#!/usr/bin/env python3
"""W4 拒絕矩陣：一次跑完 labs/04-web-api/README.md 的 7 列。

規則（照 README）：
  - 送出前先向 AWS 查主機「當下」的公開位址，不沿用上次記下的位址。
  - 權杖只從 .local/app.env 讀取用來發請求，絕不印出；列印前會自我檢查輸出是否含權杖。
  - 事件固定 event_id：事件只存在服務記憶體，同一個服務行程內重跑時 #1 會變 409，
    這是刻意的（報告要寫明），要重跑請先重啟 inspection 或改 EVENT_ID。

用法: python3 tests/reject_matrix.py [base_url]
      不給 base_url 就向 AWS 查；給了就用那個（不要用上週的位址）。
"""
import json
import pathlib
import stat
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

EVENT_ID = "g1-t1-0001"
DEVICE_ID = "g1-d01"
OBSERVED_AT = "2026-09-29T10:00:00+08:00"
OBSERVED_AT_NO_TZ = "2026-09-29T10:00:00"          # 缺時區 -> 400 field=observed_at
TIMEOUT = 10


def load_tokens():
    """讀兩個權杖；只檢查存在與權限，不回傳給呼叫端以外的任何地方。"""
    path = ROOT / ".local/app.env"
    if not path.is_file():
        raise SystemExit("STOP: 缺少 .local/app.env（權杖由你本人產生）")
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o600:
        raise SystemExit(f"STOP: .local/app.env 權限是 {oct(mode)[2:]}，必須是 600")
    tokens = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            key, _, value = line.partition("=")
            tokens[key.strip()] = value.strip()
    for key in ("REPORTER_TOKEN", "OPERATOR_TOKEN"):
        if not tokens.get(key):
            raise SystemExit(f"STOP: .local/app.env 缺少 {key}")
    return tokens["REPORTER_TOKEN"], tokens["OPERATOR_TOKEN"]


def probe_host():
    """向 AWS 查這台主機當下的狀態與公開位址；標籤不符就拒絕送出。"""
    from lab import LabError, run_aws
    res = json.loads((ROOT / ".local/resources.json").read_text(encoding="utf-8"))
    env = {}
    for line in (ROOT / ".local/w03.env").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip().strip('"')
    try:
        data = run_aws(["ec2", "describe-instances", "--instance-ids", res["instance"],
                        "--query", "Reservations[0].Instances[0].{S:State.Name,I:PublicIpAddress,T:Tags}"],
                       env["REGION"]) or {}
    except LabError as exc:
        raise SystemExit(f"STOP: 無法向 AWS 查主機狀態：{exc}")
    tags = {t["Key"]: t["Value"] for t in (data.get("T") or [])}
    if tags.get("owner") != env["OWNER"] or tags.get("group") != env["GROUP"]:
        raise SystemExit("STOP: 主機標籤的 owner/group 與本組不符，拒絕送出")
    if data.get("S") != "running" or not data.get("I"):
        raise SystemExit(f"STOP: 主機狀態是 {data.get('S')} 或沒有公開位址，拒絕送出")
    return res["instance"], data["S"], data["I"]


def request(base, method, path, token=None, payload=None,
            content_type="application/json", timeout=TIMEOUT):
    data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(base + path, data=data, method=method)
    if token is not None:
        req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8")


def compact(text):
    try:
        return json.dumps(json.loads(text), ensure_ascii=False, sort_keys=True)
    except ValueError:
        return text.strip() or "(空本文)"


def valid_event(event_id, observed_at):
    return {"event_id": event_id, "device_id": DEVICE_ID, "observed_at": observed_at,
            "type": "status", "note": "巡檢正常"}


def run_rows(base, reporter, operator):
    """回傳 [(編號, 說明, 預期狀態碼, 實際狀態碼或錯誤, 回應本文, 額外檢查結果)]"""
    rows = []
    first = valid_event(EVENT_ID, OBSERVED_AT)
    plan = [
        (1, "POST /events  reporter 權令牌，送合法事件", 201,
         lambda: request(base, "POST", "/events", reporter, first)),
        (2, "POST /events  不帶權令牌，送同一筆合法事件", 401,
         lambda: request(base, "POST", "/events", None, first)),
        (3, "POST /events  operator 權令牌，送同一筆事件（驗證 403 早於 409）", 403,
         lambda: request(base, "POST", "/events", operator, first)),
        (4, f"POST /events  reporter，observed_at 沒有時區（{OBSERVED_AT_NO_TZ}）", 400,
         lambda: request(base, "POST", "/events", reporter, valid_event("g1-t1-0004", OBSERVED_AT_NO_TZ))),
        (5, "POST /events  reporter，再送一次 #1 的 event_id", 409,
         lambda: request(base, "POST", "/events", reporter, first)),
        (6, "GET /events   reporter 權令牌讀清單", 403,
         lambda: request(base, "GET", "/events", reporter)),
        (7, "GET /events   operator 權令牌讀清單", 200,
         lambda: request(base, "GET", "/events", operator)),
    ]
    for number, description, expected, call in plan:
        try:
            status, text = call()
            detail = ""
            body = compact(text)
            if number == 1:
                got = json.loads(text)
                detail = ("含 event_id 與 received_at"
                          if got.get("event_id") == EVENT_ID and got.get("received_at", "").endswith("Z")
                          else "缺少 event_id 或 received_at")
            elif number == 4:
                field = json.loads(text).get("field")
                detail = f"field={field}" + (" ✅" if field == "observed_at" else " ❌應為 observed_at")
            elif number == 7:
                events = json.loads(text).get("events", [])
                hit = any(item.get("event_id") == EVENT_ID for item in events)
                detail = f"清單 {len(events)} 筆，含 #1 的 event_id={hit}"
        except Exception as exc:                      # 連線失敗等也要留下紀錄
            status, body, detail = None, f"（請求未完成：{type(exc).__name__}）", ""
        rows.append((number, description, expected, status, body, detail))
    return rows


def main():
    reporter, operator = load_tokens()
    secrets = {"REPORTER_TOKEN": reporter, "OPERATOR_TOKEN": operator}

    if len(sys.argv) > 1:
        base = sys.argv[1].strip().rstrip("/")
        if not base.startswith(("http://", "https://")):
            base = "http://" + base
        iid, state, ip = "-", "-", base.split("//", 1)[1]
        source = "命令列指定（請確認不是上週的舊位址）"
    else:
        iid, state, ip = probe_host()
        base, source = f"http://{ip}", "送出前向 AWS 查得"

    lines = ["== W4 拒絕矩陣（labs/04-web-api/README.md）==",
             f"主機實例: {iid}（{state}）",
             f"本次實際使用的位址: {ip}（{source}）",
             f"事件 event_id: {EVENT_ID}"]

    try:
        code, text = request(base, "GET", "/health")
        health = json.loads(text)
        lines += [f"version: {health.get('version', '?')}",
                  f"auth_configured: {health.get('auth_configured')}",
                  f"/health HTTP: {code}"]
    except Exception as exc:
        lines += [f"version: （讀不到 /health：{type(exc).__name__}）"]

    # 記憶體是否已經有同 id 的事件（決定 #1 會是 201 還是 409）
    try:
        _, text = request(base, "GET", "/events", operator)
        already = any(item.get("event_id") == EVENT_ID for item in json.loads(text).get("events", []))
        lines.append(f"部署後記憶體檢查: {'已存在 ' + EVENT_ID + '（本次 #1 將是 409，請先重啟 inspection）' if already else '尚無 ' + EVENT_ID + '（本次 #1 應為 201）'}")
    except Exception:
        lines.append("部署後記憶體檢查: 無法預先查詢（不影響矩陣執行）")

    lines.append("")
    rows = run_rows(base, reporter, operator)
    mismatches = []
    for number, description, expected, status, body, detail in rows:
        actual = status if status is not None else "無回應"
        ok = status == expected
        if not ok:
            mismatches.append(number)
        mark = "✅" if ok else "❌"
        lines.append(f"#{number} {description}")
        lines.append(f"    預期 {expected} / 實際 {actual} {mark}" + (f"  {detail}" if detail else ""))
        lines.append(f"    回應: {body}")
    lines.append("")
    lines.append("== 總結 ==")
    if mismatches:
        lines.append(f"與 README 預期不同的列: {mismatches}（{len(mismatches)}/7），請把原因寫進報告")
    else:
        lines.append("7/7 與 README 預期相同（報告第 2 段可填「無」）")
    lines.append("提醒：事件只存在服務記憶體，同一個服務行程內再跑一次，#1 會變 409。")

    text = "\n".join(lines)
    leaked = [key for key, value in secrets.items() if value and value in text]
    if leaked:
        raise SystemExit(f"STOP: 輸出含權杖（{leaked}），已中止列印，請回報這支腳本")
    print(text)
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main())
