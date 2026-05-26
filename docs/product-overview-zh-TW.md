# OptiVaults V1 — 產品總覽

**寫給誰看**：正在評估是否要存入 V1 的使用者。
**不是什麼**：不取代[白皮書](../whitepaper/whitepaper-zh-TW.md)、[security-model](security-model.md) 或 [economics](economics.md)。這份只是簡短的實務說明；想看完整技術與威脅模型細節，請讀那三份。

---

## 1. 一段話說明 V1

OptiVaults V1 是 Cardano 上的非託管智能合約 vault。使用者存入 USDCx，vault 會把所有人的存款匯集起來，組成一個由 USDCx、DJED、USDM 三種穩定幣構成的混合部位，投入 Liqwid Finance 賺取借貸收益。存入後你會拿到 **vUSDCx** 份額代幣，數量與存入金額成比例；隨著 vault 累積收益，vUSDCx 可換回的 USDCx 會逐漸變多；想退場時，銷毀 vUSDCx 就能取回對應的 USDCx。**沒有任何第三方能動用你的資金**，整套機制由公開可讀的智能合約加上一組治理多簽組成，而治理多簽只能在合約硬編碼的上限內調整協議參數。

**V1 是 Cardano DeFi 公共財參考實作 (reference implementation),不是商業產品**:4.5% 績效費用於覆蓋協議運營 + 審計儲備;**沒有股權、沒有代幣、沒有對投資人的分配**。**Keeper share 的揭露**:績效費 40%(約佔收益的 1.8%)流入 keeper 錢包作為營運補償。由於 V1 啟動時由創辦人運作 keeper,**確實有 USDCx 流入創辦人的 keeper 錢包**(100K cap 下年化 ~$108;實際 Phase 1 sub-scenario 下 < $30/年)。但**這低於 keeper 自身基礎設施成本**(基礎設施 + monitoring 一年 $400–1000,見白皮書 §4.3),所以這個位子對創辦人來說是**淨成本中心,不是利潤線**,虧損由啟動資金 runway 吸收。Apache 2.0 授權讓其他團隊可以 fork 下來做特化。存入者應以「貢獻公共財 + 當早期驗證者」的心態參與,不是購買商業服務(完整定位見白皮書 Executive Summary + §0 + §12 免責聲明)。

**V1 尚未完成第三方審計,整體存款上限 100K USDCx(約 $100K)。** 這個數字是上限,不是目標,Phase 1(啟動後頭 6-12 個月)預期 TVL 落在 **$500-$25K** 之間(下限反映 permissionless 合約 + 小額存款的現實情境,三種情境拆解見白皮書 §4.1 + §8.2)。換句話說:我們希望小規模、務實的使用者在真實環境下協助驗證系統,不是衝 TVL 的快速募集。外部審計目前目標 **Q2-Q3 2027**(反映 Cardano Project Catalyst Round 時程不確定性,見白皮書 §8.1),審計通過後才會放寬上限。

**關於目前已部署的合約(請仔細讀)。** 另有一份 **internal-verification 期的舊版合約迭代**(pre-V1)目前已在 Cardano mainnet 運作,前端為 **founder-gated**(`vault.optivaults.app` 的 deposit 只開放給創辦人錢包;withdraw 對所有 internal-verification 期的 depositor 開放)。**這份部署不是**本文件描述的 V1 設計,V1 是另一組全新的合約,要等 §1.5 啟動條件成熟時才依白皮書 §8.2 進行自己的部署儀式。Internal-verification 期已存入的使用者,V1 啟動時會有 migration 窗口;新使用者則直接走 V1 合約。完整差異說明見白皮書 §0 + §4.1 + §8.2 + `migration.md`。

**程式住在哪(兩個 repo)**。你可以在 GitHub 讀到 V1 的每一行原始碼,它拆在兩個 Apache-2.0 公 repo:

- **協議層**:[`optivaults-protocol`](https://github.com/OptiVaults/optivaults-protocol):實際控制你資金的 Aiken 智能合約、白皮書、部署流程。**你的 vUSDCx 由這一層鑄造;4.5% fee 上限、no-admin-drain 不變量、keeper 停擺 7 天免費提領**,這些都由這層強制。Fork 跑自己的完全免費。
- **Operator 層**:[`optivaults-reference`](../../optivaults-reference):運營 `optivaults.app` 的 TypeScript 程式(keeper、API、frontend、恢復 CLI)。這層就是 4.5% fee 支撐的對象。歡迎 fork;fork 運營者跑自己的實例、自訂費率。

**你的 USDCx 在金庫裡時,保護它的是智能合約,不是 OptiVaults 這家機構**。這個區分很重要,因為**若 OptiVaults 明天消失,你的存款仍可透過 self-serve 工具(`withdraw-cli` / `emergency-withdraw`)取回,不需要我們的基礎設施**。完整兩層架構見白皮書 §3.5。

---

## 1.1 V1 在一堆選項裡的獨特之處

以下這些是 V1 提供、而現有 Cardano DeFi 替代方案（Direct Liqwid / CEX earn / 自己保管 USDCx）**沒辦法一次給你的整組特性**，不是行銷話術，每一項都可直接驗證合約原始碼或鏈上狀態：

- **一筆 CIP-30 交易 = 三穩定幣分散 + 自動複利。** Cardano 上唯一打包「45% DJED + 25% USDM + 30% USDCx buffer」一筆 deposit TX 完成的產品。直接 Liqwid supply 要 2-4 筆 TX 進場 + 每次 recall 另一組 TX 來回。
- **存款人保護是合約 invariant，不是營運承諾。** 4.5% 費率 immutable、沒有 admin-drain redeemer、Withdraw 無暫停開關，全部寫進 validator hash，治理改不掉。驗證方式：讀 `contracts/validators/` 下的 validator 原始碼（使用者流程主要落在 `vault_user.ak` + `vault_keeper_hot.ak`，UpdateFee cap 落在 `vault_gov_policy.ak`）+ `aiken build` 重現 hash 與鏈上部署對照。
- **自助退場不需要任何 OptiVaults 基礎設施。** `withdraw-cli` + `emergency-withdraw` 網頁工具讓你直接對 Cardano 鏈建構並簽署 withdraw TX，不需要我們的 API、keeper、或 server 運作。V1 的 0.1% early-withdraw fee（屬於 buffer 設計的 structural fee）在 keeper 離線 7 天後合約自動免除，所以 self-serve 路徑完全免費。
- **vUSDCx 是標準 Cardano 原生代幣**（不綁原始存款錢包位置）。可送人、若未來出現二級市場 / lending market 時可抵押或出售，**這是 future-value 特性**，pre-audit 期間不一定直接用得到；對比 Liqwid qToken 必須從原始存款錢包 redeem。
- **Apache 2.0 完全開源、fork-welcome。** 其他 Cardano 團隊可免費 fork + 特化自己的變體（不同穩定幣組合、風險姿態、區域變體）。

其他 Cardano DeFi 產品可能有其中 1-2 項，但**五項同時成立**的只有 V1。若你是為這組特性而來，下面的章節會把每一項的合約保證與外部依賴但書都一項項列清楚。

---

## 2. 怎麼操作

### 2.1 存款

1. 前往 **optivaults.app/deposit**。
2. 連接 Cardano 錢包（Eternl / Lace / Vespr / Typhon / Yoroi 都可以；其他支援 CIP-30 的錢包原則上也能用，但只有這五款做過實測）。
3. 輸入要存入的 USDCx 金額並確認。
4. 錢包會跳出一筆待簽交易。**請先看過交易細節再簽**，OptiVaults API 雖然在伺服器端組交易，但最終簽名仍由你的錢包完成；你有能力驗證後再簽，不是盲簽。
5. 簽完送交 Cardano。
6. 交易確認後（約 1 個 block，20-40 秒），**vUSDCx 份額代幣會出現在你的錢包**。拿到的份額數等於「存入金額 ÷ 目前份額價格」。份額價格從 1:1 起算，隨 vault 累積收益逐步上升。

成本：Cardano 網路費約 0.5 ADA（以目前 ADA 價格換算約 $0.25）。這是你唯一要付的存款成本，**我們不收任何存款費**。

### 2.2 提款:三種路徑

| 路徑 | 適用情況 | 機制 | 結算時間 |
|------|---------|------|---------|
| **直接提款（Direct）** | 一般情況 | 單筆 TX，錢包銷毀 vUSDCx，vault 把 USDCx 直接送到你的地址 | 即時（下一個 block） |
| **排隊提款（Queue）** | vault 的現金緩衝暫時不足 | 提款單進入 order 佇列，keeper 下一個批次週期統一處理 | 通常一小時內 |
| **緊急提款（Emergency）** | 我們離線超過 7 天 | 你自己執行 `withdraw-cli`，或使用 emergency-withdraw 網頁工具 | 即時，無需我們配合 |

**這三條路在鏈上隨時都對你開放**，沒有一條需要治理批准、需要 keeper 在幾小時內回應、或需要任何鏈下訊號。智能合約加上 Cardano 帳本就夠了；就算我們明天全部消失，你仍然可以送出提款 TX。**誠實的但書**：「能提領」跟「能 1:1 USDCx 結算」不是同一件事。結算速度與產出品質取決於 (a) Cardano 鏈的 uptime、(b) 你錢包裡有 ADA 付網路費、(c) 若你的份額含 Liqwid 部位則需 Liqwid 可用、(d) 提領當下 USDCx 的市場流動性。在多協議同時出問題的危機情境（Liqwid 壞帳 + 穩定幣脫鉤 + DEX 流動性枯竭同時發生），你在鏈上的請求權仍能強制執行，但結算可能是 vault 當下持有的資產，不一定是足額美元價值的 USDCx。連動崩盤情境見 §6.6。

成本：依路徑不同，網路費約 1-2 ADA。如果在最近一次 Compound 之後的 `min_hold_seconds` 窗口內提款（啟動值 60 秒，上限 6 小時），另加 **0.1% 早提款費**。這筆費用會留在 vault 裡，以份額價格上升的形式分給繼續持有的人，換句話說，若你選擇長期持有，別人的早提款費反而對你有利。若 keeper 連續離線 7 天以上，合約會**自動免除**這筆早提款費。

### 2.3 就是這樣

沒有 staking、沒有待領獎勵、沒有需要你參與的治理投票。存、持有、想提就提。

---

## 3. 為什麼這些保護是合約強制的（不是營運承諾）

V1 §1.1 列的 5 條獨特之處，沒有一項依賴「我們承諾會做」，全部是 Cardano PlutusV3 validator 在鏈上強制執行的屬性，任何人都可自行閱讀驗證。以下把 5 項一項項列清楚，每一項列出**合約強制的保證**與**仍需外部條件的但書**（若有）。

1. **Withdraw 不能被任何人凍結。** Withdraw redeemer 只要有你的簽名加 vUSDCx 銷毀就成立;治理擋不住、keeper 擋不住、**沒有任何「暫停提款」的後門按鈕**(刻意不設計)。提款 TX 提交不出去的情況只有三種:
   - **Cardano 鏈本身暫停**:這是鏈層事件,所有 Cardano 應用都會一起受影響
   - **Vault UTXO 被其他交易先搶走**:這時改走排隊提款、一小時內仍可結算
   - **錢包沒有 ADA 付網路費**
2. **本金不可能被 admin 拿走。** 合約中不存在任何 admin redeemer 能把 `idle_buffer` 送到非存款人地址。`EmergencyWithdraw`（治理 m-of-n）可以標記損失（等比例下調所有持有人的份額價格），但不能把資金轉出 vault。Validator 層硬編碼的上限（白皮書 §6.3）也排除了治理把費率設超過 4.5% 或任一市場配置突破 100% 的可能。
3. **4.5% 費用上限 immutable。** 這由 `vault_gov_policy.ak` 的 UpdateFee redeemer（透過共用的 `validate_update_fee` helper）硬鎖，治理動不了。
4. **所有治理動作有 timelock + 1-of-n cancel。** 每個治理動作在 QueueAction 時就公開，timelock 依 `ActionKind` 分檔：最短 0（緊急）/ 48h（滑點／每市場 liveness 切換），最長 21 天（`UpdateFeeSplit`）。你可以觀察佇列、計算 payload hash，若不同意，有足夠時間在執行前提款。任一簽名者可 1-of-n cancel 否決整個動作。
5. **團隊停止營運時，你仍能自助退場。** `withdraw-cli` 是開源工具，讓你不用我們配合也能自行組建並簽署提款 TX；每次版本發布都會測試。若我們靜默 7 天以上，合約自動免除早提款費，讓自助提款在經濟上也划算。

---

## 4. 持有期間，你的錢在做什麼

存入 vault 的 USDCx 會依治理設定的目標配置（目前啟動值：**45% DJED、25% USDM、30% USDCx 緩衝**）分配到 Liqwid Finance 三個穩定幣市場。Vault 的 keeper 定期做三件事：

- **Compound 複利**:把 Liqwid 給付的利息收回來,扣除 4.5% 績效費,剩餘部分回補到 vault 總額。**節奏依 TVL 分層**:post-audit 進入 1,200+ USDCx 檔、跑 §2.6 預設節奏時,Compound 每週六固定執行一次;**實際 Phase 1 sub-scenario (a)** $500–$5K 進入 §2.6.1 Reference Implementation Mode,Compound 改為季度到年度才執行一次(累計收益要 > $5 USDCx 才會 fire,讓 gas 成本與 harvest 規模相稱);**sub-scenario (b)** $5K–$25K 區間,節奏會隨 TVL 接近 $25K 而往月度–雙週偏。當前營運模式公開於 OptiVaults 儀表板。**這對你的意義**:若你是在 Phase 1 低 TVL 期間存入的,share price 更新頻率會偏低,這是刻意的設計(營運效率考量),不是異常。完整節奏政策見白皮書 §2.6 + §2.6.1。
- **Rebalance 再平衡**：配置偏離目標時（例如大額存提之後），把各資產比例調回目標值。
- **脫鉤監控**：持續觀測三種穩定幣；任一種連續 15 分鐘偏離 1% 以上，keeper 會停下新資金部署。

**長期而言，份額價格只會往上**，除非發生以下任一事件：vault 持有的某種穩定幣脫鉤、Liqwid 出現壞帳、智能合約被攻擊（這三種在 §6 全部詳細說明）。

**30% 的 USDCx 緩衝啟動時單純放在 vault 地址**，這部分不賺收益，但能讓大部分提款在一筆 TX 內完成，不必從 Liqwid 贖回部位。日後治理若認為時機合適，可將一部分緩衝配置到 Liqwid 的 USDCx 市場（觸發條件見白皮書 §2.3）；任何此類變動都要走 7 天 timelock，你在窗口內仍有時間選擇退出。

---

## 5. 費用一覽

| 費用項目 | 金額 | 何時收 |
|---------|------|-------|
| 存款費 | **$0** | 永遠不收 |
| 管理費（AUM） | **$0** | 永遠不收（不對本金收年費） |
| 績效費 | **毛收益的 4.5%** | 每次 Compound 扣除（從收益扣，不動本金） |
| 早提款費 | **提款金額的 0.1%** | 只有在最近一次 Compound 之後的 `min_hold_seconds`（啟動值 60 秒）窗口內提款才收；費用留在 vault 分給繼續持有的人；**keeper 離線 7 天後自動免除** |
| Cardano 網路費 | **每筆 TX 0.5-2 ADA** | 由 Cardano 礦工收取，我們拿不到 |
| SwapAda 營運摩擦 | **100K TVL 下約 0.02% APY** | 反映在份額價格的微幅下降，100K TVL 下約 10-20 USDCx/年；用途是透過 oracle 公允價格替 vault swap 補充運作所需的 ADA（見白皮書 §4.5 + spec/ada-swap.md） |

**具體例子**：假設你存入 $1,000 USDCx，毛混合收益 6%、持有一年：
- 毛收益 = $60
- 績效費 = $2.70（$60 的 4.5%）
- 淨收益 = $57.30（淨 APY ≈ 5.73%）
- 再扣 SwapAda 微量摩擦約 $0.20
- **一年後可提領餘額約 $1,057**

對照其他選項：
- **自己在 Liqwid supply DJED**（約 11.8% APY）：一年拿到約 $118，但要自己花 4 小時/年做手動 rebalance，而且 100% 集中在單一穩定幣 DJED。
- **Binance USD 理財**（4-8% APY）：一年拿到 $40-$80。Binance 是**單一實體對手方**，這家公司若倒了（參考 2022 年 FTX 事件），整筆資金的風險集中在同一個實體身上。V1 的對手方結構不同，但**不是零對手方風險**：風險分散到 Circle、xReserve 跨鏈橋、Liqwid、Minswap V2、Charli3 與 Orcfax oracle 等多個協議，好處是沒有「單一公司倒了就全部歸零」的集中風險；代價則是多了 Binance 沒有的智能合約漏洞風險。兩者並不是誰比誰安全，而是出錯的方式不一樣。
- **USDCx 放錢包不動**：收益 $0，不過依然承擔 Circle / xReserve 的發行方風險（這層風險在 V1 也一樣存在）。

---

## 6. 可能出錯的地方（誠實說）

V1 **不是保本產品**，合約設計上沒有主動虧損機制（沒有槓桿、沒有清算、沒有保證金追繳），但以下外部風險仍會真實影響你的本金。完整的對手方分析請讀 [security-model](security-model.md)；這裡簡述各種失敗情境從使用者錢包看會是什麼樣子。

### 6.1 智能合約漏洞

**從使用者角度看**：最壞情況是有人利用 validator 漏洞從 vault 抽走資金。你的 vUSDCx 會按比例貶值，若完全抽乾則歸零。

**我們的防範**:啟動前已完成多輪內部審計;外部審計目標 **Q2-Q3 2027**(反映 Catalyst Round 時程不確定性,見白皮書 §8.1);100K USDCx 上限限制審計前期最大曝險;若漏洞被發現但尚未被利用殆盡，治理可透過 `EmergencyWithdraw` 凍結並啟動復原。

**你能做的**：存入金額控制在承受得起全額損失的範圍。啟動階段我們**明確建議 Phase 1 單一錢包存 $200-$2,000**,不是因為越小越安全(事實上也的確是),而是因為審計前期的風險等級就是這個量級。

### 6.2 穩定幣脫鉤（DJED、USDM 或 USDCx）

**從使用者角度看**：假設 DJED 失去對 USD 的 peg，例如跌到 $0.85。因為 vault 45% 是 DJED，你的份額價格會按比例下跌：DJED 脫鉤 10%，當前配置下份額價格約跌 4.5%。

**我們的防範**：Charli3 + Orcfax oracle 加 Minswap TWAP 逐幣種監控脫鉤；連續 15 分鐘偏離 1% 以上，觸發 keeper 停止新部署加上營運告警；治理可透過 `EmergencyWithdraw` 凍結。

**你能做的**:若你無法接受多穩定幣曝險,直接到 Liqwid 挑一種你信得過的單一穩定幣 supply 會更單純,而不是接受我們這個三幣混合組合。

### 6.3 Liqwid 協議出問題

**從使用者角度看**：若 Liqwid 出現壞帳（抵押不足、儲備金又無法覆蓋的貸款），qToken 對底層資產的兌換率會下跌；你的份額價格會按 vault 的 Liqwid 曝險比例下跌（目前約佔 TVL 70%）。

**我們的防範**：每個市場的部位彼此隔離（Liqwid DJED 的壞帳不會污染 Liqwid USDM）；keeper 可自行停止對某市場的新 supply；治理可執行 `EmergencyWithdraw` 凍結。

**你能做的**：V1 對 Liqwid 的集中度是真實存在的風險，萬一 Liqwid 整個出事，V1 啟動初期沒有備援協議可以切換。這點在白皮書 §5.3 已經標記為 V1 最大的鏈上風險來源。若 Liqwid 協議風險對你是重大考量，V1 可能不是合適的選擇。**注意 V2 的 multi-protocol 方向是 design direction 而非 committed roadmap**，若 Cardano 穩定幣借貸景觀未如預期成熟（例如沒有第二個合格借貸協議出現），V1 可能**無限期停留**在單一協議 Liqwid wrapper。

### 6.4 Keeper 離線

**從使用者角度看**：keeper 停了。Compound 停、Rebalance 停。**但提款對你完全不受影響**，直接、排隊、緊急三條路徑都跟 keeper 狀態無關。Keeper 離線超過 7 天，合約自動免除早提款費，等於直接提款完全免費。

**我們的防範**：keeper 原始碼公開、可透過 `UpdateKeeperAuth` 在鏈上替換；治理可啟用 permissionless keeper 模式；7 天觸發費用免除；`emergency-withdraw` 工具提供自助退場。

**你能做的**：不用做什麼，V1 的設計原則是把 keeper 離線當成「不便」（沒有新收益累積），而不是「損失事件」。

### 6.5 治理通過你不認同的動作

**從使用者角度看**：治理佇列裡出現一個 `UpdateStrategy`，要把 vault 配置調整到你不喜歡的方向。你有 7 天（策略變動的 timelock）決定要不要退場。

**我們的防範**：所有治理動作在 QueueAction 時就公開可見；最短 timelock（白皮書 §6.2）給你反應時間；任何單一簽名者都可 1-of-n cancel。

**你能做的**：在 timelock 窗口內，若變動對你不可接受，提款就是。

### 6.6 多資產連動崩盤

**從使用者角度看**：ADA 閃崩 30% → DJED 因為是 ADA 抵押而脫鉤；同時 Minswap DEX 對 USDM/USDCx 的撤出流動性變薄。份額價格連鎖下跌。反向 swap（DJED → USDCx）可能在 keeper freeze 觸發之前，就以脫鉤折價成交。

**我們的防範**：不完美。脫鉤監控有 15 分鐘持續閾值，極速崩潰可能在監控觸發之前就完成數筆脫鉤價 swap。我們老實承認：對 15 分鐘內的崩潰，目前沒有好的解決方案；V1 的多穩定幣配置是**單一生態系內的雙發行者分散，不是對 ADA 崩盤的獨立保障**。

**你能做的**：理解 V1 的多穩定幣配置保護的是單一發行者失敗（DJED / USDM / USDCx 其中一種獨立出事），**不是**對 ADA 連動崩盤的保護。

---

## 7. V1 適合你嗎？

簡單的決策流程：

1. **你的 USDCx 放在 Cardano 鏈上，還是在中心化交易所（CEX）？**
   - 在 CEX → V1 與你無關；要不要把資金移到 Cardano 是另一個問題（取決於你對 Circle + xReserve 的信任）。
   - 在 Cardano → 繼續。

2. **你願意每季花 1 小時自己手動管理 Liqwid DJED 部位嗎？**
   - 願意 → **直接在 Liqwid supply DJED 反而更好**。淨收益更高、活動元件更少、整體攻擊面更小。
   - 不願意 → 繼續。

3. **你會把錢放在 Binance 這類 CEX 做穩定幣理財嗎？**
   - 會 → Binance Earn 4-8% APY 是不同的風險結構（單一實體對手方 vs V1 多協議風險 + 智能合約 bug 暴險）。**兩者不是誰比誰安全** — 完整對手方對比見 §5（FTX 2022 是單一實體失敗的代表性事件）。請考慮你比較願意承擔哪種失敗模式。
   - 不會（堅持自我託管）→ V1 就是為你設計的。**繼續。**

4. **預期存入 $100-$10K、想要完全不用自己操作的被動曝險？**
   - 是 → V1 可能是合理選擇的 **post-audit 目標使用者**(目前目標 **Q2-Q3 2027** 外部審計通過、TVL 上限解除之後;funding-stack 不確定性見白皮書 §8.1)。Pre-audit 期間受 operator-enforced 100K USDCx TVL cap 限制，但**合約是 permissionless，沒有 invitation gate**，任何理解並接受 pre-audit 風險（未知 CRITICAL bug 可能、TVL 不會快速成長、founder bandwidth 有限）的 depositor 都可依自己判斷進入。進入前建議：先讀白皮書 §5 Risks。沒有「正確」的首次存入金額，目前 Phase 1 depositor 用過從 $50 到 $2K 不等的金額。**若你不確定，$100-$200 是學習機制的合理首次存入區間**；完成至少一次完整 deposit + withdraw cycle、確認流程可正常 end-to-end 後再考慮放大。原則是萬一 CRITICAL bug 出現你能承擔全額損失。Pre-audit 不適合追求最大化 yield 或規模化入場的 depositor，這群建議等 post-audit cap 解除，或直接選 Direct Liqwid DJED supply。
   - 存入 < $100 → 技術上可行，但 0.5 ADA 網路費在極小額下相當於 0.25% 入場摩擦，自己評估是否接受。
   - 存入 > $10K → 請讀白皮書 §4.4 的損益平衡敏感度表。較大金額下，純看淨收益的話，Direct Liqwid 通常勝出。

---

## 8. FAQ

**Q：有做過審計嗎？**
A:內部已完成多輪 validator 原始碼對抗性檢視。外部第三方審計目前目標 **Q2-Q3 2027**(反映 Cardano Project Catalyst Round 時程不確定性,見白皮書 §8.1)。V1 在外部審計完成前維持 100K USDCx 上限。審計方法論見白皮書 §5.1。

**Q：我怎麼知道你們不會挪用我的資金？**
A:你不必相信我們的話,程式碼公開,你自己就能讀。每一個 redeemer 都在鏈上強制執行。`idle_buffer` 只能送到下列三種目的地之一:
- 透過 Withdraw 還給存款人
- 透過 keeper 簽名的 DeployToProtocol TX 送到 DEX order 地址(有白名單)
- 透過 SupplyToLiqwid 送到 Liqwid action validator

沒有任何 redeemer 讓我們把資金抽到 admin 錢包。Validator hash 也可自行重現驗證，見白皮書 §10 Reproducibility。

**Q：Cardano 本身出事怎麼辦？**
A：V1 完全在鏈上運行。Cardano 暫停、V1 就跟著暫停；Cardano 恢復、V1 也恢復。本金不會消失，只是鏈暫停期間無法流動。

**Q：我會虧超過本金嗎？**
A：不會。你的最大損失等於事件發生時 vUSDCx 的市值，下限是零。V1 沒有槓桿、沒有借款、也沒有任何會對你的部位做保證金清算的機制。

**Q：收益要繳稅嗎？**
A：大部分司法管轄區應該要繳，穩定幣收益通常被認定為應稅所得或資本利得，依當地法規而定。這是你自己的責任；V1 不會開任何稅務單據。建議諮詢當地稅務專業人士。

**Q：vUSDCx 可以轉給別的錢包嗎？**
A：可以。vUSDCx 是標準 Cardano native token，可以送到任何錢包；接收方之後也能拿它來換回 USDCx。這也是未來若有二級市場時出售部位的方式（啟動時還沒有這樣的市場）。

**Q：最低存款多少？**
A：10 USDCx（合約強制下限）。低於這個金額會被拒絕，目的是維持 vault 的 min-UTXO 會計一致。實務上：Cardano 每筆 TX 約 0.5 ADA（≈ $0.25）網路費，對極小存款來說入場的百分比摩擦不算低。我們建議**首次存入 $100 以上**在經濟上才划算，雖然 $20 以上技術上就可以。

**Q：最高存款多少？**
A：沒有單一錢包上限。整個 vault 的審計前上限是 100K USDCx；達到上限後，新存款在 API 層被擋下（上限是營運層強制，不是合約層強制，見白皮書 §9.4）。

**Q：看到治理佇列裡有我不喜歡的動作，該怎麼辦？**
A：在 timelock 窗口內提款，視 `ActionKind` 而定：最短 0（緊急）/ 48h（滑點／每市場 liveness 切換），最長 21 天（`UpdateFeeSplit`）。實質政策變更落在較長那端，時間相當充裕，這正是 timelock 機制存在的目的。

**Q：問問題要找誰？**
A：Discord 邀請連結在 optivaults.app 首頁。安全相關問題：`optivaults@gmail.com`。

---

## 9. 總結

OptiVaults V1 是 Cardano 上的非託管穩定幣 vault，在 **pre-audit 100K USDCx hard cap** 下於 mainnet 啟動。白皮書 §0 列出完整 4-phase 模型（Pre-Catalyst → Pre-Audit Mainnet → Audit + Cap-Lift Window → Operational）；本概覽採用使用者導向的 2-phase 簡化：

- **Phase 1 user-facing（pre-audit mainnet；白皮書 Phase 2 entry）**：V1 在 §1.5 launch gates 達成（Class A overrides 清除 + axis One-Yellow + 內審完成）後於 mainnet 100K USDCx pre-audit cap 下運作。預期 TVL 區間 $500-$25K；成功標準是 Phase 1 準則（無 CRITICAL exploit + 自動化系統正常運作 + 社群信任建立 + 順利交接給審計方），**不是**填滿 cap。外部審計目標 Q2-Q3 2027，前提是 §8.1 資金堆疊到位；若不到位，V1 在此 phase 無限期維持於 mainnet（100K cap — 白皮書 §8.1 Option D）。
- **Phase 2 user-facing（post-external-audit，取決於 §8.1 funding outcome；白皮書 Phase 3 → 4）**：cap 依審計結果解鎖到 Stage 3（$500K → $2M），目標使用者擴展至 $100-$10K hands-off depositor，治理朝 Phase 2+ 簽名者輪替推進。

V1 在兩個階段都是為特定類型使用者設計：持有 USDCx、不用 CEX、偏好不自己手動管理 Liqwid、願意承擔智能合約風險來換取被動持有的混合穩定幣收益。若這描述就是你的情況，**從小額開始**，並讀[白皮書](../whitepaper/whitepaper-zh-TW.md)。若不是，完全沒問題，我們希望你找到真正符合自己需求的產品，不論是直接 Liqwid、CEX earn、或繼續自己保管 USDCx。

**我們為什麼做這個。** 創辦人是 Cardano 的自我託管使用者：2025 年起持有 ADA 並委託 stake pool 做原生質押、同時持有小額 BTC；參與過 Midnight 的 NIGHT redeem；2026 年起在 Minswap V2 的 ADA/NIGHT pool 提供流動性；目前也持有 USDCx（Circle 於 2026 年 2 月透過 xReserve 在 Cardano 發行）。V1 的起點是一個很具體的個人問題：USDCx 到手之後現實的選項有四條：

- **(a) 送到 CEX 換 earn 產品**：因自我託管原則拒絕。
- **(b) 直接在 Liqwid 的 USDCx 市場 supply**：利率 0.5-2%，扣掉通膨不划算。
- **(c) 把 USDCx 換成 DJED 再 supply**：年化約 11.8%。進場 2 筆 TX（換匯 + supply），離場或每次部分提領再走一組 recall + swap back 往返；若想同時分散到 DJED + USDM + USDCx 就是並行管三個部位。進場之後 qToken 放在錢包裡、兌換率自動累積，中間不用再動。對 $200 部位，一次進場 + 一次離場來回 gas 大約佔本金的 1-2%，持有越長攤得越薄。
- **(d) 就讓 USDCx 躺在錢包裡**：0% 收益。

Cardano 上當時沒有「存 USDCx 進去、讓它自動在 DJED + USDM 複利、離場只要一筆 TX」這樣的產品，於是創辦人就自己蓋了一個。V1 是「我自己在找但找不到、只好動手做」的產品。

**核心使用者保護是合約不變量，不是營運承諾**，沒有 admin 能抽走資金、4.5% 費用上限改不掉、keeper 離線 7 天後早提款費自動免除。（其中一些保護，例如「提領順利以 1:1 USDCx 結算」，額外依賴 Cardano + Liqwid + Minswap V2 + USDCx 都維持運作；誠實的限定條件見白皮書 §1.6.1。）

**V1 是一個便利層，不是唯一正確的選擇**。V1 把 swap + supply 配置打包進一筆 CIP-30 存入交易、離場用一次 vUSDCx burn 完成，代價是**已實現收益的 4.5%** 績效費（絕不對本金收費）。若你偏好親自操作以取得完整收益，那是合理的選擇，尤其是長期持有時，那一次性的進場 + 離場 gas 攤下來只占很小比例；若你覺得智能合約風險超出自己的承受範圍，繼續自己保管 USDCx 也是同樣合理的決定。

**V2 是方向，不是承諾的路線圖**，是否真的演化為多協議、多策略的資產配置層，取決於 Cardano DeFi 後續是否成熟（例如出現第二個合格的借貸協議、DEX 流動性是否加深）。在此之前，請以 V1 現在實際提供的功能評估它：自動複利 + 雙發行者穩定幣配置 + 自助退場保證 + 經審計且有上限的費用結構。完整的起源故事、為什麼是 Cardano 與為什麼是現在，請見白皮書 §1.6。

**營運實況（與 depositor 決策直接相關，不藏起來）。**

- **V1 的成功門檻是 $500K-$1M TVL，不是 $20M。** 4.5% 績效費 × 該 TVL × ~6% blended yield 在 V1 啟動 40% keeper 份額下每年產生 ~$270-540 keeper-share 收入，足以讓 keeper 覆蓋自身基礎建設成本。這是 **tier (a)/(b) self-sustain** 目標。坊間常被引用的「$20M TVL」是另一個 **tier (c) audit-reserve self-funding** 目標（協議能從 V1 啟動的 treasury 60% 份額自行支付未來外部審計週期），那是 Phase 3+ 的 stretch goal，不是 V1 的前提條件。完整三層 self-sustain breakdown 見白皮書 §4.3。
- **審計資金 stack — volunteer-builder + community-funded 模型（白皮書 §0.2 + §8.1）。** V1 **不論審計資金狀態**都在 mainnet pre-audit 100K cap 下啟動 — 審計是 **cap-lift gate、不是 launch gate**。資金堆疊：(a) grant 池 — Catalyst（Round 開時 $30-50K）+ Cardano Foundation + Intersect Member Committee + Aiken Foundation，合計潛在 $30-150K 視何種來源交付；**Catalyst 撰寫時處於暫停 / 重組狀態，下一個 Round 何時恢復尚無明確時程**，因此 V1 不依賴任何單一 grant 來源；(b) 審計事務所公共財費率，在 $50-$150K base 上砍 30-50%（多 reviewer 委託模式也可把 base 壓到 $70-$100K）；(c) heritage 內部審計帶來的 scope reduction（省 $15-25K）；(d) **創辦人 gap-fill 上限 ~$15K** — 創辦人承諾**最多約 $15K 個人自掏**用於 bridging (a)/(b)/(c) 到位後與最終審計報價之間的微額短缺，**明確不承諾在任何情境下 underwriting 完整 $50-$150K 審計成本**。白皮書 §8.1 寫的 **$50-$150K 委託區間**，涵蓋從多 reviewer / scope-reduced 低端（~$50K）一路到折扣前單 firm 全價（~$150K）。**若資金堆疊低於 $15K gap-fill 容量之上仍有短缺**，V1 走白皮書 §8.1 Options A-D contingency tree（時程延後 / scope-reduced 審計 / 社群 DAO crowdfund / 永久 pre-audit 100K cap）— 四個 option 都讓 V1 留在 mainnet 100K cap，只決定 cap-lift 路徑。**審計資金失敗不是 sunset 觸發條件** — 白皮書 §0.2 + §4.1 + §8.1 明說。§8.1 Option D 下 V1 在 mainnet 維持 100K cap 無限期運作；sunset 只在 §1.5 Class A overrides（Liqwid / USDCx / Cardano / oracle 事件）或創辦人明確 sunset 決定下觸發。
- **2 位獨立 SPO 治理簽名者是 Cardano 社群服務角色,不是有薪職位。** 他們會收到一個 soul-bound 認證 NFT,並有選項在 Phase 2+ 取得 5-10% gov pool 份額(gated on $500K TVL milestone),這兩者都是**「V1 成功後的 upside」而非主要動機**。挑選標準:≥ 2 年 mainnet SPO 營運、公開鏈上身份、與創辦人無事前商業關係。**SPO 招募是 launch target,不是 launch blocker**,若主網儀式前招募仍未到位,V1 會在 §5.5.1 三層治理安全設計下啟動,由創辦人以 key separation 方式操作全部 3 個簽名者席位;存入者的回收路徑(`emergency-withdraw`、硬上限、7 天 inactivity gate)**不依賴 SPO 招募是否完成**。因此實際啟動配置會是「**3-of-3 with SPOs**」**或**「**創辦人 + key separation 的 §5.5.1 fallback**」其中一種。完整內容見白皮書 §5.5 + §5.5.1 + §7.4。

**聯絡方式**：
- 網站：[optivaults.app](https://optivaults.app)
- 安全揭露：`optivaults@gmail.com`
- Discord：連結在 optivaults.app
- 原始碼：`github.com/OptiVaults`（開源 mirror，V1 mainnet 啟動時發布）

---

## 10. 延伸閱讀

| 你想了解的 | 請讀這份 |
|-----------|---------|
| 完整技術與威脅模型 | [whitepaper/whitepaper-zh-TW.md](../whitepaper/whitepaper-zh-TW.md) |
| V1 與其他方案的經濟比較 | [economics.md](economics.md) + 白皮書 §4 |
| 具體風險與攻擊面 | [security-model.md](security-model.md) + 白皮書 §5 |
| 治理機制如何運作 | [../spec/governance.md](../spec/governance.md) + 白皮書 §6 |
| 從內部驗證期部署遷移 | [migration.md](migration.md) |
| 審計計畫 | [audit-scope.md](audit-scope.md) + 白皮書 §8.1 |
| English version | [product-overview.md](product-overview.md) |
