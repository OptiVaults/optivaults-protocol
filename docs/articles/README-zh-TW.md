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

---

## Medium 對應

每篇文章也會發佈在 Medium，canonical URL 指回此 repository。

- *（Medium 連結會在發佈時補上。）*

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
