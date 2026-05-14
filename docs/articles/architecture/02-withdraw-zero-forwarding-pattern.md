# The Withdraw-Zero Forwarding Pattern: Moving Vault Logic to Staking Validators

*OptiVaults V1 Contract Architecture Series — Part 2 of 4*

---

[Part 1](./01-eutxo-vault-design-constraints.md) covered the four structural constraints when building a vault on Cardano's eUTXO: no mutable global state, every input triggers the full validator, reference script fee scales with size, and UTXOs have no native identity. This part covers OptiVaults V1's combined response to the first three — the **Withdraw-Zero Forwarding Pattern**.

V1 didn't invent this pattern. The Cardano community converged on it during the V8 / V9 era of Plutus development. But complete write-ups in any language are scarce, and V1 pushes it to the scale of 17 logic validators — a useful vehicle for showing what the pattern looks like at full size.

---

## The Concept

V1's central design choice is to move vault business logic **out of the spending validator and into staking validators**. The spending validator degenerates into a thin forwarder.

Concretely:

- The vault state UTXO still lives at a spending script address (called `vault_proxy`), but `vault_proxy`'s own logic is a single rule: **"this transaction's withdrawals must include a zero-withdraw entry against some staking validator."**
- All real business logic (deposit / withdraw / compound / batch / Liqwid supply / governance / ...) lives in staking validators.
- A staking validator is triggered by adding a "withdraw 0 ADA from this stake credential" entry to the TX. That stake credential is bound to a staking validator, which then runs.

Why does this work?

The key property is that a Cardano staking validator runs its full redeemer logic when withdrawn against, **and the TX context it sees is the same one the spending validator sees**. So the work of "validate this transaction" can be delegated from the spending validator to a staking validator — as long as the spending validator confirms "some legitimate staking validator was triggered," all business checks are done by that staking validator.

The "withdraw 0" piece sounds odd at first. It means: you create a stake credential, register it on-chain, and then in every TX that touches the vault, you add a "withdraw 0 ADA from this stake credential" entry. Withdrawing 0 ADA has no economic meaning, but it **forces the staking validator to execute**. That's the source of the pattern's name — you "withdraw 0" to make the staking validator run.

---

## vault_proxy in Practice

V1's `vault_proxy` body looks roughly like this (simplified — the real version also checks the vault NFT):

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
    // Decode which route this TX wants
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

    // Verify the TX actually triggered the corresponding staking validator
    has_zero_withdraw(tx.withdrawals, target_stake_hash)?
      && verify_vault_nft_present(tx, vault_nft_policy)?
  }
}
```

The 11 compile-time parameters (10 staking hashes + vault_nft_policy) are fixed at deployment ceremony, locking the spending validator's "list of legitimate routes" forever. `vault_proxy` is about **4.9 KB** — among the smallest logic validators in V1.

Note that `vault_proxy` **has no business logic at all**. It doesn't check deposit amounts, share-price math, or fee accounting. It cares only whether the TX is a legitimate route into one of V1's recognized staking validators. All real business validation happens inside whichever staking validator was triggered.

---

## Four Structural Benefits

Moving logic from the spending validator to staking validators yields four benefits:

### Benefit 1: Multiple logic modules share one vault UTXO

`vault_proxy` doesn't care which staking validator was triggered — it sees only "at least one legitimate zero-withdraw entry exists." So you can put deposit logic in `vault_user`, compound logic in `vault_keeper_hot`, governance logic in `vault_gov_policy`, and **all of them spend the same vault UTXO**, as long as the TX includes the right zero-withdraw entry.

This is the key response to [Part 1](./01-eutxo-vault-design-constraints.md)'s Constraint 1: the vault state UTXO remains a single UTXO (clean parallelism model), while the logic is no longer constrained to a single validator.

### Benefit 2: Breaking the 16 KB ceiling

Once the vault is split into N staking validators, each one's compiled size can be bounded under 16 KB independently. The vault's total logic has no aggregate ceiling.

V1's tightest staking validator is `vault_liqwid` (13.4 KB / ~3 KB of headroom); the largest single business module (`vault_protocol` + `vault_recall` together covering DeployToProtocol + Recall) is split into two validators of about 13 KB each. The combined size exceeds 16 KB, but split across two validators it deploys cleanly.

### Benefit 3: Reference script fee scales with what each TX actually uses

A deposit TX references only `vault_proxy` (4.9 KB) + `vault_user` (12.5 KB) — no compound, governance, or Liqwid logic. A compound TX loads `vault_proxy` + `vault_keeper_hot` + `keeper_stake_script`.

Without splitting, every TX would pay ref-script fee for the entire vault logic (which adds up to hundreds of kilobytes — far above the 16 KB ceiling). With splitting, **each TX pays only for the 17–24 KB it actually uses**.

### Benefit 4: Authorization boundaries fall out naturally

Different staking validators can carry completely different authorization rules:

- `vault_user`'s Deposit / Withdraw / CommunitySunset are **fully permissionless** — any CIP-30 wallet can trigger them.
- `vault_keeper_hot`'s Compound / RebalanceBuffer require **keeper authorization** — verified through another stake script (`keeper_stake_script`) via zero-withdraw.
- `vault_gov_policy`'s UpdateStrategy requires a **governance multisig** — verified by spending the MultisigGov UTXO.
- `vault_gov_emergency`'s EmergencyWithdraw is also governance multisig, but with a 0-day timelock (the emergency path).

These authorization rules are completely isolated from each other. To switch keeper authorization mode (e.g., GovernanceOnly → PermissionlessWithBond), you only modify `keeper_stake_script` — vault logic doesn't change, no redeployment. To add a new redeemer, you only modify the relevant staking validator; the other 16 are untouched.

---

## A Compound TX, End to End

Combining everything above into a concrete example. Compound is the keeper's regular operation: harvest Liqwid interest, deduct the 4.5% performance fee (split three ways: keeper / gov / treasury), and write the rest back to vault datum so share price rises.

The shape of a Compound TX:

```
Inputs:
  - vault UTXO (from vault_proxy address, holding the Vault NFT)
  - keeper wallet UTXO (paying fee + collateral)

Reference inputs:
  - vault_proxy script ref
  - vault_keeper_hot script ref
  - keeper_stake_script script ref
  - registry UTXO (reading protocol whitelist)

Withdrawals:
  - withdraw 0 from vault_keeper_hot stake credential
  - withdraw 0 from keeper_stake_script stake credential

Outputs:
  - new vault UTXO (back at vault_proxy address, carrying Vault NFT, updated datum)
  - keeper fee output (40% of performance fee → keeper address)
  - treasury output (60% of performance fee → treasury address)
  - keeper change

Required signers: keeper PKH
```

Validation flow:

1. **`vault_proxy` triggered** (spending the vault UTXO): decode redeemer = `UseKeeperHot`, check that the TX's withdrawals include a zero-withdraw against the `vault_keeper_hot` stake credential, and verify the vault UTXO carries the correct Vault NFT policy. Pass.
2. **`vault_keeper_hot` triggered** (via zero-withdraw): decode redeemer = `Compound { harvested, keeper_output_idx }`. Run all business checks:
   - The `total_deposited` delta is reasonable (must be ≥ harvested × (1 − performance_fee_bps / 10000))
   - The fee split matches `keeper_fee_bps` / `gov_fee_bps` / treasury ratios
   - The keeper output is correctly placed at `tx.outputs[keeper_output_idx]`, with an address corresponding to the keeper signer's PKH
   - The treasury output is sent to the `treasury_hash` address
   - All 15 immutable VaultDatum fields are unchanged
   - `last_compound_time` advances to the validity range's lower bound
3. **`keeper_stake_script` triggered** (via zero-withdraw): check that the TX is signed by the keeper PKH, and that the PKH appears in `authorized_pkhs` (in GovernanceOnly mode).

All three validators must pass independently; if any one fails, the TX is rejected.

Separation of concerns is clean: `vault_proxy` only cares about routing legitimacy, `vault_keeper_hot` only cares about business logic, `keeper_stake_script` only cares about authorization. The three are executed in the same TX (`vault_proxy` triggered by spending the vault UTXO, the other two by zero-withdraw), but their implementations are entirely independent.

---

## Summary

The core insight of the Withdraw-Zero Forwarding Pattern: **a Cardano staking validator and a spending validator see the same TX context, so validation work can be delegated from the latter to the former**. Using "withdraw 0" as the trigger mechanism, the spending validator degenerates into a router and business logic spreads across multiple staking validators.

The resulting benefits: modular logic, breaking past 16 KB, ref-script fee proportional to what each TX uses, and natural authorization isolation.

The next part answers a follow-up question: **if business logic is split across multiple staking validators, how does V1 decide how many to split it into and along which lines?** The answer is four orthogonal cuts that produce 17 logic validators — a relatively aggressive split for a Cardano vault, with concrete reasoning behind each cut.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/HY5sy8cz8s).*
