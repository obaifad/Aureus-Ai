"""
Aureus AI - account-level daily loss circuit breaker
====================================================
Pure Python (no MetaTrader5 import) so the rules can be unit-tested.

The rule: once the account has lost `limit_percent` of its day-start value
(realised AND floating), trading is LOCKED until the next UTC day.

* The lock is sticky. A recovery in floating P&L never releases it - a daily
  stop that un-trips itself when price bounces is not a stop. It ends at
  00:00 UTC or by an explicit, audited, once-a-day override.
* The baseline is the day-start balance, rebuilt from the broker's deal
  history (balance now minus today's realised result), so a bridge restart
  mid-day cannot move it. If the history is unreadable it falls back to the
  first equity seen that day.
* State survives restarts (atomic JSON write).
"""

from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Optional

MAX_OVERRIDES_PER_DAY = 1


class GuardError(Exception):
    pass


def _day_key(now: datetime) -> str:
    return now.astimezone(timezone.utc).date().isoformat()


def _fresh_state(day: str) -> Dict[str, Any]:
    return {
        "day": day,
        "baseline": None,
        "baseline_source": None,
        "locked": False,
        "locked_at": None,
        "locked_loss_percent": None,
        "overrides": 0,
        "breach_actions_done": False,
    }


class DailyLossGuard:
    def __init__(self, data_dir: Path | str) -> None:
        self.path = Path(data_dir) / "risk_state.json"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._state = self._load()

    # ---- persistence ------------------------------------------------------
    def _load(self) -> Dict[str, Any]:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(raw, dict) and isinstance(raw.get("day"), str):
                state = _fresh_state(raw["day"])
                state.update({k: raw[k] for k in state if k in raw})
                return state
        except (OSError, ValueError):
            pass
        return _fresh_state("")

    def _save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self._state, fh, indent=2)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, self.path)

    # ---- queries ----------------------------------------------------------
    def is_locked(self, now: Optional[datetime] = None) -> bool:
        with self._lock:
            if now is not None and self._state["day"] != _day_key(now):
                return False
            return bool(self._state["locked"])

    def actions_pending(self) -> bool:
        """Locked, but the configured breach action (close all) has not run."""
        with self._lock:
            return bool(self._state["locked"]) and not self._state["breach_actions_done"]

    def mark_actions_done(self) -> None:
        with self._lock:
            self._state["breach_actions_done"] = True
            self._save()

    def snapshot(self) -> Dict[str, Any]:
        with self._lock:
            return dict(self._state)

    # ---- core -------------------------------------------------------------
    def evaluate(
        self,
        *,
        equity: float,
        balance: float,
        realized_today: Callable[[], Optional[float]],
        limit_percent: float,
        now: datetime,
    ) -> Dict[str, Any]:
        """Updates and returns the guard's status. `newly_locked` is True only
        on the evaluation that trips the lock."""
        with self._lock:
            day = _day_key(now)
            if self._state["day"] != day:
                self._state = _fresh_state(day)
                self._save()

            state = self._state
            if state["baseline"] is None:
                realized = realized_today()
                if realized is None:
                    baseline, source = equity, "first_seen"
                else:
                    baseline, source = balance - realized, "deals"
                if baseline <= 0:
                    baseline, source = equity, "first_seen"
                state["baseline"], state["baseline_source"] = float(baseline), source
                self._save()

            baseline = float(state["baseline"])
            loss = baseline - equity
            loss_percent = (loss / baseline * 100.0) if baseline > 0 else 0.0

            newly_locked = False
            if not state["locked"] and limit_percent > 0 and loss_percent >= limit_percent:
                state["locked"] = True
                state["locked_at"] = now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                state["locked_loss_percent"] = round(loss_percent, 3)
                state["breach_actions_done"] = False
                newly_locked = True
                self._save()

            return {
                "day": day,
                "baseline": round(baseline, 2),
                "baseline_source": state["baseline_source"],
                "equity": round(float(equity), 2),
                "balance": round(float(balance), 2),
                "loss_amount": round(loss, 2),
                "loss_percent": round(loss_percent, 3),
                "limit_percent": float(limit_percent),
                "locked": bool(state["locked"]),
                "locked_at": state["locked_at"],
                "locked_loss_percent": state["locked_loss_percent"],
                "overrides_today": int(state["overrides"]),
                "can_trade": not state["locked"],
                "newly_locked": newly_locked,
            }

    def override(self, *, equity: float, now: datetime) -> None:
        """Explicit release after a lock: rebases the day's baseline to the
        CURRENT equity, i.e. grants a fresh loss budget from here. Allowed
        once per UTC day and only while locked."""
        with self._lock:
            if self._state["day"] != _day_key(now) or not self._state["locked"]:
                raise GuardError("Nothing to override - trading is not locked today.")
            if self._state["overrides"] >= MAX_OVERRIDES_PER_DAY:
                raise GuardError("The daily-loss override was already used today. Trading stays locked until 00:00 UTC.")
            self._state.update(
                {
                    "baseline": float(equity),
                    "baseline_source": "override",
                    "locked": False,
                    "locked_at": None,
                    "locked_loss_percent": None,
                    "breach_actions_done": False,
                    "overrides": self._state["overrides"] + 1,
                }
            )
            self._save()
