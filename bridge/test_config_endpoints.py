"""Endpoint + order-gate tests. MetaTrader5 is replaced by a mock, the app is
never started (no lifespan, no MT5 connection) and runtime data goes to a
temp dir, so the real bridge/.env secrets and data/ folder are never used."""

import asyncio
import logging
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

_DATA = tempfile.TemporaryDirectory()
os.environ["BRIDGE_API_KEY"] = "test-key"
os.environ["BRIDGE_DATA_DIR"] = _DATA.name
# Whatever is in the developer's real bridge/.env, tests must never message a real chat.
for _k in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "TELEGRAM_ALLOWED_USER_IDS"):
    os.environ[_k] = ""
_MT5 = MagicMock()
# Real integer values (as in the MetaTrader5 package) — bare MagicMock
# constants can compare equal to each other after reset_mock().
for _name, _value in {
    "TRADE_RETCODE_DONE": 10009,
    "TRADE_RETCODE_REQUOTE": 10004,
    "TRADE_RETCODE_PRICE_CHANGED": 10020,
    "TRADE_RETCODE_PRICE_OFF": 10021,
    "POSITION_TYPE_BUY": 0,
    "POSITION_TYPE_SELL": 1,
    "ORDER_TYPE_BUY": 0,
    "ORDER_TYPE_SELL": 1,
    "DEAL_ENTRY_IN": 0,
    "DEAL_ENTRY_OUT": 1,
    "DEAL_ENTRY_INOUT": 2,
    "DEAL_ENTRY_OUT_BY": 3,
    "DEAL_TYPE_BUY": 0,
    "DEAL_TYPE_SELL": 1,
    "DEAL_REASON_CLIENT": 0,
    "DEAL_REASON_MOBILE": 1,
    "DEAL_REASON_WEB": 2,
    "DEAL_REASON_EXPERT": 3,
    "DEAL_REASON_SL": 4,
    "DEAL_REASON_TP": 5,
    "DEAL_REASON_SO": 6,
    "TRADE_ACTION_DEAL": 1,
    "TRADE_ACTION_SLTP": 6,
    "ORDER_TIME_GTC": 0,
    "ORDER_FILLING_FOK": 0,
    "ORDER_FILLING_IOC": 1,
    "ORDER_FILLING_RETURN": 2,
    "TIMEFRAME_M1": 1,
    "TIMEFRAME_M5": 5,
    "TIMEFRAME_M15": 15,
    "TIMEFRAME_H1": 16385,
    "TIMEFRAME_H4": 16388,
    "TIMEFRAME_D1": 16408,
}.items():
    setattr(_MT5, _name, _value)
sys.modules["MetaTrader5"] = _MT5

import mt5_bridge_server as server  # noqa: E402
import httpx  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from risk_guard import DailyLossGuard  # noqa: E402
from signal_store import SignalStore  # noqa: E402
from security import AuthThrottle  # noqa: E402
from strategy_config import ConfigStore  # noqa: E402

mt5 = sys.modules["MetaTrader5"]
_SAFE_TRANSPORT = httpx.MockTransport(lambda request: httpx.Response(200, json={"ok": True}))
server.TELEGRAM_TRANSPORT = _SAFE_TRANSPORT
H = {"X-API-Key": "test-key"}


class EndpointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        mt5.account_info.return_value = SimpleNamespace(login=111, server="Demo-1")

    def rev(self):
        return self.client.get("/config", headers=H).json()["revision"]

    def post(self, patch, **kw):
        body = {"base_revision": self.rev(), "patch": patch, **kw}
        return self.client.post("/config/update", json=body, headers=H)

    def test_api_key_required(self):
        self.assertEqual(self.client.get("/config").status_code, 401)
        self.assertEqual(self.client.post("/config/update", json={"base_revision": 1, "patch": {}}).status_code, 401)

    def test_get_config_returns_config_bounds_and_meta(self):
        r = self.client.get("/config", headers=H)
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertEqual(body["config"]["mode"]["auto_trade"], "off")
        self.assertIn("account_limits.max_lot", body["bounds"])
        self.assertIn("mode.paused", " ".join(body["meta"]["enforced_by_bridge"]))
        self.assertEqual(r.headers["etag"], f'"{body["revision"]}"')

    def test_etag_gives_304_until_the_config_changes(self):
        etag = self.client.get("/config", headers=H).headers["etag"]
        self.assertEqual(self.client.get("/config", headers={**H, "If-None-Match": etag}).status_code, 304)
        self.assertEqual(self.post({"trade_rules": {"min_confluence": 60}}).status_code, 200)
        self.assertEqual(self.client.get("/config", headers={**H, "If-None-Match": etag}).status_code, 200)

    def test_update_success_returns_changes_and_new_config(self):
        r = self.post({"trade_rules": {"min_confluence": 60}})
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertEqual(body["config"]["trade_rules"]["min_confluence"], 60)
        self.assertEqual(body["changed"][0]["path"], "trade_rules.min_confluence")

    def test_error_codes(self):
        stale = self.client.post(
            "/config/update", json={"base_revision": 999, "patch": {"trade_rules": {"min_confluence": 60}}}, headers=H
        )
        self.assertEqual((stale.status_code, stale.json()["detail"]["code"]), (409, "stale_revision"))
        bad = self.post({"account_limits": {"risk_percent_per_trade": 50}}, confirm_risk_increase=True)
        self.assertEqual((bad.status_code, bad.json()["detail"]["code"]), (400, "validation_failed"))
        needs = self.post({"mode": {"auto_trade": "auto"}})
        self.assertEqual((needs.status_code, needs.json()["detail"]["code"]), (428, "confirmation_required"))

    def test_audit_and_restore_endpoints(self):
        first = self.rev()
        self.post({"trade_rules": {"min_confluence": 60}})
        audit = self.client.get("/config/audit", headers=H).json()["entries"]
        self.assertTrue(any(e["action"] == "update" for e in audit))
        needs = self.client.post("/config/restore", json={"revision": first, "base_revision": self.rev()}, headers=H)
        self.assertEqual(needs.status_code, 428)  # 60 -> 50 loosens the confluence gate
        r = self.client.post(
            "/config/restore",
            json={"revision": first, "base_revision": self.rev(), "confirm_risk_increase": True},
            headers=H,
        )
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["config"]["trade_rules"]["min_confluence"], 50)

    def test_fingerprint_mismatch_is_reported_and_acknowledged(self):
        self.client.get("/config", headers=H)
        mt5.account_info.return_value = SimpleNamespace(login=222, server="Live-1")
        self.assertTrue(self.client.get("/config", headers=H).json()["meta"]["fingerprint_mismatch"])
        self.assertFalse(self.client.post("/config/ack_account", headers=H).json()["meta"]["fingerprint_mismatch"])

    def test_the_market_safety_layers_are_served_in_shadow_mode_with_their_bounds(self):
        body = self.client.get("/config", headers=H).json()
        self.assertEqual(body["config"]["filters"]["impulse"]["mode"], "shadow")
        self.assertEqual(body["config"]["filters"]["chaos"]["mode"], "shadow")
        self.assertEqual(body["config"]["engines"]["ict"]["params"]["sweep_mode"], "shadow")
        self.assertEqual(body["bounds"]["filters.impulse.mode"]["values"], ["block", "shadow", "off"])
        self.assertEqual(body["bounds"]["filters.chaos.baseline_days"]["max"], 20)

    def test_a_layer_can_be_switched_to_block_over_the_api_without_confirmation(self):
        r = self.post({"filters": {"impulse": {"mode": "block"}}})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["config"]["filters"]["impulse"]["mode"], "block")
        back = self.post({"filters": {"impulse": {"mode": "shadow"}}})
        self.assertEqual((back.status_code, back.json()["detail"]["code"]), (428, "confirmation_required"))


class CandleSpreadTests(unittest.TestCase):
    """/candles also carries each bar's spread in pips, so the app can build a time-of-day spread baseline."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        mt5.terminal_info.return_value = object()
        mt5.symbol_select.return_value = True
        mt5.symbol_info.return_value = SimpleNamespace(point=0.01)
        self.rates = []
        mt5.copy_rates_from_pos.return_value = self.rates
        mt5.last_error.return_value = (1, "Success")
        self.offset = server.CLOCK.offset_seconds
        self.addCleanup(lambda: setattr(server.CLOCK, "offset_seconds", self.offset))

    def bar(self, minute, **extra):
        base = {"time": 1_700_000_000 + minute * 60, "open": 2000.0, "high": 2001.0, "low": 1999.0, "close": 2000.5, "tick_volume": 10}
        return {**base, **extra}

    def candles(self):
        r = self.client.get("/candles", params={"symbol": "XAUUSD", "timeframe": 15, "count": 10}, headers=H)
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()

    def test_the_broker_spread_in_points_is_converted_to_pips(self):
        self.rates.extend([self.bar(0, spread=25), self.bar(15, spread=80), self.bar(30, spread=0)])
        out = self.candles()
        # 25 points x $0.01 = $0.25 = 2.5 pips ($0.10 each)
        self.assertEqual([c["spread_pips"] for c in out], [2.5, 8.0, 0.0])

    def test_a_bar_without_a_spread_still_comes_back_just_without_one(self):
        self.rates.append(self.bar(0))
        out = self.candles()
        self.assertIsNone(out[0]["spread_pips"])
        self.assertEqual(out[0]["close"], 2000.5)

    def test_an_unknown_point_size_drops_the_spread_but_never_the_candles(self):
        mt5.symbol_info.return_value = None
        self.rates.append(self.bar(0, spread=25))
        out = self.candles()
        self.assertEqual(len(out), 1)
        self.assertIsNone(out[0]["spread_pips"])

    def test_a_nonsense_spread_is_dropped(self):
        self.rates.extend([self.bar(0, spread=-5), self.bar(15, spread=float("nan"))])
        self.assertEqual([c["spread_pips"] for c in self.candles()], [None, None])


class OrderGateTests(unittest.TestCase):
    ORDER = {"symbol": "XAUUSD", "direction": "buy", "volume": 0.5, "stop_loss": 1990.0, "take_profit": 2020.0}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        server.RISK = DailyLossGuard(Path(self.tmp.name))
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        mt5.account_info.return_value = SimpleNamespace(equity=100000.0, balance=100000.0, login=1, server="s")
        mt5.history_deals_get.return_value = ()
        mt5.terminal_info.return_value = object()
        mt5.symbol_select.return_value = True
        mt5.symbol_info.return_value = SimpleNamespace(filling_mode=2, trade_tick_value=1.0, trade_tick_size=0.01)
        mt5.symbol_info_tick.return_value = SimpleNamespace(ask=2000.2, bid=2000.0)
        mt5.positions_get.return_value = ()
        mt5.order_send.return_value = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, order=777, price=2000.2)

    def enable_auto(self, patch=None):
        base = server.CONFIG.revision
        server.CONFIG.update({"mode": {"auto_trade": "auto"}, **(patch or {})}, base_revision=base, confirm_risk_increase=True)

    def order(self, **over):
        return self.client.post("/order/open", json={**self.ORDER, **over}, headers=H).json()

    def test_orders_refused_by_default_because_mode_is_off(self):
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("mode.auto_trade", r["error"])
        mt5.order_send.assert_not_called()

    def test_order_goes_through_when_auto_and_within_limits(self):
        self.enable_auto()
        r = self.order()
        self.assertTrue(r["success"], r)
        self.assertEqual(r["ticket"], 777)
        mt5.order_send.assert_called_once()

    def test_paused_blocks_orders(self):
        self.enable_auto()
        server.CONFIG.update({"mode": {"paused": True}}, base_revision=server.CONFIG.revision)
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("paused", r["error"])
        mt5.order_send.assert_not_called()

    def test_volume_limits(self):
        self.enable_auto()
        self.assertIn("max_lot", self.order(volume=6.0)["error"])
        self.assertIn("min_lot", self.order(volume=0.001)["error"])
        mt5.order_send.assert_not_called()

    def test_open_position_limit(self):
        self.enable_auto()
        mt5.positions_get.return_value = (object(),)
        self.assertIn("max_open_positions", self.order()["error"])
        mt5.order_send.assert_not_called()

    def test_unverifiable_positions_fail_closed(self):
        self.enable_auto()
        mt5.positions_get.return_value = None
        self.assertIn("verify", self.order()["error"])
        mt5.order_send.assert_not_called()

    def test_spread_limit(self):
        self.enable_auto()
        mt5.symbol_info_tick.return_value = SimpleNamespace(ask=2004.0, bid=2000.0)  # 40 pips > 30
        self.assertIn("max_spread_pips", self.order()["error"])
        mt5.order_send.assert_not_called()

    def test_slippage_deviation_is_capped_by_config(self):
        self.enable_auto({"account_limits": {"max_slippage_points": 5}})
        self.assertTrue(self.order(deviation=50)["success"])
        sent = mt5.order_send.call_args[0][0]
        self.assertEqual(sent["deviation"], 5)

    def test_limit_changes_apply_to_the_very_next_order(self):
        self.enable_auto()
        self.assertTrue(self.order()["success"])
        server.CONFIG.update({"account_limits": {"max_lot": 0.2}}, base_revision=server.CONFIG.revision)
        self.assertIn("max_lot", self.order()["error"])


class CloseEndpointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        mt5.terminal_info.return_value = object()
        mt5.symbol_info.return_value = SimpleNamespace(filling_mode=2)
        mt5.symbol_info_tick.return_value = SimpleNamespace(ask=2000.2, bid=2000.0)
        mt5.order_send.return_value = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, order=1, price=2000.0, comment="")
        self.sleep = server.time.sleep
        server.time.sleep = lambda _s: None
        self.addCleanup(lambda: setattr(server.time, "sleep", self.sleep))

    def pos(self, ticket=11, kind=None, volume=0.5, symbol="XAUUSD..."):
        return SimpleNamespace(
            ticket=ticket,
            type=kind if kind is not None else mt5.POSITION_TYPE_BUY,
            volume=volume,
            symbol=symbol,
            magic=20260921,
        )

    def close(self, ticket=11):
        return self.client.post("/order/close", json={"ticket": ticket}, headers=H).json()

    def test_close_sends_an_opposite_deal_for_the_full_volume(self):
        mt5.positions_get.return_value = (self.pos(kind=mt5.POSITION_TYPE_BUY, volume=0.5),)
        r = self.close()
        self.assertTrue(r["success"], r)
        self.assertEqual(r["price"], 2000.0)
        sent = mt5.order_send.call_args[0][0]
        self.assertEqual(sent["type"], mt5.ORDER_TYPE_SELL)
        self.assertEqual(sent["volume"], 0.5)
        self.assertEqual(sent["position"], 11)
        self.assertEqual(sent["price"], 2000.0)  # a BUY closes on the BID

    def test_sell_closes_on_the_ask(self):
        mt5.positions_get.return_value = (self.pos(kind=mt5.POSITION_TYPE_SELL),)
        self.assertTrue(self.close()["success"])
        sent = mt5.order_send.call_args[0][0]
        self.assertEqual(sent["type"], mt5.ORDER_TYPE_BUY)
        self.assertEqual(sent["price"], 2000.2)

    def test_unknown_position_is_reported_as_not_found(self):
        mt5.positions_get.return_value = ()
        r = self.close()
        self.assertFalse(r["success"])
        self.assertTrue(r["not_found"])
        mt5.order_send.assert_not_called()

    def test_unreadable_positions_are_not_mistaken_for_closed(self):
        mt5.positions_get.return_value = None
        r = self.close()
        self.assertFalse(r["success"])
        self.assertFalse(r["not_found"])

    def test_closing_works_while_paused_and_in_any_mode(self):
        server.CONFIG.update({"mode": {"paused": True}}, base_revision=server.CONFIG.revision)
        mt5.positions_get.return_value = (self.pos(),)
        self.assertTrue(self.close()["success"])

    def test_requote_is_retried_with_a_fresh_quote_then_succeeds(self):
        mt5.positions_get.return_value = (self.pos(),)
        requote = SimpleNamespace(retcode=mt5.TRADE_RETCODE_REQUOTE, comment="requote", price=0)
        done = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, comment="", price=1999.8)
        mt5.order_send.side_effect = [requote, requote, done]
        r = self.close()
        self.assertTrue(r["success"], r)
        self.assertEqual(r["price"], 1999.8)
        self.assertEqual(mt5.order_send.call_count, 3)

    def test_retries_stop_after_three_attempts(self):
        mt5.positions_get.return_value = (self.pos(),)
        mt5.order_send.return_value = SimpleNamespace(retcode=mt5.TRADE_RETCODE_REQUOTE, comment="requote", price=0)
        r = self.close()
        self.assertFalse(r["success"])
        self.assertEqual(mt5.order_send.call_count, 3)

    def test_a_hard_rejection_is_not_retried_and_reports_the_reason(self):
        mt5.positions_get.return_value = (self.pos(),)
        mt5.order_send.return_value = SimpleNamespace(retcode=10018, comment="Market closed", price=0)
        r = self.close()
        self.assertFalse(r["success"])
        self.assertIn("Market closed", r["error"])
        self.assertEqual(mt5.order_send.call_count, 1)

    def test_close_all_closes_every_position_and_reports_each(self):
        mt5.positions_get.return_value = (self.pos(ticket=1), self.pos(ticket=2, kind=mt5.POSITION_TYPE_SELL))
        r = self.client.post("/order/close_all", json={"symbol": "XAUUSD..."}, headers=H).json()
        self.assertTrue(r["success"])
        self.assertEqual([c["ticket"] for c in r["closed"]], [1, 2])
        self.assertTrue(all(c["success"] for c in r["closed"]))
        mt5.positions_get.assert_called_with(symbol="XAUUSD...")

    def test_close_all_without_a_symbol_means_every_position(self):
        mt5.positions_get.return_value = ()
        r = self.client.post("/order/close_all", json={}, headers=H).json()
        self.assertTrue(r["success"])
        self.assertEqual(r["closed"], [])
        mt5.positions_get.assert_called_with()

    def test_close_all_keeps_going_after_one_failure(self):
        mt5.positions_get.return_value = (self.pos(ticket=1), self.pos(ticket=2))
        bad = SimpleNamespace(retcode=10018, comment="Market closed", price=0)
        good = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, comment="", price=2000.0)
        mt5.order_send.side_effect = [bad, good]
        r = self.client.post("/order/close_all", json={}, headers=H).json()
        self.assertFalse(r["success"])
        self.assertEqual([c["success"] for c in r["closed"]], [False, True])

    def test_closes_are_written_to_the_audit_log(self):
        mt5.positions_get.return_value = (self.pos(),)
        self.close()
        actions = [e["action"] for e in server.CONFIG.audit_tail()]
        self.assertIn("close", actions)

    def test_close_requires_the_api_key(self):
        self.assertEqual(self.client.post("/order/close", json={"ticket": 1}).status_code, 401)
        self.assertEqual(self.client.post("/order/close_all", json={}).status_code, 401)


class ReconcileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        mt5.terminal_info.return_value = object()
        mt5.positions_get.return_value = ()
        mt5.history_deals_get.return_value = ()
        self.now = int(server.time.time())
        # /reconcile only answers once a fresh tick has confirmed the server-time offset (see ServerClockTests).
        detected = server.CLOCK.detected
        server.CLOCK.detected = True
        self.addCleanup(lambda: setattr(server.CLOCK, "detected", detected))

    def deal(self, position_id, entry, kind, price, volume=0.5, reason=0, profit=0.0, commission=0.0,
             swap=0.0, at=None, symbol="XAUUSD...", magic=20260920):
        return SimpleNamespace(
            position_id=position_id, entry=entry, type=kind, price=price, volume=volume, reason=reason,
            profit=profit, commission=commission, swap=swap, fee=0.0, symbol=symbol, magic=magic,
            time=at if at is not None else self.now - 600, time_msc=0,
        )

    def get(self, **params):
        return self.client.get("/reconcile", params=params, headers=H)

    def test_closed_buy_hit_tp_reports_real_prices_profit_and_reason(self):
        mt5.history_deals_get.return_value = (
            self.deal(11, mt5.DEAL_ENTRY_IN, mt5.DEAL_TYPE_BUY, 2000.20, at=self.now - 3000, commission=-3.5),
            self.deal(11, mt5.DEAL_ENTRY_OUT, mt5.DEAL_TYPE_SELL, 2010.00, reason=mt5.DEAL_REASON_TP, profit=490.0),
        )
        body = self.get().json()
        self.assertTrue(body["history_ok"])
        (c,) = body["closed"]
        self.assertEqual(
            (c["ticket"], c["type"], c["price_open"], c["price_close"], c["reason"], c["profit"]),
            (11, "buy", 2000.20, 2010.00, "tp", 486.5),
        )
        self.assertEqual(c["time_close"], self.now - 600)

    def test_sell_closed_by_stop_and_by_hand(self):
        mt5.history_deals_get.return_value = (
            self.deal(1, mt5.DEAL_ENTRY_IN, mt5.DEAL_TYPE_SELL, 2000.0),
            self.deal(1, mt5.DEAL_ENTRY_OUT, mt5.DEAL_TYPE_BUY, 2011.0, reason=mt5.DEAL_REASON_SL, profit=-550.0),
            self.deal(2, mt5.DEAL_ENTRY_IN, mt5.DEAL_TYPE_SELL, 2000.0),
            self.deal(2, mt5.DEAL_ENTRY_OUT, mt5.DEAL_TYPE_BUY, 1995.0, reason=mt5.DEAL_REASON_CLIENT, profit=250.0),
            self.deal(3, mt5.DEAL_ENTRY_IN, mt5.DEAL_TYPE_SELL, 2000.0),
            self.deal(3, mt5.DEAL_ENTRY_OUT, mt5.DEAL_TYPE_BUY, 2030.0, reason=mt5.DEAL_REASON_SO, profit=-1500.0),
        )
        by_ticket = {c["ticket"]: c for c in self.get().json()["closed"]}
        self.assertEqual({k: v["reason"] for k, v in by_ticket.items()}, {1: "sl", 2: "manual", 3: "stop_out"})
        self.assertTrue(all(c["type"] == "sell" for c in by_ticket.values()))

    def test_partial_closes_are_averaged_and_only_reported_when_fully_closed(self):
        deals = [
            self.deal(7, mt5.DEAL_ENTRY_IN, mt5.DEAL_TYPE_BUY, 2000.0, volume=1.0),
            self.deal(7, mt5.DEAL_ENTRY_OUT, mt5.DEAL_TYPE_SELL, 2010.0, volume=0.4, at=self.now - 900),
        ]
        mt5.history_deals_get.return_value = tuple(deals)
        self.assertEqual(self.get().json()["closed"], [], "still open at the broker")
        deals.append(self.deal(7, mt5.DEAL_ENTRY_OUT, mt5.DEAL_TYPE_SELL, 2020.0, volume=0.6, reason=mt5.DEAL_REASON_TP))
        mt5.history_deals_get.return_value = tuple(deals)
        (c,) = self.get().json()["closed"]
        self.assertAlmostEqual(c["price_close"], (2010.0 * 0.4 + 2020.0 * 0.6) / 1.0)
        self.assertEqual(c["volume"], 1.0)

    def test_positions_without_an_opening_deal_in_the_window_are_skipped(self):
        mt5.history_deals_get.return_value = (self.deal(9, mt5.DEAL_ENTRY_OUT, mt5.DEAL_TYPE_SELL, 2010.0),)
        self.assertEqual(self.get().json()["closed"], [])

    def test_balance_and_zero_position_deals_are_ignored(self):
        mt5.history_deals_get.return_value = (self.deal(0, mt5.DEAL_ENTRY_IN, mt5.DEAL_TYPE_BUY, 0.0),)
        self.assertEqual(self.get().json()["closed"], [])

    def test_symbol_filter_and_age_cutoff(self):
        mt5.history_deals_get.return_value = (
            self.deal(1, mt5.DEAL_ENTRY_IN, mt5.DEAL_TYPE_BUY, 2000.0, symbol="EURUSD", at=self.now - 800),
            self.deal(1, mt5.DEAL_ENTRY_OUT, mt5.DEAL_TYPE_SELL, 2001.0, symbol="EURUSD"),
            self.deal(2, mt5.DEAL_ENTRY_IN, mt5.DEAL_TYPE_BUY, 2000.0, at=self.now - 300000),
            self.deal(2, mt5.DEAL_ENTRY_OUT, mt5.DEAL_TYPE_SELL, 2001.0, at=self.now - 290000),
            self.deal(3, mt5.DEAL_ENTRY_IN, mt5.DEAL_TYPE_BUY, 2000.0, at=self.now - 800),
            self.deal(3, mt5.DEAL_ENTRY_OUT, mt5.DEAL_TYPE_SELL, 2001.0),
        )
        closed = self.get(symbol="XAUUSD...", since_hours=24).json()["closed"]
        self.assertEqual([c["ticket"] for c in closed], [3])

    def test_open_positions_are_listed(self):
        mt5.positions_get.return_value = (
            SimpleNamespace(
                ticket=55, symbol="XAUUSD...", type=mt5.POSITION_TYPE_SELL, volume=0.3, price_open=2001.5,
                sl=2010.0, tp=1985.0, profit=12.3, magic=20260920, time=self.now - 100,
            ),
        )
        (p,) = self.get(symbol="XAUUSD...").json()["positions"]
        self.assertEqual((p["ticket"], p["type"], p["price_open"], p["sl"], p["tp"], p["magic"]),
                         (55, "sell", 2001.5, 2010.0, 1985.0, 20260920))
        mt5.positions_get.assert_called_with(symbol="XAUUSD...")

    def test_unreadable_positions_are_an_error_not_an_empty_list(self):
        mt5.positions_get.return_value = None
        self.assertEqual(self.get().status_code, 503)

    def test_unreadable_history_is_flagged_so_nothing_is_concluded_from_it(self):
        mt5.history_deals_get.return_value = None
        body = self.get().json()
        self.assertFalse(body["history_ok"])
        self.assertEqual(body["closed"], [])

    def test_requires_the_api_key(self):
        self.assertEqual(self.client.get("/reconcile").status_code, 401)


class ServerClockTests(unittest.TestCase):
    """Startup timing (2026-10-09): the bridge used to read broker times as UTC (offset 0) until the first fresh
    tick, and the app rewrote 12-14 history close times 3 h late right after a restart."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "server_clock.json"
        os.environ.pop("MT5_SERVER_UTC_OFFSET_HOURS", None)

    def tick_at_offset(self, clock, hours):
        clock.observe_fresh_tick(int(server.time.time() + hours * 3600))

    def test_first_ever_start_has_no_offset_and_is_not_confirmed(self):
        clock = server.ServerClock(self.path)
        self.assertEqual((clock.offset_seconds, clock.detected, clock.source), (0, False, "unknown"))

    def test_a_detected_offset_is_remembered_and_used_from_the_first_second_of_the_next_start(self):
        first = server.ServerClock(self.path)
        self.tick_at_offset(first, 3)
        self.assertEqual((first.offset_seconds, first.detected, first.source), (10800, True, "detected"))
        restarted = server.ServerClock(self.path)
        self.assertEqual(restarted.offset_seconds, 10800, "server times are converted right away")
        self.assertFalse(restarted.detected, "but it is not CONFIRMED until a fresh tick")
        self.assertEqual(restarted.source, "remembered")
        self.assertEqual(restarted.to_utc_seconds(1_000_000 + 10800), 1_000_000)

    def test_a_fresh_tick_replaces_a_remembered_offset_that_changed(self):
        server.ServerClock(self.path).observe_fresh_tick(int(server.time.time() + 3 * 3600))
        after_dst = server.ServerClock(self.path)                 # broker moved to +2 (winter time)
        self.tick_at_offset(after_dst, 2)
        self.assertEqual((after_dst.offset_seconds, after_dst.detected), (7200, True))
        self.assertEqual(server.ServerClock(self.path).offset_seconds, 7200)

    def test_an_unreadable_or_implausible_file_is_ignored(self):
        for content in ("not json", '{"offset_seconds": "x"}', '{"offset_seconds": 12345}', '{"offset_seconds": 90000}'):
            self.path.write_text(content, encoding="utf-8")
            clock = server.ServerClock(self.path)
            self.assertEqual((clock.offset_seconds, clock.source), (0, "unknown"), content)

    def test_an_offset_fixed_in_env_wins_over_the_remembered_one(self):
        server.ServerClock(self.path).observe_fresh_tick(int(server.time.time() + 3 * 3600))
        os.environ["MT5_SERVER_UTC_OFFSET_HOURS"] = "2"
        self.addCleanup(lambda: os.environ.pop("MT5_SERVER_UTC_OFFSET_HOURS", None))
        clock = server.ServerClock(self.path)
        self.assertEqual((clock.offset_seconds, clock.detected, clock.source), (7200, True, "fixed"))

    def test_the_file_is_written_only_when_the_offset_changes(self):
        clock = server.ServerClock(self.path)
        self.tick_at_offset(clock, 3)
        stamp = self.path.stat().st_mtime_ns
        for _ in range(5):
            self.tick_at_offset(clock, 3)
        self.assertEqual(self.path.stat().st_mtime_ns, stamp)

    def test_reconcile_refuses_until_the_offset_is_confirmed_and_health_says_why(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        server.CONFIG = ConfigStore(Path(tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        mt5.terminal_info.return_value = object()
        mt5.positions_get.return_value = ()
        mt5.history_deals_get.return_value = ()
        saved = server.CLOCK
        self.addCleanup(lambda: setattr(server, "CLOCK", saved))
        server.ServerClock(self.path).observe_fresh_tick(int(server.time.time() + 3 * 3600))
        server.CLOCK = server.ServerClock(self.path)              # a restart: offset remembered, not confirmed
        response = client.get("/reconcile", headers=H)
        self.assertEqual(response.status_code, 503)
        self.assertIn("not confirmed", response.json()["detail"])
        health = client.get("/health").json()
        self.assertEqual((health["offset_detected"], health["offset_source"], health["server_utc_offset_hours"]),
                         (False, "remembered", 3.0))
        self.tick_at_offset(server.CLOCK, 3)                      # the first fresh tick
        self.assertEqual(client.get("/reconcile", headers=H).status_code, 200)
        self.assertEqual(client.get("/health").json()["offset_source"], "detected")


class DailyLossTests(unittest.TestCase):
    ORDER = {"symbol": "XAUUSD", "direction": "buy", "volume": 0.1, "stop_loss": 1990.0, "take_profit": 2020.0}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        server.RISK = DailyLossGuard(Path(self.tmp.name))
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        self.account(10000.0)
        mt5.history_deals_get.return_value = ()
        mt5.terminal_info.return_value = object()
        mt5.symbol_select.return_value = True
        mt5.symbol_info.return_value = SimpleNamespace(filling_mode=2, trade_tick_value=1.0, trade_tick_size=0.01)
        mt5.symbol_info_tick.return_value = SimpleNamespace(ask=2000.2, bid=2000.0)
        mt5.positions_get.return_value = ()
        mt5.order_send.return_value = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, order=7, price=2000.0, comment="")
        sleep = server.time.sleep
        server.time.sleep = lambda _s: None
        self.addCleanup(lambda: setattr(server.time, "sleep", sleep))
        server.CONFIG.update({"mode": {"auto_trade": "auto"}}, base_revision=server.CONFIG.revision, confirm_risk_increase=True)

    def account(self, equity, balance=None):
        mt5.account_info.return_value = SimpleNamespace(
            equity=equity, balance=equity if balance is None else balance, login=1, server="s"
        )

    def order(self):
        return self.client.post("/order/open", json=self.ORDER, headers=H).json()

    def status(self):
        return self.client.get("/risk/status", headers=H).json()

    def position(self, ticket=1, kind=None, symbol="XAUUSD", volume=0.5, magic=20260920):
        return SimpleNamespace(
            ticket=ticket, type=mt5.POSITION_TYPE_BUY if kind is None else kind, volume=volume, symbol=symbol, magic=magic
        )

    def test_status_reports_the_numbers(self):
        s = self.status()
        self.assertTrue(s["available"])
        self.assertEqual((s["baseline"], s["equity"], s["limit_percent"], s["locked"]), (10000.0, 10000.0, 3.0, False))
        self.assertEqual(s["on_breach"], "block")

    def test_orders_flow_while_the_trade_fits_inside_the_remaining_loss_budget(self):
        self.status()
        self.account(9900.0)  # -1%: 200 of the 300 budget is left and the order risks 102
        self.assertTrue(self.order()["success"])

    def test_an_order_whose_stop_could_pass_the_limit_is_refused_before_the_limit_is_reached(self):
        self.status()
        self.account(9800.0)  # -2%: only 100 is left and the order risks 102
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("Daily loss limit: this trade could lose 102.00", r["error"])
        self.assertIn("100.00 left", r["error"])
        mt5.order_send.assert_not_called()
        self.assertFalse(self.status()["locked"], "refused, but the limit itself was not reached")

    def test_a_floating_loss_past_the_limit_locks_and_blocks_the_next_order(self):
        self.status()
        self.account(9690.0)  # -3.1%
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("Daily loss limit reached", r["error"])
        self.assertIn("00:00 UTC", r["error"])
        mt5.order_send.assert_not_called()
        self.assertTrue(self.status()["locked"])

    def test_the_lock_stays_even_after_equity_recovers(self):
        self.status()
        self.account(9600.0)
        self.status()
        self.account(10100.0)
        self.assertFalse(self.order()["success"])

    def test_an_unreadable_account_fails_closed(self):
        mt5.account_info.return_value = None
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("unreadable", r["error"])
        mt5.order_send.assert_not_called()
        self.assertFalse(self.status()["available"])

    def test_tightening_the_limit_trips_the_lock_but_loosening_never_releases_it(self):
        self.status()
        self.account(9800.0)
        server.CONFIG.update({"account_limits": {"max_daily_loss_percent": 1.5}}, base_revision=server.CONFIG.revision)
        self.assertTrue(self.status()["locked"])
        server.CONFIG.update(
            {"account_limits": {"max_daily_loss_percent": 5.0}},
            base_revision=server.CONFIG.revision,
            confirm_risk_increase=True,
        )
        self.assertTrue(self.status()["locked"])
        self.assertFalse(self.order()["success"])

    def test_closing_is_never_blocked_by_the_lock(self):
        self.status()
        self.account(9000.0)
        self.status()
        mt5.positions_get.return_value = (self.position(),)
        self.assertTrue(self.client.post("/order/close", json={"ticket": 1}, headers=H).json()["success"])

    def test_baseline_comes_from_todays_realised_deals(self):
        now = int(server.time.time())
        mt5.history_deals_get.return_value = (
            SimpleNamespace(position_id=5, time=now - 60, profit=-200.0, swap=0.0, commission=0.0, fee=0.0),
            SimpleNamespace(position_id=0, time=now - 60, profit=5000.0, swap=0.0, commission=0.0, fee=0.0),  # deposit
        )
        self.account(10000.0, balance=10000.0)
        s = self.status()
        self.assertEqual((s["baseline"], s["baseline_source"]), (10200.0, "deals"))

    def test_yesterdays_deals_do_not_count(self):
        now = int(server.time.time())
        mt5.history_deals_get.return_value = (
            SimpleNamespace(position_id=5, time=now - 3 * 86400, profit=-900.0, swap=0.0, commission=0.0, fee=0.0),
        )
        self.assertEqual(self.status()["baseline"], 10000.0)

    def test_the_background_monitor_trips_the_lock_with_no_order_attempted(self):
        self.status()
        self.account(9500.0)
        server._risk_tick()
        self.assertTrue(server.RISK.is_locked())
        self.assertIn("daily_loss_lock", [e["action"] for e in server.CONFIG.audit_tail()])

    def test_block_mode_leaves_open_positions_alone(self):
        self.status()
        mt5.positions_get.return_value = (self.position(),)
        self.account(9500.0)
        server._risk_tick()
        mt5.order_send.assert_not_called()

    def test_close_all_mode_flattens_the_account_once(self):
        server.CONFIG.update({"account_limits": {"on_daily_loss": "close_all"}}, base_revision=server.CONFIG.revision)
        self.status()
        mt5.positions_get.return_value = (
            self.position(ticket=1),
            self.position(ticket=2, kind=mt5.POSITION_TYPE_SELL, symbol="EURUSD", volume=0.2, magic=0),
        )
        self.account(9500.0)
        server._risk_tick()
        self.assertEqual(mt5.order_send.call_count, 2, "every position on the account, any symbol")
        self.assertIn("daily_loss_close_all", [e["action"] for e in server.CONFIG.audit_tail()])
        server._risk_tick()
        self.assertEqual(mt5.order_send.call_count, 2, "does not close again once done")

    def test_close_all_retries_until_every_position_is_really_closed(self):
        server.CONFIG.update({"account_limits": {"on_daily_loss": "close_all"}}, base_revision=server.CONFIG.revision)
        self.status()
        mt5.positions_get.return_value = (self.position(),)
        self.account(9500.0)
        mt5.order_send.return_value = SimpleNamespace(retcode=10018, comment="Market closed", price=0)
        server._risk_tick()
        self.assertTrue(server.RISK.actions_pending(), "a failed close must be retried")
        mt5.order_send.return_value = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, comment="", price=1999.0)
        server._risk_tick()
        self.assertFalse(server.RISK.actions_pending())

    def test_the_monitor_does_nothing_when_the_account_is_unreadable(self):
        mt5.account_info.return_value = None
        server._risk_tick()  # must not raise
        mt5.order_send.assert_not_called()

    def test_override_needs_confirmation_then_unlocks_once_per_day(self):
        self.status()
        self.account(9600.0)
        self.status()
        no = self.client.post("/risk/override", json={}, headers=H)
        self.assertEqual((no.status_code, no.json()["detail"]["code"]), (428, "confirmation_required"))
        self.assertTrue(self.status()["locked"])

        ok = self.client.post("/risk/override", json={"confirm": True, "updated_by": "tester"}, headers=H)
        self.assertEqual(ok.status_code, 200)
        self.assertFalse(ok.json()["locked"])
        self.assertEqual(ok.json()["baseline"], 9600.0)
        self.assertTrue(self.order()["success"])
        self.assertIn("daily_loss_override", [e["action"] for e in server.CONFIG.audit_tail()])

        self.account(9300.0)  # a further 3.1% loss locks again
        self.assertTrue(self.status()["locked"])
        again = self.client.post("/risk/override", json={"confirm": True}, headers=H)
        self.assertEqual(again.status_code, 429)

    def test_override_is_refused_when_not_locked(self):
        r = self.client.post("/risk/override", json={"confirm": True}, headers=H)
        self.assertEqual(r.status_code, 429)

    def test_risk_endpoints_require_the_api_key(self):
        self.assertEqual(self.client.get("/risk/status").status_code, 401)
        self.assertEqual(self.client.post("/risk/override", json={"confirm": True}).status_code, 401)

    def test_the_new_limits_are_advertised_as_enforced(self):
        enforced = " ".join(self.client.get("/config", headers=H).json()["meta"]["enforced_by_bridge"])
        self.assertIn("max_daily_loss_percent", enforced)
        self.assertIn("on_daily_loss", enforced)


class AuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)

    def test_a_wrong_key_is_refused_and_a_right_one_accepted(self):
        self.assertEqual(self.client.get("/config", headers={"X-API-Key": "nope"}).status_code, 401)
        self.assertEqual(self.client.get("/config", headers=H).status_code, 200)

    def test_a_missing_key_is_refused(self):
        self.assertEqual(self.client.get("/config").status_code, 401)

    def test_a_key_in_the_query_string_is_not_accepted(self):
        self.assertEqual(self.client.get("/config", params={"api_key": "test-key"}).status_code, 401)

    def test_repeated_wrong_keys_lock_the_client_out_even_for_the_right_key(self):
        for _ in range(10):
            self.assertEqual(self.client.get("/config", headers={"X-API-Key": "guess"}).status_code, 401)
        locked = self.client.get("/config", headers=H)
        self.assertEqual(locked.status_code, 429)
        self.assertIn("Too many", locked.json()["detail"])

    def test_a_bridge_without_a_key_refuses_everything_instead_of_running_open(self):
        original = server.BRIDGE_API_KEY
        server.BRIDGE_API_KEY = ""
        self.addCleanup(lambda: setattr(server, "BRIDGE_API_KEY", original))
        r = self.client.get("/config", headers=H)
        self.assertEqual(r.status_code, 503)
        self.assertEqual(self.client.get("/config").status_code, 503)

    def test_health_is_the_only_open_endpoint_and_always_reports_auth_required(self):
        body = self.client.get("/health").json()
        self.assertTrue(body["auth_required"])

    def test_interactive_docs_are_not_published(self):
        for path in ("/docs", "/redoc", "/openapi.json"):
            self.assertEqual(self.client.get(path).status_code, 404, path)

    def test_cors_allows_local_pages_only(self):
        ask = lambda origin: self.client.options(
            "/config",
            headers={"Origin": origin, "Access-Control-Request-Method": "GET", "Access-Control-Request-Headers": "x-api-key"},
        )
        self.assertEqual(ask("http://localhost:5000").headers.get("access-control-allow-origin"), "http://localhost:5000")
        self.assertEqual(ask("http://127.0.0.1:8765").headers.get("access-control-allow-origin"), "http://127.0.0.1:8765")
        self.assertIsNone(ask("https://evil.example").headers.get("access-control-allow-origin"))

    def test_startup_is_refused_with_a_weak_key(self):
        original = server.BRIDGE_API_KEY
        server.BRIDGE_API_KEY = "short"
        self.addCleanup(lambda: setattr(server, "BRIDGE_API_KEY", original))

        async def start():
            async with server.lifespan(server.app):
                pass

        with self.assertRaises(RuntimeError) as ctx:
            asyncio.run(start())
        self.assertIn("Refusing to start", str(ctx.exception))


class WebSocketAuthTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        mt5.terminal_info.return_value = object()
        mt5.symbol_select.return_value = True
        mt5.symbol_info_tick.return_value = SimpleNamespace(
            ask=2000.2, bid=2000.0, last=0.0, time=int(server.time.time()), time_msc=int(server.time.time() * 1000)
        )
        old = (server.WS_AUTH_TIMEOUT_SECONDS, server.HEARTBEAT_SECONDS)
        server.WS_AUTH_TIMEOUT_SECONDS, server.HEARTBEAT_SECONDS = 0.3, 0.2
        self.addCleanup(lambda: setattr(server, "WS_AUTH_TIMEOUT_SECONDS", old[0]))
        self.addCleanup(lambda: setattr(server, "HEARTBEAT_SECONDS", old[1]))

    def connect(self):
        return self.client.websocket_connect("/stream/ticks?symbol=XAUUSD")

    def assertClosedWith(self, ws, code):
        from starlette.websockets import WebSocketDisconnect

        with self.assertRaises(WebSocketDisconnect) as ctx:
            ws.receive_json()
        self.assertEqual(ctx.exception.code, code)

    def test_a_correct_auth_message_opens_the_stream(self):
        with self.connect() as ws:
            ws.send_json({"type": "auth", "api_key": "test-key"})
            message = ws.receive_json()
        self.assertIn(message["type"], ("tick", "hb"))

    def test_a_wrong_key_is_closed_with_1008(self):
        with self.connect() as ws:
            ws.send_json({"type": "auth", "api_key": "wrong"})
            self.assertClosedWith(ws, 1008)

    def test_no_auth_message_is_closed_when_the_deadline_passes(self):
        with self.connect() as ws:
            self.assertClosedWith(ws, 1008)

    def test_a_key_in_the_url_does_not_authenticate(self):
        with self.client.websocket_connect("/stream/ticks?symbol=XAUUSD&api_key=test-key") as ws:
            self.assertClosedWith(ws, 1008)

    def test_the_first_message_must_be_an_auth_message(self):
        with self.connect() as ws:
            ws.send_json({"type": "subscribe", "api_key": "test-key"})
            self.assertClosedWith(ws, 1008)

    def test_malformed_first_messages_do_not_crash_the_server(self):
        with self.connect() as ws:
            ws.send_text("not json at all")
            self.assertClosedWith(ws, 1008)

    def test_ten_bad_handshakes_lock_the_client_out(self):
        for _ in range(10):
            with self.connect() as ws:
                ws.send_json({"type": "auth", "api_key": "wrong"})
                self.assertClosedWith(ws, 1008)
        with self.connect() as ws:
            ws.send_json({"type": "auth", "api_key": "test-key"})
            self.assertClosedWith(ws, 1008)


class OrderSanityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.RISK = DailyLossGuard(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        mt5.account_info.return_value = SimpleNamespace(equity=10000.0, balance=10000.0, login=1, server="s")
        mt5.history_deals_get.return_value = ()
        mt5.terminal_info.return_value = object()
        mt5.symbol_select.return_value = True
        # XAUUSD-like: $1 per tick of 0.01 per 1.00 lot at 100 oz -> tick_value 1.0, tick_size 0.01
        mt5.symbol_info.return_value = SimpleNamespace(filling_mode=2, trade_tick_value=1.0, trade_tick_size=0.01)
        mt5.symbol_info_tick.return_value = SimpleNamespace(ask=2000.2, bid=2000.0)
        mt5.positions_get.return_value = ()
        mt5.order_send.return_value = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, order=7, price=2000.2, comment="")
        server.CONFIG.update(
            {"mode": {"auto_trade": "auto"}}, base_revision=server.CONFIG.revision, confirm_risk_increase=True
        )

    def order(self, **over):
        body = {"symbol": "XAUUSD", "direction": "buy", "volume": 0.1, "stop_loss": 1990.2, "take_profit": 2020.2, **over}
        return self.client.post("/order/open", json=body, headers=H).json()

    def test_a_well_formed_order_passes(self):
        self.assertTrue(self.order()["success"])

    def test_orders_without_a_stop_or_target_are_refused(self):
        for over in ({"stop_loss": 0}, {"take_profit": 0}, {"stop_loss": -5}):
            r = self.order(**over)
            self.assertFalse(r["success"], over)
            self.assertIn("stop loss and a take profit", r["error"])
        mt5.order_send.assert_not_called()

    def test_a_stop_on_the_wrong_side_is_refused(self):
        r = self.order(stop_loss=2010.0)  # a BUY whose stop is ABOVE the price
        self.assertFalse(r["success"])
        self.assertIn("BUY needs", r["error"])
        sell = self.order(direction="sell", stop_loss=1990.0, take_profit=2020.0)
        self.assertFalse(sell["success"])
        self.assertIn("SELL needs", sell["error"])

    def test_a_target_on_the_wrong_side_is_refused(self):
        self.assertFalse(self.order(take_profit=1995.0)["success"])

    def test_a_stop_wider_than_the_rules_is_refused(self):
        r = self.order(stop_loss=1970.0)  # 302 pips vs the 200 pip rule
        self.assertFalse(r["success"])
        self.assertIn("beyond the allowed 200 pips", r["error"])

    def test_a_small_slippage_beyond_the_limit_is_tolerated(self):
        self.assertTrue(self.order(stop_loss=1980.1, volume=0.05)["success"])  # 201 pips, within the 20 pip drift allowance

    def test_an_order_that_risks_far_more_than_configured_is_refused(self):
        # 1% of 10,000 = 100 (x1.5 = 150 allowed). 2.0 lots with a 102 pip stop risks 2,040.
        r = self.order(volume=2.0)
        self.assertFalse(r["success"])
        self.assertIn("more than 1.5x", r["error"])
        mt5.order_send.assert_not_called()

    def test_the_minimum_lot_is_never_blocked_by_the_risk_cap(self):
        server.CONFIG.update({"account_limits": {"risk_percent_per_trade": 0.05}}, base_revision=server.CONFIG.revision)
        self.assertTrue(self.order(volume=0.01)["success"])

    def test_the_risk_cap_follows_the_configured_percentage(self):
        self.assertFalse(self.order(volume=0.5)["success"])  # 510 risked vs 150 allowed at 1%
        server.CONFIG.update(
            {"account_limits": {"risk_percent_per_trade": 2.0}}, base_revision=server.CONFIG.revision, confirm_risk_increase=True
        )
        self.assertFalse(self.order(volume=0.5)["success"])  # still 510 vs 300
        self.assertTrue(self.order(volume=0.25)["success"])  # 255 vs 300

    def test_an_order_is_refused_when_the_symbol_has_no_tick_value(self):
        # Right after connecting MT5 can report a tick value of 0; the risk cannot be measured, so nothing is sent.
        for info in (
            SimpleNamespace(filling_mode=2),
            SimpleNamespace(filling_mode=2, trade_tick_value=0.0, trade_tick_size=0.01),
            SimpleNamespace(filling_mode=2, trade_tick_value=1.0, trade_tick_size=0.0),
        ):
            mt5.symbol_info.return_value = info
            r = self.order(volume=0.1)
            self.assertFalse(r["success"])
            self.assertIn("tick value is not available", r["error"])
        mt5.order_send.assert_not_called()


class NotifyTests(unittest.TestCase):
    TOKEN = "123456789:ABCdefGHIjklMNOpqrSTUvwxYZ_0123456789"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        self.sent = []
        self.status = 200
        self.down = False

        def handler(request):
            if self.down:
                raise httpx.ConnectError("boom " + str(request.url))
            self.sent.append(request)
            return httpx.Response(self.status, json={"ok": True})

        server.TELEGRAM_TRANSPORT = httpx.MockTransport(handler)
        self.addCleanup(lambda: setattr(server, "TELEGRAM_TRANSPORT", _SAFE_TRANSPORT))
        self.saved = {k: os.environ.get(k) for k in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID")}
        self.addCleanup(self.restore_env)

    def restore_env(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def configure(self):
        os.environ["TELEGRAM_BOT_TOKEN"] = self.TOKEN
        os.environ["TELEGRAM_CHAT_ID"] = "424242"

    def notify(self, text="hello"):
        return self.client.post("/notify", json={"text": text}, headers=H)

    def test_requires_the_api_key(self):
        self.assertEqual(self.client.post("/notify", json={"text": "x"}).status_code, 401)

    def test_not_configured_sends_nothing(self):
        os.environ.pop("TELEGRAM_BOT_TOKEN", None)
        os.environ.pop("TELEGRAM_CHAT_ID", None)
        self.assertEqual(self.notify().json(), {"sent": False, "reason": "telegram_not_configured"})
        self.assertEqual(self.sent, [])

    def test_sends_to_the_configured_chat(self):
        self.configure()
        self.assertEqual(self.notify("Trade closed +120 pips").json(), {"sent": True})
        (req,) = self.sent
        self.assertIn("/sendMessage", str(req.url))
        import json as _json

        payload = _json.loads(req.content)
        self.assertEqual(payload["chat_id"], "424242")
        self.assertEqual(payload["text"], "Trade closed +120 pips")

    def test_long_messages_are_truncated_to_the_telegram_limit(self):
        self.configure()
        self.notify("x" * 9000)
        import json as _json

        self.assertEqual(len(_json.loads(self.sent[0].content)["text"]), 3500)

    def test_the_token_never_appears_in_a_response(self):
        self.configure()
        self.status = 401
        r = self.notify()
        self.assertEqual(r.json(), {"sent": False, "reason": "telegram_http_401"})
        self.assertNotIn(self.TOKEN, r.text)

    def test_an_unreachable_telegram_is_reported_without_leaking_the_token(self):
        self.configure()
        self.down = True
        with self.assertLogs("aureus_bridge", level="WARNING") as logs:
            r = self.notify()
        self.assertEqual(r.json(), {"sent": False, "reason": "telegram_unreachable"})
        self.assertNotIn(self.TOKEN, r.text)
        self.assertNotIn(self.TOKEN, " ".join(logs.output))


class LogRedactionTests(unittest.TestCase):
    def test_keys_in_urls_are_scrubbed_from_log_records_the_bridge_emits(self):
        with self.assertLogs("uvicorn.access", level="INFO") as logs:
            logging.getLogger("uvicorn.access").info('%s - "GET /candles?api_key=%s HTTP/1.1" 200', "127.0.0.1", "SECRETVALUE123")
        # assertLogs captures raw records; the filter runs on the logger, so check the formatted text too.
        self.assertNotIn("SECRETVALUE123", " ".join(r.getMessage() for r in logs.records))


class TelegramBridgeTests(unittest.TestCase):
    TOKEN = "123456789:ABCdefGHIjklMNOpqrSTUvwxYZ_0123456789"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.RISK = DailyLossGuard(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        mt5.account_info.return_value = SimpleNamespace(equity=10000.0, balance=10000.0, login=1, server="s")
        mt5.history_deals_get.return_value = ()
        mt5.terminal_info.return_value = object()
        mt5.symbol_info.return_value = SimpleNamespace(filling_mode=2)
        mt5.symbol_info_tick.return_value = SimpleNamespace(ask=2000.2, bid=2000.0)
        mt5.positions_get.return_value = ()
        mt5.order_send.return_value = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, order=1, price=2000.0, comment="")
        sleep = server.time.sleep
        server.time.sleep = lambda _s: None
        self.addCleanup(lambda: setattr(server.time, "sleep", sleep))
        self.sent = []
        server.TELEGRAM_TRANSPORT = httpx.MockTransport(self.capture)
        self.addCleanup(lambda: setattr(server, "TELEGRAM_TRANSPORT", _SAFE_TRANSPORT))
        self.saved = {k: os.environ.get(k) for k in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "TELEGRAM_ALLOWED_USER_IDS")}
        self.addCleanup(self.restore_env)

    def capture(self, request):
        import json as _json

        self.sent.append(_json.loads(request.content)["text"])
        return httpx.Response(200, json={"ok": True})

    def restore_env(self):
        for k, v in self.saved.items():
            os.environ[k] = v or ""

    def configure(self, chat="424242", users=""):
        os.environ["TELEGRAM_BOT_TOKEN"] = self.TOKEN
        os.environ["TELEGRAM_CHAT_ID"] = chat
        os.environ["TELEGRAM_ALLOWED_USER_IDS"] = users

    def position(self, ticket=1, kind=None, symbol="XAUUSD...", volume=0.5, profit=12.3):
        return SimpleNamespace(
            ticket=ticket,
            type=mt5.POSITION_TYPE_BUY if kind is None else kind,
            volume=volume,
            symbol=symbol,
            magic=20260920,
            price_open=2000.1,
            profit=profit,
        )

    def actions(self):
        return server._TelegramActions()

    def run_async(self, coro):
        return asyncio.run(coro)

    # ---- status ----------------------------------------------------------
    def test_status_summarises_state_account_loss_and_positions(self):
        mt5.positions_get.return_value = (self.position(ticket=7), self.position(ticket=8, kind=mt5.POSITION_TYPE_SELL))
        text = self.run_async(self.actions().status())
        self.assertIn("Trading: active", text)
        self.assertIn("equity 10000.00", text)
        self.assertIn("Daily loss: +0.00% of 3.00% limit", text)
        self.assertIn("Open positions (2)", text)
        self.assertIn("#7 BUY 0.5 XAUUSD... @ 2000.10  P/L +12.30", text)
        self.assertIn("#8 SELL", text)

    def test_status_shows_a_pause_and_a_lock(self):
        server.CONFIG.update({"mode": {"paused": True}}, base_revision=server.CONFIG.revision)
        mt5.account_info.return_value = SimpleNamespace(equity=10000.0, balance=10000.0, login=1, server="s")
        server._risk_status()
        mt5.account_info.return_value = SimpleNamespace(equity=9500.0, balance=10000.0, login=1, server="s")
        text = self.run_async(self.actions().status())
        self.assertIn("PAUSED", text)
        self.assertIn("LOCKED until 00:00 UTC", text)
        self.assertIn("Open positions: none", text)

    def test_status_copes_with_an_unreadable_account_and_positions(self):
        mt5.account_info.return_value = None
        mt5.positions_get.return_value = None
        text = self.run_async(self.actions().status())
        self.assertIn("unreadable", text)

    # ---- pause / resume --------------------------------------------------
    def test_pause_writes_the_config_as_telegram_and_is_audited(self):
        self.assertIn("PAUSED", self.run_async(self.actions().pause()))
        self.assertTrue(server.CONFIG.snapshot()["mode"]["paused"])
        entry = next(e for e in server.CONFIG.audit_tail() if e.get("action") == "update")
        self.assertEqual(entry["by"], "telegram")

    def test_pausing_twice_is_harmless(self):
        self.run_async(self.actions().pause())
        self.assertIn("PAUSED", self.run_async(self.actions().pause()))

    def test_resume_works_because_the_button_already_confirmed_it(self):
        self.run_async(self.actions().pause())
        self.assertIn("resumed", self.run_async(self.actions().resume()))
        self.assertFalse(server.CONFIG.snapshot()["mode"]["paused"])

    def test_resume_warns_that_a_daily_loss_lock_still_blocks_orders(self):
        server._risk_status()
        mt5.account_info.return_value = SimpleNamespace(equity=9500.0, balance=10000.0, login=1, server="s")
        server._risk_status()
        self.run_async(self.actions().pause())
        text = self.run_async(self.actions().resume())
        self.assertIn("daily loss lock is still active", text)

    def test_a_stale_revision_is_retried_once(self):
        real = server.CONFIG.update
        calls = []

        def flaky(*args, **kwargs):
            calls.append(1)
            if len(calls) == 1:
                from strategy_config import ConfigError

                raise ConfigError(409, "stale_revision", "stale")
            return real(*args, **kwargs)

        server.CONFIG.update = flaky
        self.assertIn("PAUSED", self.run_async(self.actions().pause()))
        self.assertEqual(len(calls), 2)

    def test_a_refused_config_change_is_reported_not_raised(self):
        def refuse(*args, **kwargs):
            from strategy_config import ConfigError

            raise ConfigError(429, "risk_increase_rate_limited", "At most 3 risk-increasing changes per hour.")

        server.CONFIG.update = refuse
        self.assertIn("At most 3", self.run_async(self.actions().resume()))

    # ---- close all / stop ------------------------------------------------
    def test_close_all_closes_every_position_and_says_how_many(self):
        mt5.positions_get.return_value = (self.position(ticket=1), self.position(ticket=2, symbol="EURUSD"))
        text = self.run_async(self.actions().close_all())
        self.assertEqual(text, "Closed 2/2 position(s).")
        self.assertEqual(mt5.order_send.call_count, 2)
        record = next(e for e in server.CONFIG.audit_tail() if e.get("action") == "close_all")
        self.assertEqual((record["by"], record["closed"]), ("telegram", 2))

    def test_close_all_names_the_positions_that_stayed_open(self):
        mt5.positions_get.return_value = (self.position(ticket=1), self.position(ticket=2))
        mt5.order_send.side_effect = [
            SimpleNamespace(retcode=10018, comment="Market closed", price=0),
            SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, comment="", price=2000.0),
        ]
        text = self.run_async(self.actions().close_all())
        self.assertIn("Closed 1/2", text)
        self.assertIn("STILL OPEN: #1 (retcode 10018: Market closed)", text)

    def test_close_all_with_nothing_open(self):
        self.assertEqual(self.run_async(self.actions().close_all()), "No open positions.")

    def test_close_all_reports_unreadable_positions(self):
        mt5.positions_get.return_value = None
        self.assertIn("Could not read open positions", self.run_async(self.actions().close_all()))

    def test_stop_pauses_and_closes(self):
        mt5.positions_get.return_value = (self.position(),)
        text = self.run_async(self.actions().stop())
        self.assertIn("PAUSED", text)
        self.assertIn("Closed 1/1", text)
        self.assertTrue(server.CONFIG.snapshot()["mode"]["paused"])

    # ---- bot construction ------------------------------------------------
    def test_no_credentials_means_no_bot(self):
        self.assertIsNone(server._build_telegram_bot())

    def test_a_private_chat_id_authorises_that_user(self):
        self.configure(chat="424242")
        bot = server._build_telegram_bot()
        self.assertIsNotNone(bot)
        self.assertTrue(bot._authorised(424242, 424242))
        self.assertFalse(bot._authorised(424242, 1))

    def test_a_group_chat_needs_explicit_user_ids(self):
        self.configure(chat="-1001234567890")
        self.assertIsNone(server._build_telegram_bot())
        self.configure(chat="-1001234567890", users="11, 22")
        bot = server._build_telegram_bot()
        self.assertTrue(bot._authorised(-1001234567890, 22))
        self.assertFalse(bot._authorised(-1001234567890, 33))

    def test_malformed_ids_disable_the_bot_instead_of_guessing(self):
        self.configure(chat="not-a-number")
        self.assertIsNone(server._build_telegram_bot())
        self.configure(chat="424242", users="11,abc")
        self.assertIsNone(server._build_telegram_bot())

    # ---- the bot driving the real actions --------------------------------
    def test_a_confirmed_closeall_from_the_owner_really_closes_the_positions(self):
        from test_telegram_bot import FakeApi, msg, press

        self.configure(chat="424242")
        mt5.positions_get.return_value = (self.position(),)
        bot = server._build_telegram_bot()
        api = FakeApi()
        bot._api = api
        bot._clock = lambda: 1_800_000_000.0

        async def drive():
            await bot.handle_update(msg("/closeall", chat=424242, user=424242))
            self.assertEqual(mt5.order_send.call_count, 0, "asking must not close anything")
            nonce = api.keyboards()[0][0][0]["callback_data"]
            await bot.handle_update(press(nonce, chat=424242, user=424242))
            await bot.handle_update(press(nonce, chat=424242, user=424242))  # double tap
            await bot.handle_update(msg("/closeall", chat=424242, user=999))  # a stranger

        self.run_async(drive())
        self.assertEqual(mt5.order_send.call_count, 1)
        self.assertEqual(api.edited(), ["Closed 1/1 position(s)."])

    # ---- alerts the bridge raises by itself -------------------------------
    def test_the_daily_loss_lock_is_announced_on_telegram(self):
        self.configure()
        server._risk_status()
        mt5.account_info.return_value = SimpleNamespace(equity=9500.0, balance=10000.0, login=1, server="s")
        server._risk_tick()
        self.assertEqual(len(self.sent), 1)
        self.assertIn("DAILY LOSS LIMIT HIT", self.sent[0])
        self.assertIn("5.00%", self.sent[0])
        server._risk_tick()
        self.assertEqual(len(self.sent), 1, "announced once, not every 5 seconds")

    def test_nothing_is_sent_when_telegram_is_not_configured(self):
        server._risk_status()
        mt5.account_info.return_value = SimpleNamespace(equity=9500.0, balance=10000.0, login=1, server="s")
        server._risk_tick()
        self.assertEqual(self.sent, [])

    def test_a_failing_telegram_never_breaks_the_risk_monitor(self):
        self.configure()
        server.TELEGRAM_TRANSPORT = httpx.MockTransport(lambda r: (_ for _ in ()).throw(httpx.ConnectError("down")))
        server._risk_status()
        mt5.account_info.return_value = SimpleNamespace(equity=9500.0, balance=10000.0, login=1, server="s")
        server._risk_tick()  # must not raise
        self.assertTrue(server.RISK.is_locked())

    def test_an_override_is_announced(self):
        self.configure()
        server._risk_status()
        mt5.account_info.return_value = SimpleNamespace(equity=9500.0, balance=10000.0, login=1, server="s")
        server._risk_status()
        self.client.post("/risk/override", json={"confirm": True, "updated_by": "tester"}, headers=H)
        self.assertTrue(any("OVERRIDDEN by tester" in m for m in self.sent))

    def test_the_token_is_never_in_a_log_line(self):
        self.configure()
        server.TELEGRAM_TRANSPORT = httpx.MockTransport(lambda r: httpx.Response(401, json={}))
        with self.assertLogs("aureus_bridge", level="WARNING") as logs:
            server._notify_event("hello")
        self.assertNotIn(self.TOKEN, " ".join(logs.output))


class ApprovalFlowTests(unittest.TestCase):
    UID = "rangingBounce|BUY|2000.20|1790000000000"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.now = server.time.time()
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.RISK = DailyLossGuard(Path(self.tmp.name))
        server.SIGNALS = SignalStore(Path(self.tmp.name), clock=lambda: self.now)
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        mt5.account_info.return_value = SimpleNamespace(equity=10000.0, balance=10000.0, login=1, server="s")
        mt5.history_deals_get.return_value = ()
        mt5.terminal_info.return_value = object()
        mt5.symbol_select.return_value = True
        mt5.symbol_info.return_value = SimpleNamespace(
            filling_mode=2, trade_tick_value=1.0, trade_tick_size=0.01, volume_step=0.01, volume_min=0.01, volume_max=100.0
        )
        self.set_price(ask=2000.2, bid=2000.0)
        mt5.positions_get.return_value = ()
        mt5.order_send.return_value = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, order=55, price=2000.2, comment="")
        sleep = server.time.sleep
        server.time.sleep = lambda _s: None
        self.addCleanup(lambda: setattr(server.time, "sleep", sleep))

        self.telegram = []
        self.telegram_up = True

        def handler(request):
            import json as _json

            if not self.telegram_up:
                raise httpx.ConnectError("down")
            body = _json.loads(request.content)
            self.telegram.append((request.url.path.rsplit("/", 1)[-1], body))
            return httpx.Response(200, json={"ok": True, "result": {"message_id": 99}})

        server.TELEGRAM_TRANSPORT = httpx.MockTransport(handler)
        self.addCleanup(lambda: setattr(server, "TELEGRAM_TRANSPORT", _SAFE_TRANSPORT))
        self.saved = {k: os.environ.get(k) for k in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID")}
        self.addCleanup(self.restore_env)
        os.environ["TELEGRAM_BOT_TOKEN"] = "123456789:ABCdefGHIjklMNOpqrSTUvwxYZ_0123456789"
        os.environ["TELEGRAM_CHAT_ID"] = "424242"
        server.CONFIG.update(
            {"mode": {"auto_trade": "approval"}}, base_revision=server.CONFIG.revision, confirm_risk_increase=True
        )

    def restore_env(self):
        for k, v in self.saved.items():
            os.environ[k] = v or ""

    def set_price(self, ask, bid=None):
        mt5.symbol_info_tick.return_value = SimpleNamespace(ask=ask, bid=ask - 0.2 if bid is None else bid)

    def body(self, **over):
        return {
            "uid": self.UID,
            "symbol": "XAUUSD",
            "direction": "BUY",
            "entry": 2000.2,
            "stop_loss": 1990.2,
            "take_profit": 2018.2,
            "volume": 0.5,
            "label": "15M Range Zone Bounce",
            "score": 84,
            "reason": "- Price reacted at the S/R confluence",
            **over,
        }

    def submit(self, **over):
        return self.client.post("/signals/pending", json=self.body(**over), headers=H)

    def sid(self, uid=None):
        return server.SIGNALS.get(uid or self.UID)["sid"]

    def messages(self, method="sendMessage"):
        return [b for m, b in self.telegram if m == method]

    # ---- submitting ------------------------------------------------------
    def test_a_proposal_asks_the_owner_with_two_buttons_and_trades_nothing(self):
        r = self.submit()
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["state"], "pending")
        (sent,) = self.messages()
        self.assertEqual(sent["chat_id"], "424242")
        self.assertIn("Trade approval needed", sent["text"])
        self.assertIn("BUY XAUUSD - 15M Range Zone Bounce", sent["text"])
        self.assertIn("Entry ~2000.20   SL 1990.20   TP 2018.20   R:R 1:1.8", sent["text"])
        self.assertIn("Confluence score 84/100", sent["text"])
        # flat $1.50 below the entry; above it the wider of $1.50 and 0.25 x the 10.00 stop distance
        self.assertIn("Taken only while the price stays within 1998.70 - 2002.70.", sent["text"])
        buttons = sent["reply_markup"]["inline_keyboard"][0]
        sid = self.sid()
        self.assertEqual([b["callback_data"] for b in buttons], [f"ap:{sid}", f"rj:{sid}"])
        mt5.order_send.assert_not_called()
        self.assertEqual(server.SIGNALS.get(self.UID)["message_id"], 99)

    def test_the_deadline_comes_from_the_config(self):
        self.submit()
        record = server.SIGNALS.get(self.UID)
        self.assertEqual(record["expires_at"] - record["created_at"], 90)
        server.CONFIG.update({"account_limits": {"approval_ttl_seconds": 45}}, base_revision=server.CONFIG.revision)
        self.submit(uid="other")  # slot busy - but ttl is read at submit time, checked below
        server.SIGNALS = SignalStore(tempfile.mkdtemp(), clock=lambda: self.now)
        self.submit()
        record = server.SIGNALS.get(self.UID)
        self.assertEqual(record["expires_at"] - record["created_at"], 45)

    def test_approval_mode_must_be_on(self):
        server.CONFIG.update({"mode": {"auto_trade": "off"}}, base_revision=server.CONFIG.revision)
        r = self.submit()
        self.assertEqual((r.status_code, r.json()["detail"]["code"]), (409, "approval_mode_off"))
        self.assertEqual(self.messages(), [])

    def test_without_telegram_nothing_is_proposed_because_nobody_could_approve(self):
        os.environ["TELEGRAM_BOT_TOKEN"] = ""
        r = self.submit()
        self.assertEqual((r.status_code, r.json()["detail"]["code"]), (409, "telegram_not_configured"))
        self.assertEqual(server.SIGNALS.live(), [])

    def test_a_retry_of_the_same_proposal_does_not_ask_twice(self):
        first = self.submit().json()
        second = self.submit().json()
        self.assertEqual((first["state"], second["state"]), ("pending", "pending"))
        self.assertEqual(len(self.messages()), 1)

    def test_only_one_proposal_may_wait_at_a_time(self):
        self.submit()
        r = self.submit(uid="another|SELL|1999.00|2")
        self.assertEqual((r.status_code, r.json()["detail"]["code"]), (409, "slot_busy"))
        self.assertEqual(len(self.messages()), 1)

    def test_a_proposal_the_bridge_would_refuse_anyway_is_never_asked_about(self):
        server.CONFIG.update({"mode": {"paused": True}}, base_revision=server.CONFIG.revision)
        body = self.submit().json()
        self.assertEqual(body["state"], "blocked")
        self.assertIn("paused", body["reason"])
        self.assertEqual(self.messages(), [])
        self.assertEqual(server.SIGNALS.live(), [])

    def test_a_signal_whose_price_has_already_run_away_is_blocked_at_once(self):
        self.set_price(ask=2004.0)  # $3.80 from the 2000.20 entry, limit is $1.50
        body = self.submit().json()
        self.assertEqual(body["state"], "blocked")
        self.assertIn("Price moved $3.80", body["reason"])

    def test_if_telegram_is_unreachable_nothing_is_left_waiting(self):
        self.telegram_up = False
        body = self.submit().json()
        self.assertEqual((body["state"], body["reason"]), ("failed", "telegram_unreachable"))
        self.assertEqual(server.SIGNALS.live(), [])
        self.assertEqual(server.SIGNALS.get(self.UID)["state"], "failed")

    def test_the_status_endpoint_reports_the_state_and_handles_awkward_uids(self):
        self.submit()
        r = self.client.get(f"/signals/{self.UID}", headers=H)
        self.assertEqual(r.status_code, 200)
        self.assertEqual((r.json()["uid"], r.json()["state"]), (self.UID, "pending"))
        self.assertNotIn("sid", r.json(), "the button secret is never sent back to the app")
        self.assertEqual(self.client.get("/signals/unknown|x", headers=H).status_code, 404)

    def test_the_signal_endpoints_need_the_api_key(self):
        self.assertEqual(self.client.post("/signals/pending", json=self.body()).status_code, 401)
        self.assertEqual(self.client.get("/signals/x").status_code, 401)

    # ---- approving -------------------------------------------------------
    def test_approving_trades_with_a_lot_sized_to_the_configured_risk(self):
        self.submit()
        text = server._approve_signal(self.sid(), "telegram:1")
        mt5.order_send.assert_called_once()
        sent = mt5.order_send.call_args[0][0]
        # 1% of 10,000 = 100; a 10.00 stop = 1,000 per lot -> 0.10 lots (the app proposed 0.5).
        self.assertEqual(sent["volume"], 0.1)
        self.assertEqual((sent["sl"], sent["tp"]), (1990.2, 2018.2))
        self.assertEqual(sent["comment"], f"AUR-{self.sid()}")
        self.assertIn("Executed: BUY XAUUSD 0.1 lots @ 2000.20", text)
        self.assertIn("ticket #55", text)
        record = server.SIGNALS.get(self.UID)
        self.assertEqual((record["state"], record["result"]["ticket"], record["decided_by"]), ("executed", 55, "telegram:1"))

    def test_the_lot_follows_todays_stop_distance_not_the_signals(self):
        self.submit()
        self.set_price(ask=2000.7, bid=2000.5)  # stop is now 10.50 away -> 100/1050 = 0.0952 -> 0.09
        server._approve_signal(self.sid(), "telegram:1")
        self.assertEqual(mt5.order_send.call_args[0][0]["volume"], 0.09)

    def test_the_lot_never_leaves_the_configured_range(self):
        server.CONFIG.update({"account_limits": {"max_lot": 0.05}}, base_revision=server.CONFIG.revision)
        self.submit()
        server._approve_signal(self.sid(), "telegram:1")
        self.assertEqual(mt5.order_send.call_args[0][0]["volume"], 0.05)

    def test_without_symbol_data_nothing_is_traded(self):
        # The lot cannot be sized without the broker's tick value, so approving must not guess.
        self.submit(volume=0.2)
        sid = self.sid()
        mt5.symbol_info.return_value = SimpleNamespace(filling_mode=2)
        text = server._approve_signal(sid, "telegram:1")
        self.assertIn("cannot be sized", text)
        mt5.order_send.assert_not_called()

    def test_a_double_tap_trades_exactly_once(self):
        self.submit()
        sid = self.sid()
        first = server._approve_signal(sid, "telegram:1")
        second = server._approve_signal(sid, "telegram:1")
        self.assertIn("Executed", first)
        self.assertIn("Already handled", second)
        self.assertEqual(mt5.order_send.call_count, 1)

    def test_concurrent_presses_trade_once(self):
        import threading

        self.submit()
        sid = self.sid()
        threads = [threading.Thread(target=server._approve_signal, args=(sid, f"u{i}")) for i in range(12)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(mt5.order_send.call_count, 1)

    def test_a_late_press_after_the_deadline_trades_nothing(self):
        self.submit()
        self.now += 91
        text = server._approve_signal(self.sid(), "telegram:1")
        self.assertIn("Already handled or expired", text)
        mt5.order_send.assert_not_called()

    def test_price_running_away_while_the_owner_decides_blocks_the_trade(self):
        self.submit()
        self.set_price(ask=2003.0)
        text = server._approve_signal(self.sid(), "telegram:1")
        self.assertIn("Blocked - nothing was traded", text)
        self.assertIn("Price moved", text)
        mt5.order_send.assert_not_called()
        self.assertEqual(server.SIGNALS.get(self.UID)["state"], "blocked")

    def test_a_pause_or_lock_that_arrives_before_approval_still_wins(self):
        self.submit()
        server.CONFIG.update({"mode": {"paused": True}}, base_revision=server.CONFIG.revision)
        self.assertIn("paused", server._approve_signal(self.sid(), "telegram:1"))
        mt5.order_send.assert_not_called()

    def test_a_daily_loss_lock_that_arrives_before_approval_still_wins(self):
        self.submit()
        mt5.account_info.return_value = SimpleNamespace(equity=9500.0, balance=10000.0, login=1, server="s")
        server._risk_status()
        text = server._approve_signal(self.sid(), "telegram:1")
        self.assertIn("Daily loss limit reached", text)
        mt5.order_send.assert_not_called()

    def test_switching_approval_mode_off_cancels_what_was_waiting(self):
        self.submit()
        server.CONFIG.update({"mode": {"auto_trade": "off"}}, base_revision=server.CONFIG.revision)
        self.assertIn("Orders are disabled", server._approve_signal(self.sid(), "telegram:1"))
        mt5.order_send.assert_not_called()

    def test_a_position_opened_meanwhile_blocks_a_second_one(self):
        self.submit()
        mt5.positions_get.return_value = (SimpleNamespace(ticket=9, comment="x"),)
        self.assertIn("already open", server._approve_signal(self.sid(), "telegram:1"))
        mt5.order_send.assert_not_called()

    def test_a_broker_rejection_is_reported_and_recorded(self):
        self.submit()
        mt5.order_send.return_value = SimpleNamespace(retcode=10018, comment="Market closed", price=0)
        text = server._approve_signal(self.sid(), "telegram:1")
        self.assertIn("Order failed: retcode 10018: Market closed", text)
        record = server.SIGNALS.get(self.UID)
        self.assertEqual(record["state"], "failed")

    def test_a_lost_reply_is_resolved_by_finding_the_position_instead_of_retrying(self):
        self.submit()
        sid = self.sid()
        mt5.order_send.side_effect = RuntimeError("socket reset")
        mt5.positions_get.side_effect = [
            (),  # the gate's position check before sending
            (SimpleNamespace(ticket=77, comment=f"AUR-{sid}", price_open=2000.25),),  # the lookup after the failure
        ]
        text = server._approve_signal(sid, "telegram:1")
        self.assertIn("ticket #77", text)
        self.assertEqual(server.SIGNALS.get(self.UID)["state"], "executed")
        self.assertEqual(mt5.order_send.call_count, 1, "never sent a second time")

    def test_a_lost_reply_with_no_position_is_a_failure_not_a_guess(self):
        self.submit()
        mt5.order_send.side_effect = RuntimeError("socket reset")
        text = server._approve_signal(self.sid(), "telegram:1")
        self.assertIn("Order failed", text)
        self.assertEqual(server.SIGNALS.get(self.UID)["state"], "failed")

    def test_an_unreachable_terminal_fails_cleanly(self):
        self.submit()
        mt5.terminal_info.return_value = None
        mt5.initialize.return_value = False
        server._last_init_attempt = 0.0
        text = server._approve_signal(self.sid(), "telegram:1")
        self.assertIn("Order failed", text)
        self.assertEqual(server.SIGNALS.get(self.UID)["state"], "failed")

    def test_every_decision_is_audited(self):
        self.submit()
        server._approve_signal(self.sid(), "telegram:1")
        actions = [e["action"] for e in server.CONFIG.audit_tail()]
        self.assertIn("approval_requested", actions)
        self.assertIn("approval_executed", actions)

    # ---- rejecting and expiring ------------------------------------------
    def test_rejecting_trades_nothing_and_frees_the_slot(self):
        self.submit()
        sid = self.sid()
        self.assertEqual(server._reject_signal(sid, "telegram:1"), "Rejected - nothing was traded.")
        mt5.order_send.assert_not_called()
        self.assertEqual(server.SIGNALS.get(self.UID)["state"], "rejected")
        self.assertEqual(self.submit(uid="next|SELL|1|3", direction="SELL", entry=2000.0, stop_loss=2010.0, take_profit=1982.0).json()["state"], "pending")

    def test_a_rejected_signal_cannot_be_approved_afterwards(self):
        self.submit()
        sid = self.sid()
        server._reject_signal(sid, "telegram:1")
        self.assertIn("Already handled", server._approve_signal(sid, "telegram:1"))
        mt5.order_send.assert_not_called()

    def test_an_unanswered_proposal_expires_and_its_message_is_edited(self):
        self.submit()
        self.now += 91
        server._expire_pending_signals()
        self.assertEqual(server.SIGNALS.get(self.UID)["state"], "expired")
        (edit,) = self.messages("editMessageText")
        self.assertEqual(edit["message_id"], 99)
        self.assertTrue(edit["text"].endswith("\n\nExpired - nothing was traded."), edit["text"])
        for detail in ("BUY XAUUSD - 15M Range Zone Bounce", "Entry ~2000.20   SL 1990.20   TP 2018.20", "Confluence score 84/100"):
            self.assertIn(detail, edit["text"], "the trade stays readable after it expires")
        self.assertNotIn("reply_markup", edit, "the buttons are dropped")
        server._expire_pending_signals()
        self.assertEqual(len(self.messages("editMessageText")), 1, "edited once")

    def test_a_record_from_before_the_text_was_stored_is_still_edited_with_its_details(self):
        self.submit()
        server.SIGNALS._records[self.UID].pop("message_text")
        self.now += 91
        server._expire_pending_signals()
        (edit,) = self.messages("editMessageText")
        self.assertIn("Entry ~2000.20   SL 1990.20   TP 2018.20", edit["text"])
        self.assertTrue(edit["text"].endswith("Expired - nothing was traded."))

    def test_a_proposal_still_waiting_when_the_bridge_restarts_is_edited_once_it_is_back(self):
        self.submit()
        self.now += 5
        server.SIGNALS = SignalStore(Path(self.tmp.name), clock=lambda: self.now)  # the restart
        self.assertEqual(server.SIGNALS.get(self.UID)["state"], "expired")
        self.assertEqual(self.messages("editMessageText"), [])
        server._edit_recovered_signals()
        (edit,) = self.messages("editMessageText")
        self.assertEqual(edit["message_id"], 99)
        self.assertIn("Entry ~2000.20   SL 1990.20   TP 2018.20", edit["text"])
        self.assertTrue(edit["text"].endswith("Expired - the bridge was restarted, nothing was traded."))
        server._edit_recovered_signals()
        self.assertEqual(len(self.messages("editMessageText")), 1, "only once")
        self.assertIn("approval_expired", [e["action"] for e in server.CONFIG.audit_tail()])

    # ---- the price window while the owner decides --------------------------------------------------------
    def approve(self):
        return server._approve_signal(self.sid(), "telegram:1")

    def test_an_approval_pressed_late_still_works_when_the_price_ran_a_little_in_the_trades_direction(self):
        self.submit()
        self.set_price(ask=2002.5, bid=2002.3)  # $2.30 above the entry: past the flat $1.50, inside 0.25 x 10.00
        text = self.approve()
        self.assertIn("Executed", text, text)
        sent = mt5.order_send.call_args[0][0]
        self.assertEqual((sent["sl"], sent["tp"]), (1990.2, 2018.2), "the stop and target do not move")
        # the lot follows the stop distance from where it is really filled: 100 / (12.30 x 100) -> 0.08
        self.assertEqual(sent["volume"], 0.08)

    def test_beyond_the_tolerance_the_trade_is_still_refused_and_the_message_names_the_limit(self):
        self.submit()
        self.set_price(ask=2002.8, bid=2002.6)  # $2.60: just past 0.25 x 10.00
        text = self.approve()
        self.assertIn("Blocked - nothing was traded", text)
        self.assertIn("Price moved $2.60 away from the signal (limit $2.50)", text)
        mt5.order_send.assert_not_called()

    def test_a_move_against_the_trade_keeps_the_flat_limit(self):
        self.submit()
        self.set_price(ask=1998.0, bid=1997.8)  # a BUY that already fell $2.20
        text = self.approve()
        self.assertIn("Price moved $2.20 away from the signal (limit $1.50)", text)
        mt5.order_send.assert_not_called()

    def test_the_tolerance_never_leaves_less_reward_than_risk(self):
        # 1:1.2 setup: only (12 - 10) / 2 = $1.00 of chasing keeps the reward at least equal to the risk,
        # which is below the flat $1.50, so the flat limit is what applies.
        self.submit(uid="tight|BUY|2000.20|1", take_profit=2012.2)
        self.set_price(ask=2001.9, bid=2001.7)
        record = server.SIGNALS.get("tight|BUY|2000.20|1")
        text = server._approve_signal(record["sid"], "telegram:1")
        self.assertIn("Price moved $1.70 away from the signal (limit $1.50)", text)

    def test_a_wide_setup_gets_the_full_quarter_of_its_stop(self):
        self.submit(uid="wide|BUY|2000.20|1", stop_loss=1985.2, take_profit=2027.2)  # risk 15, reward 27
        self.set_price(ask=2003.9, bid=2003.7)  # $3.70 <= 0.25 x 15.00 = $3.75 (and the stop stays under 200 pips)
        record = server.SIGNALS.get("wide|BUY|2000.20|1")
        self.assertIn("Executed", server._approve_signal(record["sid"], "telegram:1"))

    def test_the_tolerance_can_be_switched_off(self):
        server.CONFIG.update({"account_limits": {"entry_drift_chase_r": 0.0}}, base_revision=server.CONFIG.revision)
        self.submit()
        sent = self.messages()[0]["text"]
        self.assertIn("within 1998.70 - 2001.70.", sent, "only the flat $1.50 either way")
        self.set_price(ask=2002.0, bid=2001.8)
        self.assertIn("Price moved $1.80 away from the signal (limit $1.50)", self.approve())

    def test_a_sell_mirrors_the_window(self):
        self.submit(uid="s|SELL|2000.00|1", direction="SELL", entry=2000.0, stop_loss=2010.0, take_profit=1982.0)
        self.assertIn("within 1997.50 - 2001.50.", self.messages()[0]["text"])
        record = server.SIGNALS.get("s|SELL|2000.00|1")
        self.set_price(ask=1998.0, bid=1997.8)  # the bid fell $2.20 in the trade's direction
        self.assertIn("Executed", server._approve_signal(record["sid"], "telegram:1"))

    def test_a_sell_whose_price_rose_against_it_is_refused(self):
        self.submit(uid="s|SELL|2000.00|2", direction="SELL", entry=2000.0, stop_loss=2010.0, take_profit=1982.0)
        record = server.SIGNALS.get("s|SELL|2000.00|2")
        self.set_price(ask=2002.0, bid=2001.8)
        self.assertIn("Price moved $1.80 away from the signal (limit $1.50)", server._approve_signal(record["sid"], "telegram:1"))

    def test_direct_orders_are_refused_while_the_mode_is_approval(self):
        body = {"symbol": "XAUUSD", "direction": "buy", "volume": 0.1, "stop_loss": 1990.2, "take_profit": 2018.2}
        r = self.client.post("/order/open", json=body, headers=H).json()
        self.assertFalse(r["success"])
        self.assertIn("mode.auto_trade", r["error"])
        mt5.order_send.assert_not_called()


if __name__ == "__main__":
    unittest.main()


class FixesTests(unittest.TestCase):
    """Entry drift on direct orders, bridge-side lot sizing, strict minimum-lot risk, Telegram retries and
    the size/risk line in approval messages."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.SIGNALS = SignalStore(Path(self.tmp.name))
        server.RISK = DailyLossGuard(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        # EUR account, XAUUSD: 1 lot moves 100 USD per 1.00, i.e. 88.89 EUR at 1.125 -> tick value 0.8889 per 0.01 tick
        mt5.account_info.return_value = SimpleNamespace(equity=10000.0, balance=10000.0, login=1, server="s", currency="EUR")
        mt5.history_deals_get.return_value = ()
        mt5.terminal_info.return_value = object()
        mt5.symbol_select.return_value = True
        mt5.symbol_info.return_value = SimpleNamespace(
            filling_mode=2, trade_tick_value=0.8889, trade_tick_size=0.01, volume_step=0.01, volume_min=0.01, volume_max=100.0
        )
        mt5.symbol_info_tick.return_value = SimpleNamespace(ask=2000.2, bid=2000.0)
        mt5.positions_get.return_value = ()
        mt5.order_send.return_value = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, order=7, price=2000.2, comment="")
        server.CONFIG.update(
            {"mode": {"auto_trade": "auto"}}, base_revision=server.CONFIG.revision, confirm_risk_increase=True
        )

    def order(self, **over):
        body = {"symbol": "XAUUSD", "direction": "buy", "volume": 0.1, "stop_loss": 1990.2, "take_profit": 2020.2, **over}
        return self.client.post("/order/open", json=body, headers=H).json()

    def set_limits(self, **limits):
        server.CONFIG.update(
            {"account_limits": limits}, base_revision=server.CONFIG.revision, confirm_risk_increase=True
        )

    # --- entry drift on the direct path -------------------------------------------------------------
    def test_a_direct_order_is_refused_when_the_price_ran_away_from_the_signal(self):
        r = self.order(entry=1997.0)  # ask 2000.2 is $3.20 above the signal; the limit is $1.50
        self.assertFalse(r["success"])
        self.assertIn("Price moved $3.20", r["error"])
        mt5.order_send.assert_not_called()

    def test_a_direct_order_whose_price_ran_a_little_in_its_direction_is_still_taken(self):
        # entry 1998.5: the ask is $1.70 above it (flat limit $1.50), but 0.25 x the 8.30 stop distance is $2.075
        self.assertTrue(self.order(entry=1998.5)["success"])

    def test_the_direct_path_refuses_what_the_approval_path_refuses(self):
        r = self.order(entry=1998.0)  # $2.20 above; 0.25 x 7.80 = $1.95
        self.assertFalse(r["success"])
        self.assertIn("Price moved $2.20 away from the signal (limit $1.95)", r["error"])

    def test_a_direct_order_within_the_drift_limit_goes_through(self):
        self.assertTrue(self.order(entry=1999.5)["success"])  # $0.70 away

    def test_without_an_entry_the_drift_check_is_not_applied(self):
        self.assertTrue(self.order()["success"])

    def test_the_drift_limit_follows_the_config(self):
        self.set_limits(max_entry_drift_dollars=5.0)
        self.assertTrue(self.order(entry=1997.0)["success"])

    # --- the bridge sizes the lot, in the account's currency -----------------------------------------
    def test_bridge_sizing_risks_the_configured_percentage_of_equity_in_account_currency(self):
        # 1% of 10,000 EUR = 100 EUR. Stop 10.00 away -> 1000 ticks x 0.8889 EUR = 888.9 EUR per lot -> 0.1125 -> 0.11 lot
        r = self.order(volume=0.10, stop_loss=1990.2, bridge_sizing=True)
        self.assertTrue(r["success"], r)
        sent = mt5.order_send.call_args[0][0]["volume"]
        self.assertEqual(sent, r["volume"])
        self.assertEqual(sent, 0.11)  # 100 / (1000 ticks x 0.8889) = 0.1125 -> floored to the 0.01 step

    def test_bridge_sizing_corrects_a_caller_estimate_that_ignored_the_currency(self):
        # The app divides EUR equity by a USD pip value; the bridge knows the real tick value.
        r = self.order(volume=0.5, stop_loss=1995.2, bridge_sizing=True)  # a 5.00 stop: risk 100 EUR -> 0.22 lot
        self.assertTrue(r["success"], r)
        self.assertEqual(r["volume"], 0.22)

    def test_without_bridge_sizing_the_callers_volume_is_used_as_before(self):
        r = self.order(volume=0.07)
        self.assertEqual(r["volume"], 0.07)
        self.assertEqual(mt5.order_send.call_args[0][0]["volume"], 0.07)

    def test_bridge_sizing_refuses_when_it_cannot_size(self):
        mt5.symbol_info.return_value = SimpleNamespace(filling_mode=2, trade_tick_value=0.0, trade_tick_size=0.01)
        r = self.order(bridge_sizing=True)
        self.assertFalse(r["success"])
        self.assertIn("cannot be sized", r["error"])
        mt5.order_send.assert_not_called()

    def test_bridge_sizing_never_exceeds_the_configured_maximum_lot(self):
        self.set_limits(max_lot=0.05)
        r = self.order(volume=0.5, bridge_sizing=True)
        self.assertTrue(r["success"], r)
        self.assertEqual(r["volume"], 0.05)

    # --- strict minimum-lot risk ---------------------------------------------------------------------
    def test_the_smallest_lot_is_allowed_by_default_even_when_it_risks_more_than_the_limit(self):
        self.set_limits(risk_percent_per_trade=0.05)  # 5 EUR; one 0.01 lot with this stop risks 8.9 EUR
        self.assertTrue(self.order(volume=0.01)["success"])

    def test_strict_mode_refuses_the_smallest_lot_when_it_risks_too_much(self):
        self.set_limits(risk_percent_per_trade=0.05, strict_min_lot_risk=True)
        r = self.order(volume=0.01)
        self.assertFalse(r["success"])
        self.assertIn("strict_min_lot_risk", r["error"])
        mt5.order_send.assert_not_called()

    def test_strict_mode_still_allows_the_smallest_lot_when_the_risk_fits(self):
        self.set_limits(strict_min_lot_risk=True)  # 1% of 10,000 EUR is plenty for 0.01 lot
        self.assertTrue(self.order(volume=0.01)["success"])

    def test_turning_strict_mode_off_is_a_risk_increase(self):
        self.set_limits(strict_min_lot_risk=True)
        r = self.client.post(
            "/config/update",
            json={"base_revision": server.CONFIG.revision, "patch": {"account_limits": {"strict_min_lot_risk": False}}},
            headers=H,
        )
        self.assertEqual(r.status_code, 428)

    # --- Telegram retries ----------------------------------------------------------------------------
    def telegram(self, responses):
        calls = []

        def handler(request):
            calls.append(request)
            item = responses[min(len(calls) - 1, len(responses) - 1)]
            if isinstance(item, Exception):
                raise item
            return item

        sleeps = []
        old = (server.TELEGRAM_TRANSPORT, server.TELEGRAM_SLEEP, os.environ.get("TELEGRAM_BOT_TOKEN"), os.environ.get("TELEGRAM_CHAT_ID"))
        server.TELEGRAM_TRANSPORT = httpx.MockTransport(handler)
        server.TELEGRAM_SLEEP = sleeps.append
        os.environ["TELEGRAM_BOT_TOKEN"], os.environ["TELEGRAM_CHAT_ID"] = "1:abc", "5"

        def restore():
            server.TELEGRAM_TRANSPORT, server.TELEGRAM_SLEEP = old[0], old[1]
            os.environ["TELEGRAM_BOT_TOKEN"], os.environ["TELEGRAM_CHAT_ID"] = old[2] or "", old[3] or ""

        self.addCleanup(restore)
        return calls, sleeps

    def test_a_rate_limited_message_is_retried_after_the_wait_telegram_asks_for(self):
        calls, sleeps = self.telegram(
            [httpx.Response(429, json={"ok": False, "parameters": {"retry_after": 2}}), httpx.Response(200, json={"ok": True, "result": {"message_id": 9}})]
        )
        result = server._telegram_send("hello")
        self.assertTrue(result["sent"])
        self.assertEqual(len(calls), 2)
        self.assertEqual(sleeps, [2.0])

    def test_a_dropped_connection_is_retried(self):
        calls, _sleeps = self.telegram([httpx.ConnectError("down"), httpx.Response(200, json={"ok": True, "result": {"message_id": 1}})])
        self.assertTrue(server._telegram_send("hello")["sent"])
        self.assertEqual(len(calls), 2)

    def test_it_gives_up_after_three_attempts(self):
        calls, _sleeps = self.telegram([httpx.Response(503, json={"ok": False})])
        result = server._telegram_send("hello")
        self.assertEqual(result, {"sent": False, "reason": "telegram_http_503"})
        self.assertEqual(len(calls), 3)

    def test_a_bad_token_is_not_retried(self):
        calls, sleeps = self.telegram([httpx.Response(401, json={"ok": False})])
        self.assertEqual(server._telegram_send("hello")["reason"], "telegram_http_401")
        self.assertEqual(len(calls), 1)
        self.assertEqual(sleeps, [])

    def test_the_wait_is_capped(self):
        _calls, sleeps = self.telegram(
            [httpx.Response(429, json={"ok": False, "parameters": {"retry_after": 600}}), httpx.Response(200, json={"ok": True, "result": {}})]
        )
        server._telegram_send("hello")
        self.assertEqual(sleeps, [5.0])

    # --- approval message ----------------------------------------------------------------------------
    def test_the_approval_message_shows_the_size_and_the_risk(self):
        text = server._approval_text(
            {"direction": "BUY", "symbol": "XAUUSD", "entry": 2000.0, "stop_loss": 1990.0, "take_profit": 2018.0, "label": "x"},
            90,
            {"volume": 0.11, "amount": 97.78, "percent": 0.98, "currency": "EUR"},
        )
        self.assertIn("Size now ~0.11 lot", text)
        self.assertIn("risk ~97.78 EUR (0.98% of equity)", text)
        self.assertIn("re-sized when you approve", text)

    def test_the_approval_message_without_sizing_is_unchanged_in_substance(self):
        text = server._approval_text(
            {"direction": "BUY", "symbol": "XAUUSD", "entry": 2000.0, "stop_loss": 1990.0, "take_profit": 2018.0}, 90
        )
        self.assertNotIn("Size now", text)
        self.assertIn("Expires in 90 s", text)

    def test_the_proposal_sent_to_telegram_carries_the_computed_size_and_risk(self):
        calls, _sleeps = self.telegram([httpx.Response(200, json={"ok": True, "result": {"message_id": 3}})])
        server.CONFIG.update({"mode": {"auto_trade": "approval"}}, base_revision=server.CONFIG.revision, confirm_risk_increase=True)
        r = self.client.post(
            "/signals/pending",
            json={"uid": "u1", "symbol": "XAUUSD", "direction": "BUY", "entry": 2000.2, "stop_loss": 1990.2,
                  "take_profit": 2018.2, "volume": 0.5, "label": "Test", "score": 80, "reason": "r"},
            headers=H,
        )
        self.assertEqual(r.json()["state"], "pending", r.json())
        import json as _json

        sent_text = _json.loads(calls[0].content)["text"]
        self.assertIn("Size now ~0.11 lot", sent_text)
        self.assertIn("EUR", sent_text)


class LotModeTests(unittest.TestCase):
    """Dynamic vs fixed lot size. The fixed lot replaces the risk-percentage sizing, and nothing else: the daily
    loss limit (locked, or about to be passed by this trade's stop) and every other gate still decide first."""

    # 1 lot, a 10.00 stop = 1000 ticks x 0.8889 EUR = 888.9 EUR. Budget: 3% of 10,000 = 300 EUR.
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        server.CONFIG = ConfigStore(Path(self.tmp.name))
        server.RISK = DailyLossGuard(Path(self.tmp.name))
        server.SIGNALS = SignalStore(Path(self.tmp.name))
        server.AUTH_THROTTLE = AuthThrottle()
        self.client = TestClient(server.app)
        mt5.reset_mock(return_value=True, side_effect=True)
        self.account(10000.0)
        mt5.history_deals_get.return_value = ()
        mt5.terminal_info.return_value = object()
        mt5.symbol_select.return_value = True
        self.symbol(volume_step=0.01, volume_min=0.01, volume_max=100.0)
        mt5.symbol_info_tick.return_value = SimpleNamespace(ask=2000.2, bid=2000.0)
        mt5.positions_get.return_value = ()
        mt5.order_send.return_value = SimpleNamespace(retcode=mt5.TRADE_RETCODE_DONE, order=7, price=2000.2, comment="")
        server.CONFIG.update(
            {"mode": {"auto_trade": "auto"}}, base_revision=server.CONFIG.revision, confirm_risk_increase=True
        )

    # --- helpers -------------------------------------------------------------------------------------
    def account(self, equity):
        mt5.account_info.return_value = SimpleNamespace(
            equity=equity, balance=equity, login=1, server="s", currency="EUR"
        )

    def symbol(self, **over):
        values = dict(filling_mode=2, trade_tick_value=0.8889, trade_tick_size=0.01, volume_step=0.01, volume_min=0.01, volume_max=100.0)
        values.update(over)
        mt5.symbol_info.return_value = SimpleNamespace(**values)

    def limits(self, **limits):
        server.CONFIG.update({"account_limits": limits}, base_revision=server.CONFIG.revision, confirm_risk_increase=True)

    def fixed(self, lot):
        self.limits(lot_mode="fixed", fixed_lot_size=lot)

    def order(self, **over):
        body = {"symbol": "XAUUSD", "direction": "buy", "volume": 0.5, "stop_loss": 1990.2, "take_profit": 2020.2, **over}
        return self.client.post("/order/open", json=body, headers=H).json()

    def status(self):
        return self.client.get("/risk/status", headers=H).json()

    def sent_volume(self):
        return mt5.order_send.call_args[0][0]["volume"]

    # --- the fixed lot is what gets traded ------------------------------------------------------------
    def test_the_default_is_dynamic_with_a_fixed_lot_of_one_hundredth(self):
        limits = server.CONFIG.snapshot()["account_limits"]
        self.assertEqual((limits["lot_mode"], limits["fixed_lot_size"]), ("dynamic", 0.01))

    def test_dynamic_mode_still_uses_the_callers_volume_unless_the_bridge_sizes(self):
        r = self.order(volume=0.07)
        self.assertEqual((r["success"], r["volume"], self.sent_volume()), (True, 0.07, 0.07))

    def test_fixed_mode_trades_the_fixed_lot_whatever_volume_the_caller_sent(self):
        self.fixed(0.05)
        r = self.order(volume=0.5)  # the caller asked for 0.5
        self.assertTrue(r["success"], r)
        self.assertEqual((r["volume"], self.sent_volume()), (0.05, 0.05))

    def test_fixed_mode_also_overrides_bridge_sizing(self):
        self.fixed(0.05)
        r = self.order(volume=0.5, bridge_sizing=True)  # dynamic sizing would have given 0.11
        self.assertEqual((r["success"], r["volume"]), (True, 0.05))

    def test_the_fixed_lot_does_not_move_with_equity_or_stop_distance(self):
        self.fixed(0.05)
        self.account(100000.0)
        self.assertEqual(self.order(stop_loss=1995.2)["volume"], 0.05)
        self.assertEqual(self.order(stop_loss=1980.2)["volume"], 0.05)

    def test_dynamic_mode_after_switching_back_sizes_by_risk_again(self):
        self.fixed(0.05)
        self.limits(lot_mode="dynamic")
        self.assertEqual(self.order(volume=0.5, bridge_sizing=True)["volume"], 0.11)

    # --- fitting the fixed lot to the broker ----------------------------------------------------------
    def test_a_lot_between_steps_is_rounded_down_never_up(self):
        self.fixed(0.057)
        self.assertEqual(self.order()["volume"], 0.05)

    def test_a_coarser_broker_step_is_respected(self):
        self.symbol(volume_step=0.1, volume_min=0.1)
        self.fixed(0.25)
        self.assertEqual(self.order()["volume"], 0.2)

    def test_a_fixed_lot_below_the_brokers_minimum_is_refused_not_raised(self):
        self.symbol(volume_step=0.1, volume_min=0.1)
        self.fixed(0.05)
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("below this broker's minimum lot 0.1", r["error"])
        mt5.order_send.assert_not_called()

    def test_the_brokers_maximum_caps_the_fixed_lot(self):
        self.symbol(volume_max=0.03)
        self.fixed(0.05)
        self.assertEqual(self.order()["volume"], 0.03)

    # --- the daily loss limit comes first, in both modes ----------------------------------------------
    def test_a_locked_account_refuses_the_fixed_lot_too(self):
        self.fixed(0.01)
        self.status()
        self.account(9690.0)  # -3.1% locks the day
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("Daily loss limit reached", r["error"])
        mt5.order_send.assert_not_called()

    def test_a_fixed_lot_whose_stop_could_pass_the_limit_is_refused(self):
        self.fixed(0.5)  # 444 EUR at the stop vs a 300 budget
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("Daily loss limit: this trade could lose 444.45", r["error"])
        self.assertIn("300.00 left", r["error"])
        mt5.order_send.assert_not_called()
        self.assertFalse(self.status()["locked"])

    def test_the_same_lot_is_fine_while_the_budget_covers_it_and_refused_once_it_does_not(self):
        self.fixed(0.25)  # 222 EUR at the stop
        self.assertTrue(self.order()["success"])
        self.status()
        self.account(9900.0)  # -1%: 200 left
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("left before the 3.0% daily limit", r["error"])

    def test_a_smaller_fixed_lot_still_fits_after_a_loss(self):
        self.status()
        self.account(9900.0)
        self.fixed(0.2)  # 178 EUR <= 200 left
        self.assertTrue(self.order()["success"])

    def test_the_projection_is_part_of_dynamic_mode_too(self):
        self.status()
        self.account(9800.0)  # 100 EUR left
        r = self.order(volume=0.1, stop_loss=1989.2)  # 0.1 lot x 11.00 stop = 97.8 EUR: fits
        self.assertTrue(r["success"], r)
        r = self.order(volume=0.12, stop_loss=1989.2)  # 117 EUR: does not
        self.assertFalse(r["success"])
        self.assertIn("Daily loss limit: this trade could lose", r["error"])

    def test_the_limit_percentage_from_the_config_sets_the_budget(self):
        self.fixed(0.5)
        self.limits(max_daily_loss_percent=5.0)  # 500 EUR budget now covers the 444 EUR stop
        self.assertTrue(self.order()["success"])

    def test_after_the_daily_override_the_budget_restarts_from_the_new_baseline(self):
        self.fixed(0.25)
        self.status()
        self.account(9690.0)
        self.assertTrue(self.status()["locked"])
        self.assertFalse(self.order()["success"])
        ok = self.client.post("/risk/override", json={"confirm": True}, headers=H)
        self.assertEqual(ok.status_code, 200)
        self.assertTrue(self.order()["success"])  # 222 EUR against a fresh 3% of 9,690 = 290.7

    # --- the risk-% cap belongs to dynamic mode only --------------------------------------------------
    def test_an_explicit_lot_is_held_to_the_risk_cap_in_dynamic_mode_but_not_in_fixed_mode(self):
        r = self.order(volume=0.25)  # 222 EUR vs 1.5 x 1% = 150
        self.assertFalse(r["success"])
        self.assertIn("more than 1.5x", r["error"])
        self.fixed(0.25)
        self.assertTrue(self.order(volume=0.25)["success"])

    # --- every other gate still applies ---------------------------------------------------------------
    def test_fixed_mode_fails_closed_without_a_tick_value(self):
        self.fixed(0.05)
        self.symbol(trade_tick_value=0.0)
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("tick value is not available", r["error"])
        mt5.order_send.assert_not_called()

    def test_fixed_mode_fails_closed_when_the_account_is_unreadable(self):
        self.fixed(0.05)
        mt5.account_info.return_value = None
        r = self.order()
        self.assertFalse(r["success"])
        self.assertIn("equity is unreadable", r["error"])

    def test_fixed_mode_respects_the_pause(self):
        self.fixed(0.05)
        server.CONFIG.update({"mode": {"paused": True}}, base_revision=server.CONFIG.revision)  # pausing is free
        self.assertIn("paused", self.order()["error"])
        mt5.order_send.assert_not_called()

    def test_fixed_mode_respects_off_mode(self):
        self.fixed(0.05)
        server.CONFIG.update({"mode": {"auto_trade": "off"}}, base_revision=server.CONFIG.revision)
        self.assertIn("Orders are disabled", self.order()["error"])
        mt5.order_send.assert_not_called()

    def test_fixed_mode_respects_the_open_position_limit(self):
        self.fixed(0.05)
        mt5.positions_get.return_value = (SimpleNamespace(ticket=1),)
        self.assertIn("already open", self.order()["error"])
        mt5.order_send.assert_not_called()

    def test_fixed_mode_respects_the_spread_limit(self):
        self.fixed(0.05)
        mt5.symbol_info_tick.return_value = SimpleNamespace(ask=2005.2, bid=2000.0)  # a 52 pip spread
        self.assertIn("Spread", self.order()["error"])
        mt5.order_send.assert_not_called()

    def test_fixed_mode_still_checks_the_stop_and_the_price_drift(self):
        self.fixed(0.05)
        self.assertIn("BUY needs", self.order(stop_loss=2010.0)["error"])
        self.assertIn("Price moved", self.order(entry=1990.0)["error"])
        mt5.order_send.assert_not_called()

    # --- configuration --------------------------------------------------------------------------------
    def test_switching_to_a_fixed_lot_needs_the_risk_confirmation(self):
        r = self.client.post(
            "/config/update",
            json={"base_revision": server.CONFIG.revision, "patch": {"account_limits": {"lot_mode": "fixed"}}},
            headers=H,
        )
        self.assertEqual(r.status_code, 428)
        self.assertIn("account_limits.lot_mode", r.json()["detail"]["risk_increasing"])

    def test_the_config_is_published_with_its_bounds(self):
        body = self.client.get("/config", headers=H).json()
        self.assertEqual(body["bounds"]["account_limits.lot_mode"]["values"], ["dynamic", "fixed"])
        self.assertEqual(
            (body["bounds"]["account_limits.fixed_lot_size"]["min"], body["bounds"]["account_limits.fixed_lot_size"]["max"]),
            (0.01, 10.0),
        )

    # --- approval path --------------------------------------------------------------------------------
    def telegram(self):
        calls = []

        def handler(request):
            calls.append(request)
            return httpx.Response(200, json={"ok": True, "result": {"message_id": len(calls)}})

        old = (server.TELEGRAM_TRANSPORT, os.environ.get("TELEGRAM_BOT_TOKEN"), os.environ.get("TELEGRAM_CHAT_ID"))
        server.TELEGRAM_TRANSPORT = httpx.MockTransport(handler)
        os.environ["TELEGRAM_BOT_TOKEN"], os.environ["TELEGRAM_CHAT_ID"] = "1:abc", "5"

        def restore():
            server.TELEGRAM_TRANSPORT = old[0]
            os.environ["TELEGRAM_BOT_TOKEN"], os.environ["TELEGRAM_CHAT_ID"] = old[1] or "", old[2] or ""

        self.addCleanup(restore)
        return calls

    def propose(self, uid="u1", volume=0.5):
        server.CONFIG.update({"mode": {"auto_trade": "approval"}}, base_revision=server.CONFIG.revision, confirm_risk_increase=True)
        return self.client.post(
            "/signals/pending",
            json={"uid": uid, "symbol": "XAUUSD", "direction": "BUY", "entry": 2000.2, "stop_loss": 1990.2,
                  "take_profit": 2018.2, "volume": volume, "label": "Test", "score": 80, "reason": "r"},
            headers=H,
        ).json()

    def test_an_approved_trade_uses_the_fixed_lot_and_the_message_says_so(self):
        import json as _json

        calls = self.telegram()
        self.fixed(0.05)
        self.assertEqual(self.propose()["state"], "pending")
        text = _json.loads(calls[0].content)["text"]
        self.assertIn("Size now ~0.05 lot (fixed)", text)
        self.assertIn("fixed lot is re-checked when you approve", text)
        result = server._approve_signal(server.SIGNALS.get("u1")["sid"], "telegram:1")
        self.assertIn("Executed", result)
        self.assertEqual(self.sent_volume(), 0.05)

    def test_a_dynamic_proposal_still_reports_a_risk_sized_lot(self):
        import json as _json

        calls = self.telegram()
        self.assertEqual(self.propose()["state"], "pending")
        text = _json.loads(calls[0].content)["text"]
        self.assertIn("Size now ~0.11 lot - risk", text)
        self.assertNotIn("(fixed)", text)

    def test_a_proposal_is_blocked_when_the_fixed_lot_could_pass_the_daily_limit(self):
        self.telegram()
        self.fixed(0.5)
        r = self.propose()
        self.assertEqual(r["state"], "blocked")
        self.assertIn("Daily loss limit: this trade could lose", r["reason"])

    def test_an_approval_is_blocked_if_the_day_got_locked_after_the_proposal(self):
        self.telegram()
        self.fixed(0.05)
        self.status()
        self.assertEqual(self.propose()["state"], "pending")
        self.account(9690.0)  # the account fell past the limit while the proposal waited
        result = server._approve_signal(server.SIGNALS.get("u1")["sid"], "telegram:1")
        self.assertIn("Blocked", result)
        self.assertIn("Daily loss limit reached", result)
        mt5.order_send.assert_not_called()

    def test_an_approval_is_blocked_if_the_remaining_budget_shrank_below_the_trade(self):
        self.telegram()
        self.fixed(0.25)  # 222 EUR
        self.status()
        self.assertEqual(self.propose()["state"], "pending")
        self.account(9900.0)  # only 200 left by the time it is approved
        result = server._approve_signal(server.SIGNALS.get("u1")["sid"], "telegram:1")
        self.assertIn("Blocked", result)
        self.assertIn("left before the 3.0% daily limit", result)
        mt5.order_send.assert_not_called()

    def test_a_fixed_lot_below_the_brokers_minimum_blocks_the_proposal(self):
        self.telegram()
        self.symbol(volume_step=0.1, volume_min=0.1)
        self.fixed(0.05)
        r = self.propose()
        self.assertEqual(r["state"], "blocked")
        self.assertIn("below this broker's minimum lot", r["reason"])
