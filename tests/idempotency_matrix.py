#!/usr/bin/env python3
"""W5 five-row persistence and idempotency matrix."""
import json
import pathlib
import stat
import subprocess
import sys
from datetime import datetime, timezone
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
TIMEOUT = 10
DEVICE_ID = "g1-d01"
OBSERVED_AT = "2026-10-06T10:00:00+08:00"


def load_tokens():
    path = ROOT / ".local/app.env"
    if not path.is_file() or stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise SystemExit("STOP: .local/app.env 不存在或權限不是 600")
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    if not values.get("REPORTER_TOKEN") or not values.get("OPERATOR_TOKEN"):
        raise SystemExit("STOP: .local/app.env 缺少必要權杖")
    return values["REPORTER_TOKEN"], values["OPERATOR_TOKEN"]


def request(base, method, path, token=None, payload=None):
    data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(base + path, data=data, method=method)
    if token is not None:
        req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as response:
            return response.status, response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8")


def compact(text):
    try:
        return json.dumps(json.loads(text), ensure_ascii=False, sort_keys=True)
    except ValueError:
        return text.strip() or "(空本文)"


def host_context():
    resources = json.loads((ROOT / ".local/resources.json").read_text(encoding="utf-8"))
    settings = {}
    for line in (ROOT / ".local/w03.env").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            key, _, value = line.partition("=")
            settings[key.strip()] = value.strip().strip('"')
    sys.path.insert(0, str(ROOT / "scripts"))
    from lab import run_aws
    data = run_aws(["ec2", "describe-instances", "--instance-ids", resources["instance"],
                    "--query", "Reservations[0].Instances[0].{S:State.Name,I:PublicIpAddress,T:Tags}"],
                   settings["REGION"])
    tags = {item["Key"]: item["Value"] for item in (data.get("T") or [])}
    if tags.get("owner") != settings.get("OWNER") or tags.get("group") != settings.get("GROUP"):
        raise SystemExit("STOP: 主機標籤不符，拒絕執行矩陣")
    if data.get("S") != "running" or not data.get("I"):
        raise SystemExit("STOP: 主機不是 running 或沒有公開位址")
    key_file = pathlib.Path.home() / ".ssh" / settings["NAME_BASE"]
    known = ROOT / ".local" / ("known_" + settings["NAME_BASE"])
    if not key_file.is_file() or not known.is_file():
        raise SystemExit("STOP: 找不到 W3 SSH 私鑰或主機指紋檔")
    ssh = ["ssh", "-i", str(key_file), "-o", "UserKnownHostsFile=" + str(known),
           "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "ec2-user@" + data["I"]]
    return settings, resources["instance"], data["I"], ssh


def remote_restart(ssh):
    result = subprocess.run(ssh + ["sudo systemctl restart inspection"], cwd=ROOT,
                            capture_output=True, text=True, timeout=30, check=False)
    if result.returncode:
        raise RuntimeError("remote restart failed")


def remote_count(ssh, event_id):
    script = """set -a
. /etc/inspection/app.env
set +a
PGPASSWORD="$DB_PASSWORD" psql "host=$DB_HOST dbname=$DB_NAME user=$DB_USER sslmode=verify-full sslrootcert=/etc/inspection/rds-ca.pem" \\
    -v event_id="%s" -At <<'SQL'
SELECT count(*) FROM events WHERE event_id = :'event_id';
SQL
""" % event_id
    result = subprocess.run(ssh + ["sudo bash -s"], input=script, cwd=ROOT,
                            capture_output=True, text=True, timeout=30, check=False)
    if result.returncode:
        return "（psql 未完成）"
    return result.stdout.strip() or "（空本文）"


def main():
    reporter, operator = load_tokens()
    event_id = "g1-w5-" + datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")
    if len(sys.argv) > 1:
        base = sys.argv[1].rstrip("/")
        if not base.startswith(("http://", "https://")):
            base = "http://" + base
        settings = None
        iid, ip, ssh = "-", base.split("//", 1)[1], None
    else:
        subprocess.run(["bash", "scripts/verify-aws.sh"], cwd=ROOT, check=True)
        settings, iid, ip, ssh = host_context()
        base = "http://" + ip

    health_code, health_text = request(base, "GET", "/health")
    try:
        health = json.loads(health_text)
        print(f"version: {health.get('version', '?')}")
        print(f"db_configured: {str(health.get('db_configured')).lower()}")
    except ValueError:
        print("version: （讀不到 /health）")
        print("db_configured: （讀不到 /health）")
    print(f"/health HTTP: {health_code}")

    first = {"event_id": event_id, "device_id": DEVICE_ID, "observed_at": OBSERVED_AT,
             "type": "status", "note": "巡檢正常"}
    conflict = dict(first, note="內容不同")
    rows = [
        (1, 201, lambda: request(base, "POST", "/events", reporter, first)),
        (2, 200, lambda: request(base, "POST", "/events", reporter, first)),
        (3, 409, lambda: request(base, "POST", "/events", reporter, conflict)),
    ]
    for number, expected, call in rows:
        try:
            code, text = call()
            print(f"#{number} HTTP {code}（預期 {expected}）: {compact(text)}")
        except Exception as exc:
            print(f"#{number} HTTP 無回應（預期 {expected}）: （{type(exc).__name__}）")

    if ssh is None:
        print("#4 HTTP 無法執行（指定 base_url 時需要 AWS 主機資訊）: （未執行重啟）")
        print("#5 psql 未執行: （指定 base_url 時需要 AWS 主機資訊）")
        return 1
    try:
        remote_restart(ssh)
        code, text = request(base, "GET", "/events/" + event_id, operator)
        print(f"#4 HTTP {code}（預期 200）: {compact(text)}")
    except Exception as exc:
        print(f"#4 HTTP 無回應（預期 200）: （{type(exc).__name__}）")
    print(f"#5 psql 筆數（預期 1）: {remote_count(ssh, event_id)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())