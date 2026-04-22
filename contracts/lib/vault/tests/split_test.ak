/// Split-boundary regression tests — vault_user + vault_keeper_hot.
///
/// Context (2026-04-22): vault_core was split into two staking validators
/// — vault_user (Deposit / Withdraw, post Phase 77d) + vault_keeper_hot
/// (Compound / RebalanceBuffer, post Phase 77b) — to make headroom for
/// an A2 `publish` handler on each half. Follow-on extractions the same
/// day: Phase 77b moved SwapAda to standalone `vault_swap_ada`; Phase
/// 77d moved BatchProcess to standalone `vault_batcher` (and let
/// vault_user drop its keeper_stake_hash param to become purely
/// permissionless). See validator files + whitepaper §9.4 + §3.1.
///
/// This file tests the pure-predicate implications of the split at the
/// unit level. TX-context tests (validator-entry rejection paths, cross-
/// validator routing, withdrawal_count invariant) live in Preprod E2E
/// scripts — V1's testing philosophy keeps TX-composition checks
/// on-chain rather than mirrored in Aiken unit tests.
///
/// What the split does NOT change:
///   - validate_deposit / validate_withdraw / validate_compound (all still
///     in lib/vault/validation.ak, shared by both halves). Already covered
///     by validation_test.ak.
///   - check_immutable_fields (shared helper, covered by validation_test).
///   - payload_hash_deregister_stake (A2 publish handler uses it on both
///     halves, already covered by deregister_test.ak).
///
/// What the split DOES introduce at the pure-predicate layer:
///   - Distinct A2 payload hashes per validator (vault_user's stake hash
///     ≠ vault_keeper_hot's stake hash, so a queued A2 ExecuteAction
///     pinning one validator's own_hash cannot accidentally execute the
///     other's deregister). This is the "sensitive_to_target" property
///     of payload_hash_deregister_stake, verified here specifically for
///     the split case.

use vault/constants.{
  ada_swap_max, ada_swap_min, ada_swap_threshold, keeper_inactive_ms,
  max_validity_range_ms, max_min_hold_seconds, one_hour_ms,
  zero_yield_cooldown_ms,
}
use vault/helpers.{payload_hash_deregister_stake}

// ─────────────────────────────────────────────────────────────────────
// A2 publish handler — per-validator isolation
//
// The published own_hash in a QueueAction (ActDeregisterStake) fixes
// which validator's stake credential is authorized for deregister. The
// payload hash must differ between vault_user + vault_keeper_hot so a
// governance action queued to deregister one cannot be replayed to
// deregister the other.
// ─────────────────────────────────────────────────────────────────────

test a2_vault_user_vs_keeper_hot_distinct_payload_hashes() {
  // Fixture values — concrete 28-byte stake hashes representative of
  // vault_user + vault_keeper_hot in a realistic deployment. The actual
  // hashes post-compile are derived from each validator's applied-
  // params bytecode; these are placeholders that exercise the payload-
  // hash determinism property.
  let vault_user_hash =
    #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let vault_keeper_hot_hash =
    #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  let user_payload = payload_hash_deregister_stake(vault_user_hash)
  let keeper_hot_payload = payload_hash_deregister_stake(vault_keeper_hot_hash)

  // Must differ — governance QueueAction for one validator cannot be
  // re-used to execute the other's Deregister.
  user_payload != keeper_hot_payload
}

test a2_vault_user_payload_hash_idempotent_same_hash() {
  // Running payload_hash_deregister_stake twice with the same input
  // yields the same output — required for QueueAction + ExecuteAction
  // to match across a 14d timelock window.
  let vault_user_hash =
    #"c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
  let h1 = payload_hash_deregister_stake(vault_user_hash)
  let h2 = payload_hash_deregister_stake(vault_user_hash)
  h1 == h2
}

// ─────────────────────────────────────────────────────────────────────
// Shared constants — both halves read these from lib/vault/constants.ak.
//
// If either half accidentally inlined a local copy during the split
// (e.g. hardcoded `3_600_000` instead of importing `one_hour_ms`), it
// would drift here independently of the other. These tests document the
// expected values so a future drift shows up as a test-suite diff, not
// as a silent on-chain behavior change.
// ─────────────────────────────────────────────────────────────────────

test shared_constants_stable_one_hour() {
  one_hour_ms == 60 * 60 * 1_000
}

test shared_constants_stable_max_validity_range() {
  // 1h validity-range width cap (R58 F-1) — enforced in
  // vault_user.Withdraw's timing check AND vault_keeper_hot.Compound
  // cooldown branches AND vault_swap_ada.SwapAda cooldown branch
  // (post-Phase-77b extraction).
  max_validity_range_ms == 60 * 60 * 1_000
}

test shared_constants_stable_keeper_inactive() {
  // 7-day keeper inactivity gate — vault_user.Withdraw reads this to
  // decide early_withdraw_fee waiver. vault_keeper_hot does not depend
  // on this constant but other validators do (governance fallback).
  keeper_inactive_ms == 7 * 24 * 60 * 60 * 1_000
}

test shared_constants_stable_zero_yield_cooldown() {
  // 10-minute on-chain minimum cooldown between zero-yield Compound
  // heartbeats — vault_keeper_hot.Compound zero-yield branch enforces
  // this. Keeper typically schedules heartbeat every 5 days off-chain
  // (operational policy, not contract constraint); the 10-min floor
  // here is the anti-grief lower bound. See whitepaper §3.4.
  zero_yield_cooldown_ms == 600_000
}

test shared_constants_stable_ada_swap_bounds() {
  // vault_swap_ada.SwapAda bounds — documented here as part of the
  // split surface. Phase 77 moved SwapAda from vault_core to
  // vault_keeper_hot along the authorization-boundary split; Phase 77b
  // extracted it into standalone vault_swap_ada (dual-feed oracle
  // reader + 6-tuple registry read hoisted out of Compound's host).
  and {
    ada_swap_min == 10_000_000,
    ada_swap_max == 50_000_000,
    ada_swap_threshold == 15_000_000,
  }
}

test shared_constants_stable_max_min_hold_seconds() {
  // 6-hour hard cap on min_hold_seconds (whitepaper §2.4 tightening).
  // vault_user.Withdraw enforces via its min_hold_ok check. Cap lives
  // in vault_gov_policy.UpdateFee which can't raise beyond this.
  max_min_hold_seconds == 6 * 60 * 60
}
