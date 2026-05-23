# Pattern Rationale — Validator Identity NFT

**狀態**：資訊性質的模式背景說明。不是 CIP、也不是 CIP 草案。OptiVaults V1 對 Cardano Improvement Proposals 的整體立場見 `docs/cip-readiness-posture-zh-TW.md`。

**範圍**：一個反覆出現的模式 — 用一個由「被消耗 UTXO 參考」參數化的 one-shot mint policy，在整個協議生命週期裡把一顆單一的標準 UTXO 與某個特定的鏈上 script 綁定起來。這個模式是通用的；OptiVaults V1 在三個地方用到它，案例研究見 §5。

---

## 1. 問題

許多鏈上協議會指定剛好一顆 UTXO 當作協議的「自己」 — 也就是 validator 每筆交易都會讀或改的 singleton 狀態 UTXO。例子包含：收益型協議裡那顆標準的 vault UTXO、攜帶 signer 與 queued action 的 singleton governance 狀態 UTXO、或是其他 validator 為了 routing whitelist 而參考的單一 configuration UTXO。

協議的 validator 接下來需要一個方法去辨識「這顆 UTXO 才是真的」 — 把標準 UTXO 從任何剛好也坐落在同一個 script address 的其他 UTXO 區分開來（script address 是公開的；任何人都可以送 token 或 ADA 到那裡，也可以在那邊用自己想要的 inline datum 偽造一顆 UTXO）。

常見的做法有三種：

1. **信任 address**。讀出現在 script address 上的任何 UTXO。這是錯的：攻擊者可以送一顆帶有偽造 inline datum 的 UTXO 到同一個 address，協議分辨不出來。Cardano DeFi 近年的事故史裡就有這種樸素做法被攻擊的案例。
2. **信任一把 key**。標準 UTXO 在被建立的時候由協議運維方的 key 簽名，每次讀 UTXO 時就檢查那個簽名。這種做法在操作上很重（要求運維方在 UTXO 被花掉再被產生時都在線上），並且會繼承所有 key 被盜用的風險。
3. **由 NFT 錨定**。鑄造一顆唯一的 token、把它鎖在標準 UTXO 裡，並讓每個 validator 在讀 UTXO 時都檢查那顆 token 是否存在。協議的身份就變成那顆 NFT 的 policy ID — 一個被烘到 validator 編譯期參數裡的密碼學值。

本文件談的是第三種做法。Validator Identity NFT 模式就是 (3) 在 Plutus V3 上被嚴謹實作的版本。

---

## 2. 模式本身

Validator Identity NFT 實作為一支 Plutus V3 minting-policy validator，**在編譯期被一個特定的 UTXO 參考所參數化**。validator 剛好兩條路徑：

```aiken
validator identity_nft(utxo_ref: OutputReference, asset_name: ByteArray) {
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    let minted = dict.to_pairs(tokens(tx.mint, policy_id))
    when minted is {
      [pair] ->
        if pair.2nd == 1 {
          // Mint branch: exactly one token of `asset_name`,
          // and the parameterised UTXO must be consumed as input.
          and {
            pair.1st == asset_name,
            list.any(tx.inputs, fn(i) { i.output_reference == utxo_ref }),
          }
        } else if pair.2nd == -1 {
          // Burn branch: exactly one token of `asset_name`,
          // unconditional otherwise.
          pair.1st == asset_name
        } else {
          False
        }
      _ -> False  // Reject zero-quantity, multi-asset-name, or quantity ≠ ±1.
    }
  }

  else(_) {
    fail @"identity_nft: unsupported purpose"
  }
}
```

兩個編譯期參數：

- `utxo_ref` — 由部署者在編譯期挑選的某顆特定 `OutputReference`。mint 分支要求這顆 UTXO 必須以 input 的形式出現在 mint 交易裡。
- `asset_name` — 選定的 token name。某些實作會在「協議永遠只 mint 一個固定 name」的情況下省略這個參數（那時 name 就變成 validator 內部寫死的常數）。

兩條由 mint quantity 正負號切開的 redeemer 路徑：

- **Mint**（`quantity == +1`）：在 validator 一輩子裡只能被允許剛好一次。前提條件 `utxo_ref ∈ tx.inputs` 強制了唯一性 — Cardano ledger 保證每顆 UTXO 至多被消耗一次。
- **Burn**（`quantity == -1`）：任何時刻都被允許，沒有其他限制。要 burn，持有者必須花掉那顆裝著 NFT 的 UTXO，所以授權隱含在所有權之中。

同一筆交易內混合 mint 與 burn 會被 `_ -> False` 的 fallthrough 拒絕。多 quantity（`+2`、`-3` 等）也會被拒絕。validator 只處理那兩個乾淨的情形。

最終 NFT 的**身份**就是 validator 編譯出來的 script hash。因為 `utxo_ref`（以及 `asset_name`，如果有用到的話）是編譯期參數，兩個不同的 UTXO ref 會編出兩個不同的 validator hash、進而是兩個不同的 policy ID。攻擊者不可能透過自己部署一份 validator 來造出「假的 OptiVault NFT」：他的 validator hash 不一樣、policy ID 也不一樣，任何用原本 policy ID 去檢查的消費者都會拒絕攻擊者的 token。

---

## 3. 安全性質

### 3.1 密碼學意義上的 one-shot

mint 分支要求 `utxo_ref` 被當作交易 input 消耗。Cardano 上的 UTXO 至多被消耗一次；一旦被花掉，它就不再存在於後續任何 ledger state 裡。因此 mint 分支在整條 chain 的歷史中至多成功一次，無論有多少筆交易嘗試。沒有任何 key 被盜、時間意外、或運維失誤可以造出第二次 mint。

這在「保證來自 ledger 的不變式、而非 key 持有者的行為」這個意義上是**密碼學**的。基於 `{all: [sig(key), before(slot)]}` 的 native-script 替代方案（Plutus V3 之前常見的做法）則是**信任型**的：保證取決於 key 持有者不在 deadline 前簽第二次 mint。如果 key 在 deadline 過期前被盜，singleton 性質就被破壞了。

### 3.2 burn 永遠可用

burn 分支沒有時間限制、也沒有 signer 限制。唯一的要求是 burn quantity 對得上 asset name。因為 NFT 被鎖在一顆由某 spending validator 控制的 UTXO 裡，那個 spending validator 自己的規則決定了 NFT *什麼時候*可以被搬動（並順帶在同一筆交易裡被 burn 掉）。一旦那些規則允許持有者動手，burn 就無法被阻擋。

這正是 Plutus V3 設計與 native-script `{all: [sig, before(slot)]}` 形式的關鍵差別。native-script 的形式**讓 mint 與 burn 共用同一個 deadline** — 一旦 deadline 過了，兩條路徑都到不了。Cardano DeFi 早年用這種形式的部署有產生過永遠 burn 不掉的 NFT，把那顆 UTXO 的 min-ADA 永久鎖在鏈上。

模式的這個切分 — mint 路徑被約束、burn 路徑保持自由 — 就是這個問題的刻意解法。

### 3.3 Mint quantity 的安全性

`[pair]` 的 pattern match 只接受單一 token entry 的 mint。`pair.2nd == 1` 檢查拒絕任何不是剛好一顆的 mint quantity。再搭配 `utxo_ref` 的「只能消耗一次」性質，這保證了在 validator 一輩子裡，整條 ledger 全域上剛好只存在一顆 `(policy_id, asset_name)` token。

替代設計裡一個很容易忽略的細節 bug 是用 `quantity > 0` 取代 `quantity == 1`，這會讓 mint 交易裡可以鑄出多顆同名 token。本模式採用嚴格相等。

### 3.4 對 rogue-policy 注入的防禦

消費標準 UTXO 的 validator 會把 identity NFT 的 policy ID 烘進自己的編譯期參數，並在每次讀 UTXO 時檢查 `quantity_of(utxo.value, expected_policy, expected_name) == 1`。如果攻擊者部署自己版本的 identity-NFT validator（用他自己控制的另一個 `utxo_ref`），會編出不同的 policy ID — 他的 token 過不了 consumer 端的檢查。

這封閉了一整類攻擊：對手在同一個 script address 用偽造的 inline datum 建一顆 UTXO。就算 datum 結構對得上，沒有 NFT、或是 policy 不對的 NFT 會讓 consumer validator 直接拒絕這顆 UTXO。

---

## 4. 與替代方案的取捨

| 做法 | one-shot 保證 | deadline 後可否 burn | 大致 script size | Plutus 評估成本 |
|---|---|---|---|---|
| `{all: [sig, before(slot)]}` native script | 信任型（key + 時間） | 不能 | 數個 bytes | 沒有（ledger fast path） |
| Plutus V2 minting policy 用 `tx.validity_range.upper_bound < slot` 當 mint guard | 信任結構相同（可以額外加 UTXO-ref 檢查，但早期程式碼很少這樣做） | 可調，但常見做法是直接擋掉 | ~1 KB | 低 |
| **Plutus V3 UTXO-ref one-shot（本模式）** | 密碼學（ledger 不變式） | 隨時可以 | ~1.5 KB | 低（validator 小、檢查簡單） |
| CIP-68 reference NFT 帶 datum | 規格上同樣是 one-shot，外加可攜帶 metadata 的能力 | 依 user-token / reference-token 切分而定 | 比較大（CIP-68 metadata helper） | 較高（datum 操作） |

Validator Identity NFT 模式做的取捨是：付出 ~1.5 KB 的 script size 與一點點評估成本，換取密碼學意義上的 one-shot 加上無條件的 burn。對一顆生命週期不定、且 sunset 時 min-ADA 回收在經濟上有意義的 singleton 狀態 UTXO 來說，這是對的取捨。

**CIP-68 立場**：這份文件描述的 identity NFT 模式**刻意不**攜帶 metadata。這顆 NFT 的工作是錨點識別、不是顯示。把本模式與 CIP-68 reference NFT 結合來提供顯示用 metadata 的未來變體是可行的 — 兩者可以共存 — 但不屬於 V1 實作的範圍。完整的 CIP-68 / CIP-25 立場見 `docs/cip-readiness-posture-zh-TW.md` §3。

---

## 5. OptiVaults V1 案例研究

V1 在三個地方實例化這個模式。每個實例都是一份 40–60 行的 validator 檔。差異在於暴露哪些編譯期參數、以及下游哪些 validator 把產生的 policy ID 當作自己的編譯期錨點。

### 5.1 Vault Identity NFT — `contracts/validators/vault_nft.ak`

```aiken
validator vault_nft(utxo_ref: OutputReference) {
  // asset_name hardcoded as vault/constants.vault_nft_token_name = "OptiVault"
  ...
}
```

- 一個編譯期參數（`utxo_ref`）；asset name 是 validator 內部寫死的常數 `"OptiVault"`。
- 在編譯期錨定 `vault_proxy`、`vusdcx`、`order` validator。任何位於 vault address 但缺少這顆 NFT 的 UTXO 都不會被這些 validator 認可為 vault — 「phantom vault」這類攻擊就被封閉了。
- V1 的單一標準 vault UTXO 從部署 ceremony 開始就坐在 `vault_proxy` 的 script address，並攜帶其中一顆 NFT。
- 完整討論見 `spec/vault-nft.md`（安全歷史、生命週期、為什麼不用 native script）。

### 5.2 Governance NFT — `contracts/validators/governance_nft.ak`

```aiken
validator governance_nft(utxo_ref: OutputReference, gov_name: ByteArray) {
  ...
}
```

- 兩個編譯期參數：`utxo_ref` + `gov_name`。name 參數讓同一份 validator 程式碼可以被 V1 的不同 fork（各自有不同的部署期 name）重複使用。
- 錨定 `vault_protocol`、`registry`、`treasury`、以及 `keeper_stake_script` — 這四個接受「governance 授權動作」的 validator 在編譯期就檢查 governance UTXO 的 NFT policy 是否吻合。在 governance script address 上偽造的 governance UTXO 會被拒絕。
- 單一的 MultisigGov UTXO 攜帶這顆 NFT。每一筆 queued 或被 execute 的 governance action 都會花掉這顆 UTXO 並產出一顆新的，NFT 在這個轉換過程中被保留。
- 完整討論見 `spec/multisig-gov.md` §4（governance UTXO 的真實性）以及 `spec/governance.md`。

### 5.3 Registry Auth NFT — `contracts/validators/registry_auth_nft.ak`

```aiken
validator registry_auth_nft(utxo_ref: OutputReference, asset_name: ByteArray) {
  ...
}
```

- 兩個編譯期參數：`utxo_ref` + `asset_name`。形狀與 Governance NFT 相同。
- 錨定標準的 Registry UTXO。當 `vault_protocol` 把 Registry 當作 reference input 讀取、以檢查某個目的地是否在 whitelist 內時，會驗證 Registry UTXO 攜帶這顆特定 policy 的 NFT。沒有 NFT 檢查的話，攻擊者可以在 Registry script address 上種一顆攜帶寬鬆 whitelist 的偽造 Registry UTXO。
- NFT 存在性的檢查放在 `helpers.read_registry_datum` 裡執行，使得每個讀 Registry 的 validator 都走同一條經過認證的讀取路徑。
- 完整討論見 `spec/pattern-rationale-registry-auth-nft-zh-TW.md`（Pattern 4 — Registry + Auth NFT Whitelist），它建構在本模式之上。

### 5.4 三者共用了什麼

三個案例研究有大約 50 行裡的 35 行是逐字相同 — 同樣的 mint/burn 切分、同樣的 `[pair]` dict-entry match、同樣的 UTXO-ref 消耗檢查。差異完全落在編譯期參數簽章、以及下游哪個 validator 拿產生的 policy ID 當錨點。

一個合理的未來重構（V1 之後、審計之後）是把共用核心抽到一份 `lib/identity_nft.ak` helper module，三個 validator 都呼叫它。是否要做這個重構，取決於「每個 validator 各自 inline」是否仍然比「去重後的版本」讀起來更乾淨；目前偏好讓每個 validator 自我完整，以利審計追蹤。

---

## 6. 範圍外的變體

下列變體**不是** Validator Identity NFT 模式涵蓋的範圍；如果未來要標準化，會是各自獨立的模式：

- **per-user 身份 NFT**（每個存款人一顆 NFT）。那是 position-token 模式，basis cardinality 是一對多。Identity NFT 模式是一對一（協議的 singleton 對應一顆 NFT）。
- **threshold-mint NFT**（由 m-of-n 簽名授權的 mint）。那屬於 MultiSig Governance + Timelock（Pattern 2）的範圍。
- **攜帶 metadata 的 NFT**（CIP-25 / CIP-68 reference token）。可以疊在本模式之上、彼此相容，但 identity NFT 模式本身對 metadata 不做表態。

---

## 7. 給未來 CIP 工作的待答問題

如果這個模式日後真的被提出來標準化，討論時需要解決：

1. **`asset_name` 採常數或參數** — V1 在三個實例之間兩種形式都用過。CIP 需要挑一種形狀（或正式允許兩種同時存在）。
2. **burn 分支的授權** — V1 把 burn 設為無條件。某些協議會偏好「burn 必須由那顆裝著 NFT 的 UTXO 對應的 spending validator 的同一位 signer 授權」，這會多加一層約束。CIP 應該把取捨講清楚並選一個預設值。
3. **與 CIP-68 reference NFT 的互動** — 一顆 identity NFT 是否、以及怎樣可以同時當 CIP-68 顯示用 reference NFT。這是共存問題、不是衝突問題。
4. **命名慣例** — 「Identity NFT」、「Singleton NFT」、「Anchor NFT」、「Witness NFT」這幾個名字在非正式的 Cardano DeFi 討論裡都看得到。CIP 會把其中一個定為標準名。

---

## 8. 另見

- `spec/vault-nft.md` — V1 具體實例 #1（Vault Identity NFT）
- `spec/multisig-gov.md` §4 + `spec/gov-nft.md` — V1 具體實例 #2（Governance NFT）
- `spec/pattern-rationale-registry-auth-nft-zh-TW.md` — V1 具體實例 #3（Registry Auth NFT，在 NFT 之上又疊了 whitelist datum）
- `spec/pattern-rationale-withdraw-zero-forwarding-zh-TW.md` — Pattern 3，與 Identity NFT 搭配使用以強制「singleton UTXO 必須是我們 validator 錨定的那一顆」
- `docs/cip-readiness-posture-zh-TW.md` — 整體 CIP 立場
- `contracts/validators/vault_nft.ak` / `governance_nft.ak` / `registry_auth_nft.ak` — 三份參考實作

---

**文件狀態**：資訊性質的模式背景說明。反映 V1 在 launch readiness 階段的設計。修訂時機依循 `cip-readiness-posture-zh-TW.md` §4 所述條件。
