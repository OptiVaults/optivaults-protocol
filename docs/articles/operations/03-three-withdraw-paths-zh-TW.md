# 三條 Withdraw 路徑：Direct / Queue / Emergency 怎麼選

*OptiVaults V1 營運機制解說 — 第 3 篇 / 共 3 篇*

---

V1 提供三條取回 USDCx 的路徑：**Direct Withdraw**、**Queue Withdraw**、**Emergency Withdraw**。三條都能讓存入者最終拿到 USDCx，但走的合約路徑、時間、成本、依賴性各不相同。

很多 vault 只給一條路徑，通常是「批次處理 by operator」。V1 的三條路徑同時存在是有原因的：它們對應**不同的「operator 可用性假設」**，存入者可以根據當下情境選擇最合適的路徑。

本篇拆解三條路徑的合約機制、適用情境、與 trade-offs。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。

---

## 三條路徑對照

| 屬性 | Direct | Queue | Emergency |
|------|--------|-------|-----------|
| 對應合約 | `vault_user.Withdraw` | `order.SubmitWithdraw` + `vault_batcher.BatchProcess` | `emergency-withdraw` CLI |
| Operator 依賴 | 需 vault state 有足夠 buffer | 需 keeper 在線跑 BatchProcess | 不需要 |
| 完成時間 | 即時（一筆 TX） | 通常 < 1 小時（依 keeper batch cadence） | 即時 |
| 用戶付 ADA | 約 1-1.5 ADA | 約 1 ADA + `max_batcher_tip` | 約 1.5-2 ADA |
| 早提領費 | 0.1%（min_hold 窗口內，若 keeper 在線） | 0%（排隊路徑不受 min_hold gate 影響） | 0.1%（若 keeper 在線）/ 0%（keeper inactive ≥ 7 天） |
| 適用情境 | 小到中額部位、vault 有 buffer 流動性 | 大額部位、vault 忙、不急 | keeper 失能或自助退場 |

---

## Direct Withdraw — 一筆 TX 完成

最簡單的路徑。流程：

```
[1] 使用者在 frontend 輸入 vUSDCx 數量
[2] Frontend 構造 TX:
    ├─ Input:  vault UTXO + 使用者的 vUSDCx token UTXO
    ├─ Burn:   vusdcx policy 燒掉 vUSDCx amount
    └─ Output: vault UTXO (扣 USDCx + idle_buffer 更新) +
               使用者地址 (收 USDCx)
[3] 錢包簽名 → 提交 → 等 ledger confirm
```

合約路徑：`vault_proxy.Spend → vault_user.Withdraw`（透過 Withdraw-Zero forwarding，[Architecture 系列 Article 2](../architecture/02-withdraw-zero-forwarding-pattern-zh-TW.md)）。

關鍵約束：

- **vault 必須有足夠的 idle_buffer USDCx** 直接結算。Buffer 不夠時 Direct Withdraw 會 fail（validator 在 `verify_shares_burned` 與 `verify_receiver_output` 之間隱含這個約束）。
- **`min_hold_seconds` 冷卻只 gating Direct Withdraw**，不 gating Queue Withdraw。若你在最近一次 Compound 後的 `min_hold_seconds` 窗口（啟動值 60 秒、validator 硬上限 6 小時）內想 Direct Withdraw，會被擋下；你可以等過冷卻再做，或改走 Queue。

成本：

- **網路費**：約 1-1.5 ADA（含 Withdraw-Zero forwarding 兩次 validator 呼叫的 ref-script fee）。
- **早提領費**：在 keeper 在線時，若仍在 `min_hold_seconds` 後但 7 天 inactivity 還沒觸發，0.1% USDCx 留在 vault（推升其他份額 share price）。

何時用：

- 部位 < $500 或 ~5% 當下 vault TVL 之內。
- Vault 有 30% idle_buffer 是正常狀態（白皮書 §2.3），多數情境 buffer 足夠。
- 不急著等 batcher cadence、希望 TX confirm 後立刻看到 USDCx。

---

## Queue Withdraw — 排隊由 keeper 批次結算

當 vault 忙、或部位較大、或想避開 vault state UTXO 競爭時，走 Queue Withdraw。流程：

```
[1] 使用者在 frontend 輸入 vUSDCx 數量 + max_batcher_tip
[2] Frontend 構造 TX:
    ├─ Input:  使用者的 vUSDCx token UTXO
    └─ Output: order proxy UTXO (datum 紀錄 user_addr,
               vusdcx_amount, max_batcher_tip, max_shares_burn)
[3] 錢包簽名 → 提交 → vUSDCx 已進 order proxy
[4] Keeper 偵測新的 order UTXO，累積到下一個 batch cycle
[5] Keeper 構造 BatchProcess TX:
    ├─ Inputs:  vault UTXO + N 個 order UTXOs
    ├─ Burn:    所有 order 對應的 vUSDCx 總量
    └─ Outputs: vault UTXO + N 個 user addresses (各收 USDCx)
[6] BatchProcess TX confirm → 所有 order 一次結算
```

合約路徑：`order.SubmitWithdraw`（提交時）→ `vault_proxy.Spend → vault_batcher.BatchProcess`（批次結算時）。

關鍵約束：

- **`max_shares_burn` 是使用者自設的容忍範圍**。如果 BatchProcess 時 share price 比預期更低（vault 此期累積損失），導致 burn 超過 `max_shares_burn`，validator 會拒絕該 order，它會留在 order proxy，由使用者 `Cancel` 或自動 `Expire` 取回 vUSDCx。
- **`max_batcher_tip` 由使用者設定**。Keeper 處理 order 時最多收取此 tip 作為批次處理報酬。建議 0.1-0.5 ADA。

幾個重要屬性：

**Queue Withdraw 不受 `min_hold_seconds` gate 影響**。`min_hold_seconds` 只擋 Direct Withdraw 路徑，存入者因此**永遠**能透過 Queue 路徑取回資金，即使治理把 `min_hold_seconds` 拉到上限 6 小時也一樣。這是白皮書 §2.4 強調的「使用者資金絕不會被鎖」的具體保證。

**Order UTXO 隨時可 Cancel**。在 keeper 還沒做 BatchProcess 前，使用者可以走 `order.CancelAction` 取回原 vUSDCx。這個 redeemer 由 `signed_by_owner` 嚴格 gating，只有原 owner 可以 cancel。

**24 小時後自動 Expire**。Order UTXO 的 datum 紀錄 `expires_at = submission_time + 24h`。過期後任何人可以代為觸發 `order.ExpireOrder`，把 vUSDCx 退回原 owner（由 `valid_refund` 強制收款人 = `ord.owner`）。這條 fail-safe 確保 keeper 完全失能時 order 不會卡在 proxy。

成本：

- **網路費**：約 1 ADA（提交 order）+ batch processing 分攤的 fee（每個 order 約 0.1 ADA）。
- **`max_batcher_tip`**：使用者付給 keeper 的優先處理 tip。
- **早提領費**：**0%（不收）**，這是 Queue 路徑相對 Direct 的優勢。

時間：

- BatchProcess cadence 通常每 5-15 分鐘一次（依 vault 活動量）。
- 常態運作下 < 1 小時結算（白皮書 §2.2 描述為「營運目標而非合約強制 SLA」）。
- 高峰期可能達到幾小時。

何時用：

- 部位 $500-$2,500 中額，批次化分攤 BatchProcess fee，比 Direct 路徑划算。
- Vault 處於 busy state（很多 deposit / withdraw 同時發生），Direct 路徑可能撞到 UTXO 競爭重試。
- 不急、可以等 1 小時內結算。

---

## Emergency Withdraw — 自助退場路徑

V1 為「keeper 失能、存入者拿不到 USDCx」情境提供的自助 fallback。流程：

```
[1] 使用者下載 emergency-withdraw CLI 或開啟 frontend 的 emergency mode
[2] 工具讀取當前 vault state (從 Blockfrost / Ogmios / Kupo)
[3] 工具構造 TX:
    ├─ Input:  vault UTXO + 使用者 vUSDCx UTXO
    ├─ Burn:   vusdcx amount
    └─ Output: vault UTXO + 使用者地址 (收 USDCx 與可能的非存入代幣)
[4] 錢包簽名 → 提交 → ledger confirm
```

合約路徑：跟 Direct Withdraw 相同（`vault_proxy.Spend → vault_user.Withdraw`），但 emergency-withdraw 工具自行構造 TX，**不依賴 V1 的 frontend / API server**。

關鍵屬性：

- **完全不需要 operator 配合**。Emergency-withdraw 從 Blockfrost / Ogmios / Kupo 讀取 vault state，使用者本機構造 TX、本機簽名、本機提交。整條路徑跟 V1 的 frontend 或 API 完全脫鉤。
- **拿到的可能是混合資產**。如果 vault 此時持有 DJED / USDM（譬如剛從 Liqwid Recall 回來、還沒 swap），emergency-withdraw 會把按比例分到的所有 token 都送到使用者地址，可能是純 USDCx，也可能是 USDCx + DJED + USDM 混合。
- **早提領費依 7 天 dead-man-switch 自動調整**（[第 2 篇](./02-seven-day-keeper-inactivity-dead-man-switch-zh-TW.md)）：
  - Keeper 仍在線（last_compound_time + 7d 未到）：付 0.1% 早提領費。
  - Keeper inactive ≥ 7 天：0%，emergency-withdraw 變得經濟合理。

成本：

- **網路費**：約 1.5-2 ADA（含 Withdraw-Zero forwarding 兩次 validator 呼叫的 ref-script fee）。
- **可能的 Liqwid Recall 限制**：emergency-withdraw 可以從 vault buffer 直接結算，但無法觸發 RecallFromLiqwid（那需要 keeper 或治理 fallback 簽名）。如果 vault buffer 不夠、所有資金都在 Liqwid，emergency-withdraw 只能領到 buffer 內的份額；剩餘要等治理 m-of-n 用 fallback 把 Liqwid 部位 Recall 回來。
- **可能的混合資產 swap 摩擦**：若領到 DJED / USDM，使用者要自己用 Minswap V2 swap 回 USDCx，付 batcher fee + slippage。

何時用：

- Keeper 完全失能 ≥ 7 天，0% fee 路徑變得划算。
- V1 frontend / API server 不可用（譬如 DNS 問題、Cloudflare 故障），但 Cardano ledger 仍在運作。
- 想完全脫鉤 operator，譬如懷疑 V1 frontend 被 phishing 仿冒，直接用 CLI 從原始 source 構造 TX。

---

## 完整退場決策樹

把三條路徑接到「實務上的退場決策」上：

```
我想退場：

├─ Vault 正常運作？(keeper 在線 + 治理在線)
│  │
│  ├─ Yes:
│  │  │
│  │  ├─ 部位 < $500 + 不在 min_hold 窗口內?
│  │  │  → Direct Withdraw ✓
│  │  │
│  │  ├─ 部位 $500-$2,500 或 vault 忙?
│  │  │  → Queue Withdraw ✓ (0% fee, 1h 內結算)
│  │  │
│  │  └─ 部位很大 (≥ 5% vault TVL)?
│  │     → 拆成多筆 Direct + Queue，避免單筆對 batch 定價的影響
│  │
│  ├─ Keeper 失能、治理仍在線:
│  │  ├─ 等 7 天讓 dead-man-switch 觸發
│  │  ├─ 或立刻 Direct/Queue Withdraw (付 0.1% fee)
│  │  └─ 治理可走 m-of-n RecallFromLiqwid fallback 把資金搬回 buffer
│  │
│  └─ Keeper + 治理同時失能:
│     ├─ 等 7 天 dead-man-switch + emergency-withdraw (0% fee)
│     └─ 等 90 天 CommunitySunset (任何 vUSDCx 持有者可 trigger
│        permissionless RecallFromLiqwid)
```

關鍵 take-away：**存入者退場永遠有路徑**。最壞情況（keeper + 治理同時 90 天失能），任一 vUSDCx 持有者可以觸發 CommunitySunset 並完整自助回收。中間情境（keeper 失能、治理在線）有 7 天 dead-man-switch + 治理 fallback。正常情境有 Direct / Queue 兩條優化路徑。

---

## 為什麼 Queue Withdraw 路徑不收早提領費

設計上的不對稱：Direct 路徑在 min_hold_seconds 窗口內收 0.1% 早提領費，Queue 路徑不收。

理由：

- **Direct 是「插隊」**，直接 spend vault state UTXO，立刻佔用該 UTXO 的當期 throughput capacity。
- **Queue 是「排隊」**，使用者把 vUSDCx 送進 order proxy，等 keeper 把它跟其他 order 一起 batch process。從 vault state UTXO 的角度，這是 throughput-friendly 的設計。

早提領費的設計目的是「補償 vault 在剩餘存入者層面承擔的營運成本」。Queue 路徑因為已經透過批次化分攤 cost，不再需要早提領費，它對 vault 來說是「合作行為」，不是「插隊」。

存入者實務含意：**如果不急著拿到 USDCx，Queue Withdraw 是更划算的選擇**，0% fee 比 Direct 路徑的 0.1% fee（在 min_hold 窗口內）省。中額存入者尤其應該優先 Queue。

---

## 為什麼 Emergency-withdraw 不能跳過 vault state validator

可能有讀者問：既然 emergency-withdraw 是「自助退場」、不依賴 operator，能不能跳過 vault state validator 直接從 vault 拿錢？

答：**不能**。Emergency-withdraw 仍然走 `vault_proxy.Spend → vault_user.Withdraw` 的合約路徑，使用者本機構造的 TX 也必須通過所有 validator 檢查（`verify_shares_burned`、`verify_receiver_output`、`min_hold_seconds` 或 7 天 inactivity 條件、`liqwid_positions` 不變式等）。

Emergency-withdraw 的「自助」屬性是：

- 工具不依賴 V1 frontend / API server。
- 工具不需要 operator 簽名（純存入者單方 TX）。
- 工具支援存入者本機運作（離線構造 TX、線上提交）。

但合約層的所有約束仍然適用，這是它的安全屬性，不是限制。如果合約層能被「emergency 路徑」繞過，那 emergency 路徑就變成攻擊面了。V1 的設計把 emergency 視為「另一個合法 spending 路徑」而非「特殊豁免」，所有 validator 強制條件平等適用。

---

## 系列總結

三篇文章走到這裡：

- **[第 1 篇](./01-swapada-dual-feed-oracle-loop-zh-TW.md)**：SwapAda — dual-feed oracle 鏈上 ADA 補充閉環
- **[第 2 篇](./02-seven-day-keeper-inactivity-dead-man-switch-zh-TW.md)**：7 天 keeper-inactivity dead-man-switch
- **第 3 篇（本文）**：三條 Withdraw 路徑:Direct / Queue / Emergency

V1 營運層的整體姿態：**把該寫進合約強制的寫進合約強制，把該交給 keeper 自主的留給 keeper，把該給存入者選擇的明確分流**。每一條路徑都對應一個具體的營運假設:operator 可用、operator 部分失能、operator 完全失能，確保任何時候存入者都有可走的路徑。

OptiVaults V1 完整原始碼以 Apache 2.0 授權公開在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。內部審計已歷經多輪審查並修復 findings；目標 2027 年 Q2-Q3 完成第三方審計（資金堆疊到位時）。

V1 在 mainnet 啟動時設定 100,000 USDCx 的營運上限；外部審計完成時，cap 解鎖至 Stage 2 / Stage 3。整個專案的定位是 Cardano DeFi 公共財參考實作，歡迎 fork、特化、商業化使用，也歡迎在 GitHub Issues 或 [Discord](https://discord.gg/HY5sy8cz8s) 提出對抗性檢視。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)。*
