"""Three-route synthetic service; /health is the measured workload, not /metrics.

Chaos is loopback-only: invoke via Compose exec, never expose an admin API to
the bridge. POST /chaos JSON: {"duration_seconds": 30, "latency_ms": 500,
"fail": true}; duration_seconds=0 restores immediately. Expiry uses monotonic
time and cannot be extended until recovery (maximum 120s, latency <= 2000ms).
"""

import ipaddress
import json
import math
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class State:
    buckets = (0.05, 0.1, 0.3, 1.0, 2.5)

    def __init__(self):
        self.lock = threading.Lock()
        self.started = time.monotonic()
        self.until = 0
        self.latency = 0
        self.fail = False
        self.requests = {"2xx": 0, "5xx": 0}
        self.rejected = {key: 0 for key in ("route", "method", "chaos_invalid", "chaos_forbidden", "chaos_active")}
        self.counts = [0] * len(self.buckets)
        self.total = 0.0

    def record(self, status, duration):
        with self.lock:
            self.requests["5xx" if status == 503 else "2xx"] += 1
            self.total += duration
            for i, bound in enumerate(self.buckets):
                self.counts[i] += duration <= bound

    def metrics(self):
        with self.lock:
            count = sum(self.requests.values())
            lines = ["# TYPE demo_http_requests_total counter"]
            for status, value in self.requests.items():
                lines.append(f'demo_http_requests_total{{route="/health",status_class="{status}"}} {value}')
            lines.append("# TYPE demo_http_rejected_total counter")
            for reason, value in self.rejected.items():
                lines.append(f'demo_http_rejected_total{{reason="{reason}"}} {value}')
            lines.append("# TYPE demo_http_request_duration_seconds histogram")
            for bound, value in zip(self.buckets, self.counts):
                lines.append(f'demo_http_request_duration_seconds_bucket{{route="/health",le="{bound:g}"}} {value}')
            lines += [f'demo_http_request_duration_seconds_bucket{{route="/health",le="+Inf"}} {count}',
                      f'demo_http_request_duration_seconds_count{{route="/health"}} {count}',
                      f'demo_http_request_duration_seconds_sum{{route="/health"}} {self.total}',
                      "# TYPE demo_uptime_seconds gauge",
                      f"demo_uptime_seconds {time.monotonic() - self.started}"]
            return ("\n".join(lines) + "\n").encode()

class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, address):
        self.state = State()
        self.slots = threading.BoundedSemaphore(32)
        super().__init__(address, Handler)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(3)

    def log_message(self, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        if code == 501:
            self.reject(405, "method")
        else:
            super().send_error(code, message, explain)

    def reply(self, status, body=b"", content_type="text/plain; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def reject(self, status, reason):
        with self.server.state.lock:
            self.server.state.rejected[reason] += 1
        self.reply(status)

    def do_GET(self):
        state = self.server.state
        if self.path == "/metrics":
            self.reply(200, state.metrics(), "text/plain; version=0.0.4; charset=utf-8")
        elif self.path == "/health":
            started = time.monotonic()
            with state.lock:
                active = started < state.until
                latency, fail = (state.latency, state.fail) if active else (0, False)
            time.sleep(latency)
            status = 503 if fail else 200
            state.record(status, time.monotonic() - started)
            self.reply(status, b"unavailable\n" if fail else b"ok\n")
        elif self.path == "/chaos":
            self.reject(405, "method")
        else:
            self.reject(404, "route")

    def do_POST(self):
        if self.path != "/chaos":
            self.reject(405 if self.path in ("/health", "/metrics") else 404, "method")
            return
        if not ipaddress.ip_address(self.client_address[0]).is_loopback:
            self.reject(403, "chaos_forbidden")
            return
        try:
            if self.headers.get("Transfer-Encoding"):
                raise ValueError
            lengths = self.headers.get_all("Content-Length", [])
            if len(lengths) != 1 or not lengths[0].isdigit():
                raise ValueError
            length = int(lengths[0])
            if not 0 < length <= 256:
                raise ValueError
            obj = json.loads(self.rfile.read(length))
            if not isinstance(obj, dict) or set(obj) - {"duration_seconds", "latency_ms", "fail"}:
                raise ValueError
            duration, latency, fail = obj["duration_seconds"], obj.get("latency_ms", 0), obj.get("fail", False)
            if any(type(v) not in (int, float) or not math.isfinite(v) for v in (duration, latency)):
                raise ValueError
            if not 0 <= duration <= 120 or not 0 <= latency <= 2000 or type(fail) is not bool:
                raise ValueError
        except (ValueError, KeyError, TypeError, OverflowError, TimeoutError, OSError):
            self.reject(400, "chaos_invalid")
            return
        state = self.server.state
        with state.lock:
            if duration and time.monotonic() < state.until:
                state.rejected["chaos_active"] += 1
                status = 409
            else:
                state.until = time.monotonic() + duration if duration else 0
                state.latency, state.fail = latency / 1000, fail
                status = 200
        self.reply(status)

    def unsupported(self):
        self.reject(405, "method")

    do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_TRACE = do_CONNECT = unsupported

if __name__ == "__main__":
    Server(("", 8080)).serve_forever()
