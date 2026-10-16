#!/usr/bin/env python3
"""Temporary encrypted blobs, with direct TLS or a loopback reverse proxy."""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import ssl
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = re.compile(r"[A-Za-z0-9_-]{43}\Z")
MAX_REQUEST = 90 * 1024 * 1024
MAX_BYTES = 200 * 1024 * 1024
MAX_TRANSFERS = 20
TTL = 3600


class TransferStore:
    def __init__(self, root, clock=time.time, max_bytes=MAX_BYTES, max_transfers=MAX_TRANSFERS, ttl=TTL):
        self.root = Path(root)
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.root.is_symlink():
            raise ValueError("Storage must not be a symlink")
        os.chmod(self.root, 0o700)
        self.clock, self.max_bytes, self.max_transfers, self.ttl = clock, max_bytes, max_transfers, ttl
        self.lock = threading.RLock()
        self.entries = {}
        self.readers = {}
        self.reserved_bytes = self.reserved_count = 0
        for metadata in self.root.glob("*.json"):
            token = metadata.stem
            if not TOKEN.fullmatch(token) or metadata.is_symlink():
                continue
            try:
                entry = json.loads(metadata.read_text())
                blob = self.root / (token + ".blob")
                if isinstance(entry.get("size"), int) and 0 < entry["size"] <= MAX_REQUEST and isinstance(entry.get("expires"), (int, float)) and not blob.is_symlink() and blob.is_file() and blob.stat().st_size == entry["size"]:
                    self.entries[token] = entry
            except (OSError, ValueError, KeyError, TypeError):
                pass
        self.cleanup()
        # Uncommitted files from interrupted uploads never become downloadable.
        for file in self.root.glob("upload-*"):
            if file.is_file() and not file.is_symlink():
                file.unlink(missing_ok=True)
        for blob in self.root.glob("*.blob"):
            if TOKEN.fullmatch(blob.stem) and blob.stem not in self.entries:
                blob.unlink(missing_ok=True)

    def cleanup(self):
        with self.lock:
            now = self.clock()
            for token, entry in list(self.entries.items()):
                if entry["expires"] <= now and not self.readers.get(token):
                    self.entries.pop(token)
                    (self.root / (token + ".blob")).unlink(missing_ok=True)
                    (self.root / (token + ".json")).unlink(missing_ok=True)

    def reserve(self, size):
        with self.lock:
            self.cleanup()
            if len(self.entries) + self.reserved_count >= self.max_transfers or sum(v["size"] for v in self.entries.values()) + self.reserved_bytes + size > self.max_bytes:
                return False
            self.reserved_count += 1
            self.reserved_bytes += size
            return True

    def release(self, size):
        with self.lock:
            self.reserved_count -= 1
            self.reserved_bytes -= size

    def commit(self, temporary, size):
        with self.lock:
            token = secrets.token_urlsafe(32)
            while token in self.entries:
                token = secrets.token_urlsafe(32)
            entry = {"size": size, "expires": self.clock() + self.ttl}
            blob = self.root / (token + ".blob")
            metadata = self.root / (token + ".json")
            try:
                os.replace(temporary, blob)
                with metadata.open("x") as output:
                    os.chmod(metadata, 0o600)
                    json.dump(entry, output)
                    output.flush()
                    os.fsync(output.fileno())
                self.entries[token] = entry
                return token, entry["expires"]
            except Exception:
                blob.unlink(missing_ok=True)
                metadata.unlink(missing_ok=True)
                raise

    def open(self, token):
        with self.lock:
            self.cleanup()
            entry = self.entries.get(token)
            if entry is None or entry["expires"] <= self.clock():
                return None
            try:
                # Open under the lock; expiry cleanup cannot race file opening.
                file = (self.root / (token + ".blob")).open("rb")
                self.readers[token] = self.readers.get(token, 0) + 1
                return file, entry["size"]
            except OSError:
                return None

    def finish_read(self, token, file):
        file.close()
        with self.lock:
            self.readers[token] -= 1
            if self.readers[token] == 0:
                self.readers.pop(token)
            self.cleanup()


LANDING = '''<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>NotchHub</title><style>body{font:17px system-ui;max-width:36rem;margin:12vh auto;padding:24px;background:#12141b;color:#fff}a{display:inline-block;background:#457aff;color:white;padding:14px 20px;border-radius:14px;text-decoration:none}p{line-height:1.6;color:#c9cdd8}</style><h1>NotchHub</h1><p>Откройте ссылку в NotchHub на Mac. Приложение расшифрует элементы локально и предложит добавить их в историю.</p><a id="open">Открыть в NotchHub</a><p>Передача доступна один час. Нужна установленная версия NotchHub с поддержкой передачи.</p><script>document.getElementById('open').href='notchhub://receive?url='+encodeURIComponent(location.href);</script></html>'''.encode('utf-8')


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass  # URLs are bearer capabilities; never write tokens to access logs.

    def setup(self):
        super().setup()
        self.connection.settimeout(30)
        if isinstance(self.connection, ssl.SSLSocket):
            self.connection.do_handshake()

    def reply(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.close_connection = True

    def do_POST(self):
        if self.path != "/transfers":
            return self.reply(404)
        authorization = self.headers.get("Authorization", "").encode()
        expected = ("Bearer " + self.server.upload_key).encode()
        if not hmac.compare_digest(hashlib.sha256(authorization).digest(), hashlib.sha256(expected).digest()):
            return self.reply(401)
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or len(lengths[0]) > 10 or not lengths[0].isdigit():
            return self.reply(411)
        size = int(lengths[0])
        if size <= 0 or size > self.server.max_request:
            return self.reply(413)
        store = self.server.store
        if not store.reserve(size):
            return self.reply(507)
        temporary = None
        try:
            descriptor, temporary = tempfile.mkstemp(prefix="upload-", dir=store.root)
            with os.fdopen(descriptor, "wb") as output:
                remaining = size
                while remaining:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        raise ValueError("Truncated request")
                    output.write(chunk)
                    remaining -= len(chunk)
                output.flush()
                os.fsync(output.fileno())
            token, expires = store.commit(temporary, size)
            temporary = None
            self.reply(201, json.dumps({"id": token, "expiresAt": expires}).encode())
        except (OSError, ValueError, TimeoutError):
            try:
                self.reply(400)
            except OSError:
                pass
        finally:
            if temporary is not None:
                Path(temporary).unlink(missing_ok=True)
            store.release(size)

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, b'{"ok":true}')
        if self.path.startswith("/s/"):
            token = self.path[3:]
            if not TOKEN.fullmatch(token):
                return self.reply(404)
            opened = self.server.store.open(token)
            if opened is None:
                return self.reply(404)
            self.server.store.finish_read(token, opened[0])
            return self.reply(200, LANDING, "text/html; charset=utf-8")
        if not self.path.startswith("/transfers/"):
            return self.reply(404)
        token = self.path[len("/transfers/"):]
        if not TOKEN.fullmatch(token):
            return self.reply(404)
        opened = self.server.store.open(token)
        if opened is None:
            return self.reply(404)
        file, size = opened
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                while chunk := file.read(65536):
                    self.wfile.write(chunk)
            except OSError:
                pass
        finally:
            self.server.store.finish_read(token, file)
        self.close_connection = True


class TransferServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, *args, **kwargs):
        self.workers = threading.BoundedSemaphore(32)
        self.request_lifetime = 30
        self.deadlines = {}
        self.deadline_lock = threading.Condition()
        self.deadline_stopped = False
        super().__init__(*args, **kwargs)
        self.deadline_worker = threading.Thread(target=self.expire_requests, daemon=True)
        self.deadline_worker.start()

    @staticmethod
    def expire_request(request):
        # An absolute deadline, independent of traffic: shutting down both
        # directions interrupts TLS handshakes and buffered header/body reads.
        try:
            request.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        request.close()

    def cancel_deadline(self, request):
        with self.deadline_lock:
            self.deadlines.pop(request, None)
            self.deadline_lock.notify()

    def expire_requests(self):
        while True:
            with self.deadline_lock:
                if self.deadline_stopped:
                    return
                if not self.deadlines:
                    self.deadline_lock.wait()
                    continue
                delay = min(self.deadlines.values()) - time.monotonic()
                if delay > 0:
                    self.deadline_lock.wait(timeout=delay)
                    continue
                now = time.monotonic()
                expired = [request for request, deadline in self.deadlines.items() if deadline <= now]
                for request in expired:
                    self.deadlines.pop(request)
            for request in expired:
                self.expire_request(request)

    def server_close(self):
        with self.deadline_lock:
            self.deadline_stopped = True
            requests = list(self.deadlines)
            self.deadlines.clear()
            self.deadline_lock.notify_all()
        for request in requests:
            self.expire_request(request)
        super().server_close()
        worker = getattr(self, "deadline_worker", None)
        if worker and worker is not threading.current_thread():
            worker.join(timeout=1)

    def handle_error(self, request, client_address):
        if not isinstance(sys.exc_info()[1], OSError):
            super().handle_error(request, client_address)

    def process_request(self, request, client_address):
        if not self.workers.acquire(blocking=False):
            self.shutdown_request(request)
            return
        with self.deadline_lock:
            self.deadlines[request] = time.monotonic() + self.request_lifetime
            self.deadline_lock.notify()
        try:
            super().process_request(request, client_address)
        except Exception:
            self.cancel_deadline(request)
            self.workers.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.cancel_deadline(request)
            self.workers.release()


def create_server(host, port, storage, upload_key, clock=time.time, max_bytes=MAX_BYTES, max_transfers=MAX_TRANSFERS, ttl=TTL, max_request=MAX_REQUEST):
    if len(upload_key) < 32 or any(c.isspace() for c in upload_key):
        raise ValueError("Upload key must contain at least 32 non-whitespace characters")
    server = TransferServer((host, port), Handler)
    server.store = TransferStore(storage, clock, max_bytes, max_transfers, ttl)
    server.upload_key, server.max_request = upload_key, max_request
    return server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8768")))
    parser.add_argument("--storage", required=True)
    args = parser.parse_args()
    key = os.environ.get("NOTCHHUB_UPLOAD_KEY", "")
    if os.environ.get("NOTCHHUB_UPLOAD_KEY_FILE"):
        key = Path(os.environ["NOTCHHUB_UPLOAD_KEY_FILE"]).read_text().strip()
    server = create_server(args.host, args.port, args.storage, key)
    cert, private_key = os.environ.get("TLS_CERT_FILE"), os.environ.get("TLS_KEY_FILE")
    if bool(cert) != bool(private_key):
        raise ValueError("Both TLS certificate paths are required")
    if cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, private_key)
        server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
        def reload_certificate(*_):
            try:
                context.load_cert_chain(cert, private_key)
            except (OSError, ssl.SSLError):
                pass  # Keep the last valid certificate; do not print filesystem secrets.
        signal.signal(signal.SIGHUP, reload_certificate)
    stopped = threading.Event()
    def cleanup():
        while not stopped.wait(300):
            try:
                server.store.cleanup()
            except OSError:
                pass
    threading.Thread(target=cleanup, daemon=True).start()
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        stopped.set()
        server.server_close()


if __name__ == "__main__":
    main()
