# OptiVaults V1 技術文章

OptiVaults V1 設計決策的長篇技術解說。這些文章與形式規格（[`spec/`](../../spec/)）與[白皮書](../../whitepaper/whitepaper-zh-TW.md)互補，以敘事方式說明特定架構選擇背後的「為什麼」。

文章與整個協議一同以 Apache 2.0 開源。

For the English version, see [README.md](./README.md).

---

## 系列

文章按主題分為不同系列子資料夾。

### [架構系列（Architecture）](./architecture/)（共 4 篇）

完整走過 V1 的合約架構：從 eUTXO 上的四個設計約束、Withdraw-Zero Forwarding Pattern，到 17 個驗證器拆分與編譯期 Vault NFT 錨點。

| # | 文章 | 閱讀時間 |
|---|------|---------|
| 1 | [在 Cardano eUTXO 上做 vault 的四個設計約束](./architecture/01-eutxo-vault-design-constraints-zh-TW.md) | ~6 分鐘 |
| 2 | [Withdraw-Zero Forwarding Pattern：把 vault 邏輯搬到 staking validator](./architecture/02-withdraw-zero-forwarding-pattern-zh-TW.md) | ~6 分鐘 |
| 3 | [OptiVaults V1 為什麼有 17 個驗證器：四條正交切割線](./architecture/03-seventeen-validators-four-cuts-zh-TW.md) | ~6 分鐘 |
| 4 | [單一 UTXO 狀態與編譯期 Vault NFT Anchor](./architecture/04-vault-datum-and-nft-anchor-zh-TW.md) | ~7 分鐘 |

每篇文章都可獨立閱讀，但彼此遞進。首次接觸者建議依 1 → 2 → 3 → 4 順序讀完。已熟悉 eUTXO 取捨的 Cardano 開發者可略過第 1 篇。

### [安全系列（Security）](./security/)（共 4 篇）

V1 的合約層安全設計：三層治理保護、鏈上對抗性重放方法論、多穩定幣風險的誠實揭露，以及 phantom-vault 攻擊向量與編譯期 NFT 錨點。

| # | 文章 | 閱讀時間 |
|---|------|---------|
| 1 | [三層治理安全：在單一簽名者治理下保住存入者的回收路徑](./security/01-three-layer-governance-safety-zh-TW.md) | ~7 分鐘 |
| 2 | [鏈上對抗性重放：把「合約應該拒」變成「合約確實拒」](./security/02-adversarial-chain-replay-methodology-zh-TW.md) | ~9 分鐘 |
| 3 | [多穩定幣配置 ≠ 真正的風險分散](./security/03-multi-stablecoin-depeg-not-real-diversification-zh-TW.md) | ~7 分鐘 |
| 4 | [Phantom-vault 攻擊向量：為什麼編譯期錨點比 runtime 檢查強](./security/04-phantom-vault-and-compile-time-anchor-zh-TW.md) | ~11 分鐘 |

安全系列補架構系列的安全面。建議讀過架構系列之後再讀；其中第 4 篇與架構系列第 4 篇有遞進關係，建議連讀。

### [經濟模型系列（Economics）](./economics/)（共 4 篇）

V1 的經濟設計：4.5% 績效費的精確語意、三流分配演進、低 TVL 公共財運作模式，以及 volunteer-builder + audit-as-cap-lift-gate 框架。

| # | 文章 | 閱讀時間 |
|---|------|---------|
| 1 | [4.5% 績效費：公式、不變式、validator-level 硬上限](./economics/01-performance-fee-precise-semantics-zh-TW.md) | ~9 分鐘 |
| 2 | [3-way fee split：keeper / gov pool / treasury 的演進](./economics/02-three-way-fee-split-evolution-zh-TW.md) | ~10 分鐘 |
| 3 | [Reference Implementation Mode：低 TVL 下的公共財運作](./economics/03-reference-implementation-mode-zh-TW.md) | ~9 分鐘 |
| 4 | [審計是 cap-lift gate，不是 launch gate：volunteer-builder 框架](./economics/04-volunteer-builder-audit-cap-lift-gate-zh-TW.md) | ~10 分鐘 |

經濟系列獨立於架構與安全系列；想理解 V1「為什麼是公共財、不是商業產品」的讀者建議從此系列入手。第 4 篇是 V1 整體姿態的核心揭露。

### [營運機制系列（Operations）](./operations/)（共 3 篇）

V1 的營運層機制：SwapAda 鏈上 ADA 補充閉環、7 天 keeper-inactivity dead-man-switch、三條 withdraw 路徑對照。

| # | 文章 | 閱讀時間 |
|---|------|---------|
| 1 | [SwapAda：用 dual-feed oracle 做鏈上 ADA 補充閉環](./operations/01-swapada-dual-feed-oracle-loop-zh-TW.md) | ~11 分鐘 |
| 2 | [7 天 keeper-inactivity dead-man-switch：讓存入者不必信任 keeper](./operations/02-seven-day-keeper-inactivity-dead-man-switch-zh-TW.md) | ~10 分鐘 |
| 3 | [三條 Withdraw 路徑：Direct / Queue / Emergency 怎麼選](./operations/03-three-withdraw-paths-zh-TW.md) | ~12 分鐘 |

營運系列偏向實務細節，適合準備存入或想知道 V1 在 mainnet 上「怎麼跑」的讀者。第 3 篇對所有存入者都實用，與其他系列獨立可讀。

---

## Medium 對應

每篇文章也會發佈在 Medium，canonical URL 指回此 repository。

- *（Medium 連結會在發佈時補上。）*

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
