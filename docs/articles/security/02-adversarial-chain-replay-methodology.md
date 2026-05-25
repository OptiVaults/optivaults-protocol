# Adversarial Chain Replay: Turning "The Contract Should Reject" Into "The Contract Did Reject"

*OptiVaults V1 Security Design Series — Part 2 of 4*

---

[Part 1](./01-three-layer-governance-safety.md) explained why the three-layer governance safety design makes single-signer governance acceptable as a fallback. That whole argument rests on one thing: the contract-level invariants are actually executed by the validators.

This premise sounds obvious — but a reader still needs to see the evidence.

V1's unit tests and property tests run on every `aiken check`, and that's necessary engineering discipline. The problem is that this class of testing **trusts the test framework's observation**: a testbench simulates a TX context and assumes the contract's outcome there represents production ledger behavior. When the validator's code changes one line and a fixture changes one line, the red light flips to green instantly, with no external constraint preventing "the test and the thing being tested drift together."

What V1 adds is **adversarial chain replay**: hand-crafted attack TXs sent to a Preprod ceremony build of the live contract, with the contract's rejection (or worse, unexpected acceptance) recorded as TX hashes or Ogmios evaluate traces. This article covers the methodology — what it does, what it doesn't do, why it complements the other layers.

The whole protocol is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). All cited redeemers and validators are browsable there.

---

## Why Unit Tests Alone Are Not Enough

A few structural gaps:

**(a) The testbench's TX context is not the ledger's rules.** Aiken's testing framework gives validators a simplified `ScriptContext`. It covers internal validator logic but doesn't guarantee that the ledger's acceptance of the overall TX structure (CBOR serialization, reference script loading, collateral rules, CIP-69 purpose dispatch) matches the test fixtures. A TX that a validator rejects in a testbench might be rejected at an earlier stage in the live contract (for example, the ledger directly rejects CBOR structure) — meaning the test isn't covering the actual defense point.

**(b) Tests co-evolve.** The same commit changes a validator's logic and a test's expectation, and CI is green. Git history looks like "the contract was hardened," when in reality "the invariant" and "the observation of the invariant" have moved together. No external anchor challenges this co-evolution.

**(c) Cross-validator integration blind spots.** Under the Withdraw-Zero Pattern, a vault spend simultaneously runs `vault_proxy` + a staking validator + possibly multiple mint policies. Each one's unit tests cover its own logic, but cross-validator coupling (for example, `vault_proxy.withdrawal_count == 1` and the staking validator's redeemer dispatch) only surfaces on production-shaped TXs.

**(d) CIP-69 purpose observation blind spots.** PlutusV3 validators may be triggered by purposes other than the intended one (for example, sending a UTXO to the spending address corresponding to a staking validator). Unit tests typically only test the purpose the validator handles; they don't automatically test "are the other purposes actually caught by `else(_) { fail }`?"

Adversarial chain replay fills exactly these four gaps: it converts testing from "I ask the framework what the contract says" to "the ledger tells me directly what the contract says."

---

## Methodology

Each adversarial probe follows the same three steps:

```
[1] Construct the attack TX
    ├─ Start from the spec or audit finding; identify an attack vector
    │  where the validator is expected to reject.
    ├─ Build the TX in a redteam-*.ts script, deliberately violating
    │  the invariant.
    └─ Use a real Preprod ceremony deployment, real vault state, real
       ref scripts — not simulation. The TX structure is the same
       one going to the ledger.

[2] Send to the chain
    ├─ First run Ogmios evaluate to see if script execution rejects
    │  (without consuming the TX).
    └─ If evaluate passes, continue with submit; the ledger's final
       verdict is authoritative.

[3] Record the rejection trace
    ├─ Rejected → Ogmios returns a structured script-error trace
    │  identifying which validator, on which purpose, on which line
    │  failed. The corresponding TX and trace go into the log.
    └─ Unexpectedly accepted → stop immediately, this is a real
       contract bug, not a false negative.
```

The key property is: **the rejection trace on-chain is a fact certified by the ledger, not a test framework's observation**. Any subsequent auditor with the same ceremony build and the same redteam script can independently reproduce the same trace; if the contract is tampered with, reproduction fails. This independent reproducibility is the fundamental difference from unit tests.

---

## V1's Verified Defense-Layer Taxonomy

What follows is the catalogue of defense layers actually exercised on Preprod by constructing attack TXs and observing ledger rejection. **This is not a quantitative claim that "all possible attacks have been tested."** External audit remains the primary security signal. Chain replay supplies an end-to-end "construct attack TX → ledger rejects" attestation that cross-checks unit tests and property tests.

### Vault main UTXO spend (`vault_proxy.ak`)

Every TX consuming the vault state UTXO triggers the proxy first. Verified rejection conditions:

- `withdrawal_count == 1` — each main spend can dispatch only one staking validator; stuffing two staking withdrawals into one TX is rejected.
- `no_foreign_vault_datum` — a UTXO not at the proxy script address but carrying an InlineDatum-shaped `VaultDatum` is rejected from being treated as a vault.
- `is_full_drain` and NFT-burn correspondence — full-drain withdraw must also burn the vault NFT; missing the burn is rejected.
- `vault_count ∈ [2, 5]` — number of NoDatum-secondary UTXOs has an upper and lower bound; out of range is rejected.
- `all_secondary_no_datum` — under the MergeUtxo path, every secondary UTXO must be NoDatum; any secondary with a datum blocks the whole TX.

### User path (`vault_user.ak`)

A purely permissionless path — no keeper authorization needed. Verified:

- `Deposit` mint-equality (`vUSDCx mint == expected_shares`) — minting +1 over expected is rejected.
- `Deposit` `min_deposit` floor — deposits below the contract-level threshold are rejected.
- `Withdraw` burn-equality (`vUSDCx burn == -shares`) — under-burning by one is rejected.
- `verify_receiver_output` strict pkh equality check — the receiver field in the redeemer must match the actual output's recipient; cannot route USDCx elsewhere.
- `verify_receiver_output` Script-credential rejection — the receiver must be a VKey wallet, cannot point to a dead-locked script address.
- `CommunitySunset` 90-day time threshold — calling even 1 second early is rejected.

### Keeper path (`vault_keeper_hot.ak` + `vault_swap_ada.ak`)

Maps to the threat model of "a compromised keeper trying to disrupt the vault with wide time windows or unreasonable amounts." Verified:

- Every time-writing redeemer enforces validity-range width cap (`upper - now ≤ 1 hour`) — a TX claiming `upper = now + 10y` is rejected at the ledger before even reaching the validator.
- `vault_swap_ada` amount-in-range boundary (10–50 ADA per swap) — out-of-range is rejected.
- `ada_below_threshold` gate — when the vault still has ample ADA, SwapAda shouldn't fire.

### Protocol routing (`vault_protocol.ak`)

Maps to the threat model of "compromised keeper trying to redirect swap output." Verified:

- `DeployToProtocol` destination whitelist (`registry.protocol_hashes`) — routing output to a script not on the whitelist is rejected.
- SwapAdapter recipient binding — caller-level and adapter-level both confirm `expected_recipient_addr`; an attacker cannot redirect USDCx swap output within the SwapAdapter.
- Tier 2 peg-floor on adapter-committed `min_receive` — `min_receive × 10_000 ≥ deploy_amount × min_swap_peg_bps`, blocking extreme-slippage attacks like `minReceive = 1`.
- `min_order_amount` floor on non-deposit-token swap-out.

### Mint policies (`vusdcx.ak`, `vault_nft.ak`)

- `vUSDCx` single asset-name discipline — multi-asset minting under the same policy is rejected.
- `vault_nft` PlutusV3 UTXO-ref one-shot minting — the parameterized UTXO must appear in `tx.inputs`; once spent, no further minting is possible, ensuring structurally that the NFT can only ever be minted once (Part 4 covers this in depth).

### Order branch (`order.ak`)

Maps to the threat model of "attacker trying to cancel someone else's order or redirect expire refund":

- `signed_by_owner` strict signer verification on `CancelAction` — fake-owner pkh + caller-sig fails.
- `valid_refund` recipient binding on `ExpireOrder` — refund must go to original `ord.owner`; replacing with an attacker address is rejected.

### Multisig governance (`multisig_gov.ak`)

- `valid_signer_set` rotation floor (`n ≥ 3` signers) — trying to shrink the signer set to 1 or 2 is rejected.
- `time_window_ok` `lower_bound ≥ executable_at_ms` — Execute attempted one second before the timelock end is rejected.
- `payload_hash` binding — the apply-side payload must hash to the queue-recorded value; the payload cannot be silently substituted during the timelock window. `RotateSigners` + `UpdateFee` + `UpdateRegistry` + `TreasurySpend` all share this pattern.
- `is_gov_authorized` cross-validator helper — each governance-gated validator independently recomputes `expected_payload_hash`, not trusting any single-side description.

### Emergency / fee governance (`vault_gov_emergency.ak`, `vault_gov_policy.ak`)

Maps to Part 1's Layer 1 argument:

- `validate_emergency_freeze_only` (`loss_amount == 0` invariant) — `EmergencyWithdraw` can only toggle the `frozen` flag, never reduce `total_deposited`. A compromised governance key **cannot** crash the vault's datum.
- `max_performance_fee_bps` (450 bps cap) — even a fully governance-authorized `UpdateFee` is rejected if it tries to set fee above 4.5%.
- The payload-binding correspondence layer shared with `multisig_gov` — Treasury Spend / UpdateFee / RotateSigners all go through the same `is_gov_authorized` helper.

### CIP-69 purpose isolation

Each PlutusV3 validator explicitly declares the purposes it handles (for example, a staking validator declares only `withdraw` + `publish`); all other purposes are caught and rejected by `else(_) { fail "<validator>: unsupported purpose" }`.

Deliberately sending a UTXO to `payment_credential = <staking script hash>` permanently locks it — because the corresponding script has no Spend handler. Replay confirms: TXs that "deliberately use the wrong purpose" are rejected at the evaluate stage.

### Share-price invariant (`total_deposited` / `total_shares`)

Every code path that touches these two fields is strictly constrained:

- Deposit + Withdraw take the strict equalities of `calculate_shares_to_mint` / `calculate_withdraw_amount`.
- Compound only modifies `total_deposited` (yield → share price rises, by design).
- BatchProcess does per-order fair-share calculation.
- Other redeemers that should not touch ledger fields enforce `total_deposited == old.total_deposited && total_shares == old.total_shares`, guarded by helpers like `verify_protocol_fields_preserved` / `verify_liqwid_invariants` / `verify_emergency_freeze_only` / `verify_datum_unchanged`.

This invariant is particularly important — it covers the entire economic guarantee of the share token. Source review plus chain replay jointly confirm: the proportionality invariant cannot be artificially broken outside its design intent.

---

## One Deliberately Deferred Vector

The case of injecting a fake Liqwid `action_addr_hash` via `UpdateRegistry`, then routing Supply to the fake address — the corresponding defense (`vault_liqwid.SupplyToLiqwid`'s `qtoken_delta > 0` invariant: a fake action validator under each market's fixed qToken policy simply cannot mint real qToken) is covered by Aiken unit tests; chain replay is deferred because the ceremony cost (queue UpdateRegistry → wait timelock → run Supply) is high relative to the additional audit-narrative value beyond unit testing.

The deferral demonstrates the methodology's discipline: it's not "every finding must be chain-replayed," but "findings with reasonable cost-benefit are chain-replayed."

---

## What Chain Replay Does **Not** Cover

It is worth being honest about the boundaries. The following are not in chain replay's scope:

- **External system failures** (Liqwid bad debt, USDCx redemption freeze, oracle staleness) — these fall in whitepaper §5.3 / §5.2 / §5.4 risk surfaces, not contract-level defense.
- **Scenarios requiring simulating malicious-operator keeper-key compromise** — covered by source review and whitepaper §5.4 keeper risk discussion; chain replay cannot simulate "the attacker holds the keeper private key" because that's a precondition invisible to the ledger.
- **Behaviors that only surface in specific Preprod build states** — for example, partial Withdraw paths that must first Recall when the vault has fully deployed to Liqwid; this is operational flow, not security defense.

External audit remains the primary security signal. Chain replay supplements the end-to-end "construct attack TX → ledger rejects" evidence, complementing unit tests, property tests, and external audits at different coverage levels.

---

## Regression Tests Are Independently Reproducible

The most important property of this methodology: **all redteam scripts are part of the open-source release**. The scenario catalog and reproduction details live in `tests/preprod-e2e-plan.md`, distributed alongside the project under the same Apache 2.0 license.

This means:

- Auditors can re-run these scripts on new Preprod ceremony builds and independently reproduce rejection traces.
- Teams forking V1 can re-run the same adversarial battery on their deployment and confirm the forked contract preserves the same defense layers.
- Any skeptic can independently verify V1's security claims without any collaboration needed.

This "externally reproducible" property is a core piece of V1's security model: trust does not depend on the founder's or operator's promises, but on facts on the ledger any observer can inspect.

The whole approach (construct attack TX → submit to chain → record rejection as TX hash or eval trace) is also a template reusable for future V1.x and V2 audit rounds — it's not a one-time ceremony, it's a reusable tool layer in the audit pipeline.

---

## Next Article

Part 3 handles another adversarial-thinking angle: **V1 holds USDCx + DJED + USDM at once — is that diversification?** The answer is not the intuitive "yes." A multi-stablecoin configuration can defend against issuer-specific failure but not against correlation stress like an ADA flash crash. Part 3 unpacks the gap between "dual-issuer configuration" and "real diversification."

Part 4 goes deeper into the phantom-vault attack vector, complementing the Architecture series' Article 4.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/HY5sy8cz8s).*
