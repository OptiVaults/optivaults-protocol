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
//// Other audit-0426 findings (M-3 / L-2 / L-3 / L-4 / L-5 / I-1 / I-2
//// / I-3) were either accepted as defense-in-depth, already-mitigated,
//// or operational (Preprod-overrides-must-revert documentation). See
//// `contracts/SECURITY.md` and audit-0426.md for the full disposition
//// matrix.

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
