import asyncio
import unittest

from telegram_bot import HELP_TEXT, TelegramApi, TelegramBot, TelegramError

CHAT = 4242
USER = 4242
NOW = 1_800_000_000.0


class FakeApi:
    def __init__(self):
        self.calls = []
        self.queue = []  # scripted getUpdates results
        self.fail_next = []

    async def call(self, method, payload=None, *, timeout=15.0):
        self.calls.append((method, payload or {}))
        if method == "getUpdates":
            if self.fail_next:
                raise self.fail_next.pop(0)
            return self.queue.pop(0) if self.queue else []
        return {}

    def sent(self):
        return [p["text"] for m, p in self.calls if m == "sendMessage"]

    def edited(self):
        return [p["text"] for m, p in self.calls if m == "editMessageText"]

    def answered(self):
        return [p["text"] for m, p in self.calls if m == "answerCallbackQuery"]

    def keyboards(self):
        return [p["reply_markup"]["inline_keyboard"] for m, p in self.calls if m == "sendMessage" and "reply_markup" in p]


class FakeActions:
    def __init__(self):
        self.ran = []
        self.fail = False

    async def _do(self, name, text):
        if self.fail:
            raise RuntimeError("boom")
        self.ran.append(name)
        return text

    async def status(self):
        return await self._do("status", "STATUS TEXT")

    async def pause(self):
        return await self._do("pause", "Trading paused.")

    async def resume(self):
        return await self._do("resume", "Trading resumed.")

    async def close_all(self):
        return await self._do("closeall", "Closed 2/2 positions.")

    async def stop(self):
        return await self._do("stop", "Paused and closed 2/2.")

    async def approve(self, sid, by):
        self.ran.append(("approve", sid, by))
        if self.fail:
            raise RuntimeError("boom")
        return f"Executed {sid}"

    async def reject(self, sid, by):
        self.ran.append(("reject", sid, by))
        if self.fail:
            raise RuntimeError("boom")
        return f"Rejected {sid}"


def msg(text, *, chat=CHAT, user=USER, age=1.0, update_id=1):
    return {"update_id": update_id, "message": {"chat": {"id": chat}, "from": {"id": user}, "text": text, "date": NOW - age}}


def press(data, *, chat=CHAT, user=USER, update_id=2, message_id=77):
    return {
        "update_id": update_id,
        "callback_query": {"id": "cb1", "from": {"id": user}, "data": data, "message": {"chat": {"id": chat}, "message_id": message_id}},
    }


class BotCase(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.api = FakeApi()
        self.actions = FakeActions()
        self.now = NOW
        self.slept = []

        async def sleep(seconds):
            self.slept.append(seconds)

        self.bot = TelegramBot(
            self.api, self.actions, chat_id=CHAT, allowed_user_ids=[USER], clock=lambda: self.now, sleep=sleep, confirm_ttl=60
        )

    async def confirm_flow(self, command):
        await self.bot.handle_update(msg(command))
        (keyboard,) = self.api.keyboards()
        yes = keyboard[0][0]["callback_data"]
        no = keyboard[0][1]["callback_data"]
        return yes, no


class Authorisation(BotCase):
    async def test_the_whitelisted_user_gets_answers(self):
        await self.bot.handle_update(msg("/status"))
        self.assertEqual(self.api.sent(), ["STATUS TEXT"])

    async def test_strangers_are_ignored_in_silence(self):
        for update in (msg("/pause", user=999), msg("/closeall", chat=999, user=999), msg("/status", chat=999)):
            await self.bot.handle_update(update)
        self.assertEqual(self.api.calls, [], "no reply at all - the bot does not reveal itself")
        self.assertEqual(self.actions.ran, [])
        self.assertEqual(self.bot.ignored, 3)

    async def test_the_right_user_in_the_wrong_chat_is_ignored(self):
        await self.bot.handle_update(msg("/pause", chat=-100123, user=USER))
        self.assertEqual(self.actions.ran, [])

    async def test_another_member_of_the_right_chat_is_ignored(self):
        await self.bot.handle_update(msg("/pause", chat=CHAT, user=777))
        self.assertEqual(self.actions.ran, [])

    async def test_buttons_pressed_by_a_stranger_do_nothing(self):
        yes, _ = await self.confirm_flow("/closeall")
        self.api.calls.clear()
        await self.bot.handle_update(press(yes, user=999))
        await self.bot.handle_update(press(yes, chat=999))
        self.assertEqual(self.actions.ran, [])
        self.assertEqual(self.api.calls, [])

    async def test_a_stranger_cannot_burn_the_owners_pending_confirmation(self):
        yes, _ = await self.confirm_flow("/closeall")
        await self.bot.handle_update(press(yes, user=999))
        await self.bot.handle_update(press(yes))
        self.assertEqual(self.actions.ran, ["closeall"])

    async def test_non_command_text_is_ignored(self):
        await self.bot.handle_update(msg("hello"))
        self.assertEqual(self.api.calls, [])

    async def test_stale_messages_are_ignored(self):
        await self.bot.handle_update(msg("/pause", age=500))
        self.assertEqual(self.actions.ran, [])


class Commands(BotCase):
    async def test_pause_is_immediate(self):
        await self.bot.handle_update(msg("/pause"))
        self.assertEqual(self.actions.ran, ["pause"])
        self.assertEqual(self.api.sent(), ["Trading paused."])
        self.assertEqual(self.api.keyboards(), [])

    async def test_a_bot_name_suffix_and_capitals_are_accepted(self):
        await self.bot.handle_update(msg("/PAUSE@AureusBot"))
        self.assertEqual(self.actions.ran, ["pause"])

    async def test_help_and_start_list_the_commands(self):
        await self.bot.handle_update(msg("/help"))
        await self.bot.handle_update(msg("/start"))
        self.assertEqual(self.api.sent(), [HELP_TEXT, HELP_TEXT])

    async def test_unknown_commands_get_help_and_run_nothing(self):
        await self.bot.handle_update(msg("/format_disk"))
        self.assertIn("Unknown command", self.api.sent()[0])
        self.assertEqual(self.actions.ran, [])

    async def test_a_failing_action_is_reported_not_raised(self):
        self.actions.fail = True
        await self.bot.handle_update(msg("/status"))
        self.assertIn("/status failed", self.api.sent()[0])
        self.assertIn("boom", self.api.sent()[0])


class Confirmations(BotCase):
    async def test_dangerous_commands_only_ask(self):
        for command in ("/closeall", "/stop", "/resume"):
            self.api.calls.clear()
            await self.bot.handle_update(msg(command))
            self.assertEqual(len(self.api.keyboards()), 1, command)
        self.assertEqual(self.actions.ran, [], "nothing runs until the button is pressed")

    async def test_yes_runs_the_action_once_and_edits_the_message(self):
        yes, _ = await self.confirm_flow("/closeall")
        await self.bot.handle_update(press(yes))
        self.assertEqual(self.actions.ran, ["closeall"])
        self.assertEqual(self.api.edited(), ["Closed 2/2 positions."])
        self.assertEqual(self.api.answered(), ["Working..."])

    async def test_a_double_tap_runs_the_action_exactly_once(self):
        yes, _ = await self.confirm_flow("/closeall")
        await self.bot.handle_update(press(yes))
        await self.bot.handle_update(press(yes))
        await self.bot.handle_update(press(yes))
        self.assertEqual(self.actions.ran, ["closeall"])
        self.assertEqual(self.api.answered()[1:], ["Already handled or expired."] * 2)

    async def test_cancel_does_nothing_and_cannot_be_reused(self):
        yes, no = await self.confirm_flow("/stop")
        await self.bot.handle_update(press(no))
        self.assertEqual(self.api.edited(), ["Cancelled - nothing was done."])
        await self.bot.handle_update(press(yes))
        self.assertEqual(self.actions.ran, [])

    async def test_an_expired_confirmation_does_nothing(self):
        yes, _ = await self.confirm_flow("/closeall")
        self.now += 61
        await self.bot.handle_update(press(yes))
        self.assertEqual(self.actions.ran, [])
        self.assertEqual(self.api.edited(), ["Expired - nothing was done."])

    async def test_a_made_up_nonce_does_nothing(self):
        await self.bot.handle_update(press("ok:notarealnonce"))
        self.assertEqual(self.actions.ran, [])
        self.assertEqual(self.api.answered(), ["Already handled or expired."])

    async def test_each_command_confirms_its_own_action(self):
        for command, expected in (("/resume", "resume"), ("/stop", "stop"), ("/closeall", "closeall")):
            self.api.calls.clear()
            yes, _ = await self.confirm_flow(command)
            await self.bot.handle_update(press(yes))
            self.assertEqual(self.actions.ran[-1], expected)

    async def test_a_failing_confirmed_action_is_reported_in_the_message(self):
        yes, _ = await self.confirm_flow("/closeall")
        self.actions.fail = True
        await self.bot.handle_update(press(yes))
        self.assertIn("/closeall failed", self.api.edited()[0])

    async def test_unanswered_confirmations_are_capped(self):
        for _ in range(5):
            await self.bot.handle_update(msg("/closeall"))
        self.api.calls.clear()
        await self.bot.handle_update(msg("/closeall"))
        self.assertIn("Too many unanswered", self.api.sent()[0])
        self.assertEqual(self.api.keyboards(), [])

    async def test_expired_confirmations_free_their_slot(self):
        for _ in range(5):
            await self.bot.handle_update(msg("/closeall"))
        self.now += 120
        self.api.calls.clear()
        await self.bot.handle_update(msg("/closeall", age=1.0 - 120))
        self.assertEqual(len(self.api.keyboards()), 1)


class Approvals(BotCase):
    async def test_approve_calls_the_action_with_the_signal_id_and_who_pressed(self):
        await self.bot.handle_update(press("ap:abc123"))
        self.assertEqual(self.actions.ran, [("approve", "abc123", f"telegram:{USER}")])
        self.assertEqual(self.api.edited(), ["Executed abc123"])
        self.assertEqual(self.api.answered(), ["Working..."])

    async def test_reject_calls_the_action(self):
        await self.bot.handle_update(press("rj:abc123"))
        self.assertEqual(self.actions.ran, [("reject", "abc123", f"telegram:{USER}")])
        self.assertEqual(self.api.edited(), ["Rejected abc123"])

    async def test_the_proposals_own_text_stays_with_the_outcome_and_who_pressed(self):
        shown = "Trade approval needed\nBUY XAUUSD\nEntry ~2000.20   SL 1990.20   TP 2018.20   R:R 1:1.8"
        for data, outcome in (("ap:abc123", "Executed abc123"), ("rj:abc123", "Rejected abc123")):
            self.api.calls.clear()
            update = press(data)
            update["callback_query"]["message"]["text"] = shown
            update["callback_query"]["from"]["first_name"] = "Sam"
            await self.bot.handle_update(update)
            self.assertEqual(self.api.edited(), [f"{shown}\n\n{outcome}\n(by Sam)"])

    async def test_without_a_name_or_original_text_only_the_outcome_is_shown(self):
        update = press("rj:abc123")
        update["callback_query"]["message"]["text"] = "   "
        await self.bot.handle_update(update)
        self.assertEqual(self.api.edited(), ["Rejected abc123"])

    async def test_a_failed_approval_still_keeps_the_text(self):
        self.actions.fail = True
        update = press("ap:abc123")
        update["callback_query"]["message"]["text"] = "Trade approval needed\nBUY XAUUSD"
        await self.bot.handle_update(update)
        edited = self.api.edited()[0]
        self.assertTrue(edited.startswith("Trade approval needed\nBUY XAUUSD\n\nApproval failed"), edited)

    async def test_no_second_confirmation_is_asked_for_an_approval(self):
        await self.bot.handle_update(press("ap:abc123"))
        self.assertEqual(self.api.keyboards(), [])

    async def test_strangers_cannot_approve_or_reject(self):
        for data in ("ap:abc123", "rj:abc123"):
            await self.bot.handle_update(press(data, user=999))
            await self.bot.handle_update(press(data, chat=999))
        self.assertEqual(self.actions.ran, [])
        self.assertEqual(self.api.calls, [])

    async def test_a_failing_approval_is_reported_in_the_message(self):
        self.actions.fail = True
        await self.bot.handle_update(press("ap:abc123"))
        self.assertIn("Approval failed", self.api.edited()[0])
        await self.bot.handle_update(press("rj:abc123"))
        self.assertIn("Rejection failed", self.api.edited()[1])

    async def test_the_existing_confirmation_buttons_still_work_alongside(self):
        yes, _ = await self.confirm_flow("/closeall")
        await self.bot.handle_update(press(yes))
        self.assertEqual(self.actions.ran, ["closeall"])


class Polling(BotCase):
    async def run_until(self, polls):
        stop = asyncio.Event()
        original = self.api.call

        async def counting(method, payload=None, *, timeout=15.0):
            result = await original(method, payload, timeout=timeout)
            if method == "getUpdates" and sum(1 for m, _ in self.api.calls if m == "getUpdates") >= polls:
                stop.set()
            return result

        self.api.call = counting
        await asyncio.wait_for(self.bot.run(stop), timeout=5)

    async def test_the_backlog_is_dropped_so_old_commands_never_run_late(self):
        self.api.queue = [
            [msg("/closeall", update_id=10)],  # the offset=-1 probe: the newest queued update
            [msg("/status", update_id=11)],
        ]
        await self.run_until(2)
        first = self.api.calls[0]
        self.assertEqual(first[1]["offset"], -1)
        self.assertEqual(self.actions.ran, ["status"], "only the update that arrived AFTER start-up ran")
        self.assertEqual(self.api.calls[1][1]["offset"], 11)

    async def test_the_offset_moves_past_every_update_before_it_is_handled(self):
        self.api.queue = [[], [msg("/pause", update_id=20), msg("/status", update_id=21)], []]
        await self.run_until(3)
        self.assertEqual(self.actions.ran, ["pause", "status"])
        self.assertEqual(self.api.calls[-1][1]["offset"], 22)

    async def test_a_crashing_handler_never_replays_its_command(self):
        self.actions.fail = True
        self.api.queue = [[], [msg("/status", update_id=30)], []]
        await self.run_until(3)
        self.assertEqual(self.api.calls[-1][1]["offset"], 31)
        self.assertEqual(sum(1 for t in self.api.sent() if "/status failed" in t), 1)

    async def test_polling_errors_back_off_and_recover(self):
        self.api.fail_next = [TelegramError("getUpdates: HTTP 502"), TelegramError("getUpdates: ConnectError")]
        self.api.queue = [[], [msg("/status", update_id=40)]]
        await self.run_until(4)
        self.assertEqual(self.slept, [1.0, 2.0])
        self.assertEqual(self.actions.ran, ["status"])

    async def test_a_failed_reply_does_not_stop_the_loop(self):
        original = self.api.call

        async def flaky(method, payload=None, *, timeout=15.0):
            if method == "sendMessage":
                raise TelegramError("sendMessage: HTTP 500")
            return await original(method, payload, timeout=timeout)

        self.api.call = flaky
        self.api.queue = [[], [msg("/status", update_id=50)], [msg("/status", update_id=51)]]
        stop = asyncio.Event()
        polls = {"n": 0}
        inner = self.api.call

        async def counting(method, payload=None, *, timeout=15.0):
            if method == "getUpdates":
                polls["n"] += 1
                if polls["n"] >= 4:
                    stop.set()
            return await inner(method, payload, timeout=timeout)

        self.api.call = counting
        await asyncio.wait_for(self.bot.run(stop), timeout=5)
        self.assertEqual(self.actions.ran, ["status", "status"])


class ApiClient(unittest.IsolatedAsyncioTestCase):
    async def test_errors_never_contain_the_token(self):
        import httpx

        token = "123456789:ABCdefGHIjklMNOpqrSTUvwxYZ_0123456789"

        def handler(request):
            raise httpx.ConnectError("boom " + str(request.url))

        api = TelegramApi(token, transport=httpx.MockTransport(handler))
        with self.assertRaises(TelegramError) as ctx:
            await api.call("getMe")
        self.assertNotIn(token, str(ctx.exception))
        self.assertNotIn(token, repr(ctx.exception.__cause__))

    async def test_http_and_api_errors_are_reported_without_the_token(self):
        import httpx

        token = "999999999:ZZZdefGHIjklMNOpqrSTUvwxYZ_0123456789"
        api = TelegramApi(token, transport=httpx.MockTransport(lambda r: httpx.Response(401, json={})))
        with self.assertRaises(TelegramError) as ctx:
            await api.call("getMe")
        self.assertIn("HTTP 401", str(ctx.exception))
        self.assertNotIn(token, str(ctx.exception))
        refused = TelegramApi(
            token, transport=httpx.MockTransport(lambda r: httpx.Response(200, json={"ok": False, "description": "Conflict"}))
        )
        with self.assertRaises(TelegramError) as ctx:
            await refused.call("getUpdates")
        self.assertIn("Conflict", str(ctx.exception))

    async def test_returns_the_result_field(self):
        import httpx

        api = TelegramApi("1:x", transport=httpx.MockTransport(lambda r: httpx.Response(200, json={"ok": True, "result": [1, 2]})))
        self.assertEqual(await api.call("getUpdates"), [1, 2])


if __name__ == "__main__":
    unittest.main()
