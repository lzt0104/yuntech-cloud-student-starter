#!/usr/bin/env bash
# W5：在既有主機所在 VPC 建立私有 PostgreSQL RDS 與其網路資源。
# 所有 AWS 呼叫皆透過 scripts/lab.py 的 run_aws；不以名稱搜尋或刪除資源。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SETTINGS=".local/w03.env"
RESOURCES=".local/resources.json"
DB_SECRET=".local/db.env"
[[ -f "$SETTINGS" && -f "$RESOURCES" ]] || {
  echo "STOP: 缺少 $SETTINGS 或 $RESOURCES（先完成 W3 主機部署）" >&2; exit 1;
}
# shellcheck disable=SC1090
source "$SETTINGS"
for v in GROUP OWNER NAME_BASE REGION; do
  [[ -n "${!v:-}" ]] || { echo "STOP: $SETTINGS 缺少 $v" >&2; exit 1; }
done

run_aws() {
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
data = json.loads(p.read_text())
key, value = sys.argv[1:]
if data.get(key) != value:
    data[key] = value
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(f"已記錄 {key}={value}")
PY
}

bash scripts/verify-aws.sh
python3 scripts/lab.py verify >/dev/null
INSTANCE_ID="$(python3 - "$RESOURCES" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8")).get("instance", "")
if not value.startswith("i-"):
    raise SystemExit("STOP: resources.json 沒有有效的 instance ID")
print(value)
PY
)"

HOST="$(run_aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{Vpc:VpcId,Subnet:SubnetId,State:State.Name,SG:SecurityGroups[0].GroupId,T:Tags}')"
read -r VPC_ID HOST_SUBNET HOST_STATE HOST_SG < <(python3 -c 'import json,sys
d=json.load(sys.stdin); tags={x["Key"]:x["Value"] for x in (d.get("T") or [])}
need={"course":"yuntech-115-1","week":"w03","group":sys.argv[1],"owner":sys.argv[2]}
if any(tags.get(k) != v for k,v in need.items()): raise SystemExit("STOP: 主機標籤不符，拒絕建立資料庫")
print(d.get("Vpc",""), d.get("Subnet",""), d.get("State",""), d.get("SG",""))' "$GROUP" "$OWNER" <<<"$HOST")
[[ "$HOST_STATE" == "running" || "$HOST_STATE" == "stopped" ]] || { echo "STOP: 主機狀態不符：$HOST_STATE" >&2; exit 1; }
[[ "$HOST_SG" == sg-* ]] || { echo "STOP: 讀不到主機 SG" >&2; exit 1; }

VPC_CIDR="$(run_aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlock' | python3 -c 'import json,sys; print(json.load(sys.stdin))')"
SUBNET_DATA="$(run_aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{Cidr:CidrBlock,AZ:AvailabilityZone,Id:SubnetId}')"
read -r SUBNET_A SUBNET_B AZ_A AZ_B < <(python3 - "$VPC_CIDR" "$SUBNET_DATA" <<'PY'
import ipaddress, json, sys

vpc = ipaddress.ip_network(sys.argv[1])
subnets = json.loads(sys.argv[2])
used = [ipaddress.ip_network(item["Cidr"]) for item in subnets]
by_az = {}
for item in subnets:
    by_az.setdefault(item["AZ"], []).append(item["Cidr"])
candidates = []
for network in vpc.subnets(new_prefix=24):
    if any(network.overlaps(existing) for existing in used):
        continue
    candidates.append(str(network))
if len(candidates) < 2 or len(by_az) < 2:
    raise SystemExit("STOP: VPC 沒有兩段不重疊 /24 或沒有兩個 AZ 可用")
azs = sorted(by_az)
print(candidates[0], candidates[1], azs[0], azs[1])
PY
<<<"$SUBNET_DATA")
echo "目標 VPC=$VPC_ID，主機 SG=$HOST_SG，私有子網=$SUBNET_A/$AZ_A、$SUBNET_B/$AZ_B"

cat <<EOF
將要建立（Learner Lab 費用依官方計價；RDS 建立後必須在下課時停止）：
  - VPC $VPC_ID 內兩個 /24 私有子網與一張只有 local 路由的路由表
  - DB subnet group、SG-db（只允許主機 SG $HOST_SG 的 TCP 5432）
  - PostgreSQL RDS ${NAME_BASE}-w5，db.t3.micro、20 GiB gp3、加密、不公開、單一 AZ
  - 本機 .local/db.env（600）與 .local/resources.json 的資源紀錄
回收方式：只依 resources.json 的 ID 停止 RDS/主機；私有子網、路由表、subnet group、SG-db 保留。
EOF
ans=""
read -r -p "輸入 yes 以建立上述資源，其他字元取消: " ans
[[ "$ans" == "yes" ]] || { echo "取消：未建立 AWS 資源" >&2; exit 1; }

TAGS="Key=course,Value=yuntech-115-1 Key=week,Value=w05 Key=group,Value=${GROUP} Key=owner,Value=${OWNER}"
TAG_SPEC="ResourceType=subnet,Tags=[{Key=course,Value=yuntech-115-1},{Key=week,Value=w05},{Key=group,Value=${GROUP}},{Key=owner,Value=${OWNER}}]"

ROUTE_TABLE_ID="$(run_aws ec2 create-route-table --vpc-id "$VPC_ID" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["RouteTable"]["RouteTableId"])')"
record w05_route_table "$ROUTE_TABLE_ID"
SUBNET_A_ID="$(run_aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_A" \
  --availability-zone "$AZ_A" --tag-specifications "$TAG_SPEC" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["Subnet"]["SubnetId"])')"
record w05_subnet_a "$SUBNET_A_ID"
SUBNET_B_ID="$(run_aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_B" \
  --availability-zone "$AZ_B" --tag-specifications "$TAG_SPEC" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["Subnet"]["SubnetId"])')"
record w05_subnet_b "$SUBNET_B_ID"
run_aws ec2 associate-route-table --route-table-id "$ROUTE_TABLE_ID" --subnet-id "$SUBNET_A_ID" >/dev/null
run_aws ec2 associate-route-table --route-table-id "$ROUTE_TABLE_ID" --subnet-id "$SUBNET_B_ID" >/dev/null
run_aws ec2 create-tags --resources "$ROUTE_TABLE_ID" "$SUBNET_A_ID" "$SUBNET_B_ID" --tags $TAGS >/dev/null

DB_SG_ID="$(run_aws ec2 create-security-group --group-name "${NAME_BASE}-db-sg" \
  --description "W5 private inspection database" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=course,Value=yuntech-115-1},{Key=week,Value=w05},{Key=group,Value=${GROUP}},{Key=owner,Value=${OWNER}}]" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["GroupId"])')"
record w05_db_sg "$DB_SG_ID"
run_aws ec2 authorize-security-group-ingress --group-id "$DB_SG_ID" --protocol tcp --port 5432 \
  --source-group "$HOST_SG" >/dev/null

DB_SUBNET_GROUP="${NAME_BASE,,}-w5-subnets"
run_aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "W5 private inspection database subnets" \
  --subnet-ids "$SUBNET_A_ID" "$SUBNET_B_ID" --tags $TAGS >/dev/null
record w05_db_subnet_group "$DB_SUBNET_GROUP"

RDS_ID="${NAME_BASE,,}-w5-db"
RDS_INPUT="$(mktemp .local/rds-input.XXXXXX)"
trap 'rm -f "$RDS_INPUT"' EXIT
chmod 600 "$RDS_INPUT"
python3 - "$DB_SECRET" "$RDS_INPUT" "$RDS_ID" "$DB_SUBNET_GROUP" "$DB_SG_ID" "$GROUP" "$OWNER" <<'PY'
import json, pathlib, secrets, sys
secret_path, input_path, identifier, subnet_group, sg, group, owner = sys.argv[1:]
password = secrets.token_urlsafe(30)
pathlib.Path(secret_path).write_text(
    "DB_HOST=\nDB_NAME=inspection\nDB_USER=inspection\nDB_PASSWORD=" + password + "\n",
    encoding="utf-8")
pathlib.Path(secret_path).chmod(0o600)
payload = {
    "DBInstanceIdentifier": identifier,
    "DBInstanceClass": "db.t3.micro",
    "Engine": "postgres",
    "AllocatedStorage": 20,
    "StorageType": "gp3",
    "StorageEncrypted": True,
    "MasterUsername": "inspection",
    "MasterUserPassword": password,
    "DBName": "inspection",
    "DBSubnetGroupName": subnet_group,
    "VpcSecurityGroupIds": [sg],
    "PubliclyAccessible": False,
    "MultiAZ": False,
    "BackupRetentionPeriod": 1,
    "Tags": [
        {"Key": "course", "Value": "yuntech-115-1"},
        {"Key": "week", "Value": "w05"},
      {"Key": "group", "Value": group},
      {"Key": "owner", "Value": owner},
    ],
}
pathlib.Path(input_path).write_text(json.dumps(payload), encoding="utf-8")
PY
run_aws rds create-db-instance --cli-input-json "file://$RDS_INPUT" >/dev/null
record w05_rds "$RDS_ID"
echo "RDS $RDS_ID 建立中；等待 available（請勿重跑本腳本）"

STATUS=""
for _ in $(seq 1 120); do
  INFO="$(run_aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
    --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible,Host:Endpoint.Address}')"
  read -r STATUS PUBLIC HOSTNAME < <(python3 -c 'import json,sys
d=json.load(sys.stdin); print(d.get("Status",""), d.get("Public", ""), d.get("Host", ""))' <<<"$INFO")
  if [[ "$STATUS" == "available" && "$PUBLIC" == "False" && -n "$HOSTNAME" && "$HOSTNAME" != "None" ]]; then
    break
  fi
  sleep 10
done
[[ "$STATUS" == "available" && "$PUBLIC" == "False" && -n "$HOSTNAME" ]] || {
  echo "STOP: RDS 尚未通過驗收（status=$STATUS public=$PUBLIC）；不要重跑，請稍後查 $RDS_ID" >&2; exit 1;
}
python3 - "$DB_SECRET" "$HOSTNAME" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = [line for line in path.read_text(encoding="utf-8").splitlines() if not line.startswith("DB_HOST=")]
path.write_text("DB_HOST=" + sys.argv[2] + "\n" + "\n".join(lines) + "\n", encoding="utf-8")
path.chmod(0o600)
PY
echo "RDS $RDS_ID status=$STATUS PubliclyAccessible=$PUBLIC"
echo "完成：資源 ID 已寫入 $RESOURCES，DB_SECRET=$DB_SECRET（內容未顯示、權限 600）"