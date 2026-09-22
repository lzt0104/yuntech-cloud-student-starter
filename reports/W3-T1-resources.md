# W3 個人資源清單（第一組／T1）

帳號末四碼：5329；region：us-east-1；組名：第一組；組內代號：T1；部署 commit：dbcbeae（dbcbeae9a6a5767f30fefb3e446ef092054f0bf8）。
既有預設 VPC／子網／IGW 僅引用，不能刪除、不能修改。

## 既有引用資源（T1 唯讀核對觀測）

| 資源類型 | ID | 備註 |
|---|---|---|
| 預設 VPC | vpc-0e3d26d914c45e0d6 | 172.31.0.0/16，isDefault |
| 預設子網（us-east-1a） | subnet-086e28069f877301b | default-for-az；本次部署用 |
| 有效路由表（main） | rtb-0267218960ab0b5a3 | 含 0.0.0.0/0 → igw-…，子網無明確關聯時套用 |
| IGW | igw-0401ee904c31eb282 | 隨 VPC 既有 |
| 既有預設 SG | sg-0ab242f945366dcf8 | 不使用、不刪除；本週另建專用 SG |

## 第一輪（T2 部署 → T4 步驟 1 完整回收）

| 資源類型 | 第一輪 ID | UTC | 標籤／關聯證據 | 回收方式 | 回收後讀回（03:15:25Z） |
|---|---|---|---|---|---|
| EC2 instance | i-0845571206121061b | 02:38:30Z（層1 running） | 補標籤後 course/week/group/owner/Name | 依 ID terminate | terminated OK |
| 根 EBS | vol-0cd4c9c7af19e6427 | 建立後補標籤 02:4xZ | instance 關聯、DeleteOnTermination、標籤 4 筆 | 隨終止刪除 | 不存在 OK |
| ENI | eni-00ee8ab188eb06e12 | 建立後補標籤 02:4xZ | instance 關聯、標籤 4 筆 | 隨終止刪除 | 不存在 OK |
| Security group | sg-0793cdf6a28eee108 | 02:37Z | 補標籤後 4 筆 | 確認 ENI 清除後依 ID 刪除 | 不存在 OK |
| 匯入的 EC2 key pair | w03-g1-t1-key | 02:38Z | 本機 ~/.ssh/w03-g1-t1.pub（ed25519）對應 | 依 key name 刪除 | 不存在 OK |

第一台 public IP：3.84.211.97（隨回收釋放）。第一輪五項回收讀回 2026-09-22T03:15:25Z 全 OK。

### T3 故障測試（第一輪主機，實測輸出摘要）

| 測試 | 操作 | 實測結果 | 恢復 | 恢復後 |
|---|---|---|---|---|
| (a) 網路層 | 移除 SG 入站 80 | curl exit=28 http=000 8.00s | 加回原規則 | /health 200 |
| (b) 服務層 | 停止 inspection 服務 | http=502 exit=0 0.45s | 重新啟動服務 | /health 200 |
| (c) 程式層 | 停止 nginx | curl exit=7 http=000 0.23s | 重新啟動 nginx | /health 200 |

## 第二輪（T4 步驟 2 重建；本週結束保留，下週 W4 處理）

| 資源類型 | 第二輪 ID | UTC | 標籤／關聯證據 | 狀態 |
|---|---|---|---|---|
| EC2 instance | i-0fee3ab3d3338301c | 03:16:45Z running；03:20:03Z /health 200；03:22:46Z stopped | 啟動當下 5 筆（verify_instance_tags 通過、缺一即停） | 保留（stopped） |
| 根 EBS | vol-06d423089b9784f9b | 03:20Z 後 | instance 關聯、DeleteOnTermination、標籤 4 筆（03:2xZ 讀回） | 保留 |
| ENI | eni-0fe77c2e4d320ce20 | 03:20Z 後 | instance 關聯、標籤 4 筆（03:2xZ 讀回） | 保留 |
| Security group | sg-06679939d7ce3a6f3 | 03:16Z | 標籤 4 筆 | 保留 |
| 匯入的 EC2 key pair（同名重新匯入） | w03-g1-t1-key | 03:16Z | 本機 ~/.ssh/w03-g1-t1.pub（ed25519）對應；KeyPairId key-0954918fdc2b12042 | 保留 |

第二台 public IP：32.194.173.69（停止後重啟會變動，W4 啟動前需重核對）。本週結束主機為「保留（stopped）」，不刪除。
報告不含完整帳號、憑證、私鑰或簽名網址。