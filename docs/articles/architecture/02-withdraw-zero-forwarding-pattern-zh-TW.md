# Withdraw-Zero Forwarding Pattern：把 vault 邏輯搬到 staking validator

*OptiVaults V1 合約架構解說 — 第 2 篇 / 共 4 篇*

---

[第 1 篇](./01-eutxo-vault-design-constraints-zh-TW.md) 講了在 Cardano eUTXO 上做 vault 的四個結構性約束：沒有 mutable global state、每個 input 觸發完整 validator、reference script fee 與大小成正比、UTXO identity 沒有原生概念。本篇講 OptiVaults V1 對前三個約束的綜合解法:**Withdraw-Zero Forwarding Pattern**。

這個 pattern 不是 V1 發明的，Cardano 社群在 V8 / V9 era 已經演化出這套寫法。但完整解釋這個 pattern 的中文文獻不多，加上 V1 把它推到「17 個 logic validator」的規模，剛好是個展示完整面貌的好機會。

---

## Pattern 概念

V1 的核心設計選擇是把 vault 的邏輯**從 spending validator 搬到 staking validator**，spending validator 退化成一層薄薄的轉發器。

具體做法：

- vault state UTXO 仍然存在 spending script 地址（叫 `vault_proxy`），但 `vault_proxy` 本身的邏輯只有一條規則：**「這筆 TX 的 withdrawals 中，必須包含對某個 staking validator 的 zero-withdraw 條目」**。
- 完整的業務邏輯（deposit / withdraw / compound / batch / liqwid supply / governance / ...）放在 staking validator 裡。
- 觸發 staking validator 的方式是在 TX 加一個「withdraw 0 ADA from this stake credential」條目；該 stake credential 對應到 staking validator，stake validator 因此會被執行。

為什麼這樣可行？

關鍵是 Cardano 的 staking validator 在被 withdraw 時會跑完整的 redeemer 邏輯，**而它看到的 TX context 跟 spending validator 看到的是同一份**。所以「驗證 TX 的合法性」這個工作可以委託給 staking validator，只要 spending validator 確認「TX 中有合法的 staking validator 被觸發」，業務檢查就由那個 staking validator 負責。

「withdraw 0」這部分聽起來很奇怪。它的意思是：你建立一個 stake credential、把它登記到鏈上，然後在每筆涉及 vault 的 TX 中加入一個「從這個 stake credential 提領 0 ADA」的條目。提領 0 ADA 這個動作沒有任何經濟意義，但它**強制觸發 staking validator 的執行**。這就是 pattern 名稱的由來，你「withdraw 0」是為了讓 staking validator 跑起來。

---

## vault_proxy 實作示意

V1 中 `vault_proxy` 的主體大概長這樣（簡化過、實際版本還有 vault NFT 檢查）：

```aiken
validator vault_proxy(
  user_stake_hash: ByteArray,
  keeper_hot_stake_hash: ByteArray,
  swap_ada_stake_hash: ByteArray,
  protocol_stake_hash: ByteArray,
  recall_stake_hash: ByteArray,
  liqwid_stake_hash: ByteArray,
  gov_policy_stake_hash: ByteArray,
  gov_emergency_stake_hash: ByteArray,
  admin_deploy_stake_hash: ByteArray,
  batcher_stake_hash: ByteArray,
  vault_nft_policy: PolicyId,
) {
  spend(_datum, redeemer: ProxyRedeemer, _own_ref, tx) {
    // 從 redeemer 解出本筆 TX 想走哪一條路由
    let target_stake_hash = when redeemer is {
      UseUser -> user_stake_hash
      UseKeeperHot -> keeper_hot_stake_hash
      UseSwapAda -> swap_ada_stake_hash
      UseProtocol -> protocol_stake_hash
      UseRecall -> recall_stake_hash
      UseLiqwid -> liqwid_stake_hash
      UseGovPolicy -> gov_policy_stake_hash
      UseGovEmergency -> gov_emergency_stake_hash
      UseAdminDeploy -> admin_deploy_stake_hash
      UseBatcher -> batcher_stake_hash
    }

    // 確認 TX 確實觸發了對應的 staking validator
    has_zero_withdraw(tx.withdrawals, target_stake_hash)?
      && verify_vault_nft_present(tx, vault_nft_policy)?
  }
}
```

11 個編譯期參數（10 個 staking hash + vault_nft_policy）在 ceremony 部署時固定下來，從此 spending validator 內含的「合法路由清單」永遠不可變更。`vault_proxy` 大約 **4.9 KB**，是整個 V1 中最小的 logic validator 之一。

注意 `vault_proxy` **沒有任何業務邏輯**，它不檢查 deposit 金額、不驗證 share price、不管 fee。它只關心「這筆 TX 是不是合法路由到一個 V1 認可的 staking validator」。所有實際業務檢查在被觸發的那個 staking validator 裡完成。

---

## 四個結構性效益

把邏輯從 spending validator 搬到 staking validator，得到四個效益：

### 效益 1：多個邏輯模組共享同一個 vault UTXO

`vault_proxy` 不在乎是哪個 staking validator 被觸發，它只看到「至少有一個合法的 zero-withdraw 條目」。所以你可以把 deposit 邏輯放在 `vault_user`、把 compound 邏輯放在 `vault_keeper_hot`、把 governance 邏輯放在 `vault_gov_policy`，**它們都能花費同一個 vault UTXO**，只要 TX 把對應的 zero-withdraw 條目放進來。

這是回應[第 1 篇](./01-eutxo-vault-design-constraints-zh-TW.md)約束 1 的關鍵：vault state UTXO 仍然是單一 UTXO（並行模型乾淨），但邏輯不再受限於單一 validator。

### 效益 2：突破 16 KB 限制

把 vault 拆成 N 個 staking validator 之後，每個 validator 自己的編譯大小可以分別控制在 16 KB 以下，整個 vault 的總邏輯量沒有上限。

V1 中最緊的 staking validator 是 `vault_liqwid`（13.4 KB / 約 3 KB headroom）；最大的業務邏輯模組（`vault_protocol` + `vault_recall` 一起涵蓋 DeployToProtocol + Recall）拆成兩個 validator 各約 13 KB，加總超過 16 KB 但分開部署沒問題。

### 效益 3：reference script fee 跟你這次 TX 用到的功能成正比

一筆 deposit TX 只需要參考 `vault_proxy`（4.9 KB）+ `vault_user`（12.5 KB），不需要載入 compound / governance / liqwid 那些根本沒用到的 validator。一筆 compound TX 載入 `vault_proxy` + `vault_keeper_hot` + `keeper_stake_script`。

如果不拆，每筆 TX 都要付完整 vault 邏輯（加總起來會是十幾萬位元組規模、遠超 16 KB 上限）的 ref-script fee。拆分之後，**一筆 TX 只付它真的用到的那 17–24 KB**。

### 效益 4：授權邊界天然分離

不同 staking validator 可以有完全不同的授權規則：

- `vault_user` 的 Deposit / Withdraw / CommunitySunset 是**純無許可**，任何 CIP-30 錢包都能觸發。
- `vault_keeper_hot` 的 Compound / RebalanceBuffer 必須有 **keeper 簽名**，透過另一個 stake script（`keeper_stake_script`）的 zero-withdraw 來驗證。
- `vault_gov_policy` 的 UpdateStrategy 必須有**治理多簽**，透過 spending MultisigGov UTXO 來驗證。
- `vault_gov_emergency` 的 EmergencyWithdraw 也是治理多簽，但 timelock 是 0 天（緊急路徑）。

這些授權規則彼此完全隔離。要修改 keeper 授權模式（GovernanceOnly → PermissionlessWithBond），只動 `keeper_stake_script`，vault 邏輯零改動、不用重新部署。要新增一個 redeemer 也只動對應的 staking validator，其他 16 個全部不變。

---

## 一筆 Compound TX 怎麼跑

把上面所有東西接起來看一個具體例子。Compound 是 keeper 的核心定期作業：harvest Liqwid 利息、扣 4.5% 績效費（拆成 keeper / gov / treasury 三流向）、把剩下的回寫到 vault datum 讓 share price 上升。

一筆 Compound TX 的結構：

```
Inputs:
  - vault UTXO (from vault_proxy address, 持有 Vault NFT)
  - keeper wallet UTXO (付 fee + collateral)

Reference inputs:
  - vault_proxy script ref
  - vault_keeper_hot script ref
  - keeper_stake_script script ref
  - registry UTXO（讀協議白名單）

Withdrawals:
  - withdraw 0 from vault_keeper_hot stake credential
  - withdraw 0 from keeper_stake_script stake credential

Outputs:
  - new vault UTXO (回到 vault_proxy address, 攜帶 Vault NFT, 更新後的 datum)
  - keeper fee output (40% of performance fee → keeper 地址)
  - treasury output (60% of performance fee → treasury 地址)
  - keeper change

Required signers: keeper PKH
```

驗證流程：

1. **`vault_proxy` 被觸發**（spending vault UTXO）：解 redeemer = `UseKeeperHot`，檢查 TX 的 withdrawals 裡有對 `vault_keeper_hot` stake credential 的 zero-withdraw 條目，並驗證 vault UTXO 持有正確 policy 的 Vault NFT。通過。
2. **`vault_keeper_hot` 被觸發**（透過 zero-withdraw）：解 redeemer = `Compound { harvested, keeper_output_idx }`。執行所有業務檢查：
   - `total_deposited` 的差是否合理（必須 ≥ harvested × (1 − performance_fee_bps / 10000)）
   - 績效費分拆是否符合 `keeper_fee_bps` / `gov_fee_bps` / treasury 比例
   - keeper output 確實寄到 `tx.outputs[keeper_output_idx]`，地址對應 keeper signer PKH
   - treasury output 寄到 `treasury_hash` 地址
   - vault datum 的 15 個不可變欄位完全沒變
   - `last_compound_time` 推進到 validity range 的 lower bound
3. **`keeper_stake_script` 被觸發**（透過 zero-withdraw）：檢查 TX 有 keeper PKH 簽名、PKH 在 `authorized_pkhs` 清單中（GovernanceOnly 模式）。

三個 validator 各自獨立通過，TX 才會被 ledger 接受。任何一個 fail 整個 TX reject。

關注點分離很乾淨：`vault_proxy` 只關心路由是否合法、`vault_keeper_hot` 只關心業務邏輯、`keeper_stake_script` 只關心授權。三者由同一筆 TX 各自獨立執行（`vault_proxy` 由 spending vault UTXO 觸發，另外兩者由 zero-withdraw 觸發），實作彼此獨立。

---

## 小結

Withdraw-Zero Forwarding Pattern 的核心洞察是：**Cardano 的 staking validator 跟 spending validator 看到同一份 TX context，所以驗證工作可以從前者委託給後者**。利用「withdraw 0」作為觸發機制，spending validator 退化成路由器，業務邏輯散在多個 staking validator。

效益是：邏輯模組化、突破 16 KB 上限、ref-script fee 跟實際用到的功能成正比、授權邊界天然分離。

下一篇會回答：**如果業務邏輯散在多個 staking validator，V1 是怎麼決定切成幾個、沿哪條線切？** 答案是四條正交切割線，把 V1 切成 17 個 logic validator，這對 Cardano vault 而言是個相當激進的拆法，每條切割線背後都有具體理由。

---

*OptiVaults V1 是 Cardano 上的非託管多穩定幣自動收益金庫，Apache 2.0 開源於 [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol)。網站 [optivaults.app](https://optivaults.app)，社群 [Discord](https://discord.gg/HY5sy8cz8s)。*
