# 4.5% 績效費：公式、不變式、validator-level 硬上限

*OptiVaults V1 經濟模型解說，第 1 篇 / 共 4 篇*

---

V1 對存入者唯一的協議層收費是「績效費 4.5%」。沒有 AUM 費、沒有管理費、沒有入金費。只在實際產生收益時、收已實現收益的 4.5%。

V1 刻意把對存入者最有感的數字，收斂成「單一欄位、單一 redeemer 路徑、一條結構性硬上限」。本篇拆開這個費率的精確語意：公式怎麼算、什麼時候收 / 什麼時候不收、為什麼治理在任何情境下都動不了 4.5% 這個上限。

整套合約以 Apache 2.0 授權開源在 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。

---

## 公式

每次 Compound 事件，validator 按下面公式計算當期績效費：

```
fee_amount = 0.045 × max(0, NAV_now − NAV_last_compound − realised_rebalance_slippage)
```

三個變數的定義：

- `NAV_now` — Compound 事件時點的金庫總價值，以 USDCx 計價。
- `NAV_last_compound` — 上次 Compound 事件的 NAV。
- `realised_rebalance_slippage` — 自上次 Compound 以來，所有跨市場再平衡的滑點成本總和。滑點 = oracle 公平價與執行價的差。

這三個變數都是 Compound TX 建構時 keeper 計算出來、validator 重算驗證後才放行。攻擊者無法說「我宣稱本期 NAV 漲了 100」就讓 validator 跑出對應的 fee，validator 會檢查 NAV 是否來自鏈上實際持倉的估值。

---

## 四個關鍵屬性

### 負期間產生零費用

公式裡的 `max(0, ...)` 是關鍵。如果 `NAV_now < NAV_last_compound`（譬如 DJED 脫鉤、USDM Liqwid 市場壞帳），整期績效費為 0，不會「補繳」、不會「攤分」、不會「先預扣下次補」。

這個屬性的含意：**vault 持有人下行風險與營運方利益對齊**。如果金庫表現不好，營運方一毛錢都拿不到。這跟「不管表現好壞每年收 1% AUM 費」的傳統資產管理模型結構性不同，V1 在 NAV 下跌時，營運方收入是 0。

實務影響：如果你存入的時點剛好碰上脫鉤期，share price 會反映損失，但這個期間 vault 沒有從你身上額外抽 fee。下一次 NAV 回到 last compound 以上時，fee 才會重新從那條基線往上算。

### 滑點由協議承擔，不直接由使用者承擔

這條的細節比較容易誤解。

公式裡 `realised_rebalance_slippage` 是從 fee 基底**扣掉**的，也就是說，再平衡滑點減少的是 fee 基底，不是直接減少使用者 NAV。

聽起來好像滑點還是被存入者吸收，因為 NAV 本來就會受滑點影響。但這條的真實含意是「fee 是對淨於滑點之後的收益計算的」，keeper 不能用「滑點再多沒關係，反正都算進 fee 基底裡」這種方式來放任滑點。

具體例子：

```
假設一期內：
  - Liqwid yield 累積 1000 USDCx
  - 再平衡 swap 損失 100 USDCx slippage

NAV_now − NAV_last_compound = 1000 − 100 = 900 USDCx
realised_rebalance_slippage = 100 USDCx

fee_amount = 0.045 × (900 − 100) = 0.045 × 800 = 36 USDCx
```

如果公式裡沒有扣 slippage，fee 會是 `0.045 × 900 = 40.5 USDCx`，存入者多付 4.5 USDCx 的「對滑點的 fee」。V1 的設計把滑點視為「應該由 protocol 自己消化的營運成本」，不轉嫁到 fee 計算上。

### 只對已實現收益收取

Compound 事件時尚未測量的 qToken 累積（unrealised），到下次 Compound 才會產生 fee。

實務影響：你存入 vault 之後，share price 上升的部分如果還沒到 Compound 時點，那部分對應的 fee 還沒被扣。如果你在兩次 Compound 之間就 Withdraw，你帶走的 share value 是包含「未實現累積」的，但 V1 設計上 share value 已經反映 Compound 時的 NAV 計算，所以提早退場不會「逃過」應付的 fee；同時，提早退場也不會多付未到期的 fee。

### 不採用 high-water mark（HWM）

每次 Compound 各自獨立對前次 Compound 的 NAV 計算。從前期高點回升不會觸發「補繳 fee」。

舉例：

```
Compound A: NAV = 100,000 → fee_basis = 100,000 (相對前期+) → 收 fee
Compound B: NAV = 95,000  → fee_basis = max(0, 95,000−100,000) = 0 → 不收 fee
Compound C: NAV = 98,000  → fee_basis = max(0, 98,000−95,000)  = 3,000 → 收 fee
```

注意 Compound C：NAV 還沒回到 Compound A 的 100,000 高點，但因為相對 Compound B 漲了 3,000，所以這 3,000 要收 fee。如果採 HWM 模型，Compound C 不會收 fee（因為 NAV 還沒超過 HWM = 100,000）。

V1 選擇不採 HWM 是有意的：HWM 在資產管理界爭議很大，存入者如果在不同時點進場，HWM 的「補繳」邏輯會讓晚進場的存入者不公平地豁免 fee。V1 用「每次 Compound 相對前次」的線性結算，所有存入者在任一時點承擔的 fee 比例相同。

是否在 V1.5 或之後納入 HWM 是治理層決定，V1 目前不規劃。

---

## Validator-level 硬上限：4.5% 結構性鎖死

公式講完了。但比公式更重要的是：**4.5% 這個數字是怎麼被鎖死的？**

很多 vault 設計把 fee rate 寫成可變欄位、由 multisig 決定。這意味著「我們承諾不會把 fee 拉到 4.5% 以上」是 social commitment，不是 enforceable property，如果 multisig 串謀，fee 可以被拉到任意高。

V1 的 `vault_gov_policy.ak` 在 `UpdateFee` redeemer 路徑強制這個上限：

```aiken
fn validate_update_fee(...) {
  expect performance_fee_bps <= max_performance_fee_bps  // 450 bps = 4.5%
  expect early_withdraw_fee_bps <= max_early_withdraw_fee_bps  // 100 bps = 1%
  expect min_hold_seconds <= max_min_hold_seconds  // 21,600 sec = 6 hours
  // ... 其餘檢查
}
```

`max_performance_fee_bps` 是寫死的 `450`，這不是 datum 欄位，不是 redeemer 參數，是 validator bytecode 內的常數。要把這個值改掉，必須：

1. Fork 整個 validator 程式碼。
2. 重新編譯產生新的 script hash。
3. 在新地址重新部署整套合約。
4. 把所有存入者遷移到新合約。

V1 的編譯期錨點（[Architecture 系列 Article 4](../architecture/04-vault-datum-and-nft-anchor-zh-TW.md) + [Security 系列 Article 4](../security/04-phantom-vault-and-compile-time-anchor-zh-TW.md)）把這條路徑封死，新合約的 script hash 跟 V1 完全不同，frontend / indexer / vusdcx / order 都不認，存入者不會受影響。

換句話說，「治理把 fee 拉到 5%」這個情境**在 V1 已部署的 vault 上做不到**。它不是「我們承諾不做」，是「合約結構上不允許」。任何人可以拿 V1 部署的 script hash 自己驗證這條：把 Plutus bytecode 反組譯（或從 GitHub source 對照），檢查 `max_performance_fee_bps = 450` 這條常數是否確實 baked-in。

---

## 同一個 helper 守住所有相關上限

`validate_update_fee` 不只守 `performance_fee_bps`，它同時守三個相關欄位：

| 欄位 | 上限 | 含意 |
|------|------|------|
| `performance_fee_bps` | 450 (4.5%) | 績效費上限 |
| `early_withdraw_fee_bps` | 100 (1%) | 早提領費上限 |
| `min_hold_seconds` | 21,600 (6 小時) | 直接提領冷卻上限 |

三個上限為什麼一起守在 `UpdateFee`？因為它們在經濟激勵上彼此關聯：

- `early_withdraw_fee_bps` 上限是 1%，比 `performance_fee_bps` 還低，這擋住「治理把早提領費拉到 10%」這種掠奪式設計。
- `min_hold_seconds` 上限是 6 小時，擋住「治理把直接提領冷卻拉到 7 天」這種困資金設計。請注意：**排隊提領路徑從不被 `min_hold_seconds` 觀察**，使用者資金無論設定值為何都不會被鎖；6 小時上限只影響「直接提領 vs 走排隊」的路徑選擇。

`min_hold_seconds` 的上限在白皮書中從原本的 24 小時收緊到 6 小時，是審視後的決定：週 Compound 節奏下，即使治理拉到 6 小時上限，直接提領閘門也只封閉當週的約 3.6% 時間。把 24 小時改成 6 小時，存入者保護更強，但實務影響可忽略。

---

## 對比：為什麼這個結構性鎖死值得在意

存入者選 vault 產品時的常見問題：「他們會不會偷偷把 fee 拉到 10%？」

傳統答案是「我們不會」，但這條承諾只能用 social signal 驗證，無法用密碼學驗證。

V1 的答案是「他們做不到」，這條保證可以用 ledger 資料驗證：

```
[1] 從 https://github.com/OptiVaults/optivaults-protocol 拉 source
[2] 對照 contracts/lib/vault/constants.ak 找到 max_performance_fee_bps = 450
[3] 跑 aiken build，得到 plutus.json 與 vault_gov_policy 的 script hash
[4] 從 Cardano 鏈上查 V1 部署的 vault_gov_policy script hash
[5] 兩個 hash 應該完全相同 — 如果不同，部署的 validator 不是這份 source
[6] hash 相同 → 部署的 validator bytecode 內 max_performance_fee_bps = 450 是 ledger 上的事實
```

任何人可以獨立執行這六個步驟，不需要相信創辦人、不需要相信營運方。

這是「結構性安全」與「承諾性安全」的差別。V1 在能用結構性安全的地方優先用結構性安全，4.5% 的硬上限就是這個原則的代表案例。

---

## 一個次要但相關的揭露：SwapAda 營運摩擦

嚴格意義上 V1 對存入者只有一個「協議層費用」:4.5% 績效費。但有一條稍微不那麼明顯的成本流，誠實揭露：**SwapAda 營運摩擦**。

機制：vault 每次跑 `DeployToProtocol` 透過 Minswap V2 做 swap，會付大約 2 ADA 給批處理者。如果沒有補充機制，vault 的 ADA 最終會降到 `min_vault_ada` 底限。V1 用 `SwapAda` redeemer 在鏈上閉環：當 `vault.lovelace < 15 ADA` 時，keeper 呼叫 `SwapAda` 給 vault 10–50 ADA，並按 Charli3 + Orcfax 的 oracle 匯率換回等值 USDCx。

這條閉環的成本由存入者承擔，USDCx 緩慢流出造成 Minswap 批處理費。100K TVL 下每 2-4 週一次 SwapAda（每次 20-40 ADA ≈ 10-20 USDCx），全年摩擦約 0.02% APY drag，相對 4-6% 毛收益幾乎可忽略。

這不是傳統意義上的「手續費」，但它確實會讓金庫資金流出，所以白皮書 §2.4 與本系列都如實揭露。SwapAda 的合約強制條件（1 小時冷卻、validity-range 上限寬度 1 小時、oracle 公平價原子交換）在 Operations 系列第 1 篇有更深入的處理。

---

## 下一篇

第 2 篇處理 4.5% 績效費**怎麼分配**。每次 Compound 把績效費拆成三流：keeper / gov pool / treasury。V1 啟動時的分配比例是 40/0/60，未來 phase 演進為 40/5/55 → 40/10/50。為什麼是這個比例、為什麼 keeper share 故意設高、為什麼 treasury 永遠保住 50%，下一篇講。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
