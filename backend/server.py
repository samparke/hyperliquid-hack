import os
import json
import math
import time
import asyncio
from typing import Any, Dict, List, Optional, Set, Deque, Tuple
from collections import deque

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel

from web3 import Web3
import websockets

load_dotenv()

# -----------------------------
# ENV / CONFIG
# -----------------------------
ALCHEMY_WSS_URL = os.getenv("ALCHEMY_WS_URL")
EVM_RPC_HTTP_URL = os.getenv("EVM_RPC_HTTP_URL")
STRATEGIST_EVM_PRIVATE_KEY = os.getenv("STRATEGIST_EVM_PRIVATE_KEY")
CHAIN_ID = int(os.getenv("CHAIN_ID", "999"))

SOVEREIGN_VAULT_ADDRESS = os.getenv("SOVEREIGN_VAULT_ADDRESS")
USDC_ADDRESS = os.getenv("USDC_ADDRESS")
WATCH_POOL = os.getenv("WATCH_POOL")  # single pool

ENABLE_HL_TRADING = os.getenv("ENABLE_HL_TRADING", "false").lower() == "true"
HL_BASE_URL = os.getenv("HL_BASE_URL", "https://api.hyperliquid-testnet.xyz")
SPOT_MARKET = os.getenv("SPOT_MARKET", "PURR/USDC")

USDC_DECIMALS = 6

# Hedging controls (micro-USDC)
MIN_HEDGE_USDC_MICRO = int(os.getenv("MIN_HEDGE_USDC_MICRO", str(25 * 10**USDC_DECIMALS)))
MAX_HEDGE_USDC_MICRO_PER_SWAP = int(os.getenv("MAX_HEDGE_USDC_MICRO_PER_SWAP", str(250 * 10**USDC_DECIMALS)))
HEDGE_COOLDOWN_MS = int(os.getenv("HEDGE_COOLDOWN_MS", "500"))
MAX_BOOK_LEVELS = int(os.getenv("MAX_BOOK_LEVELS", "10"))

# State sizes
MAX_EVENTS_STORED = int(os.getenv("MAX_EVENTS_STORED", "1000"))

required = {
    "ALCHEMY_WS_URL": ALCHEMY_WSS_URL,
    "EVM_RPC_HTTP_URL": EVM_RPC_HTTP_URL,
    "STRATEGIST_EVM_PRIVATE_KEY": STRATEGIST_EVM_PRIVATE_KEY,
    "SOVEREIGN_VAULT_ADDRESS": SOVEREIGN_VAULT_ADDRESS,
    "USDC_ADDRESS": USDC_ADDRESS,
    "WATCH_POOL": WATCH_POOL,
}
missing = [k for k, v in required.items() if not v]
if missing:
    raise RuntimeError(f"Missing env vars: {missing}")

SOVEREIGN_VAULT_ADDRESS = Web3.to_checksum_address(SOVEREIGN_VAULT_ADDRESS)
USDC_ADDRESS = Web3.to_checksum_address(USDC_ADDRESS)
WATCH_POOL = Web3.to_checksum_address(WATCH_POOL)

# -----------------------------
# ABIs (minimal)
# -----------------------------
SOVEREIGN_VAULT_ABI = [
    {"type":"function","name":"defaultVault","stateMutability":"view","inputs":[],"outputs":[{"name":"","type":"address"}]},
]
ERC20_ABI = [
    {"type":"function","name":"balanceOf","stateMutability":"view","inputs":[{"name":"account","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},
]

# event Swap(address indexed sender, bool isZeroToOne, uint256 amountIn, uint256 fee, uint256 amountOut, int256 usdcDelta);
SWAP_TOPIC0 = Web3.keccak(text="Swap(address,bool,uint256,uint256,uint256,int256)").hex()

# -----------------------------
# Web3 clients
# -----------------------------
w3_http = Web3(Web3.HTTPProvider(EVM_RPC_HTTP_URL))
account = w3_http.eth.account.from_key(STRATEGIST_EVM_PRIVATE_KEY)
STRATEGIST_ADDRESS = account.address

vault_contract = w3_http.eth.contract(address=SOVEREIGN_VAULT_ADDRESS, abi=SOVEREIGN_VAULT_ABI)
usdc_contract = w3_http.eth.contract(address=USDC_ADDRESS, abi=ERC20_ABI)

# -----------------------------
# Hyperliquid SDK (hedging)
# -----------------------------
if ENABLE_HL_TRADING:
    # pip install hyperliquid-python-sdk eth-account
    import eth_account
    from hyperliquid.info import Info
    from hyperliquid.exchange import Exchange

    HL_SECRET_KEY = os.getenv("HL_SECRET_KEY")
    HL_ACCOUNT_ADDRESS = os.getenv("HL_ACCOUNT_ADDRESS")  # address whose Core balances are being traded
    if not HL_SECRET_KEY or not HL_ACCOUNT_ADDRESS:
        raise RuntimeError("ENABLE_HL_TRADING=true requires HL_SECRET_KEY and HL_ACCOUNT_ADDRESS")

    HL_ACCOUNT_ADDRESS = Web3.to_checksum_address(HL_ACCOUNT_ADDRESS)

    hl_info = Info(base_url=HL_BASE_URL, skip_ws=True)
    hl_wallet = eth_account.Account.from_key(HL_SECRET_KEY)
    hl_exchange = Exchange(hl_wallet, HL_BASE_URL, account_address=HL_ACCOUNT_ADDRESS)

# -----------------------------
# App + State
# -----------------------------
app = FastAPI(title="Swap Listener + HL Hedge (PURR/USDC)", version="1.0.0")

state_lock = asyncio.Lock()
CLIENTS: Set[WebSocket] = set()
EVENTS: List[Dict[str, Any]] = []

# Hedge concurrency + cooldown
hedge_lock = asyncio.Lock()
last_hedge_ms = 0

# Cached market decimals
purr_sz_decimals: Optional[int] = None

# -----------------------------
# Helpers
# -----------------------------
def micro_to_usdc(micro: int) -> float:
    return micro / (10 ** USDC_DECIMALS)

def now_ms() -> int:
    return int(time.time() * 1000)

async def broadcast(msg: Dict[str, Any]) -> None:
    dead: List[WebSocket] = []
    payload = json.dumps(msg)
    for ws in list(CLIENTS):
        try:
            await ws.send_text(payload)
        except Exception:
            dead.append(ws)
    for ws in dead:
        CLIENTS.discard(ws)

def decode_swap_log(log: dict) -> Dict[str, Any]:
    sender_topic = log["topics"][1]
    sender = Web3.to_checksum_address("0x" + sender_topic[-40:])

    data_bytes = Web3.to_bytes(hexstr=log["data"])
    isZeroToOne, amountIn, fee, amountOut, usdcDelta = w3_http.codec.decode(
        ["bool","uint256","uint256","uint256","int256"],
        data_bytes
    )

    bn = log.get("blockNumber")
    block_number = int(bn, 16) if isinstance(bn, str) else int(bn)

    return {
        "pool": Web3.to_checksum_address(log["address"]),
        "sender": sender,
        "isZeroToOne": bool(isZeroToOne),
        "amountIn": int(amountIn),
        "fee": int(fee),
        "amountOut": int(amountOut),
        "usdcDelta": int(usdcDelta),  # signed micro-USDC delta
        "txHash": log.get("transactionHash"),
        "blockNumber": block_number,
    }

async def get_default_core_vault() -> str:
    v = await asyncio.to_thread(vault_contract.functions.defaultVault().call)
    return Web3.to_checksum_address(v)

def round_down(x: float, decimals: int) -> float:
    m = 10 ** decimals
    return math.floor(x * m) / m

async def init_market_decimals() -> None:
    """
    Fetch spot meta once to get szDecimals for SPOT_MARKET.
    """
    global purr_sz_decimals
    if not ENABLE_HL_TRADING:
        return

    # SDK Info object caches name_to_coin and asset_to_sz_decimals internally
    # Resolve asset id for name and read sz decimals from SDK mapping.
    def _fetch():
        asset = hl_info.name_to_asset(SPOT_MARKET)
        return int(hl_info.asset_to_sz_decimals[asset])

    purr_sz_decimals = await asyncio.to_thread(_fetch)

async def get_spot_balances() -> Dict[str, float]:
    """
    Returns dict coin->total balance as float strings converted to float.
    Useful to avoid failing orders due to insufficient inventory.
    """
    if not ENABLE_HL_TRADING:
        return {}

    def _fetch():
        st = hl_info.spot_user_state(HL_ACCOUNT_ADDRESS)
        out: Dict[str, float] = {}
        for b in st.get("balances", []):
            coin = b.get("coin")
            total = float(b.get("total", "0"))
            out[coin] = total
        return out

    return await asyncio.to_thread(_fetch)

async def execute_spot_hedge(usdc_amount_micro: int, toUsd: bool) -> Dict[str, Any]:
    """
    toUsd=True  => sell PURR for USDC (hit bids)
    toUsd=False => buy PURR with USDC (lift asks)

    Uses IOC sweep across top book levels.
    """
    if not ENABLE_HL_TRADING:
        return {"ok": False, "reason": "ENABLE_HL_TRADING=false"}

    assert purr_sz_decimals is not None, "market decimals not initialized"

    # Cap per swap event
    usdc_amount_micro = min(usdc_amount_micro, MAX_HEDGE_USDC_MICRO_PER_SWAP)

    remaining_usdc = micro_to_usdc(usdc_amount_micro)

    # Balance checks (optional but recommended)
    balances = await get_spot_balances()
    # Note: In HL spot, coin name for PURR/USDC may be "PURR" in balances
    avail_usdc = balances.get("USDC", 0.0)
    avail_purr = balances.get("PURR", 0.0)

    if not toUsd and avail_usdc <= 0:
        return {"ok": False, "reason": "no USDC available on HL account"}
    if toUsd and avail_purr <= 0:
        return {"ok": False, "reason": "no PURR available on HL account"}

    # If buying, cap to available USDC
    if not toUsd:
        remaining_usdc = min(remaining_usdc, avail_usdc)

    # If selling, cap sell size by available PURR. We'll derive max PURR we *might* need from best bid.
    snap = await asyncio.to_thread(hl_info.l2_snapshot, SPOT_MARKET)
    bids = snap.get("levels", [[], []])[0]
    asks = snap.get("levels", [[], []])[1]

    if toUsd and not bids:
        return {"ok": False, "reason": "empty bids"}
    if (not toUsd) and not asks:
        return {"ok": False, "reason": "empty asks"}

    book = bids if toUsd else asks
    book = book[:MAX_BOOK_LEVELS]
    is_buy = not toUsd

    fills = []
    for lvl in book:
        if remaining_usdc <= 0:
            break

        try:
            px = float(lvl["px"])
            lvl_sz = float(lvl["sz"])
        except Exception:
            continue

        desired_sz = remaining_usdc / px
        take_sz = min(lvl_sz, desired_sz)

        # If selling, cap by remaining PURR
        if toUsd:
            take_sz = min(take_sz, avail_purr)
            if take_sz <= 0:
                break

        take_sz = round_down(take_sz, purr_sz_decimals)
        if take_sz <= 0:
            continue

        # IOC at that level price
        order_type = {"limit": {"tif": "Ioc"}}
        res = await asyncio.to_thread(hl_exchange.order, SPOT_MARKET, is_buy, px, take_sz, order_type)

        fills.append({"px": px, "sz": take_sz, "isBuy": is_buy, "res": res})

        traded_usdc = take_sz * px
        remaining_usdc -= traded_usdc
        if toUsd:
            avail_purr -= take_sz

    return {
        "ok": True,
        "requested_usdc_micro": usdc_amount_micro,
        "requested_usdc": micro_to_usdc(usdc_amount_micro),
        "remaining_usdc": max(0.0, remaining_usdc),
        "fills": fills,
    }

async def on_swap_event(ev: Dict[str, Any]) -> None:
    """
    Interpretation:
      +delta: pool gained USDC => users sold PURR => hedge by buying PURR (toUsd=False)
      -delta: pool lost USDC  => users bought PURR => hedge by selling PURR (toUsd=True)
    """
    global last_hedge_ms

    delta = int(ev["usdcDelta"])
    amt_micro = abs(delta)

    if amt_micro < MIN_HEDGE_USDC_MICRO:
        return

    # cooldown + single-flight hedge
    async with hedge_lock:
        now = now_ms()
        if now - last_hedge_ms < HEDGE_COOLDOWN_MS:
            return
        last_hedge_ms = now

        toUsd = delta < 0
        await broadcast({"type": "hedge_intent", "data": {"pool": ev["pool"], "toUsd": toUsd, "usdc_micro": amt_micro}})

        result = await execute_spot_hedge(amt_micro, toUsd)
        await broadcast({"type": "hedge_result", "data": result})

# -----------------------------
# EVM WS: Swap logs listener (single pool)
# -----------------------------
async def evm_swap_listener_loop() -> None:
    while True:
        try:
            async with websockets.connect(ALCHEMY_WSS_URL, ping_interval=20, ping_timeout=20) as ws:
                params = {"address": [WATCH_POOL], "topics": [SWAP_TOPIC0]}
                await ws.send(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_subscribe", "params": ["logs", params]}))
                resp = json.loads(await ws.recv())
                if "error" in resp:
                    raise RuntimeError(resp["error"])
                sub_id = resp.get("result")
                print(f"[evm_swap_listener] subscribed: {sub_id} pool={WATCH_POOL}")

                async for raw in ws:
                    msg = json.loads(raw)
                    if msg.get("method") != "eth_subscription":
                        continue
                    payload = msg.get("params", {}).get("result")
                    if not payload:
                        continue

                    try:
                        ev = decode_swap_log(payload)
                    except Exception:
                        continue

                    async with state_lock:
                        EVENTS.append(ev)
                        if len(EVENTS) > MAX_EVENTS_STORED:
                            del EVENTS[: len(EVENTS) - MAX_EVENTS_STORED]

                    await broadcast({"type": "swap", "data": ev})
                    if ENABLE_HL_TRADING:
                        asyncio.create_task(on_swap_event(ev))

        except Exception as e:
            print(f"[evm_swap_listener] error: {e} — reconnecting...")
            await asyncio.sleep(2.0)

# -----------------------------
# API
# -----------------------------
@app.on_event("startup")
async def startup() -> None:
    if ENABLE_HL_TRADING:
        await init_market_decimals()
        print(f"[startup] hedging enabled. szDecimals={purr_sz_decimals}, hlAccount={os.getenv('HL_ACCOUNT_ADDRESS')}")

    asyncio.create_task(evm_swap_listener_loop())
    print("Started: EVM swap listener")

@app.get("/health")
async def health() -> Dict[str, Any]:
    default_core_vault = await get_default_core_vault()
    return {
        "ok": True,
        "watchPool": WATCH_POOL,
        "swapTopic0": SWAP_TOPIC0,
        "defaultCoreVault": default_core_vault,
        "hedgingEnabled": ENABLE_HL_TRADING,
        "spotMarket": SPOT_MARKET,
    }

@app.get("/events")
async def get_events(limit: int = 200) -> List[Dict[str, Any]]:
    limit = max(1, min(limit, 2000))
    async with state_lock:
        evs = list(EVENTS)
    return evs[-limit:]

@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    CLIENTS.add(ws)
    try:
        await ws.send_text(json.dumps({"type": "hello", "data": {"watchPool": WATCH_POOL}}))
        while True:
            _ = await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        CLIENTS.discard(ws)