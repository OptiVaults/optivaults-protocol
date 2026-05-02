# Four Design Constraints for Building a Vault on Cardano's eUTXO

*OptiVaults V1 Contract Architecture Series — Part 1 of 4*

---

OptiVaults V1 is the first non-custodial stablecoin auto-yield vault on Cardano. Depositors lock USDCx and receive vUSDCx share tokens; the vault routes capital into Liqwid's DJED and USDM lending markets to earn interest, then compounds yield back into share price periodically. Every operation that touches principal is enforced by Aiken PlutusV3 contracts — the protocol operator cannot move user principal under any redeemer path.

If your background is Ethereum / Solidity ERC-4626 vaults, the equivalent on Cardano's eUTXO model will look unfamiliar at first. **The underlying model is fundamentally different.** This series explains V1's contract architecture: why it ships with 17 logic validators + 4 NFT mint policies + 1 DEX adapter (22 compiled artefacts in total), why it adopts the Withdraw-Zero Forwarding Pattern, why state lives in a single UTXO, and what problem the compile-time Vault NFT anchor solves.

This first part starts at the foundation: the four structural constraints you hit when designing a vault on eUTXO. Understanding these four constraints gives you the full context for the design choices in Parts 2–4.

The whole project is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Every file referenced in this series is browsable there.

---

## Constraint 1: No Mutable Global State

In EVM, a vault is a contract address with internal variables stored in persistent storage slots; users invoke `deposit()` / `withdraw()` functions that mutate state directly. Cardano eUTXO has nothing like that.

Your vault state must live as a **UTXO** at some script address, and every transaction is fundamentally an atomic swap: destroy the old UTXO, produce a new one. The validator's job is to check whether the diff between the old and new datum is legal.

This has several immediate design consequences:

**(a) Parallelism is bounded.** A given UTXO can be spent only once per block. If your vault state is a single UTXO, only one transaction per block can update the vault. All users trying to operate on the vault simultaneously must queue.

**(b) You can't "read" state without consuming it.** To read the vault datum, you either consume the vault UTXO as a transaction input (which updates it) or attach it as a reference input (no consumption, but you can't modify it either). There's no EVM-style intermediate state where a view function reads a slot and you decide later whether to write back.

**(c) Cross-UTXO operations require coordination.** If you spread state across multiple UTXOs (one for buffer, one for Liqwid positions, one for accounting), then operations like "Recall DJED while supplying USDM in the same TX" require all relevant UTXOs as inputs. That makes the UTXO dependency chain fragile: if any one UTXO gets spent by someone else after you build the TX, you have to rebuild from scratch.

V1's response is to keep state in a single UTXO and decouple user-level parallelism using Order UTXOs (one per user, independent). Part 4 covers the details.

---

## Constraint 2: Every Input Triggers the Full Spending Validator

A Cardano spending validator runs whenever its UTXO is consumed. The validator is essentially a predicate: "given this transaction's context, may this UTXO be spent?"

If your vault is "vault state UTXO + spending validator that checks all rules," every transaction touching the vault re-executes the entire spending validator.

The problem: **Plutus V3 has a 16 KB reference script ceiling**. Anything larger can't be deployed. A vault validator with full deposit / withdraw / compound / batch / Liqwid supply / Liqwid recall / governance / emergency logic blows past that ceiling easily.

In rough numbers, V1's core business logic adds up like this (approximate scale per logic module):

| Logic module | Approximate size |
|---|---|
| Deposit / Withdraw / sunset path | ~12 KB |
| BatchProcess (4 fold loops) | ~11 KB |
| Compound / RebalanceBuffer | ~10 KB |
| SwapAda (dual-feed oracle) | ~12 KB |
| SupplyToLiqwid / RecallFromLiqwid | ~13 KB |
| DeployToProtocol / RecallFromProtocol / MergeUtxo | ~26 KB |
| Governance actions (UpdateStrategy / Fee / FeeSplit / Emergency / AdminDeploy) | ~38 KB |

Cramming all of that into a single validator would put bytecode several times over the 16 KB ceiling — undeployable on day one. Even if you found a way to squeeze it in, the next constraint would still bite.

---

## Constraint 3: Reference Script Fee Scales with Size

Since the Conway era, Cardano charges reference scripts on a new basis: every transaction pays `min_fee_ref_script_cost_per_byte × cumulative ref-script bytes`, with a stepped cost-per-byte schedule once cumulative bytes pass a threshold.

Implication for vault design: **the larger the validator, the higher every user's fee per interaction**. A single 16 KB vault validator means every deposit / withdraw / compound transaction has to count those 16 KB toward fee calculation.

Under V1's split, a deposit transaction references only `vault_proxy` (~4.9 KB) + `vault_user` (~12.5 KB) = ~17 KB; a compound transaction references `vault_proxy` + `vault_keeper_hot` (~10.5 KB) + `keeper_stake_script` (~8.8 KB) = ~24 KB. Each individual transaction is still nontrivial in size, but **no single transaction needs to load the entirety of V1's logic** — a deposit doesn't load the emergency path; a compound doesn't load BatchProcess logic.

If you don't split, every transaction pays the ref-script fee for the full vault logic. Splitting means each transaction only pays for what it actually uses. Over the long run, this matters significantly for small depositors' cost sensitivity.

---

## Constraint 4: UTXOs Have No Native Identity

The last constraint is the subtlest.

Your vault state UTXO and any other UTXO at the same script address — produced by anyone — **look identical to the ledger**. Cardano has no native concept of "this UTXO is the real vault state." Anyone can send a UTXO to the `vault_proxy` address.

Two attack surfaces follow:

- **Phantom UTXO attacks**: an attacker creates a phantom UTXO at the `vault_proxy` address, carrying their own fabricated datum. If your indexer / frontend / other validators use script address as the criterion for "this is the vault," they'll treat the phantom UTXO as real.
- **Cross-contract trust collapse**: suppose the `vusdcx` minting policy says "shares may be minted in any TX that spends a vault UTXO." If the definition of "vault UTXO" is just "a UTXO at the vault_proxy address," an attacker can fabricate a fake vault UTXO with arbitrary datum and trick `vusdcx` into minting unbounded shares.

This problem doesn't exist on EVM, where the contract address itself confers identity. On Cardano you must add an explicit "this really is my vault" check at the architecture level.

V1's solution is the **Vault Identity NFT plus a compile-time anchor**: a PlutusV3 UTXO-ref one-shot policy mints a chain-unique NFT, and that NFT's minting policy is baked into the compile-time parameters of `vault_proxy`, `vusdcx`, and `order`. The definition of "real vault" becomes "the UTXO at this specific vault_proxy address holding this specific NFT" — and the existence of that vault_proxy address is itself contingent on its script hash containing the correct NFT policy. Part 4 walks through this three-layer anchoring in detail.

---

## V1's Response, Previewed

Combining the four constraints, V1's design equation is:

- **Constraint 1** pushes V1 toward "single vault state UTXO + Order UTXOs to decouple user-level parallelism."
- **Constraint 2** pushes V1 toward "split vault logic across multiple staking validators."
- **Constraint 3** pushes V1 toward "group splits by redeemer purpose so each TX pays only the ref-script fee for what it actually uses."
- **Constraint 4** pushes V1 toward "Vault NFT plus compile-time anchoring."

V1's combined answer to the first three constraints is the **Withdraw-Zero Forwarding Pattern**: business logic moves from spending validators into multiple staking validators; the spending validator degenerates into a thin forwarder, with the redeemer determining which staking validator to route into.

The answer to the fourth constraint is to bake the Vault NFT minting policy into the spending validators' compile-time parameters, making phantom UTXOs structurally illegitimate.

The next three parts each go deep:

- **Part 2**: How the Withdraw-Zero Forwarding Pattern works, what benefits it gives, and what a Compound TX looks like end-to-end.
- **Part 3**: How V1's 17 logic validators are partitioned along four orthogonal cuts, and what each validator owns.
- **Part 4**: The single-UTXO state model (29-field VaultDatum, 15 immutable + 14 mutable) and the compile-time Vault NFT anchor.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/4VZK6vdK4t).*
