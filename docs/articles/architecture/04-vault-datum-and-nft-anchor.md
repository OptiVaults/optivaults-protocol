# Single-UTXO State and the Compile-Time Vault NFT Anchor

*OptiVaults V1 Contract Architecture Series — Part 4 of 4*

---

[Part 1](./01-eutxo-vault-design-constraints.md) covered the four design constraints when building a vault on Cardano's eUTXO. [Part 2](./02-withdraw-zero-forwarding-pattern.md) introduced the Withdraw-Zero Forwarding Pattern. [Part 3](./03-seventeen-validators-four-cuts.md) explained why V1 splits vault logic into 17 validators.

This final part handles the last piece: **how vault state is stored, the 29-field VaultDatum split between mutable and immutable, and how the compile-time Vault NFT anchor blocks phantom-vault attacks**. This is V1's response to Part 1's Constraint 4 — "UTXOs have no native identity."

---

## Why a Single UTXO

V1 keeps the entire observable vault state in a **single UTXO** at the `vault_proxy` address. That UTXO holds:

- All undeployed USDCx (the buffer)
- All currently-held DJED / USDM positions (non-deposit tokens in flight between swaps and Liqwid supply)
- All qToken receipts from Liqwid positions
- The accounting datum (`VaultDatum`, 29 fields)
- A small ADA balance covering the minimum-UTXO requirement

Why a single UTXO instead of multiple?

The eUTXO parallelism model dictates that a given UTXO can be spent only once per block. If vault state were spread across multiple UTXOs, cross-UTXO operations (e.g., "Recall DJED while supplying USDM in the same TX") would face dependency-chain coordination problems: all relevant UTXOs would need to be inputs in the same TX, and if any one of them were spent by anyone else after you build the TX, you'd have to rebuild from scratch.

Single-UTXO state is the standard pattern for vault design on Cardano DeFi.

**The parallelism problem is handled separately**: users queue deposits and withdrawals through Order UTXOs (one per user, independent), and the keeper batches several Orders into a single BatchProcess TX that writes back to the single vault UTXO. This decouples user-level parallelism from the vault state UTXO — users placing orders don't compete for the vault UTXO, only for their own wallet UTXOs.

---

## The 29-Field VaultDatum

VaultDatum has 29 fields, partitioned into 14 mutable and 15 immutable.

### 14 mutable fields (potentially updated on each operation)

- `total_deposited` — total USDCx principal held by the vault
- `total_shares` — total supply of vUSDCx share tokens
- `idle_buffer` — undeployed USDCx, available for instant withdrawal
- `non_deposit_value` — USDCx-equivalent of non-deposit tokens (DJED / USDM / qToken) currently in the vault
- `strategy_allocations` — current capital allocation across yield protocols
- `liqwid_positions` — per-market `supplied_value` and `qtokens_held`
- `last_compound_time` — timestamp of the most recent compound
- `last_realloc_time` — timestamp of the most recent zero-yield reallocation
- `frozen` — emergency freeze flag
- `community_sunset_triggered` — Phase 1 dead-man-switch flag
- `keeper_fee_bps` / `gov_fee_bps` — the two mutable components of the 3-way fee split
- `max_slippage_bps` / `min_swap_peg_bps` — governance-tunable slippage policy

### 15 immutable fields (set at deployment, enforced unchanged on every TX by `check_immutable_fields`)

- `governance_policy` / `governance_name` — Governance NFT identity
- `vault_nft_policy` — Vault NFT identity (the compile-time anchor; see below)
- `vusdcx_policy` — share token minting policy hash
- `deposit_token_policy` / `deposit_token_name` — USDCx identity
- `keeper_pkh` — keeper identity at launch
- `fee_collector` — fee receiving address
- `performance_fee_bps` — performance fee rate (**hard cap 4.5%**)
- `early_withdraw_fee_bps` — early-withdrawal fee rate (**hard cap 1%**)
- `min_hold_seconds` — direct-withdrawal cooldown (**hard cap 6 hours**)
- `buffer_target_bps` — target buffer ratio
- `order_script_hash` / `registry_hash` — relevant contract hash identities
- `vault_version` — contract version identifier

`check_immutable_fields` is a cornerstone of V1's security model: **any TX that mutates these 15 fields is rejected by every vault staking validator**.

Put differently, the 15 immutable fields of a deployed vault are **objective properties of the deployed validator hash** — not "we promise not to change them" but "the contract structurally does not allow changes." Performance fee can never be raised above 4.5%, min_hold_seconds can never exceed 6 hours, Vault NFT identity can never be substituted — these are objectively verifiable facts anyone can check against ledger data, requiring trust in no operator promise.

---

## The Phantom-Vault Problem

Recall from [Part 1](./01-eutxo-vault-design-constraints.md)'s Constraint 4: your vault state UTXO and any other UTXO at the same script address look identical to the ledger.

A **runtime NFT check** typically looks like this:

```aiken
fn is_real_vault(utxo: Output, expected_policy: PolicyId) -> Bool {
  quantity_of(utxo.value, expected_policy, vault_nft_name) == 1
}
```

The catch: `expected_policy` is a runtime parameter. An attacker only needs to convince the indexer / frontend / other validators that "this phantom UTXO corresponds to a fake `expected_policy`," and the entire identity check is bypassed — the validator only checks "this UTXO holds an NFT matching the policy I was given," but **the policy itself can be the wrong one**.

Concretely, the attack vector looks like this:

1. The attacker observes V1's `vusdcx` minting policy: shares can be minted in a TX that spends a vault UTXO.
2. The attacker creates a phantom UTXO at the `vault_proxy` address, holding a fake NFT they minted themselves, with fabricated datum (`total_deposited = 0`, `total_shares = 0`, looking like an empty vault).
3. The attacker spends this phantom UTXO in a TX and requests `vusdcx` to mint arbitrary shares.
4. If `vusdcx` only checks "the TX spends a vault UTXO that holds an NFT" without independently verifying "the NFT's policy is the real one," the attack succeeds.

V1 needs a mechanism by which `vusdcx`, `order`, and `vault_proxy` — three independent scripts — can all **uniquely and unambiguously identify "the real vault."**

---

## The Compile-Time Vault NFT Anchor

V1's solution is to make `vault_nft_policy` a **compile-time parameter** of the validators:

```aiken
validator vault_proxy(
  // ...other stake hash parameters...
  vault_nft_policy: PolicyId,  // ← compile-time constant
) { ... }

validator vusdcx(
  vault_hash: ByteArray,
  vault_nft_policy: PolicyId,  // ← same compile-time constant
) { ... }

validator order(
  vault_hash: ByteArray,
  vault_nft_policy: PolicyId,  // ← same compile-time constant
) { ... }
```

At deployment, the ceremony runs `aiken build` and bakes `vault_nft_policy` directly into validator bytecode. **A deployed `vault_proxy` script hash uniquely corresponds to one specific `vault_nft_policy`** — you cannot reuse the same `vault_proxy` to hold an NFT under a different policy, because `vault_proxy`'s script hash itself is "the hash of the validator with that NFT policy baked in."

Furthermore, `vusdcx` and `order` both bake in **the same compile-time parameter**. The hashes of these three independent scripts are **all locked to the same vault_nft_policy**.

**To bypass this anchor, an attacker doesn't just need a fake vault UTXO — they'd need to produce a matching set of `vault_proxy` + `vusdcx` + `order` script hashes corresponding to that fake policy** — and those hashes would not match the ones V1 actually deployed on-chain. The whole stack — frontend, indexer, other validators — refuses to recognize the fake as V1:

- The frontend only knows the fixed `vault_proxy` address published on-chain.
- Indexers track only that fixed address with a UTXO carrying the specific NFT.
- Other validators (`vusdcx` / `order`) check the baked-in vault hash; the attacker's fake UTXO isn't at the address that hash corresponds to.

The whole trust chain is locked at compile time, leaving no runtime flexibility to be fooled.

---

## The Vault NFT Itself: PlutusV3 UTXO-Ref One-Shot

The final piece: for "locking" to hold, the `vault_nft_policy` must be genuinely chain-unique and unforgeable.

V1 mints the Vault NFT using the PlutusV3 UTXO-ref one-shot pattern:

```aiken
validator vault_nft(utxo_ref: OutputReference) {
  mint(_redeemer, _own_policy, tx) {
    // To mint, this specific utxo_ref must be in the inputs (consumed)
    list.any(tx.inputs, fn(i) { i.output_reference == utxo_ref })?
  }
  // burn path is unconditionally allowed
}
```

`utxo_ref` is a specific UTXO chosen at the start of the deployment ceremony (typically a plain ADA UTXO from the deploy wallet). The condition for minting the NFT is "spend this UTXO in the mint TX" — and a UTXO can only be spent once, so the NFT can only ever be minted once.

Once minted, that `utxo_ref` is consumed and can never be recreated. **No one can trigger the mint again** — not someone with the mint script source, not the deploy wallet's private key, not even a fork of all of V1. The minting capability is permanently closed at the ledger level.

This pattern wasn't invented by V1 — the Cardano community has used it for years — but V1 applies it across **three layers of anchoring**:

| Anchor | NFT | Purpose |
|---|---|---|
| Vault identity | `vault_nft` | Identifies the real vault state UTXO |
| Governance identity | `governance_nft` | Identifies the real MultisigGov UTXO (locks the UTXO that all governance actions must pass through) |
| Registry authentication | `registry_auth_nft` | Identifies the real Registry UTXO (locks the protocol whitelist) |

All three use the same PlutusV3 UTXO-ref one-shot pattern, **a much cleaner approach than the older native-script-with-deadline approach** — the latter would prevent NFT burns once the deadline expires, blocking the sunset path.

---

## Putting It Together

V1's vault state design connects up like this:

1. **A single UTXO** holds all vault state (trading off less parallelism for a clean concurrency model)
2. **A 29-field VaultDatum**, of which **15 are immutable** (key protections structurally locked at the contract level)
3. **The Vault NFT** gives the single UTXO a chain-unique identity
4. **The NFT's minting policy is baked into the compile-time parameters of three spending validators** (`vault_proxy` / `vusdcx` / `order`)
5. **The NFT itself is minted via PlutusV3 UTXO-ref one-shot**, chain-unique and unrecreatable
6. **User-level parallelism** is decoupled via Order UTXOs and BatchProcess (deposit / withdraw don't compete for the vault UTXO)

Each layer corresponds to one of Part 1's constraints: single UTXO addresses Constraint 1 (parallelism is bounded), 15 immutable fields turn many promised protections into "structurally cannot be violated," and the compile-time NFT anchor addresses Constraint 4 (UTXOs have no native identity).

---

## Series Wrap-Up

The four parts at a glance:

- **[Part 1](./01-eutxo-vault-design-constraints.md)**: Four design constraints when building a vault on Cardano's eUTXO
- **[Part 2](./02-withdraw-zero-forwarding-pattern.md)**: The Withdraw-Zero Forwarding Pattern
- **[Part 3](./03-seventeen-validators-four-cuts.md)**: Four orthogonal cuts behind the 17 validators
- **Part 4 (this article)**: Single-UTXO state and the compile-time Vault NFT anchor

OptiVaults V1's full source is open under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Internal review has covered multiple rounds with findings addressed; the test suite is a comprehensive Aiken unit + property-based fuzz suite, with randomized check iterations executed per `aiken check` pass; external third-party audit is targeted for Q2-Q3 2027.

V1 launches on mainnet with a 100,000 USDCx operational ceiling, held until third-party audit completion. The project is positioned as a Cardano DeFi public-goods reference implementation — forks, specializations, and commercial reuse are all welcome, as are adversarial reviews via GitHub Issues or [Discord](https://discord.gg/HY5sy8cz8s).

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app).*
