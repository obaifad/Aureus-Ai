"""
Aureus AI - MT5 Bridge Server
==============================
Flutter (mobile/desktop/web) cannot embed the official `MetaTrader5`
Python package, which is a native Windows library that talks to a
locally-running MT5 terminal. This small FastAPI server runs on the SAME
Windows machine as your MT5 terminal and exposes:

  GET  /health               - unauthenticated reachability + MT5 state
  GET  /account              - account info            (X-API-Key)
  GET  /candles              - OHLC candles, real UTC  (X-API-Key)
  GET  /tick                 - latest bid/ask, real UTC(X-API-Key)
  WS   /stream/ticks         - live ticks + heartbeats (?api_key=)
  POST /ai-commentary        - Anthropic proxy         (X-API-Key)

Timestamps: MT5 returns times in the BROKER SERVER's timezone (commonly
GMT+2/GMT+3) as if they were UTC. This server detects that offset from
live ticks (or takes MT5_SERVER_UTC_OFFSET_HOURS from .env) and returns
REAL UTC everywhere, so the app's closed-candle, stale-feed and session
logic work correctly.

Threading: the MetaTrader5 package is not thread-safe, and FastAPI runs
sync endpoints on a thread pool — every MT5 call goes through MT5_LOCK.

Run it with:
    pip install -r requirements.txt
    python mt5_bridge_server.py
"""

import asyncio
import logging
import os
import threading
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Set

import httpx
import MetaTrader5 as mt5
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

load_dotenv()  # reads bridge/.env — never committed

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [AureusBridge] %(message)s",
)
log = logging.getLogger("aureus_bridge")

BRIDGE_API_KEY = os.environ.get("BRIDGE_API_KEY", "")
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-4-6")

DEFAULT_SYMBOL = os.environ.get("BRIDGE_SYMBOL", "XAUUSD")
TICK_POLL_SECONDS = 0.25
HEARTBEAT_SECONDS = 5.0
STALE_FEED_TIMEFRAME_MULTIPLIER = 2

MT5_LOCK = threading.Lock()

TIMEFRAME_MAP = {
    1: mt5.TIMEFRAME_M1,
    5: mt5.TIMEFRAME_M5,
    15: mt5.TIMEFRAME_M15,
    60: mt5.TIMEFRAME_H1,
    240: mt5.TIMEFRAME_H4,
    1440: mt5.TIMEFRAME_D1,
}


# ---------------------------------------------------------------------------
# Broker server time -> real UTC
# ---------------------------------------------------------------------------
class ServerClock:
    """Tracks the broker-server-time offset (seconds) vs real UTC.

    Detection only uses ticks that just CHANGED (i.e. arrived moments ago),
    so a stale weekend tick can never produce a wrong offset. Offsets are
    rounded to 30 minutes.
    """

    def __init__(self) -> None:
        env_hours = os.environ.get("MT5_SERVER_UTC_OFFSET_HOURS", "").strip()
        self.fixed = env_hours != ""
        self.offset_seconds: int = int(float(env_hours) * 3600) if self.fixed else 0
        self.detected = self.fixed
        if self.fixed:
            log.info("Using fixed MT5 server offset from .env: %+.1fh", self.offset_seconds / 3600)

    def observe_fresh_tick(self, tick_time_seconds: int) -> None:
        if self.fixed:
            return
        diff = tick_time_seconds - time.time()
        rounded = int(round(diff / 1800.0) * 1800)
        if abs(diff - rounded) > 120 or abs(rounded) > 14 * 3600:
            return
        if not self.detected or rounded != self.offset_seconds:
            log.info("Detected MT5 server time offset: %+.1fh", rounded / 3600)
        self.offset_seconds = rounded
        self.detected = True

    def to_utc_seconds(self, server_seconds: int) -> int:
        return int(server_seconds) - self.offset_seconds

    def to_utc_ms(self, server_ms: int) -> int:
        return int(server_ms) - self.offset_seconds * 1000


CLOCK = ServerClock()


def _mt5_call(fn, *args):
    with MT5_LOCK:
        return fn(*args)


_last_init_attempt = 0.0
_last_init_error = None
_INIT_RETRY_SECONDS = 10.0


def _ensure_connected_locked() -> bool:
    global _last_init_attempt, _last_init_error
    if mt5.terminal_info() is not None:
        return True
    # mt5.initialize() is a slow, blocking IPC call — retrying it on every
    # 250ms tick poll (or every request) when MT5 isn't installed/running
    # pegs a CPU core and floods the log forever. Retry at most once every
    # _INIT_RETRY_SECONDS instead.
    now = time.time()
    if now - _last_init_attempt < _INIT_RETRY_SECONDS:
        return False
    _last_init_attempt = now
    ok = mt5.initialize()
    if not ok:
        error = mt5.last_error()
        if error != _last_init_error:
            log.warning("mt5.initialize() failed: %s", error)
            _last_init_error = error
    else:
        _last_init_error = None
    return bool(ok)


def ensure_connected() -> None:
    with MT5_LOCK:
        if not _ensure_connected_locked():
            raise HTTPException(status_code=503, detail=f"Could not connect to MT5 terminal: {mt5.last_error()}")


def _select_symbol(symbol: str) -> None:
    with MT5_LOCK:
        if not mt5.symbol_select(symbol, True):
            raise HTTPException(404, f"Symbol '{symbol}' not found or not enabled in MT5.")


# ---------------------------------------------------------------------------
# Tick hub: ONE poller per symbol, broadcasting to every WebSocket client
# ---------------------------------------------------------------------------
class TickHub:
    def __init__(self) -> None:
        self._subscribers: Dict[str, Set[asyncio.Queue]] = {}
        self._tasks: Dict[str, asyncio.Task] = {}
        self.latest: Dict[str, dict] = {}

    def subscribe(self, symbol: str) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(maxsize=50)
        self._subscribers.setdefault(symbol, set()).add(queue)
        if symbol not in self._tasks or self._tasks[symbol].done():
            self._tasks[symbol] = asyncio.create_task(self._poll(symbol))
        return queue

    def unsubscribe(self, symbol: str, queue: asyncio.Queue) -> None:
        subs = self._subscribers.get(symbol)
        if subs is not None:
            subs.discard(queue)

    def _read_tick(self, symbol: str):
        with MT5_LOCK:
            if not _ensure_connected_locked():
                return None
            return mt5.symbol_info_tick(symbol)

    async def _poll(self, symbol: str) -> None:
        log.info("Tick poller started for %s", symbol)
        last_time_msc: Optional[int] = None
        try:
            while self._subscribers.get(symbol):
                try:
                    tick = await asyncio.to_thread(self._read_tick, symbol)
                except Exception as e:  # never let the poller die on one bad read
                    log.warning("Tick read failed: %s", e)
                    tick = None
                if tick is not None and tick.time_msc != last_time_msc:
                    changed_while_watching = last_time_msc is not None
                    last_time_msc = tick.time_msc
                    if changed_while_watching:
                        CLOCK.observe_fresh_tick(int(tick.time))
                    payload = {
                        "type": "tick",
                        "symbol": symbol,
                        "time": CLOCK.to_utc_seconds(tick.time),
                        "time_msc": CLOCK.to_utc_ms(tick.time_msc),
                        "bid": float(tick.bid),
                        "ask": float(tick.ask),
                        "last": float(tick.last) if tick.last else float(tick.bid),
                    }
                    self.latest[symbol] = payload
                    for queue in list(self._subscribers.get(symbol, ())):
                        if queue.full():
                            try:
                                queue.get_nowait()  # drop oldest; slow client
                            except asyncio.QueueEmpty:
                                pass
                        queue.put_nowait(payload)
                await asyncio.sleep(TICK_POLL_SECONDS)
        finally:
            log.info("Tick poller stopped for %s", symbol)


HUB = TickHub()


@asynccontextmanager
async def lifespan(_: FastAPI):
    with MT5_LOCK:
        if not mt5.initialize():
            log.warning("MT5 not reachable at startup (%s) — will retry on demand", mt5.last_error())
        else:
            log.info("Connected to MT5 terminal")
            mt5.symbol_select(DEFAULT_SYMBOL, True)
    # Keep one poller alive from startup so the server-time offset is
    # detected (and /candles returns real UTC) even before any app connects
    # to the tick stream.
    calibration_queue = HUB.subscribe(DEFAULT_SYMBOL)
    yield
    HUB.unsubscribe(DEFAULT_SYMBOL, calibration_queue)
    with MT5_LOCK:
        mt5.shutdown()


app = FastAPI(title="Aureus AI - MT5 Bridge", lifespan=lifespan)

# Origin filtering doesn't protect a server called by a mobile app — real
# protection is BRIDGE_API_KEY.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


class CandleOut(BaseModel):
    time: int  # candle OPEN time, real UTC seconds
    open: float
    high: float
    low: float
    close: float
    tick_volume: float


class TradeSetupIn(BaseModel):
    symbol: str
    direction: str
    timeframe: str
    setup_type: str = "confluence"
    entry: float
    stop_loss: float
    take_profit: float
    pattern: str
    risk_reward: float


class AiCommentaryOut(BaseModel):
    text: str


def require_api_key(x_api_key: Optional[str] = Header(default=None)) -> None:
    """No-op when BRIDGE_API_KEY is unset (LAN testing). Set it before
    exposing this server beyond your local network."""
    if not BRIDGE_API_KEY:
        return
    if x_api_key != BRIDGE_API_KEY:
        raise HTTPException(status_code=401, detail="Missing or invalid X-API-Key")


@app.get("/health")
def health():
    with MT5_LOCK:
        connected = mt5.terminal_info() is not None
    return {
        "connected": connected,
        "server_utc_offset_hours": CLOCK.offset_seconds / 3600,
        "offset_detected": CLOCK.detected,
        "auth_required": bool(BRIDGE_API_KEY),
    }


@app.get("/symbols", dependencies=[Depends(require_api_key)])
def find_symbols(query: str = Query(default="XAU", description="Case-insensitive substring, e.g. XAU, GOLD")):
    """Lists broker symbol names matching [query] — brokers rename/suffix
    gold in all sorts of ways (XAUUSD.m, GOLD#, XAUUSD...), so this is the
    quickest way to find the exact string to put in MT5_SYMBOL (app .env)
    when /candles rejects the default "XAUUSD" as not found."""
    ensure_connected()
    with MT5_LOCK:
        all_symbols = mt5.symbols_get() or ()
        matches = [s.name for s in all_symbols if query.upper() in s.name.upper()]
    return {"query": query, "matches": matches}


@app.get("/account", dependencies=[Depends(require_api_key)])
def account():
    with MT5_LOCK:
        if not _ensure_connected_locked():
            return {"logged_in": False, "error": str(mt5.last_error())}
        info = mt5.account_info()
        if info is None:
            return {"logged_in": False, "error": str(mt5.last_error())}
    return {
        "logged_in": True,
        "login": info.login,
        "server": info.server,
        "name": info.name,
        "balance": info.balance,
        "equity": info.equity,
        "currency": info.currency,
        "trade_allowed": info.trade_allowed,
    }


@app.get("/candles", response_model=List[CandleOut], dependencies=[Depends(require_api_key)])
def get_candles(
    symbol: str = Query(default="XAUUSD"),
    timeframe: int = Query(default=15, description="Minutes: 1, 5, 15, 60, 240, 1440"),
    count: int = Query(default=300, ge=10, le=2000),
):
    if timeframe not in TIMEFRAME_MAP:
        raise HTTPException(400, f"Unsupported timeframe: {timeframe}")
    ensure_connected()
    _select_symbol(symbol)

    with MT5_LOCK:
        rates = mt5.copy_rates_from_pos(symbol, TIMEFRAME_MAP[timeframe], 0, count)
        error = mt5.last_error()
    if rates is None or len(rates) == 0:
        raise HTTPException(502, f"MT5 returned no data: {error}")

    candles = [
        CandleOut(
            time=CLOCK.to_utc_seconds(int(r["time"])),
            open=float(r["open"]),
            high=float(r["high"]),
            low=float(r["low"]),
            close=float(r["close"]),
            tick_volume=float(r["tick_volume"]),
        )
        for r in rates
    ]

    newest_end = datetime.fromtimestamp(candles[-1].time, tz=timezone.utc) + timedelta(minutes=timeframe)
    now = datetime.now(timezone.utc)
    if now - min(newest_end, now) > timedelta(minutes=timeframe * STALE_FEED_TIMEFRAME_MULTIPLIER):
        log.info("Stale feed / market closed for %s %sm (newest candle %s UTC)",
                 symbol, timeframe, datetime.fromtimestamp(candles[-1].time, tz=timezone.utc).isoformat())
    return candles


@app.get("/tick", dependencies=[Depends(require_api_key)])
def get_tick(symbol: str = Query(default="XAUUSD")):
    ensure_connected()
    _select_symbol(symbol)
    with MT5_LOCK:
        tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        raise HTTPException(502, f"No tick for {symbol}: {mt5.last_error()}")
    return {
        "symbol": symbol,
        "time": CLOCK.to_utc_seconds(tick.time),
        "time_msc": CLOCK.to_utc_ms(tick.time_msc),
        "bid": float(tick.bid),
        "ask": float(tick.ask),
    }


@app.websocket("/stream/ticks")
async def stream_ticks(websocket: WebSocket, symbol: str = "XAUUSD", api_key: Optional[str] = None):
    """Live ticks (only when changed) plus a {"type":"hb"} heartbeat every
    5s, so the client can tell a quiet market from a dead connection."""
    if BRIDGE_API_KEY and api_key != BRIDGE_API_KEY:
        await websocket.close(code=1008)
        return

    ok = await asyncio.to_thread(_ws_prepare_symbol, symbol)
    if not ok:
        await websocket.close(code=1011)
        return

    await websocket.accept()
    client = f"{websocket.client.host if websocket.client else '?'}"
    log.info("Tick stream client connected: %s (%s)", client, symbol)
    queue = HUB.subscribe(symbol)
    try:
        latest = HUB.latest.get(symbol)
        if latest is not None:
            await websocket.send_json(latest)
        while True:
            try:
                payload = await asyncio.wait_for(queue.get(), timeout=HEARTBEAT_SECONDS)
                await websocket.send_json(payload)
            except asyncio.TimeoutError:
                await websocket.send_json({"type": "hb", "server_time": int(time.time())})
    except WebSocketDisconnect:
        pass
    except Exception as e:  # connection reset, send on closed socket, ...
        log.info("Tick stream client %s dropped: %s", client, e)
    finally:
        HUB.unsubscribe(symbol, queue)
        log.info("Tick stream client disconnected: %s", client)


def _ws_prepare_symbol(symbol: str) -> bool:
    with MT5_LOCK:
        if not _ensure_connected_locked():
            return False
        return bool(mt5.symbol_select(symbol, True))


@app.post("/ai-commentary", response_model=AiCommentaryOut, dependencies=[Depends(require_api_key)])
async def ai_commentary(setup: TradeSetupIn):
    """Generates the 2-bullet trade thesis server-side, so ANTHROPIC_API_KEY
    never has to be bundled inside the mobile app build."""
    if not ANTHROPIC_API_KEY:
        raise HTTPException(503, "ANTHROPIC_API_KEY is not set in bridge/.env")

    prompt = f"""You are a professional XAUUSD (Gold) technical analyst. A trading system just
detected the following setup:

- Setup type: {setup.setup_type}
- Direction: {setup.direction}
- Timeframe: {setup.timeframe}
- Entry: {setup.entry}
- Stop Loss: {setup.stop_loss}
- Take Profit: {setup.take_profit} (R:R = 1:{setup.risk_reward:.1f})
- Confirmation pattern: {setup.pattern}

Write exactly 2 short bullet points (each under 20 words) explaining the
trade thesis in plain, professional language. No preamble, no disclaimer,
just the two bullets."""

    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "Content-Type": "application/json",
                    "x-api-key": ANTHROPIC_API_KEY,
                    "anthropic-version": "2023-06-01",
                },
                json={
                    "model": ANTHROPIC_MODEL,
                    "max_tokens": 200,
                    "messages": [{"role": "user", "content": prompt}],
                },
            )
        response.raise_for_status()
        data = response.json()
        text = "\n".join(block.get("text", "") for block in data.get("content", [])).strip()
        if not text:
            raise HTTPException(502, "Anthropic returned an empty response")
        return AiCommentaryOut(text=text)
    except httpx.HTTPError as e:
        log.warning("Anthropic request failed: %s", e)
        raise HTTPException(502, f"Anthropic request failed: {e}")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("mt5_bridge_server:app", host="0.0.0.0", port=8000, reload=False)
