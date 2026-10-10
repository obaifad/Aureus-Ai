import json
import tempfile
import threading
import unittest
from pathlib import Path

from signal_store import (
    BLOCKED,
    EXECUTED,
    EXECUTING,
    EXPIRED,
    FAILED,
    PENDING,
    REJECTED,
    SignalStore,
    SlotBusy,
)


class StoreCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.now = 1_000.0
        self.store = SignalStore(self.tmp.name, clock=lambda: self.now)

    def reopen(self):
        return SignalStore(self.tmp.name, clock=lambda: self.now)

    def submit(self, uid="a|BUY|2000|1", ttl=90):
        return self.store.submit({"uid": uid, "direction": "BUY", "entry": 2000.0}, ttl)


class Submit(StoreCase):
    def test_a_new_signal_waits_with_a_deadline_and_a_short_id(self):
        record, created = self.submit()
        self.assertTrue(created)
        self.assertEqual((record["state"], record["expires_at"]), (PENDING, 1090.0))
        self.assertTrue(0 < len(record["sid"]) <= 12, "must fit Telegram's 64 byte callback data")

    def test_submitting_the_same_uid_again_is_idempotent(self):
        first, _ = self.submit()
        second, created = self.submit()
        self.assertFalse(created)
        self.assertEqual(first["sid"], second["sid"])

    def test_only_one_signal_may_wait_at_a_time(self):
        self.submit("one")
        with self.assertRaises(SlotBusy):
            self.submit("two")

    def test_the_slot_frees_when_the_first_one_is_decided_or_times_out(self):
        record, _ = self.submit("one")
        self.store.reject(record["sid"], "me")
        self.submit("two")
        self.now += 100
        self.submit("three")  # "two" expired by now

    def test_a_signal_still_executing_keeps_the_slot_busy(self):
        record, _ = self.submit("one")
        self.store.claim(record["sid"], "me")
        with self.assertRaises(SlotBusy):
            self.submit("two")


class Claim(StoreCase):
    def test_claim_moves_pending_to_executing_exactly_once(self):
        record, _ = self.submit()
        first = self.store.claim(record["sid"], "telegram:1")
        second = self.store.claim(record["sid"], "telegram:1")
        self.assertEqual(first["state"], EXECUTING)
        self.assertEqual(first["decided_by"], "telegram:1")
        self.assertIsNone(second, "a double tap must not execute twice")

    def test_concurrent_claims_have_one_winner(self):
        record, _ = self.submit()
        wins = []

        def go(n):
            if self.store.claim(record["sid"], f"u{n}") is not None:
                wins.append(n)

        threads = [threading.Thread(target=go, args=(n,)) for n in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(wins), 1)

    def test_a_late_press_cannot_claim_an_expired_signal(self):
        record, _ = self.submit(ttl=90)
        self.now += 90
        self.assertIsNone(self.store.claim(record["sid"], "me"))
        self.assertEqual(self.store.get(record["uid"])["state"], EXPIRED)

    def test_unknown_ids_claim_nothing(self):
        self.assertIsNone(self.store.claim("nope", "me"))

    def test_a_rejected_signal_cannot_be_claimed(self):
        record, _ = self.submit()
        self.store.reject(record["sid"], "me")
        self.assertIsNone(self.store.claim(record["sid"], "me"))


class RejectAndExpire(StoreCase):
    def test_reject_is_final_and_single_use(self):
        record, _ = self.submit()
        self.assertEqual(self.store.reject(record["sid"], "me")["state"], REJECTED)
        self.assertIsNone(self.store.reject(record["sid"], "me"))

    def test_an_executing_signal_cannot_be_rejected(self):
        record, _ = self.submit()
        self.store.claim(record["sid"], "me")
        self.assertIsNone(self.store.reject(record["sid"], "me"))

    def test_expire_due_returns_only_newly_expired_signals(self):
        record, _ = self.submit(ttl=30)
        self.assertEqual(self.store.expire_due(), [])
        self.now += 31
        (expired,) = self.store.expire_due()
        self.assertEqual((expired["uid"], expired["state"], expired["decided_by"]), (record["uid"], EXPIRED, "timeout"))
        self.assertEqual(self.store.expire_due(), [], "reported once")

    def test_expiry_never_touches_a_signal_that_is_executing(self):
        record, _ = self.submit(ttl=30)
        self.store.claim(record["sid"], "me")
        self.now += 100
        self.assertEqual(self.store.expire_due(), [])
        self.assertEqual(self.store.get(record["uid"])["state"], EXECUTING)


class Finish(StoreCase):
    def test_executing_finishes_into_a_result(self):
        record, _ = self.submit()
        self.store.claim(record["sid"], "me")
        done = self.store.finish(record["uid"], EXECUTED, {"ticket": 77, "price": 2000.1})
        self.assertEqual((done["state"], done["result"]["ticket"]), (EXECUTED, 77))

    def test_blocked_and_failed_are_valid_outcomes(self):
        for state in (BLOCKED, FAILED):
            self.store = SignalStore(tempfile.mkdtemp(), clock=lambda: self.now)
            record, _ = self.submit()
            self.store.claim(record["sid"], "me")
            self.assertEqual(self.store.finish(record["uid"], state, {"error": "x"})["state"], state)

    def test_only_an_executing_signal_can_finish(self):
        record, _ = self.submit()
        self.assertIsNone(self.store.finish(record["uid"], EXECUTED, {}))
        self.assertIsNone(self.store.finish("unknown", EXECUTED, {}))

    def test_a_finished_signal_is_not_overwritten(self):
        record, _ = self.submit()
        self.store.claim(record["sid"], "me")
        self.store.finish(record["uid"], EXECUTED, {"ticket": 1})
        self.assertIsNone(self.store.finish(record["uid"], FAILED, {"error": "late"}))
        self.assertEqual(self.store.get(record["uid"])["state"], EXECUTED)

    def test_other_states_are_rejected_as_programming_errors(self):
        record, _ = self.submit()
        with self.assertRaises(ValueError):
            self.store.finish(record["uid"], PENDING, {})


class Persistence(StoreCase):
    def test_records_survive_a_restart(self):
        record, _ = self.submit()
        self.store.claim(record["sid"], "me")
        self.store.finish(record["uid"], EXECUTED, {"ticket": 5})
        reopened = self.reopen()
        self.assertEqual(reopened.get(record["uid"])["result"]["ticket"], 5)

    def test_nothing_stays_pending_across_a_restart(self):
        record, _ = self.submit()
        reopened = self.reopen()
        after = reopened.get(record["uid"])
        self.assertEqual((after["state"], after["decided_by"]), (EXPIRED, "bridge-restart"))
        self.assertIsNone(reopened.claim(record["sid"], "me"), "an old button can no longer execute")

    def test_the_message_text_is_kept_so_it_can_be_edited_later(self):
        record, _ = self.submit()
        self.store.set_message_id(record["uid"], 42, "Trade approval needed\nBUY")
        kept = self.reopen().get(record["uid"])
        self.assertEqual((kept["message_id"], kept["message_text"]), (42, "Trade approval needed\nBUY"))

    def test_the_message_text_is_optional_and_capped(self):
        record, _ = self.submit()
        self.store.set_message_id(record["uid"], 42)
        self.assertNotIn("message_text", self.store.get(record["uid"]))
        self.store.set_message_id(record["uid"], 42, "x" * 9000)
        self.assertEqual(len(self.store.get(record["uid"])["message_text"]), 3000)

    def test_proposals_that_were_waiting_at_a_restart_are_listed_for_their_message_to_be_edited(self):
        finished, _ = self.submit("finished")
        self.store.reject(finished["sid"], "me")
        waiting, _ = self.submit("waiting")
        self.store.set_message_id(waiting["uid"], 7, "text")
        reopened = self.reopen()
        self.assertEqual([r["uid"] for r in reopened.recovered], ["waiting"])
        self.assertEqual(reopened.recovered[0]["message_id"], 7)
        self.assertEqual(self.reopen().recovered, [], "a record that was already final is never listed twice")

    def test_a_signal_caught_mid_execution_is_reported_as_failed_with_a_warning(self):
        record, _ = self.submit()
        self.store.claim(record["sid"], "me")
        after = self.reopen().get(record["uid"])
        self.assertEqual(after["state"], FAILED)
        self.assertIn("check MetaTrader", after["result"]["error"])

    def test_a_corrupt_file_starts_empty(self):
        Path(self.tmp.name, "pending_signals.json").write_text("{ nope", encoding="utf-8")
        self.assertEqual(self.reopen().live(), [])

    def test_no_temp_file_is_left_behind(self):
        self.submit()
        self.assertEqual(list(Path(self.tmp.name).glob("*.tmp")), [])

    def test_the_file_is_valid_json_after_every_change(self):
        record, _ = self.submit()
        self.store.reject(record["sid"], "me")
        data = json.loads(Path(self.tmp.name, "pending_signals.json").read_text(encoding="utf-8"))
        self.assertEqual(data["records"][record["uid"]]["state"], REJECTED)

    def test_old_decided_records_are_pruned(self):
        for i in range(260):
            self.now += 1
            rec, _ = self.store.submit({"uid": f"s{i}"}, 5)
            self.store.reject(rec["sid"], "me")
        kept = json.loads(Path(self.tmp.name, "pending_signals.json").read_text(encoding="utf-8"))["records"]
        self.assertLessEqual(len(kept), 201)


class Lookups(StoreCase):
    def test_lookup_by_uid_and_by_sid_agree_and_return_copies(self):
        record, _ = self.submit()
        by_uid = self.store.get(record["uid"])
        by_sid = self.store.get_by_sid(record["sid"])
        self.assertEqual(by_uid, by_sid)
        by_uid["state"] = "tampered"
        self.assertEqual(self.store.get(record["uid"])["state"], PENDING)

    def test_unknown_lookups_return_none(self):
        self.assertIsNone(self.store.get("x"))
        self.assertIsNone(self.store.get_by_sid("x"))

    def test_live_lists_only_waiting_and_executing_signals(self):
        record, _ = self.submit()
        self.assertEqual(len(self.store.live()), 1)
        self.store.reject(record["sid"], "me")
        self.assertEqual(self.store.live(), [])


if __name__ == "__main__":
    unittest.main()
