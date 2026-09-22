#!/usr/bin/env bash
# W3 個人部署：1 SG + 1 key pair + 1 台 AL2023 主機＋inspection 雛型
# 用法: bash deploy/up.sh；所有 AWS 呼叫皆透過 scripts/lab.py 的 run_aws（learnerlab profile）
# 注意：本腳本會存取 ~/.ssh（產生/沿用 ed25519 私鑰）與 SSH 連線，請在自己的 terminal 執行。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SETTINGS=".local/w03.env"
[[ -f "$SETTINGS" ]] || { echo "STOP: 缺少 $SETTINGS" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SETTINGS"
for v in GROUP OWNER NAME_BASE SOURCE_IP COMMIT REGION VPC_ID SUBNET_ID AMI_ID; do
  [[ -n "${!v:-}" ]] || { echo "STOP: $SETTINGS 缺少 $v" >&2; exit 1; }
done

SHA="$(git rev-parse --verify --end-of-options "${COMMIT}^{commit}")"
echo "部署 commit: $SHA"
if [[ -n "$(git status --porcelain -- app/service.py deploy/nginx.conf)" ]]; then
  echo "注意: app/service.py 或 deploy/nginx.conf 有未 commit 修改，打包只取 $SHA"
fi

# ---- 工具函式 ----
run_aws() {   # 所有 AWS 呼叫統一走 lab.run_aws（clean_env + learnerlab）
  python3 - "$REGION" "$@" <<'PY'
import json, sys
sys.path.insert(0, "scripts")
from lab import run_aws
print(json.dumps(run_aws(sys.argv[2:], sys.argv[1])))
PY
}
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log5() { echo "$(ts) $*" | tee -a .local/w03-five-layers.txt; }
record() {
  python3 - "$1" "$2" <<'PY'
import json, pathlib, sys
p = pathlib.Path(".local/resources.json")
data = json.loads(p.read_text()) if p.exists() else {}
k, v = sys.argv[1], sys.argv[2]
if data.get(k) != v:
    data[k] = v
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(f"已記錄 {k}={v}")
PY
}
CTAGS="Key=course,Value=yuntech-115-1 Key=week,Value=w03 Key=group,Value=${GROUP} Key=owner,Value=${OWNER}"
# 正確的 CLI shorthand: Tags=[{Key=course,Value=...},{Key=week,Value=...},...]
build_tagspec() {
  local rt="$1"; shift
  local part="" kv
  for kv in "$@"; do part="${part}${part:+,}{${kv}}"; done
  echo "ResourceType=${rt},Tags=[${part}]"
}
SG_TAGS="$(build_tagspec security-group Key=course,Value=yuntech-115-1 Key=week,Value=w03 Key=group,Value=${GROUP} Key=owner,Value=${OWNER})"
KEY_TAGS="$(build_tagspec key-pair Key=course,Value=yuntech-115-1 Key=week,Value=w03 Key=group,Value=${GROUP} Key=owner,Value=${OWNER})"
INST_TAGS="$(build_tagspec instance Key=course,Value=yuntech-115-1 Key=week,Value=w03 Key=group,Value=${GROUP} Key=owner,Value=${OWNER} Key=Name,Value=${NAME_BASE})"

# ---- 身分核對 ----
python3 scripts/lab.py verify >/dev/null
ACCOUNT_SUFFIX="$(python3 - "$REGION" <<'PY'
import sys
sys.path.insert(0, "scripts")
from lab import context
print(context()["account"][-4:])
PY
)"
echo "身分 OK（account 末四碼 ${ACCOUNT_SUFFIX}）"

# ---- 承諾：印出將建立清單並等確認 ----
cat <<EOF
將要建立（本週範圍，同一時間一台主機）：
  - Security group  ${NAME_BASE}-sg    入站 TCP 22/80，來源僅 ${SOURCE_IP}
  - EC2 key pair    ${NAME_BASE}-key   由 ~/.ssh/${NAME_BASE}.pub（ed25519）匯入
  - EC2 instance    ${AMI_ID} / t3.micro / ${SUBNET_ID} / IMDSv2=required
                    根 gp3 8GiB 加密 DeleteOnTermination；user data 已打包（${SHA}）
  - 標籤            course=yuntech-115-1 week=w03 group=${GROUP} owner=${OWNER}
執行會產生雲端費用（粗估少於 1 美元，以官方計價頁為準）；失敗仍需依資源清單回收。
EOF
ans=""
read -r -p "輸入 yes 以繼續，其他字元取消: " ans
[[ "$ans" == "yes" ]] || { echo "取消：未建立任何資源" >&2; exit 1; }

# ---- 打包 user data（每次重跑都重新打包）----
rm -f .local/w03-user-data.sh
bash deploy/make-user-data.sh "$SHA" .local/w03-user-data.sh

# ---- 1) Security group ----
SG_ID="$(run_aws ec2 create-security-group --group-name "${NAME_BASE}-sg" \
  --description "W3 inspection ${NAME_BASE}" --vpc-id "$VPC_ID" \
  --tag-specifications "$SG_TAGS" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["GroupId"])')"
run_aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$SOURCE_IP" >/dev/null
run_aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr "$SOURCE_IP" >/dev/null
record sg "$SG_ID"; echo "SG: $SG_ID"

# ---- 2) key pair（本機產 ed25519，只匯入公鑰）----
mkdir -p ~/.ssh; chmod 700 ~/.ssh
KEY_FILE="$HOME/.ssh/${NAME_BASE}"
if [[ ! -f "$KEY_FILE" ]]; then
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "w03-${NAME_BASE}" >/dev/null
  chmod 600 "$KEY_FILE"; echo "本機私鑰已產生: $KEY_FILE (600)"
else
  chmod 600 "$KEY_FILE"; echo "沿用既有私鑰: $KEY_FILE"
fi
KEY_NAME="$(run_aws ec2 import-key-pair --key-name "${NAME_BASE}-key" \
  --public-key-material "fileb://${KEY_FILE}.pub" \
  --tag-specifications "$KEY_TAGS" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["KeyName"])')"
record key "$KEY_NAME"; echo "key pair: $KEY_NAME"

# ---- 3) instance ----
BDM='[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":8,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]'
META='{"HttpTokens":"required","HttpEndpoint":"enabled"}'
INSTANCE_ID="$(run_aws ec2 run-instances --image-id "$AMI_ID" --instance-type t3.micro \
  --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" --key-name "$KEY_NAME" \
  --user-data "file://.local/w03-user-data.sh" \
  --block-device-mappings "$BDM" --metadata-options "$META" \
  --tag-specifications "$INST_TAGS" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Instances"][0]["InstanceId"])')"
record instance "$INSTANCE_ID"; echo "instance: $INSTANCE_ID"

# 讀回 instance 標籤（缺一即停，fail-closed）
verify_instance_tags() {
  python3 - "$INSTANCE_ID" <<'PY'
import sys
sys.path.insert(0, "scripts")
from lab import run_aws
rid = sys.argv[1]
tags = run_aws(["ec2", "describe-tags", "--filters", f"Name=resource-id,Values={rid}"], "us-east-1")
have = {t["Key"] for t in tags.get("Tags", [])}
need = {"course", "week", "group", "owner", "Name"}
missing = need - have
if missing:
    raise SystemExit(f"STOP: instance 標籤缺失 {sorted(missing)}")
print("instance 標籤完整:", sorted(need))
PY
}
verify_instance_tags

# ---- 層1 running + 取得 public IP ----
PUBLIC_IP=""
for _ in $(seq 1 60); do
  ST="$(run_aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].{S:State.Name,I:PublicIpAddress}")"
  S="$(echo "$ST" | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("S") or "")')"
  I="$(echo "$ST" | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("I") or "")')"
  if [[ "$S" == "running" && -n "$I" ]]; then
    PUBLIC_IP="$I"; log5 "層1 主機 running（${PUBLIC_IP}）"; break
  fi
  sleep 5
done
[[ -n "$PUBLIC_IP" ]] || { echo "STOP: 60 秒內未 running 或無 public IP（不自行建 EIP）" >&2; exit 1; }
record public_ip "$PUBLIC_IP"

# ---- early curl（running 後馬上，記錄失敗樣：exit 與 HTTP 分開）----
set +e
EARLY="$(curl -sS -m 8 -o /tmp/w03-early.out -w "http=%{http_code} time=%{time_total}" "http://${PUBLIC_IP}/health")"; EARLY_RC=$?
set -e
log5 "early curl exit=$EARLY_RC $EARLY"
[[ -f /tmp/w03-early.out ]] && sed -n '1,5p' /tmp/w03-early.out || true

# ---- 層2 狀態檢查 2/2 ----
for _ in $(seq 1 60); do
  SC="$(run_aws ec2 describe-instance-status --instance-ids "$INSTANCE_ID" \
    --query "InstanceStatuses[0].{I:InstanceStatus.Status,S:SystemStatus.Status}")"
  I="$(echo "$SC" | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("I") or "")')"
  S="$(echo "$SC" | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("S") or "")')"
  if [[ "$I" == "ok" && "$S" == "ok" ]]; then log5 "層2 狀態檢查 2/2"; break; fi
  sleep 5
done

# ---- 主機指紋核對（不關閉 host key 驗證）----
ssh-keyscan -T 10 "$PUBLIC_IP" > ".local/known_${NAME_BASE}" 2>/dev/null \
  || { echo "STOP: ssh-keyscan 失敗" >&2; exit 1; }
ssh-keygen -lf ".local/known_${NAME_BASE}"
fk=""
read -r -p "與教師參考值／組員比對指紋後輸入 yes：" fk
[[ "$fk" == "yes" ]] || { echo "取消：主機指紋未確認" >&2; exit 1; }
SSH=(ssh -i "$KEY_FILE" -o UserKnownHostsFile=".local/known_${NAME_BASE}" \
     -o BatchMode=yes -o ConnectTimeout=5 ec2-user@"$PUBLIC_IP")

# ---- 層3 cloud-init 完成 ----
for _ in $(seq 1 60); do
  if "${SSH[@]}" true 2>/dev/null; then break; fi
  sleep 5
done
log5 "層3 cloud-init --wait 開始"
"${SSH[@]}" "cloud-init status --wait" >/dev/null
log5 "層3 cloud-init 完成"

# ---- 層4 nginx:80 / inspection:127.0.0.1:8080 監聽 ----
for _ in $(seq 1 30); do
  OUT="$("${SSH[@]}" "ss -tln | grep -E ':(80|8080) ' || true")"
  if echo "$OUT" | grep -q ':80 ' && echo "$OUT" | grep -q ':8080 '; then
    log5 "層4 監聽 80 + 127.0.0.1:8080"; break
  fi
  sleep 5
done

# ---- 層5 /health 200 且 version==SHA ----
VER=""; CODE=""
for _ in $(seq 1 60); do
  CODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${PUBLIC_IP}/health" || true)"
  BODY="$(curl -sS -m 5 "http://${PUBLIC_IP}/health" || true)"
  VER="$(echo "$BODY" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("version",""))
except Exception: print("")' 2>/dev/null || true)"
  if [[ "$CODE" == "200" && "$VER" == "$SHA" ]]; then log5 "層5 /health 200 version=$VER"; break; fi
  sleep 5
done
[[ "$CODE" == "200" && "$VER" == "$SHA" ]] || { echo "STOP: 健康檢查未通過 (code=$CODE)" >&2; exit 1; }

# ---- 根磁碟/ENI 標籤（擁有權證據）----
VOL_ID="$(run_aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvda'].Ebs.VolumeId | [0]" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin))')"
[[ "$VOL_ID" == vol-* ]] || { echo "STOP: 讀不到根磁碟 ID（${VOL_ID}）" >&2; exit 1; }
ENI_ID="$(run_aws ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
  --query "NetworkInterfaces[0].NetworkInterfaceId" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin))')"
[[ "$ENI_ID" == eni-* ]] || { echo "STOP: 讀不到 ENI ID（${ENI_ID}）" >&2; exit 1; }
run_aws ec2 create-tags --resources "$VOL_ID" "$ENI_ID" --tags $CTAGS >/dev/null
record volume "$VOL_ID"; record eni "$ENI_ID"

echo "SUCCESS: /health 200，version=$SHA"
echo "資源清單: .local/resources.json；請把 ID 抄進 reports/W3-T1-resources.md"
echo "五層紀錄: .local/w03-five-layers.txt"