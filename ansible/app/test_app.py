"""Run without dependencies: python3 -B -m unittest discover -s ansible/app."""
import concurrent.futures
import http.client
import json
import threading
import time
import unittest
from unittest.mock import Mock

from app import Handler, Server

class AppTest(unittest.TestCase):
    def setUp(self):
        self.server = Server(("localhost", 0))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, method="GET", path="/health", body=None):
        conn = http.client.HTTPConnection("localhost", self.server.server_port, timeout=4)
        try:
            conn.request(method, path, body)
            response = conn.getresponse()
            return response.status, response.read()
        finally:
            conn.close()

    def chaos(self, **obj):
        return self.request("POST", "/chaos", json.dumps(obj))[0]

    def test_health_and_metrics_exclusions(self):
        self.assertEqual(self.request()[0], 200)
        for _ in range(2):
            status, metrics = self.request(path="/metrics")
            self.assertEqual(status, 200)
            self.assertIn(b'demo_http_requests_total{route="/health",status_class="2xx"} 1', metrics)
            self.assertIn(b'demo_http_request_duration_seconds_bucket{route="/health",le="0.3"} 1', metrics)
            self.assertIn(b"demo_uptime_seconds ", metrics)

    def test_concurrent_counter(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            statuses = list(pool.map(lambda _: self.request()[0], range(80)))
        self.assertEqual(statuses, [200] * 80)
        self.assertEqual(self.server.state.requests, {"2xx": 80, "5xx": 0})
        self.assertEqual(self.server.state.counts[-1], 80)

    def test_bounded_labels_and_methods(self):
        for n in range(20):
            self.assertEqual(self.request(path=f"/unknown-{n}")[0], 404)
        self.assertEqual(self.request("POST", "/health", "private-body")[0], 405)
        self.assertEqual(self.request("DELETE", "/metrics")[0], 405)
        self.assertEqual(self.request(path="/chaos")[0], 405)
        self.assertEqual(self.request("BREW", "/health")[0], 405)
        metrics = self.request(path="/metrics")[1]
        self.assertNotIn(b"unknown-", metrics)
        self.assertNotIn(b"private-body", metrics)
        self.assertEqual(self.server.state.rejected["route"], 20)
        self.assertEqual(self.server.state.rejected["method"], 4)

    def test_chaos_failure_metrics_recovery_and_no_extension(self):
        self.assertEqual(self.chaos(duration_seconds=0.1, fail=True, latency_ms=20), 200)
        self.assertEqual(self.chaos(duration_seconds=120, fail=True), 409)
        started = time.monotonic()
        self.assertEqual(self.request()[0], 503)
        self.assertGreaterEqual(time.monotonic() - started, 0.02)
        self.assertEqual(self.request(path="/metrics")[0], 200)
        time.sleep(0.11)
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.server.state.requests, {"2xx": 1, "5xx": 1})

    def test_latency_and_explicit_cleanup(self):
        self.assertEqual(self.chaos(duration_seconds=10, latency_ms=320), 200)
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.server.state.counts[2], 0)
        self.assertEqual(self.chaos(duration_seconds=0), 200)
        self.assertEqual(self.request()[0], 200)
        self.assertEqual(self.server.state.counts[2], 1)

    def test_validation_and_duration_cap(self):
        for body in ('{}', 'null', '[]', '{', '{"duration_seconds": NaN}',
                     '{"duration_seconds": 121}', '{"duration_seconds": -1}',
                     '{"duration_seconds": true}', '{"duration_seconds": 1, "latency_ms": 2001}',
                     '{"duration_seconds": 1, "fail": 1}', '{"duration_seconds": 1, "extra": 1}',
                     'x' * 257):
            self.assertEqual(self.request("POST", "/chaos", body)[0], 400)
        self.assertEqual(self.chaos(duration_seconds=120, latency_ms=2000, fail=True), 200)
        self.assertEqual(self.chaos(duration_seconds=0), 200)
        self.assertEqual(self.request()[0], 200)

    def test_chaos_not_available_from_bridge(self):
        handler = Mock()
        handler.path = "/chaos"
        handler.client_address = ("192.0.2.1", 1234)
        Handler.do_POST(handler)
        handler.reject.assert_called_once_with(403, "chaos_forbidden")

if __name__ == "__main__":
    unittest.main()
