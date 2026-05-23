# OptiVaults V1 為什麼有 17 個驗證器：四條正交切割線

*OptiVaults V1 合約架構解說 — 第 3 篇 / 共 4 篇*

---

[第 2 篇](./02-withdraw-zero-forwarding-pattern-zh-TW.md)介紹了 Withdraw-Zero Forwarding Pattern：把 vault 業務邏輯從 spending validator 搬到多個 staking validator。但「拆成多個」沒有講清楚拆成幾個、沿哪條線切。本篇回答這個問題。

OptiVaults V1 把 vault 邏輯切成 **17 個 logic validator + 4 個 NFT mint policy + `minswap_v2_adapter` + 2 個 SundaeSwap artefact = 24 個編譯產物**。對 Cardano vault 而言這算相當激進的拆法，很多現有 vault 設計只有 5–8 個 validator。V1 為什麼這麼多？

**因為拆分沿著四條正交切割線**，每一條都對應一個明確的設計約束。本篇逐條解釋。

---

## 切割線 1：授權邊界

不同 redeemer 需要不同的授權主體。把它們放在同一個 validator 會造成「為了驗證一個 deposit，整個 validator 必須在 spending 路徑上同時把 keeper-auth 邏輯也載入記憶體」。

V1 沿授權邊界拆出：

| Validator | 授權模型 | 涵蓋 redeemer |
|-----------|---------|---------------|
| `vault_user` | 純無許可（任何 CIP-30 錢包） | Deposit / Withdraw / CommunitySunset |
| `vault_keeper_hot` | Keeper 授權（透過 `keeper_stake_script` zero-withdraw） | Compound / RebalanceBuffer |
| `vault_batcher` | Keeper 授權 | BatchProcess |
| `vault_swap_ada` | Keeper 授權 | SwapAda（為什麼獨立切出，見切割線 3） |
| `vault_gov_policy` | 治理多簽（透過 spending MultisigGov UTXO） | UpdateStrategy / UpdateFee / UpdateFeeSplit / UpdateSlippagePolicy |
| `vault_gov_emergency` | 治理多簽 | EmergencyWithdraw |
| `vault_admin_deploy` | 治理多簽 | AdminDeployNonDeposit |

`vault_user` 只裝純無許可路徑這點很關鍵，它讓 deposit / withdraw 這兩個最高頻的使用者操作，不用為了 keeper-auth 或治理 multisig 邏輯付 ref-script fee。BatchProcess 雖然也是使用者面對的路徑，但它需要 keeper 授權（由 keeper 把若干筆排隊訂單彙整寫回 vault），所以拆到獨立的 `vault_batcher`，讓 `vault_user` 完全擺脫 keeper 授權編譯期參數，純化成「permissionless 三 redeemer」結構。

---

## 切割線 2：治理回應延遲

治理動作的 timelock 差異很大，從 emergency 的 0 天到 UpdateFeeSplit 的 21 天。把它們分開，等於把不同回應節奏的邏輯隔離：

| Validator | Timelock | Redeemer |
|-----------|----------|----------|
| `vault_gov_emergency` | **0 天** | EmergencyWithdraw（緊急凍結 vault） |
| `vault_gov_policy` UpdateSlippagePolicy | 48 小時 | 滑點政策 |
| `vault_gov_policy` UpdateStrategy | 7 天 | 策略配置 |
| `vault_gov_policy` UpdateFee | 14 天 | 績效費率 |
| `vault_gov_policy` UpdateFeeSplit | **21 天**（最長） | 三方分潤比例 |
| `vault_admin_deploy` | 7 天 keeper-inactive + 21 天 registry-stable | 非存入代幣回收路徑 |

**為什麼把 EmergencyWithdraw 獨立切出來？** 因為它是 0 day timelock 的特殊路徑，其他治理動作都要等 timelock，只有它可以即時生效（用來在被攻擊時凍結 vault）。把這條快速反應路徑保持在自己的 validator 上，**未來 SwapAdapter 擴充或其他治理邏輯增加時不會擴大緊急路徑的攻擊面**，`vault_gov_emergency` 永遠是「能在零時間內做這件事的最小邏輯集合」。

UpdateFeeSplit 的 21 天 timelock（V1 中所有治理動作裡最長）也有具體理由：這是治理調整自身報酬的動作（gov 簽名者本身可能拿到分潤）。把它放最長 timelock，等於給存入者最長的觀察窗口決定要不要在生效前退場。

---

## 切割線 3：bytecode cost center

某些 redeemer 因為依賴的 helper 而特別肥。把它們獨立出來，能讓其他 validator 不被拖累：

**`vault_swap_ada` 從 `vault_keeper_hot` 拆出**：SwapAda redeemer 需要讀 dual-feed oracle（Charli3 + Orcfax 中位數聚合，含 cross-feed 偏差檢查、staleness 檢查、min_feeds 門檻）+ 6-tuple registry 讀取。這段 bytecode 大約 4–5 KB，**只給 SwapAda 用**。

如果它跟 Compound / RebalanceBuffer 留在同一個 validator，Compound 每次跑都要把這 4–5 KB 也載入。拆掉之後，`vault_keeper_hot` 縮到 ~10.5 KB，`vault_swap_ada` 獨立成 12.2 KB；Compound TX 完全不載入 SwapAda 邏輯。

**`vault_admin_deploy` 從 `vault_gov_emergency` 拆出**：AdminDeployNonDeposit 包含 SwapAdapter 分派 + destination-whitelist 檢查 + 6-tuple registry 讀取，是治理路徑中最重的 redeemer。拆掉之後 `vault_gov_emergency` 縮到 ~12.6 KB，把 EmergencyWithdraw 保持在精簡的 validator 內。

**`vault_batcher` 從 `vault_user` 拆出**：BatchProcess 有四個獨立的 fold 迴圈（驗證每筆訂單的 owner / sums / vUSDCx 不外洩 / payout 唯一性）+ anti-leak 不變量，bytecode 規模 11.5 KB。它把 vault_user 從 keeper 授權編譯期參數中解放，deposit / withdraw 完全不需要關心 keeper 授權邏輯。

---

## 切割線 4：純粹的 size 上限

最後一條最不浪漫,「擠不進去」。

V1 引入 oracle / asset_oracles / Minswap V2 SwapAdapter dispatch 之後，原本的 `vault_protocol`（包含 DeployToProtocol + Recall + MergeUtxo）膨脹到 16.5 KB，**超出 16 KB 上限 116 B**。

不能不加這些功能，所以必須拆。沿著 DeployToProtocol / Recall 的自然分界切出：

- **`vault_protocol`**：DeployToProtocol（透過 SwapAdapter 分派到 Minswap V2）。13.1 KB / 約 3.3 KB headroom。
- **`vault_recall`**：RecallFromProtocol、MergeUtxo。13.3 KB / 約 3.0 KB headroom。

兩個合計 26.4 KB，跟拆分前的 16.5 KB 比起來增加 10 KB，其中大部分是分拆後兩邊共享的 helper（`get_continuing_datum` / `read_registry_datum` 等）。但每筆 TX 只用其中一個，所以 ref-script fee 沒有惡化。

---

## 17 個 logic validator 的最終形貌

四條切割線的綜合結果：

| Validator | 角色 | 大小 |
|-----------|------|------|
| `vault_proxy` | Withdraw-Zero 路由器 | ~4.9 KB |
| `vault_user` | Deposit / Withdraw / CommunitySunset | ~12.5 KB |
| `vault_keeper_hot` | Compound / RebalanceBuffer | ~10.5 KB |
| `vault_batcher` | BatchProcess | 11.5 KB |
| `vault_swap_ada` | SwapAda（dual-feed oracle） | 12.2 KB |
| `vault_protocol` | DeployToProtocol（SwapAdapter 分派） | 13.1 KB |
| `vault_recall` | RecallFromProtocol / MergeUtxo | 13.3 KB |
| `vault_liqwid` | SupplyToLiqwid / RecallFromLiqwid | 13.4 KB（最緊） |
| `vault_gov_policy` | UpdateStrategy / Fee / FeeSplit / Slippage | 12.6 KB |
| `vault_gov_emergency` | EmergencyWithdraw | ~12.6 KB |
| `vault_admin_deploy` | AdminDeployNonDeposit | 13.2 KB |
| `keeper_stake_script` | Keeper 授權規則 | 8.8 KB |
| `treasury` | 金庫手續費分桶與支出 | 9.9 KB |
| `multisig_gov` | m-of-n 治理狀態機 | 8.3 KB |
| `registry` | 協議白名單 + asset_oracles + swap_adapter_hashes | 8.5 KB |
| `order` | 訂單 Process / Cancel / Expire | 3.8 KB |
| `vusdcx` | 份額代幣鑄造政策 | 1.3 KB |

加上 4 個 NFT mint policy（`vault_nft` / `governance_nft` / `registry_auth_nft` / `gov_signer_nft`）+ `minswap_v2_adapter` + 2 個 SundaeSwap artefact,總共 24 個編譯產物。

最緊的目前是 `vault_liqwid` 還剩約 3 KB headroom。所有 24 個編譯產物都安全落在 16 KB 之內。

> **註:第二個 DEX adapter。** V1 的 24 個 artefact 裡有兩個是 SundaeSwap SwapAdapter（`sundaeswap_adapter` 加上配套的 `sundaeswap_cancel_guard`）。它們在部署儀式中綁定，是每一次 V1 launch 部署的一部分，但它們屬於 DEX adapter 的擴充,與本文討論的、由 size 推動的核心拆分是不同的兩件事。見 `spec/swap-adapter.md §8`。

---

## 拆分的代價

完整起見，把代價也說清楚：

**(a) Ceremony 部署 TX 數變多**：V1 ceremony 需要 42 筆 TX（3 個 NFT 鑄造 + 20 個 ref script 部署 + 14 個 stake credential 註冊 + 5 個 state UTXO 初始化），總共約 1,039 ADA 的 ref-script 鎖倉與註冊押金（ref scripts 可在 sunset 時透過 `reclaim-refs.ts` 回收）。如果整個 vault 是單一 validator，ceremony 大概只需 5–10 筆 TX。

**(b) 審計表面變大**：每個 staking validator 是獨立的審計目標。內部審計累積多輪審查並修復 findings，其中有些 finding（例如 `vault_keeper_hot` 的 Compound 路徑當初沒驗證 gov input 的 spending redeemer 是 `ReceiveCompoundShare`，導致 gov_share 可能被誤認為其他治理動作的副產物）正是因為 validator 拆得多、跨 validator 之間的 binding 不顯眼才漏掉的。

**(c) 部署時序更脆弱**：20 個 ref script 部署的順序與依賴鏈（vault_proxy 的編譯期參數需要 10 個 stake hash 都已決定）讓 ceremony 很容易踩到 TX 排序與 wallet UTXO 競爭問題。V1 的 `deploy.ts` 整套有 checkpoint 機制 + 自動 resume，這在這個拆分規模下是必備的。

但拆分的好處，能突破 16 KB、能讓使用者只付實際 ref-script fee、能讓授權邊界天然分離，對使用者體驗與安全模型的價值比這些代價大很多。所以 V1 選擇了這個方向。

---

## 模式的可推廣性

最後一個提醒:什麼會延伸到 OptiVaults V1 之外、什麼不會。

本篇文章建立在底層技術 — **Withdraw-Zero Forwarding**,把業務邏輯從 spending validator 搬到多個 staking validator、由一層薄薄的 proxy 路由 — 之上;這是一個**通用的 Cardano DeFi 模式**,適用於任何撞到 16 KB Plutus V3 上限、或想要 per-TX ref-script fee 隨實際 redeemer 使用而成比例的協議。通用文件(獨立於 OptiVaults 特定細節)在 [`spec/pattern-rationale-withdraw-zero-forwarding.md`](../../../spec/pattern-rationale-withdraw-zero-forwarding.md)。

而上表中**具體的 17-validator 目錄** — 那組精確的集合 `vault_user` / `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada` / `vault_protocol` / `vault_recall` / `vault_liqwid` / `vault_gov_policy` / `vault_gov_emergency` / `vault_admin_deploy` / `keeper_stake_script` / `treasury` / `multisig_gov` / `registry` / `order` / `vusdcx` / `vault_proxy`,沿四條切割線切分 — 是 **OptiVaults V1 特有的**。這裡展示的切分軸是被 V1 自己的邏輯組合所推動(`vault_gov_policy` 的八個 redeemer、`vault_swap_ada` 裡的 dual-feed oracle、`vault_protocol` 的 SwapAdapter dispatch、`vault_liqwid` 的逐市場部位追蹤)。另一個套用 Withdraw-Zero 的協議會沿著自己的 redeemer 面切分 — 不同的切割軸、不同的 validator 數。

簡單講:**模式**是通用的,**目錄**是特定的。V1 為未來 CIP 考量所文件化的五個模式見 [`docs/cip-readiness-posture.md`](../../cip-readiness-posture.md) §2,V1 明確標為「專案特定、不是 CIP 候選」的元件見其 §6。

---

## 小結

V1 的 17 個 logic validator 不是隨意切的。沿著**授權邊界**、**治理回應延遲**、**bytecode cost center**、**純粹的 size 上限** 四條正交切割線，每個拆分都對應一個具體的設計約束。

代價是 ceremony 變複雜、審計表面變大、部署時序更脆弱；好處是突破 16 KB、ref-script fee 按實際使用付費、授權邊界天然分離。

下一篇會講最後一塊：**vault state 怎麼存、29 欄位 VaultDatum 的可變/不可變分割、以及編譯期 Vault NFT Anchor 怎麼防 phantom-vault 攻擊**，這是 V1 對[第 1 篇](./01-eutxo-vault-design-constraints-zh-TW.md)約束 4「UTXO identity 沒有原生概念」的答案。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
