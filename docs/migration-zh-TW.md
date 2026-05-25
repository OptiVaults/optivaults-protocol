# migration.md — 現有存入者遷移到 V1

V1 是 vault stack 的全新部署。Cardano 智能合約不可變,V1 **不能**原地升級現有的 vault UTxO。在前代內部驗證部署上的現有存入者(在 operator 文件中非正式稱為「internal-verification-era」)必須主動遷移自己的資金。

本文件是 canonical 使用者面遷移參考。

**層級界定**:遷移是**協議層**事件:存入者從內部驗證期 vault 合約提領 USDCx、再存進 V1 vault 合約,兩邊都是鏈上動作、用自己錢包完成。**Operator 層**(哪個 `optivaults.app` URL 提供 UI、哪個 keeper 處理 TX)**不是遷移路徑的一部分**;存入者可以只用 `withdraw-cli` + 任意錢包 + 任意 V1 存款 UI(OptiVaults 代跑或 fork 都行)完成遷移。完整兩層 framing 見 `whitepaper §3.5`。

---

## 1. 為何採用新部署

V1 引入了若干結構性變更,**無法**以 datum 升級表達:

- **兩個新 validator**(`keeper_stake_script`、`treasury`),各自帶 UTXO 與編譯期參數。
- **前代 datum 欄位被移除**:先前的內部驗證版本直接把 `keeper_pkh`(授權 PKH)與 `fee_collector`(USDCx 收費錢包)放在 `VaultDatum` 裡。V1 把兩者都換掉:
  - `keeper_pkh` → `vault_user` / `vault_keeper_hot` / `vault_protocol` / `vault_recall` / `vault_liqwid` 上的 `keeper_stake_hash` 編譯期錨點;實際授權 PKH 集合放在 stake-script 自己的 datum(由治理透過 `UpdateKeeperAuth` 可變,輪替時不用重部署 vault)。
  - `fee_collector` → `vault_keeper_hot`(Phase-77 後 Compound 的新家)上的 `treasury_hash` 編譯期錨點;Compound 的 treasury 份額路由到 script 地址,不是錢包 PKH。
- **費用拆分改變**(過去 100% 到單一錢包 → 3-way 拆分:40% keeper / 啟動時 0% gov pool / 60% treasury,keeper 份額在 validator 硬上限以支持開源第三方 keeper 經濟可行性),這要求新的 treasury UTxO 與 multisig_gov UTxO 在 Compound 時必須已經存在。
- **幾乎每個 validator 上都有新的編譯期參數**:每個 validator hash 都變了。

因為 validator hash 變了、script 地址變了,現有 UTxO 不可能被新 validator 消費。唯一安全路徑是:
1. 在全新地址部署 V1 stack。
2. 通知存入者。
3. 存入者依自己步調從舊 vault 提領,再存進 V1。

---

## 2. 遷移視窗

**Phase A — 並行運行(目標:30 天)**

舊 vault 與 V1 並行運作。**不強迫**。存入者從舊提領 → 收到 USDCx → 在自己時機存進 V1。

**Phase B — 舊 vault 收攤(目標:Phase A 後 7 天)**

透過治理把舊 vault 凍結(`frozen = 1`)。存款停用。**提領持續開放、沒有時間壓力**。

**Phase C — 舊 vault 殘餘**

舊 vault 中剩下的任何 UTxO 會繼續累積被動 Liqwid 收益,直到該存入者提領。Operator 承諾 Phase B 之後至少 12 個月內繼續對舊 vault 的 keeper 覆蓋。

**遷移後存入者得到的 V1 額外保護(資訊性)。** 從內部驗證 vault 遷移到 V1 後,以下三層舊 vault 沒有的結構性保護自動生效:

1. **Layer 1 — EmergencyWithdraw 改為 freeze-only**:V1 治理無法透過 EmergencyWithdraw 直接把損失寫進 `total_deposited`。所有損失帳務都得走 `vault_liqwid.RecallFromLiqwid`(治理 fallback 路徑)的實體 Recall,所以治理金鑰被入侵也無法只動 datum 把 share price 寫掉。
2. **Layer 2 — Frozen 狀態下的 USDCx swap-out**:在 `frozen = 1` 下,keeper(或治理 fallback)仍能透過 SwapAdapter 白名單把 NDV stable(DJED / USDM)swap 回 USDCx,讓存入者在緊急 freeze 期間仍能提領 1:1 的 USDCx,不必收到混合資產。
3. **Layer 3 — CommunitySunset 90 天 dead-man-switch**:`vault_user.CommunitySunset` 是 permissionless redeemer,任何 vUSDCx 持有者都可在 vault 連續 90 天無動靜時觸發。它原子性地設 `frozen = 1` + 開放 `RecallFromLiqwid` 與 `DeployToProtocol` 給任意 caller,讓任何存入者都能在沒有 operator 或治理配合的情況下推動完整的 Recall → swap → Withdraw 鏈。

這三層在單一簽名者治理失能的情境下,結構性界定存入者的損失上限,移除舊內部驗證 vault 所帶的「keeper 失能後 90 天尾端風險」。完整設計與 6 個情境威脅演練見 `docs/security-model.md §5.4`。

---

## 3. 使用者遷移步驟

**Step 1**:前往 optivaults.app/withdraw(舊 vault 端點)。
**Step 2**:提領全部份額。USDCx 回到你的錢包。
**Step 3**:前往 optivaults.app/deposit(V1 端點)。
**Step 4**:存入 USDCx。以 V1 的 mint 比例取得 vUSDCx(V1 第一位存入者是 1:1 起跳,之後依 share price)。

**不需要 bridge、不需要 claim 合約、不需要 admin 動作**。就是標準的提領 + 存款流程。

**Gas 成本**:兩筆 TX 合計約 3-5 ADA。

**Early-withdraw fee**:若你在舊 vault 的部位還在 `min_hold_seconds` 之內時提領,會觸發 **0.1% early-withdraw fee**(`early_withdraw_fee_bps = 10`,由 `vault_gov_policy.ak` 的 UpdateFee redeemer 透過共用的 `validate_update_fee` helper 硬性限制在 100 bps 以內)。參考值:舊的內部驗證 vault 用 `min_hold_seconds = 7 天`;V1 啟動時為 60 秒(白皮書 §2.4 硬性限制在 6 小時以內)。Operator 從 treasury audit reserve 為前 100 個遷移錢包補貼這筆費用,寄信到 `optivaults@gmail.com` 申請。(某些使用者可能在別處看到的 4.5% 數字,是對「已實現收益」抽的**績效費**,不是 early-withdraw fee,兩者分開,適用不同流程。)

---

## 4. Share price 保留

V1 存款時的 share price 與舊 vault 的 share price 沒有直接連動。你的流程是:
1. 在舊 vault 以舊 share price 提領 → 收到 USDCx。
2. 把同一筆 USDCx 以 V1 的 share price(從 1:1 起跳)存進 V1。

若舊 vault 累積了正收益,你已經在 USDCx 裡拿走了。若 V1 在你遷移後累積收益,你的 vUSDCx 的 share price 會隨之上升。

**淨效果**:遷移過程**沒有收益流失**。Gas 是唯一的成本(每個錢包最多補貼 5 ADA,從 treasury 出)。

---

## 5. 遷移期間的 Operator 動作

**舊 vault**:
- Keeper 在 Phase A/B/C 全程繼續跑 Compound + reconciliation。
- Phase A 開始之後,keeper **不**在舊 vault 上加新的 Liqwid 部位,新的收益機會送往 V1。
- 既有的舊 vault Liqwid 部位依提領需求的節奏 Recall 回來。

**V1 vault**:
- 新部署,包含全部 **17 個 logic validator + 4 個 one-shot NFT mint policy + 1 個 DEX adapter**(切分理由見 `spec/architecture.md` §4.1)。
- Treasury 起始餘額為 0(隨 V1 累積收益、Compound 費進帳而成長)。
- 治理簽名者:**1 位創辦人 + 2 位獨立 Cardano SPO,門檻 3,啟動時全員同意(依白皮書 §5.5 / §7.4)**。
- Phase A 啟動前 14 天公開公告。

---

## 6. 資料連續性

**不**會跨越的鏈上狀態:
- Vault UTxO(新地址、新 NFT)
- vUSDCx token policy(新 policy、新 token)
- Order UTxO(必須在 V1 重新送出)
- Liqwid 部位(舊的 Recall、V1 的獨立 Supply)

**會跨越的使用者資料(鏈下)**:
- 歷史 TX 審計軌跡(optivaults.app/history 依錢包地址索引,同時顯示舊 + V1)
- APY 歷史圖表顯示連續資料(舊 + V1 在 frontend 接起來)

---

## 7. 遷移後快照

Phase B 凍結時的所有舊 vault 部位快照,會公開發布:
- 鏈上以治理動作(no-op QueueAction commit IPFS hash)
- 鏈下在 optivaults.app/migration/snapshot(JSON + CSV)

這份快照是任何遷移補貼申請的參考文件。

---

## 8. 失敗模式

### 8.1 存入者不遷移

**不需要做任何事**。他們的舊 vault 部位永遠可以被消費。Operator 承諾 Phase B 之後至少 12 個月的 keeper 覆蓋。12 個月之後,operator 可以提案治理動作,讓舊 vault 的 keeper sunset,存入者仍然可以透過 `emergency-withdraw` self-serve 工具提領(不需要 keeper)。

### 8.2 遷移期間舊 vault keeper 停擺

`keeper_inactive` fallback 在 7 天後啟動(與 V1 同)。治理可以執行 Recall / Withdraw 路徑。使用者可以用綁在舊 vault 介面一起的 `withdraw-cli` self-serve 工具。

### 8.3 V1 在遷移期間發現重大 bug

Operator 透過鏈下 TVL 監控 breach 門檻停止 V1 存款(或在前端 gating 層手動把 cap 設為 0)。已遷移的使用者可以正常從 V1 提領。新遷移暫停,直到 V2 準備好。

### 8.4 遷移期間 USDCx 脫鉤

兩邊 vault 都依 depeg 協議停止存款。提領保持開放。遷移暫停,USDCx 穩定後恢復。

---

## 9. 時程(示意,視審計進度)

| 里程碑 | 日期(示意) | 前置條件 |
|--------|------------|---------|
| V1 內部審計完成 | — | 對新 validator 的內部審計輪次 |
| V1 外部審計完成 | — | 外部審計接洽 |
| V1 Preprod 完整 E2E | — | 審計全數通過 |
| V1 mainnet 部署 ceremony | — | 審計 + Preprod E2E |
| Phase A 啟動(並行) | 部署 + 1 天 | 14 天前公告 |
| Phase B 凍結舊 vault | Phase A + 30 天 | 治理動作 queue + execute |
| Phase C 長尾 | Phase B + 持續 | Operator 12 個月承諾 |

具體日期會在執行前至少 14 天,透過 Discord + email + 鏈上治理揭露公告。

---

## 10. 常見問題

**Q:遷移期間我會損失收益嗎?**
A:不會。舊 vault 的收益累積到你提領為止。V1 的收益從你存入 V1 時開始累積。Gas 成本(約 3-5 ADA)是唯一摩擦,且前 100 位遷移者會被補貼。

**Q:我可以遷移部分份額嗎?**
A:可以。舊 vault 的 withdraw 支援部分金額。可以拆成多筆 TX。

**Q:我提領後,舊的 vUSDCx token 會怎樣?**
A:在提領時被 burn 掉。不用再做其他動作。

**Q:我需要在 V1 上「claim」什麼才能拿到遷移補貼嗎?**
A:沒有自動 claim。遷移費補貼是事後處理,寄信到 `optivaults@gmail.com`,附上你的錢包地址,treasury audit reserve 會以 USDCx 退還 early-withdraw fee。

**Q:若我在前 100 位之外呢?**
A:適用標準 early-withdraw fee。或是等過了 `min_hold_seconds` 再提,就不扣費。

**Q:V1 會支援我現有的 vUSDCx 嗎?**
A:不會。V1 鑄的是新的 vUSDCx policy。兩個是不同 token。

**Q:舊 vault 最終會被關掉嗎?**
A:沒有計畫。Operator 承諾 Phase B 凍結後 12 個月的 keeper 覆蓋。12 個月之後,只要 UTxO 仍存在,存入者還是可以透過 `emergency-withdraw` self-serve 工具提領(不需要 keeper)。

---

## 11. 延伸閱讀

- `spec/architecture.md` — V1 validator 結構
- `docs/security-model.md` — V1 威脅模型 + 信任委派
- `docs/audit-scope.md` — V1 審計計畫 + cap 放寬的門檻
- `whitepaper/whitepaper.md §11` — 遷移穩定里程碑
