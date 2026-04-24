# OptiVaults V1 — MultisigGov Validator 規格

**範圍**:`multisig_gov` validator 的內部實作細節——action_id 計算、GovDatum spend / 轉移規則、跨 validator 授權 helper,以及本 validator 與 `governance.md`(公開動作目錄)的職責分離。

本文件是 `spec/governance.md` 的**實作層級**伴隨文件。如果 `governance.md` 回答「治理能做什麼、什麼時候能做?」,本文件回答「validator 怎麼強制這些規則?」

---

## 1. Validator 結構

`multisig_gov` 是**spending validator**(單一 UTxO 狀態機),在編譯時以下列參數參數化:

```aiken
validator multisig_gov(
  governance_nft_policy: PolicyId,
  governance_nft_name: ByteArray,
) {
  spend(
    datum: Option<GovDatum>,
    redeemer: GovRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) { ... }
}
```

部署時,在此 validator 地址產生**恰好一個** UTxO,帶 one-shot 治理 NFT `(governance_nft_policy, governance_nft_name, 1)`。NFT 在部署時**剛好鑄一次**。Burning 不是正常操作(只要 V1 還活著,Gov UTxO 是永久的)。

---

## 2. GovDatum schema(canonical)

```aiken
type GovDatum {
  // --- 簽名者狀態 ---
  signers: List<VerificationKeyHash>,              // 目前 m-of-n 集合(3..20 項)
  signer_joined_at_ms: List<Int>,                   // 與 signers 平行;tenure 起始
  signer_last_qualified_ms: List<Int>,              // 與 signers 平行;上次合格 TX
  threshold: Int,                                   // m(2..signer_count——允許 unanimity)

  // --- 帶 timelock 的動作佇列 ---
  queued: List<QueuedAction>,                       // 0..10 待處理

  // --- 簽名者報酬池 ---
  signer_compensation_pool: Int,                   // Lovelace(USDCx 單位)累積
  last_distribute_ms: Int,                          // 上次 DistributeSignerCompensation TX
  distribute_period_ms: Int,                        // 7_776_000_000(90 天)季度

  // --- Anti-replay ---
  nonce: Int,                                       // 嚴格單調
}

type QueuedAction {
  action_id: ByteArray,                             // 32-byte hash(見 §4)
  action_kind: ActionKind,
  target_script: ByteArray,                         // 動作執行對象的 validator hash
  target_tx_hash: ByteArray,                        // 空(#"")或 32-byte pre-committed TX hash
  payload_hash: ByteArray,                          // redeemer payload CBOR 的 Blake2b-256
  queued_at_ms: Int,
  executable_at_ms: Int,                            // queued_at + timelock_ms
  expires_at_ms: Int,                               // executable_at + ttl_ms
}

type ActionKind {
  UpdateStrategy                                    // §governance.md 4.1
  UpdateFee                                         // §4.2
  UpdateFeeSplit                                    // §4.3(21d timelock)
  EmergencyWithdraw                                 // §4.4
  AdminDeployNonDeposit                             // §4.5
  UpdateRegistry                                    // §4.6
  FastUpdateMarkets                                 // §4.8(1h timelock)
  UpdateKeeperAuth                                  // §4.9
  TreasurySpend                                     // §4.10
  UpdateTreasuryParams                              // §4.11
  RotateSigners                                     // §4.12
  SlashBond                                         // Phase 3+ only;沒收 keeper bond
  UpdateOracleSource                                // SwapAda oracle feed 輪替(見 spec/ada-swap.md)
  ActDeregisterStake                                // §4.13(A2)取消 stake credential + 退 2 ADA 押金
}

type GovRedeemer {
  QueueAction { ... }
  CancelAction { action_id: ByteArray }
  ExecuteAction { action_id: ByteArray }
  RotateSignersRedeemer { new_signers: List<VerificationKeyHash>, new_threshold: Int }
  Heartbeat { signer: VerificationKeyHash }
  DistributeSignerCompensation { triggering_signer: VerificationKeyHash }
}
```

**平行 list 不變量**:`list.length(signers) == list.length(signer_joined_at_ms) == list.length(signer_last_qualified_ms)`。任何會動到這三個 list 之一的 redeemer,都必須保留此不變量——破壞它會造成 off-by-one 讀取,並誤派季度報酬。

---

## 3. 簽名者成員不變量

每個會改動 `signers` 的 redeemer 都強制:

- `3 <= list.length(signers) <= 20`(最低 3 才有「多簽 + 1-of-n cancel」意義;上限 20 以限制 datum 大小)
- `2 <= threshold <= list.length(signers)`(最低 2 才是真的多簽;**unanimity `threshold == n` 明確允許**)。**理由**:V1 啟動時 **3-of-3(threshold = n = 3)**,因為創辦人同時是 keeper operator + 在治理內——unanimity 強迫創辦人必須說服**其他兩位**簽名者才能通過任何動作,而不只是一位。Post-audit Phase 2+ 的最佳實務是 `threshold < n`,好讓至少一位簽名者永遠在通過 quorum 之外、能 1-of-n cancel——但這是運營政策慣例,**不是 validator 強制約束**。
- 所有 `signers` 項互不相同
- 所有 `signer_joined_at_ms[i] > 0`(時間戳非零)
- 所有 `signer_last_qualified_ms[i] >= 0`(0 代表「加入後從未合格」)

---

## 4. action_id 計算

每個 `QueuedAction.action_id` 都是一個確定性的 Blake2b-256 hash:

```aiken
fn compute_action_id(
  action_kind: ActionKind,
  target_script: ByteArray,
  payload_hash: ByteArray,
  queued_at_ms: Int,
  nonce_at_queue: Int,
) -> ByteArray {
  let preimage = bytearray.concat([
    action_kind_byte(action_kind),        // 1 byte tag
    target_script,                         // 28 bytes
    payload_hash,                          // 32 bytes
    int_to_bytes_be(queued_at_ms, 8),     // 8 bytes big-endian
    int_to_bytes_be(nonce_at_queue, 8),   // 8 bytes big-endian
  ])
  blake2b_256(preimage)                    // 32 bytes
}
```

**唯一性屬性**:`nonce_at_queue` 在整個 GovDatum 生命週期嚴格單調,所以兩個在相同 `queued_at_ms` 且 `payload_hash` 相同的動作,仍會產生**不同** `action_id`。

**防重放**:因為 `action_id` 是 `queued` 的一部分,而 `queued` 條目在 `CancelAction` / `ExecuteAction` 時被移除,所以同樣的 `(action_kind, target_script, payload_hash)` 組合可以**在移除後再 queue 一次**——但會有新的 `nonce_at_queue`、進而新的 `action_id`。合法的重新 queue 是可能的;**同一個 queue 條目的重複執行**不可能。

---

## 5. payload_hash 計算

對每個 `ActionKind`,payload 就是會在 ExecuteAction 時傳給 target validator 的 redeemer。Payload 做 CBOR 編碼後 hash:

```aiken
payload_hash = blake2b_256(cbor.serialise(payload))
```

各 ActionKind 的 Payload 型別(對應 `governance.md §4`):

| ActionKind | Canonical payload tuple(必須與 `lib/vault/helpers.ak:payload_hash_*` 一致) |
|------------|-----------------------------------------------------------------------|
| UpdateStrategy | `(new_allocations, new_buffer_target_bps)` |
| UpdateFee | `(new_performance_fee_bps, new_early_withdraw_fee_bps, new_min_hold_seconds)` |
| UpdateFeeSplit | `(new_keeper_fee_bps, new_gov_fee_bps)` |
| EmergencyWithdraw | `(loss_amount, freeze_flag)` |
| AdminDeployNonDeposit | `(deploy_amount, deploy_token_policy, deploy_token_name)`——`new_allocations` + `dest_output_idx` 是運營選擇、不預先承諾 |
| UpdateRegistry | `<new_registry_datum>`(整個 RegistryDatum 值作為 payload) |
| FastUpdateMarkets | `<new_registry_datum>`(整個 RegistryDatum 值) |
| UpdateKeeperAuth | `<new_keeper_auth_datum>`(整個 KeeperAuthDatum 值) |
| TreasurySpend | `(category_tag_byte, amount, recipient_address, audit_invoice_ref)`——category tag:`#"01"` audit / `#"02"` ops / `#"03"` rd / `#"04"` buffer |
| UpdateTreasuryParams | `(audit_bps, ops_bps, rd_bps, buffer_bps, cap_audit, cap_ops, cap_rd, cap_buffer)` |
| RotateSigners | `(new_signers, new_threshold)` |
| SlashBond | `(bond_owner, evidence_ref, slash_amount)` |
| UpdateOracleSource | **TBD**——保留的 ActionKind;payload 佈局在 V1.x 把 SwapAda oracle source 從編譯時錨點改為 mutable 欄位時定案 |
| ActDeregisterStake | `target_hash`——stake validator 自己的 28-byte script hash。`payload_hash_deregister_stake(target_hash) = blake2b_256(cbor.serialise(target_hash))`。看起來冗餘(動作的 `target_script` 欄也釘這個),但保留跨所有 ActionKind 一致的 `payload_hash_*` 模式,並擋住 off-chain 工具構造 `target_script ≠ payload_hash_input` 的 QueueAction。涵蓋的 validator:`vault_protocol`、`vault_liqwid`、`vault_admin`、`keeper_stake_script`。**不涵蓋**:`vault_core`(publish handler 因 16 KB 上限省略——見 governance.md §4.13)。 |

ExecuteAction 時,validator 從實際傳給 target validator 的 redeemer 重新計算 `payload_hash`,並與 queued 的 `payload_hash` 比對。不相符 → 拒絕。

---

## 6. Redeemer 實作

### 6.1 QueueAction

```aiken
QueueAction {
  action_kind: ActionKind,
  target_script: ByteArray,
  target_tx_hash: ByteArray,
  payload_hash: ByteArray,
  timelock_ms: Int,
  ttl_ms: Int,
}
```

**驗證**:
1. Gov UTxO 被 spent;continuing output 在同 validator 地址、帶治理 NFT
2. `tx.extra_signatories` 含 ≥ `threshold` 位 `signers` 成員
3. `timelock_ms >= min_timelock(action_kind)`(依 governance.md §3 表):
   - UpdateStrategy:7d
   - UpdateFee:14d
   - **UpdateFeeSplit:21d**
   - EmergencyWithdraw:0
   - AdminDeployNonDeposit:7d
   - UpdateRegistry:14d
   - FastUpdateMarkets:1h(3_600_000 ms)
   - UpdateKeeperAuth:14d
   - TreasurySpend:7d
   - UpdateTreasuryParams:14d
   - RotateSigners:14d
4. `86_400_000 <= ttl_ms <= 2_592_000_000`(1 天到 30 天)
5. `target_tx_hash` 為 `#""`(多數動作允許)或剛好 32 bytes
6. `len(queued_old) + 1 <= 10`(DoS 上限)
7. `payload_hash` 剛好 32 bytes
8. Continuing datum:
   - `signers, threshold, signer_joined_at_ms, signer_last_qualified_ms` 不變(除了本 TX 中簽名的每位 signer 的 `signer_last_qualified_ms[i]` 更新——他們在本季「合格」)
   - `signer_compensation_pool, last_distribute_ms, distribute_period_ms` 不變
   - `nonce = old.nonce + 1`
   - `queued = old.queued ++ [new_queued_action]`,其中:
     ```
     new_queued_action = QueuedAction {
       action_id: compute_action_id(action_kind, target_script, payload_hash, tx.validity_range.upper, old.nonce),
       action_kind, target_script, target_tx_hash, payload_hash,
       queued_at_ms: tx.validity_range.upper,
       executable_at_ms: tx.validity_range.upper + timelock_ms,
       expires_at_ms: tx.validity_range.upper + timelock_ms + ttl_ms,
     }
     ```

### 6.2 CancelAction

```aiken
CancelAction { action_id: ByteArray }
```

**驗證**:
1. Gov UTxO spent;continuing output 在同地址、帶 Gov NFT
2. `tx.extra_signatories` 含 **≥ 1 位** `signers` 成員(1-of-n 授權)
3. `∃ i. old.queued[i].action_id == action_id`(目標存在)
4. Continuing datum:
   - `queued = list.remove_at(old.queued, i)`
   - `signer_last_qualified_ms[j]` 對每位簽名的 `signers[j]` 更新(cancel 也算合格)
   - `nonce = old.nonce + 1`
   - 其他欄位不變

**1-of-n 授權的理由**:這是緊急煞車。任何單一簽名者——包含原本反對 queue 的那位——都能 cancel。若 cancel 也要求多簽,quorum 可以 queue 惡意動作、同時擋住對自己的 cancel。

### 6.3 ExecuteAction

```aiken
ExecuteAction { action_id: ByteArray }
```

**驗證**:
1. Gov UTxO spent;continuing output 在同地址、帶 Gov NFT
2. `tx.extra_signatories` 含 ≥ `threshold` 位 `signers` 成員
3. `∃ i. old.queued[i].action_id == action_id`(目標存在)
4. 令 `action = old.queued[i]`:
   - `tx.validity_range.lower >= action.executable_at_ms`(timelock 已過)
   - `tx.validity_range.upper < action.expires_at_ms`(尚未過期)
   - 若 `action.target_tx_hash != #""`:`tx.id == action.target_tx_hash`
5. **跨 validator binding**:target validator 的 UTxO 必須也在本 TX 中被消費。Target validator 讀自己的 redeemer 時,重新計算 `blake2b_256(cbor.serialise(redeemer)) == action.payload_hash`。若不符,target 拒絕 → 整筆 TX 失敗。
6. **Target 側授權檢查**(在 target validator 上跑):target validator 查找 Gov UTxO 作為 spent input、讀 ExecuteAction redeemer、確認 `action.action_kind` 與 target 預期相符、並強制 `action.target_script == self.script_hash`。
7. Continuing datum:
   - `queued = list.remove_at(old.queued, i)`
   - 每位簽名的 signer 的 `signer_last_qualified_ms[j]` 更新
   - `nonce = old.nonce + 1`
   - 其他欄位不變

### 6.4 RotateSignersRedeemer

這是先前 QueueAction 過的 `RotateSigners` 動作的鏈上執行。因為 `RotateSigners` 會改動簽名者清單本身(**關鍵狀態變更**),它有自己的 redeemer 而不走 `ExecuteAction`。這保證簽名者輪替與 datum 轉移**原子性**發生。

```aiken
RotateSignersRedeemer {
  new_signers: List<VerificationKeyHash>,
  new_threshold: Int,
}
```

**驗證**:
1. Gov UTxO spent;continuing output 在同地址、帶 Gov NFT
2. `tx.extra_signatories` 含 ≥ `old.threshold` 位 `old.signers` 成員
3. 存在已 queue 的 `RotateSigners` 動作、`payload_hash` 相符(驗證這次輪替已預先核可):
   - `∃ i. old.queued[i].action_kind == RotateSigners`
   - `old.queued[i].payload_hash == blake2b_256(cbor.serialise((new_signers, new_threshold)))`
   - `tx.validity_range.lower >= old.queued[i].executable_at_ms`
   - `tx.validity_range.upper < old.queued[i].expires_at_ms`
4. 新簽名者不變量(§3):
   - `3 <= list.length(new_signers) <= 20`
   - `2 <= new_threshold <= list.length(new_signers) - 1`
   - 所有 `new_signers` 互不相同
5. Continuing datum:
   - `signers = new_signers`
   - `threshold = new_threshold`
   - `signer_joined_at_ms = [preserve_if_retained(s, i) for (s, i) in zip(new_signers, indices)]`:
     - 對每個等於某 `old.signers[j]` 的 `new_signers[i]`:`signer_joined_at_ms[i] = old.signer_joined_at_ms[j]`(tenure 保留)
     - 對每個新加入者:`signer_joined_at_ms[i] = tx.validity_range.lower`
   - `signer_last_qualified_ms` 同樣對留任者保留;對新加入者重置為 0
   - `queued = list.remove_at(old.queued, i)`(RotateSigners queue 條目被消耗)
   - `signer_compensation_pool` 不變(備註:operator 慣例是若 pool > 0 先跑 DistributeSignerCompensation,但這**不是**合約強制——見 governance.md §2.4)
   - `nonce = old.nonce + 1`

### 6.5 Heartbeat

```aiken
Heartbeat { signer: VerificationKeyHash }
```

**驗證**:
1. Gov UTxO spent;continuing output 在同地址、帶 Gov NFT
2. `tx.extra_signatories` 含 `signer`
3. `∃ i. signers[i] == signer`(signer 是當前成員)
4. `tx.validity_range.lower - old.signer_last_qualified_ms[i] >= 7_776_000_000`(90 天、每季一次)
5. Continuing datum:
   - `signer_last_qualified_ms[i] = tx.validity_range.lower`
   - 其他欄位不變,除了 `nonce = old.nonce + 1`

**Gas 成本**:約 0.2 ADA 網路費,由 signer 支付。**不動 treasury**。

### 6.6 DistributeSignerCompensation

```aiken
DistributeSignerCompensation { triggering_signer: VerificationKeyHash }
```

**驗證**:
1. Gov UTxO spent;continuing output 在同地址、帶 Gov NFT
2. `triggering_signer ∈ old.signers`;`tx.extra_signatories` 含 `triggering_signer`
3. `tx.validity_range.lower - old.last_distribute_ms >= old.distribute_period_ms`(季度節奏,90d)
4. `old.signer_compensation_pool > 0`(沒東西可分就拒)
5. **每位 signer 的合格檢查**:
   - `qualified[i] = (old.signer_joined_at_ms[i] <= old.last_distribute_ms) AND (old.signer_last_qualified_ms[i] >= old.last_distribute_ms)`
6. 令 `qualified_signers = [(signers[i], i) for i in range if qualified[i]]`
7. 令 `per_signer = old.signer_compensation_pool / max(len(qualified_signers), 1)`
8. 令 `forfeit_total = old.signer_compensation_pool - (len(qualified_signers) * per_signer)`
9. **TX output**:
   - 對每位 `(signer_pkh, _) ∈ qualified_signers`:一筆 UTxO 到 `signer_pkh` 的付款地址,帶剛好 `per_signer` USDCx
   - **Forfeit output**:Treasury UTxO 也在本 TX 被 spent,其 continuing output `audit_reserve_balance += forfeit_total`(由 treasury 的 `ReceiveGovForfeit` redeemer 觸發——見 `spec/treasury.md §3.3`)
10. Continuing gov datum:
    - `signer_compensation_pool = 0`
    - `last_distribute_ms = tx.validity_range.lower`
    - 其他欄位不變,除了 `nonce = old.nonce + 1`

**跨 validator 原子性**:若 Treasury UTxO 的 continuing output 未能正確吸收 forfeit(金額錯、datum 更新錯),treasury validator 拒絕 → 整筆 TX 失敗,gov datum 不變。

**Zero-qualified 邊界案例**:若 `len(qualified_signers) == 0`,整個 pool 全部 forfeit 進 audit reserve。Distribute TX 仍執行(pool 清空、計時推進),但沒有 signer 收到 USDCx。預期罕見;出現時代表值得公開討論的治理健康問題。

---

## 7. 跨 validator 授權 helper

**實作在** `lib/vault/helpers.ak::is_gov_authorized`(V1 內部審計修補中加入)。`vault_admin`、`registry`、`treasury`、`keeper_stake_script` 中每個治理閘控的 redeemer 都呼叫這個 helper。Canonical 實作:

```aiken
pub fn is_gov_authorized(
  tx: Transaction,
  governance_policy: ByteArray,
  governance_name: ByteArray,
  expected_action_kind: ActionKind,
  expected_payload_hash: ByteArray,
  own_script_hash: ByteArray,
) -> Bool {
  // 1. 透過治理 NFT 找 MultisigGov UTXO
  let gov_input = list.find(tx.inputs, fn(i) {
    quantity_of(i.output.value, governance_policy, governance_name) == 1
  })
  // 2. 解析 GovDatum(InlineDatum + 防禦性型別檢查)
  // 3. 讀傳給 multisig_gov 的 redeemer(必須是 ExecuteAction)
  // 4. 依 action_id 找 queued action
  // 5. 驗證:
  //    - action.action_kind == expected_action_kind
  //    - action.target_script == own_script_hash
  //    - action.payload_hash == expected_payload_hash
  //(timelock + TTL 在 multisig_gov 自己的 ExecuteAction spend 路徑裡強制)
  ...
}
```

Caller 用 `helpers.ak` 中的 `payload_hash_*` helper(與上面的 canonical tuple 佈局對齊)預計算 `expected_payload_hash`。範例——`vault_admin.UpdateFee`:

```aiken
let expected_payload_hash = payload_hash_update_fee(
  new_performance_fee_bps, new_early_withdraw_fee_bps, new_min_hold_seconds,
)
let governance_authorized = is_gov_authorized(
  tx,
  old_datum.governance_policy, old_datum.governance_name,
  ActUpdateFee,
  expected_payload_hash,
  own_admin_hash,  // 來自 staking validator 的 `expect Script(own_admin_hash) = account`
)
```

**鏈下義務**。提交 `QueueAction` 者必須**用相同的 canonical tuple 佈局**在鏈下計算**同一**個 payload hash(`scripts/governance/opti-gov.ts` 必須與 `payload_hash_*` byte-for-byte 一致),否則執行會被拒。

這關閉了 V1 內部審計 H-1 發現:較早的 V1 草稿只檢查「GovNFT 在 tx.inputs 中」,這讓 m-of-n signer 可以 queue 一個良性 payload(在 timelock + 1-of-n cancel 窗口期間接受公開揭露),然後在同一 TX 執行**不同的** payload——**完全繞過公開審視防禦**。

---

## 8. 大小與最佳化考量

預估編譯 script 大小(視實際 Aiken 編譯而定):

| 元件 | 大小估計 |
|------|--------|
| multisig_gov spend 路徑 | ~6-8 KB |
| 所有 redeemer 分支 | ~2 KB × 6 = ~12 KB |
| 總計 | ~14-16 KB(符合 16 KB Plutus V3 validator 上限) |

已套用的最佳化:
- `ActionKind` 在 action_id preimage 中以單 byte tag 表示,**不是**完整 sum type
- `action_id` 用 blake2b_256(原生 primitive,比組合 sha2_256 便宜)
- 平行 list(`signers`、`signer_joined_at_ms`、`signer_last_qualified_ms`)共用 index;單次 traversal 處理三者

若編譯大小超過 16 KB,fallback 是把 `multisig_gov` 切成兩個 validator(一個做 queue/cancel/execute、一個做 rotate/heartbeat/distribute),以 Withdraw-Zero 模式連接——與 `vault_core` / `vault_protocol` / `vault_liqwid` 的切分類似。

---

## 9. 測試面

`multisig_gov_test.ak` 的關鍵測試案例(V1 內部審計 regression,範圍在 `docs/audit-scope.md`):

1. **QueueAction 的 `timelock_ms` 低於下限** → 拒絕
2. **QueueAction 當 `queued` 已有 10 項** → 拒絕(DoS 上限)
3. **CancelAction 帶 0 簽名** → 拒絕
4. **CancelAction 帶 1 簽名但 signer 不在 `signers` 中** → 拒絕
5. **CancelAction 合法** → `queued` 減 1、nonce+1
6. **ExecuteAction 在 `executable_at_ms` 之前** → 拒絕
7. **ExecuteAction 在 `expires_at_ms` 之後** → 拒絕
8. **ExecuteAction 帶錯誤 `action_id`** → 拒絕(找不到)
9. **ExecuteAction 帶正確 `action_id` 但 target validator 不符** → target 拒絕(跨 validator 測試)
10. **ExecuteAction payload_hash 不符** → target 拒絕
11. **RotateSigners 簽名者數 < 3** → 拒絕
12. **RotateSigners threshold > signers** → 拒絕(允許 unanimity;只有 threshold 嚴格大於 n 才拒)
13. **RotateSigners 保留既有 signer 的 `signer_joined_at_ms`** → 透過 datum diff 確認
14. **Heartbeat 在 90 天速率限制內** → 拒絕(太快)
15. **Heartbeat 來自非成員** → 拒絕
16. **DistributeSignerCompensation 在 `distribute_period_ms` 前** → 拒絕
17. **DistributeSignerCompensation 當 `pool == 0`** → 拒絕
18. **DistributeSignerCompensation 所有 signer 不合格** → pool 全數 forfeit 進 audit reserve
19. **DistributeSignerCompensation 部分合格** → 正確的 per-signer + forfeit 金額
20. **nonce 單調性被破壞** → 拒絕(每個 redeemer 都偵測)

---

## 10. 延伸閱讀

- `spec/governance.md` — 公開動作目錄、timelock 規則、簽名者生命週期
- `spec/gov-nft.md` — 與簽名者輪替同時鑄造的 Gov Signer NFT
- `spec/treasury.md §3.3` — `ReceiveGovForfeit` redeemer 跨 validator 對應
- `spec/architecture.md §4` validator 表 — multisig_gov 在 12-validator V1 stack 中的位置(+3 個輔助 NFT policy)
- `docs/audit-scope.md §2.4` — multisig_gov 屬於 V1 特有內部審計範圍
- `docs/security-model.md §3.2、§3.5` — 治理被入侵的威脅模型
