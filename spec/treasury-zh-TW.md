# OptiVaults V1 — Treasury 規格

**範圍**:持有協議費用收入的鏈上 treasury 合約,具備分類帳會計與治理閘控的支出規則。

---

## 1. 目的

Treasury validator 持有每次 Compound 從收益中抽取的協議績效費。V1 啟動時是績效費的 60%(keeper 40% / gov 0% / treasury 60%——keeper 份額在 validator 硬上限以支持開源第三方 keeper 經濟可行性);Phase 2+ 透過 `UpdateFeeSplit` 啟用治理池,treasury 份額降到 55%(Phase 2)或 50%(Phase 3,validator 硬下限)。費用拆分的硬上限見 `spec/vault-datum.md §2.2`;UpdateFeeSplit 動作見 `spec/governance.md §4.3`。

資金分成**四個類別桶**,各自有不同用途、依比例的 inflow、以及各桶特有的支出規則。Treasury 是**鏈上課責機制**——任何存入者或第三方都能檢視 treasury UTxO、對照 Compound TX 驗證 inflow、並對照治理紀錄審視 spend 動作。

Treasury 也接收**被沒收的治理補償**(§3.3):未能在季度分配時取得資格的簽名者份額,**全數進 audit reserve**。這條次級 inflow 路徑在治理表現不佳時,強化了保護存入者的預算。

---

## 2. TreasuryDatum

```aiken
type SpendCategory {
  AuditReserve    // 累積未來第三方審計費用
  Operations      // 代管基礎設施成本
  RD              // 協議開發、bounty、生態補助
  Buffer          // 預期外支出、法律、事件應變
}

type TreasurySpendRecord {
  tx_hash: ByteArray,
  category: SpendCategory,
  amount: Int,
  recipient: Address,
  timestamp: Int,
}

type TreasuryDatum {
  // --- 各類別餘額(累積持有的 USDCx,分類別) ---
  audit_reserve_balance: Int,
  operations_balance: Int,
  rd_balance: Int,
  buffer_balance: Int,

  // --- Inflow 拆分比例(bps;四者加總必須 == 10000) ---
  audit_bps: Int,        // 啟動預設:4000(40%)——從 30% 上調,讓 audit reserve 累積速度在較小的 treasury 60% 份額下,仍維持為總 fee 的 24%(60%×40%=24%,與舊 80%×30% 相同)
  ops_bps: Int,          // 啟動預設:2500(25%)——從 40% 下調,因為 keeper 現在直接拿 40% 份額,平台層 infra 不必透過 ops bucket 重複補貼 per-keeper 成本
  rd_bps: Int,           // 啟動預設:2500(25%)——從 20% 上調,維持絕對 R&D 預算
  buffer_bps: Int,       // 啟動預設:1000(10%)——不變

  // --- 支出 cooldown 與上限(分類別) ---
  last_spend_time_audit: Int,        // POSIX ms——audit-reserve 24h cooldown 錨點
  last_spend_time_ops: Int,          // POSIX ms——operations 24h cooldown 錨點
  last_spend_time_rd: Int,           // POSIX ms——r&d 24h cooldown 錨點
  last_spend_time_buffer: Int,       // POSIX ms——buffer 24h cooldown 錨點
  last_param_update_time: Int,       // POSIX ms,UpdateParams cooldown 錨點
  monthly_cap_audit: Int,            // 各類別月出流上限(USDCx)
  monthly_cap_ops: Int,
  monthly_cap_rd: Int,
  monthly_cap_buffer: Int,

  // --- 近期支出紀錄(有上限的歷史) ---
  recent_spend_log: List<TreasurySpendRecord>,  // 最後 50 筆

  // --- 不可變身份 ---
  governance_policy: ByteArray,   // 支出授權所用的治理 NFT policy
  governance_name: ByteArray,
  min_audit_reserve: Int,         // audit_reserve_balance 的絕對下限
}
```

**總欄位數**:21。**部署後不可變**:3(`governance_policy`、`governance_name`、`min_audit_reserve`)。**Receive 可變**:只有四個 balance。**Spend 可變**:目標 balance、**對應的 `last_spend_time_<category>`**(其他不動——每個類別有自己的 24h cooldown 錨點)、`recent_spend_log`。**UpdateParams 可變**:`*_bps` 欄位、`*_monthly_cap` 欄位、`last_param_update_time`。

---

## 3. Redeemer

### 3.1 `Receive`——來自 Compound 的被動 inflow

當 Compound TX 把 V1 啟動的 60% 協議費份額(或 Phase 2+ 啟用治理池後更小的份額)付到 treasury UTxO 時觸發。Treasury validator 驗證新的 balance 是否依 split ratios 正確更新。

```aiken
Receive { incoming_amount: Int }
```

**驗證**:
- `incoming_amount > 0`
- 拆分計算:
  ```
  audit_delta   = incoming_amount * audit_bps / 10000
  ops_delta     = incoming_amount * ops_bps / 10000
  rd_delta      = incoming_amount * rd_bps / 10000
  buffer_delta  = incoming_amount - audit_delta - ops_delta - rd_delta   // 殘餘
  ```
- Continuing datum 中的新 balance:
  ```
  new.audit_reserve_balance == old.audit_reserve_balance + audit_delta
  new.operations_balance    == old.operations_balance + ops_delta
  new.rd_balance            == old.rd_balance + rd_delta
  new.buffer_balance        == old.buffer_balance + buffer_delta
  ```
- Treasury UTxO value(deposit-token 計)剛好增加 `incoming_amount`
- 其他 TreasuryDatum 欄位不變
- **只有 Receive 能帶 inflow**——沒有其他 redeemer 能讓資金進來

**Receive 本身不需要額外授權——Compound TX 已經是 keeper 授權的,Receive 只是驗證 inflow 會計一致。**

### 3.2 `Spend`——治理閘控的 outflow

由 MultisigGov 的 `ExecuteAction` 對應一筆已 queue 的 `TreasurySpend` 提案觸發。

```aiken
Spend {
  category: SpendCategory,
  amount: Int,
  recipient_idx: Int,
  audit_invoice_ref: Option<ByteArray>,  // AuditReserve 類別必填
}
```

**驗證**:
- TX 必須有一個被 spent 的 input 來自 `MultisigGov` validator 地址、攜帶治理 NFT(驗證治理授權)
- `amount > 0`
- `amount <= 目標類別餘額`(不可超支)
- **月度上限**:`amount + (過去 30 天內,依 recent_spend_log 計的該類別 Spend 金額和) <= 該類別的 monthly_cap`。30 天前的紀錄不計入。防止單一治理動作榨乾整個類別。
- **每類別 24 小時 cooldown**:對正在支出的該類別,`tx.validity_range.lower - last_spend_time >= 86_400_000`。
- **Audit reserve 下限**:若 `category == AuditReserve`:
  - `amount + min_audit_reserve <= old.audit_reserve_balance`(支出後餘額仍滿足不可變下限)
  - `audit_invoice_ref` 必須是 `Some(<hash>)`——提案須指向外部審計發票的 hash(honor-system;在治理提案階段強制;鏈上紀錄以保透明)
- `recipient_idx` 的 output 必須是合法的非 treasury 地址(不可 self-loop)
- `recipient_idx` 的 output 剛好收 `amount` USDCx
- Treasury UTxO value 剛好減 `amount` USDCx
- Continuing datum 中目標類別餘額剛好減 `amount`
- `last_spend_time` 更新為 `tx.validity_range.upper`
- `recent_spend_log` 前插一筆新 `TreasurySpendRecord`;若列表長度 > 50,最舊條目被丟掉
- 其他 TreasuryDatum 欄位不變

### 3.3 `ReceiveGovForfeit`——被沒收的簽名者補償流

當 MultisigGov 的 `DistributeSignerCompensation` TX 出現不合格簽名者、其份額被改導向 treasury audit reserve(Y1 forfeit 規則)時觸發。Treasury UTxO 必須在同一 TX 被消費;continuing output 反映加上 forfeit 後的 `audit_reserve_balance`。

```aiken
ReceiveGovForfeit { forfeit_amount: Int }
```

**驗證**:
- TX 同時消費一個 MultisigGov UTxO,其 redeemer 為 `DistributeSignerCompensation`(**跨 validator binding**:若無對應 gov 動作,forfeit 不可申領)
- `forfeit_amount > 0`
- Treasury UTxO value 剛好增加 `forfeit_amount` USDCx(來自 gov TX 的轉入)
- 新 continuing datum:
  - `audit_reserve_balance == old.audit_reserve_balance + forfeit_amount`(**整筆 forfeit 進 audit reserve、不按比例拆分**)
  - 其他 balance 欄位不動
  - `operations_balance`、`rd_balance`、`buffer_balance` 不變
- `last_spend_time`、`last_param_update_time`、ratios、caps、不可變欄位全部不動

**Forfeit → audit reserve(而不重新分給合格簽名者)的理由**:
- 避免「希望同事失敗」的反向誘因
- 強化最安全關鍵的預算類別
- 對存入者傳達的訊息一致:不合格簽名者的份額,用來資助保護大家的審計時程

### 3.4 `UpdateParams`——治理閘控的比例 / 上限調整

由 MultisigGov 的 `ExecuteAction` 對應一筆已 queue 的 `UpdateTreasuryParams` 提案觸發。

```aiken
UpdateParams {
  new_audit_bps: Int,
  new_ops_bps: Int,
  new_rd_bps: Int,
  new_buffer_bps: Int,
  new_monthly_cap_audit: Int,
  new_monthly_cap_ops: Int,
  new_monthly_cap_rd: Int,
  new_monthly_cap_buffer: Int,
}
```

**驗證**:
- MultisigGov input 授權(與 Spend 相同)
- **總和 10000 不變量**:`new_audit_bps + new_ops_bps + new_rd_bps + new_buffer_bps == 10_000`
- **各類別邊界**:每個 `bps` 在 `[0, 5000]`(單一類別不得超過 inflow 的 50%)
- **審計進帳下限**:`new_audit_bps >= treasury_audit_floor_bps`(`= 2000`,即 audit reserve 進帳比例不得低於 treasury inflow 的 20%)。此下限與 `min_audit_reserve`(USDCx 絕對餘額下限)互相獨立——進帳比例下限保護未來累積速度、餘額下限保護已累積的審計資金。
- **Monthly cap 邊界**:每個 cap 在 `[0, 100_000_000_000]`(100k USDCx 的理性上限)
- **180 天更新 cooldown**:`tx.validity_range.lower - last_param_update_time >= 15_552_000_000`
- MultisigGov 側的 update timelock:**14 天**(比標準 7 天 timelock 長,反映此變更的系統性)
- 所有類別**餘額**欄位不動(UpdateParams 只改未來的 split、不動既有餘額)
- `last_param_update_time` 更新
- 所有身份欄位不動

---

## 4. 動用 audit reserve

Audit-reserve 類別比其他三類有**更強的保守**:

1. **不可變下限**(`min_audit_reserve`):部署時設定;**任何 redeemer 都不能改**。保證一份最低審計資金儲備,治理多數票也無法投掉。
2. **發票參照要求**:任何 `category = AuditReserve` 的 Spend 動作,必須帶非空的 `audit_invoice_ref` 參數。強制為 honor-system,發生在治理提案階段(鏈下簽名者在共簽前檢查發票是否真實),但該參照會記在鏈上的 `recent_spend_log`,供公開審視。
3. **更長的 timelock 路徑選項**(未來、非 V1):V1.x 或 V2 升級可能加上強制的 attestation-token 機制——audit-reserve 支出需審計事務所簽署的「審計完成」attestation;V1 靠 honor + 透明度。

這三層合起來是合約對存入者的承諾:**audit-reserve 資金會穩定累積、不會被挪去 operations 或 R&D**。

---

## 5. 啟動參數

V1 mainnet 部署時,TreasuryDatum 初始化為:

| 欄位 | 啟動值 | 理由 |
|------|------|------|
| `audit_bps` | 4000 | 40% 的 inflow 進 audit reserve,逐步累積達到下一次第三方審計約 USD 50K-150K 目標(V1 啟動 fee split 下總 fee 的 24%——與舊 80%×30% 同樣的累積速度) |
| `ops_bps` | 2500 | 25% 給平台層基礎設施:自架基礎設施(雙實例 keeper)、Blockfrost 付費版、監控 stack、網域/CDN、frontend 代管。從 40% 下調,因新的 40% keeper 直接份額已透過 Compound output 吸收 per-keeper infra 成本 |
| `rd_bps` | 2500 | 25% 給協議開發、未來的 bounty 計畫(post-audit + TVL-scale,依 `docs/audit-scope.md §6.3`)、貢獻者生態補助 |
| `buffer_bps` | 1000 | 10% 給預期外支出、法律諮詢、事件應變 |
| `monthly_cap_audit` | 500_000_000(500 USDCx) | 防單月支出榨乾 audit reserve |
| `monthly_cap_ops` | 500_000_000 | 啟動時各類別 cap 大小一致,單純 |
| `monthly_cap_rd` | 500_000_000 | 同 |
| `monthly_cap_buffer` | 500_000_000 | 同 |
| `min_audit_reserve` | 0 | 啟動時 treasury 為空;audit_reserve_balance 自然長到 0 以上前,下限為非拘束。可透過未來 UpdateParams 提高(但一旦提高就不能再降)。 |

**比例與上限可透過 `UpdateParams` 做治理調整**,受 180 天 cooldown 與各類別邊界約束。

---

## 6. 會計數學(誠實揭露)

在 pre-audit 100K USDCx TVL 上限,假設 6% gross APY:

- 每年績效費收入:`100K × 6% × 4.5% = 270 USDCx`
- Treasury 年 inflow(V1 啟動 60% 份額):`162 USDCx`
- 啟動比例下的類別年 inflow(40/25/25/10):
  - Audit reserve:`162 × 40% = 65 USDCx`
  - Operations:`162 × 25% = 41 USDCx`
  - R&D:`162 × 25% = 41 USDCx`
  - Buffer:`162 × 10% = 16 USDCx`

這些數字在 pre-audit 上限下**不足**以完全覆蓋 OptiVaults 的運營成本——光是代管基礎設施每年就要 600–1,200 USDCx。V1 進入**啟動期**——協議收入不完全覆蓋運營成本,直到 TVL 到達自給規模(基線運營約 500K–2.5M USDCx)。初期缺口由專案啟動資金承擔,預期隨 TVL 成長自然解決。V1 的 treasury 透明度,是**把這個缺口呈現為可見、可審視的狀態**,不是宣稱 pre-audit 運營已經自給自足。

在約 USD 1M TVL 下,同樣的數學:

- 年 inflow(60% treasury 份額):`1,620 USDCx`
- Audit reserve:`648/年`(總 fee 的 24% = 與舊配置同樣累積速度)→ 這個 TVL 下,累到 50K 約 77 年;USD 10M TVL 下約 8 年
- Operations:`405/年`——低端代管主機 + Blockfrost(per-keeper infra 現在透過 40% keeper 直接份額補,不再從這個 bucket)
- R&D:`405/年`——適度的 grant / bounty 預算,每年 1-2 個小 bounty
- Buffer:`162/年`

在 USD 10M TVL:

- 年 inflow:`16,200 USDCx`
- Treasury **進入自給狀態**,並開始在基線運營成本之上產生盈餘。Audit reserve $6,480/年 累 $50K cushion 約 8 年;tier (c) 完整 audit cycle 自給需 TVL $25M+。

各類別何時達成目標用途的 TVL 規模,皆透明追蹤;V1 白皮書 §9.2 與 `docs/economics.md` 討論從補貼支撐啟動到 treasury 自給的路徑。

---

## 7. 給存入者的保證

讀完本 spec,存入者可以依賴以下**合約強制**性質:

1. **Inflow 比例在 receive 時固定**:當 Compound 把 V1 啟動的 60% 份額(或 Phase 2+ 啟用治理池後的 55%/50%)付進 treasury 時,跨四個類別的拆分**完全**依當下 TreasuryDatum 的比例。Keeper 或治理都**不能**把某筆 Compound 的 inflow 改導別的類別。
2. **Spend 需要治理**:除了透過 `Spend` redeemer + MultisigGov ExecuteAction + 7 天 timelock + 1-of-n cancel 否決,否則**任何類別餘額都不會下降**。
3. **Audit reserve 下限不可變**:`min_audit_reserve` 任何治理動作都不能降。
4. **月度上限限制單次抽光**:即使治理被入侵、queue 出惡意 `Spend`,每類別月上限界定了單筆 TX 的傷害。
5. **比例調整 cooldown**:治理不能快速來回調比例;`UpdateParams` 有 180 天 cooldown + 14 天 timelock。
6. **公開審計軌跡**:每筆 Spend 都記在 `recent_spend_log`(鏈上保最後 50 筆)中,含 TX hash、類別、金額、收件人。完整歷史可以從 Cardanoscan 對 treasury script 地址的查詢重建。
