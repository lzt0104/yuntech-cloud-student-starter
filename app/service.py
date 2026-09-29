#!/usr/bin/env python3
"""W4 inspection service: authenticated event ingest, query and display page.

Events live in process memory only (by design; W5 adds a database).
Secrets come from the systemd EnvironmentFile /etc/inspection/app.env and are
never logged, echoed in error responses or written to the display page.
"""
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import json
import os
from pathlib import Path
import re
import threading
from urllib.parse import unquote, urlsplit

MAX_BODY = 4096
MAX_LIST = 50
NOTE_MAX = 200
EVENT_TYPES = ("status", "anomaly", "test")
ALLOWED_FIELDS = frozenset({"event_id", "device_id", "observed_at", "type", "note"})
REQUIRED_FIELDS = ("event_id", "device_id", "observed_at", "type")
EVENT_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}\Z")
DEVICE_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,32}\Z")
TIMESTAMP_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})\Z")


class Store:
    """Insertion-ordered in-memory event store; one writer lock, no disk."""

    def __init__(self):
        self._lock = threading.Lock()
        self._items = {}

    def add(self, event):
        with self._lock:
            if event["event_id"] in self._items:
                return False
            self._items[event["event_id"]] = event
            return True

    def get(self, event_id):
        with self._lock:
            return self._items.get(event_id)

    def latest(self, limit):
        with self._lock:
            items = list(self._items.values())
        return list(reversed(items[-limit:]))


def tokens_from_env():
    """Read both tokens from the process environment (systemd EnvironmentFile)."""
    reporter = os.environ.get("REPORTER_TOKEN", "").strip()
    operator = os.environ.get("OPERATOR_TOKEN", "").strip()
    return reporter, operator


def parse_timestamp(value):
    """Return a datetime for ISO 8601 text that carries a timezone, else None."""
    if not isinstance(value, str) or not TIMESTAMP_RE.match(value):
        return None
    text = value.replace(" ", "T", 1)
    if text[-1] in "Zz":
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def validate(payload):
    """Return (error, field) for the first contract violation, else None.

    Messages are fixed strings: no submitted value is ever echoed back.
    """
    if not isinstance(payload, dict):
        return "body must be a JSON object", "body"
    unknown = sorted(set(payload) - ALLOWED_FIELDS)
    if unknown:
        return "unknown field is not allowed", unknown[0]
    for name in REQUIRED_FIELDS:
        if name not in payload:
            return "required field is missing", name
    if not isinstance(payload["event_id"], str) or not EVENT_ID_RE.match(payload["event_id"]):
        return "event_id must be 1-64 characters of A-Z a-z 0-9 - _", "event_id"
    if not isinstance(payload["device_id"], str) or not DEVICE_ID_RE.match(payload["device_id"]):
        return "device_id must be 1-32 characters of A-Z a-z 0-9 - _", "device_id"
    if parse_timestamp(payload["observed_at"]) is None:
        return "observed_at must be ISO 8601 with a timezone offset", "observed_at"
    if payload["type"] not in EVENT_TYPES:
        return "type must be one of status, anomaly, test", "type"
    if "note" in payload:
        note = payload["note"]
        if not isinstance(note, str):
            return "note must be a string when present", "note"
        if len(note) > NOTE_MAX:
            return "note must be at most 200 characters", "note"
    return None


DISPLAY_PAGE = """<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>巡檢事件</title>
<style>
body{font-family:system-ui,sans-serif;margin:2rem;max-width:64rem;line-height:1.5}
input,button{font-size:1rem;padding:.4rem}
#status{font-weight:600}
#list{list-style:none;padding:0}
#list li{border-bottom:1px solid #ddd;padding:.4rem 0}
.k{color:#555;margin-right:.75rem}
</style>
</head>
<body>
<h1>巡檢事件</h1>
<p>貼上 operator 權令牌後按「讀取清單」。權令牌只留在此頁面的記憶體變數，
不放進網址、不寫入瀏覽器儲存；按下後輸入框會自動清空。</p>
<p><input id="token" type="password" autocomplete="off" size="46" placeholder="operator 權令牌">
<button id="load" type="button">讀取清單</button></p>
<p id="status"></p>
<ul id="list"></ul>
<script>
(function () {
  var statusEl = document.getElementById("status");
  var listEl = document.getElementById("list");
  var fields = ["event_id", "device_id", "type", "observed_at", "received_at", "note"];
  document.getElementById("load").addEventListener("click", function () {
    var input = document.getElementById("token");
    var token = input.value;
    input.value = "";
    listEl.replaceChildren();
    fetch("/events", {headers: {Authorization: "Bearer " + token}})
      .then(function (response) {
        return response.json().then(function (body) {
          return {ok: response.ok, code: response.status, body: body};
        });
      })
      .then(function (result) {
        if (!result.ok) {
          statusEl.textContent = "HTTP " + result.code + " " +
            (result.body.error || "error") +
            (result.body.field ? "（" + result.body.field + "）" : "");
          return;
        }
        var events = result.body.events || [];
        statusEl.textContent = "HTTP " + result.code + "：共 " + events.length + " 筆（最新在前）";
        events.forEach(function (item) {
          var row = document.createElement("li");
          fields.forEach(function (name) {
            var cell = document.createElement("span");
            cell.className = "k";
            var value = item[name];
            cell.textContent = name + "=" +
              (value === undefined || value === null ? "" : value);
            row.appendChild(cell);
          });
          listEl.appendChild(row);
        });
      })
      .catch(function (err) {
        statusEl.textContent = "請求失敗：" + err.message;
      });
  });
}());
</script>
</body>
</html>
"""


def make_server(version_file, port=8080, tokens=None):
    version = Path(version_file).read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[0-9a-f]{40}", version):
        raise ValueError("version must contain the deployed 40-character Git commit SHA")
    started = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    # Fail closed: unless both tokens are present and distinct, every protected
    # route answers 401 and /health reports auth_configured=false.
    reporter, operator = tokens_from_env() if tokens is None else tokens
    auth_configured = bool(reporter and operator and reporter != operator)
    store = Store()

    def identify(header):
        """Return (role, None) or (None, 401). Never reveals which token matched."""
        if not header or not header.startswith("Bearer "):
            return None, 401
        presented = header[len("Bearer "):].strip()
        if not presented or not auth_configured:
            return None, 401
        if hmac.compare_digest(presented, reporter):
            return "reporter", None
        if hmac.compare_digest(presented, operator):
            return "operator", None
        return None, 401

    class Handler(BaseHTTPRequestHandler):
        server_version = "inspection"
        sys_version = ""

        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        # --- responses -------------------------------------------------
        def _send(self, code, content_type, body):
            data = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            self.wfile.write(data)

        def _json(self, code, payload):
            self._send(code, "application/json; charset=utf-8", json.dumps(payload, ensure_ascii=False))

        def _error(self, code, message, field):
            self._json(code, {"error": message, "field": field})

        def _page(self, code):
            self._send(code, "text/html; charset=utf-8", DISPLAY_PAGE)

        # --- routes ----------------------------------------------------
        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/health":
                self._json(200, {"status": "ok", "service": "inspection", "version": version,
                                 "started_at": started, "auth_configured": auth_configured})
                return
            if path == "/":
                self._page(200)
                return
            if path == "/events" or path.startswith("/events/"):
                role, code = identify(self.headers.get("Authorization"))
                if code:
                    self._error(code, "authorization is required", "Authorization")
                    return
                if role != "operator":
                    self._error(403, "operator role is required", "role")
                    return
                if path == "/events":
                    events = store.latest(MAX_LIST)
                    self._json(200, {"count": len(events), "events": events})
                    return
                event = store.get(unquote(path[len("/events/"):]))
                if event is None:
                    self._error(404, "event_id was not found", "event_id")
                    return
                self._json(200, event)
                return
            self._error(404, "route was not found", "path")

        def do_POST(self):
            if urlsplit(self.path).path != "/events":
                self._error(404, "route was not found", "path")
                return
            # Identity first, then role, and only then the body: a caller with no
            # token must not learn any field rule from the response.
            role, code = identify(self.headers.get("Authorization"))
            if code:
                self._error(code, "authorization is required", "Authorization")
                return
            if role != "reporter":
                self._error(403, "reporter role is required", "role")
                return
            media_type = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if media_type != "application/json":
                self._error(400, "Content-Type must be application/json", "Content-Type")
                return
            try:
                length = int(self.headers.get("Content-Length") or "0")
            except ValueError:
                self._error(400, "Content-Length is not a number", "Content-Length")
                return
            if length > MAX_BODY:
                self._error(400, "body must not exceed 4096 bytes", "body")
                return
            raw = self.rfile.read(length) if length > 0 else b""
            try:
                payload = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                self._error(400, "body must be valid UTF-8 JSON", "body")
                return
            problem = validate(payload)
            if problem is not None:
                self._error(400, problem[0], problem[1])
                return
            event = dict(payload)
            event["received_at"] = datetime.now(timezone.utc).isoformat(
                timespec="seconds").replace("+00:00", "Z")
            if not store.add(event):
                self._error(409, "event_id already exists", "event_id")
                return
            self._json(201, event)

        def log_message(self, fmt, *args):
            pass  # Never log request paths, bodies, headers or query strings.

    return ThreadingHTTPServer(("127.0.0.1", port), Handler)


if __name__ == "__main__":
    make_server(Path(__file__).with_name("version")).serve_forever()
