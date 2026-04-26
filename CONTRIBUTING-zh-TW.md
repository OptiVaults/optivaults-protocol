# 貢獻 OptiVaults V1

感謝對 OptiVaults V1 的關注。V1 以 **Cardano DeFi 公共財參考實作** 的姿態、Apache 2.0 授權釋出——只要是能強化程式碼、強化審計可信度、或讓人更容易 fork 來做特化的貢獻,都歡迎。

本文件說明:怎麼建置開發環境、我們歡迎哪些類型的貢獻(以及哪些需要先討論),PR 的期待、測試與審計姿態,以及安全性通報流程。

## 貢獻要開在哪個 repo?

OptiVaults V1 拆成兩個 repo(見 `README-zh-TW.md §「兩層架構」`):

- **本 repo(`optivaults-protocol`)**——**協議層**:Aiken validators、協議 spec、whitepaper、部署流程。**合約變更、spec 修正、白皮書編輯、部署腳本改善**,都走這個 repo。
- **[`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference)**——**operator 參考實作**:TypeScript keeper、API server、frontend、CLI 工具。**Keeper runtime bug、frontend UX、API 改善、CLI 打磨**,走那個 repo。

**不確定就開在這裡**——維護者會在 repo 歸屬錯誤時移動 PR。

---

## TL;DR——開 PR 前先看這幾點

1. 讀過 `README.md` + `whitepaper/whitepaper.md`(或 `whitepaper-zh-TW.md`),先理解定位與信任模型。
2. `contracts/` 裡 `aiken check` 必須全綠(194 個 test / 689 個隨機化 check / 0 error)。
3. 合約改動需要附一個 regression test 在 `lib/vault/tests/`。
4. 規格 / 文件改動請確認內部交叉引用還接得上(validator 名稱、redeemer tag、欄位數)。
5. 不要 commit secret、mainnet signer PKH、或真的 Blockfrost key。這些屬於 `private/`(gitignored)或 operator 的 `.env`,絕對不進 repo。
6. **安全性相關的發現請寄到 `optivaults@gmail.com`(PGP key 在 optivaults.app/security),不要開公開 issue。** 詳見下方 §安全通報。

---

## 1. 環境建置

**前置需求**:

- Aiken `v1.1.x`(確切 patch 版本看 `contracts/aiken.toml`——PlutusV3 的 cost model 對 patch 版本敏感,可重現性很重要)
- Node.js 20.x+,搭配 `tsx` 來跑部署工具與 E2E 腳本
- Blockfrost Preprod project ID(開發與測試用免費版就夠)
- 一個已解鎖的 key daemon,或 Preprod 測試用的 seed phrase 環境變數(貢獻者環境**絕對不要**放 mainnet seed)

**建置 + 測試合約**:

```bash
cd contracts
rm -rf build plutus.json
aiken build                       # 重新產生 plutus.json
aiken check                       # 跑 194 個 test + 689 個隨機化 check
```

開 PR 前,分支上的 `aiken check` 必須全綠。新增 test 請放在 `lib/vault/tests/`,命名遵守現有慣例(`<feature>_test.ak`)。

**跑 Preprod 部署 ceremony 乾跑**(選用,deploy/* 相關貢獻者可跑):

```bash
tsx deploy/deploy.ts --network Preprod --releaseTag <your-test-tag> --dryRun
```

乾跑會驗證設定檔解析 + compile 步驟,不會送任何 TX。

---

## 2. 貢獻類型

### 直接開 PR 沒問題

- **Bug fix**——Aiken validator 的修正(必須附一個 regression test,示範舊版錯誤 + 新版正確)。
- **測試覆蓋強化**——更多 property-based test(`aiken/fuzz`)、更多邊界條件單元測試、`tests/preprod/` 裡更多 E2E 情境。
- **文件清晰化**——錯字修正、規格與文件與白皮書與 Aiken inline 註解的用字改善。
- **部署工具打磨**——冪等性改善、錯誤訊息改善、可觀測性。
- **i18n**——product-overview / whitepaper 除了現有的 EN + 繁體中文以外的新語言翻譯。
- **鏈下參考工具**——helper 腳本、decode 驗證器(像 `deploy/tools/verify-minswap-v2-decode.ts`)、部署健檢。

### 請先討論(開 issue 或寄信,再開 PR)

- **新增 validator** 或 **調整 validator 拓撲**(例如切分 / 合併)。這會影響審計範圍、ceremony TX 數、部署資金需求,以及對已部署 Preprod ceremony 的向後相容性。實作前先討論動機。
- **新增治理 action kind**(`ActionKind` 新增 enum)。每個新 action 都多一層審計面 + timelock 表條目 + payload hash helper。先說明為什麼不能沿用現有的。
- **新增 SwapAdapter 整合**(例如 SundaeSwap V3、Splash V2)。這走 `spec/swap-adapter.md §7` 的流程——先做規格討論,再做 adapter 實作 + 審計,最後送治理白名單提案。
- **經濟參數變更**(費用上限、buffer 目標、oracle 容忍度)。治理用 `UpdateStrategy` / `UpdateFee` / `UpdateSlippagePolicy` 在 runtime 調整實際值——如果 PR 要改的是寫死在合約裡的**上限常數**,那是政策層級的變更,需要社群討論。
- **VaultDatum 欄位的 breaking change**。29 欄位的結構在 V1 上線時鎖定;任何 schema 變更都會觸發 V2,並且打掉 sunset / migration 路徑。

### 不接受

- **移除 4.5% 績效費硬上限**——`constants.ak` 裡的 `max_performance_fee_bps = 450` 是核心安全不變量。費率在 [0, 450] 範圍內透過治理 `UpdateFee` 調整;上限本身要往上推,必須走 V2。
- **新增 admin-drain redeemer**——任何可能把金庫資金送到非存入者地址的 redeemer,在 V1 都不在範圍內。緊急路徑一律走治理 + 公開揭露。
- **自動化 adapter 註冊**(任何人部署 adapter 就能直接用,不經治理審視)。V1 要求人類治理白名單,見 `spec/swap-adapter.md §10`。
- **閉源 keeper 實作**。Keeper 必須維持 Apache 2.0 + 可重現——這正是讓存入者在預設 keeper 停擺時,能透過 `emergency-withdraw` 自助退場的前提。

---

## 3. PR 的期待

### Commit 紀律

- 一個 commit 對應一個邏輯變更。用 rebase,不用 squash-and-merge。
- Commit message:祈使句、標題 ≤ 72 字元、body 說明**為什麼**(參考現有的 `git log`)。
- **不要**加 `Co-Authored-By:` 尾行,除非使用者明確要求。
- **不要**在訊息中寫「still pending」「deferred work」「memory update」或對未來的臆測——commit 描述的是「這筆 commit 裡有什麼」,不是「還沒進去的是什麼」。
- 不要把規劃文件 / 決策紀錄 commit 進 diff,除非使用者明確要求。

### PR 說明

- 引用觸發這次工作的 issue 或 Discord 討論(如果有)。
- 總結**做了什麼**與**為什麼**。
- 合約變更:列出 hash delta(用 `git show HEAD:contracts/plutus.json | jq '.validators[]|{title,hash}'` 或等效的鏈下 diff)。
- 新增測試:標出測試數差異(例如 `194 → 198 tests`)。
- 規格 / 文件變更:確認跨文件的一致性(例如 validator 數、欄位數、size 表)。

### 審視

- 動到 Aiken validator 的 PR,需要走過一輪內部 review + CI 的 `aiken check` 通過才合併(CI 目前還沒架——V1 pre-mainnet 期間暫時接受「自行在本機跑」,由合併者做;提交者需自備 CI 證據)。
- 純文件 PR 可以在一位 reviewer 通過的情況下合併(如果 V1 早期 operator 與 reviewer 是同一個身份,也可以自我批准)。
- Keeper 參考實作的 PR(`keeper/` 開工後)有自己一套 review 慣例,TBD。

### 授權 + CLA

- **沒有 CLA。** 本專案 Apache 2.0 進出一致(inbound=outbound)。
- 開 PR 即視為同意等同 Developer Certificate of Origin (DCO) 的聲明:這段程式碼是你有權提交的、以 Apache 2.0 授權、你願意被以符合授權條款的方式用於衍生作品。

---

## 4. 測試期待

### 單元測試

任何新的 validator 行為或不變量,都必須至少有一個單元測試。放在 `contracts/lib/vault/tests/<feature>_test.ak`。測試套件透過 `aiken check` 跑——整個 suite 的隨機化 check 數請保持合理(加一個 property test × 100 iter 沒問題;要加 × 10,000 請先討論,因為 `aiken check` 的耗時是 operator 面的體驗)。

### Property 測試

用 `aiken/fuzz v2.2.0` 做對抗性覆蓋。參考 `property_test.ak` 與 `r72_test.ak` 的既有模式。

### Preprod E2E 測試

新增 redeemer 路徑或改變 redeemer 語意時,要在 `tests/preprod/` 加一個對應的 Preprod E2E 腳本。既有的 `10-deposit-direct.ts` / `11-withdraw-direct-partial.ts` 是 canonical 的樣式範例(ceremony 狀態檔載入 + Blockfrost provider + key daemon → build TX → submit → 驗證 post-state)。

腳本用階段編號命名:`0X-ceremony-health`、`1X-user-flow`、`2X-compound`、`3X-merge-utxo`、`4X-protocol`、`5X-governance`、`6X-sunset`。新增腳本請跟上這個慣例。

### CI / 可重現性

- Aiken 版本鎖在 `aiken.toml`。不要在沒討論的情況下升版——PlutusV3 的 cost model 會跨 patch 版本變動,會改變 validator hash。
- `plutus.json` 是 gitignored(自動產生)。不要 commit。
- `deploy/state/` 底下的部署 ceremony 狀態檔也是 gitignored(跟著 operator 走)。

---

## 5. 審計參與

V1 的內部審計採**涵蓋區方法論**(A–F 區,見 `docs/audit-scope.md`),取代早期版本使用的逐輪編號制。涵蓋區計畫就是外部審計範圍的權威來源。

目前已知有開放狀態的審計發現(貢獻時請留意):

- **R73 F-1 (MEDIUM)**:`vault_recall.MergeUtxo` 在 `vault_gov_emergency.EmergencyWithdraw` / `vault_admin_deploy.AdminDeployNonDeposit` 的 `valid_allocs` 不變量前有 admissibility 缺口。修補排在下一輪(見 `private/audits/r73-donation-gap.md`——僅 operator 可見)。若你動到 `vault_recall.ak` 或共用的 `verify_protocol_fields_preserved` helper,注意這個 pending 項目。

內部分類為 LOW 或 INFO 的發現,收錄在每輪的審計檔案裡(operator 可以在 `private/audits/` 看到),除非你改到受影響的 validator 區域,否則不會阻擋貢獻。

---

## 6. 安全通報

**安全相關的發現,請不要開公開 issue。** 用私下管道:

- **Email**:`optivaults@gmail.com`
- **PGP key**:`optivaults.app/security`(加密敏感的技術細節)

我們會在 72 小時內私下確認收到、7 天內完成 triage。V1 採用的是**責任揭露政策(RDP) + 酬庸式 (ex gratia) 肯定**框架,不是結構化的 bug bounty tier——完整條款見 `docs/audit-scope.md §6`。正式的 bounty 計畫是 post-external-audit + post-TVL-scale 的考量,不是 V1 啟動時的承諾。

若你不確定一個發現算不算安全敏感,寧可走私下通報。我們寧願收到一筆低嚴重性、事後請你改開公開 issue,也不要透過公開 bug tracker 才知道一個 CRITICAL。

---

## 7. 溝通與專案協作

- **快速問題 / 實作討論**:Discord(邀請連結在 optivaults.app)。
- **設計提案 / 規格變更**:在鏡射 repo 開 GitHub issue,或在 Discord 起 thread。
- **治理相關政策討論**(費率、策略配置、adapter 白名單):依 `spec/governance.md` 走社群管道 + 鏈上 `QueueAction` + 14-21 天 timelock + 公開揭露。

---

## 8. 授權

開 PR 即代表你同意你的貢獻以 **Apache License 2.0** 授權(repo 根目錄的 `LICENSE`)。

選這個授權是刻意的:V1 的成功指標包含「架構被其他 Cardano 團隊 fork + 特化」(見白皮書 §1)。在 pre-audit 驗證期限制重用,會跟這個貢獻導向的姿態互相矛盾。
