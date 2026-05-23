# OptiVaults V1 — 經濟模型

**範圍**:錢在協議中怎麼流、誰付什麼、何時協議進入自給狀態。

**層級界定(重要)**:本文件所有 fee 數字描述的是 **OptiVaults 代跑的 vault 實例**(`optivaults.app`),也就是存入者與 operator 層([`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference))之間的互動。**協議層**([`optivaults-protocol`](https://github.com/OptiVaults/optivaults-protocol))是**零 fee**:fork Aiken 合約的團隊,不論他們的運營選擇為何,都不需要付錢給 OptiVaults。當治理設 `performance_fee_bps` 時,設的是**該特定 vault 實例的費率**;合約中的 4.5% 硬上限是**協議層對任何跑該 validator 的 vault 的約束**,**不是**資金流向 OptiVaults。完整兩層 framing 見 `whitepaper §3.5`。

---

## 1. 費用結構一眼就看懂

### 1.1 存款側

- **Direct Deposit**:免費;使用者送 N USDCx 進金庫,依當下 share price 拿到對應的 vUSDCx 份額。
- **Queue Deposit**(order-batched):無協議費;使用者約付 0.5 ADA 的網路費 + batcher tip(使用者自訂 `max_batcher_tip`)。

### 1.2 提款側

- **Direct Withdraw**:提款金額的 0.1% 以 USDCx 留在金庫(透過 share price 上升歸屬給其餘持有者);keeper 停擺 ≥ 7 天時自動免除。
- **Queue Withdraw**(order-batched):無協議費;使用者約付 1 ADA 的網路費 + batcher tip。
- **Emergency Withdraw**(keeper 停擺 7 天後由使用者觸發):免費(合約強制)。

### 1.3 收益側

- **績效費**:每次 Compound 從收割的 yield 中抽 4.5%。
- **硬上限**:4.5%,在合約層強制;治理無論走哪個 redeemer 都不能把績效費推過這個上限。
- **Loss compound**:當鏈上 yield 為負時,費用強制為零(虧損時不收費)。
- **Zero-yield compound**:當鏈上 yield 為零時,純粹做 allocation 更新的 Compound 會推進 `last_realloc_time`,但不抽任何費。

績效費以 **3-way 拆分**,由 `VaultDatum.keeper_fee_bps` 與 `VaultDatum.gov_fee_bps` 管控(treasury 份額由這兩者推導):

| 階段 | 觸發條件 | Keeper | Gov pool | Treasury |
|------|---------|--------|----------|----------|
| V1 啟動 | 部署預設 | 40% | 0%(停用) | 60% |
| Phase 2 | TVL ≥ 500K + 加入外部簽名者 | 40% | 5% | 55% |
| Phase 3 | TVL ≥ 2M + 加入社群簽名者 | 40% | 10% | 50% |

**硬上限**(在 `vault_gov_policy.ak` 的 UpdateFeeSplit redeemer,透過共用的 `validate_update_fee_split` helper 強制,任何治理動作都無法突破):
- `keeper_fee_bps <= 4000`(40%,設高以支持公共財定位下的開源第三方 keeper 經濟可行性)
- `gov_fee_bps <= 1000`(10%)
- `keeper_fee_bps + gov_fee_bps <= 5000`(treasury 下限 ≥ 50%)

**每一次 fee-split 變更都是獨立的 `UpdateFeeSplit` 治理 TX,套 21 天 timelock**(`spec/governance.md` §4.3),所有 action 中最長的 timelock,因為治理在調整自己的報酬。

Keeper 份額:以 USDCx 直接付到該筆 TX 簽名者的錢包。若有多位 keeper 分擔職務,收入依每週輪替機制跨人分配(見 `spec/keeper-auth.md` §4)。

Gov pool 份額:累積到 MultisigGov UTXO 的 `signer_compensation_pool` 欄位,每季透過 `DistributeSignerCompensation` redeemer 分配(見下方 §6 治理簽名者報酬)。

Treasury 份額:依 `spec/treasury.md` 分進四個類別桶。

---

## 2. 不同 TVL 規模下的收入

績效費年度收入(假設 gross APY 6%、費率 4.5%):

| TVL | 年 gross 收益 | 績效費 4.5% | Keeper 40% | Treasury 60% |
|-----|--------------|-------------|------------|--------------|
| 100K USDCx(pre-audit 上限) | 6,000 | 270 | 108 | 162 |
| 500K USDCx | 30,000 | 1,350 | 540 | 810 |
| 1M USDCx(sustainability 門檻) | 60,000 | 2,700 | 1,080 | 1,620 |
| 10M USDCx | 600,000 | 27,000 | 10,800 | 16,200 |
| 100M USDCx | 6,000,000 | 270,000 | 108,000 | 162,000 |

數字都以 USDCx 計。上表為示意參考點,**不是預測**。

---

## 3. Treasury 類別資金流

60% 的 treasury 份額在啟動比例 40/25/25/10(治理在一定範圍內可調,sub-allocation 從歷史 30/40/20/10 重新平衡,讓 audit reserve 累積速度在較小的 treasury 份額下仍維持為總 fee 的 24%,因為新的 40% keeper 直接份額已吸收 ops bucket 過去重複補貼的 per-keeper infra 成本)下流進四個桶:

| 類別 | 比例 | 100K TVL / 年 | 1M TVL / 年 | 10M TVL / 年 | 用途 |
|------|------|--------------:|------------:|------------:|------|
| Audit reserve(40%) | 65 | 648 | 6,480 | 向下一次第三方審計帳單累積(總 fee 的 24%,與舊 80%×30% 同樣累積速度) |
| Operations(25%) | 41 | 405 | 4,050 | 平台層基礎設施:主機(frontend/landing/API)、Blockfrost(平台 queries)、監控、網域、CF Pages,per-keeper infra 現在透過 40% keeper 份額直接補,不再從此 bucket |
| R&D(25%) | 41 | 405 | 4,050 | 協議開發、未來 bounty 計畫(post-audit + TVL-scale,`docs/audit-scope.md §6.3`)、生態補助 |
| Buffer(10%) | 16 | 162 | 1,620 | 預期外支出、法律諮詢、事件應變 |

---

## 4. V1 協議基礎設施的運營成本

一個最小可行 V1 部署需要:

| 項目 | 成本(數量級) | 備註 |
|------|--------------|------|
| 跑 keeper 的伺服器(雙實例 HA) | $10–25/月 × 2 = $20–50/月 | 雙實例以提高 keeper 可用性(見白皮書 §8.4)。 |
| Blockfrost API 存取 | $0–100/月 | 免費版能支撐約 50 req/min;超過或需要專用 key rotation 就要付費版 |
| 監控 + alerting | $5–20/月 | Grafana Cloud 免費版,或自架 stack |
| 網域 + CDN(frontend + landing) | $2–10/月 | 靜態站用 Cloudflare Pages 免費;網域要付 |
| Email / Discord / 通訊 | $0–10/月 | 大多免費;為了送達率可能要付 relay |
| **總計** | **$30–200/月** = **$360–2,400/年** | V1 規模營運的穩態範圍 |

在 pre-audit 100K TVL 上限下,treasury operations 桶每年入帳約 41 USDCx(60%×25% 新分配),keeper 透過 40% 直接份額另外拿到約 108 USDCx/年。Keeper-related 合計預算 ~$149/年 @ 100K。**這仍然不足以覆蓋低端運營成本**($360-$2,400/年),差額由協議 operator 在 pre-audit 階段以啟動資金補上。E2 把補貼從「透過 TreasurySpend 補貼 keeper infra 的 indirect 路徑」轉為「每筆 Compound 直接拿 40% 的 direct 路徑」,移除一層治理摩擦,但**Phase 1 絕對缺口不變**。

---

## 5. 進入自給狀態的路徑

### 5.1 營收 vs 成本 交叉點

用 E2 啟動的類別比例(fee 的 60% × operations 25% = 15% 到 operations):

- **15% × `(TVL × 6% × 4.5%)` = 年度 ops 預算**
- 低端交叉點($360/年 ops):`TVL = $360 / (6% × 4.5% × 15%) ≈ $889,000`
- 高端交叉點($2,400/年 ops):`TVL = $2,400 / (6% × 4.5% × 15%) ≈ $5.93M`

「operations 桶單獨覆蓋基礎設施」的門檻 E2 下約 **USD 900K TVL**(最小可行),**USD 6M TVL**(舒適餘裕)。比 pre-E2 的 $417K-$2.78M 推遲約 2×,因為 ops bucket 從 32% 縮到 15% of fee。**這個轉變被 40% keeper 直接份額吸收 per-keeper infra 成本所抵消**(keeper-related 合計預算反而從 fee 的 52% 微增到 55%)。Ops bucket 縮水後,需要它覆蓋的是**平台層基礎設施**(frontend / landing / API server / treasury 監控),個別 keeper 的基礎設施 / Blockfrost / 監控由 keeper 自己 40% 份額支付。

這條線以下,V1 處於**啟動期**,運行成本超過 treasury 入帳。初期缺口由專案啟動資金承擔;跨過門檻之後,OptiVaults 本身的營收即可支撐基線運營,更高的 TVL 則漸漸支撐 audit reserve + R&D + buffer 類別。

### 5.2 Audit reserve 補足速度

目標第三方審計成本:大約 **USD 50–150K 一次**,成熟運作下預期每 12–24 個月做一次。

各 TVL 下的 audit-reserve 年度累積:

| TVL | 年 audit reserve | 累到 $50K 所需年數 | 累到 $100K 所需年數 |
|-----|------------------|--------------------|----------------------|
| 100K | 65 | 770 | —(不可行) |
| 500K | 324 | 155 | — |
| 1M | 648 | 77 | 155 |
| 5M | 3,240 | 15 | 31 |
| 10M | 6,480 | 8 | 15 |
| 25M | 16,200 | 3 | 6 |
| 50M | 32,400 | 1.5 | 3 |

讀法:以 18 個月為週期的話,**大約 25–50M TVL 之後,audit reserve 能自付下一次完整審計**。在這規模以下,審計靠 §5.2.1 的非稀釋性外部資金堆疊組合而來。

### 5.2.1 公共財路徑下的審計資金堆疊(V1 pre-audit)

V1 的公共財定位(見白皮書 §8.1 + Executive Summary)支援一個非稀釋性的資金堆疊,覆蓋外部審計(目標 Q2-Q3 2027,見 `audit-scope.md §5`),而不用涉及 VC / token / SAFE / SAFT:

| 來源 | 預期金額 | 狀態 | 出處 |
|------|---------|------|------|
| (a) Grant 堆疊 — Catalyst + Cardano Foundation + Intersect Member Committee + Aiken Foundation | 合計潛在 $30K-$150K，Catalyst 單一可取得 $30K-$50K | **撰寫時 Catalyst 處於暫停 / 重組狀態，下一個 Round 何時恢復尚無明確時程。** 並行接洽 Cardano Foundation、Intersect、Aiken Foundation 以降低單一來源依賴。V1 把 (a) 列為候選、等恢復 / 核准，但**不依賴任何單一 grant 來源**。 | 白皮書 §8.1 |
| (b) 審計事務所公共財費率 | 在 $50K-$150K base 上折 30-50%；多 reviewer 委託模式可把 base 壓到 $70K-$100K | 接洽中 | 白皮書 §8.1 |
| (c) 藉大量 heritage 內部審計史縮減範圍 | 自全範圍省 $15K-$25K | Heritage 審計工作 | `audit-scope.md §1` |
| (d) 創辦人 gap-fill 補貼（有上限、非 underwriter） | **最多約 $15K 個人自掏**用於 bridging 微額短缺；創辦人**明確不承諾在任何情境下 underwriting 完整審計成本** — 見白皮書 §0.2 + §4.1 volunteer-builder framing | 啟動資金分配（封頂） | 白皮書 §0.2 / §4.1 / §8.1 |

審計時程（目標 Q2-Q3 2027，見 `audit-scope.md §5`）明確比原 Q3 2026 計畫晚，刻意預留時間以容納 (i) Catalyst Round 恢復的概率、(ii) 並行 Cardano Foundation / Intersect / Aiken Foundation 接洽、(iii) 若 (a)/(b) 結果保守時，社群 / DAO 資助池路徑（白皮書 §8.1 Option C）的成熟時間。堆疊組合後，創辦人在任何情境下自付金額 **$0-$15K**，硬封頂在 gap-fill 上限。若資金堆疊低於 $15K 短缺以上，V1 走白皮書 §8.1 Options A-D contingency tree（時程延後 / 縮減 scope / 社群 crowdfund / 永久 pre-audit 100K cap），不擴大創辦人自付。這個 volunteer-builder 模型讓 V1 在**不 VC / 不發 token / 不稀釋 Apache 2.0 公共財姿態 / 不創辦人財務過度承諾**的前提下推進外部審計。各來源狀態更新，以 `audit-funding-status` 標籤的 GitHub issue 公開發布。

### 5.3 Keeper 份額可行性

Keeper 份額在 V1 啟動時是績效費的 40%;每年 = `TVL × gross_APY × 0.018`。下表假設 **6% 當下參考 blended APY** + **3-keeper 輪替**(每人取 keeper pool 的 ⅓) + **每位 keeper $360/年基礎設施成本**:

| TVL | Keeper 年總 pool | 單一 keeper(3 位) | 扣 $360/年基礎設施後淨額 |
|-----|-----------------|-------------------|---------------------|
| 100K | 108 | 36 | −324(虧) |
| 500K | 540 | 180 | −180(虧) |
| 1M | 1,080 | 360 | 0(打平) |
| 5M | 5,400 | 1,800 | +1,440(經濟上可行) |
| 10M | 10,800 | 3,600 | +3,240(具吸引力) |
| 100M | 108,000 | 36,000 | +35,640(高度吸引) |

**讀法**:在上述 3-keeper 輪替設定下,第三方 keeper 在約 **USD 5–10M TVL** 才變成經濟上可行。之下,keeper 是虧的,除非他們已經為其他協議(例如已經在跑其他 Cardano DeFi 的 batcher / keeper)攤提基礎設施。

這就是 V1 啟動時設 `RegistrationMode = GovernanceOnly` 的原因,當沒有經濟誘因吸引第三方時,開放 permissionless keeper 註冊沒有意義。這個機制大約在 $5M TVL 才變得有意義,屆時治理可以透過單一鏈上動作切換到 `PermissionlessWithBond` 模式(不需要合約遷移,見 `spec/keeper-auth.md` §5)。

**三層自給門檻,不同設定給出很不同的數字。** 上表假設的是特定設定(3 位 active keeper、每人 $360/年)。V1 實際上有三層不同的自給門檻,取決於「誰在跑 keeper」+「什麼 APY 條件」:

| 層 | 覆蓋範圍 | 年度成本 | Breakeven TVL(6% 當下 APY) | Breakeven TVL(2% 悲觀 APY) |
|----|---------|---------:|-------------------------:|------------------------:|
| (a) 單一創辦人 keeper、邊際運營 | 創辦人吸收自己的勞動、共用既有基礎設施 | $100–$300 | $185K – $555K | $555K – $1.67M |
| (b) 單一非創辦人專業 keeper | 獨立 operator、專用伺服器 + 監控 | $400–$800 | $740K – $1.48M | $2.22M – $4.44M |
| (b') 3-keeper 輪替(上表) | 3 位獨立 operator 各吸收 $360/年 | 共 $1,080 | ~$2M | ~$6M |
| (c) 機構級運營 + audit-reserve 累積 | 完整協議自給,含未來審計成本($30–50K 每 18–24 個月攤提) | $1,500–$3,000 + 審計攤提 | $20M+ | $50M+ |

**上表中的 $5–10M 數字** 對應的是 **層 (b') 3-keeper 輪替 + 悲觀 1–2% APY**（刻意保守地設定，讓 V1 即使在 Liqwid rate 壓縮時仍可行，而不是只在當下參考條件下可行）。在 **6% 當下 APY + 單一非創辦人 keeper（層 b）** 下，可行門檻會降到 $740K–$1.48M，早很多。V1 實際的自給目標是**層 (a) / (b)**，不是層 (c)；層 (c) 由 §5.1 的 funding stack（grants + 公共財費率 + 範圍縮減 + 受封頂的創辦人 gap-fill，見 §5.2.1 (d) — 白皮書 §0.2 解釋為何創辦人不是審計 underwriter 的 volunteer-builder framing）覆蓋，**不**依賴 treasury 累積。這與 V1 的非商業公共財定位一致，V1 不需要擴張到 $20M+ TVL 才算「完全自給」。白皮書 §4.3 有給存入者看的版本。

**SwapAda 對 keeper 可行性的影響。** 在沒有鏈上 ADA 補充機制的情況下,一個每筆 Minswap V2 order 會燒掉約 2 ADA 的金庫,需要 keeper 大約每 2–4 週自付 ADA 替金庫 top-up 一次(先前的 pre-V1 部署就是這樣運作的,由創辦人-keeper 手動送 ADA 到金庫)。V1 的 `SwapAda` redeemer(`spec/ada-swap.md`)把這個迴圈標準化到鏈上:keeper 貢獻 ADA、以 oracle 價格從金庫換取 USDCx,這是**公平交換,不是捐贈**。Keeper 面經濟影響:先前創辦人在 Minswap 上鏈下執行(並付 slippage 的)ADA-換-USDCx,現在是受 validator 閘控的原子 TX。對 keeper 可行性表的淨影響:**中性到微正**,SwapAda 每次的 ADA 網路費(約每筆 1 ADA × 每年 15 筆 = 15 ADA ≈ 100K TVL 下約 $10/年)完全被省下的 Minswap slippage / fee 吃掉。存入者端透過緩慢的 USDCx drain 來承擔 Minswap V2 batcher fee(100K TVL 下約 0.02% APY 的拖拉);這個拖拉已納入 §6.2 的「預期 net APY」那一欄。多 keeper 輪替(Phase 2+ Mixed / PermissionlessWithBond 模式)下,SwapAda 操作和 Compound / BatchProcess 一樣按公平輪替在 keeper 間分配,沒有任何一位 keeper 會被過度擔起這個成本。

---

## 6. 存入者的回報預期

### 6.1 Net APY 公式

對存入者:

- **Net APY** = gross APY ×(1 − performance_fee_rate) − 其他摩擦
- 4.5% 費率下:net APY ≈ gross × 0.955
- 0.1% Direct Withdraw 費用:退場時一次性 0.1%(若走 Queue Withdraw / Emergency Withdraw 則為零)

### 6.2 情境

示意情境(**非預測**;實際 yield 視 Liqwid 市場條件與策略配置而定)。啟動配置 45% DJED + 25% USDM + 30% 閒置 USDCx buffer(buffer 在 V1 啟動時收益 0%;見白皮書 §2.3,有未來可調性的說明):

| 情境 | 假設的 Liqwid rate | Gross APY 數學 | Gross APY | Net APY(扣 4.5% 費) |
|------|------------------|----------------|-----------|----------------------|
| 悲觀(DJED/USDM rate 壓縮、借貸需求弱) | DJED 2-3%、USDM 1-2% | `(0.45×2-3%) + (0.25×1-2%) + (0.30×0%)` | 1.15–1.85% | 1.10–1.77% |
| 當下參考(2026-04-21 Liqwid 快照) | DJED ~11.84%、USDM ~5.33% | `(0.45×11.84%) + (0.25×5.33%) + (0.30×0%)` | ~6.66% | ~6.36% |
| 樂觀(持續高借貸 + 治理核准 buffer 約 1% yield) | DJED 13-16%、USDM 6-8%、buffer 走 UpdateStrategy 得 1% yield | `(0.45×13-16%) + (0.25×6-8%) + (0.30×1%)` | 7.65–9.50% | 7.31–9.07% |

啟動時的 `(0.30 × 0%)` buffer 項反映了一個明確的設計決定,保持閒置 USDCx buffer 具備流動性(見白皮書 §2.3 為何如此)。治理可以透過 `UpdateStrategy` 把 buffer 的一部分或全部導向 yield-bearing 部位,這會把 buffer 項從 0% 往上提。任何此類變更都會公開揭露 + 執行前 7 天 timelock。

### 6.3 與替代選擇的誠實比較

對一位已持有 USDCx 的存入者(存入資產範圍,無 ADA 價格曝險):

| OptiVaults 的替代方案 | 典型 net APY | 風險堆疊 |
|----------------------|-------------|----------|
| USDCx 放錢包不動 | 0% | 僅發行者 |
| Liqwid 直接 supply USDCx | ~0.5–2%(浮動,通常低於金庫組合) | Liqwid + 發行者 |
| Minswap V2 stable-pair LP | 浮動 + 無常損失 | Minswap + IL + 發行者 |
| **OptiVaults V1**(悲觀) | 1.05–1.67% | 金庫 + Liqwid + keeper + 治理 + 脫鉤 + 發行者 |
| **OptiVaults V1**(當下參考) | ~6.08% | 同上 |

在悲觀端,OptiVaults 的回報與仔細經營的 direct-Liqwid 策略大致相當,但多了額外的風險層(金庫合約、keeper、治理、脫鉤監控)。在中高 rate 環境下,keeper 的分散 + 自動複利 overhead 攤提優勢會明顯勝出手動配置方案。

**ADA 原生質押(~2.3–2.4%)** 不是直接可比較的方案,它需要持有 ADA、並會引入 ADA 價格曝險。若你已經選擇持有 USDCx,那表示你(隱性或明確地)已經決定不承擔 ADA 價格風險。

---

## 7. 啟動期揭露

在 pre-audit 的 100K TVL 上限下,OptiVaults 自己的營收並不覆蓋運營成本。差額約為**每年 USD 300–2,000**(視基礎設施選擇而定),由專案的**啟動資金**在 pre-audit / 初期存款階段承擔。這對新 DeFi 協議而言是正常的啟動狀態,預期隨著 TVL 進入自給規模後自然解決。

### 7.1 連續性姿態

V1 運營姿態:**「在 Q2-Q3 2027 審計窗口(見 `audit-scope.md §5`)+ post-audit TVL 爬升期間維持運營,直到啟動資金用盡為止」**,**不是**一份可合約強制執行的長期保證。

對潛在存入者而言,合理的規劃期是:「假設產品在審計 + post-audit 6-12 個月爬升期內正常運作;每到一個里程碑就重新評估」。

### 7.2 有序停運協議(若啟動資金在達成自給前用盡)

若啟動資金 runway 耗盡、TVL 仍未進入自給區:

1. **提前至少 30 天**公開停運通知(Discord + GitHub issue + 鏈上治理動作)
2. 治理對 V1 金庫執行 `EmergencyWithdraw { frozen: 1 }`,凍結 Compound / Batch / Deploy;**Withdraw 保持開放**
3. 治理透過 `RecallFromLiqwid` + `MergeUtxo` +(若有剩下的非 USDCx)`AdminDeployNonDeposit` → Minswap V2 → USDCx,把所有部署資本 drain 回 idle buffer
4. 使用者走 Direct Withdraw(keeper 停擺 7 天後免費)或 self-serve 的 `withdraw-cli` / `emergency-withdraw` 工具退場
5. 當 `total_deposited == 0` 時,vault UTXO 被銷毀,協議完全下架

**觸發 sunset 時的鏈上最低運營資金儲備**:founding entity 承諾從啟動資金中預留至少約 **150 ADA**,專用於覆蓋 90 天清算窗口內的鏈上費用(keeper heartbeat + Liqwid 全 recall + Minswap V2 router gas + Conway-era ref-script 費率附加 + safety buffer)。完整分項見白皮書 §4.1。這保證 sunset 窗口擁有獨立資金,即使主要啟動資金耗盡(這本身就是 sunset 觸發條件之一),存入者也不會遇到「operator 沒 ADA → 提款 TX 失敗」。

### 7.3 30 天通知的不可執行性

30 天通知承諾**沒有合約層面的執行機制**。它靠的是:

1. 專案團隊自律與治理
2. Cardano 生態中靜默關停的聲譽成本
3. 獨立的鏈上保證:使用者本金**絕不被卡住**:Withdraw 永遠開放,且 keeper 停擺 7 天後 early-withdraw fee 自動免除

使用者不需要依靠這 30 天通知就能全身而退;它是一份禮貌,不是退場的先決條件。

---

## 7A. 治理簽名者報酬機制

Phase 2+ 透過 `UpdateFeeSplit` 把 `gov_fee_bps` 從 0 調到 500(5%)或 1000(10%)來啟動治理簽名者報酬池。

### 7A.1 累積

每筆 Compound TX 把績效費的 `gov_fee_bps / 10000` 路由到 MultisigGov UTXO 的 `signer_compensation_pool` 欄位。池持續累積;分配為每季一次(§7A.3)。

### 7A.2 資格(X3 混合規則)

簽名者要通過以下**兩個**條件,才有資格取得 Q 季的分配:

1. **full-quarter tenure**:簽名者在 Q 開始前就已加入(`signer_joined_at_ms <= last_distribute_ms`)
2. **實際參與**:Q 期間簽名者至少簽過以下其中一項:
   - `QueueAction`、`ExecuteAction`、`CancelAction`、`RotateSigners`(營運性治理工作)
   - `Heartbeat`(明確的 liveness 佐證,每位簽名者每 90 天最多一次)

理由:安靜的一季若沒有任何治理動作,不該讓所有簽名者失去資格,Heartbeat 是 fallback 訊號。反之,期中加入的簽名者要等下一季才符合資格(避免用最後一刻輪替來鑽 tenure 規則)。

### 7A.3 季度分配

任何當前簽名者都可以在 90 天 cadence 到期後觸發 `DistributeSignerCompensation`(1-of-n)。池會平分給合格簽名者,以 USDCx 支付到各自地址。

### 7A.4 Forfeit 流向(Y1:forfeit 到 audit reserve)

未合格簽名者的份額會經 `ReceiveGovForfeit` 繞過正常的 4 類拆分,直接灌進 Treasury `audit_reserve_balance`。理由:

- 避免「希望同事失敗」的反向誘因(若 forfeit 重新分配給合格簽名者)
- 強化最安全關鍵的預算類別
- 與「存入者保護為最高優先」一致

### 7A.5 預估報酬(yield 假設:5.5% gross APY)

| TVL | 階段 | gov_fee_bps | 年度 pool | 簽名者數 | 每位(合格)年報酬 |
|-----|------|-------------|-----------|--------|-------------------|
| 100K | 1 | 0 | $0 | 3 | $0 |
| 500K | 2 | 500 | $82 | 5 | ~$16 |
| 1M | 2 | 500 | $165 | 5 | ~$33 |
| 2M | 3 | 1000 | $660 | 7 | ~$94 |
| 5M | 3 | 1000 | $1,650 | 7 | ~$236 |
| 10M | 3 | 1000 | $3,300 | 7 | ~$471 |
| 50M | 3 | 1000 | $16,500 | 7 | ~$2,357 |

**誠實讀法**:USD 5M TVL 以下,簽名者報酬是象徵性的。簽名者的參與主因是非金錢的(聲譽、影響力、與協議成功的對齊)。簽名者身份模型見 `docs/security-model.md §2`;把聲譽形式化的 soul-bound Gov Signer NFT 見 `spec/gov-nft.md`。

---

## 7B. 多 keeper 輪替下的 keeper 報酬

Phase 2+ 可以透過 `UpdateKeeperAuth` 加入額外授權的 keeper。之後 keeper 費會在所有授權 keeper 間,以**每週 round-robin** 主班機制輪替(見 `spec/keeper-auth.md §4`)。

### 7B.1 費用流

每筆 Compound / MergeUtxo / BatchProcess / Supply / Recall TX 會把相關費用或 yield 的 `keeper_fee_bps / 10000` 直接路由到簽名 keeper 的 PKH 地址。跨一整輪輪替週期,每位授權 keeper 大約賺 `1/N × keeper_total_fee`(N 為活躍集合大小)。

### 7B.2 Keeper 運營成本

| 成本項 | 低端 | 標準 | 高可用 |
|--------|------|------|--------|
| 伺服器(keeper 實例) | $60/年 | $240/年 | $600/年 |
| Blockfrost key ×2 | $360/年 | $720/年 | $1,800/年 |
| 監控 + alerting | $50/年 | $200/年 | $500/年 |
| 備份 / HA 工具 | $0 | $100/年 | $500/年 |
| **總計** | **~$470/年** | **~$1,260/年** | **~$3,400/年** |

### 7B.3 各 TVL 下 keeper 淨收入(標準成本等級)

A-Plain 授權模式(每筆 keeper TX 都要 spend 一次 keeper_auth UTXO)帶來的額外每筆 TX 成本:穩態 8 TX/天 下大約 $292/年。列為 keeper 運營 overhead。

| TVL | Gross keeper fee 40% | 標準 ops + A-Plain 成本 | 淨 |
|-----|----------------------|------------------------|-----|
| 100K | $108 | $1,552 | **-$1,444**(啟動資金補差額) |
| 500K | $540 | $1,552 | -$1,012 |
| 1M | $1,080 | $1,588 | **-$508**(仍低於 break-even,但約為 20% 時代缺口的一半) |
| 5M | $5,400 | $1,734 | **+$3,666** |
| 10M | $10,800 | $1,810 | **+$8,990** |
| 25M | $27,000 | $2,078 | **+$24,922** |

**Break-even TVL**:標準等級 keeper 經濟下約 **USD 3–4M**。之下,keeper 是虧的;非創辦人 operator 不符經濟。Phase 4 啟用 `PermissionlessWithBond` 的閘門就是 TVL 達到此門檻。

---

## 7C. Treasury R&D 類別:整合 bounty 與貢獻者計畫

R&D 類別(V1 啟動時為 treasury 入帳的 25%)資助:

1. **新協議整合**:新 DEX 路徑、新 Liqwid 市場、新借貸協議(寫好後見 `docs/integration-playbook.md` 的 7 步 SOP)
2. **貢獻者 bounty**:keeper / frontend / 文件的開源貢獻(Phase 2+ 形式化尚待落地;見 `docs/contributor-program.md`)
3. **工具開發**:監控擴充、恢復工具、auditor 工具

**V1 上線的貢獻者報酬姿態**:100K TVL 為非正式。當 R&D 餘額累積到約 USD 500(大約 Phase 2 時機)時,任務式 bounty 計畫啟動。在那之前,肯定為非正式,貢獻者 NFT 設計與正式 bounty 計畫同步進行。

**R&D 預算可用量**:

| TVL | R&D 年入帳 | 實務 bounty 容量 |
|-----|-----------|-------------------|
| 100K | ~$43/年 | 無:只有致謝 |
| 500K | ~$216/年 | ~1 次小 bounty($150–250) |
| 1M | ~$432/年 | ~2 次小 bounty |
| 5M | ~$2,160/年 | ~4–6 次 bounty + 1 次大型整合 |
| 10M | ~$4,320/年 | 完整計畫 + 正式 RetroPGF 形式輪次 |

---

## 8. Post-audit 上限時程

post-audit(目標 Q2-Q3 2027,見 `audit-scope.md §5`)之後,100K USDCx TVL 上限預期分階段放寬。確切時程會跟審計報告一起發佈,這裡不事前承諾;目前意向是「把審計發現的修補」對應到每個上限放寬里程碑的分階段爬升。代表性的示意時程:

| 階段 | 觸發條件 | TVL 上限 |
|------|---------|---------|
| V1 上線 | Pre-audit | 100K USDCx |
| Stage 2 | 審計發現完全修補 + 30 天乾淨運作 | 500K USDCx |
| Stage 3 | post-audit 6 個月乾淨運作 + 無未解決 medium+ 發現 | 2M USDCx |
| Stage 4 | 12 個月乾淨運作 + 白皮書 §8.6 的社群治理完整上線 | 無上限 |

上表為示意,實際時程在 post-audit 決定。唯一的承諾特性是:**上限放寬必須閘控在外部可驗證的里程碑上**,不是 operator 的自由裁量。

---

## 9. Liqwid / Minswap / USDCx:外部協議的費用滲漏

OptiVaults 自己的費用結構只是存入者 net-yield 計算的一部分。其他摩擦:

| 摩擦 | 典型大小 | 誰拿走 |
|------|---------|--------|
| Liqwid 協議(qToken 兌換率價差) | 很小(pass-through) | Liqwid Labs + 流動性提供者 |
| Minswap V2 swap 費 | 每 leg 約 0.3% | Minswap pool |
| Cardano 網路費(每筆 TX) | 約 0.2–1 ADA | Cardano 協議(燒掉) |
| Blockfrost / Ogmios rate-limit 升級 | 已納入 operations 桶 | Blockfrost Labs |

存入者 net-yield 公式(近似):

```
Net Yield ≈ Gross Liqwid yield
           ×(1 − 4.5%)                       [績效費]
           −(swap leg 摩擦,在 deploy/recall 週期攤提)
           −(Cardano 網路費,在 deposit/withdraw)
           −(Direct Withdraw 時一次性 0.1%,其他路徑則為零)
```

對一筆持有 12+ 月的平均存款,網路 + swap 摩擦在本金攤提下通常 < 0.5%,所以主導 rate 的因素仍是 4.5% 績效費 + Liqwid 自家市場 rate。

---

## 10. 給存入者的總結

**白話版**:

- 你存 USDCx。金庫給你 vUSDCx 份額。
- Yield 靠自動複利累積,不用動手。
- 你要付的費用:**存款 0 費用、Direct Withdraw 0.1%、每次收割的 yield 抽 4.5%**(從不碰本金)。
- Keeper 拿多少:V1 啟動時 **4.5% 收割費的 40%**(≈ yield 的 1.8%,設高以支持公共財定位下的開源第三方 keeper 經濟可行性)。其餘 60%(yield 的 2.7%)進鏈上 treasury,依類別分桶使用。
- **V1 啟動於啟動期**，100K TVL 下，營收並不完全覆蓋運營成本。V1 有三層自給門檻（§5.3）：(a) 創辦人-keeper 邊際運營在 $185K–$555K TVL（當下 APY）/ $555K–$1.67M（悲觀 APY） break even；(b) 非創辦人專業 keeper 在 $740K–$1.48M / $2.22M–$4.44M；(c) 機構級運營 + audit-reserve 累積在 $20M+ / $50M+。V1 的實際目標是層 (a) / (b)；層 (c) **刻意不是目標**，審計資金來自 §5.1 的 funding stack（grants + 公共財費率 + 範圍縮減 + 受封頂的創辦人 gap-fill ~$15K 依 §5.2.1 (d) — 創辦人**不是**審計 underwriter，見白皮書 §0.2），**不**靠 treasury 累積。Phase 1 初期營運缺口由創辦人依白皮書 §4.3.1 minimal-operations 政策從個人收入補貼吸收；若成長停在層 (a) 以下且 §1.5 外部觸發條件（USDCx / Liqwid / Cardano / oracle 事件）或審計資金失敗（§8.1 Options A-D）實際成立，啟動 §7.2 的 sunset 協議。
- **你的本金絕不被卡死**,Withdraw 隨時可在鏈上進行,與 keeper 狀態、代管基礎設施可用性、創辦人狀態都無關。

完整給存入者的文件 + 風險揭露見 `whitepaper/whitepaper.md`;信任邊界分析見 `docs/security-model.md`。
