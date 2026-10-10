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
  GET  /positions            - open positions          (X-API-Key)
  POST /order/open           - open a market order      (X-API-Key)
  POST /order/close_partial  - partially close a position (X-API-Key)
  POST /order/modify_sl      - move a position's SL/TP  (X-API-Key)

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
import json
import logging
import math
import os
import sys
import threading
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

import httpx
import MetaTrader5 as mt5
from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from risk_guard import DailyLossGuard, GuardError
from signal_store import BLOCKED, EXECUTED, FAILED, SignalStore, SlotBusy
from security import AuthThrottle, RedactSecretsFilter, keys_match, validate_startup
from strategy_config import ConfigError, ConfigStore
from telegram_bot import TelegramApi, TelegramBot



def _app_dir() -> Path:
    """The folder holding .env and data/: beside the executable when frozen (PyInstaller), else
    beside this source file."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


load_dotenv(_app_dir() / ".env")  # bridge/.env — never committed

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [AureusBridge] %(message)s",
)
log = logging.getLogger("aureus_bridge")

# Whatever a client puts in a URL or header, no key or bot token may be written to a log.
for _name in ("", "aureus_bridge", "uvicorn", "uvicorn.access", "uvicorn.error", "httpx"):
    logging.getLogger(_name).addFilter(RedactSecretsFilter())
for _handler in logging.getLogger().handlers:
    _handler.addFilter(RedactSecretsFilter())

BRIDGE_API_KEY = os.environ.get("BRIDGE_API_KEY", "")
# Loopback by default: only programs on THIS machine can reach the bridge.
# Set BRIDGE_HOST=0.0.0.0 only to serve a phone on your LAN, and then prefer a
# VPN (Tailscale / WireGuard) over opening the port.
BRIDGE_HOST = os.environ.get("BRIDGE_HOST", "127.0.0.1").strip() or "127.0.0.1"
try:
    BRIDGE_PORT = int(os.environ.get("BRIDGE_PORT", "8000"))
except ValueError:
    BRIDGE_PORT = 8000
AUTH_THROTTLE = AuthThrottle()
WS_AUTH_TIMEOUT_SECONDS = 5.0
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-4-6")

DEFAULT_SYMBOL = os.environ.get("BRIDGE_SYMBOL", "XAUUSD")

# Runtime state (strategy config, audit log, backups) lives outside git.
DATA_DIR = Path(os.environ.get("BRIDGE_DATA_DIR") or _app_dir() / "data")
CONFIG = ConfigStore(DATA_DIR)
RISK = DailyLossGuard(DATA_DIR)
SIGNALS = SignalStore(DATA_DIR)
DOLLARS_PER_PIP = 0.10  # XAUUSD: $0.10 = 1 pip, same convention as the app
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

    Startup (2026-10-09): until a fresh tick arrives the offset used to be 0, so right after a restart - for under a
    second in market hours, but up to an hour in the gold daily break or a whole weekend - /candles, /reconcile and
    the daily-loss guard read broker-server times as if they were UTC (3 h off), and the app rewrote 12-14 history
    close times 3 h late before the next reconcile put them back. Now the last detected offset is remembered in
    [store_path] and used from the first second ("remembered"); a fresh tick still confirms or replaces it
    ("detected"). [detected] stays False until then, which /reconcile uses to refuse to report times at all.
    """

    def __init__(self, store_path: Optional[Path] = None) -> None:
        env_hours = os.environ.get("MT5_SERVER_UTC_OFFSET_HOURS", "").strip()
        self.fixed = env_hours != ""
        self.offset_seconds: int = int(float(env_hours) * 3600) if self.fixed else 0
        self.detected = self.fixed
        self.source = "fixed" if self.fixed else "unknown"
        self._store = store_path
        self._saved: Optional[int] = None
        if self.fixed:
            log.info("Using fixed MT5 server offset from .env: %+.1fh", self.offset_seconds / 3600)
            return
        remembered = self._load()
        if remembered is not None:
            self.offset_seconds = self._saved = remembered
            self.source = "remembered"
            log.info("Using the last detected MT5 server offset %+.1fh until a fresh tick confirms it", remembered / 3600)

    @staticmethod
    def _plausible(seconds: int) -> bool:
        return abs(seconds) <= 14 * 3600 and seconds % 1800 == 0

    def _load(self) -> Optional[int]:
        if self._store is None:
            return None
        try:
            seconds = int(json.loads(self._store.read_text(encoding="utf-8"))["offset_seconds"])
        except (OSError, ValueError, KeyError, TypeError):
            return None
        return seconds if self._plausible(seconds) else None

    def _save(self) -> None:
        if self._store is None or self._saved == self.offset_seconds:
            return
        try:
            tmp = self._store.with_suffix(".tmp")
            tmp.write_text(json.dumps({"offset_seconds": self.offset_seconds,
                                       "detected_at": datetime.now(timezone.utc).isoformat()}), encoding="utf-8")
            os.replace(tmp, self._store)
            self._saved = self.offset_seconds
        except OSError as e:
            log.warning("Could not remember the MT5 server offset: %s", type(e).__name__)

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
        self.source = "detected"
        self._save()

    def to_utc_seconds(self, server_seconds: int) -> int:
        return int(server_seconds) - self.offset_seconds

    def to_utc_ms(self, server_ms: int) -> int:
        return int(server_ms) - self.offset_seconds * 1000


CLOCK = ServerClock(DATA_DIR / "server_clock.json")


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


def _symbol_point(symbol: str) -> float:
    """The symbol's point size in dollars (0.01 on a 2-digit gold quote), or 0.0 when unknown.
    The caller must already hold MT5_LOCK."""
    try:
        point = float(getattr(mt5.symbol_info(symbol), "point", 0.0) or 0.0)
    except (TypeError, ValueError):
        return 0.0
    return point if math.isfinite(point) and point > 0 else 0.0


def _bar_spread_pips(rate: Any, point: float) -> Optional[float]:
    """A bar's broker-reported spread (MT5 gives it in points) converted to pips, or None when the bar
    carries no usable spread. Never raises: the spread is extra context, it must not break /candles."""
    if point <= 0:
        return None
    try:
        points = float(rate["spread"])
    except (KeyError, IndexError, TypeError, ValueError):
        return None
    if not math.isfinite(points) or points < 0:
        return None
    return round(points * point / DOLLARS_PER_PIP, 2)


# ENUM_SYMBOL_TRADE_EXECUTION filling-mode bitmask (symbol_info().filling_mode)
# — NOT exposed as named constants by the MetaTrader5 python package, unlike
# the ORDER_FILLING_* values actually sent in an order request. Confirmed
# 2026-09-21 against MEXAtlantic-Demo/XAUUSD (filling_mode == 1, i.e. ONLY
# FOK — every order this bridge sent with the previously hardcoded IOC was
# rejected with retcode 10030 "Unsupported filling mode").
_SYMBOL_FILLING_FOK = 1
_SYMBOL_FILLING_IOC = 2


def _pick_filling_mode(symbol: str) -> int:
    """Picks a filling mode the SYMBOL actually supports rather than
    assuming every broker/instrument allows IOC — brokers differ, and
    sending one the symbol doesn't support fails the whole order with
    retcode 10030 before it ever reaches the market."""
    with MT5_LOCK:
        info = mt5.symbol_info(symbol)
    mode = info.filling_mode if info is not None else 0
    if mode & _SYMBOL_FILLING_IOC:
        return mt5.ORDER_FILLING_IOC
    if mode & _SYMBOL_FILLING_FOK:
        return mt5.ORDER_FILLING_FOK
    return mt5.ORDER_FILLING_RETURN


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
    problems = validate_startup(BRIDGE_HOST, BRIDGE_API_KEY)
    if problems:
        raise RuntimeError("Refusing to start: " + " | ".join(problems))
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
    risk_task = asyncio.create_task(_risk_loop())
    bot = _build_telegram_bot()
    bot_task = asyncio.create_task(_run_telegram_bot(bot)) if bot is not None else None
    signal_task = asyncio.create_task(_signal_expiry_loop())
    yield
    for task in (risk_task, bot_task, signal_task):
        if task is None:
            continue
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
    HUB.unsubscribe(DEFAULT_SYMBOL, calibration_queue)
    with MT5_LOCK:
        mt5.shutdown()


# The interactive docs would publish the full API surface to anyone who can reach the port.
app = FastAPI(title="Aureus AI - MT5 Bridge", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

# Origin filtering doesn't protect a server called by a mobile app — real
# protection is BRIDGE_API_KEY.
# CORS only matters to browsers (a Flutter web build); the Windows/Android apps ignore it.
# Default: pages served from this machine only. Add more with BRIDGE_CORS_ORIGINS=https://a,https://b
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in os.environ.get("BRIDGE_CORS_ORIGINS", "").split(",") if o.strip()],
    allow_origin_regex=r"https?://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_methods=["GET", "POST"],
    allow_headers=["X-API-Key", "Content-Type"],
)


class CandleOut(BaseModel):
    time: int  # candle OPEN time, real UTC seconds
    open: float
    high: float
    low: float
    close: float
    tick_volume: float
    # The bar's broker-reported spread in PIPS ($0.10 on gold, the unit the app's live-spread checks use).
    # Optional: absent when MT5 gives no spread for the bar or the symbol's point size is unknown.
    spread_pips: Optional[float] = None


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


class PositionOut(BaseModel):
    ticket: int
    symbol: str
    type: str  # "buy" | "sell"
    volume: float
    price_open: float
    sl: float
    tp: float
    profit: float


class OrderOpenIn(BaseModel):
    symbol: str
    direction: str  # "buy" | "sell"
    volume: float
    stop_loss: float
    take_profit: float
    deviation: int = 20
    magic: int = 20260920  # Aureus AI auto-trading magic number
    # The signal's own entry price. When sent, the order is refused if the market has run further than
    # account_limits.max_entry_drift_dollars from it (the approval flow already does this check).
    entry: Optional[float] = None
    # True: the bridge sizes the lot itself from live equity and the stop distance, in the account's own
    # currency, and `volume` is only the caller's estimate.
    bridge_sizing: bool = False


class OrderOpenOut(BaseModel):
    success: bool
    ticket: Optional[int] = None
    price: Optional[float] = None
    error: Optional[str] = None
    volume: Optional[float] = None  # the lot actually sent


class ClosePartialIn(BaseModel):
    ticket: int
    volume: float
    deviation: int = 20


class ModifySlIn(BaseModel):
    ticket: int
    stop_loss: float
    take_profit: Optional[float] = None


class OrderActionOut(BaseModel):
    success: bool
    price: Optional[float] = None
    error: Optional[str] = None
    not_found: bool = False  # the position no longer exists (already closed)


class CloseIn(BaseModel):
    ticket: int
    deviation: int = 50  # closing favours getting out over a tight fill


class CloseAllIn(BaseModel):
    # None = every open position on the account (true emergency); the app
    # always sends its own gold symbol so unrelated manual trades are left alone.
    symbol: Optional[str] = None
    deviation: int = 50


class CloseResultOut(BaseModel):
    ticket: int
    success: bool
    price: Optional[float] = None
    error: Optional[str] = None


class CloseAllOut(BaseModel):
    success: bool
    closed: List[CloseResultOut] = []
    error: Optional[str] = None


class ConfigUpdateIn(BaseModel):
    base_revision: int
    patch: Dict[str, Any]
    updated_by: str = "app"
    confirm_risk_increase: bool = False


class ConfigRestoreIn(BaseModel):
    revision: int
    base_revision: int
    updated_by: str = "app"
    confirm_risk_increase: bool = False


def _client_id(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def require_api_key(request: Request, x_api_key: Optional[str] = Header(default=None)) -> None:
    """Every endpoint except /health needs the shared secret. The key is
    compared in constant time, and a client that keeps sending wrong keys is
    locked out for a while so it cannot be guessed by brute force."""
    if not BRIDGE_API_KEY:
        raise HTTPException(status_code=503, detail="Bridge is misconfigured: BRIDGE_API_KEY is not set")
    client = _client_id(request)
    if AUTH_THROTTLE.is_blocked(client):
        raise HTTPException(status_code=429, detail="Too many failed authentication attempts - try again later")
    if not keys_match(x_api_key, BRIDGE_API_KEY):
        if AUTH_THROTTLE.record_failure(client):
            log.warning("Auth: %s locked out after repeated failed attempts", client)
        raise HTTPException(status_code=401, detail="Missing or invalid X-API-Key")
    AUTH_THROTTLE.record_success(client)


@app.get("/health")
def health():
    with MT5_LOCK:
        connected = mt5.terminal_info() is not None
    return {
        "connected": connected,
        "server_utc_offset_hours": CLOCK.offset_seconds / 3600,
        "offset_detected": CLOCK.detected,
        # fixed (.env) | detected (a fresh tick) | remembered (last run, not confirmed yet) | unknown
        "offset_source": CLOCK.source,
        "auth_required": True,
    }


# ---------------------------------------------------------------------------
# Strategy configuration (single source of truth - see strategy_config.py)
# ---------------------------------------------------------------------------
def _account_fingerprint() -> str:
    try:
        with MT5_LOCK:
            info = mt5.account_info()
        return f"{info.login}@{info.server}" if info is not None else ""
    except Exception:
        return ""


def _config_http_error(e: ConfigError) -> HTTPException:
    return HTTPException(status_code=e.status, detail=e.payload())


def _remote(request: Request) -> Optional[str]:
    return request.client.host if request.client else None


@app.get("/config", dependencies=[Depends(require_api_key)])
def get_config(request: Request, response: Response):
    CONFIG.check_fingerprint(_account_fingerprint())
    etag = f'"{CONFIG.revision}"'
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers={"ETag": etag})
    response.headers["ETag"] = etag
    return CONFIG.public()


@app.post("/config/update", dependencies=[Depends(require_api_key)])
def update_config(body: ConfigUpdateIn, request: Request):
    try:
        result = CONFIG.update(
            body.patch,
            body.base_revision,
            updated_by=body.updated_by,
            confirm_risk_increase=body.confirm_risk_increase,
            remote=_remote(request),
        )
    except ConfigError as e:
        raise _config_http_error(e)
    log.info("Config updated to revision %s by %s (%d change(s))", result["revision"], body.updated_by, len(result["changed"]))
    return {**result, **CONFIG.public()}


@app.post("/config/restore", dependencies=[Depends(require_api_key)])
def restore_config(body: ConfigRestoreIn, request: Request):
    try:
        result = CONFIG.restore(
            body.revision,
            body.base_revision,
            updated_by=body.updated_by,
            confirm_risk_increase=body.confirm_risk_increase,
            remote=_remote(request),
        )
    except ConfigError as e:
        raise _config_http_error(e)
    log.info("Config restored from revision %s -> new revision %s", body.revision, result["revision"])
    return {**result, **CONFIG.public()}


@app.get("/config/audit", dependencies=[Depends(require_api_key)])
def config_audit(limit: int = Query(default=50, ge=1, le=500)):
    return {"entries": CONFIG.audit_tail(limit)}


@app.post("/config/ack_account", dependencies=[Depends(require_api_key)])
def config_ack_account(request: Request):
    fingerprint = _account_fingerprint()
    if not fingerprint:
        raise HTTPException(503, "MT5 account not available - connect the terminal first")
    CONFIG.acknowledge_account(fingerprint, remote=_remote(request))
    return CONFIG.public()


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


@app.get("/positions", response_model=List[PositionOut], dependencies=[Depends(require_api_key)])
def get_positions(symbol: str = Query(default="XAUUSD")):
    """Single Active Position Guard (Aureus AI, 2026-09-20): every currently
    OPEN position for [symbol] — regardless of magic number, so a position
    opened manually in the terminal blocks a new auto-signal exactly the
    same as one this app opened itself."""
    ensure_connected()
    with MT5_LOCK:
        positions = mt5.positions_get(symbol=symbol) or ()
    return [
        PositionOut(
            ticket=p.ticket,
            symbol=p.symbol,
            type="buy" if p.type == mt5.POSITION_TYPE_BUY else "sell",
            volume=float(p.volume),
            price_open=float(p.price_open),
            sl=float(p.sl),
            tp=float(p.tp),
            profit=float(p.profit),
        )
        for p in positions
    ]


# An order may risk at most this multiple of the configured per-trade risk
# (headroom for lot rounding and a few pips of slippage between signal and fill).
RISK_CAP_TOLERANCE = 1.5
# Pips of extra stop distance tolerated beyond max_sl_pips: the signal's entry is
# a candle close, the fill is the live price some seconds later.
SL_DRIFT_ALLOWANCE_PIPS = 20.0


def _order_sanity(order, tick, cfg, risk):
    """Independent checks on the order itself - whatever the app computed, the
    bridge refuses an order that has no stop, has its stop on the wrong side,
    a stop wider than the rules allow, or a size that risks far more than
    the configured percentage of the account."""
    if tick is None:
        return None  # order_open reports the missing quote itself
    if order.stop_loss <= 0 or order.take_profit <= 0:
        return "Orders must carry both a stop loss and a take profit"
    buy = order.direction.lower() == "buy"
    price = float(tick.ask if buy else tick.bid)
    sl, tp = float(order.stop_loss), float(order.take_profit)
    if buy and not (sl < price < tp):
        return f"BUY needs stop loss < price < take profit (got SL {sl}, price {price}, TP {tp})"
    if not buy and not (tp < price < sl):
        return f"SELL needs take profit < price < stop loss (got TP {tp}, price {price}, SL {sl})"

    sl_pips = abs(price - sl) / DOLLARS_PER_PIP
    max_sl = cfg["trade_rules"]["max_sl_pips"]
    if sl_pips > max_sl + SL_DRIFT_ALLOWANCE_PIPS:
        return f"Stop loss is {sl_pips:.0f} pips away, beyond the allowed {max_sl:.0f} pips"

    equity = risk.get("equity")
    limits = cfg["account_limits"]
    with MT5_LOCK:
        info = mt5.symbol_info(order.symbol)
    tick_value = getattr(info, "trade_tick_value", None)
    tick_size = getattr(info, "trade_tick_size", None)
    numbers = (equity, tick_value, tick_size)
    if not all(isinstance(n, (int, float)) and not isinstance(n, bool) and n > 0 for n in numbers):
        # Without the broker's tick value the risk of this order cannot be measured, so it is not sent.
        # (Right after connecting, MT5 reports a tick value of 0 for a moment.)
        return "The broker's tick value is not available right now, so the order's risk cannot be checked - try again"
    risk_amount = abs(price - sl) / tick_size * tick_value * order.volume

    # Dynamic mode: the order may not risk much more than the configured percentage. In fixed mode the lot was
    # chosen explicitly, so this cap does not apply - the daily loss limit below still does.
    if limits.get("lot_mode", "dynamic") != "fixed":
        allowed = equity * limits["risk_percent_per_trade"] / 100.0 * RISK_CAP_TOLERANCE
        strict = bool(limits.get("strict_min_lot_risk", False))
        if risk_amount > allowed and (strict or order.volume > limits["min_lot"] + 1e-9):
            return (
                f"Order risks {risk_amount:.2f} if the stop is hit, more than {RISK_CAP_TOLERANCE}x the configured "
                f"{limits['risk_percent_per_trade']}% of equity ({allowed:.2f})"
                + (
                    " - even the smallest lot is too large for this stop (strict_min_lot_risk)"
                    if strict and order.volume <= limits["min_lot"] + 1e-9
                    else ""
                )
            )

    # The daily loss limit has priority over everything, in every lot mode: a trade whose stop could take the
    # day past the limit is not opened, even though the limit has not been reached yet.
    baseline, loss_so_far = risk.get("baseline"), risk.get("loss_amount")
    limit_percent = limits["max_daily_loss_percent"]
    if (
        limit_percent > 0
        and all(isinstance(n, (int, float)) and not isinstance(n, bool) for n in (baseline, loss_so_far))
        and baseline > 0
    ):
        budget = baseline * limit_percent / 100.0
        remaining = budget - max(float(loss_so_far), 0.0)
        if risk_amount > remaining + 1e-9:
            return (
                f"Daily loss limit: this trade could lose {risk_amount:.2f} at its stop, more than the "
                f"{max(remaining, 0.0):.2f} left before the {limit_percent}% daily limit ({budget:.2f})"
            )
    return None


# After the price has run in a trade's direction, the reward left must still be at least this multiple of the
# risk the trade would now carry (the stop stays where the signal put it, so a worse entry means more risk).
MIN_REWARD_AFTER_CHASE = 1.0


def _drift_window(direction: str, entry: float, stop_loss, take_profit, limits) -> tuple:
    """(lowest, highest) price at which a signal may still be taken at market.

    * Against the trade (a BUY that already fell, a SELL that already rose) the flat
      `max_entry_drift_dollars` applies: the setup is deteriorating.
    * In the trade's direction (we would pay more) the window is the LARGER of that flat limit and
      `entry_drift_chase_r` x the signal's own stop distance, never so far that the reward left is smaller
      than the risk now carried. So an approval pressed a little late still works on a wide setup instead of a
      flat dollar amount closing the door within seconds."""
    buy = direction.lower() == "buy"
    flat = float(limits["max_entry_drift_dollars"])
    chase = float(limits.get("entry_drift_chase_r", 0.0) or 0.0)
    risk = abs(entry - float(stop_loss)) if stop_loss else 0.0
    reward = abs(float(take_profit) - entry) if take_profit else 0.0
    extra = 0.0
    if chase > 0 and risk > 0 and reward > risk:
        by_reward = (reward - MIN_REWARD_AFTER_CHASE * risk) / (1.0 + MIN_REWARD_AFTER_CHASE)
        extra = max(0.0, min(chase * risk, by_reward))
    forward = max(flat, extra)
    return (entry - flat, entry + forward) if buy else (entry - forward, entry + flat)


def _entry_drift_problem(direction: str, entry: float, stop_loss, take_profit, price: float, limits):
    """Why [price] is too far from the signal's [entry] to take it now, or None when it is acceptable."""
    low, high = _drift_window(direction, entry, stop_loss, take_profit, limits)
    if low - 1e-9 <= price <= high + 1e-9:
        return None
    limit = (high if price > entry else low) - entry
    return f"Price moved ${abs(price - entry):.2f} away from the signal (limit ${abs(limit):.2f})"


def _config_gate(order: "OrderOpenIn", allowed_modes=("auto",)):
    """The bridge is the last line of defence: whatever the app sent, these
    limits (from strategy_config.py) are re-read at the moment of execution.
    Returns (error | None, effective slippage deviation)."""
    cfg = CONFIG.snapshot()
    mode = cfg["mode"]
    limits = cfg["account_limits"]
    deviation = min(order.deviation, limits["max_slippage_points"])

    if mode["paused"]:
        return "Trading is paused on the bridge (mode.paused)", deviation
    risk = _risk_status()
    if not risk["available"]:
        return "Account equity is unreadable - order refused (the daily loss guard cannot verify the account)", deviation
    if risk["locked"]:
        return (
            f"Daily loss limit reached ({risk['locked_loss_percent']}% lost, limit {risk['limit_percent']}%) - "
            "trading is locked until 00:00 UTC",
            deviation,
        )
    if mode["auto_trade"] not in allowed_modes:
        return (
            f"Orders are disabled: bridge config mode.auto_trade is '{mode['auto_trade']}' "
            f"(needs '{' or '.join(allowed_modes)}')",
            deviation,
        )
    if order.volume > limits["max_lot"]:
        return f"Volume {order.volume} exceeds the bridge max_lot {limits['max_lot']}", deviation
    if order.volume < limits["min_lot"]:
        return f"Volume {order.volume} is below the bridge min_lot {limits['min_lot']}", deviation

    with MT5_LOCK:
        tick = mt5.symbol_info_tick(order.symbol)
        positions = mt5.positions_get(symbol=order.symbol)
    if positions is None:
        return "Could not verify open positions on the bridge - order refused", deviation
    if len(positions) >= limits["max_open_positions"]:
        return f"{len(positions)} position(s) already open (max_open_positions {limits['max_open_positions']})", deviation
    if tick is not None:
        spread_pips = (float(tick.ask) - float(tick.bid)) / DOLLARS_PER_PIP
        if spread_pips > limits["max_spread_pips"]:
            return (
                f"Spread {spread_pips:.1f} pips exceeds the bridge max_spread_pips {limits['max_spread_pips']}",
                deviation,
            )
    if tick is not None and order.entry:
        drift_problem = _entry_drift_problem(
            order.direction,
            float(order.entry),
            order.stop_loss,
            order.take_profit,
            float(tick.ask if order.direction.lower() == "buy" else tick.bid),
            limits,
        )
        if drift_problem:
            return drift_problem, deviation
    problem = _order_sanity(order, tick, cfg, risk)
    if problem:
        return problem, deviation
    return None, deviation


@app.post("/order/open", response_model=OrderOpenOut, dependencies=[Depends(require_api_key)])
def order_open(order: OrderOpenIn):
    """Opens a REAL market order (Aureus AI Dynamic Position Sizing +
    Auto-Trading, 2026-09-20) - only ever called by the app when
    ENABLE_AUTO_TRADING=true and every local safety gate (Single Active
    Position Guard, Live Spread Protection, Confluence Score, ...) already
    passed. Volume/SL/TP are computed client-side; the bridge re-checks the
    account-level limits from its own strategy config (_config_gate) and then
    executes and reports what the broker actually did."""
    ensure_connected()
    _select_symbol(order.symbol)

    cfg_now = CONFIG.snapshot()
    if order.bridge_sizing or cfg_now["account_limits"].get("lot_mode", "dynamic") == "fixed":
        with MT5_LOCK:
            quote = mt5.symbol_info_tick(order.symbol)
        if quote is None:
            return OrderOpenOut(success=False, error=f"No tick for {order.symbol}: {mt5.last_error()}")
        sized, why_not = _resolve_volume(order, float(quote.ask if order.direction.lower() == "buy" else quote.bid), cfg_now)
        if sized is None:
            return OrderOpenOut(success=False, error=why_not)
        if abs(sized - order.volume) > 1e-9:
            log.info("Lot set by the bridge (%s): %s -> %s", cfg_now["account_limits"]["lot_mode"], order.volume, sized)
        order.volume = sized

    gate_error, deviation = _config_gate(order)
    if gate_error:
        log.warning("Order refused by bridge config: %s", gate_error)
        return OrderOpenOut(success=False, error=gate_error)
    return _execute_market_order(order, deviation, "Aureus AI auto-trade")


def _execute_market_order(order: "OrderOpenIn", deviation: int, comment: str) -> "OrderOpenOut":
    """Sends the market order. Shared by direct orders and approved signals."""
    order_type = mt5.ORDER_TYPE_BUY if order.direction.lower() == "buy" else mt5.ORDER_TYPE_SELL
    filling = _pick_filling_mode(order.symbol)
    try:
        with MT5_LOCK:
            tick = mt5.symbol_info_tick(order.symbol)
            if tick is None:
                return OrderOpenOut(success=False, error=f"No tick for {order.symbol}: {mt5.last_error()}")
            price = tick.ask if order_type == mt5.ORDER_TYPE_BUY else tick.bid
            request = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": order.symbol,
                "volume": order.volume,
                "type": order_type,
                "price": price,
                "sl": order.stop_loss,
                "tp": order.take_profit,
                "deviation": deviation,
                "magic": order.magic,
                "comment": comment,
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": filling,
            }
            result = mt5.order_send(request)
    except Exception as e:  # the order may or may not have reached the broker
        log.warning("order_send raised %s", type(e).__name__)
        return OrderOpenOut(success=False, error=f"order_send failed: {type(e).__name__}")

    if result is None:
        return OrderOpenOut(success=False, error=f"order_send returned None: {mt5.last_error()}")
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        log.warning("order_send rejected: retcode=%s comment=%s", result.retcode, result.comment)
        return OrderOpenOut(success=False, error=f"retcode {result.retcode}: {result.comment}")

    log.info("Order opened: ticket=%s %s %s lots @ %s", result.order, order.direction, order.volume, result.price)
    return OrderOpenOut(success=True, ticket=result.order, price=float(result.price), volume=order.volume)


_CLOSE_RETRY_CODES = {
    mt5.TRADE_RETCODE_REQUOTE,
    mt5.TRADE_RETCODE_PRICE_CHANGED,
    mt5.TRADE_RETCODE_PRICE_OFF,
}


def _close_position_deal(pos, deviation: int, comment: str) -> dict:
    """Closes the WHOLE of [pos] at market with an opposite deal. Retries up
    to 3 times with a fresh quote on requote / price-changed / price-off
    (common in fast gold moves); any other rejection is final. Never raises.
    (/order/close_partial predates this helper and is left untouched — the
    app no longer uses it.)"""
    close_type = mt5.ORDER_TYPE_SELL if pos.type == mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY
    filling = _pick_filling_mode(pos.symbol)
    last_error = "order_send was never attempted"
    for attempt in range(3):
        with MT5_LOCK:
            tick = mt5.symbol_info_tick(pos.symbol)
            if tick is None:
                return {"success": False, "error": f"No tick for {pos.symbol}: {mt5.last_error()}"}
            price = tick.bid if close_type == mt5.ORDER_TYPE_SELL else tick.ask
            result = mt5.order_send(
                {
                    "action": mt5.TRADE_ACTION_DEAL,
                    "symbol": pos.symbol,
                    "volume": pos.volume,
                    "type": close_type,
                    "position": pos.ticket,
                    "price": price,
                    "deviation": deviation,
                    "magic": pos.magic,
                    "comment": comment,
                    "type_time": mt5.ORDER_TIME_GTC,
                    "type_filling": filling,
                }
            )
        if result is None:
            last_error = f"order_send returned None: {mt5.last_error()}"
        elif result.retcode == mt5.TRADE_RETCODE_DONE:
            return {"success": True, "price": float(result.price)}
        else:
            last_error = f"retcode {result.retcode}: {result.comment}"
            if result.retcode not in _CLOSE_RETRY_CODES:
                break
        if attempt < 2:
            time.sleep(0.15)
    log.warning("Close of #%s failed: %s", pos.ticket, last_error)
    return {"success": False, "error": last_error}


@app.post("/order/close", response_model=OrderActionOut, dependencies=[Depends(require_api_key)])
def order_close(req: CloseIn, request: Request):
    """Closes one position completely, at market. Always allowed — a pause or
    a daily-loss lock must never stop you getting OUT of a trade."""
    ensure_connected()
    with MT5_LOCK:
        positions = mt5.positions_get(ticket=req.ticket)
    if positions is None:
        return OrderActionOut(success=False, error=f"Could not read position #{req.ticket}: {mt5.last_error()}")
    if len(positions) == 0:
        return OrderActionOut(
            success=False, not_found=True, error=f"Position #{req.ticket} not found (already closed?)"
        )
    outcome = _close_position_deal(positions[0], req.deviation, "Aureus AI close")
    CONFIG.record({"action": "close", "ticket": req.ticket, "ip": _remote(request), **outcome})
    if outcome["success"]:
        log.info("Position #%s closed @ %s", req.ticket, outcome.get("price"))
    return OrderActionOut(**outcome)


@app.post("/order/close_all", response_model=CloseAllOut, dependencies=[Depends(require_api_key)])
def order_close_all(req: CloseAllIn, request: Request):
    """Emergency exit: closes every open position (optionally only [symbol])."""
    ensure_connected()
    results, error = _close_all_positions(req.symbol, req.deviation, "Aureus AI close-all")
    if results is None:
        return CloseAllOut(success=False, error=error)
    ok = all(r.success for r in results)
    CONFIG.record(
        {
            "action": "close_all",
            "symbol": req.symbol,
            "ip": _remote(request),
            "requested": len(results),
            "closed": sum(1 for r in results if r.success),
            "failed": [r.ticket for r in results if not r.success],
        }
    )
    log.warning("CLOSE ALL: %d/%d position(s) closed", sum(1 for r in results if r.success), len(results))
    return CloseAllOut(success=ok, closed=results)


RISK_POLL_SECONDS = 5.0


def _realized_today():
    """Today's (UTC) realised result across all positions: profit + swap +
    commission + fee of every trade deal. Balance operations (deposits,
    withdrawals, credit) have no position and are excluded. None when the
    deal history cannot be read."""
    now = datetime.now(timezone.utc)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    with MT5_LOCK:
        deals = mt5.history_deals_get(start - timedelta(hours=24), now + timedelta(hours=24))
    if deals is None:
        return None
    start_ts = int(start.timestamp())
    total = 0.0
    for d in deals:
        if not d.position_id:
            continue
        if CLOCK.to_utc_seconds(int(d.time)) < start_ts:
            continue
        total += d.profit + d.swap + d.commission + getattr(d, "fee", 0.0)
    return total


def _risk_status() -> dict:
    """Evaluates the daily-loss guard against the LIVE account. `available`
    is False when the account's equity cannot be read - order gates then fail
    closed, because an unverifiable account cannot be trusted with new risk."""
    cfg = CONFIG.snapshot()
    limits = cfg["account_limits"]
    now = datetime.now(timezone.utc)
    with MT5_LOCK:
        info = mt5.account_info()
    if info is None:
        return {
            "available": False,
            "locked": RISK.is_locked(now),
            "can_trade": False,
            "limit_percent": limits["max_daily_loss_percent"],
            "on_breach": limits["on_daily_loss"],
        }
    status = RISK.evaluate(
        equity=float(info.equity),
        balance=float(info.balance),
        realized_today=_realized_today,
        limit_percent=limits["max_daily_loss_percent"],
        now=now,
    )
    status["available"] = True
    status["on_breach"] = limits["on_daily_loss"]
    return status


def _close_all_positions(symbol, deviation: int, comment: str):
    """Closes every open position (optionally only [symbol]). Returns
    (results, None) or (None, error) when positions could not be read."""
    with MT5_LOCK:
        positions = mt5.positions_get(symbol=symbol) if symbol else mt5.positions_get()
    if positions is None:
        return None, f"Could not read open positions: {mt5.last_error()}"
    results = []
    for pos in positions:
        outcome = _close_position_deal(pos, deviation, comment)
        results.append(CloseResultOut(ticket=pos.ticket, **outcome))
    return results, None


def _risk_tick() -> None:
    """One pass of the background monitor: trips the lock on a floating-loss
    breach (no order needs to be attempted for it to notice) and, when the
    config says close_all, flattens the account - retrying every pass until
    every position is really closed."""
    status = _risk_status()
    if not status.get("available"):
        return
    if status.get("newly_locked"):
        log.error(
            "DAILY LOSS LIMIT HIT: -%.2f%% (limit %.2f%%) - trading locked until 00:00 UTC",
            status["loss_percent"],
            status["limit_percent"],
        )
        CONFIG.record(
            {
                "action": "daily_loss_lock",
                "loss_percent": status["loss_percent"],
                "limit_percent": status["limit_percent"],
                "equity": status["equity"],
                "baseline": status["baseline"],
                "on_breach": status["on_breach"],
            }
        )
        _notify_event(
            f"DAILY LOSS LIMIT HIT: -{status['loss_percent']:.2f}% (limit {status['limit_percent']:.2f}%). "
            f"Trading is locked until 00:00 UTC. On breach: {status['on_breach']}."
        )
    if status["locked"] and status["on_breach"] == "close_all" and RISK.actions_pending():
        results, error = _close_all_positions(None, 50, "Aureus AI daily-loss stop")
        if results is None:
            log.error("Daily-loss close-all could not read positions: %s - retrying", error)
            return
        failed = [r.ticket for r in results if not r.success]
        if failed:
            log.error("Daily-loss close-all: %d position(s) still open (%s) - retrying", len(failed), failed)
            return
        RISK.mark_actions_done()
        log.warning("Daily-loss close-all: %d position(s) closed", len(results))
        CONFIG.record({"action": "daily_loss_close_all", "closed": len(results)})
        _notify_event(f"Daily-loss stop: {len(results)} position(s) closed.")


async def _risk_loop() -> None:
    while True:
        try:
            await asyncio.to_thread(_risk_tick)
        except Exception as e:  # the monitor must never die on one bad read
            log.warning("Risk monitor pass failed: %s", e)
        await asyncio.sleep(RISK_POLL_SECONDS)


class RiskOverrideIn(BaseModel):
    confirm: bool = False
    updated_by: str = "app"


@app.get("/risk/status", dependencies=[Depends(require_api_key)])
def risk_status():
    return _risk_status()


@app.post("/risk/override", dependencies=[Depends(require_api_key)])
def risk_override(body: RiskOverrideIn, request: Request):
    """Releases a daily-loss lock by rebasing the day's loss budget to the
    CURRENT equity. A deliberate act: needs confirm=true, works once per UTC
    day, and is audited."""
    if not body.confirm:
        raise HTTPException(
            428,
            detail={
                "code": "confirmation_required",
                "message": "Overriding the daily loss lock grants a fresh loss budget from the current equity. "
                "Resend with confirm=true.",
            },
        )
    with MT5_LOCK:
        info = mt5.account_info()
    if info is None:
        raise HTTPException(503, "MT5 account not available - cannot rebase the loss budget")
    try:
        RISK.override(equity=float(info.equity), now=datetime.now(timezone.utc))
    except GuardError as e:
        raise HTTPException(429, detail={"code": "override_not_allowed", "message": str(e)})
    CONFIG.record(
        {"action": "daily_loss_override", "by": body.updated_by, "ip": _remote(request), "equity": float(info.equity)}
    )
    log.warning("Daily-loss lock OVERRIDDEN by %s - new baseline %.2f", body.updated_by, float(info.equity))
    _notify_event(f"Daily-loss lock OVERRIDDEN by {body.updated_by}: a fresh loss budget starts from equity {float(info.equity):.2f}.")
    return _risk_status()


def _reason_name(reason) -> str:
    if reason == mt5.DEAL_REASON_SL:
        return "sl"
    if reason == mt5.DEAL_REASON_TP:
        return "tp"
    if reason == mt5.DEAL_REASON_SO:
        return "stop_out"
    if reason in (mt5.DEAL_REASON_CLIENT, mt5.DEAL_REASON_MOBILE, mt5.DEAL_REASON_WEB):
        return "manual"
    if reason == mt5.DEAL_REASON_EXPERT:
        return "expert"
    return "other"


def _closed_positions_from_deals(deals) -> list:
    """Folds MT5 deal history into one record per FULLY closed position: the
    volume-weighted open/close prices, the net result (profit + swap +
    commission + fee), the real close time (UTC) and why it closed (sl / tp /
    manual / ...). A position that is only partly closed is still open at the
    broker, so it is not reported. Positions whose opening deal falls outside
    the queried window are skipped (we could not state their open price)."""
    groups: dict = {}
    for d in deals:
        if not d.position_id:
            continue
        if d.entry not in (mt5.DEAL_ENTRY_IN, mt5.DEAL_ENTRY_OUT, mt5.DEAL_ENTRY_OUT_BY):
            continue
        groups.setdefault(d.position_id, []).append(d)

    closed = []
    for position_id, group in groups.items():
        opens = [d for d in group if d.entry == mt5.DEAL_ENTRY_IN]
        exits = [d for d in group if d.entry in (mt5.DEAL_ENTRY_OUT, mt5.DEAL_ENTRY_OUT_BY)]
        if not opens or not exits:
            continue
        volume_in = sum(d.volume for d in opens)
        volume_out = sum(d.volume for d in exits)
        if volume_out + 1e-9 < volume_in:
            continue
        last_exit = max(exits, key=lambda d: (d.time, getattr(d, "time_msc", 0)))
        first_open = min(opens, key=lambda d: (d.time, getattr(d, "time_msc", 0)))
        net = sum(d.profit + d.swap + d.commission + getattr(d, "fee", 0.0) for d in group)
        closed.append(
            {
                "ticket": int(position_id),
                "symbol": last_exit.symbol,
                "type": "buy" if first_open.type == mt5.DEAL_TYPE_BUY else "sell",
                "volume": float(volume_in),
                "price_open": float(sum(d.price * d.volume for d in opens) / volume_in),
                "price_close": float(sum(d.price * d.volume for d in exits) / volume_out),
                "time_open": CLOCK.to_utc_seconds(int(first_open.time)),
                "time_close": CLOCK.to_utc_seconds(int(last_exit.time)),
                "profit": round(float(net), 2),
                "reason": _reason_name(last_exit.reason),
                "magic": int(last_exit.magic),
            }
        )
    return closed


@app.get("/reconcile", dependencies=[Depends(require_api_key)])
def reconcile(symbol: Optional[str] = Query(default=None), since_hours: int = Query(default=96, ge=1, le=720)):
    """The broker's own view, for the app to reconcile its trade log against:
    every open position, plus every position fully closed in the last
    [since_hours] with its REAL close price, time, net profit and reason.

    Refused (503) until a fresh tick has confirmed the server-time offset (2026-10-09): the app overwrites its trade
    history with these times, so an unconfirmed offset (even a remembered one) must never reach it. Right after a
    restart in market hours that is under a second; in the daily break or a weekend nothing can close anyway."""
    if not CLOCK.detected:
        raise HTTPException(503, "MT5 server time offset not confirmed yet - waiting for a fresh tick")
    ensure_connected()
    with MT5_LOCK:
        positions = mt5.positions_get(symbol=symbol) if symbol else mt5.positions_get()
    if positions is None:
        raise HTTPException(503, f"Could not read open positions: {mt5.last_error()}")

    now = datetime.now(timezone.utc)
    # Padded a day each side: deal times are broker-server time, whose offset
    # from UTC can be several hours either way.
    with MT5_LOCK:
        deals = mt5.history_deals_get(now - timedelta(hours=since_hours + 24), now + timedelta(hours=24))
    history_ok = deals is not None
    closed = []
    if history_ok:
        cutoff = int(time.time()) - since_hours * 3600
        closed = [
            c
            for c in _closed_positions_from_deals(deals)
            if c["time_close"] >= cutoff and (symbol is None or c["symbol"] == symbol)
        ]

    return {
        "positions": [
            {
                "ticket": int(p.ticket),
                "symbol": p.symbol,
                "type": "buy" if p.type == mt5.POSITION_TYPE_BUY else "sell",
                "volume": float(p.volume),
                "price_open": float(p.price_open),
                "sl": float(p.sl),
                "tp": float(p.tp),
                "profit": float(p.profit),
                "magic": int(p.magic),
                "time_open": CLOCK.to_utc_seconds(int(p.time)),
            }
            for p in positions
        ],
        "closed": closed,
        "history_ok": history_ok,
        "since_hours": since_hours,
    }


@app.post("/order/close_partial", response_model=OrderActionOut, dependencies=[Depends(require_api_key)])
def order_close_partial(req: ClosePartialIn):
    """Automatic Partial Take-Profit (Aureus AI, 2026-09-20): closes [volume]
    lots of an existing position by sending an opposite-direction deal
    against it (position ticket set) — MT5's own mechanism for a partial
    close; the remaining volume stays open under the same ticket."""
    ensure_connected()
    with MT5_LOCK:
        positions = mt5.positions_get(ticket=req.ticket) or ()
    if not positions:
        return OrderActionOut(success=False, error=f"Position #{req.ticket} not found (already closed?)")
    pos = positions[0]
    volume = min(req.volume, pos.volume)
    if volume <= 0:
        return OrderActionOut(success=False, error="Requested close volume is <= 0")

    close_type = mt5.ORDER_TYPE_SELL if pos.type == mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY
    filling = _pick_filling_mode(pos.symbol)
    with MT5_LOCK:
        tick = mt5.symbol_info_tick(pos.symbol)
        if tick is None:
            return OrderActionOut(success=False, error=f"No tick for {pos.symbol}: {mt5.last_error()}")
        price = tick.bid if close_type == mt5.ORDER_TYPE_SELL else tick.ask
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": pos.symbol,
            "volume": volume,
            "type": close_type,
            "position": pos.ticket,
            "price": price,
            "deviation": req.deviation,
            "magic": pos.magic,
            "comment": "Aureus AI partial TP",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": filling,
        }
        result = mt5.order_send(request)

    if result is None:
        return OrderActionOut(success=False, error=f"order_send returned None: {mt5.last_error()}")
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        log.warning("Partial close rejected: retcode=%s comment=%s", result.retcode, result.comment)
        return OrderActionOut(success=False, error=f"retcode {result.retcode}: {result.comment}")

    log.info("Position #%s partially closed: %s lots @ %s", req.ticket, volume, result.price)
    return OrderActionOut(success=True, price=float(result.price))


@app.post("/order/modify_sl", response_model=OrderActionOut, dependencies=[Depends(require_api_key)])
def order_modify_sl(req: ModifySlIn):
    """Automatic Break-Even (Aureus AI, 2026-09-20): moves an existing
    position's Stop Loss (and optionally Take Profit) via TRADE_ACTION_SLTP
    — no price/volume change, just the protective levels."""
    ensure_connected()
    with MT5_LOCK:
        positions = mt5.positions_get(ticket=req.ticket) or ()
    if not positions:
        return OrderActionOut(success=False, error=f"Position #{req.ticket} not found (already closed?)")
    pos = positions[0]

    with MT5_LOCK:
        request = {
            "action": mt5.TRADE_ACTION_SLTP,
            "symbol": pos.symbol,
            "position": pos.ticket,
            "sl": req.stop_loss,
            "tp": req.take_profit if req.take_profit is not None else pos.tp,
        }
        result = mt5.order_send(request)

    if result is None:
        return OrderActionOut(success=False, error=f"order_send returned None: {mt5.last_error()}")
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        log.warning("SL modify rejected: retcode=%s comment=%s", result.retcode, result.comment)
        return OrderActionOut(success=False, error=f"retcode {result.retcode}: {result.comment}")

    log.info("Position #%s SL moved to %s", req.ticket, req.stop_loss)
    return OrderActionOut(success=True)


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
        point = _symbol_point(symbol)
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
            spread_pips=_bar_spread_pips(r, point),
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
async def stream_ticks(websocket: WebSocket, symbol: str = "XAUUSD"):
    """Live ticks (only when changed) plus a {"type":"hb"} heartbeat every
    5s, so the client can tell a quiet market from a dead connection.

    The first message must be {"type": "auth", "api_key": ...}: a key in the
    URL would be written to access logs and proxy histories."""
    await websocket.accept()
    client = f"{websocket.client.host if websocket.client else '?'}"
    if AUTH_THROTTLE.is_blocked(client):
        await websocket.close(code=1008)
        return
    try:
        first = await asyncio.wait_for(websocket.receive_json(), timeout=WS_AUTH_TIMEOUT_SECONDS)
    except Exception:
        AUTH_THROTTLE.record_failure(client)
        await websocket.close(code=1008)
        return
    supplied = first.get("api_key") if isinstance(first, dict) and first.get("type") == "auth" else None
    if not keys_match(supplied, BRIDGE_API_KEY):
        AUTH_THROTTLE.record_failure(client)
        await websocket.close(code=1008)
        return
    AUTH_THROTTLE.record_success(client)

    ok = await asyncio.to_thread(_ws_prepare_symbol, symbol)
    if not ok:
        await websocket.close(code=1011)
        return

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


class NotifyIn(BaseModel):
    text: str


# Tests inject an httpx.MockTransport here; production leaves it None.
TELEGRAM_TRANSPORT = None


def _telegram_credentials():
    return os.environ.get("TELEGRAM_BOT_TOKEN", "").strip(), os.environ.get("TELEGRAM_CHAT_ID", "").strip()


TELEGRAM_ATTEMPTS = 3
_TELEGRAM_RETRY_STATUS = {429, 500, 502, 503, 504}
TELEGRAM_SLEEP = time.sleep  # replaced in tests


def _telegram_send(text: str, reply_markup=None) -> dict:
    """Sends [text] to the owner's Telegram chat (optionally with inline buttons).
    The bot token lives only in bridge/.env (never in the app bundle) and never
    appears in a response or log."""
    token, chat_id = _telegram_credentials()
    if not token or not chat_id:
        return {"sent": False, "reason": "telegram_not_configured"}
    payload = {"chat_id": chat_id, "text": text[:3500]}
    if reply_markup is not None:
        payload["reply_markup"] = reply_markup
    response = None
    for attempt in range(TELEGRAM_ATTEMPTS):
        last = attempt == TELEGRAM_ATTEMPTS - 1
        try:
            with httpx.Client(timeout=10, transport=TELEGRAM_TRANSPORT) as client:
                response = client.post(f"https://api.telegram.org/bot{token}/sendMessage", json=payload)
        except httpx.HTTPError as e:
            log.warning("Telegram send failed: %s", type(e).__name__)  # str(e) could embed the token URL
            if last:
                return {"sent": False, "reason": "telegram_unreachable"}
            TELEGRAM_SLEEP(1.0 * (attempt + 1))
            continue
        if response.status_code == 200:
            break
        # Rate limited or a server-side hiccup: try again shortly. Anything else (bad token, bad chat) will not fix itself.
        if response.status_code in _TELEGRAM_RETRY_STATUS and not last:
            wait = 1.0 * (attempt + 1)
            try:
                wait = float(((response.json().get("parameters") or {}).get("retry_after")) or wait)
            except (ValueError, TypeError, AttributeError):
                pass
            log.warning("Telegram returned HTTP %s - retrying", response.status_code)
            TELEGRAM_SLEEP(min(wait, 5.0))
            continue
        log.warning("Telegram returned HTTP %s", response.status_code)
        return {"sent": False, "reason": f"telegram_http_{response.status_code}"}
    try:
        message_id = (response.json().get("result") or {}).get("message_id")
    except ValueError:
        message_id = None
    return {"sent": True, "message_id": message_id}


def _send_telegram(text: str) -> dict:
    result = _telegram_send(text)
    return {k: v for k, v in result.items() if k != "message_id"}


def _telegram_edit(message_id, text: str) -> None:
    """Best-effort edit of a message the bridge sent earlier (drops its buttons)."""
    token, chat_id = _telegram_credentials()
    if not token or not chat_id or message_id is None:
        return
    try:
        with httpx.Client(timeout=10, transport=TELEGRAM_TRANSPORT) as client:
            client.post(
                f"https://api.telegram.org/bot{token}/editMessageText",
                json={"chat_id": chat_id, "message_id": message_id, "text": text[:3500]},
            )
    except httpx.HTTPError as e:
        log.warning("Telegram edit failed: %s", type(e).__name__)


def _notify_event(text: str) -> None:
    """Best-effort alert from inside the bridge (risk lock, overrides...). Never raises."""
    try:
        _send_telegram(text)
    except Exception as e:
        log.warning("Telegram event alert failed: %s", type(e).__name__)


@app.post("/notify", dependencies=[Depends(require_api_key)])
def notify(body: NotifyIn):
    return _send_telegram(body.text)


# ---------------------------------------------------------------------------
# Telegram remote control (commands, see telegram_bot.py)
# ---------------------------------------------------------------------------
def _telegram_status_text() -> str:
    cfg = CONFIG.snapshot()
    risk = _risk_status()
    lines = [
        "Aureus bridge",
        f"Trading: {'PAUSED' if cfg['mode']['paused'] else 'active'} - mode {cfg['mode']['auto_trade']} - config rev {cfg['revision']}",
    ]
    if risk["available"]:
        loss = risk["loss_percent"]
        lines.append(f"Account: equity {risk['equity']:.2f} - balance {risk['balance']:.2f}")
        lines.append(
            f"Daily loss: {'-' if loss > 0 else '+'}{abs(loss):.2f}% of {risk['limit_percent']:.2f}% limit"
            + (" - LOCKED until 00:00 UTC" if risk["locked"] else "")
        )
    else:
        lines.append("Account: unreadable (MT5 not connected?)")
    with MT5_LOCK:
        positions = mt5.positions_get()
    if positions is None:
        lines.append("Open positions: unreadable")
    elif not positions:
        lines.append("Open positions: none")
    else:
        lines.append(f"Open positions ({len(positions)}):")
        for p in positions[:10]:
            side = "BUY" if p.type == mt5.POSITION_TYPE_BUY else "SELL"
            lines.append(f"  #{p.ticket} {side} {p.volume:g} {p.symbol} @ {p.price_open:.2f}  P/L {p.profit:+.2f}")
    return "\n".join(lines)


def _tg_set_paused(paused: bool) -> str:
    for _attempt in range(2):
        try:
            CONFIG.update(
                {"mode": {"paused": paused}},
                base_revision=CONFIG.revision,
                updated_by="telegram",
                # Reaching this call means the owner already confirmed the button for a resume.
                confirm_risk_increase=not paused,
                remote="telegram",
            )
            break
        except ConfigError as e:
            if e.code == "stale_revision":
                continue
            return f"Could not change the pause state: {e.message}"
    else:
        return "Could not change the pause state: the config kept changing - try again."
    if paused:
        return "Trading PAUSED - no new signals or orders."
    note = ""
    if RISK.is_locked(datetime.now(timezone.utc)):
        note = "\nNote: the daily loss lock is still active, so orders stay blocked until 00:00 UTC."
    return "Trading resumed." + note


def _tg_close_all() -> str:
    results, error = _close_all_positions(None, 50, "Aureus AI telegram")
    if results is None:
        return f"Could not read open positions: {error}"
    closed = [r for r in results if r.success]
    failed = [r for r in results if not r.success]
    CONFIG.record(
        {
            "action": "close_all",
            "by": "telegram",
            "requested": len(results),
            "closed": len(closed),
            "failed": [r.ticket for r in failed],
        }
    )
    if not results:
        return "No open positions."
    text = f"Closed {len(closed)}/{len(results)} position(s)."
    if failed:
        text += "\nSTILL OPEN: " + ", ".join(f"#{r.ticket} ({r.error})" for r in failed)
    return text


# ---------------------------------------------------------------------------
# Trade approval: the app proposes, the owner decides on Telegram, the bridge
# re-verifies the market and only then trades (see signal_store.py)
# ---------------------------------------------------------------------------
class SignalPendingIn(BaseModel):
    uid: str
    symbol: str
    direction: str  # "BUY" | "SELL"
    entry: float
    stop_loss: float
    take_profit: float
    volume: float  # the app's size at signal time; the bridge re-sizes at approval
    label: str = ""
    score: int = 0
    reason: str = ""


def _fixed_volume(order: "OrderOpenIn", cfg: dict):
    """The user's fixed lot, expressed as a lot the broker accepts. Returns (volume, None) or (None, why-not).
    It is rounded DOWN to the broker's lot step and capped at the broker's maximum - both only ever reduce the
    risk - but never raised to the broker's minimum, which would risk more than the user chose."""
    limits = cfg["account_limits"]
    fixed = float(limits["fixed_lot_size"])
    with MT5_LOCK:
        info = mt5.symbol_info(order.symbol)

    def number(name):
        value = getattr(info, name, None)
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0 else None

    step, broker_min, broker_max = number("volume_step") or 0.01, number("volume_min"), number("volume_max")
    lot = math.floor(fixed / step + 1e-9) * step
    if broker_max is not None:
        lot = min(lot, broker_max)
    lot = min(lot, float(limits["max_lot"]))
    decimals = len(str(step).split(".")[1]) if "." in str(step) else 0
    lot = round(lot, decimals)
    if broker_min is not None and lot < broker_min - 1e-9:
        return None, f"The fixed lot {fixed} is below this broker's minimum lot {broker_min}"
    if lot <= 0:
        return None, f"The fixed lot {fixed} is not a lot this broker can trade"
    return lot, None


def _resolve_volume(order: "OrderOpenIn", price: float, cfg: dict):
    """The lot an order will really use: the fixed lot in fixed mode, otherwise the risk-sized lot.
    Returns (volume, None) or (None, why-not)."""
    if cfg["account_limits"].get("lot_mode", "dynamic") == "fixed":
        return _fixed_volume(order, cfg)
    sized = _sized_volume(order, price, cfg)
    if sized is None:
        return None, "The lot cannot be sized right now (the broker's tick value or the account equity is unavailable)"
    return sized, None


def _sized_volume(order: "OrderOpenIn", price: float, cfg: dict):
    """Lot size that risks exactly the configured percentage of equity at the
    ACTUAL stop distance now (not the signal-time one), rounded DOWN to the
    broker's lot step and clamped to the allowed range. None when the symbol
    or account data needed for the maths is not available."""
    limits = cfg["account_limits"]
    with MT5_LOCK:
        info = mt5.symbol_info(order.symbol)
        account = mt5.account_info()

    def number(obj, name):
        value = getattr(obj, name, None)
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None

    tick_value, tick_size, step, equity = (
        number(info, "trade_tick_value"),
        number(info, "trade_tick_size"),
        number(info, "volume_step"),
        number(account, "equity"),
    )
    if not all(n is not None and n > 0 for n in (tick_value, tick_size, step, equity)):
        return None
    risk_per_lot = abs(price - order.stop_loss) / tick_size * tick_value
    if risk_per_lot <= 0:
        return None
    raw = equity * limits["risk_percent_per_trade"] / 100.0 / risk_per_lot
    lot = math.floor(raw / step + 1e-9) * step
    low = max(limits["min_lot"], number(info, "volume_min") or 0.0)
    high = min(limits["max_lot"], number(info, "volume_max") or float("inf"))
    lot = min(max(lot, low), high)
    decimals = len(str(step).split(".")[1]) if "." in str(step) else 0
    return round(lot, decimals)


def _prepare_order(setup: dict, cfg: dict):
    """Turns a proposed signal into an order at TODAY's price. Returns
    (order, None) or (None, why-not). Refuses when price has run away from the
    signal's entry, which is what makes a slow human approval safe."""
    symbol = setup["symbol"]
    buy = setup["direction"].lower() == "buy"
    with MT5_LOCK:
        tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        return None, f"No quote for {symbol} right now"
    price = float(tick.ask if buy else tick.bid)
    drift_problem = _entry_drift_problem(
        setup["direction"], float(setup["entry"]), setup["stop_loss"], setup["take_profit"], price, cfg["account_limits"]
    )
    if drift_problem:
        return None, drift_problem
    order = OrderOpenIn(
        symbol=symbol,
        direction="buy" if buy else "sell",
        volume=float(setup["volume"]),
        stop_loss=float(setup["stop_loss"]),
        take_profit=float(setup["take_profit"]),
    )
    sized, why_not = _resolve_volume(order, price, cfg)
    if sized is None:
        return None, why_not
    order.volume = sized
    return order, None


def _find_position_by_comment(symbol: str, comment: str):
    with MT5_LOCK:
        positions = mt5.positions_get(symbol=symbol)
    for position in positions or ():
        if getattr(position, "comment", "") == comment:
            return position
    return None


def _signal_view(record: dict) -> dict:
    return {
        "uid": record["uid"],
        "state": record["state"],
        "expires_at": record["expires_at"],
        "decided_by": record["decided_by"],
        "result": record["result"],
    }


def _risk_summary(order, buy: bool, fixed: bool = False):
    """What this order would lose at its stop, in the account's currency, or None when it cannot be measured."""
    with MT5_LOCK:
        info = mt5.symbol_info(order.symbol)
        account = mt5.account_info()
        quote = mt5.symbol_info_tick(order.symbol)
    if quote is None:
        return None
    price = float(quote.ask if buy else quote.bid)
    tick_value, tick_size = getattr(info, "trade_tick_value", None), getattr(info, "trade_tick_size", None)
    equity = getattr(account, "equity", None)
    if not all(isinstance(n, (int, float)) and not isinstance(n, bool) and n > 0 for n in (tick_value, tick_size, equity)):
        return None
    amount = abs(price - order.stop_loss) / tick_size * tick_value * order.volume
    currency = getattr(account, "currency", "")
    return {
        "volume": order.volume,
        "amount": amount,
        "percent": amount / equity * 100.0,
        "currency": currency if isinstance(currency, str) else "",
        "fixed": fixed,
    }


def _approval_text(setup: dict, ttl: float, sizing=None, window=None) -> str:
    risk = abs(setup["entry"] - setup["stop_loss"])
    reward = abs(setup["take_profit"] - setup["entry"])
    ratio = f"1:{reward / risk:.1f}" if risk > 0 else "-"
    lines = [
        "Trade approval needed",
        f"{setup['direction']} {setup['symbol']}" + (f" - {setup['label']}" if setup.get("label") else ""),
        f"Entry ~{setup['entry']:.2f}   SL {setup['stop_loss']:.2f}   TP {setup['take_profit']:.2f}   R:R {ratio}",
    ]
    if setup.get("score"):
        lines.append(f"Confluence score {setup['score']}/100")
    reason = (setup.get("reason") or "").strip().splitlines()
    if reason:
        lines.append(f"Why: {reason[0].lstrip('- ')[:160]}")
    if sizing:
        unit = f" {sizing['currency']}" if sizing.get("currency") else ""
        kind = " (fixed)" if sizing.get("fixed") else ""
        lines.append(
            f"Size now ~{sizing['volume']:.2f} lot{kind} - risk ~{sizing['amount']:.2f}{unit} ({sizing['percent']:.2f}% of equity)"
        )
    if window:
        lines.append(f"Taken only while the price stays within {window[0]:.2f} - {window[1]:.2f}.")
    lines.append(
        ("The fixed lot is re-checked" if sizing and sizing.get("fixed") else "The lot is re-sized")
        + f" when you approve. Expires in {int(ttl)} s."
    )
    return "\n".join(lines)


def _decided_text(record: dict, result: str) -> str:
    """The proposal's own message with the outcome appended, so the trade's details stay readable in the chat
    after it expires, is rejected, blocked or executed (an edit replaces the whole text)."""
    original = record.get("message_text")
    if not original:  # a record from before the text was stored: rebuild what can be rebuilt
        try:
            original = _approval_text(record["setup"], record["expires_at"] - record["created_at"])
        except (KeyError, TypeError, ValueError):
            original = ""
    return f"{original}\n\n{result}" if original else result


@app.post("/signals/pending", dependencies=[Depends(require_api_key)])
def signal_pending(body: SignalPendingIn):
    """The app proposes a trade. Nothing is executed here: the owner is asked on
    Telegram. Returns the signal's state (pending | blocked | failed)."""
    cfg = CONFIG.snapshot()
    if cfg["mode"]["auto_trade"] != "approval":
        raise HTTPException(
            409, detail={"code": "approval_mode_off", "message": "mode.auto_trade is not 'approval' on the bridge"}
        )
    token, chat_id = _telegram_credentials()
    if not token or not chat_id:
        raise HTTPException(
            409,
            detail={
                "code": "telegram_not_configured",
                "message": "Approval needs Telegram (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID in bridge/.env)",
            },
        )
    existing = SIGNALS.get(body.uid)
    if existing is not None:  # a retry of the same proposal
        return _signal_view(existing)

    ensure_connected()
    _select_symbol(body.symbol)
    setup = body.model_dump()
    order, problem = _prepare_order(setup, cfg)
    if order is None:
        return {"uid": body.uid, "state": "blocked", "reason": problem}
    gate_error, _ = _config_gate(order, allowed_modes=("approval", "auto"))
    if gate_error:
        return {"uid": body.uid, "state": "blocked", "reason": gate_error}

    ttl = cfg["account_limits"]["approval_ttl_seconds"]
    try:
        record, _created = SIGNALS.submit(setup, ttl)
    except SlotBusy:
        raise HTTPException(409, detail={"code": "slot_busy", "message": "Another signal is waiting for a decision"})

    keyboard = {
        "inline_keyboard": [
            [
                {"text": "Approve", "callback_data": f"ap:{record['sid']}"},
                {"text": "Reject", "callback_data": f"rj:{record['sid']}"},
            ]
        ]
    }
    text = _approval_text(
        setup,
        ttl,
        _risk_summary(order, body.direction.lower() == "buy", cfg["account_limits"].get("lot_mode") == "fixed"),
        _drift_window(body.direction, body.entry, body.stop_loss, body.take_profit, cfg["account_limits"]),
    )
    sent = _telegram_send(text, reply_markup=keyboard)
    if not sent.get("sent"):
        # Nobody can be asked, so nothing may stay waiting.
        SIGNALS.claim(record["sid"], "bridge")
        SIGNALS.finish(record["uid"], FAILED, {"error": sent.get("reason", "telegram_unreachable")})
        return {"uid": body.uid, "state": "failed", "reason": sent.get("reason", "telegram_unreachable")}
    SIGNALS.set_message_id(record["uid"], sent.get("message_id"), text)
    CONFIG.record({"action": "approval_requested", "uid": body.uid, "direction": body.direction, "entry": body.entry})
    return _signal_view(SIGNALS.get(record["uid"]))


@app.get("/signals/{uid:path}", dependencies=[Depends(require_api_key)])
def signal_status(uid: str):
    record = SIGNALS.get(uid)
    if record is None:
        raise HTTPException(404, detail={"code": "unknown_signal", "message": "No such signal (expired and pruned, or never sent)"})
    return _signal_view(record)


def _approve_signal(sid: str, by: str) -> str:
    """Runs when the owner presses Approve. Claims the signal (so a second press
    finds nothing), re-reads the market, re-sizes, re-checks every limit, and only
    then trades. Always returns text for the Telegram message."""
    record = SIGNALS.claim(sid, by)
    if record is None:
        return "Already handled or expired - nothing was traded."
    uid, setup = record["uid"], record["setup"]
    what = f"{setup['direction']} {setup['symbol']}"

    def blocked(reason: str) -> str:
        SIGNALS.finish(uid, BLOCKED, {"reason": reason})
        CONFIG.record({"action": "approval_blocked", "uid": uid, "by": by, "reason": reason})
        return f"Blocked - nothing was traded.\n{what}: {reason}"

    def failed(error: str) -> str:
        SIGNALS.finish(uid, FAILED, {"error": error})
        CONFIG.record({"action": "approval_failed", "uid": uid, "by": by, "error": error})
        return f"Order failed: {error}"

    try:
        ensure_connected()
        _select_symbol(setup["symbol"])
        cfg = CONFIG.snapshot()
        order, problem = _prepare_order(setup, cfg)
        if order is None:
            return blocked(problem)
        gate_error, deviation = _config_gate(order, allowed_modes=("approval", "auto"))
        if gate_error:
            return blocked(gate_error)
        comment = f"AUR-{sid}"
        outcome = _execute_market_order(order, deviation, comment)
        if not outcome.success:
            # A timeout or dropped reply may hide an order that DID go through.
            found = _find_position_by_comment(order.symbol, comment)
            if found is not None:
                outcome = OrderOpenOut(success=True, ticket=int(found.ticket), price=float(found.price_open))
        if not outcome.success:
            return failed(outcome.error or "unknown error")
        result = {
            "ticket": outcome.ticket,
            "price": outcome.price,
            "volume": order.volume,
            "stop_loss": order.stop_loss,
            "take_profit": order.take_profit,
            "direction": setup["direction"],
        }
        SIGNALS.finish(uid, EXECUTED, result)
        CONFIG.record({"action": "approval_executed", "uid": uid, "by": by, **result})
        return (
            f"Executed: {what} {order.volume:g} lots @ {outcome.price:.2f}\n"
            f"SL {order.stop_loss:.2f}   TP {order.take_profit:.2f}   ticket #{outcome.ticket}"
        )
    except HTTPException as e:
        return failed(str(e.detail))
    except Exception as e:
        log.warning("Approval of %s crashed: %s", uid, type(e).__name__)
        return failed(f"{type(e).__name__}: {e}")


def _reject_signal(sid: str, by: str) -> str:
    record = SIGNALS.reject(sid, by)
    if record is None:
        return "Already handled or expired - nothing was traded."
    CONFIG.record({"action": "approval_rejected", "uid": record["uid"], "by": by})
    return "Rejected - nothing was traded."


def _expire_pending_signals() -> None:
    for record in SIGNALS.expire_due():
        CONFIG.record({"action": "approval_expired", "uid": record["uid"]})
        _telegram_edit(record.get("message_id"), _decided_text(record, "Expired - nothing was traded."))


def _edit_recovered_signals() -> None:
    """Proposals that were still waiting when the bridge last stopped: their Telegram buttons would otherwise
    stay on screen looking alive."""
    for record in SIGNALS.recovered:
        CONFIG.record({"action": "approval_expired", "uid": record["uid"], "by": "bridge-restart"})
        _telegram_edit(
            record.get("message_id"), _decided_text(record, "Expired - the bridge was restarted, nothing was traded.")
        )
    SIGNALS.recovered = []


async def _signal_expiry_loop() -> None:
    while True:
        try:
            await asyncio.to_thread(_expire_pending_signals)
        except Exception as e:
            log.warning("Signal expiry pass failed: %s", type(e).__name__)
        await asyncio.sleep(2.0)


class _TelegramActions:
    async def status(self) -> str:
        return await asyncio.to_thread(_telegram_status_text)

    async def pause(self) -> str:
        return await asyncio.to_thread(_tg_set_paused, True)

    async def resume(self) -> str:
        return await asyncio.to_thread(_tg_set_paused, False)

    async def close_all(self) -> str:
        return await asyncio.to_thread(_tg_close_all)

    async def approve(self, sid: str, by: str) -> str:
        return await asyncio.to_thread(_approve_signal, sid, by)

    async def reject(self, sid: str, by: str) -> str:
        return await asyncio.to_thread(_reject_signal, sid, by)

    async def stop(self) -> str:
        paused = await asyncio.to_thread(_tg_set_paused, True)
        closed = await asyncio.to_thread(_tg_close_all)
        return f"{paused}\n{closed}"


def _build_telegram_bot():
    """The command bot, or None when Telegram is not (safely) configured."""
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat:
        return None
    try:
        chat_id = int(chat)
    except ValueError:
        log.warning("TELEGRAM_CHAT_ID must be a number - Telegram commands are disabled")
        return None
    raw_users = os.environ.get("TELEGRAM_ALLOWED_USER_IDS", "").strip()
    try:
        users = [int(u) for u in raw_users.split(",") if u.strip()] or ([chat_id] if chat_id > 0 else [])
    except ValueError:
        log.warning("TELEGRAM_ALLOWED_USER_IDS must be comma-separated numbers - Telegram commands are disabled")
        return None
    if not users:
        log.warning("TELEGRAM_CHAT_ID is a group; set TELEGRAM_ALLOWED_USER_IDS to the user ids allowed to command - disabled")
        return None
    return TelegramBot(
        TelegramApi(token, transport=TELEGRAM_TRANSPORT), _TelegramActions(), chat_id=chat_id, allowed_user_ids=users
    )


async def _run_telegram_bot(bot) -> None:
    await asyncio.to_thread(_edit_recovered_signals)
    await asyncio.to_thread(_notify_event, "Aureus bridge online. Send /help for commands.")
    try:
        await bot.run()
    except asyncio.CancelledError:
        raise
    except Exception as e:
        log.error("Telegram bot stopped: %s", type(e).__name__)


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

    _problems = validate_startup(BRIDGE_HOST, BRIDGE_API_KEY)
    if _problems:
        print("\nAureus bridge will NOT start:\n", file=sys.stderr)
        for _p in _problems:
            print(f"  - {_p}", file=sys.stderr)
        sys.exit(2)
    log.info(
        "Bridge listening on %s:%s (%s)",
        BRIDGE_HOST,
        BRIDGE_PORT,
        "this machine only" if BRIDGE_HOST in ("127.0.0.1", "localhost", "::1") else "NETWORK-EXPOSED",
    )
    # The app object (not an import string) so the frozen executable needs no module lookup.
    uvicorn.run(app, host=BRIDGE_HOST, port=BRIDGE_PORT, reload=False)
