# Phantom-vault 攻擊向量：為什麼編譯期錨點比 runtime 檢查強

*OptiVaults V1 安全設計解說，第 4 篇 / 共 4 篇*

---

[Architecture 系列 Article 4](../architecture/04-vault-datum-and-nft-anchor-zh-TW.md) 已經介紹過 V1 的編譯期 Vault NFT Anchor 高層概念：用 PlutusV3 UTXO-ref one-shot 鑄造唯一的 Vault Identity NFT，並把 NFT 的 minting policy 烘進 `vault_proxy` / `vusdcx` / `order` 三個 validator 的編譯期參數。

那篇講的是「方案是什麼」。本篇講的是「為什麼這個方案是必要的」，把 phantom-vault 攻擊向量拆開來看，走過幾條看起來像解法但實際上守不住的設計，最後說明為什麼編譯期錨點是 Cardano 上唯一結構性堵死這個攻擊面的方式。

V1 的安全姿態裡，這條設計線是「把信任鏈在編譯期就鎖死」最具代表性的案例。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。

---

## 問題的起點：UTXO identity 在 Cardano 沒有原生概念

[Architecture 系列 Article 1](../architecture/01-eutxo-vault-design-constraints-zh-TW.md) 講過約束 4：你的 vault state UTXO 跟其他人在同個 script 地址產生的 UTXO，**從 ledger 角度看沒有差別**。

Cardano 沒有「這個 UTXO 是 vault 的真實 state」這種原生概念。任何人都可以把一個 UTXO 送到 `vault_proxy` 地址，並附帶任意 datum。Validator 在被 spend 時被執行，validator 邏輯只能看「這筆 TX 的 context 是否合理」，它沒辦法直接查詢「我這個 script 地址在哪一個 UTXO 是 vault 的真實 state」。

把這個約束跟 vault 的功能需求疊在一起，就會撞到一個結構性攻擊面。

---

## Phantom-vault 攻擊的具體形式

攻擊者的目標通常不是把 vault 的 state UTXO 偷走（這需要繞過完整的 spending validator 邏輯，難度很高），而是**讓另一個合約把 phantom UTXO 當作真實 vault**，透過這個誤判把份額代幣鑄造出來。

走一個具體例子。`vusdcx` 是 V1 的份額代幣鑄造政策，它的鑄造規則大致是：「在 spending 一個 vault UTXO 的 TX 中，可以按 `expected_shares` 公式鑄造對應的份額代幣。」

如果 `vusdcx` 對「vault UTXO」的判定機制不夠嚴格，攻擊者可以這樣走：

```
[1] 攻擊者建立 phantom UTXO
    ├─ 地址：vault_proxy 的地址（任何人都能往這個地址送 UTXO）
    ├─ 附帶 datum：自己編造的 VaultDatum
    │             — total_deposited = 0
    │             — total_shares = 0
    │             — 其他欄位填充看似合法的值
    └─ 附帶 token：攻擊者自己鑄造的一個 NFT，假裝是 vault identity

[2] 攻擊者建構一筆 TX
    ├─ Input: 上面那個 phantom UTXO（會觸發 vault_proxy 的 spending validator）
    ├─ Mint:  請求 vusdcx 政策鑄造大量份額代幣
    └─ Output: 份額代幣全部送到攻擊者錢包

[3] 攻擊者期望
    └─ vusdcx 的政策看到「TX 中有 vault UTXO 被 spend + 持有 NFT」
        → 通過鑄造請求
        → 攻擊者得到憑空鑄造的份額代幣
        → 拿去 V1 的 frontend 走 Direct Withdraw 換 USDCx
```

如果這個攻擊路徑能跑通，V1 的所有經濟保證就崩了，攻擊者可以憑空鑄造份額代幣，把其他存入者的本金抽走。

問題的關鍵是：**`vusdcx` 政策怎麼判斷「這個 UTXO 是真實 vault」？**

---

## 第一個（不夠的）解法：檢查 script address

最直觀的判斷是「Input 來自 `vault_proxy` 的 script address」。

這是不夠的。攻擊者的 phantom UTXO 確實就在 `vault_proxy` 的 script address，這個地址對所有人開放，沒辦法阻止別人往那裡送 UTXO。任何「在 vault_proxy 地址的 UTXO 都算 vault」的判斷，就把 phantom UTXO 當真了。

`vault_proxy` 的 spending validator 會被觸發、會跑邏輯，但 `vault_proxy` 也只是檢查「這筆 TX 的結構合不合法」，它沒有辦法區分「這個 spend 觸發者是不是真實 vault」。

---

## 第二個（仍然不夠的）解法：檢查 datum 中的 NFT 資訊

下一個直覺解法：在 datum 裡寫一個 `vault_nft_policy: PolicyId` 欄位，並讓 `vusdcx` 檢查「被 spend 的 UTXO 持有對應 policy 的 NFT」：

```aiken
fn is_real_vault(utxo: Output, datum: VaultDatum) -> Bool {
  quantity_of(utxo.value, datum.vault_nft_policy, vault_nft_name) == 1
}
```

這也守不住。攻擊者可以這樣做：

1. 自己創建一個 minting policy `attacker_nft_policy`，鑄造一個 NFT。
2. 在 phantom UTXO 的 datum 裡寫 `vault_nft_policy = attacker_nft_policy`。
3. 在 UTXO 上附帶 `attacker_nft_policy.vault_nft` 這個 token。

`is_real_vault()` 跑出來會返回 `true`，因為 datum 自己宣告了 NFT policy、UTXO 確實持有對應 NFT。但這個 NFT 跟 V1 真正的 Vault NFT 完全無關，是攻擊者另外鑄造的。

問題的根源是：**`datum.vault_nft_policy` 是 runtime 才能讀到的值，攻擊者可以任意設定**。如果 validator 的 identity 判斷依賴 runtime 資訊，那 identity 就可以被 runtime 偽造。

---

## 第三個（接近但還不夠的）解法：把 NFT policy 寫進 validator 的 redeemer 或常數

接下來的直覺：那 NFT policy 不要從 datum 讀，從 validator 自己的某個固定來源讀。

但這個「固定來源」如果是 redeemer，那攻擊者構造 TX 時可以帶入任意 redeemer 值。如果是 validator 內部的某個 helper function 返回的常數，除非這個常數真的「綁定到部署這個 validator 的某個唯一身份」，否則攻擊者可以重新部署一個帶不同常數的 fork validator，跟自己的 phantom UTXO 配對使用。

這條路線的最終形態就是「把 NFT policy 變成 validator 的編譯期參數」，也就是 V1 採用的方案。

---

## V1 的解法：編譯期參數

```aiken
validator vault_proxy(
  // ...其他 stake hash 參數...
  vault_nft_policy: PolicyId,  // ← 編譯期常數
) { ... }

validator vusdcx(
  vault_hash: ByteArray,
  vault_nft_policy: PolicyId,  // ← 同一個編譯期常數
) { ... }

validator order(
  vault_hash: ByteArray,
  vault_nft_policy: PolicyId,  // ← 同一個編譯期常數
) { ... }
```

部署 ceremony 跑 `aiken build` 時，這個 `vault_nft_policy` 會被烘進 validator bytecode。**已部署的 `vault_proxy` script hash 唯一對應到一個 `vault_nft_policy`**，你無法用同一個 `vault_proxy` 來持有不同 policy 的 NFT，因為 `vault_proxy` 的 script hash 本身就是「baked-in 那個 NFT policy 之後的 hash」。

更進一步，`vusdcx` 與 `order` 也以**同一個編譯期參數**烘進去。三個獨立 script 的 hash **都被同一個 vault_nft_policy 鎖死**。

把這個機制套回 phantom-vault 攻擊：

```
攻擊者構造 phantom UTXO
  ↓
phantom UTXO 必須送到「某個 vault_proxy 的 script address」才能觸發 spending validator
  ↓
如果送到 V1 真實部署的 vault_proxy script address：
  → vault_proxy 的 spending validator 會檢查「被 spend 的 UTXO 持有
     vault_nft_policy 鑄造的 NFT」
  → vault_nft_policy 是 baked-in 的，攻擊者無法修改
  → phantom UTXO 只持有 attacker_nft，不持有真實 Vault NFT
  → validator reject

如果送到「攻擊者自己 fork 的 vault_proxy script address」：
  → fork 出來的 vault_proxy 帶不同的 vault_nft_policy 參數
  → 因此 hash 跟 V1 部署的 vault_proxy 不同
  → 攻擊者的 fork script address 跟 V1 完全是兩個地址
  → V1 的 frontend / indexer / vusdcx / order 全部不認這個地址
  → 攻擊者就算成功 spend 自己的 phantom UTXO，鑄造的份額代幣
     也不是 V1 的 vUSDCx（policy hash 不同），無法在 V1 的 vault 兌換 USDCx
```

整個信任鏈在編譯期就被鎖死，runtime 沒有任何彈性可以被 fool。

---

## 為什麼三個 validator 都要綁同一個 NFT policy

只把 `vault_nft_policy` 烘進 `vault_proxy` 還不夠。

如果 `vusdcx` 不也綁這個 policy，攻擊者可以這樣繞：

1. Fork `vault_proxy` 換成自己的 `attacker_nft_policy` → 部署到一個新的 script address。
2. 攻擊者在新 address 鑄造一個假 Vault NFT、創建 phantom UTXO、把份額代幣鑄造請求發給原本 V1 的 `vusdcx`。
3. 如果 `vusdcx` 只檢查「TX 中有 vault UTXO 被 spend」而不檢查「那個 vault UTXO 在哪一個特定的 script address 下」，攻擊就成立。

V1 的回應是把 `vusdcx` 也烘進同一個 `vault_nft_policy`，`vusdcx` 在執行時會檢查「TX 中被 spend 的 vault UTXO 必須持有 `vault_nft_policy` 鑄造的 NFT」。攻擊者 fork 出來的 vault_proxy 用的是不同 NFT policy，這個檢查直接 fail。

同樣的邏輯適用於 `order`，它管 deposit / withdraw queue，是另一個會跟 vault 互動的 script。三個 script 共用同一個編譯期 anchor，phantom UTXO 就算能進到任何一個 script 的觸發路徑也會被另一個 script 擋下。

---

## NFT 本身：PlutusV3 UTXO-ref one-shot

把 `vault_nft_policy` 烘進 validator 的編譯期參數，前提是「那個 NFT policy 真的全鏈唯一、無法被偽造」。如果 NFT policy 本身可以被攻擊者隨便鑄造，這套錨定就還是塌掉。

V1 用 PlutusV3 UTXO-ref one-shot pattern 鑄造 Vault NFT：

```aiken
validator vault_nft(utxo_ref: OutputReference) {
  mint(_redeemer, _own_policy, tx) {
    // 鑄造時，這個特定的 utxo_ref 必須在 inputs 裡（被消耗）
    list.any(tx.inputs, fn(i) { i.output_reference == utxo_ref })?
  }
  // burn 路徑無條件允許
}
```

`utxo_ref` 是部署 ceremony 開始時挑的某個 UTXO（通常是 deploy wallet 持有的普通 ADA UTXO）。鑄造 NFT 的條件是「在 mint TX 中花掉這個 UTXO」，一個 UTXO 只能被花掉一次，所以這個 NFT 一輩子只能被鑄造一次。

鑄造完成後，那個 utxo_ref 已被消耗、永遠無法重現。沒有人能再次觸發鑄造，即使他持有 mint script 源碼、即使他擁有 deploy wallet 私鑰、即使他能 fork 整個 V1。**鑄造能力是 ledger 層級永久關閉的**。

這個 pattern 不是 V1 發明的，Cardano 社群已經用過幾年，但 V1 把它應用在三層 anchoring 上：

| Anchor | NFT | 用途 |
|--------|-----|------|
| Vault identity | `vault_nft` | 識別真正的 vault state UTXO |
| Governance identity | `governance_nft` | 識別真正的 MultisigGov UTXO（鎖死治理動作必經之 UTXO） |
| Registry authentication | `registry_auth_nft` | 識別真正的 Registry UTXO（鎖死協議白名單） |

三者都用同一個 PlutusV3 UTXO-ref one-shot 模式。每一個 anchor 各自處理一類 phantom 攻擊：phantom vault state、phantom 治理 UTXO、phantom registry。

---

## 為什麼比舊式 native script 更乾淨

Cardano 上另一種常見的 NFT one-shot 模式是 native script 加 `before` deadline：

```
{ all: [signature(deploy_pkh), before(deadline_slot)] }
```

機制：deploy wallet 簽名 + 在某個 deadline 之前鑄造。Deadline 過了之後，這個 NFT policy 就無法再鑄造任何東西，「one-shot」靠時間限制達成。

這個寫法有兩個結構性缺陷：

**(a) 信任 deploy wallet**。Deadline 之前任何時刻，deploy wallet 的私鑰持有者都可以再鑄造一個 NFT。鑄造的「one-shot」屬性靠的是「我們相信 deploy wallet 不會在 deadline 前再鑄造一次」，這是信任假設，不是結構保證。

**(b) Deadline 過後無法 burn**。當 deadline 過期，整個 native script 都失效，包括 burn 路徑。如果 vault 要 sunset 並 burn 掉 Vault NFT 清空 state，deadline 過了就做不到。Vault NFT 卡在 vault UTXO 裡，UTXO 的 min-ADA（約 15-20 ADA）永久鎖死。

V1 的 PlutusV3 UTXO-ref one-shot 在這兩個面向都嚴格優於 native script：

- **信任屬性**：鑄造能力來自 UTXO 的不可重現性（ledger 層保證），不是「我們相信 deploy wallet」。
- **Burn 路徑**：burn 分支永遠允許，無時間限制，sunset 可以乾淨執行。

代價是 PlutusV3 mint policy 的 script size 略大於 native script（一個 UTXO-ref 檢查的 Aiken validator 通常落在 1-2 KB），但這個成本是可接受的。

---

## 為什麼這條設計線值得單獨講

V1 的合約裡有很多防禦機制，slippage 邊界、payload-hash 綁定、registry whitelist、validity-range cap，每一條都重要。但 phantom-vault anchor 這條設計線有個獨特的屬性：

**它把信任鏈在編譯期就鎖死，runtime 無法被 fool。**

很多 Cardano DeFi 合約在內部審計過程裡，會發現某些 runtime 檢查可以被巧妙構造的 datum 或 redeemer 繞過。每一次發現都是補一條檢查、加一個 require、寫一個 invariant。這些補丁有效，但每一條都增加了表面積，將來的 audit 必須驗證「這條檢查在所有情境下都跑」。

編譯期錨點的不同在於：它不是檢查，而是身份綁定。已部署的 `vault_proxy` script hash 就是 baked-in 那個特定 NFT policy 後的 hash，這不是 runtime 條件，是 script hash 的定義。攻擊者要繞過它，唯一的方法是重新部署一個帶不同 NFT policy 的 fork validator，而那個 fork 跟 V1 完全是不同的 script address，跟 V1 部署的 vault 沒有任何鏈上連結。

這就是「結構性安全」與「檢查性安全」的分水嶺。V1 在能用結構性安全的地方優先用結構性安全，編譯期 anchor 就是這個原則的代表案例。

---

## 系列總結

四篇文章走到這裡：

- **[第 1 篇](./01-three-layer-governance-safety-zh-TW.md)**：三層治理安全為什麼能讓單一簽名者治理成為可接受的 fallback
- **[第 2 篇](./02-adversarial-chain-replay-methodology-zh-TW.md)**：鏈上對抗性重放，把「合約應該拒」變成「合約確實拒」
- **[第 3 篇](./03-multi-stablecoin-depeg-not-real-diversification-zh-TW.md)**：多穩定幣配置不是真分散，誠實揭露相關性風險
- **第 4 篇（本文）**：phantom-vault 攻擊向量與編譯期 NFT anchor

OptiVaults V1 完整原始碼以 Apache 2.0 授權公開在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。內部審計已歷經多輪審查並修復 findings；目標 2027 年 Q2-Q3 完成第三方審計。

V1 在 mainnet 啟動時設定 100,000 USDCx 的營運上限，直到第三方審計完成。整個專案的定位是 Cardano DeFi 公共財參考實作，歡迎 fork、特化、商業化使用，也歡迎在 GitHub Issues 或 [Discord](https://discord.gg/HY5sy8cz8s) 提出對抗性檢視。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)。*
