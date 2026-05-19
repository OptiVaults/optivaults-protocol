# OptiVaults V1 白皮書

**版本 1.4.2 — 公開發佈候選版**
**目標網路：Cardano Mainnet**
**存入代幣：USDCx**

---

## 0. 專案哲學與分期

OptiVaults 建立在一個核心信念上：**選對啟動時機，比搶第一個啟動更重要。**

Cardano DeFi 正處於結構性轉型期。USDCx 透過 Circle 的 xReserve 整合上線（2026 年 2 月）首次為 Cardano 引入機構級穩定幣流動性。Pogun 的 BTC DeFi 上線（2026 Q2 起，若按計劃推進）將為 Cardano 穩定幣借貸市場帶來長期缺乏的借方需求。Leios 的擴容方案與 Midnight 的 DeFi Kernel 預計在 2027 年陸續成熟。

一個在這些催化劑出現之前啟動的穩定幣收益 vault，是在解決一個還不夠規模的問題。一個在這些催化劑成熟之後啟動的穩定幣收益 vault，才有條件捕捉它們帶來的需求。

我們因此把專案組織為：

**Phase 1 — Pre-Catalyst（僅 Preprod；直到 §1.5 launch gates 通過）**
- 智能合約部署在 Cardano preprod 測試網並完成驗證
- 原始碼在 GitHub 公開，採 Apache 2.0 授權
- 白皮書、文件、設計規格持續公開維護
- 三軸觸發框架（§1.5）每月監測與公開報告
- 平行開發互補產品（固定利率 vault、Pogun 整合，§1.7）
- **V1 尚未在 mainnet 運作。** 另有一份**內部驗證期（internal-verification-era）的舊版合約迭代**部署在 Cardano mainnet，前端僅開放給創辦人（founder-gated）做內部測試——這**不是**本白皮書描述的 V1 設計，於 §0.1 揭露讓讀者清楚自己讀到的是哪一份部署。該部署會在 V1 mainnet launch ceremony 前完整清空。

**Phase 2 — Pre-Audit Mainnet（Stages 1 / 1.5 / 2 依 §1.5；TVL cap $10K → $100K）**
- V1 在 §1.5 launch gates 達成時以 **pre-audit cap 在 Cardano mainnet 啟動**（§1.5 Class A overrides 清除 + axis state 達 One-Yellow 或更佳 + 內審完成 + Preprod E2E + 部署儀式 dry-run，見 §8.1）
- 外部審計**不是** launch 前置條件；V1 在 mainnet 加上顯眼的 pre-audit 風險揭露運作（§8.2）
- TVL cap 隨 axis state 改善依 §1.5 Stage matrix $10K → $25K → $100K 推進
- 創辦人於 §4.3.1 minimal-operations 政策下擔任 keeper 與治理簽名者（在 (a) 配置下與兩位獨立 SPO 構成 1-of-3；在基本案 (b) 配置下由創辦人以 HD-key 分隔同時持有全部 3 席，見 §7.4），年化 ~$80–$200 營運補貼，不動用大額啟動資本
- 若外部基礎設施惡化，依 §1.5 由「降階條件」自動下調 cap

**Phase 3 — Audit + Cap-Lift 窗口（與 Phase 2 並行；於 §8.1 資金堆疊到位時啟動）**
- 外部審計委託到位（Anastasia Labs / MLabs / TxPipe / 獨立 Aiken 審計方，依 §8.1 (a)–(d) 結果）
- 審計完成**解鎖 cap**，從 100K 推升至 Stage 3（$500K initial、依 §1.5 ramp schedule 上至 $2M）
- 整段審計窗口期間 mainnet 在 100K cap 不間斷運作
- 若 §8.1 資金堆疊表現低於門檻，Options A–D 適用 — 四個 option 都讓 V1 留在 100K cap mainnet（見 §8.1）

**Phase 4 — Operational（Stage 3+ post-audit；前提是 Phase 3 成功）**
- 與成熟 Cardano DeFi 生態對齊的多產品線
- 治理依 §6.1 rotation path 朝社群 DAO 推進
- TVL ≥ $500K 後透過績效費累積使國庫自主可持續（§4.1 baseline）
- 若 Phase 3 始終未完成（審計資金始終未到位——§8.1 Option D），V1 在 Phase 2 無限期延續（mainnet、100K cap），不轉入 Phase 4

**我們不承諾的事**
- 不承諾 mainnet 啟動的具體日期。
- 不為「搶話題」這件事努力。
- 不會為了行銷理由調整 TVL 上限或啟動時程。

**我們承諾的事**
- 持續、可公開驗證的開發進度（每月開發報告）。
- 透明的觸發條件，公開儀表板每日更新。
- 任何不利情境下，使用者資金的優先順位高於協議自身延續。
- 誠實揭露我們不知道的事，包括生態時程的不確定性。

本文件描述 V1 在 §1.5 launch gates 達成時（依 §8.1「100K USDCx pre-audit cap 下上 mainnet 所需條件」checklist）將要部署的設計。它不是一份啟動公告：launch gates 是前瞻性條件，截至 v1.4 發布時 V1 尚未執行 mainnet launch ceremony。

### 0.1 現狀 vs 本文件描述的 V1

由於 OptiVaults 從 2026-04-17 起就在 Cardano mainnet 上有公開可見的部署，如果讀者用「OptiVaults launch」搜尋過，或在那個時間點看過 Cardanoscan，可能會把那個部署誤認為本白皮書描述的 V1。**那不是同一個東西。** 為了消除這個歧義：

- **現存的 mainnet 部署**（vault hash 前綴 `vault_v10-r71`，2026-04-17 部署）是一個**內部驗證期的合約迭代**，**不是**本文件描述的 V1 設計。它在另一個 vault 地址，Cardanoscan 上可以從合約 hash 區分（與 V1 不同）。其合約程式碼在同一公開倉庫中以另一個 version tag 發佈。
- **沒有第三方存款。** 前端（`vault.optivaults.app`）的存入頁面以單一創辦人控制的 allowlist（`Deposit.tsx ALLOWED_ADDRESSES`）gating，其他地址的 deposit 會被前端拒絕。該部署的運作資金是**創辦人內部測試資本**（來自啟動資金），用於在實際網路上驗證行為（治理流程、Liqwid Supply/Recall、Compound、脫鉤監控、緊急路徑）。Withdraw 對所有地址無條件開放——這種不對稱是刻意的，呼應 §1.6.1「自助退出永遠可行」的原則，即使在 V1 之前的階段也一樣。
- **與 V1 的架構差異。** 現存部署是**拆分前**的合約拓撲（大約 9 個 logic validator，基於單一 `vault_core` + `vault_protocol` 分區）。本白皮書描述的 V1 是 **`spec/architecture.md` §4.1 記錄的拆分後架構**（17 個 logic validator + 4 個 NFT mint policy + `minswap_v2_adapter` + 2 個 SundaeSwap artefact = 24 個 artefact），補足了 §5.4 P3-P5 滑點強制、oracle 整合（`SwapAda`）、多 validator A2 `publish` 覆蓋（§6.2）、adapter-pattern Withdraw-Zero fan-out（§3.2）等設計缺口。V1 是從不同 ref-script ceremony 重新部署的，**不是**現存合約的升級——現存 vault 到 V1 之間**沒有鏈上遷移路徑**。
- **V1 ceremony 前的處置。** 現存部署將在 **V1 pre-audit mainnet launch ceremony 前完整清空**（依 §0 為 Phase 2 entry；依 §1.5 為 Stage 1 / 1.5 / 2 啟動）：Path A `ActDeregisterStake` × 4 個 staking credential 已 queue（14 天 timelock 於 2026-05-23 ~16:55-17:11 UTC 執行），接著是完整 vault drain（`RecallFromLiqwid` + Minswap V2 swap-to-USDCx + Direct Withdraw 到創辦人錢包），最後執行 `reclaim-refs.ts` 回收 ref-script 鎖定的 ADA。Vault 地址會空且 freeze，**之後任何關於 V1 launch 的溝通都是指新的 pre-audit mainnet 部署、新的地址**，不是現存部署的延續。V1 launch ceremony 本身就是 Phase 2 進入事件——它早於外部審計完成（審計是 Phase 3 cap-lift gate，依 §0）。
- **既有的外部引用應在此框架下閱讀。** 任何先前公開把 OptiVaults 描述為「mainnet live」的內容——不論來自創辦人社群貼文、第三方 Cardano DeFi tracker、或社群頻道——指的都是**內部驗證階段的里程碑**，不是公開 V1 啟動。公開 V1 launch 尚未發生，由 §1.5 的觸發框架管理。

此節之所以存在，是因為「mainnet 上有合約」和「V1 已啟動」之間的差距，過去並未被足夠明確地揭露；誠實的專案不應該要求讀者從合約 hash 差異反推這個差別。

### 0.2 資金姿態：V1 是 volunteer-built、community-funded launch

V1 由單一創辦人以志工身份建構，加上小額 seed（~$2K USDCx 作為 Phase 1 working capital + 18 個月 pre-audit 窗口內估計約 ~$120 USD 基礎設施支出，採 §2.6.1 / §4.3.1 最小化配置）。**創辦人沒有財務能力獨力資助外部審計**（依委託模型 $50–$150K，見 §8.1），且 V1 不向 VC 募資、不發代幣、不徵求股權式承諾。

這意味著 **V1 在「pre-audit 100K USDCx hard cap + 顯眼風險揭露」框架下上 Cardano mainnet，無論啟動當日外部審計資金是否已到位**。外部審計**不是 mainnet 啟動的前置條件**；它是**把 100K cap 解鎖到 §1.5 Stage 2 / Stage 3** 的前置條件。§8.1 列舉的資金堆疊涵蓋審計的現實非稀釋性來源（Project Catalyst、Cardano Foundation、Intersect Member Committee、Aiken Foundation、audit firm 公共財折扣、社群 / DAO 資助池）。若這些來源始終未能到位，**V1 在 mainnet 維持 100K pre-audit cap 無限期運作** — 存入者仍可在小規模下取得 permissionless access，只是 cap 從未透過 audit-driven Stage 2+ 路徑解鎖。

**雙軌永續性模型。** V1 把兩個常被混淆的問題清楚分開：

1. **審計資金**（一次性、外部、約 $50–$150K）— 解決「V1 的 100K cap 能否解鎖到 Stage 2 / Stage 3？」— 受 §8.1 資金堆疊是否到位 gating，**創辦人不是 underwriter**。**不會 gating 初始 mainnet 啟動**。
2. **營運 runway**（長期、創辦人承擔、依 TVL 約 $80–$200/年 — 見 §4.3.1）— 解決「V1 能否持續運作？」— 從創辦人個人收入永續支撐，與審計資金完全脫鉤。

這就是「public-goods reference implementation」的實際意義：創辦人交付工程、以 volunteer 身份持續運作 keeper、並**在嚴格揭露 + 100K USDCx hard cap 下將 V1 上 mainnet（pre-audit）**；社群決定這項工程是否值得透過外部審計資助以進一步解鎖 cap。在 pre-audit cap 期間進場的存入者已理解並接受較高的風險側寫（未被發現的 CRITICAL bug 可能存在；見 §1.5 Stage 1 framing + §8.2 sub-scenario）。

---

## 摘要

OptiVaults V1 是 Cardano 上的非託管、以 USDCx 計價的多穩定幣收益金庫。存入者把 USDCx 送進由智能合約管控的金庫,換取 vUSDCx 份額代幣。Keeper 在治理設定的範圍內,於 Liqwid Finance 的 USDCx、DJED、USDM 之間自動複利收益並再平衡;手續費在 keeper 營運方與一個公開透明的 treasury 之間分配。

**啟動時的治理。** 金庫以兩種簽名配置之一運作,兩者都受相同的合約保證約束:

- **(a) 3-of-3 多簽** — 創辦人 + 2 位獨立 Cardano SPO,全員同意。這是目標配置,前提是 SPO 招募在 mainnet ceremony 前完成。
- **(b) 創辦人控制 + HD-key separation** — Phase 1 的 fallback(§7.4)。

考慮到 §8.2 預估的 Phase 1 TVL 為 $500–$25K,**存入者應預設啟動時為配置 (b)** — 招募是 stretch goal,不是 base case。存入者的恢復能力不取決於哪一種配置在運作,而取決於 §5.5.1 的三層合約層安全機制,這些機制在兩種配置下表現相同。Timelock 為 7 至 21 天,並有 1-of-n 取消否決;存入者隨時可提領 — 即使 keeper 停擺 — 透過自助緊急提領路徑退出。

**存入者持有什麼。** Share price 反映的是金庫當下的多穩定幣混合曝險,不是純 USDCx 的請求權。啟動目標配置為 45% DJED + 25% USDM + 30% USDCx 緩衝(§5.2)。金庫當下持有哪一種穩定幣,存入者就承擔哪一種的脫鉤風險。

**100K cap 與啟動期。** V1 在 Cardano mainnet 啟動時設有 100,000 USDCx 的 pre-audit 硬上限。在該 TVL 下,協議年收入約 $270,不足以覆蓋營運成本。V1 因此處於啟動期(bootstrapping phase):營運缺口由創辦人的 minimal-operations 個人收入補貼吸收(年化約 $80–$200,依 §4.3.1 — 是持續性補貼,不是大額預備金)。協議要等 TVL 成長到 $135K–$1.8M 區間(baseline 約 $500K;見 §4.1)後才會自給。

**審計是 cap-lift gate,不是 launch gate。** 不論 §8.1 審計資金堆疊是否到位,V1 都會在 mainnet 以 100K cap 加上顯眼的風險揭露啟動。當第三方外部審計完成時,它會把 cap **解鎖**到 Stage 3($500K → $2M;目標 2027 Q2–Q3)。若審計資金始終未到位,V1 在 mainnet 以 100K cap 無限期運作(§8.1 Option D)——協議保持 live,只是 audit 路徑的 cap 解鎖不會發生。創辦人是 volunteer builder,不是審計 underwriter:承諾的是小額 seed(~$2K Phase 1 working capital + 年化約 $80–$200 營運補貼 + $15K 審計 gap-fill 上限),**不**包含獨力支付 $50–$150K 的外部審計。存入者應將任何 Stage 2+ 的 cap lift 視為 community-funding-conditional。

**營運的可持續性。** Post-launch 的 keeper 在 §4.3.1 minimal-operations 政策下運作 — 單一自架伺服器、免費 tier 供應商、低 TVL cadence — 年化約 $80–$200,由創辦人個人收入吸收。這不動用預備金,因此營運 runway 的 sunset 觸發條件實際上不可達。V1 真正的失敗模式是 §1.5 Class A overrides(USDCx、Liqwid、Cardano 鏈或 oracle 事件)或創辦人明確的 sunset 決定 — 不是 runway 耗盡,也不是審計資金失敗(後者只把 cap 維持在 100K,不會結束協議)。

**定位:公共財參考實作。** V1 是非商業的公共財專案,不是為成長或股權式回報而最佳化的產品。4.5% 績效費用於覆蓋協議營運、審計儲備與長期 runway。沒有股權、沒有代幣、沒有對投資人的分配;Apache 2.0 授權讓其他 Cardano 團隊可以 fork 並特化(不同穩定幣組合、風險姿態、區域變體)。V1 可能是終點狀態,也可能成為其他團隊改造的基礎 — 兩者都是可接受的結局。存入者應以「貢獻公共財、當早期驗證者」的心態參與,而非購買商業服務(§12)。

**揭露:keeper share。** 4.5% 績效費拆為 40% 給 keeper、60% 給 treasury(§2.4)。由於啟動時由創辦人運作 keeper,這 40% keeper share — 約佔收益的 1.8% — 會流入創辦人的 keeper 錢包,作為基礎設施、監控與 on-call 責任的補償。所以 USDCx **確實**會流向創辦人;「沒有收益流向創辦人」是錯誤的解讀。誠實的解讀正好與利潤相反:100K cap 下 keeper share 年化約 $108,而 keeper 營運在 §4.3.1 最小化 footprint 下年化約 $80(較完整配置則 $400–$1,000)。Phase 1 的淨結果是創辦人從個人收入吸收的、年化約 $30–$75 的缺口。沒有股權式分配、沒有代幣 — 只有一條給創辦人的小額 USDCx 收入線,而它不足以覆蓋自身成本(§4.3)。

**這個產品怎麼來的。** 創辦人是 Cardano 的自我託管使用者 — 原生質押 ADA、持有小額 BTC、參與過 Midnight 的 NIGHT redeem、在 Minswap V2 提供流動性、目前持有 USDCx。V1 不是從發現市場機會開始的。創辦人想要一個非託管、自動複利、且小額提領時能直接拿回 USDCx 的金庫 — 而不是每次退出都跑一遍 recall 與 swap-back — Cardano 上沒有,所以自己蓋了一個。核心的使用者保護是合約不變量,不是營運承諾(§1.6)。

本白皮書說明 V1 做什麼、怎麼運作、存入者要接受哪些信任假設，以及啟動階段設計上的誠實侷限。

---

## 1. 問題定位

### 1.1 Cardano DeFi 缺的是什麼

Cardano 目前已經有：

- 借貸市場（Liqwid、Indigo iAsset）
- DEX（Minswap、SundaeSwap、Splash、CSWAP）
- 穩定幣（DJED、USDM、USDCx）

缺的是一個**非託管、經審計、以 USDCx 計價的多穩定幣收益金庫**，能自動跨 Liqwid 的 USDCx / DJED / USDM 三個市場複利。想賺被動穩定幣收益的使用者，今天只能自己追蹤三個 Liqwid 穩定幣市場的 APY、透過 Minswap V2 在三者之間換匯、管理 DEX LP 部位的無常損失、並在收益率改變時重新進場。V1 由 keeper 在治理設定的配置範圍內自動為金庫再平衡穩定幣組合；使用者拿到的份額以 USDCx 計價（即 vUSDCx），但經濟上等同對金庫當下所持 USDCx + DJED + USDM 混合資產的比例請求權。

**V1 不是多協議收益聚合器。** 全部收益來自 Liqwid 一個借貸協議。Minswap V2 只做穩定幣間的 swap router（換手工具），不產生收益。V1 的價值主張是「Cardano 穩定幣 supply-side 收益的便利層」：一筆存入同時取得三個 Liqwid 市場的曝險 + 自動再平衡 + 脫鉤監控 + 自助退場保證。若你要的是真正跨協議分散的收益聚合器，V1 還不是那個產品。未來若 Cardano 上出現其他成熟穩定的供應端協議，V1 會評估納入，但**目前只做 Liqwid**。

### 1.2 為什麼選 USDCx

USDCx 是 Circle 於 2026 年 2 月透過 **xReserve** 跨鏈儲備機制在 Cardano 發行的 USD 錨定穩定幣：

- 與 Circle 的 USDC 1:1 擔保（USDC 鎖在 xReserve 智能合約；USDC 本身由 Circle 持有的 USD 儲備 1:1 支撐，並由 Deloitte 每月出具 attestation）
- 採用 Cardano **native asset** 格式（多資產帳本原生代幣），而非 smart contract wrapped token——鏈上可直接轉帳與結算，不需要再包一層 wrapper
- 與 Circle 的全球 USDC 網路互通，可透過 xReserve 取用跨鏈 USDC 流動性
- Liqwid 已有運作中的 USDCx 借貸市場
- Minswap V2、SundaeSwap、Splash 都對 DJED、USDM、ADA、NIGHT 有流動性

**重要揭露**：USDCx 實質上就是 Circle USDC 在 Cardano 上的代表形式，透過 xReserve 與其他鏈相連。雖然 USDCx 在 Cardano 上是原生資產格式（沒有包一層合約），但發行與贖回流程仍依賴 Circle 的 xReserve 基礎設施、美元儲備管理，以及 Circle 的合規與審計程序。USDCx **不是**完全鏈上獨立的穩定幣——它的信任鏈會延伸到 Circle 與 xReserve。

**發行現況快照（白皮書 v1.3 撰寫時點 2026-05-11）。** 本節對 USDCx 的描述,反映的是 v1.3 發佈當下 USDCx 代幣、xReserve 機制與 Liqwid USDCx 借貸市場的實際狀態,具體如下:

- USDCx 代幣本身:2026 年 2 月起在 Cardano 主網以 native asset 形式運作至今。
- xReserve 跨鏈儲備機制:作為 USDCx 發行 / 贖回的橋接已實際運行,屬 Circle xReserve 基礎設施的 production 階段。
- Liqwid USDCx 借貸市場:已上線運作,但借貸需求仍稀薄,供應端 APY 目前約 0.5–2%(快照見 §4.4)。
- 由 USDCx 退回 Circle USDC 的贖回路徑:仍透過 Circle USDC 贖回 + xReserve 橋接退出 Cardano。

V1 主網啟動的前提是 USDCx 仍維持在 §1.5 Axis B 所描述的啟動就緒水準。若 USDCx 始終未達 Axis B Yellow 級距(流通量 $40M+),或營運狀態出現實質倒退,V1 的存入代幣可透過治理 `UpdateRegistry`(14 天 timelock)重新評估——可能的候選包括「Circle 直接把 native USDC 發到 Cardano、不再經過 xReserve」,或其他達到 Cardano-native 運作的 Tier-1 法幣穩定幣。讀者在做存入決策前,應該透過 Circle 官方管道與 Liqwid 治理論壇,自行驗證 USDCx 的最新狀態。

**V1 對 USDCx 的盡調核對清單：**

| 檢查項 | 狀態 |
|--------|------|
| 發行方身份公開 | 是 — Circle（透過 xReserve 機制） |
| 已發佈擔保證明 | 是 — Circle 月度 USDC 儲備 attestation（Deloitte），xReserve 鏈上可稽核 |
| 贖回路徑（USDCx → USD） | 是 — 透過 Circle USDC 贖回 + xReserve 橋接退出 Cardano |
| 協議支援 | Liqwid、Minswap、SundaeSwap 啟動即支援 |
| 鏈上流通 | 足以支援 V1 的 100K USDCx 預審計上限 |
| 審計歷史 | Circle Tier-1 合規框架 + xReserve 智能合約審計 |

V1 不取代存入者對 USDCx 本身的盡調。若不信任 Circle 的 USDC 發行模型、xReserve 橋接機制、或 Circle 的合規框架，不應使用 V1。

### 1.3 目標使用者

**OptiVaults V1 主要服務手中有小到中額 USDCx（約 $100–$10,000）的持有者**，也就是想在 Cardano 上賺被動穩定幣收益、但不想親手經營 DeFi 的使用者。V1 的經濟模型、使用介面、安全設計都是為這群人量身打造。**時程提醒**:$100-$10,000 這個目標規模指的是 **post-audit 階段**(目前目標 **2027 Q2-Q3+**,外部審計通過、TVL 上限解除之後;funding stack 不確定性見 §8.1)。Pre-audit 期間受 operator-enforced 100K USDCx TVL cap 限制。建議首次部位明顯低於此目標範圍下限（例如 $200-$2K 試水）。完整 pre-audit context 見 §8.2。

- **小額部位最容易被「進場 + 離場 gas」吃光。** 若一位只有 $200 USDCx 的使用者自己直接上 Liqwid：進場一次要做 swap USDCx → DJED + supply（約 2 筆 TX；若要同時分散到 DJED + USDM 則約 4 筆），將來離場還要再走一次 recall qToken + swap back。以目前 Cardano 網路費 + Minswap batcher 費估算，單方向大約 3–5 ADA，來回約 $2–4 USD，對 $200 部位就是本金的 1–2% 一次性摩擦，還沒開始賺收益。V1 把多市場配置集中在金庫層，一筆 Compound 就服務整個 TVL。因此每位存入者的進場只要一筆 CIP-30 交易、離場只要 burn 一次 vUSDCx，不必走 recall + swap back 的多步驟路徑。
- **不必每天看盤。** V1 的 keeper 會監控 Liqwid 的 APY 變動，並在治理設定的範圍內自動進行再平衡。小額持有者不需要追蹤 DJED、USDM、USDCx 三個市場的即時供應利率。
- **自助退場對小額同樣有效。** `withdraw-cli` 與 `emergency-withdraw` 工具讓任何存入者都能不靠營運方協助自行解倉，不論部位大小。
- **接受智能合約風險與穩定幣發行方風險**——任何 Cardano DeFi 產品都必須先建立這個基本信任邊界。

V1 可能不是合適選擇的情況：

- **大型機構**（單錢包部位 $500K 以上）——預審計 100K 上限對你立即形成約束，而且該規模通常自建 off-chain 再平衡機制能拿到比 V1 自動化層更完整的收益。
- **期望本金絕對保障的使用者**——V1 不保本，Liqwid 壞帳或穩定幣脫鉤都會讓份額價格下降（見 §5）。
- **需要監管背書的使用者**——V1 不做任何監管相關聲明；司法管轄層面的合規仍然由每位使用者各自負責。
- **只看 Product Overview 摘要就想下決定的使用者**——V1 的設計假設存入者會讀完 §5 Risks 的完整揭露。如果你偏好只看摘要就存入、不打算往下讀風險章節，建議等外部審計通過、TVL 上限解除之後再考慮，或先選 Direct Liqwid DJED supply 這類機制更單純的選項。

### 1.3.1 存入者實際得到什麼（產品優勢）

依照一般小額錢包受益的頻率排序：

1. **一筆交易完成多市場分散。** 存入一次，即同時取得 45% DJED + 25% USDM + 30% USDCx 閒置緩衝（啟動配置）的曝險。若要自己做到同樣分散，大約需要 2–3 筆 Minswap V2 的 swap 加上 2 筆 Liqwid supply 交易，而且要定期再平衡——每一筆都是獨立的網路費。V1 把策略執行打包到金庫層一次完成。
2. **自動 Compound，網路費依 TVL 規模攤薄。** V1 每個金庫週期只付一次 Minswap V2 batcher 費與 Cardano 網路費；自己在 Liqwid 操作的使用者則是每人各付一次。結果是小額持有者的淨 APY 可以追上大額持有者。
3. **vUSDCx 份額代幣抽象化部位。** 存入那一刻的倉位就是錢包裡的一個代幣；不用手動記帳、不必做 Excel。想送人或出售也能直接在錢包間轉讓。
4. **自助退場保證。** `withdraw-cli` 與 `emergency-withdraw` 不需要營運方配合就能使用；當 keeper 停擺超過 7 天，合約會在鏈上自動免收早提領費。本金永遠不會被卡住。
5. **脫鉤監控與停機程序。** keeper 會持續監看 Charli3、Orcfax 以及 Minswap V2 TWAP，若偏離連續 15 分鐘超過 1%，治理可透過 `EmergencyWithdraw`（`frozen=1`）凍結金庫，營運方同時停止接受新存入。自己在 Liqwid 操作則要自建這一套監控。
6. **透明的手續費結構。** 已實現收益扣 4.5%（validator 硬上限）、存入不收費、只有在 `min_hold_seconds` 內提領才收 0.1%，另外還有 SwapAda 機制造成約 0.02% APY 摩擦——它是為了補充金庫營運所需的 ADA，以 oracle 公平價用 USDCx 換 ADA 的鏈上閉環（詳見 §4.5）。沒有 AUM 管理費、沒有隱藏的績效費手法。
7. **附 1-of-n cancel 否決的鏈上治理。** 手續費上限、協議白名單等政策，任何變更都要經過 7–21 天 timelock 加公開揭露。你有充分時間在變更生效前退場。

**什麼時候選 V1，什麼時候直接用 Liqwid？**

| 情境 | 選 V1 | 選直接 Liqwid |
|------|-------|----------------|
| 部位 $200–10K | ✅ 進場一筆 TX、離場一筆 TX；多市場配置集中在金庫層 | ❌ 進場 + 離場 gas 約 $2–4 USD，對 $200 部位來回約 1–2% 本金 |
| 想要三穩定幣混合曝險 | ✅ 一筆 TX 完成 | ❌ 需 2-3 筆 swap + 3 筆 supply |
| 每週看盤 < 30 分鐘 | ✅ keeper 代勞 | ❌ 需自己監控 3 市場 APY |
| 脫鉤事件自我保護 | ✅ 合約層 freeze + 15 min sustained 偵測 | ❌ 需自建 oracle 監控 |
| 想要 vUSDCx 可轉讓的份額代幣 | ✅ 天然支援 | ❌ qToken 綁定錢包位置 |
| 部位 > $40K 且對 DJED 有定見 | ❌ 4.5% 績效費吃掉優勢 | ✅ 直接吃 100% DJED APY |
| 想要非 DJED/USDM/USDCx 的穩定幣 | ❌ V1 只支援這三種 | ✅ 可自行挑市場 |
| 不接受 m-of-n 治理風險 | ❌ 有治理層 | ✅ 只有 Liqwid 協議風險 |
| 不想付 SwapAda 0.02% 營運摩擦 | ❌ 有（§4.5） | ✅ 無 |

**誠實的損益平衡——兩成分框架（規範表）。** 在 V1 與 Direct Liqwid 之間做選擇,實際上同時牽涉兩種價值成分,誠實的損益平衡必須兩邊一起算。同一張表也作為 §4.4 的規範引用——兩節從此用同一套框架、同一組數字,不再各說各話。

**成分 A:純時間成本** —— 自己跑 Direct Liqwid 一年實際花掉的時間 × 你的時薪(以 15 小時/年 × 時薪 ÷ 5.44% gap 估算)。

**成分 B:風險管理外包** —— V1 在收益之外提供給你的東西:脫鉤監控、多穩定幣分散、合約層 freeze 反應、自動 compound、自助 emergency-withdraw。Direct Liqwid 使用者要嘛自己建一套,要嘛只能接受這些風險直接曝露在自己頭上。

| 使用者輪廓 | (A) 純時間損益平衡 | (B) 感知到的風險管理價值 | **實務損益平衡** |
|---|---|---|---|
| 時薪 $10、DeFi 經驗低 | ~$2,800 | ~$30K(高 —— 自己建監控很有壓力) | **~$33K** |
| 時薪 $20、中等經驗 | ~$5,500 | ~$25K | **~$30K** |
| 時薪 $50、經驗豐富 | ~$14K | ~$15K | **~$29K** |
| 時薪 $100、DeFi 專業人士 | ~$28K | ~$5–10K(本來就有自己的工作流) | **~$28–38K** |

**誠實推論**:

- 對絕大多數現實輪廓而言,實務損益平衡落在 **$25K–$40K 區間**,不是只看成分 A 的 $5K–$15K 區間。在此區間以下,V1 通常提供淨正價值——自己建監控與反應基礎設施是實打實的工夫,而脫鉤事件中一次操作失誤造成的損失,很容易遠超過 yield gap。
- ~$40K 以上、又有相關 DeFi 經驗的使用者,**單看數學 Direct Liqwid DJED 才是對的選擇**——V1 在這之上不再帶來淨正,我們明說。
- 明確**不重視成分 B** 的讀者(已經有自己一整套監控與反應工具的成熟持有者),請只看成分 A 那一欄,並在較低的損益平衡之上選 Direct Liqwid。對這群讀者,V1 不會試圖灌水 Component B。

V1 真正服務的對象因此是:存款規模在 $25K–$40K 及以下、又還沒建立自己的 DeFi 操作棧的使用者,加上原則上不接受 CEX 託管、以及刻意想要雙穩定幣發行者分散的使用者。我們選擇把這套揭露同時放在這裡與 §4.4(同一組數字),而不是用一個平均數字把實情蓋過去。

**簡而言之**：只要一筆 CIP-30 存入交易，你就能同時取得 Liqwid 三市場供應收益、自動再平衡、以及自助復原機制。代價是已實現收益的 4.5%。對 $200–$10,000 的部位——若直接走 Liqwid，進場 + 離場一次性 gas 大約占本金 1–2%——V1 的便利性節省是實在的，但是否能壓過 4.5% 績效費，仍要看你的持有期與時薪（見上方損益平衡表）。

### 1.4 Cardano 穩定幣借貸生態現實

要理解為什麼 V1 的設計是「單一協議的 Liqwid 包裝層」，先得認識 Cardano 穩定幣借貸基礎設施的現況。

#### 唯一一個成熟的借貸場域

截至 2026 Q2，Liqwid Finance 是 Cardano 上**唯一**規模有意義且運作中的穩定幣借貸協議。其他 Cardano 借貸協議要不是停運、就是只做非穩定幣抵押、或是 TVL 太小到無法做有意義的整合：

- **Lenfi（前身 Aada Finance）**：經歷 2024 年 12 月的智能合約漏洞事件後（團隊以 white-hack recovery 透明處理——詳見 Lenfi 官方在 2024 年 12 月於 blog / Twitter 發布的事後揭露），TVL 從近期高峰約 $5M 降到約 $230K（DefiLlama 協議 TVL history，存取時間 2026-05-12）。協議仍在運作，但規模已不足以作為 vault 多協議分散的可行第二場域。*以上數字為外部公開資料快照，可能會變動；讀者閱讀時應再次以 DefiLlama 驗證。*
- **Levvy**：被 Angels Finance 收購，目前在開發 V3。聚焦 NFT 抵押借貸，不是穩定幣市場。
- **FluidTokens**：只做 NFT 抵押借貸。
- **較小場域**（Yamfore、Cherry Lend 等）：每個市場 TVL 低於 $100K。

這不是暫時狀態。Cardano 穩定幣借貸需求一直被結構性地壓抑，因為缺少有規模的非穩定幣抵押品（Cardano 上沒有等同於 Ethereum 的 ETH/wstETH）。Pogun 的 BTC DeFi 在 2026–2027 年上線可能改變這點，但這是未來式，不是現在式。

#### V1 設計上的含義

V1 提供的「多穩定幣分散」（USDCx / USDM / DJED）操作在**資產層**，但**不在智能合約層**。這三個市場共用同一組 Liqwid 智能合約。Liqwid 的關鍵 bug 會同時影響三個部位。

V1 不把這當作「我們選的設計權衡」，而是「生態成熟度造成的限制」。我們明白記錄這個限制是因為：
- 未來存款者有權知道實際的風險拓樸，而不是行銷版本。
- V2 路線圖（§1.6.3）以這個限制改變為前提，並有明確的外部觸發條件。
- 啟動就緒框架（§1.5）在 Liqwid 專屬監測軸上反映這點。

#### Oracle 集中度

Cardano 成熟的 oracle 基礎設施主要由 Charli3 和 Orcfax 組成。Liqwid、Indigo 等大多數 Cardano DeFi 應用都使用這兩個協議。這代表 Cardano 上的 oracle 風險在協議層**結構性無法分散**。V1 透過雙源 oracle 讀取（§3.4）緩解這點，但無法迴避底層的集中度問題。這是不可化約的殘餘風險，明確列出來。

#### 限制改變的時候

V1 單一協議設計會在外部條件改變時重新評估。具體來說，V2 多協議擴張以「Cardano 出現第二個成熟穩定幣借貸場域」為前提（§1.6.3 有明確定義）。在那之前，加更多協議只會增加攻擊面，不會帶來有意義的智能合約層分散。

#### Cardano 生態相鄰產品（補充上下文）

在評估 V1 之前，存入者也應該了解 Cardano DeFi 有哪些與 V1 功能部分重疊的產品。

| 產品 | 做什麼 | 與 OptiVaults V1 的差異 |
|------|--------|-------------------------|
| **Liqwid Finance（直接 supply）** | USDCx / DJED / USDM / ADA 貨幣市場 | 只有單一市場曝險、沒有自動跨市場重配、也沒有份額代幣抽象化。再平衡與複利都要自己來。 |
| **Indigo Protocol（iAssets + iUSD 穩定池）** | 以 ADA 超額抵押鑄造合成資產（iUSD、iBTC、iETH）；穩定池賺清算費 | 風險模型完全不同：iUSD 是以 ADA 抵押的演算法合成穩定幣，不是法幣擔保；穩定池存入者要承擔 ADA 清算風險。 |
| **Minswap / SundaeSwap 穩定幣對 LP** | 對 USDCx/DJED、USDM/DJED、USDC/USDCx 等池提供流動性，賺 swap 費 | LP 部位在脫鉤事件中會承受無常損失；V1 刻意只取 supply-side 收益、避開 LP。 |
| **Genius Yield（歷史）/ Encoins** | 上一代的 Cardano DeFi 產品 | V1 啟動時已不是活躍競品；列在這裡以求完整。 |
| **ADA 原生質押** | 把 ADA 委託給 stake pool，賺約 2.3–2.4% | 不是 USDCx 計價的收益；需要持有 ADA，也就承擔 ADA 的價格風險。 |

誠實的定位：**V1 在 Liqwid supply-side APY 之上多加一層多市場分散與便利層**，並以 Minswap V2 作為穩定幣之間的 swap router。想把對手方風險壓到最低、而且願意自己手動配置的人，直接用 Liqwid 就好；想要分散的穩定幣收益、又不想自己跑 keeper 的人，才是 V1 的目標族群。

### 1.5 啟動就緒框架（Launch Readiness Framework）

V1 mainnet 啟動時程與 TVL 容量由三軸觸發框架決定。上限不由團隊主觀調整，由框架狀態決定，並由治理 multisig 加 7 天 timelock 強制執行。

#### 三軸監測

**A 軸：Pogun BTC 供應端 TVL**

Cardano 出現有規模的 Bitcoin DeFi 活動，是讓穩定幣借貸市場長期需求成形的主要外部催化劑。

| 級別 | 門檻 | 含義 |
|------|------|------|
| 🔴 紅 | < $5M，或 Pogun mainnet 未上線 | 此軸無啟動觸發 |
| 🟡 黃 | $5M – $15M | 催化劑形成中，持續監測 |
| 🟢 綠 | > $15M 持續 60 天 | 借需求已實質成形 |

衡量方式：60 天滾動平均的 BTC TVL 供應到 Pogun 借貸市場，資料來源 DefiLlama，並與 Pogun 官方數據交叉驗證。

**B 軸：USDCx 流通供應量**

Vault TAM 由 Cardano 上的 USDCx 流通量界定。後補貼期（2026 Q1 IOG 跨鏈費補貼結束後）的有機成長路徑，決定這個資產是否有獨立於行銷支援的產品市場契合度。

| 級別 | 門檻 | 含義 |
|------|------|------|
| 🔴 紅 | < $40M，或 30 天淨流出 > 10% | TAM 不足、底子在縮 |
| 🟡 黃 | $40M – $100M，趨勢穩定 | TAM 足夠、有機需求成形 |
| 🟢 綠 | > $100M 且 30 天淨流入為正 | 機構採用確認 |

衡量方式：透過 Blockfrost 追蹤鏈上 USDCx mint/burn 事件，與 Circle USDCx 官方統計、DefiLlama Cardano 穩定幣指標交叉比對。

> **門檻情境說明（2026 Q2）**：當前 USDCx 流通量約 $10–$20M，遠低於紅級門檻。$40M 黃級目標反映的是「V1 能服務 USDCx 有機需求中非微小比例、又不會變成供應端主導占比」的最低規模。如果到 2027 Q1 USDCx 流通量仍未達黃級門檻，會重新評估**門檻本身**而不是無限期延後啟動——見下面「最大延後」。

**C 軸：Liqwid 加權 supply APY**

這軸代表產品可行性。當加權收益低於 5%，V1 的價值主張（外包自動複利收 4.5% 績效費）對典型的存款規模就無法誠實成立。

| 級別 | 門檻 | 含義 |
|------|------|------|
| 🔴 紅 | 90 天加權 < 5% | 產品經濟性不可行 |
| 🟡 黃 | 5% – 7% | 邊際經濟性，break-even 困難 |
| 🟢 綠 | > 7% 持續 60 天 | 強經濟性，價值主張清楚 |

衡量方式：每日讀取 Liqwid USDCx、USDM、DJED 的 supply APY，依 V1 策略配比加權（45/25/30 預設），90 天滾動平均。

#### 否決條件

兩類 override 適用，**效果不同**（見 §0.2 / §8.1 的 volunteer-builder framing 為何分開）：

**Class A — 阻擋啟動 overrides（任一觸發完全阻擋 mainnet 啟動）。** 無論軸狀態如何，下列任一項成立時 mainnet 啟動被阻擋 — 這些反映的是會讓 V1 運作本身不安全的外部基礎設施失敗：

1. Liqwid Finance 過去 12 個月內發生過 high 或 critical 等級的智能合約事件。
2. USDCx 發行方（Circle，透過 xReserve 智能合約與 IOG 部署的 Cardano-side 整合）發生實質性運作事件。
3. Cardano mainnet 過去 6 個月內發生過 critical 鏈中斷。
4. Charli3 或 Orcfax oracle 過去 30 天內發生過持續異常（>24 小時）。

**Class B — Cap-lift overrides（V1 在 pre-audit 100K cap 下上 mainnet；這些條件只是把 cap 維持在 100K，阻擋進入 Stage 2 / Stage 3）。** V1 在這些條件下**不會**停留在 Preprod — 它會在 mainnet 上以現有的 100K USDCx cap 加上顯眼的 pre-audit 風險揭露運作（見 §8.2）：

5. V1 外部審計尚未通過。Mainnet 運作在 100K 繼續；Stage 2 / Stage 3 cap lift 需審計通過。
6. 外部審計資金截至 2027 Q4 仍未達到 §8.1 成本門檻。V1 在 pre-audit 100K mainnet cap 下無限期繼續運作；audit-driven cap lift 延後至資金到位（或始終不到位，§8.1 Option D 結局）。見 §0.2 funding posture 與 §8.1 Options A–D contingency tree——這四個 option 都不會強迫 V1 離開 mainnet，只決定 cap-lift 路徑。§0 maximum-deferral 路徑只在 **Class A** override 條件持續期間，或 §1.5 axis-state 觸發框架表明產品前提失敗（2027 Q4 前無任何 axis 達到 Yellow — 見下方「Maximum deferral」）時啟動。

#### 階段對應表

| 狀態 | A | B | C | 階段 | TVL 上限 | 是否需審計 |
|------|---|---|---|------|----------|------------|
| 催化劑前期 | 🔴 | * | * | Stage 0 — 僅 Preprod | 0（mainnet 不啟用） | — |
| 一黃 | 🟡 | * | * | Stage 1 — Limited Pilot | $10K（permissionless，前端顯著 pre-audit 風險提示；**無邀請制、無白名單**，見 §8.2） | **否**（pre-audit） |
| 兩黃 / 一綠 | 變 | 變 | 變，無紅 | Stage 1.5 — 開放 Pilot | $25K（公開但有限） | **否**（pre-audit） |
| 兩綠無紅 | 任意 🟢🟢🟡 組合 | | | Stage 2 — 軟啟動 | $100K | **否**（pre-audit；cap 維持 100K） |
| 全綠無紅 | 🟢 | 🟢 | 🟢 | Stage 3 — 正式啟動 | $500K 起，逐步增至 $2M | **是** — 外部審計完成（§8.1 cap-lift gate） |

Stages 1 / 1.5 / 2 是 **pre-audit mainnet stages** — V1 在 axis state 達標後即依該 cap 上 mainnet（依 §1.5 Override conditions Class A 清除 + §8.1 launch checklist）。Stage 3 cap lift 需要外部審計完成（依 §8.1 cap-lift checklist）。若 §8.1 資金堆疊始終未到位，V1 在 mainnet 維持 Stage 2（100K cap）無限期運作——見 §8.1 Option D。Stages 1 → 2 → 3 **不**由時間 gating；它們依 axis state 與審計結果推進。

#### Stage 3 增長時程

進入 Stage 3 之後，TVL 上限的提升依下表進行，前提是「持續維持全綠 + 過去 30 天無 high 等級 bug + 無治理暫停提案待議」：

- 第 1 個月：$500K
- 第 3 個月：$1M
- 第 6 個月：$1.5M
- 第 12 個月：$2M

上限不會因為時間到了就自動上調。每一步都需要當下狀態驗證通過。

#### 降階條件

mainnet 啟用後，下列條件會自動下調階段：

| 條件 | 動作 |
|------|------|
| 任一軸紅級持續 30 天 | 暫停新存入，加強監測 |
| 兩軸紅級持續 7 天 | 暫停新存入，治理 24 小時緊急評估 |
| Liqwid 發生 high 等級事件 | 立即暫停，啟用 emergency withdrawal 路徑 |
| USDCx 脫鉤事件 | 立即暫停，評估 sunset protocol |
| 內部審計發現 critical bug | 立即暫停，緊急修復 |

所有降階情境下，現有使用者資金都仍可提領。降階只影響新存入。

#### 公開儀表板與治理綁定

三軸當前狀態、活動階段、與對應 TVL 上限會在公開儀表板每日更新。儀表板不是裝飾——它是上限的權威來源，而且鏈上 VaultDatum 中的上限值必須跟儀表板狀態一致。

上限變更需要：
1. 觸發狀態驗證（變更時點儀表板狀態的密碼學證明）
2. 治理 multisig 批准
3. 啟用前 7 天 timelock

這個綁定確保「我們會在條件成熟時啟動」是可驗證的承諾，不是行銷話術。

#### 最大延後

如果到 2027 Q4，沒有任何一軸進入黃級狀態，專案進入策略重評估。可能的結果包括：
- 延長延後並修訂觸發條件
- 把固定利率 vault（§1.7）作為主要啟動產品
- 把累積的工作轉用到相鄰產品上
- 把程式碼以 Apache 2.0 貢獻給 Cardano 生態並 sunset

2027 Q4 這個截止日是為了避免無限期延後、確保決策可問責。

### 1.6 V1 的起源——Cardano 自我託管使用者親手打造的產品

OptiVaults 的創辦人本身是 Cardano 的自我託管使用者，正好是 V1 的典型目標使用者（職業背景見 §7.4，作為補充）：

- **2025 年起持有 ADA 並委託 stake pool 做原生質押**——Cardano 核心資產部位，透過 stake pool 賺協議原生收益。
- **2025 年起持有小額 BTC**——多鏈 scarce-asset 配置，同樣的自我託管姿態。
- **參與過 Midnight 的 NIGHT redeem**——透過 Cardano 生態內合格持倉領取 NIGHT 代幣。（後來這些 NIGHT 跟 ADA 配成 Minswap V2 的 LP 部位——見下一項——但那是後續的使用行為，不是事先規劃好的「組合部位」步驟。）
- **2026 年起在 Minswap V2 的 ADA/NIGHT pool 提供流動性**——Cardano DeFi 主動參與者，不是被動持有人。親身經驗過 Minswap batcher 行為、cancel 路徑、pool 遷移、ADA-paired 部位的 impermanent loss。
- **目前持有 USDCx**（Circle 於 2026 年 2 月透過 xReserve 在 Cardano 發行）——Tier-1 法幣擔保穩定幣，是 V1 的 deposit token。

**V1 的起點是很具體的個人需求。** USDCx 就放在創辦人錢包裡，現實的選項有四條：

- **(a) 送到 CEX 換 earn 產品**——因自我託管原則拒絕。
- **(b) 直接在 Liqwid 的 USDCx 市場 supply**——利率大約 0.5-2%，扣掉通膨實際報酬常常是負的，不值得花時間。
- **(c) 把 USDCx 換成 DJED，再 supply 到 Liqwid 的 DJED 市場**——年化可以到 ~11.8%。進場是 2 筆 TX（swap + Liqwid supply）。離場或每次部分提領是反向的 recall + swap back 一組往返。若要同時分散到 DJED + USDM 就是大約 4 筆進場、兩個部位並行管。進場之後 qToken 放在你自己錢包裡、兌換率自動累積，中間沒有每週期再平衡或定期 compound 的家庭作業。對 $200 部位而言，一次進場 + 一次離場來回 gas 大約是本金的 1-2%，持有越長攤得越薄；短期持有或頻繁部分提領才會感受明顯。
- **(d) 就讓 USDCx 躺在錢包裡**——0% 收益，而且 USDCx 發行者風險一樣要承擔。

這四條都不是創辦人真正想要的。真正想要的很簡單：**「把 USDCx 存進去、讓它自動在 Liqwid 上複利，之後需要動用小額 USDCx 時能直接提出來，不用每次都走 recall qToken + swap back 的多步驟往返」**——這個對小額提領很關鍵，因為 $50-100 的提領若要自己跑完整流程，光 gas + batcher 費加起來很可能就吃掉被提領金額的 5-10%。而 Cardano 上當時沒有這種經審計的非託管自動複利 vault——所以 V1 就是專門為了補上這個產品做的，從創辦人自己的存入需求出發，不是從市場規模反推。

**V1 是「我自己在找但找不到、只好動手做」的產品。** 這就是**起源故事**，同時也是**產品與市場契合**（product-market fit）的陳述：創辦人不是在猜想遠端客戶想要什麼，而是在出貨一個他自己想用的產品。目標使用者清單上的第一位，就是創辦人自己。

**Minswap LP 的經驗跟 V1 設計直接相關。** 是真的 Minswap V2 LP（而不是讀過 Minswap 文件的人），代表創辦人實際上：
- 看過 batcher 延遲——有時候秒成交，有時候池狀態被競爭時 fill 會堆著。V1 的 keeper 設計有為此 budget（Queue Withdraw 路徑 <1 小時結算是對 batcher cycle 現實的回應，不是理論 SLA）。
- 親身踩過 cancel 邊界情況——`StakeCredential::Constr(0,[])` vs `Constr(1,[])` 編碼差異、pool-shard 遷移問題——這也是 V1 整合手冊（`docs/integration-playbook.md`）把 cancel 路徑當成必須逆向工程、不是可選項的原因。
- 經驗過 ADA-paired LP 的 impermanent loss——這就是為什麼 V1 明確避開 LP 部位（§2.3），只取 supply-side Liqwid 收益。這個設計選擇來自經驗偏好，不是理論風險框架。

### 1.6.1 V1 的使用者保護分層:合約內強制 vs 外部依賴

V1 的使用者保護分兩層，存入者應該清楚知道自己正在依賴哪一層。

> **核心使用者保護是合約不變量，不是營運承諾。** V1 的承諾為什麼可信？因為**我們在程式碼層就根本做不到違反這些承諾。** 有幾項承諾在 validator-hash 層就被排除了背棄的可能：
>
> - 沒有任何 redeemer 能把 `idle_buffer` 送到存款人以外的地址。
> - `performance_fee_bps` 由 `vault_gov_policy.ak` 的 `UpdateFee` redeemer 透過共用的 `validate_update_fee` helper 硬鎖在 450（4.5%）上限，任何治理動作都無法把它推高。
> - 不存在「暫停提款」的 admin 開關。
>
> 這些都是已部署 validator hash 的客觀屬性，任何人都可以自己驗證。

> **不是每一項保護都是純合約不變量。** 有三項在合約內、無條件成立：(a) 沒有 admin-drain redeemer、(b) 4.5% 費用上限不可變、(c) keeper 離線 7 天後早提款費自動免除（§5.4）。其他項目仰賴外部基礎設施的可用性：提領成功要 Cardano 鏈 + Liqwid（若有部位在那邊）+ Minswap V2（若需 routing）+ USDCx 流動性（最終產出）都正常。任何一環 out，存款者鏈上的請求權仍然可強制執行，但結算可能是 vault 當下持有的資產，不一定是 1:1 USDCx。自助 `emergency-withdraw` 工具仍然能用，但產出品質會跟外部協議狀態連動。這才是誠實的姿態，不是「在任何情況下提領永遠可行」。

V1 的定位是彈性與收益的操作體驗，搭配鏈上強制的使用者保護。這個定位由三件事構成：

- **費用**：不收 AUM 費、不收管理費。唯一一筆費用，是對已實現收益收取的 4.5% 績效費。
- **退場路徑**：自助 `withdraw-cli` / `emergency-withdraw` 跟主產品一起發布，是首要功能而非緊急備案。
- **發布節奏**：在 100K USDCx 硬上限下、帶顯眼風險揭露的 pre-audit mainnet 啟動 + 多輪內部審計，之後再經外部審計通過解鎖 cap，推進至 Stage 2 / Stage 3。§8.1 解釋為何審計是 cap-lift gate 而非 launch gate。

Pre-audit 階段存入者是在 §8.2 sub-scenario 框架、完整風險透明度下決定進場，**不是**走加密圈「先上線再說、出事再處理」的姿態。合約層的安全設計（§5.5.1 三層治理保護、§6.3 硬上限、自助緊急退場）提供與審計狀態無關的存入者恢復下限。V1 不規避 DeFi 固有的信任邊界：錢包私鑰即本金控制、已確認 TX 不可逆、合約與外部依賴都可能失效。這些在 §5.1、§9.1、§12 都有詳細揭露。

### 1.6.2 為什麼選 Cardano、為什麼是現在這個時點

講公平一點，會有人問：Aave、Compound、Yearn 幾年前就在 Ethereum 上做過概念類似的 vault-aggregator，為什麼 OptiVaults V1 現在才在 Cardano 上做？為什麼不更早做？為什麼不去別條鏈做？

誠實的答案：**讓這個產品能在 Cardano 上成立的條件，最近才到齊。** 提早兩年做，你會在核心屬性上被迫妥協；換到別條鏈做，你會失去 Cardano eUTXO + Plutus 模型在架構上的契合。

- **USDCx 2026 年 2 月才上線。** Circle 透過 xReserve 機制推出 USDCx 之前，Cardano 上一直沒有一個具備機構等級後盾、而且每個月都有儲備證明的法幣擔保穩定幣。如果 vault 只能建在 DJED（ADA 抵押）或 USDM（較小型發行者）上，整個產品會被集中在單一發行者的信用風險上。USDCx 補上了這塊核心資產的空缺。
- **Liqwid 穩定幣市場在 2024–2025 成熟。** DJED 和 USDM 要在 Liqwid 上有足夠的借款需求跟供應深度，supply-side aggregator 才能在不大幅扭曲利率的情況下配置有意義的金額。這個深度是 2024 下半年才到位，而且一路延續到現在。
- **Cardano SPO 營運者社群成熟。** V1 的治理模型（3-of-3、兩位獨立 SPO 簽名者——見 §5.5）要靠一群成熟、有公開身分、在生態系裡有長期經濟利害的 stake pool 營運者。SPO 社群的廣度跟聲譽深度，是最近幾個 epoch 才長到足以作為可信獨立治理簽名者的水準。
- **Aiken + PlutusV3 工具鏈成熟。** V1 的合約架構（Withdraw-Zero 轉發、多 validator staking 委託、Conway 期 PlutusV3 reference script 費用結構）所依賴的工具鏈，到 2023 年都還是實驗性質。Aiken 做到 `v1.1.x`、`stdlib` 也穩定之後，這套實作才在可以負擔的審計預算內做得出來。

V1 不是 DeFi 史上第一個自動收益 vault，它是**這類產品裡、第一個架構前置條件真的在 Cardano 上到齊的版本**。更早動手，要嘛得在核心屬性上讓步，要嘛得等那些當時還沒存在的基礎元素（資產、市場、工具鏈）先發展起來。

### 1.6.3 V2 多協議聚合器：條件清單

V2 擴張到多協議穩定幣收益聚合器，以**外部生態條件**為前提，不以團隊內部時程為前提。下列條件**全部成立**，V2 開發才會啟動：

**必要條件（全部都要符合）**

1. **第二個成熟借貸場域。** Liqwid 以外的 Cardano 穩定幣借貸協議達到並維持 $5M+ TVL 連續 12 個月。
2. **審計對等。** 第二個場域至少完成兩次與 Liqwid 審計史等深度的獨立外部審計，且無 high 等級開放發現。
3. **運作紀錄。** 第二個場域連續 12 個月運作期間無 high 等級智能合約事件。
4. **V1 成熟度。** V1 mainnet 已完成外部審計，且 TVL 高於 $500K 運作 12 個月。
5. **國庫儲備。** OptiVaults 國庫儲備等同於 6 個月運作 runway，提供 V2 審計預算而不依賴外部資金。

**目前狀態（2026 Q2）**：5 條件中 0 條成立。

**透明監測**

每個條件的狀態在 OptiVaults 公開儀表板上監測。我們每月發布一份摘要，指出哪些條件仍未滿足、以及哪些條件相對於前月新近滿足。

**為什麼是這幾條，不是別的**

列出的條件不是隨意的。每一條都對應 V2 多協議擴張會帶來的真實風險：
- 條件 1–3 確保「加上第二個場域」是增加分散度，而不是用一個未經驗證的風險檔案取代 Liqwid 成熟的風險檔案。
- 條件 4–5 確保 V2 開發不會危及 V1 穩定，也不會耗盡維持 V1 良好運作所需的資源。

**不承諾時程**

我們不承諾 V2 的具體日期。基於目前 Cardano DeFi 開發路徑，V2 條件不太可能在 2028 年之前全部達成。我們不會為了加速 V2 而人為調整這些條件。

**條件未達成時的替代路線**

如果到 2028 Q4，第二場域條件仍未達成，V2 將被無限期延後。這個情境下，OptiVaults 會把擴張焦點放在：
- 固定利率 vault 產品（§1.7）——不需要多協議分散
- Pogun BTC 抵押收益路由（§1.7）——在 Liqwid 框架內擴張 V1
- Midnight 上的隱私 vault（§1.7）——與多協議路徑正交

**V1 有可能就是終點狀態——這也是一個可以接受的結果。** 如果連 V2.x 或 V3.0 路徑也都沒有實現，V1 就停留在「單協議 Liqwid wrapper + 三穩定幣曝險 + m-of-n 治理」——比「未來多協議 aggregator」更窄的價值主張。我們會建議存入者以 V1 **現在的樣子**來評估它：**自動複利 + 雙發行者穩定幣配置 + 自助退場保證 + 經審計且有上限的費用結構**，費用是已實現收益的 4.5%。這組合對你是否划算，取決於你自己的替代方案比較（直接 Liqwid DJED、CEX earn、或純粹持有 USDCx——§4.4 都有完整對比）。

**授權條款的定位（連帶說明）。** OptiVaults 沒打算要當 Cardano 最大的 vault。明確的目標是把一份完整、經審計、以 Apache 2.0 授權的參考實作放進 Cardano 開源公共財，讓其他團隊可以 fork 並做特化（不同穩定幣組合、不同風險姿態、產業別或區域性變體），不管 OptiVaults 自己會不會長大。BSL / source-available 授權會把 V1 的競爭地位保護到 2028 年，代價是擋掉這類 Cardano 生態系層級的採用——這是我們認為真正比較有價值的後果。Apache 2.0 就是符合這個目標的授權條款。

### 1.7 未來產品路線圖

OptiVaults 是單一產品啟動（V1 浮動利率 vault），但專案結構設計成可以隨 Cardano DeFi 基礎設施成熟而擴張到相鄰產品。每一個未來產品都依賴具體的外部觸發條件，不是內部時程。

#### V1.0 — 浮動利率穩定幣 vault（本文件）

- **狀態**：Preprod 測試網部署完成，等待啟動就緒條件（§1.5）
- **觸發**：兩黃軸狀態 + 外部審計完成
- **預估啟用**：2027 Q2 – Q3（中位情境）

#### V1.5 — 固定利率 USDCx vault

互補產品，提供期限鎖定、固定利率的 USDCx 收益（例如 4.0% APY 6 個月）。為機構與 DAO 國庫使用者設計，他們需要可預測的回報來做財務規劃。

**機制概要**：使用者把 USDCx 存入固定利率世代（3、6、或 12 個月到期）。資金透過 V1 機制（Liqwid 多市場）部署。實現收益與承諾利率之間的差價累積在儲備金中。儲備金涵蓋低收益期間的不足。Black Swan Clause 定義在哪些條件下固定利率會被暫停（Liqwid 關鍵故障、USDCx 脫鉤等）。

**觸發條件**：
- V1 mainnet 運作 6+ 個月
- 國庫儲備 > $5K
- Liqwid 90 天加權 APY 持續高於 4.5%（為 3.0% 提供利率提供 margin）

**預估啟用**：2027 H2（中位情境）

**為什麼做這個產品**：Cardano 沒有固定利率穩定幣收益基礎設施。Pendle 不在 Cardano 上運作。「需要可預測回報的穩定幣持有者」這個市場區段沒人服務。

#### V2.0 — 多協議聚合器

完整條件見 §1.6.3。擴張到多協議穩定幣收益聚合器，以第二個成熟借貸場域出現為前提。

**預估啟用**：條件達成則 2028+，不達成則無限期延後。

#### V2.x — Pogun BTC 抵押收益路由

V1 的擴展，把 Pogun BTC 借貸者使用的 Liqwid 市場納入路由邏輯。當 BTC 持有者在 Pogun 抵押 BTC 借出穩定幣時，V1 可以是供應端對手方，捕捉產生的收益。

這不是新 vault 產品，是 V1 市場路由邏輯的補充。如果 Pogun 整合既有的 Liqwid 市場，不需要另外的審計。

**觸發條件**：
- Pogun 借貸 mainnet 運作中
- Pogun BTC TVL > $15M 持續 60 天
- Pogun 審計史驗證（至少一次外部審計，無 high 等級開放發現）

**預估啟用**：2027 Q2 – Q4（取決於 Pogun 上線時程）

#### V3.0 — Midnight 上的機構級隱私 vault

OptiVaults 的隱私保護變體，部署在 Midnight 上，利用 Midnight DeFi Kernel 做 shielded 部位管理。為需要可審計但非公開 DeFi 曝險的機構使用者設計。

**機制概要**：使用者在 Midnight 存入，收到 shielded 部位憑證。收益生成繼續透過 Cardano 上的 Liqwid（公開的），但所有權對使用者私密。依 Midnight 的設計，可選擇性揭露給審計員與監管者。

**觸發條件**：
- Midnight DeFi Kernel 釋出生產版本
- Compact（Midnight ZK DSL）工具鏈達到審計就緒
- Cardano ↔ Midnight 跨鏈訊息傳遞基礎設施成熟
- V1 審計完成且穩定運作 12+ 個月

**預估啟用**：2028 H2 – 2029

#### 依賴關係與優先順序

| 產品 | 依賴 | 不依賴 |
|------|------|--------|
| V1.0 | Liqwid、USDCx、審計團隊產能 | – |
| V1.5 | V1.0 運作中 | 多協議 |
| V2.0 | 第二場域 + 5 條件 | V1.5 |
| V2.x | Pogun 上線 | V2.0、V3.0 |
| V3.0 | Midnight DeFi Kernel | V2.0、V2.x |

V1.5 比 V2.0 優先，因為它的觸發條件在 OptiVaults 的控制範圍內（V1 運作穩定性），不是外部（第二場域出現）。V2.x 比 V2.0 優先，因為 Pogun 的 2026–2027 年計劃時程比「第二個成熟借貸場域出現的不確定時點」更具體。

#### 路線圖的可持續性

這個路線圖設計成即使個別觸發沒有點燃，仍然有意義：

- 如果 Pogun 失敗或顯著延後：V2.x 延後，但 V1.5 與其他產品繼續推進。
- 如果多協議條件永遠沒有實現：V2.0 無限期延後，但 V1.5、V2.x、V3.0 仍然可用。
- 如果 Midnight DeFi Kernel 沒有成熟：V3.0 延後，其他產品不受影響。

多條平行路徑減少 OptiVaults 擴張計畫的單點失效風險。

---

## 2. 產品概覽

### 2.1 存入流程

1. 造訪 optivaults.app/deposit
2. 連接 Cardano 錢包（Eternl、Lace、Vespr、Typhon、Yoroi）。一般 CIP-30 相容錢包皆可使用；上列為啟動時主動測試的清單。
3. 輸入 USDCx 金額並確認
4. 錢包簽署 TX（由 OptiVaults API 伺服器端建構）
5. TX 提交上鏈
6. 確認後，依當前份額價格收到 vUSDCx

vUSDCx 是 Cardano 原生代幣，代表對金庫資產的比例所有權。隨著金庫累積收益，份額價格成長。

### 2.2 提領流程

1. 造訪 optivaults.app/withdraw
2. 輸入欲銷毀的 vUSDCx 數量
3. 錢包簽署 TX
4. 金庫銷毀 vUSDCx 並將 USDCx 送至使用者地址

**三種提領模式：**
- **即時提領**（閒置緩衝足夠且已過 `min_hold_seconds` 冷卻窗口時）：一筆 TX 完成，使用者僅付網路費。冷卻窗口機制詳見 §2.4。
- **排隊提領**（緩衝不足時）：提領訂單進入 proxy 地址，keeper 於下一 batcher 週期彙整至 BatchProcess TX。常態運作下結算時間通常小於 1 小時（keeper 每 5-15 分鐘跑一個批次週期，每週期處理待處理訂單），但此為**營運目標而非合約強制 SLA**。使用者資金在訂單 UTXO 中，隨時可透過 `Cancel`（任何 block）或自動 `Expire`（訂單 on-chain `expires_at` 時點之後，預設 24 小時）取回。
- **自助緊急提領**（keeper 離線 >7 天時）：使用者本機執行 `withdraw-cli` 或使用 emergency-withdraw 網頁工具自行建構並提交 TX

### 2.3 收益來源與費用定義

#### 唯一收益來源：Liqwid qToken 利息

V1 透過單一機制產生收益：來自 Liqwid 穩定幣借貸市場的供應端利息。存入的 USDCx 會視情況換成對應幣種，再供應到 USDCx、USDM、DJED 市場；Liqwid 發行 qToken，其價值隨借款方支付利息而累積。

V1 不賺：
- Liqwid 流動性挖礦獎勵（截至 2026 Q2，Liqwid 不向穩定幣供應方發行 LQ 代幣；這是 Liqwid 費用模型的結構性特徵，不是 V1 keeper 邏輯的疏漏）。
- DEX 交易手續費（V1 不為 AMM pool 提供流動性）。
- 清算獎勵（V1 不參與穩定池）。
- 協議治理費用分配（V1 不質押治理代幣）。

單一來源設計減少會計複雜度，消除獎勵代幣波動曝險，讓 NAV 在正常市場條件下保持單調遞增。

#### 績效費精確定義

4.5% 績效費在每次 Compound 事件時計算如下：

```
fee_amount = 0.045 × max(0, NAV_now − NAV_last_compound − realised_rebalance_slippage)
```

其中：
- `NAV_now` = Compound 事件時點的金庫總價值，以 USDCx 計價
- `NAV_last_compound` = 上次 Compound 事件的 NAV
- `realised_rebalance_slippage` = 自上次 Compound 以來，所有跨市場再平衡的滑點成本總和。滑點 = oracle 公平價與執行價的差。

關鍵屬性：
- **負期間產生零費用。** 如果 NAV 下跌（例如 USDM 脫鉤），那次 Compound 不收費。累積損失完全由份額持有者承擔。
- **滑點由協議承擔，不直接由使用者承擔。** 已實現再平衡滑點減少費用基底，不是直接減少使用者 NAV（滑點在再平衡執行時就已實現；這條確保費用是對「已扣除滑點的淨收益」計算）。
- **費用只對已實現收益收取。** Compound 事件時尚未測量的 qToken 累積（unrealised），到下次 Compound 才會產生費用。
- **不採用 high-water mark（HWM）。** 每次 Compound 各自獨立對前次 Compound 的 NAV 計算。從前期高點回升不會觸發「補繳 fee」。HWM 是否在 V1.5 或之後納入是治理層決定，V1 目前不規劃。

#### 啟動日目標配置

（由治理 `UpdateStrategy` 設定，可於 §2.5 定義的邊界內調整）：

| 資產 | 目標 | 角色 | 啟動日收益貢獻 |
|------|------|------|----------------|
| DJED（Liqwid supply） | 45% | 主要收益——演算法穩定幣，啟動時借貸需求最高 | 此份額享完整 Liqwid DJED 供應 APY |
| USDM（Liqwid supply） | 25% | 次要收益——法幣擔保，Liqwid 市場 TVL 較小（但 DEX swap 側有 USDCx/USDM 11.6M 直接池；詳見 §5.2） | 此份額享完整 Liqwid USDM 供應 APY |
| USDCx（閒置 buffer） | 30% | **提領流動性——V1 啟動日 0% 收益**（buffer USDCx 閒置於金庫地址；V1 啟動時 NOT 供應至 Liqwid USDCx 市場） | **0%** — 詳見下方說明 |

#### 為什麼 buffer 啟動時是 0%，以及未來可以如何調整

Buffer 的用途是讓單筆交易就能完成直接提領（Direct Withdraw），不必再走 Liqwid Recall（那會額外多一筆 gas、也可能遇到流動性摩擦）。要穩定做到，buffer 必須保持流動，也就是不能被鎖在需要另外發一筆 Recall 才能解鎖的 Liqwid 供應部位裡。

內部驗證期曾經試過把 buffer 停在 Liqwid 的 USDCx 市場賺 0.5–2% APY，實驗結果顯示兩個問題：(a) Liqwid 的 USDCx 市場深度不足，只要服務到 TVL 約 5% 的提領量，解鎖 buffer 就已經產生明顯滑點；(b) 低 APY 的市場上，每個週期 Recall + Supply 的 gas 成本反而超過賺到的利息。**所以 V1 啟動時採用 buffer = 0% 收益、閒置在金庫地址。**

#### Buffer drag — 量化

Buffer 的 drag 用「假設把 buffer 也拿去 supply 到 Liqwid USDCx 市場」這個替代方案來衡量：

```
buffer_drag = buffer_ratio × Liqwid_USDCx_supply_APY
```

按 Liqwid USDCx supply APY 1.5%（2026 Q2 估算）和 buffer 比例 30%，這代表約 **45 bps 的收益放棄**（30% × 1.5% = 0.45%），相對於「buffer 也部署到 Liqwid USDCx」的全部署版本。注意：這個 drag 數字衡量的是「buffer 不部署到 Liqwid USDCx 的成本」，不是「buffer 不部署到最高 APY 市場的成本」。

當下列條件全部成立時，治理可以透過 7 天 timelock 啟用部分 buffer 部署：

- Liqwid USDCx 市場深度 > $10M
- Liqwid USDCx 市場 90 天平均 APY > 3%
- 待提領隊列 < 金庫 TVL 的 5%

啟用後 idle 比率降到 15%（buffer 一半部署到 Liqwid USDCx），同時保留足夠流動性服務正常贖回流量。

**治理可以調整：Liqwid USDCx 分配保留條款。** V1 啟動時明確選擇 0% 至 Liqwid USDCx 的保守配置，但保留在上述條件成立時透過治理 `UpdateStrategy`（7 天 timelock）將部分 buffer 重新分配至 Liqwid USDCx 市場的權利。其他觸發條件還包括：出現更適合存 buffer 的低風險去處，例如未來的 Cardano Treasury T-bill wrapper、或更深的穩定幣貨幣市場。這些都不需合約變更，只是現有 validator 邏輯內的政策調整。任何此類調整，治理都會在執行前公開說明理由、預期收益提升、以及解倉計畫。存入者有 7 天 timelock 窗口可決定是否退場。

#### 跨市場路由與再平衡

V1 在 USDCx、USDM、DJED 三個 Liqwid 市場間動態配置供應資金。再平衡的觸發條件包括：

- 跨市場 APY spread 超過 200 bps 持續 7+ 天
- 單一市場利用率超過 90% 持續 24+ 小時（從該市場 rebalance 出來）
- 單一穩定幣相對 peg 偏離超過 50 bps 持續 1+ 小時（從該幣種 rebalance 出來）
- 治理發起的權重調整（7 天 timelock）

完整的 rebalance 演算法規格，包含滑點預算、DEX 路徑選擇、頻率上限，發布在 OptiVaults GitHub repo 的 `spec/rebalance-policy.md`。原始碼是規範性參考；白皮書只提供高層機制描述。

**V1 不是純 USDCx 產品。** 70% DJED + USDM 的曝險正是價值主張的核心（借貸市場更深、APY 明顯高於閒置 USDCx）；但相對地，存入者要按金庫當下的混合比例承擔三種穩定幣的脫鉤與流動性風險。詳見 §5.2 多穩定幣脫鉤揭露。

**V1 不使用：**
- DEX LP 倉位（無常損失風險）
- 演算法流動性挖礦（治理代幣釋出）
- 槓桿倉位
- 跨鏈橋

收益完全來自 Liqwid 供應 APY（三市場混合）與 OptiVaults 對已實現收益收取 4.5% 績效費之間的差額。

### 2.4 手續費結構

- **績效費：4.5%**（`performance_fee_bps = 450`）於每次 Compound 從毛收益中扣取，以 **USDCx**（不是 ADA）於已實現收益回寫到 `total_deposited` 之前先扣除。硬上限 4.5% 由 `vault_gov_policy.ak` 的 `UpdateFee` redeemer（透過共用 `validate_update_fee` helper）強制，治理在任何 redeemer 下都無法超過這個上限。
- **早提領費：0.1%**（`early_withdraw_fee_bps = 10`）只要 keeper 還在活動，每筆直接提領都會收取（keeper 失活 7 天後自動免收）。以 **USDCx** 於提領金額中扣除，費用留在金庫，轉化為 share price 上升回饋給剩餘持有者。硬上限 1%（100 bps）。
- **`min_hold_seconds`（直接提領的閘門，不是資金鎖定）：** 每次 Compound 之後，直接提領會被 `min_hold_seconds` 擋住一段時間才能再送；**排隊提領路徑從頭到尾不受影響**。啟動值為 60 秒；治理可透過 `UpdateFee`（14 天 timelock）調整，validator 強制的硬上限為 **6 小時**（`max_min_hold_seconds = 21_600`）。白皮書審視後從原本的 24 小時上限**收緊**為 6 小時（理由見 §6.3）。週 Compound 週期下，即使治理拉到上限，也只有約 3.6% 的時間直接提領不可用，而排隊路徑完全不受此閘門影響。使用者的資金絕不會被鎖，只是換個路徑，約 5–15 分鐘內完成。
- **SwapAda 營運摩擦：100K TVL 下約 0.02% APY**（詳見 §4.5）。這不是協議層級的手續費——它是鏈上 `SwapAda` redeemer 以 Charli3 + Orcfax oracle 公平價為金庫補充營運 ADA 時，由存入者以 USDCx 承擔的成本。100K TVL 下一年約 10–20 USDCx，反映在 share price 的自然遞減中。雖然不是傳統意義上的「手續費」，但它確實會讓金庫資金流出，所以如實揭露。
- **無存入費用。**
- **無管理費**（無 AUM 費）**。**

**3-way 手續費分拆（V1 新增）：** 每次 Compound 將績效費依 `VaultDatum.keeper_fee_bps` 與 `VaultDatum.gov_fee_bps` 分拆。Keeper 份以 USDCx 直接送至簽名 keeper 的地址；Gov pool 份累積於 MultisigGov UTXO 的 `signer_compensation_pool` 欄位（每季分配，economics.md §7A）；Treasury 份流向 treasury 合約地址。

| Phase | 觸發條件 | Keeper | Gov pool | Treasury |
|-------|---------|--------|----------|----------|
| V1 launch | 部署預設 | 40% | 0%（停用） | 60% |
| Phase 2 | TVL ≥ 500K + 加入外部簽名者 | 40% | 5% | 55% |
| Phase 3 | TVL ≥ 2M + 加入社群簽名者 | 40% | 10% | 50% |

**硬上限：** `keeper_fee_bps ≤ 4000`（40%）、`gov_fee_bps ≤ 1000`（10%）、`keeper + gov ≤ 5000`（treasury 保底 ≥ 50%）。變更需 `UpdateFeeSplit` 動作 + **21 天 timelock**（所有治理動作中最長——因治理調整自身報酬）。40% keeper 上限刻意推高,以支持公共財定位下第三方 keeper 經濟可行性——在 40% 下,Phase 2+ 非創辦人 keeper breakeven 降到 ~$1M TVL(舊 25% 上限是 ~$1.5M)。

**V1 階段三方分拆的誠實揭露。** Keeper / gov pool / treasury 在鏈上為三個獨立流向，各有不同地址、redeemer 授權路徑、timelock 設定。然而 V1 啟動時，這三個流向的**人類控制者明顯重疊**——創辦人同時運作 keeper 並持有治理簽名者席位，而 treasury 支出亦需治理簽名（見 §9.1）。V1 的三方分拆因此是**走向去中心化的結構準備，而非當下已實現的去中心化**。參見 §6.1（Six-identity separation 目標）了解三個口袋達到經濟獨立的輪替路徑。

先前內部驗證版本將 100% 手續費送至單一營運者錢包。V1 將此流程鏈上分離，並採輪替 keeper 模型（§7「Run Now, Open Later」）+ soul-bound Gov Signer NFT（見 `spec/gov-nft.md`）確立聲譽責任制。Gov Signer NFT 的 soul-bound 特性**由其鑄造政策的 spending-script 檢查強制**（並非 Cardano ledger 原生特性）：任何花費帶有 Gov Signer NFT 之 UTXO 的 TX，必須將該 NFT 傳回至支付給簽名者原始 PKH（由 NFT 資產名尾綴導出）的 output，或於同筆 TX 透過 `BurnRotatedOut` 燒毀。第三方轉讓會不通過此 script 檢查而被 ledger 拒絕。該 NFT 不具投票權或財務權利（這些位於 MultisigGov 自身的 datum）；純屬認可。

### 2.5 策略權重敏感度

預設策略配置（45% DJED / 25% USDM / 30% USDCx idle buffer）是啟動位置，不是永久配置。本節記錄治理可以在哪些條件下調整權重，以及調整必須在哪些範圍內。

#### 為什麼啟動是 45% DJED 而不是更高

DJED 目前在 Liqwid 穩定幣市場中提供最高的單市場 APY（約 11.8%）。更高的 DJED 權重會提升加權收益。我們選擇 45% 而不是更高，是因為：

1. **DJED 抵押品是 ADA 計價。** ADA 嚴重下跌（72 小時內 >30%）會降低 DJED 的抵押率，產生脫鉤風險。50% 以上的集中度會在尾部情境產生不可接受的 NAV 波動。
2. **Cardano DEX 上 DJED 兌換的流動性深度有限。** 較大的 DJED 部位在壓力期面臨較高的再平衡滑點。
3. **穩定幣發行者分散很重要。** DJED 是 Coti 發行的演算法穩定幣；USDM 是 Mehen 發行的法幣擔保；USDCx 是 Circle 透過 xReserve 發行。45% DJED 保留發行者多樣性。

#### 調整觸發（治理 7 天 timelock）

下列參數可由治理 multisig 在 7 天 timelock 後調整：

| 參數 | 範圍 | 預設 | 調整觸發條件 |
|------|------|------|--------------|
| DJED 權重 | 30% – 55% | 45% | DJED 抵押率、ADA 波動度、Liqwid DJED 利用率 |
| USDM 權重 | 15% – 35% | 25% | USDM Liqwid 市場深度、USDM 對 peg 穩定度 |
| USDCx 權重 | 0% – 30%（部署） | 0%（idle buffer） | Liqwid USDCx 市場深度、市場 APY |
| Idle buffer 下限 | 10% – 30% | 30% | 提領隊列長度、金庫 TVL 穩定度 |

#### 提高 DJED 權重的條件（朝上限調）

DJED 權重要調高到接近 55%，下列條件**全部成立**才行：

- DJED 系統抵押率 > 500% 持續 30 天
- ADA 30 天歷史波動度 < 60%
- DJED-USDC Cardano DEX 深度 > $5M（為再平衡流動性）
- Liqwid DJED 市場利用率在 40% – 80% 之間（避開兩端極端）

#### 降低 DJED 權重的條件（朝下限調）

下列條件**任一成立**，DJED 權重就自動降到 30%：

- DJED 抵押率 < 300%
- ADA 30 天歷史波動度 > 100%
- Liqwid DJED 市場利用率 > 95% 持續 24+ 小時
- DJED-USDC peg 偏離 > 50 bps 持續 1+ 小時

降低是自動的（Keeper 觸發 + on-chain 驗證），不需要 timelock，因為條件本身就是壓力訊號，需要快速反應。

#### 當前權重的公開揭露

當前策略權重與任何待議調整提案的條件，都發布在 OptiVaults 儀表板。治理權重變更提案會公開記錄理由、預期影響分析、以及任何簽名者提交的少數意見。

### 2.6 Compound 頻率

Compound 的排程頻率由 TVL 決定，並非固定節奏。內部驗證期累積出的營運政策（非合約強制）：

| `total_deposited` 分層 | Compound 排程 | Zero-yield heartbeat |
|-----------------------|---------------|----------------------|
| < 300 USDCx | 延後直到累積收益 > $1 | 每 30 天 |
| 300–750 USDCx | 每月一次 | 每 5 天 |
| 750–1,200 USDCx | 每兩週一次 | 每 5 天 |
| 1,200+ USDCx | **每週六一次**（weekly 檔） | 每 5 天 |

- **週六排程 Compound**：TVL 進入 1,200+ 檔後，每個週六固定執行一次 Compound，統一結算當週收益。
- **Zero-yield Compound**：每 5 天一次的 heartbeat，推進 `last_realloc_time`，即使當下沒有實質收益也會跑，讓 off-chain indexer 能看到金庫仍在活動。
- **Buffer-funded Compound**：當 Liqwid `supplied_value` 自上次 Compound 以來成長時，績效費直接從 buffer 的 USDCx 扣，不需要先 Recall。

**100K 上限是天花板,不是 Phase 1 實際會停在的位置。** §8.2 已經寫清楚:Phase 1 實際 TVL 是 $500–$25K 的區間,sub-scenario (a) 明確涵蓋 V1 在 $500–$5K 運作的情境。上表因此是 keeper 實際使用的**完整** TVL 分層排程——而不是「為了未來 V2 遷移而保留的恢復分支」。每次決定 Compound 節奏時,keeper 會挑「當前 `total_deposited` 對應」的那一檔。對應的低 TVL 營運模式,描述在 §2.6.1。

每一筆 Compound TX 需要 keeper 簽名。Fallback:若 keeper 停擺超過 7 天,治理可用 m-of-n 簽名代替 keeper 執行 Compound。

### 2.6.1 Reference Implementation Mode(低 TVL 營運政策)

當 V1 持續在「§2.6 預設節奏已經不再經濟合理」的 TVL 區間運作時,keeper 切換到 **Reference Implementation Mode**——一套寬鬆的營運政策,只負責維持合約 liveness,不會燒掉相對於累計收益不成比例的鏈上 gas。這個模式是 §0「Cardano DeFi 公共財參考實作」定位,在低 TVL 期間的營運對應:V1 仍以已部署的參考實作姿態完整可用,不會把營運預算耗在收益基礎無法支撐的節奏上。

#### 啟用條件

**同時**滿足兩項才啟用 Reference Implementation Mode:

1. V1 主網 TVL 在 $25K 以下持續 30 天以上,且
2. 過去 4 週、每個 Compound 區間累計的 qToken 收益的平均值,低於該次鏈上 TX 成本的 5 倍(亦即收益無法支撐預設的 Compound 頻率)。

停用條件:TVL 跨過 $25K 並維持 30 天以上,即切回 Default Mode;若 TVL 再次回落,再進入 Reference Implementation Mode。此模式屬於 keeper 在 §4.5 經濟合理性裁量下行使的營運政策——**不需要走** `UpdateStrategy` 治理動作。

#### 模式下的營運調整

| 操作 | §2.6 預設節奏 | Reference Implementation Mode |
|---|---|---|
| Productive Compound | 1,200+ 檔每週六排程 | 累計收益 > $5 USDCx 才執行;$1–5K TVL 下通常一季到一年才一次 |
| Liveness heartbeat | 每 5 天 | 約每 80 天一次(維持在 §5.5.1 Layer 3 CommunitySunset 90 天門檻之下) |
| Rebalance | §2.5 觸發條件成立時 | 配置漂移超過 §2.5 帶寬時才做,不排程 |
| SwapAda | `vault.lovelace < 15 ADA` 時 | 觸發條件相同;部署儀式預先預留的種子 ADA 拉高到 20 ADA 以上,以降低首次呼叫頻率 |
| Discord 營運通知 | 每次 Compound + heartbeat 都發 | 改為季度 + 年度總結;週報停發 |

#### 此模式不會放棄的部分(零妥協)

- 全部合約不變式——不動費率、不繞治理捷徑、不繞 validator。
- 全部存入者保護——`emergency-withdraw`、硬上限、`withdraw-cli`。
- §5.5.1 三層治理安全——Layer 1 freeze-only、Layer 2 swap-out、Layer 3 CommunitySunset 全部正常。
- Share price NAV 準確性——qToken 價值仍按需即時讀取;`total_*` datum 欄位仍在 Compound 時更新如設計。
- §5.4 的 7 天 keeper-inactivity gate——讀的是 `last_compound_time`,不受 heartbeat 節奏放慢影響。

#### 此模式會改變的部分

- **鏈下 indexer 看到的 staleness**:`last_realloc_time` 更新頻率變低,前端儀表板要能容忍這件事——在 Reference Implementation Mode 下,stale 是正常狀態,不是故障訊號。
- **績效費 crystallization 時機**:延後到 withdraw 事件或稀疏的 Compound;累計績效費**金額不變**,只是入帳時機推遲。
- **Treasury 累積速率**:對收益的抽取比例不變,只是轉帳次數變少——Compound 一旦觸發,Treasury 還是會準確累積。

#### 為什麼需要這個模式

$1–5K TVL 下,§2.6 的 weekly Compound 節奏每年大約燒掉 $50–75 keeper gas,但只能 harvest 出 $1–4 績效費。在這個情境用 default 節奏跑,經濟上不合理,也違背 §4.5 明確寫過的「Compound frequency 是上限不是目標」原則。

Reference Implementation Mode 把營運成本降低約 85–90%,同時完整保留所有合約保證——讓 V1 在低 TVL 期間的營運足跡,真正對齊 §0 那個「非商業、公共財」的定位。對於一個此刻其實是在「作為公共參考實作運作」、而不是「作為 yield 產品運作」的存入規模而言,這才是誠實的營運模式。

#### 揭露要求

Keeper 在 OptiVaults 儀表板上公開當前營運模式,包含:目前 active mode(Default / Reference Implementation)、觸發當前模式的條件、進入當前模式以來的時間、下次預計 Compound 的時點與預估收益、下次預計 heartbeat 的時點。存入者可自行用鏈上的 `last_compound_time`、`last_realloc_time`、`total_deposited` 對照儀表板的宣稱,獨立驗證模式是否確實如所宣告。

#### 模式切換機制

TVL 跨過 $25K 且停用條件成立時:

1. Keeper 在儀表板上公告即將切回 Default Mode(對存入者的通知)。
2. 7 天內執行下一次 productive Compound,把累計收益一次性 harvest 完。
3. Heartbeat 節奏恢復為 §2.6 預設(每 5 天)。
4. Rebalance 觸發回歸 §2.5 條件。

切換由 keeper 在 §4.5 裁量下發動。若未來治理認為應該把切換自動化,可以走 `UpdateStrategy` 動作把觸發條件編成規範;v1.3 規格不要求這件事。

---

## 3. 技術架構

### 3.1 智能合約堆疊

V1 部署 **17 個 logic validator**(其中 #17 `vusdcx` 是份額代幣鑄造政策——見下方列表)、**4 個一次性 NFT 鑄造政策**(`vault_nft` / `governance_nft` / `registry_auth_nft` / `gov_signer_nft`)、**1 個 DEX adapter**(`minswap_v2_adapter`),以及 **2 個 SundaeSwap artefact**(`sundaeswap_adapter` + `sundaeswap_cancel_guard`)。合計 17 + 4 + 1 + 2 = **24 個編譯 artefact**:

1. **vault_proxy** — 入口點，透過 Withdraw-Zero pattern 在 10 條路徑（User / KeeperHot / Batcher / SwapAda / Protocol / Recall / Liqwid / GovPolicy / GovEmergency / AdminDeploy）間轉發 spend，見 §3.2
2. **vault_user** — Deposit / Withdraw 專用。**純無許可**——不需要 keeper 授權。
3. **vault_keeper_hot** — Compound / RebalanceBuffer。Keeper 熱路徑；Compound 的 3-way fee split treasury output binding 在這個 validator。
4. **vault_batcher** — BatchProcess 專用。Keeper-authorized staking validator，持有 4 個 fold 迴圈（order_sums / order_owners / vusdcx_leaked / payout_indices）+ OrderDatum / OrderRedeemer decode + `list.unique` + anti-leak invariant。詳見 `spec/order-batch.md`。
5. **vault_swap_ada** — SwapAda 專用。持有 §5.4 P5 的 dual-feed oracle reader + 6-tuple registry read。V1 啟動時處於 inactive 狀態，直到治理在 `asset_oracles` 中加入 ADA 條目；詳見 `spec/ada-swap.md`。
6. **vault_protocol** — DeployToProtocol（SwapAdapter 分派 + 限額 ADA 支出）
7. **vault_recall** — RecallFromProtocol、MergeUtxo
8. **vault_liqwid** — SupplyToLiqwid、RecallFromLiqwid（逐 market 部位追蹤）
9. **vault_gov_policy** — UpdateStrategy / UpdateFee / UpdateFeeSplit / UpdateSlippagePolicy（治理政策類變更；timelock 7d–48h）
10. **vault_gov_emergency** — EmergencyWithdraw 專用（0d timelock）。把快速反應治理路徑限制在一個精簡的 validator 上，未來 SwapAdapter 擴充不會擴大緊急路徑的攻擊面。
11. **vault_admin_deploy** — AdminDeployNonDeposit 專用。處理治理的非存入代幣回收路徑（7d keeper-inactive + 21d registry-stable 閘門）。持有 SwapAdapter 分派 + destination-whitelist 檢查 + 6-tuple registry read。
12. **keeper_stake_script** — 可插拔 keeper 授權（V1 啟動為 GovernanceOnly；Phase 3+ 保留 PermissionlessWithBond 模式）
13. **treasury** — 保管非 keeper 份手續費，4 類別預算（audit reserve / ops / R&D / buffer）
14. **multisig_gov** — m-of-n 治理狀態機 + timelock + 1-of-n cancel + 簽名者補償池
15. **registry** — 穩定幣白名單、協議地址白名單、Liqwid market 目錄、`asset_oracles`、`swap_adapter_hashes`
16. **order** — 使用者 deposit / withdraw 訂單佇列 validator
17. **vusdcx** — 份額代幣鑄造政策

另外還有 4 個 mint-only 一次性 NFT 政策：

- `vault_nft` — 一次性 Vault Identity NFT（PlutusV3 UTXO-ref 一次性鑄造，詳見 `spec/vault-nft.md`）
- `governance_nft` — 一次性 Governance NFT（鎖在唯一的 MultisigGov UTXO 中）
- `registry_auth_nft` — 一次性 Registry auth NFT（鎖在唯一的 Registry UTXO 中）
- `gov_signer_nft` — 給治理簽名者的榮譽型 soul-bound NFT，鑄造 / 燒毀都必須同一筆 TX 消費 MultisigGov UTXO。不附帶任何投票權或財務權利。詳見 `spec/gov-nft.md`。

以及 3 個 swap-adapter artefact：

- `minswap_v2_adapter` — SwapAdapter 介面實作（見 `spec/swap-adapter.md`）。以治理錨點為編譯期參數（唯一目的是啟用 A2 `publish` handler 以回收 stake 押金，見 §5.1 + §6.2 `ActDeregisterStake`）；adapter hash 是 Registry `swap_adapter_hashes` 白名單的唯一識別。
- `sundaeswap_adapter` — V1 的第二個 SwapAdapter,對應 SundaeSwap V3 + Stableswaps,在部署儀式 init 時綁定（見 `spec/swap-adapter.md §8`）。
- `sundaeswap_cancel_guard` — 一個小型 staking validator,讓尚未成交的 SundaeSwap order 取消時是 drain-proof 的(整筆 order 價值必須送回金庫地址)。

**合計編譯 artefact：17 logic validator + 4 NFT mint policy + `minswap_v2_adapter` + 2 個 SundaeSwap artefact = 24**。

**第二個 DEX adapter——SundaeSwap。** V1 的第二個 SwapAdapter 對應 SundaeSwap V3 + Stableswaps:`sundaeswap_adapter`（adapter 本身）加上 `sundaeswap_cancel_guard`（一個小型 staking validator,讓尚未成交的 SundaeSwap order 取消時是 drain-proof 的——整筆 order 價值必須送回金庫地址）。這一對在**部署儀式 init 時綁定**:部署儀式的設定檔帶 `sundaeswap` 區塊,這兩個 artefact 折進 hash DAG、發佈為 reference script、種入 Registry 白名單。SundaeSwap 在 V1 中擔任 USDM leg——它的 `USDCx/USDM` stableswap pool 提供更低的同質資產滑點——外加一個萬一 Minswap V2 batcher 停擺時的 liveness 後援;DJED leg 留在 Minswap V2。因此 SundaeSwap 是每一次 V1 launch 部署的一部分,本白皮書其他段落引用的 ceremony 成本數字（~962 ADA reference-script 鎖定、20 個 reference script、~42 筆 ceremony TX）都已將它計入。見 `spec/swap-adapter.md §8`。

**拓撲設計理由。** 24 個 artefact 是沿著四個正交切割面分割（partition）的結果（authorization-boundary、governance response-latency、bytecode-cost-center、size-fix），主要由 Plutus V3 16 KB reference-script ceiling 推動，並非任意細分。工程理由與拆分後 size 列在 `spec/architecture.md §4.1`；本白皮書不列舉逐次 commit 的時序歷史，因為對 depositor 決策無實質意義。

詳細 redeemer 見 `spec/architecture.md`，VaultDatum schema（§5.4 Phase 2 + Phase 1 治理安全 dead-man-switch 後為 29 欄位）見 `spec/vault-datum.md`。

### 3.2 Withdraw-Zero Forwarding Pattern

Cardano Plutus V3 對 validator reference script 大小有 16 KB 限制。V1 的金庫邏輯超過此限。解法：將金庫邏輯拆分至多個 staking validators（`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`），用 `vault_proxy` 作為 spend-path 轉發器。

**流程：**
1. Spend 金庫 UTXO 觸發 `vault_proxy`
2. `vault_proxy` 依照自己的 `ProxyRedeemer`（`UseUser` / `UseKeeperHot` / `UseBatcher` / `UseSwapAda` / `UseProtocol` / `UseRecall` / `UseLiqwid` / `UseGovPolicy` / `UseGovEmergency` / `UseAdminDeploy`）選中對應的 staking script，要求 TX 含該 script 的零額度 withdrawal
3. Staking withdrawal 觸發實際的 validator（含完整 redeemer 邏輯）
4. Staking validator 回傳成功 → proxy 允許 spend

此 pattern 代表每次金庫 spend 實際上是兩次 validator 呼叫：proxy（輕量，~4.9 KB）+ 十個 staking validator 的其中一個（重，每個最多 16 KB）。`vault_proxy` 內部的 `withdrawal_count` invariant 強制每筆 TX 只能觸發一個 staking validator，避免 double-routing。

### 3.3 編譯期信任錨

V1 大量使用編譯期參數，把信任在部署當下就錨定住。寫進 validator hash 的欄位包括：

- **Vault NFT policy**——讓 `vault_proxy` / `vusdcx` / `order` 共用同一個身份錨
- **治理 NFT policy + name**——寫進 `multisig_gov` / `keeper_stake_script` / `vault_gov_policy` / `vault_gov_emergency` / `vault_admin_deploy` / `vault_protocol` / `vault_recall` / `vault_liqwid` / `vault_user` / `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada` / `minswap_v2_adapter`;每個治理閘門的 validator（以及每個 staking validator 的 A2 `publish` 處理器,詳見 §6.2 `ActDeregisterStake`）都靠它驗證真正的 gov UTXO 有被消費
- **Keeper stake-script hash**——寫進 `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada` / `vault_protocol` / `vault_recall` / `vault_liqwid`;keeper 授權委託給 `keeper_stake_script`(詳見 `spec/keeper-auth.md`),因此授權的 PKH 集合可以改變而不必重新部署金庫。注意：post-Phase-77d `vault_user` **不**再帶此錨點——它已變成純無許可路徑（Deposit + Withdraw 只需使用者簽名）。
- **Staking validator hashes**——`user_stake_hash` / `keeper_hot_stake_hash` / `batcher_stake_hash` / `swap_ada_stake_hash` / `protocol_stake_hash` / `recall_stake_hash` / `liqwid_stake_hash` / `gov_policy_stake_hash` / `gov_emergency_stake_hash` / `admin_deploy_stake_hash` 寫進 `vault_proxy`，提供 Withdraw-Zero **十**條分派路徑
- **Treasury script hash**——寫進 `vault_keeper_hot`（Compound 手續費導向）與 `multisig_gov`（DistributeSignerCompensation 的 forfeit 導向）
- **存入代幣 policy + name**——寫進 `treasury` 與 `multisig_gov`
- **vUSDCx 鑄造政策**——以 `vault_hash` + `vault_nft_policy` 為參數部署

要更動任何一個錨，必須全新部署（新的 validator hash、新的金庫地址、使用者遷移）。這是對抗「phantom vault」類攻擊的結構性防線（此類攻擊於內部驗證期被發現並修復）。

**Vault Identity NFT 設計 — PlutusV3 UTXO-ref 一次性鑄造。** V1 的 Vault Identity NFT 鑄造政策為 **PlutusV3 validator**，以特定 UTXO reference 作為編譯期參數，**非** Cardano native script。鑄造分支要求該 UTXO 必須於交易 inputs 中（被消耗的 UTXO 無法重播 → 密碼學一次性保證）；燒毀分支無條件通過（burn 隨時可執行，支援 vault 潔淨 sunset）。此設計取代內部驗證階段部署使用的 `{all: [sig, before(slot)]}` native-script 模式——該模式為信任導向（依賴 keeper 不會重複鑄造）且在 burn 路徑存在 deadline 陷阱（一旦 `before` slot 過期，burn 變不可能，永久鎖死金庫 min-ADA ≈ 每個 vault 部署 15–20 ADA）。PlutusV3 模式在兩個軸向嚴格優於 native script，代價為 script size 略增。完整規格：`spec/vault-nft.md`。

### 3.4 外部依賴

| 依賴 | 用途 | 信任委託 | Fallback |
|------|------|----------|----------|
| Liqwid Finance | 貨幣市場收益 | qToken 匯率正確、無壞帳 | EmergencyWithdraw + KeeperToggleMarket |
| Minswap V2 | DEX swap | Batcher 執行、fill 定價 | Order Cancel/Expire 退款 |
| USDCx 發行方（Circle 透過 xReserve） | 1:1 USDC 擔保 + 跨鏈儲備完整性 | 穩定 $1 錨 | Depeg 監控 + 手動停機 |
| Charli3 + Orcfax oracles | `SwapAda` 補充機制所需的 ADA/USD 價格 + P4 Tier 1 oracle-based fair-price 邊界 | 價格公平性與新鮮度——透過共用 `lib/vault/oracle.ak` 以 dual-feed（2 個 healthy sample 必須在 2% 分歧窗口內、個別新鮮度上限 10 分鐘）聚合中位數回傳（§5.4 P5 已完成），oracle 設定位於 Registry 的 `asset_oracles`，由 governance `UpdateRegistry`（14 天 timelock）管理 | 治理 `UpdateOracleSource`（14 天 timelock）可切換資料源；V1 launch 時 `asset_oracles = []`，SwapAda 在 governance 啟用 ADA 條目前不運作 |
| Blockfrost / Ogmios | keeper 與 API 使用的鏈上索引 | UTXO 狀態正確 | 多源備援、以鏈上為準 |

### 3.5 兩層程式碼結構

V1 的原始碼**拆在兩個獨立的公開 repo**,各自有自己的審計範圍、釋出週期、安全通報管道:

| 層 | Repository | 裡面放什麼 | Fee | Fork 意涵 |
|----|-----------|----------|-----|---------|
| **協議層** | [`optivaults-protocol`](https://github.com/OptiVaults/optivaults-protocol) | Aiken validators、spec、whitepaper、部署流程 | **零 fee**——任何人 fork 並啟動自己的 vault 實例,**完全不用付 OptiVaults** | fork 協議層 = 產出全新、獨立的 vault |
| **Operator 層** | [`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference) | TypeScript keeper、API server、frontend、CLI 工具(self-serve Withdraw / Emergency) | OptiVaults 在 `optivaults.app` 代跑的實例收已實現收益的 4.5% | 歡迎 fork;fork 者自訂費率(或零)、自己跑自己的基礎設施 |

**4.5% 績效費是 operator 實例的屬性,不是協議本身的屬性**。若團隊 fork `optivaults-protocol` 並部署自己的 vault——用自己的 keeper 錢包跑自己的 `optivaults-reference` fork,或用完全重寫的 keeper——**他們對 OptiVaults 沒有任何欠款**。合約層強制的 4.5% 硬上限適用於「某一個 vault 實例的存入者該付多少績效費」,只約束該 vault 治理所能設的值,**不約束 fork 運營者對他們自己存入者收多少**。

**安全通報 routing**:協議層發現(Aiken validator bug、datum injection、鏈上不變量違反)走 `optivaults-protocol/SECURITY.md`。Operator 層發現(keeper runtime、API 驗證、frontend XSS、CLI 解析)走 `optivaults-reference/SECURITY.md`。不確定時預設走協議層,分流時會轉派。

**審計範圍對應層分離**。Q2-Q3 2027 的外部審計明確針對協議層(見 §8.1 與 `docs/audit-scope.md`)。Operator 層有自己獨立的審計時程;其信任屬性較窄,因為失敗模式受鏈上協議不變量的約束(被入侵的 keeper 可以造成運營 DoS,但**無法抽走本金**)。

---

## 4. 經濟模型

### 4.1 啟動經濟

在 100K USDCx TVL + ~5-6% 淨收益下（`docs/economics.md §6.2` current-reference 情境；buffer=0% 計算於 2026-Q2 Liqwid 利率下為 ~6.36% 淨，區間下限涵蓋利率壓縮）：

| 指標 | 數值 |
|------|------|
| 年度毛收益（保守 5%） | $5,000 |
| 年度毛收益（樂觀 8%） | $8,000 |
| 績效費（4.5% 毛收益） | $225-360 |
| Keeper 份（V1 啟動 40%） | $90-144 |
| Gov pool（啟動 0%,Phase 2+ 啟用） | $0 |
| Treasury 份（V1 啟動 60%） | $135-216 |
| 營運成本（keeper + 基礎設施 + 審計儲備） | $360-2,400 |

**現實：100K TVL 下協議收益不足以覆蓋營運成本。**

V1 處於**啟動期(bootstrapping phase)**,直到 TVL 達到自給規模。自給範圍約 **$135K–$1.8M**,涵蓋樂觀 / 基準 / 保守三個情境,baseline 約 $500K。低於該門檻時,初期虧損由專案的啟動資金(founding capital)承擔,這是新 DeFi 協議啟動的正常狀態。達到門檻後,OptiVaults 自身營收可覆蓋基礎營運,更高 TVL 則逐步充實審計儲備、研發、緩衝類別。

**Phase 1 期望重設**(對存入者預先說清楚)。**$135K–$1.8M 自給區間(baseline 約 $500K)** 依其構造是 §2.6 預設節奏下的 **Phase 2+ post-audit reference milestone**，在 pre-audit 100K USDCx 上限下無法到達。我們對 Phase 1（pre-audit、100K cap 下）TVL 的內部估算是頭 6-12 個月落在 **$500–$25K** 區間，基於保守的使用者取得假設加上 permissionless-only 立場（沒有 closed-beta gate、沒有 invitation list，實際 TVL 完全取決於 organic discovery）。這是推測性區間而非預測，我們公開標示是為了誠實揭露模型假設，不是在做承諾。100K 上限是**風險包絡，不是銷售目標**。在 §4.3.1 volunteer-operator 模型下，Phase 1 的營運缺口（協議收入 < 營運成本）由創辦人從個人收入持續補貼吸收（年化 ~$80–$200），**不是**從一筆預先撥定、規模涵蓋審計預算的啟動資金 runway 中扣除。完整資金姿態見 §0.2 + §4.3.1；完整「Phase 1 即協議驗證」framing 見 §8.2。

**自給 TVL 門檻會隨情境怎麼變動**(取決於 Liqwid 供應 APY 與營運成本)。§4.1 的 **$135K–$1.8M 區間**涵蓋下列樂觀 / 基準 / 保守三情境,並同時呈現 §2.6 預設節奏與 §2.6.1 Reference Implementation Mode 下的數字;baseline 自給門檻約 $500K:

| 情境 | Liqwid APY | 年度營運成本(Default) | 自給 TVL 門檻(Default) | 年度營運成本(Reference Implementation Mode) | 自給 TVL 門檻(Reference) |
|------|------------|------------------------|-------------------------|---------------------------------------------|--------------------------|
| 樂觀 | 10%(借貸需求強勁) | $600(低端) | ~$135K | $80 | ~$18K |
| 基準 | 6%(近期 Liqwid 水準) | $1,200 | ~$500K | $150 | ~$56K |
| 保守 | 3%(借貸需求衰退) | $2,400(高端含審計儲備擴張) | ~$1.8M | $250 | ~$185K |

公式：`自給 TVL ≈ 年營運成本 / (毛 APY × 績效費率 0.045)`。保守-Default 情境下，從外部審計通過到 TVL 爬坡達到自給門檻，可能需要 **3-5 年**（post-audit cap 放寬 + 多次行銷週期 + Cardano DeFi 整體 TVL 成長）。**在 §4.3.1 volunteer-operator 模型下，V1 並不需要達到自給才能繼續運作**——營運成本由創辦人以個人收入持續吸收年化 ~$80–$200（§4.3.1 cost-scaling 表）。上表中的門檻因此是**一個「沒有補貼」假設下的參考里程碑**，不是 V1 必須達到才不致關停的財務生存目標。真正的 sunset 觸發條件是 §1.5 Class A overrides 或創辦人明確決定（§4.1 Triggers A–D + §9.2），而不是啟動資金 runway 耗盡。這個說法對存入者有實質意義：V1 永遠停在 $25K TVL 完全可以接受；真正會結束 V1 的是外部基礎設施失敗或創辦人主動 sunset，這兩件事都不以 TVL 為觸發條件。

**Reference Implementation Mode 那一欄怎麼解讀。** 在 §2.6.1 節奏 + 基準假設下,V1 的自給 TVL 從 $500K 降到約 $56K——大約 9× 的下降。這讓 V1 的經濟性在更小規模下也能成立,正好對應 §8.2 (b)「小規模有機成長」sub-scenario 的營運輪廓。這不是天上掉下來的好處——只是反映了一個營運現實:低 TVL 金庫不該用 $100K+ 金庫的節奏跑。Reference Implementation Mode 做的事,是把成本基礎拉到與真實收益基礎匹配。Default 與 Reference 兩欄並不是 keeper 可以為了好看任意挑選的;模式由 §2.6.1 的啟用 / 停用條件決定,並在儀表板上公開追蹤。

**Reference 下的 $56K 自給門檻**不會改變下方的 sunset 觸發條件。** 下方寫的 sunset 條件——「post-audit 6 個月內 TVL < $500K」——是**外部審計後、回到 §2.6 預設節奏下**的門檻,衡量 V1 上線後在 default cadence 下的成長輪廓。$56K 是**pre-audit、低 TVL 期間**走 §2.6.1 才成立的數字,**不會**降低 post-audit 的成長標準。v1.3 把兩個數字放在同一張表是為了透明,但它們描述兩個完全不同的營運階段,不能互換。把兩者混為一談的讀者會誤以為「V1 一路到 Phase 2 都能在 $56K 自給」——一旦 §2.6 預設節奏恢復,這個結論就不成立。

**$25K–$500K 之間的 gap（跑 Default、不算自給，但在 volunteer 模型下完全可以接受）。** 在 §2.6.1 的停用門檻（$25K——keeper 離開 Reference Implementation Mode）與假設「沒有補貼」下的自給門檻（~$500K）之間，V1 在 §2.6 預設節奏下運作，**單靠協議收入確實覆蓋不了營運成本**。具體計算：TVL $50K × 6% 毛收益 × 4.5% 績效費 = 一年 $135 協議收入，對上 §4.3.1 在 $25K-$100K TVL band 的年化營運成本 $200-$500，等於每年 ~$0-$200 的差額——由創辦人從個人收入吸收（§4.3.1 cost-scaling 表）。**這不是 sunset 觸發條件。** 在 volunteer-operator 模型下，這個缺口在結構上可永續存在——它不會逐月蠶食一筆有限的 runway。§8.2 sub-scenario (c)「$25K–$100K 接近 cap」坐在這個 gap 裡；sub-scenario (b)「$5K–$25K」則停留在 Reference Implementation Mode，年化營運成本 ~$80。真正會結束 V1 的是 §1.5 Class A overrides 或創辦人明確決定（§4.1 Triggers A–D），不是 TVL 卡在這段 gap。

**啟動資金承諾刻意維持最小化——僅涵蓋營運，不涵蓋審計。** 創辦人對 V1 的啟動資金承諾僅涵蓋**營運 + 最小化預備金，不負擔外部審計的自掏資金**。具體承諾範圍：(a) ~$2K USDCx 作為 Phase 1 working capital seed、(b) 18 個月 pre-audit 窗口內 ~$200–$500 USD 基礎設施（採 §2.6.1 Reference Implementation Mode + §4.3.1 minimal-operations 配置）、(c) 隨 TVL 變動約 $80–$200/年的小額營運補貼（見 §4.3.1 cost-scaling 表）由創辦人從個人收入吸收、(d) 一筆 audit-funding **gap-fill 上限約 $15K**，用於 bridging §8.1 資金堆疊與最終審計報價之間的微額短缺（**不**用於 underwriting 完整審計成本）。

**審計完全由外部資金支應。** 外部審計（依委託模型 $50–$150K，見 §8.1）僅由外部來源資助（Project Catalyst、Cardano Foundation、Intersect Member Committee、Aiken Foundation、audit firm 公共財折扣、社群 / DAO 資助池）。創辦人承諾上限 ~$15K 個人 gap-fill（即上述 (d)），用於彌補微額短缺，但**明確不承諾在任何情境下 underwriting 完整審計成本**。若資金堆疊表現低於 gap-fill 容量，V1 不會進入 mainnet——見 §8.1 Options A–D 的 contingency tree（時程延後 / 縮減 scope 審計 / 社群 crowdfund / 永久停留於 Preprod 的 Apache 2.0 狀態）。

**Volunteer + cap-lift-by-audit 模型下的 sunset 語意。** §4.1 的標稱 sunset 條件（"runway < 6 個月 forward burn"）將「runway」解釋為**創辦人的營運面承諾**，而非審計承諾。在 ~$80–$200/年的最小化營運燒率下，營運 runway **結構性可永續**——幾百美元能撐數年；由個人收入持續支撐在現實上完全可行。**審計資金結果不是 sunset 觸發條件。** 審計資金決定 cap 是否解鎖到 100K 以上（依 §8.1 Options A–D）；不決定 V1 是否繼續運作。V1 真實的 sunset 觸發條件是 §1.5 Class A overrides（USDCx 事件、Liqwid 事件、Cardano chain halt、oracle 異常持續），或創辦人在 §9.2 下的明確 sunset 決定。**營運 runway sunset 在 §4.3.1 minimal-cost 模型下實際上不可達**。§8.1 Option D（「永久 pre-audit 100K cap」）是審計資金持續未到位的正確 framing——V1 在 mainnet 100K 繼續運作，不是 sunset。

**Sunset 觸發條件與機制**（§9.2 + economics.md §7.2）。在 volunteer-builder + β cap-lift-by-audit 模型下，V1 有 **4 條獨立的 sunset 觸發條件**；任一觸發時，下方的有序 sunset 協議啟動：

- **Trigger A — Post-audit 成長失敗（前提是審計發生）：** 外部審計完成後 **6 個月內 TVL 未達 $500K**。此 trigger 僅適用於 post-audit 世界 — Stage 3 cap lift 已發生但 TVL 未跟上。若審計始終未到位（§8.1 Option D），此 trigger 永遠不會 fire；V1 只是無限期維持在 pre-audit 100K cap。
- **Trigger B — 營運 runway 耗盡：** 創辦人營運面 runway 降至 6 個月以下前向支出。在 §4.3.1 minimal-operations 政策下（年化 ~$80–$200，由個人收入吸收），此 trigger **結構性多年不可達**；保留作為正式 trigger 只是為了防止未來營運者單方面膨脹營運成本後悄悄破壞框架。
- **Trigger C — Class A override 持續：** 任一 §1.5 Class A override 條件（Liqwid / USDCx / Cardano chain halt / oracle 異常）持續超過 remediation 期限 — 通常持續性事件採 30+ 天門檻，鏈中斷或 USDCx 失能採立即觸發。Sunset 協議將外部基礎設施失敗吸納為受控退場，而非被動衰退。
- **Trigger D — 創辦人明確 sunset 決定：** 創辦人依 §9.2 明確啟動 sunset 協議（例如：醫療失能超過 §9.2 中期失能 fallback、個人生活不可抗力、決定停止維護）。

**審計資金失敗不是 sunset 觸發條件。** 持續的審計資金缺口（§8.1 Option D）讓 V1 在 mainnet pre-audit Phase 2 維持 100K cap；它不啟動 sunset 協議。下方的 sunset 協議適用於上述四個 triggers A–D：

1. **90 天存入者預告期**（從原 30 天延長——配合 DeFi 遷移實際需要）。預告發布於鏈上 `governance.QueuedAction` + 鏈下網站橫幅 + Discord + 既有使用者管道。
2. **預告期啟動前的前置條件**（3 項全部完成後,90 天時鐘才啟動）:
   - 所有 Liqwid qToken 部位完整 recall 為 USDCx
   - 所有在途 Minswap V2 訂單 cancel 或過期
   - 治理 queue `UpdateFee` 將 `performance_fee_bps → 0`(「sunset 期間 fee 歸零承諾」)
3. **90 天窗口期間：** 不接受新存入（frontend gate + keeper 拒絕 BatchProcess deposit orders）、withdraw 完全開放、0% 績效費、keeper 持續送 zero-yield Compound heartbeat 保持 7 天 inactivity guard 有效。
4. **90 天後：** 剩餘 < dust 門檻的部位可透過治理 `EmergencyWithdraw` 合併；ref-script 資本透過 `deploy/tools/reclaim-refs.ts`（隨 V1 實作一併發佈）回收。

**Sunset 觸發時的啟動資金保留下限。** Sunset protocol 觸發時，啟動實體承諾於啟動資本中保留至少 **~150 ADA**（約 $75-100 USD，依當下 ADA 市價）專款，覆蓋 sunset 的 90 天結算窗口所需鏈上費用：(a) 90 天 keeper 營運週期（zero-yield heartbeat 每 5 天 + 週六排程 Compound + Liqwid market 監控）≈ 60-80 ADA；(b) 1× Liqwid full recall 跨 3 個 market ≈ 6 ADA；(c) Minswap V2 router gas 為 stable → USDCx 轉換 ≈ 6 ADA；(d) Conway 期 ref-script fee 附加費(~1.2 ADA × 40 TX)≈ 48 ADA；(e) 20% 安全緩衝。此 150 ADA 保留與「fee=0% 承諾」共同形成 sunset 期間的操作性保證。即使主要啟動資金已耗盡（sunset 觸發條件本身之一），sunset 的 90 天結算仍有獨立資金覆蓋，存入者不會因營運方資金見底而陷入「提領 TX 送不出去」的絕境。

90 天預告期 + fee 歸零 + 前置清理是一個強存入者承諾——任何持倉人有 ≥ 3 個月不付績效費退出的窗口，並保證 vault state 在時鐘啟動前已處於 withdraw-ready 狀態。這刻意比天真的 30 天預告寬裕：V1 是 pre-audit 產品，sunset 期間存入者遷移摩擦是我們最想最小化的損失。

詳細計算與 TVL 分層預測見 `docs/economics.md`。

### 4.2 Treasury 模型

Treasury 在 V1 啟動時累積 60% 的績效費（3-way 拆分:keeper 40% / gov pool 0%(關閉) / treasury 60%；後續 phase 啟用對照表見 §2.4），資產以 **USDCx** 計價。啟動時的類別分配：

- **審計儲備 40% 進帳分配**——用於資助未來審計與未來安全研究者計畫（V1 上線採用「責任揭露政策 + ex gratia 認可框架」，而非固定結構化 bounty tier，詳見 `docs/audit-scope.md §6`；結構化 bounty 計畫啟用前提於 §6.3 說明）。審計比例從歷史的 30% 上調至 40%，是為了在較小的 60% treasury 份額下，仍維持「總 fee 的 24% 進審計儲備」這個累積速度（60% × 40% = 24%，與舊 80% × 30% 同）。有兩條獨立的治理硬下限保護：
  - **進帳比例下限**：`audit_bps ≥ 2000`（每次 Compound 的手續費流入必須有 20% 進審計類別）——由 `treasury.ak` 在 `UpdateParams` 時強制；治理無法把審計的進帳比例調降到 20% 以下。
  - **餘額下限**：`audit_reserve_balance ≥ min_audit_reserve`——`min_audit_reserve` 是部署當下設定的**不可變** datum 欄位（V1 啟動值為 0，也就是一開始沒有約束力）。若未來的 `UpdateParams` 把 floor 拉高，就不可再調低。任何治理動作都不能把餘額花到低於當前的 `min_audit_reserve`。
- **營運 25%**——平台層基礎設施（前端 / landing / API 的主機、Blockfrost 平台查詢、監控、網域、CDN）。**個別 keeper 的基礎設施成本**（單一 keeper 的基礎設施、Blockfrost key、監控）改由每筆 Compound 的 40% keeper 份額直接吸收，不再從此 bucket 出——這也是 ops 從舊 40% 縮成 25% 的結構性原因。
- **研發 25%**——V2+ 開發、新整合、貢獻者 bounty（post-audit + TVL-scale）。
- **緩衝 10%**——應付突發狀況的自由儲備。

40 / 25 / 25 / 10 這個分配是**每一類內部可軟調整**的——治理可透過 `UpdateTreasuryParams`（14 天 timelock + 180 天冷卻期，每類別範圍落在 [審計下限 20%, 上限 50%]）調整進帳比例。實際的支出則走 `TreasurySpend`（7 天 timelock），每類別還有「每月上限」與「24 小時冷卻」兩道閥。

唯一有硬下限的是審計儲備（進帳比例 20% + 餘額不可變下限）。營運 / 研發 / 緩衝三者的進帳比例上下界在 [0%, 50%] 之間，但餘額無下限。

**USDCx → USD 的 off-ramp。** 營運成本（基礎設施、Blockfrost 訂閱、域名續約、承包商費用）多半以 USD 或 EUR 結算。Treasury USDCx 視需求轉成美元，管道有三種：(a) 透過機構帳戶進行 Circle USDC 贖回；(b) 走 Minswap → Wrapped USDC → Coinbase/Kraken 的 CEX off-ramp；(c) 啟動實體先以 USD 墊付，事後用 USDCx 償還。三條路徑都有各自的 KYC、最小金額與處理時間摩擦；啟動實體的 treasury-operations runbook 記錄當下採行的程序。Treasury 的類別帳目仍以 USDCx 計價；實際支出當下的匯率會登錄在 treasury-operations 帳簿。

Treasury 的每筆支出都要經過 `TreasurySpend` 治理動作加 7 天 timelock。

### 4.3 Keeper 經濟

V1 啟動時由創辦人擔任 keeper。在 100K TVL 下，對其他營運者而言是賠本生意：

- 100K 下 keeper 份額 = ~$108/年（在 6% reference APY × 4.5% × 40% keeper 份額下；見 `docs/economics.md` §2）
- Keeper 基礎設施 + 監控成本 = $400–1,000/年
- **淨虧損：$292–892/年**（非創辦人 keeper）

**在實際的 Phase 1 TVL 區間**（§8.2 講的 **$500–$25K**，不是 100K 上限）下，keeper 份額的數學會更不利——一整年 keeper share 大概還不到 $30。所以 Phase 1 的 founder-keeper 安排是**由創辦人個人收入補貼支撐的 volunteer-operator 設計，不是商業平衡點**。Phase 1 的 keeper 運作本來就是個明確的支出項，每年從創辦人 §4.3.1 minimal-operations 補貼中拿走 ~$30–$75；它並未被 framed 為「啟動 TVL 下能自給」，也不會逐月耗盡一筆預先撥定的啟動資金儲備。

**什麼時候開放 keeper 註冊才合理：** 要等到 TVL 達約 $2.5–5M（pessimistic 1–2% APY 假設下），keeper 份額才達到 $600–1,200/年，接近低成本營運者的損益平衡點。V1 的 `keeper_stake_script` 已經支援 `PermissionlessWithBond` 模式，但啟動時**暫時停用**（`RegistrationMode = GovernanceOnly`）。要啟用需要兩件事：治理執行 `UpdateKeeperAuth` 動作，以及老實說——TVL 真的成長到讓開放有經濟意義為止。這是 Phase 3+ 的事，不是 Phase 1 / Phase 2 要處理的。

**三層自給 threshold —— 誠實拆解。** V1 其實有三個獨立的 self-sustainability threshold，不是單一數字；不同的 APY 假設下彼此差距達一個數量級。Keeper 份額每年 = `TVL × 毛 APY × 0.018`（V1 啟動 keeper 份額 40% × 績效費 4.5%）。

| 層級 | 覆蓋範圍 | 年度成本 | 6% current APY 的損益平衡 TVL | 2% pessimistic APY 的損益平衡 TVL |
|------|---------|--------:|---------------------------:|------------------------------:|
| (a) Founder-keeper 邊際運作 | Bootstrapping 階段；創辦人吸收自己的時間成本並共用現有 infra | $100–$300 | $93K – $278K | $278K – $833K |
| (b) Non-founder 專業 keeper | 獨立營運者、獨立伺服器 + monitoring | $400–$800 | $370K – $740K | $1.11M – $2.22M |
| (c) 機構級 ops + 審計儲備累積 | 含未來每 18–24 個月一次 $30–50K 審計成本預提的完整協議自給 | $1,500–$3,000 ops + 攤提審計 | $20M+ | $50M+ |

本節前述的 $2.5–5M 數字對應 **pessimistic 1–2% APY** 下的 tier (b)（keeper 份額 = TVL × APY × 0.018）。在 current reference 6% APY 條件下，tier (b) 在 $370K–$740K 就成立。開頭幾段用保守數字是刻意的——V1 必須在 Liqwid 利率被壓縮的壞情境下仍能維持 keeper 運作，不只是 current reference 情境下 viable 即可。注意：tier (c) 的 breakeven **由審計儲備累積主導**（audit 攤提需 $15–33K/年,ops 只需 $1.5–3K/年），而審計儲備的累積軌跡在 E2 下與舊版完全相同（60% × 40% = 24% 總 fee，與舊 80% × 30% 一致）——所以 tier (c) 的 $20M+ / $50M+ 不論 keeper 份額是 20% 或 40% 都不變。

**三維度 self-sustain 區分（讀表前先理解）。** 上表的 tier (a)/(b)/(c) 計算基於「keeper share 覆蓋 keeper ops cost」breakeven，這是 protocol 自給**三個不同維度中的第一維**：

- **(i) Keeper ops 自給**——keeper 份額(40% of 4.5% perf fee)≥ keeper 個人 infra 成本。**上表的 tier (a)/(b) 對應此維度**。Keeper 份額由歷史的 **25% 上限**提高到 40%,讓 Phase 2+ 非創辦人 keeper breakeven 降到 **~$1M TVL**(原本 25% 時為 ~$1.5M;算式:25%/40% = 0.625,$1.5M × 0.625 ≈ $0.94M ≈ $1M)。
- **(ii) Treasury ops 自給**——treasury 60% 份額覆蓋 basic ops（$360/yr）+ R&D（$432/yr）+ 運營 buffer。tier (b) 的 TVL（$740K–$1.48M）產生 treasury 份額約 $1,620–$3,240/yr，在較小的 treasury 比例下**仍 comfortably 覆蓋**第二維,因為 keeper 份額已直接吸收 per-keeper infra 成本。
- **(iii) Audit-reserve self-funding**——每年 audit reserve 分配(E2 下 40/25/25/10 sub-allocation 的 40% × treasury 60% = 總 fee 的 24%,與舊 80%×30% = 24% 累積速度相同)累積可 cover 下一輪 audit 成本($30–50K,每 18–24 個月一次)。此維度仍需 TVL **$20M+**,對應 tier (c)。20%→40% keeper 的轉變**不**改變 audit-reserve trajectory。

所以讀 tier 表時要注意：**tier (a)/(b) 的 breakeven 是「keeper 不虧」，treasury ops 在同一 TVL 自動 comfortably 覆蓋；但 audit reserve accrual 不夠，靠 §8.1 四源 funding stack 而非 protocol-revenue**。這是刻意設計，不是 gap。

**V1 實際的 self-sustain target 是 tier (a)/(b)，不是 tier (c)。** Tier (c) 由 §8.1 funding stack（grants + 審計 firm 公共財折扣 + 透過內部審計歷史的 scope reduction + 受封頂的創辦人 gap-fill，見 §8.1 (d) — §0.2 解釋為何創辦人不是審計 underwriter 的 volunteer-builder framing）覆蓋，不靠協議自身 treasury 累積。這與 V1 的非商業公共財定位一致——V1 不需要成長到 $20M+ TVL 才算「完全自給」。若 Phase 1 + post-audit 的成長 trajectory 在 2027–2028 年達到 tier (a)/(b)（$500K–$1M TVL），V1 就是以自己的 criterion 成功了。若成長停滯在 tier (a) 以下，§9.2 sunset protocol 啟動。

詳細規格見 `spec/keeper-auth.md` 的 RegistrationMode 狀態機。

### 4.3.1 Post-launch minimal-operations 政策

V1 將兩個常被混淆的永續性問題清楚分開：

1. **審計資金**（一次性、外部、約 $50–$150K）— 解決「V1 能否上 mainnet？」— 見 §0.2 / §8.1；創辦人**不是** underwriter。
2. **營運 runway**（長期、創辦人承擔、依 TVL 約 $80–$200/年）— 解決「V1 啟動後能否持續運作？」— 從創辦人個人收入永續支撐，與審計資金完全脫鉤。

本節規定營運面。啟動面在 §8.1。

**啟動時與 Phase 1（TVL $500–$25K，採 §2.6.1 Reference Implementation Mode）的營運預算：**

| 項目 | 配置 | 年化成本 |
|------|------|---------|
| 伺服器（keeper） | 單一小型 ARM instance — **此 TVL 下不採雙 instance HA** | ~$50 |
| Blockfrost API | 免費 tier + 採 §3.6 的 5-key 輪替 | $0 |
| 監控 + alert | 自架 Grafana / Discord webhook | $0 |
| Domain（`optivaults.app`） | 攤提 | ~$10 |
| 鏈上費用 | §2.6.1 cadence 下 ~12–24 TX/年 × ~$1 | ~$20 |
| **合計** | | **~$80/年** |

這是 **launch-state 營運模型**，不是我們打算很快脫離的暫時性 scarcity-mode 設定。它的可永續性取決於：要麼 (a) TVL 成長到足以支撐更完整的基礎設施、要麼 (b) 在 §9.2 下優雅 sunset。

在 ~$80/年的營運承諾下，創辦人的長期負擔**容易從個人收入吸收**，不會帶來 runway 耗盡的問題。這讓營運面的承諾即使沒有大額啟動資本儲備也依然 credible，並**將啟動決策（受 §0.2 / §8.1 audit-funding gating）與啟動後永續性決策（創辦人承擔、結構性可永續）清楚脫鉤**。

**依 TVL 變動的成本擴張**（operator-discretion 切換，非合約強制）：

| TVL 區段 | 年化營運成本 | 年化協議收入（6% gross × 4.5% perf fee） | 創辦人吸收的短缺 |
|---------|------------|--------------------------------------|---------------|
| $500–$2K (sub-scenario a) | ~$80 | $1–$5 | ~$75–$79/年 |
| $2K–$25K (sub-scenario b) | ~$80–$100 | $5–$67 | ~$30–$75/年 |
| $25K–$100K (sub-scenario c) | ~$200–$500（Default cadence 恢復） | $65–$270 | ~$0–$200/年 |
| $100K+（突破上限、post-audit 後） | ~$400–$1,200（HA + 付費監控） | $270+ | 逐步自給 |

每個 TVL 區段下，創辦人每年吸收的短缺都維持在**低三位數美元**範圍，從不需要大額 lump-sum 承諾。這正是 minimal-operations 模型能與審計資金問題乾淨脫鉤的關鍵。

**HA / 雙伺服器升級門檻。** `docs/economics.md §4` 列雙 instance HA 為「最小可行」推薦配置。V1 啟動模型**刻意以 HA 換最低成本，直到 TVL 突破約 $50K**——屆時吸收的短缺已足以正當化第二台伺服器帶來的 resilience。$50K TVL 前，單一伺服器故障表示 keeper 下線；7-day keeper-inactivity 合約 fallback（§5.4.1）確保存入者 withdraw 不被擋下、`early_withdraw_fee` 在故障期間自動 waive。單一伺服器故障在 Phase 1 早期是可接受的取捨。

**這個模型帶來什麼：**

- V1 在 pre-audit 100K cap 下從啟動日起就在 mainnet 運作，不需要創辦人 runway 同時承擔審計成本；外部審計在資金到位時用來把 cap 解鎖到 Stage 2 / Stage 3（§1.5），而不是 gating 啟動本身
- 啟動後，若社群發現速度慢，V1 可在 $500–$25K TVL **無限期運作**——同樣若審計資金始終未到位（§8.1 Option D），V1 在 100K cap 也能無限期運作
- TVL 成長與營運永續性脫鉤——V1 **不受「不成長就死」的時間壓力**——且審計資金與 mainnet 持續運作脫鉤
- §4.1 / §9.2 sunset 觸發條件**不是**由營運 runway 耗盡驅動（本模型下結構性可永續）**也不是**由審計資金失敗驅動（這只是在 §8.1 Option D 下把 cap 維持在 100K，不影響協議 live 狀態）—— sunset 觸發是 §1.5 Class A overrides（USDCx / Liqwid / Cardano chain / oracle 事件）或創辦人明確 sunset 決定
- 創辦人承諾範圍 bounded 且明確：~$2K seed + 年化 $80–$200 營運補貼 + ~$15K 審計 gap-fill 上限。創辦人對 V1 的總財務曝險是 **low-five-figures USD 上限**，跨越完整的 pre-audit + launch + 無限期 100K cap 窗口——比審計 base price 低幾個數量級，與 §0.2 公共財 volunteer-builder framing 一致。

### 4.4 誠實對比

V1 的正確對比基準**不是**自己直接 Liqwid USDCx supply（0.5–2% APY、借貸需求稀薄、有經驗的 Cardano DeFi 使用者幾乎不碰）。正確對比是**自己直接 Liqwid DJED supply**——這才是成熟使用者會親手做的事。

**2026-04-21 參考 Liqwid 供應 APY**（快照；隨借貸需求波動，每次 rebalance 重查）：DJED ~11.8%、USDM ~5.3%、USDCx ~0.5–2%。

#### V1 收益分解

我們把 V1 收益機制明確拆成「結構性 drag」與「費用衝擊」兩塊。下面數字使用 2026 Q2 參考利率。

| 組成 | 年化貢獻 |
|------|----------|
| 45% DJED Liqwid（11.84%）+ 25% USDM Liqwid（5.33%）+ 30% USDCx idle buffer（0%） | 5.33% + 1.33% + 0% = 6.66% 毛 |
| Idle buffer drag（相對於「buffer 也 supply 到 Liqwid USDCx 1.5%」的替代方案） | 30% × 1.5% = -0.45%（45 bps 放棄收益相對於部署到 Liqwid USDCx 的選項） |
| 績效費：4.5% × 6.66% 毛 | -0.30% |
| **使用者淨 APY** | **6.36%** |

注意：6.66% 毛數字已經考慮 30% buffer 賺 0%。45 bps「buffer drag」這一行衡量的是「不把 buffer supply 到 Liqwid USDCx 市場（1.5% APY）的成本」，**它不從 6.66% 再扣**——它是「保留 buffer 這個政策選擇 vs 把 buffer 部署到 Liqwid USDCx」的成本。這個政策是有意識的：buffer 在 Liqwid 利用率飆升時提供瞬間提領能力與緊急流動性。

#### 對比：V1 vs 直接 Liqwid DJED supply

擁有足夠資本與運作能力的使用者可以靠直接 supply 到單一 Liqwid 市場複製更高收益。最積極的單市場選項是 DJED：

| 參數 | V1（被動） | 自己直接 Liqwid DJED |
|------|-----------|---------------------|
| 淨 APY | 6.36% | 11.80% |
| 年化差距 | – | -544 bps |
| 使用者花的力氣 | 無 | 主動監控 + 手動 compound |
| 集中度風險 | 分散在 3 種穩定幣 + 30% buffer | 100% DJED、100% Liqwid |
| ADA 相關曝險 | ~45%（DJED 抵押） | ~100%（DJED 抵押） |
| 提領流動性 | Buffer 即時 + queue 路徑 | 取決於 Liqwid 利用率 |

差距是真的。任何有足夠 DeFi 經驗能安全自己管 DJED 部位的人，淨得收益近 V1 的兩倍。**V1 沒要在純收益上贏這個策略。** 如果那是你，自己直接 DJED supply 是對的產品。

#### V1 的 544 bps 差距買到什麼

1. **降低營運負擔。** 進場一筆 TX 搞定（不需要手動串 swap + supply）、離場用一次 vUSDCx burn 完成（每次提領不必跑 Liqwid recall + Minswap swap back 往返）、治理更新策略時的跨市場再配置由金庫層自動完成（不必自己發手動 rebalance TX）、脫鉤事件觸發由合約層的 freeze 處理（不需要自建 oracle 監控）。附註：qToken 在 Liqwid pool shard 遷移時的可贖回性是 Liqwid 自己處理的——不管透過 V1 或直接走 Liqwid 都不用使用者操心，這部分不是 V1 獨有的價值。
2. **雙發行者配置。** 啟動 45% DJED + 25% USDM 把曝險分散到兩個獨立的穩定幣發行者（COTI 發 DJED、Mehen 發 USDM）。這可防**發行者特定**失敗（Mehen 倒閉、COTI DJED 儲備耗盡）——但**不能**防 ADA 閃崩情境同時壓垮兩者（§5.2 明確覆蓋）。使用者可自己複製配置，代價是平行管兩個 Liqwid 部位。
3. **提領流動性。** 30% USDCx 閒置 buffer（0% 收益是設計——見 §2.3）讓多數提領可在一個 TX 內結算，不用等 Liqwid Recall 往返。自己直接 DJED supply 沒這種 buffer，Liqwid Recall 要一整筆 TX 且受當下市場 underlying 餘額限制。
4. **自助退場保證。** keeper 離線 7 天以上仍可用 `emergency-withdraw` 自行回收本金（§5.4）。自建部位一旦失去當初建倉工具的存取權就沒有等效保護。
5. **多穩定幣脫鉤監控。** V1 的 keeper 持續脫鉤訊號下停止新 Deploy（§5.2）；自建部位要自己寫 + 自己跑。

#### 損益平衡分析 —— 規範表請看 §1.3.1

V1 對 Direct Liqwid 的損益平衡採用 §1.3.1 引入的「時間成本 + 風險管理外包」雙成分框架。**§1.3.1 的表是規範引用;v1.3 起兩節改採同一組數字**,不再各自呈現會逐漸發散的兩套計算。本節說明兩個成分背後的數學與理由,但不重印表格——具體數字請看 §1.3.1。

**成分 A:純時間成本損益平衡。** 把使用者時間成本估為 15 小時/年 × 時薪,除以 544 bps 收益差距:

```
損益平衡存入_A = (年所需小時 × 時薪) / 收益差距_bps
              ≈ (15 × $20) / 5.44%
              ≈ $5,500
```

只用這個計算,存入超過 ~$5K 且每年有 15 小時可做手動管理的使用者,扣除時間成本後 V1 不會勝出。**但成分 A 單獨並不是大多數存入者該用的框架**——它低估了 V1 在收益之外提供的東西(下方成分 B)。

**成分 B:風險管理外包 premium。** V1 涵蓋了 Direct Liqwid 使用者要嘛自己建、要嘛只能直接接受曝險的營運與風控工作:

- **分散化價值**:持有 100% DJED 帶有 V1 45/25/30 配置避免的集中度風險。閃崩情境下,「縮減 30% 配置」這件事每年帶來大約 1–2% 存款金額的隱性保險價值,也是 V1 費用的一部分。
- **自動複利的 NAV 數學**:Direct Liqwid 使用者若沒手動 compound,相對於理論完美 compound 一年損失 ~30–50 bps。V1 自動做。
- **脫鉤反應基礎設施**:V1 合約層 freeze + keeper 脫鉤監控 + 自助 emergency-withdraw 路徑。Direct Liqwid 使用者得自建監控與反應計畫。
- **避免操作錯誤**:失敗的 Recall、batcher 延遲、swap 路由、pool-shard 遷移——V1 keeper 處理,Direct Liqwid 使用者得自己學會與處理。

風險管理 premium 成分對 $5K–$50K 規模存入的合理估計是每年 200–300 bps,並隨使用者複雜度配合存款規模而下降到 ~100–150 bps(成熟的 $1M 持有人通常已經有這些工作流程)。§1.3.1 的表已把這個區間換算成各使用者輪廓的「感知價值」欄。

**整合後的誠實損益平衡**:對大多數現實輪廓而言,實務損益平衡落在 **$25K–$40K 區間**——完整逐輪廓數字請查 [§1.3.1 損益平衡表](#131-存入者實際得到什麼產品優勢)。~$40K 以上且有相關 DeFi 經驗的使用者,Direct Liqwid DJED 真的是更好的選擇。

#### V1 適合誰

V1 為下列使用者設計，符合下面任一條件：

- 存入金額在 ~$30K 以下，時間 + 風險管理成本超過收益差距 × 時間價值
- 集中度反感：因 ADA 相關閃崩風險不願持有 100% DJED
- 沒意願或沒能力監控 Liqwid 健康狀況、管理 rebalancing、或回應脫鉤事件
- 偏好非託管被動曝險，配上可審計的鏈上操作與明確的緊急協議

#### V1 不適合誰

我們不建議下列使用者用 V1：

- 持有 ~$40K 以上且有時間做手動管理
- 對單一穩定幣（通常是收益最高的 DJED）有強烈信念，願意承擔集中度風險
- 需要收益高於 6% 才有經濟意義
- 需要固定利率曝險而非浮動利率（未來產品見 §1.7 V1.5）

我們不會人工誇大 V1 的價值主張。對直接 DJED supply 的 544 bps 差距是真的；能自己捕捉的使用者，就應該自己捕捉。

#### 未來產品定位（前向參考）

§1.7（V1.5）描述的固定利率 vault 產品，服務 V1 與直接 Liqwid 都不服務的市場區段：需要可預測、期限鎖定回報、適合機構國庫規劃的使用者。V1 與固定利率 vault 是互補關係，不是競爭關係。

#### 100K TVL 下的經濟誠實揭露

在 pre-audit 上限,V1 自身收入(以 6% 毛收益估算約 $270/年)不足以覆蓋營運成本(~$360-2,400/年,economics.md §4)。啟動期差額由啟動資金吸收,**不會**以更高費率轉嫁給存入者——不管 V1 當下規模多小,存入者只付 4.5%。要等到 TVL 成長到 $135K–$1.8M 自給規模(baseline 約 $500K),同樣的 4.5% 才能同時覆蓋營運成本 + treasury 累積。

若治理後續啟用 USDCx buffer 的收益去處（見 §2.3），0% buffer 項會上升，混合毛收益提升——例如 30% × 1.5% buffer 端收益會增加 ~45 bps 毛。變動會在 `UpdateStrategy` 進入 queue 前公開揭露，縮小但不關閉與自己直接 DJED supply 的差距。

進一步數字見 `docs/economics.md` §4（營運成本）、§6.2（淨 APY 情境）、§6.3（替代選項對照）、§9（費用流失分解）。

### 4.5 Compound 週期與每次網路費成本

> **適用範圍說明。** 本節描述 §2.6 預設節奏在 100K cap 參考點的每次網路費成本。**Phase 1 sub-scenario（$500–$25K TVL、走 §2.6.1 Reference Implementation Mode）的營運成本見 §4.3.1 cost-scaling 表**——那才是 volunteer-operator 啟動預算。本節 §4.5 對應的是 post-cap-lift Default-cadence 的成本輪廓。

§2.6 的排程是**上限、不是目標**。Keeper 只在累計收益 × 剩餘結算窗口足以攤銷鏈上費用時才真的執行 Compound，否則等待。Zero-yield heartbeat（每 5 天一次）仍會照跑，推進 `last_realloc_time`——即使當下收益在經濟上不顯著。

V1 在 pre-audit 100K USDCx 上限下、§2.6 預設節奏下位於 **weekly 檔**（`total_deposited` ≥ 1,200 USDCx 分層），對應的 Compound 排程是**每週六一次**。§2.6 的 4 層 TVL 分層完整列在 §2.6 Compound 頻率表中；低於 1,200 USDCx 的較低分層**是 keeper 在 vault 處於該門檻以下任何時期的實際運作政策**（特別是 §8.2 sub-scenario (a)–(b) 的 Phase 1 小 TVL 窗口，以及 `total_deposited` < $25K 時生效的 §2.6.1 Reference Implementation Mode）。100K cap 下的啟動日預期：**每週六一次的 Compound** + 每 5 天一次的 zero-yield heartbeat；若啟動 TVL 低於 $25K 開始，則先按上方表中較低 tier 的節奏運作，直到跨過門檻才進入下一 tier（見 §2.6.1 mode transition mechanics）。

合約 validator 會接受任何滿足 validity-range 與 cooldown 不變式的 Compound TX（見 `spec/vault-datum.md` §3 第 6 項與第 11 項）；具體何時送交由 keeper 決定。相較早期「每 3 天」的天真排程，weekly 檔大約節省 85% 的網路費開銷。

**每次 Compound 的鏈上成本**（Cardano 主網、Conway era 加 reference script 的數量級估計）：

| TX 類型 | Cardano 費用 | 支付方 |
|---------|--------------|--------|
| 排程 Compound（buffer-funded） | 1.5–2.5 ADA | Keeper（從 keeper_fee 份額支付） |
| BatchProcess（每 TX N 筆訂單） | 2–3 ADA，由 N 位使用者分攤 | Keeper |
| VaultSwap（Minswap V2 路由） | 2 ADA 網路費 + 2 ADA DEX 訂單 | Keeper |
| SupplyToLiqwid / RecallFromLiqwid | 1.5–2 ADA | Keeper |
| MergeUtxo（合併） | 0.5–1 ADA | Keeper |

100K TVL weekly 檔（約 52 次 Compound/年 + 約 12 次 heartbeat + 約 20 次 rebalance/supply），keeper 一年的鏈上成本約 **$50–80**（以 ADA 計價，由 keeper 錢包支付）。

**Vault ADA 補充——`SwapAda` 閉環機制。** 每筆 `DeployToProtocol`（VaultSwap）TX 會讓金庫淨付約 2 ADA 給 Minswap V2 批處理者；若沒有補充機制，金庫最終會降到 `min_vault_ada` 底限並阻擋後續 Deploy。V1 透過 `SwapAda` redeemer 在鏈上閉環（規格見 `spec/ada-swap.md`）：當 `vault.lovelace < 15 ADA` 時，keeper 呼叫 `SwapAda` 給金庫 10–50 ADA，並按 Charli3 + Orcfax 的 oracle 匯率換回等值 USDCx。Validator 強制 1 小時冷卻、validity-range 上限寬度 1 小時、oracle 價公平原子交換——信任前提就只有系統本來就依賴的 depeg monitoring oracle。存款人承擔的是 USDCx 緩慢流出造成的 Minswap 批處理費——100K TVL 下每 2–4 週一次 SwapAda（每次 20–40 ADA ≈ 10–20 USDCx），全年摩擦約 0.02% APY drag，相對 4–6% 毛收益幾乎可忽略。

Keeper 端：keeper 以 **USDCx** 收取 40% 份額，可定期在 Minswap 上把 USDCx 換成 ADA 來補充自己錢包的 Cardano 網路費。每次轉換約 60 bps（每季一次約等於一年 2.4 bps），100K TVL 下近乎忽略，但會隨 keeper 份額線性放大。這筆摩擦只有當 keeper 攤銷其他沈沒成本時（創辦人運營模型）才能被 40% keeper 份額（100K TVL × 6% 毛收益 ≈ $108/年）吸收;或當 TVL 跨過約 $1M 時,40% 份額本身就能覆蓋低端非創辦人 keeper 的獨立運營預算。**40% 上限(在 validator 硬上限)就是為了把第三方 keeper 經濟可行門檻拉到 ~$1M TVL 而設**——完整 breakeven matrix 見 §4.3。

#### 4.5.1 使用者自己要付的鏈上費用（直接 vs 排程對照）

存入者自行操作時，會付到的 ADA 費用全部列在這裡：

| 操作 | 對應 TX 類型 | 使用者支付 ADA | 金庫結算時間 | 備註 |
|------|--------------|----------------|---------------|------|
| **直接存入（Direct Deposit）** | 單筆 TX，錢包簽名後直接進金庫 | **約 0.5 ADA** 網路費 | 即時（該 TX confirm 後） | 需與金庫 UTXO 直接互動；忙時可能撞到 UTXO 競爭而需重送 |
| **排程存入（Queue Deposit）** | Order UTXO → keeper BatchProcess | **約 0.5 ADA 網路費 + `max_batcher_tip`** | 通常小於 1 小時（keeper 每 5–15 分鐘跑一個批次週期；非合約強制 SLA） | `max_batcher_tip` 由使用者建訂單時自行設定（建議 0.1–0.5 ADA），keeper 處理時以此為上限收取。訂單資金進 Order UTXO，隨時可 `Cancel`（任何 block）或 24 小時後自動 `Expire` 取回。`max_batcher_tip` 與 Minswap V2 自己的 batcher fee 不同——後者由金庫在 VaultSwap 時吸收、不由存入者支付。 |
| **直接提款（Direct Withdraw）** | 單筆 TX，錢包簽名後直接從金庫提 | **約 1–1.5 ADA** 網路費 | 即時 | 比直接存入貴一些，因為要透過 proxy 花費金庫 UTXO，走 Withdraw-Zero forwarding 等於一次 proxy + 一次 staking validator 共兩次 validator 呼叫（§3.2） |
| **排程提款（Queue Withdraw）** | Order UTXO → keeper BatchProcess | **約 1 ADA 網路費 + `max_batcher_tip`** | 通常小於 1 小時 | 與其他訂單一起批次化；優點是在金庫忙碌時不需搶 UTXO。份額送進 Order UTXO 後同樣可 `Cancel` / `Expire` |
| **緊急提款（Emergency Withdraw）** | 使用者自己透過 CLI 或前端建 TX 提領 | **約 1.5–2 ADA** 網路費 | 即時 | keeper 離線 > 7 天後使用；早提領費自動免收。此路徑完全不依賴營運方 |

**怎麼選？實務建議：**

- **小額部位（< $500）**：直接存入直接提款比較簡單，手續費摩擦分得還可以。
- **中額部位（$500–$2,500）**：排程單的批次化在忙碌時比較順；`max_batcher_tip` 建議設 0.2–0.5 ADA，讓 keeper 願意優先處理。
- **大額部位（≥ 5% 當下 TVL）**：盡量走直接路徑。當前 100K TVL 上限下，單筆 $5K 以上的訂單若和其他大單進到同一批，會感受到 §5 `order-batch.md` 描述的 pre-batch 定價飄移。

**一個實際數字感：** 存入 $100 USDCx（約 0.25 ADA 以當前匯率）需要支付約 0.5 ADA 網路費——相當於本金的 0.25%。這是非常小的部位常見的入場摩擦，與 V1 協議層收 0% 存入費沒有衝突：V1 不另外抽成，但 Cardano 網路本身收取的固定網路費是避不掉的。

---

## 5. 風險框架

### 5.1 智能合約風險

V1 啟動時的審計狀態：

- **繼承自內部驗證階段的多輪內部審計。** 這裡的「內部審計輪次」指：針對特定威脅模型，對每一個 validator 做一次對抗性讀碼，產出分級為 CRITICAL / HIGH / MEDIUM / LOW / INFO 的書面報告；每一輪只有在所有非 INFO 發現都已修復並加上回歸測試後才算結束。完整方法論見 `docs/audit-scope.md` §2。
- **額外針對 V1 新增範圍的內部審計覆蓋**（treasury、keeper_stake_script、跨 validator 整合流程、部署流程、off-chain runtime）。這部分以領域（A–F）為單位組織，不再採用序號式輪次，詳見 `docs/audit-scope.md` §4。
- **第三方審計仍在規劃**(目標 Q2-Q3 2027——funding-stack 揭露見 §8.1),作為解除 TVL 上限的前置門檻。

**迭代修補方法論的一個實例——A2 設計缺口關閉。** 內部審計發現 V1 每個 staking validator 一開始都只寫了 `withdraw(...)` + `else(_) { fail }` 的 catch-all。Cardano ledger 驗證 stake credential `Deregister` 證書時走 Publish purpose，剛好打到 `else` → 任何 deregister 都會被拒 → ceremony PHASE 4a 投入的每個 staking validator 2 ADA 註冊押金都會被永久鎖住。修復版本（「A2」）在 staking validator 加上治理閘門的 `publish` 處理器，重用已經頻繁使用的 `is_gov_authorized(ActDeregisterStake, payload_hash_deregister_stake(own_hash))` helper。覆蓋範圍現在涵蓋 V1 全部 **14 個 staking credential**（canonical 名單見 §6.2 `ActDeregisterStake`）。讓每個 credential 有 bytecode headroom 容納 `publish` handler 的 validator partitioning 記在 `spec/architecture.md §4.1`。設計決策紀錄在 `spec/governance.md §4.13` + `spec/keeper-auth.md §9`。這個迭代展示了 V1 的開發模式：發現 → 規格 → 修復 → 回歸測試 → 出貨 → 文件化。Preprod ceremony 的 ActDeregisterStake 執行流程完成後，存入者可以在鏈上驗證 A2 修復。

**讀者請注意。** 內部審計是必要的前置作業，但不能取代第三方審計。V1 真正關鍵的安全訊號是即將到來的外部審計報告——內部審計只能降低外部審計發現 CRITICAL 問題的機率，不能消除這個機率。100K USDCx 的 TVL 上限，就是對「V1 是未經外部審計的生產軟體」的明確承認。

外部審計前，除了「100K USDCx TVL 上限，由營運方強制執行」之外，V1 不對外做其他承諾。

#### 5.1.1 對抗性鏈上重放覆蓋

內部審計的靜態讀碼之外，另一條補強路線是「對抗性鏈上重放」：把手工構造的攻擊交易直接送到 Preprod ceremony build 的活合約上，把合約的拒絕（或接受）當成鏈上證據紀錄下來。這條路線把審計輪次盤點到的理論防禦層，轉成可觀察的拒絕樣態（以交易雜湊或 evaluate trace 為索引）。

下面列的是「實際在 Preprod 上觸發過的防禦層」，**並非**「所有可能的攻擊都已測過」的量化承諾。外部審計仍然是主要的安全訊號——鏈上重放只是補上一條「親手造攻擊 TX → 鏈上拒絕」的端到端佐證，用來與單元測試、property 測試互相驗證。

**Preprod 實測過的防禦層分類**

- **金庫主 UTXO spend（`vault_proxy.ak`）** — `withdrawal_count == 1`（每個金庫主 spend 只能 dispatch 一個 staking validator）、`no_foreign_vault_datum`（拒絕非 proxy 腳本地址的 InlineDatum-shaped `VaultDatum`）、`is_full_drain` NFT-burn 要求、`vault_count ∈ [2, 5]` NoDatum-secondary 上下限、`all_secondary_no_datum` MergeUtxo 閘門。

- **用戶路徑 redeemer（`vault_user.ak`）** — `Deposit` mint-equality（`vUSDCx mint == expected_shares`）、`Deposit` `min_deposit` 下限、`Withdraw` burn-equality（`vUSDCx burn == -shares`）、`verify_receiver_output` 嚴格 pkh 等值檢查（redeemer 內 receiver 欄位綁定到實際輸出收款人）、`verify_receiver_output` Script-credential 拒絕（receiver 必須是 VKey 錢包，不可為鎖死腳本）、`CommunitySunset` 90 天時間門檻。

- **Keeper 路徑 redeemer（`vault_keeper_hot.ak`、`vault_swap_ada.ak`）** — 所有寫時間欄位的 redeemer 強制 validity-range width cap（`upper - now ≤ 1 hour`）、`vault_swap_ada` amount-in-range 邊界（每筆 swap 10–50 ADA）、`ada_below_threshold` 補充閘門。

- **協議路由 redeemer（`vault_protocol.ak`）** — `DeployToProtocol` 目的地白名單（`registry.protocol_hashes`）、SwapAdapter 收款者綁定（caller 層 + adapter 層共同確認 `expected_recipient_addr`）、Tier 2 peg-floor 對 adapter-committed `min_receive` 的下限（`min_receive × 10_000 ≥ deploy_amount × min_swap_peg_bps`）、`min_order_amount` 非存入代幣 swap-out 的金額下限。

- **Mint policy（`vusdcx.ak`、`vault_nft.ak`）** — `vUSDCx` 單一 asset name 紀律（拒絕同 policy 下的多 asset mint）、`vault_nft` PlutusV3 UTXO-ref 一次性鑄造（parameterized UTXO 必須出現在 `tx.inputs`；該 UTXO 被花掉後就無法再 mint，從結構上保證只能鑄一次）。

- **Order 分支（`order.ak`）** — `signed_by_owner` 在 `CancelAction` 上的嚴格簽署者驗證、`valid_refund` 在 `ExpireOrder` 上的收款者綁定（退款必須給原 `ord.owner`）。

- **Multisig 治理（`multisig_gov.ak`）** — `valid_signer_set` rotation 下限（`n ≥ 3` 簽署者）、`time_window_ok` `lower_bound ≥ executable_at_ms`（timelock 結束前不可 ExecuteAction）、`payload_hash` 綁定（apply 側 payload 必須 hash 到佇列中某 action 的紀錄值——RotateSigners + UpdateFee + UpdateRegistry + TreasurySpend 全部共用此模式）、`is_gov_authorized` 跨 validator helper 重算 `expected_payload_hash`。

- **緊急 / 費用治理（`vault_gov_emergency.ak`、`vault_gov_policy.ak`）** — `validate_emergency_freeze_only`（`loss_amount == 0` 不變式：EmergencyWithdraw 只能切換 `frozen` 旗標，絕不可減少 `total_deposited`）、`max_performance_fee_bps`（450 bps 上限，即使是經完整治理授權的 `UpdateFee` 也擋下）、與 `multisig_gov` 共用的 payload-binding 對應層（Treasury Spend / UpdateFee / RotateSigners 都走同一個 `is_gov_authorized` helper）。

- **CIP-69 purpose 隔離** — 每個 PlutusV3 validator 明確宣告自己處理的 purpose（例如 staking validator 只宣告 `withdraw` + `publish`）；其餘 purpose 一律由 `else(_) { fail "<validator>: unsupported purpose" }` 捕捉並 fail，含 Spend / Mint / Vote / Propose 等。把 UTXO 故意打到 `payment_credential = <staking script hash>` 的位址上會被永久鎖死——因為對應腳本根本沒有 Spend handler。

- **份額價格不變式（`total_deposited` / `total_shares`）** — 每一條會動到這兩個欄位的路徑都被嚴格約束：Deposit + Withdraw 走 `calculate_shares_to_mint` / `calculate_withdraw_amount` 的嚴格等式；Compound 只動 `total_deposited`（產生 yield → 份額單價上升，這是設計意圖）；BatchProcess 走 per-order 公平 share 計算；其餘 8 個 redeemer 一律強制 `total_deposited == old.total_deposited && total_shares == old.total_shares`，由 `verify_protocol_fields_preserved` / `verify_liqwid_invariants` / `verify_emergency_freeze_only` / `verify_datum_unchanged` 等 helper 把關。原碼審查涵蓋全部路徑；比例不變式不會在設計意圖之外被人為破壞（Compound yield 與 deferred-yield 早期解約費用均屬設計範圍內的上升）。

**結果**：上述每一類鏈上重放都在 Preprod 上產出明確的拒絕證跡（Ogmios `evaluate` 或 `tx/submit` 回傳結構化的 script-error trace，明確指出哪個 validator 在哪個 purpose 下 fail），對應的回歸測試腳本保留在 `tests/preprod/` 底下。**沒有發現任何合約該拒卻沒拒的攻擊。** 這個結果跟迭代方法論一致——絕大多數表面在鏈上重放之前已先由單元測試與 property 測試覆蓋過——鏈上證據是再多一層獨立確認。

**有一類刻意延後**：由 `UpdateRegistry` 注入假的 Liqwid `action_addr_hash`，再讓 Supply 路由到假位址。對應的防禦（`vault_liqwid.SupplyToLiqwid` 的 `qtoken_delta > 0` 不變式——假的 action validator 在每市場固定的 qToken policy 下根本 mint 不出真的 qToken）已由 Aiken unit test（`lib/vault/tests/`）涵蓋；鏈上重放暫時不做，是因為儀式步驟（queue UpdateRegistry → 等 timelock → 跑 Supply）的成本，相對於單元測試之外能多帶來的審計敘述價值偏低。

**鏈上重放並未涵蓋的部分**：外部系統失敗（Liqwid bad-debt、USDCx redemption 凍結、oracle staleness——這些是 §5.3 / §5.2 / §5.4 的風險面，不是合約層防禦）；需要模擬惡意營運者的 keeper 私鑰妥協情境（由原碼審查 + §5.4 keeper 風險討論承擔）；以及只有特定 Preprod build 狀態才會出現的行為（例如金庫已全額配置到 Liqwid 時，部分 Withdraw 路徑必須先 Recall 才能執行——這屬於運維流程，不是安全防禦）。

回歸測試腳本本身是開源版本的一部分；審計師與整合方可以在新的 Preprod ceremony 上重跑這些腳本，獨立重現拒絕 trace。整套做法（構造攻擊 TX → 上鏈 → 把合約拒絕紀錄成 TX hash 或 eval trace）也是未來 V1.x 與 V2 審計輪次可以直接沿用的模板。

### 5.2 穩定幣脫鉤風險（多資產）

V1 同時持有三種穩定幣：USDCx（存入代幣）、DJED（Liqwid 配置）、USDM（Liqwid 配置）。**這是「單一生態系曝險下的雙發行者配置」，不是真正的風險分散。** 每一種都有自己的脫鉤風險；存入者真正承擔的是「脫鉤事件發生當下、金庫剛好持有的那一種」——不只是 USDCx。

**多穩定幣配置可以防的**（發行者特定失敗，統計上接近獨立）：

- **Mehen 倒閉 / attestation 失效** —— USDM 法幣後盾蒸發，但 DJED（ADA 擔保）與 USDCx（Circle 後盾）不受影響。
- **COTI DJED 儲備耗盡** —— DJED 擔保率崩潰，但 USDM（法幣）與 USDCx（Circle）不受影響。
- **Circle 合規事件凍結 USDC** —— USDCx 贖回路徑中斷，但 DJED（ADA）與 USDM（Mehen 法幣）仍可交易。

**多穩定幣配置不能防的**（相關性失效，Cardano 上較現實的壓力情境）：

- **ADA 閃崩。** DJED 擔保是 ADA；ADA 劇烈下跌觸發 DJED 脫鉤。同時 Cardano DEX 流動性變薄，反向 swap（DJED → USDCx、USDM → USDCx）在 keeper 凍結觸發前會以脫鉤折扣價成交。V1 配置目標把三者當獨立處理，但**不假設失效模式在統計上獨立**。ADA 閃崩是最可能引發這種相關性多資產壓力的觸發點。
- **Cardano 生態系統系統性事件**（鏈停機、協議層漏洞、針對 Cardano 穩定幣發行者整體的監管行動）。
- **黑天鵝：三者同時獨立失效**，無共同觸發點——尾端情境，V1 設計不對此做保護。

**V1 比較適合的情況**：你能接受「Cardano 穩定幣籃」作為單一相關性曝險，分散只防範發行者特定的崩潰。**V1 可能不適合的情況**：你期待多資產配置能讓你躲過 ADA 崩盤——事實上它做不到。

---

**USDCx** 的信任鏈是 Circle 的營運健全度、xReserve 橋接安全、以及 USDC 的贖回路徑。若 USDCx 真的脫鉤，V1 keeper 會停止接受新存入，存入者仍可提領（但拿回來的 USDCx 本身可能已經脫鉤）。

**DJED** 是 Cardano 原生的超額擔保演算法穩定幣，以 ADA 儲備支撐。歷史上曾在 ADA 價格劇烈波動、擔保率壓縮時發生脫鉤。當金庫在 Compound 時點仍配置於 DJED，share price 的會計會反映 DJED 當下的市價——DJED 若脫鉤，所有 vUSDCx 持有者的 share price 會按比例下修。

**USDM** 由 Mehen 以法幣儲備發行。**Liqwid USDM 市場的總 TVL 比 Liqwid DJED 市場小**（2026-04-21 快照下 DJED 11.84% APY 遠高於 USDM 5.33% 反映 DJED 有較強 borrow demand）——壓力事件時若 USDM market utilization 拉到 100%，大額 Recall 必須等借款人還款才能取回，這是 V1 對 USDM 部位的 **Liqwid-side 壓力風險**。**DEX swap 層面則相反**：Minswap V2 的 USDCx/USDM 直接池（2026-04 快照約 11.6M reserves per side）**實際上比 USDCx/DJED 任一路由（無直接大池，須 2-hop via ADA 或 3-hop via NIGHT hub）更深**，所以 reverse swap（USDM → USDCx）在小到中型規模下滑點反而比 DJED → USDCx 路徑低。兩個流動性面向（Liqwid 市場 TVL vs DEX pool depth）不應混為一談。

**存入者實際持有的是什麼：** 是對金庫「當下資產組合」的比例請求權，並不是純 USDCx 的請求權。假設金庫此時有 90% 在 DJED，而 DJED 脫鉤 20%，那 share price 會下跌約 18%——USDCx 本身狀況如何已不重要。

**V1 的緩解措施：**

- **逐一資產的脫鉤監控** ——keeper 持續監看 Cardano 原生的 oracle 資料源（Charli3 + Orcfax）與 Minswap V2 TWAP，偵測「連續 15 分鐘 > 1% 的偏離」。全程不經過跨鏈 oracle 橋接，與 §2.3「不使用跨鏈橋」的承諾一致。持續脫鉤一旦確認，治理即可透過 `EmergencyWithdraw` 動作將 `frozen` 設為 1，並對營運方觸發警報。
- **配置上限** ——`UpdateStrategy` 維持每個穩定幣的配置上下限（目前的營運目標：45% DJED + 25% USDM + 30% USDCx buffer）。若要將某個市場配置拉到政策上限之上，治理必須走完整的 `UpdateStrategy` 動作加 7 天 timelock。
- **透過 `KeeperToggleMarket` 做 Liqwid 市場層級隔離** ——keeper 可以單方面停用特定 Liqwid 市場的新 supply（單向旗標：`active: True → False`），不必等治理 timelock；這是 `frozen = 1` 完整凍結前的快速應變層。

**V1 不緩解的：**

- **快速脫鉤期間的在途 swap 滑點。** 反向 swap（例如 DJED → USDCx）有機會在凍結觸發前，以脫鉤折扣價先被成交。
- **相關性脫鉤風險。** DJED 的擔保是 ADA、USDM 的後盾是法幣儲備、USDCx 的後盾是 Circle USDC——名義上是三條獨立的信任鏈，但歷史市場壓力事件顯示 Cardano 穩定幣的脫鉤往往會同步發生：ADA 一次劇烈下跌會同時觸發 DJED 脫鉤、**並且**壓縮 USDM/USDCx 在 DEX 上的流動性。V1 的配置目標把三者當成獨立，但**並不假設失效模式在統計上獨立**。ADA 閃崩是最可能引發這種相關性壓力的觸發點。
- **黑天鵝：三種穩定幣同時獨立失效。** V1 設計不對這種純尾端情境做保護；前面講的「相關性壓力」才是較現實的多資產風險模式。
- **發行方發起的贖回凍結**（Circle 合規事件、Mehen attestation 失效等）。鏈上代幣仍可轉讓，但可能一時無法兌換回美元。

**Flash-loan 與早提領費保留機制的互動。** V1 的早提領費（§2.4）以 share price 上升的形式回饋給剩餘持有者——也就是被提領者付的費用留在金庫作為 buffer，拉升所有剩餘份額的請求權。攻擊者理論上可以 flash-loan 一筆 vUSDCx，立刻在 `min_hold_seconds` 窗口內提領付費，再重新入場把費用領回。但這套攻擊實際上跑不起來：(a) flash-loan vUSDCx 需要已存在的 vUSDCx 借貸市場，啟動時並沒有；(b) 費用按比例攤給所有剩餘份額（包括攻擊者重入的那份），來回淨為零；(c) 攻擊者還要付閃電循環裡的網路 TX 費與 Minswap 滑點。目前這套設計沒有已知可獲利的 flash-loan 路徑；V1 會持續觀察是否出現 vUSDCx 借貸市場，真有了再重新評估。

### 5.2.1 Cardano 生態演化情境

V1 的風險輪廓不是靜態的。Cardano DeFi 基礎設施的數個預期里程碑若如期成熟，會實質改變 V1 的風險輪廓——有些會降低風險，有些則引入新的風險面。本小節列出存入者應留意的條件性敏感度，獨立於 V1 自身設計（§5.1–5.6）。**這些是明確的外部狀態假設，不是預測或承諾**——存入者有權看到並自行追蹤。

**Pogun BTC DeFi 上線（2026 Q2 借貸 → Q3 yield → Q4 BitVM bridge）。** Pogun 在 Cardano 上推出 BTC 抵押借貸，若按計劃上線，會實質提升 Liqwid 穩定幣市場的借方需求——目前這正是結構性缺口、也是 Liqwid 穩定幣 APY 集中而非分散的根本原因。更高且穩定的借方需求將：(a) 拉升 V1 的混合收益、(b) 降低 Liqwid 利用率飆升阻擋 keeper Recall 的機率、(c) 最終解鎖 V2.x BTC 抵押收益路由（§1.7）。**風險：** Pogun 目前是 IO 公開揭露的 roadmap，主網時程有目標但無確切日期。若 Pogun 延後過 2027 Q2，V1 將無限期維持當前的單一協議 Liqwid 姿態，啟動就緒框架（§1.5）的 A 軸維持紅級。

**Leios 擴容（testnet 2026 年底，mainnet 2027）。** Cardano 的 Leios 升級目標是把 TX 吞吐量提升 10–65×。對 V1 而言，Leios 降低：(a) 每筆 Compound / BatchProcess / Swap TX 的網路費、(b) order 從送出到 batch fill 的延遲、(c) 脫鉤事件期間 Minswap V2 batcher 的擁塞。淨效果：V1 的營運成本基線預估在 Leios 之後縮減 30–60%，相應降低 §4.3 的 keeper 損益平衡 TVL。**風險：** Leios 自身是大型協議升級，有時程不確定性。若 Leios 延後到 2028 之後，V1 keeper 經濟學維持當前成本曲線，§4.3 自給門檻會推向 $740K–$1.48M tier (b) 區間的上端。

**Midnight DeFi Kernel 成熟（研究階段，生產目標 2028+）。** Midnight 公開的隱私保護 DeFi 基礎設施成熟後，將解鎖 V3.0 機構級隱私 vault（§1.7）。對 V1 自身而言，Midnight 成熟**不是**風險變動因素——V1 是 Cardano mainnet 公開產品，與 Midnight **完全無依賴關係**。Midnight 純粹是 V3.0 的前向 optionality；不論 Midnight 進展如何，V1 風險輪廓**都不受影響**。**風險：** Midnight DeFi Kernel 目前處於研究論文層級概念、非生產代碼。公開的 2028+ 時程帶有可觀的不確定性；V3.0 評估要等 Midnight Kernel 進入生產形態才會啟動。若 Midnight 沒有成熟，V1 + V1.5 + V2.x 仍是專案的產品面——V3.0 單純不發生，這也是可接受的結果。

**USDCx 補貼到期（Q1 2026 IOG 跨鏈費補貼結束後）。** USDCx 在 Cardano 上線初期由 IOG 出資的跨鏈費補貼支撐——這降低了透過 xReserve 把 USDC 移入移出 Cardano 的摩擦。補貼結束（Q1 2026 之後），USDCx mint/burn 的天然成本重新浮現——這是個小但非零的單趟摩擦，可能抑制 Cardano 上 USDCx 的有機 supply 成長。對 V1 而言，這透過啟動就緒框架（§1.5）的 B 軸監控：若補貼後 30 天淨流出超過 10%，B 軸轉紅，V1 啟動被閘控。**風險：** 若 USDCx supply 在補貼後出現實質收縮（30 天淨流出 > 10%），這是 Cardano 有機 USDCx 需求低於門檻的明確訊號，V1 的 TAM 假設（§1.2）需要重新檢視。反過來說，若補貼結束後 supply 仍持續成長，B 軸的綠燈就是 V1 市場定位結構性穩固的最強訊號之一。

**NIGHT solar drop 持續釋出時程（450 天 thawing）。** NIGHT token thawing 時程從每位持有者的快照日起算 450 天持續釋出 supply。對 V1 的關聯是間接的：創辦人的 Minswap V2 ADA/NIGHT LP 部位（§1.6）是創辦人個人投資組合的一部分，NIGHT 持續釋出會影響 Minswap V2 上 ADA/NIGHT pool 的動態——而這是 V1 用來做穩定幣 routing 的同一個 DEX。Minswap V2 上的 pool 深度變動（任一 pair，因為 AMM 共享流動性提供者注意力）會邊際影響 V1 的 swap 衝擊估計。這是低量級的影響——Minswap V2 穩定幣 pool 的規模大致獨立於 NIGHT 相關流動性——但為求完整列出，因為創辦人的 NIGHT/ADA LP 是 §1.6 文件化的偏誤來源之一。

**V1 不假設的事。** 上述條件性敏感度文件化的目的是讓存入者了解，當 Cardano DeFi 基礎設施成熟時 V1 風險輪廓會如何演化——**不是預測、不是承諾**。V1 設計上能在當前姿態（單一協議 Liqwid wrapper、僅 Cardano mainnet、USDCx 計價）下運作，與哪一個情境是否成立無關。Pogun 延後，V1 繼續以當前 yield 出貨。Leios 延後，V1 keeper 經濟維持原狀。Midnight 沒有成熟，V3.0 不發生——V1 不受影響。啟動就緒框架（§1.5）是外部狀態變動回饋到 V1 TVL 上限演進的正式機制；本小節讓底層假設與觸發條件明確化，讓存入者能獨立追蹤。

### 5.3 Liqwid 協議風險

**§1.1 的刻意 scope boundary 換個角度看就是這裡的風險。** §1.1 明確說「V1 **不是** 多協議收益 aggregator」——那是刻意的產品範圍選擇，不是疏漏。從威脅模型的角度再看同一件事，它就變成存入者要承擔的風險：V1 只 route 到一個協議，那個協議一旦倒了，V1 沒有可切換的備援。本節是 §1.1 產品定位在風險面的誠實對照——兩邊描述的是同一件事，只是視角不同。

**單一協議集中度風險（V1 特定）。** V1 全部收益來自 Liqwid 一個協議——不是因為我們看好 Liqwid 勝過所有對手，而是 Cardano 當前穩定幣供應端沒有第二個達到「深度 + 審計成熟度 + Aiken 整合可行性」三重門檻的借貸協議。若 Liqwid 發生協議級失效（合約漏洞、清算機制崩潰、governance 攻擊），V1 **沒有備援協議可以快速遷移**——會被迫走 `EmergencyWithdraw` 凍結 + 存入者自助退場。Mitigation：(a) Liqwid 本身已歷多輪第三方審計 + 主網運行超過一年；(b) 任何 Liqwid 異常事件均可由治理觸發 `EmergencyWithdraw` 凍結金庫，存入者 `withdraw-cli` 自助退場路徑**完全不依賴 Liqwid 可用性**，只需 Cardano ledger 本身可用；(c) 未來 V2+ 若引入第二個供應端協議（§1.1 的方向，門檻見 §1.6.3），將降低此集中度。在 V2+ 演進發生前，存入者應將 Liqwid 協議風險視為 V1 的**單一最大鏈上風險源**——高於治理風險，也高於任一穩定幣的脫鉤風險。

V1 對 Liqwid 的曝險來自把 USDCx、DJED、USDM 供應至 Liqwid 的 action validator，並把 qToken 收據留在金庫 UTXO 裡。這帶來幾類協議風險：

- **壞帳**：若 Liqwid 的清算與準備金機制未能覆蓋擔保不足的貸款，qToken 對 underlying 的兌換率會下降。金庫供應倉位按比例貶值，會於下次 Compound 反映到 share price。
- **qToken 匯率誤算或操縱**：V1 信任 Liqwid 鏈上的匯率模型做 qToken ↔ underlying 換算。若匯率被攻擊或誤算，金庫部位價值會被錯誤入帳。
- **Pool 遷移**：Liqwid 偶爾會遷移 pool shard（`action_addr_hash` 變動）。若 keeper 對舊 pool 執行 Recall 會失敗。V1 用 `FastUpdateMarkets`（治理 1 小時 timelock）將 registry 指向新 pool 處理。
- **Action validator 升級**：Liqwid 合約更新若改變 Supply/Recall 介面，keeper 邏輯可能會壞。使用者資金仍在（合約升級不會動到資金），但收益累積會暫停直到 keeper 程式更新。

V1 的緩解措施：

- **Share price 透明化**——損失會在下次 Compound 顯現，不會被藏起來。存入者在下一個配置決策前就能看到帳面變化。
- **`EmergencyWithdraw`**——治理可凍結金庫以規劃復原（0 天 timelock）。Phase 1 治理安全限制:此 redeemer 在 validator 層**只能 freeze**——不能減少 `total_deposited`、不能修改 `liqwid_positions`。實際損失帳務改走 `vault_liqwid.RecallFromLiqwid` 的治理 fallback 路徑——透過實體 Recall underlying USDCx 並只寫入實際實現的短缺（見 §5.5.1 Layer 1 + `docs/security-model.md` §5.4）。
- **`KeeperToggleMarket`**——keeper 可在不需治理延遲的情況下單方停用特定 Liqwid 市場的新 Supply（單向旗標 `active: True → False`）。這是 keeper 偵測異常但治理尚未開會時的快速應變層。
- **Per-market 部位隔離**——`LiqwidPosition { market_id, qtokens_held, supplied_value }` 依 market 獨立追蹤；單一市場發生壞帳不會自動把其他市場一併寫掉。

### 5.4 Keeper 風險

Keeper 是一個信任委託，鏈上邊界整理如下：

- **不變式檢查。**
    - `no_vusdcx_leak`：BatchProcess 不可將 vUSDCx 路由到 `order_owners ∪ proxy_hash` 以外的地址；
    - `verify_other_tokens_preserved`：keeper 不可把金庫內的非存入代幣拿走；
    - `slippage_ok`：每一筆訂單都會被檢查——keeper 建構的 BatchProcess TX 必須尊重每位使用者於存入訂單給的 `min_shares` 與提領訂單給的 `max_shares_burn`。這是使用者在建訂單時自行設定的容忍範圍，不是協議預設的固定百分比。
- **Keeper 端 swap 滑點政策（V1 當前狀態，誠實揭露）。** 當 keeper 主動透過 `DeployToProtocol` 在 Minswap V2 上為再平衡做 DEX swap（USDCx ↔ DJED / USDM）時，keeper 軟體會對 `minReceive` 套 1.5% 容忍度、並在預期價格衝擊 > 2% 時放棄該路由。**這層保護是 keeper 軟體的營運政策，V1 啟動時合約並沒有強制。** 被入侵的 keeper 如果硬要送一筆更寬滑點的 TX，V1 合約仍會接受——結果就是金庫餘額按滑點差縮水，所有 vUSDCx 持有者的 share price 同步下降。逐訂單的 `min_shares` / `max_shares_burn` 使用者端邊界保護 BatchProcess 路徑，**不會限制 keeper 主動發起的 DEX swap 對金庫餘額造成的損失**。單次 swap 的理論損失上限 = Minswap V2 當下池深對金庫 swap 規模允許的最大滑點（100K TVL 下以當前池深估計為低個位數百分比；池深本身是公開資料）。目前的 mitigation 屬於營運層：(a) `protocol_hashes` Registry 白名單把對手方綁死在 Minswap V2 身上，資金無法被路由到 keeper 控制的 script；(b) 創辦人擔任 keeper 也就是把個人聲譽與沉沒成本壓上去；(c) 鏈上 TX 歷史公開，寬滑點 swap 一經執行就看得到，存入者可於 7 天早提領費免除窗口內退場。

    **V1.x pre-audit 前置條件——合約強制滑點上限**（承諾，非延遲）。出貨 peg-floor + oracle-based 滑點強制是外部審計**關鍵路徑**上的工作，不是 post-audit 迭代。datum 層機制：

    - 把 `max_slippage_bps` + `min_swap_peg_bps` 加進 `VaultDatum`，由新的 `UpdateSlippagePolicy` 治理 redeemer 管理（48h timelock 是為了維持 depeg 應變的敏捷性，1-of-n cancel 保留）。
    - `DeployToProtocol` 解碼 Minswap V2 route order datum，提取 `minReceive` 與 `amount_in`，強制 `min_receive × 10_000 >= deploy_amount × min_swap_peg_bps` 作為 Tier 2 peg-floor 邊界（擋下 `minReceive = 1` 極端滑點攻擊類，不需 oracle feed）。多跳透明——邊界套在**最終**輸出。
    - Tier 1（oracle-based fair-price `minReceive >= fair_out × (10_000 − max_slippage_bps) / 10_000`）會隨 Charli3 + Orcfax 雙 feed 對某 asset 達成覆蓋，透過治理 `UpdateRegistry` 更新新的 `asset_oracles` 清單，逐 asset 啟用。
    - SwapAda（§3.4 + §4.5）從單 Int MVP oracle 升級到同一套 dual-feed reader，關閉單 feed MVP 設計的已知疑慮。

    實作時程：pre-external-audit，與審計 commit 同一個 deploy ceremony。完整的 P1–P5 滑點 stack 出貨即**全部上鏈**，不再是營運政策層；「V1 Pre-Launch Candidate」指的是這個完整強制的合約 delta（以外部審計為前提）。

    **當前狀態 — 依驗證階段分類：**

    | 項目 | Code 落地 | Unit tested | Preprod E2E | 外部審計 |
    |------|:---------:|:-----------:|:-----------:|:--------:|
    | P1 vault_admin 拆分 | ✓ | ✓ | ✓ | Q2-Q3 2027 |
    | P2 UpdateSlippagePolicy + datum 欄位 | ✓ | ✓ | ✓ | Q2-Q3 2027 |
    | P3 Tier 1 dual-feed oracle | ✓ | ✓ | partial — registry validator 已部署；`asset_oracles` 啟動時為空（治理 post-mainnet 植入） | Q2-Q3 2027 |
    | P4 Minswap V2 decoder + peg-floor | ✓ | ✓ | **outstanding** — decoder 需對真實鏈上 `SwapExactIn` + `SwapMultiRouting` TX 做 byte-for-byte 驗證（`spec/swap-adapter.md §9`） | Q2-Q3 2027 |
    | P5 SwapAda dual-feed 升級 | ✓ | ✓ | partial — vault_swap_ada 已部署；`asset_oracles[ADA]` 啟動時為空（SwapAda 暫 inactive 直到治理植入） | Q2-Q3 2027 |
    | A2 deregister `publish` 在 14 個 staking credential | ✓ | ✓ | partial — 部分 staking credential 已驗證；14-credential 完整 Preprod 重新驗證主網前需完成 | Q2-Q3 2027 |

    「Code 落地」+ 194 個 unit + property 測試通過（689 個隨機化 checks per `aiken check`）並不取代 Preprod E2E 或外部審計。全部 24 個 artefact（17 個 logic validator + 4 個 NFT mint policy + `minswap_v2_adapter` + 2 個 SundaeSwap artefact）仍低於 16 KB Plutus V3 上限；最緊的 headroom 是 `vault_liqwid` 的 2,992 B free。（`docs/audit-scope.md §3` 用另一個 test-count metric「30 properties × 100 iterations = 3,000 fuzz runs per build」，那是只計算 `aiken/fuzz` 隨機 iteration 上限；本處的 689 是 `aiken check` summary 對整套測試的計數。完整對齊說明見 `audit-scope.md §3`。）

    **審計範圍 + 資金含意（摘要）。** 上述 pre-audit 滑點工作相對於「最小 pre-audit V1」擴大了外部審計範圍，粗估在 **$50–$150K 委託區間**（per-engagement、後折扣；折扣前 base 為 $100–$150K——見 §8.1）基礎上再多 +$15–$25K，Phase 3-5 開發時程多 +6-12 週（詳細拆解：範圍新增項、成本建模、資金堆疊影響——見 `docs/economics.md §5.2`）。在 §0.2 + §8.1 (d) volunteer-builder 框架下，審計成本本身**不**由創辦人 underwrite——它流經 §8.1 (a)–(d) 資金堆疊，創辦人 gap-fill 封頂約 $15K。+$15–$25K 範圍增量因此疊加到資金堆疊的目標金額上，而不是消耗某個私人 runway 數字；若堆疊表現低於門檻，則套用 Options A–D（時程延後 / 縮減 scope / 社群 crowdfund / 永久 mainnet 100K cap），見 §8.1。之所以在 pre-audit 就出貨滑點工作、而不是延到「V1.x post-audit」，理由是信任姿態：啟動時對外宣告、同時留著一個已知的 compromised-keeper 寬滑點攻擊路徑，比 audit-scope delta 的代價更差。
- **目的地白名單。** Registry 的 `protocol_hashes` 把 DeployToProtocol 的目的地限制在治理核准的 script（Minswap V2 orderbook、Liqwid action validator）；其他地址會被 `vault_protocol.ak` 直接拒絕。
- **Keeper 失效 fallback。** 鏈上完全以 `last_compound_time` 判斷 keeper 是否失效。當 `last_compound_time + 7d < tx.validity_range.upper` 時，會自動發生三件事：(a) 直接提領在合約層一律免收 `early_withdraw_fee`，不論 `min_hold_seconds` 是多少；(b) keeper 授權 redeemer（RecallFromLiqwid / RecallFromProtocol / AdminDeployNonDeposit）上的 `require_keeper_or_governance_fallback` gate 會開啟 m-of-n 治理 fallback 路徑——由治理以同一個 redeemer 代替 keeper 簽名；(c) `emergency-withdraw` 自助工具在經濟上變得合理，因為使用者不再付早提領費。整個機制不需要 off-chain 的 keeper 健康 oracle——在時間窗口內沒看到 keeper TX，本身就是訊號。這個比較**不能**被 TX 提交者用偽造的寬 `validity_range.upper` 騙過去：`vault_user.ak` 與 `vault_keeper_hot.ak` 對每個會寫入時間欄位的 redeemer 都強制 `validity_range.upper - validity_range.lower <= 1 hour`（內部驗證期確立的 width-cap 機制，詳見 `spec/vault-datum.md` §3 第 11 項），因此聲稱 `upper = now + 10y` 的交易會被 ledger 直接拒絕。Keeper 失效判定依賴的是實際的 ledger 時間，不是 TX 提交者的自稱。

**`last_compound_time` 與 `last_realloc_time` 的關係。** 這是 datum 裡兩個**不同的欄位**（詳見 `spec/vault-datum.md` §2.1）：

- `last_compound_time` 只有「實際收益 > 0」的 Compound 才會更新。
- `last_realloc_time` 則由 zero-yield Compound（heartbeat）以及任何配置更新（RebalanceBuffer / UpdateStrategy / reconciliation）觸發更新。

7 天 keeper 失效 gate **只讀 `last_compound_time`**。Zero-yield heartbeat 的用途是給 off-chain indexer 保持 `last_realloc_time` 新鮮的 liveness 訊號，**並不會重設 7 天 fallback 窗口**。換句話說，治理 fallback 能不能啟動，完全取決於真正的收益活動，不是 keeper 的「我還活著」ping。

最壞情況：keeper 完全停止運作。使用者一樣可以直接提領（第 7 天過後免費）或用 `emergency-withdraw` 自助工具，本金隨時取得回。

### 5.5 治理風險

啟動時為 **3-of-3 多簽**（3 位簽名者、threshold 3、全員同意才能通過）。簽名者配置為 **1 位創辦人簽名者 + 2 位獨立 Cardano 知名 SPO**，三位身份均於網站公開。3-of-3「全員同意」要求是刻意設計：即使創辦人 key 被竊或單方決策失誤，**也無法單獨 queue 任何治理動作**——必須說服 2 位獨立 SPO 同意才行；反之，創辦人串謀任一位 SPO 也只有 2-of-3，仍然不夠。1-of-3 cancel 不對稱性保留：任一位簽名者（包含任一位獨立 SPO）可於 timelock 窗口內否決已 queue 的動作。

獨立 SPO 招募是 mainnet ceremony 前的**目標**,但**不是合約層的上線 blocker**——§5.5.1 三層治理安全設計提供可接受的 fallback,若招募進度落後,V1 可以 founder-only governance 啟動,SPO 招募在啟動後窗口繼續進行(這是 contingency 路徑,不是目標)。選擇標準:Cardano 主網 SPO ≥ 2 年營運、鏈上公開識別(pool ticker + 站點)、未與創辦人有商業合作歷史、社群技術聲譽良好、理想上至少一位於非亞洲時區以提供治理回應時間分散。

**SPO 簽名者的角色定位 —— Cardano 社群服務。** V1 啟動時 2 位獨立 SPO 簽名者的承諾**本質上是 Cardano 社群服務角色，而非經濟誘因驅動**。Phase 2+ 若達到 $500K TVL 觸發 `UpdateFeeSplit` 引入 5-10% gov pool share 是額外好處，不是主要動機。SPO 接受這個角色的理由：(a) 支持 Cardano DeFi 公共財基礎設施、(b) 以 stake pool 營運者身份為 V1 存款人提供結構性異議否決保護、(c) 聲譽資產的延伸，類似 DRep 承諾的定位。若 V1 停在 Phase 1 終點狀態（§1.6.3 + §8.2 可能情境），SPO 的承諾不預期獲得財務回報——這與 V1 公共財、非商業的定位相符。SPO 招募溝通會在 mainnet ceremony 前以這套框架說明，避免簽名者的預期與實際激勵結構脫鉤。

**SPO 招募分階段——依實際營運 TVL 推進。** SPO 招募的活動強度,隨 V1 真實營運規模調整。以下分階段取代過去把「SPO 席位」視為主網日前必須完成的固定可交付項的框架:

- **Phase 0(主網前)**——若 §1.5 啟動就緒條件仍未滿足,SPO 招募**可延後**。創辦人單獨治理 + §5.5.1 三層安全設計,本身就是存入者保護的底線。在主網前邀請 SPO 進入治理可以接受但非必要;若 SPO 偏好等到主網真實營運開始才加入,我們尊重這個選擇。
- **Phase 1 小 TVL($500–$25K)**——V1 進入 Reference Implementation Mode(§2.6.1),治理活動稀疏(偶爾的 `UpdateStrategy`、可能的緊急回應)。這個階段邀請 SPO 加入,**必須完整揭露「治理工作量很輕」這件事**。為了「掛 SPO 之名做信任 signal」而招募、卻不告知實際工作量,**不是合適的做法**。
- **Phase 1 中段 TVL($25–100K)**——主動進行 SPO 招募,並明確說明預期治理工作量,以及預期切到 Phase 2 的時程。
- **Phase 2 觸發($100K+ TVL、且已 post-audit)**——3-of-3 完整運作。三位 SPO 席位全部 active。治理工作量反映真實的存入者規模。

創辦人保留「比 TVL 進度更早招募 SPO」的選項——前提是,這對 V1 對外定位(audit firm 接洽、Cardano Foundation 接洽、Catalyst 評審委員會)能帶來實質的可信度提升。但 SPO 的承諾,本質上仍是上方所說的「Cardano 社群服務」,**在實質 TVL 出現之前,不會被預期負擔有意義的治理工作量**。若 V1 無限期停留在 Phase 1(§1.6.3 的 terminal-state 情境),SPO 的角色也可能維持為象徵性 / standby——以 §5.5.1 三層安全設計作為實質替代。這是可被接受的 terminal 結局,**不是**治理設計失敗。

相關揭露：

- 三位簽名者身份皆在網站公開（1 位創辦人 + 2 位 SPO，含 pool ticker）。
- 手續費與簽名者變更都要走 14 天 timelock；`UpdateFeeSplit` 走 21 天 timelock。
- 任一簽名者可於 timelock 內用 1-of-n cancel 否決。
- 若簽名者無法續任，有訂定有序結束協議（§9.2）。

殘餘風險：**3-of-3 全部串謀**（三位簽名者集體配合推動惡意動作）。緩解方式：(a) 三位身份公開帶來的聲譽壓力，且 2 位 SPO 各自有獨立 stake pool 需要長期維護、聲譽綁定強；(b) 14 天（或 21 天）的 timelock 窗口內存入者可從容退場；(c) validator 層的硬上限（§6.3）——即使治理全部串謀，也還是動不了這些上限。

**審計後路線圖。** 外部審計通過、TVL 成長後，治理依 §6.1 的 Phase 2/3/4 輪替。從 Phase 2 開始（5+ 位簽名者、新增社群徵選簽名者），threshold 下降到 `n-1`（例如 4-of-5），這樣任何時候都至少有一位簽名者不在通過 quorum 裡，可以行使真正的 1-of-n 結構性異議否決——把 3-of-3 啟動時「創辦人可被單獨 SPO 擋下」的保護進一步強化為「quorum 外獨立簽名者永遠存在」。

### 5.5.1 三層治理安全設計

不論簽名者組成為何，V1 validator 集合都帶有三層結構性保護，防範治理金鑰失陷。這三層的設計目的是讓**單一簽名者治理**（例如 SPO 招募延遲時的暫時狀態）能成為 Phase 1 的合理 fallback——存入者的回收機制不取決於治理簽名者的人數或獨立性。

**Layer 1 — EmergencyWithdraw 改為 freeze-only。** `vault_gov_emergency` 中的 `EmergencyWithdraw` redeemer 不能減少 `total_deposited`、不能移除或修改 `liqwid_positions` 中的任何條目、也不能接受非零的 `loss_amount`。它唯一能做的就是切換 `frozen` flag（0 ↔ 1）。所有實際損失帳務必須走 `vault_liqwid.RecallFromLiqwid` 的治理 fallback 路徑——透過實體 Recall underlying USDCx 並只寫入真實實現的損失（`supplied_value − underlying_received`）。被入侵的治理金鑰**無法**只動 datum 把部位寫掉造成 share price 下降——qToken 變孤兒的 grief 攻擊面在 validator 層被完全封閉。

**Layer 2 — DeployToProtocol 在 freeze 下對 swap-out 仍開放。** 當 `frozen == 1` 且 redeemer 的 `deploy_token != deposit_token` 時，keeper 仍可透過 registry 白名單的 SwapAdapter（Minswap V2）執行 swap-out。SwapAdapter validator 強制目的地 = vault 自己的地址，所以即便 keeper 金鑰被入侵，攻擊者也無法把 output 改路；最壞情況只能逼出 Tier 2 peg-floor 邊界內的 slippage（≤ 5-7%），且 USDCx 仍然落到 vault 給 user 提領。沒有這層例外，freeze 一啟動 NDV 部分就會卡到 21 天後的 `AdminDeployNonDeposit` 治理 fallback 才能脫困——Layer 2 把這 21 天窗口縮短為「keeper 仍在線就能立刻 swap」。

**Layer 3 — CommunitySunset 自動止血開關。** 當 vault 連續 90 天無操作（`max(last_compound_time, last_realloc_time) + 90 天 ≤ now`），任何 vUSDCx 持有者都可以呼叫 `vault_user` 中的 `CommunitySunset` 這個 permissionless redeemer。它原子性地把 `frozen` 設為 1、`community_sunset_triggered` 設為 1（單向不可逆）。一旦觸發：

- `vault_liqwid.RecallFromLiqwid` 接受任何簽名者（不需要 keeper 或治理簽名）。
- `vault_protocol.DeployToProtocol` Layer 2 路徑也接受任何簽名者（同上）。

任何 vUSDCx 持有者都能驅動完整的回收鏈——Recall → Swap → Withdraw——完全不需要 keeper 或治理介入。90 天門檻相當於漏跑 ≈ 18 次 zero-yield heartbeat（每 5 天一次），等同於 keeper 完全死掉。Sunset 路徑**只開回收，不能改 datum**——它無法動 `total_deposited`、`total_shares`、`idle_buffer`、`liqwid_positions` 或任何 policy / immutable 欄位。Validator 的保留條款確保 sunset 期間 SwapAdapter 的目的地、peg-floor、slippage 限制仍然生效，攻擊者無法利用開放的回收路徑抽走價值。

**邊角情境:只打 heartbeat 但停掉 productive Compound 的 keeper。** Layer 3 觸發條件是 `max(last_compound_time, last_realloc_time) + 90 天`,因此一個只持續送 heartbeat、卻不做 productive Compound 的 keeper,理論上可以無限期延後 Layer 3。這**不是缺陷**,而是有意的設計選擇——在這個情境下,存入者仍有足夠的保護:

1. **§5.4 的 7 天 inactivity gate 只讀 `last_compound_time`**,不論 heartbeat 有沒有打,只要 productive Compound 停超過 7 天,gate **就會**啟動:(a) Direct Withdraw 早提領費自動免收、(b) keeper-authorized redeemer 的治理 m-of-n fallback 打開、(c) Emergency Withdraw 對存入者變得經濟合理。
2. **Direct Withdraw 完全照常運作**,早提費自動免收,存入者不需要 keeper 配合也能退場。
3. **未被 compound 的真實收益會反映在 share price 停滯上**,存入者隨時可從金庫帳務看到。
4. **Withdraw-Zero 的 `vault_user` validator 在 Direct Withdraw 上是 permissionless 的**——不需要 keeper 簽名。

Layer 3 因此是**最後一道**回收路徑,不是主要保護。Layer 1–2 + 7 天 gate + 自助 withdraw 基礎設施,在攻擊者撐到 Layer 3 之前就已經把 keeper-sabotage 情境蓋住了。

**為什麼用 `max(both)` 而不是只看 `last_compound_time`。** Layer 3 觸發條件用 `max(last_compound_time, last_realloc_time)`、而不是單看 `last_compound_time`,這個選擇是有意的,為了同時支援兩種合法營運情境:

- **Reference Implementation Mode(§2.6.1)**:低 TVL 期間只跑 heartbeat 是合法的營運模式。若只看 `last_compound_time`,會在這個模式下過早觸發 Layer 3。
- **遷移 / V2 部署情境**:治理可能合法地在遷移窗口暫停 productive Compound,同時透過 `RebalanceBuffer` 或 `UpdateStrategy` 維持金庫狀態存活——這兩種動作都會更新 `last_realloc_time`。

「keeper 故意只打 heartbeat 來拖延 Layer 3」這個情境確實存在,但已被上述其他保護蓋住範圍。成本效益權衡(保住合法使用情境 vs 攻擊者拖延 Layer 3 的時間)上,`max(both)` 是較合理的選擇。此處特別揭露,是給審計方在檢視 Layer 3 設計選擇時的參考。

**實務上的意義。** 如果創辦人誠實但只用一把 key，系統就照常運作為 1-of-1 multisig，配合 timelock + cancel 安全原語。如果創辦人金鑰被盜，攻擊者拿不到任何價值（Layer 1 封死 brick 路徑，Layer 2 維持回收流量，§6.3 的硬上限封住手續費濫用）。**如果創辦人停付 §4.3.1 ~$80/年營運補貼、但又沒正式啟動 §9.2 sunset**（v1.4 volunteer 模型下的場景，於 §9.2 (c) 描述）：keeper 離線 → §5.4 7 天 gate 自動生效（Direct Withdraw 早提款費免除）→ 到了 90 天下方 Layer 3 即可由任一 vUSDCx 持有者觸發。**如果創辦人因任何原因連續 90+ 天失能**，存入者直接執行 Layer 3 社群止血，不需要任何 operator 配合就能拿回 USDCx。**這個回收範圍不涵蓋**部署用的 ~962 ADA reference-script 鎖定，也不涵蓋 ~28 ADA 的 stake credential 押金——這兩部分綁定創辦人部署錢包與 A2 治理路徑，作為單一簽名者治理的殘留成本。

這三層設計是**讓單一簽名者治理成為 Phase 1 合理 fallback**的關鍵——而不是嚴重風險。SPO 招募仍是首選路徑（提供額外的可信度與結構性異議），但不是上線阻礙。

### 5.6 未經外部審計的風險

V1 雖然經過多輪內部審計，但尚未經第三方審計。**100K 的 TVL 上限就是對此風險的明確承認。** 存入者自行承擔責任。不論審計狀態為何，自助提領路徑隨時可用。

---

## 6. 信任模型與治理

### 6.1 六個獨立身份的分離目標（啟動時尚未完全達成，誠實揭露）

V1 的長期目標是讓六個身份由不同的人控制:keeper、三位治理簽名者、ref script 部署者、創辦人錢包。**啟動時這個分離只是部分達成,不是完全達成**——標題寫的是長期目標,不是啟動現況。

啟動時創辦人直接控制 **6 個席位中的 3 個**,這 3 個席位由下方 4 個角色聚合而成(ref-script deployer 與創辦人 subsidy wallet 在啟動時共用同一個錢包,所以 4 → 3 合併;完整地址對應見 `docs/security-model.md` §2):

- **(1) Keeper operator** —— 運作 keeper instance,簽署 Compound / Recall / Supply / VaultSwap 等 TX。
- **(2) 3 位治理簽名者中的 1 位** —— 創辦人在 `MultisigGov` quorum 中的簽名。
- **(3) Ref-script deployer 兼 創辦人 subsidy wallet(同一錢包)** —— 創辦人單一錢包同時 (a) 持有 20 個 ref-script UTXO(§8.2 ~962 ADA 鎖定),且 (b) 是把啟動資金注入 Phase 1 營運的 subsidy 來源。把這兩個角色合併成同一個錢包,是誠實揭露:即使把它們拆成兩個錢包,在 Phase 1 仍是同一位簽名者,對 SPOF 本質沒有改變,反而徒增儀式複雜度。

另外兩位治理簽名者由獨立 Cardano SPO 擔任、不在創辦人控制範圍——**前提是 §5.5 的 SPO 招募已落地**;若進入 §5.5.1 / §7.4 的 fallback 情境,創辦人會以 key separation 方式持有全部 3 個簽名者席位。§5.5.1 的三層治理安全設計就是為了讓存入者的回收路徑**不依賴**「六身份分離是否已完成」這件事。**V2 部署儀式計畫把 (3) 拆成 multi-sig ref-deployer wallet,分為兩個獨立金鑰**——見 §9.2 與 `docs/security-model.md` §2 的輪替路徑。

**輪替路徑**（以下使用 `threshold-of-total` 表示簽名者配置）：

- **Phase 1**（啟動到外部審計通過）：3 位簽名者（**1 位創辦人 + 2 位獨立 Cardano SPO**）、**threshold 3（3-of-3 全員同意）**——結構上創辦人為少數派（1/3）；理由見 §7.4。
- **Phase 2**（審計通過後 + TVL > 500K）：5 位簽名者（新增 1 位社群徵選簽名者）、**threshold 4（4-of-5）**——結構性異議簽名者恢復：`n - threshold = 1` 位永遠在通過 quorum 之外，可以行使 1-of-n cancel。
- **Phase 3**（TVL > 2M）：7 位簽名者（加入社群選舉席位——選舉機制 TBD，明確**不**以 vUSDCx 持有量作為投票權）、**threshold 5（5-of-7）**——`n - threshold = 2` 位 quorum 外的簽名者。
- **Phase 4**（成熟期、TVL > 10M）：評估 DAO 遷移。

### 6.2 治理動作

治理 ActionKind 收錄在 `spec/governance.md` §4。依最短 timelock 排序（validator 可強制更長、不可更短）：

| 最短 Timelock | ActionKind | 類別 |
|--------------|------------|------|
| 0 天（無最短等待——見下方注解） | `EmergencyWithdraw` | 緊急回應 |
| 1 小時 | `FastUpdateMarkets` | Liqwid pool-shard 遷移 |
| 48 小時 | `UpdateSlippagePolicy` | 安全 bound 調整（§5.4） |
| 7 天 | `UpdateStrategy` | 配置 / buffer 參數 |
| 7 天 | `TreasurySpend` | Treasury 類別流出 |
| 7 天 | `AdminDeployNonDeposit` | 非存款 token 回收 |
| 14 天 | `UpdateFee` | Performance / early fee / min-hold |
| 14 天 | `UpdateRegistry` | 穩定幣 / Liqwid markets / oracle |
| 14 天 | `UpdateKeeperAuth` | Keeper allowlist / 輪替 |
| 14 天 | `UpdateTreasuryParams` | 類別比例 / 上限 |
| 14 天 | `RotateSigners` | Multisig 成員 / threshold |
| 14 天 | `SlashBond` | Phase 3+ — V1 啟動時不可達 |
| 14 天 | `UpdateOracleSource` | SwapAda Charli3 / Orcfax feed 輪替 |
| 14 天 | `ActDeregisterStake` | End-of-life：14 staking validator × 2 ADA |
| 21 天 | `UpdateFeeSplit` | **治理在調整自己的報酬——timelock 最長** |

另有直接（非 queue）redeemer：`KeeperToggleMarket`（1 小時 keeper 單方停掉某個 Liqwid market — 見 §5.3，非治理 gating）、`Heartbeat`（1-of-self 簽名者 liveness）、`DistributeSignerCompensation`（1-of-n 季度資金池分配）。這些不走 queue→timelock→execute 流程，記在 `spec/governance.md` §5。

> **關於 `EmergencyWithdraw` 的 0 天 timelock。** 0 天指的是 Queue 跟 Execute **之間不設最短等待時間**，**不是**繞過治理共識。每一次 `EmergencyWithdraw` 執行仍需要**完整的 3-of-3 簽名**（§5.5 的 unanimity 要求）、queue 跟 execute 之間不管有多短的空窗仍**暴露在 1-of-n cancel 否決權下**、仍受 payload-hash 綁定約束。0 天買的是**反應速度**——當持續性脫鉤或 Liqwid 事件需要立刻凍結時，治理可以在同一次簽名 session 內 queue + execute 完成。Keeper 無法單方觸發 `EmergencyWithdraw`；keeper 的快速反應手段是 `KeeperToggleMarket`（§5.3），只能單方停掉某個 Liqwid market 的新 Supply，沒辦法凍結金庫或移動資金。

`ActDeregisterStake` 是 V1 operator 面向的「end-of-life」路徑：用來贖回 ceremony PHASE 4a 為每個 staking validator 投入的 2 ADA Cardano stake 註冊押金，走標準的 m-of-n 治理流程 + 14 天 timelock + 1-of-n cancel。**V1 的 14 個 staking credential 全部具備此路徑**：`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`、`keeper_stake_script`，以及 SwapAdapter `minswap_v2_adapter`，再加上 SundaeSwap 這一對 `sundaeswap_adapter` + `sundaeswap_cancel_guard`（各自單純為了啟用此路徑而以治理錨點為編譯期參數）。每一個治理動作都滿足：

- **最短 timelock 由 `multisig_gov.ak` 於鏈上強制**——治理可以選擇更長的 timelock，但不能比最短值更短。
- **Queue 時提交 payload hash**——避免執行時被替換成別的 payload（每個目標 validator 會呼叫 `is_gov_authorized`，重新計算 `blake2b_256(cbor.serialise(payload))` 並與 queue 時的 hash 比對）。
- **整個 timelock 期間任一簽名者可以 1-of-n cancel**——單方取消即可生效。
- **目標 script 綁定**——queue 時寫入的 `target_script` 必須等於目標 validator 的 script hash，確保某個動作無法被導向另一個 validator 執行。

### 6.3 治理的硬上限

以下上限寫死在 validator 裡，治理繞不過：

- `performance_fee_bps > 450`（4.5%）——會被 `vault_gov_policy.ak` 的 `UpdateFee` redeemer 拒絕
- `early_withdraw_fee_bps > 100`（1%）——同樣被 `UpdateFee` 拒絕
- `min_hold_seconds > 21600`（6 小時）——被 `UpdateFee` 拒絕。理由：V1 採週 Compound 節奏，即使治理拉到 6 小時上限，直接提領閘門也只封閉當週的約 3.6% 時間；排隊提領路徑從不被這個閘門觀察，使用者資金無論設定值為何都不會被鎖。從原本 24 小時的設計上限收緊至此——詳見 §2.4。
- `keeper_fee_bps > 4000`（40%）、`gov_fee_bps > 1000`（10%）、或 `keeper_fee_bps + gov_fee_bps > 5000`（treasury 下限 50%）——被 `UpdateFeeSplit` 拒絕
- `signers < 3`、`threshold < 2`、或 `threshold > signers`（全員同意 `threshold == signers` 明確允許——V1 啟動採 3-of-3）
- 任何編譯期錨的變更——需要重新部署整套合約

`buffer_target_bps` 是 keeper 在 Supply 與 Recall 之間抉擇時參考的建議值，不是 validator 強制的範圍。治理可以透過 `UpdateStrategy` 在 [0, 10000] 區間內設定，但 keeper 不會執行經濟上明顯不合理的數值。

---

## 7. Keeper 模型 —「先跑起來，再開放」

### 7.1 V1 啟動：只有創辦人當 keeper

V1 以 `RegistrationMode = GovernanceOnly` 部署 `keeper_stake_script`，allowlist 裡只有創辦人自己的 keeper pubkey。這是**誠實的啟動狀態**：

- 100K TVL 下的 keeper 經濟對非創辦人營運者不划算
- 假裝有其他選項就是誤導
- 未來要開放 keeper 的架構已經就位，也已納入審計範圍

### 7.2 未來開放：PermissionlessWithBond

等 TVL 成長到 keeper 營運在經濟上合理的水準（約 $5–10M 以上），治理可以透過 `UpdateKeeperAuth` 把 `RegistrationMode` 切換到 `PermissionlessWithBond`。屆時：

- 任何一方只要質押足額 bond（金額由治理設定）就能成為授權 keeper
- Keeper 依 bond 大小與績效排序
- Slashing 條件負責規範行為

完整的 bond + slashing 狀態機寫在 `spec/keeper-auth.md`，V1 審計會一併涵蓋，即使啟動時暫時停用。

### 7.3 為什麼現在就把這段設計公開

1. **承諾訊號。** V1 通往去中心化的路徑是架構性的、不是口頭承諾。未來要開放 keeper，只需要一筆治理 TX，不用重新設計協議。
2. **審計效率。** 機制整套一次審計，比起「啟動時審一次、未來升級再審一次」更省成本也更安全。
3. **社群回饋。** 提前公開設計，讓未來想當 keeper 的營運者能在切換前給意見。

### 7.4 創辦人兼任 keeper operator 與治理簽名者

**在基本案 Phase 1 小 TVL 配置 (b) 下**——依 Executive Summary 與 §8.2 $500–$25K Phase 1 TVL 區間，存入者啟動時應以此為預設假設——創辦人運作 keeper instance **並同時**以 HD-key 分隔（多把 HD-derived keys 存於物理上隔離的簽名環境）持有全部 3 個治理簽名者席位。**在 stretch-target 配置 (a) 下**——以 mainnet ceremony 前 SPO 招募成功落地為前提——創辦人運作 keeper 並擔任 **3 位治理簽名者中的 1 位**，其餘 2 席由獨立 Cardano SPO 持有（見 §5.5）。§5.5.1 三層治理安全設計 + §6.3 硬上限**不論簽名者集合組成都保留**存款人的復原路徑；(a) / (b) 的差別只影響治理異議語意，不影響合約層的存入者保護。任一情境下，此安排在 §6.1 揭露為 launch 階段的**單一營運方風險**——範圍僅限 keeper operator 選擇（在 (b) 下還包含治理簽名者集合），**不涵蓋合約程式碼**（全開源）、**不涵蓋 keeper 程式碼**（全開源且合約支援 `UpdateKeeperAuth` 切換）。

**Phase 1 3-of-3 全員同意實際能提供的保護**(誠實說法):

- **避免意外動作。** 沒有單一簽名者——包含創辦人——能因誤操作、金鑰失竊、脅迫或精神狀態不佳（喝醉、倉促、錢包被駭）而單方 queue 任何治理動作。這是真實的營運安全性質，與信任無關。
- **創辦人無法單獨通過治理。** 即使創辦人串謀 1 位 SPO，也只有 2-of-3，仍然不足以執行任何動作。任一位獨立 SPO 拒絕即可全面阻擋。
- **1-of-3 cancel 不對稱性。** Queue 需要 3 簽名，停止需要 1 個——任一位簽名者（包含任一位獨立 SPO）都可在 timelock 窗口內單方取消。
- **公開 timelock 觀察窗口。** 高影響動作 14 天 timelock（`UpdateFeeSplit` 21 天）公開曝露每個已 queue 變更，供存入者檢視 + 獨立研究到執行前。
- **治理完全動不了的硬性不變式**——validator 層上限（費用上限 4.5%、配置邊界、不可變身份欄位）。見 §6.3。

**Phase 1 3-of-3 的侷限**（同樣誠實）：

- **Keeper operator 啟動時為單人營運**（非 keeper 程式碼中心化）。V1 整個 keeper 原始碼開源，任何人可讀、可稽核、可自建 instance 跑。啟動階段由創辦人運作實際上線的 keeper——保持單一簽約義務方而非因技術限制。治理 `UpdateKeeperAuth`（14 天 timelock + 1-of-n cancel）可隨時更換授權的 keeper PKH——例如 Phase 2 TVL 門檻達成後指派其他營運者，或 Phase 3 啟用 `PermissionlessWithBond` 開放 keeper 註冊（合約已實作，啟動時 `RegistrationMode = GovernanceOnly` 停用）。若當前 keeper key 被竊，7 天 keeper 失效窗口過後合約自動啟動 m-of-n 治理 fallback；這期間 Compound / swap / DeployToProtocol 暫停，但 Direct Withdraw 0% 早提領費自動觸發，本金仍然安全。
- **SPO 社交距離仍有界。** 獨立 SPO 雖非創辦人招募對象，但 Cardano SPO 生態規模有限，彼此有一定社群互動。這個「獨立性」要理解為經濟與技術獨立，不是完全陌生。

**存入者應該如何理解 Phase 1 治理：** **「1 位創辦人 + 2 位獨立 Cardano SPO 共同治理；keeper instance 仍為創辦人單運作但授權可鏈上切換；結構性保護來自 timelock + hard caps + 自助退場路徑」**。Phase 2（post-audit + TVL > $500K，§6.1）擴充到 5 位簽名者並改為 4-of-5，引入結構性異議否決特性。

**Phase 1 小 TVL 治理姿態(營運 contingency)。** 若 V1 在 Phase 1 小 TVL 情境下啟動($500–$25K——即 §8.2 描述的 sub-scenario (a)「個人 reference」或 (b)「小規模有機成長」),這段期間 SPO 招募可能延後、或保留為象徵性 / standby 形式,與 §5.5 的 TVL-phased 招募框架一致。在這個情境下,創辦人**實質上以單一簽名者**方式運作治理——可以諮詢已邀請的 SPO,但日常治理動作不必要求 SPO 簽名。原本由「真實多簽名者異議否決」提供的結構性保護,改由 §5.5.1 三層安全設計取代。

這在文件中明確記載為**營運 contingency 模式**,**不是**對 §5.5 「3-of-3 啟動目標」的偏離。3-of-3 目標對「中段 TVL 以上」情境仍是正確配置;在小 TVL 情境下,它相對於實際治理活動量是 over-engineered,而 §5.5.1 fallback 才是更合適的營運姿態。當 TVL 持續跨越中段 TVL 門檻($25K+ 並維持),即按 §5.5 的分階段啟動完整 SPO 席位。

**創辦人的專業背景——在這裡揭露作為補充資訊，不是主要的起源故事。** 創辦人在 OptiVaults 之前的專業工作在傳統金融產業的財富管理／私人客戶服務端。這個背景在本節（不是 §1.6）揭露，**提供給覺得這個資訊有用的讀者**作為額外脈絡：V1 的某些設計選擇——4-bucket treasury 含 audit-reserve 硬 floor、專門針對 `UpdateFeeSplit` 用最長的 21 天 timelock（因為治理正在調整自己的報酬）、跟傳統金融產品發布節奏而非加密圈啟動節奏對齊的多層 Compound cadence——確實參考了傳統金融端熟悉的產品設計模式。但 V1 **並不是定位為傳統金融洞察的產物**；主要的起源故事（§1.6）是「創辦人就是使用者」。審計方、Catalyst 評審委員、投資人若想看職業背景脈絡，可以用這段；存入者應該用合約做什麼來評估 V1，而不是用創辦人的履歷。

### 7.5 Conway-era DRep 立場

V1 的金庫 UTXO 只持有必要的 ADA：符合 min-UTXO 規範，以及支付再平衡與 Compound 週期 gas 的營運緩衝。Treasury 合約累積的是 USDCx 績效費，不是 ADA。因此 V1 在 Conway-era 並沒有具規模的 ADA 部位可做 DRep 投票委託；金庫不是大規模 stake pool 委託者，Treasury 也不會對 Cardano 協議參數做鏈上表態。若未來營運累積出可觀的閒置 ADA（例如未來的 stake-based keeper-bond 方案），屆時可新增 `TreasuryDelegateDRep` 治理動作來處理委託。

---

## 8. 路線圖與里程碑

### 8.1 啟動前門檻

**Mainnet 啟動於 100K USDCx pre-audit cap 下（§1.5 的 Stage 1 / 1.5 / 2）所需條件：**

- [ ] V1 合約完成、全部測試通過、內部審計輪次完成
- [ ] Preprod 部署 + E2E 驗證（全 17 logic validators + 4 NFT mint policies + 1 DEX adapter，完整流程）
- [ ] 部署儀式 Preprod 演練
- [ ] §1.5 Class A override conditions（Liqwid / USDCx / Cardano chain / oracle）全部清除
- [ ] §1.5 axis 狀態達到 One-Yellow 或更佳（依 Stage matrix）

**Cap 解鎖到 Stage 3（$500K → $2M 依 §1.5 ramp）所需條件：**

- [ ] 委託外部審計並完成
- [ ] 審計發現修復
- [ ] §1.5 axis 狀態達到 All-Green 持續 60 天

**外部審計不是 launch gate；它是 cap-lift gate。** V1 在上方 launch gates 滿足時於 100K USDCx pre-audit cap 下上 mainnet。外部審計在資金到位時完成 Stage 3 cap lift；若資金始終未到位，V1 在 mainnet 維持 100K cap 無限期運作。這個分離是 §0.2 與 §4.3.1 闡述 volunteer-builder + community-funded audit 框架的結構性原因——創辦人承諾從啟動日起在 mainnet 100K 持續運作 V1；社群若希望 V1 成長到 cap 以上、自行資助審計。

**外部審計委託（若資金到位、目標 Q2-Q3 2027）。** 本白皮書撰寫時審計機構尚未選定或簽約；委託以「V1 Aiken 實作功能完整且內部驗證通過」**且** §8.1 資金堆疊提供足夠資金涵蓋委託為前置條件。候選機構將自具有 Cardano Plutus V3 + Aiken 先前經驗的審計方短名單中選出——這是一個相對狹窄的集合（發表時點包含 Anastasia Labs、MLabs、TxPipe 以及少數獨立 Aiken 審計方）。簽約機構與範圍將於審計啟動前至少 2 週公開公布。

**審計發現處置（當審計發生時）。** 若外部審計出現 CRITICAL findings、需合約重新設計的項目、或系統性設計缺陷，**Stage 2+ cap lift 會延期**直到修復 + 重新審計確認通過。Mainnet 在 100K cap 的運作在這個 remediation 窗口繼續，除非該 finding 嚴重到觸發 §1.5 Class A override（例如 CRITICAL 等級導致 §5 governance 緊急 freeze）。若審計發現當前架構無法修復的系統性缺陷，cap 無限期維持在 100K，架構重設會公開發布，且 V1 **沒有外部貢獻者出資／代幣預售／SAFE / SAFT 義務**需要清算——未支用的啟動資本留在啟動實體手中，供修訂後設計使用。

外部審計資金來自專案創辦資本（而非現有存款——internal-verification 階段部署有獨立的營運預算）。`docs/economics.md §5.2` 裡每次委託 **USD $50–$150K 的區間**,是根據 2025-2026 年間 Cardano 具備 Plutus V3 審計能力的公司(Anastasia Labs、MLabs、TxPipe)公開定價指示所估算——這個區間**上界對應折扣前 base 報價(~$100K–$150K),下界對應拿到 public-goods 折扣後的實際委託金額(~$50K–$90K)**。實際委託金額會在合約簽定時公開揭露。

**審計資金策略（公共財路徑下的 sustainability）。** V1 的公共財定位讓我們可以同時動用多個 non-dilutive funding source 降低 audit 成本負擔:

- **(a) Cardano Project Catalyst + Cardano Foundation + Intersect Member Committee + Aiken Foundation grants**：V1 的「Cardano DeFi public-goods reference implementation」定位與這四家的 DeFi / Infrastructure / Open Source 主題都對得上。四家合計樂觀情境 **$80–150K**（見下方資金堆疊表）；其中 Catalyst 單獨在 Round 開放時可預期取得 **$30–50K**，Cardano Foundation / Intersect Member Committee / Aiken Foundation 三家各自對 Cardano DeFi 公共財基礎設施 typical 額度約 **$10–30K**（公開資料可查 2024–2026 grant 歷史）。**撰寫時的狀態：Cardano Project Catalyst 處於暫停 / 重組狀態，下一個 Round 何時恢復尚無明確時程**；其餘三家持續以 rolling 或批次形式接受提案。V1 把 (a) 視為四個 channel 並行的候選來源、不依賴任一單一管道；審計時程（目標 Q2-Q3 2027）即是為了讓 Catalyst 在此區間恢復、或讓 funding 由非 Catalyst 的 (a) channels + (b)+(c)+(d) 完全覆蓋，兩種路徑都留得到時間。
- **(b) Audit firm 的 public-goods pricing**:Apache 2.0 + 非商業定位可能取得 **30-50% 折扣**,從全價 $100K-$150K 降到約 $50K-$90K;
- **(c) Scope reduction via extensive internal audit**:累積的多輪內部審計歷史作為 preparatory material 讓外部審計範圍可聚焦在 critical paths(2-3 個 most critical validators + 跨 validator 整合流程),而非全部 17 個 logic validator + 1 個 adapter 全範圍,再降約 **$15K-$25K**;
- **(d) 創辦人 gap-fill 補貼（有上限、非 underwriter）**：創辦人承諾**最多約 $15K 個人自掏**用於 bridging (a)/(b)/(c) 到位之後與最終審計報價之間的**微額短缺**。創辦人**明確不承諾在任何情境下 underwriting 完整 $50–$150K 審計成本**。這個上限相對於審計 base price 刻意設得很小——V1 是 volunteer-built 公共財（§0.2），不是 founder-underwritten 商業產品。若資金堆疊表現低於 $15K gap-fill 容量，V1 走下方 Options A–D contingency tree，而非升級 founder 自籌規模。

**Volunteer + capped-gap-fill 模型下的分布。** 資金堆疊結果分布如下（審計 base price $50–$150K — 下界由多家機構委託模式、scope reduction via 內審依賴、或審計機構 public-goods 折扣等手段達成；上界是 single firm full-scope 折扣前報價）：

| 來源 | 樂觀情境 | 中段情境 | Worst case |
|---|---|---|---|
| (a) Catalyst + Cardano Foundation + Intersect + Aiken Foundation grants 總和 | $80–150K 合計 | $30–60K | $0（審計啟動前都未恢復／核准） |
| (b) 審計機構 public-goods 折扣 | 砍 50%（−$50–75K） | 砍 30%（−$30–45K） | 0% 折扣（全價照付） |
| (c) 透過內部審計歷史縮減 scope | −$25K | −$15K | −$0（審計方堅持完整 scope） |
| (d) 創辦人 gap-fill 上限 | $0（資金堆疊已覆蓋全價） | $0–$15K | **$15K（達上限）** |
| Worst case 結果 | — | — | **剩餘 $35–$135K 資金缺口；啟動 Options A–D** |

**Worst case 不是「創辦人自掏 $100–$150K」。** 在 volunteer-builder 框架下，worst case 是「(a)+(b)+(c)+(d) 都表現不佳，使 $35–$135K 的資金缺口超過 $15K gap-fill 上限，V1 走 Options A–D contingency tree 而非按原訂時程上 mainnet」。這與 v1.3 時期「創辦人自籌無上限擴張」的 worst case 有本質差異；這裡創辦人承諾被**封頂在 $15K gap-fill**，worst case 由**專案本身**（而非 founder 銀行帳戶）吸收短缺（延後 / 縮 scope / 募資 / 停留 Preprod）。

**資金堆疊超出 gap-fill 容量時的 contingency tree。** 若 2027 Q1 之前 (a)+(b)+(c) 已承諾加上 $15K (d) gap-fill 合計仍低於委託審計報價，以下替代方案會**公開**評估、不會悄悄吸收：

- **Option A — 審計時程延後（優先方案）。** 審計推遲至 2027 Q4 或 2028 H1。**V1 在整段期間維持在 pre-audit 100K USDCx mainnet cap 下運作。** 爭取時間給 Catalyst Round 重啟、額外 grant 接洽、或社群資助池擴大。創辦人 $80–$200/年的營運承諾持續；在 pre-audit cap 期間進場的存入者風險側寫不變。Cap 維持 100K；Stage 2+ 進度等審計到位。
- **Option B — 縮減 scope 審計。** 審計範圍縮到「critical-path validator only」（通常是 17 個 logic validator 中安全性最關鍵的 5–7 個）以匹配可用資金。其餘 validator 移到未來 Phase 2 輪審計處理。**V1 mainnet 在此 scope-reduced 審計前、中、後都在 100K cap 下持續運作。** Scope-reduced 審計完成後，可能正當化部分 cap lift（例如 100K → 200K）但不會到完整 Stage 3 lift；任何部分 cap lift 時對存入者揭露 scope-limited badge 是必要程序。
- **Option C — 社群 / DAO 募資。** 一個透明、非股權、非代幣的社群資助池，請 Cardano 社群為審計出資。預先公告預算 + 審計後透明會計 + Apache 2.0 程式碼是唯一「回饋」給贊助者的東西。這在 Cardano 是條真實路徑（Catalyst alternatives + 臨時社群池在鄰近生態系曾資助公共財審計），但取決於社群興趣是否在需要的規模上成形。**V1 mainnet 在 crowdfund 窗口期間維持 100K cap 持續運作。**
- **Option D — 永久 pre-audit 100K cap。** 若 A/B/C 全部落空，**V1 在 mainnet 維持 100K USDCx cap 無限期運作**，不再透過 audit 解鎖 cap。存入者仍可在小規模下取得 permissionless access；協議保持 live、keeper 在 §4.3.1 下持續運作、治理仍然 active、程式碼維持 Apache 2.0 公共財。這是 §0 / §0.2「V1 可能就是 terminal state」結局——V1 在 mainnet 安頓為一個永久小規模公共財 reference implementation，**不是 Preprod-only artefact**。「terminal state」framing 的意思是 cap 從未透過 audit 路徑解鎖、不是 V1 停止運作。**§9.2 sunset** 是另一條獨立路徑，只在 §1.5 Class A overrides（USDCx / Liqwid / Cardano / oracle 事件）或創辦人明確決定下觸發——Option D 本身不會觸發 sunset。

  **Option D 下的存入者風險揭露（針對持續 Option D 運作的特定揭露）。** 「V1 在 100K cap 下、多年無外部審計地運作」這個風險側寫，與「V1 在 pre-audit、但幾個月內審計資金即將到位」是兩個本質上不同的存入者風險側寫。在持續性 Option D 狀態下進場的存入者應該明確理解以下幾點：

  (a) **合約從未經獨立外部審計、未來也可能始終不會被審計。** 對未被發現的 CRITICAL bug 的保護，完全仰賴內部審計累積歷史（v1.4 publication 時約 70+ 輪）+ §5.5.1 三層合約安全（Layer 1 freeze-only EmergencyWithdraw / Layer 2 freeze 下 swap-out / Layer 3 90 天 permissionless CommunitySunset）+ §6.3 validator 強制硬上限。沒有第三方審計背書、也沒有任何承諾說審計會在某天到來。

  (b) **創辦人失能風險在 Option D 下結構上更高**，因為 Option D 把 Phase 1 的單一營運方集中狀態無限期延長，不進入 §6.1 路線圖中 Phase 2 擴張簽名者集合的階段。§5.5.1 Layer 3（90 天 CommunitySunset）作為絕對備援仍然有效——若創辦人停止運作，任何 vUSDCx 持有者可 permissionless 觸發完整自助恢復——但結構保護的形態變成「程式碼層安全、不是人員備援安全」。存入者應據此控制部位規模。

  (c) **外部審計訊號在 Option D 下永久缺席**，這是存入者實質上接受的一項資訊不對稱。在相鄰生態（Ethereum DeFi）「多年未審計、卻仍在生產跑」這個訊號在 OpSec 文化上是負面的，即便有內部審計歷史也一樣。V1 的 Apache 2.0 + §5.5.1 架構在合約層技術上是站得住腳的，但**永久 pre-audit 狀態對外觀感的結果是真實存在的，由存入者透過更窄的曝光面 + 更少的第三方背書承擔**。

  (d) **持續 Option D 下的存入決定，正確的 framing 是「長期接受 pre-audit 風險側寫」**，不是「等待審計到來」。將外部審計訊號視為存入前置條件的人，應把 Option D 當作永久 disqualifier、不應進場；對 §5.5.1 + §6.3 合約層安全設計 + 公共財 reference implementation 定位的價值評估，足以接受審計永久不確定性的人，可以進場——但要對這個 trade-off 充分睜眼。

我們承諾以透明方式處理 funding gap，不會用軟性詞彙包裝過去。在 funding stack 期間，儀表板每月公布 (a)+(b)+(c)+(d) 的承諾與到位狀態，讓存入者與觀察者可獨立評估哪一個方案最可能發生。

**與 §4.1 sunset 觸發條件的聯動——在 volunteer 模型下的釐清。** §4.1 標稱 sunset 條件（"runway < 6 個月 forward burn"）將「runway」解釋為**創辦人營運面承諾**（依 §4.3.1 ~$80–$200/年），不是審計承諾。在 volunteer-builder 框架下，營運 runway 從個人收入持續支撐、結構上**幾乎不可達**作為 sunset 觸發條件；真實的失敗模式是 §1.5 Class A overrides（USDCx / Liqwid / Cardano chain / oracle 事件）與創辦人明確 sunset 決定。**審計資金失敗不是 sunset 觸發條件** — 它只是在 §8.1 Option D 下把 cap 維持在 100K。V1 在四個（A/B/C/D）審計資金結果下都會在 mainnet 持續運作。

**審計時程反映 funding-stack 不確定性。** Q2-Q3 2027 目標明確比原本 Q3 2026 計畫晚，刻意預留時間以容納 (i) Catalyst Round 恢復的概率、(ii) 並行 Cardano Foundation / Intersect / Aiken Foundation grant 接洽、(iii) 若 (a)/(b) 結果保守時，社群 / DAO 資助池路徑（上方 Option C）的成熟時間。**V1 在整個過渡期間於 mainnet 維持 100K pre-audit cap 運作**；若 2027 Q4 仍未讓資金堆疊達到成本門檻，§1.5 Override condition 6 啟動（cap 無限期維持 100K — V1 仍在 mainnet，不退回 Preprod）。審計本身**取決於資金到位，不取決於 calendar 日期**——見上方 §8.1 Options A-D 與 §0.2 funding posture 的 volunteer-builder framing。

各 funding source 進度會在 `docs/economics.md §5.2` 持續更新。這個 stack 讓 V1 可以在不進入 VC / 代幣募資 / 不稀釋 Apache 2.0 公共財立場的前提下完成外部審計。

### 8.2 啟動（TVL 上限 100K USDCx）

**Phase 1 的真正性質——誠實標示。** V1 在 100K USDCx 上限下的啟動是 **對抗性條件下的協議驗證**，不是商業 TVL-scale 發射。100K cap 是**上限，不是目標**。我們內部對 Phase 1 TVL 的預期是**頭 6-12 個月落在 $500-$25K 區間**——這是推測性區間，不是預測，基於保守的使用者取得假設加上 permissionless-only 立場（沒有 closed-beta gate，因此若 organic discovery 緩慢，下限可能極低）；實際結果可能往任一方向顯著偏離。以「填滿 cap」情境為基礎模擬 Phase 1 的讀者，應該知道那並不是我們在規劃的結果。

**Pre-audit 期間的營運姿態。** Pre-audit 階段 V1 不做 marketing 推廣、landing 只維持 organic SEO。合約本身是 permissionless smart contract，任何理解並接受 pre-audit 風險（未知 CRITICAL bug 可能、TVL 不會快速成長、founder bandwidth 有限）的 depositor 都可依自己判斷進入——沒有 invitation gate，沒有 whitelist。但請**誠實預期**：這不是 opening sale 階段，而是驗證階段；想規模化入場或追求最大化 yield 的 depositor 建議等 post-audit cap 解除、或直接選 Direct Liqwid DJED supply。

**Phase 1 TVL 是 range，不是 target。** 早期白皮書草稿假設 Phase 1 TVL 會落在 $5K-$25K，路徑是「closed beta 框架下從 founder 人脈圈招募 ~10-15 位 depositor」。該框架已移除，改為純 permissionless + risk-disclosure。後果是：**實際 Phase 1 TVL 將完全取決於 organic discovery 與個別 depositor 自行的風險評估**，可預測性顯著低於 closed-beta 框架下的預期。可能結果包括：(a) **$500–$5K**（只有 founder + 1-2 位社群 depositor；只要 Phase 1 期間沒出現 CRITICAL bug，仍算成功的 Phase 1，因為驗證目的已達）；(b) **$5K-$25K**（先前的預期，現在視為中段情境）；(c) **$25K-$100K**（高於預期；會觸發 frontend 加強警示提醒 pre-audit 風險密度，但不會有合約層額外限制——既有的 100K cap 仍是唯一硬上限）。三種結果都是 Phase 1 可接受的結尾，沒有任何一個本身代表「失敗」。Phase 1 成功與否以下方 (a)-(d) 成功準則衡量，不以 TVL 規模衡量。

**Sub-scenario 對應的營運模式、SPO 姿態、對外 framing。** v1.3 把這個對應明確寫出來,讓存入者可以直接從表中讀出「我現在所處的 sub-scenario 是哪一個」:

| Sub-scenario | TVL 區間 | 預期存入者數量 | 營運模式 | SPO 治理姿態 | 審計 / 對外 framing |
|---|---|---|---|---|---|
| (a) 個人 reference | $500–$5K | 創辦人 + 1–2 位社群 | Reference Implementation Mode(§2.6.1)——季度到年度 Compound | 延後 / 象徵性 | 「Cardano reference vault 實作」 |
| (b) 小規模有機成長 | $5K–$25K | 5–20 位存入者 | Reference Implementation Mode(§2.6.1)——隨 TVL 接近 $25K 停用門檻,節奏自動往月度–雙週 Compound 偏 | 可選擇性招募 SPO,並完整揭露工作量 | 標準非商業公共財 framing |
| (c) Phase 1 接近 cap | $25K–$100K | 20–100 位存入者 | §2.6 預設節奏(週六排程 Compound) | 完整 3-of-3 SPO 席位 active | 標準產品審計 framing |

每一個 sub-scenario 都是 §8.2 成功準則 (a)–(d) 下可接受的 Phase 1 結尾。模式之間的切換,屬於 §4.5 裁量下的 keeper 營運政策,**不**需要治理動作——除非 TVL 反覆來回跨越門檻(若如此,就值得用 `UpdateStrategy` 把切換條件正式編入規範)。

若 V1 在 sub-scenario (a) 啟動,然後在 6–12 個月內有機成長到 (b),keeper 會在儀表板上公告模式切換,讓存入者透明看到節奏調整。若 TVL 從 (c) 收縮回 (b)(例如出現較大的提領),keeper 以相同公告方式反向切換。這是設計上預期的彈性行為,**不是**運作異常的訊號。

這個姿態基於同時存在的兩項事實：

1. **$135K–$1.8M 自給 TVL 區間(baseline 約 $500K)依定義是 §2.6 預設節奏下的 Phase 2+ post-audit 目標。** 在 $100K cap 時代無法到達。Pre-audit TVL 成長超過 ~$25K 會超出存入者應接受的風險範圍。
2. **Pre-audit 誠實的成功準則不是「填滿 cap」：**
   - (a) 審計期內已部署合約無 CRITICAL 被攻擊
   - (b) 自動化系統（keeper + API + 前端）在真實使用者流量下以「有意義但仍小規模」正確運作
   - (c) 透過透明的治理行動 + 公開事故史建立社群信任
   - (d) 交接給外部審計方一個真實運作、審計方可實際壓測的系統

達成全部四項、TVL $15K，是 **成功的 Phase 1**。達成 TVL $80K 但四項有任何一項未驗證，是 **被數字掩蓋的失敗**。

**Phase 1 啟動的操作面：**

- V1 mainnet 部署儀式（約 42 筆 TX：3 個一次性 ceremony NFT 鑄造（Vault Identity / Governance / Registry Auth）+ 20 筆 reference-script 發佈（17 個 logic validator 的 ref script + `minswap_v2_adapter` + 2 個 SundaeSwap artefact，每筆 TX 發佈一個 ref script）+ 14 筆 stake-credential 註冊 + 5 筆 state-UTXO 初始化（vault / registry / governance / treasury / keeper_stake）；gov_signer_nft 隨簽名者加入時逐次鑄造，不計入這 42 筆）
- 公開宣告 + 內部驗證期存入者遷移窗口
- 前 100 個遷移錢包：早提領費由審計儲備補貼
- **對外溝通的基調**:訴求明確是「歡迎小額存入協助在真實條件下驗證系統」——V1 不是高收益獵取的管道。這個 signal 是為了避開那些追求 yield 最大化、本來就該走 Direct Liqwid DJED 的使用者;他們直接用 Liqwid 對他們更有利,不是 V1 挑剔他們。

**部署儀式部分失敗處置。** V1 部署儀式大約是 42 筆交易的序列：先鑄三個 one-shot NFT（Vault Identity、Governance、Registry Auth），接著發佈 **20** 個 reference script（17 個 logic validator + `minswap_v2_adapter` + 2 個 SundaeSwap artefact，每筆 TX 一個），接著註冊 14 個 stake credential，接著初始化 Registry + Governance + Treasury + Keeper Stake 四個 UTXO，最後才初始化 vault UTXO 自身。每一筆 TX 都是 idempotent-safe：每次成功後 state 會 checkpoint 到本地 JSON，部署腳本重跑時會從上次的 checkpoint 續行。部分失敗不會留下破碎狀態——進行中的儀式把 reference script 和 identity NFT 暫留在部署錢包地址，直到 vault UTXO 初始化 TX 完成為止。唯一不可恢復的失敗情境，是「已鑄的 one-shot NFT 其部署時 validity range 到期前儀式沒跑完」；應對方式是以新的 `RELEASE_TAG` 跑一次全新儀式，並另外用一筆 sweep TX 把孤立 reference script 裡鎖住的 ADA 回收回來。完整 runbook：`docs/runbooks/v1-mainnet-ceremony.md`（隨 V1 實作一併發佈）。

**Reference-script 資本鎖定。** V1 的 17 個 logic validator 加上 `minswap_v2_adapter` SwapAdapter 與 2 個 SundaeSwap artefact 每一個都以 Cardano **reference script UTXO**（CIP-33）形式發佈到部署錢包地址。Reference script 帶有 Conway-era 的 min-ADA，隨序列化 script 大小而增；以當前協議參數加上 operator 的 1.10× safety multiplier，~5.6 KB 的 proxy script 鎖 ~29 ADA，~10 KB 的 validator 約 50 ADA，最大的 ~14 KB validator 約 70 ADA。20 個 reference script（17 個 logic validator + `minswap_v2_adapter` + 2 個 SundaeSwap artefact）合計，V1 部署大約鎖定 **962 ADA（以近期 ADA 市價估算約為低三位數美元）** 作為 reference-script min-UTXO。（V1 Preprod 部署實測為 962.07 ADA。）此外還有 **28 ADA 的 stake credential 押金**（14 個 staking validator × 2 ADA each，全部可在 14d governance timelock 後透過 A2 deregister `publish` handler 回收，見 §6.2）。儀式總資本承諾：**~990 ADA 可回收**，加上 ~22 ADA 不可回收的網路 TX fees + ~27 ADA 的 state-UTXO 種子 ADA（vault / registry / treasury / keeper-auth / governance script address），合計 **~1,039 ADA** 在儀式結束時。部署錢包地址持有 20 個 ref-script UTXO——它們是每次 vault TX 的**可花費 reference input**，但**除非花掉 UTXO 本身（會停用該 reference script），否則無法回收**。V2 遷移計畫：新版本部署時，V1 的 reference script UTXO 會被一次性 reclaim TX 花掉並取回，鎖定的 ADA 扣掉每次儀式約 2.5 ADA 的 TX fee 後回到部署錢包。部署錢包簽名 key 由啟動實體持有；此處明確揭露，讓存入者知道 ~962 ADA 的啟動資本於部署當下承諾於 V1，僅在 sunset / V2 遷移時才能取回。

### 8.3 啟動後里程碑

| 里程碑 | 觸發條件 | 動作 |
|--------|----------|------|
| 外部審計完成 | 審計方簽核 | 將 TVL 上限提升至 1M USDCx |
| TVL 達 500K | — | Phase 2 治理輪替（加入外部簽名者） |
| TVL 達 2M | — | Phase 3 輪替（社群簽名者） |
| TVL 達 5M | — | 評估 `PermissionlessWithBond` keeper 開放 |
| TVL 達 10M | — | 考慮 DAO 遷移探索 |

里程碑是目標，非承諾。實際時程取決於審計可用性、市場條件、社群準備度。

### 8.4 遷移穩定性里程碑

V1 想達到的具體里程碑：**V1 連續 12 個月運作無遷移或重新部署**。先前內部部署（V1 → internal-verification era）經歷多次重新部署以修復合約 bug。V1 的目標是保持同一部署 hash 12 個月——成熟度指標。

若重大 bug 需 V2，遷移依 `docs/migration.md` 文件化的相同全新部署模式。

---

## 9. 誠實的界線

### 9.1 V1 不是什麼

- **沒有保險。** V1 不保本，智能合約 bug、Liqwid 壞帳、USDCx 脫鉤都可能造成損失。
- **啟動時還不是去中心化的。** 創辦人同時負責 keeper 運作、持有治理席位、並控制部署錢包。V1 是公開發佈的創辦人自行運作的軟體，不是 DAO。
- **不以任何代價追求最大收益。** V1 不會為了拉高 APY，把存入者推到治理代幣波動或跨鏈橋風險上。
- **不是財務建議的替代品。** 存入者必須自行評估風險承受度。

### 9.2 V1 的承諾

- **原始碼在主網啟動前公開。**
- **審計報告完成時公開。**
- **治理動作公開透明**——每個 QueueAction 於 1 小時內對外公告，鏈上歷史即為正式紀錄。
- **結束協議透明**——若 §4.1 的 4 個 sunset triggers 任一觸發（A：post-audit 6 個月後 TVL < $500K，**前提是審計發生**；B：營運 runway 耗盡；C：Class A override 持續；D：創辦人明確決定），90 天通知 + fee 歸零 + Liqwid 部位預先 recall 前置條件適用，依 §4.1 sunset 機制，加上 `EmergencyWithdraw` 治理路徑 + `emergency-withdraw` 自助工具。**硬失敗備援**：即使創辦人和任何 SPO 共簽者連續 90 天完全聯絡不上，任何 vUSDCx 持有者都可呼叫 permissionless 的 `CommunitySunset` redeemer（vault_user）原子性凍結金庫 + 開放 permissionless 的 `RecallFromLiqwid` + swap-to-USDCx 路徑，讓存入者完整自助回收——見 §5.5.1 Layer 3 + `docs/security-model.md` §5.4 情境 E。**注意**：持續性審計資金缺口（§8.1 Option D）**不是** sunset 觸發條件——它讓 V1 在 mainnet 維持 pre-audit 100K cap；wind-down 協議在該情境下不啟動。
- **架構上不設計「抽乾資金跑路」（rug-pull）的後門。** 任何可能抽乾資金的不變式都在 validator 層封閉，不留給社會信任層。
- **創辦人失能應對（Founder incapacitation protocol）。** V1 啟動時創辦人同時擔任 keeper operator、治理簽名者（在配置 (a) SPO 已招募下為 1-of-3；在基本案配置 (b) 下持有全部 3 席，見 §7.4）、ref-deployer wallet 控制者，個人層級單點故障是真實的。應對機制：(a) **短期失聯（< 7 天）**——合約層 7 天 keeper inactivity 窗口自動生效，Direct Withdraw 路徑完全可用且 early-withdraw fee 免除；(b) **中期失能（7-30 天）**——在配置 (a) 下，2 位獨立 SPO 可透過 `UpdateKeeperAuth` 治理動作（14 天 timelock + 1-of-n cancel）把 keeper PKH 切換到社群接手者；在配置 (b) 下，創辦人 HD-key 分隔的簽名環境提供一部分備援，若全部失效則退到下方 (c) 路徑；(c) **營運補貼停付但未正式 sunset**（v1.4 volunteer 模型下的真實場景）——創辦人健在、但停付 ~$80/年的基礎設施補貼、且未依 §9.2 正式啟動 sunset。後續鏈：keeper 離線 → §5.4 7 天 inactivity gate 自動觸發（early-withdraw fee 免除）→ Direct Withdraw 仍可用 → vault 進入「founder-keeper 離線、合約仍 live」的混合狀態，直到 90 天 §5.5.1 Layer 3 `CommunitySunset` 可由任一 vUSDCx 持有者觸發完成自助恢復。這條路徑在 v1.4 volunteer-operator 模型下實際存在，此處明寫讓存入者知道恢復**不需要創辦人配合**；(d) **永久失能**——配置 (a) 下由 2 位 SPO 觸發 §4.1 sunset path（90 天預告 + fee=0 + 存入者自助退場）；配置 (b) 下，§5.5.1 Layer 3 `CommunitySunset` 在 90 天時是絕對備援。Ref-deployer wallet key 目前由創辦人獨自控制，若此 key 遺失或無法存取，**~962 ADA** 的 ref-script 資本 + **~28 ADA** 的 stake-credential 押金會永久鎖定（對應 §8.2 實測 962.07 ADA + 14 × 2 ADA）——但**不影響存入者提領**，因為 ref-script 仍可作為 reference input。V2 部署儀式會納入 multi-sig ref-deployer wallet 或社群 key escrow 機制消除此 SPOF。

### 9.3 仍然可能出錯的地方

即使多輪內部審計已經處理掉目前發現的問題，下列情況仍然可能發生：

- **V1 獨有的新範圍**（treasury、keeper_stake_script）在外部審計前仍可能存在未知漏洞
- 利用尚未考慮過的交互關係的**新型攻擊**
- **外部協議失效**（Liqwid、Minswap、Circle / xReserve / USDC）級聯影響到 V1

100K 上限不是一個建議值——它是對「V1 是尚未經外部審計的生產軟體」的明確承認。

### 9.4 V1 已知限制(公開揭露,不藏著)

- **V1 全部 14 個 staking credential 的 2 ADA stake 押金都可回收**（canonical 名單見 §6.2 `ActDeregisterStake`）。每個都帶自己的 A2 治理閘門 `publish` handler — sunset 時可透過治理流程合計回收 **28 ADA**（14 天 timelock + 1-of-n cancel）。其中 10 個是 §3.2 的 vault-proxy Withdraw-Zero 路由；另外 4 個 — `keeper_stake_script`、`minswap_v2_adapter`、`sundaeswap_adapter` 與 `sundaeswap_cancel_guard` — 各自有獨立的 staking credentials 以維持委託獨立性，**不**走 vault-proxy 分派。早期 monolithic-validator 拓撲因 16 KB ceiling 與 `publish` handler 的 bytecode 衝突，最大 validator 曾有 2 ADA 永久鎖定的 caveat；現在的 partitioning 已經解除這個限制，詳見 `spec/architecture.md §4.1`。
- **100K TVL 上限「不」在合約層強制** — 由 operator 透過前端存入 gating + keeper `tvlCapMonitor` 告警執行。這是 V1 刻意的設計選擇，不是疏漏。內部審計曾設計過合約層版本（`max_tvl` datum field + `ActUpdateTvlCap` 7 天 timelock 治理動作，當時稱 Option B），最終沒出貨，理由有二：(1) 上限的存在意義只在 pre-audit 期作為審慎訊號；外審通過後要嘛放寬無限、要嘛 V2 重部署時拿掉，合約層動態調整機制對「一次性生命週期事件」是過度工程。(2) V1 啟動雖為 3-of-3 unanimity 搭配 1 位創辦人 + 2 位獨立 SPO（§5.5），3-of-3 能擋下創辦人單方 queue，但上限調整的「正確性」判斷並非 SPO 的核心領域（他們是 stake pool 營運者，非 vault 經濟模型設計者）；在 pre-audit 期把上限交給 SPO 裁決也不是真正的制衡關係——誠實標記為「operator-enforced」比裝扮成「contract-enforced」更有品格。希望多一層合約層存入上限保護的 存入者，請等 Phase 2 gov 輪替（外部 signer 加入，§6.1）——屆時才有實質 dissent-veto 語意，V2 會重新評估。
- **Reference-script 資本鎖倉。** V1 的 20 個 reference script UTXO（17 個 logic validator + `minswap_v2_adapter` + 2 個 SundaeSwap artefact）部署在 deploy wallet 地址，合計佔用約 **962 ADA**（Conway 時代的 per-byte `minFeeRefScriptCostPerByte` × 1.10× operator safety multiplier — V1 Preprod 實測為 962.07 ADA），若 operator 決定 sunset 部署可透過 `deploy/tools/reclaim-refs.ts` 回收。此外還有 28 ADA 的 stake credential 押金（14 × 2 ADA）可透過 A2 governance 在 14d timelock 後回收。詳見 §8.2 的 pre-launch 審計背景。
- **架構複雜度成長。** V1 第一版是 12 個 validator；目前拓撲是 **24 個 artefact**（17 個 logic validator + 4 個 NFT mint policy + `minswap_v2_adapter` + 2 個 SundaeSwap artefact），是被 Plutus V3 16 KB reference-script 上限 + §5.4 P3-P5 滑點 stack 新增推動的。每加一個 validator 就增加 (a) 一個獨立的審計範圍面、(b) 一組額外的 compile-time anchor、(c) 一個額外的 reference-script UTXO（目前參數下平均每個約 48 ADA）、(d) 一筆額外的 deploy ceremony TX。對首次部署的淨效果：ref-script 鎖定從早期估的 ~400 ADA 增加到實測的 962.07 ADA（+140%），ceremony TX 從 ~18 增加到 ~42（+133%）。對外部審計預算的影響：**14 個 staking-credential 的 A2 `publish` handler 都需要單獨接受審計**（不像之前 single-validator vault_core lock 的情境是被歸在審計範圍外），所以「解除 vault_core 2 ADA 永久鎖定」是用「擴大審計表面」換來的。未來 feature 加入有可能再觸發拆分——一個 V1 cycle 內從 12 → 24 的 trajectory 暗示 V2 需要 (a) 接受更高 artefact 數作為新 baseline，或 (b) 用 on-chain dispatch table 整合。V1 明確選擇 (a)，因為 design freeze → audit → launch 的順序不允許在後期重新調整架構；V2 會重新評估。
- **Circle / xReserve 信任鏈。** USDCx 的價值依賴 Circle 的 USD reserve 完整性 + xReserve 跨鏈橋安全。兩者各自由其團隊公開審計;V1 不在此之上多加信任假設。

這些限制在這裡明文揭露,不藏進 spec 深處,因為 存入者 應該知道 V1 實際能做到什麼、邊界在哪裡——而不是被高階摘要或對外表述誤導。

---

## 10. 可重現性

V1 的原始碼真實來源是開源鏡像 https://github.com/OptiVaults/optivaults-protocol （這份鏡像對應私有開發儲存庫；依 §9.2 於 V1 主網啟動時發佈）。鏈上發佈的每一個 validator hash，都可以從原始碼重新產出：

```bash
aiken --version    # 必須與下方鎖定的版本一致
aiken build        # 產生 plutus.json
scripts/verify-hashes.sh  # 比對 plutus.json 的 hash 與鏈上部署
```

**工具版本鎖定**（要讓 hash 位元完全一致，這一步不能省——Aiken 的 optimizer 輸出對版本很敏感）：

| 工具 | 鎖定版本 | 理由 |
|------|----------|------|
| Aiken compiler | **v1.1.x**（在最終審計 commit 當下鎖定確切 patch 版本） | Plutus V3 的 cost-model 在 patch 版本之間會變動，進而改變 exec-unit 的 hash |
| aiken-lang/stdlib | 與該版 Aiken release 對應 | 模組命名空間可能隨版本調整 |
| aiken-lang/fuzz | v2.2.0 | property-based 測試的重現性 |

精確的 `aiken` patch 版本鎖定在儲存庫的 `.tool-versions` 檔，並於審計報告中再次確認；任何第三方都能從審計 commit 的原始碼，重現出已部署的 hash。

公開儲存庫裡的部署腳本與 runbook 讓任何營運者都能獨立驗證：鏈上的部署 hash 與網站標註的 commit 原始碼一致。

治理的每一筆 QueueAction 的 payload hash，也都可以從 CBOR 反推——存入者因此可以自行確認：比如一筆剛排入的手續費變更，對應的實際數值與鏈下公告的內容吻合。

---

## 11. 相關文件

**規格（位於 `spec/`）**：

- `architecture.md` — **17 個 logic validator** 目錄與 redeemer 細節（+ 4 個 one-shot NFT mint policy + `minswap_v2_adapter` + 2 個 SundaeSwap artefact = 合計 24 個 artefact）；§4.1 說明 partitioning rationale（4 個正交切割面：authorization-boundary / response-latency / bytecode-cost-center / size-fix）
- `vault-datum.md` — VaultDatum schema（**29 欄位**，§5.4 Phase 2 + Phase 1 治理安全;原 26 欄位上加入 `max_slippage_bps` + `min_swap_peg_bps` + `community_sunset_triggered`）、不可變 / 治理可變 / 操作可變分類、每個 redeemer 的 state-transition 矩陣
- `governance.md` — 15 個 queue 走治理流程的 ActionKind（完整表格見 §6.2；包含 `ActDeregisterStake`，作為 operator 端的 stake 押金回收路徑），外加 3 個 direct/非 queue redeemer（`KeeperToggleMarket`、`Heartbeat`、`DistributeSignerCompensation`）；timelock 下限、啟動簽名者集合與輪替路線圖
- `multisig-gov.md` — MultisigGov validator 內部細節、action_id / payload_hash 計算、`is_gov_authorized` 跨 validator helper
- `gov-nft.md` — Gov Signer 靈魂綁定 NFT 鑄造政策（僅作聲譽、不可轉讓）
- `keeper-auth.md` — `keeper_stake_script` 狀態機、週輪替、A-Plain 授權、PermissionlessWithBond 模式
- `treasury.md` — TreasuryDatum schema、4 類預算、Receive / Spend / ReceiveGovForfeit / UpdateParams redeemer
- `order-batch.md` — OrderDatum + BatchProcess、pre-batch snapshot 定價、使用者自訂 batcher tip
- `ada-swap.md` — SwapAda redeemer(金庫 ADA 補充閉環)、Charli3 + Orcfax oracle 讀取
- `vault-nft.md` — Vault Identity NFT 的 PlutusV3 UTXO-ref one-shot 設計
- `swap-adapter.md` — SwapAdapter 介面(Tier 2 peg-floor decoder、order datum 逐 byte 驗證;`minswap_v2_adapter` 加上 §8 的 SundaeSwap adapter 一對;§3.4、§5.4 P4 引用)
- `rebalance-policy.md` — 完整再平衡演算法(slippage 預算、DEX 路徑選擇、頻率限制;§2.5 高階機制描述的規範性來源)

**文件（位於 `docs/`）**：

- `security-model.md` — 對手方分類、六身份分離目標、攻擊面清單、殘餘風險總整
- `economics.md` — 三方手續費分拆數學、TVL 分層預測、啟動期揭露、簽名者補償機制
- `migration.md` — 內部驗證期使用者遷移到 V1 的指引
- `audit-scope.md` — 內部覆蓋領域 A–F + 外部審計計畫
- `integration-playbook.md` — 加入新 DEX 路徑 / Liqwid 市場的 7 步 SOP（Type A/B/C/D）
- `contributor-program.md` — 開源貢獻者獎勵（Phase 2+ 啟用）

**其他語言**：

- `whitepaper/whitepaper.md` — 英文版本

---

## 12. 免責聲明

**Non-investment product / non-solicitation。** V1 是 Cardano DeFi 公共財 reference implementation（見 Executive Summary 的定位宣告），**不是投資產品、不是 fund、不是 managed service**。4.5% Performance fee 覆蓋協議運營與 treasury 累積（審計儲備 / R&D / buffer）；**沒有股權、沒有代幣、沒有對投資人的分配**。**Keeper share 的揭露**：績效費 40%（約佔收益 1.8%）流入 keeper 錢包作為營運補償；由於 V1 啟動時由創辦人運作 keeper（§7.4），**確實有 USDCx 流入創辦人的 keeper 錢包**（100K cap 下年化 ~$108；§8.2 所列實際 Phase 1 sub-scenario 下 < $30/年）。**即便在 §4.3.1 minimal-operations footprint（~$80/年基礎設施 + 鏈上 fee）下這條收入仍不夠覆蓋 keeper 自身基礎設施**，所以這個位子對創辦人來說是**淨成本中心、不是利潤線**——缺口由創辦人從個人收入持續吸收（§4.3.1 cost-scaling 表），不是從預先撥定的啟動資金 runway 中扣除。誠實的解讀是：沒有股權式利潤分配、沒有代幣，但有一條不足以支付自身成本的小額 USDCx 收入線。§0 + §0.2 + §4.3 + §4.3.1 + §7.4 完整揭露結構。本白皮書是對 V1 設計與啟動條件的**事實描述**，不構成投資建議、不構成任何形式的招攬。智能合約存入本身涉及全部損失的風險。

**Geographical posture。** V1 是 Cardano 鏈上 permissionless 智能合約，技術上任何持有 Cardano 錢包的人都可以互動。但 V1 是為 Cardano 原生使用者設計，**不主動提供服務給任何法域的居民**。存入者必須**自行判斷**其所在司法管轄區（特別是美國、歐盟、英國、中國、OFAC 制裁名單國家）是否允許使用非託管 DeFi 公共財 infrastructure；合規責任由存入者自負。V1 的前端（optivaults.app）可能基於法律意見在特定法域**顯示警告或阻擋存取**；這是**純前端 soft signal**，不限制底層鏈上智能合約——使用者若繞過前端直接與合約互動（例如透過 `withdraw-cli` 或自建 TX），完整自行承擔該法域合規責任。**V1 合約本身不做地址白名單或地理限制**，這違背 non-custodial + permissionless 設計本質，也不在 roadmap 內。任何前端 geoblock 變動會於公開 channel（optivaults.app + Discord）通知。若你所在法域明確禁止使用非託管 DeFi 或未登記金融服務,**不要使用 V1**——即使技術上繞過前端做得到。

**Code-is-law 姿態。** V1 是 open source / Apache 2.0 / 部署後 validator hash 永久不變。存入者存入時即接受「合約在鏈上以其部署時的形式執行」——沒有任何個人、團隊或治理動作能修改合約邏輯本身(治理只能在合約授權的 parameter 範圍內調整)。若合約 bug 導致損失,自助 `emergency-withdraw` 工具是唯一恢復路徑;**無任何法律追索可讓已確認的鏈上 TX 逆轉**。這不是 bug,是 V1 的核心設計選擇——你的資金不被 intermediary 掌控的代價是 intermediary 無法為你恢復意外。

**Depositor 自行盡職調查。** 存入者必須自行對 OptiVaults V1、USDCx(Circle / xReserve)、Liqwid、Minswap V2、Cardano 協議本身做完整 due diligence。**任何「V1 為我管理風險」的期待都是誤解定位**——V1 只是將風險公開、分散、並在架構上讓你隨時可退場(見 §5 Risks 完整揭露 + §6.3 治理硬上限)。V1 不是 insurance、不是 advisory service、不是 wealth manager。

**聯絡資訊。** 安全揭露(PGP key 見 optivaults.app/security)、遷移補貼申請、一般諮詢:`optivaults@gmail.com`。即時討論請到 Discord(連結於 optivaults.app)。

---

## 變更紀錄

### v1.4.2 — 2026-05-14

**新增**
- §5.1.1 對抗性鏈上重放覆蓋 — 新增子章節，把手工構造的攻擊交易在 Preprod ceremony build 上實測過的防禦層做語義分類。九大類別（金庫主 UTXO spend / 用戶路徑 / Keeper 路徑 / 協議路由 / Mint policy / Order 分支 / Multisig 治理 / 緊急與費用治理 / CIP-69 purpose 隔離）外加份額價格不變式的原碼審查說明。明確列出「鏈上重放並未涵蓋的部分」（外部系統失敗、keeper 私鑰妥協情境、特定 Preprod build 狀態假設），並揭露一類刻意延後的測試（`UpdateRegistry` 注入假 Liqwid `action_addr_hash`——已由 `lib/vault/tests/` 的 Aiken unit test 涵蓋）。

**語氣**
- §5.1.1 把方法論定位為單元測試 + property 測試 + 外部審計的補強，不是替代；強調主要的安全訊號仍然是即將到來的外部審計報告。不做「X 個測試通過」這種量化承諾；改以防禦層分類呈現，並指引讀者到 `tests/preprod/` 回歸測試腳本去自行重現。

### v1.4.1 — 2026-05-12

針對 v1.4 的內部一致性修訂。無框架變更——v1.4 的 volunteer-builder + audit-as-cap-lift-gate 模型維持不變；本修訂清除三段（§4.1 / §1.6.1 / §7.4）中 v1.4 重寫未替換到位的 v1.3 殘留措辭、並收緊跨段對齊。

**對齊 volunteer-builder 資金模型**
- §4.1 — 移除散落於五個段落（Phase-1 期望重設、sensitivity 表結尾、$25K–$500K gap、Executive Summary keeper-share disclosure、§12 Disclosure keeper-share）的「18 個月 runway 涵蓋 development + 審計 + 6 個月 post-audit 爬坡」描述。五處全部改為依 §4.3.1 描述營運缺口由創辦人個人收入持續補貼吸收，而非從一筆預先撥定、規模涵蓋審計預算的 runway 中扣除。
- §4.3 + §5.4 — 同步對齊「審計成本流經 §8.1 資金堆疊、不是創辦人 runway」。
- §1.6.1 — 移除「不走 launch first audit later」措辭——該句與 §0 + §1.5 + §8.1 的「pre-audit mainnet 啟動 + 審計通過後解鎖 cap」新結構直接衝突。cross-ref §0.2 + §8.1。

**與 Executive Summary 對齊**
- §7.4 — 現在先講基本案配置 (b)（創辦人運作 keeper、以 HD-key 分隔持有全部 3 席治理簽名者），再講配置 (a)（創辦人 + 2 位獨立 SPO）為 stretch target。順序與 Executive Summary「存入者啟動時應假設配置 (b)」對齊。
- §8.1 Option D — 新增持續性 Option D 運作（永久未審計、mainnet 100K cap）下的存入者風險揭露：(a) 永久未審計的含意、(b) 在無限期單一營運方配置下升高的創辦人失能風險、(c) 外部審計訊號永久缺席作為真實資訊不對稱、(d) 將情境 framed 為「長期接受 pre-audit 風險側寫」而非「等審計」。

**Cross-reference 補齊**
- §4.5 開頭加適用範圍說明：「§4.5 適用於 post-cap-lift Default-cadence 成本輪廓；Phase 1 sub-scenario（$500–$25K TVL、走 §2.6.1）的成本見 §4.3.1」。
- §9.2 新增 (c) 場景：創辦人健在但停付 ~$80/年營運補貼、未正式啟動 §9.2 sunset。完整復原鏈描述（§5.4 7 天 gate → Direct Withdraw 仍可用 → 90 天 §5.5.1 Layer 3）。
- §5.5.1「實務上的意義」段落補上 subsidy-cessation 作為「金鑰被盜」與「失能 90+ 天」之間的中間層。
- §8.1 (a) 段落改為描述 Catalyst + Cardano Foundation + Intersect Member Committee + Aiken Foundation 為四個並行 grant channel，與資金堆疊表的「合計樂觀 $80–150K」一致。
- §0 Phase 2 + §9.2 創辦人失能段落 — 治理簽名者描述改為以 (a)/(b) 配置為條件的措辭。

### v1.4 — 2026-05-12

**新增**
- §0.1 — 明確揭露既有內部驗證期 mainnet 部署（前端 founder-allowlist gating、零第三方存款、pre-V1 合約迭代）與本白皮書 V1 設計的關係。包含 V1 mainnet ceremony 前的清空時程（ActDeregisterStake × 4 staking-cred queue → 完整 vault drain → ref-script reclaim）。
- §0.2 — 資金姿態宣告：V1 為 volunteer-built，創辦人承諾上限明確（~$2K seed + 年化 $80–$200 營運補貼 + ~$15K 審計 gap-fill 上限）。外部審計由 §8.1 四來源資金堆疊資助，**不**由創辦人 underwrite。
- §4.3.1 — Post-launch minimal-operations 政策：$500–$25K TVL 採 §2.6.1 下年化 ~$80 預算、依 TVL 變動的成本表、$50K TVL 才升級 HA 的單一伺服器門檻。營運缺口由創辦人個人收入吸收，非從預先撥定的啟動資金儲備扣除。
- §1.4 Lenfi 段落加上 citation pointer（Lenfi 官方 2024 年 12 月事後揭露 + DefiLlama 協議 TVL history），並註明數字為外部公開資料快照、可能變動。

**取代**
- 摘要治理段落 — 兩種配置在相同合約保證下並列：(a) 3-of-3 with 獨立 SPO（stretch target，前提是招募完成）與 (b) 創辦人控制 + HD-key separation（基本案，依 §7.4 對應 Phase 1 小 TVL）。依 §8.2 的 $500–$25K Phase 1 TVL 預估，存入者啟動時應預設配置 (b)。存入者的回收能力**不取決於哪種配置在運作**，而取決於 §5.5.1 的三層合約安全機制。
- §1.5 Override conditions 拆為 Class A（完全阻擋啟動——外部基礎設施失敗：Liqwid / USDCx / Cardano chain / oracle 事件）與 Class B（只把 cap 維持在 100K——審計未通過或審計資金未到位）。V1 在現有 100K cap 下以 pre-audit 上 mainnet；Class B 只 gating Stage 2+ 進度。
- §1.5 Override condition 3 — 改為「USDCx 發行方（Circle，透過 xReserve 智能合約與 IOG 部署的 Cardano-side 整合）」，把 Circle（發行方）與 IOG（Cardano-side 整合者）分清楚。
- §4.1 sunset trigger 重組為 4 條明確 conditional triggers：Trigger A（post-audit TVL < $500K，前提是審計發生）、Trigger B（營運 runway 耗盡，依 §4.3.1 結構性不可達）、Trigger C（Class A override 持續）、Trigger D（創辦人明確決定）。審計資金失敗**不是** sunset 觸發條件——它只是讓 V1 在 mainnet 上維持 §8.1 Option D 的 100K cap。
- §4.5 weekly tier 段落 — 較低 Compound tier 描述為 keeper 在 vault 處於該 TVL 區間任何期間的實際運作政策（特別是 Phase 1 小 TVL sub-scenario 與 §2.6.1 Reference Implementation Mode），而非「legacy scheduling 分支」。
- §6.2 治理動作列表 — 改為依 timelock 排序的表格（最短 Timelock | ActionKind | 類別），下方額外標注三個 direct / 非 queue redeemer（KeeperToggleMarket、Heartbeat、DistributeSignerCompensation）。
- §8.1 funding stack — (d) 創辦人承諾改為 ~$15K gap-fill 上限，**不是** underwriter。Worst-case 不再是「founder 自掏 $100–$150K」而是「Options A–D cap-lift contingency tree 啟動」：A（審計時程延後）、B（scope-reduced 審計）、C（社群 / DAO crowdfund）、D（mainnet 永久 pre-audit 100K cap）。所有四個 option 都讓 V1 留在 mainnet；只決定 cap-lift 路徑。
- §8.1 啟動前門檻拆為兩個 checklist：(i)「100K pre-audit cap 下上 mainnet 所需」（內審 + Preprod E2E + dry-run + Class A overrides 清除 + axis One-Yellow）、(ii)「解鎖到 Stage 3 所需」（外部審計通過 + findings 修復 + axis All-Green）。外部審計從 launch-gate 移到 cap-lift-gate。

**Phasing**
- §0 — 3-phase 模型擴為 4 phases：Phase 1（Pre-Catalyst、僅 Preprod）、Phase 2（Pre-Audit Mainnet，Stages 1 / 1.5 / 2，cap $10K → $100K）、Phase 3（Audit + Cap-Lift 窗口，與 Phase 2 並行）、Phase 4（Operational，Stage 3+ post-audit）。
- §1.5 Stage matrix 加入「是否需審計」column：Stages 1 / 1.5 / 2 標 No（pre-audit），Stage 3 標 Yes（post-audit）。Stages **不**由時間 gating，依 axis state 與審計結果推進。

**修改**
- §5 + §9.2 — 移除逐字列出 14 個名字的 `vault_user / vault_keeper_hot / ...` 列表；兩處皆 cross-reference §6.2 ActDeregisterStake 的 canonical 名單。「28 ADA / 14 × 2 ADA each」數字揭露在四個 load-bearing 上下文（§8.2 ref-script 鎖定、§9 創辦人 incapacitation、§9.2 sunset、§9.4 honest-limits）保留。
- §1.6 — origin-story 結尾句改寫，避免與摘要段落字面重複。
- §0.1 disposition 段落 — 「V1 mainnet ceremony」明確為「V1 pre-audit mainnet launch ceremony（依 §0 為 Phase 2 entry；依 §1.5 為 Stage 1 / 1.5 / 2 啟動）」，使 ceremony framing 對 pre-audit 時序的指涉明確。
- §9.2 wind-down 協議條目 — 明列 4 條 sunset triggers（A 標註為審計條件相依），並加註腳：持續性審計資金缺口（Option D）**不是** sunset 觸發條件。

**語氣**
- 「V1 將在 mainnet 上以 pre-audit 100K USDCx 硬上限 + 顯眼風險揭露啟動」取代 v1.3「100K cap until audit completes」（隱含審計必然完成）的措辭。
- 「lower tier = 僅供 recovery」這個 legacy framing 全文移除；較低 tier 改為描述為對應 TVL band 下 keeper 的實際運作政策。

### v1.3 — 2026-05-11

**新增**
- §1.2 — 將 USDCx 代幣、xReserve 機制、Liqwid USDCx 借貸市場在 v1.3 發佈當下的營運狀態加上時間戳明確揭露，並標示「狀態若實質倒退，可透過 `UpdateRegistry` 重新評估存入代幣」的退路。
- §2.6.1 Reference Implementation Mode — 低 TVL（< $25K）持續期間的營運模式；放寬 Compound + heartbeat 節奏，保留所有合約不變式，把營運成本壓低約 85–90%。由 keeper 在 §4.5 經濟合理性裁量下啟動，不需要治理動作。
- §5.5.1 — 明確處理「只打 heartbeat 但停掉 productive Compound」的 keeper 故意拖延 sabotage 情境；說明 `max(last_compound_time, last_realloc_time)` Layer 3 觸發語意的設計理由，以及與 §2.6.1 合法使用情境的對齊。
- §8.1 — 四來源資金堆疊樂觀 / 中段 / worst case 分布；四個應變方案（延後時程 / 縮減 scope / 無限期延後 / 在 §0 框架下 sunset），並承諾儀表板按月公開追蹤。
- §8.2 — sub-scenario × 營運模式對應表，把 Phase 1 sub-scenario (a) / (b) / (c) 對應到具體營運模式、SPO 治理姿態、與對外 framing。
- §4.1 Reference Implementation Mode 自給 TVL 欄位 — 顯示在 §2.6.1 下，V1 自給 TVL 從 $500K 下降到約 $56K，支撐 sub-scenario (b) 的可行性。
- §7.4 Phase 1 小 TVL 治理姿態段落 — 明文記載當啟動落入 (a) / (b) sub-scenario 時，實質採單一簽名者的營運 contingency。

**替換**
- §1.3.1 + §4.4 break-even 統一框架 — 改採同一套「時間成本 + 風險管理外包」雙成分框架（實務損益平衡 $25–$40K），取代先前兩節各自呈現、結論方向不一致的兩張表。§1.3.1 持有規範表；§4.4 引用而不重印。

**修改**
- §2.6 — 移除「低 TVL 分層只是為了 V2 遷移恢復」的描述，完整 tier 表現在正式作為 keeper 的 live 政策呈現，低 TVL 對應的營運模式由 §2.6.1 明確接手。
- §5.5 SPO 招募 — 招募活動明確綁定 TVL sub-scenario，並在主網前 + Phase 1 小 TVL 期間明說治理工作量的預期。若 V1 停留在 terminal Phase 1，SPO 的承諾以 Cardano 社群服務形式被尊重。

**揭露調整**
- §0 + §12 — 澄清「不對創辦人 / 投資人生利」說的是股權 / 代幣分配層面；Keeper 40% share 在 Phase 1 是給創辦人的一條 USDCx 收入線、屬營運補償，但低於 keeper 自身基礎設施成本，所以這個位子對創辦人也是 net cost-centre。
- §0 Pre-Catalyst 期 — 明確揭露內部驗證期合約迭代已部署於 Cardano mainnet，前端 founder-gated，**不是**本白皮書的 V1 設計。
- §6.1 — 標題改為「六個獨立身份的分離目標（啟動時尚未完全達成，誠實揭露）」，內文重寫成直接陳述啟動狀態。
- §1.5 Stage matrix — Stage 1 改為「Limited Pilot（permissionless、顯著 pre-audit 風險提示；無邀請制、無白名單）」，與 §8.2 已移除 closed-beta framing 對齊。
- §8.1 候選審計機構短名單調整為 Anastasia Labs、MLabs、TxPipe + 獨立 Aiken 審計方（公開可驗證的 Cardano-Aiken 業務）。
- §4.1 — 新增段落澄清，§2.6.1 Reference Implementation Mode 下的 $56K 自給數字**不會**改變 §4.1 / §9.2 的 $500K post-audit sunset 觸發門檻；兩者描述不同營運階段。

**語氣**
- 透過加入營運對應（§2.6.1 模式、§5.5 分階段、§8.1 sunset 選項），強化 v1.2「公共財參考實作」定位。
- 把 $500–$5K「個人 reference」TVL sub-scenario 承認為合法的 Phase 1 結尾，而非失敗。

### v1.2 — 2026-05-08

**新增**
- §5.2.1 Cardano 生態演化情境 — 5 個條件性敏感度（Pogun BTC DeFi 上線、Leios 擴容、Midnight DeFi Kernel 成熟、USDCx 補貼到期、NIGHT solar drop 釋出時程），明確 framing 為外部狀態假設，**不是預測也不是承諾**。關閉 §5 風險框架的缺口——先前版本在 §1.5 啟動就緒框架討論外部觸發條件，但沒有文件化這些觸發條件啟動時 V1 風險輪廓會如何演化。

**語氣轉變**
- 強化「V1 是 Cardano DeFi 公共財參考實作，不是『2028 必須出貨』的承諾」framing——V1 在當前姿態下繼續出貨，與哪個演化情境成立無關。

### v1.1 — 2026-05-06

**新增**
- §0 專案哲學與分期 — 啟動前姿態定為 Cardano DeFi 公共財參考實作，採觸發條件啟動而非依日曆。
- §1.4 Cardano 穩定幣借貸生態現實 — 唯一成熟借貸場域認知（只有 Liqwid 達規模；Lenfi/Levvy/FluidTokens 現況）、oracle 集中度揭露。原「Cardano 生態的相鄰產品」表保留為末段子節。
- §1.5 啟動就緒框架 — 三軸觸發系統（Pogun BTC TVL、USDCx 流通量、Liqwid 加權 APY）、5 階段 TVL 上限矩陣、否決條件、降階條件、公開儀表板綁定、2027 Q4 最大延後。
- §1.7 未來產品路線圖 — V1.5 固定利率 vault、V2.0 多協議、V2.x Pogun BTC 路由、V3.0 Midnight 隱私 vault。每個都有明確的外部觸發條件。
- §2.5 策略權重敏感度 — 可調整權重範圍（DJED 30-55%、USDM 15-35%、USDCx 0-30%、buffer 下限 10-30%），上調/下調條件、上調用治理 7d timelock、下調由 Keeper 觸發應對壓力訊號。

**替換**
- §2.3 收益來源與費用定義 — 精確績效費公式 `fee = 4.5% × max(0, NAV_now − NAV_last_compound − slippage)`，明確「無 high-water mark」+「負期間零費用」屬性；LQ 流動性挖礦澄清；buffer drag 量化為 30% × 1.5% = 45 bps（相對於 buffer 部署到 Liqwid USDCx 的替代方案）；rebalancing 觸發條件；交叉引用 spec/rebalance-policy.md。
- §1.6.3 V2 多協議聚合器條件（前 §1.5.3）— 把「方向不是承諾」的敘事替換為 5 個明確外部條件（第二場域 12 個月運作紀錄、審計對等、V1 成熟度 12 個月 + $500K TVL、國庫儲備 6 個月 runway）。目前狀態：0/5 達成。
- §4.4 誠實對比（前「V1 適合誰」）— 明確的收益分解表；修正 buffer drag 數學（45 bps 不是 270 bps）；兩成分損益平衡框架（純時間成本 ~$5K + 風險管理 premium $25-35K = 實務 $25-40K）；前向參考 V1.5 固定利率 vault。

**重新編號（編號級聯）**
- 既有 §1.5（創辦人起源）→ §1.6
- §1.5.1（使用者保護）→ §1.6.1
- §1.5.2（為什麼 Cardano、為什麼現在）→ §1.6.2
- §1.5.3（V1 是當下、V2 是方向）→ §1.6.3（內容也已替換如上）
- §2.5（Compound 頻率）→ §2.6
- 所有交叉引用已更新。

**語氣轉變**
- 從「我們設計了一個保守產品」轉到「我們在 Cardano DeFi 階段現實上建設」。
- 從基於時程的 pre-audit framing 轉到基於觸發條件的啟動框架。
- 從單一損益平衡數字（$40K）轉到兩成分框架（時間成本 + 風險管理 premium）。

### v1.0 — 2026-04-21

首次發佈。生產就緒的 V1 設計規格。單一協議 Liqwid wrapper、三穩定幣配置（45/25/30）、4.5% 績效費、0.1% 早提費、100K USDCx pre-audit TVL 上限、3-of-3 治理 multisig、Withdraw-Zero 轉發模式、編譯期 Vault NFT 錨點、駭客視角對抗式審計。

---

**白皮書 V1.4.2 結束**
