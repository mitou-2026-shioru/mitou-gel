import json
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer
from mock_m5stack import Handler, MockDevice


class MockDeviceTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.device = MockDevice(clock=lambda: self.now)
        self.session = str(uuid.uuid4())

    def command(self, sequence=1, enabled=False, **changes):
        return {"version": 1, "command_id": str(uuid.uuid4()), "session_id": self.session,
                "sequence": sequence, "temperature": 0.75, "stiffness": 1,
                "ttl_ms": 6000, "enabled": enabled, **changes}

    def test_expiry_and_stop(self):
        self.device.apply(self.command())
        self.device.apply(self.command(sequence=2, enabled=True))
        self.now = 5.9
        self.assertEqual(self.device.status()["state"], "active")
        self.now = 6
        self.assertEqual(self.device.status()["state"], "expired")
        self.assertEqual(self.device.status()["stiffness_target"], 0)
        self.device.apply(self.command(sequence=3, enabled=True))
        self.assertEqual(self.device.apply(self.command(sequence=4))["state"], "idle")

    def test_late_active_command_cannot_override_stop(self):
        self.device.apply(self.command())
        self.device.apply(self.command(sequence=3))
        with self.assertRaises(ValueError):
            self.device.apply(self.command(sequence=2, enabled=True))
        self.assertEqual(self.device.status()["state"], "idle")

    def test_invalid_commands_do_not_change_targets(self):
        self.device.apply(self.command())
        for changes in ({"temperature": float("nan")}, {"stiffness": 2}, {"enabled": "true"},
                        {"ttl_ms": 99999}, {"sequence": -1}, {"command_id": "bad"}):
            with self.assertRaises(ValueError):
                self.device.apply(self.command(**{"sequence": 2, "enabled": True, **changes}))
        self.assertEqual(self.device.status()["state"], "idle")

    def test_new_session_must_start_disabled(self):
        with self.assertRaises(ValueError):
            self.device.apply(self.command(enabled=True))

    def test_http_round_trip(self):
        Handler.device = self.device
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}"
            payload = self.command()
            request = urllib.request.Request(base + "/v1/state", data=json.dumps(payload).encode(),
                                             headers={"Content-Type": "application/json"}, method="POST")
            with urllib.request.urlopen(request, timeout=2) as response:
                status = json.load(response)
            self.assertEqual(status["accepted_command_id"], payload["command_id"])
            self.assertTrue(status["simulated"])
            with urllib.request.urlopen(base + "/v1/status", timeout=2) as response:
                self.assertEqual(json.load(response)["state"], "idle")
        finally:
            server.shutdown()
            server.server_close()
            worker.join()


if __name__ == "__main__":
    unittest.main()
