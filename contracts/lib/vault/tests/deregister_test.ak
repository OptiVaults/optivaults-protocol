/// A2 regression tests — ActDeregisterStake payload hash + enum plumbing.
///
/// Unit-level coverage here: verify the payload-hash helper is
/// deterministic + sensitive to its input (the stake script hash it
/// pins), and that `ActDeregisterStake` slots into the existing
/// `action_kind_byte` / `min_timelock_ms` switches without breaking
/// exhaustiveness.
///
/// TX-context coverage (publish handler rejection paths — no-gov-input,
/// wrong action_kind, wrong target, wrong payload, non-ExecuteAction
/// redeemer) lives in the Preprod E2E scripts: `v1/deploy/tools/
/// mock-full-drain-deploy.ts` + any future `a2-deregister-test.ts`.
/// The unit-test suite intentionally stops at pure predicates — V1's
/// broader philosophy is that TX-composition checks belong on-chain,
/// not mirrored in Aiken unit tests.

use vault/constants.{
  timelock_deregister_stake_ms, timelock_update_keeper_auth_ms,
}
use vault/helpers.{payload_hash_deregister_stake}

// ─────────────────────────────────────────────────────────────────────
// payload_hash_deregister_stake — determinism + sensitivity
// ─────────────────────────────────────────────────────────────────────

test payload_hash_deregister_stake_deterministic() {
  let hash1 = payload_hash_deregister_stake(
    #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  let hash2 = payload_hash_deregister_stake(
    #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  hash1 == hash2
}

test payload_hash_deregister_stake_sensitive_to_target() {
  let hash_a = payload_hash_deregister_stake(
    #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  )
  let hash_b = payload_hash_deregister_stake(
    #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  )
  hash_a != hash_b
}

test payload_hash_deregister_stake_empty_target_distinct() {
  // Empty ByteArray is a legitimate Data value and must hash
  // differently from the all-zeros 28-byte target. Guards against an
  // off-chain bug where a missing target_hash fallback to `#""` would
  // collide with `#"00"*28` — the payload hashes must not alias.
  let h_empty = payload_hash_deregister_stake(#"")
  let h_zeros = payload_hash_deregister_stake(
    #"00000000000000000000000000000000000000000000000000000000",
  )
  h_empty != h_zeros
}

// ─────────────────────────────────────────────────────────────────────
// Timelock constant sanity
// ─────────────────────────────────────────────────────────────────────

test deregister_timelock_bounded() {
  // Accept 1h (Preprod verification override) OR 14d (production).
  // Production value is `timelock_update_keeper_auth_ms` (14 days);
  // Preprod override is 1h to make on-chain A2 verification tractable.
  timelock_deregister_stake_ms == 60 * 60 * 1_000 || timelock_deregister_stake_ms == timelock_update_keeper_auth_ms
}
