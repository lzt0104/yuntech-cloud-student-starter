# W2 私有物件與短效分享 — 增量報告（草稿，待學生確認）


## 週次／組別／成員／Git 版本

- 週次：W2
- 組別／成員：B11323222 劉政廷
- Git 版本（驗證當下 HEAD）：`6846c8f`（W1-W2 版本；本週新增 `labs/02-private-s3/s3lab.py` 尚未 commit）
- 執行時間（UTC）：2026-09-15T03:39:32Z（`date -u` 記錄；物件 LastModified 03:33:25/03:33:33）

## 需求與架構選擇

- 需求（labs/02-private-s3/README.md）：建立有自己標籤的私有 bucket，保存與更新合成文字，精確回收；短效 URL 只在程式記憶體使用。
- 架構選擇：
  - `labs/02-private-s3/s3lab.py` 包裝 `scripts/lab.py` 的 `clean_env()/run_aws()`，所有 CLI 請求固定 `learnerlab` profile＋us-east-1，避免環境變數劫持。
  - presign 用 Boto3 `generate_presigned_url`，URL 僅存於程式記憶體（stdout 只輸出 status／bytes），符合「不得輸出簽名 URL」。
  - bucket 名稱含自己標籤：`lab02-5329-b11323222-20260915`（小寫轉換：學號 B11323222 → b11323222）。

## AWS 區域、帳號末四碼、核准資源範圍、成本預估

- 區域：`us-east-1`；帳號末四碼：`5329`
- 核准資源範圍：1 個私有 bucket＋1 個合成文字物件；四項 public access block 全 true；不觸碰 EC2/RDS/IAM/既有 vpc/sg。
- 成本預估：物件 <1 KB、STANDARD 儲存、少量 API，接近零成本（Learner Lab 免費額度內）；未以帳單驗證。

## 部署與重建步驟（不含秘密）

1. 前置：W1 已建立 learnerlab profile（`~/.aws/`，repo 外）並通過 `verify-aws.sh`。
2. 寫入 `labs/02-private-s3/s3lab.py`（包裝 lab.py；子命令：create-bucket／put-public-block／get-public-block／put-object／get-object／compare／anonymous-get／presign-test／list-objects／delete-object／delete-bucket／head-bucket）。
3. 建立 bucket：`python3 labs/02-private-s3/s3lab.py create-bucket`（us-east-1 不帶 LocationConstraint）。
4. 鎖私有：`s3lab.py put-public-block` → `s3lab.py get-public-block`（四項 true）。
5. 合成文字（`/tmp/opencode/`）：v1 上傳 → 下載 → 比較；v2 覆寫同 key → 下載 → 比較。
6. 匿名拒絕：`s3lab.py anonymous-get`（`--no-sign-request`）。
7. 短效分享：`s3lab.py presign-test --expires 60 --wait 65`（記憶體內，200→403）。
8. 回收：`list-objects` 確認僅本題物件 → `delete-object` → `delete-bucket` → `head-bucket` 驗證 404。

## 成功測試：输入、預期、實際、時間、證據位置

| # | 輸入（命令） | 預期 | 實際（工具輸出） | 證據 |
|---|---|---|---|---|
| T2 | `s3lab.py create-bucket` | Location 回傳 | `"Location": "/lab02-5329-b11323222-20260915"`、`BucketArn: arn:aws:s3:::lab02-5329-b11323222-20260915` | 本會話輸出 |
| T3 | put→get-public-block | 四項 true | `BlockPublicAcls/IgnorePublicAcls/BlockPublicPolicy/RestrictPublicBuckets` 全 `true` | 本會話輸出 |
| T4 | put v1→get→compare | bytes 相同 | ETag `9c9c81a9…`；`bytes_equal=True`；sha256 同（bcd38ace…） | 本會話輸出 |
| T4 | put v2（覆寫）→get→compare | 更新生效、bytes 相同 | 新 ETag `e11795dc…`、61 bytes；`bytes_equal=True`；sha256 同（e12d4dfe…） | 本會話輸出 |
| T4 | `list-objects` | 僅本題物件 | 僅 `hello-b11323222.txt`（61 bytes, STANDARD） | 本會話輸出 |
| T5 | `anonymous-get` | 403 拒絕 | `AccessDenied`；無檔案寫入 | 本會話輸出 |
| T6 | `presign-test` | 200→403 | 效期內 `200 bytes=61`；過期 `403` | 本會話輸出 |
| T7 | delete→head-bucket | bucket 不存在 | 刪除成功；`head-bucket → 404` | 本會話輸出 |

## 拒絕／故障測試：操作、預期、實際、原因、最小修正

| 操作 | 預期 | 實際 | 原因／最小修正 |
|---|---|---|---|
| 匿名 `get-object --no-sign-request` | 403 AccessDenied（私有 bucket 隱藏存在性） | `AccessDenied`，無檔案落地 | 私有性成立（驗收項） |
| presign URL 過期後 GET | 403（Request has expired） | `status=403` | 短效防護（驗收項） |
| `presign-test` 執行 | 正常執行 | `ModuleNotFoundError: No module named 'boto3'` | **一次修正**：devcontainer 未預裝 Boto3 → `python3 -m pip install --user boto3`（1.43.94）→ 重跑成功 |

## 一次請求經過哪些服務與權限檢查

以 `create-bucket` 為例：`s3lab.py` → `lab.run_aws()`（`clean_env` 過濾 `AWS_*`、固定 profile/region/credentials file）→ AWS CLI SigV4 簽章 → S3 `CreateBucket`（全域命名空間檢查）→ 回傳 Location/ARN。後續 `put-object` 需 `s3:PutObject`、`put-public-access-block` 需 `s3:PutBucketPublicAccessBlock`、`get-object` 需 `s3:GetObject`；權限來源為 Learner Lab 臨時 assumed-role，本週未修改 IAM。presign 路徑：Boto3 以 learnerlab profile 簽署 URL（記憶體）→ 直接對 S3 endpoint 發 HTTP GET。

## AI 協助內容、本人驗證與修改

- AI 協助（模型建議，依會話記錄）：規劃 T1–T8、撰寫 s3lab.py、執行並記錄 T2–T7 輸出、診斷 boto3 缺失並建議最小修正、整理報告草稿。
- 聲明：草稿工具輸出為實際執行；presign URL 未輸出、未入 Git。

## 精確資源 ID 清單與回收／保留理由

| 資源 ID | 類型 | 建立者 | 回收／保留 |
|---|---|---|---|
| `arn:aws:s3:::lab02-5329-b11323222-20260915` | S3 bucket | 本組（T2） | **已回收**（T7 刪除；head-bucket 404） |
| `hello-b11323222.txt`（key） | S3 object | 本組（T4） | **已回收**（T7 刪除） |
| `vpc-0e3d26d914c45e0d6`、`sg-0ab242f945366dcf8` | 預設 VPC／SG | Learner Lab（W0 盤點） | 保留、未觸碰 |

## 成本觀察與不確定性

- 觀察：<1 KB 標準儲存數分鐘、約 10 次 API 呼叫，預期零費用。
- 不確定性：未以帳單/Billing API 驗證；bucket 已刪除，無持續費用。

## 未測部分／阻塞／下一步

- 阻塞：無（boto3 缺失已修正）。
- 下一步：報告經本人確認後 commit（`labs/02-private-s3/s3lab.py`＋報告）；W3 起 Lab 依同流程：先 verify＋inventory 盤點再動手。