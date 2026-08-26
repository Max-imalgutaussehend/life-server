#!/usr/bin/env python3
"""
notify.py — one-way courier: agent → operator's WhatsApp. (M16, ADR-0024)

WHY THIS EXISTS
    The CEO agent can think and read the board, but had no way to reach a
    human between runs. Paperclip is pull-only: the operator has to go and
    look. This is the push half.

    OpenClaw already holds the WhatsApp session and already proved it can
    send unprompted (M11), so the CEO borrows that channel rather than
    getting one of its own.

WHY A SEPARATE CONTAINER AND NOT A DOCKER SOCKET ON HERMES
    Sending through OpenClaw means `docker exec`, which means the Docker
    socket, which means host root (ADR-0023). Giving that to Hermes would
    create a SECOND container with full host access — and unlike OpenClaw,
    Hermes processes tickets typed into a web UI.

    This service holds the socket instead. It is the same shape as
    cliproxy-heartbeat: it is safe to hold a dangerous capability precisely
    because it runs a fixed script and never executes model-chosen code.
    It is a courier, not an agent.

WHAT IT WILL AND WILL NOT DO
    It sends text to ONE configured number, with a fixed prefix, capped in
    length. It does not read messages, does not take a recipient from the
    request, and never passes anything to a shell. The worst a prompt-injected
    agent achieves here is sending the operator a silly message.
"""

import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

# The recipient is configuration, never request input. An agent that could
# choose the number could use this to message anyone.
TARGET = os.environ["OPERATOR_WHATSAPP"]
CONTAINER = os.environ.get("OPENCLAW_CONTAINER", "prod-openclaw")

# Digits and nothing else. TARGET comes from the environment, but a typo there
# should fail loudly at start rather than produce a confusing CLI error on the
# first real notification.
if not re.fullmatch(r"\d{6,20}", TARGET):
    raise SystemExit(f"OPERATOR_WHATSAPP must be digits only, got {TARGET!r}")

# WhatsApp truncates long messages anyway, and an agent that pastes a whole
# log into a chat is worse than one that summarises. A screenful on a phone.
MAX_CHARS = 1500


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._reply(200, {"ok": True})
        else:
            self._reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/notify":
            return self._reply(404, {"error": "not found"})

        length = int(self.headers.get("Content-Length", 0))
        if length > 64_000:
            return self._reply(413, {"error": "too large"})

        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._reply(400, {"error": "invalid JSON"})

        text = (data.get("text") or "").strip()
        if not text:
            return self._reply(400, {"error": "field 'text' is required"})

        if len(text) > MAX_CHARS:
            text = text[:MAX_CHARS] + "\n[…truncated — see the board]"

        # The prefix is added HERE, not by the caller: the operator reads these
        # in their own self-chat alongside OpenClaw's own replies, and needs to
        # see at a glance which one is speaking.
        message = f"🧠 CEO: {text}"

        # A list, never a shell string. The message is agent-authored text and
        # must not be able to reach a shell — `shell=True` here would be a
        # command-injection hole with a chat box in front of it.
        try:
            result = subprocess.run(
                ["docker", "exec", CONTAINER,
                 "openclaw", "message", "send",
                 "--channel", "whatsapp",
                 # `--target` and `--message`, NOT `--to` and `--text`. Read
                 # off `openclaw message send --help`; the obvious guesses are
                 # both wrong and fail only at send time.
                 "--target", TARGET,
                 "--message", message],
                capture_output=True, text=True, timeout=60,
            )
        except subprocess.TimeoutExpired:
            return self._reply(504, {"error": "openclaw timed out"})

        if result.returncode != 0:
            return self._reply(502, {
                "error": "send failed",
                "detail": (result.stderr or result.stdout)[:300],
            })

        return self._reply(200, {"sent": True, "chars": len(text)})

    def log_message(self, fmt, *args):
        # Default logging writes the full request line to stderr. Message
        # bodies are the operator's private data; only outcomes are logged,
        # from the handlers above.
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8099), Handler).serve_forever()
