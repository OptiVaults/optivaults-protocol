# OptiVaults V1 — Order Queue 與 Batch Processing

**範圍**:`order` validator、OrderDatum,以及 `vault_batcher` 上的 BatchProcess redeemer(這個 standalone keeper-authorized staking validator 擁有 4 個 fold 迴圈 + OrderDatum/OrderRedeemer decode + list.unique + R51/R52 anti-leak 不變量)——存款與提款如何被排進批次處理。

---

## 1. 為什麼需要 batch queue

Cardano 的 eUTXO 模型下,vault UTxO 每個 block 只能被一筆 TX 消費。若兩位使用者同時直接消費 vault UTxO 做存款,其中一筆會失敗。Batch queue 把**使用者動作**(在 `order` script 地址建立 Order UTxO)與 **vault 狀態變動**(keeper 在單一 BatchProcess TX 中一次消費 N 筆 order)解耦。

Batch queue 提供的性質:

- **並行**:任意多使用者可同時送單
- **費用攤提**:每次 batch 只動一次 vault UTxO,把動 vault 的 gas 分攤到 N 筆 order
- **抗 flash-loan**:24h order 過期 + 批次處理延遲,防止原子性「存-提」攻擊
- **Keeper 獨立的退款保證**:永遠沒被處理的 order,24h 後任何人都能退款(見 `Expire` redeemer)
- **明確的定價規則**:同一 batch 中所有 order 以 pre-batch snapshot 定價,避免順序依賴的結果

---

## 2. OrderDatum

```aiken
type OrderAction {
  DepositOrder { min_shares: Int }       // 使用者可接受的最低 vUSDCx
  WithdrawOrder { min_receive: Int, receiver: Address }  // 使用者可接受的最低 USDCx + payout 地址
}

type OrderDatum {
  owner: VerificationKeyHash,    // 可 Cancel 的簽名者;Expire 時退款的收件人
  action: OrderAction,
  expires_at: Int,               // POSIX ms;建立後 24 小時
  max_batcher_tip: Int,          // Lovelace;每筆 order 允許 keeper 拿的 tip 上限
}
```

Order UTxO 內容:

- `DepositOrder`:使用者的 USDCx 存款 + 少量 ADA 押金(覆蓋 min-UTXO + `max_batcher_tip` + 退款餘裕,典型 ~2.5 ADA)
- `WithdrawOrder`:使用者的 vUSDCx 份額 + 同樣少量的 ADA 押金

`max_batcher_tip` 由使用者在建立 order 時自訂。送低優先 order 的使用者可以給低 tip(或零)並冒 keeper 跳過的風險;要快速處理就把 tip 設高一點。Keeper 依 tip 經濟性選擇要處理哪些 order。

---

## 3. Order 生命週期

```
 使用者建立 Order UTxO
       │
       ▼
 Order 停在 `order` script 地址,expires_at = 建立時間 + 24h
       │
       ├──── Keeper 處理 ─────────────▶ Process redeemer(批次)
       │
       ├──── Owner 取消 ─────────────▶ Cancel redeemer
       │
       └──── 過期 ──────────────────▶ Expire redeemer(任何人都能觸發)
```

同一個 Order UTxO 的 Process / Cancel / Expire 只會有其中一個消費它。後續嘗試會因為 UTxO 已被 spent 而失敗。

---

## 4. Redeemer

### 4.1 `Process`——keeper 在 batch 中處理 order

當 keeper 把 Order UTxO 納入 BatchProcess TX 時,vault 側觸發這個。

```aiken
Process {
  vault_ref_input_idx: Int,       // Vault reference input 的 index(用來讀 pre-batch snapshot)
  payout_output_index: Int,       // Withdraw 時:支付使用者的 output index
  tip_output_idx: Option<Int>,    // 支付 keeper tip 的 output index;None = keeper 放棄 tip
}
```

**Order 側驗證**:
- `tx.validity_range.upper < ord.expires_at`(order 尚未過期)
- TX 中必須有 vault input(keeper 同時消費 vault UTxO + 本 order UTxO)
- Vault input 必須在 `order_script_hash` 綁定的 vault 地址(即「正確」的 vault,透過 Vault NFT 驗證)
- Keeper 授權檢查(透過 `keeper_stake_script` 的 withdrawal 條目)
- DepositOrder:使用者的 USDCx 必須流入 vault output;keeper 鑄造並把 vUSDCx 路由到 `owner` 地址的 `payout_output_index`;mint 比例依 `vault_batcher` BatchProcess 不變量計算
- WithdrawOrder:使用者的 vUSDCx 被 burn;使用者要求的 `min_receive` USDCx 必須流向 `WithdrawOrder.receiver` 於 `payout_output_index`
- `min_shares` / `min_receive` 滑點下限強制(若 batch 定價低於使用者指定最低,order 失敗不執行)
- Tip 抽取(若 `tip_output_idx = Some(idx)`):
  - `idx` 的 output 拿到 ≥ 0 且 ≤ `max_batcher_tip` lovelace
  - Tip 從 Order UTxO 自己的 ADA 餘額支付(**不是**從使用者 USDCx 存款出)
  - Tip 收件地址不受合約約束(keeper 自由選自己錢包)
- 退款:Order UTxO 剩下的 ADA(押金減 min-UTXO 減 tip)回到 `owner` 地址

### 4.2 `Cancel`——owner 取消待處理 order

```aiken
Cancel
```

**驗證**:
- `tx.extra_signatories` 含 `ord.owner`
- Order UTxO 全部 value(USDCx / vUSDCx + 所有 ADA)退回 owner 地址
- 不涉 vault

Cancel 無論 `expires_at` 為何都可用——owner 在 order 被 Process 之前對 order 保有完整控制權。

### 4.3 `Expire`——過期後任何人都能觸發的退款

```aiken
Expire
```

**驗證**:
- `tx.validity_range.lower >= ord.expires_at`
- Order UTxO 全部 value 退回 `ord.owner` 地址
- 不涉 vault
- **不要求簽名者**——任何人都可送這筆 TX。Order 的完整 value 流向 owner,**不是**流向觸發者,所以 Expire 不會被武器化(觸發者付 TX fee、拿不到回饋)。

Expire 是「keeper 停擺」的 failsafe:即使 keeper 完全離線,24 小時後待處理 order 可以透過**任何**其他 Cardano 使用者送出 Expire TX 退款給使用者。**這代表使用者的本金絕不會被卡在未處理的 order 裡**——最壞情境是「等 24 小時自動退款」。

---

## 5. BatchProcess redeemer(vault 側)

`order.Process` 的 vault 側對應物。Keeper 把一批 order 納入 TX 時,在 `vault_batcher`(Phase-77d 後 BatchProcess 的 standalone 新家)觸發 staking-validator redeemer。

```aiken
BatchProcess {
  order_inputs: List<OrderInput>,   // 每筆 order 的 metadata:input index、payout index、tip index、action
  mint_total: Int,                  // 總 vUSDCx 鑄造量(跨 deposit order 加總)
  burn_total: Int,                  // 總 vUSDCx 燒掉量(跨 withdraw order 加總)
  new_idle_buffer: Int,             // 計算後的 post-batch idle_buffer
}
```

**驗證重點**(完整細節在實作):

1. 所有 `order_inputs` 指向 `order` script 地址的 UTxO;每筆在 TX 中都有對應的 `Process` redeemer
2. `mint_total == Σ deposit_order_shares`(依每筆 deposit 的 amount × pre-batch share price 計算)
3. `burn_total == Σ withdraw_order_shares`
4. `new_total_deposited = old_total_deposited + Σ deposit_amounts − Σ withdraw_amounts`
5. `new_total_shares = old_total_shares + mint_total − burn_total`
6. `new_idle_buffer = old_idle_buffer + Σ deposit_amounts − Σ withdraw_amounts`
7. Mint 不變量:`tx.mint[vusdcx] == mint_total − burn_total`(淨 mint = mint − burn,可為正負)
8. **Pre-batch snapshot 定價**:每筆 order 的 fair share / fair withdrawal 都對 `old_total_deposited / old_total_shares` 計算,**不是**動態 accumulator
9. **Payout index 唯一**:batch 中每個 `payout_output_index` 互不相同(防止 keeper 把兩筆 order 指向同一 output 做重算)
10. **無 vUSDCx 外漏**:鑄出的 vUSDCx 只能流向 deposit-order owner 或被 withdraw order 燒掉;不能淨流到 keeper 地址或任何第三方 output
11. **非凍結**:`old.frozen == 0`
12. **Keeper 授權**:`keeper_stake_script` zero-withdraw 存在

---

## 6. Pre-batch snapshot 定價——詳細說明

同一 batch 中所有 order 都以 **pre-batch 匯率快照**定價,意即:

```
share_price_in_batch = old_total_deposited / old_total_shares
```

這個匯率在 batch 開始時算一次,所有 order 都用這個值。存 X USDCx 永遠鑄出 `X / share_price_in_batch` vUSDCx,**與同 batch 其他 order 無關**。

**為什麼採用這條規則**(而不是 running-accumulator):

Vault 強制 per-batch 的聚合不變量:`Σ minted_shares_per_deposit_order + Σ burned_shares_per_withdraw_order == mint_total - burn_total`。要讓整數算術下這個和精確成立,所有 order 必須用同一 share price。Running accumulator(第 N 筆用 1..N-1 處理後的狀態)在邊界情境下破壞此不變量,並重新引入**一個曾被內部驗證關閉的、順序相關的費用抽取漏洞**。

**結果**:若使用者的 Withdraw 與同 batch 中的大 Deposit 並存,Withdraw 按**pre-batch** 狀態定價。反之,Deposit 與大 Withdraw 並存,Deposit 也按 pre-batch 定價。**兩個方向都一樣**——使用者拿到清楚、事後可驗證的定價規則;**keeper 沒有任何順序操弄的優勢**。

**定價漂移界限**:TVL 成熟時,`max_single_order / total_deposited` 在 basis point 級,pre-batch vs post-batch 的定價漂移可忽略。在 pre-audit 100K TVL 上限下,5K 的單筆 order 對 100K vault 會產生約 5% 的漂移窗口。**低 TVL 下送大單的使用者應優先走 Direct Deposit / Direct Withdraw 以避開這個漂移**。

---

## 7. Keeper 對 tip 的經濟考量

`max_batcher_tip` 建立一個 keeper 處理優先權的市場。Keeper 觀察 order 佇列,依下列考量選要處理哪些 order:

- 自身的 tip 收取策略(拿滿 `max_batcher_tip`、拿少一點來贏過其他 keeper、或自願公益地不拿)
- 納入 order 的 gas 成本(每筆 order 增加 TX size 與計算成本)
- 過期截止臨近度(快接近 24h 到期的 order 會被處理,否則走 Expire 退款)

**最低可行 tip**(**frontend 強制,不是合約強制**):frontend 拒絕 `max_batcher_tip < 100_000` lovelace(0.1 ADA)的 order,防 spam。透過 Cardano CLI 直接送單的使用者可繞過,但這類 order 不太可能被任何 keeper 拾起——經濟誘因不存在。

**V1 啟動時的 tip 範圍**:
- 低優先:100,000–200,000 lovelace(0.1–0.2 ADA)
- 標準:500,000 lovelace(0.5 ADA)
- 高優先:1,000,000+ lovelace(1+ ADA)

使用者應在上線後觀察 keeper 行為,校準自己的出價。

---

## 8. 誠實認知低 TVL 下的 ordering 漂移

因為 V1 啟動有 100K TVL 上限,任何單筆接近這個上限 5%(即 $5K)的 order,如果與同 batch 的其他大 order 並存,就會經驗到明顯的 pre-batch vs post-batch 漂移。小 order(<$500)的漂移實質可忽略。實務影響:

- **小 order(<$500)**:Queue Deposit/Withdraw 完全沒問題;漂移 sub-bp
- **中 order($500–$2500)**:Queue 仍合理;漂移 single-digit bp
- **大 order($2500+)**:**優先走 Direct Deposit / Direct Withdraw** 避開漂移窗口。Direct 不批次,永遠對當下 vault 狀態定價。

當 order 金額接近當下 TVL 的 5% 時,frontend 會在 Deposit/Withdraw UX 顯示這個建議。

---

## 9. 給存入者的保證

讀完本 spec,使用者可以依賴以下**合約強制**的性質:

1. **排隊期間本金安全**:你的存款 USDCx(或提款的 vUSDCx)留在 `order` script 地址的 Order UTxO;只有**你**(透過 Cancel)、**keeper**(透過 Process)、或 24 小時後**任何人**(透過 Expire)能動它。**沒有其他人能動。**
2. **取消權**:在 Process 之前任何時候都能 Cancel、全額退款保證。
3. **24 小時復原保證**:若 keeper 永不處理,24 小時後透過 Expire 自動退款——**絕不會被卡住**。
4. **滑點保護**:`DepositOrder.min_shares` 與 `WithdrawOrder.min_receive` 設最低接受門檻;若 batch 價格給得少於你指定,order 失敗(不執行)。
5. **批次中無隱藏費**:你指定的 `max_batcher_tip` 是唯一不可退的 ADA 成本;批次操作**沒有** USDCx 協議費。
6. **Payout 地址保證**:WithdrawOrder 指定 `receiver: Address`;合約驗證 USDCx 精準流向該地址。
7. **Keeper 無法 skim**:batch 的 mint / burn / payout 邏輯完全由 validator 強制;除了使用者授權的 `max_batcher_tip` 之外,**沒有任何 keeper 可見機制能把 batch 的 value 虹吸到自己錢包**。

---

## 10. 相關文件

- `spec/architecture.md §5` — Order / BatchProcess 在 12 種 TX pattern 中的位置
- `spec/vault-datum.md §4` — 狀態轉移表中的 BatchProcess 欄
- `spec/keeper-auth.md` — BatchProcess 使用的 keeper 授權機制
- `docs/economics.md §1` — Queue Deposit / Withdraw vs Direct 的費用結構
