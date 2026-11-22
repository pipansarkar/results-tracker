"""Push alerts via FCM topics (free). The app subscribes to `stock_<SYMBOL>`
when a user stars a stock, so no device tokens are stored anywhere."""
from __future__ import annotations

import logging
import re
from typing import Dict, Optional

log = logging.getLogger(__name__)


def topic_for(symbol: str) -> str:
    """Must match topicForSymbol() in lib/models/models.dart."""
    return "stock_" + re.sub(r"[^a-zA-Z0-9\-_.~]", "_", symbol)


class Notifier:
    def __init__(self, dry_run: bool):
        self.dry_run = dry_run
        self.sent = []

    def send(self, symbol: str, title: str, body: str,
             data: Optional[Dict[str, str]] = None) -> None:
        topic = topic_for(symbol)
        payload = {"symbol": symbol, **(data or {})}
        self.sent.append((topic, title, body))
        if self.dry_run:
            log.info("[push dry-run] %s | %s | %s", topic, title, body)
            return
        try:
            from firebase_admin import messaging
            messaging.send(messaging.Message(
                topic=topic,
                notification=messaging.Notification(title=title, body=body),
                data=payload,
                android=messaging.AndroidConfig(priority="high"),
            ))
        except Exception as e:  # never let a push failure stop the pipeline
            log.warning("push to %s failed: %s", topic, e)
