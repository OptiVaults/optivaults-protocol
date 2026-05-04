/// Production-timelock regression tests.
///
/// After the mainnet-candidate revert restored 12 Preprod 60s
/// overrides to production values, these tests pin every relevant
/// `timelock_*_ms` constant against its expected production value.
/// If anyone shrinks a constant for Preprod E2E iteration and
/// forgets to revert before mainnet, this file fails first.
///
/// `multisig_gov.min_timelock_ms` is a private switch over these
/// constants — verifying the constants is sufficient because the
/// switch arms are mechanically tied to the imported names (a
/// build-time `aiken check` failure would catch any switch-arm typo
/// pointing at the wrong constant).
///
/// Two end-to-end paths are documented inline:
///
///   - **Liqwid pool migration** = ActFastUpdateMarkets (1h, intentional
///     keeper-driven fast path).  Off-chain entry point is
///     `deploy/tools/h-update-registry.ts`.
///
///   - **Sunset stake reclaim** = ActDeregisterStake (14d, slow operator
///     path).  Off-chain entry point is `deploy/tools/a2-queue-deregister.ts`.

use vault/constants.{
  timelock_admin_deploy_ms, timelock_deregister_stake_ms, timelock_emergency_ms,
  timelock_fast_update_markets_ms, timelock_rotate_signers_ms,
  timelock_slash_bond_ms, timelock_treasury_spend_ms, timelock_update_fee_ms,
  timelock_update_fee_split_ms, timelock_update_keeper_auth_ms,
  timelock_update_registry_ms, timelock_update_slippage_policy_ms,
  timelock_update_strategy_ms, timelock_update_treasury_params_ms,
}

const ms_per_hour: Int = 3_600_000

const ms_per_day: Int = 86_400_000

// ─────────────────────────────────────────────────────────────────────
// Per-kind production timelock pins
// ─────────────────────────────────────────────────────────────────────

test prod_timelock_update_strategy() {
  timelock_update_strategy_ms == 7 * ms_per_day
}

test prod_timelock_update_fee() {
  timelock_update_fee_ms == 14 * ms_per_day
}

test prod_timelock_update_fee_split() {
  timelock_update_fee_split_ms == 21 * ms_per_day
}

test prod_timelock_emergency() {
  // Emergency response path — 0d by design.
  timelock_emergency_ms == 0
}

test prod_timelock_admin_deploy() {
  timelock_admin_deploy_ms == 7 * ms_per_day
}

test prod_timelock_update_registry() {
  timelock_update_registry_ms == 14 * ms_per_day
}

test prod_timelock_fast_update_markets() {
  // Liqwid pool-migration path. 1h is the intentional keeper-driven
  // fast lane — the keeper observes a stale `action_addr_hash` after a
  // Liqwid pool shard rotates, KeeperToggleMarket flips the stale
  // market to inactive (no timelock), then governance Queue+Execute of
  // ActFastUpdateMarkets writes the new hash within the hour.
  timelock_fast_update_markets_ms == 1 * ms_per_hour
}

test prod_timelock_update_keeper_auth() {
  timelock_update_keeper_auth_ms == 14 * ms_per_day
}

test prod_timelock_treasury_spend() {
  timelock_treasury_spend_ms == 7 * ms_per_day
}

test prod_timelock_update_treasury_params() {
  timelock_update_treasury_params_ms == 14 * ms_per_day
}

test prod_timelock_rotate_signers() {
  timelock_rotate_signers_ms == 14 * ms_per_day
}

test prod_timelock_slash_bond() {
  timelock_slash_bond_ms == 14 * ms_per_day
}

test prod_timelock_deregister_stake() {
  // A2 sunset stake-reclaim path. 14d is the intentional slow operator
  // lane — deliberate, multi-day governance window for an action with
  // permanent on-chain consequences (stake credential deregistration
  // returns the 2 ADA deposit but unbinds the staking validator).
  timelock_deregister_stake_ms == 14 * ms_per_day
}

test prod_timelock_update_slippage_policy() {
  timelock_update_slippage_policy_ms == 48 * ms_per_hour
}

// ─────────────────────────────────────────────────────────────────────
// Two-path comparison: Liqwid migration (1h) vs A2 deregister (14d)
// ─────────────────────────────────────────────────────────────────────
//
// These two tests pin the relative ordering — the keeper-driven
// Liqwid migration must always be cheaper (in wall-clock terms) than
// the operator-driven A2 sunset.  If the two ever cross, something is
// structurally wrong.

test liqwid_migration_path_faster_than_a2_deregister() {
  timelock_fast_update_markets_ms < timelock_deregister_stake_ms
}

test liqwid_migration_path_within_one_hour() {
  // Implementation detail: the off-chain `h-update-registry.ts` polls
  // for `now >= queued_at_ms + 1h` after Queue lands.  If this constant
  // grows beyond 1h, that script's polling loop must be updated to
  // match.
  timelock_fast_update_markets_ms <= 1 * ms_per_hour
}

// ─────────────────────────────────────────────────────────────────────
// Anti-regression: no constant accidentally <= 1 minute
// ─────────────────────────────────────────────────────────────────────
//
// Production has no governance action shorter than the 1h
// fast-markets path (except `timelock_emergency_ms`, which is 0 by
// design).  If a constant slips back to a 60s Preprod override, the
// affected per-kind test above would fail first; this test is a
// belt-and-braces summary so a partial regression (a few constants
// shrunk but their per-kind test commented out) still trips a clear
// "something's < 1h" signal.

test no_kind_below_one_hour_except_emergency() {
  let one_hour = 1 * ms_per_hour
  let all_kinds_safe =
    timelock_update_strategy_ms >= one_hour &&
    timelock_update_fee_ms >= one_hour &&
    timelock_update_fee_split_ms >= one_hour &&
    timelock_admin_deploy_ms >= one_hour &&
    timelock_update_registry_ms >= one_hour &&
    timelock_fast_update_markets_ms >= one_hour &&
    timelock_update_keeper_auth_ms >= one_hour &&
    timelock_treasury_spend_ms >= one_hour &&
    timelock_update_treasury_params_ms >= one_hour &&
    timelock_rotate_signers_ms >= one_hour &&
    timelock_slash_bond_ms >= one_hour &&
    timelock_deregister_stake_ms >= one_hour &&
    timelock_update_slippage_policy_ms >= one_hour
  // `timelock_emergency_ms` is intentionally 0 — exempt from this floor.
  all_kinds_safe && timelock_emergency_ms == 0
}
