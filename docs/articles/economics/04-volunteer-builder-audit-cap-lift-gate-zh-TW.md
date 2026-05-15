# 審計是 cap-lift gate，不是 launch gate：volunteer-builder 框架

*OptiVaults V1 經濟模型解說 — 第 4 篇 / 共 4 篇*

---

V1 經濟模型最容易被誤解的一個面向：**外部審計不是 mainnet 啟動的前置條件**。

聽到「審計不是 launch gate」的第一反應通常是「那就是先射箭再畫靶？」。不是。V1 的姿態是 **volunteer-builder + community-funded audit**——創辦人以志工身份建構 V1，不向 VC 募資、不發代幣、不接受股權形式的出資；但同時，創辦人也**不擔任審計 underwriter**。外部審計（依委託模型 $50-$150K）由 community-funded 資金堆疊承擔，不由創辦人個人 runway 吃下。

這個分離有具體的結構含意：V1 在啟動日上 Cardano mainnet 採 100K USDCx hard cap，不論 §8.1 審計資金堆疊是否已到位。外部審計到位時，**把 cap 解鎖**至 Stage 2 / Stage 3（post-audit $500K → $2M）；若資金始終未到位，V1 在 100K cap 維持無限期運作。

本篇拆解這個框架的結構性理由：為什麼 launch / cap-lift 分開、為什麼創辦人不是 underwriter、Options A-D contingency tree 在實際上長什麼樣子、以及這個姿態對存入者有什麼實質含意。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。

---

## 雙軌可永續性模型

先把兩個常被混淆的問題清楚分開：

**(1) 審計資金 — 一次性、外部、約 $50-$150K**

解決的問題：「V1 的 100K cap 能否解鎖到 Stage 2 / Stage 3？」

承擔方：community-funded 資金堆疊（白皮書 §8.1 列出的四個來源）。

不承擔方：創辦人（明確不擔任 underwriter）。

**(2) 營運 runway — 長期、創辦人承擔、依 TVL 約 $80-$200/年**

解決的問題：「V1 啟動後能否持續運作？」

承擔方：創辦人從個人收入持續支撐。

關鍵屬性：與審計資金完全脫鉤。

把這兩個問題綁在一起的傳統 DeFi 模型是「founder 籌一筆大資本，蓋上線、付審計、跑營運、等成長」。V1 拆開來處理：

- 營運是創辦人的長期承諾（用最小化模型把成本壓到 $80-$200/年，[第 3 篇](./03-reference-implementation-mode-zh-TW.md) 拆過）。
- 審計是社群的選項（cap 解鎖路徑，不影響協議生死）。

這就是 volunteer-builder 框架的核心結構。

---

## 為什麼啟動 / cap-lift 分開

如果按傳統 DeFi 邏輯，外部審計就是 launch gate——「沒審完不能上 mainnet」。為什麼 V1 拒絕這個邏輯？

幾個結構性理由：

### 創辦人不是 underwriter，因此也不是 single point of failure

如果審計是 launch gate，那「審計資金能不能 timely 到位」就會控制協議能不能啟動。這意味著：

- 創辦人必須承諾自掏 $50-$150K 補齊任何資金缺口，否則 V1 永遠不啟動。
- Project Catalyst（撰寫時點狀態：暫停 / 重組）的恢復時程、Cardano Foundation 的 grant 評估速度、單一 audit firm 的 pricing——任一個外部不確定性都會卡住 V1 的整個啟動。
- 創辦人為了避免「無限延後 = 失敗」的壓力，最終可能要妥協做出「不健康」的決定（例如降低審計範圍、選擇較差的審計方、或乾脆放棄審計）。

把 launch 與 cap-lift 拆開，這些壓力都不存在：

- V1 在 §1.5 launch gates 滿足時即可上 mainnet，100K cap 下的存入者風險是有界且明確揭露的。
- 審計可以慢慢來、選對的審計方、跑完整的範圍——因為它不 gating 協議生死。
- 創辦人不需要承擔「我沒籌到審計錢 = V1 不存在」的單點失敗壓力。

### 100K hard cap 是有界風險，不是「先射箭再畫靶」

「審計不是 launch gate」聽起來可能像 reckless launch。但這個說法忽略 V1 的具體姿態：

- **100K USDCx hard cap** 在合約層強制——operator 無法突破。
- **顯眼的 pre-audit 風險揭露**在 frontend、白皮書、文件上各處明確標示。
- **多輪內部審計**已完成（具體內容在白皮書 §5.1 + `docs/audit-scope.md`）——內部審計不能取代外部審計，但能顯著降低外部審計發現 CRITICAL 的機率。
- **三層治理安全**（Security 系列第 1 篇）提供與審計狀態無關的存入者恢復下限。

存入者在 pre-audit 階段進場是**在 100K 風險包絡內、配合完整透明度下做的決定**，不是「我不知道風險就存進去了」。V1 的 framing 不要存入者忽略風險——V1 的 framing 是「在這個風險被有界 + 揭露的前提下，存入者自己選擇是否進場」。

這比「強制等審計、無限期延後 launch」對 Cardano DeFi 社群整體更有價值。因為在「無限延後」的世界裡，沒有任何人能用 V1、沒有人能驗證合約在 production 環境的行為、沒有人能對 V1 做有意義的對抗性測試——所有反饋只能來自 testnet。V1 的 mainnet 100K 上線，等同於「在 small-stakes 環境下做大規模 production validation」，這對外部審計本身也是更好的準備。

### Audit 可能永遠不發生——這也是可接受的結局

V1 公開承認 audit funding 有不確定性。白皮書 §8.1 的 Options A-D contingency tree：

- **Option A** — 完整 $50-$150K 到位：full-scope audit 委託，cap 解鎖到 Stage 3。
- **Option B** — 部分到位：scope-reduced audit 委託，cap 解鎖到 Stage 2（譬如 $250K），未來補審後再解鎖到 Stage 3。
- **Option C** — Community crowdfund 補位：透過 Cardano DeFi 社群眾籌補齊不足。
- **Option D** — 持續未到位：**V1 在 100K cap 維持無限期運作**。

Option D 不是「失敗」——它是 community 用「不出資審計」表達的偏好。在 Option D 下：

- V1 繼續在 Cardano mainnet 上 100K cap 運作，permissionless access 給任何在這個風險包絡下願意進場的存入者。
- 創辦人繼續以年化 $80-$200 的個人補貼維持 keeper 與基礎設施。
- Apache 2.0 開源讓其他 Cardano DeFi 團隊可以 fork 並各自決定是否付自己版本的審計。

這個姿態跟「籌不到審計錢 = 協議死掉」的 dilemma 完全不同——V1 在 100K cap 下作為 Cardano DeFi 公共財參考實作的價值仍然存在，不依賴審計資金。

---

## 創辦人承諾的範圍

把 volunteer-builder framework 翻譯成具體的創辦人個人承諾，誠實揭露：

| 項目 | 承諾 | 含意 |
|------|------|------|
| Seed working capital | ~$2K USDCx | Phase 1 啟動的 working capital |
| 營運基礎設施（18 個月） | ~$200-$500 USD | 採 Reference Implementation Mode + 最小化配置 |
| 年化營運補貼 | $80-$200/年 | 隨 TVL 區段變動；從創辦人個人收入吸收 |
| Audit gap-fill 上限 | ~$15K USD | bridging 資金堆疊與最終報價之間的微額短缺 |

**累積最大承諾：low five-figures USD**，跨越完整的 pre-audit + launch + 無限期 100K cap 窗口。

這個數字比審計 base price 低**幾個數量級**——audit 全價 $100-$150K 是 V1 個人承諾上限的 10× 以上。這就是「創辦人不是 underwriter」的具體含意：創辦人承擔的是「把產品做出來 + 跑營運 + 補微額短缺」，不是「無論如何把審計資金補齊」。

對應地，creator 對 V1 的財務曝險有上限、也已明確揭露——存入者可以對照這條揭露評估「創辦人是否可能在某個時點失能放棄 V1」的風險。在 low-five-figures 的曝險水準下，創辦人從個人收入持續吸收完全不依賴 V1 商業成功；V1 不會因為「個人補貼太重」而被迫 sunset。

---

## Audit-funding 失敗為什麼不是 sunset trigger

V1 sunset 觸發條件（白皮書 §9.2 + economics §7.2）有四條：

- **Trigger A** — Post-audit 成長失敗（前提是審計發生）：外部審計完成後 6 個月內 TVL 未達 $500K。**僅適用於 post-audit 世界**。
- **Trigger B** — 營運 runway 耗盡：創辦人營運面 runway 降至 6 個月以下前向支出。在 Reference Implementation Mode + $80-$200/年下，**結構性多年不可達**。
- **Trigger C** — Class A override 持續：任一 §1.5 Class A override（Liqwid / USDCx / Cardano chain / oracle 異常）持續超過 remediation 期限。
- **Trigger D** — 創辦人明確 sunset 決定：醫療失能 / 個人不可抗力 / 決定停止維護。

**Audit-funding 失敗不在這四條 trigger 內**。Option D（持續未到位）讓 V1 維持在 pre-audit 100K cap，**不啟動 sunset 協議**。這條框架對存入者的實質含意：

「V1 永遠停在 $5K TVL 完全可以接受。真正會結束 V1 的是外部基礎設施失敗或創辦人主動 sunset，這兩件事都不以 TVL 為觸發條件、也不以 audit funding 為觸發條件。」

---

## 為什麼這個分離對存入者有實質幫助

把上面所有的話濃縮成存入者實際關心的問題：

**問題 1：「V1 上 mainnet 但沒審計，我存錢進去風險多大？」**

答：100K USDCx hard cap + 多輪內部審計 + 三層治理安全 + 自助退場路徑 + Apache 2.0 開源原始碼可被任何人對抗性檢視。風險不是 0，明確揭露在白皮書 §5。是否進場是存入者的選擇，但選擇是在完整資訊下做的。

**問題 2：「如果審計永遠籌不到錢，我存進去的錢會怎樣？」**

答：V1 維持 100K cap mainnet 運作，你的 USDCx 仍然可以隨時提領。100K cap 不影響你的提領能力——cap 只限制 protocol 接受新存入的上限。

**問題 3：「創辦人會不會某天突然棄坑？」**

答：個人補貼承諾 $80-$200/年 是低承諾，從個人收入吸收結構性可永續。如果創辦人真的失能 90+ 天，[Security 系列第 1 篇](../security/01-three-layer-governance-safety-zh-TW.md) 講的 Layer 3 CommunitySunset 讓任何 vUSDCx 持有者可以觸發 permissionless 回收路徑，不需要 operator 配合。

**問題 4：「為什麼不像其他 DeFi 那樣等到審計通過再上線？」**

答：「等到審計通過」假設創辦人能 underwrite 完整審計成本，這是 founder-funded 商業產品的模型，不是 V1 的 volunteer-builder 公共財模型。V1 的姿態是「在 100K 風險包絡內、配合完整透明度啟動 mainnet」，把選擇權交給存入者，不要求創辦人擔任 single point of failure 的 underwriter。

---

## 對外部審計機構的姿態

V1 對審計機構的姿態與「商業 underwriting 模型」也不同：

- **不承諾固定的審計時程**——目標 Q2-Q3 2027，但實際時程取決於 §8.1 資金堆疊與審計方排程，不會為了趕 launch 而選擇較差的審計方。
- **不承諾固定的審計範圍**——若資金堆疊只能覆蓋 scope-reduced audit，那就先做 scope-reduced，未來補做完整 scope。
- **不承諾固定的審計方**——撰寫時候選名單包含 Anastasia Labs、MLabs、TxPipe 以及少數獨立 Aiken 審計方。最終選擇在資金到位、審計方排程確認後公開揭露。

這個姿態讓審計機構能用 V1 的公共財定位申請自己的 public-goods discount（白皮書 §8.1 (b) 列為 30-50% 折扣可能性），審計也可以在沒有商業 underwriting 壓力下選對的範圍與深度。對審計機構與存入者雙方都是更健康的合作關係。

---

## 對 Cardano DeFi 生態的意義

V1 是 Cardano DeFi 第一個明確用 volunteer-builder + community-funded audit 框架啟動的 vault 產品。如果這個模型在 V1 證明可行，它對其他 Cardano DeFi 團隊提供了一個替代範本：

- 不必為了 launch 籌 $50-$150K 自掏審計預算。
- 不必把「成長壓力」綁進產品設計。
- 可以以「公共財參考實作」這個更謙虛但更可永續的姿態啟動。

Apache 2.0 開源讓 V1 的設計範本可以被任何 Cardano 團隊 fork 並特化（不同穩定幣組合、不同風險姿態、不同地區變體）。如果 V1 的 volunteer-builder + community-funded 框架在實踐中證明合理，它對 Cardano DeFi 生態整體的價值會超越 V1 自身的 TVL 規模。

這就是 V1 公共財定位的真正含意——**不是「我自己長大」，是「為 Cardano DeFi 提供一個健康的範本」**。

---

## 系列總結

四篇文章走到這裡：

- **[第 1 篇](./01-performance-fee-precise-semantics-zh-TW.md)**：4.5% 績效費精確語意 + validator hard cap
- **[第 2 篇](./02-three-way-fee-split-evolution-zh-TW.md)**：keeper / gov pool / treasury 三流分配與演進
- **[第 3 篇](./03-reference-implementation-mode-zh-TW.md)**：Reference Implementation Mode — 低 TVL 公共財運作
- **第 4 篇（本文）**：Volunteer-builder + audit-as-cap-lift-gate

V1 經濟模型的整體姿態：**結構性鎖死的費率 / 三流分權 / 與成長壓力脫鉤的低 TVL 模式 / 與創辦人 underwriting 脫鉤的審計框架**。每一塊都對應 V1 公共財定位的具體承諾——把該寫進合約的寫進合約、把該誠實揭露的清楚揭露、把該交給社群決定的真的交給社群。

OptiVaults V1 完整原始碼以 Apache 2.0 授權公開在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。內部審計已歷經多輪審查並修復 findings；目標 2027 年 Q2-Q3 完成第三方審計（資金堆疊到位時）。

V1 在 mainnet 啟動時設定 100,000 USDCx 的營運上限；外部審計完成時，cap 解鎖至 Stage 2 / Stage 3。若資金堆疊始終未到位，V1 在 100K cap 維持無限期運作。整個專案的定位是 Cardano DeFi 公共財參考實作——歡迎 fork、特化、商業化使用，也歡迎在 GitHub Issues 或 [Discord](https://discord.gg/HY5sy8cz8s) 提出對抗性檢視。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)。*
