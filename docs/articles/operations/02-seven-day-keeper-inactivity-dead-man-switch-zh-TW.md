# 7 天 keeper-inactivity dead-man-switch：讓存入者不必信任 keeper

*OptiVaults V1 營運機制解說，第 2 篇 / 共 3 篇*

---

Keeper 是 V1 唯一一個「需要持續運作才能讓金庫正常產生收益」的角色。它執行 Compound、再平衡、Minswap V2 swap、Liqwid Supply/Recall。沒有 keeper，金庫不再累積收益，但所有資金仍然在 vault UTXO 裡，只是「被動」而非「自動運作」。

存入者該怎麼面對「keeper 可能停擺」這個風險？

傳統 DeFi 的常見回應有兩種：(a) 把 keeper 改成 multi-operator 冗餘設計，多個 keeper 互相備援；(b) 在 keeper 停擺時依賴 multisig 治理介入。

V1 兩個都沒採。V1 把這條防線寫在合約層：**`last_compound_time + 7 days` 過去之後，三件事自動發生**，存入者不需要信任 keeper 還活著，不需要等 multisig 開會。本篇拆解這個 dead-man-switch 怎麼運作、為什麼是 7 天、以及最關鍵的：**它為什麼不能被偽造的時間戳騙過去**。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。

---

## 三件自動發生的事

當 `last_compound_time + 7d < tx.validity_range.upper` 時，validator 自動觸發：

**(1) Direct Withdraw 早提領費自動免收**。

正常運作下，Direct Withdraw 在 `min_hold_seconds` 窗口內會收 0.1% 早提領費（白皮書 §2.4）。Keeper inactivity 7 天後，`vault_user.Withdraw` 把 `early_withdraw_fee_bps` 視為 0，不論 datum 上的設定值是多少。這條讓存入者在 keeper 停擺期間不必為了 keeper 失能買單。

**(2) Keeper-authorized redeemer 的治理 m-of-n fallback 打開**。

正常情況下 `vault_liqwid.RecallFromLiqwid` / `vault_recall.RecallFromProtocol` / `vault_admin_deploy.AdminDeployNonDeposit` 需要 keeper 簽名。Keeper inactivity 7 天後，validator 內部的 `require_keeper_or_governance_fallback` gate 開啟，治理可以用 m-of-n 簽名代替 keeper 簽名執行同樣的 redeemer。

這條讓「keeper 跑路 + 資金卡在 Liqwid」這個情境有解：m-of-n 治理可以代替 keeper 把 qToken 全部 Recall 回 USDCx，讓所有存入者可以直接 Withdraw。

**(3) Emergency-withdraw 工具對存入者變得經濟合理**。

`emergency-withdraw` CLI 與前端工具讓存入者本機構造 TX 自助退場，**不需要任何 operator 配合**。這條工具一直存在，但正常情況下走 emergency-withdraw 仍要付 early_withdraw_fee；7 天 inactivity 後 fee 自動免收，emergency-withdraw 對存入者的吸引力就出現了，既不依賴任何 operator，又不付 fee。

把三條合在一起：keeper 完全停擺後 7 天，存入者有三條獨立的退場路徑：

```
路徑 A: 直接走 frontend / wallet 做 Direct Withdraw (0% fee)
路徑 B: 等治理 m-of-n 簽名介入 RecallFromLiqwid 把 qToken 換回 USDCx
路徑 C: 自己用 emergency-withdraw CLI 構造 TX (0% fee)
```

每一條都不需要 keeper 配合。存入者的本金安全不依賴「我們承諾 keeper 不會出事」，它依賴鏈上時間戳的客觀比較。

---

## 為什麼是 7 天

7 天是兩個考量的折衷：

**太短 → false positive**。Keeper 可能因合理理由短暫停擺：主機維護、Cardano mainnet 短暫擁塞、Blockfrost / Ogmios 短期不可用、營運者短期休假。若 dead-man-switch 是 1-3 天，這些情境會被誤判為「keeper 死了」，trigger early_withdraw_fee 免收會讓存入者誤判趨勢。

**太長 → 存入者保護不足**。若 dead-man-switch 是 30-60 天，keeper 真的跑路後，存入者要等 1-2 個月才能無 fee 退場。對 emergency 情境（譬如 Liqwid 突然出問題），這個窗口太長。

7 天讓「合理短期停擺」不觸發 fallback，同時讓「keeper 真的失能」很快進入 fallback 模式。它也跟白皮書 §2.6 的 Compound 排程一致，1,200+ TVL 檔每週六一次 productive Compound，所以「上一次 productive Compound > 7 天前」基本上等同於「keeper 漏了一次該做的事」。

7 天值刻意不可調。它是 `vault_user.ak` / `vault_keeper_hot.ak` 內的編譯期常數 `keeper_inactivity_window_ms = 7 × 24 × 60 × 60 × 1000`。治理在 V1 內無法調整這個值，要改必須重新部署整個 V1（編譯期錨點，見 [Security 系列 Article 4](../security/04-phantom-vault-and-compile-time-anchor-zh-TW.md)）。

---

## 關鍵：`last_compound_time` vs `last_realloc_time`

V1 的 datum 有兩個時間欄位，職責不同：

- **`last_compound_time`**：只有「實際收益 > 0」的 productive Compound 才會更新。
- **`last_realloc_time`**：由 zero-yield Compound（heartbeat）以及任何配置更新（RebalanceBuffer / UpdateStrategy / reconciliation）觸發更新。

**7 天 dead-man-switch 只讀 `last_compound_time`**。這條設計很關鍵：

- Zero-yield heartbeat 的用途是給 off-chain indexer 保持 liveness 訊號，**不會重設 7 天 fallback 窗口**。
- Heartbeat 只更新 `last_realloc_time`，不影響 `last_compound_time`。
- Reference Implementation Mode 下（Economics 系列第 3 篇）keeper 故意只跑 heartbeat 不跑 Compound，這個合法營運模式不會錯誤觸發 7 天 gate（因為 Compound 真的累積到收益夠多就會跑）。

dead-man-switch 因此完全取決於**真正的收益活動**，不是 keeper 的「我還活著」ping。

這個分離也擋下一條繞道：「keeper 故意只送 heartbeat 拖延 dead-man-switch」這個對抗情境**不存在**，heartbeat 不會更新 `last_compound_time`，所以 keeper 即使瘋狂送 heartbeat 也不能拖延 7 天 fallback 觸發。

---

## 為什麼不能被偽造的 validity range 騙過去

dead-man-switch 的判斷邏輯：

```aiken
fn keeper_is_inactive(datum: VaultDatum, tx: Transaction) -> Bool {
  datum.last_compound_time + 7_days_ms <= tx.validity_range.upper
}
```

這條看起來有個漏洞：`tx.validity_range.upper` 是 TX 提交者自己設的。如果提交者宣稱 `validity_range.upper = now + 100 years`，那 `keeper_is_inactive` 永遠為 true，dead-man-switch 永遠觸發，keeper 永遠是「inactive」。

V1 把這條繞道堵死了。**每個會寫入時間欄位的 redeemer 都強制 `validity_range.upper - validity_range.lower <= 1 hour`**。這條 width cap 寫在 `vault_user.ak` 與 `vault_keeper_hot.ak` 對應的 helper 裡：

```aiken
fn validate_validity_range_width(tx: Transaction) {
  let lower = tx.validity_range.lower.bound
  let upper = tx.validity_range.upper.bound
  expect upper - lower <= 1 * 60 * 60 * 1000  // 1 hour
}
```

效果：

- 聲稱 `upper = now + 10y` 的 TX 在 ledger 端被拒（width 超過 1 小時）。
- 聲稱 `upper - lower = 1 hour` 的 TX 通過 width check，但 `upper` 仍然只能是 `lower + 1 hour`，不能是 `lower + 100 years`。
- Cardano ledger 對 `validity_range.lower` 也有約束（必須 ≤ 當前 slot），所以 `upper ≤ now + 1 hour`。

加總起來：**keeper inactivity 判定依賴的是實際的 ledger 時間，不是 TX 提交者的自稱**。攻擊者無法用「我宣稱現在是 2030 年」這種方式繞過 dead-man-switch。

---

## 對 emergency-withdraw 自助路徑的影響

V1 從一開始就提供 `emergency-withdraw` CLI 與前端工具，讓存入者本機構造 TX。這條路徑不需要任何 operator 配合，它直接 spend vault UTXO、burn vUSDCx、依當下 share price 領回 USDCx。

正常運作下 emergency-withdraw 仍要付 early_withdraw_fee（0.1%）。為什麼存在 fee？因為存入者用 emergency-withdraw 是「跳過正常的 keeper 處理」，這個 fee 補償剩餘存入者承擔的「未經 keeper 優化的 swap 路徑」可能造成的影響。

7 天 dead-man-switch 觸發後，這個 fee 自動降為 0。理由：

- Keeper 失能後沒有「正常路徑」可走，emergency-withdraw 變成「唯一可用路徑」。
- 在這個情境下對存入者收 fee 沒道理，他們不是選擇跳過 keeper，是 keeper 不存在了。

這條 0% fee 在合約層自動生效，不需要任何治理動作，不需要任何 operator 同意。存入者直接用 emergency-withdraw 工具，付 vault.lovelace 的最小 TX fee（約 1.5-2 ADA）就能退場。

---

## 與三層治理安全的關係

dead-man-switch 跟 [Security 系列 Article 1](../security/01-three-layer-governance-safety-zh-TW.md) 講的三層治理安全是互補關係：

| 機制 | 觸發時點 | 主要作用 |
|------|---------|---------|
| **7 天 dead-man-switch** | `last_compound_time + 7d` | Direct Withdraw 0% fee + 治理 fallback + emergency-withdraw 經濟合理 |
| **三層治理安全 Layer 1**（freeze-only） | 治理介入 | 凍結 vault 新 Deploy |
| **三層治理安全 Layer 2**（freeze 下 swap-out） | 治理 freeze + keeper 在線 | swap 非存入代幣回 USDCx |
| **三層治理安全 Layer 3**（CommunitySunset） | `max(last_compound_time, last_realloc_time) + 90d` | 任一 vUSDCx 持有者觸發完整 permissionless 回收 |

7 天 dead-man-switch 跟 Layer 3 的 90 天 sunset 不衝突，它們處理不同情境:：

- 7 天 fallback 假設「keeper 失能但治理仍然能 m-of-n 簽名」，治理介入用 fallback path Recall 資金。
- 90 天 sunset 假設「keeper + 治理同時失能」，任何 vUSDCx 持有者可以代行回收。

存入者退場路徑因此有層次：

```
[Day 1-7] keeper 失能但 < 7 天
  → Direct Withdraw 仍正常 (with early_withdraw_fee 若在 min_hold 窗口內)
  → 走 Queue Withdraw 仍然 fine (但 keeper 不在線可能延遲)
  → emergency-withdraw 可用 (with fee)

[Day 7+] keeper 失能 ≥ 7 天
  → Direct Withdraw 0% fee
  → 治理 m-of-n fallback 打開 (若治理仍在運作)
  → emergency-withdraw 0% fee

[Day 90+] keeper + 治理同時失能
  → 任一 vUSDCx 持有者觸發 CommunitySunset
  → 完整 permissionless 回收路徑
```

每一層加上一個「不依賴上一層」的退場選項。即使所有 operator 同時失能 90 天，存入者仍然能拿回 USDCx。

---

## 為什麼這條機制比 multi-operator 冗餘設計好

傳統 DeFi 應對「keeper SPOF」的解法是 multi-operator，譬如 3 個 keeper instances 由不同 operator 運作，互相備援。

這個方案的問題：

**(a) 多個 keeper 共享 keeper key**。如果三個 keeper 用同一把私鑰，任一被竊就是全竊。如果用不同私鑰、合約需要任一簽名通過，攻擊者只要 compromise 任一 keeper。

**(b) Operator 串謀風險**。多個 operator 之間如果有經濟綁定（譬如同一公司、同一 team），多 operator 等於假 multi-operator。

**(c) 增加合約複雜度**。Validator 要驗證多個 keeper 簽名的不同情境，增加 audit surface。

V1 採用的姿態：**單一 keeper + dead-man-switch fallback**。它的優點：

- **合約 surface 小**。Keeper 認證邏輯簡單（單一 PKH 或可由 `keeper_stake_script` 切換的 PKH）。
- **存入者保護不依賴 multi-operator 假設**。即使單一 keeper 真的失能，dead-man-switch 自動觸發；不需要相信其他 operator 會代行。
- **未來可選擇開放 multi-operator**。`keeper_stake_script` 支援 `PermissionlessWithBond` 模式（白皮書 §7.2），在 TVL 達 $5-10M 時可以由治理切換到開放註冊。dead-man-switch 與 PermissionlessWithBond 並存，後者增加 keeper 在線機率，前者作為終極 backstop。

這個權衡反映 V1 的整體姿態：**先讓「最壞情況」結構上有解，再考慮「最壞情況很少發生」的優化**。Dead-man-switch 是「最壞情況有解」的具體實現。

---

## 下一篇

第 3 篇處理存入者最常碰到的實務問題：**怎麼從 vault 取回 USDCx**？V1 提供三條 withdraw 路徑:Direct / Queue / Emergency。它們的 trade-offs、什麼情境下選哪一條、成本與時間差，下一篇講。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
