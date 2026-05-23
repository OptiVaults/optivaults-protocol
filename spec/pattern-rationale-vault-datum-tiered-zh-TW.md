# Pattern Rationale — VaultDatum Tiered Immutability

**狀態**：資訊性質的模式背景說明。不是 CIP、也不是 CIP 草案。OptiVaults V1 對 Cardano Improvement Proposals 的整體立場見 `docs/cip-readiness-posture-zh-TW.md`。

**範圍**：一個反覆出現的模式 — 把 singleton 狀態 UTXO 的 inline datum 切成幾個 tier（identity 不可變、governance 可變、accounting、operational），並用 helper 函數在每一條 redeemer 上強制執行該 redeemer 對應的 tier 變更包絡。模式本身是通用的；OptiVaults V1 把它具現為一份 29 個欄位的 VaultDatum（案例研究見 §6）。

---

## 1. 問題

有點規模的協議在它的生命週期裡，singleton 狀態 UTXO 的欄位會不斷累積。一個 vault 的 datum 從 5 個欄位起步，一次 fee-policy 重構加 3 個、為了 mainnet 整合的 accounting 準確度加 4 個、一次 governance 重構再加 3 個、一個 oracle 整合再加 2 個 — 還沒進到第一次外部審計之前就會到 20 個欄位以上。

一份平坦的 20 欄位 datum 暴露三種失敗模式：

1. **身份漂移。** 一條本來只想更新 fee schedule 的 redeemer 不小心改寫了 deposit token policy。錯誤在那條 redeemer 自己的邏輯裡看不出來（這條 redeemer 滿腦子都在想 fee），但會產生一個無法回復的狀態：vault 認知的 deposit token 跟使用者持有的不一樣。Cardano DeFi 早年的事故有過這種形狀。
2. **授權混淆。** keeper 可呼叫的 redeemer（Compound、BatchProcess）不小心讓 keeper 能改一個本來只能由 governance multisig 改的欄位。沒有把「在這裡哪些欄位不可變」明列出來的話，這個 bug 直到被利用之前都看不到。
3. **審計爆炸。** 每條 redeemer 都要各自列舉「我被允許改哪些欄位？」「我必須保留哪些欄位？」 — N 條 redeemer × M 個欄位 = O(N×M) 的審計面。在「間接被牽動」的欄位上出錯非常常見。

Tiered Immutability 模式是一個結構層的回應。每個欄位在靜態上被指派一個 tier；每條 redeemer 宣告自己的 tier 範圍；helper 函數把每個 tier 的變更包絡壓成一行。審計面從 O(N×M) 縮到 O(N + tier_count) — 每條 redeemer 的 tier 範圍是一小段斷言、每個 tier 的內容檢查一次。

---

## 2. 模式本身

四個 tier，每個 tier 有自己一套變更紀律：

### 2.1 Tier 1 — Identity（不可變）

部署時就被烘進來、在 singleton 一輩子裡**永遠不變**的欄位。典型內容：

- 協議版本標記
- 編譯期錨點的相互參考（governance NFT policy、registry hash、auth NFT policy）
- Token policy + token name 參數（deposit token、share token）
- 協議路由經過的外部 script hash（order script、registry script）

這些欄位之所以放在 datum 裡（而不是放在每個 validator 的編譯期參數），是因為它們會被需要在 runtime 用到它們的 validator 讀到 — 例如 withdraw validator 要用 deposit-token policy 來驗證使用者收到的是不是對的資產。把它們放 datum 每條 redeemer 多付一次讀的代價；放編譯期參數則會讓每個 validator 的 parameter signature 都爆炸。

一個 helper 在每條 non-deploy redeemer 上強制執行 tier 1 的不可變性：

```aiken
pub fn check_immutable_fields(old: VaultDatum, new: VaultDatum) -> Bool {
  and {
    new.vault_version == old.vault_version,
    new.governance_policy == old.governance_policy,
    // ... one line per Tier 1 field
  }
}
```

除了部署時的 initialiser 之外，每條 redeemer 都呼叫這個 helper。審計只審 helper 本身一次以確認完整性；每條 redeemer 只審「有沒有呼叫到 helper」。

### 2.2 Tier 2 — Governance-mutable Policy

由 governance 偶爾授權改一次、改完之後在下一次 governance action 之前保持穩定的欄位（通常依循 MultiSig + Timelock 模式 — 見 Pattern 2）。典型內容：

- 費用參數（performance fee、early-withdraw fee、fee split）
- 策略配置目標
- Buffer 目標、slippage 上限、oracle 參數
- 操作上限（min hold time、max allocation count）

每個 policy 欄位都有自己對應的 update redeemer（UpdateFee、UpdateStrategy、UpdateSlippagePolicy、…）。在那些 redeemer 之外，policy 欄位是不可變的。

第二個 helper 在非 policy-changing redeemer 上執行：

```aiken
pub fn check_policy_fields_unchanged(old: VaultDatum, new: VaultDatum) -> Bool {
  and {
    new.performance_fee_bps == old.performance_fee_bps,
    // ... one line per Tier 2 field
  }
}
```

審計只審 helper、再審每條非 policy redeemer 有沒有叫 helper。

### 2.3 Tier 3 — Accounting

協議的工作狀態，在大多數操作上都會變動的欄位：

- 總存款、總 shares
- Idle buffer、non-deposit value
- 最後 compound 時間、最後 update 時間、最後 action 時間戳
- 策略配置（active 百分比）
- 外部協議部位（Liqwid qToken 持倉、Minswap LP 部位）

這裡沒有單一一個「tier 3 immutability」helper。取而代之的是每條會改 accounting 的 redeemer 各自攜帶**redeemer 特定的數學不變式**，驗證 delta 是對的（share 數學、fee 數學、buffer 約束、配置守恆）。tier 本身不去執行逐欄位的相等性檢查；它執行的是「在這個操作下、每個欄位都對」。

模式在這裡的貢獻是*組織層次*的：把哪些欄位是「工作狀態」明確地圈出來，這樣每條 redeemer 的數學不變式才知道自己擁有什麼。Identity / policy 欄位永遠不會出現在任何一條 redeemer 的數學不變式裡。

### 2.4 Tier 4 — Operational

一小組單向或需要特殊處理的旗標：

- 緊急 freeze（`frozen: Int`，0 → 1 單向，除非 governance 反向解凍）
- Community sunset trigger（`community_sunset_triggered: Int`，0 → 1 單向、不可逆）
- 其他 circuit-breaker / dead-man-switch 標記

Tier 4 欄位帶有單調性規則：大多數只能朝單一方向轉移。會設定某個 tier 4 旗標的 validator 在設定之前會先檢查舊 datum 的旗標值，且大多數 redeemer 會保留旗標（不能清掉它）。審計端的紀律是：每條 redeemer 都必須明確思考它對每個 tier 4 旗標是要保留還是要轉移。

---

## 3. Aiken 示意

最簡單的實作方式是用程式碼註解把 datum 依 tier 組織：

```aiken
pub type VaultDatum {
  // — Accounting (Tier 3) —
  total_deposited: Int,
  total_shares: Int,
  idle_buffer: Int,
  last_compound_time: Int,
  strategy_allocations: List<Allocation>,
  // ... other tier 3 fields

  // — Policy (Tier 2) —
  performance_fee_bps: Int,
  early_withdraw_fee_bps: Int,
  // ... other tier 2 fields

  // — Identity (Tier 1, immutable) —
  vault_version: Int,
  governance_policy: ByteArray,
  governance_name: ByteArray,
  deposit_token_policy: ByteArray,
  // ... other tier 1 fields

  // — Operational (Tier 4) —
  frozen: Int,
  community_sunset_triggered: Int,
}
```

一條使用者端 redeemer（Deposit）示範典型的變更包絡：

```aiken
fn validate_deposit(old: VaultDatum, new: VaultDatum, ...) -> Bool {
  and {
    // Tier 1 — identity preserved
    check_immutable_fields(old, new),
    // Tier 2 — policy preserved (Deposit doesn't change policy)
    check_policy_fields_unchanged(old, new),
    // Tier 3 — accounting math
    new.total_deposited == old.total_deposited + deposit_amount,
    new.total_shares == old.total_shares + minted_shares,
    new.idle_buffer == old.idle_buffer + deposit_amount,
    // ... other tier 3 deltas
    // Tier 4 — operational preserved
    new.frozen == old.frozen,
    new.community_sunset_triggered == old.community_sunset_triggered,
    old.frozen == 0,  // Reject if vault is frozen
  }
}
```

一條 governance-policy redeemer（UpdateFee）有不同的形狀 — tier 2 部分變動、tier 1 + tier 3 + tier 4 保持不變：

```aiken
fn validate_update_fee(old: VaultDatum, new: VaultDatum, ...) -> Bool {
  and {
    // Tier 1 — identity preserved
    check_immutable_fields(old, new),
    // Tier 2 — only the fee fields change; others within tier 2 preserved
    new.performance_fee_bps == new_performance_fee_bps,  // from redeemer
    new.early_withdraw_fee_bps == new_early_withdraw_fee_bps,
    new.min_hold_seconds == new_min_hold_seconds,
    new.buffer_target_bps == old.buffer_target_bps,      // not this redeemer's job
    new.keeper_fee_bps == old.keeper_fee_bps,            // not this redeemer's job
    // ... rest of tier 2 unchanged
    // Tier 3 — accounting fully preserved
    new.total_deposited == old.total_deposited,
    // ... all tier 3 fields equal old
    // Tier 4 — operational preserved
    new.frozen == old.frozen,
    new.community_sunset_triggered == old.community_sunset_triggered,
  }
}
```

redeemer 的「tier 範圍」從結構就看得出來：呼叫了哪些 helper、哪些欄位等於舊值、哪些欄位是從 redeemer 參數推出來的、哪些欄位帶有數學不變式。

---

## 4. 安全性質

### 4.1 在每一條 non-deploy redeemer 上保持身份不變

`check_immutable_fields` 會被每一條會產出 continuing vault output 的 redeemer 呼叫。沒呼叫 helper 是一眼就會被 code review 抓出來的紅旗。Identity 欄位因此不可能在任何單筆 TX redeemer 執行裡漂移。

審計不變式：grep 每個 `Deposit` / `Withdraw` / `Compound` / `BatchProcess` / … handler，逐一確認都呼叫了 `check_immutable_fields(old, new)`。V1 的審計歷史（Coverage area C — V1 Integration Flows；見 `docs/audit-scope.md`）在每一條 redeemer 上驗證了這個不變式。

### 4.2 Policy 變更必須走專屬 redeemer

Tier 2 欄位只透過 UpdateFee / UpdateStrategy / UpdateSlippagePolicy / UpdateFeeSplit redeemer 變動，每一條都被 MultiSig + Timelock 模式（Pattern 2）守。其他非 policy redeemer 全部呼叫 `check_policy_fields_unchanged`，所以 keeper 可呼叫的 Compound 不可能不小心動到 fee schedule。

### 4.3 每條 redeemer 的數學不變式擁有自己的 tier

Tier 3 accounting 欄位每個操作都會動，但每條 redeemer 的數學不變式只跟自己有關。Compound 的不變式講的是收益 + fee 配置 + share-price 保留；Deposit 的不變式講的是 share-mint 的正確性；Withdraw 的不變式講的是 share-burn + receiver 撥付。tier 組織讓這些不變式不會洩漏到彼此。

這個機制能擋的舊式 bug 樣態：一個 Deposit handler 正確地增加了 `total_deposited`，但不小心也改寫了 `last_compound_time` — 把 keeper 的 compound 時程搞亂。有 tier 紀律的話，`last_compound_time` 是 tier 3 但 Deposit 的數學不變式不會碰它（只有 Compound 會碰），所以審計會抓到這種錯放。

### 4.4 Operational 旗標帶方向性

Tier 4 旗標是單向（或除非有一條專屬解凍路徑、否則單向）。每條 redeemer 都必須明確選擇是保留還是轉移每個旗標。審計不變式：每條 redeemer 的 handler grep 應該對每個 tier 4 旗標剛好命中一次。

一個具體的防線：`community_sunset_triggered` 是被一條「90 天 keeper inactivity」redeemer 設下來的 dead-man-switch 旗標；一旦設下，幾條 recall 路徑就開放給任何人呼叫。如果這個旗標不被當作 tier 4 保護，惡意 redeemer 就能在 recall 被觸發之後又把它清掉、把協議在復原中途又鎖回去。

### 4.5 每條 redeemer 的包絡都可被審計

每條 redeemer 的變更包絡從它的結構就看得出來：

| Redeemer | Tier 1 | Tier 2 | Tier 3 | Tier 4 |
|---|---|---|---|---|
| Deposit | 保留（helper） | 保留（helper） | 變動：total_deposited、total_shares、idle_buffer | 保留 + `frozen == 0` 前提 |
| Withdraw | 保留 | 保留 | 變動：total_deposited、total_shares、idle_buffer | 保留（即使 frozen 也可走） |
| Compound | 保留 | 保留 | 變動：total_deposited、last_compound_time、strategy_allocations | 保留 |
| UpdateFee | 保留 | 變動：performance_fee_bps、early_withdraw_fee_bps、min_hold_seconds | 保留（每個 Tier 3 = old） | 保留 |
| RotateSigners | 保留 | 保留 | 保留 | 保留（governance UTXO 是另一顆；vault datum 不動） |
| CommunitySunset | 保留 | 保留 | 保留（大多數欄位） | 轉移：`frozen 0→1` + `community_sunset_triggered 0→1` |

這張矩陣就是審計的主要檢視對象。每一列是一條 redeemer 的範圍；每個 cell 是一次 helper 呼叫、或是一小組明確的相等 / 不等性檢查。bug 的可能面就是「某個 cell 與該 redeemer 文件化的範圍不一致」。

---

## 5. 與替代方案的取捨

| 做法 | 每條 redeemer 的審計面 | 變更包絡的可見度 | 加一個欄位的成本 | Helper 開銷 |
|---|---|---|---|---|
| 平坦 datum、每條 redeemer 各自列舉 | 每條 O(M) 行 | 低（必須逐條讀 redeemer source） | 觸碰每一條 redeemer | 無 |
| Tier helper + 每條 redeemer 呼叫（本模式） | O(tier_count) 行 | 高（矩陣式組織） | 只觸碰 helper | 每條 redeemer 每個 tier 一次函數呼叫 |
| 每個 tier 一顆獨立 UTXO | 每顆 UTXO 各自邏輯 | 高 | 只觸碰該 tier 的 validator | 每筆 TX 要花掉多顆 UTXO |
| Datum versioning（struct 棄用 + migration redeemer） | 高（每個版本都要處理） | 混合 | 加一步 migration | migration redeemer 必須保留不變式 |

Tiered immutability 做的取捨是：每條 redeemer 多花幾個 Plutus eval cycle 在 `check_immutable_fields` + `check_policy_fields_unchanged` 上，換來「審計面在每條新 redeemer 被加進來時收斂」這件事。對一份在協議生命週期裡從 10 個欄位長到 30 個欄位的 datum 來說，這個取捨明顯划算。

本模式與 datum versioning **互補**、不衝突。當 datum schema 需要加一個新的 tier 1 欄位時，tier 組織讓 migration redeemer 的範圍變得很明顯 — 只有那個新欄位會出現在 migration 的變更包絡裡。

---

## 6. OptiVaults V1 案例研究

V1 的 VaultDatum 在 `contracts/lib/vault/types.ak`，總共 29 個欄位、組織在 4 個 tier 之間：

- **Tier 1 — Identity（9 個不可變欄位）**：`vault_version`、`governance_policy`、`governance_name`、`deposit_token_policy`、`deposit_token_name`、`vusdcx_policy`、`order_script_hash`、`registry_hash`、`registry_auth_policy`。Helper：`contracts/lib/vault/validation.ak` 裡的 `check_immutable_fields`。
- **Tier 2 — Policy（8 個 governance-mutable 欄位）**：`performance_fee_bps`、`early_withdraw_fee_bps`、`min_hold_seconds`、`buffer_target_bps`、`keeper_fee_bps`、`gov_fee_bps`、`max_slippage_bps`、`min_swap_peg_bps`。Helper：`check_policy_fields_unchanged`。專屬 redeemer：`UpdateFee`、`UpdateFeeSplit`、`UpdateStrategy`、`UpdateSlippagePolicy`（每條都由 MultiSig + Timelock 守 — 見 Pattern 2）。
- **Tier 3 — Accounting（10 個工作狀態欄位）**：`total_deposited`、`total_shares`、`idle_buffer`、`non_deposit_value`、`last_compound_time`、`last_realloc_time`、`last_fee_update_time`、`last_ada_swap_time`、`strategy_allocations`、`liqwid_positions`。每條會碰 accounting 的 redeemer 各自攜帶 redeemer 特定的數學不變式（share 數學、fee 數學、buffer 約束、配置守恆、oracle 界限）。
- **Tier 4 — Operational（2 個單向旗標）**：`frozen`（freeze 時 0→1；只能透過專屬 governance redeemer 反向）、`community_sunset_triggered`（在 90 天 keeper inactivity 時 0→1；單向、不可逆）。

呼叫 helper 的紀律在整套 validator 上都被執行：

- `check_immutable_fields` 從**九**個 call site 被呼叫 — `validation.ak` 裡 7 個、`helpers.ak` 裡 2 個。審計不變式驗證每條會產出 continuing vault output 的 redeemer 都會走到其中一個 call site，而且沒有任何 continuing-output redeemer 跳過 helper。
- `check_policy_fields_unchanged` 被每一條非 policy-changing redeemer 呼叫。四條會改 policy 的 redeemer（UpdateFee、UpdateFeeSplit、UpdateStrategy、UpdateSlippagePolicy）會明確列舉它擁有哪些 tier 2 欄位。

Tier 1 有 9 個欄位，並在 `docs/audit-scope.md` 的 coverage matrix 中被認可。Tier 4 的 `community_sunset_triggered` 旗標的單向性質在 `contracts/lib/vault/tests/` 有回歸測試（見對應 test 檔對所有非 CommunitySunset redeemer 的 preservation 檢查）。

每條 redeemer 包絡可見度的具體例子：V1 的 `Compound` redeemer 在 `vault_keeper_hot.ak` 裡帶有以下結構：

```
- check_immutable_fields(old, new)           // Tier 1
- check_policy_fields_unchanged(old, new)    // Tier 2
- Math invariants on total_deposited, last_compound_time, strategy_allocations  // Tier 3
- new.frozen == old.frozen                   // Tier 4
- new.community_sunset_triggered == old.community_sunset_triggered  // Tier 4
- old.frozen == 0                            // Tier 4 precondition: do not Compound when frozen
```

六行（或六個小區塊）構成整個變更包絡。詳細的數學在第三條 bullet 裡；tier 紀律在前後五條裡。

---

## 7. 給未來 CIP 工作的待答問題

如果這個模式日後真的被提出來標準化，討論時需要解決：

1. **Tier 在鏈上的識別。** 目前這個模式是 code-organisation 上的慣例。CIP 可以規定一個 datum 層級的 tier 標記（一個放在前面的 enum 欄位、或一個 struct-nested tier marker），或是繼續留給專案慣例。取捨是「decoder 的明確性」與「schema 膨脹」。
2. **Helper 標準化。** `check_immutable_fields` + `check_policy_fields_unchanged` 目前是專案各自寫的。CIP 可以提供一份參考 Aiken library，包含可以從 datum 的 tier 標記衍生出 tier 檢查的 macro / generic helper。
3. **每個 tier 對應的 update redeemer template。** CIP 可以規定更新 tier 2 欄位的 redeemer 的標準形狀 — input 集合、output 集合、預期順序的 helper 呼叫。某些舊式協議有各自獨特的形狀，這會讓跨協議審查變得複雜。
4. **與 versioning 的互動。** 跨協議升級的 datum-schema versioning（例如新增一個 tier 1 欄位）目前是每個協議各自處理。CIP 可以提供一份 migration-redeemer template。
5. **命名。** 「Tiered Immutability」、「Datum Field Tiers」、「Per-Field Mutation Discipline」在非正式的 Cardano DeFi 討論裡都出現過。CIP 會把其中之一定為標準名。

---

## 8. 另見

- `contracts/lib/vault/types.ak` — V1 的 `VaultDatum` 定義（含 tier 註解）
- `contracts/lib/vault/validation.ak` — `check_immutable_fields` + `check_policy_fields_unchanged` helper
- `contracts/lib/vault/helpers.ak` — 其他共用驗證 helper
- `spec/vault-datum.md` — V1 的 vault-datum 規格（逐欄位文件）
- `docs/audit-scope.md` Coverage area C — V1 Integration Flows 的審計覆蓋
- `spec/pattern-rationale-multisig-gov-timelock-zh-TW.md` — Pattern 2；守 Tier 2 變更 redeemer
- `spec/pattern-rationale-validator-identity-nft-zh-TW.md` — Pattern 1；讓 validator 能信任這份 datum 的 Vault NFT 錨點
- `spec/pattern-rationale-withdraw-zero-forwarding-zh-TW.md` — Pattern 3；讓多個 validator 共用一份 VaultDatum 的架構基底
- `docs/cip-readiness-posture-zh-TW.md` — 整體 CIP 立場

---

**文件狀態**：資訊性質的模式背景說明。反映 V1 在 launch readiness 階段的設計。修訂時機依循 `cip-readiness-posture-zh-TW.md` §4 所述條件。
