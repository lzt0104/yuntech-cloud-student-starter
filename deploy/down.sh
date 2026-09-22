#!/usr/bin/env bash
# W3 個人回收：只處理 .local/resources.json 記錄的 ID；刪除前核對標籤；不依名稱大量刪除。
# 用法: bash deploy/down.sh         完整回收（terminate、刪 SG、刪 key、讀回）
#       bash deploy/down.sh --stop  只停止主機（保留 SG/key 供下週 W4）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
[[ -f .local/w03.env && -f .local/resources.json ]] || { echo "STOP: 缺 .local/w03.env 或 .local/resources.json" >&2; exit 1; }
MODE="${1:-}"
if [[ "$MODE" != "" && "$MODE" != "--stop" ]]; then echo "用法: bash deploy/down.sh 或 bash deploy/down.sh --stop" >&2; exit 1; fi

if [[ "$MODE" == "--stop" ]]; then
  cat <<'EOF'
將要執行（--stop）：只停止下列主機，SG 與 key pair 保留、不刪除。
  instance: 讀自 .local/resources.json（刪除前會核對 group/owner 標籤）
EOF
else
  cat <<'EOF'
將要刪除（依 .local/resources.json 的 ID，刪除前核對標籤，不以名稱搜尋）：
  1. EC2 instance（terminate，根磁碟/ENI 隨之釋放）
  2. Security group
  3. EC2 key pair
會釋放雲端資源；停止計費效果依官方計價頁。若中途失敗，請貼輸出並先診斷，不要自行擴大刪除範圍。
EOF
fi
ans=""
read -r -p "輸入 yes 以繼續，其他字元取消: " ans
[[ "$ans" == "yes" ]] || { echo "取消：未刪除/停止任何資源" >&2; exit 1; }

python3 - "$MODE" <<'PY'
import json, pathlib, re, sys, time
sys.path.insert(0, "scripts")
from lab import run_aws, LabError

MODE = sys.argv[1]
ROOT = pathlib.Path.cwd()

def load_env():
    env = {}
    for line in (ROOT / ".local/w03.env").read_text().splitlines():
        m = re.match(r'^([A-Za-z_]+)="(.*)"$', line.strip())
        if m:
            env[m.group(1)] = m.group(2)
    return env
ENV = load_env()
REGION, GROUP, OWNER = ENV["REGION"], ENV["GROUP"], ENV["OWNER"]
RES = json.loads((ROOT / ".local/resources.json").read_text())

def call(args):
    return run_aws(args, REGION)

def is_notfound(exc):
    return "NotFound" in str(exc)

def gone(args):
    try:
        call(args)
        return False
    except LabError as exc:
        if is_notfound(exc):
            return True
        raise

def utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def check_tags(rid, kind):
    d = call(["ec2", "describe-tags", "--filters",
              f"Name=resource-id,Values={rid}", f"Name=resource-type,Values={kind}"])
    tags = {t["Key"]: t["Value"] for t in d.get("Tags", [])}
    if tags.get("owner") != OWNER or tags.get("group") != GROUP:
        raise SystemExit(f"STOP: {kind} {rid} 標籤不符（owner={tags.get('owner')}, group={tags.get('group')}），拒絕刪除")

iid = RES["instance"]
# 先核對 instance 標籤與真實狀態
tags = {}
state = ""
try:
    d = call(["ec2", "describe-instances", "--instance-ids", iid,
              "--query", "Reservations[0].Instances[0].{Tags:Tags,State:State.Name}"])
    tags = {t["Key"]: t["Value"] for t in (d.get("Tags") or [])}
    state = d.get("State") or ""
except LabError as exc:
    if is_notfound(exc):
        print(f"[{utc()}] 注意: instance {iid} 已不存在，跳過狀態操作")
    else:
        raise
if tags and (tags.get("owner") != OWNER or tags.get("group") != GROUP):
    raise SystemExit(f"STOP: instance {iid} 標籤不符，拒絕操作")

if MODE == "--stop":
    if state != "stopped":
        call(["ec2", "stop-instances", "--instance-ids", iid])
        for _ in range(60):
            st = call(["ec2", "describe-instances", "--instance-ids", iid,
                       "--query", "Reservations[0].Instances[0].State.Name"])
            if st == "stopped":
                break
            time.sleep(5)
    st = call(["ec2", "describe-instances", "--instance-ids", iid,
               "--query", "Reservations[0].Instances[0].State.Name"])
    if st != "stopped":
        raise SystemExit("STOP: instance 未在預期時間內停止")
    print(f"[{utc()}] instance {iid} 已停止（保留）")
    print("保留清單: instance（stopped）、SG、key pair —— 下週 W4 啟動前重核對 public IP 與 SG 來源")
else:
    if state != "terminated":
        call(["ec2", "terminate-instances", "--instance-ids", iid])
        for _ in range(60):
            st = call(["ec2", "describe-instances", "--instance-ids", iid,
                       "--query", "Reservations[0].Instances[0].State.Name"])
            if st == "terminated":
                break
            time.sleep(5)
    st = call(["ec2", "describe-instances", "--instance-ids", iid,
               "--query", "Reservations[0].Instances[0].State.Name"])
    if st != "terminated":
        raise SystemExit("STOP: instance 未在預期時間內終止")
    vol, eni = RES["volume"], RES["eni"]
    v_gone = gone(["ec2", "describe-volumes", "--volume-ids", vol])
    e_gone = gone(["ec2", "describe-network-interfaces", "--network-interface-ids", eni])
    sg = RES["sg"]
    check_tags(sg, "security-group")
    call(["ec2", "delete-security-group", "--group-id", sg])
    sg_gone = gone(["ec2", "describe-security-groups", "--group-ids", sg])
    key = RES["key"]
    call(["ec2", "delete-key-pair", "--key-name", key])
    key_gone = gone(["ec2", "describe-key-pairs", "--key-names", key])
    print(f"[{utc()}] 五項讀回:")
    print(f"  instance: terminated OK")
    print(f"  根磁碟 {vol}: {'不存在 OK' if v_gone else '仍存在(異常)'}")
    print(f"  ENI     {eni}: {'不存在 OK' if e_gone else '仍存在(異常)'}")
    print(f"  SG      {sg}: {'不存在 OK' if sg_gone else '仍存在(異常)'}")
    print(f"  key     {key}: {'不存在 OK' if key_gone else '仍存在(異常)'}")
PY