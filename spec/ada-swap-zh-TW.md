# OptiVaults V1 — Vault ADA 補充(`SwapAda`)

**範圍**:`SwapAda` redeemer,讓 keeper 以 oracle 定價的公平匯率,原子性地把 ADA 貢獻進金庫、換回 USDCx,用於補充被 Minswap V2 swap batcher fee 消耗掉的金庫運營 ADA。

---

## 1. 此 redeemer 解決的問題

V1 的 `DeployToProtocol` 與相關 swap 產生型 redeemer,每筆 Minswap V2 order 從金庫消耗約 4 ADA。Fill 通常只退回約 2 ADA(扣完 batcher fee),**每個 swap 週期淨損失約 2 ADA**,這是金庫為 Minswap batcher 基礎設施付的錢。

在 100K TVL 下、每年約 20 次 swap,金庫預期年 ADA 消耗約 40 ADA。若無補充機制,金庫 ADA 會單調下降至 `min_vault_ada`(10 ADA 下限),屆時 `DeployToProtocol` 會被拒,策略再也無法 rebalance。

內部驗證期 mainnet 採用的方式是 operator 手動把 NoDatum ADA UTxO 送到金庫地址、再用 `MergeUtxo` 合入。可行,但它是鏈下運營步驟、有幾個問題:
- 需要專屬 keeper 時間 + ADA
- 在多 keeper 輪替時造成不對稱負擔(誰剛好被叫去 top up?)
- 對 keeper 付出的 ADA 沒有鏈上補償

`SwapAda` 把這件事變成**原子性的鏈上等價交換**:keeper 給金庫 ADA,金庫用 oracle 定價的公平匯率把等值 USDCx 給回 keeper。Keeper 經濟上中性(1:1 市價等值交換);金庫 USDCx 隨時間緩慢下降,而那個緩慢下降**就是**協議向存入者收取 Minswap batcher fee 的方式(透過 share-price 微幅下修)。**閉環。**

---

## 2. Redeemer

```aiken
type VaultCoreRedeemer {
  // ... 既有 redeemer(Deposit、Withdraw、Compound 等)
  SwapAda { amount_ada: Int }
}
```

單一整數參數:keeper 貢獻進金庫的 ADA(lovelace)。

---

## 3. 驗證

`SwapAda` redeemer 位於 `vault_swap_ada`(從 vault_keeper_hot 抽出來的 standalone staking validator,目的是把 dual-feed oracle 讀取 + 6-tuple registry 讀取的 bytecode 從 Compound 的 host 移走;透過 `vault_proxy` 的 `UseSwapAda` route 做 Withdraw-Zero forwarding)。強制的不變量如下。V1 關鍵要點:**keeper 授權走 stake-script zero-withdraw 模式**,**不是**靠 `keeper_pkh` datum 欄位(V1 VaultDatum 中不存在)。Output routing 用的 keeper PKH 是從 `tx.extra_signatories` runtime 推導、對應到 `keeper_output_idx` 的 output 地址。

```aiken
SwapAda { amount_ada, keeper_output_idx } -> {
  // 識別自己的 input + continuing output
  expect vault_input_count == 1
  expect old_datum.frozen == 0                          // V1 內部審計發現:凍結擋 SwapAda

  let own_lovelace = lovelace_of(own_input.output.value)
  let (cont_output, new_datum) =
    get_continuing_datum(tx.outputs, proxy_hash, own_input.output)
  let out_lovelace = lovelace_of(cont_output.value)

  // 1. Keeper 授權：V1 的 stake-script zero-withdraw,
  //    不是 require_keeper(keeper_pkh)。vault_core 編譯期錨定
  //    keeper_stake_script_hash;任何被 stake script 授權的錢包都可呼叫。
  let keeper_authorized = require_keeper_stake_script(tx, keeper_stake_hash)

  // 2. 觸發前置條件:vault ADA 低於門檻
  let ada_below_threshold = own_lovelace < ada_swap_threshold   // 15 ADA

  // 3. 金額邊界
  let amount_in_range = and {
    amount_ada >= ada_swap_min,      // ≥ 10 ADA
    amount_ada <= ada_swap_max,      // ≤ 50 ADA
  }

  // 4. 物理 ADA 轉移
  let ada_added = out_lovelace == own_lovelace + amount_ada

  // 5. 公平 USDCx 輸出(透過 oracle 讀取的匯率)
  //    ada_price_bps = 1 ADA 兌多少 USDCx × 10^4;V1 MVP 讀第一個 Int
  //    reference input(Charli3+Orcfax 共識,鏈下)。完整 dual-feed 強制
  //    是 V1.x candidate(見 §5)。
  let ada_price_bps = read_ada_price_oracle(tx)
  let usdcx_out_expected = amount_ada * ada_price_bps / 10_000_000

  let own_usdcx = quantity_of(
    own_input.output.value,
    old_datum.deposit_token_policy, old_datum.deposit_token_name,
  )
  let out_usdcx = quantity_of(
    cont_output.value,
    old_datum.deposit_token_policy, old_datum.deposit_token_name,
  )
  let usdcx_deducted = own_usdcx == out_usdcx + usdcx_out_expected

  // 6. Keeper 收 USDCx：keeper_output_idx 的 output 必須付給
  //    一個 VerificationKey wallet,其 PKH 在 tx.extra_signatories
  //    (簽名 keeper)裡出現。這從 TX runtime 推導 keeper 身份,
  //    不是從 datum 欄位。
  let valid_keeper_output =
    expect Some(kout) = list.at(tx.outputs, keeper_output_idx)
    when kout.address.payment_credential is {
      VerificationKey(pkh) ->
        and {
          list.has(tx.extra_signatories, pkh),
          quantity_of(kout.value,
            old_datum.deposit_token_policy, old_datum.deposit_token_name,
          ) >= usdcx_out_expected,
        }
      _ -> False
    }

  // 7. Cooldown + 1h validity-range 寬度上限(內部驗證)
  let valid_cooldown = when (
      tx.validity_range.lower_bound.bound_type,
      tx.validity_range.upper_bound.bound_type,
    ) is {
      (Finite(now), Finite(upper)) -> and {
        now >= old_datum.last_ada_swap_time + ada_swap_cooldown_ms,
        upper - now <= max_validity_range_ms,
        new_datum.last_ada_swap_time >= now,
        new_datum.last_ada_swap_time <= upper,
      }
      _ -> False
    }

  // 8. Datum:只有 last_ada_swap_time + idle_buffer 會變,其餘全部保留
  let valid_datum_other = and {
      new_datum.total_deposited == old_datum.total_deposited,
      new_datum.total_shares == old_datum.total_shares,
      new_datum.idle_buffer == old_datum.idle_buffer - usdcx_out_expected,
      new_datum.non_deposit_value == old_datum.non_deposit_value,
      new_datum.last_compound_time == old_datum.last_compound_time,
      new_datum.last_realloc_time == old_datum.last_realloc_time,
      new_datum.last_fee_update_time == old_datum.last_fee_update_time,
      new_datum.strategy_allocations == old_datum.strategy_allocations,
      new_datum.liqwid_positions == old_datum.liqwid_positions,
      new_datum.frozen == old_datum.frozen,
      check_immutable_fields(old_datum, new_datum),
      check_policy_fields_unchanged(old_datum, new_datum),
      new_datum.idle_buffer >= 0,
    }

  // 9. Token 保留(內部驗證雙層)
  let valid_other_tokens_preserved = verify_other_tokens_preserved(
    own_input.output, cont_output,
    old_datum.deposit_token_policy, old_datum.deposit_token_name,
    #"", #"",
  )

  // 10. 無 mint / 無 order input(防止與 BatchProcess 混合)
  let no_mint = get_mint_quantity(tx, old_datum.vusdcx_policy) == 0
  let no_order_inputs = val_has_no_order_inputs(
    tx.inputs, old_datum.order_script_hash,
  )

  and {
    keeper_authorized,
    amount_in_range,
    ada_below_threshold,
    ada_added,
    usdcx_deducted,
    valid_keeper_output,
    valid_cooldown,
    valid_datum_other,
    valid_other_tokens_preserved,
    no_mint,
    no_order_inputs,
  }
}
```

---

## 4. 編譯期參數

整合進 `vault_swap_ada` 的編譯期參數集(SwapAda 的家):

| 參數 | V1 啟動值 | 語意 |
|------|-----------|------|
| `ada_swap_threshold` | 15_000_000(15 ADA) | 觸發條件:金庫 ADA 必須**低於**此值才能呼叫 |
| `ada_swap_min` | 10_000_000(10 ADA) | 每次 SwapAda 最少 ADA(防 dust spam) |
| `ada_swap_max` | 50_000_000(50 ADA) | 每次 SwapAda 最多 ADA(限縮 oracle-stale 利用的上限) |
| `ada_swap_cooldown_ms` | 3_600_000(1 小時) | SwapAda TX 之間最小間隔(anti-spam + oracle-stale 邊界) |
| `ada_price_oracle_source` | Charli3/Orcfax 的 policy + asset_name,或 Minswap V2 ADA/USDCx pool script hash | Reference-input 的身份來源,供 price 讀取 |

**改動任一參數都要完整 V1 重部署**(新 validator hash、新 vault 地址)。這是刻意的:這些邊界決定了 SwapAda 的信任模型,V1 不讓治理可調。

---

## 5. Oracle 來源

**§5.4 P5:透過 `contracts/lib/vault/oracle.ak` 的共用 dual-feed 讀取器。** SwapAda 透過與 P4 Tier 1 peg-floor(on `DeployToProtocol`)相同的 `read_fair_price` helper 讀取 ADA/USDCx 價格。Oracle 設定來自 registry 的 `asset_oracles` list:一個 `AssetOracleEntry` 釘在 ADA 慣例 `(asset_policy = #"", asset_name = #"")`。治理透過 `UpdateRegistry`(14 天 timelock)填入 ADA 條目;V1 啟動時 `asset_oracles = []`,代表 SwapAda **在治理啟用之前處於 inactive**;啟動窗口內,金庫 ADA top-up 走 `MergeUtxo` 捐贈(operator 路徑)。

### 5.1 Registry 條目佈局

`RegistryDatum.asset_oracles` 中的 ADA 條目釘:

- **資產身份**:`(asset_policy = #"", asset_name = #"")`,Cardano lovelace 慣例。
- **Feeds list**(通常 2 項):每個 `AssetOracleFeed` 以 `(feed_script_hash, feed_auth_policy, feed_auth_name)` 標定 reference-UTXO 位置。Auth NFT 防止在同 script 地址的誘餌 UTxO。V1 啟動慣例是 1 個 Charli3 feed + 1 個 Orcfax feed,oracle operator 在鏈下做 aggregate 後寫入 canonical `PriceSample` 格式(見 5.2)。
- **`max_disagreement_bps`**:跨 feed spread 上限。建議 200(2%),對應 legacy MVP 的 `diff_pct <= 2` 行為。
- **`max_staleness_ms`**:各 feed 相對 `tx.validity_range.lower_bound` 的年齡上限。鏈上 ceiling 為 **1 小時**，由 `contracts/lib/vault/validation.ak::valid_asset_oracle_entry` 強制。啟動建議值為**每條目 600_000（10 分鐘）**，可由治理 `UpdateRegistry` 在 ceiling 內調整。比 legacy MVP 的 40 分鐘緊,因為 dual-feed 聚合已經補償單一 feed 的延遲。
- **`min_feeds`**:所需健康 feed 數。設 2(所有 feed 都要同意)。

### 5.2 PriceSample datum 格式

每個 feed UTxO 帶一份 canonical V1 `InlineDatum`:

```aiken
PriceSample {
  price_bps: Int,       // USDCx per ADA × 10_000(10_000 = $1.00)
  timestamp_ms: Int,    // oracle operator 發布該 sample 的 ledger ms
}
```

鏈下 oracle operator 負責讀取 Charli3 + Orcfax native feed,套用自身聚合政策(通常是 midpoint 或 median),每個 feed slot 發布一份 `PriceSample` UTxO。Operator 身份 + 發布政策是文件化的外部信任邊界,見 `../docs/security-model.md`。未來 V1.x / V2 可能換成各協議的原生解析器(Charli3 `OracleDatum` + Orcfax `FactStatement`)以移除 operator 聚合層。

### 5.3 共識規則(在 `vault_swap_ada` 中強制)

```aiken
expect Some(ada_entry) = find_asset_oracle(asset_oracles, #"", #"")
expect Some(ada_price_bps) = read_fair_price(tx, ada_entry)
let usdcx_out_expected = amount_ada * ada_price_bps / 10_000_000
```

`read_fair_price` 定義於 `contracts/lib/vault/oracle.ak`,強制:

1. 至少 `entry.min_feeds` 份健康 sample(feed UTxO 存在 + auth NFT 存在 + `price_bps > 0`)。
2. 每份 sample 的 `timestamp_ms` 比 `tx.validity_range.lower_bound - entry.max_staleness_ms` 更新。過時的 sample 會從聚合中掉出。
3. 跨 feed spread(`(max − min) × 10_000 / min`)至多 `entry.max_disagreement_bps`。
4. 回傳的公平價是健康 sample 的中位點,對 2 feed 條目而言等同 median。

任何失敗(無條目、健康 feed 太少、過時、disagreement、價格退化)回傳 `None`,`SwapAda` 內的 `expect Some(...)` 會強制 TX revert。

配合 SwapAda 的 1 小時 cooldown 與啟動建議的 10 分鐘每 feed 過期上限（鏈上 ceiling 為 1 小時），**想做單一 oracle 操弄的攻擊者必須讓兩個 feed 在設定的過期窗口內各自說同樣的謊**:dual-feed 共識把門檻從「一個 oracle 被入侵」提升到「兩個獨立 oracle 在過期窗口內同時被入侵」。

---

## 6. 經濟模型

### 6.1 100K TVL 下的年金庫 ADA 流

假設每年約 20 個 swap 週期,每次從 vault → Minswap 淨 −2 ADA:

| 事件 | 頻率 | ADA 變動 |
|------|------|---------|
| DeployToProtocol(VaultSwap) | ~20 次 / 年 | −4 × 20 = −80 ADA(出給 Minswap order) |
| Minswap fill | ~20 次 / 年 | +2 × 20 = +40 ADA(回金庫) |
| **淨金庫 ADA 消耗** | — | **−40 ADA / 年** |
| SwapAda(補充) | ~2 次 / 年(每次 +20 ADA) | +40 ADA |
| **金庫 ADA 淨值** | — | **≈ 0**(閉環) |

金庫 ADA 在 13–35 ADA 區間震盪(偶爾碰 15 ADA 下閾,然後 SwapAda 把它回復到 ~35)。

### 6.2 誰付這個成本

| 角色 | ADA 淨流 | USDCx 淨流 | 經濟位置 |
|------|---------|-----------|---------|
| 存入者 | 0(無直接 ADA 曝險) | −20 USDCx / 年(透過 share-price 微幅下修) | 最終成本承擔者(100K TVL 下約 0.02% APY 的微幅下修) |
| Keeper | ±0 淨(SwapAda 是公平等值) | 從 SwapAda +20 USDCx / 年(被所付 ADA 抵消) | 經濟上中性 |
| Minswap V2 batcher | +40 ADA / 年 | 0 | 正常收取 batcher fee |

存入者每年付約 20 USDCx(TVL 的 0.02%)作為協議使用 Minswap V2 的權利。**以 share-price 微拖曳顯現、不是明確費用**。

### 6.3 Keeper 輪替公平性(Phase 2+)

多 keeper 輪替下,在某個週期簽 SwapAda TX 的是誰,就是誰做 ADA↔USDCx 等值交換。跨多個週期看,SwapAda 大致按各 keeper 的輪替週數均勻分配。每筆交換都個別公平(oracle 定價),**沒有結構性的不公**。

這比內部驗證期「**創辦人-keeper 一人承擔所有補充成本**」的手動 top-up 模式是嚴格改善。

---

## 7. 失敗模式 + 緩解

| 失敗 | 緩解 |
|------|------|
| Oracle feed spread > 2%(操弄 / 停機) | TX 被拒;keeper 等候、或自費在外部 Minswap V2 手動 USDCx→ADA |
| 兩個 oracle 都過期 > 40 分鐘 | TX 被拒;同上 |
| Keeper 錢包 ADA 不足(20-50 ADA) | Keeper 運營責任;`docs/integration-playbook.md` 文件化,keeper 應維持 100+ ADA 儲備 |
| 惡意 keeper 在金庫 ADA **未**低於門檻時觸發 SwapAda | 合約檢查拒絕(`ada_below_threshold = false`) |
| 惡意 keeper 靠 SwapAda 做 stale oracle 套利(最多 50 ADA × 2% tolerance = 每次 1 USDCx × 每日 24 次) | Cooldown 1h + bounded spread + 50 ADA 上限,把每日損失限制在約 24 USDCx(100K TVL 下最壞 0.024%) |
| Oracle 來源(Charli3 + Orcfax)同時被入侵 | 治理可以 queue `UpdateOracleSource` 動作,經 14 天 timelock 換 feed;期間 `EmergencyWithdraw` 把金庫凍結(frozen=1)擋住 SwapAda 呼叫 |

---

## 8. 為什麼不支援反向(USDCx → ADA 提取)

`WithdrawAda` redeemer(keeper 給 USDCx、收 ADA)被考慮過,**V1 延後**:

- **實務上用途有限**:金庫 ADA 自然在 13–35 ADA 震盪,很少超過假設的 `> 50` 上閾。Keeper 少有機會呼叫。
- **攻擊面翻倍**:Keeper-profit 型 oracle-stale 套利在兩個方向都可行;關掉反向讓攻擊面減半。
- **Keeper 有替代路徑**:keeper 收到的 USDCx fee 收入,可以在自己的時程透過 Minswap V2 轉成 ADA(約每季一次、每次 2 ADA 的 Minswap fee = 每年合計 8 ADA,100K TVL 下經濟上微不足道)。

若實際運營經驗顯示需要,列為 V1.x candidate feature。

---

## 9. 相關 spec

- `spec/vault-datum.md §2.1` — 會計狀態組新增 `last_ada_swap_time` 欄位
- `spec/architecture.md §7.5` — ADA 生命週期概述 + 指向本 spec
- `whitepaper/whitepaper.md §4.5 + §5.4` — 給存入者揭露的閉環模型
- `docs/security-model.md §3.x` — oracle 失敗威脅模型
