import os
import json
import asyncio
from typing import Optional, List, Dict, Any, Set

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel
from web3 import Web3
import eth_account
from hyperliquid.info import Info
from hyperliquid.exchange import Exchange
from hyperliquid.utils import constants
import websockets

load_dotenv()

# -------- Config --------
HL_SECRET_KEY = os.getenv("HL_SECRET_KEY")       # 0x...
HL_ACCOUNT_ADDRESS = os.getenv("HL_ACCOUNT_ADDRESS")  # 0x...

if not HL_SECRET_KEY or not HL_ACCOUNT_ADDRESS:
    raise RuntimeError("Set HL_SECRET_KEY and HL_ACCOUNT_ADDRESS in your .env")

hl_info = Info(constants.TESTNET_API_URL, skip_ws=True)  # REST-only info client  [oai_citation:3‡PyPI](https://pypi.org/project/hyperliquid-python-sdk/?utm_source=chatgpt.com)

wallet = eth_account.Account.from_key(HL_SECRET_KEY)
hl_exchange = Exchange(wallet, constants.TESTNET_API_URL, account_address=HL_ACCOUNT_ADDRESS)  #  [oai_citation:4‡thedocumentation.org](https://thedocumentation.org/hyperliquid-python-sdk/api_reference/?utm_source=chatgpt.com)

PURR_MARKET = "PURR/USDC"
USDC_DECIMALS = 6

WS_URL = os.getenv("ALCHEMY_WS_URL")
if not WS_URL:
    raise RuntimeError("Missing ALCHEMY_WS_URL in .env")

MAX_EVENTS_STORED = int(os.getenv("MAX_EVENTS_STORED", "2000"))

# -------- Swap event signature --------
# event Swap(address indexed sender, bool isZeroToOne, uint256 amountIn, uint256 fee, uint256 amountOut, uint256 usdcBalance);
SWAP_TOPIC0 = Web3.keccak(text="Swap(address,bool,uint256,uint256,uint256,uint256)").hex()

app = FastAPI(title="HyperEVM Swap Event Listener (WS)", version="1.0.0")

# In-memory state
WATCHED: Set[str] = set()                 # checksum addresses
EVENTS: List[Dict[str, Any]] = []         # decoded swap events
CLIENTS: Set[WebSocket] = set()

state_lock = asyncio.Lock()

# Web3 instance just for utilities + ABI decoding
w3 = Web3()


class WatchRequest(BaseModel):
    address: str


def to_checksum(addr: str) -> str:
    if not Web3.is_address(addr):
        raise ValueError("Invalid address")
    return Web3.to_checksum_address(addr)


def decode_swap_log(log: Dict[str, Any]) -> Dict[str, Any]:
    """
    Decode the Swap event from a raw log object returned by eth_subscribe.
    - topics[1] contains indexed sender
    - data contains: bool, uint256, uint256, uint256, uint256
    """
    topics = log.get("topics", [])
    if len(topics) < 2 or topics[0].lower() != SWAP_TOPIC0.lower():
        raise ValueError("Not a Swap log")

    sender_topic = topics[1]
    sender = Web3.to_checksum_address("0x" + sender_topic[-40:])

    data_bytes = Web3.to_bytes(hexstr=log.get("data", "0x"))
    isZeroToOne, amountIn, fee, amountOut, usdcBalance = w3.codec.decode(
        ["bool", "uint256", "uint256", "uint256", "uint256"],
        data_bytes,
    )

    # blockNumber/logIndex may be hex strings depending on provider
    bn = log.get("blockNumber")
    li = log.get("logIndex")
    txh = log.get("transactionHash")

    return {
        "pool": Web3.to_checksum_address(log["address"]),
        "sender": sender,
        "isZeroToOne": bool(isZeroToOne),
        "amountIn": str(amountIn),
        "fee": str(fee),
        "amountOut": str(amountOut),
        "usdcBalance": str(usdcBalance),
        "txHash": txh,
        "blockNumber": int(bn, 16) if isinstance(bn, str) else bn,
        "logIndex": int(li, 16) if isinstance(li, str) else li,
    }


async def broadcast(event: Dict[str, Any]) -> None:
    dead: List[WebSocket] = []
    msg = json.dumps({"type": "swap", "data": event})

    for ws in list(CLIENTS):
        try:
            await ws.send_text(msg)
        except Exception:
            dead.append(ws)

    for ws in dead:
        CLIENTS.discard(ws)


async def eth_subscribe_logs(ws, addrs: List[str]) -> str:
    """
    Subscribe to Swap logs for given addresses.
    Returns subscription id.
    """
    params = {
        "address": addrs if addrs else ["0x0000000000000000000000000000000000000000"],
        "topics": [SWAP_TOPIC0],
    }
    req = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_subscribe",
        "params": ["logs", params],
    }
    await ws.send(json.dumps(req))
    resp = json.loads(await ws.recv())
    if "error" in resp:
        raise RuntimeError(f"eth_subscribe error: {resp['error']}")
    return resp["result"]


async def eth_unsubscribe(ws, sub_id: str) -> None:
    req = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "eth_unsubscribe",
        "params": [sub_id],
    }
    await ws.send(json.dumps(req))
    # provider will respond; we can ignore errors here
    try:
        _ = await ws.recv()
    except Exception:
        pass


async def subscribe_loop() -> None:
    """
    Maintains a WS connection and eth_subscribe for Swap logs.
    If WATCHED changes, it re-subscribes with updated address filter.
    """
    last_filter_key: Optional[str] = None
    sub_id: Optional[str] = None

    while True:
        try:
            async with websockets.connect(
                WS_URL,
                ping_interval=20,
                ping_timeout=20,
                close_timeout=5,
                max_queue=1024,
            ) as ws:

                while True:
                    async with state_lock:
                        addrs = sorted(WATCHED)
                    filter_key = ",".join(addrs)

                    # (Re)subscribe if needed
                    if filter_key != last_filter_key:
                        if sub_id:
                            await eth_unsubscribe(ws, sub_id)
                            sub_id = None

                        sub_id = await eth_subscribe_logs(ws, addrs)
                        last_filter_key = filter_key

                    # Wait for messages
                    msg = json.loads(await ws.recv())

                    if msg.get("method") == "eth_subscription":
                        payload = msg.get("params", {}).get("result", {})
                        try:
                            ev = decode_swap_log(payload)
                            
                        except Exception:
                            continue

                        usdc_balance_micro = ev["usdcBalance"]  # make sure decoder returns int
                        toUsd = True  # your vault logic decides
                        asyncio.create_task(rebalance(usdc_balance_micro, toUsd))

                        async with state_lock:
                            EVENTS.append(ev)
                            if len(EVENTS) > MAX_EVENTS_STORED:
                                del EVENTS[: len(EVENTS) - MAX_EVENTS_STORED]

                        await broadcast(ev)

        except Exception as e:
            print(f"[subscribe_loop] error: {e}. Reconnecting...")
            await asyncio.sleep(2.0)

import math

def round_down(x: float, decimals: int) -> float:
    m = 10 ** decimals
    return math.floor(x * m) / m

async def rebalance(usdc_amount_micro: int, toUsd: bool) -> None:
    """
    usdc_amount_micro: how much USDC notional to rebalance in micro-USDC (1e-6).
    toUsd=True  => SELL PURR to receive ~usdc_amount_micro USDC (because USDC was withdrawn / PURR overweight)
    toUsd=False => BUY PURR spending ~usdc_amount_micro USDC (because PURR was withdrawn / USDC overweight)
    """

    # Convert micro-USDC to USDC float
    remaining_usdc = usdc_amount_micro / (10 ** USDC_DECIMALS)

    snap = await asyncio.to_thread(hl_info.l2_snapshot, PURR_MARKET)
    bids = snap.get("levels", [[], []])[0]
    asks = snap.get("levels", [[], []])[1]

    if toUsd and not bids:
        print("[rebalance] No bids available.")
        return
    if (not toUsd) and not asks:
        print("[rebalance] No asks available.")
        return

    # If you want exact sizing: fetch szDecimals from spot_meta and cache it.
    # This is a safe default; you can tighten later.
    sz_decimals = 6

    book = bids if toUsd else asks
    is_buy = not toUsd

    filled_usdc = 0.0
    filled_purr = 0.0

    for lvl in book:
        if remaining_usdc <= 0:
            break

        px = float(lvl["px"])      # USDC per PURR
        lvl_sz = float(lvl["sz"])  # PURR available at this level

        # Target PURR size to trade for remaining USDC notional
        desired_sz = remaining_usdc / px
        take_sz = min(lvl_sz, desired_sz)

        # Round down size so we don't exceed remaining notional after rounding
        take_sz = round_down(take_sz, sz_decimals)
        if take_sz <= 0:
            continue

        tif = {"limit": {"tif": "Ioc"}}

        # Place aggressive limit at best level price (crosses immediately if liquidity is there)
        res = await asyncio.to_thread(hl_exchange.order, PURR_MARKET, is_buy, px, take_sz, tif)
        print("[rebalance] order:", {"buy": is_buy, "px": px, "sz": take_sz, "res": res})

        traded_usdc = take_sz * px
        remaining_usdc -= traded_usdc

        filled_usdc += traded_usdc
        filled_purr += take_sz

    filled_usdc_micro = int(round(filled_usdc * (10 ** USDC_DECIMALS)))
    remaining_usdc_micro = int(round(max(0.0, remaining_usdc) * (10 ** USDC_DECIMALS)))

    print(
        f"[rebalance] toUsd={toUsd} "
        f"filled_usdc_micro={filled_usdc_micro} filled_purr={filled_purr:.6f} "
        f"remaining_usdc_micro={remaining_usdc_micro}"
    )

@app.on_event("startup")
async def startup():
    asyncio.create_task(subscribe_loop())


@app.get("/health")
async def health():
    async with state_lock:
        watched = sorted(WATCHED)
        stored = len(EVENTS)

    return {
        "ok": True,
        "wsUrl": WS_URL.split("/v2/")[0] + "/v2/<redacted>",
        "swapTopic0": SWAP_TOPIC0,
        "watchedContracts": watched,
        "storedEvents": stored,
        "serverWsEndpoint": "/ws",
    }


@app.post("/watch")
async def watch(req: WatchRequest):
    try:
        addr = to_checksum(req.address)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    async with state_lock:
        WATCHED.add(addr)

    return {"ok": True, "watching": addr, "total": len(WATCHED)}


@app.get("/watch")
async def list_watch():
    async with state_lock:
        return {"watched": sorted(WATCHED)}


@app.get("/events")
async def get_events(limit: int = 200, since_block: Optional[int] = None):
    limit = max(1, min(limit, 2000))
    async with state_lock:
        evs = list(EVENTS)

    if since_block is not None:
        evs = [e for e in evs if int(e["blockNumber"]) >= since_block]

    return evs[-limit:]


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    CLIENTS.add(ws)
    try:
        async with state_lock:
            watched = sorted(WATCHED)
        await ws.send_text(json.dumps({"type": "hello", "watchedContracts": watched}))

        # keep alive
        while True:
            _ = await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        CLIENTS.discard(ws)