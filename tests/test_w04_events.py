"""W4 offline contract checks.

These tests read tests/fixtures/*.json from disk (no AWS calls, no real tokens).
Break a fixture on purpose and the matching test must fail.
"""
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).with_name("fixtures")

spec = importlib.util.spec_from_file_location("w04_service", ROOT / "app/service.py")
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)

# Synthetic placeholders: never the tokens from .local/app.env or the host.
REPORTER = "offline-reporter-placeholder-token"
OPERATOR = "offline-operator-placeholder-token"


def fixture(name):
    """Load a fixture from disk so the file itself is under test."""
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class ServiceHarness(unittest.TestCase):
    def start(self, tokens=(REPORTER, OPERATOR)):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        version = Path(tmp.name) / "version"
        version.write_text("b" * 40, encoding="utf-8")
        server = service.make_server(version, port=0, tokens=tokens)
        worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05},
                                  daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(worker.join, 2)
        self.addCleanup(server.shutdown)  # LIFO: shutdown -> join -> close -> tmp
        self.base = "http://127.0.0.1:" + str(server.server_port)
        return server

    def call(self, method, path, token=None, body=None, content_type="application/json",
             raw_body=None):
        data = raw_body
        if data is None and body is not None:
            data = json.dumps(body).encode("utf-8")
        request = urllib.request.Request(self.base + path, data=data, method=method)
        if token is not None:
            request.add_header("Authorization", "Bearer " + token)
        if data is not None:
            request.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode("utf-8")

    def json_call(self, *args, **kwargs):
        status, text = self.call(*args, **kwargs)
        return status, json.loads(text)


class FixturesOnDisk(ServiceHarness):
    """Proves the three fixtures are present and are the files under test."""

    def test_three_fixtures_exist_with_expected_shape(self):
        success = fixture("event_success.json")
        no_tz = fixture("event_reject_no_tz.json")
        note_null = fixture("event_reject_note_null.json")
        self.assertEqual(sorted(success), ["device_id", "event_id", "note", "observed_at", "type"])
        self.assertTrue(service.parse_timestamp(success["observed_at"]))
        self.assertIsNone(service.parse_timestamp(no_tz["observed_at"]))
        self.assertIsNone(note_null["note"])
        self.assertEqual(len({success["event_id"], no_tz["event_id"], note_null["event_id"]}), 3)


class HealthAndAuth(ServiceHarness):
    def setUp(self):
        self.start()

    def test_health_reports_version_and_auth_configured(self):
        status, body = self.json_call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["version"], "b" * 40)
        self.assertEqual(body["service"], "inspection")
        self.assertEqual(body["status"], "ok")
        self.assertIs(body["auth_configured"], True)
        self.assertTrue(body["started_at"].endswith("Z"))

    def test_health_needs_no_token(self):
        self.assertEqual(self.call("GET", "/health")[0], 200)

    def test_missing_token_is_401_not_400(self):
        # Review item 1: identity before content. A malformed body without a
        # token must still be 401 so field rules stay private.
        status, body = self.json_call("POST", "/events", body=fixture("event_reject_no_tz.json"))
        self.assertEqual(status, 401)
        self.assertNotIn("observed_at", json.dumps(body, ensure_ascii=False))
        self.assertEqual(self.call("POST", "/events")[0], 401)

    def test_wrong_token_is_401(self):
        self.assertEqual(self.call("POST", "/events", token="not-a-real-token")[0], 401)
        self.assertEqual(self.call("GET", "/events", token="not-a-real-token")[0], 401)
        self.assertEqual(self.call("GET", "/events", token="")[0], 401)


class TokensNotConfigured(ServiceHarness):
    def setUp(self):
        self.start(tokens=("", ""))

    def test_missing_secret_file_fails_closed(self):
        status, body = self.json_call("GET", "/health")
        self.assertEqual(status, 200)
        self.assertIs(body["auth_configured"], False)
        self.assertEqual(self.call("GET", "/events", token=OPERATOR)[0], 401)
        self.assertEqual(self.call("GET", "/events/g1-t1-0001", token=OPERATOR)[0], 401)
        self.assertEqual(self.call("POST", "/events", token=REPORTER,
                                   body=fixture("event_success.json"))[0], 401)


class EventIngest(ServiceHarness):
    def setUp(self):
        self.start()

    def test_success_fixture_is_accepted(self):
        status, body = self.json_call("POST", "/events", token=REPORTER,
                                      body=fixture("event_success.json"))
        self.assertEqual(status, 201)
        self.assertEqual(body["event_id"], "g1-t1-0001")
        self.assertTrue(body["received_at"].endswith("Z"))
        self.assertEqual(body["observed_at"], "2026-09-29T10:00:00+08:00")

    def test_duplicate_event_id_is_409(self):
        payload = fixture("event_success.json")
        self.assertEqual(self.json_call("POST", "/events", token=REPORTER, body=payload)[0], 201)
        self.assertEqual(self.json_call("POST", "/events", token=REPORTER, body=payload)[0], 409)

    def test_reject_fixtures_report_the_offending_field(self):
        status, body = self.json_call("POST", "/events", token=REPORTER,
                                      body=fixture("event_reject_no_tz.json"))
        self.assertEqual(status, 400)
        self.assertEqual(body["field"], "observed_at")
        status, body = self.json_call("POST", "/events", token=REPORTER,
                                      body=fixture("event_reject_note_null.json"))
        self.assertEqual(status, 400)
        self.assertEqual(body["field"], "note")

    def test_operator_may_not_post(self):
        status, body = self.json_call("POST", "/events", token=OPERATOR,
                                      body=fixture("event_success.json"))
        self.assertEqual(status, 403)
        self.assertEqual(body["field"], "role")

    def test_contract_edge_cases(self):
        cases = [
            ({"type": "test", "device_id": "g1-d01",
              "observed_at": "2026-09-29T10:00:00+08:00"},
             "event_id", "required field is missing"),
            ({"event_id": "g1-t1-9002", "device_id": "g1-d01", "type": "test",
              "observed_at": "2026-09-29T10:00:00+08:00", "extra": 1}, "extra", "unknown field"),
            ({"event_id": "g1-t1-9003", "device_id": "g1-d01", "type": "boom",
              "observed_at": "2026-09-29T10:00:00+08:00"}, "type", "type must be one of"),
            ({"event_id": "g1-t1-9004", "device_id": "g1 d01", "type": "test",
              "observed_at": "2026-09-29T10:00:00+08:00"}, "device_id", "device_id must be"),
            ({"event_id": "g1-t1-9005", "device_id": "g1-d01", "type": "test", "note": "x" * 201,
              "observed_at": "2026-09-29T10:00:00+08:00"}, "note", "at most 200"),
            ({"event_id": "g1-t1-9006", "device_id": "g1-d01", "type": "test",
              "observed_at": "2026-13-45T10:00:00+08:00"}, "observed_at", "ISO 8601"),
        ]
        for payload, field, fragment in cases:
            with self.subTest(field=field):
                status, body = self.json_call("POST", "/events", token=REPORTER, body=payload)
                self.assertEqual(status, 400)
                self.assertEqual(body["field"], field)
                self.assertIn(fragment, body["error"])

    def test_content_type_and_size_limits(self):
        payload = fixture("event_success.json")
        status, body = self.json_call("POST", "/events", token=REPORTER, body=payload,
                                      content_type="text/plain")
        self.assertEqual(status, 400)
        self.assertEqual(body["field"], "Content-Type")
        oversized = dict(payload, note="x" * 5000)
        status, body = self.json_call("POST", "/events", token=REPORTER, body=oversized)
        self.assertEqual(status, 400)
        self.assertEqual(body["field"], "body")
        status, _ = self.json_call("POST", "/events", token=REPORTER,
                                   raw_body=b"{not json")
        self.assertEqual(status, 400)


class EventQuery(ServiceHarness):
    def setUp(self):
        self.start()
        status, _ = self.json_call("POST", "/events", token=REPORTER,
                                   body=fixture("event_success.json"))
        self.assertEqual(status, 201)

    def test_reporter_may_not_list(self):
        status, body = self.json_call("GET", "/events", token=REPORTER)
        self.assertEqual(status, 403)
        self.assertEqual(body["field"], "role")

    def test_operator_lists_and_finds_the_event(self):
        status, body = self.json_call("GET", "/events", token=OPERATOR)
        self.assertEqual(status, 200)
        self.assertEqual(body["count"], 1)
        self.assertEqual(body["events"][0]["event_id"], "g1-t1-0001")
        status, body = self.json_call("GET", "/events/g1-t1-0001", token=OPERATOR)
        self.assertEqual(status, 200)
        self.assertEqual(body["received_at"], body["received_at"])
        self.assertEqual(self.call("GET", "/events/g1-t1-nope", token=OPERATOR)[0], 404)
        self.assertEqual(self.call("GET", "/events/g1-t1-0001")[0], 401)

    def test_unknown_route_is_404(self):
        self.assertEqual(self.call("GET", "/unknown")[0], 404)


class DisplayPage(ServiceHarness):
    def setUp(self):
        self.start()

    def test_page_is_served_without_a_token(self):
        status, page = self.call("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn("textContent", page)
        self.assertIn("/events", page)

    def test_page_uses_no_innerhtml_storage_or_url_token(self):
        # Review item 3: event text must go through textContent, and the token
        # must not reach the URL, localStorage or sessionStorage.
        page = self.call("GET", "/")[1]
        for banned in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write",
                       "localStorage", "sessionStorage", "?token=", "eval("):
            with self.subTest(banned=banned):
                self.assertNotIn(banned, page)

    def test_service_source_never_prints_secrets(self):
        # Review item 2: no token or whole-body echo in responses or logs.
        source = (ROOT / "app/service.py").read_text(encoding="utf-8")
        for banned in ("print(", "logger", "logging.", "traceback"):
            with self.subTest(banned=banned):
                self.assertNotIn(banned, source)

    def test_error_responses_carry_only_error_and_field(self):
        responses = [
            self.json_call("POST", "/events", body=fixture("event_success.json")),
            self.json_call("GET", "/events", token=REPORTER),
            self.json_call("POST", "/events", token=REPORTER,
                           body=fixture("event_reject_note_null.json")),
            self.json_call("GET", "/events/g1-t1-missing", token=OPERATOR),
        ]
        for status, body in responses:
            with self.subTest(status=status):
                self.assertGreaterEqual(status, 400)
                self.assertEqual(sorted(body), ["error", "field"])
                text = json.dumps(body, ensure_ascii=False)
                self.assertNotIn(REPORTER, text)
                self.assertNotIn(OPERATOR, text)
                self.assertNotIn("巡檢正常", text)


if __name__ == "__main__":
    unittest.main()
