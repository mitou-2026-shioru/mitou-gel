import argparse
import json
import math
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class MockDevice:
    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.lock = threading.Lock()
        self.session_id = None
        self.sequence = 0
        self.accepted_command_id = None
        self.state = "idle"
        self.temperature = 0.5
        self.stiffness = 0.0
        self.deadline = 0.0

    def _status(self):
        if self.state == "active" and self.clock() >= self.deadline:
            self.state = "expired"
            self.temperature = 0.5
            self.stiffness = 0.0
        return {"version": 1, "accepted_command_id": self.accepted_command_id, "state": self.state,
                "actual_temperature_c": None, "actual_pressure_kpa": None,
                "temperature_target": self.temperature, "stiffness_target": self.stiffness,
                "error": None, "simulated": True}

    def status(self):
        with self.lock:
            return self._status()

    def apply(self, payload):
        if not isinstance(payload, dict) or payload.get("version") != 1:
            raise ValueError("version must be 1")
        for key in ("command_id", "session_id"):
            uuid.UUID(payload[key])
        for key in ("temperature", "stiffness"):
            value = payload[key]
            if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1:
                raise ValueError(f"{key} must be a finite number between 0 and 1")
        if type(payload["enabled"]) is not bool:
            raise ValueError("enabled must be a boolean")
        if type(payload["ttl_ms"]) is not int or not 1_000 <= payload["ttl_ms"] <= 6_000:
            raise ValueError("ttl_ms must be between 1000 and 6000")
        if type(payload["sequence"]) is not int or payload["sequence"] <= 0:
            raise ValueError("sequence must be a positive integer")
        with self.lock:
            if payload["session_id"] != self.session_id:
                if payload["enabled"]:
                    raise ValueError("send a disabled command to establish the session first")
                self.session_id = payload["session_id"]
                self.sequence = 0
            if payload["sequence"] <= self.sequence:
                raise ValueError("superseded command")
            self.sequence = payload["sequence"]
            self.accepted_command_id = payload["command_id"]
            self.state = "active" if payload["enabled"] else "idle"
            self.temperature = payload["temperature"] if payload["enabled"] else 0.5
            self.stiffness = payload["stiffness"] if payload["enabled"] else 0.0
            self.deadline = self.clock() + payload["ttl_ms"] / 1000
            return self._status()


class Handler(BaseHTTPRequestHandler):
    device = MockDevice()

    def respond(self, code, payload):
        data = json.dumps(payload, allow_nan=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/v1/status":
            self.respond(200, self.device.status())
        else:
            self.respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/v1/state":
            self.respond(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 4096:
                raise ValueError("invalid content length")
            payload = json.loads(self.rfile.read(length))
            self.respond(200, self.device.apply(payload))
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            self.respond(400, {"error": str(error)})


def main():
    parser = argparse.ArgumentParser(description="GelLink API v1 mock: no physical hardware is controlled")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8080, type=int)
    arguments = parser.parse_args()
    server = ThreadingHTTPServer((arguments.host, arguments.port), Handler)
    print(f"Mock M5Stack: http://{arguments.host}:{arguments.port} (simulated=true)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
