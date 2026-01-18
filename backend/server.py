import os
import json
import math
import time
import asyncio
import traceback
from typing import Any, Dict, List, Optional, Set

from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from web3 import Web3
import websockets

load_dotenv()

# -----------------------------
# ENV / CONFIG
# -----------------------------
ALCHEMY_WSS_URL = os.getenv("ALCHEMY_WS_URL")
EVM_RPC_HTTP_URL = os.getenv("EVM_RPC_HTTP_URL")
STRATEGIST_EVM_PRIVATE_KEY = os.getenv("STRATEGIST_EVM_PRIVATE_KEY")

SOVEREIGN_VAULT_ADDRESS = os.getenv("SOVEREIGN_VAULT")  # contract that has defaultVault()
USDC_ADDRESS = os.getenv("USDC_ADDRESS")
PURR_ADDRESS = os.getenv("PURR_ADDRESS")
WATCH_POOL = os.getenv("WATCH_POOL")

ENABLE_HL_TRADING = os.getenv("ENABLE_HL_TRADING", "false").lower() == "true"
HL_BASE_URL = os.getenv("HL_BASE_URL", "https://api.hyperliquid-testnet.xyz")
SPOT_MARKET = os.getenv("SPOT_MARKET", "PURR/USDC")

DEBUG = os.getenv("DEBUG", "true").lower() == "true"

USDC_DECIMALS = 6
PURR_DECIMALS = int(os.getenv("PURR_DECIMALS", "5"))

# Rebalance band (1.5% default)
REBALANCE_BAND = float(os.getenv("REBALANCE_BAND", "0.015"))

# Hedging controls (micro-USDC)
MIN_HEDGE_USDC_MICRO = int(os.getenv("MIN_HEDGE_USDC_MICRO", str(50_000)))  # 0.05 USDC default
MAX_HEDGE_USDC_MICRO_PER_SWAP = int(os.getenv("MAX_HEDGE_USDC_MICRO_PER_SWAP", str(250 * 10**USDC_DECIMALS)))
HEDGE_COOLDOWN_MS = int(os.getenv("HEDGE_COOLDOWN_MS", "500"))
MAX_BOOK_LEVELS = int(os.getenv("MAX_BOOK_LEVELS", "10"))

MAX_EVENTS_STORED = int(os.getenv("MAX_EVENTS_STORED", "1000"))

required = {
    "ALCHEMY_WS_URL": ALCHEMY_WSS_URL,
    "EVM_RPC_HTTP_URL": EVM_RPC_HTTP_URL,
    "STRATEGIST_EVM_PRIVATE_KEY": STRATEGIST_EVM_PRIVATE_KEY,
    "SOVEREIGN_VAULT_ADDRESS": SOVEREIGN_VAULT_ADDRESS,
    "USDC_ADDRESS": USDC_ADDRESS,
    "PURR_ADDRESS": PURR_ADDRESS,
    "WATCH_POOL": WATCH_POOL,
}
missing = [k for k, v in required.items() if not v]
if missing:
    raise RuntimeError(f"Missing env vars: {missing}")

SOVEREIGN_VAULT_ADDRESS = Web3.to_checksum_address(SOVEREIGN_VAULT_ADDRESS)
USDC_ADDRESS = Web3.to_checksum_address(USDC_ADDRESS)
PURR_ADDRESS = Web3.to_checksum_address(PURR_ADDRESS)
WATCH_POOL = Web3.to_checksum_address(WATCH_POOL)

# -----------------------------
# ABIs (minimal)
# -----------------------------
SOVEREIGN_VAULT_ABI = [
    {"type": "function", "name": "defaultVault", "stateMutability": "view", "inputs": [], "outputs": [{"name": "", "type": "address"}]},
]
ERC20_ABI = [
    {
        "type": "function",
        "name": "balanceOf",
        "stateMutability": "view",
        "inputs": [{"name": "account", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    },
    {
        "type": "function",
        "name": "decimals",
        "stateMutability": "view",
        "inputs": [],
        "outputs": [{"name": "", "type": "uint8"}],
    },
]

SWAP_TOPIC0 = Web3.to_hex(Web3.keccak(text="Swap(address,bool,uint256,uint256,uint256,int256)"))
assert SWAP_TOPIC0.startswith("0x") and len(SWAP_TOPIC0) == 66, f"bad topic0: {SWAP_TOPIC0}"

# -----------------------------
# Web3 clients
# -----------------------------
w3_http = Web3(Web3.HTTPProvider(EVM_RPC_HTTP_URL))
account = w3_http.eth.account.from_key(STRATEGIST_EVM_PRIVATE_KEY)
STRATEGIST_ADDRESS = account.address

vault_contract = w3_http.eth.contract(address=os.getenv("SOVEREIGN_VAULT"), abi=SOVEREIGN_VAULT_ABI)
usdc_contract = w3_http.eth.contract(address=USDC_ADDRESS, abi=ERC20_ABI)
purr_contract = w3_http.eth.contract(address=PURR_ADDRESS, abi=ERC20_ABI)

CHAIN_ID = int(os.getenv("CHAIN_ID") or w3_http.eth.chain_id)

print("[boot] CWD =", os.getcwd(), flush=True)
print("[boot] DEBUG =", DEBUG, flush=True)
print("[boot] CHAIN_ID =", CHAIN_ID, flush=True)
print("[boot] ENABLE_HL_TRADING =", ENABLE_HL_TRADING, flush=True)
print("[boot] WATCH_POOL =", WATCH_POOL, flush=True)
print("[boot] SWAP_TOPIC0 =", SWAP_TOPIC0, flush=True)
print("[boot] SPOT_MARKET =", SPOT_MARKET, flush=True)
print("[boot] REBALANCE_BAND =", REBALANCE_BAND, flush=True)

# -----------------------------
# Hyperliquid SDK (spot trading)
# -----------------------------
if ENABLE_HL_TRADING:
    import eth_account
    from hyperliquid.info import Info
    from hyperliquid.exchange import Exchange

    HL_SECRET_KEY = os.getenv("HL_SECRET_KEY")
    HL_ACCOUNT_ADDRESS = os.getenv("HL_ACCOUNT_ADDRESS")
    if not HL_SECRET_KEY or not HL_ACCOUNT_ADDRESS:
        raise RuntimeError("ENABLE_HL_TRADING=true requires HL_SECRET_KEY and HL_ACCOUNT_ADDRESS")

    HL_ACCOUNT_ADDRESS = Web3.to_checksum_address(HL_ACCOUNT_ADDRESS)

    hl_info = Info(base_url=HL_BASE_URL, skip_ws=True)
    hl_wallet = eth_account.Account.from_key(HL_SECRET_KEY)
    hl_exchange = Exchange(hl_wallet, HL_BASE_URL, account_address=HL_ACCOUNT_ADDRESS)

# -----------------------------
# App + State
# -----------------------------
state_lock = asyncio.Lock()
CLIENTS: Set[WebSocket] = set()
EVENTS: List[Dict[str, Any]] = []

hedge_lock = asyncio.Lock()
last_hedge_ms = 0

purr_sz_decimals: Optional[int] = None

# -----------------------------
# Helpers
# -----------------------------
def micro_to_usdc(micro: int) -> float:
    return micro / (10 ** USDC_DECIMALS)

def usdc_to_micro(usdc: float) -> int:
    return int(usdc * (10 ** USDC_DECIMALS))

def now_ms() -> int:
    return int(time.time() * 1000)

async def broadcast(msg: Dict[str, Any]) -> None:
    dead: List[WebSocket] = []
    payload = json.dumps(msg, default=str)
    for ws in list(CLIENTS):
        try:
            await ws.send_text(payload)
        except Exception:
            dead.append(ws)
    for ws in dead:
        CLIENTS.discard(ws)

async def debug_emit(event: str, data: Dict[str, Any]) -> None:
    if not DEBUG:
        return
    msg = {"type": "debug", "data": {"event": event, "ts_ms": now_ms(), **data}}
    print(f"[debug:{event}] {json.dumps(msg['data'], default=str)[:3000]}", flush=True)
    await broadcast(msg)

def decode_swap_log(log: dict) -> Dict[str, Any]:
    sender_topic = log["topics"][1]
    sender = Web3.to_checksum_address("0x" + sender_topic[-40:])

    data_bytes = Web3.to_bytes(hexstr=log["data"])
    isZeroToOne, amountIn, fee, amountOut, usdcDelta = w3_http.codec.decode(
        ["bool", "uint256", "uint256", "uint256", "int256"],
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
        "usdcDelta": int(usdcDelta),
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
    global purr_sz_decimals
    if not ENABLE_HL_TRADING:
        return

    def _fetch():
        asset = hl_info.name_to_asset(SPOT_MARKET)
        return int(hl_info.asset_to_sz_decimals[asset])

    purr_sz_decimals = await asyncio.to_thread(_fetch)

async def get_spot_balances() -> Dict[str, float]:
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

async def get_vault_balances_evm() -> Dict[str, Any]:
    """
    Read balances from EVM defaultVault() address.
    Returns human units.
    """
    vault_addr = os.getenv("SOVEREIGN_VAULT")

    usdc_raw = await asyncio.to_thread(usdc_contract.functions.balanceOf(vault_addr).call)
    purr_raw = await asyncio.to_thread(purr_contract.functions.balanceOf(vault_addr).call)

    usdc = usdc_raw / (10 ** USDC_DECIMALS)
    purr = purr_raw / (10 ** 5)

    return {"vault": vault_addr, "usdc": usdc, "purr": purr, "usdc_raw": int(usdc_raw), "purr_raw": int(purr_raw)}

def _parse_level(lvl):
    # supports {"px": "...", "sz": "..."} and ["...", "..."] and {"px": 4.7, "sz": 1.2}
    if isinstance(lvl, dict):
        return float(lvl["px"]), float(lvl["sz"])
    if isinstance(lvl, (list, tuple)) and len(lvl) >= 2:
        return float(lvl[0]), float(lvl[1])
    raise TypeError(f"unknown level shape: {type(lvl)} {lvl}")

async def get_spot_mid_q_usdc_per_purr() -> float:
    """
    HL L2 px is USDC per 1 PURR.
    """
    if not ENABLE_HL_TRADING:
        raise RuntimeError("Need HL Info to fetch spot mid")

    snap = await asyncio.to_thread(hl_info.l2_snapshot, SPOT_MARKET)
    bids = snap.get("levels", [[], []])[0]
    asks = snap.get("levels", [[], []])[1]

    # show shapes once per call
    await debug_emit("hl_book_head", {
        "bid0": bids[0] if bids else None,
        "ask0": asks[0] if asks else None,
    })

    if not bids or not asks:
        raise RuntimeError("empty bids/asks")

    bid_px, _ = _parse_level(bids[0])
    ask_px, _ = _parse_level(asks[0])
    return (bid_px + ask_px) / 2.0

def compute_ratio(U_usdc: float, P_purr: float, q_usdc_per_purr: float) -> float:
    # target: U == P*q  => ratio = U/(P*q) should be 1
    if P_purr <= 0 or q_usdc_per_purr <= 0:
        return float("nan")
    return U_usdc / (P_purr * q_usdc_per_purr)

def rebalance_plan(U: float, P: float, q: float, half: bool = True) -> Dict[str, Any]:
    """
    q = USDC per PURR.
    Vp = P*q is USDC value of PURR.
    d_usdc = U - Vp: positive means USDC-heavy => buy PURR.
    """
    Vp = P * q
    d_usdc = U - Vp

    if abs(d_usdc) < 1e-12:
        return {"action": "NONE", "trade_usdc": 0.0, "trade_purr": 0.0, "d_usdc": d_usdc}

    factor = 0.5 if half else 1.0

    if d_usdc > 0:
        spend_usdc = d_usdc * factor
        buy_purr = spend_usdc / q
        return {"action": "BUY_PURR_SPOT", "trade_usdc": spend_usdc, "trade_purr": buy_purr, "d_usdc": d_usdc}
    else:
        recv_usdc = (-d_usdc) * factor
        sell_purr = recv_usdc / q
        return {"action": "SELL_PURR_SPOT", "trade_usdc": recv_usdc, "trade_purr": sell_purr, "d_usdc": d_usdc}

def _hl_order_has_error(res: Dict[str, Any]) -> Optional[str]:
    """
    HL returns {status:"ok", response:{type:"order", data:{statuses:[{...}]}}}
    A rejected order often appears as statuses[0].error
    """
    try:
        statuses = res.get("response", {}).get("data", {}).get("statuses", [])
        if statuses and isinstance(statuses[0], dict) and statuses[0].get("error"):
            return str(statuses[0]["error"])
    except Exception:
        return "unknown_error_shape"
    return None

async def execute_spot_rebalance_by_usdc_notional(usdc_notional_micro: int, buy_purr: bool) -> Dict[str, Any]:
    if not ENABLE_HL_TRADING:
        return {"ok": False, "reason": "ENABLE_HL_TRADING=false"}
    assert purr_sz_decimals is not None, "market decimals not initialized"

    usdc_notional_micro = min(usdc_notional_micro, MAX_HEDGE_USDC_MICRO_PER_SWAP)
    remaining_usdc = micro_to_usdc(usdc_notional_micro)

    balances = await get_spot_balances()
    avail_usdc = balances.get("USDC", 0.0)
    avail_purr = balances.get("PURR", 0.0)

    await debug_emit("hl_spot_balances", {"avail_usdc": avail_usdc, "avail_purr": avail_purr})

    if buy_purr:
        if avail_usdc <= 0:
            return {"ok": False, "reason": "no USDC available on HL account"}
        remaining_usdc = min(remaining_usdc, avail_usdc)
    else:
        if avail_purr <= 0:
            return {"ok": False, "reason": "no PURR available on HL account"}

    snap = await asyncio.to_thread(hl_info.l2_snapshot, SPOT_MARKET)
    bids = snap.get("levels", [[], []])[0]
    asks = snap.get("levels", [[], []])[1]

    # log top of book
    await debug_emit("hl_top", {
        "best_bid": bids[0] if bids else None,
        "best_ask": asks[0] if asks else None,
        "buy_purr": buy_purr,
    })

    book = (asks if buy_purr else bids)[:MAX_BOOK_LEVELS]
    if not book:
        return {"ok": False, "reason": "empty_book"}

    fills = []
    for i, lvl in enumerate(book):
        if remaining_usdc <= 0:
            break

        try:
            q_px, lvl_sz_purr = _parse_level(lvl)  # ✅ robust parsing
        except Exception:
            await debug_emit("hl_level_parse_failed", {"level": i, "lvl": lvl, "trace": traceback.format_exc()})
            continue

        # desired PURR from USDC budget
        desired_purr = remaining_usdc / q_px
        take_purr = min(lvl_sz_purr, desired_purr)
        if not buy_purr:
            take_purr = min(take_purr, avail_purr)

        raw_take = take_purr
        take_purr = round_down(take_purr, purr_sz_decimals)

        await debug_emit("spot_size_round", {
            "level": i,
            "q_px": q_px,
            "raw_take_purr": raw_take,
            "rounded_take_purr": take_purr,
            "szDecimals": purr_sz_decimals,
        })

        if take_purr <= 0:
            continue

        await debug_emit("spot_ioc_attempt", {
            "level": i,
            "is_buy": buy_purr,
            "px_usdc_per_purr": q_px,
            "sz_purr": take_purr,
            "remaining_usdc": remaining_usdc,
            "lvl_sz_purr": lvl_sz_purr,
        })

        slippage = float(os.getenv("HL_SLIPPAGE", "0.01"))  # 1% default

        await debug_emit("market_open_call", {
            "is_buy": buy_purr,
            "take_purr": take_purr,
            "slippage": slippage,
        })

        res = await asyncio.to_thread(
            hl_exchange.market_open,
            SPOT_MARKET,
            buy_purr,      # is_buy
            take_purr     # sz (already quantized to szDecimals)       # px override
        )

        err = _hl_order_has_error(res)
        if err:
            await debug_emit("spot_order_rejected", {"level": i, "error": err, "res": res})
            continue

        fills.append({"q_px": q_px, "purr": take_purr, "isBuy": buy_purr, "res": res})

        traded_usdc = take_purr * q_px
        remaining_usdc -= traded_usdc

        if not buy_purr:
            avail_purr -= take_purr

    if not fills:
        return {
            "ok": False,
            "reason": "no_fills",
            "requested_usdc_micro": usdc_notional_micro,
            "requested_usdc": micro_to_usdc(usdc_notional_micro),
            "remaining_usdc": max(0.0, remaining_usdc),
            "fills": [],
            "buy_purr": buy_purr,
        }

    return {
        "ok": True,
        "requested_usdc_micro": usdc_notional_micro,
        "requested_usdc": micro_to_usdc(usdc_notional_micro),
        "remaining_usdc": max(0.0, remaining_usdc),
        "fills": fills,
        "buy_purr": buy_purr,
    }
# -----------------------------
# Main decision: run on every swap log
# -----------------------------
async def on_swap_event(ev: Dict[str, Any]) -> None:
    global last_hedge_ms

    try:
        await debug_emit("swap_decoded", {
            "txHash": ev.get("txHash"),
            "blockNumber": ev.get("blockNumber"),
            "sender": ev.get("sender"),
            "usdcDelta_micro": ev.get("usdcDelta"),
            "usdcDelta_usdc": micro_to_usdc(ev.get("usdcDelta", 0)),
        })

        vault_bal = await get_vault_balances_evm()
        q_mid = await get_spot_mid_q_usdc_per_purr()

        U = float(vault_bal["usdc"])
        P = float(vault_bal["purr"])
        r = compute_ratio(U, P, q_mid)
        dev = r - 1.0 if not math.isnan(r) else float("nan")
        abs_dev = abs(dev) if not math.isnan(dev) else float("nan")
        Vp = P * q_mid
        d_usdc = U - Vp
        await debug_emit("imbalance", {
            "U_usdc": U,
            "P_purr": P,
            "q_usdc_per_purr": q_mid,
            "Vp_usdc": Vp,
            "d_usdc": d_usdc,
            "side": "USDC_HEAVY" if d_usdc > 0 else "PURR_HEAVY",
        })

        if math.isnan(r) or P <= 0 or q_mid <= 0:
            await debug_emit("rebalance_skip_invalid_state", {})
            return

        if abs_dev <= REBALANCE_BAND:
            await debug_emit("rebalance_skip_in_band", {"abs_dev": abs_dev, "band": REBALANCE_BAND})
            return

        async with hedge_lock:
            now = now_ms()
            since = now - last_hedge_ms
            if since < HEDGE_COOLDOWN_MS:
                await debug_emit("rebalance_skip_cooldown", {"since_ms": since, "cooldown_ms": HEDGE_COOLDOWN_MS})
                return
            last_hedge_ms = now

            plan = rebalance_plan(U, P, q_mid)
            await debug_emit("rebalance_plan", plan)

            desired_usdc = float(plan["trade_usdc"])
            desired_micro = usdc_to_micro(desired_usdc)

            if desired_micro < MIN_HEDGE_USDC_MICRO:
                await debug_emit("rebalance_skip_below_min_notional", {
                    "desired_usdc": desired_usdc,
                    "desired_micro": desired_micro,
                    "min_micro": MIN_HEDGE_USDC_MICRO,
                })
                return

            capped_micro = min(desired_micro, MAX_HEDGE_USDC_MICRO_PER_SWAP)
            if capped_micro != desired_micro:
                await debug_emit("rebalance_cap_applied", {"desired_micro": desired_micro, "capped_micro": capped_micro})

            action = plan["action"]
            buy_purr = action == "BUY_PURR_SPOT"

            await broadcast({"type": "rebalance_intent", "data": {
                "action": action,
                "usdc_micro": capped_micro,
                "usdc": micro_to_usdc(capped_micro),
                "ratio": r,
                "abs_dev": abs_dev,
                "q_mid_usdc_per_purr": q_mid,
            }})

            if ENABLE_HL_TRADING:
                result = await execute_spot_rebalance_by_usdc_notional(capped_micro, buy_purr=buy_purr)
            else:
                result = {"ok": False, "reason": "trading_disabled"}

            await debug_emit("rebalance_result", {"result": result})
            await broadcast({"type": "rebalance_result", "data": result})

    except Exception:
        await debug_emit("on_swap_event_crash", {"trace": traceback.format_exc()})

# -----------------------------
# EVM WS: Swap logs listener
# -----------------------------
async def heartbeat_loop() -> None:
    while True:
        print(f"[heartbeat] alive clients={len(CLIENTS)} events={len(EVENTS)}", flush=True)
        await asyncio.sleep(10)

async def evm_swap_listener_loop() -> None:
    while True:
        try:
            print("[evm_swap_listener] connecting...", flush=True)
            async with websockets.connect(ALCHEMY_WSS_URL, ping_interval=20, ping_timeout=20) as ws:
                params = {"address": WATCH_POOL, "topics": [SWAP_TOPIC0]}
                req = {"jsonrpc": "2.0", "id": 1, "method": "eth_subscribe", "params": ["logs", params]}

                print("[evm_swap_listener] subscribe req:", json.dumps(req), flush=True)
                await ws.send(json.dumps(req))

                resp_raw = await ws.recv()
                print("[evm_swap_listener] subscribe resp_raw:", resp_raw, flush=True)

                resp = json.loads(resp_raw)
                if "error" in resp:
                    raise RuntimeError(resp["error"])

                sub_id = resp.get("result")
                print(f"[evm_swap_listener] subscribed: {sub_id} pool={WATCH_POOL}", flush=True)

                async for raw in ws:
                    try:
                        msg = json.loads(raw)
                    except Exception:
                        print("[evm_swap_listener] bad json:", raw[:200], flush=True)
                        await debug_emit("ws_bad_json", {"raw_prefix": raw[:200]})
                        continue

                    if msg.get("method") != "eth_subscription":
                        continue

                    payload = msg.get("params", {}).get("result")
                    if not payload:
                        continue

                    await debug_emit("raw_log", {"payload": payload})

                    try:
                        ev = decode_swap_log(payload)
                    except Exception:
                        await debug_emit("decode_swap_failed", {"trace": traceback.format_exc(), "payload": payload})
                        continue

                    async with state_lock:
                        EVENTS.append(ev)
                        if len(EVENTS) > MAX_EVENTS_STORED:
                            del EVENTS[: len(EVENTS) - MAX_EVENTS_STORED]

                    await broadcast({"type": "swap", "data": ev})

                    # Always run decision logic so you can see thinking even if trading disabled
                    asyncio.create_task(on_swap_event(ev))

        except asyncio.CancelledError:
            print("[evm_swap_listener] cancelled", flush=True)
            raise
        except Exception as e:
            print(f"[evm_swap_listener] error: {e} — reconnecting...", flush=True)
            print(traceback.format_exc(), flush=True)
            await debug_emit("listener_error", {"error": str(e), "trace": traceback.format_exc()})
            await asyncio.sleep(2.0)

# -----------------------------
# API + Lifespan
# -----------------------------
from contextlib import asynccontextmanager

listener_task: Optional[asyncio.Task] = None
heartbeat_task: Optional[asyncio.Task] = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global listener_task, heartbeat_task
    print("[lifespan] startup begin", flush=True)

    if ENABLE_HL_TRADING:
        await init_market_decimals()
        print(f"[startup] trading enabled. szDecimals={purr_sz_decimals}, hlAccount={os.getenv('HL_ACCOUNT_ADDRESS')}", flush=True)
        await debug_emit("startup", {"trading": True, "szDecimals": purr_sz_decimals})
    else:
        await debug_emit("startup", {"trading": False})

    listener_task = asyncio.create_task(evm_swap_listener_loop(), name="evm_swap_listener")
    heartbeat_task = asyncio.create_task(heartbeat_loop(), name="heartbeat")

    print("Started: EVM swap listener", flush=True)

    try:
        yield
    finally:
        print("[lifespan] shutdown begin", flush=True)
        for t in [listener_task, heartbeat_task]:
            if t:
                t.cancel()
                try:
                    await t
                except asyncio.CancelledError:
                    pass
        print("[lifespan] shutdown complete", flush=True)

app = FastAPI(
    title="Swap Listener + HL Rebalance (ratio-based)",
    version="2.1.0",
    lifespan=lifespan,
)

@app.get("/health")
async def health() -> Dict[str, Any]:
    default_core_vault = await get_default_core_vault()
    return {
        "ok": True,
        "watchPool": WATCH_POOL,
        "swapTopic0": SWAP_TOPIC0,
        "defaultCoreVault": default_core_vault,
        "tradingEnabled": ENABLE_HL_TRADING,
        "spotMarket": SPOT_MARKET,
        "band": REBALANCE_BAND,
        "chainId": CHAIN_ID,
        "purrAddress": PURR_ADDRESS,
        "usdcAddress": USDC_ADDRESS,
        "hlAccount": os.getenv("HL_ACCOUNT_ADDRESS"),
        "szDecimals": purr_sz_decimals,
    }

@app.get("/events")
async def get_events(limit: int = 200) -> List[Dict[str, Any]]:
    limit = max(1, min(limit, 2000))
    async with state_lock:
        evs = list(EVENTS)
    return evs[-limit:]

@app.get("/hl/spot_state")
async def hl_spot_state():
    if not ENABLE_HL_TRADING:
        return {"ok": False, "reason": "trading_disabled"}
    st = await asyncio.to_thread(hl_info.spot_user_state, HL_ACCOUNT_ADDRESS)
    return st

@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    CLIENTS.add(ws)
    try:
        await ws.send_text(json.dumps({"type": "hello", "data": {"watchPool": WATCH_POOL, "debug": DEBUG}}))
        while True:
            _ = await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        CLIENTS.discard(ws)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="debug")