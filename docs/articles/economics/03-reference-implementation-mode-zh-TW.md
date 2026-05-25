# Reference Implementation Mode：低 TVL 下的公共財運作

*OptiVaults V1 經濟模型解說，第 3 篇 / 共 4 篇*

---

V1 啟動時設了 100K USDCx hard cap。內部估算顯示 Phase 1（pre-audit 階段）的有機 TVL 大致落在 $500-$25K 區間，遠低於 cap，也遠低於協議自給規模（baseline ~$500K）。

一般 DeFi vault 在這個區間有兩個選項：(a) 用「快速成長」的姿態擠出短期 TVL（行銷預算、激勵措施、補貼），快速跨過自給門檻；(b) 直接收掉產品，因為「成長太慢 = 失敗」。

V1 兩個選項都不採，而且這個拒絕本身寫進營運政策。**Reference Implementation Mode** 是 V1 在低 TVL 區間的合法營運模式：把營運節奏降到符合真實收益基礎、降到「即使 TVL 永遠停在 $5K，V1 仍然可以無限期運作」的水準。

本篇拆解這個模式的細節：什麼時候啟用、會調整什麼、不會調整什麼、為什麼這個設計反映 V1「Cardano DeFi 公共財參考實作」的真實定位。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。

---

## 問題：低 TVL 下，預設 Compound 節奏不經濟

V1 的預設 Compound 排程依 TVL 分層（白皮書 §2.6）：

| `total_deposited` 分層 | Compound 排程 | Zero-yield heartbeat |
|-----------------------|---------------|----------------------|
| < 300 USDCx | 累積收益 > $1 才執行 | 每 30 天 |
| 300-750 USDCx | 每月一次 | 每 5 天 |
| 750-1,200 USDCx | 每兩週一次 | 每 5 天 |
| 1,200+ USDCx | 每週六一次 | 每 5 天 |

每筆 Compound TX 在 Cardano 主網大約消耗 1.5-2.5 ADA。每筆 heartbeat 大約 0.5-1 ADA。把這些加起來，1,200+ USDCx 分層的 weekly 檔每年大約消耗 70-80 ADA（≈ $35-40，依 ADA 市價）。

這個成本在 100K TVL 下是合理的，100K × 6% 毛收益 × 4.5% × 40% keeper share ≈ $108/年，剛好覆蓋一個獨立營運者的最低運作成本。

但在 $1-5K TVL 下，數學完全不一樣：

```
TVL = $5,000
毛收益 6%/year = $300
績效費 4.5% = $13.5
Keeper share 40% = $5.4

Default cadence 一年 keeper gas 成本（weekly Compound + heartbeat）
  ≈ 70-80 ADA
  ≈ $35-40

淨：keeper 倒虧 $30-35
協議收益：$13.5 / 年（全部進 treasury + 創辦人 keeper share）
```

這個情境下，預設 cadence 的鏈上 gas 反而超過 keeper 從中提取的收入，更不用說覆蓋主機 / 監控的營運基礎設施。**用 default cadence 跑 $5K TVL 在經濟上不合理，也違背 V1 公共財定位**。

Reference Implementation Mode 就是 V1 給這個問題的合約 + 營運層回應。

---

## 啟用條件：兩個必須同時成立

Reference Implementation Mode 不是「想啟用就啟用」，它需要**兩個條件同時成立**：

1. V1 主網 TVL 在 $25K 以下持續 30 天以上。
2. 過去 4 週、每個 Compound 區間累計的 qToken 收益的平均值，低於該次鏈上 TX 成本的 5 倍（亦即收益無法支撐預設的 Compound 頻率）。

第二條的「5 倍」是經濟合理性的緩衝，如果收益剛好等於 TX 成本，Compound 是經濟「打平」；要有 5 倍以上的緩衝，default cadence 才不會變成「為了 Compound 而 Compound」。

停用條件：TVL 跨過 $25K 並維持 30 天以上，即切回 Default Mode；若 TVL 再次回落，再進入 Reference Implementation Mode。模式切換可以雙向發生。

**這個模式屬於 keeper 在白皮書 §4.5 經濟合理性裁量下行使的營運政策，不需要走 `UpdateStrategy` 治理動作**。它是 keeper 的營運自主權，不是合約強制條件。但 keeper 必須在儀表板上公開揭露當前的活動模式（後面詳述）。

---

## 模式下的營運調整

| 操作 | 預設節奏 | Reference Implementation Mode |
|------|---------|-------------------------------|
| Productive Compound | 1,200+ 檔每週六排程 | 累計收益 > $5 USDCx 才執行；$1-5K TVL 下通常一季到一年才一次 |
| Liveness heartbeat | 每 5 天 | 約每 80 天一次（維持在 90 天 CommunitySunset 門檻之下） |
| Rebalance | 觸發條件成立時 | 配置漂移超過帶寬時才做，不排程 |
| SwapAda | `vault.lovelace < 15 ADA` 時 | 觸發條件相同；部署儀式預先預留的種子 ADA 拉高到 20 ADA 以上，降低首次呼叫頻率 |
| Discord 營運通知 | 每次 Compound + heartbeat 都發 | 改為季度 + 年度總結；週報停發 |

幾個微妙的設計選擇：

**Heartbeat 不能完全停，必須維持在 90 天 sunset 門檻之下**。Heartbeat 的目的是更新 `last_realloc_time`，避免觸發 [Security 系列 Article 1](../security/01-three-layer-governance-safety-zh-TW.md) 講的 Layer 3 CommunitySunset。把 heartbeat 拉到 80 天就剛好低於 90 天 sunset 門檻，既最大化 gas 節省，又確保 vault liveness。

**SwapAda 觸發條件不變，只是把預留 ADA 拉高**。SwapAda 由 `vault.lovelace < 15 ADA` 觸發；模式不改這個合約條件，但部署 ceremony 多預留 5-10 ADA 給 vault，讓 SwapAda 首次呼叫推遲到後面。

**Discord 通知頻率降低**。週報對 $5K TVL 沒人在意，一年 $13.5 績效費，誰想看 52 份「本週 vault 收益 $0.26」？季度 + 年度總結反而對「公共財參考實作」這個定位更貼切。

---

## 此模式不會放棄的部分（零妥協）

這是重要的揭露：**Reference Implementation Mode 是 keeper cadence 政策，不是合約層的鬆綁**。下列保護一律不受影響：

- **全部合約不變式**:不動費率、不繞治理捷徑、不繞 validator。
- **全部存入者保護**:`emergency-withdraw`、4.5% / 1% / 6h 硬上限、`withdraw-cli`。
- **三層治理安全**（Security 系列第 1 篇）:Layer 1 freeze-only、Layer 2 swap-out、Layer 3 CommunitySunset 全部正常。
- **Share price NAV 準確性**:qToken 價值仍按需即時讀取；`total_*` datum 欄位仍在 Compound 時更新如設計。
- **7 天 keeper-inactivity gate**:這條讀的是 `last_compound_time`，不受 heartbeat 節奏放慢影響。

7 天 gate 這條特別重要。它表示即使 keeper 在 Reference Implementation Mode 下幾個月不送 productive Compound，**只要實際收益 < heartbeat threshold，這個情境就不啟動 7 天 fallback**。但若 keeper 完全停止運作（包括 heartbeat 都不送），7 天 gate 仍會以 `last_compound_time` 為基準觸發，Direct Withdraw 早提領費自動免收、emergency-withdraw 變得經濟合理。

這個分離讓 Reference Implementation Mode 在「合法低 TVL 模式」與「keeper 異常停擺」之間有清楚邊界：前者繼續維持 vault 服務、不觸發 fallback；後者立即觸發 fallback、給存入者退場路徑。

---

## 此模式會改變的部分

- **鏈下 indexer 看到的 staleness**：`last_realloc_time` 更新頻率變低，前端儀表板要能容忍這件事。在 Reference Implementation Mode 下，stale 是正常狀態，不是故障訊號。
- **績效費 crystallization 時機**：延後到 withdraw 事件或稀疏的 Compound；累計績效費**金額不變**，只是入帳時機推遲。
- **Treasury 累積速率**：對收益的抽取比例不變，只是轉帳次數變少，Compound 一旦觸發，Treasury 還是會準確累積。

存入者該注意的：**share price 在 Reference Implementation Mode 下會「跳階段」**，不是每週小幅漲，而是每幾個月跳一次。長期持有的存入者最終拿到的 NAV 是一樣的（甚至更多，因為省下 gas）；短期持有的存入者觀察到的「累積收益」會看起來不平滑。

---

## 為什麼是 85-90% 的營運成本降低

把預設節奏 vs Reference Implementation Mode 一年的鏈上 gas 算出來：

**預設節奏（weekly Compound + 5-day heartbeat）**：
- Compound × 52 次 × 1.5-2.5 ADA ≈ 80-130 ADA
- Heartbeat × 73 次 × 0.5-1 ADA ≈ 35-70 ADA
- **總計 ≈ 115-200 ADA / 年**

**Reference Implementation Mode（季度 Compound + 80-day heartbeat）**：
- Compound × 1-4 次 × 1.5-2.5 ADA ≈ 1.5-10 ADA
- Heartbeat × 4-5 次 × 0.5-1 ADA ≈ 2-5 ADA
- **總計 ≈ 4-15 ADA / 年**

降幅約 85-95%。這個數字加上「不需要付雲端 keeper 高階代管方案」（Reference Implementation Mode 下單一小型 ARM 伺服器約 $50/年就足夠），讓 V1 在低 TVL 下的營運成本壓到約 **$80/年**，這個數字寫在白皮書 §4.3.1 cost-scaling 表的最低區段。

$80/年是個關鍵的閾值。它意味著創辦人從個人收入吸收這個成本的負擔輕到「不需要動用任何啟動資本儲備」，這就是 V1「結構性可永續」這個聲明的具體含意。

---

## 模式切換的揭露要求

Keeper 在 OptiVaults 儀表板上公開當前營運模式，包含：

- 目前 active mode（Default / Reference Implementation）。
- 觸發當前模式的條件。
- 進入當前模式以來的時間。
- 下次預計 Compound 的時點與預估收益。
- 下次預計 heartbeat 的時點。

存入者可自行用鏈上的 `last_compound_time`、`last_realloc_time`、`total_deposited` 對照儀表板的宣稱，獨立驗證模式是否確實如所宣告。這條揭露不依賴 trust，存入者可以拿 cardanoscan 資料對帳。

---

## 模式切換機制

TVL 跨過 $25K 且停用條件成立時：

1. Keeper 在儀表板上公告即將切回 Default Mode（對存入者的通知）。
2. 7 天內執行下一次 productive Compound，把累計收益一次性 harvest 完。
3. Heartbeat 節奏恢復為預設（每 5 天）。
4. Rebalance 觸發回歸預設條件。

切換由 keeper 在白皮書 §4.5 裁量下發動。若未來治理認為應該把切換自動化，可以走 `UpdateStrategy` 動作把觸發條件編成規範；V1 不要求這件事。

---

## 為什麼這個模式反映 V1 的真實定位

最後一段把 Reference Implementation Mode 拉回 V1 的整體姿態。

很多 DeFi 產品的隱含預設是「成長到自給規模 = 成功；沒成長到 = 失敗」。這個框架下，低 TVL 階段被視為「過渡期」，要用各種方式加速跨越:行銷預算、激勵措施、補貼、token 釋出。

V1 不採這個框架。**V1 是 Cardano DeFi 的公共財參考實作**，它的價值主張不是「最大化 TVL」，是「以正確的方式做出第一個非託管多穩定幣自動收益 vault 在 Cardano 上的實作」。如果這個實作在 Cardano 生態的成熟度下只有 $5K 的有機需求，那 $5K TVL 在 $80/年營運模式下無限期運作就是合理的終端狀態。

這個姿態對存入者有幾個實際含意：

- **V1 沒有「不成長就死」的時間壓力**。Reference Implementation Mode 在結構上可永續，不會「燒完 runway 之後關門」。
- **V1 sunset 觸發條件不是 TVL 卡在低位**。真正會結束 V1 的是白皮書 §1.5 Class A overrides（USDCx 事件、Liqwid 事件、Cardano chain halt、oracle 異常）或創辦人明確 sunset 決定。
- **Apache 2.0 開源意味著 V1 的價值不依賴自己長大**。即使 V1 維持在 $5K TVL，原始碼仍可被其他 Cardano DeFi 團隊 fork 並特化，這對 Cardano 生態的貢獻不會因為 V1 自己 TVL 規模而改變。

Reference Implementation Mode 就是把這個哲學翻譯成具體營運政策。**「當存入規模其實只是在『跑公共參考實作』、而不是『跑 yield 產品』時，這才是誠實的營運姿態。」**

---

## 下一篇

第 4 篇處理 V1 公共財定位最容易被誤解的一個面向：**外部審計不是 launch gate、是 cap-lift gate**。創辦人不為審計擔任 underwriter；V1 在啟動日上 mainnet 採 100K USDCx hard cap，不論審計資金是否到位。下一篇講這個 volunteer-builder + community-funded audit 框架的結構性理由。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
