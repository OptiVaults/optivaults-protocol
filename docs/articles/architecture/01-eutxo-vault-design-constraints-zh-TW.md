# 在 Cardano eUTXO 上做 vault 的四個設計約束

*OptiVaults V1 合約架構解說 — 第 1 篇 / 共 4 篇*

---

OptiVaults V1 是 Cardano 上第一個非託管穩定幣自動收益金庫。使用者存入 USDCx，取得 vUSDCx 份額代幣；金庫把資金部署到 Liqwid 的 DJED / USDM 借貸市場賺取利息，定期複利回寫進份額價格。所有與本金有關的操作都由 Aiken PlutusV3 合約強制，協議營運方在任何 redeemer 路徑下都無法挪動使用者本金。

如果你只熟悉 Ethereum / Solidity 上的 ERC-4626 vault，Cardano eUTXO 上的等效實作會看起來不太自然。**重點是底層模型不同**。本系列會解釋 V1 的合約架構：為什麼是 17 個 logic validator + 4 個 NFT mint policy + `minswap_v2_adapter` + 2 個 SundaeSwap artefact（共 24 個編譯產物），為什麼採用 Withdraw-Zero Forwarding Pattern，狀態為什麼集中在單一 UTXO，以及 Vault NFT 的編譯期錨點解決了什麼問題。

本篇先講設計起點：在 eUTXO 上做 vault 會踩到的四個結構性約束。理解這四個約束，後面三篇講的設計選擇就會有完整脈絡。

整個專案以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)，本系列提到的每個檔案都可以對照閱讀。

---

## 約束 1：沒有 mutable global state

EVM 上一個 vault 是一個合約地址，內部變數存在持久化的 storage slot 裡，使用者透過 `deposit()` / `withdraw()` 函數呼叫直接修改 state。Cardano eUTXO 沒有這種東西。

你的 vault state 必須以 **UTXO 形式**存在某個 script 地址，每筆 TX 的本質是「消滅舊 UTXO + 產生新 UTXO」的原子置換。Validator 的工作是檢查新舊 datum 的差是否合法。

這帶來幾個直接的設計後果：

**(a) 並行性受限**：同一個 UTXO 在同一個 block 只能被花費一次。如果 vault state 是單一 UTXO，那同一個 block 裡頂多只有一筆 TX 可以更新 vault。所有試圖同時操作 vault 的使用者必須排隊。

**(b) 不能「讀取」state 而不消耗它**：要讀 vault datum，要嘛把 vault UTXO 當 input 消耗（會更新它）、要嘛當 reference input（不消耗，但你不能修改它）。沒有 EVM 那種「我呼叫一個 view 函數讀某個 state slot 然後決定要不要寫回」的中間狀態。

**(c) 跨 UTXO 操作要協調**：如果你把 state 分散到多個 UTXO（例如 buffer 一個、Liqwid 部位一個、accounting 一個），要做「同時 Recall DJED + Supply USDM」這種跨組合的操作，就要把所有相關 UTXO 在同一筆 TX 中一起 input。這會讓 UTXO 相依鏈變得複雜，並且任何一個 UTXO 在你 build TX 之後被別人花掉，整筆 TX 就要重 build。

V1 的回應是把 state 集中在單一 UTXO，並用 Order UTXO（每個使用者各自獨立）解耦使用者層的並行。第 4 篇會講細節。

---

## 約束 2：每個 input 觸發 spending validator 完整執行

Cardano 的 spending validator 在被花費時會被執行，validator 邏輯是「給定這筆 TX 的 context，我這個 UTXO 可不可以被花掉」的判斷函數。

如果你的 vault 是「持有 vault state UTXO」+「spending validator 驗證所有規則」，那每一筆涉及 vault 的 TX 都會把 spending validator 整段跑一次。

問題是 **Plutus V3 的 reference script 上限是 16 KB**，超過就無法部署。一個有完整 deposit / withdraw / compound / batch / liqwid supply / liqwid recall / governance / emergency 邏輯的 vault validator，輕易就會撞到上限。

實際上 V1 的核心業務邏輯加起來會是這樣（按邏輯模組分組的大致規模）：

| 邏輯模組 | 大致規模 |
|---------|---------|
| Deposit / Withdraw / 提早退場路徑 | ~12 KB |
| BatchProcess（4 個 fold 迴圈） | ~11 KB |
| Compound / RebalanceBuffer | ~10 KB |
| SwapAda（dual-feed oracle） | ~12 KB |
| SupplyToLiqwid / RecallFromLiqwid | ~13 KB |
| DeployToProtocol / RecallFromProtocol / MergeUtxo | ~26 KB |
| 治理動作（UpdateStrategy / Fee / FeeSplit / Emergency / AdminDeploy） | ~38 KB |

把這些業務邏輯硬塞進單一 validator，bytecode 會是 16 KB 上限的數倍，根本無法部署。即使你想辦法把它壓進去，下一個約束會繼續折磨你。

---

## 約束 3：reference script fee 跟大小成正比

Conway 紀元起，Cardano 對 reference script 加了新的計費規則：每筆 TX 都要付 `min_fee_ref_script_cost_per_byte × 累積 ref-script bytes` 的費用，而且累積到一定 threshold 之後 cost-per-byte 會階梯上升。

對 vault 設計的影響：**validator 越大，使用者每次互動的 fee 越高**。一個 16 KB 的單一 vault validator，每筆 deposit / withdraw / compound 都要把 16 KB 算進 fee 計算。

V1 採用的拆分策略下，一筆 deposit TX 只需要參考 `vault_proxy`（~4.9 KB）+ `vault_user`（~12.5 KB），總共 ~17 KB；一筆 compound TX 參考 `vault_proxy` + `vault_keeper_hot`（~10.5 KB）+ `keeper_stake_script`（~8.8 KB），總共 ~24 KB。看起來各別 TX 都還大，但**沒有任何一筆 TX 需要載入 V1 的全部邏輯**，你 deposit 的時候不會載入 emergency 路徑，你 compound 的時候不會載入 BatchProcess 邏輯。

如果不拆，每筆 TX 都得載入完整 vault 邏輯付 ref-script fee；拆分之後，每筆 TX 只付它真的用到的那部分。長期下來，這對小額存入者的成本敏感度差異很大。

---

## 約束 4：UTXO identity 沒有原生概念

最後一個約束最微妙。

你的 vault state UTXO 跟其他人在同個 script 地址產生的 UTXO，**從 ledger 角度看沒有差別**。Cardano 沒有「這個 UTXO 是 vault 的真實 state」這種原生概念，任何人都可以把一個 UTXO 送到 `vault_proxy` 地址。

這帶來的攻擊面：

- **Phantom UTXO 攻擊**：攻擊者在 `vault_proxy` 地址產生一個 phantom UTXO，攜帶他自己編造的 datum。如果你的 indexer / frontend / 其他 validator 用 script address 作為「這是 vault」的判準，就會把 phantom UTXO 當真。
- **跨合約信任失效**：如果 `vusdcx` 鑄造政策的規則是「在 spending vault UTXO 的 TX 中可以鑄造份額」，但「vault UTXO」的定義只是「在 vault_proxy 地址的某個 UTXO」，那攻擊者可以建一個假 vault UTXO，配上自己的假 datum，誘騙 vusdcx 鑄造任意多的份額代幣。

EVM 上這個問題不存在，因為合約地址本身就有 identity，但 Cardano 上你必須額外加入「這真的是我的 vault」的檢查機制。

V1 的解法是 **Vault Identity NFT + 編譯期錨點**：用一個 PlutusV3 UTXO-ref one-shot policy 鑄造一個全鏈唯一的 NFT，把 NFT 的 minting policy 烘進 `vault_proxy` / `vusdcx` / `order` validator 的編譯期參數，讓「真實 vault」的定義變成「持有那個特定 NFT 的 UTXO，在那個特定的 vault_proxy 地址」，而那個 vault_proxy 地址本身的存在前提就是它的 script hash 內含了正確的 NFT policy。第 4 篇會細講這個三層 anchoring 的結構。

---

## V1 的回應，預告

四個約束加起來的設計方程式是：

- **約束 1** 推 V1 走向「單一 vault state UTXO + Order UTXO 解耦並行」
- **約束 2** 推 V1 走向「拆解 vault 邏輯到多個 staking validator」
- **約束 3** 推 V1 走向「按 redeemer 用途分組拆分，讓每筆 TX 只付實際用到的 ref-script fee」
- **約束 4** 推 V1 走向「Vault NFT + 編譯期 anchoring」

V1 對前三個約束的綜合答案是 **Withdraw-Zero Forwarding Pattern**，把業務邏輯從 spending validator 搬到多個 staking validator，spending validator 退化成一層薄薄的轉發器，由 redeemer 決定路由到哪個 staking validator。

對第四個約束的答案是把 Vault NFT 的 minting policy 變成 spending validator 的編譯期參數，讓 phantom UTXO 從架構層級就無法被合法視為 vault。

讀者若想看 **V1 的回應如何延伸到 OptiVaults 之外**，四個約束各自對應到一個在 Cardano DeFi 中反覆出現的模式:

- **約束 2 + 3**（大小限制 + per-TX ref-script 費用）→ **Withdraw-Zero Forwarding Pattern**,通用模式文件在 [`spec/pattern-rationale-withdraw-zero-forwarding.md`](../../../spec/pattern-rationale-withdraw-zero-forwarding.md)。V1 的 `vault_proxy` + 10 個被路由的 staking validator 是其中一個具體實例。
- **約束 4**（UTXO 沒有原生身份）→ **Validator Identity NFT Pattern**,通用模式文件在 [`spec/pattern-rationale-validator-identity-nft.md`](../../../spec/pattern-rationale-validator-identity-nft.md)。V1 的 Vault NFT + `vault_proxy` / `vusdcx` / `order` 編譯期錨點是其中一個具體實例。

V1 對這些模式以及 Cardano Improvement Proposal 流程的更廣立場見 [`docs/cip-readiness-posture.md`](../../cip-readiness-posture.md)。立場文件是**資訊性質的** — V1 發布模式 rationale,但在 V1 release 階段不會撰寫 CIP 提案。

接下來三篇會分別深入：

- **第 2 篇**：Withdraw-Zero Forwarding Pattern 是怎麼運作的、有什麼效益、一筆 Compound TX 怎麼跑
- **第 3 篇**：17 個 logic validator 沿著哪四條正交切割線拆分、每個 validator 各自負責什麼
- **第 4 篇**：單 UTXO 狀態模型（29 欄位 VaultDatum、15 不可變 + 14 可變）與編譯期 Vault NFT Anchor

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
