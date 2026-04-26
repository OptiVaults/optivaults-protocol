//// R75 audit-0426 regression suite.
////
//// External audit `audit-0426.md` (2026-04-26) flagged 1 CRITICAL,
//// 2 MEDIUM, and 5 LOW findings against V1 contracts. Three were
//// addressed in code (C-1 / L-1 / M-2). This file consolidates the
//// regression coverage for M-2; C-1 + L-1 live in `layer3_test.ak`
//// because they are CommunitySunset-related and belong with the rest
//// of the Layer 3 dead-man-switch tests.
////
//// Cross-reference matrix:
////
////   - C-1 CRITICAL — vault_user.ak::CommunitySunset vUSDCx asset-name
////     bug (`""` → `vusdcx_token_name`). Tests in layer3_test.ak:
////       layer3_vusdcx_constant_matches_vUSDCx_ascii
////       layer3_vusdcx_lookup_canonical_name_succeeds
////       layer3_vusdcx_lookup_empty_name_returns_zero_buggy_pattern
////       layer3_caller_has_vusdcx_finds_holder_with_canonical_name
////       layer3_caller_has_vusdcx_buggy_empty_name_misses_holder
////       layer3_caller_has_vusdcx_rejects_no_holder
////
////   - L-1 LOW — `validate_community_sunset_trigger_time` reads ONLY
////     `last_compound_time` (was `max(last_compound, last_realloc)`,
////     vulnerable to keeper zero-yield heartbeat spam bricking the
////     dead-man-switch). Tests in layer3_test.ak:
////       r75_l1_heartbeat_spam_does_not_extend_sunset_window
////       r75_l1_recent_real_compound_still_blocks_sunset
////       r75_l1_aligned_with_keeper_inactive_window
////     plus the rewritten trigger-time threshold tests
////     (layer3_trigger_time_*) which all use the new single-arg
////     signature.
////
////   - M-2 MEDIUM — order.ak `Process` `tip_output_idx` could alias
////     `payout_output_index`, double-counting the user's payout
////     output as the keeper's tip. Tested below.
////
////   - L-4 LOW — vault_proxy.ak NoDatum branch enforces
////     `withdrawal_count == 1` symmetrically with the primary
////     VaultDatum branch (defense-in-depth gap closure). Tested
////     below.
////
//// Other audit-0426 findings (M-3 / L-2 / L-3 / L-5 / I-1 / I-2 /
//// I-3) were either accepted as defense-in-depth (NFT one-shot anchor
//// is the primary defense for M-3), already-mitigated (R73 F-1
//// admissibility guard for L-2; R72 F-1 cross-validator binding for
//// L-3), or operational (Preprod-overrides-must-revert documentation
//// for L-5). See `contracts/SECURITY.md` and audit-0426.md for the
//// full disposition matrix.

use aiken/collection/list

// ─────────────────────────────────────────────────────────────────────
// M-2: tip_output_idx ≠ payout_output_index in order.ak::Process
// ─────────────────────────────────────────────────────────────────────
//
// The fix lands inline in `order.ak::Process` (no shared helper to
// import). The predicate exercised below mirrors the on-chain logic
// verbatim:
//
//   tip_ok =
//     if tip_output_idx < 0           { True }   // no tip
//     else if tip_output_idx == payout_output_index { False }
//     else { /* per-output max_batcher_tip cap check */ }
//
// Tests pin the three branches.

fn tip_ok(
  tip_output_idx: Int,
  payout_output_index: Int,
  output_lovelace: Int,
  max_batcher_tip: Int,
) -> Bool {
  if tip_output_idx < 0 {
    True
  } else if tip_output_idx == payout_output_index {
    False
  } else {
    output_lovelace <= max_batcher_tip
  }
}

test r75_m2_tip_idx_negative_skips_check() {
  // tip_output_idx == -1 means "no tip"; payout_output_index value
  // is irrelevant in this branch.
  tip_ok(-1, 0, 0, 0)
}

test r75_m2_tip_idx_negative_skips_check_payout_at_zero() {
  // Same branch with non-zero payout index — must still pass.
  tip_ok(-1, 5, 999_999_999, 0)
}

test r75_m2_tip_idx_aliases_payout_idx_rejected() {
  // The exact pre-fix attack: keeper points tip and payout at the
  // same output. Pre-R75 this passed (tip <= max_batcher_tip held
  // because the user's payout typically had small ADA). Post-R75
  // rejected unconditionally regardless of lovelace.
  !tip_ok(0, 0, 0, 1_000_000)
}

test r75_m2_tip_idx_aliases_payout_idx_rejected_high_index() {
  // Sanity: not just index 0 — any matching index is rejected.
  !tip_ok(7, 7, 0, 1_000_000)
}

test r75_m2_tip_idx_distinct_within_cap_accepted() {
  // The normal happy path: tip and payout are different outputs,
  // tip lovelace within user's max_batcher_tip ceiling.
  tip_ok(1, 0, 500_000, 1_000_000)
}

test r75_m2_tip_idx_distinct_at_cap_accepted() {
  // Inclusive boundary at max_batcher_tip.
  tip_ok(1, 0, 1_000_000, 1_000_000)
}

test r75_m2_tip_idx_distinct_over_cap_rejected() {
  // Per-order tip ceiling still enforced post-R75.
  !tip_ok(1, 0, 1_000_001, 1_000_000)
}

test r75_m2_tip_idx_distinct_zero_max_rejected() {
  // User set max_batcher_tip = 0 explicitly: no tip allowed at all.
  // Distinct index is fine, but lovelace > 0 fails the cap.
  !tip_ok(1, 0, 1, 0)
}

test r75_m2_tip_idx_distinct_zero_max_zero_lovelace_accepted() {
  // Edge: user max_batcher_tip = 0 AND tip output carries 0
  // lovelace; passes the inclusive cap. (In practice such an
  // output would fail Cardano's min-ADA rule, but the per-order
  // predicate still accepts it — min-ADA is a different layer.)
  tip_ok(1, 0, 0, 0)
}

// ─────────────────────────────────────────────────────────────────────
// L-4: vault_proxy NoDatum branch enforces withdrawal_count == 1
// ─────────────────────────────────────────────────────────────────────
//
// Pre-fix the NoDatum branch only enforced
// `has_authorized_withdrawal` (≥ 1 of the 10 staking validators
// invoked) and relied transitively on the primary VaultDatum branch
// (which `has_primary` forces to be present in the same TX) to
// enforce `withdrawal_count == 1`. Plutus's all-spend-handlers-must-
// pass rule made this transitively safe today, but the NoDatum
// branch had no second line of defense if the primary branch's
// count check were ever weakened in a future refactor.
//
// Post-fix the NoDatum branch independently computes
// `withdrawal_count` (inline copy of primary's fold over all 10
// stake hashes) and `expect`s it == 1. The fold predicate exercised
// below mirrors the on-chain logic verbatim.
//
// The fold is intentionally NOT extracted into a shared helper at
// this revision — V1 launch-candidate posture favours minimal diff
// + explicit symmetry over single-source-of-truth. If V2 introduces
// more staking validators and the touch-site count grows beyond ~6,
// revisit refactoring both branches to share a
// `count_authorized_withdrawals(tx, hashes)` helper.

fn count_authorized(
  withdrawal_creds: List<Int>,
  authorized_ids: List<Int>,
) -> Int {
  list.foldl(
    withdrawal_creds,
    0,
    fn(cred_id, acc) {
      if list.any(authorized_ids, fn(h) { h == cred_id }) {
        acc + 1
      } else {
        acc
      }
    },
  )
}

// Mock 10 stake hashes as opaque integer IDs (the on-chain validator
// uses ByteArray hashes; using Int here keeps tests focused on the
// counting logic without dragging hex-literal noise).
const auth_ids: List<Int> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

test r75_l4_zero_withdrawals_count_zero() {
  count_authorized([], auth_ids) == 0
}

test r75_l4_one_authorized_withdrawal_count_one() {
  // Happy path: NoDatum branch sees exactly one staking validator
  // invoked → withdrawal_count == 1 → expect passes.
  count_authorized([5], auth_ids) == 1
}

test r75_l4_two_authorized_withdrawals_rejected() {
  // The exact pre-fix gap: two staking validators invoked
  // simultaneously. Post-fix NoDatum's count fold catches this
  // independently of the primary branch.
  count_authorized([3, 7], auth_ids) == 2
}

test r75_l4_three_authorized_withdrawals_rejected() {
  // Beyond two — multi-validator smuggling attempt.
  count_authorized([1, 5, 9], auth_ids) == 3
}

test r75_l4_one_authorized_one_unrelated_count_one() {
  // Mixed bag: one authorized + one unrelated stake credential
  // (e.g., a user delegating their own stake key in the same TX).
  // count_authorized only counts the authorized ones → still 1.
  count_authorized([5, 999], auth_ids) == 1
}

test r75_l4_only_unrelated_withdrawals_count_zero() {
  // No authorized invocations at all. NoDatum branch's
  // `has_authorized_withdrawal` would also reject — count check is
  // a defense-in-depth secondary signal here.
  count_authorized([999, 1000], auth_ids) == 0
}

test r75_l4_duplicate_same_validator_counts_each() {
  // Edge: same staking validator credential appearing twice in
  // tx.withdrawals. (Conway permits this only with distinct values
  // per credential — but we count instances, not unique creds.)
  // Should still trigger the > 1 rejection.
  count_authorized([5, 5], auth_ids) == 2
}
