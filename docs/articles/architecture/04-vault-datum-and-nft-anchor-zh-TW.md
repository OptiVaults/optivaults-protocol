# 單一 UTXO 狀態與編譯期 Vault NFT Anchor

*OptiVaults V1 合約架構解說，第 4 篇 / 共 4 篇*

---

[第 1 篇](./01-eutxo-vault-design-constraints-zh-TW.md)講了在 Cardano eUTXO 上做 vault 的四個設計約束。[第 2 篇](./02-withdraw-zero-forwarding-pattern-zh-TW.md)介紹 Withdraw-Zero Forwarding Pattern。[第 3 篇](./03-seventeen-validators-four-cuts-zh-TW.md)解釋 V1 為什麼把 vault 邏輯切成 17 個 validator。

本篇處理最後一塊：**vault state 怎麼存、29 欄位 VaultDatum 切成 9 不可變 + 8 政策可變 + 12 會計／運營三層、以及編譯期 Vault NFT Anchor 怎麼防 phantom-vault 攻擊**。這是 V1 對第 1 篇約束 4「UTXO identity 沒有原生概念」的回應。

---

## 為什麼是單一 UTXO

V1 把整個 vault 的可觀察狀態壓在**單一 UTXO** 裡，存在 `vault_proxy` 地址。這個 UTXO 持有：

- 所有未部署的 USDCx（buffer）
- 所有當前持有的 DJED / USDM 部位（在 swap 與 Liqwid supply 中間流動的非存入代幣）
- 所有 Liqwid 部位的 qToken 收據
- accounting datum（`VaultDatum`，29 個欄位）
- 一小撮 ADA 滿足 minimum-UTXO 要求

為什麼是單 UTXO 而不是多 UTXO？

eUTXO 的並行模型是「同一個 UTXO 在同一個 block 只能被花費一次」。如果 vault state 散在多個 UTXO，跨 UTXO 操作（例如「同時 Recall DJED + Supply USDM」）就會碰到 UTXO 相依鏈的協調問題：必須把所有相關 UTXO 在同一筆 TX 中一起 input，任何一個 UTXO 在你 build TX 之後被別人花掉，整筆 TX 就要重 build。

單 UTXO 是 Cardano DeFi 上 vault 設計的標準做法。

**並行存取的問題另外處理**：使用者透過 Order UTXO（多個獨立 UTXO，使用者各自 Queue）排隊存提款，由 keeper 在 BatchProcess TX 中一次彙整若干 Order 寫回單一 vault UTXO。這把使用者層的並行從 vault state UTXO 解耦，使用者下單不需要互相競爭 vault UTXO，只競爭自己的 wallet UTXO。

---

## 29 欄位 VaultDatum

VaultDatum 29 個欄位分三層：**9 個不可變**、**8 個政策可變**（在硬性邊界內由治理調整）、**12 個會計／運營**（每次操作可能更新）。

### 12 個會計／運營欄位（每次操作可能更新）

- `total_deposited`：vault 持有的 USDCx 總本金
- `total_shares`：vUSDCx 份額代幣總供應量
- `idle_buffer`：未部署的 USDCx，可立即提款
- `non_deposit_value`：vault 中持有的非存入代幣（DJED / USDM / qToken）的 USDCx 等值
- `strategy_allocations`：跨 yield 協議的當前資金配置
- `liqwid_positions`：各市場的 supplied_value + qtokens_held
- `last_compound_time`：最近一次 compound 時戳
- `last_realloc_time`：最近一次零收益再分配時戳
- `last_fee_update_time`：UpdateFee cooldown 錨點
- `last_ada_swap_time`：SwapAda cooldown 錨點
- `frozen`：緊急凍結旗標
- `community_sunset_triggered`：Phase 1 dead-man-switch 旗標

### 8 個政策可變欄位（由治理透過專屬 UpdateFee / UpdateFeeSplit / UpdateStrategy redeemer 在硬性邊界內調整）

- `performance_fee_bps`：績效費率（**硬上限 4.5%**）
- `early_withdraw_fee_bps`：早提款費率（**硬上限 1%**）
- `min_hold_seconds`：直接提款冷卻（**硬上限 6 小時**）
- `buffer_target_bps`：目標緩衝比率
- `keeper_fee_bps`：keeper 在 3-way fee split 的份額（**硬上限 40%**）
- `gov_fee_bps`：治理池在 3-way fee split 的份額（**硬上限 10%**）
- `max_slippage_bps`：§5.4 P2 Tier 1 oracle 公允價邊界（**硬上限 5%**）
- `min_swap_peg_bps`：§5.4 P2 Tier 2 peg-floor 邊界

政策可變層由 `check_policy_fields_unchanged` 在每一條非治理 redeemer 強制檢查。唯一能動這些值的，就是上述三條治理 redeemer，每條都有自己的 timelock 與 m-of-n 門檻。硬上限在 validator 層強制：治理在任何 redeemer 路徑下都不可能突破。

### 9 個不可變欄位（部署時設定，每次 TX 由 `check_immutable_fields` 強制檢查不變）

- `vault_version`：合約版本識別碼
- `governance_policy` / `governance_name`：Governance NFT 識別
- `vusdcx_policy`：份額代幣鑄造政策雜湊
- `deposit_token_policy` / `deposit_token_name`：USDCx 識別
- `order_script_hash`：Order validator hash
- `registry_hash`：Registry validator hash
- `registry_auth_policy`：Registry auth NFT policy

V1 刻意**沒有**把 `keeper_pkh` 或 `fee_collector` 放進 datum。Keeper 授權委派給 `keeper_stake_script`（每一條 keeper 觸及的 validator 都以其 stake hash 為編譯期參數的獨立 staking validator）；fee 目的地是 `treasury` script 地址（`vault_keeper_hot` 的編譯期參數）。兩個錨點都放在 validator hash 而非 datum，這在結構上比任何 datum 保證更強，因為控制 datum 的攻擊者都還是換不掉這兩個值。

`check_immutable_fields` 是 V1 安全模型的一個基石：**任何改動以上 9 個欄位的 TX，所有 vault staking validator 都會 reject**。配合 `check_policy_fields_unchanged`（在非治理 redeemer 守住 8 個政策可變欄位），總共 17 個欄位在任何非治理路徑上都結構性鎖死。

也就是說，已部署 vault 的這 9 個欄位是**已部署 validator hash 的客觀屬性**，不是「我們承諾不改」，是「合約結構上根本不允許改」。`vault_version` 永遠不會變、Governance NFT identity 永遠不可能被替換、USDCx identity 永遠不會漂移，這些都是任何人可以拿 ledger 資料自己驗證的客觀事實，不需要相信營運方任何承諾。8 個政策可變欄位加上第二層：可以動，但只能透過專屬治理 redeemer、只能在 validator 強制的硬上限內、只能在各自的 timelock 過後。

---

## phantom-vault 問題

[第 1 篇](./01-eutxo-vault-design-constraints-zh-TW.md)約束 4 講過：你的 vault state UTXO 跟其他人在同個 script 地址產生的 UTXO，從 ledger 角度看沒有差別。

**普通的 NFT 識別（runtime check）**長這樣：

```aiken
fn is_real_vault(utxo: Output, expected_policy: PolicyId) -> Bool {
  quantity_of(utxo.value, expected_policy, vault_nft_name) == 1
}
```

問題是 `expected_policy` 是 runtime 參數。攻擊者只需要說服 indexer / frontend / 其他 validator 「這個 phantom UTXO 對應到一個假的 expected_policy」，整個 identity check 就會被繞過，因為 validator 只檢查「這個 UTXO 持有 NFT 等於我傳進去的 policy」，但**「我傳進去的 policy」本身可能是假的**。

實際的攻擊向量大概是這樣：

1. 攻擊者觀察到 V1 的 `vusdcx` 鑄造政策的規則大致是「在 spending 一個 vault UTXO 的 TX 中，可以鑄造對應的份額代幣」。
2. 攻擊者建立一個 phantom UTXO 在 `vault_proxy` 地址，持有他自己鑄造的假 NFT，配上自己編造的 datum（`total_deposited = 0, total_shares = 0`，看起來像一個空 vault）。
3. 攻擊者在 TX 中花費這個 phantom UTXO，並請求 `vusdcx` 鑄造任意多的份額代幣。
4. 如果 `vusdcx` 政策只檢查「TX 中有 vault UTXO 被花費 + 持有 NFT」而沒有額外驗證 NFT 的 policy 是「真的那一個」，攻擊就成立。

V1 必須有一個機制讓 `vusdcx`、`order`、`vault_proxy` 這三個獨立 script 都能**唯一無爭議地識別「真正的 vault」**。

---

## 編譯期 Vault NFT Anchor

V1 的解法是把 `vault_nft_policy` 變成 validator 的**編譯期參數**：

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

部署時 ceremony 跑 `aiken build` 會把這個 `vault_nft_policy` 烘進 validator bytecode。**已部署的 `vault_proxy` script hash 唯一對應到一個 `vault_nft_policy`**，你無法用同一個 `vault_proxy` 來持有不同 policy 的 NFT，因為 `vault_proxy` 的 script hash 本身就是「baked-in 那個 NFT policy 之後的 hash」。

更進一步，`vusdcx`、`order` validator 也以**同一個編譯期參數**烘進去。三個獨立 script 的 hash **都被同一個 vault_nft_policy 鎖死**。

**攻擊者要繞過這個 anchor，不只要建假 vault UTXO，還要產生一組能對應到那個假 policy 的 `vault_proxy` + `vusdcx` + `order` script hash**，而這些 hash 會跟 V1 已經部署在鏈上的 hash 不同。整個體系從 frontend / indexer / 其他 validator 都無法把它認成 V1 vault：

- Frontend 只認鏈上發布的固定 `vault_proxy` 地址。
- Indexer 只追蹤那個固定地址 + 持有特定 NFT 的 UTXO。
- 其他 validator（`vusdcx` / `order`）的 spending 規則檢查的是 baked-in 的 vault hash，攻擊者的假 UTXO 不在那個 hash 對應的地址下。

整個信任鏈在編譯期就被鎖死，runtime 沒有任何彈性可以被 fool。

---

## Vault NFT 本身：PlutusV3 UTXO-ref one-shot

最後一塊：「鎖死」要成立，前提是那個 `vault_nft_policy` 真的全鏈唯一、無法被偽造。

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

`utxo_ref` 是部署 ceremony 開始時挑的某個 UTXO（通常是一個 deploy wallet 持有的普通 ADA UTXO）。鑄造 NFT 的條件是「在 mint TX 中花掉這個 UTXO」，一個 UTXO 只能被花掉一次，所以這個 NFT 一輩子只能被鑄造一次。

鑄造完成後，那個 utxo_ref 已被消耗、永遠無法重現。**沒有人能再次觸發鑄造**，即使他持有 mint script 源碼、即使他擁有 deploy wallet 私鑰、即使他能 fork 整個 V1。鑄造能力是 ledger 層級永久關閉的。

這個 pattern 不是 V1 發明的，Cardano 社群已經用過幾年，但 V1 把它應用在**三層 anchoring** 上：

| Anchor | NFT | 用途 |
|--------|-----|------|
| Vault identity | `vault_nft` | 識別真正的 vault state UTXO |
| Governance identity | `governance_nft` | 識別真正的 MultisigGov UTXO（鎖死治理動作必經之 UTXO） |
| Registry authentication | `registry_auth_nft` | 識別真正的 Registry UTXO（鎖死協議白名單） |

三者都用同一個 PlutusV3 UTXO-ref one-shot 模式，**比舊的 native script 加 deadline 寫法乾淨得多**，後者在 deadline 過期後會讓 NFT 無法被燒毀，把 sunset 路徑卡住。

---

## 連起來看

V1 對 vault state 的設計是這樣串起來的：

1. **單一 UTXO** 收容所有 vault state（換來並行模型的乾淨）
2. **29 欄位 VaultDatum**，其中 **9 個不可變**、再加 **8 個政策可變**在 validator 強制的硬上限內（合約結構上鎖死關鍵保護）
3. **Vault NFT** 給單一 UTXO 一個全鏈唯一的 identity
4. **NFT 的 minting policy 烘進三個 spending validator 的編譯期參數**（vault_proxy / vusdcx / order）
5. **NFT 本身用 PlutusV3 UTXO-ref one-shot 鑄造**，全鏈唯一、不可再造
6. **使用者層並行**透過 Order UTXO 跟 BatchProcess 解耦（所有使用者 deposit / withdraw 不爭奪 vault UTXO）

每一層的設計都對應到第 1 篇講的某個約束：單 UTXO 對應約束 1（並行受限），9 個不可變 + 8 個政策可變欄位讓很多保護承諾變成「結構上做不到違反」，編譯期 NFT anchor 對應約束 4（identity 沒有原生概念）。

---

## 系列總結

四篇文章走到這裡：

- **[第 1 篇](./01-eutxo-vault-design-constraints-zh-TW.md)**：在 eUTXO 上做 vault 的四個設計約束
- **[第 2 篇](./02-withdraw-zero-forwarding-pattern-zh-TW.md)**：Withdraw-Zero Forwarding Pattern
- **[第 3 篇](./03-seventeen-validators-four-cuts-zh-TW.md)**：17 個 validator 的四條正交切割線
- **第 4 篇（本文）**：單 UTXO 狀態 + 編譯期 Vault NFT Anchor

OptiVaults V1 完整原始碼以 Apache 2.0 授權公開在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。內部審計已歷經多輪審查並修復 findings；測試套件為完整的 Aiken 單元 + 屬性式 fuzz 測試套件，每次 `aiken check` 都會跑隨機化檢查迭代；目標 2027 年 Q2-Q3 完成第三方審計。

V1 在 mainnet 啟動時設定 100,000 USDCx 的營運上限，直到第三方審計完成。整個專案的定位是 Cardano DeFi 公共財參考實作，歡迎 fork、特化、商業化使用，也歡迎在 GitHub Issues 或 [Discord](https://discord.gg/HY5sy8cz8s) 提出對抗性檢視。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)。*
