"""
Aureus AI - bridge security helpers
===================================
Pure Python (no MetaTrader5 / FastAPI import) so each rule is unit-testable.

* constant-time key comparison (no timing side channel on the API key)
* a brute-force throttle for failed authentication
* log redaction, so a key can never be written to a log file
* startup validation: the bridge refuses to run without a real key, and
  refuses a non-loopback bind unless the key is strong
"""

from __future__ import annotations

import hmac
import ipaddress
import logging
import re
import threading
import time
from collections import deque
from typing import Deque, Dict, List, Optional

MIN_KEY_LENGTH = 16
STRONG_KEY_LENGTH = 24
FAILURES_BEFORE_BLOCK = 10
FAILURE_WINDOW_SECONDS = 60.0
BLOCK_SECONDS = 300.0


def keys_match(supplied: Optional[str], expected: str) -> bool:
    """Constant-time comparison. False for a missing key or an unset expected one."""
    if not supplied or not expected:
        return False
    return hmac.compare_digest(supplied.encode("utf-8"), expected.encode("utf-8"))


def is_loopback(host: str) -> bool:
    if host in ("localhost", ""):
        return host == "localhost"
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def validate_startup(host: str, api_key: str) -> List[str]:
    """Returns the reasons the bridge must NOT start (empty = fine)."""
    problems: List[str] = []
    if not api_key:
        problems.append(
            "BRIDGE_API_KEY is not set. The bridge can open and close REAL positions, so it will not run "
            "without a secret. Generate one with:  python -c \"import secrets; print(secrets.token_urlsafe(32))\"  "
            "and put the SAME value in bridge/.env and in the app's .env."
        )
    elif len(api_key) < MIN_KEY_LENGTH:
        problems.append(f"BRIDGE_API_KEY is too short ({len(api_key)} characters, minimum {MIN_KEY_LENGTH}).")
    if api_key and not is_loopback(host) and len(api_key) < STRONG_KEY_LENGTH:
        problems.append(
            f"BRIDGE_HOST={host} exposes the bridge to the network, which needs a key of at least "
            f"{STRONG_KEY_LENGTH} characters (yours has {len(api_key)})."
        )
    return problems


class AuthThrottle:
    """Blocks a client after too many failed authentications, so the key
    cannot be guessed by trying values in a loop."""

    def __init__(
        self,
        failures: int = FAILURES_BEFORE_BLOCK,
        window: float = FAILURE_WINDOW_SECONDS,
        block: float = BLOCK_SECONDS,
        clock=time.monotonic,
    ) -> None:
        self._failures = failures
        self._window = window
        self._block = block
        self._clock = clock
        self._lock = threading.Lock()
        self._recent: Dict[str, Deque[float]] = {}
        self._blocked_until: Dict[str, float] = {}

    def is_blocked(self, client: str) -> bool:
        with self._lock:
            until = self._blocked_until.get(client)
            if until is None:
                return False
            if self._clock() >= until:
                del self._blocked_until[client]
                self._recent.pop(client, None)
                return False
            return True

    def record_failure(self, client: str) -> bool:
        """Returns True if this failure caused the client to become blocked."""
        with self._lock:
            now = self._clock()
            window = self._recent.setdefault(client, deque())
            window.append(now)
            while window and now - window[0] > self._window:
                window.popleft()
            if len(window) >= self._failures:
                self._blocked_until[client] = now + self._block
                return True
            return False

    def record_success(self, client: str) -> None:
        with self._lock:
            self._recent.pop(client, None)


_SECRET_PATTERNS = [
    re.compile(r"(api_key=)[^&\s\"']+", re.IGNORECASE),
    re.compile(r"(x-api-key['\"]?\s*[:=]\s*['\"]?)[^\s,'\"}]+", re.IGNORECASE),
    re.compile(r"(bot)\d{6,}:[A-Za-z0-9_-]{20,}", re.IGNORECASE),  # Telegram bot tokens in URLs
]


def redact(text: str) -> str:
    out = text
    out = _SECRET_PATTERNS[0].sub(r"\1***", out)
    out = _SECRET_PATTERNS[1].sub(r"\1***", out)
    out = _SECRET_PATTERNS[2].sub(r"\1***", out)
    return out


class RedactSecretsFilter(logging.Filter):
    """Rewrites every record so API keys / bot tokens never reach a log."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:
            return True
        cleaned = redact(message)
        if cleaned != message:
            record.msg = cleaned
            record.args = ()
        return True
