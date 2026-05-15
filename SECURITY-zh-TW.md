# 安全政策 — OptiVaults V1

## 漏洞通報

若你在 OptiVaults V1 的智能合約、部署工具或參考實作中發現安全性漏洞,請私下通報。**不要開公開 issue。**

**Email:** `optivaults@gmail.com`
**PGP key:** `optivaults.app/security`(加密敏感的技術細節)

**通報內容請包含:**
- 漏洞描述
- 重現步驟(若還沒實作成 exploit,給理論攻擊流程也可以)
- 影響評估(嚴重性 + 受影響的 validator / redeemer)
- 建議的修復方向(如果有想法)

**回應時程:**
- 私下確認收到:72 小時內
- 初步 triage:7 天內
- Fix + patch 公告:視嚴重性而定;CRITICAL / HIGH 目標 30 天內完成修補,並立即公開 operator 端的暫時緩解措施

---

## 範圍

**本 repo 的安全範圍是協議層**——Aiken validators、部署流程、協議規格 artefact。鏈下 operator 程式(keeper runtime、API server、frontend、CLI 工具)另有獨立 repo [`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference),有自己的 [`SECURITY.md`](https://github.com/OptiVaults/optivaults-reference/blob/v1/SECURITY.md)。

**不確定時,預設走本 repo 的通報管道**——若是 operator 層發現,分流時會轉派到 `optivaults-reference`。

### 在範圍內

- **Aiken 智能合約**(`contracts/validators/` 底下):
  - `vault_proxy.ak`——Withdraw-Zero forwarding + phantom-vault 防禦
  - `vault_user.ak`——Deposit / Withdraw / full-drain
  - `vault_keeper_hot.ak`——Compound / RebalanceBuffer / SwapAda(gov-share binding)
  - `vault_batcher.ak`——BatchProcess(payout 唯一性 + no-vUSDCx-leak)
  - `vault_swap_ada.ak`——SwapAda 雙源預言機讀取
  - `vault_protocol.ak`——DeployToProtocol(adapter 分派的 peg-floor + Tier 1 oracle)
  - `vault_recall.ak`——RecallFromProtocol / MergeUtxo(secondary 允許清單)
  - `vault_liqwid.ak`——SupplyToLiqwid / RecallFromLiqwid(gov-path 孤兒 qToken 防護)
  - `vault_gov_policy.ak`——UpdateStrategy / UpdateFee / UpdateFeeSplit / UpdateSlippagePolicy
  - `vault_gov_emergency.ak`——EmergencyWithdraw(loss write-off + 凍結)
  - `vault_admin_deploy.ak`——AdminDeployNonDeposit(keeper 失聯 7 天的 fallback)
  - `multisig_gov.ak`——m-of-n 治理狀態機 + ExecuteAction + RotateSigners
  - `treasury.ak`——4-bucket 預算 + 24 小時 cooldown + audit-reserve 下限
  - `keeper_stake_script.ak`——keeper 授權(啟動時為 GovernanceOnly)
  - `registry.ak`——協議白名單 + stable_tokens + liqwid_markets + asset_oracles + swap_adapter_hashes
  - `order.ak`——Order UTxO + Cancel + Expire + BatchProcess 內的 Process
  - `vusdcx.ak`——vUSDCx 份額 minting policy + 10^18 超鑄上限
  - `minswap_v2_adapter.ak`——SwapAdapter(§B@launch=1)
  - `sundaeswap_adapter.ak`——SundaeSwap V3 + Stableswaps 的 SwapAdapter(部署 SundaeSwap adapter pair 時納入範圍——opt-in,見 `spec/swap-adapter.md`)
  - `sundaeswap_cancel_guard.ak`——SundaeSwap order 的 drain-proof cancel 授權(與 `sundaeswap_adapter` 一同部署)

- **NFT mint policy**:
  - `vault_nft.ak`——one-shot Vault Identity NFT(proxy / vusdcx / order 的編譯時錨點)
  - `governance_nft.ak`——one-shot 治理 NFT(`is_gov_authorized` 的錨點)
  - `gov_signer_nft.ak`——soul-bound 簽名者肯定 NFT
  - `registry_auth_nft.ak`——one-shot Registry Auth NFT

- **共用的驗證與 helper 函式庫**:
  - `contracts/lib/vault/constants.ak`
  - `contracts/lib/vault/types.ak`——VaultDatum(29 欄位)/ GovDatum / RegistryDatum / TreasuryDatum / OrderDatum 等
  - `contracts/lib/vault/validation.ak`——逐 redeemer 的 datum 轉移斷言
  - `contracts/lib/vault/helpers.ak`——`is_gov_authorized` / `find_vault_utxo` / token 保留 / payload hash
  - `contracts/lib/vault/oracle.ak`——雙源 oracle 讀取器(§5.4 P3)
  - `contracts/lib/vault/swap_adapter.ak`——SwapAdapter dispatch + Tier 2 peg-floor(§5.4 P4)

- **部署流程**(`deploy/`):任何鏈下失敗,如果可能導致 operator key 外洩、ceremony 狀態錯置、或產出錯誤的鏈上身份錨點,都在範圍內。

### 不在範圍內(對 V1 而言)

- **Keeper 參考實作**——尚未開始(`keeper/` 還是空的)。實作落地後才開始接受發現。
- **API server**——V1 source tree 不附帶公開 API。外部整合商自己蓋 API 的,走他們自己的安全姿態。
- **Frontend**——V1 開源釋出聚焦在合約層 + 部署工具。Frontend 的安全姿態(CIP-30 錢包整合、JWT 處理等)屬於 operator 自己的部署範圍,不在 V1 scope。
- **測試檔案**(`*_test.ak`、`*.test.ts`)——故意寫成對抗性案例;那裡 fail 是設計目的。
- **對治理簽名者、operator、存入者的社交工程攻擊。**
- **第三方基礎設施**——Cardano node / Blockfrost / Ogmios / Kupo / Liqwid Finance / Minswap V2 / Circle xReserve,各自有自己的揭露流程。

---

## 安全模型

### 鏈上保證(合約強制)

以下三條保證在已部署的 V1 Aiken validator 中**無條件成立**,與 operator 的任何行動無關:

1. **沒有 admin-drain redeemer。** 沒有任何 redeemer 會把金庫本金送到非存入者的地址。緊急路徑一律走 `vault_gov_emergency.EmergencyWithdraw`,需要治理多簽 + 公開揭露。
2. **4.5% 績效費上限不可變。** `constants.ak` 中的 `max_performance_fee_bps = 450` 在編譯時由共用的 `validate_update_fee` helper 錨定,於 `vault_gov_policy.UpdateFee` 呼叫。治理**可以**在 `[0, 450]` 內調整 `performance_fee_bps`,但**不能**在任何情況下突破上限。
3. **keeper 失聯 7 天的免除機制。** 當 `now > last_compound_time + 7 days`,`vault_user.Withdraw` 會依 `keeper_inactive_ms` 檢查自動免除 `early_withdraw_fee_bps`。如果 keeper 永久停擺,存入者可以不扣 early fee 退場。

其他鏈上強制的不變量(不完整——詳見 `docs/audit-scope.md §1`):

- **非存入代幣的保留。** `verify_other_tokens_preserved` 模式套用在 7+ 個 redeemer 上,防止 token 被靜默注入或抽走。
- **Allocation invariant。** 金庫操作集上強制兩個版本——較嚴的 `alloc_sum + idle_buffer ≤ total_deposited`,透過共用的 `validate_allocations` helper 強制(用於 `Compound` / `DeployToProtocol` / `RecallFromProtocol` / `UpdateStrategy` / `AdminDeployNonDeposit` / `vault_liqwid` ops);較寬鬆的 `alloc_sum + idle_buffer ≤ total_deposited + non_deposit_value + Σ liqwid_principal`,以 inline 方式檢查於 `vault_gov_emergency.EmergencyWithdraw`。`vault_recall.MergeUtxo` 在捐贈導致狀態變更的源頭以 `valid_merge_utxo_admissibility` 守住較寬鬆那條(R73 F-1 修補)——MergeUtxo 的 post-state 只要通過較寬鬆,下游較嚴版本也自動通過,因為 NDV 與 Σ liqwid_principal 均為非負。
- **首位存入者保護。** `initial_share_multiplier = 10^6` + `valid_deposited > 0` 防止 ERC-4626 式通膨攻擊。
- **最低存款門檻。** Direct Deposit 最低 10 USDCx(Queued Order 走 dust-safe 批次路徑;BatchProcess 強制份額鑄造量必須非零)。
- **防雙重兌現。** `vault_user.Withdraw` 強制 `receiver_output_idx` 綁定。BatchProcess 強制多個 order 的 `payout_output_index` 互不重複。
- **無 vUSDCx 外漏。** BatchProcess 拒絕任何將 vUSDCx 鑄到 `(order_owner ∪ proxy_hash)` 以外地址的 TX。
- **延後收益(deferred-yield)的 Withdraw。** `withdraw_amount = base_withdraw − early_fee`;early fee 物理上留在金庫 → share price 上升 `(early_fee / total_shares)` → 其餘存入者受益。先前在此路徑上的一處會計漂移已關閉。
- **Vault NFT 的編譯時錨點。** `vault_proxy` / `vusdcx` / `order` 都在部署時以 `vault_nft_policy` 作參數化,而非透過 datum——藉此關閉 phantom-vUSDCx 自我引用 datum 攻擊。
- **15 個不可變 VaultDatum 欄位。** `governance_policy` / `governance_name` / `keeper_pkh` / `fee_collector` / `vault_version` / `performance_fee_bps` / `early_withdraw_fee_bps` / `min_hold_seconds` / `buffer_target_bps` / `vusdcx_policy` / `deposit_token_policy` / `deposit_token_name` / `order_script_hash` / `registry_hash` / `registry_auth_policy`。第 16 個錨點(`vault_nft_policy`)更強——是編譯時錨點,不是 datum 欄位。注意:`performance_fee_bps` 的「不可變」指的是**欄位結構位置**固定;值會透過治理 `UpdateFee` 在 `[0, 450]` 範圍內調整。完整欄位語意見 `contracts/docs/vault-state-machine.md`(或 V1 的 `spec/vault-datum.md`)。
- **治理 cancel 否決。** 每筆 `QueueAction` 都有 1-of-n `CancelAction` 否決窗口;執行需要**同時**滿足 m-of-n 簽名**與**在 timelock 期間沒被取消。
- **Validity-range 寬度上限。** 所有會寫時間的 redeemer(Compound / UpdateFee / RotateSigners / UpdateStrategy / SwapAda / RebalanceBuffer)都強制 `upper - now ≤ 1 小時`,限縮時間戳操弄面。
- **治理簽名者下限。** `valid_signer_set` 要求 `signers ≥ 3, threshold ≥ 2, threshold ≤ n, 唯一`(縱深防禦)。
- **治理 empty-hash 委派。** 這是已文件化的設計權衡——詳見下方§「已知設計決策」。

### 依賴鏈下條件的保證

以下給存入者的承諾,會依賴外部基礎設施繼續可用:

- **Withdraw 以 1:1 USDCx 結算。** 需要 Cardano 鏈活著 + 存入者錢包有 ADA 付 TX fee + Liqwid 可用(若 vault 有 Liqwid 部位)+ USDCx 有流動性。
- **Share price 準確追蹤底層收益。** 需要 keeper 定期執行 Compound。如果 keeper 停擺超過 7 天,合約層的 7 日免除機制能讓存入者不被收 early fee 退場,但在下一次 Compound 前,share price 會暫時無法反映停擺期間 Liqwid 累積的新利息。
- **緊急自助退場。** 需要 Cardano 鏈 + USDCx 流動性。`emergency-withdraw` 自助工具打包在開源 source tree 裡;任何存入者都能在不需要 operator 配合的情況下跑它。

---

## 測試覆蓋

| 類別 | 覆蓋面 | 狀態 |
|-----|--------|------|
| Aiken 單元測試 | 全部 22 個 artefact 的確定性案例 + 跨 validator 整合流程；含 `minswap_v2_adapter` 內的 inline test。實際數可在部署 commit 跑 `cd contracts && aiken check` 取得。 | 全過 |
| Aiken property-based fuzz（`aiken/fuzz` v2.2.0） | `lib/vault/tests/property_test.ak` 內 property test，使用 iteration cap 紀律（預設每 property 100 iter，首次失敗 early-exit）。實際 property 數可在 `aiken check` 取得。 | 全過 |
| Preprod E2E 腳本（`tests/preprod/`） | 多階段覆蓋：ceremony health、用戶流程（Deposit / Withdraw / Queue / Batch / Order Cancel+Expire / Queued-Withdraw）、zero-yield Compound、MergeUtxo 捐贈路徑（含負測路徑）、治理狀態機（Queue / Execute / Cancel）、oracle E2E（Tier 1 + Tier 2 + stale / disagreement / no-entry 拒絕）、SwapAdapter dispatch（R77 F-1 攻擊接收方鏈上重演）、以及 mock-Liqwid Supply / Recall / Compound / Distribute 端對端。 | 全部已在對應 ceremony 鏈上驗證 |
| Keeper vitest | 參考 keeper 實作位於 operator repo，測試套件設於該 repo。 | — |
| API vitest | 不在 V1 scope（V1 只涵蓋協議層——見 `README.md` 雙層架構）。 | — |
| Frontend vitest | 不在 V1 scope（V1 只涵蓋協議層——見 `README.md` 雙層架構）。 | — |

Preprod ceremony 已跨多個 release tag 演練完整 deploy pipeline + 部署後操作流程。每次 ceremony 鏈上 TX 證據存於 `deploy/state/<network>-<release-tag>.json`（operator-only，gitignored）。近期 CRITICAL 修補已在 post-fix 全新 ceremony 重新驗證：R77 F-1 攻擊接收方鏈上重演防線（`SwapAdapterRedeemer.expected_recipient_addr` Layer-1 / Layer-2 強制檢查）。

---

## 審計狀態

### 方法論

V1 的內部審計採**涵蓋區方法論**(A–F 區,見 `docs/audit-scope.md §4`),取代先前 prototype 版本使用的逐輪編號制。涵蓋區對應到 validator 群組 + 跨 validator 整合流程,而不是綁在某個時間順序的審計輪次。

### 內部審計輪次歷史

針對 V1 合約程式碼執行過的內部對抗性審計輪次(更早的輪次涵蓋 V1 切換前的 prototype 階段——見 `spec/architecture.md §4.1`):

| 輪次 | 範圍 | 嚴重性分佈 | 狀態 |
|------|------|----------:|------|
| R72 | Phase-77d 後對完整 V1 集合(17 logic + 4 NFT + 1 adapter)的 hacker-mindset 審視 | 0 CRIT / 0 HIGH / 1 MEDIUM / 3 LOW / 6 INFO | MEDIUM + 3 LOW 已鏈上修補;INFO 已文件化 |
| R73 | `valid_allocs × vault_recall.MergeUtxo` admissibility 缺口 | 0 CRIT / 0 HIGH / 1 MEDIUM | **已修補**——透過 `lib/vault/validation.ak` 的 `valid_merge_utxo_admissibility` + `vault_recall.MergeUtxo` 呼叫;6 個 regression test 在 `lib/vault/tests/r73_test.ak` |
| R74 | Phase O pre-mainnet Minswap V2 decoder 對真實 mainnet order 做 byte-for-byte 驗證 | 0 CRIT / 1 HIGH / 0 MEDIUM | **已修補**(本次 commit)——見下方「最近修補」中的 R74 F-1 條目 |

### 涵蓋區狀態(待外部審計)

| 區域 | 範圍 | 狀態 |
|------|------|------|
| A | Keeper 授權 + stake-script 狀態機 | 尚未開始 |
| B | Treasury + 4-bucket 預算流 | 尚未開始 |
| C | 治理狀態機 + m-of-n + timelocks | 尚未開始 |
| D | Compound / 費用拆分 / keeper-gov-treasury 三向流 | 尚未開始 |
| E | SwapAdapter dispatch + 多 DEX 生命週期 | 尚未開始 |
| F | 跨 validator 整合 + full-drain + sunset 路徑 | 尚未開始 |

### 外部審計

- **目標**:Q2-Q3 2027。
- **候選事務所**(截至 2025-2026 具備 Plutus V3 + Aiken 經驗的窄名單):Anastasia Labs / MLabs / Certik-Cardano / TxPipe + 獨立 Aiken reviewer。最終選定與範圍會在合作啟動前至少 2 週公開公告。
- **合作啟動前的姿態**:operator 自律的 100K USDCx TVL 上限(見白皮書 §8.2)。

---

## 已知開放中的審計發現

_目前沒有任何 LOW 以上嚴重性的開放審計發現。最近關閉的項目見下方「最近修補」。_

---

## 最近修補

### R74 F-1 — `minswap_v2_adapter` `lp_asset` decoder 格式不相符(HIGH,已修補)

**發現過程。** Phase O pre-mainnet Minswap V2 decoder byte-for-byte 驗證,對一筆真實 mainnet 3-hop SwapMultiRouting order 做驗證時,抓到 adapter 在 decode 階段就拒絕了該 order。

**根因。** `minswap_v2_adapter.ak::extract_target_from_lp` 把 Minswap V2 order datum 的 `lp_asset` 欄位當成「兩個資產的 pair」來解——預期是 4-field 扁平格式 `[policy_a, name_a, policy_b, name_b]`,或 2-field 巢狀格式 `[Asset_a, Asset_b]`。實際上 Minswap V2 的 `lp_asset` 是**單一 LP-token 識別碼** `Constr(0, [LP_policy_28B, LP_name_32B])`(pool 的 LP-token 本身,不是底層 pair)。Aiken decoder 走到 nested-Constr 分支、對 LP-name 這個 ByteArray 呼叫 `un_constr_data` → 在 UPLC 中 trap → 每一筆真實 Minswap V2 order 都會被鏈上拒絕。

**嚴重性說明。** Adapter 在 ship 出來的那一版在 mainnet 上實質不可用,因此沒有直接的攻擊可以成立。但這**類**的 bug——adapter 接受 DEX datum 卻不獨立驗證 swap 的輸出資產——屬於 HIGH 嚴重性:在理論上,被入侵的 keeper 有機會把金庫穩定幣路由到任意未白名單的 pool,讓 vault 收到毫無價值的代幣、但會計上偽裝成所承諾的目標資產。分級為 HIGH,作為 pre-mainnet blocker 處理。

**修補**(本次 commit):`SwapAdapterRedeemer` 把 `target_asset_policy` + `target_asset_name` 替換為 `hop_chain: List<(ByteArray, ByteArray)>`——SwapExactIn 用 2 項(`[asset_in, target_out]`),N-hop SwapMultiRouting 用 N+1 項。`minswap_v2_adapter.ak::compute_lp_asset_name` 實作 Minswap 的 canonical LP-name 公式(`sha3_256(sha3_256(policy_a || name_a) || sha3_256(policy_b || name_b))`,輸入按 policy-先-name-後的順序做 canonical sort)。`verify_routing_chain` 逐對比對每個鏈上 routing hop 與相鄰的 `hop_chain` 項目,若鏈上 LP name 重新雜湊後對不上承諾的 pair 就拒絕。`last_hop_target` 暴露 chain 的最末項供下游 Tier 2 peg-floor + 選用的 Tier 1 oracle 查詢。

27 個新增 test 覆蓋 LP 公式(含 Minswap 自家 test vector 與三組真實 mainnet LP)、chain 驗證的正負路徑、以及結構規則(空 chain / 單項 chain / 相鄰重複的情況全部拒絕)。`swap_test.ak` 也已更新到新的 redeemer 形狀。

**Hash 漂移。** `minswap_v2_adapter`、`vault_protocol`、`vault_gov_emergency`、`vault_admin_deploy`,以及參數化後的 `vault_proxy` 形式全部會變。任何鏈下 TX builder 要送出 adapter redeemer 時,必須填 `hop_chain`。

標記為 Q2-Q3 2027 外部審計驗證時覆查。

### R73 F-1 — `vault_recall.MergeUtxo` admissibility 缺口(MEDIUM,已修補)

**根因。** `vault_recall.MergeUtxo` 接受 deposit token(USDCx)捐贈、把 `idle_buffer` 加上來,但沒有同步抬升 `total_deposited` / `non_deposit_value` / `liqwid_principal`。下游有七個 redeemer(`vault_keeper_hot.Compound`、`vault_protocol.DeployToProtocol`、`vault_recall.RecallFromProtocol`、`vault_liqwid` Supply/Recall、`vault_gov_policy.UpdateStrategy`、`vault_admin_deploy.AdminDeployNonDeposit`、`vault_gov_emergency.EmergencyWithdraw`)會檢查 `alloc_sum + idle_buffer ≤ RHS`,其中 RHS 為兩種其中之一(較嚴的 `total_deposited`、或較寬鬆的 `total_deposited + non_deposit_value + Σ liqwid_principal`)。若捐贈把 `idle_buffer` 推過 RHS,這七個路徑會全部 brick,一直到 Compound 收益把差距補回來——在 Phase 1 TVL 下,相當於攻擊者以每天 sub-dollar 級別的成本,對 keeper + 治理路徑做持續 DoS。

**不是盜取本金**——捐進來的 USDCx 會在後續 Withdraw 活動中按比例分配給既有存入者,捐贈者什麼也拿不回來。這是對營運面 + 治理 liveness 的 DoS,不是本金損失。使用者的 `Withdraw` 路徑從來不受影響(該路徑沒有呼叫 `validate_allocations`)。

**修補**(本次 commit):`lib/vault/validation.ak` 內新增 `valid_merge_utxo_admissibility` 斷言,在狀態變更的源頭(`vault_recall.MergeUtxo`)強制「較寬鬆」那條不變量。守住「較寬鬆」就嚴格足夠——因為 NDV 與 Σ liqwid_principal 均為非負,任何 post-merge 狀態只要通過較寬鬆版本,下游的較嚴版本也自動通過。會打破不變量的捐贈在 MergeUtxo 時就被拒絕,金庫永遠不會進入壞狀態,攻擊因此被擋在源頭。

`lib/vault/tests/r73_test.ak` 六個 regression test 覆蓋:合法捐贈(通過)、超額捐贈(拒絕)、同時抬高 LHS 與 RHS 的穩定幣捐贈(通過)、等號邊界(通過)、Liqwid principal 納入 RHS(通過)、`alloc_sum` 抬高 LHS 並超額配置(拒絕)。

標記為 Q2-Q3 2027 外部審計驗證時覆查。

---

## 已知設計決策(已文件化,不屬於 finding)

### Emergency Freeze 期間仍允許 Withdraw

`vault_user.Withdraw` **不**檢查 `frozen == 0`。這是刻意的:不論金庫狀態如何,存入者的資金絕不鎖死。`frozen` flag 阻擋的是可能複合錯誤會計的操作(Compound / BatchProcess / RebalanceBuffer / DeployToProtocol / SupplyToLiqwid),但 Withdraw / RecallFromProtocol / RecallFromLiqwid / MergeUtxo 在凍結狀態下仍可用,以便回收資金。`idle_buffer ≥ base_withdraw` 的自然條件會防止超額提領。這點經多輪審計確認。

### 治理 empty-hash 委派

`multisig_gov.QueueAction` 允許 `target_tx_hash` 為空(`#""`),這讓 m-of-n 治理可以預先授權一個 `VaultAdmin` / `RegistryAdmin` capability,之後由任意 1-of-n 簽名者在該 action kind 的 timelock 過後執行(多數 action kind 最短 14 天;測試時 Preprod 覆寫為 60 秒)。

會有這個選項是因為 `target_tx_hash` 對治理 UTXO 存在無法避免的循環依賴(TX body 包含 queued 的 datum、datum 裡包含 target_tx_hash——對那些「執行 TX body 還沒建構出來」的 action 來說,queue 當下無法得知執行 TX 的 hash)。

**執行窗口期間仍保留的鏈上防禦**:`CancelAction`(1-of-n 否決)、`action_ttl_ms` 37 天絕對上限、`GovNFT == 1` 唯一性、target script 必須是 spent input、ADA 保留、全部 15 個不可變 VaultDatum 欄位。

**鏈下 operator 義務**:
- Empty-hash 的 `QueueAction` 必須在 1 小時內公開廣播。
- 至少 1 位誠實簽名者必須在整個 timelock + TTL 窗口監控治理佇列,一有異常用 `CancelAction` 否決。
- 簽名者集合必須至少包含 2 方非共謀、各自有獨立監控基礎設施的人。
- 只要執行 TX body 可以提前算出,就優先用明確的 `target_tx_hash`。

### BatchProcess 零份額邊界案例

當 `total_shares > 0 && total_deposited == 0` 時,BatchProcess 會正確地鑄 0 份額。這個狀態需要 100% 資金損失才會發生(vault 已失去全部價值),此時鑄 0 份額才是正確行為。正常運作下 `total_deposited > 0` 保證份額計算為正。

### Vault UTxO 中的垃圾 token 灰塵

透過 `MergeUtxo` 以 `non_deposit_increase = 0` 吸收進 vault UTxO 的空投 token,會被保留在 UTxO 中,但不能透過 `AdminDeployNonDeposit` 搬走(後者只處理白名單內的 `stable_tokens`)。這是可接受的:垃圾 token 是無害的灰塵。Full drain 會把整個 vault UTxO 摧毀、釋放所有 token。

---

## 責任揭露 + 酬庸式肯定

V1 啟動時**不**運行結構化的 bug bounty 計畫。
Bounty tier 表適合「post-external-audit、TVL 大到 audit-reserve 的累積足以支付市場競爭水準獎金」的協議階段。V1 的 Phase 1 規模($500–$25K TVL)無法在不訂出「低於市場行情」的 tier 的前提下支撐 bounty——那樣做會比乾脆沒有 tier 更糟:表面上看起來是承諾、實際數字卻只是象徵性的;會招來審計事務所「scale mismatch」的批評;也與 V1 的非商業公共財定位矛盾。

V1 改以標準的**責任揭露政策(RDP)+ 酬庸式(ex gratia)肯定**框架釋出。完整條款見 `docs/audit-scope.md §6`。摘要:

- **範圍**:與上方 §「在範圍內」相同(Aiken 合約 + 部署流程 + 22 個編譯 artefact)。鏈下 operator 層的發現(keeper / API / frontend)仍接受,並依上方 §Scope 註記 triage 轉送至 `optivaults-reference`。
- **揭露窗口**:triage 後 90 天(若修補需要與 Liqwid / Minswap V2 / Circle-xReserve 延伸協調,可再延 30 天)。
- **確認回應**:72 小時內;7 天內完成 triage + 初步修補計畫。
- **肯定方式(操作方裁量、酬庸式)**:在 V1 審計報告 + repo 公開致謝、合撰 finding + fix 的 case-study、對未來內部審計草稿 + pre-mainnet 測試部署有優先存取權、以及來自創辦人啟動資金的酬庸式感謝支付(明確**不是**市場行情 bounty——V1 Phase 1 treasury audit-reserve 的累積速率支撐不了;見 `docs/audit-scope.md §6.2`)。
- **對善意揭露不提告**。

結構化 bounty tier 計畫是 post-external-audit + post-TVL-scale 的考量(前提條件見 `docs/audit-scope.md §6.3`),不是 V1 啟動時的承諾。

---

## 聯絡方式

- **安全通報**:`optivaults@gmail.com`(PGP 在 `optivaults.app/security`)
- **一般 / 非敏感**:Discord(邀請在 `optivaults.app`)
- **商業 / 合作**:不主動招攬——V1 是公共財參考實作,不是商業服務

---

## 延伸閱讀

- `whitepaper/whitepaper.md` §5(風險)+ §6(信任與治理)+ §12(免責聲明)
- `docs/security-model.md`——信任邊界 + 威脅模型 + 已知殘餘風險
- `docs/audit-scope.md`——完整涵蓋區方法論 + 外部審計計畫
- `spec/governance.md`——MultisigGov action kind + timelock 規則
- `spec/swap-adapter.md`——SwapAdapter 威脅模型 + 上線後新增 DEX 生命週期
- `CONTRIBUTING.md`——貢獻與揭露流程
