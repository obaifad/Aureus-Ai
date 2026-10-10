"""
Aureus AI - Telegram remote control
===================================
Long-polling bot that runs inside the bridge process. Pure Python + httpx (no
MetaTrader5 / FastAPI import): everything it can DO is injected as `actions`,
so every rule below is unit-testable with a fake Telegram and fake actions.

Safety rules
------------
* Only whitelisted Telegram USER ids are obeyed, and only in the whitelisted
  chat. Everyone else is ignored in silence (no reply reveals the bot).
* The pending backlog is DROPPED at start-up: an old "/closeall" typed while
  the bridge was offline is never executed late.
* Messages older than `max_age` seconds are ignored.
* The offset advances BEFORE a command runs, so a crashing handler can never
  replay a command.
* Commands that add risk or are destructive (/resume, /closeall, /stop) need a
  second tap on an inline button. Each button is single-use (a nonce), expires,
  and only the whitelisted user can press it - a double tap runs the action once.
"""

from __future__ import annotations

import asyncio
import logging
import secrets
import time
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Dict, Iterable, List, Optional, Protocol

import httpx

log = logging.getLogger("aureus_bridge")

HELP_TEXT = (
    "Aureus bridge commands\n"
    "/status - account, positions, daily loss, trading state\n"
    "/pause - stop all NEW trading now\n"
    "/resume - allow trading again (asks to confirm)\n"
    "/closeall - close every open position (asks to confirm)\n"
    "/stop - pause AND close everything (asks to confirm)\n"
    "/help - this message"
)

CONFIRMED_COMMANDS = {
    "resume": "Resume trading? New trades may open again.",
    "closeall": "Close ALL open positions at market price?",
    "stop": "EMERGENCY STOP: pause trading and close ALL open positions?",
}


class TelegramError(Exception):
    pass


class TelegramApi:
    """Thin Bot API client. Errors carry no URL, so the token cannot leak
    through an exception message."""

    def __init__(self, token: str, transport: Optional[httpx.AsyncBaseTransport] = None) -> None:
        self._token = token
        self._transport = transport

    async def call(self, method: str, payload: Optional[Dict[str, Any]] = None, *, timeout: float = 15.0) -> Any:
        url = f"https://api.telegram.org/bot{self._token}/{method}"
        try:
            async with httpx.AsyncClient(timeout=timeout, transport=self._transport) as client:
                response = await client.post(url, json=payload or {})
        except httpx.HTTPError as e:
            raise TelegramError(f"{method}: {type(e).__name__}") from None
        if response.status_code != 200:
            raise TelegramError(f"{method}: HTTP {response.status_code}")
        body = response.json()
        if not body.get("ok"):
            raise TelegramError(f"{method}: {body.get('description', 'not ok')}")
        return body.get("result")


class BotActions(Protocol):
    async def status(self) -> str: ...
    async def pause(self) -> str: ...
    async def resume(self) -> str: ...
    async def close_all(self) -> str: ...
    async def stop(self) -> str: ...
    async def approve(self, sid: str, by: str) -> str: ...
    async def reject(self, sid: str, by: str) -> str: ...


@dataclass
class _Pending:
    command: str
    user_id: int
    chat_id: int
    expires: float


class TelegramBot:
    def __init__(
        self,
        api: TelegramApi,
        actions: BotActions,
        *,
        chat_id: int,
        allowed_user_ids: Iterable[int],
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        poll_timeout: int = 25,
        confirm_ttl: float = 60.0,
        max_age: float = 90.0,
    ) -> None:
        self._api = api
        self._actions = actions
        self._chat_id = int(chat_id)
        self._users = {int(u) for u in allowed_user_ids}
        self._clock = clock
        self._sleep = sleep
        self._poll_timeout = poll_timeout
        self._confirm_ttl = confirm_ttl
        self._max_age = max_age
        self._offset = 0
        self._started = False
        self._pending: Dict[str, _Pending] = {}
        self.ignored = 0

    # ---- authorisation ----------------------------------------------------
    def _authorised(self, chat_id: Optional[int], user_id: Optional[int]) -> bool:
        return chat_id == self._chat_id and user_id in self._users

    # ---- sending ----------------------------------------------------------
    async def _send(self, text: str, keyboard: Optional[List[List[Dict[str, str]]]] = None) -> None:
        payload: Dict[str, Any] = {"chat_id": self._chat_id, "text": text[:3500]}
        if keyboard:
            payload["reply_markup"] = {"inline_keyboard": keyboard}
        await self._api.call("sendMessage", payload)

    async def _run(self, command: str) -> str:
        actions = {
            "status": self._actions.status,
            "pause": self._actions.pause,
            "resume": self._actions.resume,
            "closeall": self._actions.close_all,
            "stop": self._actions.stop,
        }
        try:
            return await actions[command]()
        except Exception as e:  # report to the user, never crash the bot
            log.warning("Telegram command /%s failed: %s", command, type(e).__name__)
            return f"/{command} failed: {type(e).__name__}: {e}"

    async def _run_approval(self, approving: bool, sid: str, by: str) -> str:
        try:
            return await (self._actions.approve if approving else self._actions.reject)(sid, by)
        except Exception as e:
            log.warning("Telegram approval failed: %s", type(e).__name__)
            return f"{'Approval' if approving else 'Rejection'} failed: {type(e).__name__}: {e}"

    # ---- updates ----------------------------------------------------------
    async def handle_update(self, update: Dict[str, Any]) -> None:
        if "message" in update:
            await self._on_message(update["message"])
        elif "callback_query" in update:
            await self._on_callback(update["callback_query"])

    async def _on_message(self, message: Dict[str, Any]) -> None:
        chat_id = (message.get("chat") or {}).get("id")
        user_id = (message.get("from") or {}).get("id")
        if not self._authorised(chat_id, user_id):
            self.ignored += 1
            return
        if self._clock() - float(message.get("date", 0)) > self._max_age:
            return
        text = (message.get("text") or "").strip()
        if not text.startswith("/"):
            return
        command = text.split()[0][1:].split("@")[0].lower()

        if command in ("help", "start"):
            await self._send(HELP_TEXT)
        elif command in ("status", "pause"):
            await self._send(await self._run(command))
        elif command in CONFIRMED_COMMANDS:
            await self._ask_to_confirm(command, int(user_id), int(chat_id))
        else:
            await self._send("Unknown command.\n\n" + HELP_TEXT)

    async def _ask_to_confirm(self, command: str, user_id: int, chat_id: int) -> None:
        now = self._clock()
        self._pending = {k: v for k, v in self._pending.items() if v.expires > now}
        if len(self._pending) >= 5:
            await self._send("Too many unanswered confirmations - answer or wait for them to expire.")
            return
        nonce = secrets.token_urlsafe(6)
        self._pending[nonce] = _Pending(command, user_id, chat_id, now + self._confirm_ttl)
        await self._send(
            f"{CONFIRMED_COMMANDS[command]}\n(expires in {int(self._confirm_ttl)} s)",
            keyboard=[[{"text": "Yes, do it", "callback_data": f"ok:{nonce}"}, {"text": "Cancel", "callback_data": f"no:{nonce}"}]],
        )

    async def _on_callback(self, query: Dict[str, Any]) -> None:
        message = query.get("message") or {}
        chat_id = (message.get("chat") or {}).get("id")
        user_id = (query.get("from") or {}).get("id")
        if not self._authorised(chat_id, user_id):
            self.ignored += 1
            return

        async def answer(text: str) -> None:
            await self._api.call("answerCallbackQuery", {"callback_query_id": query.get("id"), "text": text})

        async def finish(text: str) -> None:
            await self._api.call(
                "editMessageText", {"chat_id": chat_id, "message_id": message.get("message_id"), "text": text[:3500]}
            )

        data = str(query.get("data", ""))
        if data.startswith(("ap:", "rj:")):
            # Trade-approval buttons: single use is enforced by the signal store, not here.
            approving = data.startswith("ap:")
            await answer("Working..." if approving else "Rejecting...")
            result = await self._run_approval(approving, data[3:], f"telegram:{user_id}")
            # Keep the proposal's own text (entry, stop, target, why) in the chat, with the outcome and who
            # pressed the button underneath - in a shared group that is the record of who decided.
            who = str((query.get("from") or {}).get("first_name") or "").strip()
            original = str(message.get("text") or "").strip()
            outcome = f"{result}\n(by {who})" if who else result
            await finish(f"{original}\n\n{outcome}" if original else outcome)
            return

        verdict, _, nonce = data.partition(":")
        pending = self._pending.pop(nonce, None)  # pop = single use: a double tap finds nothing
        if pending is None or verdict not in ("ok", "no"):
            await answer("Already handled or expired.")
            return
        if pending.expires <= self._clock():
            await answer("Expired.")
            await finish("Expired - nothing was done.")
            return
        if pending.user_id != user_id or pending.chat_id != chat_id:
            await answer("Not yours.")
            return
        if verdict == "no":
            await answer("Cancelled.")
            await finish("Cancelled - nothing was done.")
            return
        await answer("Working...")
        await finish(await self._run(pending.command))

    # ---- polling ----------------------------------------------------------
    async def _skip_backlog(self) -> None:
        updates = await self._api.call("getUpdates", {"offset": -1, "timeout": 0})
        if updates:
            self._offset = int(updates[-1]["update_id"]) + 1
        self._started = True

    async def run(self, stop: Optional[asyncio.Event] = None) -> None:
        backoff = 1.0
        while not (stop is not None and stop.is_set()):
            try:
                if not self._started:
                    await self._skip_backlog()
                updates = await self._api.call(
                    "getUpdates",
                    {"offset": self._offset, "timeout": self._poll_timeout, "allowed_updates": ["message", "callback_query"]},
                    timeout=self._poll_timeout + 10,
                )
                backoff = 1.0
                for update in updates or []:
                    # Advance first: a handler that raises must never see the same command again.
                    self._offset = max(self._offset, int(update["update_id"]) + 1)
                    try:
                        await self.handle_update(update)
                    except TelegramError as e:
                        log.warning("Telegram reply failed: %s", e)
                    except Exception as e:
                        log.warning("Telegram update handler failed: %s", type(e).__name__)
            except asyncio.CancelledError:
                raise
            except TelegramError as e:
                log.warning("Telegram polling problem: %s - retrying in %.0fs", e, backoff)
                await self._sleep(backoff)
                backoff = min(backoff * 2, 30.0)
