# OptiVaults V1 白皮書

**版本 1.0 — 公開發佈候選版**
**目標網路：Cardano Mainnet**
**存入代幣：USDCx**

---

## 摘要

OptiVaults V1 是 Cardano 上的非託管**多穩定幣收益金庫，以 USDCx 計價**。存入者把 USDCx 送進由智能合約管控的金庫地址，換取 vUSDCx 份額代幣；份額的 share price 反映金庫當下在 USDCx、DJED、USDM 三種穩定幣之間、透過 Liqwid Finance 所持的混合部位。Keeper 程式負責自動複利收益，並在治理設定的範圍內於這三種穩定幣之間再平衡；手續費在 keeper 營運方與鏈上公開治理金庫之間分配。治理採 3-of-3 多簽（啟動時要求全員同意——理由見 §5.5 / §7.4）+ 7 至 21 天 timelock + 1-of-n 取消否決。存入者隨時可以提領；即使 keeper 停擺，也可以走自助緊急提領路徑自行退出。

**給存入者的重要揭露**：share price 反映的是金庫當下的多穩定幣混合曝險，**並不是純 USDCx 的請求權**。啟動時的目標配置為 45% DJED + 25% USDM + 30% USDCx 閒置緩衝（見 §5.2）；金庫當下持有哪一種穩定幣，存入者就承擔哪一種的脫鉤風險。

V1 啟動時設有 **100,000 USDCx 硬上限**,直到第三方審計完成(目標 **2027 Q2-Q3**,反映 Cardano Project Catalyst Round 時程不確定性——見 §8.1)為止。100K TVL 下協議每年的收入只有約 $270——遠不足以覆蓋營運成本。V1 此時處於**啟動期（bootstrapping phase）**：初期缺口由專案的啟動資金承擔，預期要等到 TVL 達到 $500K–$2.5M 的自給區間後才會解決。

**V1 的定位:Cardano DeFi 的公共財參考實作(reference implementation)。** V1 是**非商業的公共財專案**,不是為了追求成長或回報的商業產品。4.5% 績效費用於覆蓋協議運營 + 審計儲備 + 長期 runway,**不是創辦人或投資人的收益**;Apache 2.0 授權讓其他 Cardano DeFi 團隊可以 fork 並特化(不同穩定幣組合 / 風險姿態 / 區域變體)。V1 可能是終點狀態,也可能成為其他團隊基於此改造的基礎——兩者都是可接受的結局。存入者應以「**貢獻公共財 + 當早期驗證者**」的心態進入,不是購買商業服務(完整含意與存入者 framing 見 §12 免責聲明)。

**這個產品怎麼來的。** OptiVaults 的創辦人本身就是 Cardano 的自我託管使用者：原生質押 ADA、持有小額 BTC、參與過 Midnight 的 NIGHT redeem、在 Minswap V2 提供 ADA/NIGHT 流動性、目前也持有 USDCx（Circle 於 2026 年 2 月透過 xReserve 在 Cardano 發行）。V1 不是從「發現一個市場機會」開始的，而是創辦人自己想要一個非託管、自動複利、小額提領時能直接拿回 USDCx 的 vault，Cardano 上當時沒有這種產品，所以乾脆自己蓋。所有**核心**使用者保護都寫進合約不變量、不靠我們的營運承諾。完整的起源故事、為什麼是 Cardano 與為什麼是現在、創辦人考慮過的四條 USDCx 處置選項及其摩擦分析、「提領永遠可行」所依賴的外部協議條件說明（§1.5.1），以及 V2 的設計方向，請見 §1.5。

本白皮書說明 V1 做什麼、怎麼運作、存入者要接受哪些信任假設，以及啟動階段設計上的誠實侷限。

---

## 1. 問題定位

### 1.1 Cardano DeFi 缺的是什麼

Cardano 目前已經有：

- 借貸市場（Liqwid、Indigo iAsset）
- DEX（Minswap、SundaeSwap、Splash、CSWAP）
- 穩定幣（DJED、USDM、USDCx）

缺的是一個**非託管、經審計、以 USDCx 計價的多穩定幣收益金庫**，能自動跨 Liqwid 的 USDCx / DJED / USDM 三個市場複利。想賺被動穩定幣收益的使用者，今天只能自己追蹤三個 Liqwid 穩定幣市場的 APY、透過 Minswap V2 在三者之間換匯、管理 DEX LP 部位的無常損失、並在收益率改變時重新進場。V1 由 keeper 在治理設定的配置範圍內自動為金庫再平衡穩定幣組合；使用者拿到的份額以 USDCx 計價（即 vUSDCx），但經濟上等同對金庫當下所持 USDCx + DJED + USDM 混合資產的比例請求權。

**V1 不是多協議 yield aggregator。** 全部收益來自 Liqwid 一個借貸協議——Minswap V2 只做穩定幣間的 swap router（換手工具），不產生收益。V1 的價值主張是**「Cardano 穩定幣 supply-side 收益的便利層」**：一筆存入同時取得三個 Liqwid 市場的曝險 + 自動再平衡 + 脫鉤監控 + 自助退場保證。若你要的是真正跨協議分散的 yield aggregator，V1 還不是那個產品——**V1 未來演進會在 Cardano 上出現其他成熟穩定的供應端協議時評估納入，但 V1 目前只做 Liqwid**。

### 1.2 為什麼選 USDCx

USDCx 是 Circle 於 2026 年 2 月透過 **xReserve** 跨鏈儲備機制在 Cardano 發行的 USD 錨定穩定幣：

- 與 Circle 的 USDC 1:1 擔保（USDC 鎖在 xReserve 智能合約；USDC 本身由 Circle 持有的 USD 儲備 1:1 支撐，並由 Deloitte 每月出具 attestation）
- 採用 Cardano **native asset** 格式（多資產帳本原生代幣），而非 smart contract wrapped token——鏈上可直接轉帳與結算，不需要再包一層 wrapper
- 與 Circle 的全球 USDC 網路互通，可透過 xReserve 取用跨鏈 USDC 流動性
- Liqwid 已有運作中的 USDCx 借貸市場
- Minswap V2、SundaeSwap、Splash 都對 DJED、USDM、ADA、NIGHT 有流動性

**重要揭露**：USDCx 實質上就是 Circle USDC 在 Cardano 上的代表形式，透過 xReserve 與其他鏈相連。雖然 USDCx 在 Cardano 上是原生資產格式（沒有包一層合約），但發行與贖回流程仍依賴 Circle 的 xReserve 基礎設施、美元儲備管理，以及 Circle 的合規與審計程序。USDCx **不是**完全鏈上獨立的穩定幣——它的信任鏈會延伸到 Circle 與 xReserve。

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

**OptiVaults V1 主要服務手中有小到中額 USDCx（約 $100–$10,000）的持有者**——想在 Cardano 上賺被動穩定幣收益、但不想親手經營 DeFi 的使用者。V1 的經濟模型、使用介面、安全設計都是為這群人量身打造。**時程提醒**:$100-$10,000 這個目標規模指的是 **post-audit 階段**(目前目標 **2027 Q2-Q3+**,外部審計通過、TVL 上限解除之後;funding stack 不確定性見 §8.1)。Pre-audit 期間受 operator-enforced 100K USDCx TVL cap 限制，建議首次部位明顯低於此目標範圍下限（例如 $200-$2K 試水）——完整 pre-audit context 見 §8.2。

- **小額部位最容易被「進場 + 離場 gas」吃光。** 若一位只有 $200 USDCx 的使用者自己直接上 Liqwid：進場一次要做 swap USDCx → DJED + supply（約 2 筆 TX；若要同時分散到 DJED + USDM 則約 4 筆），將來離場還要再走一次 recall qToken + swap back。以目前 Cardano 網路費 + Minswap batcher 費估算，單方向大約 3–5 ADA，來回約 $2–4 USD——對 $200 部位就是本金的 1–2% 一次性摩擦，還沒開始賺收益。V1 把多市場配置集中在金庫層（一筆 Compound 就服務整個 TVL），每位存入者的進場只要一筆 CIP-30 交易、離場只要 burn 一次 vUSDCx，不必走 recall + swap back 的多步驟路徑。
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

**誠實的損益平衡——對你時間成本的敏感性分析**（§4.4 有完整數學）。V1 的 544 bps 費用差距 vs 它為你省下的手動 rebalance 時間，損益平衡點完全取決於你怎麼估自己的每小時價值。一個季度 1 小時手動管理（≈ 一年 4 小時）× 你的時薪 = V1 每年為你省下的時間價值；此與 544 bps 費用在不同存入規模下的平衡點：

| 你的時薪 | V1 損益平衡存入金額 | 對這類使用者的誠實含意 |
|---------|---------------|----------------|
| $10/小時（學生、新興市場、退休） | ~$8K | **多數目標使用者應選 Direct Liqwid DJED。** 你省下的 4 小時/年只值 $40，但 $8K 存入 V1 的 544 bps 費用一年要 $435——你付的費用是你省下時間價值的 ~10 倍。 |
| $20/小時（一般小資收入者） | ~$16K | **「目標範圍」上半段也應選 Direct Liqwid。** V1 只在 ~$16K 以上才是淨正。 |
| $50/小時（早期白皮書用的數字） | ~$40K | 這個使用者在 $40K 以下 V1 才淨正，但這個時薪**高於** $100-$10K 目標客群合理能賺到的。 |
| $100/小時（DeFi 專業／創辦人層級） | ~$80K | V1 在 $80K 以下都淨正，**但這類使用者明確不是 V1 目標**（他們自己跑 keeper）。 |

**誠實推論**：名義上 $100-$10K「目標範圍」中相當比例的使用者，**正確選擇其實是 Direct Liqwid DJED supply，不是 V1。** V1 實際能服務的使用者群縮小到：(a) 把避免 DeFi 操作複雜度看得高於邊際時薪的使用者（對很多把 DeFi 視為令人卻步、而非以時間成本理性計算取捨的人，合理）、(b) 原則上拒絕 CEX 託管所以沒有替代選項、(c) 想要雙穩定幣發行者分散但不想並行管理兩個 Liqwid 部位。這比單一 $40K 損益平衡數字所暗示的產品市場要小。我們在此明確揭露，而不是躲在平均數字後面。

**簡而言之**：只要一筆 CIP-30 存入交易，你就能同時取得 Liqwid 三市場供應收益、自動再平衡、以及自助復原機制。代價是已實現收益的 4.5%。對 $200–$10,000 的部位——若直接走 Liqwid，進場 + 離場一次性 gas 大約占本金 1–2%——V1 的便利性節省是實在的，但是否能壓過 4.5% 績效費，仍要看你的持有期與時薪（見上方損益平衡表）。

### 1.4 Cardano 生態的相鄰產品

在評估 V1 之前，存入者也應該了解 Cardano DeFi 有哪些與 V1 功能部分重疊的產品。

| 產品 | 做什麼 | 與 OptiVaults V1 的差異 |
|------|--------|-------------------------|
| **Liqwid Finance（直接 supply）** | USDCx / DJED / USDM / ADA 貨幣市場 | 只有單一市場曝險、沒有自動跨市場重配、也沒有份額代幣抽象化。再平衡與複利都要自己來。 |
| **Indigo Protocol（iAssets + iUSD 穩定池）** | 以 ADA 超額抵押鑄造合成資產（iUSD、iBTC、iETH）；穩定池賺清算費 | 風險模型完全不同：iUSD 是以 ADA 抵押的演算法合成穩定幣，不是法幣擔保；穩定池存入者要承擔 ADA 清算風險。 |
| **Minswap / SundaeSwap 穩定幣對 LP** | 對 USDCx/DJED、USDM/DJED、USDC/USDCx 等池提供流動性，賺 swap 費 | LP 部位在脫鉤事件中會承受無常損失；V1 刻意只取 supply-side 收益、避開 LP。 |
| **Genius Yield（歷史）/ Encoins** | 上一代的 Cardano DeFi 產品 | V1 啟動時已不是活躍競品；列在這裡以求完整。 |
| **ADA 原生質押** | 把 ADA 委託給 stake pool，賺約 2.3–2.4% | 不是 USDCx 計價的收益；需要持有 ADA，也就承擔 ADA 的價格風險。 |

誠實的定位：**V1 是一層疊在 Liqwid supply-side APY 之上的多市場分散與便利層**，並以 Minswap V2 作為穩定幣之間的 swap router。想把對手方風險壓到最低、而且願意自己手動配置的人，直接用 Liqwid 就好；想要分散的穩定幣收益、又不想自己跑 keeper 的人，才是 V1 的目標族群。

### 1.5 V1 的起源——Cardano 自我託管使用者親手打造的產品

OptiVaults 的創辦人本身是 Cardano 的自我託管使用者，正好是 V1 的典型目標使用者（職業背景見 §7.4，作為補充）：

- **2025 年起持有 ADA 並委託 stake pool 做原生質押**——Cardano 核心資產部位，透過 stake pool 賺協議原生收益。
- **2025 年起持有小額 BTC**——多鏈 scarce-asset 配置，同樣的自我託管姿態。
- **參與過 Midnight 的 NIGHT redeem**——透過 Cardano 生態內合格持倉領取 NIGHT 代幣。（後來這些 NIGHT 跟 ADA 配成 Minswap V2 的 LP 部位——見下一項——但那是後續的使用行為，不是事先規劃好的「組合部位」步驟。）
- **2026 年起在 Minswap V2 的 ADA/NIGHT pool 提供流動性**——Cardano DeFi 主動參與者，不是被動持有人。親身經驗過 Minswap batcher 行為、cancel 路徑、pool 遷移、ADA-paired 部位的 impermanent loss。
- **目前持有 USDCx**（Circle 於 2026 年 2 月透過 xReserve 在 Cardano 發行）——Tier-1 法幣擔保穩定幣，是 V1 的 deposit token。

**V1 的起點是很具體的個人需求。** USDCx 就放在創辦人錢包裡，現實的選項有四條：

- **(a) 送到 CEX 換 earn 產品**——因自我託管原則拒絕。
- **(b) 直接在 Liqwid 的 USDCx 市場 supply**——利率大約 0.5-2%，扣掉通膨實際報酬常常是負的，不值得花時間。
- **(c) 把 USDCx 換成 DJED，再 supply 到 Liqwid 的 DJED 市場**——年化可以到 ~11.8%。進場是 2 筆 TX（swap + Liqwid supply），離場或每次部分提領是反向的 recall + swap back 一組往返；若要同時分散到 DJED + USDM 就是大約 4 筆進場、兩個部位並行管。進場之後 qToken 放在你自己錢包裡、兌換率自動累積，中間沒有每週期再平衡或定期 compound 的家庭作業。對 $200 部位而言，一次進場 + 一次離場來回 gas 大約是本金的 1-2%，持有越長攤得越薄；短期持有或頻繁部分提領才會感受明顯。
- **(d) 就讓 USDCx 躺在錢包裡**——0% 收益，而且 USDCx 發行者風險一樣要承擔。

這四條都不是創辦人真正想要的。真正想要的很簡單：**「把 USDCx 存進去、讓它自動在 Liqwid 上複利，之後需要動用小額 USDCx 時能直接提出來，不用每次都走 recall qToken + swap back 的多步驟往返」**——這個對小額提領很關鍵，因為 $50-100 的提領若要自己跑完整流程，光 gas + batcher 費加起來很可能就吃掉被提領金額的 5-10%。而 Cardano 上當時沒有這種經審計的非託管自動複利 vault。於是創辦人就自己蓋了一個。

**V1 是「我自己在找但找不到、只好動手做」的產品。** 這就是**起源故事**，同時也是**產品與市場契合**（product-market fit）的陳述：創辦人不是在猜想遠端客戶想要什麼，而是在出貨一個他自己想用的產品。目標使用者清單上的第一位，就是創辦人自己。

**Minswap LP 的經驗跟 V1 設計直接相關。** 是真的 Minswap V2 LP（而不是讀過 Minswap 文件的人），代表創辦人實際上：
- 看過 batcher 延遲——有時候秒成交，有時候池狀態被競爭時 fill 會堆著。V1 的 keeper 設計有為此 budget（Queue Withdraw 路徑 <1 小時結算是對 batcher cycle 現實的回應，不是理論 SLA）。
- 親身踩過 cancel 邊界情況——`StakeCredential::Constr(0,[])` vs `Constr(1,[])` 編碼差異、pool-shard 遷移問題——這也是 V1 整合手冊（`docs/integration-playbook.md`）把 cancel 路徑當成必須逆向工程、不是可選項的原因。
- 經驗過 ADA-paired LP 的 impermanent loss——這就是為什麼 V1 明確避開 LP 部位（§2.3），只取 supply-side Liqwid 收益。這個設計選擇來自經驗偏好，不是理論風險框架。

### 1.5.1 V1 的使用者保護分層:合約內強制 vs 外部依賴

V1 的使用者保護分兩層，存入者應該清楚知道自己正在依賴哪一層。

> **核心使用者保護是合約不變量，不是營運承諾。** V1 的承諾為什麼可信？因為**我們在程式碼層就根本做不到違反這些承諾**——有幾項承諾在程式碼層就被排除了背棄的可能。沒有任何 redeemer 能把 `idle_buffer` 送到存款人以外的地址；`performance_fee_bps` 由 `vault_gov_policy.ak` 的 `UpdateFee` redeemer 透過共用的 `validate_update_fee` helper 硬鎖在 450（4.5%）上限，任何治理動作都無法把它推高；不存在「暫停提款」的 admin 開關。這些都是已部署 validator hash 的客觀屬性，任何人都可以自己驗證。

> **不是每一項保護都是純合約不變量。** 有三項在合約內、無條件成立：(a) 沒有 admin-drain redeemer、(b) 4.5% 費用上限不可變、(c) keeper 離線 7 天後早提款費自動免除（§5.4）。其他項目依賴外部基礎設施可用性：提領成功要 Cardano 鏈 + Liqwid（若有部位在那邊）+ Minswap V2（若需 routing）+ USDCx 流動性（最終產出）都正常。任何一環 out，存款者鏈上的請求權仍然可強制執行，但結算可能是 vault 當下持有的資產，不一定是 1:1 USDCx。自助 `emergency-withdraw` 工具仍然能用，但產出品質會跟外部協議狀態連動。這才是誠實的姿態，不是「在任何情況下提領永遠可行」。

V1 的定位是**彈性 + 收益的操作體驗，搭配鏈上強制的使用者保護**：不收 AUM 費、不收管理費（只對實際產生的收益收 4.5% 績效費）；自助退場路徑（`withdraw-cli` / `emergency-withdraw`）跟主產品一起發布，不是緊急備案而是首要功能；pre-audit 100K USDCx cap + 多輪內部審計 + 外部審計通過後才放量，不走加密圈「先上線再審計」。V1 不規避 DeFi 固有的信任邊界（錢包私鑰即本金控制、已確認 TX 不可逆、合約與外部依賴都可能失效）——這些在 §5.1 + §9.1 + §12 都有詳細揭露。

### 1.5.2 為什麼選 Cardano、為什麼是現在這個時點

講公平一點，會有人問：Aave、Compound、Yearn 幾年前就在 Ethereum 上做過概念類似的 vault-aggregator，為什麼 OptiVaults V1 現在才在 Cardano 上做？為什麼不更早做？為什麼不去別條鏈做？

誠實的答案：**讓這個產品能在 Cardano 上成立的條件，最近才到齊。** 提早兩年做，你會在核心屬性上被迫妥協；換到別條鏈做，你會失去 Cardano eUTXO + Plutus 模型在架構上的契合。

- **USDCx 2026 年 2 月才上線。** Circle 透過 xReserve 機制推出 USDCx 之前，Cardano 上一直沒有一個具備機構等級後盾、而且每個月都有儲備證明的法幣擔保穩定幣。如果 vault 只能建在 DJED（ADA 抵押）或 USDM（較小型發行者）上，整個產品會被集中在單一發行者的信用風險上。USDCx 補上了這塊核心資產的空缺。
- **Liqwid 穩定幣市場在 2024–2025 成熟。** DJED 和 USDM 要在 Liqwid 上有足夠的借款需求跟供應深度，supply-side aggregator 才能在不大幅扭曲利率的情況下配置有意義的金額。這個深度是 2024 下半年才到位，而且一路延續到現在。
- **Cardano SPO operator 社群成熟。** V1 的治理模型（3-of-3、兩位獨立 SPO 簽名者——見 §5.5）要靠一群成熟、有公開身分、在生態系裡有長期經濟利害的 stake pool operator。SPO 社群的廣度跟聲譽深度，是最近幾個 epoch 才長到足以作為可信獨立治理簽名者的水位。
- **Aiken + PlutusV3 工具鏈成熟。** V1 的合約架構（Withdraw-Zero 轉發、多 validator staking 委託、Conway 期 PlutusV3 reference script 費用結構）所依賴的工具鏈，到 2023 年都還是實驗性質。Aiken 做到 `v1.1.x`、`stdlib` 也穩定之後，這套實作才在可以負擔的審計預算內做得出來。

V1 不是 DeFi 史上第一個自動收益 vault，它是**這類產品裡、第一個架構前置條件真的在 Cardano 上到齊的版本**。更早動手，要嘛得在核心屬性上讓步，要嘛得等那些當時還沒存在的基元（資產、市場、工具鏈）先長出來。

### 1.5.3 V1 是當下,V2 是未來可能的方向(並非承諾路線圖)

V1 是這個想法的第一個具體實作。**V2+ 是同一個想法在 Phase 1 驗證結果 + Cardano DeFi 生態條件都兌現之後、可能長成的樣子——是方向，不是被承諾的 roadmap。**

目前對 V2 的想法大概是這樣：

- V1 先證明「單協議（Liqwid）+ 三穩定幣（USDCx / DJED / USDM）+ m-of-n 治理」這套模式在生產環境下、面對真實對抗性條件下，真的跑得起來。
- 等到 Cardano DeFi 景觀再深化——Liqwid 以外出現合格的借貸協議、DEX 流動性加深、整體穩定幣 TVL 基數擴大、keeper operator 社群成熟——V2 才會朝**多協議、多策略的資產配置層**演化。
- **至於 V2 具體的設計項目（策略路由、協議 adapter 介面、風險參數框架、跨策略 rebalance 界限），目前刻意不做承諾。** 設計空間要等 Phase 1 實際跑過之後才會定型——包括實際看到哪些失敗模式、使用者怎麼用、Liqwid 市場怎麼變、合格的替代協議到底有沒有真的出現。

V2 是**方向**，不是承諾。誠實地講：V1 是現在要上線的生產軟體；V2 是同一個想法**如果生態條件配合**會走過去的地方。

**V1 有可能就是終點狀態——這也是一個可以接受的結果。** 如果 Cardano 穩定幣 DeFi 的景觀沒有朝我們希望的方向成熟（沒有第二個合格借貸協議出現、DEX 深度一直太薄、TVL 到了一個 plateau 就不再成長），V2 就不會出貨。這個情境下，V1 就是停留在「單協議 Liqwid wrapper + 三穩定幣曝險 + m-of-n 治理」——比「未來多協議 aggregator」更窄的價值主張。我們會建議存入者以 V1 **現在的樣子**來評估它：**自動複利 + 雙發行者穩定幣配置 + 自助退場保證 + 經審計且有上限的費用結構**，費用是已實現收益的 4.5%。這組合對你是否划算，取決於你自己的替代方案比較（直接 Liqwid DJED、CEX earn、或純粹持有 USDCx——§4.4 都有完整對比）。

**連帶補一個跟授權條款有關的定位點。** OptiVaults 沒打算要當 Cardano 最大的 vault。明確的目標是把一份完整、經審計、以 Apache 2.0 授權的參考實作放進 Cardano 開源公共財，讓其他團隊可以 fork 並做特化（不同穩定幣組合、不同風險姿態、產業別或區域性變體），不管 OptiVaults 自己會不會長大。BSL / source-available 授權會把 V1 的競爭地位保護到 2028 年，代價是擋掉這類 Cardano 生態系層級的採用——這是我們認為真正比較有價值的後果。Apache 2.0 就是對齊這個目標該選的授權條款。

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

### 2.3 收益來源 + 目標配置

V1 收益來自：
- **Liqwid 借貸**：USDCx、DJED、USDM 供應至 Liqwid 市場，賺取借款人利息
- **複利再投資**：收益流回緩衝，保留為 USDCx 或於下次再平衡時 swap 至最高 APY 市場

**啟動日目標配置**（由治理 `UpdateStrategy` 設定，可於邊界內調整）：

| 資產 | 目標 | 角色 | 啟動日收益貢獻 |
|------|------|------|----------------|
| DJED（Liqwid supply） | 45% | 主要收益——演算法穩定幣，啟動時借貸需求最高 | 此份額享完整 Liqwid DJED 供應 APY |
| USDM（Liqwid supply） | 25% | 次要收益——法幣擔保，Liqwid 市場 TVL 較小（但 DEX swap 側有 USDCx/USDM 11.6M 直接池；詳見 §5.2） | 此份額享完整 Liqwid USDM 供應 APY |
| USDCx（閒置 buffer） | 30% | **提領流動性——V1 啟動日 0% 收益**（buffer USDCx 閒置於金庫地址；V1 啟動時 NOT 供應至 Liqwid USDCx 市場） | **0%** — 詳見下方說明 |

**為什麼 buffer 啟動時是 0%，以及未來可以如何調整。** Buffer 的用途是讓單筆交易就能完成直接提領（Direct Withdraw），不必再走 Liqwid Recall（那會額外多一筆 gas、也可能遇到流動性摩擦）。要穩定做到，buffer 必須保持流動——也就是不能被鎖在需要另外發一筆 Recall 才能解鎖的 Liqwid 供應部位裡。

內部驗證期曾經試過把 buffer 停在 Liqwid 的 USDCx 市場賺 0.5–2% APY，實驗結果顯示兩個問題：(a) Liqwid 的 USDCx 市場深度不足，只要服務到 TVL 約 5% 的提領量，解鎖 buffer 就已經產生明顯滑點；(b) 低 APY 的市場上，每個週期 Recall + Supply 的 gas 成本反而超過賺到的利息。**所以 V1 啟動時採用 buffer = 0% 收益、閒置在金庫地址。**

**治理可以調整——Liqwid USDCx 分配保留條款。** V1 啟動時明確選擇 **0% 至 Liqwid USDCx** 的保守配置，但**保留未來透過治理 `UpdateStrategy`（7 天 timelock）將部分 buffer 重新分配至 Liqwid USDCx 市場的權利**。觸發條件包括但不限於：(a) Liqwid 的 USDCx 市場深度明顯變深（至少能吃 15-25% × V1 當時 TVL 而不壓縮 APY 超過 100 bps）、(b) USDCx Liqwid APY 穩定維持在 ~2% 以上超過一季、(c) keeper 於 Phase 2+ 已累積 Recall 失敗的災難復原經驗，或 (d) 出現更適合存 buffer 的低風險去處（例如未來的 Cardano Treasury T-bill wrapper、或更深的穩定幣貨幣市場）。這些都不需合約變更——是現有 validator 邏輯內的政策調整。任何此類調整，治理會公開說明理由、預期收益提升、以及解倉計畫，存入者有 7 天 timelock 窗口內決定是否退場。

**V1 不是純 USDCx 產品。** 65% DJED + USDM 的曝險正是價值主張的核心（借貸市場更深、APY 明顯高於閒置 USDCx）；但相對地，存入者要按金庫當下的混合比例承擔三種穩定幣的脫鉤與流動性風險。詳見 §5.2 多穩定幣脫鉤揭露。

**V1 不使用：**
- DEX LP 倉位（無常損失風險）
- 演算法流動性挖礦（治理代幣釋出）
- 槓桿倉位
- 跨鏈橋

收益嚴格為 Liqwid 供應 APY（三市場混合）與 OptiVaults 對毛收益收取 4.5% 績效費之間的利差。

### 2.4 手續費結構

- **績效費：4.5%**（`performance_fee_bps = 450`）於每次 Compound 從毛收益中扣取，以 **USDCx**（不是 ADA）於已實現收益回寫到 `total_deposited` 之前先扣除。硬上限 4.5% 由 `vault_gov_policy.ak` 的 `UpdateFee` redeemer（透過共用 `validate_update_fee` helper）強制，治理在任何 redeemer 下都無法超過這個上限。
- **早提領費：0.1%**（`early_withdraw_fee_bps = 10`）只要 keeper 還在活動，每筆直接提領都會收取（keeper 失活 7 天後自動免收）。以 **USDCx** 於提領金額中扣除，費用留在金庫，轉化為 share price 上升回饋給剩餘持有者。硬上限 1%（100 bps）。
- **`min_hold_seconds`（直接提領的閘門，不是資金鎖定）：** 每次 Compound 之後，直接提領會被 `min_hold_seconds` 擋住一段時間才能再送；**排隊提領路徑從頭到尾不受影響**。啟動值為 60 秒；治理可透過 `UpdateFee`（14 天 timelock）調整，validator 強制的硬上限為 **6 小時**（`max_min_hold_seconds = 21_600`）。白皮書審視後從原本的 24 小時上限**收緊**為 6 小時（§2.4 與 §6.3 有完整理由）：週 Compound 週期下，即使治理拉到上限，也只有約 3.6% 的時間直接提領不可用；而排隊路徑完全不受此閘門影響——使用者的資金絕不會被鎖，只是換個路徑，~5–15 分鐘內完成。
- **SwapAda 營運摩擦：100K TVL 下約 0.02% APY**（詳見 §4.5）。這不是協議層級的手續費——它是鏈上 `SwapAda` redeemer 以 Charli3 + Orcfax oracle 公平價為金庫補充營運 ADA 時，由存入者以 USDCx 承擔的成本。100K TVL 下一年約 10–20 USDCx，反映在 share price 的自然遞減中。雖然不是傳統意義上的「手續費」，但它是一個真實從金庫流出的經濟活動，所以如實揭露。
- **無存入費用。**
- **無管理費**（無 AUM 費）**。**

**3-way 手續費分拆（V1 新增）：** 每次 Compound 將績效費依 `VaultDatum.keeper_fee_bps` 與 `VaultDatum.gov_fee_bps` 分拆。Keeper 份以 USDCx 直接送至簽名 keeper 的地址；Gov pool 份累積於 MultisigGov UTXO 的 `signer_compensation_pool` 欄位（每季分配，economics.md §7A）；Treasury 份流向 treasury 合約地址。

| Phase | 觸發條件 | Keeper | Gov pool | Treasury |
|-------|---------|--------|----------|----------|
| V1 launch | 部署預設 | 20% | 0%（停用） | 80% |
| Phase 2 | TVL ≥ 500K + 加入外部簽名者 | 20% | 5% | 75% |
| Phase 3 | TVL ≥ 2M + 加入社群簽名者 | 20% | 10% | 70% |

**硬上限：** `keeper_fee_bps ≤ 2500`（25%）、`gov_fee_bps ≤ 1000`（10%）、`keeper + gov ≤ 3000`（treasury 保底 ≥ 70%）。變更需 `UpdateFeeSplit` 動作 + **21 天 timelock**（所有治理動作中最長——因治理調整自身報酬）。

**V1 階段三方分拆的誠實揭露。** Keeper / gov pool / treasury 在鏈上為三個獨立流向，各有不同地址、redeemer 授權路徑、timelock 設定。然而 V1 啟動時，這三個流向的**人類控制者明顯重疊**——創辦人同時運作 keeper 並持有治理簽名者席位，而 treasury 支出亦需治理簽名（見 §9.1）。V1 的三方分拆因此是**走向去中心化的結構準備，而非當下已實現的去中心化**。參見 §6.1（Six-identity separation 目標）了解三個口袋達到經濟獨立的輪替路徑。

先前內部驗證版本將 100% 手續費送至單一營運者錢包。V1 將此流程鏈上分離，並採輪替 keeper 模型（§7「Run Now, Open Later」）+ soul-bound Gov Signer NFT（見 `spec/gov-nft.md`）確立聲譽責任制。Gov Signer NFT 的 soul-bound 特性**由其鑄造政策的 spending-script 檢查強制**（並非 Cardano ledger 原生特性）：任何花費帶有 Gov Signer NFT 之 UTXO 的 TX，必須將該 NFT 傳回至支付給簽名者原始 PKH（由 NFT 資產名尾綴導出）的 output，或於同筆 TX 透過 `BurnRotatedOut` 燒毀。第三方轉讓會不通過此 script 檢查而被 ledger 拒絕。該 NFT 不具投票權或財務權利（這些位於 MultisigGov 自身的 datum）；純屬認可。

### 2.5 Compound 頻率

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

V1 於預審計 100K USDCx 上限下永遠在 1,200+ 檔（weekly 排程）——上面三個較低 TVL 分層保留在 keeper 程式中，只是為了未來 V2 遷移從近空金庫起步時的恢復路徑。

每一筆 Compound TX 需要 keeper 簽名。Fallback：若 keeper 停擺超過 7 天，治理可用 m-of-n 簽名代替 keeper 執行 Compound。

---

## 3. 技術架構

### 3.1 智能合約堆疊

V1 部署 **17 個 logic validator**，加上 5 個 mint-only 政策（vUSDCx 份額代幣 + 4 個一次性 NFT），再加上 1 個 DEX adapter：

1. **vault_proxy** — 入口點，透過 Withdraw-Zero pattern 在 10 條路徑（User / KeeperHot / Batcher / SwapAda / Protocol / Recall / Liqwid / GovPolicy / GovEmergency / AdminDeploy）間轉發 spend，見 §3.2
2. **vault_user** — Deposit / Withdraw 專用。**純無許可**——不需要 keeper 授權。
3. **vault_keeper_hot** — Compound / RebalanceBuffer。Keeper 熱路徑；Compound 的 3-way fee split treasury output binding 在這個 validator。
4. **vault_batcher** — BatchProcess 專用。Keeper-authorized staking validator，持有 4 個 fold 迴圈（order_sums / order_owners / vusdcx_leaked / payout_indices）+ OrderDatum / OrderRedeemer decode + `list.unique` + R51/R52 anti-leak invariant。詳見 `spec/order-batch.md`。
5. **vault_swap_ada** — SwapAda 專用。持有 §5.4 P5 的 dual-feed oracle reader + 6-tuple registry read。V1 啟動時處於 inactive 狀態，直到治理在 `asset_oracles` 中植入 ADA entry；詳見 `spec/ada-swap.md`。
6. **vault_protocol** — DeployToProtocol（SwapAdapter 分派 + 限額 ADA 支出）
7. **vault_recall** — RecallFromProtocol、MergeUtxo
8. **vault_liqwid** — SupplyToLiqwid、RecallFromLiqwid（逐 market 部位追蹤）
9. **vault_gov_policy** — UpdateStrategy / UpdateFee / UpdateFeeSplit / UpdateSlippagePolicy（治理政策類變更；timelock 7d–48h）
10. **vault_gov_emergency** — EmergencyWithdraw 專用（0d timelock）。把快速反應治理路徑保持在一個 tight 的 validator 上，未來 SwapAdapter 擴充不會擴大緊急路徑的攻擊面。
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

以及 1 個 DEX adapter：

- `minswap_v2_adapter` — SwapAdapter 介面實作（§B@launch=1 架構，見 `spec/swap-adapter.md`）。以 governance anchors 為編譯期參數（唯一目的是啟用 A2 `publish` handler 以回收 stake 押金，見 §5.1 + §6.2 `ActDeregisterStake`）；adapter hash 是 Registry `swap_adapter_hashes` 白名單的唯一識別。

**合計編譯 artefact：17 logic validator + 4 NFT mint policy + 1 DEX adapter = 22**。

**拓撲設計理由。** 22-artefact 的數量是沿著四個正交切割面 partition 的結果（authorization-boundary、governance response-latency、bytecode-cost-center、size-fix），主要由 Plutus V3 16 KB reference-script ceiling 推動，並非任意細分。工程理由與拆分後 size 列在 `spec/architecture.md §4.1`；本白皮書不列舉逐次 commit 的時序歷史，因為對 depositor 決策無實質意義。

詳細 redeemer 見 `spec/architecture.md`，VaultDatum schema（§5.4 Phase 2 後為 28 欄位）見 `spec/vault-datum.md`。

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

---

## 4. 經濟模型

### 4.1 啟動經濟

在 100K USDCx TVL + ~5-6% 淨收益下（`docs/economics.md §6.2` current-reference 情境；buffer=0% 計算於 2026-Q2 Liqwid 利率下為 ~6.36% 淨，區間下限涵蓋利率壓縮）：

| 指標 | 數值 |
|------|------|
| 年度毛收益（保守 5%） | $5,000 |
| 年度毛收益（樂觀 8%） | $8,000 |
| 績效費（4.5% 毛收益） | $225-360 |
| Keeper 份（20%） | $45-72 |
| Treasury 份（80%） | $180-288 |
| 營運成本（keeper + 基礎設施 + 審計儲備） | $360-2,400 |

**現實：100K TVL 下協議收益不足以覆蓋營運成本。**

V1 處於**啟動期（bootstrapping phase）**，直到 TVL 達到自給區間約 $500K-$2.5M。以下時期，初期虧損由專案**啟動資金（founding capital）**承擔——這是新 DeFi 協議啟動的正常狀態。達到門檻後，OptiVaults 自身營收可覆蓋基礎營運，更高 TVL 則逐步充實審計儲備、研發、緩衝類別。

**Phase 1 期望重設**（對存入者預先說清楚）。$500K-$2.5M 自給閾值依其構造是 **Phase 2+ post-audit 目標**——在 pre-audit 100K USDCx 上限下無法到達。我們對 Phase 1（pre-audit、100K cap 下）TVL 的內部估算是頭 6-12 個月落在 **$500-$25K** 區間，基於保守的使用者取得假設加上 permissionless-only 立場（沒有 closed-beta gate、沒有 invitation list — 實際 TVL 完全取決於 organic discovery）；這是推測性區間，不是預測，我們公開標示是為了誠實揭露模型假設——不是在做承諾。100K 上限是**風險包絡，不是銷售目標**。啟動資金 runway 規模的計算假設 Phase 1 TVL **不**承擔營運——啟動資金完全吸收 Phase 1 燒錢，協議自給性從 Phase 2 post-audit、TVL cap 放寬後才開始（§8.3）。完整「Phase 1 即協議驗證」framing 見 §8.2。

**自給 TVL 門檻會隨情境怎麼變動**（取決於 Liqwid 供應 APY 與營運成本）。§4.1 的 $500K-$2.5M 區間並非單一點估，而是下列三情境的下界與上界：

| 情境 | Liqwid 供應混合 APY | 年度營運成本 | 自給 TVL 門檻（近似） |
|------|---------------------|--------------|----------------------|
| 樂觀 | 10%（借貸需求強勁、審計儲備擴張緩慢） | $600（低端） | ~$135K |
| 基準 | 6%（近期 Liqwid 水準，§4.1 主情境） | $1,200 | ~$500K |
| 保守 | 3%（借貸需求衰退、Cardano DeFi TVL 壓縮） | $2,400（高端含審計儲備擴張） | ~$1.8M |

公式：`自給 TVL ≈ 年營運成本 / (毛 APY × 績效費率 0.045)`。保守情境下，從外部審計通過到 TVL 爬坡達到自給門檻，可能需要 **3-5 年**（post-audit cap 放寬 + 多次行銷週期 + Cardano DeFi 整體 TVL 成長）——若啟動資金 runway 到期前仍未達到，§9.2 sunset protocol 啟動。18 個月 runway 在**基準情境**下足以涵蓋「開發 + 審計 + 6 個月 post-audit 爬坡」；若遭遇**保守情境**延展，runway 可能需要額外啟動資金挹注或加速 sunset 決策。這是存入者應該理解的結構性不確定性。

**啟動資金可燒時長承諾。** 啟動資金規模足以支撐 **≥ 18 個月營運 runway**，計算方法依 `docs/economics.md §7` 的支出率方法論，涵蓋：(a) pre-audit 開發窗口、(b) 外部審計預算(目前目標 Q2-Q3 2027——見 §8.1)、(c) 悲觀端營運成本下的 6 個月 post-audit TVL 爬坡期。資本由啟動實體在鏈外保管；`docs/economics.md §7` 裡有逐項的月支出拆解（基礎設施 + 審計儲備 + 外包 + 預備金），讀者可據此獨立驗證 18 個月的數字。**具體總金額不公開**（專案政策——創辦人自投資金屬於私人風險，不是信任錨），但 runway 計算可從公開的支出條目重現。

**Sunset 觸發條件與機制**（§9.2 + economics.md §7.2）：若外部審計完成後 **6 個月內 TVL 未達 $500K**，或 runway 任何時點降至 6 個月以下前向支出，有序 sunset 協議啟動：

1. **90 天存入者預告期**（由白皮書 review 後從原 30 天延長——配合 DeFi 遷移實際需要）。預告發布於鏈上 `governance.QueuedAction` + 鏈下網站橫幅 + Discord + 既有使用者管道。
2. **預告期啟動前的前置條件**（3 項全部完成後,90 天時鐘才啟動）:
   - 所有 Liqwid qToken 部位完整 recall 為 USDCx
   - 所有在途 Minswap V2 訂單 cancel 或過期
   - 治理 queue `UpdateFee` 將 `performance_fee_bps → 0`(「sunset 期間 fee 歸零承諾」)
3. **90 天窗口期間：** 不接受新存入（frontend gate + keeper 拒絕 BatchProcess deposit orders）、withdraw 完全開放、0% 績效費、keeper 持續送 zero-yield Compound heartbeat 保持 7 天 inactivity guard 有效。
4. **90 天後：** 剩餘 < dust 門檻的部位可透過治理 `EmergencyWithdraw` 合併；ref-script 資本透過 `deploy/tools/reclaim-refs.ts`（隨 V1 實作一併發佈）回收。

**Sunset 觸發時的啟動資金保留下限。** Sunset protocol 觸發時，啟動實體承諾於啟動資本中保留至少 **~150 ADA**（約 $75-100 USD，依當下 ADA 市價）專款，覆蓋 sunset 的 90 天結算窗口所需鏈上費用：(a) 90 天 keeper 營運週期（zero-yield heartbeat 每 5 天 + 週六排程 Compound + Liqwid market 監控）≈ 60-80 ADA；(b) 1× Liqwid full recall 跨 3 markets ≈ 6 ADA；(c) Minswap V2 router gas 為 stable → USDCx 轉換 ≈ 6 ADA；(d) Conway 期 ref-script fee 附加費(~1.2 ADA × 40 TX)≈ 48 ADA；(e) 20% 安全緩衝。此 150 ADA 保留與「fee=0% 承諾」共同形成 sunset 期間的操作性保證——即使主要啟動資金已耗盡（sunset 觸發條件本身之一），sunset 的 90 天結算仍有獨立資金覆蓋，存入者不會因營運方資金見底而陷入「提領 TX 送不出去」的絕境。

90 天預告期 + fee 歸零 + 前置清理是一個強存入者承諾——任何持倉人有 ≥ 3 個月不付績效費退出的窗口，並保證 vault state 在時鐘啟動前已處於 withdraw-ready 狀態。這刻意比天真的 30 天預告寬裕：V1 是 pre-audit 產品，sunset 期間存入者遷移摩擦是我們最想最小化的損失。

詳細計算與 TVL 分層預測見 `docs/economics.md`。

### 4.2 Treasury 模型

Treasury 累積 80% 的績效費（V1 啟動時的分拆比例，3-way split 後續 phase 見 §2.4），資產以 **USDCx** 計價。啟動時的類別分配：

- **審計儲備 30% 進帳分配**——用於資助未來審計與未來安全研究者計畫（V1 上線採用「責任揭露政策 + ex gratia 認可框架」，而非固定結構化 bounty tier，詳見 `docs/audit-scope.md §6`；結構化 bounty 計畫啟用前提於 §6.3 說明）。有兩條獨立的治理硬下限保護：
  - **進帳比例下限**：`audit_bps ≥ 2000`（每次 Compound 的手續費流入必須有 20% 進審計類別）——由 `treasury.ak` 在 `UpdateParams` 時強制；治理無法把審計的進帳比例調降到 20% 以下。
  - **餘額下限**：`audit_reserve_balance ≥ min_audit_reserve`——`min_audit_reserve` 是部署當下設定的**不可變** datum 欄位（V1 啟動值為 0，也就是一開始沒有約束力）。若未來的 `UpdateParams` 把 floor 拉高，就不可再調低。任何治理動作都不能把餘額花到低於當前的 `min_audit_reserve`。
- **營運 40%**——基礎設施費用（VPS、監控、Blockfrost key）以及 keeper 冗餘。
- **研發 20%**——V2+ 開發、新整合。
- **緩衝 10%**——應付突發狀況的自由儲備。

30 / 40 / 20 / 10 這個分配是**每一類內部可軟調整**的——治理可透過 `UpdateTreasuryParams`（14 天 timelock + 180 天冷卻期，每類別範圍落在 [審計下限 20%, 上限 50%]）調整進帳比例。實際的支出則走 `TreasurySpend`（7 天 timelock），每類別還有「每月上限」與「24 小時冷卻」兩道閥。

唯一有硬下限的是審計儲備（進帳比例 20% + 餘額不可變下限）。營運 / 研發 / 緩衝三者的進帳比例上下界在 [0%, 50%] 之間，但餘額無下限。

**USDCx → USD 的 off-ramp。** 營運成本（VPS、Blockfrost 訂閱、域名續約、承包商費用）多半以 USD 或 EUR 結算。Treasury USDCx 視需求轉成美元，管道有三種：(a) 透過機構帳戶進行 Circle USDC 贖回；(b) 走 Minswap → Wrapped USDC → Coinbase/Kraken 的 CEX off-ramp；(c) 啟動實體先以 USD 墊付，事後用 USDCx 償還。三條路徑都有各自的 KYC、最小金額與處理時間摩擦；啟動實體的 treasury-operations runbook 記錄當下採行的程序。Treasury 的類別帳目仍以 USDCx 計價；實際支出當下的匯率會登錄在 treasury-operations 帳簿。

Treasury 的每筆支出都要經過 `TreasurySpend` 治理動作加 7 天 timelock。

### 4.3 Keeper 經濟

V1 啟動時由創辦人擔任 keeper。在 100K TVL 下，對其他營運者而言是賠本生意：

- 100K 下 keeper 份額 = $60–96/年
- Keeper VPS + 監控成本 = $400–1,000/年
- **淨虧損：$340–940/年**（非創辦人 keeper）

**在實際的 Phase 1 TVL 區間**（§8.2 講的 **$500–$25K**，不是 100K 上限）下，keeper 份額的數學會更不利——一整年 keeper share 大概還不到 $20。所以 Phase 1 的 founder-keeper 安排是**由啟動資金補貼的 bootstrapping 設計，不是商業平衡點**。Phase 1 的 keeper 運作本來就是要由 §4.1 那筆 18 個月啟動資金的 runway 承擔的明確支出項，不對外宣稱「啟動 TVL 下能自給」。

**什麼時候開放 keeper 註冊才合理：** 要等到 TVL 達約 $5–10M，keeper 份額達到 $600–1,200/年，才接近低成本營運者的損益平衡點。V1 的 `keeper_stake_script` 已經支援 `PermissionlessWithBond` 模式，但啟動時**暫時停用**（`RegistrationMode = GovernanceOnly`）。要啟用需要兩件事：治理執行 `UpdateKeeperAuth` 動作，以及老實說——TVL 真的成長到讓開放有經濟意義為止。這是 Phase 3+ 的事，不是 Phase 1 / Phase 2 要處理的。

**三層自給 threshold —— 誠實拆解。** V1 其實有三個獨立的 self-sustainability threshold，不是單一數字；不同的 APY 假設下彼此差距達一個數量級。Keeper 份額每年 = `TVL × 毛 APY × 0.009`（4.5% 績效費的 20%）。

| 層級 | 覆蓋範圍 | 年度成本 | 6% current APY 的損益平衡 TVL | 2% pessimistic APY 的損益平衡 TVL |
|------|---------|--------:|---------------------------:|------------------------------:|
| (a) Founder-keeper 邊際運作 | Bootstrapping 階段；創辦人吸收自己的時間成本並共用現有 infra | $100–$300 | $185K – $555K | $555K – $1.67M |
| (b) Non-founder 專業 keeper | 獨立營運者、獨立 VPS + monitoring | $400–$800 | $740K – $1.48M | $2.22M – $4.44M |
| (c) 機構級 ops + 審計儲備累積 | 含未來每 18–24 個月一次 $30–50K 審計成本預提的完整協議自給 | $1,500–$3,000 ops + 攤提審計 | $20M+ | $50M+ |

本節前述的 $5–10M 數字對應 **pessimistic 1–2% APY** 下的 tier (b)（keeper 份額 = TVL × APY × 0.009）。在 current reference 6% APY 條件下，tier (b) 在 $740K–$1.48M 就成立。開頭幾段用保守數字是刻意的——V1 必須在 Liqwid 利率被壓縮的壞情境下仍能維持 keeper 運作，不只是 current reference 情境下 viable 即可。

**三維度 self-sustain 區分（讀表前先理解）。** 上表的 tier (a)/(b)/(c) 計算基於「keeper share 覆蓋 keeper ops cost」breakeven，這是 protocol 自給**三個不同維度中的第一維**：

- **(i) Keeper ops 自給**——keeper 份額（20% of 4.5% perf fee）≥ keeper 個人 infra 成本。**上表的 tier (a)/(b) 對應此維度**。
- **(ii) Treasury ops 自給**——treasury 80% 份額覆蓋 basic ops（$360/yr）+ R&D（$432/yr）+ 運營 buffer。tier (b) 的 TVL（$740K–$1.48M）產生 treasury 份額約 $2,160–$4,320/yr，**第二維也 comfortably 覆蓋**。
- **(iii) Audit-reserve self-funding**——每年 audit reserve 分配（30% of treasury inflow）累積可 cover 下一輪 audit 成本（$30–50K，每 18–24 個月一次）。此維度需 TVL **$20M+**，對應 tier (c)。

所以讀 tier 表時要注意：**tier (a)/(b) 的 breakeven 是「keeper 不虧」，treasury ops 在同一 TVL 自動 comfortably 覆蓋；但 audit reserve accrual 不夠，靠 §8.1 四源 funding stack 而非 protocol-revenue**。這是刻意設計，不是 gap。

**V1 實際的 self-sustain target 是 tier (a)/(b)，不是 tier (c)。** Tier (c) 由 §8.1 的四源審計 funding stack（Catalyst grant + 審計 firm 公共財折扣 + 透過內部審計歷史的 scope reduction + 創辦人自籌）覆蓋，不靠協議自身 treasury 累積。這與 V1 的非商業公共財定位一致——V1 不需要成長到 $20M+ TVL 才算「完全自給」。若 Phase 1 + post-audit 的成長 trajectory 在 2027–2028 年達到 tier (a)/(b)（$500K–$1M TVL），V1 就是以自己的 criterion 成功了。若成長停滯在 tier (a) 以下，§9.2 sunset protocol 啟動。

詳細規格見 `spec/keeper-auth.md` 的 RegistrationMode 狀態機。

### 4.4 V1 適合誰，以及什麼情況下其他產品可能更合適

V1 的正確對比基準**不是**自己直接 Liqwid USDCx supply（0.5–2% APY、借貸需求稀薄、有經驗的 Cardano DeFi 使用者幾乎不碰）。正確對比是**自己直接 Liqwid DJED supply**——這才是成熟使用者會親手做的事。

**2026-04-21 參考 Liqwid 供應 APY**（快照；隨借貸需求波動，每次 rebalance 重查）：DJED ~11.8%、USDM ~5.3%、USDCx ~0.5-2%。

**對真實替代品（自己直接 Liqwid DJED supply）的誠實對比**：

| 策略 | 毛 APY | 手續費 | 淨 APY | 年度工作量 |
|---|---|---|---|---|
| 自己直接 Liqwid DJED supply | 11.8% | 0% | **11.8%** | ~4 次手動 rebalance + 監控 |
| V1 vault（45% DJED / 25% USDM / 30% USDCx buffer） | 6.66% | 毛收益的 4.5% | **~6.36%** | 0（keeper 做） |
| **差距** | | | **−544 bps** | |

這差距是真的。任何有足夠 DeFi 經驗能安全自己管 DJED 部位的人，淨得收益近 V1 的兩倍。**V1 沒要在純收益上贏這個策略。** 如果那是你，自己直接 DJED supply 是對的產品。

**V1 的 544 bps 差距買到什麼：**

1. **降低營運負擔。** 進場一筆 TX 搞定（不需要手動串 swap + supply）、離場用一次 vUSDCx burn 完成（每次提領不必跑 Liqwid recall + Minswap swap back 往返）、治理更新策略時的跨市場再配置由金庫層自動完成（不必自己發手動 rebalance TX）、脫鉤事件觸發由合約層的 freeze 處理（不需要自建 oracle 監控）。附註：qToken 在 Liqwid pool shard 遷移時的可贖回性是 Liqwid 自己處理的——不管透過 V1 或直接走 Liqwid 都不用使用者操心，這部分不是 V1 獨有的價值。V1 費用差距 vs 為你省下的時間之間的損益平衡點，高度取決於你如何估自己的時薪（≈ 一季 1 小時 × 時薪 = 一年省下的時間價值——前提是你本來就會每季做一次再平衡或主動回應脫鉤事件；若你其實是完全被動持有，V1 幫你省下的時間接近於零，這也正是下表為什麼會直接說「這類使用者該選 Direct Liqwid」）：

    | 你的時薪 | V1 損益平衡存入金額 | 這類使用者通常是誰 |
    |---------|-----------------|----------------|
    | $10/小時 | ~$8K | 學生／新興市場使用者／退休者——**在這以下 Direct Liqwid 扣除時間成本後仍勝出** |
    | $20/小時 | ~$16K | 一般小資存款者 |
    | $50/小時 | ~$40K | 中職涯專業人士（早期草稿使用的數字） |
    | $100/小時 | ~$80K | DeFi 專業人士——**非 V1 目標客群** |

    **直接講結論**:一筆 $2,000 存入、在 $20/小時時薪下,V1 一年費用約 $109 vs 省下時間價值 $80——**只要你願意一季坐下來手動 rebalance 一次**,Direct Liqwid 每年還多 ~$30。V1 值得付費的使用者是以下三類:

- 把避免 DeFi 複雜度看得高於邊際時薪的人
- 原則上拒絕 CEX 託管的人
- 想要雙發行者配置、但不想同時管兩個 Liqwid 部位的人

損益平衡不是一個普適的 $40K 數字。
2. **雙發行者配置。** 啟動 45% DJED + 25% USDM 把曝險分散到兩個獨立的穩定幣發行者（Cardano Foundation 旗下 COTI 發 DJED、Mehen 發 USDM）。這可防**發行者特定**失敗（Mehen 倒閉、COTI DJED 儲備耗盡）——但**不能**防 ADA 閃崩情境同時壓垮兩者（§5.2 明確覆蓋）。使用者可自己複製配置，代價是平行管兩個 Liqwid 部位。
3. **提領流動性。** 30% USDCx 閒置 buffer（0% 收益是設計——見 §2.3 腳註）讓多數提領可在一個 TX 內結算，不用等 Liqwid Recall 往返。自己直接 DJED supply 沒這種 buffer，Liqwid Recall 要一整筆 TX 且受當下市場 underlying 餘額限制。
4. **自助退場保證。** keeper 離線 7 天以上仍可用 `emergency-withdraw` 自行回收本金（§5.4）。自建部位一旦失去當初建倉工具的存取權就沒有等效保護。
5. **多穩定幣脫鉤監控。** V1 的 keeper 持續脫鉤訊號下停止新 Deploy（§5.2）；自建部位要自己寫 + 自己跑。

**依使用者輪廓的誠實建議：**

- **DeFi 熟手、存入 > ~$40K、願意主動管：** 不用 V1，直接在 Liqwid supply DJED。544 bps 差距在此規模下是實打實的成本差，不是可以忽略的數字。
- **存入 $100-$10K、會對 DeFi 做理性計算、中等時薪（$20-40/小時）：** **誠實地先看 Direct Liqwid。** 這個級距的損益平衡點在 $16-32K，以下 Direct Liqwid 扣除手動 rebalance 時間成本後仍勝出。在這類使用者的情境下，V1 只有在你「拒絕 CEX 託管 AND 不願意一季做一次手動 rebalance」時才是對的。
- **存入 $100-$10K、明確把避免 DeFi 複雜度看得高於時薪數學：** V1 為這類使用者設計。自動化 + 雙發行者 + 流動性，對於把 DeFi 操作視為心理障礙（而非以時間成本理性計算取捨）的使用者，值這個費用。
- **存入 > $10K 但不信心自己操作 DJED：** V1 仍合理——但請把 544 bps 差距理解為 **「避免 DeFi 操作複雜度的外包費」**（多市場一筆 TX 配置、合約層脫鉤 freeze、Recall 失敗恢復、部分提領多步驟往返），**不是學費**。V1 不提供任何把使用者「畢業」到 Direct Liqwid 的教學路徑，長期付 544 bps 並不會逐步建立你自己的手動 DeFi 能力。若你最終意圖是親自管理部位，V1 不是合適的老師——把等量時間花在研讀 Liqwid 文件 + 在 Preprod 練習會更有效。

**100K TVL 下的經濟誠實揭露：** 在 pre-audit 上限，V1 自身收入（以 6% 毛收益估算約 $270/年）不足以覆蓋營運成本（~$360-2,400/年，economics.md §4）。啟動期差額由啟動資金吸收，**不會**以更高費率轉嫁給存入者——不管 V1 當下規模多小，存入者只付 4.5%。要等到 TVL 成長到 $500K-$2.5M 自給區間，同樣的 4.5% 才能同時覆蓋營運成本 + treasury 累積。

若治理後續啟用 USDCx buffer 的收益去處（見 §2.3），0% buffer 項會上升，混合毛收益提升——例如 30% × 1% buffer 端收益會增加 ~30 bps 毛。變動會在 `UpdateStrategy` 進入 queue 前公開揭露，縮小但不關閉與自己直接 DJED supply 的差距。

進一步數字見 `docs/economics.md` §4（營運成本）、§6.2（淨 APY 情境）、§6.3（替代選項對照）、§9（費用流失分解）。

### 4.5 Compound 週期與每次網路費成本

§2.5 的排程是**上限、不是目標**。Keeper 只在累計收益 × 剩餘結算窗口足以攤銷鏈上費用時才真的執行 Compound，否則等待。Zero-yield heartbeat（每 5 天一次）仍會照跑，推進 `last_realloc_time`——即使當下收益在經濟上不顯著。

V1 在 100K USDCx 上限下永遠位於 **weekly 檔**（`total_deposited` ≥ 1,200 USDCx 分層），對應的 Compound 排程是**每週六一次**。§2.5 的 4 層 TVL 分層完整列在 §2.5 Compound 頻率表中；低於 1,200 USDCx 的分層只是 keeper 程式中保留的低 TVL 恢復分支，V1 正常啟動並不會進入。

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

Keeper 端：keeper 以 **USDCx** 收取 20% 份額，可定期在 Minswap 上把 USDCx 換成 ADA 來補充自己錢包的 Cardano 網路費。每次轉換約 60 bps（每季一次約等於一年 2.4 bps），100K TVL 下近乎忽略，但會隨 keeper 份額線性放大。這筆摩擦只有當 keeper 正好是創辦人、並用其他沈沒成本一起攤銷時，才能被 20% keeper 份額（6% 毛收益下約 $54/年）吸收。這也是 §4.3 明確聲明「非創辦人營運者要到 $5–10M TVL 區間才具商業可行性」的原因；V1 並未隱瞞此點。

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

- **繼承自內部驗證階段的多輪內部審查。** 這裡的「內部審計輪次」指：針對特定威脅模型，對每一個 validator 做一次對抗性讀碼，產出分級為 CRITICAL / HIGH / MEDIUM / LOW / INFO 的書面報告；每一輪只有在所有非 INFO 發現都已修復並加上回歸測試後才算結束。完整方法論見 `docs/audit-scope.md` §2。
- **額外針對 V1 新增範圍的內部審計覆蓋**（treasury、keeper_stake_script、跨 validator 整合流程、部署流程、off-chain runtime）。這部分以領域（A–F）為單位組織，不再採用序號式輪次，詳見 `docs/audit-scope.md` §4。
- **第三方審計仍在規劃**(目標 Q2-Q3 2027——funding-stack 揭露見 §8.1),作為解除 TVL 上限的前置門檻。

**迭代修補方法論的一個實例——A2 設計缺口關閉。** 內部審查發現 V1 每個 staking validator 一開始都只寫了 `withdraw(...)` + `else(_) { fail }` 的 catch-all。Cardano ledger 驗證 stake credential `Deregister` 證書時走 Publish purpose，剛好打到 `else` → 任何 deregister 都會被拒 → ceremony PHASE 4a 投入的每個 staking validator 2 ADA 註冊押金都會被永久鎖住。修復版本（「A2」）在 staking validator 加上治理閘門的 `publish` 處理器，重用已經頻繁使用的 `is_gov_authorized(ActDeregisterStake, payload_hash_deregister_stake(own_hash))` helper。覆蓋範圍現在涵蓋 V1 全部 **12 個 staking credential**：vault_user / vault_keeper_hot / vault_batcher / vault_swap_ada / vault_protocol / vault_recall / vault_liqwid / vault_gov_policy / vault_gov_emergency / vault_admin_deploy / keeper_stake_script / minswap_v2_adapter。讓每個 credential 有 bytecode headroom 容納 `publish` handler 的 validator partitioning 記在 `spec/architecture.md §4.1`。設計決策紀錄在 `spec/governance.md §4.13` + `spec/keeper-auth.md §9`。這個迭代展示了 V1 的開發模式：發現 → 規格 → 修復 → 回歸測試 → 出貨 → 文件化。Preprod ceremony 的 ActDeregisterStake 執行流程完成後，存入者可以在鏈上驗證 A2 修復。

**讀者請注意。** 內部審查是必要的前置作業，但不能取代第三方審計。V1 真正關鍵的安全訊號是即將到來的外部審計報告——內部審計只能降低外部審計發現 CRITICAL 問題的機率，不能消除這個機率。100K USDCx 的 TVL 上限，就是對「V1 是未經外部審計的生產軟體」的明確承認。

外部審計前，除了「100K USDCx TVL 上限，由營運方強制執行」之外，V1 不對外做其他承諾。

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

**V1 大概是合適選擇的情況**：你能接受「Cardano 穩定幣籃」作為單一相關性曝險，分散只防範發行者特定的崩潰。**V1 可能不是合適選擇的情況**：你期待多資產配置能讓你躲過 ADA 崩盤——事實上它做不到。

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

### 5.3 Liqwid 協議風險

**§1.1 的刻意 scope boundary 換個角度看就是這裡的風險。** §1.1 明確說「V1 **不是** 多協議收益 aggregator」——那是刻意的產品範圍選擇，不是疏漏。從威脅模型的角度再看同一件事，它就變成存入者要承擔的風險：V1 只 route 到一個協議，那個協議一旦倒了，V1 沒有可切換的備援。本節是 §1.1 產品定位在風險面的誠實對照——兩邊描述的是同一件事，只是視角不同。

**單一協議集中度風險（V1 特定）。** V1 全部收益來自 Liqwid 一個協議——不是因為我們看好 Liqwid 勝過所有對手，而是 Cardano 當前穩定幣供應端沒有第二個達到「深度 + 審計成熟度 + Aiken 整合可行性」三重門檻的借貸協議。若 Liqwid 發生協議級失效（合約漏洞、清算機制崩潰、governance 攻擊），V1 **沒有備援協議可以快速遷移**——會被迫走 `EmergencyWithdraw` 凍結 + 存入者自助退場。Mitigation：(a) Liqwid 本身已歷多輪第三方審計 + 主網運行超過一年；(b) 任何 Liqwid 異常事件均可由治理觸發 `EmergencyWithdraw` 凍結金庫，存入者 `withdraw-cli` 自助退場路徑**完全不依賴 Liqwid 可用性**，只需 Cardano ledger 本身可用；(c) 未來 V2+ 若引入第二個供應端協議（§1.1 的方向，門檻見 §1.5.2），將降低此集中度。在 V2+ 演進發生前，存入者應將 Liqwid 協議風險視為 V1 的**單一最大鏈上風險源**——高於治理風險，也高於任一穩定幣的脫鉤風險。

V1 對 Liqwid 的曝險來自把 USDCx、DJED、USDM 供應至 Liqwid 的 action validator，並把 qToken 收據留在金庫 UTXO 裡。這帶來幾類協議風險：

- **壞帳**：若 Liqwid 的清算與準備金機制未能覆蓋擔保不足的貸款，qToken 對 underlying 的兌換率會下降。金庫供應倉位按比例貶值，會於下次 Compound 反映到 share price。
- **qToken 匯率誤算或操縱**：V1 信任 Liqwid 鏈上的匯率模型做 qToken ↔ underlying 換算。若匯率被攻擊或誤算，金庫部位價值會被錯誤入帳。
- **Pool 遷移**：Liqwid 偶爾會遷移 pool shard（`action_addr_hash` 變動）。若 keeper 對舊 pool 執行 Recall 會失敗。V1 用 `FastUpdateMarkets`（治理 1 小時 timelock）將 registry 指向新 pool 處理。
- **Action validator 升級**：Liqwid 合約更新若改變 Supply/Recall 介面，keeper 邏輯可能會壞。使用者資金仍在（合約升級不會動到資金），但收益累積會暫停直到 keeper 程式更新。

V1 的緩解措施：

- **Share price 透明化**——損失會在下次 Compound 顯現，不會被藏起來。存入者在下一個配置決策前就能看到帳面變化。
- **`EmergencyWithdraw`**——治理可以標記損失金額（`loss_amount`）並凍結金庫以規劃復原。此動作 timelock 為 0 天。
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

    - 把 `max_slippage_bps` + `min_swap_peg_bps` 加進 `VaultDatum`，由新的 `UpdateSlippagePolicy` 治理 redeemer 管理（48h timelock 為 depeg 應變敏捷性，1-of-n cancel 保留）。
    - `DeployToProtocol` 解碼 Minswap V2 route order datum，提取 `minReceive` 與 `amount_in`，強制 `min_receive × 10_000 >= deploy_amount × min_swap_peg_bps` 作為 Tier 2 peg-floor 邊界（擋下 `minReceive = 1` 極端滑點攻擊類，不需 oracle feed）。多跳透明——邊界套在**最終**輸出。
    - Tier 1（oracle-based fair-price `minReceive >= fair_out × (10_000 − max_slippage_bps) / 10_000`）會隨 Charli3 + Orcfax 雙 feed 對某 asset 達成覆蓋，透過治理 `UpdateRegistry` 更新新的 `asset_oracles` 清單，逐 asset 啟用。
    - SwapAda（§3.4 + §4.5）從單 Int MVP oracle 升級到同一套 dual-feed reader，關閉白皮書 review critic #8。

    實作時程：pre-external-audit，與審計 commit 同一個 deploy ceremony。完整的 P1–P5 滑點 stack 出貨即**全部上鏈**，不再是營運政策層；「V1 Pre-Launch Candidate」指的是這個完整強制的合約 delta（以外部審計為前提）。

    **當前狀態 — 依驗證階段分類：**

    | 項目 | Code 落地 | Unit tested | Preprod E2E | 外部審計 |
    |------|:---------:|:-----------:|:-----------:|:--------:|
    | P1 vault_admin 拆分 | ✓ | ✓ | ✓ | Q2-Q3 2027 |
    | P2 UpdateSlippagePolicy + datum 欄位 | ✓ | ✓ | ✓ | Q2-Q3 2027 |
    | P3 Tier 1 dual-feed oracle | ✓ | ✓ | partial — registry validator 已部署；`asset_oracles` 啟動時為空（治理 post-mainnet 植入） | Q2-Q3 2027 |
    | P4 Minswap V2 decoder + peg-floor | ✓ | ✓ | **outstanding** — decoder 需對真實鏈上 `SwapExactIn` + `SwapMultiRouting` TX 做 byte-for-byte 驗證（`spec/swap-adapter.md §9`） | Q2-Q3 2027 |
    | P5 SwapAda dual-feed 升級 | ✓ | ✓ | partial — vault_swap_ada 已部署；`asset_oracles[ADA]` 啟動時為空（SwapAda 暫 inactive 直到治理植入） | Q2-Q3 2027 |
    | A2 deregister `publish` 在 12 個 staking credentials | ✓ | ✓ | partial — 部分 staking credential 已驗證；12-credential 完整 Preprod 重新驗證主網前需完成 | Q2-Q3 2027 |

    「Code 落地」+ 104 個 unit + property 測試通過（599 個隨機化 checks per `aiken check`）並不取代 Preprod E2E 或外部審計。全部 22 個 artefacts（17 個 logic validator + 4 個 NFT mint policy + 1 個 DEX adapter）仍低於 16 KB Plutus V3 上限；最緊的 headroom 是 `vault_liqwid` 的 2,992 B free。（`docs/audit-scope.md §3` 用另一個 test-count metric「30 properties × 100 iterations = 3,000 fuzz runs per build」，那是只計算 `aiken/fuzz` 隨機 iteration 上限；本處的 599 是 `aiken check` summary 對整套測試的計數。完整對齊說明見 `audit-scope.md §3`。）

    **審計範圍 + 資金含意（摘要）。** 上述 pre-audit 滑點工作相對於「最小 pre-audit V1」擴大了外部審計範圍，粗估在 $50-150K 基線上多 +$15-25K，Phase 3-5 開發時程多 +6-12 週（詳細拆解：範圍新增項、成本建模、runway 影響——見 `docs/economics.md §5.2`）。兩項增量都由啟動資金吸收、不會延後 18 個月 runway 承諾；但會使 post-launch runway buffer 縮短約 1-2 個月，這會回流到 §4.1 / §9.2 的 sunset 觸發閾值計算裡。之所以在 pre-audit 就出貨滑點工作、而不是延到「V1.x post-audit」，理由是信任姿態：啟動時對外宣告、同時留著一個已知的 compromised-keeper 寬滑點攻擊路徑，比 audit-scope delta 的代價更差。
- **目的地白名單。** Registry 的 `protocol_hashes` 把 DeployToProtocol 的目的地限制在治理核准的 script（Minswap V2 orderbook、Liqwid action validator）；其他地址會被 `vault_protocol.ak` 直接拒絕。
- **Keeper 失效 fallback。** 鏈上完全以 `last_compound_time` 判斷 keeper 是否失效。當 `last_compound_time + 7d < tx.validity_range.upper` 時，會自動發生三件事：(a) 直接提領在合約層一律免收 `early_withdraw_fee`，不論 `min_hold_seconds` 是多少；(b) keeper 授權 redeemer（RecallFromLiqwid / RecallFromProtocol / AdminDeployNonDeposit）上的 `require_keeper_or_governance_fallback` gate 會開啟 m-of-n 治理 fallback 路徑——由治理以同一個 redeemer 代替 keeper 簽名；(c) `emergency-withdraw` 自助工具在經濟上變得合理，因為使用者不再付早提領費。整個機制不需要 off-chain 的 keeper 健康 oracle——在時間窗口內沒看到 keeper TX，本身就是訊號。這個比較**不能**被 TX 提交者用偽造的寬 `validity_range.upper` 騙過去：`vault_user.ak` 與 `vault_keeper_hot.ak` 對每個會寫入時間欄位的 redeemer 都強制 `validity_range.upper - validity_range.lower <= 1 hour`（內部驗證期確立的 width-cap 機制，詳見 `spec/vault-datum.md` §3 第 11 項），因此聲稱 `upper = now + 10y` 的交易會被 ledger 直接拒絕。Keeper 失效判定依賴的是實際的 ledger 時間，不是 TX 提交者的自稱。

**`last_compound_time` 與 `last_realloc_time` 的關係。** 這是 datum 裡兩個**不同的欄位**（詳見 `spec/vault-datum.md` §2.1）：

- `last_compound_time` 只有「實際收益 > 0」的 Compound 才會更新。
- `last_realloc_time` 則由 zero-yield Compound（heartbeat）以及任何配置更新（RebalanceBuffer / UpdateStrategy / reconciliation）觸發更新。

7 天 keeper 失效 gate **只讀 `last_compound_time`**。Zero-yield heartbeat 的用途是給 off-chain indexer 保持 `last_realloc_time` 新鮮的 liveness 訊號，**並不會重設 7 天 fallback 窗口**。換句話說，治理 fallback 能不能啟動，完全取決於真正的收益活動，不是 keeper 的「我還活著」ping。

最壞情況：keeper 完全停止運作。使用者一樣可以直接提領（第 7 天過後免費）或用 `emergency-withdraw` 自助工具，本金隨時取得回。

### 5.5 治理風險

啟動時為 **3-of-3 多簽**（3 位簽名者、threshold 3、全員同意才能通過）。簽名者配置為 **1 位創辦人簽名者 + 2 位獨立 Cardano 知名 SPO**，三位身份均於網站公開。3-of-3「全員同意」要求是刻意設計：即使創辦人 key 被竊或單方決策失誤，**也無法單獨 queue 任何治理動作**——必須說服 2 位獨立 SPO 同意才行；反之，創辦人串謀任一位 SPO 也只有 2-of-3，仍然不夠。1-of-3 cancel 不對稱性保留：任一位簽名者（包含任一位獨立 SPO）可於 timelock 窗口內否決已 queue 的動作。

獨立 SPO 招募於 mainnet ceremony 前完成，選擇標準：Cardano 主網 SPO ≥ 2 年營運、鏈上公開識別（pool ticker + 站點）、未與創辦人有商業合作歷史、社群技術聲譽良好、理想上至少一位於非亞洲時區以提供治理回應時間分散。

**SPO signer role 定位 —— Cardano 社群服務。** V1 啟動時的 2 位獨立 SPO signer 的 commitment **本質上是 Cardano 社群服務 role，不是 economic-incentive 驅動**。Phase 2+ 若達到 $500K TVL 觸發 `UpdateFeeSplit` 引入 5-10% gov pool share 是 upside，不是主要動機。SPO 接受這個 role 的理由：(a) 支持 Cardano DeFi 公共財基礎設施、(b) 利用其 stake pool operator 身份為 V1 存款人提供結構性異議否決保護、(c) 聲譽 / reputation asset 延伸，類似 DRep commitment 的定位。若 V1 停在 Phase 1 terminal state（§1.5.3 + §8.2 可能情境），SPO 的 commitment 不預期獲得財務回報——這與 V1 公共財、非商業性的定位相符。SPO 招募 outreach 會在 mainnet ceremony 前以此 framing 溝通，避免 signer 預期與實際激勵結構脫鉤。

相關揭露：

- 三位簽名者身份皆在網站公開（1 位創辦人 + 2 位 SPO，含 pool ticker）。
- 手續費與簽名者變更都要走 14 天 timelock；`UpdateFeeSplit` 走 21 天 timelock。
- 任一簽名者可於 timelock 內用 1-of-n cancel 否決。
- 若簽名者無法續任，有訂定有序結束協議（§9.2）。

殘餘風險：**3-of-3 全部串謀**（三位簽名者集體配合推動惡意動作）。緩解方式：(a) 三位身份公開帶來的聲譽壓力，且 2 位 SPO 各自有獨立 stake pool 需要長期維護、聲譽綁定強；(b) 14 天（或 21 天）的 timelock 窗口內存入者可從容退場；(c) validator 層的硬上限（§6.3）——即使治理全部串謀，也還是動不了這些上限。

**審計後路線圖。** 外部審計通過、TVL 成長後，治理依 §6.1 的 Phase 2/3/4 輪替。從 Phase 2 開始（5+ 位簽名者、新增社群徵選簽名者），threshold 下降到 `n-1`（例如 4-of-5），這樣任何時候都至少有一位簽名者不在通過 quorum 裡，可以行使真正的 1-of-n 結構性異議否決——把 3-of-3 啟動時「創辦人可被單獨 SPO 擋下」的保護進一步強化為「quorum 外獨立簽名者永遠存在」。

### 5.6 未經外部審計的風險

V1 雖然經過多輪內部審查，但尚未經第三方審計。**100K 的 TVL 上限就是對此風險的明確承認。** 存入者自行承擔責任。不論審計狀態為何，自助提領路徑隨時可用。

---

## 6. 信任模型與治理

### 6.1 六個獨立身份的分離目標

V1 的長期目標是讓六個身份由不同的人控制：keeper、三位治理簽名者、ref script 部署者、創辦人錢包。啟動時身份部分重疊——創辦人直接控制六個中的三個（keeper operator + 1 位治理簽名者 + ref script 部署者 + 創辦人錢包，合計 3 獨立席位；兩位治理簽名者為獨立 Cardano SPO，不在創辦人控制範圍）。完整揭露見 `docs/security-model.md` §2。

**輪替路徑**（以下使用 `threshold-of-total` 表示簽名者配置）：

- **Phase 1**（啟動到外部審計通過）：3 位簽名者（**1 位創辦人 + 2 位獨立 Cardano SPO**）、**threshold 3（3-of-3 全員同意）**——結構上創辦人為少數派（1/3）；理由見 §7.4。
- **Phase 2**（審計通過後 + TVL > 500K）：5 位簽名者（新增 1 位社群徵選簽名者）、**threshold 4（4-of-5）**——結構性異議簽名者恢復：`n - threshold = 1` 位永遠在通過 quorum 之外，可以行使 1-of-n cancel。
- **Phase 3**（TVL > 2M）：7 位簽名者（加入社群選舉席位——選舉機制 TBD，明確**不**以 vUSDCx 持有量作為投票權）、**threshold 5（5-of-7）**——`n - threshold = 2` 位 quorum 外的簽名者。
- **Phase 4**（成熟期、TVL > 10M）：評估 DAO 遷移。

### 6.2 治理動作

`spec/governance.md` 總共收錄 **14 個**治理動作 kind，最短 timelock 從快速端的 `FastUpdateMarkets`（1 小時）、`EmergencyWithdraw`（0 天）開始，中段為 `UpdateStrategy` / `TreasurySpend` / `AdminDeployNonDeposit`（7 天）、`UpdateSlippagePolicy`（48 小時），接著 `UpdateFee` / `UpdateRegistry` / `UpdateKeeperAuth` / `UpdateTreasuryParams` / `RotateSigners` / `SlashBond` / `UpdateOracleSource` / `ActDeregisterStake`（14 天），最長為 `UpdateFeeSplit`（21 天——治理在調整自己的報酬，所以 timelock 刻意最長）。

> **關於 `EmergencyWithdraw` 的 0 天 timelock。** 0 天指的是 Queue 跟 Execute **之間不設最短等待時間**，**不是**繞過治理共識。每一次 `EmergencyWithdraw` 執行仍需要**完整的 3-of-3 簽名**（§5.5 的 unanimity 要求）、queue 跟 execute 之間不管有多短的空窗仍**暴露在 1-of-n cancel 否決權下**、仍受 payload-hash 綁定約束。0 天買的是**反應速度**——當持續性脫鉤或 Liqwid 事件需要立刻凍結時，治理可以在同一次簽名 session 內 queue + execute 完成。Keeper 無法單方觸發 `EmergencyWithdraw`；keeper 的快速反應手段是 `KeeperToggleMarket`（§5.3），只能單方停掉某個 Liqwid market 的新 Supply，沒辦法凍結金庫或移動資金。

`ActDeregisterStake` 是 V1 operator 面向的「end-of-life」路徑：用來贖回 ceremony PHASE 4a 為每個 staking validator 投入的 2 ADA Cardano stake 註冊押金，走標準的 m-of-n 治理流程 + 14 天 timelock + 1-of-n cancel。**V1 的 12 個 staking credential 全部具備此路徑**：`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`、`keeper_stake_script`，以及 SwapAdapter `minswap_v2_adapter`（單純為了啟用此路徑而以 governance anchors 為編譯期參數）。每一個治理動作都滿足：

- **最短 timelock 由 `multisig_gov.ak` 於鏈上強制**——治理可以選擇更長的 timelock，但不能比最短值更短。
- **Queue 時提交 payload hash**——避免執行時被替換成別的 payload（每個目標 validator 會呼叫 `is_gov_authorized`，重新計算 `blake2b_256(cbor.serialise(payload))` 並與 queue 時的 hash 比對）。
- **整個 timelock 期間任一簽名者可以 1-of-n cancel**——單方取消即可生效。
- **目標 script 綁定**——queue 時寫入的 `target_script` 必須等於目標 validator 的 script hash，確保某個動作無法被導向另一個 validator 執行。

### 6.3 治理的硬上限

以下上限寫死在 validator 裡，治理繞不過：

- `performance_fee_bps > 450`（4.5%）——會被 `vault_gov_policy.ak` 的 `UpdateFee` redeemer 拒絕
- `early_withdraw_fee_bps > 100`（1%）——同樣被 `UpdateFee` 拒絕
- `min_hold_seconds > 21600`（6 小時）——被 `UpdateFee` 拒絕。理由：V1 採週 Compound 節奏，即使治理拉到 6 小時上限，直接提領閘門也只封閉當週的約 3.6% 時間；排隊提領路徑從不被這個閘門觀察，使用者資金無論設定值為何都不會被鎖。從原本 24 小時的設計上限收緊至此——詳見 §2.4。
- `keeper_fee_bps > 2500`（25%）、`gov_fee_bps > 1000`（10%）、或 `keeper_fee_bps + gov_fee_bps > 3000`（treasury 下限 70%）——被 `UpdateFeeSplit` 拒絕
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

### 7.4 創辦人兼任 keeper operator 與 3 位治理簽名者之一

V1 啟動時，創辦人運作 keeper instance 並同時擔任 **3 位治理簽名者中的 1 位**（其餘 2 位為獨立 Cardano SPO，§5.5）。此安排在 §6.1 揭露為 launch 階段的**單一營運方風險**——範圍僅限 keeper operator 選擇，**不涵蓋治理層**（治理由 1 位創辦人 + 2 位獨立 SPO 共同）、**不涵蓋合約程式碼**（全開源）、**不涵蓋 keeper 程式碼**（全開源且合約支援 `UpdateKeeperAuth` 切換）。

**Phase 1 3-of-3 全員同意實際能提供的保護**(誠實說法):

- **避免意外動作。** 沒有單一簽名者——包含創辦人——能因誤操作、金鑰失竊、脅迫或精神狀態不佳（喝醉、倉促、錢包被駭）而單方 queue 任何治理動作。這是真實的營運安全性質，與信任無關。
- **創辦人無法單獨通過治理。** 即使創辦人串謀 1 位 SPO，也只有 2-of-3，仍然不足以執行任何動作。任一位獨立 SPO 拒絕即可全面阻擋。
- **1-of-3 cancel 不對稱性。** Queue 需要 3 簽名，停止需要 1 個——任一位簽名者（包含任一位獨立 SPO）都可在 timelock 窗口內單方取消。
- **公開 timelock 觀察窗口。** 高影響動作 14 天 timelock（`UpdateFeeSplit` 21 天）公開曝露每個已 queue 變更，供存入者審查 + 獨立研究到執行前。
- **治理完全動不了的硬性不變式**——validator 層上限（費用上限 4.5%、配置邊界、不可變身份欄位）。見 §6.3。

**Phase 1 3-of-3 的侷限**（同樣誠實）：

- **Keeper operator 啟動時為單人營運**（非 keeper 程式碼中心化）。V1 整個 keeper 原始碼開源，任何人可讀、可稽核、可自建 instance 跑。啟動階段由創辦人運作實際上線的 keeper——保持單一簽約義務方而非因技術限制。治理 `UpdateKeeperAuth`（14 天 timelock + 1-of-n cancel）可隨時更換授權的 keeper PKH——例如 Phase 2 TVL 門檻達成後指派其他營運者，或 Phase 3 啟用 `PermissionlessWithBond` 開放 keeper 註冊（合約已實作，啟動時 `RegistrationMode = GovernanceOnly` 停用）。若當前 keeper key 被竊，7 天 keeper 失效窗口過後合約自動啟動 m-of-n 治理 fallback；這期間 Compound / swap / DeployToProtocol 暫停，但 Direct Withdraw 0% 早提領費自動觸發，本金仍然安全。
- **SPO 社交距離仍有界。** 獨立 SPO 雖非創辦人招募對象，但 Cardano SPO 生態規模有限，彼此有一定社群互動。這個「獨立性」要理解為經濟與技術獨立，不是完全陌生。

**存入者應該如何理解 Phase 1 治理：** **「1 位創辦人 + 2 位獨立 Cardano SPO 共同治理；keeper instance 仍為創辦人單運作但授權可鏈上切換；結構性保護來自 timelock + hard caps + 自助退場路徑」**。Phase 2（post-audit + TVL > $500K，§6.1）擴充到 5 位簽名者並改為 4-of-5，引入結構性異議否決特性。

**創辦人的專業背景——在這裡揭露作為補充資訊，不是主要的起源故事。** 創辦人在 OptiVaults 之前的專業工作在傳統金融產業的財富管理／私人客戶服務端。這個背景在本節（不是 §1.5）揭露，**提供給覺得這個資訊有用的讀者**作為額外脈絡：V1 的某些設計選擇——4-bucket treasury 含 audit-reserve 硬 floor、專門針對 `UpdateFeeSplit` 用最長的 21 天 timelock（因為治理正在調整自己的報酬）、跟傳統金融產品發布節奏而非加密圈啟動節奏對齊的多層 Compound cadence——確實參考了傳統金融端熟悉的產品設計模式。但 V1 **並不是定位為傳統金融洞察的產物**；主要的起源故事（§1.5）是「創辦人就是使用者」。審計方、Catalyst reviewer、投資人若想看職業背景脈絡，可以用這段；存入者應該用合約做什麼來評估 V1，而不是用創辦人的履歷。

### 7.5 Conway-era DRep 立場

V1 的金庫 UTXO 只持有必要的 ADA：符合 min-UTXO 規範，以及支付再平衡與 Compound 週期 gas 的營運緩衝。Treasury 合約累積的是 USDCx 績效費，不是 ADA。因此 V1 在 Conway-era 並沒有具規模的 ADA 部位可做 DRep 投票委託；金庫不是大規模 stake pool 委託者，Treasury 也不會對 Cardano 協議參數做鏈上表態。若未來營運累積出可觀的閒置 ADA（例如未來的 stake-based keeper-bond 方案），屆時可新增 `TreasuryDelegateDRep` 治理動作來處理委託。

---

## 8. 路線圖與里程碑

### 8.1 啟動前門檻

- [ ] V1 合約完成、全部測試通過、內部審計輪次完成
- [ ] Preprod 部署 + E2E 驗證（全 17 logic validators + 4 NFT mint policies + 1 DEX adapter，完整流程）
- [ ] 委託外部審計並完成
- [ ] 審計發現修復
- [ ] 部署儀式 Preprod 演練

**外部審計委託(目標 Q2-Q3 2027)。** 本白皮書撰寫時審計機構尚未選定或簽約；委託以「V1 Aiken 實作功能完整且內部審查通過」為前置條件。候選機構將自具有 Cardano Plutus V3 + Aiken 先前經驗的審計方短名單中選出——這是一個相對狹窄的集合（發表時點包含 Anastasia Labs、MLabs、Certik-Cardano、TxPipe 以及少數獨立 Aiken 審查員）。簽約機構與範圍將於審計啟動前至少 2 週公開公布。

**審計發現處置。** 若外部審計出現 CRITICAL findings、需合約重新設計的項目、或系統性設計缺陷，mainnet 啟動會延期，直到修復 + 重新審計確認通過。若審計發現當前架構無法修復的系統性缺陷，V1 啟動會取消、架構重設會公開發布，且 V1 **沒有外部貢獻者出資／代幣預售／SAFE / SAFT 義務**需要清算——未支用的啟動資本留在啟動實體手中，供修訂後設計使用。

外部審計資金來自專案創辦資本（而非現有存款——internal-verification 階段部署有獨立的營運預算）。`docs/economics.md §5.2` 裡每次委託 USD 50–150K 的區間，是根據 2025-2026 年間 Cardano 具備 Plutus V3 審計能力的公司（Anastasia Labs、MLabs、Certik-Cardano、TxPipe）公開定價指示所估算；實際委託金額會在合約簽定時公開揭露。

**審計資金策略（公共財路徑下的 sustainability）。** V1 的公共財定位讓我們可以同時動用多個 non-dilutive funding source 降低 audit 成本負擔:

- **(a) Cardano Project Catalyst grant**:V1 的「Cardano DeFi public-goods reference implementation」定位完全 fit Catalyst 的 DeFi / Infrastructure / Open Source 主題,若有合適 Round 開,預期可取得 **$30K-$50K** 資助。**撰寫時的狀態:Cardano Project Catalyst 處於暫停 / 重組狀態,下一個 Round 何時恢復尚無明確時程。** V1 把 (a) 列為候選資金來源、等 Catalyst 恢復,但**不依賴它**;審計時程(目標 Q2-Q3 2027)即是為了讓 Catalyst 在此區間恢復、或讓 funding 完全由 (b)+(c)+(d) 來源覆蓋,兩種路徑都留得到時間。
- **(b) Audit firm 的 public-goods pricing**:Apache 2.0 + 非商業定位可能取得 **30-50% 折扣**,從全價 $100K-$150K 降到約 $50K-$90K;
- **(c) Scope reduction via extensive internal audit**:累積的多輪內部審計歷史作為 preparatory material 讓外部審計範圍可聚焦在 critical paths(2-3 個 most critical validators + 跨 validator 整合流程),而非全部 17 個 logic validator + 1 個 adapter 全範圍,再降約 **$15K-$25K**;
- **(d) 創辦人自籌補完 (Founder self-fund)**:扣除以上 mitigations 後,若 (a) 達成則預期創辦人個人實際承擔 **$20K-$40K**;若 (a) 在審計啟動前未達成,則上限拉高至 **$50K-$90K**。

**審計時程反映 funding-stack 不確定性。** Q2-Q3 2027 目標明確比原本 Q3 2026 計畫晚,刻意預留時間以容納 (i) Catalyst Round 恢復的概率、(ii) Cardano Foundation / Intersect / Aiken Foundation 等 alternative grant 的接洽、(iii) 若 (a)/(b) 結果保守時,founder runway 累積的時間。V1 在整個過渡期間都維持 pre-audit 姿態(100K USDCx hard cap)——見 §4(TVL 上限)與 §8.2(Phase 1 framing)。在任何 plausible 資金情境下,**審計本身不取消;只是起跑日期推遲**。

各 funding source 進度會在 `docs/economics.md §5.2` 持續更新。這個 stack 讓 V1 可以在不進入 VC / 代幣募資 / 不稀釋 Apache 2.0 公共財立場的前提下完成外部審計。

### 8.2 啟動（TVL 上限 100K USDCx）

**Phase 1 的真正性質——誠實標示。** V1 在 100K USDCx 上限下的啟動是 **對抗性條件下的協議驗證**，不是商業 TVL-scale 發射。100K cap 是**上限，不是目標**。我們內部對 Phase 1 TVL 的預期是**頭 6-12 個月落在 $500-$25K 區間**——這是推測性區間，不是預測，基於保守的使用者取得假設加上 permissionless-only 立場（沒有 closed-beta gate，因此若 organic discovery 緩慢，下限可能極低）；實際結果可能往任一方向顯著偏離。以「填滿 cap」情境為基礎模擬 Phase 1 的讀者，應該知道那並不是我們在規劃的結果。

**Pre-audit 期間的營運姿態。** Pre-audit 階段 V1 不做 marketing 推廣、landing 只維持 organic SEO。合約本身是 permissionless smart contract，任何理解並接受 pre-audit 風險（未知 CRITICAL bug 可能、TVL 不會快速成長、founder bandwidth 有限）的 depositor 都可依自己判斷進入——沒有 invitation gate，沒有 whitelist。但請**誠實預期**：這不是 opening sale 階段，而是驗證階段；想規模化入場或追求最大化 yield 的 depositor 建議等 post-audit cap 解除、或直接選 Direct Liqwid DJED supply。

**Phase 1 TVL 是 range，不是 target。** 早期白皮書草稿假設 Phase 1 TVL 會落在 $5K-$25K，路徑是「closed beta 框架下從 founder 人脈圈招募 ~10-15 位 depositor」。該框架已移除，改為純 permissionless + risk-disclosure。後果是：**實際 Phase 1 TVL 將完全取決於 organic discovery 與個別 depositor 自行的風險評估**，可預測性顯著低於 closed-beta 框架下的預期。可能結果包括：(a) **$500–$5K**（只有 founder + 1-2 位社群 depositor；只要 Phase 1 期間沒出現 CRITICAL bug，仍算成功的 Phase 1，因為驗證目的已達）；(b) **$5K-$25K**（先前的預期，現在視為中段情境）；(c) **$25K-$100K**（高於預期；會觸發 frontend 加強警示提醒 pre-audit 風險密度，但不會有合約層額外限制——既有的 100K cap 仍是唯一硬上限）。三種結果都是 Phase 1 可接受的結尾，沒有任何一個本身代表「失敗」。Phase 1 成功與否以下方 (a)-(d) 成功準則衡量，不以 TVL 規模衡量。

這個姿態基於同時存在的兩項事實：

1. **$500K-$2.5M 自給 TVL 閾值依定義是 Phase 2+ post-audit 目標。** 在 $100K cap 時代無法到達。Pre-audit TVL 成長超過 ~$25K 會超出存入者應接受的風險範圍。
2. **Pre-audit 誠實的成功準則不是「填滿 cap」：**
   - (a) 審計期內已部署合約無 CRITICAL 被攻擊
   - (b) 自動化系統（keeper + API + 前端）在真實使用者流量下以「有意義但仍小規模」正確運作
   - (c) 透過透明的治理行動 + 公開事故史建立社群信任
   - (d) 交接給外部審計方一個真實運作、審計方可實際壓測的系統

達成全部四項、TVL $15K，是 **成功的 Phase 1**。達成 TVL $80K 但四項有任何一項未驗證，是 **被數字掩蓋的失敗**。

**Phase 1 啟動的操作面：**

- V1 mainnet 部署儀式（約 27–30 筆 TX：17 個 logic validator 的 ref script + 1 個 SwapAdapter 的 ref script+ 3 個一次性 ceremony NFT 鑄造（Vault Identity / Governance / Registry Auth）+ 每位簽名者加入時分別 on-demand 鑄造 gov_signer_nft + vault / registry / governance / treasury / keeper_stake 的 UTXO 初始化）
- 公開宣告 + 內部驗證期存入者遷移窗口
- 前 100 個遷移錢包：早提領費由審計儲備補貼
- **對外溝通的基調**:訴求明確是「歡迎小額存入協助在真實條件下驗證系統」——V1 不是高收益獵取的管道。這個 signal 是為了避開那些追求 yield 最大化、本來就該走 Direct Liqwid DJED 的使用者;他們直接用 Liqwid 對他們更有利,不是 V1 挑剔他們。

**部署儀式部分失敗處置。** V1 部署儀式大約是 27–30 筆交易的序列：先鑄三個 one-shot NFT（Vault Identity、Governance、Registry Auth），接著發佈 **18** 個 reference script（17 個 logic validator + 1 個 SwapAdapter），接著初始化 Registry + Governance + Treasury + Keeper Stake 四個 UTXO，最後才初始化 vault UTXO 自身。每一筆 TX 都是 idempotent-safe：每次成功後 state 會 checkpoint 到本地 JSON，部署腳本重跑時會從上次的 checkpoint 續行。部分失敗不會留下破碎狀態——進行中的儀式把 reference script 和 identity NFT 暫留在部署錢包地址，直到 vault UTXO 初始化 TX 完成為止。唯一不可恢復的失敗情境，是「已鑄的 one-shot NFT 其部署時 validity range 到期前儀式沒跑完」；應對方式是以新的 `RELEASE_TAG` 跑一次全新儀式，並另外用一筆 sweep TX 把孤立 reference script 裡鎖住的 ADA 回收回來。完整 runbook：`docs/runbooks/v1-mainnet-ceremony.md`（隨 V1 實作一併發佈）。

**Reference-script 資本鎖定。** V1 的 17 個 logic validator 加上 `minswap_v2_adapter` SwapAdapter 每一個都以 Cardano **reference script UTXO**（CIP-33）形式發佈到部署錢包地址。Reference script 帶有 Conway-era 的 min-ADA，隨序列化 script 大小而增；以當前協議參數加上 operator 的 1.10× safety multiplier，~5 KB 的 proxy script 鎖 ~27 ADA，~10 KB 的 validator 約 49 ADA，最大的 ~13.5 KB staking validator 約 64–66 ADA。18 個 reference script（17 個 logic validator + 1 個 DEX adapter）合計，V1 部署大約鎖定 **870 ADA（以近期 ADA 市價估算約為低三位數美元）** 作為 reference-script min-UTXO。（V1 Preprod 部署實測為 871.51 ADA。）此外還有 **24 ADA 的 stake credential 押金**（12 個 staking validator × 2 ADA each，全部可在 14d governance timelock 後透過 A2 deregister `publish` handler 回收，見 §6.2）。儀式總資本承諾：**~895 ADA 可回收**，加上 ~22 ADA 不可回收的網路 TX fees + ~27 ADA 的 state-UTXO 種子 ADA（vault / registry / treasury / keeper-auth / governance script address），合計 **~944 ADA** 在儀式結束時。部署錢包地址持有 18 個 ref-script UTXO——它們是每次 vault TX 的**可花費 reference input**，但**除非花掉 UTXO 本身（會停用該 reference script），否則無法回收**。V2 遷移計畫：新版本部署時，V1 的 reference script UTXO 會被一次性 reclaim TX 花掉並取回，鎖定的 ADA 扣掉每次儀式約 2.5 ADA 的 TX fee 後回到部署錢包。部署錢包簽名 key 由啟動實體持有；此處明確揭露，讓存入者知道 ~870 ADA 的啟動資本於部署當下承諾於 V1，僅在 sunset / V2 遷移時才能取回。

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
- **結束協議透明**——若創辦人無法繼續，有 90 天通知 + fee 歸零 + Liqwid 部位預先 recall 完成前置條件（見 §4.1 sunset 機制） + `EmergencyWithdraw` 治理路徑 + `emergency-withdraw` 自助工具可走。
- **架構上不設計「抽乾資金跑路」（rug-pull）的後門。** 任何可能抽乾資金的不變式都在 validator 層封閉，不留給社會信任層。
- **創辦人失能應對（Founder incapacitation protocol）。** V1 啟動時創辦人同時擔任 keeper operator、1 位治理簽名者、ref-deployer wallet 控制者，個人層級單點故障是真實的。應對機制：(a) **短期失聯（< 7 天）**——合約層 7 天 keeper inactivity 窗口自動生效，Direct Withdraw 路徑完全可用且 early-withdraw fee 免除；(b) **中期失能（7-30 天）**——2 位獨立 SPO 可透過 `UpdateKeeperAuth` 治理動作(14 天 timelock + 1-of-n cancel)把 keeper PKH 切換到社群接手者；(c) **永久失能**——2 位 SPO 觸發 §4.1 sunset path(90 天預告 + fee=0 + 存入者自助退場)。Ref-deployer wallet key 目前由創辦人獨自控制，若此 key 遺失或無法存取，~420 ADA 的 ref-script 資本會永久鎖定(但**不影響存入者提領**，因為 ref-script 仍可作為 reference input)。V2 部署儀式會納入 multi-sig ref-deployer wallet 或社群 key escrow 機制消除此 SPOF。

### 9.3 仍然可能出錯的地方

即使多輪內部審查已經處理掉目前發現的問題，下列情況仍然可能發生：

- **V1 獨有的新範圍**（treasury、keeper_stake_script）在外部審計前仍可能存在未知漏洞
- 利用尚未考慮過的交互關係的**新型攻擊**
- **外部協議失效**（Liqwid、Minswap、Circle / xReserve / USDC）級聯影響到 V1

100K 上限不是一個建議值——它是對「V1 是尚未經外部審計的生產軟體」的明確承認。

### 9.4 V1 已知限制(公開揭露,不藏著)

- **V1 全部 12 個 staking credential 的 2 ADA stake 押金都可回收。** `vault_user` / `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada` / `vault_protocol` / `vault_recall` / `vault_liqwid` / `vault_gov_policy` / `vault_gov_emergency` / `vault_admin_deploy` / `keeper_stake_script` / `minswap_v2_adapter` 每個都帶自己的 A2 治理閘門 `publish` handler — sunset 時可透過治理流程合計回收 24 ADA。（早期 monolithic-validator 拓撲因 16 KB ceiling 與 `publish` handler 的 bytecode 衝突，最大 validator 曾有 2 ADA 永久鎖定的 caveat；現在的 partitioning 已經解除這個限制，詳見 `spec/architecture.md §4.1`。）
- **100K TVL 上限「不」在合約層強制** — 由 operator 透過前端存入 gating + keeper `tvlCapMonitor` 告警執行。這是 V1 刻意的設計選擇，不是疏漏。內部審查曾設計過合約層版本（`max_tvl` datum field + `ActUpdateTvlCap` 7 天 timelock 治理動作，當時稱 Option B），最終沒出貨，理由有二：(1) 上限的存在意義只在 pre-audit 期作為審慎訊號；外審通過後要嘛放寬無限、要嘛 V2 重部署時拿掉，合約層動態調整機制對「一次性生命週期事件」是過度工程。(2) V1 啟動雖為 3-of-3 unanimity 搭配 1 位創辦人 + 2 位獨立 SPO（§5.5），3-of-3 能擋下創辦人單方 queue，但上限調整的「正確性」判斷並非 SPO 的核心領域（他們是 stake pool 營運者，非 vault 經濟模型設計者）；在 pre-audit 期把上限交給 SPO 裁決也不是真正的制衡關係——誠實標記為「operator-enforced」比裝扮成「contract-enforced」更有品格。希望多一層合約層存入上限保護的 存入者，請等 Phase 2 gov 輪替（外部 signer 加入，§6.1）——屆時才有實質 dissent-veto 語意，V2 會重新評估。
- **Reference-script 資本鎖倉。** V1 的 18 個 reference script UTXO（17 個 logic validator + 1 個 SwapAdapter）部署在 deploy wallet 地址，合計佔用約 **870 ADA**（Conway 時代的 per-byte `minFeeRefScriptCostPerByte` × 1.10× operator safety multiplier — V1 Preprod 實測為 871.51 ADA），若 operator 決定 sunset 部署可透過 `deploy/tools/reclaim-refs.ts` 回收。此外還有 24 ADA 的 stake credential 押金（12 × 2 ADA）可透過 A2 governance 在 14d timelock 後回收。詳見 §8.2 的 pre-launch 審計背景。
- **架構複雜度成長。** V1 第一版是 12 validators；目前拓撲是 **22 個 artefacts**（17 個 logic validator + 4 個 NFT mint policy + 1 個 DEX adapter），80% 的成長是被 Plutus V3 16 KB reference-script 上限 + §5.4 P3-P5 滑點 stack 新增推動的。每加一個 validator 就增加 (a) 一個獨立的審計範圍面、(b) 一組額外的 compile-time anchor、(c) 一個額外的 reference-script UTXO（目前參數下約 ~50 ADA each）、(d) 一筆額外的 deploy ceremony TX。對首次部署的淨效果：ref-script 鎖定從早期估的 ~400 ADA 增加到實測的 871.51 ADA（+118%），ceremony TX 從 ~18 增加到 27-30（+50%）。對外部審計預算的影響：**12 個 staking-credential 的 A2 `publish` handler 必須各自被審計**（不像之前 single-validator vault_core lock 的情境是被歸在審計範圍外），所以「解除 vault_core 2 ADA 永久鎖定」是用「擴大審計表面」換來的。未來 feature 加入有可能再觸發拆分——一個 V1 cycle 內從 12 → 22 的 trajectory 暗示 V2 需要 (a) 接受更高 artefact 數作為新 baseline，或 (b) 用 on-chain dispatch table 整合。V1 明確選擇 (a)，因為 design freeze → audit → launch 的順序不容許後期重新架構；V2 會重新評估。
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

- `architecture.md` — **17 個 logic validator** 目錄與 redeemer 細節（+ 4 個 one-shot NFT mint policy + 1 個 DEX adapter = 合計 22 個 artefact）；§4.1 說明 partitioning rationale（4 個正交切割面：authorization-boundary / response-latency / bytecode-cost-center / size-fix）
- `vault-datum.md` — VaultDatum schema（**28 欄位**，§5.4 Phase 2 後加入 `max_slippage_bps` + `min_swap_peg_bps`）、不可變 / 治理可變 / 操作可變分類、每個 redeemer 的 state-transition 矩陣
- `governance.md` — 14 個治理動作 kind（包含 `ActDeregisterStake`，作為 operator 端的 stake 押金回收路徑）、timelock 下限、啟動簽名者集合與輪替路線圖
- `multisig-gov.md` — MultisigGov validator 內部細節、action_id / payload_hash 計算、`is_gov_authorized` 跨 validator helper
- `gov-nft.md` — Gov Signer 靈魂綁定 NFT 鑄造政策（僅作聲譽、不可轉讓）
- `keeper-auth.md` — `keeper_stake_script` 狀態機、週輪替、A-Plain 授權、PermissionlessWithBond 模式
- `treasury.md` — TreasuryDatum schema、4 類預算、Receive / Spend / ReceiveGovForfeit / UpdateParams redeemer
- `order-batch.md` — OrderDatum + BatchProcess、pre-batch snapshot 定價、使用者自訂 batcher tip
- `ada-swap.md` — SwapAda redeemer（金庫 ADA 補充閉環）、Charli3 + Orcfax oracle 讀取
- `vault-nft.md` — Vault Identity NFT 的 PlutusV3 UTXO-ref one-shot 設計

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

**Non-investment product / non-solicitation。** V1 是 Cardano DeFi 公共財 reference implementation（見 Executive Summary 的定位宣告），**不是投資產品、不是 fund、不是 managed service**。4.5% Performance fee 覆蓋協議運營 + 審計儲備 + 長期 runway，不產生創辦人或投資人的收益。本白皮書是對 V1 設計與啟動條件的**事實描述**，不構成投資建議、不構成任何形式的招攬。智能合約存入本身涉及全部損失的風險。

**Geographical posture。** V1 是 Cardano 鏈上 permissionless 智能合約，技術上任何持有 Cardano 錢包的人都可以互動。但 V1 是為 Cardano 原生使用者設計，**不主動提供服務給任何法域的居民**。存入者必須**自行判斷**其所在司法管轄區（特別是美國、歐盟、英國、中國、OFAC 制裁名單國家）是否允許使用非託管 DeFi 公共財 infrastructure；合規責任由存入者自負。V1 的前端（optivaults.app）可能基於法律意見在特定法域**顯示警告或阻擋存取**；這是**純前端 soft signal**，不限制底層鏈上智能合約——使用者若繞過前端直接與合約互動（例如透過 `withdraw-cli` 或自建 TX），完整自行承擔該法域合規責任。**V1 合約本身不做地址白名單或地理限制**，這違背 non-custodial + permissionless 設計本質，也不在 roadmap 內。任何前端 geoblock 變動會於公開 channel（optivaults.app + Discord）通知。若你所在法域明確禁止使用非託管 DeFi 或未登記金融服務,**不要使用 V1**——即使技術上繞過前端做得到。

**Code-is-law 姿態。** V1 是 open source / Apache 2.0 / 部署後 validator hash 永久不變。存入者存入時即接受「合約在鏈上以其部署時的形式執行」——沒有任何個人、團隊或治理動作能修改合約邏輯本身(治理只能在合約授權的 parameter 範圍內調整)。若合約 bug 導致損失,自助 `emergency-withdraw` 工具是唯一恢復路徑;**無任何法律追索可讓已確認的鏈上 TX 逆轉**。這不是 bug,是 V1 的核心設計選擇——你的資金不被 intermediary 掌控的代價是 intermediary 無法為你恢復意外。

**Depositor 自行盡職調查。** 存入者必須自行對 OptiVaults V1、USDCx(Circle / xReserve)、Liqwid、Minswap V2、Cardano 協議本身做完整 due diligence。**任何「V1 為我管理風險」的期待都是誤解定位**——V1 只是將風險公開、分散、並在架構上讓你隨時可退場(見 §5 Risks 完整揭露 + §6.3 治理硬上限)。V1 不是 insurance、不是 advisory service、不是 wealth manager。

**聯絡資訊。** 安全揭露(PGP key 見 optivaults.app/security)、遷移補貼申請、一般諮詢:`optivaults@gmail.com`。即時討論請到 Discord(連結於 optivaults.app)。

---

**白皮書 V1.0 結束**
