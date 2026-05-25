# OptiVaults V1

![License](https://img.shields.io/badge/license-Apache%202.0-blue)
![Aiken](https://img.shields.io/badge/aiken-v1.1.x-red)
[![CI](https://github.com/OptiVaults/optivaults-protocol/actions/workflows/aiken-check.yml/badge.svg?branch=v1)](https://github.com/OptiVaults/optivaults-protocol/actions/workflows/aiken-check.yml)
![Audit Status](https://img.shields.io/badge/audit-pending%20Q2--Q3%202027-yellow)
![Mainnet](https://img.shields.io/badge/mainnet-pre--launch-orange)

> **開發分支：`v1`。** 本 repo 沒有 `main` 分支:V1 是第一個公開釋出版本,我們以版本號作為分支名。未來主要版本(V2、V3⋯)會走各自的平行分支。

**OptiVaults V1 是 Cardano DeFi 公共財參考實作 (reference implementation):一個非託管、鏈上自動複利的穩定幣金庫,以 Apache 2.0 授權釋出,作為 Cardano DeFi 公共財的一份貢獻。V1 沒有針對商業規模做最佳化。** 存入者應有的預期、資金來源策略、以及法規姿態,請見白皮書 Executive Summary + §12 免責聲明。

本資料夾收錄 V1 的設計、規格、實作與遷移文件。這裡所有內容都是以 V1 本身為主體來寫,不是前代版本的延續或修補。

---

## 兩層架構

OptiVaults V1 **刻意被拆成兩個 repo**,反映兩個**根本不同**的東西:

- **`optivaults-protocol`**(本 repo):**協議層**。Aiken validators、協議規格、白皮書、部署流程。**本層零費用**;任何團隊都可以 fork 並啟動自己的 vault,完全不用付錢。**純 Cardano DeFi commons 貢獻**。
- **[`optivaults-reference`](../optivaults-reference)**:**operator 參考實作**。TypeScript keeper、API server、frontend、CLI 工具。跑 `optivaults.app` 的 live vault 實例。由合約強制的 4.5% 績效費支撐(啟動 40% keeper / 60% treasury,keeper 份額推到合約硬上限以支持開源第三方 keeper 經濟可行性;**無創辦人 dividend、無投資人 return、無 token**)。以 Apache 2.0 授權,歡迎 fork。

**4.5% fee 只發生在 operator 層**。**協議本身免費**:你跑自己實例就不需要付。完整費用拆分見 `docs/economics-zh-TW.md`;跨兩層的信任模型見 `docs/security-model-zh-TW.md §2`。

---

## 版本定義

- **V1**:第一個公開上線版本。以獨立產品的方式設計、規格化與審計。公開存入者的入口版本。
- **Prior versions (內部驗證期)**:內部驗證期。在 100K USDCx 上限的 pre-audit 框架下,於 Cardano mainnet 跑過一連串架構迭代,用來在真實市場條件下驗證合約不變量。internal-verification phase 是內部驗證的最後一版;V1 mainnet 上線時,該期將正式停運(sunset)。

V1 不是「internal-verification 加 patch」,而是獨立釋出版本,有自己的架構、自己的審計歷程(V1 pre-launch 內部輪次 + Q2-Q3 2027 第三方審計),以及自己的公開上線標準。

---

## V1 核心特性(摘要)

OptiVaults V1 由以下架構決策構成。每一項在本資料夾的對應文件中各自詳述。

1. **非託管鏈上金庫**：使用者資金全程由 Aiken PlutusV3 智能合約管控,沒有任何 operator 密鑰能提走本金。
2. **以 USDCx 作為存入資產**：Circle 透過 xReserve 跨鏈儲備機制在 Cardano 發行的美元錨定原生穩定幣。金庫將存入的 USDCx 路由至 Liqwid Finance 的穩定幣市場(DJED、USDM)以及 Minswap V2 的 DEX 路徑,以取得分散後的收益。
3. **m-of-n MultisigGov 治理**：所有協議政策變更(策略、費率、緊急凍結)都必須通過多簽 + 7 天 timelock + 1-of-n 取消否決。
4. **鏈上金庫儲備**：績效費收入的 60% 流進由治理管理的 treasury 合約,並由合約強制劃分至四個用途(audit reserve / operations / R&D / operational buffer;啟動 sub-allocation 40/25/25/10 維持 audit-reserve 累積速度為總 fee 的 24%)。
5. **以 stake validator 做 keeper 授權**：keeper 的操作透過一個帶 mode flag 的 stake validator 驗證,讓授權規則可以演進(治理核可清單 → 帶保證金的 permissionless),不需要重部署主 vault 合約。
6. **keeper 費率分成 40%**：執行該筆 Compound 的 keeper 拿 40% 績效費作為營運補償(validator 硬上限);其餘 60% 進 treasury。設在硬上限是為了在公共財定位下支持 post-audit Phase 2+ 第三方 keeper 經濟可行性。
7. **使用者自訂 batch tip**：Order UTxO 帶有使用者自訂的 tip 上限;keeper 在處理 batched order 時只能在此上限內收取。
8. **Withdraw-Zero forwarding pattern**：單一 vault UTxO 透過 `vault_proxy` 委派給 10 個 staking validator(`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`),以滿足大小限制並做乾淨的角色分離。切分理由(四條正交軸線:授權邊界、治理反應延遲、bytecode 成本集中點、size 修正)整理於 `spec/architecture.md §4.1`。每個 stake credential(10 個 Withdraw-Zero 委派的 validator + `keeper_stake_script` + `minswap_v2_adapter` SwapAdapter + `sundaeswap_adapter` + `sundaeswap_cancel_guard`,共 14 個)都各自帶有自己的 A2 `publish` handler,所以這 14 份 stake-registration 押金都可以在 sunset 時透過治理回收。
9. **編譯期信任錨點**：Vault Identity NFT、governance NFT policy、treasury script、keeper stake script 都在部署時燒進 validator script hash,而不是放在 datum 欄位。
10. **Pre-audit TVL 上限**：Operator 自律執行的 100K USDCx 上限,一直到 Q2-Q3 2027 第三方審計完成為止;post-audit 的上限調整計畫會與審計報告一併公開。
11. **公共財定位**：V1 被定位為**非商業**的公共財參考實作。4.5% 績效費用於覆蓋營運 + audit reserve + 長期 runway,不是創辦人或投資人的收益。Apache 2.0 授權讓 fork 與特化變得可行(不同穩定幣組合、不同風險姿態、區域變體)。V1 可能就是最終狀態,也可能是其他 Cardano DeFi 團隊改造的基礎,這兩個結局都是可接受的。存入者參與時應抱持的心態是「**貢獻公共財 + 擔任早期驗證者**」,不是購買商業服務。完整含意見白皮書 §12 免責聲明。

---

## 延伸閱讀

V1 另外為它實作的五個反覆出現的 Cardano DeFi 模式發布了**模式 rationale 筆記**:Validator Identity NFT、MultiSig Governance + Timelock、Withdraw-Zero Forwarding、Registry + Auth NFT Whitelist、VaultDatum Tiered Immutability。每份筆記都用通用詞彙描述模式本身,並把 V1 的實例化當作具體案例引用。專案對 Cardano Improvement Proposal 流程的整體立場見 [`docs/cip-readiness-posture-zh-TW.md`](docs/cip-readiness-posture-zh-TW.md)（V1 準備模式文件、但在 V1 release 階段不會撰寫任何 CIP 提案）;五份逐模式筆記見 [`spec/pattern-rationale-*.md`](spec/)。

---

## 目錄結構

```
.
├── README.md                   本檔案
├── spec/                       V1 協議規格
│   ├── architecture.md         高階架構(含 §4.1 切分歷史)
│   ├── vault-datum.md          VaultDatum 欄位、不變量、狀態轉移(29 欄位)
│   ├── treasury.md             Treasury 合約規格
│   ├── keeper-auth.md          Keeper stake-validator 規格
│   ├── order-batch.md          Order + BatchProcess + user-tip 規格
│   ├── governance.md           MultisigGov actions + timelock 規則(14 個 ActionKind)
│   ├── multisig-gov.md         MultisigGov 內部邏輯 + is_gov_authorized 跨 validator 斷言
│   ├── gov-nft.md              治理簽名者 soul-bound NFT
│   ├── ada-swap.md             SwapAda redeemer + dual-feed 預言機讀取器
│   ├── vault-nft.md            Vault Identity NFT one-shot mint 模式
│   ├── swap-adapter.md         SwapAdapter 介面 + B@launch=1 上線後新增 DEX 流程
│   ├── pattern-rationale-validator-identity-nft-zh-TW.md     通用 Validator Identity NFT 模式(V1 案例研究)
│   ├── pattern-rationale-multisig-gov-timelock-zh-TW.md      通用 m-of-n + timelock + cancel veto 模式
│   ├── pattern-rationale-withdraw-zero-forwarding-zh-TW.md   通用 Withdraw-Zero Forwarding 模式(size + per-TX-fee 切分)
│   ├── pattern-rationale-registry-auth-nft-zh-TW.md          通用 governance-mutable whitelist + auth NFT 模式
│   └── pattern-rationale-vault-datum-tiered-zh-TW.md         通用 tiered-immutability datum 模式
├── contracts/                  V1 Aiken PlutusV3 原始碼（17 個 logic validator + 4 個 NFT mint policy + `minswap_v2_adapter` + 2 個 SundaeSwap artefact）;`aiken check` 全綠（對應部署 commit 跑可取得當前 test summary）
├── deploy/                     部署流程
│   ├── README.md               Deploy pipeline 總覽 + checklist
│   ├── deploy.ts               單指令 ceremony 指揮(冪等 + 可續跑)
│   ├── compile.ts              離線 hash 推導(跨 24 個 artefact 做 applyParams)
│   ├── lib/                    blockfrostProvider + 設定載入 + 狀態檔 + datum 建構 + ref-script 部署 + 階段助手
│   ├── config/                 preprod.example.json + mainnet.example.json(樣板)+ preprod-mock.json(operator 自備的實用設定為 gitignored)
│   ├── state/                  Ceremony 狀態 checkpoint(gitignored，依 releaseTag 分 JSON)
│   ├── tools/                  Operator CLI
│   │   ├── deregister-stakes.ts        舊版(pre-A2)
│   │   ├── derive-gov-signers.ts       PKH 推導助手
│   │   ├── whoami-preprod.ts           錢包狀態快檢
│   │   ├── a2-queue-deregister.ts      A2 Queue(冪等)
│   │   ├── a2-execute-deregister.ts    A2 Execute(冪等)
│   │   ├── a2-cancel-deregister.ts     A2 Cancel(冪等)
│   │   ├── h-emergency-benign.ts       ActEmergencyWithdraw(0,0) Queue+Execute 煙霧測試
│   │   ├── verify-minswap-v2-decode.ts 鏈下 Minswap V2 order decoder 驗證器
│   │   ├── reclaim-refs.ts             Sunset 時 ref-script ADA 回收
│   │   ├── full-drain-test.ts          已作廢(pre-Phase-77 拓撲)
│   │   ├── mock-full-drain-deploy.ts   已作廢(pre-Phase-77 拓撲)
│   │   ├── sunset-ceremony.ts          完整 sunset 流程指揮
│   │   └── SUNSET_RUNBOOK.md           Operator sunset SOP
│   └── runbooks/
│       └── v1-mainnet-ceremony.md      V1 mainnet 部署 runbook(pre-flight + 階段 + 失敗處理 + sunset)
├── docs/
│   ├── product-overview.md     給使用者看的實務總覽(EN)：你存什麼、拿什麼、風險用一般用語寫
│   ├── product-overview-zh-TW.md  繁體中文產品總覽
│   ├── migration.md            internal-verification 停運 → V1 存入者過渡
│   ├── economics.md            費用結構、treasury 資金流、永續性數學
│   ├── security-model.md       信任邊界、威脅模型、已知殘餘風險
│   ├── audit-scope.md          Pre-audit 內部輪次計畫 + 外部審計範圍
│   ├── integration-playbook.md 新增 DEX 路徑 / Liqwid market 的 operator SOP
│   ├── contributor-program.md  開源貢獻者回饋(Phase 2+ 啟用)
│   └── cip-readiness-posture-zh-TW.md   V1 對 Cardano Improvement Proposal 流程的立場(資訊性質)
├── tests/
│   └── preprod-e2e-plan.md     規格層級的情境目錄(100+);可執行的 TS 腳本放在 `optivaults-reference`(operator repo)
└── whitepaper/
    ├── whitepaper.md           V1 公開白皮書(EN)
    └── whitepaper-zh-TW.md     V1 公開白皮書(繁體中文)
```

每份文件都是寫成 V1 的獨立參考,這個 tree 裡任何一份都不預設讀者讀過前代文件。

---

### 開發歷史說明

本 repo 在 2026 年 4 月作為 V1 branch 公開發布,整合收攏了大約 1,000+ commit 的內部驗證期迭代。內部驗證期脈絡見 `spec/architecture.md §4.1`(切分歷史)與 `docs/migration.md`(sunset 計畫)。

給審計合作方:V1 的審計基準會是 engagement letter 簽署時 v1 branch 上釘住的那個 commit。更早的開發歷史可依需要在非正式保密前提下提供。

---

## 狀態

V1 目前處於**mainnet pre-flight 階段**:

- ✅ 規格 / 文件 / 白皮書完成(`spec/` + `docs/` + `whitepaper/` 共 15 份 markdown)。
- ✅ 全部 17 個 Aiken logic validator + 4 個 NFT mint policy + `minswap_v2_adapter` + 2 個 SundaeSwap artefact 都已實作,`aiken check` 全綠(`contracts/`)。切分理由見 `spec/architecture.md` §4.1。`UpdateSlippagePolicy` + 2 個 VaultDatum 欄位(§5.4 Phase 2)以及 ref-script SwapAdapter dispatch + `minswap_v2_adapter` + Registry `swap_adapter_hashes`(§B@launch=1)全部上鏈。
- ✅ 單元 + property 測試套件：對應部署 commit 跑 `aiken check` 全綠（cd contracts && aiken check 取得當前 summary；property test 使用 `aiken/fuzz` 的 iteration cap 紀律，首次失敗 early-exit）。
- ✅ Preprod E2E 測試計畫已草擬(`tests/preprod-e2e-plan.md`),涵蓋全部 vault validator + 4 個 NFT one-shot policy + 跨 validator 整合流程,共 100+ 個情境。
- ✅ Preprod E2E 測試腳本:多階段覆蓋，包含 ceremony health + 用戶流程（Deposit / Withdraw / Queue / Batch / Order Cancel+Expire / Queued-Withdraw）+ zero-yield Compound + MergeUtxo 捐贈路徑（含負測路徑）+ 治理狀態機流程 + oracle / SwapAdapter chain replay。腳本發布在 operator reference repo。
- ✅ 多次 Preprod ceremony 已執行，每次 42 筆 TX，所有階段鏈上驗證通過。近期 ceremony 已驗證治理 Queue/Execute 多簽流程、mock-Liqwid Supply/Recall/Compound/Distribute 端對端、oracle E2E（含 stale-feed / disagreement / no-entry 拒絕路徑）、以及攻擊接收方鏈上重演防線。
- ✅ A2 治理閘控 stake deregister 工具(`deploy/tools/a2-{queue,execute,cancel}-deregister.ts`),帶冪等性 + CBOR-Constr payload 編碼。
- ✅ Mainnet ceremony runbook 已草擬(`deploy/runbooks/v1-mainnet-ceremony.md`,501 行):資金預算 + pre-flight + 逐階段 + 部分失敗處理 + 儀式後補登 + sunset 路徑。
- ✅ 鏈下 byte-for-byte decoder `deploy/tools/verify-minswap-v2-decode.ts` 把 Minswap V2 adapter 的 decode 邏輯暴露出來,讓 pre-mainnet 可以對歷史鏈上 TX 做 decode 驗證而不用重送一次。
- ⏳ Keeper 參考實作:放在 `optivaults-reference`(operator repo),尚未開始。
- ⏳ 內部審計輪次（涵蓋區 A-F，見 `docs/audit-scope.md`）:已完成多輪內部對抗性審計，以涵蓋區為組織單位；迄今所有非 INFO 級的發現都已在程式碼中修補並補上 regression test（`SECURITY.md` 帶有定性摘要）。第三方審計待進行。
- ⏳ 外部審計接洽:目標 Q2-Q3 2027,事務所尚未選定。

### Preprod deploy 狀態

V1 合約集已執行多次 Preprod ceremony，演練完整 deploy pipeline + 治理狀態機 + Liqwid 整合 + SwapAdapter dispatch + oracle E2E。每次 ceremony 的 per-validator hash 與鏈上 TX 證據都記錄在該 ceremony 的 state JSON（`deploy/state/<network>-<release-tag>.json`，operator-only，gitignored）。最近一次 ceremony 的 `mainnet-hash-preview.txt` 快照可透過 `deploy/tools/verify-mainnet-build.sh` 重新產出（該腳本現已包含對所有 `h-*.ts` operator tool 的 TIMELOCK_MS 預檢 audit gate）。

Stake-registration 押金（每次 14 × 2 ADA = 28 ADA）+ ref-script min-ADA 鎖定（每次約 962 ADA）在 sunset 時都可以透過 `deploy/tools/a2-{queue,execute}-deregister.ts` + `deploy/tools/reclaim-refs.ts` 回收，前提是走 A2 治理流程（14 天 production timelock）。

編譯後 validator 大小:全部 24 個 artefact 都在 16 KB Plutus V3 上限以下。任何 commit 的精確 per-validator bytes 可透過 `cd contracts && aiken build` 後對 `plutus.json` 計算重現；我們刻意不在本文件 pin 特定大小，避免隨審計輪次修補使合約面演進而與 source of truth 脫節。

開發 / 審計 / 上線時程見 [docs/audit-scope.md](docs/audit-scope.md)。

---

## 授權

OptiVaults V1 以 **Apache License 2.0** 釋出。本 repo(`optivaults-protocol`)涵蓋協議層:智能合約、部署流程、CLI 工具、以及文件。Operator 層(keeper 參考實作、API server、frontend、preprod E2E 腳本)放在姊妹 repo [`optivaults-reference`](../optivaults-reference),同樣以 Apache 2.0 授權。任何團隊都可以在 Apache 2.0 條款範圍內 fork、特化或把 V1 架構整合進衍生產品(見 [LICENSE](../LICENSE))。

選這麼寬鬆的授權是刻意的:V1 的成功指標明確包含「架構被其他 Cardano 團隊 fork + 特化」這一條(見白皮書 §1「我們為什麼要做這件事」)。在 pre-audit 的驗證期做重用限制,會跟這個貢獻導向的姿態互相矛盾。

---

## 聯絡方式

- 網站:[optivaults.app](https://optivaults.app)
- 協議 repo(本 repo):[github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)(分支 `v1`)
- Operator 參考 repo:[../optivaults-reference](../optivaults-reference)(分支 `v1`)
- 安全通報(協議層):optivaults@gmail.com,見 `SECURITY.md`
- 安全通報(operator 層):見 [`optivaults-reference/SECURITY.md`](../optivaults-reference/SECURITY.md)
