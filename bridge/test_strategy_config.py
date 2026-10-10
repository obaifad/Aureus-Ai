import json
import tempfile
import unittest
from pathlib import Path

import strategy_config as sc
from strategy_config import ConfigError, ConfigStore


def new_store():
    tmp = tempfile.TemporaryDirectory()
    return tmp, ConfigStore(Path(tmp.name))


class DefaultsAndBounds(unittest.TestCase):
    def test_defaults_are_valid(self):
        _, errors, _ = sc._validate_full(sc.default_config())
        self.assertEqual(errors, [])

    def test_every_engine_has_a_unique_magic_and_priority(self):
        cfg = sc.default_config()
        engines = cfg["engines"]
        self.assertEqual(set(engines), set(sc.ENGINE_IDS))
        self.assertEqual(len({e["magic"] for e in engines.values()}), 6)
        self.assertEqual(sorted(e["priority"] for e in engines.values()), [1, 2, 3, 4, 5, 6])
        ranked = sorted(engines, key=lambda k: engines[k]["priority"])
        self.assertEqual(ranked, ["htf_retest", "ict", "ici", "range_bounce", "orb", "breakout"])

    def test_range_bounce_and_the_asia_orb_are_dxy_exempt_by_default(self):
        cfg = sc.default_config()
        self.assertEqual(cfg["engines"]["range_bounce"]["dxy"], "exempt")
        self.assertEqual(cfg["engines"]["orb"]["dxy"], "exempt")
        for engine in ("htf_retest", "ict", "ici", "breakout"):
            self.assertEqual(cfg["engines"][engine]["dxy"], "block", engine)

    def test_bounds_expose_limits_for_the_ui(self):
        b = sc.bounds()
        self.assertEqual(b["account_limits.risk_percent_per_trade"]["max"], 2.0)
        self.assertTrue(b["engines.orb.magic"]["read_only"])
        self.assertIn("auto", b["mode.auto_trade"]["values"])


class MarketSafetyLayers(unittest.TestCase):
    """Fast-impulse guard, chaos filter and ICT sweep alignment (2026-10-07)."""

    LAYER_MODES = ("filters.impulse.mode", "filters.chaos.mode", "engines.ict.params.sweep_mode")

    def setUp(self):
        self.tmp, self.store = new_store()
        self.addCleanup(self.tmp.cleanup)

    def update(self, patch, **kw):
        return self.store.update(patch, base_revision=self.store.revision, **kw)

    def test_every_layer_defaults_to_shadow_so_nothing_is_blocked_until_verified(self):
        cfg = sc.default_config()
        self.assertEqual(cfg["filters"]["impulse"]["mode"], "shadow")
        self.assertEqual(cfg["filters"]["chaos"]["mode"], "shadow")
        self.assertEqual(cfg["engines"]["ict"]["params"]["sweep_mode"], "shadow")

    def test_defaults_match_the_specification(self):
        cfg = sc.default_config()
        imp, chaos, ict = cfg["filters"]["impulse"], cfg["filters"]["chaos"], cfg["engines"]["ict"]["params"]
        self.assertEqual((imp["consecutive"], imp["shock_atr"]), (3, 3.0))
        self.assertEqual((imp["min_hours"], imp["max_hours"]), (2.0, 4.0))
        self.assertEqual(chaos["baseline_days"], 20)
        self.assertEqual((chaos["range_mult"], chaos["spread_mult"]), (3.0, 3.0))
        self.assertEqual(ict["sweep_range_lookback"], 48)
        _, errors, _ = sc._validate_full(cfg)
        self.assertEqual(errors, [])

    def test_modes_offer_block_shadow_off_and_the_ui_gets_the_bounds(self):
        b = sc.bounds()
        for path in self.LAYER_MODES:
            with self.subTest(path):
                self.assertEqual(b[path]["values"], ["block", "shadow", "off"])
        self.assertEqual((b["filters.chaos.baseline_days"]["min"], b["filters.chaos.baseline_days"]["max"]), (5, 20))
        self.assertEqual(b["filters.impulse.shock_atr"]["type"], "float")

    def test_a_config_saved_before_the_layers_existed_loads_with_defaults_and_keeps_its_risk_settings(self):
        # What production's rev-12 file looked like: auto mode, fixed 0.1 lot, 5% daily loss, no layers.
        self.update(
            {
                "mode": {"auto_trade": "auto"},
                "account_limits": {
                    "lot_mode": "fixed",
                    "fixed_lot_size": 0.1,
                    "max_daily_loss_percent": 5.0,
                    "max_lot": 1.0,
                    "risk_percent_per_trade": 2.0,
                },
            },
            confirm_risk_increase=True,
        )
        raw = json.loads(self.store.path.read_text(encoding="utf-8"))
        del raw["filters"]["impulse"], raw["filters"]["chaos"]
        for key in ("sweep_mode", "sweep_range_lookback", "sweep_min_range_atr", "sweep_boundary_atr", "sweep_max_efficiency"):
            del raw["engines"]["ict"]["params"][key]
        del raw["account_limits"]["entry_drift_chase_r"]
        self.store.path.write_text(json.dumps(raw), encoding="utf-8")

        cfg = ConfigStore(self.store.dir).snapshot()
        self.assertEqual(cfg["filters"]["impulse"]["mode"], "shadow")
        self.assertEqual(cfg["filters"]["chaos"]["mode"], "shadow")
        self.assertEqual(cfg["engines"]["ict"]["params"]["sweep_mode"], "shadow")
        al = cfg["account_limits"]
        self.assertEqual(cfg["mode"]["auto_trade"], "auto")
        self.assertEqual((al["lot_mode"], al["fixed_lot_size"]), ("fixed", 0.1))
        self.assertEqual(al["max_daily_loss_percent"], 5.0)
        self.assertEqual(al["entry_drift_chase_r"], 0.25)

    def test_turning_a_layer_on_is_free_and_turning_it_down_needs_confirmation(self):
        for path in self.LAYER_MODES:
            with self.subTest(path):
                patch = _nest(path, "block")
                self.update(patch)  # shadow -> block tightens: no confirmation
                with self.assertRaises(ConfigError) as ctx:
                    self.update(_nest(path, "shadow"))
                self.assertEqual(ctx.exception.code, "confirmation_required")
                self.assertIn(path, ctx.exception.extra["risk_increasing"])
                self.update(_nest(path, "shadow"), confirm_risk_increase=True)

    def test_switching_a_layer_off_from_shadow_is_risk_increasing(self):
        with self.assertRaises(ConfigError) as ctx:
            self.update({"filters": {"chaos": {"mode": "off"}}})
        self.assertEqual(ctx.exception.code, "confirmation_required")

    def test_an_unknown_mode_is_rejected(self):
        for patch in (
            {"filters": {"impulse": {"mode": "enforce"}}},
            {"filters": {"chaos": {"mode": True}}},
            {"engines": {"ict": {"params": {"sweep_mode": "strict"}}}},
        ):
            with self.subTest(patch=patch):
                with self.assertRaises(ConfigError) as ctx:
                    self.update(patch, confirm_risk_increase=True)
                self.assertEqual(ctx.exception.code, "validation_failed")

    def test_values_outside_the_hard_bounds_are_rejected(self):
        for patch in (
            {"filters": {"chaos": {"baseline_days": 25}}},
            {"filters": {"chaos": {"baseline_days": 2}}},
            {"filters": {"impulse": {"consecutive": 1}}},
            {"filters": {"impulse": {"shock_atr": 0.5}}},
            {"filters": {"impulse": {"max_hours": 24}}},
            {"engines": {"ict": {"params": {"sweep_max_efficiency": 1.5}}}},
            {"engines": {"ict": {"params": {"sweep_range_lookback": 5}}}},
        ):
            with self.subTest(patch=patch):
                with self.assertRaises(ConfigError) as ctx:
                    self.update(patch, confirm_risk_increase=True)
                self.assertEqual(ctx.exception.code, "validation_failed")

    def test_the_restriction_window_cannot_end_before_it_starts(self):
        with self.assertRaises(ConfigError) as ctx:
            self.update({"filters": {"impulse": {"min_hours": 5.0, "max_hours": 3.0}}}, confirm_risk_increase=True)
        self.assertIn("min_hours", " ".join(ctx.exception.extra["errors"]))

    def test_loosening_a_layer_threshold_needs_confirmation_but_tightening_does_not(self):
        for path, tighter, looser in [
            ("filters.impulse.shock_atr", 2.0, 5.0),
            ("filters.impulse.min_hours", 3.0, 1.0),
            ("filters.chaos.range_mult", 2.0, 6.0),
            ("filters.chaos.pause_minutes", 30, 10),
            ("engines.ict.params.sweep_boundary_atr", 0.3, 1.2),
            ("engines.ict.params.sweep_min_range_atr", 3.0, 1.0),
        ]:
            with self.subTest(path):
                self.update(_nest(path, tighter), confirm_risk_increase=True)
                with self.assertRaises(ConfigError) as ctx:
                    self.update(_nest(path, looser))
                self.assertEqual(ctx.exception.code, "confirmation_required")
                self.assertIn(path, ctx.exception.extra["risk_increasing"])

    def test_changing_a_layer_never_touches_the_risk_settings(self):
        before = self.store.snapshot()
        self.update({"filters": {"impulse": {"mode": "block"}, "chaos": {"mode": "block"}}})
        after = self.store.snapshot()
        for section in ("mode", "account_limits", "trade_rules"):
            self.assertEqual(after[section], before[section], section)
        self.assertEqual(after["filters"]["dxy"], before["filters"]["dxy"])


class RangeBounceLateSession(unittest.TestCase):
    """Range Bounce's late-session no-entry window (2026-10-07)."""

    def setUp(self):
        self.tmp, self.store = new_store()
        self.addCleanup(self.tmp.cleanup)

    def update(self, patch, **kw):
        return self.store.update(patch, base_revision=self.store.revision, **kw)

    def test_the_window_ships_off_with_hard_bounds(self):
        params = sc.default_config()["engines"]["range_bounce"]["params"]
        self.assertEqual((params["block_start_utc"], params["block_end_utc"]), (24, 24))  # start >= end = off
        b = sc.bounds()
        for key in ("block_start_utc", "block_end_utc"):
            self.assertEqual((b[f"engines.range_bounce.params.{key}"]["min"], b[f"engines.range_bounce.params.{key}"]["max"]), (0, 24))

    def test_hours_outside_a_day_are_rejected(self):
        for patch in ({"block_start_utc": -1}, {"block_end_utc": 25}, {"block_start_utc": 17.5}, {"block_end_utc": "24"}):
            with self.subTest(patch=patch):
                with self.assertRaises(ConfigError) as ctx:
                    self.update({"engines": {"range_bounce": {"params": patch}}}, confirm_risk_increase=True)
                self.assertEqual(ctx.exception.code, "validation_failed")

    def test_switching_it_on_or_widening_is_free_and_shrinking_or_switching_it_off_needs_confirmation(self):
        # switching it on = lowering the start below the end: a safer engine, no confirmation
        self.update({"engines": {"range_bounce": {"params": {"block_start_utc": 15}}}})
        for patch, path in (
            ({"block_start_utc": 20}, "block_start_utc"),  # starts later: a smaller window
            ({"block_end_utc": 22}, "block_end_utc"),  # ends earlier: a smaller window
        ):
            with self.subTest(patch=patch):
                with self.assertRaises(ConfigError) as ctx:
                    self.update({"engines": {"range_bounce": {"params": patch}}})
                self.assertEqual(ctx.exception.code, "confirmation_required")
                self.assertIn(f"engines.range_bounce.params.{path}", ctx.exception.extra["risk_increasing"])

    def test_a_config_saved_before_the_window_existed_loads_with_it_off(self):
        import json

        raw = json.loads(self.store.path.read_text(encoding="utf-8"))
        del raw["engines"]["range_bounce"]["params"]["block_start_utc"]
        del raw["engines"]["range_bounce"]["params"]["block_end_utc"]
        self.store.path.write_text(json.dumps(raw), encoding="utf-8")
        params = sc.ConfigStore(self.store.dir).snapshot()["engines"]["range_bounce"]["params"]
        self.assertEqual((params["block_start_utc"], params["block_end_utc"]), (24, 24))


class AsiaOrb(unittest.TestCase):
    """The ORB engine rebuilt as the Asia ORB (2026-10-09): the London/New York switches and the 4H filter are gone."""

    def setUp(self):
        self.tmp, self.store = new_store()
        self.addCleanup(self.tmp.cleanup)

    def update(self, patch, **kw):
        return self.store.update(patch, base_revision=self.store.revision, **kw)

    def test_only_the_stop_and_target_overrides_remain(self):
        params = sc.default_config()["engines"]["orb"]["params"]
        self.assertEqual(set(params), {"sl_pips_override", "tp_pips_override"})
        self.assertEqual((params["sl_pips_override"], params["tp_pips_override"]), (0.0, 0.0))

    def test_it_keeps_its_place_as_engine_5(self):
        self.assertEqual(sc.default_config()["engines"]["orb"]["priority"], 5)

    def test_the_old_settings_are_rejected_as_unknown(self):
        for key, value in (("london_enabled", False), ("newyork_enabled", False), ("htf_mode", "off")):
            with self.assertRaises(ConfigError) as ctx:
                self.update({"engines": {"orb": {"params": {key: value}}}})
            self.assertIn("unknown setting", str(ctx.exception.extra) + ctx.exception.message)

    def test_a_config_saved_with_the_old_orb_settings_still_loads(self):
        import json

        raw = json.loads(self.store.path.read_text(encoding="utf-8"))
        raw["engines"]["orb"]["params"].update({"london_enabled": True, "newyork_enabled": True, "htf_mode": "block"})
        raw["engines"]["orb"]["enabled"] = False
        self.store.path.write_text(json.dumps(raw), encoding="utf-8")
        snap = sc.ConfigStore(self.store.dir).snapshot()
        self.assertEqual(set(snap["engines"]["orb"]["params"]), {"sl_pips_override", "tp_pips_override"})
        self.assertFalse(snap["engines"]["orb"]["enabled"], "everything else in the saved file is kept")


class RangeBounceHotVolatility(unittest.TestCase):
    """Range Bounce's hot-volatility gate (2026-10-07)."""

    PATH = "engines.range_bounce.params.max_atr_ratio"

    def setUp(self):
        self.tmp, self.store = new_store()
        self.addCleanup(self.tmp.cleanup)

    def update(self, patch, **kw):
        return self.store.update(patch, base_revision=self.store.revision, **kw)

    def patch(self, value):
        return {"engines": {"range_bounce": {"params": {"max_atr_ratio": value}}}}

    def test_the_limit_defaults_to_1_2_with_hard_bounds(self):
        self.assertEqual(sc.default_config()["engines"]["range_bounce"]["params"]["max_atr_ratio"], 1.2)
        b = sc.bounds()[self.PATH]
        self.assertEqual((b["type"], b["min"], b["max"]), ("float", 1.0, 10.0))

    def test_values_outside_the_bounds_are_rejected(self):
        for bad in (0.5, 0.99, 10.5, "1.2", True):
            with self.subTest(bad=bad):
                with self.assertRaises(ConfigError) as ctx:
                    self.update(self.patch(bad), confirm_risk_increase=True)
                self.assertEqual(ctx.exception.code, "validation_failed")

    def test_tightening_is_free_and_loosening_needs_confirmation(self):
        self.update(self.patch(1.1))  # a stricter gate: no confirmation
        with self.assertRaises(ConfigError) as ctx:
            self.update(self.patch(1.5))
        self.assertEqual(ctx.exception.code, "confirmation_required")
        self.assertIn(self.PATH, ctx.exception.extra["risk_increasing"])
        self.update(self.patch(1.5), confirm_risk_increase=True)
        self.assertEqual(self.store.snapshot()["engines"]["range_bounce"]["params"]["max_atr_ratio"], 1.5)

    def test_switching_the_gate_off_in_practice_needs_confirmation(self):
        with self.assertRaises(ConfigError) as ctx:
            self.update(self.patch(10.0))
        self.assertEqual(ctx.exception.code, "confirmation_required")

    def test_a_config_saved_before_the_gate_existed_loads_with_it_on(self):
        import json

        raw = json.loads(self.store.path.read_text(encoding="utf-8"))
        del raw["engines"]["range_bounce"]["params"]["max_atr_ratio"]
        self.store.path.write_text(json.dumps(raw), encoding="utf-8")
        self.assertEqual(sc.ConfigStore(self.store.dir).snapshot()["engines"]["range_bounce"]["params"]["max_atr_ratio"], 1.2)


class RangeBounceFreshMove(unittest.TestCase):
    """Range Bounce's fresh-move gate (2026-10-08)."""

    PATH = "engines.range_bounce.params.max_fade_atr"

    def setUp(self):
        self.tmp, self.store = new_store()
        self.addCleanup(self.tmp.cleanup)

    def update(self, value, **kw):
        patch = {"engines": {"range_bounce": {"params": {"max_fade_atr": value}}}}
        return self.store.update(patch, base_revision=self.store.revision, **kw)

    def test_it_ships_off_with_hard_bounds(self):
        # 10 ATR is "off in practice": the gate lost money in every replay (see strategy_config.py)
        self.assertEqual(sc.default_config()["engines"]["range_bounce"]["params"]["max_fade_atr"], 10.0)
        b = sc.bounds()[self.PATH]
        self.assertEqual((b["type"], b["min"], b["max"]), ("float", 1.0, 10.0))

    def test_out_of_bounds_values_are_rejected(self):
        for bad in (0.5, 10.5, "3", True):
            with self.subTest(bad=bad):
                with self.assertRaises(ConfigError) as ctx:
                    self.update(bad, confirm_risk_increase=True)
                self.assertEqual(ctx.exception.code, "validation_failed")

    def test_switching_it_on_is_free_and_loosening_it_again_needs_confirmation(self):
        self.update(3.0)  # from off (10) to a 3 ATR limit tightens the engine: no confirmation
        with self.assertRaises(ConfigError) as ctx:
            self.update(5.0)
        self.assertEqual(ctx.exception.code, "confirmation_required")
        self.assertIn(self.PATH, ctx.exception.extra["risk_increasing"])

    def test_a_config_saved_before_the_gate_existed_loads_with_it_off(self):
        import json

        raw = json.loads(self.store.path.read_text(encoding="utf-8"))
        del raw["engines"]["range_bounce"]["params"]["max_fade_atr"]
        self.store.path.write_text(json.dumps(raw), encoding="utf-8")
        self.assertEqual(sc.ConfigStore(self.store.dir).snapshot()["engines"]["range_bounce"]["params"]["max_fade_atr"], 10.0)


def _nest(path, value):
    out = node = {}
    parts = path.split(".")
    for part in parts[:-1]:
        node[part] = {}
        node = node[part]
    node[parts[-1]] = value
    return out


class Updates(unittest.TestCase):
    def setUp(self):
        self.tmp, self.store = new_store()
        self.addCleanup(self.tmp.cleanup)

    def update(self, patch, **kw):
        return self.store.update(patch, base_revision=self.store.revision, **kw)

    def test_update_bumps_revision_and_persists(self):
        before = self.store.revision
        result = self.update({"trade_rules": {"min_confluence": 60}})
        self.assertEqual(result["revision"], before + 1)
        reloaded = ConfigStore(Path(self.tmp.name))
        self.assertEqual(reloaded.snapshot()["trade_rules"]["min_confluence"], 60)
        self.assertEqual(reloaded.revision, before + 1)

    def test_noop_update_does_not_bump_revision(self):
        before = self.store.revision
        result = self.update({"trade_rules": {"min_confluence": 50}})
        self.assertEqual(result["changed"], [])
        self.assertEqual(self.store.revision, before)

    def test_stale_base_revision_is_rejected_with_409(self):
        with self.assertRaises(ConfigError) as ctx:
            self.store.update({"trade_rules": {"min_confluence": 60}}, base_revision=self.store.revision - 1 or 999)
        self.assertEqual(ctx.exception.status, 409)
        self.assertEqual(ctx.exception.code, "stale_revision")

    def test_two_editors_second_one_loses(self):
        base = self.store.revision
        self.store.update({"trade_rules": {"min_confluence": 55}}, base_revision=base, updated_by="app")
        with self.assertRaises(ConfigError) as ctx:
            self.store.update({"trade_rules": {"min_confluence": 65}}, base_revision=base, updated_by="telegram")
        self.assertEqual(ctx.exception.status, 409)

    def test_unknown_key_rejected(self):
        with self.assertRaises(ConfigError) as ctx:
            self.update({"trade_rules": {"nonsense": 1}})
        self.assertEqual(ctx.exception.status, 400)

    def test_hard_bounds_enforced(self):
        for patch in (
            {"account_limits": {"risk_percent_per_trade": 50}},
            {"account_limits": {"max_daily_loss_percent": 0}},
            {"trade_rules": {"min_confluence": 5}},
            {"account_limits": {"max_open_positions": 10}},
        ):
            with self.subTest(patch=patch):
                with self.assertRaises(ConfigError) as ctx:
                    self.update(patch, confirm_risk_increase=True)
                self.assertEqual(ctx.exception.code, "validation_failed")

    def test_type_checks(self):
        for patch in (
            {"mode": {"paused": "yes"}},
            {"account_limits": {"max_lot": True}},
            {"account_limits": {"risk_percent_per_trade": "1"}},
            {"mode": {"auto_trade": "turbo"}},
            {"account_limits": {"max_open_positions": 1.5}},
        ):
            with self.subTest(patch=patch):
                with self.assertRaises(ConfigError):
                    self.update(patch, confirm_risk_increase=True)

    def test_whole_number_float_accepted_for_int_field(self):
        self.update({"trade_rules": {"min_confluence": 60.0}})
        self.assertEqual(self.store.snapshot()["trade_rules"]["min_confluence"], 60)

    def test_meta_and_magic_are_read_only(self):
        for patch in ({"revision": 99}, {"updated_by": "x"}, {"engines": {"orb": {"magic": 1}}}):
            with self.subTest(patch=patch):
                with self.assertRaises(ConfigError) as ctx:
                    self.update(patch)
                self.assertEqual(ctx.exception.status, 400)

    def test_cross_field_rules(self):
        with self.assertRaises(ConfigError):
            self.update({"trade_rules": {"min_sl_pips": 60.0, "max_sl_pips": 55.0}})
        with self.assertRaises(ConfigError):
            self.update({"account_limits": {"min_lot": 1.0, "max_lot": 0.5}})
        with self.assertRaises(ConfigError):
            self.update({"engines": {"breakout": {"params": {"min_body_atr": 2.0, "max_body_atr": 1.5}}}})

    def test_priority_must_stay_a_permutation(self):
        with self.assertRaises(ConfigError):
            self.update({"engines": {"orb": {"priority": 1}}})
        self.update({"engines": {"orb": {"priority": 1}, "htf_retest": {"priority": 5}}})
        snap = self.store.snapshot()["engines"]
        self.assertEqual((snap["orb"]["priority"], snap["htf_retest"]["priority"]), (1, 5))

    def test_nullable_override_can_be_set_and_cleared(self):
        self.update({"engines": {"orb": {"rr": 2.0}}})
        self.assertEqual(self.store.snapshot()["engines"]["orb"]["rr"], 2.0)
        self.update({"engines": {"orb": {"rr": None}}})
        self.assertIsNone(self.store.snapshot()["engines"]["orb"]["rr"])
        with self.assertRaises(ConfigError):
            self.update({"trade_rules": {"default_rr": None}})

    def test_warning_when_tp_floor_unreachable(self):
        result = self.update({"trade_rules": {"min_tp_pips": 100.0}})
        self.assertTrue(any("min_tp_pips" in w for w in result["warnings"]))


class RiskControl(unittest.TestCase):
    def setUp(self):
        self.tmp, self.store = new_store()
        self.addCleanup(self.tmp.cleanup)

    def update(self, patch, **kw):
        return self.store.update(patch, base_revision=self.store.revision, **kw)

    def test_tightening_needs_no_confirmation(self):
        result = self.update(
            {
                "account_limits": {"risk_percent_per_trade": 0.5, "max_spread_pips": 20.0},
                "filters": {"news": {"blackout_minutes": 30}},
                "trade_rules": {"min_confluence": 70},
            }
        )
        self.assertEqual(result["risk_increasing"], [])

    def test_loosening_requires_confirmation(self):
        self.update({"account_limits": {"risk_percent_per_trade": 0.5}})
        with self.assertRaises(ConfigError) as ctx:
            self.update({"account_limits": {"risk_percent_per_trade": 1.0}})
        self.assertEqual(ctx.exception.status, 428)
        self.assertIn("account_limits.risk_percent_per_trade", ctx.exception.extra["risk_increasing"])
        result = self.update({"account_limits": {"risk_percent_per_trade": 1.0}}, confirm_risk_increase=True)
        self.assertEqual(result["risk_increasing"], ["account_limits.risk_percent_per_trade"])

    def test_turning_a_filter_off_is_risk_increasing(self):
        with self.assertRaises(ConfigError) as ctx:
            self.update({"filters": {"dxy": {"enabled": False}}})
        self.assertEqual(ctx.exception.code, "confirmation_required")
        self.update({"filters": {"dxy": {"enabled": True}}})  # no change, no confirmation

    def test_loosening_an_engine_threshold_needs_confirmation_but_tightening_does_not(self):
        # Lower floors let weaker setups through; a wider entry window chases price.
        for engine, key, tighter, looser in [
            ("htf_retest", "min_rr", 2.0, 1.2),
            ("ict", "min_confluence_reversal", 80, 60),
            ("ici", "min_sl_pips", 40.0, 20.0),
            ("range_bounce", "min_rr", 1.5, 1.1),
            ("breakout", "max_entry_distance_atr", 0.5, 1.5),
        ]:
            with self.subTest(f"{engine}.{key}"):
                # the first move may be either direction from the default, so confirm it
                self.update({"engines": {engine: {"params": {key: tighter}}}}, confirm_risk_increase=True)
                # tightening (already applied above) needed no further confirmation; loosening does
                with self.assertRaises(ConfigError) as ctx:
                    self.update({"engines": {engine: {"params": {key: looser}}}})
                self.assertEqual(ctx.exception.code, "confirmation_required")
                self.assertIn(f"engines.{engine}.params.{key}", ctx.exception.extra["risk_increasing"])

    def test_the_late_approval_tolerance_defaults_on_and_widening_it_needs_confirmation(self):
        al = sc.default_config()["account_limits"]
        self.assertEqual(al["entry_drift_chase_r"], 0.25)
        self.assertEqual(
            (sc.bounds()["account_limits.entry_drift_chase_r"]["min"], sc.bounds()["account_limits.entry_drift_chase_r"]["max"]),
            (0.0, 0.5),
        )
        self.update({"account_limits": {"entry_drift_chase_r": 0.1}})  # narrowing is free
        self.update({"account_limits": {"entry_drift_chase_r": 0.0}})  # and so is switching it off
        with self.assertRaises(ConfigError) as ctx:
            self.update({"account_limits": {"entry_drift_chase_r": 0.4}})
        self.assertEqual(ctx.exception.code, "confirmation_required")
        self.assertIn("account_limits.entry_drift_chase_r", ctx.exception.extra["risk_increasing"])
        for bad in (-0.1, 0.51, 3.0):
            with self.assertRaises(ConfigError, msg=bad):
                self.update({"account_limits": {"entry_drift_chase_r": bad}}, confirm_risk_increase=True)

    def test_a_config_saved_before_the_tolerance_existed_loads_with_its_default(self):
        import json

        raw = json.loads(self.store.path.read_text(encoding="utf-8"))
        del raw["account_limits"]["entry_drift_chase_r"]
        self.store.path.write_text(json.dumps(raw), encoding="utf-8")
        reloaded = sc.ConfigStore(self.store.dir)
        self.assertEqual(reloaded.snapshot()["account_limits"]["entry_drift_chase_r"], 0.25)

    def test_a_threshold_outside_its_hard_bounds_is_rejected(self):
        with self.assertRaises(ConfigError) as ctx:
            self.update({"engines": {"breakout": {"params": {"min_body_atr": 9.0}}}}, confirm_risk_increase=True)
        self.assertEqual(ctx.exception.status, 400)

    def test_lot_mode_defaults_to_dynamic_with_a_one_hundredth_fixed_lot(self):
        al = sc.default_config()["account_limits"]
        self.assertEqual((al["lot_mode"], al["fixed_lot_size"]), ("dynamic", 0.01))

    def test_switching_to_a_fixed_lot_or_enlarging_it_is_risk_increasing(self):
        with self.assertRaises(ConfigError) as ctx:
            self.update({"account_limits": {"lot_mode": "fixed"}})
        self.assertEqual(ctx.exception.status, 428)
        self.assertIn("account_limits.lot_mode", ctx.exception.extra["risk_increasing"])
        self.update({"account_limits": {"lot_mode": "fixed"}}, confirm_risk_increase=True)
        self.update({"account_limits": {"fixed_lot_size": 0.02}}, confirm_risk_increase=True)
        with self.assertRaises(ConfigError):
            self.update({"account_limits": {"fixed_lot_size": 0.5}})
        self.update({"account_limits": {"fixed_lot_size": 0.01}})  # smaller is always free
        self.update({"account_limits": {"lot_mode": "dynamic"}})  # and so is going back

    def test_the_fixed_lot_must_sit_inside_the_hard_bounds(self):
        for bad in (0.0, 0.001, -1.0, 10.5):
            with self.assertRaises(ConfigError, msg=bad):
                self.update({"account_limits": {"fixed_lot_size": bad}}, confirm_risk_increase=True)

    def test_an_unknown_lot_mode_is_rejected(self):
        with self.assertRaises(ConfigError):
            self.update({"account_limits": {"lot_mode": "martingale"}}, confirm_risk_increase=True)

    def test_a_fixed_lot_must_fit_between_min_lot_and_max_lot(self):
        self.update({"account_limits": {"min_lot": 0.1, "max_lot": 1.0}}, confirm_risk_increase=True)
        with self.assertRaises(ConfigError) as ctx:  # below min_lot
            self.update({"account_limits": {"lot_mode": "fixed", "fixed_lot_size": 0.05}}, confirm_risk_increase=True)
        self.assertIn("fixed_lot_size must be between min_lot and max_lot", str(ctx.exception.extra))
        with self.assertRaises(ConfigError):  # above max_lot
            self.update({"account_limits": {"lot_mode": "fixed", "fixed_lot_size": 2.0}}, confirm_risk_increase=True)
        self.update({"account_limits": {"lot_mode": "fixed", "fixed_lot_size": 0.5}}, confirm_risk_increase=True)

    def test_max_lot_cannot_be_lowered_under_an_active_fixed_lot(self):
        self.update({"account_limits": {"lot_mode": "fixed", "fixed_lot_size": 1.0}}, confirm_risk_increase=True)
        with self.assertRaises(ConfigError):
            self.update({"account_limits": {"max_lot": 0.5}})

    def test_in_dynamic_mode_the_fixed_lot_is_not_checked_against_max_lot(self):
        self.update({"account_limits": {"fixed_lot_size": 1.0}}, confirm_risk_increase=True)
        self.update({"account_limits": {"max_lot": 0.5}})  # fine: the fixed lot is not in use

    def test_escalating_auto_trading_requires_confirmation_but_lowering_does_not(self):
        with self.assertRaises(ConfigError):
            self.update({"mode": {"auto_trade": "auto"}})
        self.update({"mode": {"auto_trade": "approval"}}, confirm_risk_increase=True)
        self.update({"mode": {"auto_trade": "off"}})

    def test_pausing_is_free_resuming_is_not(self):
        self.update({"mode": {"paused": True}})
        with self.assertRaises(ConfigError):
            self.update({"mode": {"paused": False}})
        self.update({"mode": {"paused": False}}, confirm_risk_increase=True)

    def test_engine_spread_override_compared_against_effective_value(self):
        self.update({"account_limits": {"max_spread_pips": 20.0}})
        # None -> 15 tightens the effective limit (20 -> 15): free.
        self.update({"engines": {"orb": {"max_spread_pips": 15.0}}})
        # 15 -> 25 loosens it: needs confirmation.
        with self.assertRaises(ConfigError):
            self.update({"engines": {"orb": {"max_spread_pips": 25.0}}})

    def test_dxy_mode_ordering(self):
        with self.assertRaises(ConfigError):
            self.update({"engines": {"ict": {"dxy": "off"}}})
        self.update({"engines": {"ict": {"dxy": "score"}}}, confirm_risk_increase=True)
        self.update({"engines": {"ict": {"dxy": "block"}}})

    def test_risk_increases_are_rate_limited(self):
        steps = [0.5, 0.6, 0.7, 0.8]
        self.update({"account_limits": {"risk_percent_per_trade": 0.1}})
        for value in steps[:3]:
            self.update({"account_limits": {"risk_percent_per_trade": value}}, confirm_risk_increase=True)
        with self.assertRaises(ConfigError) as ctx:
            self.update({"account_limits": {"risk_percent_per_trade": steps[3]}}, confirm_risk_increase=True)
        self.assertEqual(ctx.exception.status, 429)
        # Tightening is never rate limited.
        self.update({"account_limits": {"risk_percent_per_trade": 0.1}})


class PersistenceAndAudit(unittest.TestCase):
    def setUp(self):
        self.tmp, self.store = new_store()
        self.addCleanup(self.tmp.cleanup)

    def test_audit_records_changes_and_rejections(self):
        self.store.update({"trade_rules": {"min_confluence": 60}}, base_revision=self.store.revision, updated_by="app")
        with self.assertRaises(ConfigError):
            self.store.update({"mode": {"auto_trade": "auto"}}, base_revision=self.store.revision, updated_by="telegram")
        entries = self.store.audit_tail()
        actions = [e["action"] for e in entries]
        self.assertIn("update", actions)
        self.assertIn("rejected", actions)
        update = next(e for e in entries if e["action"] == "update")
        self.assertEqual(update["changes"], [{"path": "trade_rules.min_confluence", "old": 50, "new": 60}])
        self.assertEqual(update["by"], "app")

    def test_backups_are_pruned_to_the_limit(self):
        for i in range(sc.MAX_BACKUPS + 5):
            self.store.update(
                {"trade_rules": {"reject_cooldown_minutes": i % 100}},
                base_revision=self.store.revision,
            )
        backups = list(Path(self.tmp.name, "config_backups").glob("rev-*.json"))
        self.assertEqual(len(backups), sc.MAX_BACKUPS)

    def test_restore_rolls_back_to_an_earlier_revision(self):
        original = self.store.revision
        self.store.update({"trade_rules": {"min_confluence": 70}}, base_revision=original)
        # 70 -> 50 loosens the confluence gate, so a restore needs confirmation too.
        with self.assertRaises(ConfigError) as ctx:
            self.store.restore(original, base_revision=self.store.revision)
        self.assertEqual(ctx.exception.status, 428)
        self.store.restore(original, base_revision=self.store.revision, confirm_risk_increase=True)
        self.assertEqual(self.store.snapshot()["trade_rules"]["min_confluence"], 50)
        self.assertEqual(self.store.revision, original + 2)
        with self.assertRaises(ConfigError) as ctx:
            self.store.restore(9999, base_revision=self.store.revision)
        self.assertEqual(ctx.exception.status, 404)

    def test_corrupt_file_falls_back_to_last_backup(self):
        self.store.update({"trade_rules": {"min_confluence": 65}}, base_revision=self.store.revision)
        Path(self.tmp.name, "strategy_config.json").write_text("{ not json", encoding="utf-8")
        recovered = ConfigStore(Path(self.tmp.name))
        self.assertEqual(recovered.snapshot()["trade_rules"]["min_confluence"], 65)
        self.assertEqual(recovered.snapshot()["updated_by"], "recovery")
        self.assertTrue(list(Path(self.tmp.name).glob("strategy_config.invalid-*.json")))

    def test_hand_edited_out_of_bounds_file_is_not_trusted(self):
        path = Path(self.tmp.name, "strategy_config.json")
        data = json.loads(path.read_text(encoding="utf-8"))
        data["account_limits"]["risk_percent_per_trade"] = 99
        path.write_text(json.dumps(data), encoding="utf-8")
        reloaded = ConfigStore(Path(self.tmp.name))
        self.assertLessEqual(reloaded.snapshot()["account_limits"]["risk_percent_per_trade"], 2.0)

    def test_missing_keys_are_filled_from_defaults(self):
        path = Path(self.tmp.name, "strategy_config.json")
        data = json.loads(path.read_text(encoding="utf-8"))
        del data["trade_rules"]["reject_cooldown_minutes"]
        path.write_text(json.dumps(data), encoding="utf-8")
        reloaded = ConfigStore(Path(self.tmp.name))
        self.assertEqual(reloaded.snapshot()["trade_rules"]["reject_cooldown_minutes"], 15)

    def test_no_temp_file_is_left_behind(self):
        self.store.update({"trade_rules": {"min_confluence": 60}}, base_revision=self.store.revision)
        self.assertEqual(list(Path(self.tmp.name).rglob("*.tmp")), [])

    def test_snapshot_is_a_deep_copy(self):
        snap = self.store.snapshot()
        snap["account_limits"]["max_lot"] = 999
        self.assertNotEqual(self.store.snapshot()["account_limits"]["max_lot"], 999)


class Fingerprint(unittest.TestCase):
    def setUp(self):
        self.tmp, self.store = new_store()
        self.addCleanup(self.tmp.cleanup)

    def test_first_sighting_is_recorded_then_mismatch_is_flagged(self):
        self.assertFalse(self.store.check_fingerprint("123@Demo"))
        self.assertFalse(self.store.check_fingerprint("123@Demo"))
        self.assertTrue(self.store.check_fingerprint("456@Live"))
        self.assertTrue(self.store.public()["meta"]["fingerprint_mismatch"])
        self.store.acknowledge_account("456@Live")
        self.assertFalse(self.store.check_fingerprint("456@Live"))


if __name__ == "__main__":
    unittest.main()
