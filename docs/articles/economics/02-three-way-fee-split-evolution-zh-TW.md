# 3-way fee split：keeper / gov pool / treasury 的演進

*OptiVaults V1 經濟模型解說，第 2 篇 / 共 4 篇*

---

[第 1 篇](./01-performance-fee-precise-semantics-zh-TW.md)講 4.5% 績效費怎麼算、validator 怎麼把 4.5% 鎖死。本篇處理下一層問題：**這 4.5% 收進來之後，怎麼分配？**

V1 把績效費拆成三流：**keeper（運作 keeper bot 的營運者）/ gov pool（治理簽名者的補償池）/ treasury（協議自己的金庫）**。啟動時的分配比例是 40 / 0 / 60，未來 phase 依 TVL 與簽名者組成演進為 40 / 5 / 55 → 40 / 10 / 50。

每個比例不是隨便挑的，它對應 V1 對「協議自主性」與「營運者經濟可行性」之間的具體權衡。本篇拆開這些權衡，並解釋為什麼有些上限是治理可調的、有些是 validator 寫死的。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。

---

## 三流，三個獨立 spend 路徑

先把鏈上機制講清楚。每次 Compound 觸發 fee 計算之後，validator 強制把 fee 按 `keeper_fee_bps` 與 `gov_fee_bps` 拆成三筆 output：

```
Compound TX outputs:
  ├─ Keeper share   = fee_amount × keeper_fee_bps / 10000
  │                   → 直接送到簽名 keeper 的地址（USDCx）
  ├─ Gov pool share = fee_amount × gov_fee_bps / 10000
  │                   → 累積於 MultisigGov UTXO 的
  │                     signer_compensation_pool 欄位（USDCx）
  └─ Treasury share = fee_amount × (10000 − keeper_fee_bps − gov_fee_bps) / 10000
                      → 流向 treasury 合約地址（USDCx）
```

三個 destination 各自有獨立的：

- **鏈上地址**:keeper 的個人地址、MultisigGov UTXO、treasury 合約地址。
- **Redeemer 授權路徑**:keeper 的 share 直接落到他的錢包，gov pool 由 `DistributeSignerCompensation`（季度結算）分配，treasury 由 `TreasurySpend`（治理 7 天 timelock）支用。
- **Timelock 設定**:`keeper_fee_bps` / `gov_fee_bps` 的調整走 `UpdateFeeSplit` 動作，timelock **21 天**（V1 所有治理動作中最長，理由稍後解釋）。

這個三流結構是 V1 鏈上分權的具體體現:三個口袋、三套規則、三層 timelock。

---

## 啟動分配：40 / 0 / 60

V1 啟動時的分配：

| 接收方 | 比例 | 含意 |
|--------|------|------|
| Keeper | 40% | 由創辦人運作的 keeper instance 收取 |
| Gov pool | 0%（停用） | Phase 1 啟動時關閉 |
| Treasury | 60% | 流向 4 類別預算（審計儲備 / 營運 / 研發 / 緩衝） |

幾個關鍵點：

**Keeper 40% 看起來高，但實際上是 net cost-centre**。100K TVL × 6% 毛收益 × 4.5% × 40% ≈ $108/年 — 在 Phase 1 baseline 配置下完全不足以覆蓋一個獨立營運者的基礎設施 + 監控成本（典型約 $400–$1,000/年）。Keeper 40% 上限刻意推高，是為了讓未來開放 keeper 註冊時（白皮書 §7.2 PermissionlessWithBond）非創辦人 keeper 的損益平衡 TVL 降到約 $1M，舊的 25% 上限對應 ~$1.5M，40% 上限降到 ~$1M。這是 V1 為「Phase 3+ 真正開放 keeper」鋪的結構性路。

**Gov pool 啟動時為 0**。Phase 1 由 3-of-3 簽名者治理（或於 SPO 招募延後時退到單一簽名者 fallback），治理活動稀疏，gov pool 在這個階段沒有經濟必要。把 `gov_fee_bps` 設為 0 等同於「停用 gov pool」，不會有 USDCx 累積在 MultisigGov UTXO，治理動作的 timelock 與 cancel 機制照常運作。

**Treasury 60% 是 protocol 自身**。這 60% 進到 treasury 合約地址，由 `TreasurySpend` 治理動作支用。Treasury 把累積的資金按 4 類別分配（審計儲備 40% / 營運 25% / 研發 25% / 緩衝 10%）；每一筆支出都要走 7 天 timelock。Treasury 不是任何個人的口袋，它是合約管控的資金池，所有支出在 cardanoscan 上可被任何人觀察。

---

## 演進：Phase 2 改成 40 / 5 / 55

當 TVL 跨過 $500K 並進入 Phase 2（白皮書 §6.1 定義的階段），分配演進為：

| 接收方 | 比例 | 變化 |
|--------|------|------|
| Keeper | 40% | 不變 |
| Gov pool | 5% | **啟用**（從 0 升到 5%） |
| Treasury | 55% | 從 60% 降為 55%（讓 5% 給 gov pool） |

Phase 2 啟用 gov pool 的觸發條件是 TVL ≥ $500K + 加入外部簽名者（社群徵選）。`UpdateFeeSplit` 是治理路徑（21 天 timelock），啟用 gov pool 需要簽名者全員同意把 `gov_fee_bps` 從 0 改成 500。

為什麼 Phase 2 才啟用 gov pool？因為 Phase 1 階段：

- 治理活動稀疏（偶爾的 UpdateStrategy、可能的緊急回應），不足以正當化常態 compensation。
- 創辦人的單一簽名者 fallback 情境下，gov pool 等同於「創辦人付給創辦人」，沒有意義。

Phase 2 後簽名者集合擴充到 5 位（包含至少一位社群徵選），治理活動量隨 TVL 提升、結構性異議否決也開始有實際工作量。這個時候啟用 5% gov pool 才能讓非創辦人簽名者有微小但非零的補償，把「Cardano 社群服務」維持為可永續的角色。

季度分配機制（`DistributeSignerCompensation`）有一條重要的「forfeit 條款」：如果某位簽名者在那個季度沒有透過 `Heartbeat` 維持 liveness，他在當期 pool 的份額會 forfeit，其他合格簽名者按比例多分。這條規則由 `multisig_gov.ak` 在 validator 層強制，不需要任何人線下決定誰合格。

---

## 終端：Phase 3 改成 40 / 10 / 50

當 TVL 跨過 $2M、進入 Phase 3：

| 接收方 | 比例 | 變化 |
|--------|------|------|
| Keeper | 40% | 不變 |
| Gov pool | 10% | 從 5% 升到 10% |
| Treasury | 50% | 從 55% 降到 50% — **觸及 validator hard floor** |

Phase 3 的關鍵性質是 **treasury 觸及 50% 硬下限**。V1 的 `validate_update_fee_split` 強制：

```
expect keeper_fee_bps <= 4000          // 40% 上限
expect gov_fee_bps <= 1000              // 10% 上限
expect keeper_fee_bps + gov_fee_bps <= 5000  // treasury 下限 50%
```

也就是說，**treasury 的 50% 是 validator 鎖死的，治理無論怎麼調整 keeper / gov pool 的比例，都不能讓 treasury 比例降到 50% 以下**。這個下限的存在理由：

- **審計儲備累積速率不被治理稀釋**。Treasury 內部分配中審計儲備佔 40%，因此「總 fee 進審計儲備」= 50% × 40% = 20%。這條進帳比例由 `treasury.ak` 在 `UpdateParams` 時強制 ≥ 20%（白皮書 §4.2 audit reserve floor）。Treasury 50% × audit-bucket 40% 下限的雙重保護，確保未來 V1.x / V2 審計委託的資金累積不被治理短期決策破壞。
- **協議自身的研發 / 營運預算結構性保留**。Treasury 25% 給研發 + 25% 給營運 + 10% 緩衝 = 50%；觸發的 floor 確保 protocol 在任何 fee split 配置下都有非零的自身營運餘力。

---

## 上限結構：4 條硬上限

把 fee split 的所有 validator 強制條件整理在一張表：

| 條件 | 數值 | 由誰守 | 含意 |
|------|------|--------|------|
| `keeper_fee_bps` | ≤ 4000 (40%) | `vault_gov_policy.UpdateFeeSplit` | Keeper 最多拿 40% |
| `gov_fee_bps` | ≤ 1000 (10%) | `vault_gov_policy.UpdateFeeSplit` | Gov pool 最多拿 10% |
| `keeper_fee_bps + gov_fee_bps` | ≤ 5000 (50%) | `vault_gov_policy.UpdateFeeSplit` | Treasury 至少 50% |
| Audit-bucket 內部進帳 | ≥ 2000 (20%) | `treasury.UpdateParams` | 審計儲備累積率 ≥ 20% |

第四條「audit-bucket 進帳 ≥ 20%」是 treasury 內部分配的下限，跟 fee split 是兩個層級的保護：

- Fee split 守的是「treasury 拿到多少 fee 總額」。
- Treasury params 守的是「treasury 拿到的總額裡多少進審計儲備」。

兩條乘起來：`50% × 20% = 10%` 是「總 fee 中至少 10% 累積在審計儲備」的結構性下限。治理無論在 fee split 或 treasury params 上做什麼調整，都不能讓未來審計委託的累積率降到這條線以下。

---

## 為什麼 `UpdateFeeSplit` timelock 是 21 天（V1 所有動作中最長）

V1 治理動作的 timelock 設定（依長短排序）：

| 動作 | Timelock |
|------|----------|
| `EmergencyWithdraw` | 0 天（freeze-only，仍需 3-of-3 簽名） |
| `FastUpdateMarkets` | 1 小時 |
| `UpdateSlippagePolicy` | 48 小時 |
| `UpdateStrategy` / `TreasurySpend` / `AdminDeployNonDeposit` | 7 天 |
| `UpdateFee` / `UpdateRegistry` / `UpdateKeeperAuth` / `RotateSigners` / 其他 | 14 天 |
| **`UpdateFeeSplit`** | **21 天** |

`UpdateFeeSplit` 是 V1 所有動作中 timelock 最長的，比修改費率、調整 registry、輪替簽名者都長。理由是：

**這是治理在調整自己的報酬**。當治理動作直接影響簽名者的個人收入（gov pool）或 keeper 的收入（keeper share），存入者最需要時間退場觀察。21 天的窗口讓任一存入者在生效前都有充足時間：

- 觀察 queue 的具體 payload（新比例、簽名理由）。
- 評估這個變動對自己持倉的長期含意。
- 如果決定退場，從容走 Direct Withdraw 或 Queue Withdraw。

21 天比較長，但在「治理調整自己報酬」這個特定情境下，把存入者保護放在第一位是合理的。其他動作（譬如 `UpdateStrategy` 調整配置）的影響是漸進的，7 天足夠反應；fee split 的影響是直接金錢，21 天的窗口更合宜。

`UpdateFeeSplit` 也跟其他治理動作一樣享有 1-of-n cancel，任一簽名者可在 21 天內否決。多重保護下，存入者很難在「治理悄悄把比例改掉」這個情境下受到實質損害。

---

## 鏈上獨立性 vs 啟動時人類控制者重疊

V1 把 fee split 設計成鏈上獨立的三個 destination，這是結構準備；但啟動時的**人類控制者明顯重疊**，需要誠實揭露：

- **Keeper** 由創辦人運作 → 創辦人。
- **Gov pool** 在 Phase 1 為 0%；若啟用，3-of-3 治理（含創辦人簽名）→ 含創辦人。
- **Treasury** 的支出需治理 3-of-3 同意 → 含創辦人。

三個流向的鏈上獨立性是真的，三個地址、三個 redeemer、三組 timelock。但簽名者集合在 Phase 1 重疊，所以**結構準備好了，去中心化還沒完成**。

這就是 V1 把「Six-identity separation」（白皮書 §6.1）放在路線圖上的原因。Phase 2 引入社群徵選簽名者、Phase 3 增加更多獨立簽名者，把人類控制者重疊度逐步拉低，目標是 Phase 4 評估 DAO 遷移。

V1 啟動的姿態是「在去中心化的路上、結構準備就位、誠實揭露當下狀態」，不是「我們現在已經是去中心化的」。這個區別對存入者很重要。

---

## 對比：傳統 DeFi vault 的 fee split 怎麼處理

很多 DeFi vault 的 fee 直接由 multisig 收取，分配規則寫在 readme 或部落格、不在合約裡。這意味著：

- Fee 進到單一錢包，後續分配靠 multisig 線下協調。
- 沒有 audit reserve hard floor、沒有 treasury minimum、沒有 keeper / governance 分流。
- 存入者要相信「multisig 會按 readme 分配」，這是 social commitment，無法用 ledger 驗證。

V1 的差異是把分配規則寫進 validator：每次 Compound TX 自動拆三流、每一流有獨立地址、每一條上限由 validator 強制。任何人可以在 cardanoscan 上對任一個 Compound TX 觀察：

```
Inputs:
  └─ Vault UTXO (包含 fee 對應的 USDCx)
Outputs:
  ├─ Keeper address: <USDCx amount A>
  ├─ MultisigGov UTXO: <USDCx amount B in signer_compensation_pool>
  └─ Treasury address: <USDCx amount C>

Verify:
  A / (A+B+C) == keeper_fee_bps / 10000
  B / (A+B+C) == gov_fee_bps / 10000
  C / (A+B+C) == (10000 - keeper_fee_bps - gov_fee_bps) / 10000
```

如果 keeper 構造的 TX 不滿足這個比例，validator 拒絕；ledger 不收。這條 verification 任何人可以重做，不需要相信創辦人或 multisig。

---

## 下一篇

第 3 篇處理 V1 經濟模型的一個結構性挑戰：**100K TVL 上限下、~$270/年的協議收入不足以覆蓋營運成本**。傳統 DeFi 應對的方式是「快速成長到自給規模」，但 V1 的姿態是「在低 TVL 下也能永續運作」。下一篇講 Reference Implementation Mode：低 TVL 公共財運作模式，怎麼把營運節奏降下來，讓 V1 在 $500-$25K TVL 下不需要靠成長壓力存活。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
