# OptiVaults V1 — 架構

**狀態**:V1 設計規格
**對象**:協議審計者、智能合約開發者、整合者、具技術素養的存入者

---

## 1. 一段話說明產品

OptiVaults V1 是 Cardano 上的非託管、鏈上自動複利穩定幣金庫。存入者鎖進 USDCx,拿到 vUSDCx 份額代幣(按存入比例)。一個自動化 keeper 透過 Minswap V2 routing 把匯集的資本部署到 Liqwid Finance 穩定幣借貸市場(DJED、USDM),鏈上收割收益,再把它複利回 vault 會計,讓 share price 隨時間上升。所有影響本金的操作——存款、提款、份額鑄造、收益計算、費用抽取、協議 routing——都由 Aiken PlutusV3 智能合約驗證。**協議 operator 在任何 redeemer 路徑下都無法提走使用者本金**。

V1 是第一個公開上線版本。Cardano mainnet 上有一個面對使用者的 vault 實例,operator 自律執行 100,000 USDCx 的 TVL 上限,直到第三方審計完成;屆時上限時程會在審計報告中公開。

---

## 2. Actor

五個不同的 actor 與 V1 協議互動。角色分離在**可能的地方**由合約強制;**不能由合約強制的地方**在 `docs/security-model.md` 以誠實的人類控制者地圖揭露。

| Actor | 角色 | 授權來源 |
|-------|------|---------|
| **存入者** | 存入 USDCx、收 vUSDCx;之後燒 vUSDCx 提取 USDCx + 累積收益 | 任一 CIP-30 錢包簽名 |
| **Keeper** | 執行自動化:compound、batch-process orders、在 buffer 與 Liqwid 市場間移動資本、透過 Minswap V2 routing | 擁有一個 PKH 列在 `keeper_stake_script` 授權 datum 中的錢包 |
| **治理(MultisigGov)** | 設策略、在 `[0, 450]` bps 內調績效費(4.5% 上限**不可變**——治理可以往下降、但不能推過上限)、緊急凍結、輪替 keeper 集合、動用 treasury、輪替治理簽名者 | 對鏈上 `MultisigGov` validator 的 m-of-n 門檻簽名(啟動時 3-of-3 全員同意、隨 TVL 分階段到 4-of-5、5-of-7——見 V1 白皮書 §6.1) |
| **Treasury** | 協議費份額的被動累積器;分類別;治理支出帶 timelock | 無直接 actor——完全由治理對 `treasury` validator 的 redeemer 控制 |
| **第三方合約** | Liqwid action validator 與 pool shard(qToken mint/burn)、Minswap V2 swap order(USDCx ↔ DJED/USDM routing) | 不在 OptiVaults 控制下;它們的正確性是文件化在 `docs/security-model.md` 的信任假設 |

---

## 3. 鏈上狀態

V1 在 Cardano 上以四個不同 UTxO 類別維護狀態。每個類別在任一時刻都有單一 canonical UTxO(例外:Order UTxO 可能有多筆)。

### 3.1 Vault UTxO

`vault_proxy` script 地址上的單一 UTxO,以 one-shot 的 **Vault Identity NFT** 標記。內容:

- 尚未部署到收益來源的閒置 USDCx(「buffer」)
- 金庫地址上介於 swap 與 Liqwid supply 之間暫存的非存入穩定幣部位(DJED / USDM)
- Liqwid 部位的 qToken 收據
- 會計 datum(`VaultDatum`,29 個欄位——見 `spec/vault-datum.md`)
- 小量 ADA 餘額,覆蓋 min-UTXO 需求與 DEX order 資金

Vault NFT 提供**編譯時信任錨點**:`vault_proxy`、`vusdcx`、`order` 三個 validator 都把 Vault NFT 的 minting policy 燒進自己的 script hash。在 `vault_proxy` 地址但**沒有** Vault NFT 的 UTxO,**不是**合法 vault、也不可能被任何 validator 誤認。

### 3.2 Treasury UTxO

`treasury` script 地址上的單一 UTxO。內容:

- V1 啟動以來累積的協議費 USDCx,分為四個 balance 欄位
- 會計 datum(`TreasuryDatum`——見 `spec/treasury.md`)
- UTxO 必要的 min-ADA

類別桶:

| 桶 | Inflow 份額 | 用途 | 支出閘控 |
|----|-----------|------|---------|
| Audit reserve | 40% | 累積以覆蓋定期第三方審計 | 治理閘控;提案需帶 `audit_invoice_ref` |
| Operations | 25% | 平台層基礎設施(前端 / landing / API 用 VPS、Blockfrost 平台查詢、監控、網域、CDN);個別 keeper 自己的基礎設施改由每筆 Compound 的 40% keeper 份額直接吸收,不再走這個 bucket | 治理閘控、各類別 24h cooldown |
| R&D | 25% | 協議開發、未來的 bounty 計畫(post-audit + TVL-scale,依 `docs/audit-scope.md §6.3`)、生態補助 | 治理閘控、各類別 24h cooldown |
| Buffer | 10% | 預期外支出、法律、事件應變 | 治理閘控、各類別 24h cooldown |

類別比例**治理可調**(每類別在 [0%, 50%]、總和剛好 100%、更新 cooldown 180 天)。

### 3.3 治理 UTxO

`multisig_gov` script 地址上的單一 UTxO,以 one-shot 的 **Governance NFT** 標記。內容:

- 治理簽名者集合 + 門檻
- 帶 timelock 時間戳的 queued action 提案
- 輪替 cooldown 計時
- 治理會計 datum(`GovDatum`——見 `spec/governance.md`)

### 3.4 Order UTxO(多筆)

使用者的每筆存款或提款 order 在 `order` script 地址建立一個 transient UTxO。內容:

- 使用者存進的 USDCx(DepositOrder)或他們的 vUSDCx(WithdrawOrder)
- 使用者 owner 地址(退款與 payout routing)
- 使用者指定的 `max_batcher_tip`(keeper 補償的 ADA 上限)
- `expires_at` 時間戳(建立後 24 小時)
- 會計 datum(`OrderDatum`——見 `spec/order-batch.md`)

Order UTxO 由 keeper 在批次 TX 中處理,或透過 `Cancel`(owner 簽名)或 `Expire`(過期後任何人都能觸發)退款。

### 3.5 Keeper stake validator

`keeper_stake_script` 是 Cardano staking validator,持有 keeper 動作的授權規則。其 stake credential 在鏈上註冊。Vault validator 中的 keeper 授權檢查表達為「本 TX 對 `keeper_stake_script` 的 stake credential 帶一筆 zero-withdraw」,把授權決定委派給 stake validator 的 redeemer。

此 stake validator 有三個模式,以自己 datum 追蹤:

| 模式 | 誰可以 withdraw(即,成為 keeper) | 啟動狀態 |
|------|-----------------------------------|----------|
| `GovernanceOnly` | PKH 在 `authorized_pkhs` 列表中、由治理管理 | **V1 啟動模式** |
| `PermissionlessWithBond` | 任何人發 ADA 保證金(bond_amount 由治理設);經證明違規時保證金可被 slash | 透過治理模式切換動作啟用,**不用**合約遷移 |
| `Mixed` | `authorized_pkhs` **或** 發保證金者;漸進轉換用 | 透過治理模式切換動作啟用 |

切換模式需要治理動作 + 標準 7 天 timelock。從 `GovernanceOnly` 切到 `PermissionlessWithBond` 是**單一鏈上事件、不需要重部署合約**——vault validator 只關心本 TX 是否對 `keeper_stake_script` 有 zero-withdraw;stake script 的內部規則在治理下可演進。

### 3.6 Registry UTxO

`registry` script 地址上的單一 UTxO,以 auth NFT 標記。持有合法的協議目的地白名單(Liqwid action-validator hash、Minswap V2 stake credential)、穩定幣白名單、Liqwid 市場 metadata,以及 **asset oracles**(§5.4 P3,2026-04-22)——每資產的 dual-feed oracle 設定列表,供 `DeployToProtocol` peg-floor(P4)與 `SwapAda` 公平價(P5)檢查使用。由治理透過 14 天 timelock 的 `UpdateRegistry` 更新;Liqwid 遷移響應可以透過 1 小時 timelock 的 `FastUpdateMarkets` 走快速路徑。`asset_oracles` **只能透過** `UpdateRegistry` 改——`KeeperToggleMarket` 與 `FastUpdateMarkets` 會 bit-for-bit 保留它。

`asset_oracles` list 持有 `AssetOracleEntry` 值,把每個定價資產釘到:

- `feeds: List<AssetOracleFeed>`——通常 2 項(一個 Charli3 feed、一個 Orcfax feed),每項以 reference-UTXO `(feed_script_hash, feed_auth_policy, feed_auth_name)` 三元組標定。Auth NFT 防止同 script 地址的誘餌 UTxO。
- `max_disagreement_bps`——跨 feed 價差上限。超過就讀取失敗。
- `max_staleness_ms`——各 feed 相對 `tx.validity_range.lower_bound` 的年齡上限。過期 feed 從聚合中被丟棄。
- `min_feeds`——返回公平價所需的最低健康 feed 數。V1 dual-feed 條目為 2(兩個 feed 必須在邊界內同意)。

Feed datum 格式(feed UTxO 上的 InlineDatum):`PriceSample { price_bps: Int, timestamp_ms: Int }`。鏈下 oracle operator 把 native Charli3 + Orcfax feed 聚合成這個 canonical 格式——operator 身份是 `spec/security-model.md` 中文件化的外部信任邊界。V1 啟動時 `asset_oracles = []`,隨著每資產的 dual-feed 覆蓋上線(先 DJED + USDM + ADA,再加任何新的 Liqwid market),透過治理 `UpdateRegistry` 填入。

---

## 4. 合約目錄

V1 出廠時帶 **17 個 logic validator + 4 個 NFT mint policy + 1 個 DEX adapter(`minswap_v2_adapter`)= 共 22 個編譯 artefact**(canonical 數字,跨白皮書 §3.1、README size 表、`audit-scope.md §6` scope 聲明一致)。全部是 Aiken PlutusV3;編譯大小記在 `README.md`。切分理由(四條正交軸:授權邊界、治理反應延遲、bytecode-cost-center、size 修正)見下方 §4.1。

| # | Validator | 角色 | 授權模型 |
|---|-----------|------|---------|
| 1 | `vault_proxy` | 持有 vault UTxO 的薄 spending validator;透過 zero-withdraw forward 邏輯到 staking validator | 編譯時參數化:(user、keeper_hot、swap_ada、protocol、recall、liqwid、gov_policy、gov_emergency、admin_deploy、batcher 的 stake_hashes + vault_nft_policy)——11 params、10 routes |
| 2 | `vault_user` | Staking validator:Deposit、Withdraw、CommunitySunset——permissionless 使用者路徑(BatchProcess 由獨立的 `vault_batcher` validator 承擔)。CommunitySunset 是 Phase 1 dead-man-switch;見 `governance.md` §4.4.1。 | 編譯時參數化:(governance_nft_policy、governance_nft_name)——`keeper_stake_hash` 不再需要,因為三個 redeemer 都是 permissionless。CommunitySunset 由任何 vUSDCx 持有者觸發,前提是 `max(last_compound_time, last_realloc_time) + 90d ≤ now`。`publish` handler 由 ActDeregisterStake(A2)閘控。 |
| 3 | `vault_keeper_hot` | Staking validator:Compound、RebalanceBuffer、SwapAda——keeper 熱路徑 | 編譯時參數化:(keeper_stake_hash、treasury_hash、governance_nft_policy、governance_nft_name);三個 redeemer 全走 keeper_stake_script zero-withdraw keeper 授權;`publish` handler 由 ActDeregisterStake(A2)閘控 |
| 4 | `vault_protocol` | Staking validator:DeployToProtocol(DEX,透過 SwapAdapter 分派) | 編譯時參數化:(keeper_stake_hash、governance_nft_policy、governance_nft_name);僅 keeper 授權;`verify_swap_via_adapter`(來自 `lib/vault/swap_adapter.ak`)整合 adapter 呼叫 + Tier 2 peg-floor + 選用 Tier 1 oracle bound;`publish` handler 由 A2 閘控 |
| 5 | `vault_recall` | Staking validator:RecallFromProtocol、MergeUtxo | 編譯時參數化:(keeper_stake_hash、governance_nft_policy、governance_nft_name);keeper-with-fallback(keeper 停擺 7 天後治理介入);`publish` handler 由 A2 閘控 |
| 6 | `vault_gov_policy` | Staking validator:UpdateStrategy(7d)、UpdateFee(14d)、UpdateFeeSplit(21d)、UpdateSlippagePolicy(48h)——慢速審慎的政策變更 | 編譯時參數化:(governance_nft_policy、governance_nft_name)供 A2 `publish` handler;`withdraw` 透過 MultisigGov 的 spent input 授權 |
| 7 | `vault_gov_emergency` | Staking validator:EmergencyWithdraw(0d)、AdminDeployNonDeposit(7d keeper 停擺 + 21d registry 穩定)——緊急 / 恢復路徑。其 DEX-swap 分支也接 SwapAdapter 分派。 | 編譯時參數化:(governance_nft_policy、governance_nft_name);透過 MultisigGov 的 spent input 授權 |
| 8 | `vault_liqwid` | Staking validator:SupplyToLiqwid、RecallFromLiqwid | 編譯時參數化:(keeper_stake_hash、governance_nft_policy、governance_nft_name);keeper-with-fallback;`publish` handler 由 A2 閘控 |
| 9 | `keeper_stake_script` | 依 mode flag 授權 keeper 動作的 staking validator(GovernanceOnly / PermissionlessWithBond / Mixed) | 透過 MultisigGov 做規則變更;執行用自己的 redeemer 規則 |
| 10 | `treasury` | 持有 treasury UTxO 的 spending validator;接收 inflow、以類別 + cooldown 閘控 outflow | 編譯時以 deposit token 身份參數化;透過 MultisigGov 的 spent input 授權 |
| 11 | `multisig_gov` | 持有治理 UTxO + queued 提案的 spending validator | 以 GovNFT policy + name 參數化 |
| 12 | `registry` | 持有協議白名單 + `asset_oracles`(§5.4 P3)+ `swap_adapter_hashes`(§B@launch=1)的 spending validator | 未參數化;治理 + keeper 的 fast-path market toggle |
| 13 | `order` | 持有使用者 order 的 spending validator;Process / Cancel / Expire redeemer | 以 vault_hash + vault_nft_policy 參數化 |
| 14 | `vusdcx` | vUSDCx 份額代幣的 minting policy | 以 vault_hash + vault_nft_policy 參數化 |
| 15 | `vault_nft` | Vault Identity NFT 的 one-shot minting policy——**PlutusV3 validator**,以特定 UTxO 參照參數化。Mint 要求該 UTxO 在 TX input(密碼學 one-shot);burn 無約束(永遠允許)。見 `spec/vault-nft.md`。 |
| 16 | `minswap_v2_adapter` | **Minswap V2 order 的 SwapAdapter**(§B@launch=1)。Staking validator,由 `vault_protocol.DeployToProtocol` + `vault_gov_emergency.AdminDeployNonDeposit` 透過 zero-withdrawal 呼叫。Decode Minswap V2 order datum(SwapExactIn / SwapMultiRouting)+ 驗證 redeemer 承諾的 min_receive 與 target_asset 與鏈上 datum 一致。未參數化——hash 透過 Registry `swap_adapter_hashes` 白名單化。上線後新增 DEX adapter 走治理 `UpdateRegistry`(14 天 timelock)——**不需要** V1 vault 重部署。見 `lib/vault/swap_adapter.ak` + `validators/minswap_v2_adapter.ak`。 |

另有兩個 minting policy 支援治理與 registry actor。兩者都沿用**與 `vault_nft` 相同的 PlutusV3 UTXO-ref one-shot 模式**(見 `spec/vault-nft.md §2`)——無 native-script 截止日、burn 無條件、透過消費 UTXO 參照做密碼學 mint-once 保證。三個 one-shot 身份 NFT 走同一模式,安全推理一致,避免了內部驗證期 native-script 截止日 trap 曾阻擋乾淨 sunset 的問題。

- `governance_nft`——治理 NFT 的 one-shot policy(單一 token、鎖在 MultisigGov UTxO;可在 V1 sunset / V2 遷移時 burn 以防 phantom-gov UTxO)
- `registry_auth_nft`——Registry auth NFT 的 one-shot policy(單一 token、鎖在 Registry UTxO;可在 sunset 時 burn)

第四個 minting policy 發行給治理簽名者的肯定性 NFT:

- `gov_signer_nft`——以 `(governance_nft_policy, governance_nft_name)` 參數化;mint/burn 閘控在同一 TX 中消費 MultisigGov UTxO,所以只有 multisig 授權的 TX 能發或回收 signer NFT。Asset-name 慣例 `<generation_byte><signer_index_byte><前 28 bytes 的 signer_pkh>` 由 frontend 強制(validator 接受任意長度的任意 asset name——在合約內約束一個不帶金融權利的肯定 artefact 的形狀會讓 bytecode 膨脹、不划算)。Soul-bound 強制靠社會約定:若簽名者轉讓其 NFT,治理用 RotateSigners + BurnRotatedOut 把他移除。完整生命週期見 `spec/gov-nft.md`。

### 4.1 Validator 切分理由

V1 的 17 個 logic validator(+ 4 NFT mint policy + 1 DEX adapter = 22 個 artefact)反映**沿四條正交軸**的切分,每條都由 Plutus V3 16 KB reference-script 上限驅動:

- **(1) 授權邊界**——把 permissionless redeemer 與 keeper-authorized + governance-authorized 的分開,讓每一半都保持在上限以下,並縮小各 validator 的審計面。例子:`vault_user`(permissionless Deposit/Withdraw)從 `vault_keeper_hot`(keeper-auth Compound/RebalanceBuffer)切出;`vault_batcher`(keeper-auth BatchProcess)從 `vault_user` 切出,讓後者可以**完全移除** `keeper_stake_hash` 參數。
- **(2) 治理反應延遲邊界**——把慢速審慎的政策變更(7-21d timelock)從 emergency / recovery 路徑(0d + 7d-conditional)分開,防止未來的政策 feature 擴張意外撐大 emergency 路徑的攻擊面。例子:`vault_gov_policy`(UpdateStrategy/Fee/FeeSplit/SlippagePolicy)從 `vault_gov_emergency`(EmergencyWithdraw)切出;`vault_admin_deploy`(AdminDeployNonDeposit + SwapAdapter dispatch)再從 `vault_gov_emergency` 抽出。
- **(3) Bytecode-cost-center 抽取**——當某個 redeemer 帶 4-5 KB 獨有的重機械(oracle reader、decoder、fold suite),且同 validator 中**沒有其他 redeemer 共用**時,把它抽成獨立 validator 能把完整 bytecode 當作 headroom 還給母 validator。例子:`vault_swap_ada`(dual-feed oracle reader + 6-tuple registry read,從 `vault_keeper_hot` 抽出);`vault_admin_deploy`(SwapAdapter dispatch,從 `vault_gov_emergency` 抽出)。
- **(4) 強迫的 size 修正切分**——當加入必要 feature 把某 validator 推過上限時,沿上述三條軸中成本最低者切分。例子:SwapAdapter dispatch + Tier 1 oracle wiring 把 `vault_protocol` 合計大小推到 16,500 B 後,把 `vault_recall`(RecallFromProtocol + MergeUtxo)從其中抽出。

所有切分之後,`vault_proxy` 帶 **11 個編譯時參數**(10 個 staking validator hash + `vault_nft_policy`),routing **10 條 Withdraw-Zero 路徑**(`UseUser` / `UseKeeperHot` / `UseSwapAda` / `UseProtocol` / `UseRecall` / `UseLiqwid` / `UseGovPolicy` / `UseGovEmergency` / `UseAdminDeploy` / `UseBatcher`)。Withdrawal-count 不變量(每 TX 恰好一個 vault staking validator)隨 route 數縮放。Post-split 最緊的 headroom 是 `vault_liqwid` 13,392 B(剩 2,992 B、距上限 18.3%)。12 個 staking validator 每個都帶 A2 `publish` handler——每個的 2 ADA Cardano stake 押金在治理通過 14 天 timelock 後都能回收,關閉了 pre-split monolithic validator 年代的「2 ADA 永久鎖死」trap。

每次抽取的細節(母 → 女 validator 對應、精確的編譯時參數、每次切分的內部審計發現)存在工程用 memory(不在公共 repo 中)。外部審計事務所合作時可申請存取完整抽取模板文件。

---

## 5. 交易模式

V1 協議從使用者視角有**七種主要 TX 模式**,從 keeper 視角有**六種**。全部遵循 Cardano eUTXO 模型——每筆 TX 消費 input UTxO、產出 output UTxO;中間狀態以 datum 編碼。

### 5.1 使用者:Direct Deposit

使用者從錢包 spend USDCx 到 vault UTxO,並按存入比例收 vUSDCx 份額,在一筆由自己提交的 TX 中完成。

- **Spend**:使用者的 USDCx UTxO、vault UTxO(被消費並以更新後 datum 重建)
- **Mint**:vUSDCx(數量 = 公平份額)
- **Output**:新 vault UTxO(`idle_buffer += deposit_amount`、`total_deposited += deposit_amount`、`total_shares += shares`);vUSDCx 到使用者地址
- **授權**:使用者簽名,keeper 不介入

### 5.2 使用者:Direct Withdraw

使用者燒 vUSDCx 份額,從 vault idle buffer 收 USDCx。若 keeper 未停擺 7 天,收 0.1% early-withdraw fee;停擺 ≥ 7 天則免除。

- **Spend**:使用者的 vUSDCx UTxO、vault UTxO
- **Burn**:vUSDCx
- **Output**:新 vault UTxO(idle_buffer、total_deposited、total_shares 全部下降);USDCx 到使用者宣告的 receiver 地址
- **授權**:使用者簽名,keeper 不介入

### 5.3 使用者:Queue Deposit

使用者在 `order` script 地址建立帶 `DepositOrder` action 的 Order UTxO,以自己的 USDCx + 少量 ADA + 自選 `max_batcher_tip` 出資。

- **Spend**:使用者的 USDCx + ADA
- **Output**:`order` script 地址的 Order UTxO
- **授權**:使用者簽名
- 後續:keeper 在 BatchProcess TX 中處理此 Order(§5.8)。若 keeper 在 24 小時內未處理,任何人都能觸發 `Expire`、把 Order 完整 value 退給使用者。

### 5.4 使用者:Queue Withdraw

類比 Queue Deposit,但用 `WithdrawOrder` action、以使用者 vUSDCx 份額出資。

### 5.5 使用者:Cancel

Owner 簽名取消待處理的 Order UTxO。

- **Spend**:Order UTxO
- **Output**:Order 完整 value 退回 owner 地址
- **授權**:需 owner 簽名

### 5.6 使用者:Emergency Withdraw

Keeper 停擺 7 天(以 `last_compound_time` 衡量)後,任何 vUSDCx 持有者可以做 direct-withdraw、免 early-withdraw fee。合約強制、不需治理動作。

### 5.7 任何人:Order Expire

Order UTxO 的 `expires_at` 過後,任何人(不限 owner)都可觸發 Expire redeemer,把 Order value 退給 owner。這讓**keeper 停擺變得可容忍**——queued order 無論 keeper 是否可用,都能被回收。

### 5.8 Keeper:BatchProcess

Keeper 在單一批次 TX 中處理 N 筆待處理的 Order UTxO(deposit + withdraw 混合)。

- **Spend**:N 筆 Order UTxO、vault UTxO、keeper_stake_script zero-withdraw 做授權
- **Mint/burn**:vUSDCx,按批次淨存款/提款比例
- **Output**:新 vault UTxO;vUSDCx 到 deposit order owner;USDCx 到 withdraw order owner;ADA tip 到 keeper 地址(每筆 ≤ order 的 `max_batcher_tip`)
- **授權**:keeper stake script 的 withdrawal

Batch 中的 order 按 **pre-batch snapshot** 定價(TX 開始時的 `total_deposited / total_shares`)。這讓每 order 的聚合不變量(`Σ minted_shares == batch_mint_total`)數學上精確;副作用是——與同 batch 大額反向 order 並存的 order,會以 pre-batch 匯率定價、**不是** running-accumulator 匯率。成熟 TVL 下典型 order 大小的影響是 sub-bp;pre-audit 100K 上限下,單筆 5K order 的 batch 可能產生幾個百分點的漂移,這就是為什麼**低 TVL 下的大額存款應走 Direct Deposit 而不是批次**。

### 5.9 Keeper:Compound

Keeper 觸發收益收割:vault 當下的 `idle_buffer + non_deposit_value - total_deposited` 換算為鏈上收益,其中 4.5%(或更低、依治理設定)抽為績效費,V1 啟動時拆成 40% 給執行 keeper + 60% 給 treasury(keeper 份額在 validator 硬上限以支持開源第三方 keeper 經濟可行性)。

- **Spend**:vault UTxO、treasury UTxO、keeper_stake_script zero-withdraw
- **Output**:
  - 新 vault UTxO(`total_deposited += net_yield`、`idle_buffer` 反映重分配)
  - 新 treasury UTxO(協議份額依當下比例拆進四個類別桶)
  - USDCx 轉到 keeper 地址(perf_fee 的 40%)
- **授權**:keeper stake script 的 withdrawal
- **Cooldown**:compound 之間最少 1 小時;validity range 寬度 ≤ 1 小時,防 timestamp 操弄
- **Zero-yield 模式**:若 `on_chain_yield == 0`,Compound 以 allocation-only 模式執行(無 perf_fee、無 keeper 份、無 treasury inflow);用來在沒有真實收益時推進 `last_compound_time`

### 5.10 Keeper:資本部署週期

三種 keeper redeemer 協調,在 vault 與 Liqwid 借貸市場間移動資本:

1. `DeployToProtocol`——從 vault 花 USDCx 到白名單 Minswap V2 swap order(例如 USDCx → DJED)
2. `RecallFromProtocol`——把 swap 結果 UTxO 消費回 vault(非存入 token 到達、NDV 增加)
3. `SupplyToLiqwid`——把非存入 token(DJED/USDM)supply 到 Liqwid action validator、收 qToken 收據進 vault

回到 USDCx 的反向週期:`RecallFromLiqwid`(燒 qToken、收穩定幣)→ `DeployToProtocol`(穩定幣 → USDCx swap)→ `RecallFromProtocol`(回 vault)。

- **授權**:三者都走 keeper stake script 的 withdrawal
- **白名單強制**:DeployToProtocol 的目的地必須在 `registry.protocol_hashes`;NDV 會計更新需要非存入 token 在 `registry.stable_tokens` 中
- **會計**:`non_deposit_value` 按移動的 token 數量 1:1 更新(**非 oracle 推導**)——keeper 報 + 受 registry 白名單約束

### 5.11 Keeper:MergeUtxo

把 batcher 退回的 UTxO(Minswap V2 batch fill 在 vault 地址產生的 orphan UTxO)合併回 vault 的主 UTxO。**純家務**;除了整併資產,無會計變動。

### 5.12 治理:協議政策變更

所有治理動作走相同的 3 步模式:

1. `QueueAction`——m-of-n 門檻簽名者用目標 TX hash + timelock 期間提案(最短 7 天,敏感操作如 `UpdateTreasuryParams` 為 14 天)
2. **Timelock 期間**——期間任一簽名者都能 `CancelAction` 作 1-of-n 否決
3. `ExecuteAction`——任一簽名者都能觸發執行;提案的目標 TX 被提交

V1 支援的治理動作:

- `UpdateStrategy`——改 strategy_allocations
- `UpdateFee`——在 [0, 450] 內改 performance_fee_bps(4.5% 硬上限不可變)
- `EmergencyWithdraw`——設 `frozen=1`(暫停 Compound / BatchProcess / DeployToProtocol;Withdraw 永遠開放)
- `AdminDeployNonDeposit`——透過 Minswap V2 把滯留的非存入穩定幣換回 USDCx,閘控在 7d keeper 停擺 + 21d registry timelock
- `UpdateRegistry`——改協議白名單(7d 治理 timelock)
- `KeeperToggleMarket`——停用特定 Liqwid 市場(1h cooldown、keeper 授權,快速 Liqwid 遷移響應)
- `FastUpdateMarkets`——更新 Liqwid 市場 metadata(1h 治理 cooldown、遷移快速路徑)
- `UpdateKeeperAuth`——改 `keeper_stake_script` 模式或 `authorized_pkhs` list(7d timelock)
- `AddTreasurySpend` / `UpdateTreasuryParams`——treasury 操作(7d 或 14d timelock,視 action 而定)
- `RotateSigners`——改治理簽名者集合 + 門檻(30 天輪替 cooldown)

---

## 6. Withdraw-Zero forwarding 模式

V1 用 Withdraw-Zero forwarding 模式,讓主 vault UTxO 保持在單一地址,但把 redeemer 邏輯切到多個 staking validator。

**為什麼**:Cardano 的 16 KB max-TX-size 限制了 reference-script UTxO 的編譯 script 大小。一個涵蓋 user + keeper + governance 所有流程的**單一 monolithic vault validator** 會超過此上限。切成多個 staking validator、每個處理協議職責的一個連貫子集,讓每個編譯 script 都在上限以下,同時保留**單 UTxO 會計模型**。

**怎麼運作**:

1. 主 vault UTxO 停在 `vault_proxy` script 地址
2. 每筆動到 vault UTxO 的 TX,都必須對其中一個 staking validator(`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`、`keeper_stake_script`)帶一筆 zero-withdrawal
3. 該 staking validator 的 redeemer 承載真正的 OptiVaults redeemer 邏輯(Deposit、Compound、SupplyToLiqwid 等)
4. `vault_proxy` validator 只做通用檢查:Vault NFT 存在、continuing-output 存在、每 TX 一個 stake-validator

**好處**:

- 每個 staking validator 較小、可獨立審計
- Staking validator 集合可以演進(為新功能加新 staking validator)**而不重部署** `vault_proxy` 合約,**前提是新 stake credential 被加進 `vault_proxy` 的編譯時參數集**——而那本身就要 vault 重部署。這是部分彈性、不是無限彈性。
- `keeper_stake_script` 特別利用了這個模式:keeper 授權規則可以**完全在 stake validator 自己的 datum + redeemer 邏輯內**演進,不用動 `vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid` 或 `vault_proxy`。

---

## 7. 外部依賴

V1 依賴三個外部 Cardano 原生協議。**沒有任何一個合約性地承諾 OptiVaults 的持續正確性**;每一個都是信任假設——有揭露、有緩解,但無法消除。

### 7.1 USDCx(存入資產)

- **發行方**:Circle,透過其 xReserve 跨鏈儲備機制在 Cardano(2026-02 上線)
- **Mainnet policy ID**:`1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34`
- **Asset name hex**:`5553444378`(即 "USDCx")
- **Vault 依賴**:USDCx 是 deposit-token policy;vault 的本金會計以 USDCx 計價
- **失敗模式**:發行方無償 / 儲備事件 / 制裁凍結 → vault USDCx 餘額與任一其他持有者同等受影響
- **OptiVaults 緩解**:合約層**無**;在白皮書 §1.2.5 揭露

### 7.2 Liqwid Finance(主要收益來源)

- **整合模式**:direct action-validator 路徑做 qToken mint/burn(V1 不與 Liqwid 的 borrow-side batcher 互動)
- **使用的市場**:DJED、USDM
- **Vault 依賴**:`SupplyToLiqwid` 在 Liqwid action validator 地址鑄 qToken;`RecallFromLiqwid` 燒它們。`strategy_allocations` 與 `liqwid_positions` 追蹤 supplied vs held 數量。
- **失敗模式**:Liqwid 協議 exploit / 壞帳 / 市場 sunset / action-validator 遷移 → qToken 可能無法按票面值贖回
- **OptiVaults 緩解**:35% 閒置 buffer 作為第一層流動性絕緣;`EmergencyWithdraw` 治理壞帳 write-off 路徑;`AdminDeployNonDeposit` Minswap V2 恢復路徑(獨立於 Liqwid);per-market `LiqwidPosition` 隔離。完整分析見 `docs/security-model.md`。

### 7.3 Minswap V2(DEX routing)

- **整合模式**:V1 送 swap order 到白名單 Minswap V2 pool;Minswap batcher 處理;fill 以 orphan UTxO 形式回到 vault 地址,keeper 透過 MergeUtxo 整合
- **使用的 pool**:USDCx/DJED、USDCx/USDM 直連 pool;直連 pool 衝擊 >2% 時走 NIGHT hub 3-hop 路徑
- **Vault 依賴**:vault 地址上的 swap 結果 UTxO 由 keeper 合併、按接收量 1:1 token 單位計入 `non_deposit_value`(**非 oracle 推導**)
- **失敗模式**:Minswap V2 協議 bug / batcher 停擺 / 卡單 → swap leg 可能失敗
- **OptiVaults 緩解**:keeper 鏈下 swap 引擎強制 minReceive 下限 + max impact 上限;失敗 swap 可透過 Minswap V2 自身的 cancel 機制退款;`registry.protocol_hashes` 白名單防止路由到攻擊者控制的 pool

---

## 7.5 Vault ADA 生命週期

Vault UTxO 帶 ADA 有兩個並存目的:

1. **Min-UTxO**(Cardano 協議需求):UTxO 必須持有足夠 lovelace 覆蓋自身序列化 output 大小 + token 數。29 欄 VaultDatum 序列化約 400–600 bytes(視 `strategy_allocations` + `liqwid_positions` 長度與數值而定);配上 2 個 token(Vault NFT + USDCx),min-UTxO 落在 2.5–3.5 ADA 區間。Operator 應視為**約略**——每次部署時依 Cardano 協議參數精確量。
2. **DEX-order 運營 buffer**:`DeployToProtocol` 送 Minswap V2 order 帶約 4 ADA(batcher fee + order min-UTXO),這些 ADA 從 vault 的 lovelace 餘額出。每筆 order 吃 ~4 ADA;fill 時 Minswap batcher 消 ~2 ADA 當 fee、vault 淨收回 ~2 ADA,**每個 swap 週期從 vault 淨損失 ~2 ADA 給 Minswap 基礎設施**。

### 7.5.1 合約強制的邊界(`max_deploy_ada`、`min_vault_ada`)

`vault_protocol.ak::DeployToProtocol` 強制兩個編譯時參數,限制 vault ADA 下降幅度:

| 參數 | V1 啟動值 | 語意 |
|------|-----------|------|
| `max_deploy_ada` | 5 ADA | 每 TX lovelace 下降上限 |
| `min_vault_ada` | 10 ADA | 低於此下限時 `DeployToProtocol` 被拒 |

`DeployToProtocol` 裡的驗證:

```aiken
out_ada >= own_lovelace - max_deploy_ada  -- per-TX 上限
  && out_ada <= own_lovelace             -- 不能透過此 redeemer 增加 ADA
  && out_ada >= min_vault_ada            -- 永不 drain 過下限
```

這合起來保證:
- 被入侵的 keeper 不能透過快速 swap 迴圈 drain 所有 vault ADA(per-TX 上限)。
- Vault ADA 已低時仍想 deploy 的操作錯誤,在資金離開前就被拒,避免 vault 卡在 Cardano min-UTXO 以下(下限)。
- Swap 中 ADA 不能被注入 vault 以掩蓋會計(ADA 上限為 `own_lovelace`)。

### 7.5.2 SwapAda 閉環補充

Vault ADA 隨時間下降,因為每筆 `DeployToProtocol` TX 淨貢獻約 2 ADA 給 Minswap V2 batcher fee(見 §7.5)。沒有補充機制,vault 最終會撞到 `min_vault_ada`、擋住所有 Deploy TX,直到 operator 手動 top-up——這是 liveness 風險 + 運營雜務。

V1 透過 `SwapAda` redeemer 把這個迴圈在鏈上關起來(完整 spec:`spec/ada-swap.md`)。機制:

1. **觸發條件**——keeper 只在 `vault.lovelace < ada_swap_threshold`(編譯時常數 15 ADA)時呼叫 `SwapAda`。
2. **原子等值交換**——keeper 貢獻 `amount_ada`(範圍 10–50 ADA,編譯時 bounded)到 vault。Vault 用 reference oracle 匯率(Charli3 + Orcfax 共識;validator 讀 `ada_price_oracle_source` reference inputs)把等值 USDCx 送回。
3. **Cooldown + 寬度上限**——SwapAda TX 之間 `ada_swap_cooldown_ms = 1 h`;`tx.validity_range.upper - now <= 1 h`(內部驗證的寬度上限模式),防止 stale-oracle 利用。
4. **會計不變量**——vault 的 `own_lovelace` 剛好增加 `amount_ada`;vault 的 USDCx 餘額減少 `amount_ada × ada_price_bps / 10^7`;`total_deposited` **不變**(swap 不改變 vault TVL、只改資產組成)。
5. **`last_ada_swap_time` datum 欄位**——每次 SwapAda 時更新;納入 1 小時寬度上限不變量(`vault-datum.md §3` 第 11 項)。

**經濟面描述**。存入者的 USDCx 本金透過這個機制慢慢支付 DEX-order 運營 overhead——速度緩慢、Cardano 原生成本、不額外加託管層或費用。100K TVL 下,每 2-4 週一次 SwapAda,每次 20-40 ADA(當下 ADA 價約 10-20 USDCx),年度拖曳約 20 USDCx = 0.02% APY——相對 4-6% gross yield 微不足道。

**為什麼不用 operator-funded top-up**。Operator top-up 引入信任依賴(keeper 得記得 + 有 ADA + 簽名)+ 誘因問題(keeper 為什麼要捐 ADA 給他營運的 vault?)。SwapAda 把這個轉成**鏈上、oracle 驗證、cooldown 限流的原子操作**,除了 oracle feed(整個系統已經為了 depeg 監控而依賴)之外,**沒有額外的信任前提**。

**為什麼只 ADA-in / USDCx-out(無反向)**。反向 `WithdrawAda` redeemer(vault 收 ADA、送出 USDCx 等值)考慮過但否決:keeper 沒誘因拉出 ADA(他們用 ADA 付網路費),而這個 feature 會新增攻擊面(keeper 磨 oracle 時機 + 以有利匯率抽 vault USDCx),**不會**關閉任何 liveness gap。

### 7.5.3 Sunset / 遷移恢復

當 vault sunset(`total_shares == 0`,full-drain Withdraw),`nft_burned` 要求(見 `spec/vault-nft.md`)銷毀 Vault NFT,vault UTxO 的完整 lovelace 餘額流向提領者。V1 中**沒有 vault ADA 的殘餘鎖死**——PlutusV3 UTXO-ref NFT policy 保證 burn 永遠可用。

(對比:內部驗證期的 native-script NFT 有 `before(slot)` 截止日,截止後 burn 被擋,每個 vault 約 15-20 ADA 在 sunset 時永久滯留。這個 trap 在 V1 關閉。)

### 7.5.4 部署時 ADA 大小指引

部署 V1 的 operator 應該在部署時以 **min_vault_ada + 5-10 ADA headroom ≈ 15-20 ADA** seed vault UTxO:
- 足夠同時承擔 2-3 筆並發 Minswap order 而不碰 `min_vault_ada` 下限(swap 吞吐週期在運營上觀察到的瓶頸)
- 不會大到一個假設的 validator 會計 bug 洩漏非微量 ADA 到卡住狀態

V1 mainnet 可能呈現與估計不同的部署時 ADA 需求——operator 應該監控上線後前 30 天的 `vault.lovelace`,若觀察到 throughput 模式需更大 headroom,透過 `MergeUtxo`(NoDatum ADA 捐贈,keeper 合入)調整 seed 大小。

---

## 8. V1 刻意不納入的內容

若干能力 V1 考慮過且刻意延後:

- **更多鏈上 oracle 整合**——V1 在 keeper 層消費 Charli3 + Orcfax + Minswap V2 TWAP 做 depeg 監控(Cardano 原生、15 分鐘 sustained deviation)。更進一步的 validator 層 oracle 讀取(例如在 Deposit 不變量中直接整合鏈上價格 feed)**延後**;目前模式讓 oracle 依賴停留在 vault validator 的熱路徑之外
- **多 key keeper native-minting 授權**——V1 用 stake-validator mode-flag 路徑,嚴格上更有彈性;另行的 multi-key 授權會冗餘
- **Permissionless BatchProcess**——V1 保持 BatchProcess 在 license-gate 下;V2 可能開放,視 Liqwid batcher 先例實際經驗與使用者-tip 誘因對齊
- **多 vault 支援**——啟動時單一 vault;多 vault 架構(多 deposit token、不同風險輪廓)是 post-V1 candidate,前提是單 vault 可持續性得到證明
- **治理 token**——V1 用 PKH-based m-of-n multisig 作治理;**無協議 token、無 token 發行、無 yield-farming 誘因**。Token 設計是獨立決定,可能適合也可能不適合 V2/V3 方向
- **不良 keeper 的 slashing**——V1 用治理撤銷(從 authorized_pkhs 清單移除);帶保證金的 slashing 在當下 TVL tier 是 overkill、且增加實作複雜度
- **跨鏈**——V1 僅 Cardano

---

## 9. 相關文件引用

- `spec/vault-datum.md` — VaultDatum 欄位精確定義、不可變性分類、每 redeemer 的轉移規則
- `spec/treasury.md` — TreasuryDatum、類別數學、支出 redeemer 規則、audit reserve 鎖定機制
- `spec/keeper-auth.md` — keeper_stake_script 模式、授權邏輯、模式切換流程
- `spec/order-batch.md` — OrderDatum、Process redeemer、使用者-tip 機制、Expire 語意
- `spec/governance.md` — MultisigGov 動作目錄、timelock 規則、cancel/rotate 流程
- `docs/economics.md` — 費用結構、treasury 流量數學、可持續性門檻
- `docs/security-model.md` — 完整威脅模型、信任邊界、殘餘風險揭露
- `docs/migration.md` — 內部驗證期存入者的遷移計畫
- `docs/audit-scope.md` — Pre-launch 審計計畫 + Q2-Q3 2027 外部審計範圍
- `whitepaper/whitepaper.md` — V1 公開白皮書(給非開發者的整體摘要)
