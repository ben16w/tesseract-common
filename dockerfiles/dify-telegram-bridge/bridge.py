#!/usr/bin/env python3
"""Relay Telegram messages to a Dify chatbot using long polling."""

import json
import logging
import os
import re
import threading
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

TELEGRAM_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
DIFY_API_KEY = os.environ.get("DIFY_APP_API_KEY", "")
DIFY_API_URL = os.environ.get("DIFY_API_URL", "http://dify_api:5001/v1").rstrip("/")
STATE_PATH = Path(os.environ.get("STATE_PATH", "/data/state.json"))
POLL_TIMEOUT = int(os.environ.get("POLL_TIMEOUT", "30"))
ALLOWED_USER_IDS = {
    int(value.strip())
    for value in os.environ.get("TELEGRAM_ALLOWED_USER_IDS", "").split(",")
    if value.strip()
}

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(message)s",
)
LOG = logging.getLogger("dify-telegram-bridge")
THINKING_BLOCK = re.compile(r"<think(?:ing)?\b[^>]*>.*?</think(?:ing)?>", re.IGNORECASE | re.DOTALL)
DIFY_UNAVAILABLE = "Service temporarily unavailable."


class DifyError(RuntimeError):
    pass


def request_json(url, payload, headers=None, timeout=60):
    request = Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", **(headers or {})},
        method="POST",
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except HTTPError as error:
        body = error.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {error.code} from {url}: {body[:500]}") from error
    except (URLError, TimeoutError) as error:
        raise RuntimeError(f"Request to {url} failed: {error}") from error


def telegram(method, payload, timeout=60):
    result = request_json(
        f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/{method}",
        payload,
        timeout=timeout,
    )
    if not result.get("ok"):
        raise RuntimeError(f"Telegram {method} failed: {result.get('description', 'unknown error')}")
    return result["result"]


def load_state():
    try:
        with STATE_PATH.open(encoding="utf-8") as state_file:
            state = json.load(state_file)
            state.setdefault("offset", 0)
            state.setdefault("conversations", {})
            return state
    except FileNotFoundError:
        return {"offset": 0, "conversations": {}}
    except (OSError, ValueError) as error:
        LOG.warning("Could not load state, starting fresh: %s", error)
        return {"offset": 0, "conversations": {}}


def save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = STATE_PATH.with_suffix(".tmp")
    with temporary_path.open("w", encoding="utf-8") as state_file:
        json.dump(state, state_file)
        state_file.flush()
        os.fsync(state_file.fileno())
    temporary_path.replace(STATE_PATH)


def strip_thinking(text):
    cleaned, count = THINKING_BLOCK.subn("", text)
    if count:
        LOG.info("Dropped %s thinking blocks", count)
    return re.sub(r"\n{3,}", "\n\n", cleaned).strip()


def keep_typing(chat_id, stop_event):
    while not stop_event.wait(4):
        try:
            telegram("sendChatAction", {"chat_id": chat_id, "action": "typing"})
        except Exception as error:
            LOG.warning("Could not refresh typing indicator: %s", error)


def send_message(chat_id, text):
    text = text or "(Dify returned an empty response.)"
    for start in range(0, len(text), 4096):
        telegram("sendMessage", {"chat_id": chat_id, "text": text[start:start + 4096]})


def ask_dify(chat_id, text, state):
    conversation_id = state["conversations"].get(str(chat_id), "")
    try:
        result = request_json(
            f"{DIFY_API_URL}/chat-messages",
            {
                "inputs": {},
                "query": text,
                "response_mode": "blocking",
                "conversation_id": conversation_id,
                "user": f"telegram-{chat_id}",
            },
            headers={"Authorization": f"Bearer {DIFY_API_KEY}"},
            timeout=300,
        )
        if result.get("conversation_id"):
            state["conversations"][str(chat_id)] = result["conversation_id"]
        return strip_thinking(result.get("answer", ""))
    except Exception as error:
        raise DifyError(str(error)) from error


def handle_message(message, state):
    chat_id = message.get("chat", {}).get("id")
    user_id = message.get("from", {}).get("id")
    text = message.get("text")

    if chat_id is None or user_id is None or not text:
        return
    if ALLOWED_USER_IDS and user_id not in ALLOWED_USER_IDS:
        LOG.warning("Ignoring message from unauthorized Telegram user %s", user_id)
        return
    LOG.info("Message from user telegram-%s", chat_id)
    if text.split(maxsplit=1)[0].split("@", 1)[0] in {"/start", "/new"}:
        state["conversations"].pop(str(chat_id), None)
        send_message(chat_id, "Started a new conversation.")
        return

    stop_typing = threading.Event()
    telegram("sendChatAction", {"chat_id": chat_id, "action": "typing"})
    threading.Thread(target=keep_typing, args=(chat_id, stop_typing), daemon=True).start()
    try:
        answer = ask_dify(chat_id, text, state)
    finally:
        stop_typing.set()
    send_message(chat_id, answer)


def validate_config():
    missing = []
    if not TELEGRAM_TOKEN:
        missing.append("TELEGRAM_BOT_TOKEN")
    if not DIFY_API_KEY:
        missing.append("DIFY_APP_API_KEY")
    if missing:
        raise SystemExit(f"Missing required environment variables: {', '.join(missing)}")


def main():
    validate_config()
    state = load_state()
    bot = telegram("getMe", {})
    telegram("deleteWebhook", {"drop_pending_updates": False})
    LOG.info("Polling Telegram as @%s", bot.get("username"))
    if not ALLOWED_USER_IDS:
        LOG.warning("TELEGRAM_ALLOWED_USER_IDS is empty; any Telegram user can use this bot")

    backoff = 1
    while True:
        try:
            updates = telegram(
                "getUpdates",
                {
                    "offset": state["offset"],
                    "timeout": POLL_TIMEOUT,
                    "allowed_updates": ["message"],
                },
                timeout=POLL_TIMEOUT + 10,
            )
            backoff = 1
            for update in updates:
                try:
                    handle_message(update.get("message", {}), state)
                except DifyError as error:
                    LOG.error("Dify request failed for update %s: %s", update["update_id"], error)
                    message = update.get("message", {})
                    if message.get("chat", {}).get("id") is not None:
                        try:
                            send_message(message["chat"]["id"], DIFY_UNAVAILABLE)
                        except Exception:
                            LOG.exception("Could not send failure message")
                except Exception as error:
                    LOG.exception("Failed to handle Telegram update %s: %s", update["update_id"], error)
                    message = update.get("message", {})
                    if message.get("chat", {}).get("id") is not None:
                        try:
                            send_message(message["chat"]["id"], "Sorry, the bridge could not process that message.")
                        except Exception:
                            LOG.exception("Could not send failure message")
                finally:
                    state["offset"] = update["update_id"] + 1
                    save_state(state)
        except Exception as error:
            LOG.error("Polling failed: %s; retrying in %ss", error, backoff)
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    main()
