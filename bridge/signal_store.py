"""
Aureus AI - pending trade approvals
===================================
State machine for "approve this trade from Telegram". Pure Python (no
MetaTrader5 / FastAPI), so every transition is unit-testable.

    pending --claim--> executing --> executed | failed | blocked
       |
       +--reject--> rejected
       +--(time)--> expired

Rules that make a double tap, a retry or a restart harmless:
* every transition is a compare-and-set under one lock - only ONE caller can
  move a signal out of `pending`, so a button pressed twice executes once;
* a signal that has passed its deadline can never be claimed (it is marked
  `expired` instead), however late the button is pressed;
* only one signal may be waiting at a time (the one-active-trade rule extends
  to "one decision at a time");
* after a restart nothing stays `pending` (the bridge cannot know whether the
  owner still wants it) and anything caught mid-`executing` is reported as
  `failed` with an instruction to check MT5.
"""

from __future__ import annotations

import copy
import json
import os
import secrets
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

PENDING = "pending"
EXECUTING = "executing"
EXECUTED = "executed"
REJECTED = "rejected"
EXPIRED = "expired"
BLOCKED = "blocked"
FAILED = "failed"

LIVE_STATES = {PENDING, EXECUTING}
FINAL_STATES = {EXECUTED, REJECTED, EXPIRED, BLOCKED, FAILED}

KEEP_RECORDS = 200
KEEP_SECONDS = 7 * 86400


class SlotBusy(Exception):
    """Another signal is still waiting for a decision."""


class SignalStore:
    def __init__(self, data_dir: Path | str, clock: Callable[[], float] = time.time) -> None:
        self.path = Path(data_dir) / "pending_signals.json"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._clock = clock
        self._lock = threading.RLock()
        self._records: Dict[str, Dict[str, Any]] = self._load()
        # Proposals that were still waiting when the previous run stopped (now expired): the bridge edits their
        # Telegram messages once it is back, so the old buttons do not look alive.
        self.recovered: List[Dict[str, Any]] = []
        self._recover()

    # ---- persistence ------------------------------------------------------
    def _load(self) -> Dict[str, Dict[str, Any]]:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
            records = raw.get("records") if isinstance(raw, dict) else None
            if isinstance(records, dict):
                return {k: v for k, v in records.items() if isinstance(v, dict) and "state" in v}
        except (OSError, ValueError):
            pass
        return {}

    def _save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"records": self._records}, fh, indent=1)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, self.path)

    def _recover(self) -> None:
        now = self._clock()
        changed = False
        for record in self._records.values():
            if record["state"] == PENDING:
                record["state"] = EXPIRED
                record["decided_by"] = "bridge-restart"
                record["decided_at"] = now
                self.recovered.append(self._view(record))
                changed = True
            elif record["state"] == EXECUTING:
                record["state"] = FAILED
                record["result"] = {
                    "error": "The bridge restarted while this order was being executed - check MetaTrader "
                    "for an open position before trying again."
                }
                record["decided_at"] = now
                changed = True
        if changed:
            self._save()

    # ---- helpers ----------------------------------------------------------
    @staticmethod
    def _view(record: Dict[str, Any]) -> Dict[str, Any]:
        return copy.deepcopy(record)

    def _prune(self, now: float) -> None:
        final = [k for k, v in self._records.items() if v["state"] in FINAL_STATES]
        final.sort(key=lambda k: self._records[k]["created_at"])
        for key in final[:-KEEP_RECORDS]:
            del self._records[key]
        for key in [k for k in final if now - self._records.get(k, {}).get("created_at", now) > KEEP_SECONDS]:
            self._records.pop(key, None)

    def _by_sid(self, sid: str) -> Optional[Dict[str, Any]]:
        for record in self._records.values():
            if record["sid"] == sid:
                return record
        return None

    # ---- queries ----------------------------------------------------------
    def get(self, uid: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            record = self._records.get(uid)
            return self._view(record) if record else None

    def get_by_sid(self, sid: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            record = self._by_sid(sid)
            return self._view(record) if record else None

    def live(self) -> List[Dict[str, Any]]:
        with self._lock:
            return [self._view(r) for r in self._records.values() if r["state"] in LIVE_STATES]

    # ---- transitions ------------------------------------------------------
    def expire_due(self, now: Optional[float] = None) -> List[Dict[str, Any]]:
        """Marks every overdue `pending` signal expired; returns those records."""
        with self._lock:
            now = self._clock() if now is None else now
            expired = []
            for record in self._records.values():
                if record["state"] == PENDING and record["expires_at"] <= now:
                    record["state"] = EXPIRED
                    record["decided_by"] = "timeout"
                    record["decided_at"] = now
                    expired.append(self._view(record))
            if expired:
                self._save()
            return expired

    def submit(self, setup: Dict[str, Any], ttl_seconds: float) -> tuple[Dict[str, Any], bool]:
        """Registers [setup] (must carry `uid`). Returns (record, created).
        Submitting the same uid again is idempotent and returns the original."""
        with self._lock:
            now = self._clock()
            self.expire_due(now)
            uid = str(setup["uid"])
            existing = self._records.get(uid)
            if existing is not None:
                return self._view(existing), False
            if any(r["state"] in LIVE_STATES for r in self._records.values()):
                raise SlotBusy("another signal is still waiting for a decision")
            record = {
                "uid": uid,
                "sid": secrets.token_urlsafe(6),
                "state": PENDING,
                "created_at": now,
                "expires_at": now + float(ttl_seconds),
                "decided_by": None,
                "decided_at": None,
                "setup": copy.deepcopy(setup),
                "result": None,
                "message_id": None,
            }
            self._records[uid] = record
            self._prune(now)
            self._save()
            return self._view(record), True

    def set_message_id(self, uid: str, message_id: Optional[int], text: Optional[str] = None) -> None:
        """Remembers the Telegram message (and the text it carried) so it can be edited when the proposal ends."""
        with self._lock:
            if uid in self._records:
                self._records[uid]["message_id"] = message_id
                if text is not None:
                    self._records[uid]["message_text"] = text[:3000]
                self._save()

    def claim(self, sid: str, by: str) -> Optional[Dict[str, Any]]:
        """pending -> executing. None when the signal is unknown, already
        handled, or past its deadline (in which case it is marked expired)."""
        with self._lock:
            now = self._clock()
            record = self._by_sid(sid)
            if record is None or record["state"] != PENDING:
                return None
            if record["expires_at"] <= now:
                record["state"] = EXPIRED
                record["decided_by"] = "timeout"
                record["decided_at"] = now
                self._save()
                return None
            record["state"] = EXECUTING
            record["decided_by"] = by
            record["decided_at"] = now
            self._save()
            return self._view(record)

    def reject(self, sid: str, by: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            now = self._clock()
            record = self._by_sid(sid)
            if record is None or record["state"] != PENDING or record["expires_at"] <= now:
                return None
            record["state"] = REJECTED
            record["decided_by"] = by
            record["decided_at"] = now
            self._save()
            return self._view(record)

    def finish(self, uid: str, state: str, result: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """executing -> executed | failed | blocked."""
        if state not in (EXECUTED, FAILED, BLOCKED):
            raise ValueError(f"cannot finish into {state!r}")
        with self._lock:
            record = self._records.get(uid)
            if record is None or record["state"] != EXECUTING:
                return None
            record["state"] = state
            record["result"] = copy.deepcopy(result)
            self._save()
            return self._view(record)
