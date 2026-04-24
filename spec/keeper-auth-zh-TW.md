# OptiVaults V1 — Keeper 授權規格

**範圍**:授權所有 V1 vault 合約中 keeper 執行 redeemer 的 `keeper_stake_script` staking validator。

---

## 1. 目的

OptiVaults V1 需要一種**能隨時間演進**的 keeper 動作授權方式——從「只有協議 operator 白名單的特定錢包」開始,可能演化到「任何人繳保證金」——**而不改動 vault 合約**。`keeper_stake_script` 提供這層:把授權規則編在一個 Cardano staking validator 中,vault 合約透過 zero-withdraw 檢查查詢。

Vault 合約(`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`)**不直接**編碼 keeper 身份。這些合約中每個 keeper redeemer 只做一個檢查:

```aiken
expect list.any(tx.withdrawals, fn((cred, _amt)) ->
  cred == Inline(Script(keeper_stake_script_hash))
)
```

這個檢查說:「本 TX 有一筆 zero-withdrawal,其 stake credential 解析到 keeper_stake_script hash」。這筆 credential withdrawal 會觸發 staking validator 的 redeemer,再由其強制當下有效的授權政策。政策在治理控制下演進時,**vault 合約保持不變**。

---

## 2. KeeperAuthDatum

```aiken
type RegistrationMode {
  GovernanceOnly           // 只有 authorized_pkhs 中的 PKH 能當 keeper
  Mixed                    // authorized_pkhs 或 bond 持有者
  PermissionlessWithBond   // 只要有 active bond 者
}

type KeeperBond {
  bond_owner: VerificationKeyHash,
  bond_amount: Int,            // 鎖定的 lovelace;治理證實不當行為時可 slash
  posted_at: Int,              // POSIX ms
  withdrawal_requested_at: Option<Int>,  // bond-owner 發起 withdraw 時設;30 天 cooldown 後才退款
}

type KeeperAuthDatum {
  registration_mode: RegistrationMode,
  authorized_pkhs: List<VerificationKeyHash>,   // 治理管理的 keeper list(有序;rotation 依據)
  active_bonds: List<KeeperBond>,                // Permissionless 註冊的 keeper(帶 bond)
  bond_amount_required: Int,                     // 最低 bond(lovelace,例如 100_000_000 = 100 ADA)
  last_config_update_time: Int,                  // 治理 UpdateKeeperAuth cooldown
  cooldown_ms: Int,                              // 同 PKH 兩次 withdrawal 間的最小 ms(防 spam)
  max_authorized_count: Int,                     // authorized_pkhs 長度上限

  // --- 每週輪替欄位(Phase 2+ 多 keeper 協調) ---
  rotation_epoch_start_ms: Int,                  // 輪替算術的 POSIX ms 錨點
  rotation_period_ms: Int,                       // 604_800_000 = 7 天
  failover_window_ms: Int,                       // 1_800_000 = 30 分鐘
  last_successful_tx_at: Int,                    // 每筆 WithdrawAsAuthorized TX 更新
  nonce: Int,                                    // 嚴格單調的 anti-replay counter

  // --- 編譯時治理錨點 ---
  governance_policy: ByteArray,                  // GovNFT policy(治理動作的不可變錨點)
  governance_name: ByteArray,
}
```

**欄位可變性分類**:

- **部署後不可變**:`governance_policy`、`governance_name`
- **可透過 UpdateKeeperAuth 治理動作變更(14 天 timelock)**:`registration_mode`、`authorized_pkhs`、`bond_amount_required`、`cooldown_ms`、`max_authorized_count`、`rotation_period_ms`、`failover_window_ms`、`last_config_update_time`
- **在授權清單變動時重錨定**:`rotation_epoch_start_ms`(當 `authorized_pkhs` 或 `active_bonds` 變動時,設為 `tx.validity_range.lower`)
- **透過 bond-posting / bond-withdrawal redeemer 變更**:`active_bonds`
- **每筆 keeper TX 都變**:`last_successful_tx_at`、`nonce`

---

## 3. Redeemer

### 3.1 `WithdrawAsAuthorized`——keeper 執行 vault 操作

當 keeper 想執行一個 keeper 授權的 vault redeemer 時觸發。Vault redeemer 會失敗,除非 TX 包含對 `keeper_stake_script` 的 zero-withdrawal;這個 redeemer 授權該筆 withdrawal。

**Keeper 授權的 redeemer 集合(都走這個閘門)。** 每個 validator 的 redeemer 所在:
- `vault_keeper_hot.Compound`——productive + zero-yield heartbeat
- `vault_keeper_hot.RebalanceBuffer`——allocation-only idle-buffer rebalance
- `vault_batcher.BatchProcess`——填 queued deposit / withdraw order
- `vault_swap_ada.SwapAda`——透過 keeper↔vault oracle 等值交換的閉環 vault-ADA 補充(見 `spec/ada-swap.md`)
- `vault_protocol.DeployToProtocol`——透過 SwapAdapter 分派送 DEX swap(bounded ADA 支出)
- `vault_recall.RecallFromProtocol`——cancel / 收回待處理 DEX order
- `vault_recall.MergeUtxo`——整合 vault + NoDatum UTxO
- `vault_admin_deploy.AdminDeployNonDeposit`——把滯留非存入 token 換回 USDCx(gov-gated,7d keeper 停擺 + 21d registry 穩定為前置條件,不是例行 keeper redeemer,但當 keeper 活躍時仍走 keeper_stake_script 閘門)
- `vault_liqwid.SupplyToLiqwid`——把 buffer → qToken
- `vault_liqwid.RecallFromLiqwid`——贖回 qToken → buffer

以上每個 vault redeemer 都需要 `tx.extra_signatories` keeper 簽名**且** `keeper_stake_script` zero-withdraw(雙重檢查)。純治理 redeemer(UpdateStrategy、UpdateFee、UpdateFeeSplit、UpdateRegistry、TreasurySpend、UpdateKeeperAuth、RotateSigners、EmergencyWithdraw、UpdateOracleSource)繞過此閘門——改以 `multisig_gov` 的 m-of-n 簽名授權。

Keeper 停擺 7 天後(以 `last_compound_time` 衡量),治理可透過 vault validator 中的 `require_keeper_or_governance_fallback` 模式,介入處理上述 keeper 授權 redeemer;治理用 GovNFT spend 簽 TX,本 `WithdrawAsAuthorized` redeemer 不會被呼叫(vault validator 改走 gov-fallback 分支)。

```aiken
WithdrawAsAuthorized { keeper_pkh: VerificationKeyHash }
```

**V1 採「A-Plain」授權變體——每筆 keeper TX 都必須 spend 那個 keeper_auth UTxO、並產出 continuing output,其 `last_successful_tx_at` 推進到 `tx.validity_range.lower`、`nonce` +1。** 這把每筆 keeper 動作**原子性地**綁到授權狀態,避免 reference-input race。

**驗證**:

- `tx.extra_signatories` 必須含 `keeper_pkh`(keeper 確實簽名)
- `keeper_pkh` 必須在 active keeper 集合(下方授權路徑)
- Zero-withdrawal 限制:本 stake credential 的 `tx.withdrawals` 項必須是 `0` lovelace(避免誤 / 惡意抽 stake-rewards)
- 單一 keeper_auth UTxO 必須同時作為 input 與 continuing output 出現在此 stake-script 的 spend 地址
- Continuing output datum 必須滿足:
  - `new_datum.last_successful_tx_at == tx.validity_range.lower`
  - `new_datum.nonce == old_datum.nonce + 1`
  - 所有其他欄位 bit-identical 於 input
- **Primary / failover 檢查**(§4)必須成立

**依 `registration_mode` 的授權路徑**:

- Mode `GovernanceOnly`:`keeper_pkh ∈ authorized_pkhs`
- Mode `Mixed`:`keeper_pkh ∈ authorized_pkhs` 或 `∃ bond ∈ active_bonds. bond.bond_owner == keeper_pkh && bond.withdrawal_requested_at == None`
- Mode `PermissionlessWithBond`:`∃ bond ∈ active_bonds. bond.bond_owner == keeper_pkh && bond.withdrawal_requested_at == None`

**Primary / failover 閘門**(active keeper 集合 ≥ 2 人時強制):

- 若 `keeper_pkh == current_primary_pkh(auth, tx.validity_range.lower)` → primary 路徑,允許
- 否則(`keeper_pkh` 是合法的非 primary)→ failover 路徑,需 `tx.validity_range.lower - old_datum.last_successful_tx_at >= failover_window_ms`

Active 集合恰好 1 人時(V1 啟動),`current_primary_pkh` 永遠回那位 PKH、failover 閘門不被啟用。單一創辦人 keeper 可以無額外限制地送 TX。

**Anti-spam cooldown**:鏈上的 `last_successful_tx_at` 更新代表 same-PKH 垃圾流量會被 TX 計時自然 capped;明確的 `cooldown_ms` 檢查只在 validator 看到 same-PKH 在窗口內再嘗試時強制——V1 啟動時 `cooldown_ms = 60_000`(1 分鐘),遠在正常 keeper 運作節奏內。

### 3.2 `PostBond`——第三方透過 bond 註冊為 keeper

只在 `Mixed` 與 `PermissionlessWithBond` 模式下可用。

```aiken
PostBond { bond_owner: VerificationKeyHash }
```

**驗證**:
- `registration_mode != GovernanceOnly`
- `tx.extra_signatories` 含 `bond_owner`
- TX 把剛好 `bond_amount_required` lovelace 鎖進專用 bond output(stake-script 自己地址或治理參數化的 bond 保管地址)
- 新 `KeeperAuthDatum.active_bonds` 含條目:
  - `bond_owner == bond_owner`(來自 redeemer)
  - `bond_amount == bond_amount_required`
  - `posted_at == tx.validity_range.upper`
  - `withdrawal_requested_at == None`
- 既有 `active_bonds` 條目保留
- 其他 KeeperAuthDatum 欄位不變
- **不得重複 bond**:此動作前 `bond_owner ∉ (active_bonds.map(bond_owner))`

### 3.3 `RequestBondWithdrawal`——bond-owner 發起解除 bond

```aiken
RequestBondWithdrawal { bond_owner: VerificationKeyHash }
```

**驗證**:
- `tx.extra_signatories` 含 `bond_owner`
- 對應 `active_bonds` 條目的 `withdrawal_requested_at == None`
- 新 datum:對應條目的 `withdrawal_requested_at` 設為 `tx.validity_range.upper`
- 其他欄位不變
- **效果**:bond 作為 keeper 的授權**立即**停止(依 `WithdrawAsAuthorized` 檢查:`withdrawal_requested_at == None`)。接著 30 天 cooldown,才能把 bond 取回。

### 3.4 `WithdrawBond`——cooldown 後退回 bond

```aiken
WithdrawBond { bond_owner: VerificationKeyHash }
```

**驗證**:
- `tx.extra_signatories` 含 `bond_owner`
- 對應 `active_bonds` 條目的 `withdrawal_requested_at == Some(t)`
- `tx.validity_range.lower - t >= 30 * 86_400 * 1000`(30 天 cooldown 已過)
- 退款 output 支付剛好 `bond_amount` lovelace 到 bond_owner 地址
- Continuing `keeper_auth` output 至少保留 `own_input.lovelace - bond_amount` lovelace,並保留支撐其他 bond 的任何剩餘 `active_bonds` lovelace(即,剩餘 `active_bonds.bond_amount` 值的總和由 continuing UTXO 的 lovelace 餘額覆蓋)
- 新 datum:該條目從 `active_bonds` 移除
- 其他欄位不變

**實作備註——bond-backing UTXO 不變量。** `keeper_auth` UTxO 必須帶實體 lovelace ≥ `Σ active_bonds.bond_amount + min_utxo`。當 keeper `PostBond` 時,TX 在 datum 更新的同時把該 bond 的 lovelace 加進 `keeper_auth` UTxO 餘額。`WithdrawBond` 在退款時對應地扣掉該 bond 的 lovelace。管理 `keeper_auth` UTxO 的 operator 必須確保它**不被 split**、**不被除了 `WithdrawBond` / `SlashBond` 以外的路徑抽走 lovelace**,否則 bond-refund 不變量會失敗、某 keeper 的 bond 會無法取回。這在 validator 層由上方 continuing-lovelace 檢查強制;違反的 TX 被拒絕。

### 3.5 `UpdateAuthDatum`——治理調整授權規則

由 MultisigGov 的 `ExecuteAction` 對應一筆已 queue 的 `UpdateKeeperAuth` 提案觸發。

```aiken
UpdateAuthDatum {
  new_datum: KeeperAuthDatum,
}
```

**驗證**:
- TX 含來自 `MultisigGov` validator、帶治理 NFT 的 spent input
- `tx.validity_range.lower - old_datum.last_config_update_time >= 86_400_000`(治理更新間至少 24 小時 cooldown)
- **不可變欄位保留**:`new_datum.governance_policy == old.governance_policy`、`new_datum.governance_name == old.governance_name`
- `len(new_datum.authorized_pkhs) <= new_datum.max_authorized_count`
- `new_datum.max_authorized_count <= 20`(授權 keeper 數硬上限)
- `new_datum.bond_amount_required >= 50_000_000`(最低 50 ADA bond;防 bond 金額被歸零)
- `new_datum.cooldown_ms in [60_000, 86_400_000]`(1 分鐘到 24 小時之間)
- `new_datum.rotation_period_ms in [86_400_000, 2_592_000_000]`(1 天到 30 天之間)
- `new_datum.failover_window_ms in [600_000, 7_200_000]`(10 分鐘到 2 小時之間)
- `new_datum.active_bonds == old_datum.active_bonds`(治理**不能**直接操弄 bond——只能透過 bond redeemer 新增 / 移除)
- `new_datum.last_config_update_time == tx.validity_range.upper`
- `new_datum.nonce == old_datum.nonce + 1`
- **Rotation 重錨定規則**:若 `new_datum.authorized_pkhs != old_datum.authorized_pkhs`,或模式從其他模式切到(或從)`PermissionlessWithBond`(active 集合組成可能顯著改變),則 `new_datum.rotation_epoch_start_ms == tx.validity_range.lower`。否則 `new_datum.rotation_epoch_start_ms == old_datum.rotation_epoch_start_ms`。
- Value 全數保留:stake-script UTxO output 必須帶與 input 相同(或更多)的 ADA
- **不得降級既有 bond**:若模式從 `PermissionlessWithBond` 改到 `GovernanceOnly`,既有 bond 仍保持授權,直到他們自願 `RequestBondWithdrawal`(他們的授權綁在 bond 條目、不是模式)。這防止治理單方「取消所有 bonded keeper 授權」卻不退 bond。

### 3.6 `SlashBond`——治理對違規 keeper 沒收 bond

> **V1 啟動時不可達。** V1 出廠時 `RegistrationMode = GovernanceOnly`;無 bonded keeper,`active_bonds` 為空,任何 `SlashBond` TX 都無法通過驗證。MultisigGov action 目錄(`governance.md §4`)中定義了 `SlashKeeper` action kind 以利向前相容,但若在空 bond 集上嘗試,會在 execute 時被 MultisigGov `ExecuteAction` validator 拒絕。本節規格化 redeemer 的形狀以備 Phase 3+;**不要假設 slashing 在 V1 可用**。

由(Phase 3+)MultisigGov 的 `ExecuteAction` 對應一筆已 queue 的 `SlashKeeper` 提案觸發。預期用於**可證實的違規**(例如 keeper 違反 registry 白名單、把 swap 路由到攻擊者地址——這在 registry 檢查層會被鏈上擋下,但若出現某種被 vault validator 沒直接抓到的 grief 行為,這就是恢復機制)。

```aiken
SlashBond {
  bond_owner: VerificationKeyHash,
  evidence_ref: ByteArray,    // 違規證據的鏈上 TX hash
  slash_amount: Int,          // 通常是完整 bond 金額
}
```

**驗證**:
- MultisigGov 治理 input
- 對應 `active_bonds` 條目存在
- `slash_amount <= bond.bond_amount`
- 被 slash 的 lovelace 流向 treasury UTxO(**不流向**治理簽名者;防止反向誘因)
- 條目從 `active_bonds` 移除(bond 被沒收)
- `evidence_ref` 記錄在 slashing 歷史(KeeperAuthDatum 新欄位,或 treasury 的 spend log)
- SlashKeeper 治理動作套 14 天 timelock(比標準 7 天長,反映此主張的對抗性)
- **被指控方的救濟管道**:14 天 timelock 窗口讓被指控 keeper 能公開回應;治理簽名者若證據不足可以 CancelAction。

V1 啟動時**刻意不提供** slashing——V1 出廠為 `GovernanceOnly` 模式,keeper 是人工管理的,slashing 是 overkill(治理只需從 `authorized_pkhs` 透過 UpdateAuthDatum 移除他們即可)。`SlashBond` redeemer 在這裡規格化,是為了未來存在 bonded permissionless keeper、slashing 成為課責機制的模式。

---

## 4. Primary 輪替機制(多 keeper 協調)

當 active keeper 集合 ≥ 2 人(Phase 2+),V1 採**每週 round-robin 輪替**,把 keeper fee 收入公平分佈到所有授權 keeper。

### 4.1 核心概念

- 所有授權 keeper 輪流當「primary」,每人一整週
- Primary 可以**任何時候**執行任意 vault redeemer(`min_wait = 0`)
- 非 primary keeper 待命;只有在 primary 沉默 `failover_window_ms`(預設 30 分鐘)後才能執行
- 跨 N 個輪替週期,每人約 1/N 的時間是 primary,賺約 1/N 累積的 keeper fee

V1 啟動時 1 位 keeper,「輪替」週期為 1,那位單一 keeper 永遠是 primary——實際上不發生輪替。

### 4.2 輪替公式(純時間推導)

**不需要明確的輪替觸發 TX**——輪替隨 wall-clock 自動前進:

```aiken
fn active_keeper_set(auth: KeeperAuthDatum) -> List<VerificationKeyHash> {
  // GovernanceOnly:authorized_pkhs list
  // Mixed:authorized_pkhs ++ active_bonds(排除 withdrawal_requested_at == Some 者)
  // PermissionlessWithBond:只有 active bonds
  // 順序保留;這就是輪替 cycle
  build_active_set(auth)
}

fn current_primary_pkh(auth: KeeperAuthDatum, now_ms: Int) -> VerificationKeyHash {
  let set = active_keeper_set(auth)
  expect list.length(set) > 0
  let elapsed = now_ms - auth.rotation_epoch_start_ms
  let slot = elapsed / auth.rotation_period_ms
  let index = slot % list.length(set)
  list.at(set, index)
}
```

`now_ms` 取自 `tx.validity_range.lower`。Validity-range 寬度上限(繼承自 vault redeemer 的 time-bounded 窗口)保證 `now_ms` 不能被操弄以把計算出的 primary 移出合法窗口。

### 4.3 Failover 路徑

Primary 離線時,非 primary keeper 可以在 30 分鐘沉默後介入:

- 非 primary 簽名者送 `WithdrawAsAuthorized` redeemer 的 TX
- Validator 從 keeper_auth input datum 讀 `last_successful_tx_at`
- 要求 `tx.validity_range.lower - last_successful_tx_at >= failover_window_ms`(30 分鐘)
- 成功時 `last_successful_tx_at` 更新 → primary 也必須等 30 分鐘才能收回(自然形成 handoff 節奏)

若 primary 在自己那週內回來,可以**立即**恢復 primary 路徑(無等待——primary 簽名者永遠被允許)。只有非 primary 簽名者面對 failover 閘門。

### 4.4 授權集合變動時重錨定

當 `authorized_pkhs` 透過 `UpdateAuthDatum` 改動、或 active bond 的新增 / 撤除實質改動 active keeper 集合時,`rotation_epoch_start_ms` 被重設為當下時間。輪替從新 active 集合的 index 0 重啟。

Trade-off:正在服務的 primary 的那週可能被切短。緩解:
- `UpdateAuthDatum` 有 14 天治理 timelock(即將離任的 primary 能預見變更並規劃交接)
- `PostBond` 會加到集合、但**不在週中重錨定**(輪替從下一個 slot 邊界挑進新 bonded keeper——比治理 add 更不干擾)

### 4.5 費用分配

Keeper fee output 的 100% 進簽名 keeper 的 PKH。**非 primary keeper 沒有保底金**;他們在不是 primary 的週份沒收入(除了在 outage 時偶爾介入的 failover TX fee 以外)。

跨多個輪替週期,每位的收入大約平均到 `1/N × 總 keeper_fee`(N = active 集合大小)。體驗到較多 failover 事件(因同儕 keeper 不可靠)的 keeper 賺得略多;自己不可靠的 keeper 則賺得少。

### 4.6 範例:Phase 2 的 3-keeper 輪替

設定:
- `authorized_pkhs = [founder_pkh, ally_A_pkh, ally_B_pkh]`(3 keeper,治理管理)
- `rotation_period_ms = 604_800_000`(7 天)
- `failover_window_ms = 1_800_000`(30 分鐘)

輪替週期:

| 週 | Primary | Secondary | Tertiary |
|----|---------|-----------|----------|
| 1 | founder | ally_A | ally_B |
| 2 | ally_A | ally_B | founder |
| 3 | ally_B | founder | ally_A |
| 4 | founder | ally_A | ally_B |

每位 keeper 每 3 週中 1 週當 primary,該期間賺約 1/3 的 keeper-fee 總額。

### 4.7 Bond 加權輪替(Phase 3+)

當 `registration_mode` 是 `Mixed` 或 `PermissionlessWithBond` 且至少有一個 bonded keeper 時,`current_primary_pkh` 從純時間 round-robin 切到 **bond 加權時間分配**:keeper 的 primary-time 份額與其 bond 金額成比例。

```aiken
fn current_primary_pkh_weighted(auth: KeeperAuthDatum, now_ms: Int) -> VerificationKeyHash {
  let set = active_keeper_set(auth)             // List<(pkh, bond)>
  let total_bond = sum_bonds(set)
  let cycle_ms = auth.rotation_period_ms * list.length(set)  // 一個完整 cycle
  let elapsed_in_cycle = (now_ms - auth.rotation_epoch_start_ms) % cycle_ms

  // 累積走過 set,挑 bond 加權 slot 包含 elapsed_in_cycle 的 keeper
  find_primary_by_cumulative_bond(set, elapsed_in_cycle, total_bond, cycle_ms)
}
```

**等值 bond fallback**:若所有 active keeper 的 bond 相等(或 `GovernanceOnly` 無 bond),演算法退回等值時間 round-robin——與 §4.2 相同。

**Phase 3 啟用**:當 `registration_mode` 透過 `UpdateAuthDatum` 治理動作設為 `Mixed` 時,這個自動發生。**不需要**治理每季評估 keeper 順序——bond 決定排程。

**Phase 4 啟用**:`PermissionlessWithBond` 模式,開放 bond 發行。任何人都可以 `PostBond` 並以 bond 加權 slot 比例進入輪替。更高 bond 買更多 primary 時間——bond 同時是 liveness 承諾(可 slash)與經濟訊號。

**安全性質**:
- 單一擁有不成比例大 bond 的 keeper**不能**阻止其他人賺——加權輪替仍把 cycle 在所有 bonded keeper 間切分
- `bond_amount_required >= 50_000_000`(50 ADA)最低 bond,防零權重 bonded 條目
- 任一 keeper 的最大 bond 時間份額為 `bond[k] / total_bond` → 只有在所有其他 bond 為零時才會是 100%;否則自然有界

### 4.8 V2 升級觸發條件(未來規模)

上述純鏈上輪替機制在 V1 到 Phase 3/4 都足用。V2 重部署可能在**同時滿足下列條件**時引入額外最佳化:TVL ≥ 50M USDCx **且** active keeper 集合大小 ≥ 10 **且** 連續 3 個月、每月 failover race 事件 ≥ 3。V2 candidate 最佳化包括 reference-input-only primary 驗證(A-Optimized 模式)與爭議解決輪次。這些**不在 V1 範圍**。

---

## 5. V1 啟動設定

V1 mainnet 部署時,KeeperAuthDatum 初始化為:

| 欄位 | 啟動值 | 理由 |
|------|------|------|
| `registration_mode` | `GovernanceOnly` | V1 出廠時 keeper 集合人工管理;permissionless 註冊延到有真實需求再開 |
| `authorized_pkhs` | `[founder_pkh]` | 誠實的初始狀態——啟動時只有創辦人跑 keeper |
| `active_bonds` | `[]` | 啟動時無 bond;permissionless 模式未啟用 |
| `bond_amount_required` | `100_000_000`(100 ADA) | 為未來 permissionless 啟用的合理預設;模式變更前不用 |
| `last_config_update_time` | 啟動時為 `tx.validity_range.upper` | |
| `cooldown_ms` | `60_000`(1 分鐘) | 啟動時寬鬆 anti-spam;必要時可收緊 |
| `max_authorized_count` | `10` | 授權清單硬上限;防治理無限擴張 |
| `rotation_epoch_start_ms` | 啟動時為 `tx.validity_range.upper` | 輪替算術錨點 |
| `rotation_period_ms` | `604_800_000`(7 天) | 一旦 ≥ 2 keeper 啟用,每週輪替 |
| `failover_window_ms` | `1_800_000`(30 分鐘) | Primary 沉默 30 分鐘後,非 primary 可介入 |
| `last_successful_tx_at` | 啟動時為 `tx.validity_range.upper` | 初始化為部署時間 |
| `nonce` | `0` | 嚴格單調的 anti-replay counter |
| `governance_policy` | GovNFT policy | 部署後不可變 |
| `governance_name` | "OptiVaultsGovV1" asset name | 部署後不可變 |

**V1 啟動時 active keeper 集合大小 = 1**(只有創辦人)。輪替與 failover 邏輯實質休眠;`current_primary_pkh` 決定性地回創辦人 PKH(無論時間)。

當第二位 keeper 透過治理加入時(Phase 2,預期 TVL ≥ 500K USDCx 之後),每週輪替自動從**重錨定的 epoch** 啟動。

---

## 6. 模式切換流程(「現在先跑、未來再開放」設計的賦能)

當 TVL 與生態成熟度足以支撐 permissionless keeper 註冊時,切換是**單一鏈上事件、不需重部署 vault**:

1. **產品負責人提案**:治理 queue `UpdateKeeperAuth`,`new_datum.registration_mode = PermissionlessWithBond`(或 `Mixed`)、設想的 `bond_amount_required`
2. **7 天 timelock**——任一 gov 簽名者可以 1-of-n 否決 CancelAction
3. **Execute**——任一簽名者執行;stake-script datum 更新
4. **任何人可以 bond**:第三方透過 `PostBond` 發 bond,成為授權 keeper
5. **Vault 合約不動**——`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid` 仍只檢查「有 zero-withdraw 對 keeper_stake_script 嗎?」,不管 stake script 內部規則如何

這就是 stake-validator 方法**相對於其他方案**(硬編碼 PKH list、License NFT minting policy 等)的**主要架構好處**:授權政策**在單一 validator 自己的 datum 內演進**,對協議其他部分不可見。

---

## 7. 為什麼不用 License NFT minting policy

License NFT 方案(每位授權 keeper 鑄一個 NFT;vault 合約檢查 keeper input 中有 NFT)考慮過但被 V1 否決、採用 stake-validator:

- **輪替彈性**:License NFT mint/burn 每次 add/remove 要一筆 minting policy TX;stake-script datum 更新是單一 UTxO consume + recreate,更乾淨。
- **模式彈性**:stake-validator 可在自己 datum 邏輯內編碼多個模式(governance-only、mixed、permissionless);License NFT 要嘛多個 minting policy,要嘛 per-license runtime 檢查「此 license 有效嗎?」。
- **已在用這個模式**:V1 已經為 `vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid` 使用 staking validator。加上 `keeper_stake_script` 架構上一致,不需要存入者學新原語。
- **Bond 整合**:stake-validator 自然地在自己地址持有 bond UTxO;License NFT 需要獨立 bond 合約。

License NFT 層可以在 V2+ 作為 stake script 之上的補充憑證檢查加入(例如「permissionless 模式下,註冊 ceremony 為 UX 鑄一個 NFT」),不與 V1 架構衝突。

---

## 8. 給存入者的保證

讀完本 spec,存入者可以依賴以下**合約強制**性質:

1. **Keeper 身份在啟動時治理管理**:沒有第三方可以在**未**經治理 `UpdateKeeperAuth` 動作(新增其 PKH)的情況下當 keeper,而該動作需要啟動時的 3-of-3 multisig + 14 天 timelock(依 `governance.md §3` 動作目錄)。
2. **模式轉換需要治理**:不會有單方切到 permissionless 的事情;治理必須 queue + 等 + execute,期間有 1-of-n cancel 否決窗口。
3. **Keeper 無法抽走本金**:`keeper_stake_script` 授權 keeper 的*動作*(Compound、BatchProcess、SupplyToLiqwid 等),但 vault validator 在授權之上仍強制自己的不變量(token 保留、費用上限、不可鑄份額 token 以外的 token 等)。**持有合法 stake-script 授權的 keeper,仍無法 drain vault**。
4. **Keeper 被入侵的影響限縮在運營 DoS**:被入侵的 keeper 錢包可以阻擋自動複利、延遲批次處理,但**不能**把資金路由到攻擊者地址(DeployToProtocol + RecallFromProtocol 都強制 `registry.protocol_hashes` 白名單)。
5. **7 天緊急逃脫仍在**:不論 keeper 狀態如何,`Withdraw` 對使用者永遠開放;`last_compound_time + 7d < now` 觸發免費 direct withdraw。

---

## 9. 相關文件引用

- `spec/architecture.md §3.5` — stake-validator 在協議架構中的角色摘要
- `spec/governance.md` — 完整目錄中的 `UpdateKeeperAuth` / `SlashKeeper` 治理動作
- `docs/security-model.md` — 誠實的 6-身份人類控制者地圖(哪些自然人持有 keeper PKH 對比治理簽名)
- `docs/audit-scope.md` — stake-validator 作為 V1 審計中獨立審計的子系統

---

## 10. Stake credential 生命週期(A2,2026-04-20)

每次 `keeper_stake_script` 的 stake credential 被註冊(V1 每次部署一次,在 ceremony PHASE 4a),Cardano ledger 鎖 2 ADA 押金。將 credential 取消註冊時,2 ADA 退還給取消註冊的 TX 提交者。

`keeper_stake_script` 帶一個 gov-gated `publish` handler(A2),用標準 `is_gov_authorized(ActDeregisterStake)` 檢查、對自己既有的編譯時 `governance_nft_policy` + `governance_nft_name` 參數。流程:

1. 治理 queue `ActDeregisterStake`,`target_script = keeper_stake_script_hash`、`payload_hash = blake2b_256(cbor.serialise(keeper_stake_script_hash))`。
2. 14 天 timelock 過(Preprod 驗證覆寫 1 小時——見 `lib/vault/constants.ak`)。
3. 任一簽名者執行 TX,該 TX:(a) 消費 `multisig_gov` UTxO 以 `ExecuteAction(action_id)`、(b) 為 `keeper_stake_script` 的 stake credential 包含 Cardano `Deregister` 憑證、(c) 產生對應狀態轉移的 continuing `multisig_gov` output。

Cardano ledger 在 Deregister cert 上呼叫 `keeper_stake_script.publish`;我們的 handler 重驗證治理授權並回傳 True。Ledger 接受 cert + 退 2 ADA。

Deregister 後,vault **不可運作**——任何對 `keeper_stake_script` 的 Withdraw-Zero 企圖都會失敗(credential 不再註冊)。Deregister 因此是**生命終點 / 下架**動作,不是例行運營。Post-Phase-77 + 77b/77c/77d,同樣模式套用到 V1 全部 12 個 staking credential(`vault_user` / `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada` / `vault_protocol` / `vault_recall` / `vault_liqwid` / `vault_gov_policy` / `vault_gov_emergency` / `vault_admin_deploy` / `keeper_stake_script` / `minswap_v2_adapter` SwapAdapter)。Pre-Phase-77 的 16 KB 上限曾擋住 `vault_core` 的 `publish` handler,那個限制透過把 vault_core 切成 `vault_user` + `vault_keeper_hot` 解決——見 `spec/governance.md §4.13`。
