# 鏈上對抗性重放：把「合約應該拒」變成「合約確實拒」

*OptiVaults V1 安全設計解說 — 第 2 篇 / 共 4 篇*

---

[第 1 篇](./01-three-layer-governance-safety-zh-TW.md)講三層治理安全為什麼能讓單一簽名者治理變成可接受的 fallback。整篇的論述依賴一件事：合約層的不變式真的會被 validator 執行。

這個前提聽起來理所當然——但對讀者而言，它需要證據。

V1 的單元測試與 property 測試會在 `aiken check` 跑過，這是必要的開發紀律。問題是這類測試**信任的是測試框架的觀察**：testbench 模擬一個 TX context，假設合約跑出來的結果可以代表 production ledger 的判斷。當合約程式碼改了一行、測試 fixture 也改了一行，紅燈瞬間變綠燈，沒有外部約束阻止「測試與被測物一起漂移」。

V1 補上的安全層是**鏈上對抗性重放**：手工構造攻擊 TX、送到 Preprod ceremony 部署的活合約上、把合約的拒絕（或更糟，意外的接受）紀錄成 TX hash 或 Ogmios evaluate trace。本篇講這套方法論——它做什麼、不做什麼、為什麼補在哪。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)，提到的 redeemer 與 validator 都可以對照閱讀。

---

## 為什麼單元測試不夠

幾個結構性差距：

**(a) Testbench 模擬的 TX context 不是 ledger 規則**。Aiken 的測試框架以一個簡化的 `ScriptContext` 給 validator 執行。它涵蓋 validator 內部邏輯，但不保證 ledger 對 TX 整體結構（CBOR 序列化、reference script 載入、collateral 規則、CIP-69 purpose dispatch）的接受度與測試 fixture 一致。一個 validator 在 testbench 拒掉的 TX，活合約有可能在更早的階段（例如 ledger 直接 reject CBOR 結構）就被擋下——這時測試覆蓋的不是真正的防禦點。

**(b) 測試共演化**。同一個 commit 改一條 validator 邏輯、同時改一條測試 expectation，CI 一樣綠燈。Git history 看起來像「合約強化了」，實際上「不變式」與「對不變式的觀察」一起搬家了。沒有外部錨點挑戰這個共演化。

**(c) 跨 validator 整合的盲點**。Withdraw-Zero Pattern 下，一筆 vault spend 同時跑 `vault_proxy` + 一個 staking validator + 可能多個 mint policy。各自的單元測試蓋自己的邏輯，但跨 validator 的耦合（例如 `vault_proxy.withdrawal_count == 1` 與 staking validator 的 redeemer dispatch 之間）只在 production-shaped TX 上才會曝露。

**(d) CIP-69 purpose 觀察盲點**。PlutusV3 的 validator 可能被以非預期的 purpose 觸發（例如把一個 UTXO 故意送到 staking validator 對應的 spending address）。單元測試通常只測該 validator 處理的 purpose 是否正確；不會自動測「其他 purpose 是不是真的被 `else(_) { fail }` 攔住」。

鏈上對抗性重放補上的就是這四個面向：它把測試從「我問框架合約會說什麼」變成「ledger 親自說合約說什麼」。

---

## 方法論

每一條對抗路線都遵循同一個三步驟：

```
[1] 構造攻擊 TX
    ├─ 從合約規格或 audit finding 起頭，找出一條「validator 應該拒絕」的攻擊向量
    ├─ 在 redteam-*.ts 腳本裡建一筆 TX，刻意違反該不變式
    └─ 使用真實的 Preprod ceremony 部署、真實的 vault state、真實的 ref scripts
       —— 不是模擬，是要直接送到 ledger 的 TX 結構

[2] 送上鏈
    ├─ 先走 Ogmios evaluate 看 script execution 是否拒絕（不消耗實際 TX）
    └─ 若 evaluate 通過，繼續走 submit；ledger 端的最終裁定才是權威

[3] 紀錄拒絕證跡
    ├─ 拒絕 → Ogmios 回傳結構化 script-error trace，紀錄哪個 validator
    │         在哪個 purpose 下、在哪一行 fail。對應 TX 與 trace 入庫。
    └─ 意外接受 → 立刻停下，這是真實的 contract bug，不是 false negative
```

關鍵屬性是：**鏈上的 reject trace 是被 ledger 簽證的事實，不是測試框架的觀察**。任何後續的稽核者拿著同一份 ceremony build + 同一個 redteam 腳本，可以獨立重現同一條 trace；如果合約被偷改，重現會失敗。這個獨立可重現性是它跟 unit test 的根本差別。

---

## V1 已驗證的防禦層分類

以下列舉的是「實際在 Preprod 上構造攻擊 TX 並觀察到 ledger 拒絕」的防禦層，不是「所有可能的攻擊都已測過」的量化承諾。外部審計仍然是主要安全訊號——鏈上重放只是補上一條端到端的佐證，與單元測試、property 測試互相驗證。

### 金庫主 UTXO spend（`vault_proxy.ak`）

每一筆消耗 vault state UTXO 的 TX 都會先觸發 proxy。已重放的拒絕條件：

- `withdrawal_count == 1` — 每筆主 spend 只能 dispatch 一個 staking validator；同一筆 TX 內塞兩個 staking withdrawal 會被拒。
- `no_foreign_vault_datum` — 拒絕非 proxy 腳本地址下、卻帶有 InlineDatum-shaped `VaultDatum` 的 UTXO 被當作 vault 用。
- `is_full_drain` 與 NFT-burn 對應 — 全額提領必須同時 burn vault NFT；少了 burn 會被拒。
- `vault_count ∈ [2, 5]` — NoDatum-secondary UTXO 數量上下限，超出範圍會被拒。
- `all_secondary_no_datum` — MergeUtxo 路徑下，所有 secondary UTXO 必須是 NoDatum；任何帶 datum 的 secondary 都會擋下整筆 TX。

### 用戶路徑（`vault_user.ak`）

純無許可路徑，不需要 keeper 授權。已重放：

- `Deposit` mint-equality（`vUSDCx mint == expected_shares`）— 多鑄 +1 會被拒。
- `Deposit` `min_deposit` 下限 — 低於合約閘門的存入會被拒。
- `Withdraw` burn-equality（`vUSDCx burn == -shares`）— 少 burn 一份都會被拒。
- `verify_receiver_output` 嚴格 pkh 等值檢查 — redeemer 內的 receiver 欄位必須對應實際 output 的收款人，無法把 USDCx 路由到別處。
- `verify_receiver_output` Script-credential 拒絕 — receiver 必須是 VKey 錢包，不可指向鎖死腳本地址。
- `CommunitySunset` 90 天時間門檻 — 提前 1 秒呼叫都會被拒。

### Keeper 路徑（`vault_keeper_hot.ak` + `vault_swap_ada.ak`）

對應「被入侵的 keeper 想用寬時間窗口或不合理金額擾亂金庫」威脅模型。已重放：

- 所有寫時間欄位的 redeemer 強制 validity-range width cap（`upper - now ≤ 1 hour`）— 聲稱 `upper = now + 10y` 的交易在 ledger 端就會被拒，不需要 validator 介入。
- `vault_swap_ada` amount-in-range 邊界（每筆 swap 10–50 ADA）— 超出範圍會被拒。
- `ada_below_threshold` 補充閘門 — vault 還有充足 ADA 時，SwapAda 不應該被啟動。

### 協議路由（`vault_protocol.ak`）

對應「被入侵的 keeper 想把 swap output 改路」威脅模型。已重放：

- `DeployToProtocol` 目的地白名單（`registry.protocol_hashes`）— output 路由到不在白名單的腳本會被拒。
- SwapAdapter 收款者綁定 — caller 層 + adapter 層共同確認 `expected_recipient_addr`，攻擊者無法在 SwapAdapter 內部把 USDCx swap 結果改送其他地址。
- Tier 2 peg-floor 對 adapter-committed `min_receive` 的下限 — `min_receive × 10_000 ≥ deploy_amount × min_swap_peg_bps`，擋下 `minReceive = 1` 這類極端滑點攻擊。
- `min_order_amount` 非存入代幣 swap-out 的金額下限。

### Mint policies（`vusdcx.ak`、`vault_nft.ak`）

- `vUSDCx` 單一 asset name 紀律 — 同 policy 下的多 asset mint 會被拒。
- `vault_nft` PlutusV3 UTXO-ref 一次性鑄造 — parameterized UTXO 必須出現在 `tx.inputs`；該 UTXO 被花掉後就無法再 mint，結構上保證只能鑄一次（[第 4 篇](./04-phantom-vault-and-compile-time-anchor-zh-TW.md)深入講）。

### Order 分支（`order.ak`）

對應「攻擊者想 cancel 別人的 order 或把 expire 退款改路」威脅模型：

- `signed_by_owner` 在 `CancelAction` 上的嚴格簽署者驗證 — fake-owner pkh + caller-sig 不通過。
- `valid_refund` 在 `ExpireOrder` 上的收款者綁定 — 退款必須給原 `ord.owner`，改成攻擊者地址會被拒。

### Multisig 治理（`multisig_gov.ak`）

- `valid_signer_set` rotation 下限（`n ≥ 3` 簽署者）— 試圖把 signer 集合縮成 1 或 2 人會被拒。
- `time_window_ok` `lower_bound ≥ executable_at_ms` — timelock 結束前一秒 Execute 都會被拒。
- `payload_hash` 綁定 — apply 側 payload 必須 hash 到 queue 紀錄值，無法在 timelock 期間悄悄替換 payload。`RotateSigners` + `UpdateFee` + `UpdateRegistry` + `TreasurySpend` 全部共用同一個模式。
- `is_gov_authorized` 跨 validator helper — 每個受治理 gating 的 validator 都重算 `expected_payload_hash`，不信任 queue 結構單方面的描述。

### 緊急 / 費用治理（`vault_gov_emergency.ak`、`vault_gov_policy.ak`）

對應第 1 篇 Layer 1 的論述：

- `validate_emergency_freeze_only`（`loss_amount == 0` 不變式）— `EmergencyWithdraw` 只能切換 `frozen` 旗標，絕不可減少 `total_deposited`。被竊治理金鑰**無法**把 vault 寫崩。
- `max_performance_fee_bps`（450 bps 上限）— 即使是經完整治理授權的 `UpdateFee` 也擋下高於 4.5% 的設定。
- 與 `multisig_gov` 共用的 payload-binding 對應層 — Treasury Spend / UpdateFee / RotateSigners 都走同一個 `is_gov_authorized` helper。

### CIP-69 purpose 隔離

PlutusV3 每個 validator 明確宣告處理的 purpose（例如 staking validator 只宣告 `withdraw` + `publish`）；其餘 purpose 一律由 `else(_) { fail "<validator>: unsupported purpose" }` 捕捉並 fail。

把 UTXO 故意送到 `payment_credential = <staking script hash>` 的位址上會被永久鎖死——因為對應腳本根本沒有 Spend handler。重放確認：這類「故意走錯 purpose」的 TX 在 evaluate 階段就被拒。

### 份額價格不變式（`total_deposited` / `total_shares`）

每一條會動到這兩個欄位的路徑都被嚴格約束：

- Deposit + Withdraw 走 `calculate_shares_to_mint` / `calculate_withdraw_amount` 的嚴格等式。
- Compound 只動 `total_deposited`（產生 yield → 份額單價上升，這是設計意圖）。
- BatchProcess 走 per-order 公平 share 計算。
- 其他不該動帳本欄位的 redeemer 一律強制 `total_deposited == old.total_deposited && total_shares == old.total_shares`，由 `verify_protocol_fields_preserved` / `verify_liqwid_invariants` / `verify_emergency_freeze_only` / `verify_datum_unchanged` 等 helper 把關。

這條不變式特別重要——它涵蓋整個份額代幣的經濟保證。原碼審查 + 鏈上重放共同確認：比例不變式不會在設計意圖之外被人為破壞。

---

## 一個刻意延後的對抗向量

由治理 `UpdateRegistry` 注入假的 Liqwid `action_addr_hash`，再讓 Supply 路由到假位址。對應的防禦是 `vault_liqwid.SupplyToLiqwid` 的 `qtoken_delta > 0` 不變式——假的 action validator 在每市場固定的 qToken policy 下根本 mint 不出真的 qToken，這條防禦由 Aiken 單元測試涵蓋。鏈上重放暫時不做：儀式步驟（queue UpdateRegistry → 等 timelock → 跑 Supply）的成本，相對於單元測試之外能多帶來的審計敘述價值偏低。

這個刻意延後的揭露反過來說明方法論的紀律：不是「所有 finding 都要鏈上重放」，而是「對成本效益合理的 finding 鏈上重放」。

---

## 鏈上重放**沒有**涵蓋什麼

誠實說清楚邊界很重要。下列情境不在鏈上重放範圍：

- **外部系統失敗**（Liqwid bad-debt、USDCx redemption 凍結、oracle staleness）— 這些屬於白皮書 §5.3 / §5.2 / §5.4 的風險面，不是合約層防禦。
- **需要模擬惡意營運者的 keeper 私鑰妥協情境** — 由原碼審查 + 白皮書 §5.4 keeper 風險討論承擔；鏈上重放無法模擬「攻擊者掌握 keeper 私鑰」這個假設前提，因為這已經是 ledger 看不見的條件。
- **只有特定 Preprod build 狀態才會出現的行為** — 例如金庫已全額配置到 Liqwid 時，部分 Withdraw 路徑必須先 Recall 才能執行；這屬於運維流程，不是安全防禦。

外部審計仍是主要的安全訊號。鏈上重放補的是「親手構造攻擊 TX → 鏈上拒絕」這條端到端證跡，與單元測試、property 測試、外部審計各自覆蓋不同層級。

---

## 回歸測試可以被獨立重現

這個方法論最重要的一個屬性：**所有 redteam 腳本都是開源版本的一部分**。它們放在 `v1/tests/preprod/` 底下，與專案以同樣的 Apache 2.0 條款一同發佈。

這意味著：

- 審計方可在新的 Preprod ceremony build 上重跑這些腳本，獨立重現拒絕 trace。
- Fork V1 的團隊可在自己的 deploy 上重現同一組對抗測試，確認 fork 後的合約仍保留同樣的防禦層。
- 任何懷疑者可在不需要任何協作的情況下，自行驗證 V1 的安全聲明。

這條「外部可重現」的屬性是 V1 安全模型的一個核心：信任不依賴創辦人或營運方的承諾，依賴的是 ledger 上可被任何人觀察的事實。

整套做法（構造攻擊 TX → 上鏈 → 把合約拒絕紀錄成 TX hash 或 eval trace）也是未來 V1.x 與 V2 審計輪次可以直接沿用的模板——它不是一次性的儀式，是審計流程裡可重用的工具層。

---

## 下一篇

第 3 篇處理另一個面向的對抗性思考：**V1 同時持有 USDCx + DJED + USDM——這算分散嗎？** 答案不是直觀的「是」。多穩定幣配置可以擋掉發行者特定失敗，但擋不掉 ADA 閃崩這類相關性壓力。第 3 篇拆解「雙發行者配置」與「真分散」之間的差距。

第 4 篇深入 phantom-vault 攻擊向量，補足 Architecture 系列 Article 4 對編譯期 NFT anchor 的處理。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
