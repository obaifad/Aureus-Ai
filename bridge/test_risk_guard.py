import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from risk_guard import DailyLossGuard, GuardError

D1 = datetime(2026, 10, 2, 9, 0, tzinfo=timezone.utc)
D2 = datetime(2026, 10, 3, 0, 5, tzinfo=timezone.utc)


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.guard = DailyLossGuard(self.tmp.name)

    def ev(self, equity, *, balance=10000.0, realized=0.0, limit=3.0, now=D1, guard=None):
        return (guard or self.guard).evaluate(
            equity=equity, balance=balance, realized_today=lambda: realized, limit_percent=limit, now=now
        )

    def test_baseline_is_the_day_start_balance_rebuilt_from_deals(self):
        # Balance is 10000 now after losing 200 realised today -> the day began at 10200.
        s = self.ev(10000.0, balance=10000.0, realized=-200.0)
        self.assertEqual((s["baseline"], s["baseline_source"]), (10200.0, "deals"))
        self.assertAlmostEqual(s["loss_percent"], 200 / 10200 * 100, places=2)

    def test_a_restart_mid_day_cannot_move_the_baseline(self):
        self.ev(10000.0, balance=10000.0, realized=-200.0)
        restarted = DailyLossGuard(self.tmp.name)
        s = self.ev(9900.0, balance=9900.0, realized=-300.0, guard=restarted)
        self.assertEqual(s["baseline"], 10200.0)

    def test_baseline_falls_back_to_first_equity_when_history_is_unreadable(self):
        s = self.guard.evaluate(equity=9950.0, balance=9950.0, realized_today=lambda: None, limit_percent=3.0, now=D1)
        self.assertEqual((s["baseline"], s["baseline_source"]), (9950.0, "first_seen"))

    def test_baseline_is_computed_once_per_day(self):
        calls = []
        for equity in (10000.0, 9990.0, 9980.0):
            self.guard.evaluate(
                equity=equity, balance=10000.0, realized_today=lambda: calls.append(1) or 0.0, limit_percent=3.0, now=D1
            )
        self.assertEqual(len(calls), 1)

    def test_no_lock_below_the_limit(self):
        self.ev(10000.0)
        s = self.ev(9750.0)  # -2.5% of 3%
        self.assertFalse(s["locked"])
        self.assertTrue(s["can_trade"])
        self.assertFalse(s["newly_locked"])

    def test_locks_exactly_at_the_limit_and_reports_it_once(self):
        self.ev(10000.0)
        tripped = self.ev(9700.0)  # -3.0%
        self.assertTrue(tripped["locked"])
        self.assertTrue(tripped["newly_locked"])
        self.assertFalse(tripped["can_trade"])
        self.assertEqual(tripped["locked_loss_percent"], 3.0)
        again = self.ev(9650.0)
        self.assertTrue(again["locked"])
        self.assertFalse(again["newly_locked"], "the trip is reported only on the evaluation that causes it")

    def test_floating_losses_count_not_just_realised_ones(self):
        self.ev(10000.0)
        self.assertTrue(self.ev(9600.0, balance=10000.0)["locked"])  # balance unchanged, equity down

    def test_the_lock_is_sticky_even_if_equity_recovers(self):
        self.ev(10000.0)
        self.ev(9600.0)
        recovered = self.ev(10100.0)
        self.assertTrue(recovered["locked"])
        self.assertFalse(recovered["can_trade"])

    def test_a_zero_limit_never_locks(self):
        self.ev(10000.0, limit=0)
        self.assertFalse(self.ev(5000.0, limit=0)["locked"])

    def test_tightening_the_limit_can_trip_the_lock_but_loosening_does_not_release_it(self):
        self.ev(10000.0)
        self.assertTrue(self.ev(9800.0, limit=1.5)["locked"])
        self.assertTrue(self.ev(9800.0, limit=5.0)["locked"])

    def test_a_new_utc_day_resets_everything(self):
        self.ev(10000.0)
        self.ev(9600.0)
        s = self.ev(9600.0, balance=9600.0, realized=0.0, now=D2)
        self.assertFalse(s["locked"])
        self.assertEqual(s["baseline"], 9600.0)
        self.assertEqual(s["day"], "2026-10-03")

    def test_the_day_boundary_is_utc_not_local_time(self):
        late = datetime(2026, 10, 2, 23, 59, tzinfo=timezone(timedelta(hours=-5)))  # = 04:59 UTC on the 3rd
        self.assertEqual(self.ev(10000.0, now=late)["day"], "2026-10-03")

    def test_state_survives_a_restart_including_the_lock(self):
        self.ev(10000.0)
        self.ev(9600.0)
        reloaded = DailyLossGuard(self.tmp.name)
        self.assertTrue(reloaded.is_locked(D1))
        self.assertFalse(reloaded.is_locked(D2), "a lock from yesterday means nothing today")

    def test_a_corrupt_state_file_starts_clean_instead_of_crashing(self):
        Path(self.tmp.name, "risk_state.json").write_text("{ not json", encoding="utf-8")
        guard = DailyLossGuard(self.tmp.name)
        self.assertFalse(guard.is_locked(D1))

    def test_no_temp_file_is_left_behind(self):
        self.ev(10000.0)
        self.assertEqual(list(Path(self.tmp.name).glob("*.tmp")), [])

    def test_breach_action_bookkeeping(self):
        self.ev(10000.0)
        self.assertFalse(self.guard.actions_pending())
        self.ev(9600.0)
        self.assertTrue(self.guard.actions_pending())
        self.guard.mark_actions_done()
        self.assertFalse(self.guard.actions_pending())
        self.assertTrue(DailyLossGuard(self.tmp.name).snapshot()["breach_actions_done"])


class OverrideTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.guard = DailyLossGuard(self.tmp.name)

    def trip(self, now=D1):
        self.guard.evaluate(equity=10000.0, balance=10000.0, realized_today=lambda: 0.0, limit_percent=3.0, now=now)
        return self.guard.evaluate(equity=9600.0, balance=10000.0, realized_today=lambda: 0.0, limit_percent=3.0, now=now)

    def test_override_rebases_to_current_equity_and_unlocks(self):
        self.trip()
        self.guard.override(equity=9600.0, now=D1)
        s = self.guard.evaluate(equity=9600.0, balance=9600.0, realized_today=lambda: 0.0, limit_percent=3.0, now=D1)
        self.assertFalse(s["locked"])
        self.assertEqual((s["baseline"], s["baseline_source"], s["overrides_today"]), (9600.0, "override", 1))
        self.assertEqual(s["loss_percent"], 0.0)

    def test_after_an_override_the_next_full_loss_locks_again(self):
        self.trip()
        self.guard.override(equity=9600.0, now=D1)
        s = self.guard.evaluate(equity=9300.0, balance=9600.0, realized_today=lambda: 0.0, limit_percent=3.0, now=D1)
        self.assertTrue(s["locked"])  # 9300 is 3.1% below the new 9600 baseline

    def test_only_one_override_per_day(self):
        self.trip()
        self.guard.override(equity=9600.0, now=D1)
        self.guard.evaluate(equity=9300.0, balance=9600.0, realized_today=lambda: 0.0, limit_percent=3.0, now=D1)
        with self.assertRaises(GuardError) as ctx:
            self.guard.override(equity=9300.0, now=D1)
        self.assertIn("already used", str(ctx.exception))

    def test_cannot_override_when_not_locked(self):
        self.guard.evaluate(equity=10000.0, balance=10000.0, realized_today=lambda: 0.0, limit_percent=3.0, now=D1)
        with self.assertRaises(GuardError):
            self.guard.override(equity=10000.0, now=D1)

    def test_the_override_budget_renews_the_next_day(self):
        self.trip()
        self.guard.override(equity=9600.0, now=D1)
        self.trip(now=D2)
        self.guard.override(equity=9600.0, now=D2)  # does not raise

    def test_the_override_is_persisted(self):
        self.trip()
        self.guard.override(equity=9600.0, now=D1)
        saved = json.loads(Path(self.tmp.name, "risk_state.json").read_text(encoding="utf-8"))
        self.assertEqual((saved["overrides"], saved["locked"], saved["baseline"]), (1, False, 9600.0))


if __name__ == "__main__":
    unittest.main()
