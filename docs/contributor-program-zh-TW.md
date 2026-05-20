# OptiVaults V1 — 開源貢獻者計畫

**範圍**:說明 OptiVaults 開源程式碼的貢獻者要怎麼被肯定、怎麼被酬庸。涵蓋 V1 當下(非正式)的姿態,以及進入 Phase 2 正式啟用的路徑。

---

## 1. 目前姿態(V1 上線至 Phase 1)

**貢獻者酬庸計畫在 V1 上線時尚未正式啟用。**

在 pre-audit 的 100K TVL 上限下,Treasury R&D 類別每年入帳約 US$43,不足以撐起結構化 bounty 計畫。Phase 1 階段,貢獻者會得到:

- **公開致謝**:repo commit log、release note,以及(對實質貢獻)Discord `#contributions` 頻道的公開提及
- **貢獻者 NFT**(Phase 2 起開放,上線時尚未啟用):見下方 §3
- **未來回溯性肯定**:若專案到達該計畫正式啟用的 TVL 規模,先前的貢獻者將在 §2 的機制下享有回溯性肯定資格

這是誠實的描述。在 100K TVL 下,V1 處於**啟動期**,沒有預算做現金酬庸。貢獻是為了專案成功、不是為了報酬;V1 不會另外宣稱別的。

---

## 2. Phase 2 啟用(目標:TVL ≥ 500K 或 treasury R&D ≥ US$500)

當 Treasury R&D 類別餘額達到約 US$500(典型在 500K TVL 左右)時,結構化計畫啟動,由四個機制組成:

### 機制 A:任務型 bounty

**流程:**
1. 動工前,治理(透過 `QueueAction` → `TreasurySpend`)為特定任務預留一筆 bounty(例:「實作 Splash V2 整合,bounty US$500」)
2. 任務公開在 GitHub + Discord
3. 貢獻者提交 PR
4. Keeper operator + 至少一位額外 reviewer,以技術實質審通過該 PR
5. 治理執行 `TreasurySpend` 到貢獻者的 Cardano 錢包

**Bounty 分級**(示意;治理依任務訂):

| 任務類型 | 典型 bounty |
|---------|-------------|
| 小 bug 修正(< 4 小時) | US$25–75 |
| 小功能(4–20 小時) | US$100–500 |
| 整合:A 類 Liqwid 市場 | US$300–750 |
| 整合:B 類 DEX 路由 | US$1,000–3,000 |
| 安全揭露(協調式、HIGH 嚴重性) | US$500–5,000(見 `docs/audit-scope.md`) |
| 整合:C 類新協議 | US$3,000–10,000 |

**治理 timelock**:bounty 的 `QueueAction` 套 7 天 timelock(與其他 `TreasurySpend` 動作相同)。Cancel 否決適用。

**防 rug 條款:**
- PR 合併前**不會**支付 bounty
- 在 bounty 公告之前完成的工作,不會自動符合資格(但治理可以透過機制 B 回溯性資助)

### 機制 B:回溯性肯定

**流程:**
1. 每季治理會回顧開源貢獻紀錄
2. 標出那些帶來長期價值、但事前沒有 bounty 的貢獻
3. 依判斷提案回溯性 `TreasurySpend` 給貢獻者
4. 貢獻者也可以透過 GitHub issue 自薦

**典型回溯金額**:每項肯定 US$50–500。

**用途**:承認開源貢獻有時是不可預測的,貢獻者可能寫出專案原本沒意識到自己需要的東西。純事前 bounty 計畫會錯過這一類。

### 機制 C:貢獻者 NFT(soul-bound)

一個 soul-bound NFT,精神上與治理 Gov Signer NFT(`spec/gov-nft.md`)相似。細節:

```
policy: OptiVaultsContributorNFT(每代 one-shot)
tokens:
  Gen1-<貢獻者標籤>  × 1  → 認可的貢獻者
  Gen2-<貢獻者標籤>  × 1
  ...
```

**性質:**
- 不可轉讓(soul-bound)
- 無金融權利、無投票權
- Cardano 錢包中以「收藏品」形式顯示
- 治理肯定時鑄造,附到貢獻者錢包
- 若事後證實該貢獻為惡意,會被 burn(極罕見,作為 safety valve)

**發放標準**:治理裁量;典型是貢獻者通過三份不同 merged PR、或完成一次重要 bounty 之後發放。

### 機制 D:Retroactive Public Goods Funding(Phase 4+,TVL ≥ 10M)

在更大規模下,V1 可能採取季度 RetroPGF 形式的資助輪次(靈感來自 Optimism):

- 治理預留季度 R&D 預算(例:US$2,000)
- 社群提交貢獻 / 提名
- 治理簽名者排序並分配資金
- 公開排名 + 理由

這是**期許,不是承諾**。V1 上線時不承諾 RetroPGF。可行性視 TVL 成長與社群規模而定。

---

## 3. 貢獻者角色

本計畫認可以下貢獻類別:

| 角色 | 目標 repo | 做什麼 | 典型酬庸機制 |
|------|----------|-------|-------------|
| **整合貢獻者** | `optivaults-protocol`(新 DEX adapter / Liqwid 市場條目)+ `optivaults-reference`(keeper 支援) | 實作新 DEX 路徑、新 Liqwid 市場、其他協議整合 | 機制 A(事前 bounty) |
| **Keeper 工程師** | `optivaults-reference` | 改善 keeper 可靠性、監控、恢復工具 | 機制 A + B |
| **Frontend 貢獻者** | `optivaults-reference` | React UI 改善、i18n、UX 打磨 | 機制 B(回溯性) |
| **安全研究者** | `optivaults-protocol`(validator / 部署)或 `optivaults-reference`(operator),scope 見各 repo 的 `SECURITY.md` | 透過協調流程揭露漏洞 | 機制 A(依 `docs/audit-scope.md` 的 tier) |
| **文件貢獻者** | `optivaults-protocol`(spec / whitepaper / docs)或 `optivaults-reference`(operator docs) | 白皮書更新、教學、翻譯 | 機制 B |
| **審計方(正式合作)** | `optivaults-protocol`(主要、外部審計目標)+ `optivaults-reference`(另走時程) | 第三方安全審計 | 從 Treasury audit reserve 出,不走 R&D |
| **工具開發者** | `optivaults-reference`(主要),視工具用途而定 | CLI 改進、監控 bot、區塊瀏覽器儀表板 | 機制 A + B |

每一種角色除了現金酬庸以外,都可能額外拿到貢獻者 NFT(機制 C)。

---

## 4. 資格規則

### 4.1 什麼算貢獻

- 合併進任一官方 OptiVaults GitHub repo 的 PR
- 被接受的 issue / writeup / 揭露
- 完成的 bounty 任務
- 實質的 Discord / 社群支援(例如幫助使用者、撰寫 guide,治理裁量)

### 4.2 什麼不算貢獻

- Fork 出去的程式(貢獻必須 upstream 回官方 repo)
- 抄襲
- 違反貢獻準則的工作(例如造成 license 衝突、夾帶 secret)
- 存在利益衝突卻未揭露的貢獻(例如與 V1 正在整合的 DEX 有關聯)

### 4.3 多方貢獻

若多人共同完成一份工作(例如兩人合撰整合):
- Bounty 依 PR 描述中的明確約定拆分
- 未約定則由治理依貢獻權重判斷比例

---

## 5. 預算可用量

整合與酬庸預算隨 TVL 擴張(複製自 `docs/economics.md §7C`):

| TVL | R&D 類別年入帳 | 實務酬庸容量 |
|-----|--------------|-------------|
| 100K(上線) | ~$43/年 | 沒有結構化計畫:僅公開致謝 |
| 500K | ~$216/年 | 每年 1 次小型 bounty |
| 1M | ~$432/年 | 每年 2–3 次小型 bounty |
| 5M | ~$2,160/年 | 每年 4–6 次 bounty + 1 次大型整合 |
| 10M | ~$4,320/年 | 完整計畫,含季度 RetroPGF 形式輪次 |
| 50M+ | ~$21,600/年 | 成熟計畫,與其他 Cardano DeFi treasury 有競爭力 |

每年的計畫預算由治理依前一年的 R&D 餘額與整合路線圖預期來訂。

---

## 6. 治理互動

所有結構化酬庸透過治理 `TreasurySpend` 走:

- 提案:任何貢獻者或社群成員都可以提 bounty 或回溯性支付
- 審視:治理簽名者評估提案的合理性
- Queue:`TreasurySpend` 一律 7 天 timelock
- Cancel:timelock 期間 1-of-n 否決
- Execute:timelock 過後由治理簽名

這讓貢獻者計畫保留在**公開審計軌跡**上(每筆支付都是一筆鏈上 TX),並避免任何單一方控制酬庸流。

**利益衝突規則**:若治理簽名者同時是某 bounty 的貢獻者,必須迴避該筆簽名。迴避要公開記錄。

---

## 7. 與安全揭露的關係

安全揭露**不**透過本貢獻者計畫處理。V1 的責任揭露姿態是**責任揭露政策(RDP)+ 酬庸式(ex gratia)肯定**框架,描述於 `docs/audit-scope.md §6`。有效揭露的酬庸式感謝支付,由創辦人啟動資金出,不從 Treasury audit reserve 出(Phase 1 $500–$25K TVL 下的 treasury 累積速率太慢,無法提供可預測的來源)。

本文件 §3 機制 A 表格中的「安全研究者」那一列,是對該政策的**跨引**,不是獨立的 bounty 機制。

結構化 bounty tier 計畫是 post-external-audit + post-TVL-scale 的考量(前提條件見 `docs/audit-scope.md §6.3`),**不是** V1 啟動時的承諾。若該計畫未來被引入,它會:
- 由 Treasury `audit_reserve` 累積支撐(屆時規模應足以支撐市場競爭水準獎金、無需動用創辦人資金)。
- 通過治理批准的 `UpdateTreasuryParams`,授權支撐該計畫的 audit-reserve 出款。
- 採用已文件化、經 V1 當下治理簽名者集合審視並核可的 tier 結構。
- 漏洞揭露要求比一般貢獻工作更緊的協調(NDA 窗口、responsible disclosure)。

---

## 8. 公共財立場

OptiVaults 是**公共財協議**:程式原始碼、審計報告、白皮書、營運 runbook 全部公開。對這些公開資產的貢獻,強化的不只是本協議,也強化整個 Cardano DeFi 生態。

本貢獻者計畫的目的,是讓個別貢獻者的誘因與公共財產出對齊,同時避免在協議之上再長出一層金融投機。貢獻者 NFT 刻意設為**不可轉讓**,正是為了防止這件事,聲譽與肯定是長期回報;現金 bounty 只是短期動機。

---

## 9. 時程

| 里程碑 | 觸發條件 | 動作 |
|--------|---------|------|
| V1 上線 | TVL 在 100K 上限、pre-audit | 無計畫;僅非正式致謝 |
| Phase 2 啟用 | Treasury R&D ≥ US$500 或 TVL ≥ 500K | 任務 bounty(機制 A)+ 回溯性(機制 B)+ 貢獻者 NFT(機制 C)正式上 |
| Phase 3 成熟 | Treasury R&D 餘額穩定 ≥ US$2,000 | 第一次 RetroPGF 形式季度輪次(機制 D) |
| Phase 4(成熟) | TVL ≥ 10M | 計畫與其他 Cardano DeFi 協議具競爭力;可預期會有數十位符合 bounty 的貢獻者 |

具體日期在啟用前 14 天,透過 Discord + 治理動作公告。

---

## 10. V1 上線當下怎麼參與

在正式計畫啟用之前:

1. **讀**文件(從本檔開始是好起點)
2. **挑**一個 GitHub 上標 `good-first-issue` 的 issue,或自己提一個
3. **討論**:在 Discord `#contributions` 頻道討論之後再投入顯著精力
4. **提交** PR,依照 repo 根目錄 `CONTRIBUTING.md` 的風格準則
5. **期待值**:merge commit + Discord 公告的致謝。現金酬庸**尚未**開放,進場前請理解這點。

**若你的貢獻屬於實質**(重大新功能、安全研究、完整的協議整合),你的名字會進入 Phase 2 啟用時的回溯性肯定清單。治理已公開表態:啟動期的貢獻者,在計畫啟用後有資格拿到回溯性 bounty。

---

## 11. 延伸閱讀

- `docs/economics.md §7C` — R&D 預算數學與 TVL 預估
- `docs/audit-scope.md §6` — 安全揭露的責任揭露政策 + 酬庸式肯定框架
- `spec/gov-nft.md` — 啟發貢獻者 NFT 設計的 soul-bound NFT 機制
- `spec/governance.md §4.10 TreasurySpend` — bounty 支付的鏈上授權
- `spec/treasury.md §3.4 UpdateParams` — 治理如何隨時間調整 R&D 配置
- `docs/integration-playbook.md` — 提案並完成整合 bounty 的流程
