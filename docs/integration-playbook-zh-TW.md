# OptiVaults V1 — 整合 Playbook

**範圍**:為 V1 加入新 DEX 路徑、新借貸市場、新協議整合時,在不犧牲安全的前提下該怎麼走的作業流程。

這份是 canonical SOP,operator 與治理簽名者在提案 `UpdateRegistry` 或動 keeper 程式加進新的外部協議**之前**必須照這份走。之所以要寫這份:Cardano DeFi 裡可預防的資金損失,**最大原因不是智能合約 bug、不是市場事件**,而是跳過驗證步驟。

---

## 1. 歷史脈絡

V1 繼承了 pre-V1 內部驗證期的整合失敗教訓。代表性的損失(都可以靠本 playbook 預防):

| 日期 | 原因 | 損失 |
|------|------|------|
| 2026-03-29 | CSWAP cancel redeemer 格式沒從鏈上逆向,直接 mainnet submit | ~102 ADA |
| 2026-03-31 | CSWAP datum 格式用假設、沒驗證 | ~9 ADA |
| 2026-03-31 | 在 Minswap V2 batcher 停擺時送單;cancel 路徑沒測過 | ~20 USDCx + 8 ADA |
| 2026-03-31 | `StakeCredential` 編成 `Constr(0, [])` 而不是 `Constr(1, [])`,validator crash、無法 cancel | ~11 USDCx + 12 ADA |
| 2026-04-03 | 非冪等的 debug 腳本把 ADA 重送進金庫,永久鎖死 | 10 ADA |

**V1 開發階段可預防的損失總額:大約 US$270。** 沒有一筆是智能合約漏洞,全是整合 SOP 問題。本 playbook 就是為了不讓 V1 存入者付出「重新學一次這些教訓」的代價而存在。

---

## 2. 整合類型

| 類型 | 例子 | 典型範圍 | 治理路徑 |
|------|------|---------|---------|
| **A. 新 Liqwid 市場** | 加新穩定幣市場(例如 USDA、假設的 USDE) | Registry 的 `liqwid_markets` 條目;keeper 的 Supply/Recall builder 擴充 | `UpdateRegistry`(14 天 timelock) |
| **B. 新 DEX 路徑** | Splash、新 Minswap pool shard、新 DEX 協議 | Registry 的 `protocol_hashes` 條目;keeper swap builder;新 DEX order/cancel TX builder | `UpdateRegistry`(14 天 timelock) |
| **C. 新借貸協議** | 全新協議如 Aada、Lenfi | 可能要動 vault validator 邏輯;顯著審計範圍 | V2 重部署(完整遷移週期) |
| **D. 協議遷移** | Liqwid pool-shard 維護後 `action_addr_hash` 輪替 | 只動 registry 欄位 | `FastUpdateMarkets`(1 小時 timelock) |

成本與審計面大致從 A 到 C 線性增加。D 類是運營層面(治理工具已到位,能快速響應)。

---

## 3. 七步整合 SOP

每份整合提案都必須通過**全部七步**,才能上治理做 `UpdateRegistry`。**跳任何一步就作廢**。

### Step 1 — 識別

**輸入**:APY 掃描、社群討論、協議公告、operator 觀察。

**輸出**:
- 簡短的整合摘要(協議名稱、為什麼值得加、預期 TVL 影響、風險類別 A/B/C/D)
- 在 Discord 的 `#integration-proposals` 頻道(或同等場合)公開發表
- 可行性**公開審視 7 天**,才進入 Step 2

**不允許**:跳過社群可視性的私下提案。

### Step 2 — 可行性分析

**輸出**(必須文件化在 GitHub issue):

1. **該協議已經上鏈嗎?** 必須在 mainnet 上線 ≥ 90 天、無 exploit 紀錄。
2. **是否活躍使用?** Batcher / keeper / sequencer 在過去 30 天內需要有 ≥ 50 筆成功 TX。停擺協議會以意想不到的方式卡住使用者資金。
3. **原始碼是否公開?** Validator 原始碼若不公開,審計面會大幅擴張。V1 偏好整合開源的 Cardano 協議。
4. **使用者送出的 order 是否有 cancel / refund 路徑?** 需由至少 3 筆真實鏈上 cancel TX 驗證。**若無 cancel 路徑,V1 拒絕整合**,使用者資金不能處於無法 cancel 的狀態。
5. **實際下行損失?** 若協議行為異常(例如 batcher 路由到錯地址)最壞會損失多少;以 V1 的 100K TVL 上限量化評估。

**出口門檻**:五題全部有答案,且有引用來源。

### Step 3 — 從真實 mainnet 活動逆向

**輸出**:

1. 目標操作(Deposit/Swap/Supply/Withdraw/Cancel)的 5-10 筆真實 mainnet TX。每筆的 decoded CBOR 存進 `contracts/integrations/<protocol>/traces/`。
2. Datum schema:**byte-level 精準**,從這些 trace 推導。**不准用猜的**。若 3 筆獨立 TX 對得上,schema 視為「鎖定」;若對不上,先查清楚再往下。
3. Redeemer schema:包含 **cancel** 與 **expire** redeemer。這兩個往往與主執行 redeemer 不同、很容易漏掉。
4. Stake credential 編碼:`Constr(0, [...])` vs `Constr(1, [...])`,從真實 TX 驗證,**不准用假設**。(這就是 2026-03-31 的教訓。)
5. Reference-input 依賴:哪些 UTxO 必須以 reference 形式存在、他們的 datum 內容要是什麼。

**出口門檻**:GitHub issue 收錄 decoded CBOR、schema,以及至少一位 peer reviewer 對逆向結果的簽核。

### Step 4 — 在 Preprod 實作

**輸出**:

1. Keeper 程式實作新 builder(例:`optivaults/optivaults-vps/keeper/src/engines/newProtocolEngine.ts`)。
2. 在 Preprod 部署上跑 end-to-end,金額極小(例如 1 個 test USDCx)。
3. **特別測 cancel / refund**:送一筆 order,然後 cancel 掉。驗證使用者資金乾淨退回。**這是最重要的上 mainnet 前單項檢查**。
4. Preprod TX 紀錄附在 GitHub issue 內。

**出口門檻**:主路徑 TX 與 cancel TX 在 Preprod 都成功。**兩者都沒通過時,不得往下**。

### Step 5 — 治理提案

**輸出**:

1. 用 `opti-gov queue --action update-registry --target <target_hash> --timelock 14d` 提出 registry 的變更(新 `liqwid_markets` 條目或 `protocol_hashes` 條目)。
2. 在 GitHub 發布提案說明,內容包含:
   - 整合類型(A/B/C/D)
   - Steps 1–4 輸出的摘要
   - 風險評估(最壞情境損失、緩解措施)
3. 治理簽名者**審視 14 天**。這段期間 1-of-n cancel 可用。
4. Timelock 到期後(若未被 cancel),執行 `opti-gov execute --index <n>`。

**對 D 類遷移(1 小時 timelock)**:可以走 `FastUpdateMarkets` action。1 小時窗口足以應對緊急 pool-shard 輪替,同時仍不妨礙社群監控。

### Step 6 — Mainnet 煙霧測試

**輸出**:

1. 以**最小允許金額**(通常 5 ADA 或該協議的最小 order 量)送 mainnet。
2. 驗證 TX 上鏈,主路徑操作成功。
3. 驗證 cancel 路徑(若操作適用),以小筆測試 order 驗證。
4. 煙霧測試紀錄附在 GitHub issue 內。

**出口門檻**:煙霧 TX 確認 **且** cancel 驗證通過。兩者都通過之前,**不得**在生產 keeper 設定中啟用新路徑。

### Step 7 — 生產啟用

**輸出**:

1. 更新 keeper 設定,納入新路徑 / 新市場。
2. 為新操作設定好監控 + Discord alert。
3. 7 天後做 post-launch review:看 TVL 影響、是否有異常、使用者回饋。
4. 文件更新:`optivaults/frontend/FAQ.md`、`optivaults/whitepaper.md §3`(整合清單)、`optivaults-vps/README.md`(keeper 能力)。

**出口門檻**:生產啟用、監控綠燈、24 小時無異常。

---

## 4. 六條不可妥協的安全規則

Step 3 到 Step 7 的每個動作,都必須同時遵守**以下全部六條**。違反任何一條就讓這次整合作廢:

### 規則 1:一定要有真實使用者在該協議的官方 frontend 完成過該操作。

V1 不整合那些**主流程在野外沒被測過**的協議。若沒有使用者成功在 mainnet 上跑過該協議的 Deposit / Swap / Supply 流程,V1 就不是首位整合者。**我們從別人的生產經驗學教訓,而不是用存入者資金當白老鼠。**

### 規則 2:Datum 格式必須由 ≥ 3 筆真實 mainnet TX 逆向而來。

**不准用假設**。若協議公布了 schema 文件、但 3 筆鏈上 TX 顯示文件是錯的,**信鏈上、不信文件**。

### 規則 3:Redeemer 格式必須同時逆向 fill 與 cancel TX。

漏了 cancel redeemer 模式,會在使用者需要放棄時損失資金。整合前**兩種路徑都要文件化**。

### 規則 4:Cancel / refund 路徑必須在 Preprod 做端到端測試。

Preprod cancel 成功 = 上 mainnet 的閘門。**沒有例外**。

### 規則 5:協議的 batcher / keeper / sequencer 必須活躍。

在做 mainnet 煙霧測試之前,確認 batcher 在最近 10 分鐘內有運作過。**安靜的 batcher** 意味著 order 會無限期卡住。這就是 2026-03-31 送 Minswap V2 order 無法回收的原因,batcher 因無關原因當時停擺,而 V1 沒有自動偵測機制。

### 規則 6:第一次 mainnet 測試必須用最小允許金額。

通常是 5 ADA 或該協議的最小 order 值。**第一次測試用更大的金額,就是在浪費錢**,萬一出問題,全是額外損失。

---

## 5. 治理與 operator 的權限分工

| 動作 | 誰決定 | 機制 | Timelock |
|------|-------|------|---------|
| 提案整合(Steps 1–4) | 任何貢獻者(社群或 operator) | 公開 GitHub issue + Discord 討論 | — |
| Preprod 驗證(Step 4) | Keeper operator + peer reviewer | 不涉及治理 | — |
| `UpdateRegistry` queue(Step 5) | 治理簽名者(達門檻) | 鏈上 `QueueAction` | 14 天 |
| `UpdateRegistry` cancel | 任一簽名者 | 鏈上 `CancelAction` | 0(立即否決) |
| `UpdateRegistry` execute(Step 5) | 治理簽名者(達門檻) | 鏈上 `ExecuteAction` | —(timelock 過後) |
| `FastUpdateMarkets`(Liqwid action_addr_hash 緊急輪替) | 治理簽名者(達門檻) | `registry.ak` 內的鏈上 redeemer | 只有 1 小時 cooldown(沒有 14 天等待) |
| `KeeperToggleMarket`:緊急停用某個 Liqwid 市場 | Keeper operator(單方) | `registry.ak` 內的鏈上 redeemer;只能 `active: true → false` | 0(立即,僅 keeper) |
| 重新啟用被 `KeeperToggleMarket` 停用的市場 | 治理簽名者(達門檻) | 鏈上 `UpdateRegistry` | 14 天 |
| Mainnet 煙霧測試(Step 6) | Keeper operator | Keeper wallet | — |
| 生產啟用(Step 7) | Keeper operator(execute 之後) | Keeper 設定 push | — |

**Operator 權限上限**:keeper operator 絕不能單方把協議或市場加進白名單,registry 的**新增**都必須走治理(14 天 timelock)。Keeper **可以**:(a) 拒絕使用白名單內的某個協議(跳過風險路徑),以及 (b) 在偵測到壞帳訊號或 pool 遷移異常、否則會讓金庫資金被困住時,立即透過 `KeeperToggleMarket` **停用**某 Liqwid 市場。重新啟用 keeper 停用的市場**必須經治理**,這是**單向逃生閥模式**(keeper 打破玻璃,治理審視後重新密封)。

**社群權限**:任何社群成員都可以透過 Step 1 提案整合,並向治理施壓促成優先。治理不保證執行社群提案,但對重要提案需要公開回應。

---

## 6. 每類整合的成本與時程

### 類型 A:新 Liqwid 市場

- 逆向工程時間:5–10 小時
- Keeper 程式:10–15 小時
- Preprod + mainnet 煙霧:5–10 小時
- **Operator 總工時**:~20–40 小時
- **直接成本**:~10–30 ADA(gas)
- **從提案到生產的日曆時間**:3–4 週(大多是 14 天治理 timelock)
- **審計範圍**:無(沿用現有 Liqwid action-validator 整合)

### 類型 B:新 DEX 路徑

- 逆向工程時間:15–25 小時
- Keeper 程式:15–25 小時
- Preprod + mainnet 煙霧:10–15 小時
- **Operator 總工時**:~40–80 小時
- **直接成本**:~50–150 ADA
- **日曆時間**:4–6 週
- **審計範圍**:1–2 輪內部(外部審計約 US$500–2,000)

### 類型 C:新借貸協議

- 逆向工程時間:30+ 小時
- 合約變更:40+ 小時(可能含新 vault validator)
- 完整審計:1–2 輪外部
- **Operator 總工時**:~120–300 小時
- **直接成本**:~300–1,000 ADA + 審計費
- **日曆時間**:3–6 個月(V2 風格新部署)
- **審計範圍**:~US$10–25K 外部審計 + 內部輪次

### 類型 D:協議遷移

- 逆向:3–5 小時(只是 `action_addr_hash` 更新)
- 程式:1–3 小時
- 煙霧:2–5 小時
- **Operator 總工時**:~5–15 小時
- **直接成本**:~5–20 ADA
- **日曆時間**:當天(1 小時 `FastUpdateMarkets`)
- **審計範圍**:無

---

## 7. 整合的資金來源

整合工作由 treasury R&D 類別支應(見 `docs/economics.md §3` 與 §7C)。低 TVL 下,整合工作實質上是志工,創辦人或貢獻者自行吸收成本。TVL 成長後,treasury R&D 的資金才夠到值得給 operator 補償的程度:

| TVL | R&D 年入帳 | A 類可達頻率 | B 類頻率 | C 類 |
|-----|-----------|--------------|----------|------|
| 100K | ~$43 | 0(僅志工) | 0 | 0 |
| 500K | ~$216 | 1 | 0 | 0 |
| 1M | ~$432 | 2 | 0 | 0 |
| 5M | ~$2,160 | 4 | 1 | 0 |
| 10M | ~$4,320 | 6 | 2 | 0 |
| 50M+ | ~$21,600+ | 10+ | 5 | 1 |

這是誠實的描述,整合量能隨 TVL 與 treasury 入帳擴張。**US$1M TVL 以下,預期每年 ≤ 2 次整合;US$10M 以上,整合節奏明顯加速。**

---

## 8. 上線後檢討與 rollback

### 8.1 上線後檢討(T+7 天)

每項生產整合都要做一次 7 天檢討:

- TVL 影響:整合真的有被使用嗎?
- TX 成功率:keeper 的執行是否乾淨成功?
- 透過 Discord 回報的使用者問題
- 任何運營異常(預期外費用、卡單、batcher 行為怪異)

好的整合通過 7 天點沒問題。**有問題的可能被 rollback。**

### 8.2 Rollback 程序

若生產整合發生意外問題:

1. **立即**:Keeper operator 在 keeper 設定中停用該路徑(不需治理,operator 永遠可以停用白名單路徑的使用)
2. **短期**:治理 queue `UpdateRegistry` 移除協議 hash(14 天 timelock、1-of-n cancel 否決)
3. **緊急**:若整合**正在**造成資金損失(不只是效率差),治理可以 `EmergencyWithdraw` 凍結金庫,等調查

Rollback 是正常運作模式,不是失敗事件。V1 的 registry 刻意設計為可在治理監督下變動,**正是為了能修正整合錯誤**。

---

## 9. 整合檢查表(提交前摘要)

治理簽名者在共簽「新增協議」的 `UpdateRegistry` 提案之前,必須驗證:

- [ ] Step 1 公開提案已完成,含 7 天的開放評論期
- [ ] Step 2 可行性分析已寫入 GitHub issue,五題都有答案
- [ ] Step 3 逆向完成,附 ≥ 3 筆 TX 的 decoded CBOR
- [ ] Cancel / refund redeemer 已逆向
- [ ] Step 4 Preprod 端到端測試:主路徑**與** cancel 路徑都通過
- [ ] 協議在 mainnet 上線 ≥ 90 天、無 exploit
- [ ] 提案當下,batcher / keeper / sequencer 在最近 10 分鐘內活躍
- [ ] Step 6 mainnet 煙霧測試規劃好(計劃 post-execute 執行,使用 5 ADA 或最小值)
- [ ] 最壞情境損失 bounded 在當前 TVL 的 1% 以下

任一項未打勾,就是不執行提案的正當理由。

---

## 10. 延伸閱讀

- `docs/economics.md §7C` — 整合資金的 R&D 預算可用量
- `spec/governance.md §4.6 UpdateRegistry` — 鏈上授權機制
- `spec/governance.md §4.8 FastUpdateMarkets` — 協議遷移的 1 小時快速路徑
- `docs/security-model.md §3` — 整合相關的攻擊面與威脅模型
- GitHub repo:`contracts/integrations/`(每個協議的 trace 保存與 schema lock)
