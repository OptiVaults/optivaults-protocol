# Pattern Rationale：Withdraw-Zero Forwarding

**狀態**：資訊性質的模式背景說明。不是 CIP、也不是 CIP 草案。OptiVaults V1 對 Cardano Improvement Proposals 的整體立場見 `docs/cip-readiness-posture-zh-TW.md`。

**範圍**：一個反覆出現的模式，把鏈上業務邏輯從 spending validator 移出去、放進一個或多個 staking validator，並用 zero-amount withdrawal 來觸發。這個模式是通用的；OptiVaults V1 把它當作整個 vault 的結構骨幹來用（1 個 proxy validator + 10 個被路由的 staking validator），案例研究見 §6。

---

## 1. 問題

Cardano 的 eUTXO 模型對任何想把狀態放在鏈上的協議施加了四個限制：

1. **沒有可變的全域狀態。** 所有狀態都活在 UTXO 裡。一個有單顆狀態物件的協議（持有 pooled 資金的 vault、持有 governance configuration 的 registry）在每筆會改變狀態的交易裡都會花掉目前的狀態 UTXO、產出一顆新的。
2. **每個 input 都會把它的 validator 完整觸發一次。** spending validator 在 UTXO 被消耗時就會跑，沒有辦法跳過 evaluation。如果 validator 把所有對 singleton 狀態 UTXO 可能適用的業務檢查 union 起來扛在一起，每筆交易都要付這些檢查全部的 Plutus 評估成本。
3. **16 KB 的 script size 上限。** 每份編譯出來的 validator 都必須符合 Cardano 的單腳本 byte 預算。一個有點規模的協議 — multi-action vault、multi-redeemer governance、multi-market lending — 如果全部編在一起，很快就會超過 16 KB。
4. **Reference script 費用會隨大小累積。** 即使 validator 被部署成 reference script，每筆使用到它的交易仍然要付一筆與「被引用 bytes」成比例的費用。一份單體式的 16 KB validator 會把這筆成本強加在每一筆交易上，不管那筆交易需要的是整份邏輯還是只是其中一小片。

限制 (1) 是結構性的 — 對於要把資金 pool 在一起的協議來說，singleton 狀態 UTXO 是無法迴避的。限制 (2)、(3)、(4) 合在一起製造了**單體 validator 的問題**：協議範圍一變大，守護狀態 UTXO 的 spending validator 就會不斷累積業務邏輯，最終撞到 16 KB 那堵牆，之後協議要再長大就被擋住了。

Withdraw-Zero Forwarding 模式是一個結構層次的回應。它把業務邏輯從 spending validator 移出去、放進一個或多個 staking validator，同時讓 singleton 狀態 UTXO 仍然只坐在單一 address。

---

## 2. 模式本身

實作 Withdraw-Zero Forwarding 的協議會部署兩種 validator：

- **一份 spending validator**（在這裡稱為 *proxy*）守護 singleton 狀態 UTXO。proxy 不放任何業務邏輯。它唯一的工作是確認交易透過「對某個 staking validator 的 credential 加入一筆 zero-amount withdrawal」這個機制，觸發了一組編譯期固定已知的 staking validator 之中的某一個。
- **N 份 staking validator**（在這裡稱為 *route*）承載真正的業務邏輯。每個 route 處理協議的一個邏輯切片 — deposit / withdraw、compound、governance、swap、lending 整合。每個 route 都各自獨立編譯；每個都各自獨立壓在 16 KB 以下。

觸發機制是看似奇怪、其實是刻意設計的 **zero-amount withdrawal**。一筆 Cardano 交易可以包含對 stake credential 的提領；如果那個 stake credential 綁了一份 staking validator，該 validator 就會作為交易驗證的一部分被跑起來。提領金額可以是 0，這時實際上沒有 ADA 移動 — 但 staking validator 還是會跑。這把 staking validator 變成「交易作者透過加上一筆 zero-withdraw entry 主動選用的邏輯模組」。

讓這件事行得通的 Cardano ledger 關鍵性質是：**在同一筆交易裡被觸發的 spending validator 與 staking validator 看到的是同一份交易 context**。它們觀察到一樣的 inputs、一樣的 outputs、一樣的 mints、一樣的 withdrawals、一樣的 validity range。因此驗證工作可以從 spending validator（每次狀態 UTXO 被消耗都會跑）下放到 staking validator（由交易作者選擇要不要觸發），而不會失去驗證所依賴的任何 context。

示意圖：

```
                    ┌────────────────────────────────────────┐
       ┌────────────│       Transaction (TX context)         │────────────┐
       │            └────────────────────────────────────────┘            │
       │                                                                  │
       ▼                                                                  ▼
  proxy validator                                              route N staking validator
  (runs because singleton                                      (runs because TX includes
   state UTXO is spent)                                         zero-withdraw against it)
       │                                                                  │
       │ Sees: full TX                                                    │ Sees: same full TX
       │ Checks: TX contains a zero-withdraw                              │ Checks: deposit amount,
       │   entry against ONE of the {1..N}                                │   share math, datum
       │   approved route stake credentials                               │   delta, output addresses, ...
       │ Decides: pass / fail                                             │ Decides: pass / fail
       ▼                                                                  ▼
                              Both must pass for TX to validate.
```

狀態 UTXO 繼續住在 proxy address 上。業務邏輯則散在 N 份 route validator 之間。哪一個 route 是這次的活動 route，由交易作者透過選擇要加哪一筆 zero-withdraw entry 來決定，並受限於 proxy 在編譯期就釘住的可接受 route 集合。

---

## 3. Aiken 示意

一份最小化的 proxy：

```aiken
type ProxyRedeemer { Use(Int) }  // index into the pinned routes list

validator proxy(routes: List<ByteArray>) {
  spend(_datum, redeemer: ProxyRedeemer, _own_ref, tx: Transaction) {
    expect Use(idx) = redeemer
    expect Some(target_stake_hash) = list.at(routes, idx)
    list.any(tx.withdrawals, fn(pair) {
      let (cred, amount) = pair
      cred == Inline(Script(target_stake_hash)) && amount == 0
    })
  }
}
```

`routes` 是一個編譯期參數 — 一份被烘進 proxy 編譯後 bytecode 的固定 staking validator hash 清單。proxy 拒絕路由到任何不在這份清單上的東西；要新增 route 必須重新部署。

一份最小化的 route validator（這裡以「deposit」route 作為示意）：

```aiken
validator deposit_route(...compile-time-params...) {
  withdraw(redeemer: DepositRedeemer, _stake_cred, tx: Transaction) {
    // Read the state UTXO from tx.inputs
    // Verify expected datum delta, share-math, fee accounting, ...
    // Return True iff all checks pass.
    ...
  }
}
```

route validator 的 `withdraw` handler 之所以會跑，是因為交易包含了那筆 zero-withdraw entry。它從 `tx.inputs` 讀狀態 UTXO（也就是 proxy 此刻正在被觸發、針對的那同一顆 UTXO — ledger 保證 context 一致），並驗證所有適用於協議「deposit 切片」的業務規則。

從這個形狀自然落出兩個乾淨的職責切分：

- **「路由是否合法」是 proxy 的工作。**「是不是有某個已被批准的 route 被觸發了？」
- **「業務上是否合法」是 route 的工作。**「在這個 route 是 active 的前提下，這筆交易有沒有滿足這個 route 自己的具體規則？」

兩個關注點都不需要知道對方的存在。proxy 從來不會讀狀態 UTXO 的 datum。route 從來不會去列舉其他的 route。

---

## 4. 安全性質

### 4.1 同 TX context 保證

模式的正確性建立在「被同一筆交易觸發的所有 validator 都觀察到完全相同的 transaction context」這條 ledger 性質上。proxy「相信某個 route 被觸發過了」並不是在相信 route 自身的*完整性* — 而是在相信 ledger 真的在 proxy 正在批准的同一筆交易上跑過 route 的邏輯。Ledger 的 TX-context 決定性讓這種授權委派是安全的。

### 4.2 Route 列舉在部署時就封閉了

proxy 的編譯期 `routes` 參數在部署時就把可接受的 staking validator hash 集合釘死。部署之後，要新增任何 route 都會產生一份不同的 proxy hash、對應一個不同的鏈上 address — 換言之是另一個協議。原本 proxy address 上的狀態 UTXO 仍然只能被原本那組 route 守門。

這種封閉很重要。如果 route 可以在 runtime 被加進來，協議的授權面就會無限制成長。相對地，**改變單一 route 允許什麼**（升級 route 的邏輯、或修改它讀的某個 datum）可以由協議自行選擇的機制來治理 — staking validator 自身不帶 datum，所以 route 升級走的是 stake-credential 輪替，不是單純改一份 datum。協議可以決定 route 升級是不是它想支援的能力；多數選擇不支援。

### 4.3 Singleton 強制與本模式正交

只憑這個模式本身，並不會強制「proxy address 上剛好只有一顆狀態 UTXO」。任何人都可以付 ADA 進 proxy address 並夾帶任意 inline datum，造出「幽靈」狀態 UTXO。常見有兩種防禦：

- **Identity-NFT 錨定。** proxy 額外驗證被花掉的 UTXO 攜帶某一個特定 minting policy 的 token（見 `pattern-rationale-validator-identity-nft-zh-TW.md`）。route validator 也對它們讀到的任何狀態 UTXO 做同樣的檢查。偽造 UTXO 通不過 NFT 檢查。
- **Datum 形狀過濾。** proxy 或 route 拒絕 inline datum 不符合預期 schema 的 UTXO。這比 NFT 錨定弱，因為攻擊者也可以造出形狀正確的 datum；當作 defence-in-depth 仍然有用。

V1 兩個都用。本模式文件把「錨定」當作互補模式（Pattern 1，Validator Identity NFT），而不把它烘進 Withdraw-Zero Forwarding 自己裡面。

### 4.4 Stake-credential 註冊是前提

每個 route 的 stake credential 必須先在鏈上註冊過，第一筆對它的 zero-withdraw 才能成功。註冊是一筆獨立交易，有自己的 deposit（Cardano mainnet 上通常是每個 credential 2 ADA，deregistration 時退還）。對一個有 N 個 route 的協議來說，deploy ceremony 要做 N 次 stake registration。

這在操作上有意義：部署 ceremony 的複雜度隨 route 數線性成長，且協議的永久 ADA float 會包含 N × 2 ADA 的 stake-deposit 持倉。

### 4.5 Reference script 順序

Route 通常被部署成 reference script，把單筆交易成本攤平。每個 route 只會被「實際用到它」的交易引用 — deposit 交易引用 proxy 與 deposit route，但不引用 compound route。這就是 §1 限制 (4) 的緩解：reference-script 費用隨每筆交易實際需要的東西規模。

---

## 5. 與替代方案的取捨

| 做法 | 16 KB 上限 | 主路徑上的 ref-script 費用 | 授權隔離 | 部署複雜度 |
|---|---|---|---|---|
| 單體式 spending validator | 在中等規模就會撞到 | 每筆 TX 都付完整邏輯的錢 | 所有檢查共用同一個 validator scope | 一份 validator |
| 多顆狀態 UTXO 散在多個 script address | 撞不到（每個 address 有自己的 validator） | 依 address 收費 | 依 address 隔離 | validator 變多、但不需要 zero-withdraw 那一套水管 |
| **Withdraw-Zero Forwarding（本模式）** | 撞不到（每個 route ≤ 16 KB） | 付 proxy + 一個 route 的錢 | 依 route 的 stake credential 隔離 | proxy + N 次 stake registration |
| Mint-policy 委派（每個 redeemer 對應一顆「permission token」 mint） | 撞不到 | 付 mint policy 的錢 | 依 token 隔離 | 每個 redeemer 都變成一筆 mint TX |

Withdraw-Zero Forwarding 做的取捨是：接受每個 route 的 stake-registration ADA deposit 與「部署 ceremony 複雜度線性成長」這兩個代價，換來「協議範圍可以繼續長大而不撞到 16 KB、且不會在每筆交易裡為用不到的邏輯付錢」這個結構能力。

Mint-policy 委派機制上很類似（兩者都把驗證工作從 spending validator 拉出來），但當協議需要表達「這個 redeemer 會改寫狀態 UTXO 的 datum」時就會變得彆扭 — mint policy 不會自然地讀或斷言 spending validator 的 output，除非你很小心地把線接好。對狀態 UTXO 類型的協議來說，Withdraw-Zero 在結構上是比較乾淨的選擇。

「多顆狀態 UTXO」這個替代方案適合協議的邏輯切片操作在**互不重疊**的狀態上的場景（例如每個使用者部位一顆 UTXO、沒有共享 pool）。對於 pooled 狀態協議 — 每個操作都要讀、改同一顆 singleton — 把狀態散到多個 address 會引入併發爭用與順序性 bug；保持狀態 singleton、把邏輯切散，才是比較乾淨的因式分解。

---

## 6. OptiVaults V1 案例研究

V1 把這個模式拉到完整規模在用：**1 份 proxy validator + 10 份被路由的 staking validator + 周邊 validator（governance、registry、swap adapter、…）**。Proxy 是 `vault_proxy.ak`（編譯後 ~4.9 KB），由 10 個 route stake hash 加上 Vault Identity NFT policy 一起參數化。

那 10 個 route 把 V1 的 vault 邏輯沿著**四個正交的切分軸**散開，每個切分軸都對應一個具體的授權或操作關注點：

1. **Permissionless 與 keeper-authorised** — 切開使用者路徑（`vault_user`）與 keeper 路徑（`vault_keeper_hot`、`vault_batcher`）。
2. **Hot path 與 governance path** — 切開 keeper-hot 操作與 governance 變更操作（`vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`）。
3. **Vault 內數學運算與外部協議互動** — 切開內部 compound/rebalance 與外部協議路由（`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_swap_ada`）。
4. **同步與佇列** — 切開使用者直接動作與被 batch / queue 的動作（`vault_batcher`）。

四個切分軸背後完整的推理放在長篇架構文章 `docs/articles/architecture/03-seventeen-validators-four-cuts.md`。模式本身的長篇敘事在 `docs/articles/architecture/02-withdraw-zero-forwarding-pattern.md`。本背景說明文件是上述兩篇敘事的「通用模式對應」版本。

一個具體結果：V1 中編譯後最大的單一 route 是 `vault_liqwid`、約 ~13.4 KB（離 16 KB 上限約 3 KB 的安全空間）。所有 route 的 bytecode 總和大約 140 KB — 如果寫成單體不可能塞得下。單筆交易的 reference-script 負載被壓在 4.9 KB（proxy）+ 當下那一個 active route 之內 — 通常一筆交易落在 18–25 KB，會被單筆交易的 protocol fee 表攤平掉。

V1 也把 Withdraw-Zero 當作 **keeper 授權**的基底：keeper 的權限由一份獨立的 `keeper_stake_script` 強制執行，所有 keeper-authorised TX 都必須包含對它的 zero-withdraw。那份 validator 是 Withdraw-Zero 模式的 *consumer*（它把 staking-validator 進入點用在不同的目的上 — 守一個外部控制的權限通道，而不是承載某一片 vault 業務邏輯）。Keeper-authorisation 的細節見 `spec/keeper-auth.md`；模式本身相同。

---

## 7. 給未來 CIP 工作的待答問題

如果這個模式日後真的被提出來標準化，討論時需要解決：

1. **Conway 時代 ref-script 費用曲線的互動。** Cardano Conway 上 reference-script 費用對「累積引用 bytes」是非線性的。Withdraw-Zero 協議每筆交易常規會引用 4–6 份腳本。CIP 應該把費用曲線對典型 Withdraw-Zero 部署的影響寫清楚。
2. **Stake-credential 生命週期。** N × 2 ADA 的 stake-deposit overhead 與 route 的 deregistration 路徑對中型協議來說在操作上有重量。CIP 可以把 route 生命週期（registration、rotation、retirement）標準化、並提供參考的部署工具鏈。
3. **Aiken 端的人因。** 一份一致的 code-generation macro / template，用於「以共享的編譯期參數編出 N 份 route validator + 一份對結果 hash 取雜湊的 proxy」，會大幅減少樣板程式碼。目前每個協議都要自己寫部署腳本。
4. **命名。** 「Withdraw-Zero Forwarding」、「Staking Validator Delegation」、「Proxy-Plus-Routes Pattern」這幾個名字在非正式的 Cardano DeFi 討論裡都出現過。CIP 會把其中一個定為標準名。
5. **與 CIP-95 的組合**（Conway delegation flow 的 web-wallet bridge）。Stake-script 註冊會接觸到 Conway delegation primitive。Withdraw-Zero 協議的部署工具鏈是否應該掛上 CIP-95，值得討論。

---

## 8. 另見

- `docs/articles/architecture/01-eutxo-vault-design-constraints.md` — 本模式所回應的四個 eUTXO 限制的敘事文章
- `docs/articles/architecture/02-withdraw-zero-forwarding-pattern.md` — V1 實作的長篇敘事，包含一筆 Compound TX 的完整 walk-through
- `docs/articles/architecture/03-seventeen-validators-four-cuts.md` — V1 為什麼選擇沿那四個正交軸切分的敘事
- `spec/architecture.md` §4 — V1 validator 名錄
- `spec/pattern-rationale-validator-identity-nft-zh-TW.md` — Pattern 1，經常與本模式組合來強制 singleton 性質
- `spec/pattern-rationale-registry-auth-nft-zh-TW.md` — Pattern 4，同時用到 Withdraw-Zero（讓讀 Registry 的 validator 走這條）與 Identity NFT（錨定 Registry 的 singleton 性質）
- `spec/keeper-auth.md` — V1 的 keeper-authorisation stake-script，本模式的 consumer
- `docs/cip-readiness-posture-zh-TW.md` — 整體 CIP 立場
- `contracts/validators/vault_proxy.ak` — 參考 proxy 實作

---

**文件狀態**：資訊性質的模式背景說明。反映 V1 在 launch readiness 階段的設計。修訂時機依循 `cip-readiness-posture-zh-TW.md` §4 所述條件。
