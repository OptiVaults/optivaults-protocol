# Pattern Rationale — Registry + Auth NFT Whitelist

**狀態**：資訊性質的模式背景說明。不是 CIP、也不是 CIP 草案。OptiVaults V1 對 Cardano Improvement Proposals 的整體立場見 `docs/cip-readiness-posture-zh-TW.md`。

**範圍**：一個反覆出現的模式 — 用一顆 one-shot identity NFT 錨定、由 redeemer 各自規範變更權限、用來維護一份可被 governance 修改的鏈上 configuration 物件（典型是允許目的地的 whitelist、市場目錄、或參數表）。本模式把 Pattern 1（Validator Identity NFT）、一份 singleton 狀態 validator、與一套 per-redeemer 變更政策組合在一起。OptiVaults V1 把它當作 protocol-destination + Liqwid-market + swap-adapter 的 registry 在用（案例研究見 §6）。

---

## 1. 問題

DeFi 協議常常需要把一塊 configuration 外部化，這塊 configuration：

- 必須被協議自己的 validator **信任**（例如「這個目的地 address 是不是 keeper 被允許路由資金過去的對象？」）。
- 必須在部署之後**仍然可以由 governance 控制著更新**（例如新增一個 DEX adapter、暫停一個出問題的 lending 市場、刷新某個 price-feed 參考）。
- 必須能夠**被很多筆交易高效率地讀**，而每次讀都不必各自再付一次完整 datum-mutation 驗證的成本。
- 必須**抗偽造** — 攻擊者在 configuration 的 script address 種一顆攜帶對攻擊者有利 inline datum 的 UTXO，不可以因此讓消費端 validator 誤認為那是真正的 configuration。

不夠好的做法：

1. **只用編譯期 configuration。** 把 whitelist 烘進每個消費端 validator 的編譯期參數。簡單、且天然防偽造，但**不可變** — 任何 whitelist 變更都得重新部署，而對持有存款的協議來說重新部署等於是要遷移使用者資金。
2. **每個消費者各自一份 datum 副本。** 每個消費端 validator 自己保存一份 whitelist 副本，當作可變 datum。避開了重新部署，但偽造面被乘上 N 倍、governance 水管也被乘上 N 倍，且不同副本漂移時會造成一致性 bug。
3. **中心化的鏈下 configuration。** 把 whitelist 放在鏈下、透過 redeemer 參數餵給 validator。這完全拿掉了鏈上的真實性 — keeper 或使用者可以餵任何值。

Registry + Auth NFT Whitelist 模式是一個結構層的回應：單一一顆鏈上 configuration UTXO、被 identity NFT 錨定、透過一組受限的 redeemer 來更新、並可以透過 reference input 廉價讀取。

---

## 2. 模式本身

一份 Registry 實作會定義：

- **一份 Registry validator**，包含一條或多條 redeemer 路徑。validator 在自己的 script address 上擁有單一一顆標準狀態 UTXO（也就是 *Registry UTXO*）。validator 在每一條 redeemer 下的邏輯，會明確規範 (a) inline datum 的哪些欄位被允許變動、(b) 該變動需要什麼授權（例如 governance 簽名、keeper 單邊 toggle、時間 cooldown）。
- **一份 Identity NFT minting policy**（Pattern 1），由部署期的某顆 UTXO ref 參數化。剛好一顆 Registry Auth NFT 在部署之後就一直被持有在 Registry UTXO 內。這顆 NFT 的 policy ID 就是協議「真正的 registry 是攜帶這顆 token 的那一顆」的宣告。
- **一份在消費端進行 authenticated read 的 helper**。任何想讀 Registry 的 validator 都呼叫它。helper 先驗證傳進來的 Registry UTXO 攜帶預期的 Auth NFT policy + name，再回傳 inline datum。任何坐在 Registry address、但沒有 NFT 的 UTXO 一律被拒絕。

Registry datum 攜帶協議想要外部化的任何 configuration。常見形狀：

- `protocol_hashes: List<ByteArray>` — 允許的目的地 script hash
- `markets: List<MarketEntry>` — 每個市場的 metadata（address、NFT policy、action validator）
- `oracle_feeds: List<OracleEntry>` — 每種資產的價格 feed policy + 參考
- `governance_anchor: (PolicyId, AssetName)` — 這份 Registry 的 update 路徑所依附的 governance NFT
- Cooldowns / timestamps / bounds — 規範「什麼時候可以更新」的操作 metadata

Redeemer 集合通常會切出：

- **慢速更新路徑** — 多天的 governance timelock、寬廣的欄位變更權。用於新增 DEX adapter、替換市場、改 oracle 參數。
- **快速更新路徑**（選用）— 短或零的 governance timelock、狹窄的欄位變更權（典型情境是「世界變了、把*這一條* URL 換掉就好」）。用於慢速路徑會慢到太晚的緊急遷移。
- **單邊 pause 路徑**（選用）— 由非 governance 的權限方（通常是 keeper）把單一一個 boolean 從 `active=True` 翻到 `active=False`。用作 circuit-breaker：任何有操作可見度的當事人都可以擋住壞掉的 route，不用等 governance。

每個 redeemer 都把「哪些欄位可變、哪些不可變」編碼進來。validator 把 redeemer 對應的變更包絡（mutation envelope）落實成「逐欄位比對舊 datum（從花掉的 input 讀）與新 datum（從 continuing output 讀）」。

---

## 3. Aiken 示意

一份有兩條 redeemer 的最小化 Registry validator：

```aiken
type RegistryDatum {
  governance_anchor: (PolicyId, AssetName),
  whitelist: List<ByteArray>,
  last_update_time: Int,
}

type RegistryRedeemer {
  UpdateWhitelist           // Governance-gated, slow path
  PauseEntry { index: Int } // Operator-unilateral, narrow effect
}

validator registry(cooldown_ms: Int) {
  spend(datum: Option<RegistryDatum>, redeemer: RegistryRedeemer, own_ref, tx) {
    expect Some(old) = datum
    expect Some(own_input) = list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
    expect Script(own_hash) = own_input.output.address.payment_credential
    expect Some(cont) = find_single_continuing(tx.outputs, own_hash)
    expect InlineDatum(new_data) = cont.datum
    expect new: RegistryDatum = new_data

    // Auth NFT preserved on the continuing output (forgery defence)
    let nft_preserved = nft_count(cont.value, auth_nft_policy, auth_nft_name) == 1

    // Cooldown enforced
    let cooldown_ok = new.last_update_time >= old.last_update_time + cooldown_ms

    // Per-redeemer mutation envelope
    let envelope_ok = when redeemer is {
      UpdateWhitelist ->
        and {
          new.governance_anchor == old.governance_anchor,        // anchor immutable
          gov_signed(tx, old.governance_anchor),                 // governance must sign
          list.length(new.whitelist) <= 20,                      // upper bound
        }
      PauseEntry { index: _ } ->
        and {
          new.governance_anchor == old.governance_anchor,
          new.whitelist == old.whitelist,                        // unchanged here
          operator_signed(tx),
          // PauseEntry would also touch a hypothetical `active: Bool` per
          // entry — elided from this sketch for clarity.
        }
    }

    and { nft_preserved, cooldown_ok, envelope_ok }
  }
}
```

消費端的 authenticated read（任何把 Registry 當作 reference input 來讀的 validator 都會呼叫它）：

```aiken
fn read_registry_datum(
  ref_inputs: List<Input>,
  expected_auth_policy: PolicyId,
  expected_auth_name: AssetName,
) -> RegistryDatum {
  expect Some(found) = list.find(ref_inputs, fn(i) {
    nft_count(i.output.value, expected_auth_policy, expected_auth_name) == 1
  })
  expect InlineDatum(d) = found.output.datum
  expect parsed: RegistryDatum = d
  parsed
}
```

要檢查「這個目的地 address 是否在 whitelist 裡」的消費端 validator 會先呼叫 `read_registry_datum`、再做 `list.has(reg.whitelist, target_hash)`。`read_registry_datum` 內部的 NFT 檢查是消費端唯一的偽造防線。

---

## 4. 安全性質

### 4.1 透過 Identity NFT 強制 singleton

任何時刻都剛好有一顆攜帶 Auth NFT 的 Registry UTXO。Pattern 1 的密碼學 one-shot 保證 — NFT 在 validator 一輩子裡至多被 mint 過一次 — 會傳遞到 Registry：在同一個 address 上偽造「第二顆」Registry UTXO 不可能也帶著同一顆 NFT，消費端的 NFT 檢查會直接拒絕它。

Registry validator 自己在每一次變更時都會把 NFT 保留在 continuing output 上，所以 NFT 在每次 update 過程中都跟著標準狀態 UTXO 走。

### 4.2 讀端的認證是消費者自己的責任

Registry validator 只在 Registry UTXO 被花掉（亦即 update）時才會跑。把 Registry 當作 **reference input** 來讀的讀者，根本不會觸發 Registry validator — 讀者必須自己獨立去驗證傳進來的 Registry UTXO 攜帶預期的 Auth NFT。`read_registry_datum` helper 把這個檢查集中起來；採用本模式的協議應該統一只走一份 helper 函數，並讓每個 Registry 讀取點都繞道過它。

要小心的一類 bug：消費者在沒做 NFT 檢查的情況下讀 Registry UTXO，這是輕易就能被利用的。針對本模式的程式碼審查應該用 grep 把「Registry」附近的「reference input」都找出來，逐一確認每個 call site 都走過 authenticated read helper。

### 4.3 Per-redeemer 變更包絡

每個 redeemer 都宣告自己被允許變動哪些欄位。validator 透過逐欄位比較舊 datum 與新 datum 來執行包絡。這把一個複雜的 multi-redeemer 政策因式分解成一張可被檢視的矩陣：

| 欄位 | 慢速更新 | 快速更新 | 單邊 pause |
|---|---|---|---|
| `governance_anchor` | 不可變 | 不可變 | 不可變 |
| `whitelist` | 可變 | 不可變 | 不可變 |
| `oracle_feeds` | 可變 | 不可變 | 不可變 |
| `market_action_hash` | 可變 | 可變 | 不可變 |
| `market.active` | 可變 | 可變 | 可變（單向 False） |
| `last_update_time` | 強制 + cooldown | 強制 + cooldown | 強制 |

這張矩陣可以一次掃完做審計 — 對每個 redeemer，每個欄位都屬於 {不可變、可變、單向} 三者之一。如果有 bug 讓低權限 redeemer 能夠改高權限欄位，會以「validator 在那條 redeemer 分支裡缺少對應的相等性檢查」的形式浮出來。

### 4.4 List 長度的上限

每個 list 型別的欄位（`whitelist`、`markets`、`oracle_feeds`、…）都帶一個上限（例如 `≤ 20`）。如果沒有上限，惡意的 governance 提案可以讓 Registry datum 無限制變大，最終在消費端 authenticated read 那一步因為 memory limit 而失敗。有了上限，消費端成本是有界的。

### 4.5 時間 cooldown

`last_update_time` 欄位 + cooldown 檢查（通常 1 小時到 1 天）防止已經拿到 governance key 的攻擊者快速接連發出多次惡意更新。再加上 governance 端的 timelock，這給了鏈下監控充裕的時間，在下一次更新落地之前偵測並爭議單一一筆可疑更新。

---

## 5. 與替代方案的取捨

| 做法 | 不重新部署也能更新 | 抗偽造 | 每次讀的成本 | 跨 validator 一致性 |
|---|---|---|---|---|
| 只有編譯期參數 | 不行 | 強（編譯進去） | 免費 | 天然一致 |
| 每個消費者各自一份 datum | 可以 | 每份各自弱；且需要每份對應一份完整 validator | 每份各自付 | 副本會漂移 |
| 鏈下 config + redeemer 參數 | 可以 | 無（redeemer 餵什麼是什麼） | 免費 | 由呼叫者控制 |
| **Registry + Auth NFT（本模式）** | 可以 | 強（NFT 錨定） | 一次 NFT 檢查 | 單一真實來源 |

本模式做的取捨是：每次讀都付一次 NFT 檢查，換來 runtime 可更新性、singleton 錨定、與「所有消費端共用同一份真實來源」。對「一年變更 1–10 次、每天被讀 100–1000 次」這種 configuration 來說，這個取捨明顯划算。

**關於 CIP-72**：CIP-72 描述的是 dApp 對外發布身份 metadata。Registry + Auth NFT 模式是反方向的事 — 協議內部 configuration 由協議自己的 validator 消費。兩者解的是正交的問題、不會被歸在同一份 CIP 之下。完整的 CIP-72 立場見 `docs/cip-readiness-posture-zh-TW.md` §3。

---

## 6. OptiVaults V1 案例研究

V1 的 Registry 在 `contracts/validators/registry.ak`，由 `registry_auth_nft.ak` 錨定（Pattern 1 的三個實例之一）。Registry datum（`lib/vault/types.ak` 裡的 `RegistryDatum`）有 9 個欄位：

| 欄位 | 可變性 | 用途 |
|---|---|---|
| `governance_policy` | 不可變 | Governance NFT 的 policy ID — 慢速 UpdateRegistry redeemer 在做授權檢查時依附的錨點 |
| `governance_name` | 不可變 | `governance_policy` 的對應欄位 |
| `keeper_pkh` | 不可變 | Keeper 身份 — 單邊的 `KeeperToggleMarket` redeemer 在做授權檢查時用 |
| `protocol_hashes` | 可變（慢速、上限 20） | DeployToProtocol 走的目的地 script hash 白名單 |
| `stable_tokens` | 可變（慢速、上限 50） | 用於 NDV 掃描的穩定幣 policy + name 允許清單 |
| `liqwid_markets` | 可變（慢速、上限 20）+ 每個市場的 `active` 旗標（單邊 pause、單向）+ 每個市場的 `action_addr_hash`（快速） | Liqwid 整合的每個市場 metadata |
| `asset_oracles` | 可變（慢速、上限 20） | 每種資產的雙 feed（Charli3 + Orcfax）oracle 參考 |
| `swap_adapter_hashes` | 可變（慢速、上限 10） | 已被審計過的 DEX adapter validator hash 白名單 |
| `last_update_time` | 強制 + 1 小時 cooldown | 防止快速連發更新 |

三條 redeemer（依 `RegistryRedeemer`）：

- **`UpdateRegistry`** — 慢速 governance 路徑（14 天 timelock + 1 小時 cooldown）。寬廣的變更權限，但三個不可變欄位（`governance_policy`、`governance_name`、`keeper_pkh`）不能改。攜帶一個 payload-hash 綁定，使 governance 的 Queue+Execute 流程承諾於確切的新 datum。
- **`KeeperToggleMarket`** — keeper 單邊 pause。單向 one-way：任何 `liqwid_markets[i].active` 都可以從 `True → False` 翻一次，不能反向。當 Liqwid 市場出現問題時當作快速 circuit-breaker。
- **`FastUpdateMarkets`** — 短 governance 路徑（1 小時 timelock + 1 小時 cooldown）。每個市場只有 `action_addr_hash` + `active` 可變。用於 Liqwid action-validator 遷移事件 — 在遷移時間窗內，慢速路徑會強迫協議落在一個壞掉的狀態。

authenticated read 是 `lib/vault/helpers.ak` 裡的 `helpers.read_registry_datum`。每個消費者（`vault_protocol.DeployToProtocol`、`vault_admin_deploy.AdminDeployNonDeposit`、keeper 端 router）都呼叫這個 helper，而不是直接讀 reference input。

內部驗證已確認目前所有消費端 call site 都走過 authenticated read；針對這個 invariant 的 defence-in-depth 審計檢查是常駐 regression suite 的一部分（`audit-scope.md` Coverage area C — V1 Integration Flows）。

---

## 7. 給未來 CIP 工作的待答問題

如果這個模式日後真的被提出來標準化，討論時需要解決：

1. **Datum 的 schema 版本化。** Registry datum 被多個 deploy 時間軸不同的 validator 消費；升級會加新欄位。CIP 應該說清楚 schema 如何演進而不會破壞舊版讀者（proto3 風格的 optional 欄位、版本標籤式的 union、或是用一條 migration redeemer 把新舊 Registry 並排部署）。
2. **Authenticated-read helper 的慣例。** 本模式的正確性建立在「每個讀者都走 NFT 檢查 helper」之上。CIP 可以把 helper 的 signature 標準化、並提供一份參考 Aiken library，這樣協議就不會各寫各的。
3. **上限的可發現性。** List 長度上限是 writer 與 reader 之間的軟性約定。CIP 可以規範上限如何被發現 — 放在 datum 中一個已知位置的欄位、或當作獨立的 CIP-25 風格 metadata 文件。
4. **與 CIP-68 的組合。** Auth NFT 是否應該同時當 CIP-68 reference NFT 來提供 discovery 用 metadata，這仍然開放；目前的模式刻意讓 NFT 不帶 metadata。
5. **命名。** 「Registry」這個字在 Cardano DeFi 詞彙裡負擔太重。CIP 可能會選一個更銳利的名字（例如「Configuration Anchor」或「Protocol Parameter UTXO」）以降低與 CIP-72 式對外 registration 的撞名。

---

## 8. 另見

- `contracts/validators/registry.ak` — 參考 Registry validator
- `contracts/validators/registry_auth_nft.ak` — Auth NFT（Pattern 1 實例 #3）
- `contracts/lib/vault/helpers.ak` `read_registry_datum` — authenticated read helper
- `contracts/lib/vault/types.ak` `RegistryDatum` / `RegistryRedeemer` — V1 的 datum 形狀
- `spec/pattern-rationale-validator-identity-nft-zh-TW.md` — Pattern 1，與本模式組合使用
- `spec/pattern-rationale-withdraw-zero-forwarding-zh-TW.md` — Pattern 3；V1 中讀 Registry 的 validator 透過 Withdraw-Zero 被觸發
- `spec/pattern-rationale-multisig-gov-timelock-zh-TW.md` — Pattern 2；守 `UpdateRegistry` 與 `FastUpdateMarkets` 的 governance 系統
- `docs/cip-readiness-posture-zh-TW.md` — 整體 CIP 立場；§3 特別處理了 CIP-72

---

**文件狀態**：資訊性質的模式背景說明。反映 V1 在 launch readiness 階段的設計。修訂時機依循 `cip-readiness-posture-zh-TW.md` §4 所述條件。
