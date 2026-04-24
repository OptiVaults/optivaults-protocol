# OptiVaults V1

![License](https://img.shields.io/badge/license-Apache%202.0-blue)
![Aiken](https://img.shields.io/badge/aiken-v1.1.x-red)
![Tests](https://img.shields.io/badge/tests-144%20passing-brightgreen)
![Checks](https://img.shields.io/badge/randomized%20checks-639-brightgreen)
![Audit Status](https://img.shields.io/badge/audit-RFP%20in%20progress-yellow)
![Mainnet](https://img.shields.io/badge/mainnet-pre--launch-orange)

> **開發分支：`v1`。** 本 repo 沒有 `main` 分支——V1 是第一個公開釋出版本,我們以版本號作為分支名。未來主要版本(V2、V3⋯)會走各自的平行分支。

**OptiVaults V1 是 Cardano DeFi 公共財參考實作 (reference implementation)——一個非託管、鏈上自動複利的穩定幣金庫,以 Apache 2.0 授權釋出,作為 Cardano DeFi 公共財的一份貢獻。V1 沒有針對商業規模做最佳化。** 存入者應有的預期、資金來源策略、以及法規姿態,請見白皮書 Executive Summary + §12 免責聲明。

本資料夾收錄 V1 的設計、規格、實作與遷移文件。這裡所有內容都是以 V1 本身為主體來寫——不是前代版本的延續或修補。

---

## 兩層架構

OptiVaults V1 **刻意被拆成兩個 repo**,反映兩個**根本不同**的東西:

- **`optivaults-protocol`**(本 repo)——**協議層**。Aiken validators、協議規格、白皮書、部署流程。**本層零費用**;任何團隊都可以 fork 並啟動自己的 vault,完全不用付錢。**純 Cardano DeFi commons 貢獻**。
- **[`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference)**——**operator 參考實作**。TypeScript keeper、API server、frontend、CLI 工具。跑 `optivaults.app` 的 live vault 實例。由合約強制的 4.5% 績效費支撐(20% keeper / 80% treasury;**無創辦人 dividend、無投資人 return、無 token**)。Apache 2.0——歡迎 fork。

**4.5% fee 只發生在 operator 層**。**協議本身免費**——你跑自己實例就不需要付。完整費用拆分見 `docs/economics-zh-TW.md`;跨兩層的信任模型見 `docs/security-model-zh-TW.md §2`。

---

## 版本定義

- **V1**——第一個公開上線版本。以獨立產品的方式設計、規格化與審計。公開存入者的入口版本。
- **Prior versions (內部驗證期)**——內部驗證期。在 100K USDCx 上限的 pre-audit 框架下,於 Cardano mainnet 跑過一連串架構迭代,用來在真實市場條件下驗證合約不變量。internal-verification phase 是內部驗證的最後一版;V1 mainnet 上線時,該期將正式停運(sunset)。

V1 不是「internal-verification 加 patch」——它是獨立釋出版本,有自己的架構、自己的審計歷程(V1 pre-launch 內部輪次 + Q2-Q3 2027 第三方審計),以及自己的公開上線標準。

---

## V1 核心特性(摘要)

OptiVaults V1 由以下架構決策構成。每一項在本資料夾的對應文件中各自詳述。

1. **非託管鏈上金庫**——使用者資金全程由 Aiken PlutusV3 智能合約管控,沒有任何 operator 密鑰能提走本金。
2. **以 USDCx 作為存入資產**——Circle 透過 xReserve 跨鏈儲備機制在 Cardano 發行的美元錨定原生穩定幣。金庫將存入的 USDCx 路由至 Liqwid Finance 的穩定幣市場(DJED、USDM)以及 Minswap V2 的 DEX 路徑,以取得分散後的收益。
3. **m-of-n MultisigGov 治理**——所有協議政策變更(策略、費率、緊急凍結)都必須通過多簽 + 7 天 timelock + 1-of-n 取消否決。
4. **鏈上金庫儲備**——績效費收入的 80% 流進由治理管理的 treasury 合約,並由合約強制劃分至四個用途(audit reserve / operations / R&D / operational buffer)。
5. **以 stake validator 做 keeper 授權**——keeper 的操作透過一個帶 mode flag 的 stake validator 驗證,讓授權規則可以演進(治理核可清單 → 帶保證金的 permissionless),不需要重部署主 vault 合約。
6. **keeper 費率分成 20%**——執行該筆 Compound 的 keeper 拿 20% 績效費作為營運補償;其餘 80% 進 treasury。
7. **使用者自訂 batch tip**——Order UTxO 帶有使用者自訂的 tip 上限;keeper 在處理 batched order 時只能在此上限內收取。
8. **Withdraw-Zero forwarding pattern**——單一 vault UTxO 透過 `vault_proxy` 委派給 10 個 staking validator(`vault_user`、`vault_keeper_hot`、`vault_batcher`、`vault_swap_ada`、`vault_protocol`、`vault_recall`、`vault_liqwid`、`vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`),以滿足大小限制並做乾淨的角色分離。切分理由(四條正交軸線:授權邊界、治理反應延遲、bytecode 成本集中點、size 修正)整理於 `spec/architecture.md §4.1`。每個 stake credential(10 個 Withdraw-Zero 委派的 validator + `keeper_stake_script` + `minswap_v2_adapter` SwapAdapter,共 12 個)都各自帶有自己的 A2 `publish` handler,所以這 12 份 stake-registration 押金都可以在 sunset 時透過治理回收。
9. **編譯時信任錨點**——Vault Identity NFT、governance NFT policy、treasury script、keeper stake script 都在部署時燒進 validator script hash,而不是放在 datum 欄位。
10. **Pre-audit TVL 上限**——Operator 自律執行的 100K USDCx 上限,一直到 Q2-Q3 2027 第三方審計完成為止;post-audit 的上限調整計畫會與審計報告一併公開。
11. **公共財定位**——V1 被定位為**非商業**的公共財參考實作。4.5% 績效費用於覆蓋營運 + audit reserve + 長期 runway,不是創辦人或投資人的收益。Apache 2.0 授權讓 fork 與特化變得可行(不同穩定幣組合、不同風險姿態、區域變體)。V1 可能就是最終狀態,也可能是其他 Cardano DeFi 團隊改造的基礎——這兩個結局都是可接受的。存入者進場時應有的心態是「**貢獻公共財 + 擔任早期驗證者**」,不是購買商業服務。完整含意見白皮書 §12 免責聲明。

---

## 目錄結構

```
.
├── README.md                   本檔案
├── spec/                       V1 協議規格
│   ├── architecture.md         高階架構(含 §4.1 切分歷史)
│   ├── vault-datum.md          VaultDatum 欄位、不變量、狀態轉移(28 欄位)
│   ├── treasury.md             Treasury 合約規格
│   ├── keeper-auth.md          Keeper stake-validator 規格
│   ├── order-batch.md          Order + BatchProcess + user-tip 規格
│   ├── governance.md           MultisigGov actions + timelock 規則(14 個 ActionKind)
│   ├── multisig-gov.md         MultisigGov 內部邏輯 + is_gov_authorized 跨 validator 斷言
│   ├── gov-nft.md              治理簽名者 soul-bound NFT
│   ├── ada-swap.md             SwapAda redeemer + dual-feed 預言機讀取器
│   ├── vault-nft.md            Vault Identity NFT one-shot mint 模式
│   └── swap-adapter.md         SwapAdapter 介面 + B@launch=1 上線後新增 DEX 流程
├── contracts/                  V1 Aiken PlutusV3 原始碼——17 個 logic validator + 4 個 NFT mint policy + 1 個 DEX adapter;104 個 unit + property test / 599 個隨機化 check;`aiken check` 全綠
├── keeper/                     V1 keeper 參考實作(尚未開始)
├── deploy/                     部署流程
│   ├── deploy.ts               單指令 ceremony 指揮(冪等 + 可續跑)
│   ├── compile.ts              離線 hash 推導(跨 22 個 artefact 做 applyParams)
│   ├── lib/                    blockfrostProvider + 設定載入 + 狀態檔 + datum 建構 + 階段助手
│   ├── config/                 preprod.json(實用) + mainnet.example.json(樣板) + preprod-mock.json
│   ├── state/                  Ceremony 狀態 checkpoint(gitignored——依 releaseTag 分 JSON)
│   ├── tools/                  Operator CLI
│   │   ├── deregister-stakes.ts        舊版(pre-A2)
│   │   ├── derive-gov-signers.ts       PKH 推導助手
│   │   ├── whoami-preprod.ts           錢包狀態快檢
│   │   ├── a2-queue-deregister.ts      A2 Queue(冪等——Phase 84 回移)
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
│   ├── product-overview.md     給使用者看的實務總覽(EN)——你存什麼、拿什麼、風險用一般用語寫
│   ├── product-overview-zh-TW.md  繁體中文產品總覽
│   ├── migration.md            internal-verification 停運 → V1 存入者過渡
│   ├── economics.md            費用結構、treasury 資金流、永續性數學
│   ├── security-model.md       信任邊界、威脅模型、已知殘餘風險
│   ├── audit-scope.md          Pre-audit 內部輪次計畫 + 外部審計範圍
│   ├── integration-playbook.md 新增 DEX 路徑 / Liqwid market 的 operator SOP
│   └── contributor-program.md  開源貢獻者回饋(Phase 2+ 啟用)
├── private/                    Operator-only(gitignored)——審計報告、狀態檔案保存、敏感設定
│   ├── audits/                 內部審計輪次報告(R72、R73、Minswap 靜態審視)
│   ├── state/                  Ceremony 狀態保存 + recovery-verification 筆記
│   └── preprod-deploy-config.json    實用的 Blockfrost keys + signer PKHs
├── tests/
│   ├── preprod-e2e-plan.md     規格層級的情境目錄(100+)
│   └── preprod/                可執行的 TS 腳本(16 個——Phase B + C + D 覆蓋;
│                                  Phase E/F/H/I/J 尚未動)
│       ├── 00-ceremony-health.ts
│       ├── 10-deposit-direct.ts
│       ├── 11-withdraw-direct-partial.ts
│       ├── 12-withdraw-full-drain.ts
│       ├── 13-queue-deposit-order.ts
│       ├── 14-batch-process-single.ts
│       ├── 15-batch-multi-order.ts
│       ├── 16-order-cancel.ts
│       ├── 17-order-expire.ts
│       ├── 18-withdraw-queue-batch.ts
│       ├── 20-compound-zero-yield.ts
│       ├── 30-merge-ada-donation.ts
│       ├── 31-merge-deposit-token.ts
│       ├── 32-merge-multi-secondary.ts
│       ├── 33-merge-reject-datum.ts              (NEGATIVE path)
│       ├── 34-merge-reject-garbage-token.ts      (NEGATIVE path)
│       ├── helpers.ts
│       └── EXECUTION-ORDER.md
└── whitepaper/
    ├── whitepaper.md           V1 公開白皮書(EN)
    └── whitepaper-zh-TW.md     V1 公開白皮書(繁體中文)
```

每份文件都是寫成 V1 的獨立參考——這個 tree 裡任何一份都不預設讀者讀過前代文件。

---

### 開發歷史說明

本 repo 在 2026-04-22 以 **`v1-postphase77d-preprod`** release tag 起頭。程式碼本身有更早的開發歷史(約 1,000+ commit,跨越多輪內部驗證期迭代),在 V1 切換時整批整合收攏。內部驗證期的細節整理在 `spec/architecture.md §4.1`(切分歷史)與 `docs/migration.md`(sunset 計畫)。

給審計合作方:V1 的審計基準是 `v1-postphase77d-preprod` tag。更早的開發歷史可依需要在非正式保密前提下提供。

---

## 狀態

V1 目前處於**實作早期**:

- ✅ 規格 / 文件 / 白皮書完成(`spec/` + `docs/` + `whitepaper/` 共 15 份 markdown)。
- ✅ 全部 17 個 Aiken logic validator + 4 個 NFT mint policy + 1 個 DEX adapter(`minswap_v2_adapter`,§B@launch=1 SwapAdapter)都已實作,`aiken check` 全綠(`contracts/`)。切分理由見 `spec/architecture.md` §4.1。`UpdateSlippagePolicy` + 2 個 VaultDatum 欄位(§5.4 Phase 2)以及 ref-script SwapAdapter dispatch + `minswap_v2_adapter` + Registry `swap_adapter_hashes`(§B@launch=1)全部上鏈。
- ✅ 單元 + property 測試套件——**144 個 test 全部通過,每次 `aiken check` 會跑 639 個 check**(8 個 property test × 最多 100 iter + 其他確定性案例,含 R72 + R73 + R74 regression 覆蓋;R74 在 `minswap_v2_adapter` 內加 24 個 inline test,另在 `tests/r74_test.ak` 加 10 個結構性 test)。
- ✅ Preprod E2E 測試計畫已草擬(`tests/preprod-e2e-plan.md`),涵蓋全部 vault validator + 4 個 NFT one-shot policy + 跨 validator 整合流程,共 100+ 個情境。
- ✅ Preprod E2E 測試腳本(`tests/preprod/*.ts`)——16 個腳本,覆蓋 ceremony health + Phase B(Deposit / Withdraw / Queue / Batch / Order Cancel+Expire / Queued-Withdraw)+ Phase C(zero-yield Compound)+ Phase D(MergeUtxo 捐贈路徑,含 2 條負測路徑)。Phase E(真實 Minswap V2)/ Phase F(mock Liqwid stack)/ Phase H(治理狀態機)尚未動。
- ✅ 兩次 Preprod ceremony 已執行完成——見下方「Preprod deploy 狀態」表。每次 38 筆 TX,所有階段鏈上驗證通過。
- ✅ A2 治理閘控 stake deregister 工具(`deploy/tools/a2-{queue,execute,cancel}-deregister.ts`),帶冪等性 + CBOR-Constr payload 編碼。
- ✅ Mainnet ceremony runbook 已草擬(`deploy/runbooks/v1-mainnet-ceremony.md`,501 行)——資金預算 + pre-flight + 逐階段 + 部分失敗處理 + 儀式後補登 + sunset 路徑。
- ✅ 鏈下 byte-for-byte decoder `deploy/tools/verify-minswap-v2-decode.ts` 把 Minswap V2 adapter 的 decode 邏輯暴露出來,讓 pre-mainnet 可以對歷史鏈上 TX 做 decode 驗證而不用重送一次。
- ⏳ Keeper 參考實作(`keeper/`)——尚未開始。
- ⏳ 內部審計輪次(涵蓋區 A-F,見 `docs/audit-scope.md`)——R72(post-Phase-77d,1 MEDIUM + 3 LOW 已修)、R73(`valid_allocs × MergeUtxo` 捐贈缺口,1 MEDIUM 已修)、以及 R74(pre-mainnet Minswap V2 decoder `lp_asset` 格式不相符,1 HIGH 已修——見 `SECURITY.md §「最近修補」`)已完成;A-F 區域逐一走讀尚未展開。
- ⏳ 外部審計接洽——目標 Q2-Q3 2027,事務所尚未選定。

### Preprod deploy 狀態

| Release tag | 日期 | Vault 地址 | Vault NFT policy | 備註 |
|-------------|------|-----------|------------------|------|
| `v1-preprod-p3` | 2026-04-23 | `addr_test1wz87t7qnkpk3cgy2057rsrnsz6px88ks23y3ktd46q0jzfg5zfddz` | `7a0eea53cfa90b949009729bd0eaa73e3cb9f2f8056cc235d57218c5` | 目前這一版。把 timelock 常數縮到 60 秒之後的 ceremony,方便加速 Preprod E2E 迭代。B1 Deposit + B2 Partial Withdraw + vault_user 的 A2 Queue 都已鏈上驗證通過。 |
| `v1-postphase77d-preprod` | 2026-04-22 | `addr_test1wqca8hpe87tcfx0r0q7ju3uxf2thpr4jjcyjg44cc8kpvngysgja2` | — | 縮 timelock 前的 ceremony。Phase 84 跑過的 E2E 範圍:B1-B9 + D1/D2/D4/D5/D6 + C1 + H1-H5 Queue/Cancel,全部鏈上驗證通過。 |

這兩次 ceremony 的 stake-registration 押金(每次 12 × 2 ADA = 24 ADA)+ ref-script min-ADA 鎖定(每次約 870 ADA)在 sunset 時都可以透過 `deploy/tools/a2-{queue,execute}-deregister.ts` + `deploy/tools/reclaim-refs.ts` 回收,前提是走 A2 治理流程(mainnet 14 天 timelock;Preprod 為了迭代速度暫時覆寫為 1 小時)。

編譯後 validator 大小(全部在 16 KB PlutusV3 上限以下,由大到小排序)。取自目前 `v1-preprod-p3` build;`timelock_*_ms` 常數目前為 Preprod 覆寫值 60 秒,共影響 11 個 action kind(所有治理路徑,除了 `timelock_emergency_ms=0`、`timelock_fast_update_markets_ms=1h`、`timelock_deregister_stake_ms=1h`)。進入任何 mainnet build 之前,production timelock(7-21 天)**必須**還原——見 `constants.ak` 檔頭註解與 `deploy/runbooks/v1-mainnet-ceremony.md §0`。

| Validator | 大小(bytes) | 剩餘空間 |
|-----------|-------------:|---------:|
| vault_liqwid | 13,392 | 2,992 B |
| vault_recall | 13,337 | 3,047 B |
| vault_admin_deploy | 13,157 | 3,227 B |
| vault_protocol | 13,130 | 3,254 B |
| vault_gov_policy | 12,584 | 3,800 B |
| vault_keeper_hot | 12,381 | 4,003 B |
| vault_swap_ada | 12,164 | 4,220 B |
| vault_user | 11,885 | 4,499 B |
| vault_batcher | 11,553 | 4,831 B |
| vault_gov_emergency | 10,861 | 5,523 B |
| treasury | 9,851 | 6,533 B |
| keeper_stake_script | 8,774 | 7,610 B |
| registry | 8,504 | 7,880 B |
| multisig_gov | 8,233 | 8,151 B |
| minswap_v2_adapter | 5,020 | 11,364 B |
| vault_proxy | 4,912 | 11,472 B |
| order | 3,788 | 12,596 B |
| vusdcx | 1,255 | 15,129 B |
| gov_signer_nft | 399 | 15,985 B |
| vault_nft | 337 | 16,047 B |
| governance_nft | 319 | 16,065 B |
| registry_auth_nft | 319 | 16,065 B |

最緊的是 `vault_liqwid`——剩 2,992 B(距上限 18.3%)。若改回 production timelock 重建,`multisig_gov` 會往上長 ~100-200 B(常數 const-inline 後編出來比較大),其他 validator 的 hash 不會變。

開發 / 審計 / 上線時程見 [docs/audit-scope.md](docs/audit-scope.md)。

---

## 授權

OptiVaults V1 以 **Apache License 2.0** 釋出。授權範圍涵蓋整個 repo——智能合約、keeper 參考實作、API server、frontend、CLI 工具、以及文件。任何團隊都可以在 Apache 2.0 條款範圍內 fork、特化或把 V1 架構整合進衍生產品(見 [LICENSE](../LICENSE))。

選這麼寬鬆的授權是刻意的:V1 的成功指標明確包含「架構被其他 Cardano 團隊 fork + 特化」這一條(見白皮書 §1「我們為什麼要做這件事」)。在 pre-audit 的驗證期做重用限制,會跟這個貢獻導向的姿態互相矛盾。

---

## 聯絡方式

- 網站:[optivaults.app](https://optivaults.app)
- 協議 repo(本 repo):[github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)(分支 `v1`)
- Operator 參考 repo:[github.com/OptiVaults/optivaults-reference](https://github.com/OptiVaults/optivaults-reference)(分支 `v1`)
- 安全通報(協議層):optivaults@gmail.com——見 `SECURITY.md`
- 安全通報(operator 層):見 [`optivaults-reference/SECURITY.md`](https://github.com/OptiVaults/optivaults-reference/blob/v1/SECURITY.md)
