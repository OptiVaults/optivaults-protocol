/// Production-timelock regression tests.
///
/// These tests pin every timelock_*_ms constant against its expected value
/// for BOTH build modes:
///
///   - `preprod_fast_timelocks = True` (Preprod E2E ceremonies): every
///     gated timelock should resolve to 60_000 ms (60s).
///   - `preprod_fast_timelocks = False` (mainnet-candidate build): every
///     gated timelock should resolve to its production value (7d / 14d /
///     21d / 48h).
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
  preprod_fast_timelocks, timelock_admin_deploy_ms,
  timelock_deregister_stake_ms, timelock_emergency_ms,
  timelock_fast_update_markets_ms, timelock_rotate_signers_ms,
  timelock_slash_bond_ms, timelock_treasury_spend_ms, timelock_update_fee_ms,
  timelock_update_fee_split_ms, timelock_update_keeper_auth_ms,
  timelock_update_registry_ms, timelock_update_slippage_policy_ms,
  timelock_update_strategy_ms, timelock_update_treasury_params_ms,
}

const ms_per_hour: Int = 3_600_000

const ms_per_day: Int = 86_400_000

const preprod_fast_ms: Int = 60_000

// ─────────────────────────────────────────────────────────────────────
// Per-kind timelock pins (flag-aware)
// ─────────────────────────────────────────────────────────────────────

test prod_timelock_update_strategy() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      7 * ms_per_day
    }
  timelock_update_strategy_ms == expected
}

test prod_timelock_update_fee() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      14 * ms_per_day
    }
  timelock_update_fee_ms == expected
}

test prod_timelock_update_fee_split() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      21 * ms_per_day
    }
  timelock_update_fee_split_ms == expected
}

test prod_timelock_emergency() {
  // Emergency response path — 0d by design.  NOT gated by flag.
  timelock_emergency_ms == 0
}

test prod_timelock_admin_deploy() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      7 * ms_per_day
    }
  timelock_admin_deploy_ms == expected
}

test prod_timelock_update_registry() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      14 * ms_per_day
    }
  timelock_update_registry_ms == expected
}

test prod_timelock_fast_update_markets() {
  // Liqwid pool-migration path. 1h is the intentional keeper-driven
  // fast lane — the keeper observes a stale `action_addr_hash` after a
  // Liqwid pool shard rotates, KeeperToggleMarket flips the stale
  // market to inactive (no timelock), then governance Queue+Execute of
  // ActFastUpdateMarkets writes the new hash within the hour.
  // NOT gated by flag (already short by design).
  timelock_fast_update_markets_ms == 1 * ms_per_hour
}

test prod_timelock_update_keeper_auth() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      14 * ms_per_day
    }
  timelock_update_keeper_auth_ms == expected
}

test prod_timelock_treasury_spend() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      7 * ms_per_day
    }
  timelock_treasury_spend_ms == expected
}

test prod_timelock_update_treasury_params() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      14 * ms_per_day
    }
  timelock_update_treasury_params_ms == expected
}

test prod_timelock_rotate_signers() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      14 * ms_per_day
    }
  timelock_rotate_signers_ms == expected
}

test prod_timelock_slash_bond() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      14 * ms_per_day
    }
  timelock_slash_bond_ms == expected
}

test prod_timelock_deregister_stake() {
  // A2 sunset stake-reclaim path. Production: 14d (intentional slow
  // operator lane — multi-day governance window for an action with
  // permanent on-chain consequences).
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      14 * ms_per_day
    }
  timelock_deregister_stake_ms == expected
}

test prod_timelock_update_slippage_policy() {
  let expected =
    if preprod_fast_timelocks {
      preprod_fast_ms
    } else {
      48 * ms_per_hour
    }
  timelock_update_slippage_policy_ms == expected
}

// ─────────────────────────────────────────────────────────────────────
// Two-path comparison: Liqwid migration (1h) vs A2 deregister (14d)
// ─────────────────────────────────────────────────────────────────────
//
// These structural-ordering tests pin the relative ordering between
// fast-markets path and slow-deregister path. Only meaningful in
// production mode (where deregister is 14d > fast-markets 1h). In
// Preprod-fast mode deregister is 60s and the relative ordering
// inverts; that is fine for E2E ceremony work.

test liqwid_migration_path_faster_than_a2_deregister() {
  if preprod_fast_timelocks {
    True
  } else {
    timelock_fast_update_markets_ms < timelock_deregister_stake_ms
  }
}

test liqwid_migration_path_within_one_hour() {
  // Implementation detail: the off-chain `h-update-registry.ts` polls
  // for `now >= queued_at_ms + 1h` after Queue lands. If this constant
  // grows beyond 1h, that script's polling loop must be updated to
  // match. NOT gated by flag — fast_update_markets is always 1h.
  timelock_fast_update_markets_ms <= 1 * ms_per_hour
}

// ─────────────────────────────────────────────────────────────────────
// Anti-regression: no production constant accidentally <= 1 minute
// ─────────────────────────────────────────────────────────────────────
//
// In production mode, no governance action is shorter than the 1h
// fast-markets path (except `timelock_emergency_ms` = 0 by design).
// In Preprod-fast mode this invariant intentionally relaxes (most
// constants drop to 60s). This test passes trivially in preprod and
// performs the floor check in mainnet builds.

test no_kind_below_one_hour_except_emergency() {
  if preprod_fast_timelocks {
    True
  } else {
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
}
