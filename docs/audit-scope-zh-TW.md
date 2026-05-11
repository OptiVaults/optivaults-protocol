# audit-scope.md — V1 審計計畫

V1 新增了 validator(`keeper_stake_script`、`treasury`、`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_recall`、`vault_admin_deploy`、`minswap_v2_adapter`),並調整了若干既有 validator(`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_proxy`、`vusdcx`、`order` 的編譯時參數變更)。V1 審計計畫以**涵蓋區方法論**(A–F 區,見 §4)覆蓋完整合約集合,並以「所有 heritage regression test 必須通過」作為前置條件。

---

## 1. 沿用下來的設計不變量

V1 validator 集合從內部驗證期設計繼承下列架構不變量,作為 V1 合約中的硬性檢查保留;涵蓋區計畫(§4)會逐一驗證這些不變量在 V1 重構後仍被強制。

| 不變量 | V1 強制點 |
|--------|-----------|
| 非存入代幣保留(不能靜默注入或抽離 token) | `vault_user`、`vault_keeper_hot`、`vault_protocol`、`vault_recall`、`vault_liqwid` 內的 `verify_other_tokens_preserved`;`verify_all_tokens_preserved` 作為對稱 helper 用於「只寫 datum」的 redeemer |
| 績效費硬上限 450 bps(4.5%) | `vault_gov_policy.ak` 的 UpdateFee 入口處 `performance_fee_bps <= 450`(透過共用的 `validate_update_fee` helper);`early_withdraw_fee_bps` 另外有 ≤ 100 bps(1%)的上限,見 `vault-datum.md` §2.2 |
| Buffer 下限 + 非空配置 | UpdateStrategy 強制 `buffer_target_bps >= 500`;`strategy_allocations` 非空檢查 |
| Multisig 治理架構 | `multisig_gov.ak` 的 m-of-n 狀態機,每個 action 各自有 timelock |
| 治理 empty-hash 模式 + timelock 下限 | `QueueAction` 的 timelock 下限 + TTL 上限;1-of-n cancel 否決 |
| Vault NFT 編譯時錨點 | `vault_proxy` / `vusdcx` / `order` 在部署時都以 `vault_nft_policy` 參數化;datum 不再保留這個欄位 |
| Withdraw 防雙重兌現 | Direct Withdraw 強制 `receiver_output_idx` |
| 延後收益(deferred-yield)的 Withdraw 語意 | `withdraw_amount = base_withdraw − early_fee`;early fee 物理上留在金庫內 |
| 治理安全模型 | `multisig_gov.ak` 的檔頭註解 + `spec/governance.md` 的設計論述 |
| 無 vusdcx 外漏 + 簽名者下限 ≥3 | BatchProcess 的 no-leak 檢查 + RotateSigners `signer_count ≥ 3` |
| Order NFT reference-input 的真實性 | `order.ak` Expire 路徑透過 `find_vault_datum_ref` 強制 NFT |
| 邊界案例掃過(token 白名單、NDV 下限) | MergeUtxo secondary 白名單;Supply/Recall/AdminDeployNonDeposit 的 `idle_buffer >= 0` + `non_deposit_value >= 0` 下限 |
| 時間欄位 validity-range 寬度上限 | 所有會寫時間的 redeemer(Compound、UpdateFee、UpdateStrategy、RotateSigners、SwapAda)都強制 upper 上限 1 小時 |
| Allocation 不變量 + 首位存入者下限 | 全域 `valid_deposited > 0`;`alloc_sum + idle_buffer <= total_deposited + NDV + Σ liqwid_principal` |
| 鏈下編譯時參數同步 | Keeper / API / CLI 設定透過 `VAULT_NFT_POLICY` + `EXPECTED_PROXY_HASH` env 閘控,與鏈上 validator hash 鎖在同步 |
| 部署流程狀態隔離 | `RELEASE_TAG` 閘 + 逐腳本 flushState + 延長的 NFT deadline |
| Registry 身份欄位不可變 | `RegistryDatum.keeper_pkh`(身份參照,**不是**目前授權 keeper 集合)、`deposit_token_policy`、`deposit_token_name`、ref-script hash 一經設定即鎖定。注意:**目前的 keeper rotation** 路徑是 **`keeper_stake_script.authorized_pkhs`**(透過 `UpdateKeeperAuth` 治理,見 `spec/keeper-auth.md`)——那才是 keeper 被新增 / 輪替 / 移除時會改動、且不需要重部署 vault 的欄位。兩者用途不同:`RegistryDatum.keeper_pkh` 是部署時鎖定的身份參照,供 indexer / 查詢用;`keeper_stake_script.authorized_pkhs` 則是 validator 實際授權檢查時讀的 runtime 列表。|

**Regression 測試:** heritage regression test suite 必須在 V1 validator 上持續通過,作為每個涵蓋區出口(exit)的前置條件。任何一條 fail 就是 blocker。

---

## 2. V1 特有的新審計範圍

### 2.1 `keeper_stake_script.ak`

**全新 validator。需要完整審計輪次。**

範圍:
- `RegistrationMode` enum 的正確性(GovernanceOnly / Mixed / PermissionlessWithBond)
- `keeper_auth_datum` 狀態機轉移
- 保證金沒收條件(V1 上線時尚未啟用,但先審——為未來做準備)
- `WithdrawAsAuthorized` redeemer 透過 Withdraw-Zero 與 `vault_user` / `vault_keeper_hot` / `vault_protocol` / `vault_recall` / `vault_liqwid` 整合
- 保證金提取的 grace period 計時
- 跨 validator 授權流程(gov-path vs keeper-path)

**目標發現數:** 上線前 0 CRIT / 0 HIGH / 0 MEDIUM。

### 2.2 `treasury.ak`

**全新 validator。需要完整審計輪次。**

範圍:
- `TreasuryDatum` 18 欄位的正確性
- `Receive` redeemer 能接收 Compound 的 fee output、而不會被 datum 操弄
- `Spend` redeemer 強制 `amount <= category_balance[category]`
- `UpdateParams` 強制比例不變量(sum = 10000、audit_reserve_ratio >= 2000、沒有任一類別 > 5000)
- 與 `multisig_gov` 的互動(TreasurySpend、UpdateTreasuryParams 的授權)
- 對類別餘額讀取的抗前跑(front-running)
- 捐贈處理(在 Compound 流程之外收到 token)

**目標發現數:** 上線前 0 CRIT / 0 HIGH / 0 MEDIUM。

### 2.3 修改過的 validator

**`vault_user.ak` + `vault_keeper_hot.ak` + `vault_batcher.ak` + `vault_swap_ada.ak`:**
- 編譯時參數:`keeper_stake_hash`(透過 `keeper_stake_script` zero-withdraw 授權——輪替時不用重部署)套在 `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada` 上;`vault_keeper_hot` 與 `vault_swap_ada` 另外加 `treasury_hash`(USDCx 費用 + ADA 換 USDCx 的收益路由到 script 地址,不是錢包 PKH)。`vault_user` 是純 permissionless 路徑(不需要 `keeper_stake_hash`)。
- 授權模型:`vault_user` 放 Deposit + Withdraw(permissionless,使用者簽名)。`vault_keeper_hot` 放 Compound + RebalanceBuffer(keeper 授權)。`vault_batcher` 放 BatchProcess(keeper 授權,多筆 order 的 vUSDCx mint/burn 指揮)。`vault_swap_ada` 放 SwapAda(keeper 授權、ADA→USDCx swap、搭配雙源預言機,見 `spec/ada-swap.md`)。
- Compound redeemer(放在 `vault_keeper_hot`)把費用做 **3-way 拆分**,依照 `keeper_fee_bps` + `gov_fee_bps` 分給 keeper / gov pool / treasury(上線值 4000 / 0 / 6000;上限由 UpdateFeeSplit 管——見 `spec/vault-datum.md` §2.2)。
- 驗證費用拆分正確(rounding 不得被 skim)。
- 驗證 Compound 時 treasury output 的 datum 被正確保留(跨 validator 對 `treasury.Receive`)。
- 驗證 gov-pool 的 USDCx 實體金流與 `gov_share` 一致(跨 validator 對 `multisig_gov.ReceiveCompoundShare` 的 binding)。
- 驗證 `validate_compound` 仍強制所有先前的不變量。
- 驗證 `vault_batcher` 的 BatchProcess `no_vusdcx_leak` 不變量。

**`vault_protocol.ak` + `vault_recall.ak`:**
- `vault_protocol` 只放 DeployToProtocol(加 A2 `publish`)。DEX swap 透過 SwapAdapter 介面分派(見 `spec/swap-adapter.md`);`minswap_v2_adapter` 是啟動時的 adapter。
- `vault_recall` 放 RecallFromProtocol + MergeUtxo(加 A2 `publish`)。
- 編譯時參數變更會 cascade 到 `vault_proxy`(11 個參數、10 條 Withdraw-Zero route)。
- 驗證 `UpdateKeeperAuth` 與 `keeper_stake_script` 的互動。
- 驗證 `UpdateTreasuryParams` 與 `TreasurySpend` 不會繞過既有不變量。

**`vault_proxy.ak`、`vusdcx.ak`、`order.ak`:**
- 編譯時參數變更(core/protocol/liqwid/treasury/keeper_stake 的新 hash)
- 驗證 applied form 的 hash 與預期相符
- 預期**沒有邏輯變更**——這輪審計是 cascade 驗證

**`vault_liqwid.ak`:**
- 切分出來的 staking validator,邏輯沿用
- 以 regression 方式審——確認 heritage 的 Liqwid 相關發現仍維持關閉(Supply/Recall 會計、market_id 唯一性、qToken 兌換率語意)

### 2.4 治理新增項目

`multisig_gov.ak` 新增 `ActionKind` 變體:
- `UpdateKeeperAuth`
- `TreasurySpend`
- `UpdateTreasuryParams`

每項都要審:
- timelock 下限(UpdateKeeperAuth 與 UpdateTreasuryParams 為 14 天;TreasurySpend 為 7 天)
- payload hash 的計算
- 跨 validator 的授權流程

### 2.5 Registry 新增項目

`registry.ak` 可能新增:
- `treasury_hash` 的參照(唯讀)
- `keeper_stake_script_hash` 的參照(唯讀)

這些都是**唯讀錨點**——沒有新 redeemer、沒有狀態變化。審計重點:確認新欄位是不可變,或只能透過既有的 `UpdateRegistry` redeemer 被正確閘控。

---

## 3. Property-based 測試新增項目

V1 在 `lib/vault/tests/property_test.ak` 下提供一組 property-based 測試,使用 `aiken/fuzz` 的迭代紀律(預設每個 property 上限 100 iter,首次失敗 early-exit)。Pre-V1 既有套件涵蓋 peg-floor 與 asset-oracle lookup 不變量;V1 審計範圍規劃以下新增,每項採同 100 iter 上限(如有不同會註明):

| Property | 說明 |
|----------|------|
| Treasury 類別下限 | `audit_reserve_balance >= min_audit_reserve`(不可變下限) |
| Compound 費用拆分 | `keeper_fee + treasury_fee == total_fee` 必須完全相等(rounding 不得被 skim) |
| Treasury 比例總和 | `Σ category_ratios == 10000` 不變量 |
| 保證金沒收界線 | `slash_amount <= posted_bond` |
| Keeper 授權轉移性 | 若 redeemer 聲稱 `WithdrawAsAuthorized`,則 `keeper_stake_script` output 必須顯示已更新的保證金狀態 |

任何 commit 的精確 property 數、iteration 上限、以及完整 `aiken check` summary 都可從 source 重現——對應 commit 跑 `aiken check` 即可驗證。本文刻意不固定特定 test-count 數字,避免隨 property suite 成長與 source of truth 脫節;真正持久的描述是方法論(iteration-capped fuzzing + early-exit + per-property axiomatic invariants)。

---

## 4. 內部審計涵蓋區計畫

V1 特有的內部審計依**涵蓋區**組織,而不是用輪次編號。每個區域獨立追蹤;輪次數要看複審時的發現密度與範圍調整而定。

**層級界定**:涵蓋區 A-D + F 覆蓋**協議層**([`optivaults-protocol`](https://github.com/OptiVaults/optivaults-protocol))——Aiken validators + 部署流程。區 E 覆蓋 **operator 層**([`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference))——TypeScript keeper + API + frontend + CLI。Q2-Q3 2027 的外部審計(§5)明確針對協議層;operator 層依自己時程審、scope 宣告於 `optivaults-reference/SECURITY.md`。Fork 協議層的團隊**繼承 A-D/F 的覆蓋歷史**(相同 validator hash);fork operator 層的團隊**繼承 E 方法論但要自己對他們特定的 TypeScript delta 做 E 審計**。

**涵蓋區 A — Treasury**
聚焦:`treasury.ak` 整個 validator、透過 `multisig_gov` 的 `TreasurySpend` + `UpdateTreasuryParams` + `ReceiveGovForfeit`。出口:0 CRIT / 0 HIGH / 0 MEDIUM。

**涵蓋區 B — Keeper Stake Script**
聚焦:`keeper_stake_script.ak` 整個 validator、透過 `multisig_gov` 的 `UpdateKeeperAuth`、每週輪替機制、保證金生命週期。出口:0 CRIT / 0 HIGH / 0 MEDIUM。

**涵蓋區 C — V1 整合流程**
聚焦:跨 validator 的流程——Compound 的 3 個 fee output(keeper + gov pool + treasury)、`UpdateKeeperAuth` 觸發 keeper_auth 狀態變化、m-of-n 下的 `TreasurySpend`、`DistributeSignerCompensation` + `ReceiveGovForfeit` 的跨 validator binding、**三層治理安全設計**(Layer 1 `vault_gov_emergency.EmergencyWithdraw` freeze-only / Layer 2 `vault_protocol.DeployToProtocol` 在 `frozen = 1` 下開放 USDCx swap-out / Layer 3 `vault_user.CommunitySunset` 90 天 permissionless dead-man-switch——見 `spec/governance.md §4.4` + `docs/security-model.md §5.4`)。出口:0 CRIT / 0 HIGH / 0 MEDIUM。

**涵蓋區 D — V1 Regression**
把所有 heritage regression test 重跑一遍 V1 validator。標記新編譯時參數帶來的任何 cascade 影響。出口:V1 重構後所有既有測試仍通過。

**涵蓋區 E — V1 鏈下程式**
Keeper、API、frontend、CLI 全部為 V1 stack 更新過。具體面向:keeper 的 slippage policy 範圍(跨 validator 對 `vault_gov_policy.UpdateSlippagePolicy`)、API 的 JWT 簽名驗證流程、withdraw-cli + emergency-withdraw 的 HTML 不變量(不依賴 frontend 的自助退場路徑)、TVL 上限在 frontend 存款閘控 + keeper `tvlCapMonitor` alert 的執行。**嚴重性層級**:CRITICAL = 直接造成使用者資金損失 / 未授權的資金移動;HIGH = 鏈下與鏈上間的靜默狀態失步;MEDIUM = liveness 退化,需要 operator 介入;LOW = 外觀 / 可觀測性缺口。**出口**:keeper 0 CRIT / 0 HIGH;API + CLI 0 CRIT。(鏈下程式與鏈上 validator 不在同一個爆炸半徑內——存入者資金的保護來自鏈上檢查,與鏈下 bug 無關——但鏈下 CRIT/HIGH 仍值得在上線前修,因為它們可能把使用者面的體驗降到「沒有 operator 協助就退不了場」的程度。)

**涵蓋區 F — V1 部署流程**
V1 的部署 ceremony 多了 treasury UTXO init + keeper_stake_script UTXO init。部署流程審計方法論套用到這些新步驟。出口:狀態機 0 CRIT;runbook 已文件化。

---

## 5. 外部審計

**目標:Q2-Q3 2027**(反映 funding-stack 不確定性——Cardano Project Catalyst 處於暫停 / 重組狀態;funding 姿態見 §8.5)。

候選事務所(評估中):Runtime Verification、CertiK、Tweag、MLabs、Anastasia Labs。

**向外部審計方請求的範圍:**
- V1 validator 完整 Aiken 原始碼審視。
- 所有 redeemer 的不變量保留。
- 核心不變量的形式化驗證(延後收益 Withdraw 語意、BatchProcess mint-ratio 等式、MergeUtxo secondary-source 白名單),如果可行的話。
- 編譯時參數審計(確認所有錨點在部署時就設定好)。
- 鏈下的 keeper、API、CLI 審計為「選項」,但傾向納入。
- 部署 ceremony 乾跑審計。

**通過門檻:**
- 無未解決的 CRITICAL 發現。
- 無未附 operator 接受 + 社群揭露文件的 HIGH 發現。
- 外部審計方簽字認可 V1 的鏈上不變量集合。

**審計後動作:**
- 發布審計報告(IPFS + 網站)。
- TVL 上限從 100K 提升到 1M USDCx。
- 透過治理 `QueueAction` 公告審計里程碑(把審計報告 hash 上鏈)。

---

## 6. 責任揭露 + 酬庸式肯定

**V1 啟動時不運行結構化 bug bounty 計畫。** Bounty tier 表是**特定協議階段**的特定工具——post-external-audit + TVL 大到 audit-reserve 累積夠支撐市場競爭水準獎金的階段。V1 的 Phase 1 規模($500–$25K TVL、audit-reserve 累積速率 ~$0.3–$15/年)如果要訂 bounty,只能訂出「低於市場」的 tier,而這比沒有 tier 更糟:看起來像承諾、實際數字卻象徵性;招來審計事務所「scale mismatch」的質疑;也跟 V1 的非商業公共財定位互相矛盾。

V1 改採業界標準的**責任揭露政策(RDP)+ 酬庸式(ex gratia)肯定**框架。

### 6.1 責任揭露政策

**範圍:** V1 的鏈上 validator(**17 個 logic validator + 4 個 one-shot NFT mint policy + 1 個 DEX adapter = 22 個編譯 artefact**——切分理由見 `spec/architecture.md` §4.1)、部署腳本、keeper 程式、API server。

**我們承諾的事:**

- 收到有效通報(寄到 `optivaults@gmail.com`,強烈建議用 PGP 加密,公鑰在 optivaults.app/security)後 **72 小時內私下回覆**。
- **7 天內完成 triage + 初步修補計畫。**
- **triage 後 90 天的協調揭露窗口**,若修補需要額外時間準備 fix TX、經治理 timelock 發布更新、或與外部依賴(Liqwid、Minswap V2、Circle/xReserve)延伸協調,可再延 30 天。
- 窗口結束後**公開揭露**發現與修補,無論正式 fix 是否已經落地——reporter 在 120 天後保有自行公開的權利,研究成果不會被無限期壓住。
- **對善意揭露者不提告。** 以本政策為基礎的揭露,我們不會採取法律行動。

**我們請求 reporter 做的事:**

- 先私下通報,別在 triage 回覆前公開。
- 先在 Preprod 或本機測;不要主動在 mainnet 上利用漏洞,除了為了示範 finding 所需的最小程度。
- 不要抽離超出示範所需的資金;不慎抽離的資金,要透過治理協調的 TX 歸還給金庫。

### 6.2 酬庸式肯定框架

V1 對任何 finding **不**承諾固定金額。儘管如此,嚴肅的安全研究有其價值、有意義的肯定也很重要。對有效通報,我們可以在**裁量性、酬庸式**基礎上提供:

1. **公開致謝**——在 V1 公開審計報告、repo 的 `SECURITY.md` 揭露章節、以及(經 reporter 同意下)下一版 V1 release note 的專屬 changelog 中致謝。
2. **專案文件致謝**——經 reporter 同意,姓名與聯絡方式列進 V1 貢獻者清單。
3. **酬庸式感謝支付**——operator 裁量、由創辦人啟動資金支付(**不**從 treasury audit reserve 出——Phase 1 TVL 下累積太慢、沒辦法提供可預測的來源)。金額逐案而定,依循:finding 的嚴重性、對存入者保護的影響、通報本身的研究品質、以及當下的 ADA/USDCx 匯率。雙方都清楚這是**感謝象徵**——不會、也**無法**達到商業規模 DeFi 協議對等 finding 的市場行情 bounty。
4. **研究合作**——若 reporter 有意願,我們會就 finding + fix 合寫一份公開 case study。對非商業專案來說,這通常是能給安全研究者的最有價值的肯定方式。
5. **優先可視性**——有過有效 finding 紀錄的 reporter,未來內部審計輪次草稿 + pre-mainnet 測試部署可以拿到優先存取權(若他們有興趣)。

### 6.3 未來的結構化 Bug Bounty 計畫

結構化 bounty tier 計畫是 **post-audit + post-scale** 的考量,不是 Phase 1 的承諾。啟用前的前提條件:

- 外部審計順利完成(目標 Q2-Q3 2027——見 §5)。
- TVL 成長到自給規模(見 `docs/economics.md §6.3`,約 $500K+ TVL),讓 treasury audit-reserve 的累積足以承擔 bounty、不用再動到創辦人資金。
- 治理 m-of-n 門檻依白皮書 §6.1 Phase 2+ 路線圖調整(至少 1 位簽名者在執行 quorum 之外),讓 bounty 支付的授權路徑有真正的 dissent-veto。

在那些條件成立前,V1 的安全姿態建立在:多輪內部審計(§4 內部審計涵蓋區計畫)、獨立外部審計(§5 外部審計)、鏈上不變量(費用上限不可變、沒有 admin-drain redeemer、自助退場路徑),以及上述的 RDP + ex gratia 框架。

當結構化 bounty 計畫被引入時,本節會更新文件,記錄範圍、tier 結構與支付來源——同步以治理批准的 `UpdateTreasuryParams` 授權支撐它的 audit-reserve 出款。

---

## 7. 持續審計節奏

上線之後,內部審計輪次每月持續,聚焦在:
- 透過 `UpdateRegistry` 擴張範圍時引入的任何新 redeemer / validator。
- 新 DEX 整合(新 `protocol_hashes` 白名單項目)。
- 新 Liqwid 市場。
- Keeper 程式變更(特別是 `vaultSwapEngine.ts`、`strategyRouter.ts`)。

每 6 個月:對當時已部署的 hash 做 heritage 測試套件 + V1 涵蓋區測試的完整 regression。

每 12 個月:外部審計 refresh(較小範圍,自上次完整審計後的 delta)。

---

## 8. 公開透明

所有審計報告(內部 + 外部)都公開發布:
- GitHub:`/audit/` 目錄,放報告、test artifact、plutus.json hash、可重現腳本。
- 網站:optivaults.app/audit,附摘要與下載連結。
- 鏈上:每份審計報告的 IPFS hash 以 no-op `QueueAction` 形式寫進 `multisig_gov`(可 cancel,但 IPFS pin 會留)。

這會形成一份**防竄改的公開紀錄**:每一份審計都成為鏈上歷史的一部分。

---

## 8.5 審計資金姿態(公共財路徑)

V1 定位為 Cardano DeFi **非商業公共財**參考實作。審計接洽資金靠一個非稀釋性堆疊組成:

- **(a) Cardano Project Catalyst 撥款**:若有合適 Round 開,預期可取得 $30K-$50K。**撰寫時的狀態:Cardano Project Catalyst 處於暫停 / 重組狀態,下一個 Round 何時恢復尚無明確時程。** V1 把 (a) 列為候選資金來源、等 Catalyst 恢復,但**不依賴**;Q2-Q3 2027 審計時程(§5)即是為了讓 Catalyst 在此區間恢復、或讓 funding 完全由 (b)+(c)+(d) 覆蓋兩種路徑都留得到時間。
- **(b) 審計事務所公共財優惠費率**:從 $100K-$150K 全價折 30-50%(接洽中)。也計畫接洽 Cardano Foundation、Intersect、Aiken Foundation 等 alternative grant 來源。
- **(c) 大量 heritage 內部審計史帶來的範圍縮減**(見 §1):讓外部審計聚焦在關鍵路徑、而不是完整 17 logic validator + 1 DEX adapter 的範圍(共 22 個 artefact——數字見 §6),可省 $15K-$25K
- **(d) 創辦人自付殘額**:(a) 達成則 $20K-$40K 自付;**(a) 未達成則上限拉高至 $50K-$90K**

這個定位對評估合作的審計事務所可能有參考價值:

- **Apache 2.0 授權**:歡迎 fork、完整開源參考實作
- **無商業獲利動機**:4.5% 績效費用於覆蓋營運 + audit reserve + 長期 runway,不是創辦人 / 投資人的收益
- **無 token / 無 VC / 無 SAFE / 無 SAFT**:接洽不涉及證券相關義務
- **審計報告公開強制**:完成即全文公開(見上方 §8)——適合重視公共財 portfolio 的事務所

若貴所提供 Cardano DeFi 參考實作的公共財定價方案,請聯繫 `optivaults@gmail.com`。完整資金堆疊見白皮書 §8.1 + `economics.md §5.2.1`。

---

## 9. 延伸閱讀

- `docs/security-model.md` — V1 威脅模型
- `spec/architecture.md` — V1 validator 目錄
- `spec/governance.md` — timelock 下限與 action payload
- `spec/treasury.md` — TreasuryDatum 不變量
- `spec/keeper-auth.md` — keeper_stake_script 與保證金生命週期
