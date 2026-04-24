# OptiVaults V1 — VaultDatum 規格

**範圍**:存放所有 vault 會計狀態的單一 UTxO datum。

---

## 1. 結構

```aiken
type VaultDatum {
  // --- 會計狀態(在特定 redeemer 下可變) ---
  total_deposited: Int,           // USDCx 總本金 + 累積收益(6 位小數)
  total_shares: Int,              // vUSDCx 總供給
  idle_buffer: Int,               // 尚未部署、留在 vault 地址的 USDCx
  non_deposit_value: Int,         // 金庫中非存入穩定幣(DJED、USDM)的價值(以 deposit token 單位計)
  last_compound_time: Int,        // POSIX 毫秒,Compound cooldown 錨點
  last_realloc_time: Int,         // POSIX 毫秒,reallocation cooldown 錨點
  last_fee_update_time: Int,      // POSIX 毫秒,UpdateFee 7 天 cooldown 錨點
  last_ada_swap_time: Int,     // POSIX 毫秒,SwapAda cooldown 錨點(見 spec/ada-swap.md)
  strategy_allocations: List<Allocation>,  // 每個協議的目標配置
  liqwid_positions: List<LiqwidPosition>,  // 每個市場的 Liqwid 持倉

  // --- 政策參數(在治理 redeemer 下可調) ---
  performance_fee_bps: Int,       // 績效費 bps,[0, 450]
  early_withdraw_fee_bps: Int,    // Early withdrawal fee bps
  min_hold_seconds: Int,          // Compound 後到 Direct Withdraw 間的最短持有時間
  buffer_target_bps: Int,         // 目標 buffer 比例(3500 = 35%)
  keeper_fee_bps: Int,            // Keeper 的績效費分成,[0, 2500]
  gov_fee_bps: Int,               // 治理簽名者池分成,[0, 1000]
                                   // Treasury 分成為推導值:10000 - keeper_fee_bps - gov_fee_bps

  // --- 不可變的身份參數 ---
  vault_version: Int,             // V1 = 1;debug + 版本閘控鏈下工具用
  governance_policy: ByteArray,   // 治理 NFT policy ID
  governance_name: ByteArray,     // 治理 NFT asset name
  deposit_token_policy: ByteArray,  // USDCx policy ID
  deposit_token_name: ByteArray,    // USDCx asset name("USDCx")
  vusdcx_policy: ByteArray,         // vUSDCx minting policy hash
  order_script_hash: ByteArray,   // Order validator hash(BatchProcess 授權用)
  registry_hash: ByteArray,       // Registry validator hash
  registry_auth_policy: ByteArray,  // Registry auth NFT policy

  // --- 運營旗標 ---
  frozen: Int,                    // 0 = 正常、1 = 緊急凍結
}
```

**總欄位數**:26(新增 `last_ada_swap_time` 給 SwapAda redeemer——見 `spec/ada-swap.md`)。**不可變**(部署後永不變):**9**(8 個身份錨點 + `vault_version`)。**治理可變**(在邊界內可被治理動作調整):**6**(`performance_fee_bps`、`early_withdraw_fee_bps`、`min_hold_seconds`、`buffer_target_bps`、`keeper_fee_bps`、`gov_fee_bps`;`strategy_allocations` 另外是治理可設定的,屬獨立 action)。**運營可變**(每次 keeper / user 動作可變):10 個會計欄位(`total_deposited`、`total_shares`、`idle_buffer`、`non_deposit_value`、4 個時間錨點、`strategy_allocations`、`liqwid_positions`)以及 `frozen` 旗標。

數字對帳:9 不可變 + 6 政策 + 10 會計 + 1 運營 = 26 ✓。本 spec 較早草稿誤植為「13 個不可變」——那是把 9 個真正不可變的欄位 + 4 個在內部驗證期 compile-time-anchor 重構中**從 datum 搬到 `vault_proxy` / `vusdcx` / `order` 編譯時參數**的舊欄位也計算進去。實際存在 datum 內的不可變欄位是 9。

V1 有**兩個**身份錨點刻意**不**放進 datum:

- **Keeper 授權**:**沒有** `keeper_pkh` 欄位。Keeper 授權委派給 `keeper_stake_script` staking validator;stake-script hash 是 `vault_user`、`vault_keeper_hot`、`vault_protocol`、`vault_recall`、`vault_liqwid` 的編譯時參數(並間接透過 `vault_proxy` 的 Withdraw-Zero route table)。變更授權 keeper 集合發生在 stake script 自己的 datum 裡,不會動到 VaultDatum。
- **Fee collector**:**沒有** `fee_collector` 欄位。績效費流向 `treasury` script 地址;treasury-script hash 是 `vault_keeper_hot`(Phase-77 後 Compound 的新家)的編譯時參數,在 Compound redeemer 的 fee-output binding 中檢查。

把這兩個錨點搬到編譯時參數,提供了**比 datum 欄位更嚴格**的信任屬性——控制了惡意 datum 的攻擊者**無法**替換 keeper 或 fee 收件方,因為 validator 會忽略 datum、直接從自己的 script hash 查死寫好的值。

---

## 2. 逐欄位說明

### 2.1 會計狀態

| 欄位 | 型別 | 意義 | 不變量 |
|------|------|------|-------|
| `total_deposited` | Int | 金庫認列的累積 deposit-token 本金 + 累積收益。以 deposit token 單位(USDCx = 6 位小數)。 | `total_shares > 0` 時 `total_deposited > 0` |
| `total_shares` | Int | 流通中的 vUSDCx 總量。 | `total_shares >= 0`;`total_shares == 0` 當且僅當 `total_deposited == 0` |
| `idle_buffer` | Int | 留在 vault 地址、尚未部署到收益來源的 deposit-token。 | `idle_buffer >= 0`;`idle_buffer <= total_deposited + non_deposit_value + Σ liqwid_principal`(合法會計上限) |
| `non_deposit_value` | Int | 金庫中 registry 白名單的非存入穩定幣價值,以 deposit-token 單位 1:1 計價。只在 DeployToProtocol / RecallFromProtocol / MergeUtxo 過程中,由 registry 白名單 token 轉移改動。 | `non_deposit_value >= 0` |
| `last_compound_time` | Int | 上次 Compound 執行的 POSIX 毫秒。 | Compound redeemer 下必須單調推進;寫入值 `≤ tx.validity_range.upper`、且寬度上限 `upper - lower ≤ 1h` |
| `last_realloc_time` | Int | 上次 zero-yield Compound(純 allocation 更新)的 POSIX 毫秒。 | 同 `last_compound_time` 的不變量 |
| `last_fee_update_time` | Int | 上次 UpdateFee 治理動作的 POSIX 毫秒。 | UpdateFee 動作之間最少 7 天 cooldown |
| `last_ada_swap_time` | Int | 上次 `SwapAda` 執行的 POSIX 毫秒。限制 keeper ADA 補充頻率(見 `spec/ada-swap.md`)。 | SwapAda 呼叫之間最少 1 小時 cooldown;寫入值 `≤ tx.validity_range.upper`、寬度上限 `upper - lower ≤ 1h` |
| `strategy_allocations` | List<Allocation> | 每個協議的目標配置——資本應如何分配。每項包含 `protocol_name`(enum:`Liqwid`、`MinswapLP`、`SundaeSwapLP`)+ `amount` + `expected_apy_bps`。 | 長度 ≤ 10;`Σ amount + idle_buffer <= total_deposited + non_deposit_value + Σ liqwid_principal` |
| `liqwid_positions` | List<LiqwidPosition> | 每個 Liqwid 市場的持倉。每項 = `{market_id, qtokens_held, supplied_value}`。 | 長度 ≤ 5;`qtokens_held > 0` 代表該部位存在;`supplied_value == 0` 代表已完全 recall |

### 2.2 政策參數

| 欄位 | 型別 | V1 啟動值 | 治理可調範圍 | 透過誰調整 |
|------|------|-----------|--------------|-----------|
| `performance_fee_bps` | Int | 450(4.5%) | [0, 450]——4.5% 硬上限在 UpdateFee redeemer 強制 | `UpdateFee` 治理動作 |
| `early_withdraw_fee_bps` | Int | 10(0.1%) | [0, 100] | `UpdateFee` 治理動作 |
| `min_hold_seconds` | Int | 60 | [0, 21600](6 小時)——從較早的 24 小時上限依白皮書 review 收緊(理由見白皮書 §2.4 + §6.3) | `UpdateFee` 治理動作 |
| `buffer_target_bps` | Int | 3500(35%) | [0, 10000]——建議目標,不嚴格強制 | `UpdateStrategy` 治理動作(與配置變更一起執行) |
| `keeper_fee_bps` | Int | 2000(20%) | [0, 2500]——25% 硬上限;與 `gov_fee_bps` 合計 ≤ 3000(30%) | `UpdateFeeSplit` 治理動作(21 天 timelock) |
| `gov_fee_bps` | Int | 0(啟動時停用) | [0, 1000]——10% 硬上限 | `UpdateFeeSplit` 治理動作(21 天 timelock) |

`performance_fee_bps` 4.5% 硬上限是合約層不變量,在 UpdateFee redeemer 強制——**治理在任何 redeemer 路徑下都無法**把費率推過 4.5%。這與「4.5% 是目前值」是兩回事:欄位在 [0, 450] 內可變,但不能超過 450 bps。

3-way 績效費拆分(keeper / 治理池 / treasury)在 Compound 時強制。Treasury 份額**不存 datum**——以 `10000 - keeper_fee_bps - gov_fee_bps` 推導。`vault_gov_policy.ak` 的 UpdateFeeSplit redeemer 透過共用的 `validate_update_fee_split` helper 強制以下硬性不變量:

- `0 <= keeper_fee_bps <= 2500`(keeper ≤ 25%)
- `0 <= gov_fee_bps <= 1000`(gov pool ≤ 10%)
- `keeper_fee_bps + gov_fee_bps <= 3000`(treasury 下限 ≥ 70%)

分階段啟動路線(治理可在上限內調整、每次變更套 21 天 timelock):

| 階段 | keeper_fee_bps | gov_fee_bps | Treasury | 啟用條件 |
|------|----------------|-------------|----------|---------|
| V1 啟動 | 2000(20%) | 0(0%) | 80% | 部署預設;gov pool 停用;啟動簽名者無支付 |
| Phase 2 | 2000 | 500(5%) | 75% | 需要:(a) TVL ≥ 500K USDCx **且** (b) 治理已透過 `RotateSigners` 加入至少一位外部(與創辦人無關聯)簽名者。治理再以 `UpdateFeeSplit` 啟用——無自動晉升。 |
| Phase 3 | 2000 | 1000(10%) | 70% | 需要:(a) TVL ≥ 2M USDCx **且** (b) 治理已透過 `RotateSigners` 納入至少一位社群選出的簽名者。治理再以 `UpdateFeeSplit` 啟用。 |

**啟用並非自動**。每個階段轉換都需要明確的治理 `UpdateFeeSplit` 動作(帶各自的 21 天 timelock)。TVL + 簽名者集合前置條件是治理在 queue 前**鏈下**做的政策閘門,合約**不強制**。Validator 只強制硬上限(`keeper_fee_bps ≤ 2500`、`gov_fee_bps ≤ 1000`、`sum ≤ 3000`)。一個在 TVL 100K 時 queue 把 gov_fee_bps 推到 500(違反 Phase 2 TVL 閘門作為政策)的治理,**只要**硬上限有滿足,**鏈上仍會成功**——是鏈下的敘事紀律讓分階段模型有意義。

每次 fee-split 變更都是獨立的 `UpdateFeeSplit` 治理動作,帶完整 21 天 timelock + 1-of-n cancel 否決。變更從**下次** Compound 之後才適用——已累積的 gov pool 資金保留先前的處理方式,直到分配。

### 2.3 身份參數(不可變)

| 欄位 | 值 | 用途 |
|------|------|------|
| `vault_version` | 1 | V1 識別碼。在 V1 小版本升級(V1.x)間**不變**;要重新定義 vault 架構的 V2 fresh deploy 才會遞增到 2。 |
| `governance_policy`、`governance_name` | (部署時設定) | 治理 NFT 身份。治理授權需要 TX 中花費一個帶該 NFT 的 UTxO。 |
| `deposit_token_policy`、`deposit_token_name` | Mainnet 上為 USDCx | 存入代幣身份。 |
| `vusdcx_policy` | (部署時設定) | vUSDCx minting policy。 |
| `order_script_hash` | (部署時設定) | Order validator hash。BatchProcess 要求所有被消費的 Order UTxO 地址 hash 相符。 |
| `registry_hash` | (部署時設定) | Registry validator hash。DeployToProtocol / RecallFromProtocol 把 Registry UTxO 當 reference input 讀,地址必須 match。 |
| `registry_auth_policy` | (部署時設定) | Registry auth NFT policy。Registry UTxO 必須帶此 policy 的 token 才被信任。 |

### 2.4 運營旗標

| 欄位 | 值 | `= 1` 時的效果 |
|------|------|---------------|
| `frozen` | 0(正常)/ 1(凍結) | 擋掉 Compound、BatchProcess、RebalanceBuffer、DeployToProtocol、SupplyToLiqwid、SwapAda。**不**擋 Withdraw、RecallFromLiqwid、RecallFromProtocol、MergeUtxo、AdminDeployNonDeposit、EmergencyWithdraw(資金回收與治理閘控的清理路徑仍開放)。透過 `EmergencyWithdraw` 治理動作設為 1。 |

---

## 3. 每個 redeemer 都會檢查的不變量

所有會動 datum 的 redeemer 都必須保留以下不變量(由 `lib/vault/validation.ak` 強制):

1. **不可變欄位保留**:9 個不可變欄位(8 身份錨點 + `vault_version`)在輸入與輸出 datum 之間必須 bit-identical。
2. **會計值非負**:`total_shares >= 0`、`total_deposited >= 0`、`idle_buffer >= 0`、`non_deposit_value >= 0`。
3. **份額供給一致性**:`total_shares == 0` 當且僅當 `total_deposited == 0`。(零份額 vault 只能收第一筆存款;有未了結份額但本金為零的 vault 是**不合法**狀態。)
4. **Allocation 上限**:`(Σ strategy_allocations.amount) + idle_buffer <= total_deposited + non_deposit_value + Σ liqwid_position.supplied_value`。
5. **Allocation 最大數量**:`len(strategy_allocations) <= 10`。
6. **Liqwid 部位最大數量**:`len(liqwid_positions) <= 5`。
7. **不可變 policy 保留**:vault UTxO output 必須保留 Vault Identity NFT(一份、正確 policy、正確 asset name)。
8. **不允許未授權 mint**:Deposit / Withdraw / BatchProcess 以外的 redeemer 明確強制 `tx.mint` 為空;收益流不涉 mint / burn。
9. **Token 保留**:input vault UTxO 持有的每個 token 類型,必須以 ≥ input 的數量出現在 output 中——淨效果等於 input 減任何明確花費的量(例如 DeployToProtocol 會從 `deposit_token_policy` 扣 `deposit_amount`)。
10. **單一 vault input**:除 `MergeUtxo` 外,TX 中在 vault 地址只能有**恰好一個** input UTxO。
11. **Validity range 寬度上限**:寫入時間錨定欄位(`last_compound_time`、`last_realloc_time`、`last_fee_update_time`、`last_ada_swap_time`)的 redeemer,TX validity range 寬度必須 ≤ 1 小時,防止長窗口 timestamp 操弄。

---

## 4. 各 redeemer 的狀態轉移

下表列出每個 redeemer 可以動哪些欄位。`=` 代表「必須等於 input」;`Δ` 代表「可能變動,受該 redeemer 自身不變量約束」。

| Redeemer | total_deposited | total_shares | idle_buffer | non_deposit_value | 時間錨點 | strategy_allocations | liqwid_positions | frozen |
|----------|-----------------|--------------|-------------|-------------------|---------|----------------------|------------------|--------|
| Deposit | Δ(+) | Δ(+) | Δ(+) | = | = | = | = | = |
| Withdraw | Δ(−) | Δ(−) | Δ(−) | = | = | = | = | = |
| BatchProcess | Δ | Δ | Δ | = | = | = | = | = |
| Compound(buffer-funded) | Δ(+) | = | Δ(−) | Δ | Δ last_compound_time、last_realloc_time | = | Δ | = |
| Compound(zero-yield) | = | = | = | = | 只 Δ last_realloc_time | Δ | = | = |
| RebalanceBuffer | = | = | Δ | = | Δ last_realloc_time | Δ | = | = |
| DeployToProtocol | = | = | Δ(−) | Δ(+ stable) | = | Δ | = | = |
| RecallFromProtocol | = | = | Δ(若為 deposit token + ) | Δ(−) | = | Δ | = | = |
| SupplyToLiqwid | = | = | Δ(若為 deposit,−)或 Δ(非 deposit,−) | Δ(若為非 deposit,−) | = | = | Δ(+) | = |
| RecallFromLiqwid | = | = | Δ(+) | = | = | = | Δ(−) | = |
| MergeUtxo | = | = | Δ(+) | Δ(+) | = | = | = | = |
| UpdateStrategy | = | = | = | = | = | Δ | = | = |
| UpdateFee | = | = | = | = | Δ last_fee_update_time | = | = | = |
| UpdateFeeSplit | = | = | = | = | Δ last_fee_update_time | = | = | = |
| EmergencyWithdraw | = | = | Δ | = | = | Δ 清空 | Δ 清空 | Δ(0 或 1) |
| AdminDeployNonDeposit | = | = | = | Δ(−) | = | = | = | = |
| SwapAda | = | = | Δ(−) | = | Δ last_ada_swap_time | = | = | = |

任何未列出、或標 `=` 的欄位,輸入與輸出 datum 必須 bit-identical。違反本表 `=` 欄的任何 mutating redeemer,validator 會拒絕。

---

## 5. 從內部驗證期遷移(internal-verification phase)

從內部驗證期遷移到 V1 的存入者,經歷的是**帳戶重置**:從內部驗證期 vault(UTxO 在 `addr1w9rlrur3ks0jplf8zsnk66vhfe4s8a2yn02jhut9wl9e4jg3r3lt3`)提領 USDCx、再存進 V1 vault(V1 的 `vault_proxy` 新地址,V1 mainnet 啟動時公告)。**不會**自動帶過去任何會計——V1 vault 從 `total_deposited = 0`、`total_shares = 0` 起步。

完整遷移協議見 `docs/migration.md`。給存入者的重點:

1. 內部驗證期在整個 V1 啟動期間持續運作
2. 內部驗證期 sunset 至少提前 30 天公告
3. 從內部驗證期的 Direct Withdraw 持續可用;keeper 停擺 7 天後(sunset 時刻意觸發),early-withdraw fee 自動免除
4. 最後一位存入者退場後,內部驗證期的 vault UTxO 被銷毀

**沒有**從內部驗證期到 V1 的原地升級路徑——Cardano 合約不可變使這結構上不可能。新的合約面,唯一選項就是 fresh deploy。
