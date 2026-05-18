# 三層治理安全：在單一簽名者治理下保住存入者的回收路徑

*OptiVaults V1 安全設計解說 — 第 1 篇 / 共 4 篇*

---

V1 啟動時最尷尬的現實是這個：理想中 mainnet ceremony 前會招募兩位獨立的 Cardano SPO 擔任治理簽名者，組成 3-of-3 全員同意的 multisig；但在 Phase 1 小 TVL 情境下（白皮書 §8.2 描述的 $500–$25K 區間），SPO 招募可能延後、可能維持為 standby 形式，創辦人實際上以單一簽名者方式運作治理。

「單一簽名者治理 + 容易出事的金鑰」聽起來像是存入者該躲開的 red flag。

V1 的回應**不是**承諾「不會出事」，而是把整套合約設計成「即使創辦人金鑰被竊、即使創辦人停付營運補貼、即使創辦人連續 90 天失能」存入者仍然有路徑拿回 USDCx。這條保證不靠承諾——它在 validator 程式碼裡，任何人可以拿已部署的 script hash 自己驗證。

本篇拆解這個保證怎麼成立：三層結構性保護，分別處理「被入侵的治理金鑰想造成損失」、「被入侵的 keeper 想擾亂回收」、以及「治理 + keeper 同時不見人」三個情境。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)，本篇引用的 validator 都可以對照閱讀。

---

## 為什麼需要三層

先講清楚要防的是什麼。

傳統 DeFi vault 在治理面通常只有兩種設計：(a) 完全沒有 emergency 路徑、有事只能等社群協調、或者 (b) 留一條 emergency 路徑給治理 multisig 用，授權內容很寬——包括直接動 datum、減 `total_deposited`、移除部位紀錄。

兩種都不適合 V1 的啟動姿態。(a) 太脆——Liqwid 出事時沒有任何凍結手段是真實風險。(b) 太寬——如果 emergency 路徑能直接動帳本欄位，那「治理金鑰失竊 = 攻擊者把 vault 寫成 0」就成立，存入者只剩聲譽證據可以申訴，鏈上沒救。

V1 把 emergency 路徑切成三層，每一層各自處理特定威脅，並且**每一層都不會給治理超過該威脅所需的權限**：

| Layer | 觸發者 | 能做什麼 | 不能做什麼 |
|-------|--------|---------|-----------|
| Layer 1 | 治理 multisig | 切換 `frozen` flag | 動 `total_deposited`、`liqwid_positions`、`idle_buffer` |
| Layer 2 | Keeper（freeze 下仍可呼叫） | 透過白名單 SwapAdapter 把非存入代幣 swap 回 USDCx | 把 output 路由到 vault 以外的地址 |
| Layer 3 | 任一 vUSDCx 持有者（permissionless） | 觸發後解鎖無許可的回收路徑 | 動 datum 上任何 immutable 欄位 |

三層加總起來的覆蓋面就是：**治理失能也好、keeper 失能也好、兩個同時失能也好，存入者一定還有可走的退場路徑。**

---

## Layer 1 — `EmergencyWithdraw` 改為 freeze-only

第一個威脅是「治理金鑰被竊，攻擊者試圖透過 emergency 路徑造成損失」。

很多 vault 設計把 emergency 路徑做成「multisig 簽過就能任意動 datum」。V1 不行。`vault_gov_emergency.EmergencyWithdraw` 的 validator 在編譯期就被限制為 freeze-only：

- **不能減少 `total_deposited`。** 任何把這個欄位寫小的 TX 在 validator 層直接被拒。
- **不能移除或修改 `liqwid_positions` 中的任何條目。** Liqwid 部位的 `supplied_value` 與 `qtokens_held` 只能由 `vault_liqwid.SupplyToLiqwid` / `RecallFromLiqwid` 寫——後者透過實體 Recall underlying USDCx 並只寫入真實實現的損失（`supplied_value − underlying_received`）。
- **不能接受非零 `loss_amount`。** 損失帳務不能由治理簽名片面決定。

它**唯一能做**的就是把 `frozen` flag 在 0 與 1 之間切換——配合 14 天 timelock + 1-of-n cancel，讓治理在偵測到 Liqwid 異常或穩定幣脫鉤訊號時凍結金庫，停止新的 Deploy 與部位變動，給社群時間規劃復原。

`EmergencyWithdraw` 的 timelock 設為 0 天（white-paper §6.2 詳述），是為了反應速度——當持續性脫鉤訊號需要立刻凍結時，治理可以在同一次簽名 session 內 queue + execute 完成。「0 天」指的是**最短等待時間為 0**，**不是**繞過共識：每一次仍需完整的 3-of-3 簽名（如果該階段 SPO 已就位）、仍受 1-of-n cancel 否決、仍受 payload-hash 綁定。

**這層保護的安全屬性**：被入侵的治理金鑰最多只能讓 vault 進入 frozen 狀態。它**不能**把 qToken 部位變成孤兒、不能假造損失把 share price 寫低、不能把存入者的本金記錄抹掉。所有可能造成 NAV 下降的動作都必須透過 `vault_liqwid` 的具體 token movement 路徑，由 ledger 上實際發生的 Recall / Swap 事件決定金額。Datum 不能被治理片面寫崩。

---

## Layer 2 — DeployToProtocol 在 freeze 下對 swap-out 仍開放

Layer 1 把破壞性路徑封死了，但留下一個新問題：**vault 凍結之後，金庫裡可能持有大量 DJED / USDM（剛從 Liqwid Recall 回來，但還沒 swap 成 USDCx）。如果 freeze 完全擋住 DeployToProtocol，這些非存入代幣就會卡在 vault 裡，存入者直接 Withdraw 拿到的是 DJED 而不是 USDCx，必須自行處理 swap。**

對小額存入者，這是糟糕的使用體驗——freeze 應該保護他們，不是把處理 DEX swap 的責任轉嫁過去。

Layer 2 用一個精確的例外處理這個問題：當 `frozen == 1` 且 redeemer 的 `deploy_token != deposit_token` 時，keeper 仍可透過 registry 白名單的 SwapAdapter（Minswap V2）執行 swap-out。

關鍵在於這個例外**只開 swap-out、不開其他操作**：

- **SwapAdapter validator 強制目的地必須是 vault 自己的地址。** 即便 keeper 金鑰同時被入侵，攻擊者也無法把 swap output 改路到他控制的錢包。最壞情況只能逼出 Tier 2 peg-floor 邊界內的 slippage（每筆 swap 的 `min_receive × 10_000 ≥ deploy_amount × min_swap_peg_bps`），且 swap 所得 USDCx 仍然落到 vault 給使用者提領。
- **新存入 / 部位擴張仍被 freeze 擋住。** Layer 2 不容許 USDCx → DJED 方向的 swap（因為 `deploy_token == deposit_token` 時走的是正常路徑，會被 freeze 擋下）。它只開反方向。
- **Registry whitelist 仍然強制執行。** SwapAdapter hash 必須在 `swap_adapter_hashes` 白名單裡，由治理 14 天 timelock 管理。被入侵的 keeper 無法新增任意 adapter。

沒有 Layer 2，freeze 一啟動非存入代幣的部分就會卡到 21 天後的 `AdminDeployNonDeposit` 治理 fallback 才能脫困。Layer 2 把這個 21 天窗口縮短為「keeper 仍在線就能立刻把非存入代幣 swap 回 USDCx，讓使用者 Direct Withdraw 拿到的是 USDCx」。

---

## Layer 3 — CommunitySunset 自動止血開關

前兩層都假設「keeper 或治理至少有一邊在運作」。如果兩邊都不見人呢？

Layer 3 處理這個最壞情況：當 vault 連續 90 天無操作（`max(last_compound_time, last_realloc_time) + 90d ≤ now`），任何 vUSDCx 持有者都可以呼叫 `vault_user.CommunitySunset` 這個 permissionless redeemer。觸發後：

- `community_sunset_triggered` flag 設為 1（單向不可逆）。
- `frozen` 設為 1（阻止新的 Deploy）。
- **`vault_liqwid.RecallFromLiqwid` 接受任何簽名者**（不再需要 keeper 或治理簽名）。
- **`vault_protocol.DeployToProtocol` Layer 2 swap-out 路徑也接受任何簽名者**。

任何 vUSDCx 持有者都能驅動完整的回收鏈：Recall → Swap → Withdraw，完全不需要 keeper 或治理介入。90 天門檻相當於漏跑大約 18 次 zero-yield heartbeat（每 5 天一次），等同於 keeper 完全死掉。

Sunset 路徑**只開回收，不能改 datum**。它無法動 `total_deposited`、`total_shares`、`idle_buffer`、`liqwid_positions` 或任何 immutable 欄位。Validator 的保留條款確保 sunset 期間 SwapAdapter 的目的地、peg-floor、slippage 限制仍然生效——攻擊者就算 sunset 過後也無法利用開放的回收路徑抽走價值。

### 為什麼用 `max(both)` 而不是只看 `last_compound_time`

Layer 3 觸發條件選 `max(last_compound_time, last_realloc_time)`，表面看起來給 keeper 一個「我只送 heartbeat 不做 productive Compound」就能無限延後 sunset 的空間。這個選擇是有意的，理由是要保住兩個合法的營運情境：

- **Reference Implementation Mode**（白皮書 §2.6.1）：低 TVL 期間只跑 heartbeat 是合法的營運模式。若只看 `last_compound_time`，會在這個模式下過早觸發 Layer 3。
- **遷移 / V2 部署情境**：治理可能在遷移窗口暫停 productive Compound、同時透過 `RebalanceBuffer` 或 `UpdateStrategy` 維持金庫狀態存活——這兩種動作都會更新 `last_realloc_time`。

「keeper 故意只打 heartbeat 拖延 Layer 3」這個對抗情境確實存在，但已被另外幾層保護蓋住：白皮書 §5.4 描述的 7 天 keeper-inactivity gate **只讀 `last_compound_time`**，不論 heartbeat 有沒有打。只要 productive Compound 停超過 7 天，gate 就會啟動 Direct Withdraw 早提領費自動免收、keeper-authorized redeemer 的治理 m-of-n fallback、以及 emergency-withdraw 工具對存入者變得經濟合理。換言之，Layer 3 是最後一道回收路徑，不是主要保護。Layer 1 + Layer 2 + 7 天 gate + 自助 withdraw 基礎設施，在攻擊者撐到 Layer 3 之前就已經把 keeper-sabotage 情境蓋住了。

---

## 三層加總起來的覆蓋面

把三層連起來看，V1 的回應對應四種具體情境：

**情境 A — 創辦人誠實但只用一把 key**：系統照常運作為 1-of-1 multisig，配合 timelock + cancel 安全原語。Layer 1/2/3 都不會被觸發。

**情境 B — 創辦人金鑰被竊**：攻擊者拿不到任何價值。Layer 1 封死 brick 路徑（不能把 vault 寫崩）、Layer 2 維持回收流量（freeze 下仍可 swap-out）、白皮書 §6.3 的硬上限封住手續費濫用（`performance_fee_bps` 永遠不可能被推到 4.5% 以上）。即使攻擊者 queue 了惡意動作，14 天 timelock 加上 1-of-n cancel 在實務上都會擋下——若那時已招募 SPO，任一位獨立 SPO 即可取消。

**情境 C — 創辦人停付營運補貼但又沒正式啟動 sunset**（白皮書 §9.2 (c) 描述的場景）：keeper 離線 → §5.4 7 天 gate 自動生效（Direct Withdraw 早提款費免除）→ 到了 90 天 Layer 3 可由任一 vUSDCx 持有者觸發。

**情境 D — 創辦人連續 90+ 天失能**：存入者直接執行 Layer 3 社群止血，不需要任何 operator 配合就能拿回 USDCx。

---

## 這個回收範圍**不**涵蓋什麼

誠實揭露邊界很重要。Layer 3 解鎖的回收範圍**不**涵蓋：

- **部署用的 ref-script 鎖定 ADA**（V1 啟動部署 ceremony 共鎖定大約 962 ADA，分散在 20 個 ref-script UTXO 上）。
- **stake credential 押金**（14 個 staking validator × 2 ADA = 28 ADA）——這部分由 `ActDeregisterStake` 治理動作處理，需要創辦人錢包簽名。

這兩部分綁定創辦人部署錢包與 A2 治理路徑，作為單一簽名者治理的殘留成本——大約 990 ADA。存入者的 USDCx 本金不在這個殘留範圍內，永遠可透過 Layer 1/2/3 + Direct Withdraw 回收。

---

## 為什麼這套設計能讓單一簽名者治理成為可接受的 fallback

把上述四種情境連起來看：V1 的存款人保護**不依賴**「治理金鑰沒被竊」、**不依賴**「creator 沒失能」、**不依賴**「keeper 還在線」。每一個假設都有對應的回收路徑替代。

這就是「single-signer governance 為什麼可以作為 Phase 1 fallback」的結構性答案：不是因為相信創辦人不會出事，而是因為合約**設計成創辦人出事的後果可控**。

當然，這不是說 3-of-3 + 2 位獨立 SPO 變得無關緊要。SPO 招募仍是首選路徑——它提供額外的可信度與結構性異議否決，把「治理串謀做惡」的窗口從「14 天 timelock + 公開觀察」進一步收窄為「需要 3 位獨立身份同時配合」。但它不是上線阻礙，因為合約層的保護已經把存入者的最壞情況限定在「USDCx 本金可以拿回，僅損失 V1 的便利性」——這是個可接受的下限。

---

## 下一篇

第 2 篇會處理第二個面向：**怎麼確認上述保護真的存在**？單元測試會 lie——validator 邏輯改一行，測試也改一行，紅燈秒變綠燈。V1 補上的是「對抗性鏈上重放」：構造攻擊 TX、送到 Preprod ceremony build 的活合約上、把合約的拒絕（或接受）當鏈上證據紀錄下來。第 2 篇講方法論與已驗證的防禦層分類。

第 3 篇處理 V1 同時持有 USDCx + DJED + USDM 的脫鉤風險——什麼能防、什麼不能防。第 4 篇深入 phantom-vault 攻擊向量，補足第一系列 Article 4 對編譯期 NFT anchor 處理的不足。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
