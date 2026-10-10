"""
Aureus AI - Strategy configuration store
========================================
Single source of truth for every runtime-tunable trading setting. Pure
Python (no MetaTrader5 import) so it can be unit-tested anywhere.

Design rules
------------
* The bridge OWNS the config; clients (Flutter app, Telegram) read it with
  GET /config and change it with POST /config/update.
* Every field has a hard BOUND defined here, in code. The API can never
  move a value outside it, no matter who calls.
* Updates are optimistic-concurrency controlled: the caller sends the
  `base_revision` it last read; a stale one is rejected (409) instead of
  silently overwriting someone else's edit.
* Changes that make the account RISKIER (raise risk %, loosen spread, turn a
  filter off, escalate auto-trading, resume from pause...) need an explicit
  `confirm_risk_increase`, and are rate limited. Tightening is always free.
* Writes are atomic (temp file + fsync + os.replace); every accepted or
  rejected change is appended to an audit log; the last N revisions are kept
  as restorable backups.
"""

from __future__ import annotations

import copy
import json
import math
import os
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Deque, Dict, List, Optional, Tuple

SCHEMA_VERSION = 1
MAX_BACKUPS = 20
RISK_INCREASES_PER_HOUR = 3

ENGINE_IDS: Tuple[str, ...] = ("htf_retest", "ict", "ici", "orb", "breakout", "range_bounce")

# Matches SignalChecker._enginePriorityOrder: Top-Down > ICT > ICI > Range Bounce >
# ORB > Breakout (lower number wins a simultaneous fire).
DEFAULT_PRIORITY = {"htf_retest": 1, "ict": 2, "ici": 3, "range_bounce": 4, "orb": 5, "breakout": 6}

# Keys the API may never write (set by the server itself).
META_KEYS = ("schema_version", "revision", "updated_at", "updated_by", "account_fingerprint")

# What the bridge itself enforces today vs. what is only stored for now
# (consumed by the Flutter engines / later phases). Served to the UI so it
# never presents a stored-only field as if it were already enforced.
ENFORCED_BY_BRIDGE = [
    "mode.paused",
    "mode.auto_trade (direct orders)",
    "account_limits.max_lot",
    "account_limits.max_spread_pips",
    "account_limits.max_open_positions",
    "account_limits.max_slippage_points",
    "account_limits.strict_min_lot_risk",
    "account_limits.lot_mode",
    "account_limits.fixed_lot_size",
    "account_limits.max_entry_drift_dollars (direct and approved orders)",
    "account_limits.entry_drift_chase_r (direct and approved orders)",
    "account_limits.max_daily_loss_percent",
    "account_limits.on_daily_loss",
]


class ConfigError(Exception):
    """Carries an HTTP-friendly status and a machine-readable code."""

    def __init__(self, status: int, code: str, message: str, extra: Optional[Dict[str, Any]] = None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.extra = extra or {}

    def payload(self) -> Dict[str, Any]:
        return {"code": self.code, "message": self.message, **self.extra}


# ---------------------------------------------------------------------------
# Field specification (types, hard bounds, risk direction)
# ---------------------------------------------------------------------------
def _f(default, lo=None, hi=None, nullable=False, risk=None):
    return {"type": "float", "default": default, "min": lo, "max": hi, "nullable": nullable, "risk": risk}


def _i(default, lo=None, hi=None, nullable=False, risk=None):
    return {"type": "int", "default": default, "min": lo, "max": hi, "nullable": nullable, "risk": risk}


def _b(default, risk=None):
    return {"type": "bool", "default": default, "nullable": False, "risk": risk}


def _e(default, values, risk=None):
    return {"type": "enum", "default": default, "values": list(values), "nullable": False, "risk": risk}


# risk: "up"            bigger value = riskier
#       "down"          smaller value = riskier
#       "false_riskier" turning it OFF = riskier
#       "true_safer"    True is the safe state, turning it OFF = riskier
#                       (mode.paused: resuming re-enables trading)
#       "order"         enum: later in `values` = riskier
def _engine_spec(engine_id: str, index: int, params: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "enabled": _b(True),
        "priority": _i(DEFAULT_PRIORITY[engine_id], 1, len(ENGINE_IDS)),
        "magic": _i(20260921 + index),  # immutable, see _IMMUTABLE_SUFFIXES
        "rr": _f(None, 1.0, 4.0, nullable=True),
        "max_spread_pips": _f(None, 1.0, 60.0, nullable=True, risk="up"),
        # Range Bounce and the Asia ORB were replayed without the DXY filter, so they ship exempt from it.
        "dxy": _e("exempt" if engine_id in ("range_bounce", "orb") else "block", ["block", "score", "off", "exempt"], risk="order"),
        "on_disable": _e("block_new", ["block_new", "close_open"]),
        "shadow": _b(False),
        "params": params,
    }


# Market-dynamics safety layers (2026-10-07). The signal engines in the app evaluate them; the bridge
# only owns and bounds the settings. A layer's mode is one of:
#   block   enforced: a setup it rejects is not traded
#   shadow  evaluated and recorded (log + the setup's shadow flags) but never blocks - the default
#   off     not evaluated at all
# `order` risk: later in the list = riskier, so moving block -> shadow/off needs the risk confirmation
# while tightening (off/shadow -> block) is always free.
LAYER_MODES = ["block", "shadow", "off"]


def _layer_mode() -> Dict[str, Any]:
    return _e("shadow", LAYER_MODES, risk="order")


def _build_spec() -> Dict[str, Any]:
    engine_params = {
        "htf_retest": {"min_rr": _f(1.5, 1.0, 3.0, risk="down")},
        "ict": {
            "min_confluence_reversal": _i(70, 50, 95, risk="down"),
            # Liquidity-Sweep Reversal realignment: only allowed when aligned with the 4H+1H structure bias,
            # or - with no clear bias - when the sweep happened at the boundary of a real, non-trending range.
            "sweep_mode": _layer_mode(),
            "sweep_range_lookback": _i(48, 16, 192),
            "sweep_min_range_atr": _f(2.0, 0.5, 8.0, risk="down"),
            "sweep_boundary_atr": _f(0.5, 0.1, 2.0, risk="up"),
            "sweep_max_efficiency": _f(0.35, 0.1, 0.8, risk="up"),
        },
        "ici": {
            "min_impulse_body_ratio": _f(0.65, 0.4, 0.95),
            "min_consecutive_impulse": _i(2, 1, 5),
            "min_rejection_wick_ratio": _f(0.5, 0.2, 0.9),
            "min_sl_pips": _f(30.0, 10.0, 150.0, risk="down"),
        },
        # Asia ORB (2026-10-09): the old London/New York session switches and the 4H trend filter were removed with
        # the old engine. A config saved before that still loads - _read_valid keeps only the keys in this spec.
        "orb": {
            "sl_pips_override": _f(0.0, 0.0, 300.0),
            "tp_pips_override": _f(0.0, 0.0, 600.0),
        },
        "breakout": {
            "min_body_atr": _f(0.6, 0.2, 2.0),
            "max_body_atr": _f(2.5, 1.0, 5.0),
            "close_location": _f(0.70, 0.5, 0.95),
            "min_range_expansion": _f(1.2, 1.0, 3.0),
            "max_entry_distance_atr": _f(0.8, 0.2, 3.0, risk="up"),
            "require_retest": _b(True, risk="false_riskier"),
            "retest_lookback": _i(24, 4, 60),
            "retest_tolerance_dollars": _f(0.5, 0.1, 3.0),
            "failed_reversal": _b(False),
            "sl_atr": _f(1.2, 0.3, 4.0),
            "tp_r": _f(1.8, 1.0, 4.0),
            "htf_mode": _e("block", ["block", "score", "off"], risk="order"),
        },
        "range_bounce": {
            "touch_dollars": _f(1.0, 0.2, 5.0),
            "min_wick_ratio": _f(0.5, 0.2, 0.9),
            "break_lookback": _i(10, 3, 30),
            "sl_atr": _f(0.5, 0.1, 3.0),
            "min_boundary_r": _f(1.0, 0.5, 3.0),
            "min_rr": _f(1.2, 1.0, 3.0, risk="down"),
            "zone_count": _i(3, 1, 6),
            # Late-session no-entry window (UTC hours, [start, end)): Range Bounce opens nothing while the clock
            # is inside it. start >= end switches it off - and it ships OFF (24-24): on top of the 15M-only rule its
            # measured effect was not stable (-266 pips over 16.09-07.10, +235 over 09.07-15.09), see
            # AppConfig.zoneBounceBlockStartUtc. Lower the start to 17 to block 17:00-24:00 UTC (the thin hours
            # around the NY close). Raising the start or lowering the end shrinks the window, i.e. loosens the engine.
            "block_start_utc": _i(24, 0, 24, risk="up"),
            "block_end_utc": _i(24, 0, 24, risk="down"),
            # Hot-volatility gate: Range Bounce opens nothing while ATR(14) on 15M is more than this many times
            # the median ATR of the last 3 days (1.2 = 20% hotter than its own norm). A bounce fades a move,
            # and in a hot market the move is more likely to keep going. 10 effectively switches it off.
            "max_atr_ratio": _f(1.2, 1.0, 10.0, risk="up"),
            # Fresh-move gate: Range Bounce will not fade a sharp move. If price ran more than this many ATR(14)
            # AGAINST the trade's direction over the last 2 hours (8 closed 15M candles) - a BUY after a fall, a SELL
            # after a rally - the bounce is skipped. OFF BY DEFAULT (10 = off in practice): replayed on ~12 weeks of
            # real MT5 history, on top of the other Range Bounce rules, it lost money in both periods at every limit
            # tried (2-4 ATR), so it ships disabled; lower the value to turn it on.
            "max_fade_atr": _f(10.0, 1.0, 10.0, risk="up"),
        },
    }
    return {
        "mode": {
            "auto_trade": _e("off", ["off", "approval", "auto"], risk="order"),
            "paused": _b(False, risk="true_safer"),
        },
        "account_limits": {
            # dynamic: the lot is sized from risk_percent_per_trade and the stop distance.
            # fixed: every order uses fixed_lot_size (the daily loss limit and all other gates still apply).
            "lot_mode": _e("dynamic", ["dynamic", "fixed"], risk="order"),
            "fixed_lot_size": _f(0.01, 0.01, 10.0, risk="up"),
            "risk_percent_per_trade": _f(1.0, 0.05, 2.0, risk="up"),
            "max_daily_loss_percent": _f(3.0, 0.5, 5.0, risk="up"),
            "on_daily_loss": _e("block", ["block", "close_all"]),
            "max_open_positions": _i(1, 1, 3, risk="up"),
            "min_lot": _f(0.01, 0.01, 1.0),
            "max_lot": _f(5.0, 0.01, 10.0, risk="up"),
            "max_spread_pips": _f(30.0, 1.0, 60.0, risk="up"),
            "max_slippage_points": _i(20, 0, 100, risk="up"),
            # Off (default): the smallest lot is always allowed, even when it risks more than the limit
            # (small accounts). On: such an order is refused instead.
            "strict_min_lot_risk": _b(False, risk="false_riskier"),
            "max_entry_drift_dollars": _f(1.5, 0.1, 5.0, risk="up"),
            # How far the price may already have run IN THE TRADE'S DIRECTION (we would pay more) before an
            # approval or a late order is refused, as a share of the signal's own stop distance - on top of
            # the flat dollar limit above (the larger of the two applies). The reward must still be at least
            # as big as the new risk. 0 = flat dollar limit only. Moves against the trade keep the flat limit.
            "entry_drift_chase_r": _f(0.25, 0.0, 0.5, risk="up"),
            "approval_ttl_seconds": _i(90, 15, 300, risk="up"),
        },
        "trade_rules": {
            "min_sl_pips": _f(20.0, 5.0, 100.0),
            "max_sl_pips": _f(200.0, 50.0, 500.0),
            "min_tp_pips": _f(60.0, 10.0, 300.0),
            "min_confluence": _i(50, 30, 95, risk="down"),
            "default_rr": _f(1.8, 1.0, 4.0),
            "one_active_trade": _b(True, risk="false_riskier"),
            "reject_cooldown_minutes": _i(15, 0, 120),
        },
        "filters": {
            "dxy": {"enabled": _b(True, risk="false_riskier")},
            "news": {
                "enabled": _b(True, risk="false_riskier"),
                "blackout_minutes": _i(15, 0, 120, risk="down"),
            },
            # Fast Impulse Detector: three consecutive high-momentum candles (or one shock candle larger than
            # shock_atr x ATR) restrict the mean-reversion engine (Range Bounce) from counter-trend entries for
            # min_hours (a run) to max_hours (a shock candle).
            "impulse": {
                "mode": _layer_mode(),
                "consecutive": _i(3, 2, 6, risk="up"),
                "min_body_ratio": _f(0.60, 0.3, 0.95, risk="up"),
                "min_body_atr": _f(0.70, 0.2, 2.0, risk="up"),
                "shock_atr": _f(3.0, 1.5, 8.0, risk="up"),
                "min_hours": _f(2.0, 0.5, 6.0, risk="down"),
                "max_hours": _f(4.0, 0.5, 8.0, risk="down"),
            },
            # Volatility & Chaos Filter: current candle range / spread against the median of the same
            # time-of-day slot over the last baseline_days days. Stress pauses every engine for pause_minutes.
            "chaos": {
                "mode": _layer_mode(),
                "range_mult": _f(3.0, 1.5, 10.0, risk="up"),
                "spread_mult": _f(3.0, 1.5, 10.0, risk="up"),
                "baseline_days": _i(20, 5, 20),
                "pause_minutes": _i(15, 5, 120, risk="down"),
            },
        },
        "engines": {eid: _engine_spec(eid, i, engine_params[eid]) for i, eid in enumerate(ENGINE_IDS)},
    }


SPEC: Dict[str, Any] = _build_spec()


def _is_leaf(node: Any) -> bool:
    return isinstance(node, dict) and isinstance(node.get("type"), str)


def _walk_spec(node: Any, prefix: str = ""):
    for key, child in node.items():
        path = f"{prefix}.{key}" if prefix else key
        if _is_leaf(child):
            yield path, child
        else:
            yield from _walk_spec(child, path)


FLAT_SPEC: Dict[str, Dict[str, Any]] = dict(_walk_spec(SPEC))


def _defaults_from_spec(node: Any) -> Any:
    if _is_leaf(node):
        return node["default"]
    return {k: _defaults_from_spec(v) for k, v in node.items()}


def default_config() -> Dict[str, Any]:
    cfg = _defaults_from_spec(SPEC)
    cfg.update(
        {
            "schema_version": SCHEMA_VERSION,
            "revision": 1,
            "updated_at": _now_iso(),
            "updated_by": "init",
            "account_fingerprint": "",
        }
    )
    return cfg


def bounds() -> Dict[str, Any]:
    """Read-only limits served to the UI so its sliders/validation match."""
    out: Dict[str, Any] = {}
    for path, spec in FLAT_SPEC.items():
        entry: Dict[str, Any] = {"type": spec["type"], "nullable": spec["nullable"]}
        if spec["type"] in ("float", "int"):
            entry["min"], entry["max"] = spec["min"], spec["max"]
        if spec["type"] == "enum":
            entry["values"] = spec["values"]
        if path.endswith(".magic"):
            entry["read_only"] = True
        out[path] = entry
    return out


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Flatten / validate / diff helpers
# ---------------------------------------------------------------------------
def _flatten(node: Any, prefix: str = "") -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    if isinstance(node, dict):
        for k, v in node.items():
            path = f"{prefix}.{k}" if prefix else k
            out.update(_flatten(v, path))
    else:
        out[prefix] = node
    return out


def _get_path(cfg: Dict[str, Any], path: str) -> Any:
    cur: Any = cfg
    for part in path.split("."):
        cur = cur[part]
    return cur


def _set_path(cfg: Dict[str, Any], path: str, value: Any) -> None:
    parts = path.split(".")
    cur = cfg
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
    cur[parts[-1]] = value


def _coerce(path: str, spec: Dict[str, Any], value: Any) -> Tuple[Any, Optional[str]]:
    if value is None:
        return (None, None) if spec["nullable"] else (None, f"{path}: null is not allowed")
    kind = spec["type"]
    if kind == "bool":
        return (value, None) if isinstance(value, bool) else (None, f"{path}: must be true/false")
    if kind in ("int", "float"):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None, f"{path}: must be a number"
        if isinstance(value, float) and not math.isfinite(value):
            return None, f"{path}: must be a finite number"
        if kind == "int":
            if isinstance(value, float):
                if not value.is_integer():
                    return None, f"{path}: must be a whole number"
                value = int(value)
        else:
            value = float(value)
        if spec["min"] is not None and value < spec["min"]:
            return None, f"{path}: {value} is below the hard minimum {spec['min']}"
        if spec["max"] is not None and value > spec["max"]:
            return None, f"{path}: {value} is above the hard maximum {spec['max']}"
        return value, None
    if kind == "enum":
        if value in spec["values"]:
            return value, None
        return None, f"{path}: must be one of {spec['values']}"
    return None, f"{path}: unsupported type"


def _validate_full(cfg: Dict[str, Any]) -> Tuple[Dict[str, Any], List[str], List[str]]:
    """Returns (normalised config, errors, warnings)."""
    errors: List[str] = []
    warnings: List[str] = []
    out = copy.deepcopy(cfg)

    for path, spec in FLAT_SPEC.items():
        try:
            raw = _get_path(cfg, path)
        except (KeyError, TypeError):
            errors.append(f"{path}: missing")
            continue
        value, err = _coerce(path, spec, raw)
        if err:
            errors.append(err)
        else:
            _set_path(out, path, value)

    if errors:
        return out, errors, warnings

    tr, al = out["trade_rules"], out["account_limits"]
    if tr["min_sl_pips"] >= tr["max_sl_pips"]:
        errors.append("trade_rules: min_sl_pips must be below max_sl_pips")
    if al["min_lot"] > al["max_lot"]:
        errors.append("account_limits: min_lot must not exceed max_lot")
    if al["lot_mode"] == "fixed" and not (al["min_lot"] - 1e-9 <= al["fixed_lot_size"] <= al["max_lot"] + 1e-9):
        errors.append("account_limits: fixed_lot_size must be between min_lot and max_lot")

    priorities = sorted(e["priority"] for e in out["engines"].values())
    if priorities != list(range(1, len(ENGINE_IDS) + 1)):
        errors.append(f"engines: priority values must be a permutation of 1..{len(ENGINE_IDS)}")

    bo = out["engines"]["breakout"]["params"]
    if bo["min_body_atr"] >= bo["max_body_atr"]:
        errors.append("engines.breakout.params: min_body_atr must be below max_body_atr")

    imp = out["filters"]["impulse"]
    if imp["min_hours"] > imp["max_hours"]:
        errors.append("filters.impulse: min_hours must not exceed max_hours")

    magics = [e["magic"] for e in out["engines"].values()]
    if len(set(magics)) != len(magics):
        errors.append("engines: magic numbers must be unique")

    if tr["default_rr"] * tr["min_sl_pips"] < tr["min_tp_pips"]:
        warnings.append(
            "trade_rules: default_rr x min_sl_pips is below min_tp_pips, so the tightest "
            "stops can never reach the minimum take-profit and will be rejected"
        )
    return out, errors, warnings


def _check_patch_keys(patch: Any, spec_node: Any, prefix: str, errors: List[str]) -> None:
    if not isinstance(patch, dict):
        errors.append(f"{prefix or 'patch'}: must be an object")
        return
    for key, value in patch.items():
        path = f"{prefix}.{key}" if prefix else key
        if key in META_KEYS and not prefix:
            errors.append(f"{path}: read-only (managed by the bridge)")
            continue
        if key not in spec_node:
            errors.append(f"{path}: unknown setting")
            continue
        child = spec_node[key]
        if _is_leaf(child):
            if path.endswith(".magic"):
                errors.append(f"{path}: read-only")
            elif isinstance(value, dict):
                errors.append(f"{path}: must be a single value")
        else:
            _check_patch_keys(value, child, path, errors)


def _deep_merge(base: Dict[str, Any], patch: Dict[str, Any]) -> None:
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            _deep_merge(base[key], value)
        else:
            base[key] = value


def _effective(cfg: Dict[str, Any], path: str) -> Any:
    value = _get_path(cfg, path)
    if value is None and path.startswith("engines.") and path.endswith(".max_spread_pips"):
        return cfg["account_limits"]["max_spread_pips"]
    return value


def _risk_increasing_paths(old: Dict[str, Any], new: Dict[str, Any], changed: List[str]) -> List[str]:
    risky: List[str] = []
    for path in changed:
        spec = FLAT_SPEC.get(path)
        if spec is None or not spec.get("risk"):
            continue
        before, after = _effective(old, path), _effective(new, path)
        if before == after:
            continue
        rule = spec["risk"]
        if rule == "up" and after > before:
            risky.append(path)
        elif rule == "down" and after < before:
            risky.append(path)
        elif rule == "false_riskier" and before is True and after is False:
            risky.append(path)
        elif rule == "true_safer" and before is True and after is False:
            risky.append(path)
        elif rule == "order":
            values = spec["values"]
            if values.index(after) > values.index(before):
                risky.append(path)
    return risky


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------
class ConfigStore:
    def __init__(self, data_dir: Path | str) -> None:
        self.dir = Path(data_dir)
        self.dir.mkdir(parents=True, exist_ok=True)
        self.path = self.dir / "strategy_config.json"
        self.backup_dir = self.dir / "config_backups"
        self.backup_dir.mkdir(exist_ok=True)
        self.audit_path = self.dir / "config_audit.log"
        self._lock = threading.RLock()
        self._risk_increase_times: Deque[float] = deque()
        self.fingerprint_mismatch = False
        self._cfg: Dict[str, Any] = self._load()

    # ---- persistence ------------------------------------------------------
    def _read_valid(self, path: Path) -> Optional[Dict[str, Any]]:
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        if not isinstance(raw, dict):
            return None
        merged = default_config()
        merged_flat = _flatten({k: v for k, v in raw.items() if k not in META_KEYS})
        for p, v in merged_flat.items():
            if p in FLAT_SPEC:
                _set_path(merged, p, v)
        for key in META_KEYS:
            if key in raw:
                merged[key] = raw[key]
        normalised, errors, _ = _validate_full(merged)
        if errors:
            return None
        normalised["schema_version"] = SCHEMA_VERSION
        return normalised

    def _atomic_write(self, path: Path, cfg: Dict[str, Any]) -> None:
        tmp = path.with_suffix(path.suffix + ".tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2, sort_keys=False)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)

    def _save(self, cfg: Dict[str, Any]) -> None:
        self._atomic_write(self.path, cfg)
        self._atomic_write(self.backup_dir / f"rev-{cfg['revision']:06d}.json", cfg)
        backups = sorted(self.backup_dir.glob("rev-*.json"))
        for stale in backups[:-MAX_BACKUPS]:
            try:
                stale.unlink()
            except OSError:
                pass

    def _load(self) -> Dict[str, Any]:
        if self.path.exists():
            cfg = self._read_valid(self.path)
            if cfg is not None:
                return cfg
            quarantined = self.path.with_name(f"strategy_config.invalid-{int(time.time())}.json")
            try:
                os.replace(self.path, quarantined)
            except OSError:
                pass
            self._audit({"action": "load_failed", "reason": f"invalid file moved to {quarantined.name}"})
            for backup in sorted(self.backup_dir.glob("rev-*.json"), reverse=True):
                cfg = self._read_valid(backup)
                if cfg is not None:
                    cfg["revision"] += 1
                    cfg["updated_by"] = "recovery"
                    cfg["updated_at"] = _now_iso()
                    self._save(cfg)
                    self._audit({"action": "recovered_from_backup", "revision": cfg["revision"]})
                    return cfg
        cfg = default_config()
        self._save(cfg)
        self._audit({"action": "init", "revision": cfg["revision"]})
        return cfg

    def _audit(self, entry: Dict[str, Any]) -> None:
        record = {"ts": _now_iso(), **entry}
        try:
            with open(self.audit_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(record) + "\n")
        except OSError:
            pass

    def record(self, entry: Dict[str, Any]) -> None:
        """Append a non-config event (e.g. a position close) to the audit log."""
        self._audit(entry)

    # ---- read API ---------------------------------------------------------
    @property
    def revision(self) -> int:
        with self._lock:
            return int(self._cfg["revision"])

    def snapshot(self) -> Dict[str, Any]:
        with self._lock:
            return copy.deepcopy(self._cfg)

    def public(self) -> Dict[str, Any]:
        with self._lock:
            return {
                "config": copy.deepcopy(self._cfg),
                "bounds": bounds(),
                "revision": self._cfg["revision"],
                "schema_version": SCHEMA_VERSION,
                "meta": {
                    "fingerprint_mismatch": self.fingerprint_mismatch,
                    "enforced_by_bridge": ENFORCED_BY_BRIDGE,
                    "risk_increases_per_hour": RISK_INCREASES_PER_HOUR,
                },
            }

    def audit_tail(self, limit: int = 50) -> List[Dict[str, Any]]:
        try:
            lines = self.audit_path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return []
        out: List[Dict[str, Any]] = []
        for line in lines[-max(1, min(limit, 500)):]:
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
        return out

    # ---- write API --------------------------------------------------------
    def update(
        self,
        patch: Dict[str, Any],
        base_revision: int,
        updated_by: str = "app",
        confirm_risk_increase: bool = False,
        remote: Optional[str] = None,
        action: str = "update",
    ) -> Dict[str, Any]:
        with self._lock:
            return self._apply(patch, base_revision, updated_by, confirm_risk_increase, remote, action)

    def restore(
        self,
        revision: int,
        base_revision: int,
        updated_by: str = "app",
        confirm_risk_increase: bool = False,
        remote: Optional[str] = None,
    ) -> Dict[str, Any]:
        with self._lock:
            source = self.backup_dir / f"rev-{int(revision):06d}.json"
            cfg = self._read_valid(source) if source.exists() else None
            if cfg is None:
                raise ConfigError(404, "backup_not_found", f"No valid backup for revision {revision}")
            patch = {k: v for k, v in cfg.items() if k not in META_KEYS}
            _strip_magic(patch)
            return self._apply(patch, base_revision, updated_by, confirm_risk_increase, remote, "restore")

    def _reject(self, error: ConfigError, updated_by: str, remote: Optional[str], action: str) -> ConfigError:
        self._audit(
            {
                "action": "rejected",
                "attempted": action,
                "code": error.code,
                "by": updated_by,
                "ip": remote,
                "detail": error.message,
            }
        )
        return error

    def _apply(
        self,
        patch: Dict[str, Any],
        base_revision: int,
        updated_by: str,
        confirm_risk_increase: bool,
        remote: Optional[str],
        action: str,
    ) -> Dict[str, Any]:
        if base_revision != self._cfg["revision"]:
            raise ConfigError(
                409,
                "stale_revision",
                "Config changed since you loaded it — reload and re-apply your edit.",
                {"current_revision": self._cfg["revision"]},
            )

        key_errors: List[str] = []
        _check_patch_keys(patch, SPEC, "", key_errors)
        if key_errors:
            raise self._reject(
                ConfigError(400, "invalid_patch", "Patch rejected", {"errors": key_errors}), updated_by, remote, action
            )

        candidate = copy.deepcopy(self._cfg)
        _deep_merge(candidate, patch)
        normalised, errors, warnings = _validate_full(candidate)
        if errors:
            raise self._reject(
                ConfigError(400, "validation_failed", "Config rejected", {"errors": errors}), updated_by, remote, action
            )

        old_flat = _flatten({k: v for k, v in self._cfg.items() if k not in META_KEYS})
        new_flat = _flatten({k: v for k, v in normalised.items() if k not in META_KEYS})
        changed = sorted(p for p in new_flat if new_flat[p] != old_flat.get(p))
        if not changed:
            return {"changed": [], "risk_increasing": [], "warnings": warnings, "revision": self._cfg["revision"]}

        risky = _risk_increasing_paths(self._cfg, normalised, changed)
        if risky:
            if not confirm_risk_increase:
                raise self._reject(
                    ConfigError(
                        428,
                        "confirmation_required",
                        "These changes increase account risk — resend with confirm_risk_increase=true.",
                        {"risk_increasing": risky},
                    ),
                    updated_by,
                    remote,
                    action,
                )
            now = time.time()
            while self._risk_increase_times and now - self._risk_increase_times[0] > 3600:
                self._risk_increase_times.popleft()
            if len(self._risk_increase_times) >= RISK_INCREASES_PER_HOUR:
                raise self._reject(
                    ConfigError(
                        429,
                        "risk_increase_rate_limited",
                        f"At most {RISK_INCREASES_PER_HOUR} risk-increasing changes per hour.",
                        {"risk_increasing": risky},
                    ),
                    updated_by,
                    remote,
                    action,
                )
            self._risk_increase_times.append(now)

        normalised["revision"] = self._cfg["revision"] + 1
        normalised["updated_at"] = _now_iso()
        normalised["updated_by"] = updated_by
        normalised["schema_version"] = SCHEMA_VERSION
        normalised["account_fingerprint"] = self._cfg.get("account_fingerprint", "")
        self._save(normalised)

        changes = [{"path": p, "old": old_flat.get(p), "new": new_flat[p]} for p in changed]
        self._audit(
            {
                "action": action,
                "revision": normalised["revision"],
                "by": updated_by,
                "ip": remote,
                "changes": changes,
                "risk_increasing": risky,
                "confirmed": bool(risky and confirm_risk_increase),
            }
        )
        self._cfg = normalised
        return {"changed": changes, "risk_increasing": risky, "warnings": warnings, "revision": normalised["revision"]}

    # ---- account fingerprint ---------------------------------------------
    def check_fingerprint(self, fingerprint: str) -> bool:
        """Records the MT5 login+server the first time it is seen; afterwards
        flags a mismatch (config tuned on a demo account being reused live)."""
        if not fingerprint:
            return self.fingerprint_mismatch
        with self._lock:
            stored = self._cfg.get("account_fingerprint", "")
            if not stored:
                self._cfg["account_fingerprint"] = fingerprint
                self._save(self._cfg)
                self._audit({"action": "fingerprint_set", "fingerprint": fingerprint})
                self.fingerprint_mismatch = False
            elif stored != fingerprint:
                if not self.fingerprint_mismatch:
                    self._audit({"action": "fingerprint_mismatch", "stored": stored, "current": fingerprint})
                self.fingerprint_mismatch = True
            else:
                self.fingerprint_mismatch = False
            return self.fingerprint_mismatch

    def acknowledge_account(self, fingerprint: str, updated_by: str = "app", remote: Optional[str] = None) -> None:
        with self._lock:
            self._cfg["account_fingerprint"] = fingerprint
            self._save(self._cfg)
            self.fingerprint_mismatch = False
            self._audit({"action": "fingerprint_acknowledged", "fingerprint": fingerprint, "by": updated_by, "ip": remote})


def _strip_magic(patch: Dict[str, Any]) -> None:
    for engine in patch.get("engines", {}).values():
        engine.pop("magic", None)
