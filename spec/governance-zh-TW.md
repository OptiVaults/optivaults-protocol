# governance.md — MultisigGov 動作目錄

V1 治理是帶 timelock 與 cancel 否決的 m-of-n 多簽。本文件列出每個受治理閘控的動作、其 timelock、cancel 窗口、以及鏈上授權流程。

---

## 1. MultisigGov 概述

`multisig_gov` validator 持有一個 UTxO,帶 one-shot **治理 NFT**(部署時鑄、policy + name 在部署時燒進每個接受治理授權的 validator)。該 UTxO 的 datum:

```aiken
type GovDatum {
  signers: List<VerificationKeyHash>,        // 目前 m-of-n 簽名者集合
  signer_joined_at_ms: List<Int>,             // 平行 list:每位 tenure 起始時間
  signer_last_qualified_ms: List<Int>,        // 平行 list:上次做合格動作(治理 TX 或 heartbeat)的時間
  threshold: Int,                              // m
  queued: List<QueuedAction>,                 // 待處理的 timelocked 動作
  signer_compensation_pool: Int,              // 累積的治理費用池(lovelace,以 USDCx 單位計)
  last_distribute_ms: Int,                    // 上次 DistributeSignerCompensation 執行
  distribute_period_ms: Int,                  // 90 天(季度)
  nonce: Int,                                  // 單調,每次狀態變化 +1
}

type QueuedAction {
  action_id: ByteArray,       // 動作內容的 32-byte hash
  target_script: ByteArray,   // 動作最終會 spend 的 validator hash
  target_tx_hash: ByteArray,  // 選用預先承諾的 TX hash(空 = 「未知」)
  action_kind: ActionKind,
  queued_at_ms: Int,
  executable_at_ms: Int,      // queued_at + timelock
  expires_at_ms: Int,         // executable_at + TTL
  payload_hash: ByteArray,    // redeemer payload 的 hash(執行時驗證)
}
```

任何改變狀態的治理 redeemer 都需要 **≥ threshold 位 `signers` 的簽名**。

---

## 2. Redeemer 目錄

### 2.1 QueueAction

把新條目 push 進 `queued`。由 ≥ threshold 位簽名者簽署。**當下無法執行**——只是排進佇列。

```aiken
QueueAction {
  action: ActionKind,
  target_script: ByteArray,
  target_tx_hash: ByteArray,
  payload_hash: ByteArray,
  timelock_ms: Int,            // 必須 >= 該 action kind 的最小 timelock
  ttl_ms: Int,                 // executable_at 之後的執行窗口
}
```

驗證:
- 有 `threshold` 個簽名
- `timelock_ms` >= 各 action 的下限(§3)
- `ttl_ms` >= 1 天、<= 30 天
- `nonce` 正好 +1
- `queued` 長度 <= 10(DoS 上限)

### 2.2 CancelAction

移除一個 queued 條目。**1-of-n 授權**——任一簽名者都能 cancel,不需要門檻。這是針對「流氓簽名者共謀 queue 惡意動作」的緊急煞車。

驗證:
- 有 1 個簽名(任一 `signers` 成員)
- 目標 `action_id` 存在於 `queued`
- `nonce` 正好 +1

### 2.3 ExecuteAction

消費一個 queued 動作並據此 spend target validator 的 UTxO。由 ≥ threshold 位簽署。必須在 `[executable_at_ms, expires_at_ms]` 窗口內。

驗證:
- 有 `threshold` 個簽名
- 當前 slot 時間在 `[executable_at_ms, expires_at_ms]` 內
- Redeemer payload hash 與 `payload_hash` 相符
- 若 `target_tx_hash != #""`,強制 `tx.id == target_tx_hash`(罕見的 opt-in 模式,用於預先簽署的 recovery 流程)
- Queued 動作被移除;`nonce` +1

### 2.4 RotateSigners

改動 `signers` + `threshold`。與其他治理動作的 timelock 相同(**沒有捷徑**)。

執行時的約束:
- `list.length(new_signers) >= 3`
- `new_threshold >= 2`
- `new_threshold <= list.length(new_signers)`——**明確允許 unanimity(`threshold == n`)**。V1 啟動時採 3-of-3,強制 unanimity(因為創辦人也是 keeper operator)。Post-audit Phase 2+ 的慣例是維持 `threshold < n`,讓非 quorum 的簽名者永遠有真正的 1-of-n cancel 權力——但這是運營政策,**不是** validator 強制。
- 所有 `new_signers` 元素互不相同
- 對每個也出現在 `old_signers` 中的 `new_signers[i]`:保留舊狀態中的 `signer_joined_at_ms[i]` 與 `signer_last_qualified_ms[i]`
- 對每個新加入者:`signer_joined_at_ms[i] = tx.validity_range.lower`,`signer_last_qualified_ms[i] = 0`(必須自己賺到第一次合格)
- `nonce` +1
- **輪替前補償**:若輪替時 `signer_compensation_pool > 0`,慣例是先跑 DistributeSignerCompensation(operator 慣例;**非**合約強制)與離任簽名者結清

### 2.5 Heartbeat

任何當前簽名者都可以送 Heartbeat TX 來佐證 liveness、把自己在本季的合格狀態延長。**1-of-self 授權**。

```aiken
Heartbeat { signer: VerificationKeyHash }
```

驗證:
- `signer ∈ gov_datum.signers`
- `tx.extra_signatories` 含 `signer`
- 速率限制:`tx.validity_range.lower - gov_datum.signer_last_qualified_ms[signer_index] >= 7_776_000_000`(90 天)——每季每位簽名者最多一次 heartbeat
- 新 datum:`signer_last_qualified_ms[signer_index] = tx.validity_range.lower`
- 其他欄位不變,除了 `nonce` +1
- 成本:**不動 treasury**;一筆 Heartbeat TX 約 0.2 ADA 網路費,由簽名者自付

**理由**:Heartbeat 是給安靜季(沒有 QueueAction / ExecuteAction / CancelAction)的廉價 liveness 訊號。沒有 Heartbeat,休眠的簽名者會依 X3 混合規則(§2.6)失去當季補償份額。

### 2.6 DistributeSignerCompensation

把累積的治理費用池分給合格簽名者。**1-of-n 授權**——任一 `signers` 成員都能觸發。

```aiken
DistributeSignerCompensation { triggering_signer: VerificationKeyHash }
```

驗證:
- `triggering_signer ∈ gov_datum.signers`
- `tx.extra_signatories` 含 `triggering_signer`
- `tx.validity_range.lower - gov_datum.last_distribute_ms >= gov_datum.distribute_period_ms`(季度節奏)
- `gov_datum.signer_compensation_pool > 0`(空了就沒東西可分)
- **每位簽名者 `i` 的合格檢查**:
  - `gov_datum.signer_joined_at_ms[i] <= gov_datum.last_distribute_ms`(full-quarter tenure;在該季開始前就加入)
  - `gov_datum.signer_last_qualified_ms[i] >= gov_datum.last_distribute_ms`(該季簽了 ≥ 1 筆合格 TX:Queue/Execute/Cancel/Rotate/Heartbeat)
- 令 `qualified_signers = [signers[i] where qualification holds]`
- 令 `per_signer_amount = gov_datum.signer_compensation_pool / max(len(qualified_signers), 1)`
- TX output:
  - 每位合格簽名者一筆 USDCx output:金額 = `per_signer_amount`、地址 = 簽名者 PKH-payment 地址
  - **Forfeit 流**:`forfeit_amount = gov_datum.signer_compensation_pool - (len(qualified_signers) * per_signer_amount)` + rounding 餘。此 forfeit 透過 `ReceiveGovForfeit` redeemer 送到 Treasury UTxO 的 `audit_reserve_balance`(見 `spec/treasury.md §3.3`)
- Continuing gov output:
  - `signer_compensation_pool = 0`(pool 清空)
  - `last_distribute_ms = tx.validity_range.lower`
  - 其他欄位不變,除了 `nonce` +1

**無合格簽名者邊界**:若 `len(qualified_signers) == 0`,整個 pool 全數 forfeit 進 audit reserve。(健康治理下不應發生;縱深防禦。)

---

## 3. 動作 timelock 下限

每個 `ActionKind` 都有最低 timelock。治理可以 queue **較長的** timelock,但不能更短。

| ActionKind              | 最小 timelock | 預設 TTL | Cancel 窗口 | 備註 |
|-------------------------|--------------|---------|-------------|------|
| `UpdateStrategy`        | 7 天         | 7 天    | 7 天        | Buffer 比、allocation 上限、Liqwid 開關 |
| `UpdateFee`             | 14 天        | 7 天    | 14 天       | 績效費、early-withdraw fee、min_hold |
| `UpdateFeeSplit`        | **21 天**    | 7 天    | **21 天**   | **Keeper + gov fee-bps 拆分(keeper_fee_bps、gov_fee_bps)。最長 timelock,因為治理在調整自己的報酬。** |
| `EmergencyWithdraw`     | 0 天         | 1 天    | 0 天        | 立即,但需要門檻 + 鏈上 insolvency 條件證明 |
| `AdminDeployNonDeposit` | 7 天         | 14 天   | 7 天        | 非存入 token 提取(捐贈、不支援的空投) |
| `UpdateRegistry`        | 14 天        | 7 天    | 14 天       | 增減穩定幣、協議白名單、Liqwid 市場 |
| `KeeperToggleMarket`    | 0(keeper)  | N/A     | N/A         | 1 小時 keeper 單方——**非治理閘控** |
| `FastUpdateMarkets`     | 1 小時       | 1 天    | 1 小時      | 治理快速路徑,處理 Liqwid pool 遷移 |
| `UpdateKeeperAuth`      | 14 天        | 7 天    | 14 天       | 改 `keeper_stake_script` RegistrationMode 或 allowlist |
| `TreasurySpend`         | 7 天         | 14 天   | 7 天        | 把資金從 treasury 類別桶轉到外部地址 |
| `UpdateTreasuryParams`  | 14 天        | 7 天    | 14 天       | 改類別比例、類別上限 |
| `RotateSigners`         | 14 天        | 7 天    | 14 天       | 改多簽成員 / 門檻 |
| `SlashBond`             | 14 天        | 7 天    | 14 天       | **僅 Phase 3+**(`active_bonds` 非空);沒收違規 keeper 的 bond。V1 啟動時不可達。 |
| `UpdateOracleSource`    | 14 天        | 7 天    | 14 天       | 切換 SwapAda oracle 來源(Charli3/Orcfax feed 輪替)。見 `spec/ada-swap.md §7`。 |
| `DeregisterStake`       | 14 天        | 7 天    | 14 天       | 拆解後,取回每個 staking validator 的 2 ADA Cardano stake-registration 押金。涵蓋 **V1 全部 12 個 staking credential**:`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`、`keeper_stake_script`、`minswap_v2_adapter`(SwapAdapter)。|
| `Heartbeat`             | 0(self)    | N/A     | N/A         | 1-of-self 簽名者 liveness;直接 redeemer,不 queue |
| `DistributeSignerCompensation` | 0(1-of-n) | N/A | N/A         | 季度 pool 分配;直接 redeemer,不 queue |

**理由**:高影響動作(費率變更、簽名者輪替、registry 變更)給 14 天窗口——足以讓任何不同意的存入者在執行前退場。低影響或緊急動作(策略、緊急 recall)給 7 天或更少。`UpdateFeeSplit` 拿最長的 21 天窗口,**因為這是治理調整自己報酬的唯一動作**——額外一週是針對自我交易的結構性保護。

---

## 4. 各動作細節

### 4.1 UpdateStrategy

**用途**:調整 buffer target、allocation 權重、Liqwid 市場開關。

**Payload**:
```aiken
type StrategyPayload {
  new_buffer_target_bps: Int,             // 0..10000
  new_allocations: List<StrategyAlloc>,   // 和 <= 10000 bps
  liqwid_markets_enabled: List<ByteArray>,
}
```

**執行時強制的不變量**:
- `new_buffer_target_bps >= 500`(5% 下限——防止治理讓使用者卡住)
- `new_buffer_target_bps <= 5000`(50% 上限——防止治理讓 vault 閒置)
- `sum(new_allocations.weight) + new_buffer_target_bps <= 10000`
- `liqwid_markets_enabled` ⊆ `registry.liqwid_markets`

### 4.2 UpdateFee

**用途**:改費用參數(績效費率、early-withdraw fee、最短持有期)。

**範圍**:`performance_fee_bps`、`early_withdraw_fee_bps`、`min_hold_seconds`。**不**改 3-way 費用拆分——那是另一個動作(§4.3 UpdateFeeSplit)。

**硬上限(validator 層強制、治理無法改)**:
- `performance_fee_bps <= 450`(4.5% 絕對上限,內部驗證期政策鎖)
- `early_withdraw_fee_bps <= 100`(1% 上限)
- `min_hold_seconds >= 0` 且 `<= 21600`(最多 6 小時——依白皮書 review 從較早的 24h 上限收緊;合約常數在 `lib/vault/constants.ak` 的 `max_min_hold_seconds`)

治理**不能**提高這些上限——它們是 `lib/vault/constants.ak` 中的協議常數,由 `vault_gov_policy.ak` 的 UpdateFee redeemer 呼叫的共用 `validate_update_fee` helper 檢查。

### 4.3 UpdateFeeSplit

**用途**:調整績效費在 keeper、治理池、treasury 間的 3-way 拆分。

**範圍**:`keeper_fee_bps`、`gov_fee_bps`。Treasury 份額為 `10000 - keeper_fee_bps - gov_fee_bps`,**不存**。

**硬上限(validator 層強制)**:
- `keeper_fee_bps <= 4000`(40% 上限——設高以支持公共財定位下的開源第三方 keeper 經濟可行性)
- `gov_fee_bps <= 1000`(10% 上限)
- `keeper_fee_bps + gov_fee_bps <= 5000`(treasury 下限 ≥ 50%)

**Timelock**:21 天(**所有治理動作中最長的 timelock**,因為治理在調整自己的報酬)。

**21 天 timelock 的理由**:自我交易是結構性風險。治理可能被壓力(內部或流氓 m-of-n 共謀)推動把 `gov_fee_bps` 推到上限。21 天窗口給:
- 存入者時間在新拆分生效前退場
- 1-of-n 異議簽名者時間 CancelAction
- 社群時間評估與公開討論

**公開揭露義務**:簽名者必須在 queue 後 1 小時內公開宣布提議的新拆分、理由、預期 TVL 影響。**未揭露是公開信任重評的理由**(非合約強制)。

**階段路線(示意;每一步都需要自己的 UpdateFeeSplit TX)**:
- Phase 1(啟動):`keeper 4000 / gov 0 / treasury 6000`——keeper 在 validator 硬上限,gov pool 啟動時停用
- Phase 2(TVL ≥ 500K + 透過 RotateSigners 加入外部簽名者):`keeper 4000 / gov 500 / treasury 5500`
- Phase 3(TVL ≥ 2M + 加入社群簽名者):`keeper 4000 / gov 1000 / treasury 5000`——treasury 在 validator 硬下限

### 4.3.1 UpdateSlippagePolicy

**用途**:治理閘控調整 §5.4 Phase 2 的兩個滑點上限(`max_slippage_bps` Tier 1 oracle 邊界 + `min_swap_peg_bps` Tier 2 peg-floor 邊界)。讓治理可以在不升級合約的前提下調整 `DeployToProtocol` 的滑點嚴格度。

**範圍**:`max_slippage_bps`、`min_swap_peg_bps`。其他 VaultDatum 欄位**不得變更**。

**硬上限(validator 層強制,定義在 `lib/vault/constants.ak`)**:
- `0 <= new_max_slippage_bps <= max_slippage_bps_cap`(`max_slippage_bps_cap = 500` → 絕對上限 5%)
- `min_swap_peg_bps_floor <= new_min_swap_peg_bps <= min_swap_peg_bps_ceiling`(9_300..9_950 → 介於 93% 與 99.5% peg)

**Timelock**:48 小時(`timelock_update_slippage_policy_ms`)。比費用類動作短,理由:(a) 這個變更**加強**或**放鬆**安全邊界,而非重導資金流;(b) 市場狀況(例如短暫 depeg)可能需要即時調整。Production timelock = 48 小時;Preprod 為了 ceremony 迭代速度覆寫成 60 秒。

**Payload-hash 綁定**:`payload_hash_update_slippage_policy(new_max_slippage_bps, new_min_swap_peg_bps)`(見 `lib/vault/helpers.ak`)。Payload 在 queue 時即固定,execute 不能換值。

**與 `vault_protocol.DeployToProtocol` 的組合**:每次 `DeployToProtocol` 都會檢查 `max_slippage_bps`(Tier 1,當 `registry.asset_oracles` 有 deploy 資產時)+ `min_swap_peg_bps`(Tier 2,從 Minswap V2 route datum 的 `min_receive` 解出)。任一邊界收緊後,於新 datum 落鏈後的下一筆 deploy 起生效。

### 4.4 EmergencyWithdraw

**用途**:當治理察覺嚴重的協議級事件(持續 depeg、Liqwid 壞帳,或其他需要立即停下的緊急狀況)時,**原子性地停掉所有生產性操作**(`frozen = 1`)。

**前置條件**:
- 門檻簽名(m-of-n)
- `target_script == vault_gov_emergency_hash`
- Redeemer 攜帶 `loss_amount` + `freeze_flag`(都進 payload-hash 綁定),但 `loss_amount` 在 validator 層被**強制為 0**(見下方「Layer 1 — freeze-only」)

**Layer 1 — freeze-only(Phase 1 治理安全,2026-04-25)**:validator 把 `valid_deposited` 改為要求 `total_deposited` 不變 + `liqwid_positions` 不變 + `loss_amount == 0`。Redeemer **不能**降低 `total_deposited`,也不能從 datum 移除部位。所有真實損失帳務改走 `vault_liqwid.RecallFromLiqwid` 的治理 fallback 路徑——透過實體 Recall underlying USDCx 並只寫入實際實現的損失(`supplied_value − underlying_received`)。這封閉了單一簽名者治理在金鑰失陷時可以「只動 datum 把部位寫掉造成 share_price 歸零」的 grief 攻擊面(qToken-orphan 向量在 validator 層被根除)。

**與 Layer 2(`vault_protocol.DeployToProtocol`)組合**:在 `frozen = 1` 下,keeper 仍可透過 SwapAdapter 驅動 swap-out(`deploy_token != deposit_token`)。讓誠實 keeper 在緊急 freeze 期間仍能把 NDV stable token(DJED / USDM)換回 USDCx,使用戶 `Withdraw` 能完整支付按比例的份額。

### 4.4.1 CommunitySunset(vault_user,非治理)

**用途**:Phase 1 dead-man-switch。允許任何 vUSDCx 持有者在 keeper + 治理已連續失能 ≥ 90 天時打破運營死局。

**授權**:permissionless——呼叫者必須在 TX 某個 input 中持有 ≥ 1 vUSDCx。

**前置條件**:
- `vault_input_count == 1`
- `max(old.last_compound_time, old.last_realloc_time) + 90 days ≤ tx.validity_range.lower_bound`
- `old.last_compound_time > 1_700_000_000_000`(防護:防止未設置 / 為 0 的時間戳被誤觸發)
- `old.community_sunset_triggered == 0`

**效果**:`frozen = 1` + `community_sunset_triggered = 1`(單向不可逆)。其他所有欄位完整保留(`total_deposited`、`total_shares`、`idle_buffer`、`liqwid_positions`、所有 policy 欄位、所有 immutable 欄位)。

**與回收 validator 組合**:
- `vault_liqwid.RecallFromLiqwid` 在 `community_sunset_triggered == 1` 時接受任何簽名者(跳過 keeper-active / 7-day-keeper-inactive gate)。Loss-aware partial recall 路徑與治理 fallback 分支相同。
- `vault_protocol.DeployToProtocol` Layer 2 路徑在 `community_sunset_triggered == 1` 時接受任何簽名者(跳過 keeper 簽名要求)。SwapAdapter 目的地 + peg_floor + slippage cap 仍套用。

觸發後,任何 vUSDCx 持有者都能驅動 Recall → Swap → Withdraw,完全不需要 keeper 或治理介入。Redeemer **只開回收路徑**——它不能修改任何含值欄位;攻擊者無法用它把 vault drain 或 brick 掉。

**範圍外**:**不**回收 ~870 ADA 的 reference-script 鎖定(在創辦人部署錢包),也**不**回收 ~24 ADA 的 stake-credential 押金(只能透過治理 A2 ActDeregisterStake)。這兩部分作為單一簽名者治理的殘留成本被接受。

### 4.5 AdminDeployNonDeposit

**用途**:從 vault 提取累積的非存入 token,來源:
1. 捐贈(任何人可送 token 到 proxy 地址)
2. 對 vault 地址的空投
3. DEX / 協議灰塵殘留

**約束**:
- `token != deposit_token`(不能透過此路徑 drain 使用者資金)
- `token != vUSDCx`(不能 drain 份額)
- `token != ADA`(不能把 vault ADA 降到運營下限以下)
- `amount <= quantity_of(vault_input, token_policy, token_name)`
- 若該 token 計入 NDV,`non_deposit_value` 相應調整

### 4.6 UpdateRegistry

**用途**:維護協議白名單 + 穩定幣清單 + Liqwid 市場目錄。

**範圍限制**:
- `stable_tokens`:增減條目,每項為 `(policy, name)`
- `protocol_hashes`:增減允許作為 `DeployToProtocol` DEX / swap 目的地的 script hash
- `liqwid_markets`:增減市場條目,每項為 `(market_id, action_addr_hash, qtoken_policy, qtoken_name, active)`
- `keeper_pkh`:**不可變**(內部驗證——除了整個重部署,不能改)
- `registry_auth_policy`:**不可變**(在 registry 部署時錨定)

### 4.7 KeeperToggleMarket(keeper、非治理)

**用途**:讓 keeper 在偵測到 Liqwid 市場退化時立即暫停。

**授權**:僅由 `keeper_pkh` 簽名。**無 timelock**。**無治理簽名**。

**方向**:只能 `active: true → false`。Keeper **不能**重新啟用市場。

**理由**:Keeper 對 Liqwid 健康有即時可視性。等 14 天治理暫停一個失敗市場可能造成使用者資金損失。但 keeper**不能**重新啟用市場——那需要治理審視。

### 4.8 FastUpdateMarkets

**用途**:Liqwid 遷移 pool shard 時 `action_addr_hash` 改變。一般 `UpdateRegistry` 有 14 天 timelock——對 live 遷移**太慢**。

**範圍**:僅改既有市場的 `action_addr_hash`。**不能**加新市場、改 `qtoken_policy/name`、或切 `active`。

**授權**:門檻簽名、1 小時 timelock。

**攻擊面(揭露)**:被入侵的治理(m 位簽名者共謀)可能搶先於假 Liqwid 遷移、把 Supply/Recall 重導到攻擊者控制的 action 地址。緩解:1 小時內 1-of-n cancel + 鏈下監控 + keeper 可 `KeeperToggleMarket` 到 `active: false` 在治理受質疑時停掉所有操作。

### 4.9 UpdateKeeperAuth

**用途**:改 keeper 授權體制。

**V1 啟動範圍**:在 `GovernanceOnly`、`Mixed`、`PermissionlessWithBond` 間切換 `RegistrationMode`。更新 keeper allowlist(在 `GovernanceOnly` 模式下)。

**後期階段範圍**:改 bond 參數(金額、grace period、slashing 條件)。在 treasury 會計內更新 `keeper_commission_bps`。

### 4.10 TreasurySpend

**用途**:把 treasury 資金移到外部地址(審計付款、ops、R&D、創辦人還款)。

**約束**:
- `amount <= treasury.category_balances[category]`
- `category_balances` 更新:`-amount`
- 收件人地址**鏈上不約束**——治理在鏈下為收件人背書
- 審計軌跡:TX 層 CBOR 含 action_id + category + amount + 目的地

### 4.11 UpdateTreasuryParams

**用途**:改類別比例(預設 30/40/20/10,對 audit/ops/R&D/buffer)。

**不變量**:
- 所有類別比例加總 == 10000 bps(100%)
- 任一類別比例 <= 5000 bps(50%)——防止治理把資金集中
- `audit_reserve_ratio >= 2000`(20% 下限——audit reserve 不能被掏空)

### 4.12 RotateSigners

**用途**:改多簽成員。

**不變量(自 §2.4)**:
- `signer_count >= 3`
- `threshold >= 2`
- `threshold <= signer_count - 1`

**Timelock**:14 天(與幾個其他高影響動作並列;`UpdateFeeSplit` 21 天是唯一更長的)。

---

### 4.13 DeregisterStake(A2)

**用途**:取回 V1 部署 ceremony 時,每個 staking validator 的 credential 被註冊時繳的 2 ADA Cardano stake-registration 押金。解決 `deploy/state/recovery-verification.md §2` 中文件化的 V1 design-gap——原本 staking validator 的 `else(_) { fail }` catch-all 拒絕 ledger 的 Publish purpose。

**V1 啟動時的範圍**:
- **V1 全部 12 個 staking credential** 都帶 gov 閘控的 `publish` handler,都可透過此 action deregister:`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`、`keeper_stake_script`,以及 SwapAdapter `minswap_v2_adapter`。切分理由見 `spec/architecture.md §4.1`。

**Publish handler 模式**:
```aiken
publish(_redeemer, credential, tx) {
  expect Script(own_hash) = credential
  is_gov_authorized(
    tx,
    governance_nft_policy,
    governance_nft_name,
    ActDeregisterStake,
    payload_hash_deregister_stake(own_hash),
    own_hash,
  )
}
```

`governance_nft_policy` + `governance_nft_name` 是四個 staking validator 的**編譯時參數**(keeper_stake_script 在 A2 之前就有;vault_protocol / vault_liqwid / vault_admin 各自新加入這一對)。在編譯時錨定——而不是透過 `find_vault_utxo` 從 vault datum 讀——讓 deregister 順序解耦:operator 可以在 vault full-drain 之後(vault UTxO 已不存在時)做 deregister,也可以在之前,順序任意。

**Payload**:`payload_hash_deregister_stake(target_hash) = blake2b_256(cbor.serialise(target_hash))`。Off-chain 工具排入時計算同樣的 hash。

**Timelock**:14 天(production)。與 `UpdateKeeperAuth` 同——同屬「operator credential 變更」層級。**Preprod A2 驗證覆寫**:1 小時(`lib/vault/constants.ak` 的 `timelock_deregister_stake_ms`——mainnet build 前須還原)。

**攻擊面分析**:
- AT-1(grief):被入侵的 m-of-n gov queue ActDeregisterStake → 14d timelock + 1-of-n cancel 否決。與其他 Act* 的防禦 profile 相同。
- AT-2(same-block race):原子化;deregister 後,vault TX 自然失敗(stake cred 已消失)。
- AT-3(部分 deregister 導致狀態不一致):operator 側的帳務問題,**無資金損失**——withdraw-zero 模式乾淨地斷裂。
- AT-4(第三方重新註冊):任何人可以再註冊已 deregister 的 stake cred(依 Cardano ledger 規則,Register cert 無 script),自付 2 ADA。**攻擊者損失 2 ADA、operator 取回 2 ADA。對攻擊者是淨負——不可利用。**
- AT-5(gov 簽名者被入侵):不是新攻擊面——被入侵的 gov 可以執行任何其他 Act*。

**工具**:`deploy/tools/deregister-stakes.ts`(為 gov flow 重寫:`--queue` 對每個 target queue ActDeregisterStake,`--execute` 在 timelock 後執行)。

---

## 5. Empty-Hash 授權模式

**背景**:`QueueAction` 接受 `target_tx_hash == #""`(空)。當 target 為空時,`ExecuteAction` **不**強制 `tx.id == target_tx_hash`。這是**刻意的**。

**Empty-hash 並未改變的事**:

`ExecuteAction` 在執行時**永遠**要求 `signers_present >= gov.threshold`(`multisig_gov.ak:378`——`sig_ok = signers_present >= gov.threshold`)。Empty-hash 模式**只**繞過 `tx.id == action.target_tx_hash` binding;`ExecuteAction` 的其他不變量仍然套用:

- **≥ threshold 簽名**在執行時(**不存在**「1-of-n 單獨執行」路徑)。
- **Payload-hash binding**(`blake2b_256(cbor.serialise(redeemer))` 必須與 `action.payload_hash` 相符)。Target validator 的 redeemer 參數——新費率、新 allocation、receiver 地址、金額——在 queue 時就固定,**無法**在執行時被抽換。
- **Timelock 窗口**(`tx.validity_range.lower >= action.executable_at_ms` 且 `upper < action.expires_at_ms`)。
- **Validity-range 寬度上限**(`upper - lower <= 1 小時`),限制 `tx.id` 篡改企圖。
- **GovNFT 唯一性**(`nft_in_input && nft_in_output`)。

**常見錯誤描述避免**:「14 天後任何 1-of-n 簽名者都能執行任意 admin」——**這是錯的**。`ExecuteAction` 永遠要求完整門檻,與 `target_tx_hash` 是否為空無關。

**為什麼需要 empty-hash**:

- 許多治理動作**無法預知**其未來 TX hash(TX hash 取決於執行時選定的 input,其中最重要的是付費 UTxO)。
- 要求特定 TX hash 會讓多數治理動作**無法排入佇列**,除了少數例外(例如 input 可預知的自包含 `MultisigGov` spend)。
- 平行的 `tx.id ↔ target_tx_hash` 循環依賴:queue 時計算 `target_tx_hash` 需要知道完整執行時 TX body——而該 body 又包含 `target_tx_hash` 本身。

**哪些動作接受 empty hash(V1 目前)**:

- `UpdateFee`、`UpdateFeeSplit`、`UpdateRegistry`、`RotateSigners`、`TreasurySpend`、`UpdateTreasuryParams`、`UpdateKeeperAuth`——都接受 empty hash。
- `EmergencyWithdraw`、`AdminDeployNonDeposit`、`FastUpdateMarkets`——也接受 empty hash(設計上 queue 在執行時狀態之前)。
- `Heartbeat`、`DistributeSignerCompensation`、`CancelAction`——**不屬於 queued action**(直接 1-of-n 或 1-of-self redeemer)。

**實際殘餘風險(如實描述)**:

使用 empty-hash 時剩餘的攻擊面:

1. **`m` 位共謀簽名者**可以排入動作(提前 14-30 天,依 `timelock_ms`)。
2. Timelock 過後,`m` 位共謀簽名者執行該動作。Payload 完全被 `payload_hash` 綁定,所以執行後的鏈上狀態**正是**他們 queue 的那份——**不可能「抽換任意 redeemer」**。Empty-hash 放寬的是 TX**外形**(哪些 UTxO 付費、哪些非必要 output),但這個自由不改變 payload 的意圖。
3. **防禦——1-of-n CancelAction**(`multisig_gov.ak::CancelAction`,`sig_ok >= 1`):**任何一位未共謀的簽名者,都可以在 timelock 窗口期間隨時 cancel**。
4. **防禦——鏈下義務**(operator charter,非 validator 強制):
   - 每筆非瑣碎的 queue 在簽名後 1 小時內公開廣播(公開 Discord 公告 + 鏈上 CBOR decode,任何人都能解析 payload)。
   - 維持至少 1 位誠實簽名者監控每筆 queue。
   - 招募簽名者時讓 ≥2 位非共謀(charter 要求;V1 啟動以 1 位創辦人 + 2 位獨立 Cardano SPO 滿足此要求)。

**V1 啟動備註(3-of-3 unanimity)**。啟動時 `threshold == n == 3`,所以「m 位共謀」意指「全部 3 位簽名者共謀」。1-of-n cancel = 3 位中任 1 位可以 veto。這在結構上比典型門檻設定**更強**,因為 queue 本身就要 unanimity;只有當 Phase 2+ 切到 `threshold < n`(5 位 / 門檻 4)時,這層憂慮才有牙齒——4 位共謀 + 1 位沉默誠實簽名者能推動惡意動作,**若鏈下監控失敗**。

**歷史上已關閉的變體**:一個「1-signer CancelAction + timelock=0 緊急路徑」的 grief(惡意簽名者可以用 0-timelock 濫用 grief 合法動作)已在內部驗證關閉。目前 `min_timelock_ms(action_kind)` 對每個動作(包括 `EmergencyWithdraw`)都設下 ≥ 文件化最小值的底(§3)。

---

## 6. Nonce 與防重放

`GovDatum.nonce` **嚴格單調**,每次狀態變化(Queue、Cancel、Execute、Rotate)都 +1。這防止:
- Replay 攻擊(同一 redeemer 兩次)
- 鏈下觀察者的歧義狀態讀取
- 跨 reorg 的不一致視角

每個治理 redeemer 的 Plutus eval 都讀 `old_nonce + 1 == new_nonce`。違反就 TX 失敗。

---

## 7. 跨 validator 授權流程

當 `vault_protocol` 收到 `VaultAdmin` redeemer(例如 `UpdateFee`)時,會跑:

```aiken
validate_gov_admin: fn(tx) -> Bool {
  // 1. 找 MultisigGov input
  let gov_input = find_input_by_script(tx.inputs, governance_policy)
  expect gov_input: Input

  // 2. 解析 GovDatum 並找 queued action
  let gov_datum = parse_gov_datum(gov_input.output.datum)
  let action_id = compute_action_id(redeemer)
  let queued = list.find(gov_datum.queued, fn(q) { q.action_id == action_id })
  expect Some(action): Option<QueuedAction> = queued

  // 3. 驗證 timelock 窗口
  expect tx.validity_range.lower >= action.executable_at_ms
  expect tx.validity_range.upper < action.expires_at_ms

  // 4. 驗證 target 相符
  expect action.target_script == vault_protocol_hash

  // 5. 驗證 payload hash
  expect compute_payload_hash(redeemer) == action.payload_hash

  // 6. 驗證 continuing gov output 已移除該 action、nonce +1
  //(由 multisig_gov validator 在自己 spend 路徑上完成)

  True
}
```

`vault_protocol`、`registry`、`treasury`、`keeper_stake_script` 中每個治理閘控的 redeemer 都委派給這個模式。**MultisigGov validator 是授權的單一真相來源**。

---

## 8. V1 啟動簽名者集合

啟動時 **3 位創辦人連結的簽名者、threshold 3**(3-of-3 unanimity)。所有身份在公開白皮書 + 部署時的鏈上揭露。

**啟動為何用 unanimity**:創辦人同時也是 keeper operator。2-of-3 啟動會讓創辦人只需要**一位**其他簽名者的協助就能推動治理動作。**要求 3-of-3 強迫創辦人必須說服「另外兩位獨立招募的簽名者」雙方都同意**,每筆治理動作皆然。這個 trade-off 失去「結構性異議簽名者」屬性(若三位全共謀,quorum 外無人可 veto),但啟動時三位簽名者都已是創辦人連結的,這個屬性本就薄弱;**強制 unanimity 是更強的保證**。

**輪替路線**:
- Phase 1(啟動 → 審計通過):3 位創辦人連結的簽名者、**threshold 3(3-of-3)**
- Phase 2(post-audit、TVL > 500K):5 位簽名者(加 1-2 位外部者——候選:大額存入者、同業協議創辦人、技術社群成員),**threshold 4(4-of-5)**——結構性異議簽名者恢復
- Phase 3(TVL > 2M):7 位簽名者(加入社群選舉職位;選舉機制**TBD**、在 Phase 3 啟用前決定——vUSDCx 持有**明確不**作為投票權重,避免 plutocracy),**threshold 5(5-of-7)**
- Phase 4(成熟、TVL > 10M):探討 DAO 遷移

每次輪替是帶完整 14 天 timelock 的 `RotateSigners` TX。**公開揭露新簽名者身份是治理 charter 的一部分**。

**Gov Signer NFT**:每位簽名者加入集合時會收到一個 soul-bound **OptiVaults Gov Signer** NFT。該 NFT 無鏈上投票 / 金融權利——**純肯定**,簽名者輪替出去時被 burn。Mint policy 與目錄透過以 `governance_policy` 參數化的 minting policy 管理,讓治理 NFT 與 Gov Signer NFT **密碼學連結**。完整 NFT spec 見 `spec/gov-nft.md`。

---

## 9. 簽名者補償機制

本節摘要治理簽名者補償如何流經合約 stack(完整細節在 §2.5–§2.6 與 `docs/economics.md`)。

### 9.1 累積
每筆 Compound TX 按 `VaultDatum.keeper_fee_bps` / `gov_fee_bps` 把績效費 3-way 拆分:
- Keeper 份額 → 簽名 keeper 的 PKH 地址
- 治理份額 → MultisigGov UTxO 的 `signer_compensation_pool`(跨多次 Compound 累積)
- Treasury 份額 → Treasury UTxO 的類別餘額

### 9.2 合格(X3 混合規則)
簽名者在季度 Q 要合格必須**同時**:
1. **Tenure**:`signer_joined_at_ms[i] <= last_distribute_ms`(在 Q 開始前加入)
2. **活動**:`signer_last_qualified_ms[i] >= last_distribute_ms`(Q 期間至少簽過 1 筆:QueueAction、ExecuteAction、CancelAction、RotateSigners、Heartbeat)

Heartbeat 的存在,就是為了讓安靜季的簽名者**仍可**合格。

### 9.3 分配
- 季度(90 天)透過 `DistributeSignerCompensation` redeemer
- 1-of-n 授權——任一當前簽名者都可觸發
- Pool **平分**給合格簽名者
- **Forfeit 流**:不合格簽名者的份額流向 Treasury audit reserve 類別(Y1 設計——不在合格者間重分配,避免「希望同事失敗」的反向誘因)

### 9.4 啟動狀態
- `gov_fee_bps = 0` 在 V1 啟動時 → 無 pool 累積 → 無補償
- Phase 2 啟用(TVL ≥ 500K)透過 `UpdateFeeSplit`(21 天 timelock)把 `gov_fee_bps` 提高
- 預估收入:見 `docs/economics.md §簽名者補償`

---

## 10. 延伸閱讀

- `spec/architecture.md` — validator 目錄、治理在信任模型中的角色
- `spec/keeper-auth.md` — 治理如何透過 `UpdateKeeperAuth` 授權 keeper
- `spec/treasury.md` — 治理如何透過 `TreasurySpend` 動用 treasury、forfeit 累積路徑
- `spec/gov-nft.md` — Gov Signer NFT mint policy 與生命週期
- `spec/vault-datum.md §2.2` — validator 層強制的 fee-split 硬上限
- `docs/security-model.md` — 完整威脅模型,含治理被入侵的情境
- `docs/economics.md` — 3-way fee split 數學、各 TVL 下的補償預估
