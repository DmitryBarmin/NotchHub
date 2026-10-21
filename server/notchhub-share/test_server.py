import http.client
import importlib.util
import json
from pathlib import Path
import socket
import ssl
import shutil
import subprocess
import time
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location("notchhub_share", Path(__file__).with_name("server.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.now = [1000.0]
        self.key = "test-only-upload-key-" + "x" * 32
        self.server = module.create_server("127.0.0.1", 0, self.directory.name, self.key, clock=lambda: self.now[0], max_bytes=32, max_transfers=2, max_request=24, ttl=10)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def request(self, method, path, data=None, authorized=True, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        values = {"Authorization": "Bearer " + self.key} if authorized else {}
        values.update(headers or {})
        connection.request(method, path, data, values)
        response = connection.getresponse()
        result = response.status, response.read(), dict(response.getheaders())
        connection.close()
        return result

    def upload(self, data=b"encrypted-example"):
        status, body, _ = self.request("POST", "/transfers", data)
        self.assertEqual(status, 201)
        return json.loads(body)["id"]

    def test_authentication_health_and_private_storage(self):
        self.assertEqual(self.request("GET", "/health", authorized=False)[0], 200)
        self.assertEqual(self.request("POST", "/transfers", b"data", authorized=False)[0], 401)
        self.assertEqual(self.request("POST", "/transfers", b"data", headers={"Authorization": "Bearer wrong"})[0], 401)
        self.assertEqual(list(Path(self.directory.name).glob("*.blob")), [])
        token = self.upload()
        self.assertRegex(token, r"^[A-Za-z0-9_-]{43}$")
        self.assertEqual((Path(self.directory.name) / (token + ".blob")).stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.request("GET", "/transfers/" + token, authorized=False)[1], b"encrypted-example")

    def test_landing_and_download_do_not_consume_or_leak_content(self):
        token = self.upload()
        status, body, headers = self.request("GET", "/s/" + token, authorized=False)
        self.assertEqual(status, 200)
        self.assertNotIn(b"encrypted-example", body)
        self.assertIn(b'src="/receiver.js"', body)
        self.assertNotIn(b"<script>", body)
        self.assertIn("connect-src 'self'", headers["Content-Security-Policy"])
        self.assertNotIn("unsafe-inline", headers["Content-Security-Policy"])
        self.assertEqual(headers["Cache-Control"], "no-store")
        for _ in range(2):
            status, body, headers = self.request("GET", "/transfers/" + token, authorized=False)
            self.assertEqual((status, body), (200, b"encrypted-example"))
            self.assertEqual(headers["Content-Type"], "application/octet-stream")

    def test_browser_assets_are_local_uncached_and_do_not_require_credentials(self):
        for path, content_type in [("/receiver.js", "text/javascript"), ("/receiver.css", "text/css")]:
            status, body, headers = self.request("GET", path, authorized=False)
            self.assertEqual(status, 200)
            self.assertTrue(headers["Content-Type"].startswith(content_type))
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertTrue(body)
        script = self.request("GET", "/receiver.js", authorized=False)[1]
        self.assertIn(b"encodeURIComponent(location.href)", script)
        self.assertNotIn(b"innerHTML", script)
        self.assertIn(b"credentials: 'omit'", script)
        self.assertEqual(self.request("GET", "/receiver.js?key=x")[0], 404)

    def test_expiry_removes_blob_and_metadata_and_releases_quota(self):
        token = self.upload()
        self.now[0] += 11
        self.assertEqual(self.request("GET", "/transfers/" + token)[0], 404)
        self.assertEqual(self.request("GET", "/s/" + token)[0], 200)
        self.assertFalse((Path(self.directory.name) / (token + ".blob")).exists())
        self.assertFalse((Path(self.directory.name) / (token + ".json")).exists())
        self.upload(b"new")

    def test_quota_oversize_and_traversal(self):
        self.assertEqual(self.request("POST", "/transfers", b"x" * 25)[0], 413)
        self.upload(b"x" * 20)
        self.assertEqual(self.request("POST", "/transfers", b"x" * 20)[0], 507)
        self.upload(b"x")
        self.assertEqual(self.request("POST", "/transfers", b"x")[0], 507)
        for path in ["/transfers/../server.py", "/s/%2e%2e%2fserver.py", "/transfers/" + "a" * 43 + "?key=x", "/s/" + "a" * 43 + "/extra"]:
            self.assertEqual(self.request("GET", path)[0], 404)

    def test_reservation_prevents_concurrent_quota_overrun(self):
        first = socket.create_connection(("127.0.0.1", self.server.server_port), timeout=3)
        first.sendall(("POST /transfers HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " + self.key + "\r\nContent-Length: 24\r\n\r\nx").encode())
        # Wait for the server reservation without a race or arbitrary long delay.
        reached = threading.Event()
        def check():
            for _ in range(100):
                with self.server.store.lock:
                    if self.server.store.reserved_count == 1:
                        reached.set()
                        return
                threading.Event().wait(0.01)
        checker = threading.Thread(target=check)
        checker.start()
        self.assertTrue(reached.wait(2))
        self.assertEqual(self.request("POST", "/transfers", b"x" * 10)[0], 507)
        first.sendall(b"x" * 23)
        self.assertIn(b"201", first.recv(4096))
        first.close()
        checker.join()

    def test_restart_retains_committed_blob(self):
        token = self.upload()
        restored = module.TransferStore(self.directory.name, clock=lambda: self.now[0], max_bytes=32, max_transfers=2)
        opened = restored.open(token)
        self.assertIsNotNone(opened)
        self.assertEqual(opened[0].read(), b"encrypted-example")
        restored.finish_read(token, opened[0])

    def assert_slow_connection_expires(self, prefix):
        self.server.request_lifetime = 0.3
        connection = socket.create_connection(("127.0.0.1", self.server.server_port), timeout=1)
        connection.sendall(prefix)
        stop = threading.Event()
        def drip():
            while not stop.wait(0.04):
                try:
                    connection.sendall(b"x")
                except OSError:
                    return
        sender = threading.Thread(target=drip, daemon=True)
        sender.start()
        began = time.monotonic()
        try:
            try:
                self.assertEqual(connection.recv(1), b"")
            except (ConnectionResetError, BrokenPipeError):
                pass
            except socket.timeout:
                self.fail("Dripped bytes kept the connection alive beyond its absolute deadline")
            self.assertLess(time.monotonic() - began, 0.9)
        finally:
            stop.set()
            connection.close()
            sender.join(timeout=1)

    def test_absolute_deadline_closes_dripped_headers(self):
        self.assert_slow_connection_expires(b"GET /health HTTP/1.1\r\nHost: localhost\r\nX-Slow: ")
        self.assertEqual(self.request("GET", "/health")[0], 200)

    def test_absolute_deadline_closes_dripped_body_and_releases_reservation(self):
        prefix = ("POST /transfers HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " + self.key + "\r\nContent-Length: 24\r\n\r\n").encode()
        self.assert_slow_connection_expires(prefix)
        limit = time.monotonic() + 1
        while time.monotonic() < limit:
            with self.server.store.lock:
                if self.server.store.reserved_count == 0:
                    break
            threading.Event().wait(0.01)
        self.assertEqual(self.server.store.reserved_count, 0)
        self.assertEqual(list(Path(self.directory.name).glob("upload-*")), [])
        self.upload(b"x" * 24)

    @unittest.skipUnless(shutil.which("openssl"), "openssl is needed only to generate the local TLS test fixture")
    def test_tls_handshake_has_absolute_deadline_without_blocking_accept(self):
        certificate = Path(self.directory.name) / "test-cert.pem"
        private_key = Path(self.directory.name) / "test-key.pem"
        subprocess.run([shutil.which("openssl"), "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(private_key), "-out", str(certificate), "-days", "1", "-subj", "/CN=localhost"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.server = module.create_server("127.0.0.1", 0, self.directory.name, self.key)
        self.server.request_lifetime = 0.3
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(certificate), str(private_key))
        # Same non-blocking-accept TLS setup as the production entry point.
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True, do_handshake_on_connect=False)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        silent = socket.create_connection(("127.0.0.1", self.server.server_port), timeout=1)
        try:
            healthy = http.client.HTTPSConnection("127.0.0.1", self.server.server_port, timeout=1, context=ssl._create_unverified_context())
            try:
                healthy.request("GET", "/health")
                response = healthy.getresponse()
                self.assertEqual(response.status, 200)
                response.read()
            finally:
                healthy.close()
            self.assertEqual(silent.recv(1), b"")
        finally:
            silent.close()


if __name__ == "__main__":
    unittest.main()
