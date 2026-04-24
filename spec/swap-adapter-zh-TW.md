# SwapAdapter 介面 — V1 多 DEX 擴充點

**狀態:** V1 啟動時只帶一個 adapter(`minswap_v2_adapter`)。上線後,**不需要重部署 V1、也不需要強迫存入者遷移**,可以透過治理 `UpdateRegistry`(14 天 timelock + 1-of-n cancel)把額外的 DEX adapter 部署 + 白名單化。

## 1. 動機

V1 的 DEX-swap 路徑(`vault_protocol.DeployToProtocol` 與其治理閘門版本 `vault_gov_emergency.AdminDeployNonDeposit`)必須 decode 目的 DEX 的 order datum,才能對 `minimum_receive` 做 trustless 的 peg-floor 檢查。不同 DEX 有不同 datum 格式(Minswap V2 用 Constr-tagged `OrderDatum` + `OrderStep` 模式;假設的 SundaeSwap V3 或 Splash 會用不同結構)。把每個 DEX decoder 全部寫死進 `vault_protocol`,會產生兩個問題:

1. **審計面膨脹**——每加一個 DEX 整合,就要把整個 `vault_protocol` validator 重新審計一次。
2. **遷移壓力**——上線後新增一個 DEX 要強制 V1.x 重部署 + 存入者遷移(燒掉舊 vUSDCx、存進新 vault),從 DeFi 歷史經驗看,每次遷移事件成本約 $50K-$80K + 幾個月 + 5-15% 的滯留資金。

SwapAdapter 模式把 DEX datum 解析拆成每個 DEX 各自的 validator,由治理透過白名單在 runtime 分派,解耦這兩個問題。

## 2. 架構

```
┌───────────────────────────────────┐
│ vault_protocol.DeployToProtocol   │
│ (或 vault_gov_emergency.          │
│  AdminDeployNonDeposit)           │
└────────────┬──────────────────────┘
             │  verify_swap_via_adapter(
             │    tx,
             │    registry.swap_adapter_hashes,
             │    registry.asset_oracles,
             │    ...
             │  )
             ▼
┌───────────────────────────────────┐
│ lib/vault/swap_adapter.ak         │
│  1. find_single_adapter_invocation│
│  2. read_adapter_redeemer         │
│  3. check_peg_floor               │
│  4. check_tier1_bound(選用)     │
└────────────┬──────────────────────┘
             │  透過 zero-withdrawal
             ▼
┌───────────────────────────────────┐
│ minswap_v2_adapter(Plutus V3)   │
│                                    │
│  withdraw(r: SwapAdapterRedeemer,  │
│           _: Credential,           │
│           tx: Transaction) {       │
│    1. 將 tx.outputs[r.idx] 按    │
│       Minswap V2 order datum decode│
│    2. 驗證 r.min_receive           │
│       == decoded minimum_receive   │
│    3. 驗證 r.target_asset          │
│       == decoded output asset      │
│  }                                 │
└───────────────────────────────────┘
```

## 3. SwapAdapterRedeemer

定義於 `lib/vault/swap_adapter.ak`:

```aiken
pub type SwapAdapterRedeemer {
  dest_output_idx: Int,
  min_receive: Int,
  hop_chain: List<(ByteArray, ByteArray)>,
}
```

- `dest_output_idx`——這個 adapter 正在驗證的 DEX order UTXO 在 `tx.outputs` 中的索引。
- `min_receive`——adapter 承諾的 `minimum_receive` 欄位(來自 order datum);vault_protocol 對此套 peg-floor。
- `hop_chain`——swap 會經過的資產序列:`[asset_in, mid_1, ..., target_out]`。Single-hop SwapExactIn 帶 2 項(`[in, out]`);N-hop SwapMultiRouting 帶 N+1 項,每個 pool 邊界一項。每一項是 `(policy_id, asset_name)`;ADA 為 `(#"", #"")`。目標資產(swap 產出的 token)是 `hop_chain[last]`;`vault_protocol` 透過 `last_hop_target` helper 將其暴露給 `asset_oracles` 的 Tier 1 查詢使用。

**為什麼用 hop_chain 而不用 target_asset(R74 F-1 修補)**:Minswap V2 order datum 中的 `lp_asset` 是**單一 LP-token 識別碼**(`[LP_policy, LP_name]`),**不是**雙資產 pair。光從 order datum 無法推出目標資產。Adapter 逐 hop 比對每個鏈上的 LP name,以 byte-for-byte 對應 `compute_lp_asset_name(chain[i], chain[i+1])` 的結果——把 routing 拓撲與端點資產都綁到承諾的 chain 上。被入侵的 keeper 因此不可能把資金路由到任意未白名單的 pool,因為 LP name 會對不上。完整 finding + fix 理由見 `v1/private/audits/r74-minswap-lp-formula-fix.md`。

## 4. Adapter 合約

SwapAdapter 是 PlutusV3 staking validator,只有一個 `withdraw` handler。被呼叫時:

1. 讀 `tx.outputs[redeemer.dest_output_idx]`。
2. 以該 DEX 專屬的格式知識,decode 那個 output 的 inline datum。
3. 驗證:
   - Datum 代表的是 **swap** order(不是 LP deposit / withdraw 之類)。
   - decoded `minimum_receive` 等於 `redeemer.min_receive`。
   - `redeemer.hop_chain` 結構完整(≥ 2 項,相鄰不重複)。
   - 對每個 routing hop(SwapMultiRouting)或單一 SwapExactIn 的 `lp_asset`,鏈上 LP name 對得上 `compute_lp_asset_name(chain[i], chain[i+1])`——其中 `compute_lp_asset_name` 是該 DEX 的 canonical LP-asset-name 公式。
4. 所有檢查通過才回傳 `True`。

任何一項失敗,ledger 會跑出 adapter 的 `withdraw → False`、TX revert,vault_protocol 永遠看不到 adapter success。

## 5. Caller 合約(vault_protocol + vault_gov_emergency)

一個 helper 呼叫就把所有驗證整合起來:

```aiken
verify_swap_via_adapter(
  tx,
  adapter_hashes,       // 來自 registry.swap_adapter_hashes
  asset_oracles,        // 來自 registry.asset_oracles
  expected_dest_idx,    // 來自 caller 自己的 redeemer(DeployToProtocol / AdminDeployNonDeposit)
  deploy_amount,
  min_swap_peg_bps,     // 來自 VaultDatum
  max_slippage_bps,     // 來自 VaultDatum
) -> Bool
```

內部流程:

1. 掃描 `tx.withdrawals`,找恰好一筆零金額 withdrawal、其 script hash 在 `adapter_hashes` 中。同一筆 TX 中多次 adapter 呼叫會被拒絕(anti-double-routing)。
2. 透過 `pairs.get_first(tx.redeemers, Withdraw(Script(adapter_hash)))` 讀取該 adapter 的 redeemer。
3. 驗證 `redeemer.dest_output_idx == expected_dest_idx`(防止多個並行 DEX output 的混淆)。
4. **Tier 2 peg-floor**(一律套用):`redeemer.min_receive × 10_000 ≥ deploy_amount × min_swap_peg_bps`。因為 adapter 已經驗證 `min_receive` 與鏈上 DEX datum 一致,這條界線是 trustless 的。
5. **Tier 1 oracle bound**(只有當 `asset_oracles` 中有對應 `(target_asset_policy, target_asset_name)` 項目時才套用):`redeemer.min_receive ≥ fair_out × (10_000 − max_slippage_bps) / 10_000`,其中 `fair_out = deploy_amount × oracle_fair_price_bps / 10_000`。V1 啟動時 `asset_oracles = []`,Tier 1 處於休眠,直到治理填入各資產的 oracle 設定。

## 6. Registry 白名單

`RegistryDatum.swap_adapter_hashes: List<ByteArray>` 存授權的 adapter script hash。

- **上限**:10 個 adapter 條目(見 `registry.ak`)。
- **格式**:每一項精準 28 bytes(Plutus V3 script hash 長度)。
- **唯一性**:不允許重複。
- **更新路徑**:`UpdateRegistry` redeemer,14 天 timelock + 1-of-n cancel 否決。在 `KeeperToggleMarket` + `FastUpdateMarkets` 中 bit-for-bit 保留。

V1 啟動時恰好只有一個條目:`minswap_v2_adapter` 的 script hash(部署時從 `plutus.json` 計算)。

## 7. 新增 DEX adapter(上線後的生命週期)

1. **開發**一個新的 `*_adapter.ak` validator,遵循 adapter 合約(§4)。
2. **審計** adapter 本身——caller(`vault_protocol`)不知道該 DEX 的內部細節,所以審計範圍只有 adapter 的 datum decoder + assertion。成本估算:每個 DEX 約 $10K-$20K。
3. **Preprod E2E**:在 Preprod 上的目標 DEX 送出真實 order,驗證 adapter decode 正確、peg-floor 能正確拒絕惡意 `minimum_receive` 企圖。
4. **部署** 審計過的 adapter reference script 到 mainnet(Cardano stake script 押金 2 ADA + 依 adapter 大小約 25-40 ADA 的 per-byte ref-script min-ADA)。
5. **治理 queue**:送出 `UpdateRegistry`,其中 `new_reg.swap_adapter_hashes = reg.swap_adapter_hashes ++ [new_adapter_hash]`。這會觸發 14 天 timelock。
6. **觀察窗**:社群 + n 位治理簽名者中的任一位,都可以在 timelock 期間 cancel 該 queued 動作。任何不認可新 adapter 的存入者,可以在 14 天窗口內退場。
7. **治理 execute**:timelock 過後 registry UTxO 被更新、新 adapter 啟用。Keeper 可以透過它 routing;V1 金庫地址與既有 vUSDCx 持有不變。

## 8. 安全屬性

**Adapter 治理 NOT 能做的事**:

- 繞過 Tier 2 peg-floor——`verify_swap_via_adapter` 永遠對 adapter 承諾的 `min_receive` 套用它。
- 路由到 `registry.protocol_hashes` 以外的 script——`verify_destination_whitelisted` 仍獨立套用。
- 把金庫資金 drain 到任意地址——adapter 的 `withdraw` handler 只驗證 swap datum、並不花費 vault UTXO;所有 value 移動都透過 `vault_protocol.DeployToProtocol` 自己的 token-preservation 檢查。

**Adapter 治理 CAN 做的事**(威脅模型):

- 核准一個對 `min_receive` 說謊的惡意 adapter——對任意 `SwapAdapterRedeemer` 都回傳 `True` 的 adapter 會繞過 Tier 2。**緩解**:adapter 原始碼開放 + 可透過 script hash 做鏈上審視;治理簽名者是公開身份的 m-of-n;14 天 timelock + 1-of-n cancel 給存入者退場時間。
- 把 `minswap_v2_adapter` 從白名單移除——會停掉 Minswap V2 路由。**緩解**:立即可見;存入者可在 14 天觀察窗內退場;1-of-n cancel。

## 9. 上 mainnet 前的驗證檢查表

Mainnet 部署前必做(納入 V1 外部審計範圍追蹤):

- [ ] Preprod 上送真實 Minswap V2 `SwapExactIn` order → `extract_minswap_v2_order` 正確 decode `minimum_receive` + 目標資產。
- [ ] Preprod 上送真實 Minswap V2 `SwapMultiRouting` order → 正確 decode 最後一 hop 的目標資產。
- [ ] 送一筆 `min_receive = 1` 的構造 order → `verify_swap_via_adapter` 透過 peg-floor 拒絕。
- [ ] 同一筆 TX 同時觸發兩個 adapter 呼叫 → `find_single_adapter_invocation` 拒絕(`count != 1`)。
- [ ] 送一筆 adapter hash 未白名單的呼叫 → 被拒。
- [ ] 治理 `UpdateRegistry` 加一個 mock 第二 adapter → 觀察 14 天 timelock → execute 成功 → 第二 adapter 可被呼叫。
- [ ] 治理 `UpdateRegistry` 移除 `minswap_v2_adapter` → 後續 DeployToProtocol revert。

## 10. V1 不支援的事

- **自動化 adapter 註冊**。V1 要求每個新 adapter 都經人類治理審視。Permissionless adapter 註冊(任何人部署立刻可用)需要更精細的信任框架,延後到 V2+。
- **Adapter 版本化**。若 Minswap V3 帶新 datum 格式,operator 部署 `minswap_v3_adapter` 作為獨立 validator,由治理白名單化。舊的 `minswap_v2_adapter` 仍在名單上(處理 legacy V2 routes)或被移除(乾淨切換)。**沒有** adapter 內部版本升級機制。
- **Adapter 內部 cost bound**。每個 adapter 設定自己的計算預算。V1 靠 ledger 的 evaluation limit 防止失控執行;**沒有**跨 adapter 的預算強制。

## 11. 參考

- 程式:`lib/vault/swap_adapter.ak`、`validators/minswap_v2_adapter.ak`
- 白皮書:§3.4 外部依賴(多 DEX 擴充性)、§5.3 DEX 滑點保護(Tier 2 peg-floor + Tier 1 oracle)
- Spec:`spec/architecture.md §3.6`(Registry 結構)、§4(validator 目錄)
- 相關:`spec/oracle.md`(adapter caller 使用的 Tier 1 oracle 讀取器)
