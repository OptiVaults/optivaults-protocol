# security-model.md — V1 威脅模型

V1 的安全故事建立在三層:(1) 部署時燒進 validator hash 的編譯時信任錨點、(2) 每筆 TX 都會驗證的 redeemer 層級不變量、(3) 限縮鏈下代理人信任範圍的明確 operator 義務。本文件列出對手分類、各自能觸及的攻擊面、鏈上防禦,以及我們對存入者揭露的殘餘風險。

---

## 1. 對手分類

| 分類 | 能力 | 是否在範圍內 |
|------|------|-------------|
| **外部使用者** | 送任意 TX、存 / 提、鑄詐騙 token、送捐贈 | 是 |
| **被入侵的 keeper** | 以 `keeper_pkh` 簽 TX、拿到 keeper 熱錢包、看得到即時金庫狀態 | 是 |
| **惡意治理 quorum** | m-of-n 簽名者共謀,能 queue 並 execute 任意治理動作 | 是(殘餘) |
| **單一 rogue 簽名者** | 1-of-n 被入侵,可以 1-of-n cancel 掉任何 queued 動作 | 是(屬防禦方,不是攻擊方) |
| **Liqwid 協議失敗** | 壞帳、rate oracle 操弄、pool 遷移時 attacker 拿到 action_addr | 部分(逃生閥已文件化) |
| **Minswap V2 batcher 失敗** | Batcher 離線、卡單、錯誤 fill | 是(expire + cancel 路徑) |
| **USDCx 發行失敗** | Circle 撤銷或改變 USDCx、xReserve bridge 被攻破、底層 USDC 儲備失敗 | 不在範圍(見 §6.1) |
| **Cardano ledger 失敗** | 鏈 re-org、節點共識分裂、Plutus bug | 不在範圍 |
| **Discord / Telegram 頻道注入** | 攻擊者透過頻道發訊息、嘗試對 operator 社交工程 | 是(明確的拒絕政策) |

---

## 2. 六個鏈上身份(人類控制者)

V1 把權責拆在六個不同的密鑰控制身份。依政策,**沒有任何一個人持有超過一個身份**。

**層級界定說明**:以下六個身份全部是**跑 vault 實例的運營角色**。它們描述 OptiVaults 代跑的實例(或任何 fork)。協議層程式本身([`optivaults-protocol`](https://github.com/OptiVaults/optivaults-protocol))**沒有任何控制者**——任何人都可以讀、fork、或部署自己的實例、用自己的身份集合。下表是**運營 `optivaults.app` 的實例**的;fork 運營者組自己的身份集合,與 OptiVaults 的完全獨立。

| # | 身份 | 層 | 角色 | 鏈上表徵 | 輪替路徑 |
|---|------|----|------|---------|---------|
| 1 | **Keeper** | Operator | Compound、rebalance、batch、swap、Liqwid supply / recall | 透過 `keeper_stake_script` zero-withdraw 模式授權——`keeper_stake_hash` 是 `vault_user` / `vault_keeper_hot` / `vault_protocol` / `vault_recall` / `vault_liqwid` 的編譯時參數;實際授權 PKH 集合放在 stake-script 自己的 datum(治理可變) | `UpdateKeeperAuth` 透過治理(14 天 timelock)更新 stake-script datum |
| 2 | **治理簽名者 A** | Instance 治理 | 3-of-3 quorum 成員 | `GovDatum.signers` 中的 pubkey | `RotateSigners` 14 天 timelock |
| 3 | **治理簽名者 B** | Instance 治理 | 3-of-3 quorum 成員 | `GovDatum.signers` 中的 pubkey | `RotateSigners` 14 天 timelock |
| 4 | **治理簽名者 C** | Instance 治理 | 3-of-3 quorum 成員 | `GovDatum.signers` 中的 pubkey | `RotateSigners` 14 天 timelock |
| 5 | **Ref-script deployer** | Operator | 部署 validator reference script、持有 deployer wallet UTXO | Deploy wallet pubkey(鏈下身份,以 TX 歷史錨定) | V1 部署完成後退場(ref script 不可變) |
| 6 | **創辦人補貼錢包** | Operator | 持有個人 runway,在金庫 break-even 前補貼 | 個人 Cardano wallet | 依白皮書 §9.2 退場或公開交接 |

**「Instance 治理」vs「Operator」**——治理簽名者(身份 2-4)控制鏈上協議政策變更(費率、策略、keeper 授權);他們是**該 vault 實例的治理**。Fork 運營者會有自己的治理簽名者集合,與 OptiVaults 的分開,可能有不同的簽名者數、輪替政策、人。**協議層程式不關心簽名者是誰**——它只檢查任何治理動作是否有達門檻的簽名。

**啟動現實**:V1 啟動時,身份 1 + 5 + 6 都是**同一位創辦人**。身份 2/3/4 是創辦人 + 2 位信任的合作者。這個 6-身份地圖是 OptiVaults 實例的**目標狀態**——白皮書 §8.6 揭露當下的集中度與分離路徑。

---

## 3. 攻擊面目錄

### 3.1 Phantom Vault 注入(內部驗證期 CRITICAL,已關閉)

**攻擊**:攻擊者部署自己的 `vault_nft` validator,鑄 `(attacker_policy, "OptiVault")`,造一份宣稱 `vault_nft_policy = attacker_policy` 的假 VaultDatum,把這個 UTxO 送到真實的 proxy 地址。在舊版 validator 中,所有 NFT 檢查都是自引用的(從 datum 讀 policy、驗證 policy 在 UTxO 內)→ 假 UTxO 通過所有檢查 → 首位存入者的 multiplier 從假 datum 鑄出 10^13 個真實 vUSDCx → 燒回真實金庫把 TVL 抽乾。

**V1 防禦**:Vault NFT policy 成為 `vault_proxy`、`vusdcx`、`order` 的**編譯時參數**。每個 NFT 檢查都錨在編譯時值上,偽造這個值就等於打破 validator hash。送到真實 proxy 地址的假 datum UTxO 會被忽略,因為 validator 根本不讀它自稱的 `vault_nft_policy`。

**狀態**:V1 中結構上不可能。

### 3.2 治理 Empty-Hash 信任委派

**背景**:`QueueAction` 接受 `target_tx_hash == #""`(空)。當 target 為空時,`ExecuteAction` **不**強制 `tx.id == target_tx_hash`。這是刻意的——多數治理動作在 queue 時無法預知未來的 TX hash(hash 取決於執行時付費的 input,那時無從得知)。完整模式見 `spec/governance.md §5`。

**Empty-hash 並未**改變的事:`ExecuteAction` **永遠**要求 `signers_present >= gov.threshold`(`multisig_gov.ak:378`)。Empty-hash 路徑**只**繞過 `tx.id` 綁定——`payload_hash` 綁定(redeemer 參數的 blake2b_256)仍然強制,所以 target validator 執行後的鏈上狀態,在 queue 時就已經完全固定。

**常見的錯誤描述要特別注意**:「14 天後任何 1-of-n 簽名者都可以執行任意 admin」**是錯的**。Validator 沒有 1-of-n execute 路徑。攻擊面是 m-of-n 共謀,不是 1-of-n 委派。

**歷史上已關閉的變體(內部驗證期)**:一個涉及 `timelock = 0` + 1-signer `CancelAction` 的 grief 路徑在內部 review 時已關閉。目前 `QueueAction` 強制 `timelock_ms >= min_timelock_ms(action_kind)`(governance.md §3),所以每個 queue 的動作都 ≥ 文件化的最小值(實質動作 7-21 天,`EmergencyWithdraw` / `FastUpdateMarkets` 為 0-1 小時)。

**V1 殘餘風險(如實描述)**:

- **`m` 位共謀簽名者** queue 一個動作(依 action kind 預先 14-30 天)。
- Timelock 過後,同一批 `m` 位 execute。Payload_hash 綁定代表執行後的鏈上狀態正是他們 queue 的那份——**不可能換掉一個不同的 redeemer**。Empty-hash 放寬的是執行 TX 的**外形**(付費 input、非關鍵 output),**不是** payload 的意圖。
- **鏈上防禦——1-of-n CancelAction**:任何一位不在共謀集合中的簽名者,都可以在 timelock 窗口內隨時 cancel(`multisig_gov.ak::CancelAction`,`sig_ok >= 1`)。
- **鏈下防禦——operator charter**:
  - 簽名後 1 小時內公開廣播每筆非瑣碎的 queue(Discord + 鏈上 CBOR decode)。
  - 至少 1 位誠實簽名者主動監控每筆 queue。
  - 招募簽名者時,至少要讓 ≥2 位是非共謀的(V1 啟動:1 位創辦人 + 2 位獨立的 Cardano SPO)。

**V1 啟動備註(3-of-3 全員同意)**:啟動時 `threshold == n == 3`,所以「m 位共謀」意指 3 位全員。1-of-n cancel = 3 位中任 1 位可以否決。這在結構上比典型的門檻設定更強——queue 本身就需要全員同意。只有在 Phase 2+ 引入 `threshold < n`(5 位 / 門檻 4)之後,這層考量才會變緊——4 位共謀 + 1 位沉默的誠實簽名者可能把惡意動作推過去,前提是鏈下監控義務失敗。

### 3.3 vUSDCx 透過 Mint-Ratio 偷吃通膨(內部驗證期,已關閉)

**攻擊**:Keeper 把多筆 order 合在一次 BatchProcess,用 pre-batch 快照算 `expected_mint`,但實際鑄 `expected_mint + 1`(rounding「剩餘」)→ 1 單位 vUSDCx 每筆 batch 對每位持有者稀釋約 1/total_shares。

**V1 防禦**:`vault_batcher.ak:valid_mint_ratio` 強制 `total_mint == Σ per_order_fair_shares`(**精確等於,沒有 tolerance**)。Rounding 剩餘無法被鑄——它會化成現有持有者的 share price 微升。

**狀態**:已關閉。

### 3.4 Keeper 錢包被劫持(在範圍,有界——operator 層 scope)

**層級 scope**:Keeper 錢包被入侵是 **operator 層**威脅。它影響 OptiVaults 代跑實例(或任何 fork)的運營可用性,但**不會蔓延到協議層**——使用相同 Aiken 合約、但獨立 keeper 錢包的 fork,不會受 OptiVaults 的 keeper 被入侵影響。下方的鏈上不變量約束 keeper 被入侵的傷害,**不論被入侵的是哪個實例的 keeper**。


**情境**:Keeper 熱錢包被入侵。攻擊者可以:
- 簽 Compound、RebalanceBuffer、MergeUtxo、BatchProcess、SupplyToLiqwid、RecallFromLiqwid、DeployToProtocol、VaultSwap、AdminDeployNonDeposit(僅 gov-path)、KeeperToggleMarket。
- 簽 VaultSwap 把金庫資金送到一個由攻擊者控制 owner 的 Minswap V2 order → fill 時資金流到攻擊者錢包。

**V1 的傷害範圍有界**:
- `verify_destination_whitelisted`——DeployToProtocol 的目標地址必須有 stake credential 在 `registry.protocol_hashes`。任意惡意接收地址的 stake credential 必須事先被白名單。
- `no_vusdcx_leak`(內部驗證期)——BatchProcess 不能把鑄出的 vUSDCx 路由到非 order-owner 地址。
- `verify_other_tokens_preserved`(內部驗證期)——非存入 token 不能透過 Compound / Rebalance 被抽走。
- Order 上的 `slippage_ok`(內部驗證期)——keeper 無法在超出使用者 `min_shares` 或 `max_shares_burn` 的價格偏差下執行 fill。
- `buffer_target_bps >= 500` 在 UpdateStrategy——但 keeper 無 UpdateStrategy 權限,僅治理可動。

**剩下的風險**:keeper 可以對 Minswap V2 做 `VaultSwap`,swap target 是 attacker 控制但仍在 `protocol_hashes` 白名單內的地址。防禦:`protocol_hashes` 白名單很緊(Minswap V2 order script + stake、Liqwid action address)。擴張白名單要走 `UpdateRegistry`(14 天 timelock)。

**Keeper-commission 沒收(slashing)**:V1 暫緩正式 slashing。V1 啟動時,keeper 被入侵的傷害由以上合約檢查界定 + 經濟現實:被入侵的 keeper 最多拿到 performance-fee 流(收益的 4.5% × keeper 40% 份額 ≈ gross yield 的 1.8%,100K TVL 下約 $108/年)。理性攻擊者的利潤上限**仍**低於入侵成本——V1 啟動的 40% 份額(在 validator 硬上限,以支持開源第三方 keeper 經濟可行性)讓 bounded loss 比舊 20% 翻倍,但 Phase 1 TVL 下數量級仍維持「僅創辦人威脅模型」。

### 3.5 治理被入侵造成 Treasury 抽乾

**情境**:m 位簽名者共謀,queue 一筆 `TreasurySpend`,目標是整個 buffer 類別的餘額。

**V1 防禦**:
- 7 天 timelock → 任何存入者都有 7 天退場。
- `audit_reserve_ratio >= 2000` 下限 → 即使治理也不能把 audit 類別降到 treasury 的 20% 以下。
- 1-of-n cancel → 任何剩餘的誠實簽名者都能否決。
- TX audit 軌跡——目的地地址在鏈上公開。

**殘餘風險**:真正的 m-of-n 共謀是 MultisigGov 的明確信任假設。緩解:公開簽名者身份、1 小時廣播義務、社群監控、7 天大規模提領窗口。

### 3.6 Liqwid 壞帳

**情境**:Liqwid 市場發生協議層損失(oracle 操弄、清算失敗、壞帳累積)→ 金庫的 qToken 變得低於 `supplied_value`。

**V1 行為**:
- `RecallFromLiqwid`(keeper 路徑):要求 `underlying_received >= supplied_value`。若 Liqwid 還得少,TX fail。Keeper 無法把損失自動化。
- `RecallFromLiqwid`(治理 fallback 路徑,keeper 停擺 7 天後):允許 `underlying_received < supplied_value`——物理 Recall 可回收的 underlying,並把實際實現的短缺(`supplied_value − underlying_received`)寫進 `total_deposited`。這是 Phase 1 治理安全(Layer 1,見 §5.4)下的標準損失寫入路徑。EmergencyWithdraw 自己**不能**寫掉部位——它只能切換 `frozen` flag。
- 存入者在治理 fallback Recall 完成後,透過 share price 下降按比例看到損失。

**逃生閥**:
- `KeeperToggleMarket`——keeper 單方可以停用一個市場(單向,`active: true → false`)。
- `EmergencyWithdraw`——治理凍結金庫以阻止後續 Compound / Supply / Deploy 操作,讓 Recall 路徑進行(Phase 1 Layer 1:freeze-only,見 §5.4)。
- `RecallFromLiqwid` 治理 fallback 路徑——物理 Recall underlying + 只寫入實際實現的損失。

### 3.7 USDCx 脫鉤

**情境**:USDCx 在 DEX 上交易到 $0.50,但 Circle xReserve 帳上仍 1:1 → 套利機會讓攻擊者以市價 $1 存 2 USDCx,換到價值 1 美元底層資產的份額。

**V1 防禦**:V1 **沒有**鏈上 USDCx 價格預言機。這是刻意的——加進 price feed 會引入 oracle 操弄攻擊面。

**鏈下防禦**:`tvlCapMonitor` + 透過 **Cardano 原生預言機** feed 的脫鉤監控(Charli3 + Orcfax + Minswap V2 TWAP 作為鏈上三方交叉驗證),15 分鐘 sustained 偏差門檻,每日 2 次觸發限流。**不使用跨鏈 oracle bridge**(與白皮書 §2.3 「no cross-chain bridges」一致)。先前內部驗證期的部署在鏈下輪詢 CoinGecko + DeFi Llama——測試階段方便,但那些是 web2 價格 API,不是鏈上 oracle。V1 上線設定改為鏈上 Cardano oracle。偵測到持續脫鉤時,keeper 觸發 `KeeperToggleMarket`(無 timelock)+ 治理 queue `EmergencyWithdraw`(timelock 依 `governance.md §4.6`)。

**Operator 義務**:在持續脫鉤訊號出現的 1 小時內停掉新存款。提領保持開放(client-side whitelist 從不阻擋提領——見白皮書 §9.2)。見白皮書 §6.5 揭露。

### 3.8 首位存入者份額稀釋(內部驗證期,已關閉)

**攻擊**:金庫狀態 `total_deposited = 1, total_shares = 10^15`。新存入者存 10 USDCx → 收到 `10 × 10^15 / 1 = 10^16` 份額,但既有持有者手上的 `1 × 10^15 / (10^15 + 10^16)` = 約原值的 9%,等同 multiplier 被重新鑄一次。

**V1 防禦**:每個 redeemer 都強制 `valid_deposited > 0` 與 `valid_shares > 0` 下限。`total_deposited = 0, total_shares > 0` 的 zombie 狀態**不可能存在**——EmergencyWithdraw 必須留下 ≥ 1 單位兩者,或改用不同 redeemer。

**狀態**:已關閉。

### 3.9 捐贈毒化

**攻擊**:攻擊者送帶任意 token 的 UTxO 到 proxy 地址,企圖撐大金庫或推高 min-ADA。

**V1 防禦**:
- MergeUtxo 白名單:只有 `{ADA、deposit token、registry.stable_tokens}` 才能被合併。其他 token 被拒——keeper 無法合併捐贈。
- 若捐贈 UTxO 合不進來,它會留在 proxy 地址沒被消費。攻擊者自願燒掉了自己的 token。
- `AdminDeployNonDeposit`(gov-path)可以回收合法卡住的 token。

**狀態**:已關閉。

### 3.10 Order UTXO 幽靈 datum(內部驗證期,已關閉)

**攻擊**:攻擊者在 proxy 地址放一筆 UTxO,datum 是偽造的 VaultDatum(在修復前的內部驗證程式碼中,`find_vault_datum_ref` 沒做 NFT 檢查)。Order 的 Expire redeemer 讀到這份假 datum,等同讓攻擊者 permissionless drain 自己控制的 order UTxO。

**V1 防禦**:`find_vault_datum_ref` 強制 `datum.vault_nft_policy != #""` 且 `quantity_of(value, vault_nft_policy, name) == 1`。沒有真實 Vault NFT 的假 UTxO 會被忽略。Expire fallback 退還 order 完整 value 給 owner。

**狀態**:已關閉。

---

## 4. 信任委派(明確列出)

V1 明確把信任委派給以下各方。存入者在存入之前應該逐一評估每個委派。

| 信任對象 | 委派範圍 | 限制 |
|---------|---------|------|
| **Keeper operator** | Swap 路由、compound 時機、策略內的配置 | Slippage 容忍度 + `protocol_hashes` 白名單 + 策略上限 |
| **治理簽名者** | 費率變更、策略變更、緊急動作 | Timelock + 1-of-n cancel + 費用硬上限 |
| **Liqwid 協議** | USDCx / DJED / USDM 被 supply 時的安全託管 | Liqwid 自己的審計 + 逃生閥(KeeperToggleMarket、EmergencyWithdraw) |
| **Minswap V2 batcher** | 以公平價執行 DEX order | 使用者自設 `min_shares` + slippage 檢查 + Cancel / Expire fallback |
| **USDCx 發行方(Circle 透過 xReserve)** | 透過 xReserve + USDC 本身的美元儲備維持 1:1 backing | Circle Deloitte 每月 attestation + 脫鉤監控 + operator 停機程序 |
| **Blockfrost / Ogmios indexing** | 為 keeper + API 提供準確的 UTxO 狀態 | 多來源冗餘 + 以鏈上驗證為 source of truth |

---

## 5. 縱深防禦分層

### 5.1 編譯時錨點(不重部署就不能改)

Validator hash + 基礎身份。任何一個變動都會強制新部署(新地址、要遷移)。

- `vault_nft_policy`——Vault NFT 身份(燒進 `vault_proxy` / `vusdcx` / `order`)
- `governance_policy` + `governance_name`——MultisigGov NFT 身份(燒進 `multisig_gov` / `keeper_stake_script`)
- `core_stake_hash`、`protocol_stake_hash`、`liqwid_stake_hash`、`admin_stake_hash`——Staking validator hash(燒進 `vault_proxy`)
- `keeper_stake_hash`——keeper_stake_script 的 hash(燒進 `vault_user` / `vault_keeper_hot` / `vault_protocol` / `vault_recall` / `vault_liqwid`)
- `treasury_hash`——Treasury script hash(燒進 `vault_keeper_hot` 用於 Compound 費用路由,Phase-77 後 Compound 從 vault_core 遷來這裡 + 燒進 `multisig_gov` 用於 DistributeSignerCompensation 的 forfeit 路由)
- `deposit_token_policy` + `deposit_token_name`——USDCx 的 policy / name(燒進 `treasury` + `multisig_gov`)
- `vusdcx_policy`——vUSDCx 份額 token 的 policy(以 `vault_hash` + `vault_nft_policy` 參數化的 minting policy 部署)
- `registry_hash`、`order_script_hash`、`vault_hash`——跨 validator 依賴錨點

關於 keeper 身份的備註:V1 **不**在編譯時錨定特定的 `keeper_pkh`。授權 keeper 集合是**治理可變**的(透過 `UpdateKeeperAuth`,14 天 timelock),改動的是 `keeper_stake_script` 的內部 datum。編譯時錨點是 stake-script **hash**,不是 PKH——讓輪替不必重部署。

### 5.2 Runtime 不變量(每筆 TX 強制)

- Token 保留(多輪內部驗證)
- 會計值非負(`idle_buffer >= 0`、`non_deposit_value >= 0`、執行後 `total_deposited > 0`)
- 費用上限(`performance_fee_bps <= 450`、`early_withdraw_fee_bps <= 100`)
- 時間欄位寬度上限(每個會寫時間的 redeemer `upper - now <= 1 小時`,內部驗證)
- Allocation 不變量(`alloc_sum + idle_buffer <= total_deposited + NDV + Σ liqwid_principal`)
- Share price 單調性(Deposit / Compound / Withdraw 保留或拉升 share price,內部驗證的 deferred-yield 規則)

### 5.3 經濟 / 社會層

- 100K USDCx pre-audit TVL 上限(operator 透過 `tvlCapMonitor` 自律執行)
- 治理簽名者身份公開揭露
- 治理 queue 的 1 小時廣播義務
- 有序停運協議(白皮書 §9.2)
- 放寬上限的閘門是第三方審計

### 5.4 Phase 1 治理安全 — 三層 founder-only-acceptable 設計

不論簽名者組成為何(3-of-3 with SPOs vs 單一簽名者 founder fallback),V1 上線時就帶有三個 **validator 層**的安全防護,在最壞單一簽名者失能情境下界定存入者損失。設計目標是讓 **founder-only Phase 1 治理成為合理的上線 fallback**——SPO 招募變成可信度加分項,而不是上線阻礙。

#### Layer 1 — `EmergencyWithdraw` 改為 freeze-only

`vault_gov_emergency.EmergencyWithdraw` 不能減少 `total_deposited`、不能移除或修改 `liqwid_positions`、不能接受 `loss_amount > 0`。它唯一能做的就是切換 `frozen` flag(0 ↔ 1)。實際損失帳務被限制在 `vault_liqwid.RecallFromLiqwid` 的治理 fallback 路徑——透過實體 Recall underlying USDCx 並只寫入實際實現的損失(`supplied_value − underlying_received`)。qToken 變孤兒攻擊面——被入侵的治理金鑰可以用「只動 datum 寫掉部位」讓 `share_price` 歸零——在 validator 層被根除(`validate_emergency_freeze_only` 在 `lib/vault/validation.ak`)。

#### Layer 2 — `DeployToProtocol` 在 freeze 下對 USDCx 例外

當 `frozen == 1` 且 redeemer 的 `deploy_token != deposit_token`,`vault_protocol.DeployToProtocol` 允許 swap-out。Keeper 可透過 registry 白名單的 SwapAdapter 把 NDV stable token(DJED、USDM)換回 USDCx,使 user `Withdraw` 在緊急 freeze 期間仍能完整支付按比例的份額。SwapAdapter validator 強制目的地 = vault 自己的地址,所以即使攻擊者掌握 keeper key 也無法把 output 改路;最壞情況只能逼出 Tier 2 peg-floor 邊界內的 slippage(≤ 5-7%),且 USDCx 仍然落到 vault 給 user 提領。沒有這層例外,freeze 一啟動 NDV 部分就會卡到 21 天後的 `AdminDeployNonDeposit` 治理 fallback 才能脫困——Layer 2 把這 21 天窗口縮短。Spec:`validate_deploy_frozen_gate` 在 `lib/vault/validation.ak`。

#### Layer 3 — `CommunitySunset` dead-man-switch

當 vault 連續 90 天無操作(`max(last_compound_time, last_realloc_time) + 90 天 ≤ now`),任何 vUSDCx 持有者都可呼叫 `vault_user` 中的 `CommunitySunset` permissionless redeemer。它原子性地把 `frozen` 設為 1、`community_sunset_triggered` 設為 1(單向不可逆)。一旦觸發:

- `vault_liqwid.RecallFromLiqwid` 接受任何簽名者(不需要 keeper 或治理簽名)。
- `vault_protocol.DeployToProtocol` Layer 2 路徑也接受任何簽名者(同上)。

90 天門檻相當於漏跑 ≈ 18 次 zero-yield heartbeat(每 5 天一次),等同於 keeper 完全死掉。Sunset 路徑**只開回收**——它不能修改 `total_deposited`、`total_shares`、`idle_buffer`、`liqwid_positions`,或任何 policy / immutable 欄位。Sunset 期間 SwapAdapter 的目的地、peg-floor、slippage 限制仍然生效,攻擊者無法利用開放的回收路徑抽走價值。

#### 情境演練

三層設計的目的就是在實際單一簽名者治理失能情境下界定存入者損失。每個情境描述攻擊者能做什麼、validator 怎麼回應、存入者最終結果、時間範圍。

**情境 A — Founder 誠實,vault 正常運作**
- 沒有偵測到異常。Compound + Recall + Supply + Withdraw 照常規節奏跑。
- 存入者結果:yield 完整累積,任何時候 Withdraw 立即結算 USDCx。
- 時間範圍:無限期。

**情境 B — Liqwid 真的出壞帳(沒有 key 失陷)**
- Liqwid 市場發生協議級損失(qToken rate 跌破 supplied basis)。
- 運營反應:治理 queue `EmergencyWithdraw(loss_amount=0, freeze=1)`。Frozen = 1 立即生效(0d timelock;multisig 還是要簽)。
- 存入者 `Withdraw` 繼續可用(Layer 1 沒改這個)。Idle-buffer 部分按未變的 `share_price` 立即支付。
- Liqwid 部分:keeper 驅動 `RecallFromLiqwid`(freeze 下仍允許)→ underlying 收回 vault NDV。短缺(`supplied_value − underlying_received`)在這時被寫入,`share_price` 按比例調整。然後 keeper 驅動 `DeployToProtocol` Layer 2 swap → USDCx 落到 `idle_buffer` → 存入者可提領回收的部分。
- 時間範圍:從事件偵測到完整結算 hours-to-days。

**情境 C — Founder key 被盜,攻擊者嘗試 grief-freeze**
- 攻擊者用偷來的治理 key 觸發 `EmergencyWithdraw`,試圖透過 datum 把 Liqwid 部分寫掉(pre-Layer-1 攻擊鏈)。
- Validator 反應:Layer 1 拒絕任何非零 `loss_amount` 與任何 `liqwid_positions` 變動。攻擊者只能設 `frozen = 1`——純 freeze 沒有價值影響。
- 存入者結果:`Withdraw` 繼續可用,立刻按比例支付 `idle_buffer`。Liqwid 部分,keeper(可能是同一個被入侵的對象,也可能不是)仍可驅動 `RecallFromLiqwid` + `DeployToProtocol` Layer 2 swap 把 NDV 換回 USDCx——產生的 USDCx 落到 vault 支付存入者。即使攻擊者也控制 keeper key,SwapAdapter validator 強制目的地 = vault address,攻擊者拿不走;最壞只能逼出每次 swap 最大 slippage drain NDV(每次 ≤ 7%,peg-floor 邊界)。
- 時間範圍:存入者 hours-to-days 內完整回收。最大損失:NDV 耗盡前每 cycle ≤ 7%。

**情境 D — Founder key 被盜,攻擊者連鎖 UpdateRegistry + AdminDeployNonDeposit**
- 攻擊者 queue `UpdateRegistry` 加入惡意 SwapAdapter(14 天 timelock)。
- 存入者透過 1 小時廣播義務看到 queued action,在 14 天窗口內 self-Withdraw 退場。14 天後 `AdminDeployNonDeposit` 還需要額外 7 天 keeper-inactive 窗口——攻擊者透過惡意 adapter 提取的總曝險窗口 ≥ 21 天。
- 存入者結果:任何留心的存入者在 14 天內退場、不受影響。漠不關心的存入者每 cycle 損失最多 ~7%(per-swap slippage cap)。
- 時間範圍:14-21 天 self-exit window。

**情境 E — Founder 失能、沒 SPO 共簽者、≥ 90 天無動靜**
- 創辦人聯絡不上 / 過世 / 失去 key。Keeper 停跑。90+ 天沒有任何治理動作 queue。
- 存入者反應:任何 vUSDCx 持有者呼叫 `CommunitySunset`。Frozen + sunset_triggered 設定。然後任何持有者 fire `RecallFromLiqwid` per market → underlying 收回。然後任何持有者 fire `DeployToProtocol` Layer 2 swap → USDCx 落到 vault。然後每位持有者 fire `Withdraw` → 拿回按比例的 USDCx。
- 存入者結果:完整按比例回收 USDCx。範圍外損失:~962 ADA reference-script 鎖定(創辦人部署錢包)、~28 ADA stake-credential 押金(治理 A2 路徑)——這兩部分作為單一簽名者治理的殘留成本被接受。
- 時間範圍:90 天門檻達到後,社群驅動回收 hours-to-days。90 天門檻本身就是觸發條件,從事件到回收啟動的總時間取決於運營失能偵測窗口。

**情境 F — Founder key 被盜 + 攻擊者也控制 keeper + 90 天過去**
- 攻擊者掌握所有 key 但拿不到任何價值(Layer 1+2+3 + 硬上限覆蓋所有路徑)。最終攻擊者 grief 慢慢停下,或存入者觸發 CommunitySunset。
- 存入者結果:透過 Scenario E 路徑完整按比例回收 USDCx。
- 時間範圍:同 Scenario E。

#### Sunset 範圍外

CommunitySunset **不**回收:
- 部署用的 ~962 ADA reference-script UTXO(創辦人部署錢包,只能用創辦人部署 key 回收)。
- ~28 ADA 的 stake-credential 押金(A2 ActDeregisterStake 需要治理 multisig)。

這是 operator/founder 端的損失,不是存入者損失,作為單一簽名者治理的殘留成本被接受。未來 founder 端的緩解措施(multi-sig 部署錢包、stake 押金的 dead-man-release)在 V1 上線範圍外。

---

## 6. 不在範圍內

### 6.1 USDCx 發行方失敗
V1 假設 USDCx 是正常運作、充分擔保的穩定幣。信任鏈上的失敗——Circle 的公司誠信、xReserve bridge 的安全、USDC 的美元儲備——都不在 V1 的威脅模型內。存入者應該另外評估 USDCx 自身的風險輪廓,包括 Circle 的合規姿態、xReserve 智能合約審計、以及 USDC 的 Deloitte attestation。

### 6.2 Cardano ledger 失敗
共識分裂、Plutus 編譯器 bug、stake pool 攻擊、鏈 re-org 都不在 V1 威脅模型內。V1 繼承 Cardano 的安全假設。

### 6.3 存入者實體錢包被入侵
使用者錢包被入侵時,他的份額會被提走。V1 不提供額外保護——這是使用者自己的金鑰管理。

### 6.4 法規 / 監管
V1 不做任何法規合規方面的承諾。使用者對自己司法管轄區的義務負責。

---

## 7. 殘餘風險總結

| 風險 | 發生可能 | 影響 | 緩解 |
|------|---------|------|------|
| 治理 m-of-n 共謀 | 低 | 高 | 公開身份、14 天 timelock、1-of-n cancel、有序停運 |
| Keeper 被入侵 + 白名單濫用 | 低 | 中 | 緊 `protocol_hashes`、策略變更僅治理、slippage 上限 |
| Liqwid 壞帳 | 中 | 中 | EmergencyWithdraw 逃生閥、KeeperToggleMarket 單向暫停 |
| USDCx 脫鉤 | 中 | 高 | 鏈下監控、operator 停機程序 |
| Minswap batcher 停擺 | 中 | 低 | Order Expire fallback 退錢給使用者 |
| 創辦人錢包被入侵 | 低 | 受 Layer 1+2+3 (§5.4) 限制:不能只動 datum 寫掉部位、swap 目的地鎖定 vault、最多 ~7%/swap NDV slippage drain。存入者完整回收靠 14 天 timelock 窗口或 90 天 CommunitySunset 路徑 | 三層治理安全 + 硬上限 + 14 天 timelock 窗口 + 90 天社群止血 fallback |
| V1 validator 的 Plutus bug | 低 | 高 | 內部審計(上線前 ≥1 輪外部)、責任揭露政策 + 酬庸式肯定框架(`docs/audit-scope.md §6`)、EmergencyWithdraw |
| 監管動作(SEC / MiCA / FinCEN / OFAC / 在地) | 低-中 | 高(operator 法律曝險) / 低(存入者本金——Withdraw 永遠開放) | 依白皮書 §12 採公共財定位(非商業、non-solicitation、地理架構);operator 可以依法律意見對特定司法管轄區 geoblock |

---

## 8. 審計姿態

V1 進入公開上線時帶有:
- **多輪內部驗證**——透過不變的 validator 模式沿用到 V1。
- 內部驗證階段 **0 CRIT / HIGH / MEDIUM**。
- **V1 特有的新範圍**(treasury、keeper_stake_script、V1 治理 redeemer)在 TVL 上限放寬前,需要額外內部輪次 + 至少一輪外部審計。

V1 審計計畫見 `docs/audit-scope.md`。

---

## 8.5 監管姿態

V1 定位為非商業 Cardano DeFi 公共財參考實作——**不是投資產品、不是基金、不是管理服務**。完整監管姿態在白皮書 §12 揭露(非投資 / 非招攬 / 地理架構 / code-is-law / 存入者盡職調查)。V1 的 bootstrap 策略明確**不追求** VC 募資、token 發行,或 SAFE / SAFT 承諾。

殘餘監管風險不為零,且隨 TVL 擴張:

- **Phase 1(100K 上限、TVL 預期 $5K-$25K)**:<5% 執法風險——金額規模在典型執法門檻以下
- **Phase 2(post-audit,上限提到 1M、TVL $100K-$500K)**:10-20% 可視性上升——放寬上限執行前建議先做地理姿態 + 法律 review
- **Phase 3+(TVL $1M+)**:30-50% 實質風險——進入此級別前建議先設立法律實體 + 合規政策

評估 V1 營運風險的審計事務所,應該把這條姿態視為**獨立於**智能合約風險面的額外考量。

---

## 9. 揭露政策

任何疑似漏洞請私下寄到 `optivaults@gmail.com`,建議用 PGP 加密(key 在 optivaults.app/security)。回應 SLA:24 小時確認收到、72 小時 triage;依嚴重性 tier 從 treasury audit reserve 類別支付 bounty。公開揭露預設 90 天協調窗口,除非漏洞正在被積極利用。
