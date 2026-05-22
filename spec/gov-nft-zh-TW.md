# OptiVaults V1 — Gov Signer NFT 規格

**範圍**:發給每位治理簽名者的 soul-bound、非金融性 NFT,作為其角色的公開肯定。

---

## 1. 目的

V1 啟動時(以及 Phase 2-3 擴張期間)的治理簽名者**沒有**顯著的金錢補償:Phase 1 為 $0、Phase 2 約每位每年 $16–33、Phase 3 典型 TVL 下約每年 $100–200。這個角色的主要價值是**非金融**的:

- 聲譽:「我是 OptiVaults 治理簽名者」是一個可驗證的公開主張
- 影響力:簽名者形塑費用政策、treasury 開支、keeper 授權
- 可課責:簽名者身份公開,鏈上簽名是其紀錄

**Gov Signer NFT** 是讓這個聲譽主張可驗證的鏈上 artifact。它是 soul-bound(不能轉讓)、輪替出去時會 burn、**不帶任何投票或金融權利**;那些東西住在 `multisig_gov` 自己的 datum 裡。

---

## 2. Policy 設計

### 2.1 編譯時參數

```aiken
validator gov_signer_nft(
  governance_policy: ByteArray,   // MultisigGov 治理 NFT policy
  governance_name: ByteArray,     // MultisigGov 治理 NFT asset 名稱
) {
  mint(redeemer: GovSignerNFTRedeemer, policy_id: PolicyId, tx: Transaction) { ... }
}
```

把治理 NFT policy + name 作為編譯時參數,把這個 minting policy 密碼學地綁到**這個特定 MultisigGov 實例**。Gov Signer NFT 只有在同一筆 TX 中 MultisigGov UTxO 被 spend 時才可 mint,兩個 NFT 互相依存。

### 2.2 Asset-name schema

每個 Gov Signer NFT 有唯一的 asset name,編碼簽名者的世代與身份:

```
<generation_byte><signer_index_byte><前 28 bytes 的 signer_pkh>

範例:
  0x01 0x00 <founder_pkh[0..28]>    = Gen1 Signer #0(創辦人)
  0x01 0x01 <ally_a_pkh[0..28]>     = Gen1 Signer #1(盟友 A)
  0x01 0x02 <ally_b_pkh[0..28]>     = Gen1 Signer #2(盟友 B)
  0x02 0x00 <new_pkh[0..28]>        = Gen2 Signer #0(第一次 RotateSigners 之後)
```

`generation_byte` 會在每次改動簽名者集合的 `RotateSigners` TX 後 +1;`signer_index_byte` 是該人在新 `signers` list 中的位置。簽名者 PKH 的前 28 bytes 用來在跨輪替時區分身份。

Frontend 顯示該 NFT 為 `OptiVaults Gov Signer #<n> (Gen <g>)`,並連同該簽名者公開披露的身份一起呈現。

---

## 3. Redeemer

```aiken
type GovSignerNFTRedeemer {
  MintForSignerSet {
    signer_indices: List<Int>,    // 要鑄 NFT 的 gov_datum.signers 位置
  }

  BurnRotatedOut {
    rotated_pkh: VerificationKeyHash,
  }
}
```

### 3.1 `MintForSignerSet`

驗證:
- TX 消費 MultisigGov UTxO(以帶有 `governance_policy + governance_name` 識別)
- 該消費的 redeemer 是 `RotateSigners`,**或**此為首次部署 TX(為啟動簽名者集合做 MintForSignerSet)
- 對每個 `i ∈ signer_indices`:
  - `gov_datum.signers[i]` 有定義(在邊界內)
  - 恰好鑄 1 個 token,asset name 為 `<gen_byte><i_byte><signers[i][0..28]>`
  - 該 asset name 的鑄造數量恰好是 `1`
- Mint 集合中不得有 burn(由獨立的 `BurnRotatedOut` 處理)
- 總鑄造數 == `list.length(signer_indices)`

### 3.2 `BurnRotatedOut`

驗證:
- TX 消費 MultisigGov UTxO,redeemer 為 `RotateSigners` 或 `ExecuteAction` 之 RotateSigners
- `rotated_pkh` **不在** `new_gov_datum.signers` 中(確認該次輪替確實把他移除了)
- 恰好 burn 1 個 token(`mint == -1`),asset name 對應 `<gen_byte><prev_index><rotated_pkh[0..28]>`,其中 `<prev_index>` 是該 PKH 在 `old_gov_datum.signers` 中的位置
- 同一 burn redeemer 內不得有 minting

### 3.3 Soul-bound 強制

為了讓 NFT 不可轉讓,minting policy 的 spend-path(有人試著 spend 帶 Gov Signer NFT 的 UTxO)強制:

- 該 NFT 的 UTxO output 繼續流向**原本簽名者的 payment 地址**(PKH 對得上 NFT asset name 的 suffix)
- **或**,該 NFT 在同一 TX 中被 `BurnRotatedOut` 燒掉

這能在不讓簽名者把 NFT 轉給第三方的前提下,仍允許簽名者在自己的 UTxO 間移動(為了管理手續費、合併等)。

惡意的轉讓嘗試會過不了這個檢查,TX 被拒絕。

---

## 4. 生命週期

### 4.1 V1 啟動時的鑄造

V1 mainnet 部署時,一筆 `MintForSignerSet` TX:
- 與 MultisigGov 初始化(GovInit)TX 綁在一起
- 鑄 3 個 Gov Signer NFT(每個啟動簽名者一個)
- 把每個 NFT 送到對應簽名者的 payment 地址
- 鏈上紀錄:這三個 NFT 永久綁在收件人身上

### 4.2 Phase 2 / 3 輪替

當 `RotateSigners` 加入新簽名者時:
1. 輪替 TX 帶:
   - `multisig_gov` 以 `RotateSigners` redeemer 被 spent → 新 `signers` list 公布
   - `gov_signer_nft` 以 `MintForSignerSet { signer_indices: [new_position] }` 鑄造 → 新 NFT 發給加入的簽名者
   - (若同時有簽名者輪替出去)`gov_signer_nft` 以 `BurnRotatedOut { rotated_pkh }` 燒掉
2. 這三個動作**原子化**在同一 TX;不可能有部分輪替的中間狀態

### 4.3 退休 / 退出

當簽名者自願輪替出去(或被治理多數輪替出去)時:
- `RotateSigners` TX 對其 NFT 帶 `BurnRotatedOut`
- NFT 被銷毀;該簽名者不再帶有鏈上主張

若簽名者只是把 key 弄丟而沒有鏈上輪替,他的 NFT 會保留到下次輪替。治理慣例:一旦有簽名者失去存取,就盡速 RotateSigners 移除之。

---

## 5. NFT 不賦予的權利

明確列出**非權利**以避免混淆:

| 權利 | NFT 是否賦予? |
|------|---------------|
| 對治理動作的投票 | ❌ 沒有,投票走 `gov_datum.signers` list + TX 簽名 |
| 對 treasury 資金的請求權 | ❌ 沒有,treasury 資金流走 `TreasurySpend` redeemer,不是靠 NFT 所有權 |
| 績效費分成 | ❌ 沒有,gov fee split 進 MultisigGov UTxO 的 `signer_compensation_pool`,由 `DistributeSignerCompensation` 分到簽名者地址,**不**以 NFT 閘控 |
| 可轉讓性 | ❌ 沒有,soul-bound |
| 再售 / 二級市場 | ❌ 沒有,soul-bound 意味著不能在 NFT 市集掛牌 |
| 在 DAO 快照中的代表性 | ❌ 沒有,V1 不使用 DAO 快照式治理 |

**NFT 只是一份可見、可驗證的「我是 / 曾是 V1 治理簽名者」聲明**。僅此而已。

---

## 6. 顯示與 UX

Frontend(optivaults.app/governance)顯示:
- 目前簽名者集合(從 `multisig_gov` datum 即時讀取)
- 每位簽名者公開披露的姓名 / 機構
- 他們的 Gov Signer NFT 的 Cardanoscan 連結
- 他們的任期(從 GovDatum 的 `signer_joined_at_ms`)
- 季度資格狀態(從 `signer_last_qualified_ms`)

簽名者可以在 Cardano 錢包 UI(Eternl、Lace、Vespr)中顯示 NFT 作為角色證明。有些錢包會把它當「collectible」顯示,簽名者可以自訂顯示方式。

---

## 7. 延伸(未來)

V2+ 可能會把 NFT 系統擴展為:
- **世代 metadata**:NFT metadata 包含簽名者的加入日期、輪替歷史、任何附加的公開聲明
- **貢獻者 NFT**:針對開源貢獻者的類似模式(見 `docs/contributor-program.md`)
- **Auditor NFT**:為執行過審計的事務所另開一個 policy,soul-bound 到該事務所的錢包

**這些不在 V1 範圍**。V1 出廠時只含本文件描述的 Gov Signer NFT。

---

## 8. 安全考量

- **NFT 偽造**:不可能。Mint policy 以治理 NFT policy / name 為參數,鑄造要求消費治理 UTxO。其他實體無法鑄造。
- **NFT 冒充**:每個 NFT 的 asset name 含該簽名者 PKH 的 28 bytes;冒充者無法鑄出一個宣稱**不同**簽名者身份的 NFT。
- **NFT 遺失**:簽名者可以在自己 UTxO 間移動(soul-bound 強制 payment PKH 不變)。若錢包完全被入侵,治理應該 `RotateSigners` 把他移除、NFT 隨之 burn。**不需要** recovery 路徑,NFT 是非金融的。
- **部署時 vs. 輪替時的 NFT**:啟動時鑄的 NFT 與未來輪替時鑄的 NFT 走同一個 policy,行為一致,沒有特例邏輯。

---

## 9. CIP-applicability（soul-bound recognition NFT）

Gov Signer NFT 是 **Soul-Bound NFT pattern** 的一個工作中實例 — 在 policy 強制的綁定條件下、鑄給特定持有者的不可轉移 token，用途是身份 / 認可 / 角色宣稱，而不是金融價值。這個模式在 Cardano DeFi 與鄰近生態系中以非正式形式出現，但目前沒有任何 CIP 把鏈上形狀標準化。

### 9.1 V1 示範了什麼

§2（Policy Design）與 §3（Redeemer）的實作在 Plutus V3 minting-policy 模型下，攜帶了一份 SBT 的結構元素：

- **身份綁定** — asset name 嵌入持有者 PKH 的 28 bytes，所以單一一個 policy 可以支援多個 one-of-one token，每一個都從密碼學上綁到不同的持有者。
- **不可轉移** — 由「守著裝有 NFT 的 UTXO」的 spending validator 強制：NFT 只能在「共用同一把 payment PKH」（亦即同一位簽名者自己錢包內部）的 UTXO 之間移動。在交易市場上轉移會在 validator 層被擋下來。
- **授權 mint 來源** — 鑄造前提要求消費 singleton Governance NFT UTXO，所以只有 governance 核可過的交易才能鑄造或輪替 SBT。沒有第三方能在這個 policy 下產生 token。
- **授權 burn 路徑** — 簽名者輪替的 `RotateSigners` 交易在同一筆 TX 內把退場簽名者的 SBT burn 掉，使「鏈上簽名者 registry」與「SBT 集合」保持同步。

這四個元素合在一起構成 V1 實例化的 SBT 模式。每一項都不新 — Cardano DeFi 中都看過各自變體 — 但 V1 的形式是具體、有審計軌跡、且鏈上可驗證的，如果未來有人撰寫 Soul-Bound NFT CIP，它適合當作參考實例。

### 9.2 V1 對 CIP 標準化的立場

V1 在 V1 階段**不會**為這個模式撰寫 CIP。[`cip-readiness-posture.md`](../docs/cip-readiness-posture.md) §4 中所列的四個一般 gate 都適用 — 外部審計尚未完成、沒有獨立實作、社群治理還沒從 founder-only 階段過渡、且生產壓力證據仍處於 pre-mainnet 狀態。本檔中模式被文件化的形式是 V1 參考實作,不是 CIP 草案。

§7 「Extensions (future)」中列出的 Contributor NFT、Auditor NFT,每個都會是同一個 SBT 模式在不同 policy 參數化下的額外實例。它們不在 V1 範圍內;若未來有 Soul-Bound NFT CIP 討論,會把三個 V1 實例(Gov Signer / Contributor / Auditor)放在同一個傘狀討論下,而不是各自分開。

### 9.3 與 Validator Identity NFT 模式的區別

Gov Signer NFT **不是** [Validator Identity NFT 模式](./pattern-rationale-validator-identity-nft.md) 的實例。兩者處理不同問題:

| 模式 | Cardinality | 角色 | V1 實例 |
|---|---|---|---|
| Validator Identity NFT | 一對一(一顆 NFT 錨定一顆標準 UTXO) | validator 身份的編譯期錨點 | Vault NFT、Governance NFT(*spending validator 的錨點*,不是本檔的簽名者-識別 NFT)、Registry Auth NFT |
| Soul-Bound NFT(本節) | 每個持有者一顆 | 身份 / 認可宣稱、不可轉移 | Gov Signer NFT(本檔)、未來的 Contributor NFT、未來的 Auditor NFT |

Gov **Signer** NFT(本檔)與 Gov **Identity** NFT(錨定 `multisig_gov` UTXO 的 singleton — 見 [`pattern-rationale-validator-identity-nft.md`](./pattern-rationale-validator-identity-nft.md) §5.2)是不同的東西。兩者都用了「Gov」這個字,但解決的是正交的問題。

### 9.4 相關 pattern-rationale 文件

- [`pattern-rationale-validator-identity-nft.md`](./pattern-rationale-validator-identity-nft.md) — Governance Identity NFT(one-shot anchor),本檔 Gov Signer NFT 的 mint policy 在授權上依賴它;兩顆 NFT 共存且角色不同
- [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md) — `RotateSigners` 是「簽名者加入或退出 multisig 集合時 mint / burn Gov Signer NFT」的 redeemer
- [`cip-readiness-posture.md`](../docs/cip-readiness-posture.md) — V1 對 Cardano Improvement Proposals 的整體立場;Soul-Bound NFT 不在五個候選模式清單裡(重點放在 protocol-primitive 模式),但 §6 範圍外的釐清處有隱含提及

---

## 10. 延伸閱讀

- `spec/governance.md §8` — 簽名者輪替路線圖與啟動簽名者集合
- `spec/multisig-gov.md` — MultisigGov validator 內部
- `docs/security-model.md §2` — 治理信任模型、簽名者角色
- `docs/audit-scope.md` — NFT mint policy 屬於 V1 審計範圍
