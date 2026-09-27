"""Alerts. LINE Notify was shut down in 2025, so LINE uses the Messaging API."""

from __future__ import annotations

import json
import logging
import os
import urllib.request

log = logging.getLogger(__name__)


class Notifier:
    def send(self, text: str) -> None:
        log.info("ALERT: %s", text)


class _HttpNotifier(Notifier):
    def _post(self, text: str, url: str, payload: dict, headers: dict[str, str] | None = None) -> None:
        super().send(text)
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", **(headers or {})},
        )
        try:
            urllib.request.urlopen(req, timeout=10).close()
        except Exception as e:  # alerts must never crash the trading loop
            log.warning("notification failed: %s", e)


class TelegramNotifier(_HttpNotifier):
    def __init__(self, token: str, chat_id: str):
        self.url = f"https://api.telegram.org/bot{token}/sendMessage"
        self.chat_id = chat_id

    def send(self, text: str) -> None:
        self._post(text, self.url, {"chat_id": self.chat_id, "text": text})


class LineNotifier(_HttpNotifier):
    def __init__(self, channel_access_token: str, to: str):
        self.token, self.to = channel_access_token, to

    def send(self, text: str) -> None:
        self._post(
            text,
            "https://api.line.me/v2/bot/message/push",
            {"to": self.to, "messages": [{"type": "text", "text": text}]},
            {"Authorization": f"Bearer {self.token}"},
        )


class MultiNotifier(Notifier):
    def __init__(self, notifiers: list[Notifier]):
        self.notifiers = notifiers

    def send(self, text: str) -> None:
        for n in self.notifiers:
            n.send(text)


def notifier_from_env() -> Notifier:
    ns: list[Notifier] = []
    if os.environ.get("TELEGRAM_BOT_TOKEN") and os.environ.get("TELEGRAM_CHAT_ID"):
        ns.append(TelegramNotifier(os.environ["TELEGRAM_BOT_TOKEN"], os.environ["TELEGRAM_CHAT_ID"]))
    if os.environ.get("LINE_CHANNEL_ACCESS_TOKEN") and os.environ.get("LINE_USER_ID"):
        ns.append(LineNotifier(os.environ["LINE_CHANNEL_ACCESS_TOKEN"], os.environ["LINE_USER_ID"]))
    return MultiNotifier(ns) if ns else Notifier()
