#!/usr/bin/env bash
# W5 個人部署：把「已 commit 的版本」裝到原本那台主機，並放置服務秘密檔。
# 用法: bash deploy/deploy.sh [commit]      commit 預設 HEAD
# 所有 AWS 呼叫皆透過 scripts/lab.py 的 run_aws（learnerlab profile）
# 規格（labs/04-web-api/README.md「權杖與 deploy.sh」四條）：
#   1. 只部署已 commit 的版本（打包器與 up.sh 用同一份 make-user-data.sh）
#   2. 經 SSH 在原本那台主機執行安裝腳本，秘密檔經 SSH 標準輸入落地，再重啟一次 inspection
#   3. 結束時確認 /health 的 version 等於這次 commit、auth_configured 為 true
#   4. 執行前印出目標主機與 commit，等你確認
# 注意：秘密檔由腳本讀取但絕不印出；全程不使用 set -x；不得在命令列參數帶權杖。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SETTINGS=".local/w03.env"
SECRET=".local/app.env"
DB_SECRET=".local/db.env"
BUNDLE=".local/w05-user-data.sh"

# ---- 設定與身分 ----
[[ -f "$SETTINGS" ]] || { echo "STOP: 缺少 $SETTINGS（先跑過 W3 的 deploy/up.sh 才有）" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SETTINGS"
for v in GROUP OWNER NAME_BASE REGION; do
  [[ -n "${!v:-}" ]] || { echo "STOP: $SETTINGS 缺少 $v" >&2; exit 1; }
done
KNOWN=".local/known_${NAME_BASE}"
KEY_FILE="$HOME/.ssh/${NAME_BASE}"
[[ -f .local/resources.json ]] || { echo "STOP: 缺少 .local/resources.json（不知道要更新哪台主機）" >&2; exit 1; }

run_aws() {   # 所有 AWS 呼叫統一走 lab.run_aws（clean_env + learnerlab）
  python3 - "$REGION" "$@" <<'PY'
import json, sys
sys.path.insert(0, "scripts")
from lab import run_aws
print(json.dumps(run_aws(sys.argv[2:], sys.argv[1])))
PY
}
record() {
  python3 - "$1" "$2" <<'PY'
import json, pathlib, sys
p = pathlib.Path(".local/resources.json")
data = json.loads(p.read_text()) if p.exists() else {}
if data.get(sys.argv[1]) != sys.argv[2]:
    data[sys.argv[1]] = sys.argv[2]
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(f"已記錄 {sys.argv[1]}={sys.argv[2]}")
PY
}

if ! SHA="$(git rev-parse --verify --end-of-options "${1:-HEAD}^{commit}" 2>/dev/null)"; then
  echo "STOP: 無法解析 commit：${1:-HEAD}" >&2; exit 1
fi

echo "== 部署前檢查 =="
python3 scripts/lab.py verify

# 秘密檔：只檢查存在與權限，絕不讀出內容到畫面
if [[ ! -f "$SECRET" ]]; then
  echo "STOP: 缺少 $SECRET。請先自行產生兩個權杖（不要貼給任何人）：" >&2
  cat >&2 <<'EOF'
  umask 077
  python3 - <<'PY' > .local/app.env
  import secrets
  print("REPORTER_TOKEN=" + secrets.token_urlsafe(32))
  print("OPERATOR_TOKEN=" + secrets.token_urlsafe(32))
  PY
  chmod 600 .local/app.env
  stat -c '%a' .local/app.env      # 必須是 600
EOF
  exit 1
fi
SECRET_MODE="$(stat -c '%a' "$SECRET")"
[[ "$SECRET_MODE" == "600" ]] || { echo "STOP: $SECRET 權限是 $SECRET_MODE，必須是 600；請 chmod 600 後再執行" >&2; exit 1; }
echo "秘密檔 $SECRET 權限 600 OK（內容未讀出）"

[[ -f "$DB_SECRET" ]] || { echo "STOP: 缺少 $DB_SECRET（先執行 deploy/db-up.sh）" >&2; exit 1; }
DB_SECRET_MODE="$(stat -c '%a' "$DB_SECRET")"
[[ "$DB_SECRET_MODE" == "600" ]] || { echo "STOP: $DB_SECRET 權限是 $DB_SECRET_MODE，必須是 600；請 chmod 600 後再執行" >&2; exit 1; }
echo "秘密檔 $DB_SECRET 權限 600 OK（內容未讀出）"

[[ -f "$KEY_FILE" ]] || { echo "STOP: 缺少私鑰 $KEY_FILE（沿用 W3 產生的那把）" >&2; exit 1; }
chmod 600 "$KEY_FILE"
for key in REPORTER_TOKEN OPERATOR_TOKEN; do
  if ! grep -q "^${key}=" "$SECRET"; then
    echo "STOP: $SECRET 缺少 $key（只檢查鍵名，不顯示值）" >&2; exit 1
  fi
done
echo "秘密檔含 REPORTER_TOKEN / OPERATOR_TOKEN 兩個鍵 OK"
for key in DB_HOST DB_NAME DB_USER DB_PASSWORD; do
  if ! grep -q "^${key}=" "$DB_SECRET"; then
    echo "STOP: $DB_SECRET 缺少 $key（只檢查鍵名，不顯示值）" >&2; exit 1
  fi
done
echo "秘密檔含 DB_HOST / DB_NAME / DB_USER / DB_PASSWORD 四個鍵 OK"

if [[ -n "$(git status --porcelain -- app/service.py deploy/nginx.conf)" ]]; then
  echo "注意: app/service.py 或 deploy/nginx.conf 有未 commit 修改；打包只取 $SHA"
fi
echo "部署 commit: $SHA"

# ---- 核對目標主機（fail-closed：狀態與標籤都要對）----
# 注意：必須先攔截 python 的離開碼再拆行。若寫成 read <<<"$(python3 ...)"，
# 核對失敗時 read 仍會回 0，就不會停在這裡。
if ! PROBE="$(python3 - <<'PY'
import json, pathlib, sys
sys.path.insert(0, "scripts")
from lab import run_aws, context
ctx = context()
res = json.loads(pathlib.Path(".local/resources.json").read_text())
d = run_aws(["ec2", "describe-instances", "--instance-ids", res["instance"],
             "--query", "Reservations[0].Instances[0].{S:State.Name,I:PublicIpAddress,T:Tags}"],
            ctx["region"]) or {}
tags = {t["Key"]: t["Value"] for t in (d.get("T") or [])}
env = {}
for line in pathlib.Path(".local/w03.env").read_text().splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, _, v = line.partition("=")
        env[k.strip()] = v.strip().strip('"')
need = {"course": "yuntech-115-1", "week": "w03", "group": env["GROUP"], "owner": env["OWNER"]}
bad = {k: (tags.get(k), v) for k, v in need.items() if tags.get(k) != v}
if bad or d.get("S") != "running":
    print(f"{res['instance']} {d.get('S') or 'missing'} {d.get('I') or ''}")
    raise SystemExit("STOP: 主機標籤或狀態不符，拒絕部署 -> " + json.dumps(bad, ensure_ascii=False))
print(f"{res['instance']} {d['S']} {d['I']}")
PY
)"; then
  echo "STOP: 未通過主機核對，什麼都沒做" >&2; exit 1
fi
read -r IID ISTATE IP <<<"$PROBE"
echo "目標主機: $IID（$ISTATE，公開位址 $IP）"

# ---- 承諾：印出將要做的變更並等確認 ----
cat <<EOF
將要在「同一台主機」上執行（不建立任何新 AWS 資源）：
  1. 打包已 commit 的 $SHA（deploy/make-user-data.sh，與 up.sh 同一份）
  2. SSH 進 $IID（$IP）跑安裝腳本：更新 /opt/inspection 與 systemd unit，重啟 inspection、reload nginx
  3. 經 SSH 標準輸入合併寫入 /etc/inspection/app.env（root、600），再重啟一次 inspection
  4. 讀回 /health：要求 version=$SHA、auth_configured=true、db_configured=true
不會印出權杖、不會把權杖放進命令列、不進 user data、不進 Git。
注意：重啟 inspection 會清空記憶體裡的事件（README：本週事件只存記憶體）。
EOF
ans=""
read -r -p "輸入 yes 以繼續，其他字元取消: " ans
[[ "$ans" == "yes" ]] || { echo "取消：未變更主機" >&2; exit 1; }

# ---- 1) 打包（只取已 commit 的內容）----
rm -f "$BUNDLE"
bash deploy/make-user-data.sh "$SHA" "$BUNDLE"

# 驗證打包內容的成員清單：打包器是 base64+gzip，權杖就算被寫進程式也會被編碼掉，
# 用 grep 比對原文永遠比不到（等於沒有檢查）。真正有效的是列出 tar 成員，
# 確認只有白名單三個檔，秘密檔不可能被帶上去。
python3 - "$BUNDLE" <<'PY'
import base64, gzip, io, pathlib, re, sys, tarfile
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"<<'W3_ARCHIVE'[^\n]*\n(.*?)\nW3_ARCHIVE", text, re.S)
if not match:
    raise SystemExit("STOP: 打包腳本內容格式不符，找不到 archive 區塊")
raw = base64.b64decode(match.group(1))
with tarfile.open(fileobj=io.BytesIO(gzip.decompress(raw))) as archive:
    names = sorted(archive.getnames())
    sizes = {member.name: member.size for member in archive.getmembers()}
expected = ["app/service.py", "app/version", "deploy/nginx.conf"]
if names != expected:
    raise SystemExit(f"STOP: 打包內容成員不符：{names}（應為 {expected}）")
print("打包內容成員:", names, "（無秘密檔）")
print("  app/service.py", sizes["app/service.py"], "bytes / app/version", sizes["app/version"], "bytes")
PY

# ---- 2) 經 SSH 執行安裝腳本（安裝腳本經 stdin，不落地、不進 argv）----
SSH=(ssh -i "$KEY_FILE" -o UserKnownHostsFile="$KNOWN"
     -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10
     ec2-user@"$IP")
echo "== 安裝中（SSH 到 $IP）=="
if ! "${SSH[@]}" "sudo bash -s" < "$BUNDLE"; then
  echo >&2
  echo "STOP: 安裝腳本執行失敗。若錯誤提到 host key 被改變，" >&2
  echo "      請先與教師/組員核對新指紋，再手動刪除 $KNOWN 的舊紀錄；不要改成 StrictHostKeyChecking=no。" >&2
  exit 1
fi

# ---- 3) 秘密檔經 stdin 落地（root、600），再重啟一次 inspection ----
echo "== 放置權杖秘密檔並重啟服務 =="
"${SSH[@]}" "sudo install -d -m 700 /etc/inspection && \
             sudo sh -c 'umask 077; cat > /etc/inspection/app.env' && \
             sudo chown root:root /etc/inspection/app.env && \
             sudo chmod 600 /etc/inspection/app.env && \
             sudo systemctl restart inspection" < <(cat "$SECRET" "$DB_SECRET")

# 讀回主機上的權限與鍵名（只讀 metadata，不讀內容）
"${SSH[@]}" "sudo stat -c 'app.env 權限=%a 擁有者=%U' /etc/inspection/app.env; \
             sudo grep -c '^REPORTER_TOKEN=' /etc/inspection/app.env; \
             sudo grep -c '^OPERATOR_TOKEN=' /etc/inspection/app.env"

# 等服務真的起來再驗收（restart 後 8080 可能還沒 listen）
for _ in $(seq 1 20); do
  if "${SSH[@]}" "systemctl is-active inspection >/dev/null && ss -tln | grep -q ':8080 '"; then
    break
  fi
  sleep 2
done
"${SSH[@]}" "systemctl is-active inspection; ss -tln | grep -c ':8080 '" || true

# ---- 4) 資料通道驗收：version 與 auth_configured ----
VER=""; AUTH=""; DB_CONFIGURED=""; CODE=""
for _ in $(seq 1 30); do
  CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${IP}/health" || true)"
  BODY="$(curl -sS -m 5 "http://${IP}/health" || true)"
  VER="$(printf '%s' "$BODY" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("version",""))
except Exception: print("")' 2>/dev/null || true)"
  AUTH="$(printf '%s' "$BODY" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("auth_configured"))
except Exception: print("")' 2>/dev/null || true)"
  DB_CONFIGURED="$(printf '%s' "$BODY" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("db_configured"))
except Exception: print("")' 2>/dev/null || true)"
  if [[ "$CODE" == "200" && "$VER" == "$SHA" && "$AUTH" == "True" && "$DB_CONFIGURED" == "True" ]]; then break; fi
  sleep 3
done
echo "== /health =="
curl -sS -m 5 "http://${IP}/health" || true
echo
[[ "$CODE" == "200" && "$VER" == "$SHA" && "$AUTH" == "True" && "$DB_CONFIGURED" == "True" ]] \
  || { echo "STOP: 驗收未通過 (http=$CODE version=$VER auth_configured=$AUTH db_configured=$DB_CONFIGURED)" >&2; exit 1; }

record public_ip "$IP"
echo
echo "SUCCESS: 已更新同一台主機，version=$SHA，auth_configured=true，db_configured=true"
echo "顯示頁: http://${IP}/ （貼 operator 權令牌；權令牌由你本人貼，勿交給 Agent）"
echo "下一步: 跑 tests/idempotency_matrix.py 的 W5 冪等矩陣 5 列。"
