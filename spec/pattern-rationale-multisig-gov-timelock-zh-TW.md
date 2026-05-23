# Pattern Rationale — MultiSig Governance + Timelock

**狀態**：資訊性質的模式背景說明。不是 CIP、也不是 CIP 草案。OptiVaults V1 對 Cardano Improvement Proposals 的整體立場見 `docs/cip-readiness-posture-zh-TW.md`。

**範圍**：一個反覆出現的協議政策治理模式，組合了 (a) m-of-n 門檻簽名核可、(b) 每個動作各自的 timelock（核可與執行之間的時間差）、(c) timelock 窗內任一 signer 都可以行使 1-of-n veto、(d) 嚴格單調遞增的 nonce 綁定 action 識別碼、(e) payload-hash 綁定 — 確保被 queue 的動作在執行之前其效果不會漂移、(f) timelock 過後的 TTL 上限 — 不讓過期的核可一直留在 queue 裡。模式本身是通用的；OptiVaults V1 把它具現為 14 種 action kind，案例研究見 §6。

---

## 1. 問題

持有 pooled 存款資金的 DeFi 協議需要一條升級路徑。某些參數會隨時間變動 — 費率隨市場條件改變、策略配置隨機會出現與消失、整合 whitelist 隨 DEX adapter 被加進或退出、signer 成員隨人員在運維團隊裡輪替。沒有升級路徑的協議很脆。

但每一條升級路徑同時也是攻擊面。單一一把 key 控制升級就是單點故障。樸素的 m-of-n multisig 改善了單 key 的形狀，但沒有處理兩個反覆出現的失敗模式：

- **立即執行。** 當 m-of-n 簽名與升級落在同一筆交易裡時，存款人沒有反應時間。被入侵的 m-of-n 法定人數可以在任何監控偵測到變化之前抽乾 vault、或把策略換成惡意版本。
- **沉默的 payload 漂移。** m-of-n signer 在原則上核可「把 fee 升到 4%」，但實際交易攜帶的 payload 是「把 fee 升到 40%」。簽 transaction hash 而非簽參數內容的 multisig 簽名方案會錯失這個差異。鏈下簽名工具在多鏈 DeFi 歷史上多次製造出這種形狀的事故。

一份穩健的治理模式必須抵禦 (a) 達門檻的 key 被入侵、(b) 立即執行、(c) 核可與執行之間的 payload 漂移，且要簡單到讓存款人不需要特化工具也能驗證協議的治理規則。

MultiSig Governance + Timelock 模式是一個結構層的回應，它組合了六個機制 — 門檻、timelock、veto、nonce、payload-hash、TTL — 在動作生命週期的對應節點各自處理一種失敗模式。

---

## 2. 模式本身

這個模式使用一顆 singleton 治理狀態 UTXO（由 Identity NFT 錨定 — 見 Pattern 1），以及每個動作都會走過的三階段生命週期：

```
Queue ──── timelock window ──── (Execute or Cancel) ──── TTL ceiling
   │              │                       │
   │              │                       │
   m-of-n         any-signer-can          m-of-n (Execute)
   approval +     1-of-n CANCEL           or
   payload                                no execution before TTL
   commitment                             ─→ action expires
```

### 2.1 m-of-n 門檻簽名

治理 UTXO 攜帶一個 `signers: List<VerificationKeyHash>` 欄位與一個 `threshold: Int` 欄位。每一筆 queue 與 execute 交易都必須由目前 `signers` 集合中至少 `threshold` 位簽名。這兩個欄位本身也是可變的 — 透過 `RotateSigners` action kind 改 — governance 透過用在其他所有事情上的同一套模式來改變自己的組成。

threshold 由協議自己決定；常見選擇是 2-of-3、3-of-5、4-of-7。較大的 m 提供更強的抗入侵能力，但代價是合法更新時的協調變難。模式本身不挑 m；它提供基底。

### 2.2 每個動作各自的 timelock

當動作被 queue 時，validator 在那個 queued action 的 datum entry 裡記錄 `executable_at_ms = queued_at_ms + timelock_ms`。execute 路徑在鏈上目前時間還沒越過 `executable_at_ms` 之前都會拒絕跑。timelock 由每種 action kind 決定，烘進 queue redeemer，並在 validator 內部由「每種 action kind 各自的下限與上限」封住（這樣即使 queue 時帶 `timelock_ms = 0`，也無法繞過敏感動作該有的保護）。

timelock 窗的目的是**偵測時間**。鏈下監控會抓 governance UTXO，把每一筆 queued action 暴露給存款人。這段窗給存款人時間採取行動 — 退出協議、發出警報、準備爭議 — 在動作真正生效之前。

### 2.3 1-of-n cancel veto

在 timelock 窗期間，任何一位 signer 都可以 cancel 任何 queued action。cancel 路徑只要求剛好一個 `signers` 內的簽名，不是 m-of-n。這個不對稱是刻意設計：

- **進攻是 m-of-n。** 要把變更推過去必須多位 signer 協調。
- **防守是 1-of-n。** 任何單一位察覺到問題的 signer 可以單邊把變更擋下來。

這種不對稱針對的威脅模型：攻擊者拿到 m 把 signer key 後可以 queue 惡意動作，但他無法阻止剩下 n − m 位 signer 去 cancel。只要至少一位沒被攻破的 signer 上線監看著，cancel 路徑就會奏效。

### 2.4 嚴格單調遞增的 nonce → action_id

governance datum 攜帶一個 `nonce: Int`，每 queue 一次動作就剛好加 1。每個 queued action 的 `action_id` 透過 `(nonce, action_kind, target_script, target_tx_hash, payload_hash, queued_at_ms, executable_at_ms, expires_at_ms)` 做雜湊計算出來。nonce 保證了：

- 不同時間 queue 同一個效果，會得到不同的 `action_id`。
- 攻擊者無法用「重新 queue 一份完全相同的參數、再用舊的 `action_id`」這種方式重放一個曾被 cancel 過的動作（新的 queue 會因為 nonce 改變而算出不同的 `action_id`）。
- `action_id` 在後續交易裡可被引用（execute redeemer 攜帶 `action_id` 來指明它正在執行的是哪一筆 queued action）。

### 2.5 Payload-hash 綁定

queue redeemer 對一個 `payload_hash: ByteArray` 做承諾 — 它是動作執行時將產生的「效果 CBOR 序列化結果」的 Blake2b-256 雜湊。雜湊被記在 queued action 的 datum entry 裡。execute 路徑要求實際的效果交易（registry update CBOR、fee 參數 list、strategy allocation map、…）必須雜湊到同一個值。

於是 queue 與 execute 之間的 payload 漂移在結構上不可能：queued action 透過雜湊綁到它最終的效果。在 queue 上簽名的 signer 是對一個具體的 payload 做承諾，不是對「某種抽象的 action kind」做承諾。

### 2.6 timelock 過後的 TTL 上限

queue redeemer 也對 `ttl_ms` 上限做承諾。validator 在 queued action 的 datum entry 裡記錄 `expires_at_ms = executable_at_ms + ttl_ms`。`expires_at_ms` 之後，動作就不能再被 execute 了；queue 作者可以用一筆 cancel 來清掉那個 entry（cancel 路徑也接受過期的動作）。

TTL 上限防止「過期動作」攻擊：某筆 queue 過、但因正當理由（governance 改變方向、signer 輪替使原本的 quorum 失效）沒被 execute 的動作，如果沒有 TTL 會一直留在 queue，等著在「signer 當初評估時的條件已經不一樣」的環境下被機會性地 execute。

---

## 3. Aiken 示意

一份最小化的 GovDatum + redeemer 集合：

```aiken
type ActionKind {
  UpdateFee
  UpdateStrategy
  RotateSigners
  // ... protocol-specific action kinds
}

type QueuedAction {
  action_id: ByteArray,
  action_kind: ActionKind,
  target_script: ByteArray,
  payload_hash: ByteArray,
  queued_at_ms: Int,
  executable_at_ms: Int,
  expires_at_ms: Int,
}

type GovDatum {
  signers: List<VerificationKeyHash>,
  threshold: Int,
  queued: List<QueuedAction>,
  nonce: Int,
}

type GovRedeemer {
  QueueAction {
    action_kind: ActionKind,
    target_script: ByteArray,
    payload_hash: ByteArray,
    timelock_ms: Int,
    ttl_ms: Int,
  }
  CancelAction { action_id: ByteArray }
  ExecuteAction { action_id: ByteArray }
  RotateSignersRedeemer { new_signers: List<VerificationKeyHash>, new_threshold: Int }
}

validator multisig_gov(gov_nft_policy: PolicyId, gov_nft_name: ByteArray) {
  spend(datum: Option<GovDatum>, redeemer: GovRedeemer, own_ref, tx) {
    expect Some(old) = datum
    expect Some(cont) = find_single_continuing(tx.outputs, own_script_hash)
    expect new: GovDatum = inline_datum_of(cont)

    // Gov NFT must be preserved on the continuing output
    expect nft_count(cont.value, gov_nft_policy, gov_nft_name) == 1

    when redeemer is {
      QueueAction { action_kind, target_script, payload_hash, timelock_ms, ttl_ms } -> {
        let signed = count_signers_in_tx(tx, old.signers) >= old.threshold
        let timelock_ok = timelock_floor(action_kind) <= timelock_ms
        let action_id = derive_action_id(old.nonce, action_kind, target_script,
                                          payload_hash, ...)
        let queued_entry = QueuedAction { action_id, ... }
        and {
          signed,
          timelock_ok,
          new.nonce == old.nonce + 1,
          new.queued == list.push(old.queued, queued_entry),
          new.signers == old.signers,
          new.threshold == old.threshold,
        }
      }
      CancelAction { action_id } -> {
        let one_signed = count_signers_in_tx(tx, old.signers) >= 1
        and {
          one_signed,
          new.queued == list.filter(old.queued, fn(a) { a.action_id != action_id }),
          // signers + threshold + nonce unchanged
        }
      }
      ExecuteAction { action_id } -> {
        expect Some(action) = list.find(old.queued, fn(a) { a.action_id == action_id })
        let signed = count_signers_in_tx(tx, old.signers) >= old.threshold
        let timelock_passed = tx_lower_bound(tx) >= action.executable_at_ms
        let not_expired = tx_lower_bound(tx) <= action.expires_at_ms
        let effect_matches = verify_effect_payload_hash(tx, action.target_script, action.payload_hash)
        and {
          signed,
          timelock_passed,
          not_expired,
          effect_matches,
          new.queued == list.filter(old.queued, fn(a) { a.action_id != action_id }),
        }
      }
      RotateSignersRedeemer { new_signers, new_threshold } -> {
        // RotateSigners runs ONLY via ExecuteAction with a queued RotateSigners
        // action; this redeemer is the destination-side effect. Verify the
        // queue entry exists, timelock passed, and the new_signers / threshold
        // bundle hashes match the queued payload_hash.
        ...
      }
    }
  }
}
```

這份示意展示了四條 redeemer 路徑，加上任何 Pattern 1 + Pattern 4 的消費者都會繼承的「continuing-output NFT 檢查」。`derive_action_id` 與 `verify_effect_payload_hash` 函數是協議特定的；模式文件把它們視為必備元件，但不對具體實作做出規範。

---

## 4. 安全性質

### 4.1 門檻安全性

控制少於 `threshold` 位 signer 的攻擊者連 queue 任何動作都做不到。協議的抗入侵能力是參數化的 — 提高 `threshold` 就會嚴格增加攻擊者要在進攻面上推進所必須掌握的不同 key 數量。

### 4.2 透過 timelock 取得可偵測性

鏈在 queue 與 execute 之間提供每一筆 queued action 的公開紀錄。timelock 窗就是鏈下監控的偵測時間。模式本身不強制要監控 — 這是協議存款人與生態觀察者的運維責任 — 但 timelock 使監控成為可能。

這個機制能擋下的一類常見攻擊：governance key 被入侵後立即抽資金。即使拿到 key，攻擊者必須 queue 抽款、等過 timelock、再 execute。timelock 期間，存款人可以提款、signer 可以 cancel。如果協議是 `timelock_ms = 0`，這個窗就不存在。

### 4.3 1-of-n veto 的不對稱

cancel 路徑的 1-of-n 門檻把進攻—防守的算術倒了過來：進攻需要 m 把被入侵的 key、防守只需要 1 把沒被入侵的 key。對任何 `m ≤ n − 1` 的合理 m 與 n，防守結構上比進攻強。`m == n` 時這個不對稱會崩潰（這時沒有任何「沒被入侵的 key」夠用來防守）；模式文件因此建議 `m < n`。

### 4.4 透過嚴格單調 nonce 抗重放

用完全一樣的參數重新 queue 同一個動作會得到不同的 `action_id`（nonce 已經加 1）。攻擊者無法預先算出一條動作的雜湊鏈、再從中挑一個動作替換、之後用同一個識別碼把它塞回去。

### 4.5 Queue 與 Execute 之間 payload 的不可變性

execute 路徑驗證實際效果交易的 payload 雜湊等於 queue 時所記錄的值。漂移在結構上不可能；任何差異都會讓 execute 交易被拒絕。在 queue 上簽名的 signer 是對具體的 payload 做承諾、不是對抽象的 action kind。

### 4.6 對過期動作的 TTL 上限

timelock 過了但一直沒被 execute 的動作最終會過期。TTL 上限防止「無限懸而未決」的條目幾個月後變成「在當初評估條件已經不一樣的環境下、被機會性地 execute」的攻擊面。

### 4.7 透過同一條路徑做自我修改

`RotateSigners` 只是另一種 action kind，與其他所有動作一樣受到 threshold + timelock + payload-hash + TTL + cancel 的約束。沒有獨立的「meta」治理路徑。governance 改變自己的組成走的是「governance 改 fee 參數」用的同一套水管；少一個 validator 面、少一個 bug 機會。

這個性質 — *自我修改不是特例* — 是本模式的結構性乾淨優點之一。某些舊式治理設計會為了改 owner 集合而留一條獨立的「owner-only」路徑，這條路徑會引入一個特權面，跳開了 threshold + timelock 的保證。

---

## 5. 與替代方案的取捨

| 做法 | 抗入侵能力 | 偵測時間 | Payload 完整性 | 自我修改 |
|---|---|---|---|---|
| 單一 owner key | 等同 key 持有者 | 沒有 | 隱含 | owner 直接換 owner |
| 純 m-of-n（立即執行） | m-of-n | 沒有 | 取決於簽名工具 | 通常有獨立的 owner 路徑 |
| Token-weighted DAO 投票 | 取決於 token 供應 | 提案投票期 | Payload 承諾各家不一 | 同一路徑 |
| **m-of-n + timelock + veto + nonce + payload-hash + TTL（本模式）** | 進攻 m-of-n、防守 1-of-n | 完整的 timelock 窗 | 密碼學綁定 | 與任何其他動作走同一路徑 |
| CIP-1694 風格的鏈上 DAO 治理 | Cardano-treasury 感知、參數化 | 每個動作對應的 governance 期 | 在 ledger framework 內 | 受 constitution 約束 |

本模式做的取捨是：接受「queue+wait+execute」的操作負擔（相對於單筆 TX 立即執行），換來一份完全鏈上的審計軌跡、密碼學的 payload 綁定、與結構上不對稱的防守。對任何 pooled 資金協議來說，單一一個失誤就會造成可量化的存款人損失，這個取捨明顯划算。

本模式與 CIP-1694 風格的生態系治理是**互補**的、不是衝突的。CIP-1694 治理 Cardano ledger 層級的參數（treasury、hard-fork-initiator）；本模式治理應用層級的協議參數（fee schedule、strategy 配置、whitelist 內容）。兩者可以在同一個部署裡共存。

---

## 6. OptiVaults V1 案例研究

V1 的 MultisigGov validator 在 `contracts/validators/multisig_gov.ak`，由 Governance NFT（Pattern 1 的三個實例之一）錨定。實作約 890 行 Aiken，攜帶以下參數：

| 元件 | V1 實例 |
|---|---|
| Signer 人數 | 上線時 3 位；上限 20（`max_signers`）；強制 `threshold ≥ 2`；透過 `RotateSigners` action 輪替 signer |
| Threshold 預設 | 上線時 3-of-3；計畫在 Phase 2+ 社群治理過渡期間擴大 |
| Action kind | 14 種：`UpdateStrategy`、`UpdateFee`、`UpdateFeeSplit`（21 天 timelock）、`UpdateSlippagePolicy`（48 小時 timelock）、`EmergencyWithdraw`（0 天 timelock，外加額外保護）、`AdminDeployNonDeposit`、`UpdateRegistry`、`FastUpdateMarkets`（1 小時 timelock）、`UpdateKeeperAuth`、`TreasurySpend`、`UpdateTreasuryParams`、`RotateSigners`、`SlashBond`（Phase 3+）、`ActDeregisterStake`（stake-credential 清理） |
| 預設 timelock | 寬廣 action kind 預設 14 天；操作上時效性強的縮短（1 小時 FastUpdateMarkets、0 天 EmergencyWithdraw）；最敏感的拉長（21 天 UpdateFeeSplit） |
| Queue 容量 | 任何時刻 0..10 筆 pending action |
| Signer 補償池 | GovDatum 多一個欄位追蹤累積的 USDCx 作為 signer 補償，每季透過 keeper 可呼叫的 `DistributeSignerCompensation` 路徑分發 — 見 `spec/multisig-gov.md` §6 |
| Empty-hash 彈性目標模式 | 動作可以用 `target_tx_hash = #""`（空）來 queue，使其可以對 target script 上任何符合 payload 的 TX hash 執行；相對地，指定 32-byte target_tx_hash 則是預先承諾某顆特定 UTXO。取捨討論見 `spec/governance.md` |
| 自我修改 | `RotateSigners` 是普通的 `ActionKind` — 與其他任何動作走同一套 threshold + timelock + cancel 規則 |
| 抗 replay | `nonce` 嚴格單調、queue 時加 1。`action_id` = 對 queue 參數 + nonce 做 Blake2b-256 |
| Payload-hash 綁定 | 每個動作記錄目的端 redeemer 的 CBOR 序列化 payload 的 Blake2b-256；`vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`、`registry`、`treasury`、`keeper_stake_script` 的 execute 路徑都會驗證實際 payload 雜湊到 queued 值 |

模式文件把以下兩項 V1 特定的延伸視為「專案政策」（不是協議 primitive）：

- **每種 action kind 各自的 timelock 下限與上限。** V1 把每種 kind 的最小 + 最大 timelock 寫死（例如 UpdateStrategy 必須是 7–30 天；UpdateFeeSplit 必須 ≥ 21 天；EmergencyWithdraw 必須剛好 0 天）。這樣 queue 就無法靠把敏感動作的 `timelock_ms` 設成 0 來繞過保護。未來的 CIP 可能會把「每種 action kind 的下限/上限清單」標準化、或留給專案政策。
- **Signer 補償池 + 每季分發。** V1 包含一層操作經濟學 — signer 為了監看 + 簽名的運維負擔而被補償。這個池從協議費累積、每 90 天透過一條非 governance 路徑（`DistributeSignerCompensation`）分發，任何 signer 都可以呼叫，且有 30 分鐘的寬限窗。這是 V1 實例特定的東西；模式文件並不要求這一層。

V1 的審計歷史（Coverage area C — V1 Integration Flows；見 `docs/audit-scope.md`）對六個模式機制各自覆蓋，並驗證了每個 governance-authorised 消費端的跨 validator payload-hash 檢查。

---

## 7. 給未來 CIP 工作的待答問題

如果這個模式日後真的被提出來標準化，討論時需要解決：

1. **Action-kind timelock 下限表。** 每種 action kind 的最小 timelock 應該由協議層（被 CIP 鎖住）規範，還是由鏈下專案政策（每個部署自己挑）規範？V1 把自己的表寫死；CIP 可能會標準化。
2. **Empty-hash vs 預先承諾的 target。** 模式同時允許兩種。CIP 應該把取捨講清楚並建議預設。
3. **Signer 輪替走 governance vs 獨立路徑。** V1 把 `RotateSigners` 與其他動作走同一條路徑。某些舊式設計會為 owner 輪替留一條獨立路徑。CIP 應該選一個預設並說明理由。
4. **Signer 補償。** 補償池欄位是 V1 實例政策；CIP 可以選擇把它標準化、或留為範圍外的運維議題。
5. **與 CIP-1694 的組合。** 應用層治理（本模式）在哪裡結束、Cardano ledger 層治理（CIP-1694）從哪裡開始？兩者應該乾淨地組合；CIP 可以把組合規則文件化。
6. **命名。** 「MultisigGov」、「MultiSig Governance with Timelock」、「Queue-Execute-Cancel Pattern」在非正式的 Cardano DeFi 討論裡都出現過。CIP 會把其中之一定為標準名。

---

## 8. 另見

- `contracts/validators/multisig_gov.ak` — 參考實作
- `contracts/validators/governance_nft.ak` — Pattern 1 實例 #2（Governance NFT）
- `contracts/lib/vault/types.ak` `GovDatum` / `QueuedAction` / `ActionKind` / `GovRedeemer` — V1 的 datum + redeemer 形狀
- `spec/multisig-gov.md` — V1 的實作規格（~440 行，比本背景說明更深入）
- `spec/governance.md` — V1 公開動作的目錄（每種 action kind 的用途 + timelock + payload 形狀）
- `spec/pattern-rationale-validator-identity-nft-zh-TW.md` — Pattern 1，Gov NFT 錨定的基底
- `spec/pattern-rationale-withdraw-zero-forwarding-zh-TW.md` — Pattern 3；V1 的 gov-authorised redeemer 透過 Withdraw-Zero 被路由到 `vault_gov_policy`、`vault_gov_emergency`、`vault_admin_deploy`
- `spec/pattern-rationale-registry-auth-nft-zh-TW.md` — Pattern 4；Registry 的 `UpdateRegistry` redeemer 是 14 種 ActionKind 之中一個由本模式守的動作
- `docs/cip-readiness-posture-zh-TW.md` — 整體 CIP 立場

---

**文件狀態**：資訊性質的模式背景說明。反映 V1 在 launch readiness 階段的設計。修訂時機依循 `cip-readiness-posture-zh-TW.md` §4 所述條件。
