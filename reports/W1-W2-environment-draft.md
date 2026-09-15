# W1–W2 環境與唯讀盤點 


## 週次／組別／成員／Git 版本

- 週次：W1–W2
- 組別／成員：B11323222 劉政廷
- Git 版本（驗證當下 HEAD）：`6846c8f`（Limit current student release to W1-W2 labs）
- 執行時間（UTC）：2026-09-15T03:17:59Z（工具執行 `date -u` 記錄）

## 需求與架構選擇

- 需求（課程目標，labs/00-environment/README.md）：完成自己的 Codespace、隱藏憑證輸入與身分核對，說明 browser、Codespace、AWS 三者位置。
- 架構選擇：本週**零建立資源**，僅執行身分驗證（`sts:GetCallerIdentity`）與 5 項唯讀盤點（EC2/S3/RDS/VPC/SecurityGroups）；憑證存於 repo 外的 `~/.aws/`，所有 AWS CLI 呼叫經 `scripts/lab.py` 的 `clean_env()` 過濾環境變數後以 `learnerlab` profile 發出，防止請求被導到其他帳號。

## AWS 區域、帳號末四碼、核准資源範圍、成本預估

- 區域：`us-east-1`
- 帳號末四碼：`5329`（完整 12 位帳號不透出）
- 核准資源範圍：不建立、不變更、不刪除任何 AWS 資源；僅唯讀 API。
- 成本預估：唯讀 API 呼叫＋STS 臨時憑證，接近零成本；Learner Lab 免費額度內。

## 部署與重建步驟（不含秘密）

1. 在 Learner Lab console（browser）取得臨時憑證（Access key ID、Secret access key、Session token）與帳號 ID。
2. 學生在自己的互動 terminal 執行 `scripts/set-learnerlab-credentials.sh`，以 `getpass` 隱藏輸入 3 個憑證值；程式先以 `sts:GetCallerIdentity` 驗證帳號與 assumed-role 相符才寫入 `~/.aws/credentials`、`~/.aws/config`、`~/.aws/learnerlab-context.json`（均在 repo 外）。
3. 版本檢查：`aws --version`、`python3 --version`、`git --version`。
4. 身分核對：`scripts/verify-aws.sh`。
5. 唯讀盤點：`scripts/aws-inventory.sh`（5 項 bounded projection 查詢）。
6. 拒絕測試（可重現）：於非互動環境執行 `scripts/set-learnerlab-credentials.sh`，預期被拒絕且不寫入任何檔案。

## 成功測試：输入、預期、實際、時間、證據位置

| # | 輸入（命令） | 預期 | 實際（工具輸出） | 證據位置 |
|---|---|---|---|---|
| T1 | `scripts/set-learnerlab-credentials.sh`（學生 terminal，因 getpass 需互動） | `Verified and saved learnerlab profile outside the repo.` | 學生回報 T1 完成；間接由 T3 成功（Identity OK）證實 profile 生效 | 本會話記錄；`~/.aws/`（repo 外，不讀內容） |
| T2 | `aws --version && python3 --version && git --version` | 三版本正常輸出 | AWS CLI 2.36.42（Python 3.14.6）、Python 3.12.14、git 2.51.1 | 本會話工具輸出 |
| T3 | `scripts/verify-aws.sh` | `Identity OK: account ending XXXX, region ..., profile learnerlab`，且 `:assumed-role/` | `Identity OK: account ending 5329, region us-east-1, profile learnerlab`（符合預期格式） | 本會話工具輸出 |
| T4 | `scripts/aws-inventory.sh` | 空帳號＋預設 VPC（學生預測） | EC2 `[]`、S3 `[]`、RDS `[]`；VPC：`vpc-0e3d26d914c45e0d6`（172.31.0.0/16）；SG：`sg-0ab242f945366dcf8`（default，掛於該 VPC） | 本會話工具輸出（五段 JSON） |

## 拒絕／故障測試：操作、預期、實際、原因、最小修正

| 操作 | 預期 | 實際 | 原因／處置 |
|---|---|---|---|
| 在非互動環境執行 `scripts/set-learnerlab-credentials.sh` | `STOP: Credential entry requires your interactive terminal; never pass secrets as command arguments or chat.`，退出碼 1，不寫入檔案 | 與預期完全一致，exit=1，`~/.aws` 未變動 | 程式在 `sys.stdin.isatty()` 檢查處拒絕，防止秘密被非互動程序收錄；此為**實際觸發的拒絕證據** |
| ExpiredToken 情境 | 錯誤代碼 `ExpiredToken` → STOP，要求學生重新收錄憑證 | **未實際觸發**（本次憑證有效） | 臨時憑證過期屬正常現象；最小修正＝回 console 重新取得憑證、重跑 T1 |
| AccessDenied 情境 | 錯誤代碼 `AccessDenied` → STOP，停止操作、不修改 IAM | **未實際觸發**（本次權限正常） | 依規則不得修改 IAM／繞過限制；記錄後請教師核對 |

## 一次請求經過哪些服務與權限檢查

請求（例：`sts:GetCallerIdentity`）路徑：
1. `scripts/verify-aws.sh` → `lab.py verify()` 讀取 `~/.aws/learnerlab-context.json`（檢查帳號格式為 12 位、區域為 us-east-1/us-west-2）。
2. `clean_env()` 過濾環境中所有 `AWS_*`、`TF_*` 等變數，固定 `AWS_PROFILE=learnerlab`、`AWS_SHARED_CREDENTIALS_FILE`、`AWS_CONFIG_FILE`，避免被外部環境變數誤導。
3. AWS CLI 以 `--profile learnerlab` 簽章呼叫 STS；驗證回傳帳號與 context 一致、Arn 含 `:assumed-role/` 才繼續。
4. `aws-inventory.sh` 再以同一身分對 EC2/S3/RDS 執行 5 個唯讀 describe/list（bounded projection）。
- 權限來源：Learner Lab 提供的臨時角色（assumed-role）── 本週不需也不允許修改 IAM。

## AI 協助內容、本人驗證與修改

- AI 協助（模型建議，依會話記錄）：規劃 T1–T7、執行 T2–T5 唯讀/拒絕測試並記錄輸出、整理本草稿技術證據、解說 ExpiredToken/AccessDenied 差異。
- 本人驗證與修改：**待學生填寫**（例如：確認 T1 於自己 terminal 完成、核對 console 帳號末四碼 5329 與區域、複述三者位置、補組別成員等）。
- 聲明：草稿中的工具輸出為實際執行結果；標示「未實際觸發」者不得視為通過。

## 精確資源 ID 清單與回收／保留理由

| 資源 ID | 類型 | 建立者 | 回收／保留 |
|---|---|---|---|
| `vpc-0e3d26d914c45e0d6`（172.31.0.0/16） | 預設 VPC | Learner Lab 自動建立（非本組） | 保留；僅記錄，不刪除 |
| `sg-0ab242f945366dcf8`（default） | 預設 Security Group | Learner Lab 自動建立（非本組） | 保留；僅記錄，不刪除 |
| `~/.aws/` learnerlab profile＋context | 本機設定（repo 外） | T1 configure | 學期結束或不用時執行 `scripts/clear-aws-credentials.sh` 移除（不撤銷 STS、不刪 AWS 資源） |

本週未建立任何 AWS 資源。

## 成本觀察與不確定性

- 觀察：僅 5 項唯讀 API＋1 次 STS 身分查詢＋1 次拒絕測試，皆在免費額度內，預期無費用。
- 不確定性：未查詢帳單（本週未進行成本 API 查詢）；確切費用需後續以帳單/Billing 驗證，本欄暫記「唯讀操作，預期零費用，未以帳單驗證」。

## 未測部分／阻塞／下一步

- 未測：ExpiredToken、AccessDenied 未實際觸發（憑證有效、權限正常）；成本未以帳單驗證。
- 阻塞：無。
- 下一步：W3 起的 Lab 建置；每週先以 `verify-aws.sh`＋`aws-inventory.sh` 重新核對身分與既有資源後再動手；報告草稿經本人確認後存為正式報告。