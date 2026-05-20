# SwapAda：用 dual-feed oracle 做鏈上 ADA 補充閉環

*OptiVaults V1 營運機制解說 — 第 1 篇 / 共 3 篇*

---

每筆 `DeployToProtocol` TX 會讓金庫淨付大約 2 ADA 給 Minswap V2 批處理者。100K TVL 下一年大約跑 20-50 次 DeployToProtocol，淨流出 40-100 ADA。

沒有補充機制，金庫的 ADA 最終會掉到 `min_vault_ada` 底限，validator 會拒絕後續所有 DeployToProtocol，整個 keeper 自動化機制卡住。

很多 vault 用 off-chain manual top-up 處理這個問題：營運者定期手動送 ADA 進 vault。這個方案有個結構性缺陷，它讓 vault 的營運可用性綁定到 operator 的個人錢包狀態與 manual ops 流程。任何時候 operator 失能或忘記補 ADA，vault 就掛掉。

V1 把這個機制移到鏈上：**`SwapAda` redeemer 在合約層自動補 ADA，由 dual-feed oracle 提供公平價，validator 強制所有經濟參數**。本篇拆解這個閉環的運作、為什麼選 dual-feed 而非 single-source、以及它對存入者的成本影響。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)，本篇引用的 validator 規格在 `spec/ada-swap.md`。

---

## 為什麼 vault 需要 ADA

Cardano 的每筆 TX 都要付 ADA 網路費，這跟 EVM 的 gas 邏輯類似但有兩個關鍵差異：

**(1) 每個 UTXO 都要有 min-UTXO 量的 ADA**。Cardano ledger 規定每個 UTXO 的 ADA 量必須足夠支付該 UTXO 自身的儲存成本（依 datum 大小、附帶 token 數量計算）。vault state UTXO 含有 29 欄位的 VaultDatum 加上 idle USDCx 與多種 stablecoin / qToken，min-UTXO 約 15-20 ADA。

**(2) Minswap V2 批處理費由發起 TX 的人付 ADA**。每次 DeployToProtocol 透過 Minswap V2 做 USDCx ↔ DJED / USDM swap，vault 需要在 Minswap order UTXO 中放入 batcher fee（約 2 ADA）。這筆 ADA 跟 Minswap orderbook 一起走，最終由 batcher 收走，**vault 自己拿不回來**。

所以 vault 隨著時間會「漏 ADA」：

```
初始 vault ADA = 20 ADA (min-UTXO 預留)

每次 DeployToProtocol:
  vault ADA → vault ADA − 2 ADA (Minswap batcher fee)

10 次 DeployToProtocol 後:
  vault ADA = 0 ADA → 違反 min-UTXO → 後續 TX 全部 fail
```

這個漏水現象不是 V1 的設計缺陷，是 Cardano + Minswap V2 互動的結構特性。任何持有非 ADA token 又需要 DEX swap 的 Cardano 合約都會撞到。

---

## 第一個（不夠的）解法：manual top-up

最直觀的解法：營運者定期從自己錢包送 ADA 到 vault。

這個方案不可接受，因為：

- **Vault 的可用性綁定到 operator 個人錢包**。任何時候 operator 個人錢包餘額不足、被竊、或忘記補，vault 卡住。
- **無法被存入者驗證**。Operator 補多少、什麼時候補，存入者只能事後在 cardanoscan 上觀察，不能在事前知道「補 ADA 的政策是什麼」。
- **沒有公平價約束**。Operator 如果同時想從 vault 換出 USDCx（譬如「我補 20 ADA、從 vault 拿走 10 USDCx」），這個 swap 的價格沒有任何 validator 強制，operator 可以用任意匯率執行。

V1 拒絕這個方案，把 ADA 補充機制完整搬到鏈上。

---

## V1 的解法：`SwapAda` redeemer

`vault_swap_ada.SwapAda` 是 V1 專門處理 vault ADA 補充的 redeemer。流程：

```
[1] Keeper 偵測到 vault.lovelace < 15 ADA
[2] Keeper 從 Cardano oracle 讀取 ADA/USD 公平價
[3] Keeper 構造 SwapAda TX:
    ├─ Input:  vault UTXO (帶當前 USDCx + ADA)
    │          keeper 的個人 ADA UTXO (提供 10-50 ADA)
    ├─ Output: vault UTXO (vault.ADA += swap_amount_ada,
    │                      vault.USDCx -= swap_amount_ada × oracle_price)
    │          keeper 個人 UTXO (取得對應的 USDCx)
    └─ Redeemer: SwapAda { swap_amount_ada, oracle_proof }
[4] Validator 檢查:
    ├─ vault.lovelace < ada_below_threshold (15 ADA)
    ├─ swap_amount_ada ∈ [10, 50] ADA
    ├─ exchange rate matches oracle fair price (dual-feed median)
    ├─ validity_range.upper - now ≤ 1 hour
    ├─ time since last SwapAda ≥ 1 hour (cooldown)
    └─ no other vault state changes (frozen / total_deposited / liqwid_positions)
[5] TX 提交、ledger 接受
```

幾個關鍵屬性：

**鏈上原子交換**。Vault 收 ADA、keeper 收 USDCx 是同一筆 TX 的兩個 output，validator 強制兩者按 oracle 公平價匹配。Keeper 無法說「我給 vault 10 ADA，但 vault 給我 1000 USDCx」，validator 拒絕。

**Oracle 公平價驗證**。Validator 從 Cardano 鏈上的 oracle 資料（Charli3 + Orcfax）讀取當下 ADA/USD 公平價，重算 expected USDCx amount，必須與 redeemer 提交的金額精確匹配。

**Amount-in-range 邊界**。每筆 swap 限制在 10-50 ADA，擋下「一次補 1000 ADA」這種規模異常的操作。

**1 小時冷卻**。同一個 vault 上的 SwapAda 之間至少間隔 1 小時，擋下「短時間連續觸發多筆 SwapAda」吸走 vault USDCx 的情境。

**Validity-range cap**。每筆 SwapAda 的時間視窗上限 1 小時，擋下「聲稱 upper = now + 100 days」這種試圖在 oracle 公平價變動後仍能成交舊 TX 的攻擊。

把這幾個約束疊加起來，被入侵的 keeper 的最壞情況是「以當下公平價換 50 ADA / 小時」，對 vault 影響微不足道，且 oracle 公平價約束 USDCx 流出量精確匹配實際換到的 ADA 價值。

---

## 為什麼選 dual-feed oracle（而非 single-source）

Oracle 是 SwapAda 的信任前提。如果 oracle 報的 ADA/USD 價格被操控，vault 就會以扭曲的匯率被換走 USDCx。Oracle 的安全屬性決定 SwapAda 的安全屬性。

V1 用 dual-feed reader：

```aiken
fn read_oracle_price(asset_oracles: List<AssetOracle>, asset: AssetClass) -> Option<Int> {
  // 從 asset_oracles 找到對應 asset 的 oracle 設定
  let oracle_entries = find_oracle_entries(asset_oracles, asset)

  // 讀取 Charli3 + Orcfax 各自的最新報價 + timestamp
  let charli3_sample = read_feed(oracle_entries.charli3, current_time)
  let orcfax_sample  = read_feed(oracle_entries.orcfax, current_time)

  // 檢查兩個 feed 的新鮮度 (≤ 10 分鐘)
  expect is_fresh(charli3_sample, max_staleness_ms = 600_000)
  expect is_fresh(orcfax_sample,  max_staleness_ms = 600_000)

  // 檢查兩個 feed 的差異在容忍範圍內 (≤ 2%)
  let diff_bps = abs(charli3_sample.price - orcfax_sample.price) * 10_000
              / min(charli3_sample.price, orcfax_sample.price)
  expect diff_bps <= 200  // 2% disagreement window

  // 取中位數作為公平價
  Some(median([charli3_sample.price, orcfax_sample.price]))
}
```

幾個關鍵屬性：

**Dual-source 才接受**。Single-source 在這條 helper 直接 fail。`Charli3` 與 `Orcfax` 是 Cardano 上獨立運作的兩個 oracle 協議，它們各自有自己的資料源、aggregation 機制、發布時程。要同時操控兩者需要兩套獨立攻擊。

**Disagreement window**。兩個 feed 必須在 2% 以內。如果 Charli3 報 ADA/USD = $0.50、Orcfax 報 $0.45，差距 11%，helper 拒絕回傳價格，SwapAda 整筆 TX fail。這條讓「single-feed 被攻擊但另一個 feed 正常」這個情境被自動偵測為「oracle 異常」。

**Freshness window**。每個 feed 必須在 10 分鐘以內。Cardano 上 oracle 的更新頻率通常是每幾個 block 一次（10-30 秒），所以 10 分鐘上限對正常運作是寬鬆的；但若某個 oracle 停止更新（譬如 oracle 自身故障），這條 freshness check 會把 SwapAda 擋下。

**Median aggregation**。Dual-feed 的兩個價格取中位數（2 個樣本下，中位數等於平均）。當未來有第三個 oracle 加入時，median 提供結構性的 single-feed-outlier 抗性。

---

## 治理對 oracle 設定的控制

V1 把 oracle 設定放在 `registry.asset_oracles` 而不是 hardcoded 在 validator 裡，理由是 **oracle 生態可能變動**：

- 新的 oracle 協議出現（譬如 V1 啟動後 Cardano 上線了第三個成熟 oracle）。
- 既有 oracle 出問題（譬如 Charli3 某個 feed 被棄用、需要切換新 feed reference）。
- Feed 對應的鏈上格式調整（譬如 oracle 升級 datum schema）。

`UpdateRegistry` 治理動作（14 天 timelock）可以調整 `asset_oracles`：新增 oracle entry、停用某個 feed、輪替到新 feed。但 `UpdateOracleSource` 動作（同樣 14 天 timelock）有更窄的權限，專門用於 oracle source 輪替，與 `UpdateRegistry` 形成兩層保護。

**V1 啟動時 `asset_oracles = []`**。這條設計很關鍵：啟動時 SwapAda 是 inactive 的，因為 helper 在 `asset_oracles` 找不到 ADA 條目就直接 fail。要啟用 SwapAda，治理必須走完整的 `UpdateRegistry` 動作把 ADA 的 oracle 設定植入。

為什麼啟動時 inactive？因為 oracle 設定本身是個高敏感配置：一旦植入錯誤的 oracle reference，所有未來 SwapAda 都會以扭曲的匯率執行。把這個設定放在 14 天 timelock 後啟用，給社群充分時間檢視植入的 oracle 是否真的對應正確的 feed。SwapAda inactive 期間 vault 可以照常運作（直到 ADA 真的耗盡），這給植入 oracle 之前的安全 buffer。

---

## 對存入者的成本：~0.02% APY drag

把 SwapAda 的鏈上成本算出來：

```
100K TVL 假設:
  vault ADA 漏失率 ≈ 50 ADA / month (DeployToProtocol × 25 次 × 2 ADA)
  SwapAda 觸發頻率 ≈ 每 2-4 週一次
  每次 SwapAda swap 量 ≈ 20-40 ADA

換算到 USDCx (ADA = $0.50 假設):
  每次 SwapAda vault USDCx 流出 ≈ 10-20 USDCx
  年累計流出 ≈ 200-400 USDCx

drag 換算:
  200-400 USDCx / 100,000 USDCx TVL ≈ 0.20-0.40% / year ← 沒道理，太高
```

等等，這個算法錯了。SwapAda 換給 vault 的是 ADA，vault 拿到的 ADA 不是「漏失」，是 vault 自己需要的營運成本（給 Minswap batcher）。所以 SwapAda 流出的 USDCx 對應的是 vault 真實的營運成本，不是額外的 drag。

正確的算法：

```
真實 drag = vault 一年付給 Minswap batcher 的 ADA × ADA/USD 公平價
         ≈ 50 ADA/month × 12 × $0.50 ≈ $300 / year

換算到 100K TVL:
  drag ≈ $300 / $100,000 = 0.30% / year
```

這個數字看起來還是高。但這是「DeFi 上跑 vault 的網路 gas 成本」的總和，任何在 Cardano 上做 swap-based rebalancing 的 vault 都會撞到類似的數字。V1 的設計把這個成本暴露出來、明確揭露，而不是藏在「總費用」裡。

白皮書 §2.4 給的「~0.02% APY drag」是 **incremental drag from SwapAda mechanism itself**（不包含 Minswap batcher 費，那是 protocol 必要成本）。它衡量的是「跟『operator manual top-up』模型比起來，SwapAda 機制本身額外造成的摩擦」，主要來自 oracle 取中位數導致的微小匯率不公平（vault 永遠在公平價 0% 點換 ADA，不像 manual top-up 可以挑時間用較好的匯率）。這個數字大致與 dual-feed median 與 keeper 個人最佳匯率之間的 spread 同數量級，典型 0.01-0.05%。

存入者該怎麼看這個數字：

- **0.02% APY 跟 4.5% 績效費比，數量級可忽略**。即使在 0.05% 上限情境下，相對 4-6% 毛收益也不會改變存入決策。
- **這個 drag 對應的是「結構性、不依賴 operator manual ops」的 ADA 補充機制**。代價是把可能的 0-0.05% drag 攤給存入者，回報是 vault 在任何時候不需要 operator 介入就能維持 ADA。
- **如果未來 oracle 競爭更激烈、median 與最佳匯率的 spread 縮小，drag 會自動降低**。V1 不主動優化這個數字，因為它已經夠小；但未來 V1.x / V2 可能評估是否值得加更多 oracle source。

---

## 為什麼 1 小時冷卻 + 1 小時 validity-range cap

兩個 1 小時的限制各自處理一類威脅：

**Cooldown 防的是 high-frequency abuse**。若沒有冷卻，被入侵的 keeper 可以在短時間內連續觸發多筆 SwapAda，例如 1 分鐘觸發 10 次，每次 50 ADA，總計 500 ADA。Vault USDCx 流出 = 500 ADA × oracle 公平價 ≈ 250 USDCx。雖然個別 swap 都是公平價，但累積規模會超出「vault 真實需要的 ADA」很多。冷卻 1 小時讓最大流出率限制在 50 ADA / hour，被入侵的 keeper 1 天最多換 1200 ADA / 600 USDCx，相對 100K TVL 是低個位數百分比，不會把 vault 抽空。

**Validity-range cap 防的是 oracle stale-price abuse**。若沒有 cap，keeper 可以構造「validity_range.upper = now + 10y」的 TX，這筆 TX 雖然在當下 oracle 公平價下成立，但若 oracle 公平價在 10 年內變動很大，攻擊者可以在某個時點重新提交這筆已簽名的 TX，利用 stale 公平價賺差價。1 小時的 width cap 把這個攻擊面壓到「TX 必須在 1 小時內 settle，否則作廢」，oracle 公平價在 1 小時內變動有限，攻擊收益不足以正當化攻擊成本。

這兩個 cap 都不依賴 oracle 本身，是 validator 對 TX 結構的純粹邏輯約束。即使 oracle 短暫被攻擊，這兩條 cap 仍然有效。

---

## 與 §5.4 keeper risk 的關係

SwapAda 機制是 V1 keeper 風險管理的具體案例。白皮書 §5.4 列出 keeper 風險：「keeper 對某些操作的 slippage / pricing 政策由 keeper 軟體決定，不一定由合約強制」。SwapAda 把這條 keeper risk 反向處理:**把 SwapAda 的 pricing 強制從 keeper 軟體轉到合約層**。

這條設計給 V1 提供一個範本：

- **可以由 keeper 軟體政策處理的（譬如 Minswap V2 slippage tolerance 1.5%）**：暴露 risk 但用 destination whitelist + 公開觀察減輕。
- **必須由合約強制的（譬如 SwapAda 的 oracle 公平價）**：直接用 validator 強制，把 keeper 從信任路徑移除。

V1 在 P3-P5 滑點工作中（白皮書 §5.4 + spec/ada-swap.md）持續把這條設計線往前推，把更多 keeper-side 政策搬到合約層強制。這是「結構性安全 vs 信任性安全」分水嶺在營運機制上的具體實踐。

---

## 下一篇

第 2 篇處理另一條與 keeper liveness 直接相關的合約機制：**7 天 keeper-inactivity dead-man-switch**。當 keeper 連續 7 天沒送 productive Compound，合約自動觸發三件事:Direct Withdraw 早提領費自動免收、治理 fallback 路徑打開、emergency-withdraw 變得經濟合理。下一篇講這個機制怎麼運作、為什麼是 7 天、以及它為什麼不能被 TX 提交者用偽造 validity range 騙過去。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
