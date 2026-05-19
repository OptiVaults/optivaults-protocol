# OptiVaults V1 — Vault Identity NFT 規格

**範圍**:one-shot Vault Identity NFT 的 minting policy,以及它作為編譯時信任錨點的角色。

---

## 1. 目的

Vault Identity NFT 是鏈上用來區分**這個** V1 vault UTxO 與任何其他可能共用 `vault_proxy` script 地址的 UTxO 的 marker。設計上它承擔三件事:

1. **唯一鑄造**:整個 V1 生命週期內恰好只有一個 NFT(**無法重鑄**)。
2. **編譯時錨點**:NFT 的 minting policy 是 `vault_proxy`、`vusdcx`、`order` 的編譯時參數。在 vault 地址但缺 NFT 的 UTxO,對這三個 validator 而言不被視為 vault,這關閉了內部驗證期辨識出的「phantom vault」攻擊類別。
3. **burn 路徑永遠可用**:當 vault 最終 sunset(TVL drain、`total_shares == 0`)時,NFT 必須可以 burn,好讓最後的 vault UTxO 被銷毀、min-ADA 被回收。V1 設計明確要求「**burn 沒有任何時間截止限制**」(這也是 V1 不採用內部驗證期繼承的 native-script 截止模式的原因,見 §5「為什麼不用 native script」)。

---

## 2. Minting policy

Vault NFT 實作為一個 **PlutusV3 minting-policy validator**,以特定 UTXO 參照做參數化:

```aiken
use aiken/crypto.{ScriptHash}
use cardano/transaction.{Transaction, OutputReference, flatten}
use aiken/collection/list

// 編譯時參數:消費此 UTXO 參照 → 授權鑄造。
// 部署時選擇:部署者控制的、過去未被 spent 的任一 UTXO 都行。
validator vault_nft(utxo_ref: OutputReference) {
  mint(_redeemer: Data, policy_id: ScriptHash, tx: Transaction) {
    let mint_entries = flatten(tx.mint)
    let own_entries =
      list.filter(mint_entries, fn(entry) {
        let (policy, _, _) = entry
        policy == policy_id
      })
    // 把 own_entries 切成 burn(qty < 0)與 mint(qty > 0)。
    let is_burn = list.all(own_entries, fn(entry) {
      let (_, _, qty) = entry
      qty < 0
    })
    let is_mint = list.all(own_entries, fn(entry) {
      let (_, _, qty) = entry
      qty > 0
    })
    when (is_burn, is_mint) is {
      (True, _) ->
        // Burn 分支:無條件允許。任何持有 Vault NFT UTxO 的人,
        // 都可以在同一筆 TX 中 spend 它並 burn 掉 token。
        // 沒有時間限制、沒有簽名者限制。
        True
      (_, True) ->
        // Mint 分支:恰好一個名為 "OptiVault"、數量 1 的 token,
        // 且參數化的 UTXO 參照必須被當成 TX input 消費
        // (UTXO 只能被 spent 一次,所以這把鑄造牢牢綁在單一事件上)。
        and {
          list.length(own_entries) == 1,
          expect_one_opti_vault_mint(own_entries),
          list.any(tx.inputs, fn(i) { i.output_reference == utxo_ref }),
        }
      _ ->
        // 同一筆 TX 同時 mint + burn own_policy:拒絕。
        // 乾淨語意:只允許純 mint 或純 burn。
        False
    }
  }
  else(_) {
    // 此 validator 沒有 spend / withdrawal purpose。
    False
  }
}

fn expect_one_opti_vault_mint(entries: List<(ByteArray, ByteArray, Int)>) -> Bool {
  when entries is {
    [(_, name, qty)] -> name == "OptiVault" && qty == 1
    _ -> False
  }
}
```

**部署時選 `utxo_ref`**:V1 mainnet 部署 ceremony 期間,operator 挑一個自己控制、尚未被 spent 的特定 UTxO。這個 UTxO 成為編譯時參數,第一筆 mint TX 會消費它。消費之後,沒有任何未來 TX 能 replay 這次 mint(該 UTxO 已從 ledger 消失)。

---

## 3. 安全屬性

### 3.1 密碼學 one-shot(相對於信任基礎)

先前的內部驗證部署用的是形如 `{all: [sig(keeper_pkh), before(slot)]}` 的 **native-script** minting policy。這個設計是**基於信任**:

- 主要保證:只有 `keeper_pkh` 能 mint;系統依賴 keeper 承諾不會 mint 第二次。
- 次要保證:`before(slot)` 對所有 mint 畫一條硬性截止;截止後任何 mint 都不可能。
- 漏洞:若 `keeper_pkh` 在截止前被入侵,攻擊者可以用同一個 policy 鑄出第二個 Vault NFT,並端出一個 phantom vault。

V1 的 PlutusV3 設計是**密碼學 one-shot**:

- Mint 前置條件(`utxo_ref` 以 input 形式存在)是 ledger 層的事實,**只能被滿足一次**:UTxO 被 mint TX 消費之後,在後續狀態中不存在。
- Mint 分支**不需要**信任 keeper。被入侵的 keeper 密鑰無法鑄出第二個 NFT,因為第二個 `utxo_ref` UTxO 不存在、無從消費。

### 3.2 burn 永遠可用(相對於 deadline-trapped)

Native-script 模式對 mint 與 burn 使用同一份 script expression,所以 `before(slot)` 截止同時擋住截止後的 burn。內部驗證期的部署因此產生了**永久無法 drain 的** 遺留 mainnet vault:截止日(部署後約 2–5 天)過後,~15–20 ADA / vault 作為 reference-UTXO min-ADA 被鎖在鏈上無期限。

V1 的 PlutusV3 設計依 redeemer 數量正負拆分 script。Burn 分支**除了所有權之外不加任何約束**(持有 NFT 的 UTxO 必須能被持有者 spend,即一般 ledger 規則),任何 slot 都有效。這保留了 vault 的 sunset 路徑:

1. 所有存入者提領他們的份額(partial Withdraw)。
2. 最後一位持有者做 full-drain Withdraw,`total_shares → 0`,同一 TX 中 burn 掉 Vault NFT(`vault_user.ak` 的 `Withdraw` redeemer full-drain 分支在 Phase-77 後從 vault_core 遷來這裡,要求 `quantity_of(tx.mint, vault_nft_policy, "OptiVault") == -1`)。
3. `vault_nft` validator 的 burn 分支通過(無約束)。
4. Vault UTxO 被銷毀;min-ADA 回到提領者。

**沒有 ADA 被永久鎖住**。

### 3.3 鑄造數量安全

Mint 分支強制 `quantity == 1` + `asset_name == "OptiVault"`。企圖多鑄、零鑄、或用錯誤資產名,都被拒。配合 `utxo_ref` 的「只被消費一次」,這保證 V1 生命週期內全球 ledger 恰好存在一個 `(policy_id, "OptiVault")` token。

### 3.4 防 rogue-policy 注入

即使攻擊者部署自己的 `vault_nft` validator、用自己控制的另一個 UTxO 做參數、鑄出一個他叫做 "OptiVault" 的 token,因為 UTxO ref 參數不同、編譯出的 script hash 也不同,policy ID 就跟 V1 的不同。`vault_proxy` / `vusdcx` / `order` validator 把 V1 特定的 `vault_nft_policy` 燒進自己的編譯時參數,所以會拒絕任何**在 vault 地址但不帶 V1 特定 NFT policy token** 的 UTxO。**Phantom vault 攻擊在 validator 錨點層就被關閉,不是靠 policy 名字匹配。**

---

## 4. 生命週期

### 4.1 Mint(部署)

V1 mainnet 部署 ceremony(`docs/runbooks/v1-mainnet-ceremony.md`)期間:

1. Operator 挑一個自己控制的 unspent UTxO 作為編譯時參數
2. Operator 用該 UTxO ref 編譯 `vault_nft` validator → 產出 `vault_nft_policy`
3. Operator 以 `vault_nft_policy` 作編譯時參數,編譯 `vault_proxy`、`vusdcx`、`order`
4. Operator 建 vault-init TX,消費 `utxo_ref` 並鑄 1 × "OptiVault" token
5. Mint TX 把 token 輸出到 `vault_proxy` 地址的 vault UTxO(連同初始 vault datum + 任何 seed USDCx)
6. Mint 之後,`utxo_ref` 已不在 ledger 上 → 未來任何 mint 都不可能

### 4.2 日常運作(vault 運行)

Vault NFT 在每一筆 TX(Deposit、Withdraw、Compound、BatchProcess、DeployToProtocol 等)都留在 vault UTxO 內。`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_gov_emergency`、`vault_admin_deploy` 這些 validator 各自對 continuing output 強制 `quantity_of(output.value, vault_nft_policy, "OptiVault") == 1`,NFT 在 vault UTxO 內被物理保留。

### 4.3 Burn(sunset / V2 遷移)

Full-drain Withdraw(提領後 `total_shares = 0`)要求在同一筆 TX 中 burn 掉 NFT:

- Keeper 或創辦人建一筆 Withdraw TX,`withdraw_amount == vault_total`,`tx.mint` 包含 `(vault_nft_policy, "OptiVault", -1)`
- `vault_user.ak` 的 full-drain 分支檢查 `nft_burned == -1`
- `vault_nft` validator 的 burn 分支通過(無約束)
- Vault UTxO 被銷毀;min-ADA + 任何剩餘 token 流向 Withdraw redeemer 指定的接收地址

**不可能**在同一 policy 下鑄出第二個 NFT(參數化的 UTxO 早就被消費掉)。此 policy 實質上退役。

### 4.4 緊急 burn

若 V1 需要透過 `EmergencyWithdraw` 治理動作緊急下架,而不走 full-drain Withdraw,該治理 TX 可以直接 burn 掉 NFT,burn 分支永遠驗證通過。這是特殊情境但有支援:在 vault_core 有 bug 導致 full-drain 路徑無法執行時很有用。

---

## 5. 為什麼不用 native script

內部驗證期對 vault NFT 鑄造用的是 `{all: [sig, before(slot)]}` native script。那個選擇最佳化的是:

- **script 體積小**:native script 只有幾個 byte;PlutusV3 validator 有幾 KB。
- **mint 時零 Plutus 評估成本**:native script 的評估是 ledger 原生快速路徑;PlutusV3 評估會消耗 mem / steps。

V1 以 PlutusV3 換取的 trade-off:

- 密碼學(而不是信任基礎)的 one-shot 保證,關閉 keeper-key-compromise 的 mint 攻擊。
- burn 路徑**不**受截止日鎖死,乾淨 sunset、不永久鎖 ADA。
- ref-script 的 min-UTXO 略大(比 native 多 ~10–20 ADA,部署時一次性)。
- Mint + burn 有少量 Plutus eval cost(幾十萬 mem units)。

對「目標生命週期不定、sunset 路徑能實際回收 ADA」的 vault 而言,PlutusV3 是正確的交換。

---

## 6. 相關 spec

- `spec/architecture.md §4` — validator #11 摘要列
- `spec/vault-datum.md §2.3` — `vault_nft_policy` 如何作為 `vault_proxy`、`vusdcx`、`order` 的編譯時錨點使用
- `docs/security-model.md` — phantom vault 攻擊分析與內部驗證期的修補史
