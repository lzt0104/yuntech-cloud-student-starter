# W3-T1 標籤事件紀錄（兩起）

週次：W3；組別：第一組；成員：T1；部署 commit：dbcbeae9a6a5767f30fefb3e446ef092054f0bf8。
日期：2026-09-22（UTC）。

## 背景與診斷

`deploy/up.sh` 五層部署成功後，結尾「為根磁碟／ENI 打標籤」失敗：

```
lab.LabError: ec2 create-tags: InvalidID.
```

原因：`up.sh` 內的 `run_aws` 包裝器輸出 `json.dumps(...)`，`--query "...VolumeId | [0]"` 取回的值帶有雙引號（`"vol-xxx"` 而非 `vol-xxx`），直接餵給 `create-tags --resources` 變成無效 ID。本紀錄的修正程式碼改以 `json.load` 解引號並驗證前綴。

## 修正命令（在學生 terminal 執行，經 lab.run_aws）

```bash
python3 - <<'PY'
import json, sys
sys.path.insert(0, "scripts")
from lab import run_aws
Q = "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='/dev/xvda'].Ebs.VolumeId | [0]"
vol = run_aws(["ec2", "describe-instances", "--instance-ids", "i-0845571206121061b", "--query", Q], "us-east-1")
eni = run_aws(["ec2", "describe-network-interfaces", "--filters", "Name=attachment.instance-id,Values=i-0845571206121061b",
               "--query", "NetworkInterfaces[0].NetworkInterfaceId"], "us-east-1")
assert isinstance(vol, str) and vol.startswith("vol-"), f"vol 異常: {vol}"
assert isinstance(eni, str) and eni.startswith("eni-"), f"eni 異常: {eni}"
print("VOL_ID =", vol); print("ENI_ID =", eni)
run_aws(["ec2", "create-tags", "--resources", vol, eni,
         "--tags", "Key=course,Value=yuntech-115-1", "Key=week,Value=w03",
         "Key=group,Value=第一組", "Key=owner,Value=T1"], "us-east-1")
print("標籤已設定")
print(json.dumps(run_aws(["ec2", "describe-tags", "--filters", f"Name=resource-id,Values={vol},{eni}"],
                         "us-east-1"), indent=2, ensure_ascii=False))
PY
```

## 實際輸出（工具證據）

```
VOL_ID = vol-0cd4c9c7af19e6427
ENI_ID = eni-00ee8ab188eb06e12
標籤已設定
```

`describe-tags` 讀回 8 筆（ENI 與根磁碟各 4 筆）：`course=yuntech-115-1`、`week=w03`、`group=第一組`、`owner=T1`。

## 後續

- `deploy/up.sh` 已修正 VOL_ID／ENI_ID 取法（解引號＋`vol-*`／`eni-*` 前綴驗證），供 T4 重建時重用。
- 補充：本紀錄不含完整帳號、憑證、私鑰或簽名網址。

---

# 第二起：tag-specifications 結構錯誤（down.sh 標籤防護攔截）

日期：2026-09-22（UTC），T4 步驟 1 回收第一台時發現。

## 事件

`bash deploy/down.sh` 刪除前核對 instance 標籤時停止：

```
STOP: instance i-0845571206121061b 標籤不符，拒絕操作
```

## 診斷（唯讀實測證據）

```
describe-instances Tags: [{Name: w03-g1-t1}]        ← instance 只有 Name
describe-tags sg-0793…:  [{owner: T1}]              ← SG 只有 owner
describe-tags w03-g1-t1-key: []                     ← key pair 無標籤
```

根因：`up.sh` 的 `--tag-specifications "Tags=[{${CTAGS// /,}}]"` 把多組
`Key=,Value=` 併進**同一個 struct**；AWS CLI shorthand 需要每個 Key/Value
各自一對大括號（`Tags=[{Key=course,Value=…},{Key=week,Value=…},…]`）。
同 struct 內 Key 重複時後值蓋前值 → instance 只剩最後一組 Name、SG 只剩
最後一組 owner、key 全消失。

## 修正

- 修正 A（`deploy/up.sh`）：新增 `build_tagspec` 產生 `{Key=,Value=}` 逐對
  大括號的合法 shorthand；instance 建立後新增 `verify_instance_tags`
  （讀回 course/week/group/owner/Name 五筆，缺一即 STOP，fail-closed）。
- 修正 B（現有資源補標籤）：`create-tags` 對 instance／SG／key 補齊標籤；
  注意 EC2 key pair 的資源 ID 是 `key-*` 的 **KeyPairId**（首次使用 key 名稱
  得到 `InvalidID`），本組為 `key-0954918fdc2b12042`。

## 結果（工具證據）

- 補標籤後 `bash deploy/down.sh` 通過核對，五項讀回 03:15:25Z 全 OK。
- 第二輪 `bash deploy/up.sh` 啟動當下即印出
  `instance 標籤完整: ['Name', 'course', 'group', 'owner', 'week']`；
  第二輪 VOL／ENI 讀回各 4 筆（course/week/group/owner）。
- 既有 `.local/resources.json` 的「key」欄位存 key 名稱，`--resources` 需用
  KeyPairId 時兩者不可混用（本紀錄已標註）。