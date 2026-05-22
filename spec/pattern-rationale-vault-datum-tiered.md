# Pattern Rationale — VaultDatum Tiered Immutability

**Status**: informational pattern rationale. Not a CIP, not a CIP draft. See `docs/cip-readiness-posture.md` for OptiVaults V1's overall position on Cardano Improvement Proposals.

**Scope**: a recurring pattern for organising the inline datum of a singleton state UTXO into tiers — identity-immutable, governance-mutable, accounting, operational — with helper functions that enforce per-tier mutation envelopes on every redeemer. The pattern is generic; OptiVaults V1 instantiates it with a 29-field VaultDatum (case study in §6).

---

## 1. Problem

Singleton state UTXOs in non-trivial protocols accrete fields over the protocol's lifetime. A vault's datum starts with five fields, a fee-policy refactor adds three, mainnet integration adds four for accounting accuracy, a governance refactor adds three more, an oracle integration adds two — the datum reaches 20+ fields before the first external audit wraps.

A flat 20-field datum exposes three failure modes:

1. **Identity drift.** A redeemer designed to update the fee schedule accidentally rewrites the deposit token policy. The mistake is invisible in the redeemer's own logic (the redeemer only thinks about fees) but produces an unrecoverable state where the vault thinks its deposit token is different from what users hold. Heritage Cardano DeFi incidents of this shape exist.
2. **Authorization confusion.** A keeper-callable redeemer (Compound, BatchProcess) inadvertently allows the keeper to mutate a field that should only change under governance multisig. Without an enumerated "what is immutable here" check, the bug is invisible until exploited.
3. **Audit explosion.** Every redeemer must individually enumerate "what fields am I allowed to change?" and "what fields must I preserve?" — N redeemers × M fields is an O(N×M) audit surface. Mistakes are common in transitively-modified fields.

The tiered immutability pattern is a structural response. Each field is statically assigned a tier; each redeemer declares its tier scope; helper functions enforce the per-tier mutation envelope as a single line. The audit surface collapses from O(N×M) to O(N + tier_count) — each redeemer's tier scope is a small assertion, and each tier's contents are reviewed once.

---

## 2. The Pattern

Four tiers, each with distinct mutation discipline:

### 2.1 Tier 1 — Identity (immutable)

Fields whose values are baked at deploy time and **never** change over the singleton's lifetime. Typically:

- Protocol version markers
- Compile-time-anchor cross-references (governance NFT policy, registry hash, auth NFT policy)
- Token policy + token name parameters (deposit token, share token)
- External script hashes the protocol routes through (order script, registry script)

These fields exist in the datum (rather than as compile-time parameters of every validator) because they are read by validators that need them at runtime — for example, a withdraw validator that needs the deposit-token policy to verify the user is receiving the right asset out. Putting them in the datum costs one read per redeemer; putting them in the compile-time parameters of every validator costs an explosion of parameter signatures.

A single helper enforces tier 1 immutability across every non-deploy redeemer:

```aiken
pub fn check_immutable_fields(old: VaultDatum, new: VaultDatum) -> Bool {
  and {
    new.vault_version == old.vault_version,
    new.governance_policy == old.governance_policy,
    // ... one line per Tier 1 field
  }
}
```

Every redeemer except the deploy-time initialiser calls this helper. Audit reviews the helper once for completeness; reviews each redeemer for the helper-call presence.

### 2.2 Tier 2 — Governance-mutable Policy

Fields whose values change occasionally under governance authorisation (typically per the MultiSig + Timelock pattern — see Pattern 2) and remain stable between governance actions. Typically:

- Fee parameters (performance fee, early-withdraw fee, fee split)
- Strategy allocation targets
- Buffer targets, slippage caps, oracle parameters
- Operational caps (min hold time, max allocation count)

Each policy field has a dedicated update redeemer (UpdateFee, UpdateStrategy, UpdateSlippagePolicy, ...). Outside those redeemers, the policy fields are immutable.

A second helper enforces this on non-policy-changing redeemers:

```aiken
pub fn check_policy_fields_unchanged(old: VaultDatum, new: VaultDatum) -> Bool {
  and {
    new.performance_fee_bps == old.performance_fee_bps,
    // ... one line per Tier 2 field
  }
}
```

Audit reviews the helper, and reviews each non-policy redeemer for the helper call.

### 2.3 Tier 3 — Accounting

Fields that mutate on most operations as the working state of the protocol:

- Total deposits, total shares
- Idle buffer, non-deposit value
- Last-compound time, last-update-time, last-action time markers
- Strategy allocations (active percentages)
- External-protocol positions (Liqwid qToken holdings, Minswap LP positions)

There is no single "tier 3 immutability" helper. Instead, each redeemer that modifies accounting carries **redeemer-specific math invariants** verifying the delta is correct (share math, fee math, buffer constraints, allocation conservation). The tier doesn't enforce field-by-field equality; it enforces field-by-field correctness given the operation.

The pattern's contribution here is *organisational*: clearly demarcating which fields are "working state" so the per-redeemer math invariants know what they own. Identity / policy fields would never appear inside a per-redeemer math invariant.

### 2.4 Tier 4 — Operational

A small set of one-way or special-handling flags:

- Emergency freeze (`frozen: Int`, 0 → 1 one-way unless governance unfreezes)
- Community sunset trigger (`community_sunset_triggered: Int`, 0 → 1 one-way irreversible)
- Other circuit-breaker / dead-man-switch markers

Tier 4 fields have monotonicity rules: most can only transition in one direction. Validators that set a tier 4 flag verify the old datum's flag value before setting, and most redeemers preserve the flag (cannot clear it). The audit-side discipline is: every redeemer must explicitly think about whether it preserves or transitions each tier 4 flag.

---

## 3. Aiken Sketch

Datum tier organisation by code comment is the simplest implementation:

```aiken
pub type VaultDatum {
  // — Accounting (Tier 3) —
  total_deposited: Int,
  total_shares: Int,
  idle_buffer: Int,
  last_compound_time: Int,
  strategy_allocations: List<Allocation>,
  // ... other tier 3 fields

  // — Policy (Tier 2) —
  performance_fee_bps: Int,
  early_withdraw_fee_bps: Int,
  // ... other tier 2 fields

  // — Identity (Tier 1, immutable) —
  vault_version: Int,
  governance_policy: ByteArray,
  governance_name: ByteArray,
  deposit_token_policy: ByteArray,
  // ... other tier 1 fields

  // — Operational (Tier 4) —
  frozen: Int,
  community_sunset_triggered: Int,
}
```

A user-facing redeemer (Deposit) demonstrates the typical mutation envelope:

```aiken
fn validate_deposit(old: VaultDatum, new: VaultDatum, ...) -> Bool {
  and {
    // Tier 1 — identity preserved
    check_immutable_fields(old, new),
    // Tier 2 — policy preserved (Deposit doesn't change policy)
    check_policy_fields_unchanged(old, new),
    // Tier 3 — accounting math
    new.total_deposited == old.total_deposited + deposit_amount,
    new.total_shares == old.total_shares + minted_shares,
    new.idle_buffer == old.idle_buffer + deposit_amount,
    // ... other tier 3 deltas
    // Tier 4 — operational preserved
    new.frozen == old.frozen,
    new.community_sunset_triggered == old.community_sunset_triggered,
    old.frozen == 0,  // Reject if vault is frozen
  }
}
```

A governance-policy redeemer (UpdateFee) has a different shape — tier 2 partially mutates, tier 1 + tier 3 + tier 4 preserved:

```aiken
fn validate_update_fee(old: VaultDatum, new: VaultDatum, ...) -> Bool {
  and {
    // Tier 1 — identity preserved
    check_immutable_fields(old, new),
    // Tier 2 — only the fee fields change; others within tier 2 preserved
    new.performance_fee_bps == new_performance_fee_bps,  // from redeemer
    new.early_withdraw_fee_bps == new_early_withdraw_fee_bps,
    new.min_hold_seconds == new_min_hold_seconds,
    new.buffer_target_bps == old.buffer_target_bps,      // not this redeemer's job
    new.keeper_fee_bps == old.keeper_fee_bps,            // not this redeemer's job
    // ... rest of tier 2 unchanged
    // Tier 3 — accounting fully preserved
    new.total_deposited == old.total_deposited,
    // ... all tier 3 fields equal old
    // Tier 4 — operational preserved
    new.frozen == old.frozen,
    new.community_sunset_triggered == old.community_sunset_triggered,
  }
}
```

The redeemer's "tier scope" is visible from the structure: which helpers are called, which fields equal old, which fields are derived from redeemer arguments, which fields carry math invariants.

---

## 4. Security Properties

### 4.1 Identity preservation across every non-deploy redeemer

`check_immutable_fields` is called by every redeemer that produces a continuing vault output. Failure to call the helper would be a code-review red flag, easy to spot. Identity fields can therefore not drift through any single-TX redeemer execution.

The audit invariant: grep for `Deposit` / `Withdraw` / `Compound` / `BatchProcess` / ... handlers and confirm each calls `check_immutable_fields(old, new)`. V1's audit history (Coverage area C — V1 Integration Flows; see `docs/audit-scope.md`) verifies this invariant on every redeemer.

### 4.2 Policy mutation requires explicit dedicated redeemer

Tier 2 fields only mutate via UpdateFee / UpdateStrategy / UpdateSlippagePolicy / UpdateFeeSplit redeemers, each gated by the MultiSig + Timelock pattern (Pattern 2). The non-policy redeemers all call `check_policy_fields_unchanged`, so a keeper-callable Compound cannot accidentally bump the fee schedule.

### 4.3 Per-redeemer math invariants own their tier

Tier 3 accounting fields move on every operation, but each redeemer's math invariants are local to that redeemer. A Compound's invariants are about harvested yield + fee allocation + share-price preservation; a Deposit's invariants are about share-mint correctness; a Withdraw's invariants are about share-burn + receiver payout. The tier organisation prevents these invariants from leaking into each other.

A common heritage bug pattern this defends against: a Deposit handler that increments `total_deposited` correctly but accidentally also rewrites `last_compound_time` — confusing the keeper's compound schedule. With tier discipline, `last_compound_time` is tier 3 but the Deposit redeemer's math invariants don't touch it (Compound is the only redeemer that does), so an audit catches the misplacement.

### 4.4 Operational flags carry directionality

Tier 4 flags are one-way (or one-way except for a dedicated unfreeze path). Every redeemer must explicitly preserve or transition each flag. The audit invariant: each redeemer's handler grep should match each tier 4 flag exactly once.

A specific defence: `community_sunset_triggered` is a dead-man-switch flag set by a 90-day-keeper-inactivity redeemer; once set, several recall paths open up to permissionless invocation. If the flag were not protected as tier 4, a malicious redeemer could clear it after the recall was triggered, re-locking the protocol mid-recovery.

### 4.5 Auditable per-redeemer envelope

The mutation envelope of each redeemer is visible from its structure:

| Redeemer | Tier 1 | Tier 2 | Tier 3 | Tier 4 |
|---|---|---|---|---|
| Deposit | Preserved (helper) | Preserved (helper) | Mutates: total_deposited, total_shares, idle_buffer | Preserved + `frozen == 0` precondition |
| Withdraw | Preserved | Preserved | Mutates: total_deposited, total_shares, idle_buffer | Preserved (open even on frozen) |
| Compound | Preserved | Preserved | Mutates: total_deposited, last_compound_time, strategy_allocations | Preserved |
| UpdateFee | Preserved | Mutates: performance_fee_bps, early_withdraw_fee_bps, min_hold_seconds | Preserved (every Tier 3 = old) | Preserved |
| RotateSigners | Preserved | Preserved | Preserved | Preserved (governance UTXO is separate; vault datum unchanged) |
| CommunitySunset | Preserved | Preserved | Preserved (most fields) | Transitions: `frozen 0→1` + `community_sunset_triggered 0→1` |

The matrix is the audit's primary review object. Each row is one redeemer's scope; each cell is a single helper call or a small set of explicit equality / inequality checks. A bug surface is "any cell that does not match the redeemer's documented scope".

---

## 5. Trade-offs vs Alternatives

| Approach | Audit surface per redeemer | Mutation envelope visibility | Field-add cost | Helper overhead |
|---|---|---|---|---|
| Flat datum, per-redeemer enumeration | O(M) lines per redeemer | Low (must read each redeemer's source) | Touches every redeemer | None |
| Tier helpers + per-redeemer call (this pattern) | O(tier_count) lines | High (matrix-organised) | Touches only the helper | One function call per tier per redeemer |
| Separate UTXO per tier | Per-UTXO logic | High | Touches only the tier's validator | Multiple UTXOs to spend per TX |
| Datum versioning (struct deprecation + migration redeemer) | High (must handle every version) | Mixed | Adds a migration step | Migration redeemer must preserve invariants |

The trade made by tiered immutability: spend a few Plutus eval cycles on `check_immutable_fields` + `check_policy_fields_unchanged` per redeemer, in exchange for an audit surface that collapses with each redeemer added. For a datum that grows from 10 to 30 fields over the protocol's life, this trade is heavily favourable.

The pattern is **complementary** to datum versioning, not in tension. When a datum schema needs to add a new tier-1 field, the tier organisation makes the migration redeemer's scope obvious — only the new field appears in the migration's mutation envelope.

---

## 6. OptiVaults V1 Case Study

V1's VaultDatum is at `contracts/lib/vault/types.ak`, with 29 fields organised across 4 tiers:

- **Tier 1 — Identity (9 immutable fields)**: `vault_version`, `governance_policy`, `governance_name`, `deposit_token_policy`, `deposit_token_name`, `vusdcx_policy`, `order_script_hash`, `registry_hash`, `registry_auth_policy`. Helper: `check_immutable_fields` in `contracts/lib/vault/validation.ak`.
- **Tier 2 — Policy (8 governance-mutable fields)**: `performance_fee_bps`, `early_withdraw_fee_bps`, `min_hold_seconds`, `buffer_target_bps`, `keeper_fee_bps`, `gov_fee_bps`, `max_slippage_bps`, `min_swap_peg_bps`. Helper: `check_policy_fields_unchanged`. Dedicated redeemers: `UpdateFee`, `UpdateFeeSplit`, `UpdateStrategy`, `UpdateSlippagePolicy` (each gated by MultiSig + Timelock — see Pattern 2).
- **Tier 3 — Accounting (10 working-state fields)**: `total_deposited`, `total_shares`, `idle_buffer`, `non_deposit_value`, `last_compound_time`, `last_realloc_time`, `last_fee_update_time`, `last_ada_swap_time`, `strategy_allocations`, `liqwid_positions`. Each redeemer that touches accounting carries redeemer-specific math invariants (share math, fee math, buffer constraints, allocation conservation, oracle bounds).
- **Tier 4 — Operational (2 one-way flags)**: `frozen` (set 0→1 on freeze; reset only through dedicated governance redeemer), `community_sunset_triggered` (set 0→1 on 90-day-keeper-inactivity; one-way irreversible).

The helper-call discipline is enforced across the validator set:

- `check_immutable_fields` is called from **nine** call sites — seven in `validation.ak` and two in `helpers.ak`. The audit invariant verifies that every redeemer producing a continuing vault output reaches one of these call sites, and that no continuing-output redeemer skips the helper.
- `check_policy_fields_unchanged` is called by every non-policy-changing redeemer. The four policy-changing redeemers (UpdateFee, UpdateFeeSplit, UpdateStrategy, UpdateSlippagePolicy) explicitly enumerate which tier 2 fields they own.

Tier 1 contains 9 fields and is recognised in `docs/audit-scope.md`'s coverage matrix. Tier 4's `community_sunset_triggered` flag's one-way property is regression-tested at `contracts/lib/vault/tests/` (see the relevant test file's preservation checks across all non-CommunitySunset redeemers).

A worked example of the per-redeemer envelope visibility: V1's `Compound` redeemer carries the following structure in `vault_keeper_hot.ak`:

```
- check_immutable_fields(old, new)           // Tier 1
- check_policy_fields_unchanged(old, new)    // Tier 2
- Math invariants on total_deposited, last_compound_time, strategy_allocations  // Tier 3
- new.frozen == old.frozen                   // Tier 4
- new.community_sunset_triggered == old.community_sunset_triggered  // Tier 4
- old.frozen == 0                            // Tier 4 precondition: do not Compound when frozen
```

Six lines (or six small blocks) constitute the entire mutation envelope. The detailed math is in the third bullet; the tier discipline is in the surrounding five.

---

## 7. Open Questions for Future CIP Work

If this pattern is ever proposed for CIP standardisation, the discussion should resolve:

1. **Tier identification on chain.** The pattern is currently a code-organisation convention. A CIP could specify a datum-level tier marker (a leading enum field, a struct-nested tier marker), or leave it as project convention. The trade-off is decoder explicitness vs schema bloat.
2. **Helper standardisation.** `check_immutable_fields` + `check_policy_fields_unchanged` are project-written. A CIP could provide a reference Aiken library with macro / generic helpers that derive the tier checks from the datum's tier markers.
3. **Per-tier-update redeemer template.** A CIP could specify a canonical shape for redeemers that update tier 2 fields — input set, output set, helper calls in expected order. Some heritage protocols have idiosyncratic shapes that complicate cross-protocol review.
4. **Versioning interaction.** Datum-schema versioning across protocol upgrades (e.g., adding a new tier 1 field) is currently per-protocol. A CIP could provide a migration-redeemer template.
5. **Naming.** "Tiered Immutability" / "Datum Field Tiers" / "Per-Field Mutation Discipline" all appear in informal Cardano DeFi discussion. A CIP would canonicalise.

---

## 8. See Also

- `contracts/lib/vault/types.ak` — V1's `VaultDatum` definition with tier comments
- `contracts/lib/vault/validation.ak` — `check_immutable_fields` + `check_policy_fields_unchanged` helpers
- `contracts/lib/vault/helpers.ak` — additional shared validation helpers
- `spec/vault-datum.md` — V1's vault-datum specification (per-field documentation)
- `docs/audit-scope.md` Coverage area C — V1 Integration Flows audit coverage
- `spec/pattern-rationale-multisig-gov-timelock.md` — Pattern 2; gates Tier 2 mutation redeemers
- `spec/pattern-rationale-validator-identity-nft.md` — Pattern 1; the Vault NFT anchor that lets validators trust this datum
- `spec/pattern-rationale-withdraw-zero-forwarding.md` — Pattern 3; the architectural substrate that lets multiple validators share one VaultDatum
- `docs/cip-readiness-posture.md` — the overall CIP posture

---

**Document status**: informational pattern rationale. Reflects V1 design as of launch readiness. Revisions will follow the conditions stated in `cip-readiness-posture.md` §4.
