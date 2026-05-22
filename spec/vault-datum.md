# OptiVaults V1 — VaultDatum Specification

*Implementation of the VaultDatum Tiered Immutability pattern (see [`pattern-rationale-vault-datum-tiered.md`](./pattern-rationale-vault-datum-tiered.md) for the generic pattern, the helper-function discipline that enforces tier boundaries on every redeemer, and open CIP design questions). V1's 29 fields are organised across four tiers — identity-immutable, governance-mutable policy, accounting, operational — with `check_immutable_fields` and `check_policy_fields_unchanged` helpers enforcing the per-tier mutation envelopes on every redeemer that produces a continuing vault output.*

**Scope**: the single UTXO datum that stores all vault-accounting state.

---

## 1. Structure

```aiken
type VaultDatum {
  // --- Tier 3 — Accounting state (mutates per-redeemer with math invariants) ---
  total_deposited: Int,           // USDCx total principal + accumulated yield (6 decimals)
  total_shares: Int,              // vUSDCx total supply
  idle_buffer: Int,               // Undeployed USDCx held at vault address
  non_deposit_value: Int,         // Value of non-deposit stable tokens (DJED, USDM) at vault, in deposit-token units
  last_compound_time: Int,        // POSIX milliseconds, Compound cooldown anchor
  last_realloc_time: Int,         // POSIX milliseconds, reallocation cooldown anchor
  last_fee_update_time: Int,      // POSIX milliseconds, UpdateFee 7-day cooldown anchor
  last_ada_swap_time: Int,     // POSIX milliseconds, SwapAda cooldown anchor (see spec/ada-swap.md)
  strategy_allocations: List<Allocation>,  // Target allocation per protocol
  liqwid_positions: List<LiqwidPosition>,  // Per-market Liqwid holdings

  // --- Tier 2 — Policy parameters (mutates only via dedicated governance redeemers) ---
  performance_fee_bps: Int,       // Performance fee in basis points, [0, 450]
  early_withdraw_fee_bps: Int,    // Early withdrawal fee in basis points
  min_hold_seconds: Int,          // Minimum post-Compound hold before Direct Withdraw
  buffer_target_bps: Int,         // Target buffer ratio (3500 = 35%)
  keeper_fee_bps: Int,            // Keeper's share of performance fee, [0, 4000]
  gov_fee_bps: Int,               // Governance signers' pool share, [0, 1000]
                                   // Treasury share is derived: 10000 - keeper_fee_bps - gov_fee_bps
  max_slippage_bps: Int,          // §5.4 P2 Tier 1 oracle-based fair-price bound, [0, 500] (5% cap)
  min_swap_peg_bps: Int,          // §5.4 P2 Tier 2 peg-floor bound, [9_300, 9_950]

  // --- Tier 1 — Identity (immutable; guarded by check_immutable_fields helper) ---
  vault_version: Int,             // V1 = 1; for debugging + version-gated off-chain tools
  governance_policy: ByteArray,   // Governance NFT policy ID
  governance_name: ByteArray,     // Governance NFT asset name
  deposit_token_policy: ByteArray,  // USDCx policy ID
  deposit_token_name: ByteArray,    // USDCx asset name ("USDCx")
  vusdcx_policy: ByteArray,         // vUSDCx minting policy hash
  order_script_hash: ByteArray,   // Order validator hash (for BatchProcess authorization)
  registry_hash: ByteArray,       // Registry validator hash
  registry_auth_policy: ByteArray,  // Registry auth NFT policy

  // --- Tier 4 — Operational flags (one-way transitions; preserved by all non-CommunitySunset / non-Emergency redeemers) ---
  frozen: Int,                          // 0 = normal operation, 1 = emergency frozen
  community_sunset_triggered: Int,      // 0 = normal, 1 = dead-man-switch fired (Phase 1, see governance.md §4.4.1)
}
```

**Total fields**: 29 (= original 26 + `last_ada_swap_time` for SwapAda + `max_slippage_bps` + `min_swap_peg_bps` for §5.4 P2 + `community_sunset_triggered` for the Phase 1 dead-man-switch, see `spec/governance.md` §4.4.1). **Immutable** (never change after deploy): **9** (8 identity anchors + `vault_version`). **Governance-mutable** (adjustable within bounds by governance action): **8** (`performance_fee_bps`, `early_withdraw_fee_bps`, `min_hold_seconds`, `buffer_target_bps`, `keeper_fee_bps`, `gov_fee_bps`, `max_slippage_bps`, `min_swap_peg_bps`, with `strategy_allocations` also governance-settable as a separate action). **Operationally mutable** (changed per keeper/user action): the 10 accounting state fields (`total_deposited`, `total_shares`, `idle_buffer`, `non_deposit_value`, 4 time anchors, `strategy_allocations`, `liqwid_positions`) and the 2 operational flags (`frozen`, `community_sunset_triggered`).

Count reconciliation: 9 immutable + 8 policy + 10 accounting + 2 operational = 29 ✓.

Two identity anchors that V1 deliberately does NOT store in the datum:

- **Keeper authorization**: there is no `keeper_pkh` field. Keeper authorization is delegated to the `keeper_stake_script` staking validator; the stake-script hash is a compile-time parameter of `vault_user`, `vault_keeper_hot`, `vault_protocol`, `vault_recall`, and `vault_liqwid` (plus indirectly via `vault_proxy`'s Withdraw-Zero route table). Changing the set of authorized keepers happens inside the stake script's own datum, with no change to VaultDatum.
- **Fee collector**: there is no `fee_collector` field. Performance-fee flow is to the `treasury` script address; the treasury-script hash is a compile-time parameter of `vault_keeper_hot` (the home of Compound; checked in the Compound redeemer's fee-output binding).

Moving these two anchors to compile-time parameters provides a strictly stronger trust property than keeping them as datum fields — an attacker who controls a malicious datum cannot swap the keeper or fee recipient, because the validators ignore the datum for these checks and look up the hard-coded values from their own script hashes.

---

## 2. Field-by-field reference

### 2.1 Tier 3 — Accounting state (10 fields)

| Field | Type | Meaning | Invariant |
|-------|------|---------|-----------|
| `total_deposited` | Int | Cumulative deposited-token principal that the vault recognizes, plus accrued yield. In deposit-token units (USDCx = 6 decimals). | `total_deposited > 0` whenever `total_shares > 0` |
| `total_shares` | Int | Total vUSDCx in circulation. | `total_shares >= 0`; `total_shares == 0` iff `total_deposited == 0` |
| `idle_buffer` | Int | Deposited-token units held at the vault address not deployed to yield sources. | `idle_buffer >= 0`; `idle_buffer <= total_deposited + non_deposit_value + Σ liqwid_principal` (upper bound on valid accounting) |
| `non_deposit_value` | Int | Value of registry-whitelisted non-deposit stable tokens held at the vault, denominated in deposit-token units 1:1. Modified only by registry-whitelisted token transfers during DeployToProtocol / RecallFromProtocol / MergeUtxo. | `non_deposit_value >= 0` |
| `last_compound_time` | Int | POSIX milliseconds timestamp of the last Compound execution. | Must progress monotonically under Compound redeemer; written value `≤ tx.validity_range.upper` with width cap `upper - lower ≤ 1h` |
| `last_realloc_time` | Int | POSIX milliseconds timestamp of the last zero-yield Compound (allocation-only update). | Same invariants as `last_compound_time` |
| `last_fee_update_time` | Int | POSIX milliseconds timestamp of the last UpdateFee governance action. | 7-day minimum cooldown between UpdateFee actions |
| `last_ada_swap_time` | Int | POSIX milliseconds timestamp of the last `SwapAda` execution. Rate-limits keeper ADA replenishment (see `spec/ada-swap.md`). | 1-hour minimum cooldown between SwapAda invocations; written value `≤ tx.validity_range.upper` with width cap `upper - lower ≤ 1h` |
| `strategy_allocations` | List<Allocation> | Target allocation per protocol — how capital should be distributed. Entries reference `protocol_name` (enum: `Liqwid`, `MinswapLP`, `SundaeSwapLP`) + `amount` + `expected_apy_bps`. | Length ≤ 10; `Σ amount + idle_buffer <= total_deposited + non_deposit_value + Σ liqwid_principal` |
| `liqwid_positions` | List<LiqwidPosition> | Per-Liqwid-market holdings. Entry = `{market_id, qtokens_held, supplied_value}`. | Length ≤ 5; `qtokens_held > 0` implies position exists; `supplied_value == 0` implies fully recalled |

### 2.2 Tier 2 — Policy parameters (8 fields)

| Field | Type | Value at V1 launch | Governance-adjustable range | Adjustable via |
|-------|------|---------------------|----------------------------|----------------|
| `performance_fee_bps` | Int | 450 (4.5%) | [0, 450] — 4.5% hard cap enforced in UpdateFee redeemer | `UpdateFee` governance action |
| `early_withdraw_fee_bps` | Int | 10 (0.1%) | [0, 100] | `UpdateFee` governance action |
| `min_hold_seconds` | Int | 60 | [0, 21600] (6 hours) — tightened from an earlier 24h cap after whitepaper review (see whitepaper §2.4 + §6.3 for rationale) | `UpdateFee` governance action |
| `buffer_target_bps` | Int | 3500 (35%) | [0, 10000] — advisory target, not strictly enforced | `UpdateStrategy` governance action (bundled with allocation changes) |
| `keeper_fee_bps` | Int | 4000 (40%) | [0, 4000] — 40% hard cap; combined with `gov_fee_bps` ≤ 5000 (50%) | `UpdateFeeSplit` governance action (21-day timelock) |
| `gov_fee_bps` | Int | 0 (disabled at launch) | [0, 1000] — 10% hard cap | `UpdateFeeSplit` governance action (21-day timelock) |

The 4.5% hard cap on `performance_fee_bps` is a contract-level invariant enforced in the UpdateFee redeemer — **governance cannot raise the fee above 4.5% under any redeemer path**. This is distinct from "4.5% is the current fee": the field is mutable in [0, 450] but cannot exceed 450 bps.

The 3-way performance-fee split (keeper / governance pool / treasury) is enforced at Compound time. The treasury share is not stored — it is computed as `10000 - keeper_fee_bps - gov_fee_bps`. Hard invariants verified by `vault_gov_policy.ak`'s UpdateFeeSplit redeemer (via the shared `validate_update_fee_split` helper):

- `0 <= keeper_fee_bps <= 4000` (keeper ≤ 40%)
- `0 <= gov_fee_bps <= 1000` (gov pool ≤ 10%)
- `keeper_fee_bps + gov_fee_bps <= 5000` (treasury floor ≥ 50%)

Phase launch roadmap (governance can adjust within the caps, subject to 21-day timelock per change):

| Phase | keeper_fee_bps | gov_fee_bps | Treasury | Activation conditions |
|-------|----------------|-------------|----------|-----------------------|
| V1 launch | 4000 (40%) | 0 (0%) | 60% | Deploy default; keeper share at validator hard cap to support open-source third-party keeper viability; gov pool disabled; gov signers unpaid at launch |
| Phase 2 | 4000 | 500 (5%) | 55% | Both: (a) TVL ≥ 500K USDCx **AND** (b) governance has executed `RotateSigners` to add at least one external (non-founder-connected) signer. Governance then executes `UpdateFeeSplit` to activate — no automatic promotion. |
| Phase 3 | 4000 | 1000 (10%) | 50% | Both: (a) TVL ≥ 2M USDCx **AND** (b) governance has executed `RotateSigners` to seat at least one community-elected signer. Governance then executes `UpdateFeeSplit` to activate. Treasury at 50% — the validator hard floor. |

**Activation is not automatic.** Each phase transition requires an explicit governance `UpdateFeeSplit` action (with its own 21-day timelock). The TVL + signer-set preconditions are policy gates the governance applies off-chain when deciding whether to queue `UpdateFeeSplit`; they are not contract-enforced. The validator only enforces the hard caps (`keeper_fee_bps ≤ 4000`, `gov_fee_bps ≤ 1000`, `sum ≤ 5000`). A governance that queued `UpdateFeeSplit` to gov_fee_bps = 500 at TVL 100K (violating the Phase 2 TVL gate as a policy) would succeed on-chain as long as the hard caps are met — the off-chain narrative discipline is what keeps the phase model meaningful.

Every fee-split change is a separate `UpdateFeeSplit` governance action with full 21-day timelock and 1-of-n cancel veto. Changes apply from the next Compound onwards — already-accrued gov pool funds retain their prior treatment until distributed.

### 2.3 Tier 1 — Identity parameters (9 immutable fields)

| Field | Value | Purpose |
|-------|-------|---------|
| `vault_version` | 1 | V1 identifier. Does not change across V1 minor upgrades (V1.x); would increment to 2 if a V2 fresh deploy redefines the vault architecture. |
| `governance_policy`, `governance_name` | (set at deploy) | Governance NFT identity. Governance authorization requires a transaction to spend a UTXO carrying this NFT. |
| `deposit_token_policy`, `deposit_token_name` | USDCx on mainnet | Deposit token identity. |
| `vusdcx_policy` | (set at deploy) | vUSDCx minting policy. |
| `order_script_hash` | (set at deploy) | Order validator hash. BatchProcess requires all consumed Order UTXOs to be at an address matching this hash. |
| `registry_hash` | (set at deploy) | Registry validator hash. DeployToProtocol / RecallFromProtocol read the Registry UTXO as a reference input whose address must match this hash. |
| `registry_auth_policy` | (set at deploy) | Registry auth NFT policy. The Registry UTXO is only trusted if it carries a token of this policy. |

### 2.4 Tier 4 — Operational flags (2 one-way fields)

| Field | Values | Effect when = 1 |
|-------|--------|-----------------|
| `frozen` | 0 (normal) / 1 (frozen) | Blocks Compound, Deposit, BatchProcess, RebalanceBuffer, SupplyToLiqwid, SwapAda. Also blocks the Supply path of `DeployToProtocol` (`deploy_token == deposit_token`), but the swap-out path (`deploy_token != deposit_token`) remains open under freeze (Layer 2 — see `governance.md` §4.4 + `docs/security-model.md` §5.4). Does **not** block Withdraw, RecallFromLiqwid, RecallFromProtocol, MergeUtxo, AdminDeployNonDeposit, EmergencyWithdraw (fund-recovery and governance-gated cleanup operations remain open). Set to 1 via `EmergencyWithdraw` governance action OR `CommunitySunset` (Phase 1 dead-man-switch). |
| `community_sunset_triggered` | 0 (normal) / 1 (sunset fired) | One-way 0 → 1 flag. Set by `CommunitySunset` (`vault_user`, permissionless, ≥ 1 vUSDCx + 90-day inactivity precondition — see `governance.md` §4.4.1). Once set, opens permissionless paths in `vault_liqwid.RecallFromLiqwid` + `vault_protocol.DeployToProtocol` Layer 2 (any signer, no keeper/governance auth required). Preserved by every other redeemer; cannot be reset to 0 by any path. |

---

## 3. Invariants checked on every redeemer

All mutating redeemers must preserve the following invariants (enforced by `lib/vault/validation.ak`):

1. **Immutable-field preservation**: the 9 immutable fields (8 identity anchors + `vault_version`) must be bit-identical between input and output datum.
2. **Non-negative accounting**: `total_shares >= 0`, `total_deposited >= 0`, `idle_buffer >= 0`, `non_deposit_value >= 0`.
3. **Share-supply consistency**: `total_shares == 0` if and only if `total_deposited == 0`. (Zero-share vault can only receive a first deposit; zero-principal vault with outstanding shares is an invalid state.)
4. **Allocation upper bound**: `(Σ strategy_allocations.amount) + idle_buffer <= total_deposited + non_deposit_value + Σ liqwid_position.supplied_value`.
5. **Maximum allocation count**: `len(strategy_allocations) <= 10`.
6. **Maximum Liqwid position count**: `len(liqwid_positions) <= 5`.
7. **Immutable-policy preservation**: the vault UTXO output must retain the Vault Identity NFT (one unit, correct policy, correct asset name).
8. **No unauthorized mint**: redeemers other than Deposit / Withdraw / BatchProcess explicitly enforce `tx.mint` is empty; yield flows never involve mint/burn.
9. **Token preservation**: every token type held by the input vault UTXO must appear in the output with quantity at least matching the input — net effect, minus any explicitly-spent quantity (e.g., `deposit_amount` subtracted from `deposit_token_policy` on DeployToProtocol).
10. **Single vault input per transaction**: unless the redeemer is `MergeUtxo`, exactly one input UTXO may be at the vault address.
11. **Validity range width cap**: redeemers that write time-anchored fields (`last_compound_time`, `last_realloc_time`, `last_fee_update_time`, `last_ada_swap_time`) must have transaction validity range width ≤ 1 hour, preventing long-window timestamp manipulation.

---

## 4. State transitions by redeemer

The following table summarizes which fields each redeemer may modify. `=` means "must equal input value"; `Δ` means "may change, subject to redeemer's own invariants".

| Redeemer | total_deposited | total_shares | idle_buffer | non_deposit_value | time anchors | strategy_allocations | liqwid_positions | frozen |
|----------|-----------------|--------------|-------------|-------------------|--------------|----------------------|------------------|--------|
| Deposit | Δ (+) | Δ (+) | Δ (+) | = | = | = | = | = |
| Withdraw | Δ (−) | Δ (−) | Δ (−) | = | = | = | = | = |
| BatchProcess | Δ | Δ | Δ | = | = | = | = | = |
| Compound (buffer-funded) | Δ (+) | = | Δ (−) | Δ | Δ last_compound_time, last_realloc_time | = | Δ | = |
| Compound (zero-yield) | = | = | = | = | Δ last_realloc_time only | Δ | = | = |
| RebalanceBuffer | = | = | Δ | = | Δ last_realloc_time | Δ | = | = |
| DeployToProtocol | = | = | Δ (−) | Δ (+ stable) | = | Δ | = | = |
| RecallFromProtocol | = | = | Δ (+ if deposit) | Δ (−) | = | Δ | = | = |
| SupplyToLiqwid | = | = | Δ (− if deposit) or Δ (− non-dep) | Δ (− if non-dep) | = | = | Δ (+) | = |
| RecallFromLiqwid | = | = | Δ (+) | = | = | = | Δ (−) | = |
| MergeUtxo | = | = | Δ (+) | Δ (+) | = | = | = | = |
| UpdateStrategy | = | = | = | = | = | Δ | = | = |
| UpdateFee | = | = | = | = | Δ last_fee_update_time | = | = | = |
| UpdateFeeSplit | = | = | = | = | Δ last_fee_update_time | = | = | = |
| EmergencyWithdraw | = | = | Δ | = | = | Δ clear | Δ clear | Δ (0 or 1) |
| AdminDeployNonDeposit | = | = | = | Δ (−) | = | = | = | = |
| SwapAda | = | = | Δ (−) | = | Δ last_ada_swap_time | = | = | = |

Any field not listed or marked `=` must be bit-identical between input and output datum. Any mutating redeemer that violates this table's `=` columns fails the validator.

---

## 5. Migration from internal verification phase (internal-verification phase)

Depositors migrating from internal-verification phase to V1 experience an account reset: they withdraw their USDCx from the internal-verification phase vault (UTXO at `addr1w9rlrur3ks0jplf8zsnk66vhfe4s8a2yn02jhut9wl9e4jg3r3lt3`) and re-deposit into the V1 vault (new UTXO at V1's `vault_proxy` address, to be announced at V1 mainnet launch). No accounting is carried over automatically — the V1 vault begins with `total_deposited = 0`, `total_shares = 0`.

Full migration protocol is described in `docs/migration.md`. Key points for depositors:

1. internal-verification phase remains operational throughout the V1 launch window
2. internal-verification phase sunset is announced with ≥ 30 days lead time ahead of its shutdown
3. Direct Withdraw from internal-verification phase continues to work; after 7 days of keeper inactivity (triggered deliberately at sunset), early-withdraw fee is waived automatically
4. internal-verification phase vault UTXO is destroyed after the last depositor exits

There is **no in-place upgrade path** from internal-verification phase to V1 — Cardano contract immutability makes this structurally impossible. Fresh deploy is the only option for a new contract surface.

---

## 6. CIP-applicability

The 4-tier organisation of `VaultDatum` (Tier 1 identity / Tier 2 policy / Tier 3 accounting / Tier 4 operational), combined with the `check_immutable_fields` and `check_policy_fields_unchanged` helpers that enforce per-tier mutation envelopes on every redeemer, is V1's instantiation of the **VaultDatum Tiered Immutability** pattern documented in [`pattern-rationale-vault-datum-tiered.md`](./pattern-rationale-vault-datum-tiered.md). The pattern is a candidate for future Cardano Improvement Proposal standardisation; V1 does not author a CIP at the V1 stage. See [`cip-readiness-posture.md`](../docs/cip-readiness-posture.md) for the overall posture.

### 6.1 What V1 inherits from the generic pattern

| Pattern property | V1 enforcement point |
|---|---|
| Tier 1 (identity) immutable across every non-deploy redeemer | `check_immutable_fields(old, new)` in `lib/vault/validation.ak` enforces equality on all 9 identity fields. Called from nine call sites — seven in `validation.ak` and two in `helpers.ak`. Every redeemer that produces a continuing vault output reaches one of these call sites |
| Tier 2 (policy) mutable only via dedicated governance redeemers | `check_policy_fields_unchanged(old, new)` enforces equality on all 8 policy fields for non-policy-changing redeemers. The four policy-changing redeemers — `UpdateFee`, `UpdateFeeSplit`, `UpdateStrategy`, `UpdateSlippagePolicy` — explicitly enumerate which subset of policy fields they own |
| Tier 3 (accounting) governed by per-redeemer math invariants | Each redeemer carries explicit deltas (share math, fee math, buffer constraints, allocation conservation, oracle bounds). The state-transition matrix in §4 above is the audit's primary review object |
| Tier 4 (operational) one-way flags preserved across non-transitioning redeemers | `frozen` and `community_sunset_triggered` are preserved by every redeemer except the small set that explicitly transitions them; the transitions are one-way (0 → 1) for `community_sunset_triggered` (irreversible) and bidirectional only via dedicated governance redeemers for `frozen` |

§3 "Invariants checked on every redeemer" + §4 "State transitions by redeemer" carry the V1-specific row-by-row reconciliation; the generic pattern's audit-surface reasoning (O(N×M) → O(N + tier_count)) in the rationale doc applies unchanged.

### 6.2 V1-specific design choices on top of the pattern

- **Two helpers, not one** — V1 separates `check_immutable_fields` (Tier 1) from `check_policy_fields_unchanged` (Tier 2) rather than collapsing them. The reason is auditability: policy-changing redeemers call only `check_immutable_fields` and then enumerate which Tier 2 fields they own, so the diff between "what does this redeemer touch in Tier 2" and "what stays equal" is visible in one read. A merged helper would force every policy-changing redeemer to inline the equality checks for the Tier 2 fields it does NOT own, doubling the audit surface.
- **Per-field bound-check helpers** — Tier 2 mutation redeemers don't just assert "new value differs from old"; they additionally enforce numerical bounds (`performance_fee_bps ∈ [0, 450]`, `min_swap_peg_bps ∈ [9_300, 9_950]`, etc.) via dedicated `validate_update_fee` / `validate_update_strategy` helpers. The bound-check helpers are V1 operational policy, not part of the generic pattern.
- **Tier 4 `community_sunset_triggered` interaction with redeemer authorization** — the one-way flag's transition opens up several normally-keeper-authorised paths to permissionless invocation. This authorization-layer coupling is a V1-specific elaboration (the generic pattern only specifies that Tier 4 flags are one-way; it does not specify what other validators do based on them).

### 6.3 Related pattern-rationale docs

- [`pattern-rationale-vault-datum-tiered.md`](./pattern-rationale-vault-datum-tiered.md) — the generic pattern (this file's primary rationale)
- [`pattern-rationale-validator-identity-nft.md`](./pattern-rationale-validator-identity-nft.md) — the Vault NFT anchor that lets other validators trust this datum (datum without the anchoring NFT could be forged at the vault address)
- [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md) — the governance mechanism that gates Tier 2 mutations
- [`pattern-rationale-withdraw-zero-forwarding.md`](./pattern-rationale-withdraw-zero-forwarding.md) — the architectural substrate that lets multiple route validators share this one datum
- [`cip-readiness-posture.md`](../docs/cip-readiness-posture.md) — overall V1 stance on Cardano Improvement Proposals
