"""Bounded proofreading gateway; provider credentials live only in the worker."""
from collections import deque
import json
import select
import socket
import threading
import time

MODEL = "gpt-6-luna"
EFFORT = "none"
MAX_BODY = 24 * 1024
MAX_CHARS = 6000
MAX_RESULT = 32 * 1024
TIMEOUT = 22
SOCKET_PATH = "/run/notchhub-correction/worker.sock"


class CorrectionCancelled(Exception):
    pass


class CorrectionError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def validate_text(value):
    if not isinstance(value, str) or not value.strip():
        raise CorrectionError(400, "Provide non-empty text.")
    if len(value) > MAX_CHARS or len(value.encode("utf-8")) > MAX_BODY:
        raise CorrectionError(413, "Text is too long (maximum 6000 characters).")
    return value


def validate_result(value):
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_CHARS * 2 or len(value.encode("utf-8")) > MAX_RESULT:
        raise CorrectionError(502, "Correction returned an invalid result.")
    return value


class UnixProvider:
    def __init__(self, path=SOCKET_PATH):
        self.path = path

    def __call__(self, text, timeout, cancelled=lambda: False):
        if cancelled():
            raise CorrectionCancelled()
        deadline = time.monotonic() + timeout
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            def budget():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError()
                connection.settimeout(remaining)
            budget()
            connection.connect(self.path)
            if cancelled():
                raise CorrectionCancelled()
            budget()
            connection.sendall(json.dumps({"text": text, "timeout": max(0, deadline - time.monotonic())}, ensure_ascii=False).encode() + b"\n")
            data = bytearray()
            while b"\n" not in data:
                if cancelled():
                    raise CorrectionCancelled()
                budget()
                if not select.select([connection], [], [], min(.05, deadline - time.monotonic()))[0]:
                    continue
                chunk = connection.recv(min(4096, MAX_RESULT * 2 + 1 - len(data)))
                if not chunk:
                    raise ValueError("Worker disconnected")
                data.extend(chunk)
                if len(data) > MAX_RESULT * 2:
                    raise ValueError("Worker result too large")
            result = json.loads(data)
            if result.get("error") == "busy":
                raise CorrectionError(429, "Correction is busy. Try again shortly.")
            if result.get("error") == "timeout":
                raise TimeoutError()
            if set(result) != {"text"}:
                raise ValueError("Invalid worker result")
            return validate_result(result["text"])


class CorrectionService:
    def __init__(self, provider=None, clock=time.monotonic):
        self.provider = provider if provider is not None else UnixProvider()
        self.clock = clock
        self.lock = threading.Lock()
        self.requests = deque()
        self.active = 0

    def correct(self, text, timeout=TIMEOUT, cancelled=lambda: False):
        validate_text(text)
        with self.lock:
            now = self.clock()
            while self.requests and self.requests[0] <= now - 86400:
                self.requests.popleft()
            if self.active >= 2:
                raise CorrectionError(429, "Correction is busy. Try again shortly.")
            if any(sum(t > now - window for t in self.requests) >= limit for window, limit in ((60, 10), (3600, 100), (86400, 500))):
                raise CorrectionError(429, "Correction limit reached. Try again later.")
            self.requests.append(now)
            self.active += 1
        try:
            return {"text": validate_result(self.provider(text, timeout, cancelled)), "model": MODEL, "effort": EFFORT}
        except (CorrectionError, CorrectionCancelled):
            raise
        except (TimeoutError, socket.timeout):
            raise CorrectionError(504, "Correction timed out. Try again.") from None
        except Exception:
            raise CorrectionError(502, "Correction is unavailable. Try again shortly.") from None
        finally:
            with self.lock:
                self.active -= 1
