# 多穩定幣配置 ≠ 真正的風險分散

*OptiVaults V1 安全設計解說 — 第 3 篇 / 共 4 篇*

---

V1 同時持有三種穩定幣：USDCx（存入代幣 + idle buffer）、DJED（Liqwid 配置）、USDM（Liqwid 配置）。啟動目標配置是 45% DJED + 25% USDM + 30% USDCx buffer。

很多 vault 設計把多穩定幣配置當作行銷重點，暗示「我們分散在三種穩定幣 = 你的風險被分散了」。

這不是 V1 的姿態。V1 同時持有三種，但**這是「單一生態系曝險下的雙發行者配置」，不是真正的風險分散**。本篇拆解這個區別:什麼能擋、什麼擋不掉，以及為什麼這個誠實揭露比行銷話術更重要。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。

---

## 「分散」的兩種意義

談「分散」之前先把名詞拆清楚，因為混用會讓討論失焦：

**意義 (a) — 發行者分散**：把曝險拆到不同的發行方/穩定機制，這樣某一個發行方出事不會把全部部位歸零。USDCx（Circle 法幣後盾）/ DJED（Coti 演算法 + ADA 擔保）/ USDM（Mehen 法幣後盾）確實是三條獨立信任鏈。**這個層面 V1 確實做到了**。

**意義 (b) — 系統風險分散**：把曝險拆到不同的市場條件，這樣同一個外部壓力源不會同時打中所有部位。**V1 在這個層面做不到**，三種穩定幣全部在 Cardano 鏈上、全部仰賴 Cardano DEX 流動性、全部受同一組 oracle（Charli3 + Orcfax）監控。

行銷上常把 (a) 講成 (b)，讓讀者覺得「持有三種穩定幣 = 我的風險被攤平到三條經濟線」。V1 不採這個說法，因為它在 Cardano 上不成立。

---

## V1 的多穩定幣配置可以擋什麼

多穩定幣配置確實有用，但作用範圍是**發行者特定失敗**:統計上接近獨立的事件：

- **Mehen 倒閉 / attestation 失效**：USDM 法幣後盾蒸發，但 DJED（ADA 擔保）與 USDCx（Circle 後盾）不受影響。25% USDM 部位重挫不會把另外 75% 一起拉下去。
- **COTI DJED 儲備耗盡**：DJED 擔保率崩潰，但 USDM（法幣）與 USDCx（Circle）不受影響。45% DJED 部位重挫不會殃及另外 55%。
- **Circle 合規事件凍結 USDC**：USDCx 贖回路徑中斷，但 DJED（ADA）與 USDM（Mehen 法幣）仍可交易。USDCx 部分受影響，但 vault 整體仍有 DEX swap 可走。

這三個情境的共同特徵是「壓力源來自單一發行者，與另外兩個發行者沒有共同因子」。在這種情境下，V1 的多穩定幣配置會把單一發行者失效的損失壓在 25%–45% 區間，而不是 100%。

---

## 多穩定幣配置擋不掉什麼

但 V1 真正會撞到的壓力情境不是發行者特定，而是**相關性失效**:同一個外部因子同時打中多條穩定幣信任鏈。

### ADA 閃崩

這是 Cardano 上最現實的多資產壓力情境。機制是這樣的：

1. ADA 市價在短時間內劇烈下跌（譬如 72 小時 -30% 以上）。
2. DJED 的擔保品是 ADA，擔保率瞬間從 400%+ 壓到 250% 以下。市場開始擔心 DJED 脫鉤，二級市場 DJED/USDC 報價先行下挫。
3. 同時，Cardano DEX 上的 USDM/USDCx、USDM/ADA、DJED/USDCx 池深度劇烈縮水，LP 提供者觀察到 ADA 波動，主動撤池或被預言機事件觸發的賣壓清空。
4. V1 的 keeper 偵測脫鉤訊號（連續 15 分鐘 > 1% 偏離）並觸發治理 `EmergencyWithdraw` freeze，但在 freeze 啟動到生效之間，已經有反向 swap（DJED → USDCx、USDM → USDCx）以脫鉤折扣價先行成交。
5. 治理 freeze 之後，金庫餘額按市價結算，DJED 部位以脫鉤折扣計入 share price、Minswap V2 上 USDM/USDCx 池深度若惡化也會推升 swap 滑點。

ADA 閃崩**同時打中** DJED 與 USDM/USDCx 的流動性面，因此「45% DJED 部位下挫，但另外 55% 不受影響」這個論述**不成立**。三條看起來獨立的信任鏈，在這個情境下會同步承壓。

### Cardano 生態系統性事件

幾個低機率但非零的情境：

- **鏈停機**：Cardano mainnet 發生長時間停機（Conway era 以來尚未發生，但結構上不能排除）。所有 V1 操作暫停，存入者無法 Withdraw，三條穩定幣全部「凍在當下狀態」。
- **協議層漏洞**：Cardano ledger 本身發現嚴重漏洞需 emergency hard-fork 處理。停機期間同 (1)。
- **針對 Cardano 穩定幣的監管行動**：例如美國 OFAC 或歐盟 MiCA 對 Cardano-issued 穩定幣作出禁令（這不是 V1 風險源，但屬於存入者該知道的尾端情境）。

這些情境下，三穩定幣同時受影響。

### 黑天鵝：三者同時獨立失效

理論上可能 USDCx、DJED、USDM 各自因為無共同觸發點的獨立原因同時失效。V1 設計**不對此做保護**，這屬於純尾端情境，與「相關性壓力」是不同層級的風險。

---

## V1 的緩解措施（合約層）

V1 不能消除上述風險，但合約層放了幾道閥減少破壞：

**逐一資產的脫鉤監控**。Keeper 持續監看 Cardano 原生的 oracle 資料源（Charli3 + Orcfax）與 Minswap V2 TWAP，偵測「連續 15 分鐘 > 1% 的偏離」。**全程不經過跨鏈 oracle 橋接**，與「不使用跨鏈橋」的承諾一致，V1 認為跨鏈橋是已被歷史證明的單點故障，不願把存入者風險押在橋上。持續脫鉤一旦確認，治理即可透過 `EmergencyWithdraw` 動作將 `frozen` 設為 1。

**配置上限**。`UpdateStrategy` 維持每個穩定幣的配置上下限（啟動目標：45% DJED + 25% USDM + 30% USDCx buffer）。若要將某個市場配置拉到政策上限之上，治理必須走完整的 `UpdateStrategy` 動作加 7 天 timelock。攻擊性的「把全部 vault 集中到 DJED」這條路徑被 timelock 擋住，存入者有充足窗口退場。

**Liqwid 市場層級隔離（`KeeperToggleMarket`）**。Keeper 可以單方面停用特定 Liqwid 市場的新 supply（單向旗標：`active: True → False`），不必等治理 timelock；這是 `frozen = 1` 完整凍結前的快速應變層。當 Liqwid USDM 市場利用率瞬間飆到 100%、或 DJED 抵押率異常壓縮時，keeper 可以即時切掉新 supply，把問題範圍縮限到既有部位。

---

## V1 不緩解的（誠實揭露）

**快速脫鉤期間的在途 swap 滑點**。反向 swap 有機會在凍結觸發前以脫鉤折扣價先被成交。15 分鐘的偏離視窗故意設得稍寬，是為了避開瞬時雜訊；但這也意味著小到中型的脫鉤事件可能在偵測完成前就吃掉 1-3% 的滑點。

**相關性脫鉤**。如上所述，ADA 閃崩是最現實的觸發。V1 的配置目標假設三者統計上獨立，但**並不假設失效模式在統計上獨立**:這個區別很重要：配置目標是經濟期望值，不是風險假設。

**發行方發起的贖回凍結**（Circle 合規事件、Mehen attestation 失效等）。鏈上代幣仍可轉讓，但可能一時無法兌換回美元，V1 把 vUSDCx 兌回 USDCx 沒問題，但 USDCx 兌回 USD 的最後一哩路徑取決於 Circle / xReserve 是否仍可運作。

---

## 存入者實際持有的是什麼

把上面所有的話濃縮成一句：

**vUSDCx 是對金庫「當下資產組合」的比例請求權，不是純 USDCx 的請求權。**

舉個具體例子：假設金庫此時持有 90% DJED（45% 目標 + 部分 buffer 已被 keeper 配置），而 DJED 脫鉤 20%，那 share price 會下跌約 18%，USDCx 本身狀況如何已不重要，因為金庫此刻持有的 USDCx 比例很小。

這對存入者的實務意義：

- **要看 share price，不只看「我存了多少 USDCx」**。Share price 反映金庫當下的混合資產價值，存入時的金額不是回收時的下限保證。
- **不能假設「最壞情況我拿回 USDCx」**。最壞情況是金庫此刻持有的混合資產組合按市價結算，可能包含 DJED 或 USDM 折扣計價。
- **緊急退場路徑（Direct Withdraw / Queue Withdraw / Emergency Withdraw）拿到的是 USDCx**，但是按當下的金庫資產估值。脫鉤期間退場會吃掉脫鉤的折扣。

---

## 與 Cardano DeFi 生態現實的關係

V1 為什麼仍然在這個約束下選擇多穩定幣配置？因為當下 Cardano 沒有更好的選擇：

- **直接 100% 押 USDCx**：Liqwid USDCx 市場深度淺、APY 0.5-2%，買不到任何收益。
- **直接 100% 押 DJED**：可以拿到較高 APY，但所有 ADA 擔保風險集中曝險。
- **多協議分散到 Liqwid 以外**：Cardano 上沒有第二個達到「深度 + 審計成熟度 + Aiken 整合可行性」三重門檻的借貸協議。

V1 在這三個壞選項裡選了「多穩定幣 + 單協議 + Liqwid」這個組合，**並明白記錄這是「Cardano 生態成熟度限制」造成的設計，不是「我們認為這就是分散」**。當 Cardano 上出現第二個成熟穩定幣借貸協議時（白皮書 §1.6.3 列出的 V2 觸發條件），V1 的後續版本會評估納入。

---

## V1 適合誰、不適合誰

把上面的揭露轉成存入決策：

**V1 適合的情況**：你能接受「Cardano 穩定幣籃」作為單一相關性曝險，分散只防範發行者特定的崩潰。你理解 ADA 閃崩會同時打中三個部位、並且這就是 V1 在 Cardano 當下生態下的合理姿態。

**V1 不適合的情況**：你期待多資產配置能讓你躲過 ADA 崩盤，事實上它做不到。如果你需要真正的「跨鏈系統風險分散」，目前 Cardano 上沒有任何穩定幣 vault 能提供，包括 V1。

這個揭露不是 disclaimer 樣板，是 V1 風險模型的核心姿態：**清楚說明 V1 能做什麼、不能做什麼，比讓讀者誤以為多穩定幣就是真分散更重要**。

---

## Flash-loan 與早提領費保留機制的互動

順帶處理一個常見的誤解：V1 的早提領費（0.1%）以 share price 上升的形式回饋給剩餘持有者，也就是被提領者付的費用留在金庫作為 buffer，拉升所有剩餘份額的請求權。

攻擊者理論上可以 flash-loan 一筆 vUSDCx，立刻在 `min_hold_seconds` 窗口內提領付費，再重新入場把費用領回。但這套攻擊實際上跑不起來：

- Flash-loan vUSDCx 需要已存在的 vUSDCx 借貸市場，V1 啟動時並沒有。
- 費用按比例攤給所有剩餘份額（**包括攻擊者重入的那份**），來回淨為零。
- 攻擊者還要付閃電循環裡的網路 TX 費與 Minswap 滑點。

目前這套設計沒有已知可獲利的 flash-loan 路徑；V1 會持續觀察是否出現 vUSDCx 借貸市場，真有了再重新評估。這條揭露放在 depeg 風險篇的最後是因為它在概念上相近，都屬於「多資產 + 經濟激勵」交叉面的攻擊向量。

---

## 下一篇

第 4 篇處理 phantom-vault 攻擊向量。Architecture 系列 Article 4 已經介紹過編譯期 Vault NFT Anchor 的高層概念，第 4 篇會深入：runtime NFT 檢查為什麼不夠、攻擊者實際能做什麼、編譯期參數怎麼把這個攻擊面結構性堵死。這條設計線是 V1 把「信任鏈在編譯期就鎖死」的核心案例。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
