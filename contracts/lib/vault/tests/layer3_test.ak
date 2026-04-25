//// Layer 3 — Dead-man-switch / CommunitySunset (2026-04-25).
////
//// Phase 1 governance-safety design layer 3: permissionless recovery
//// path triggerable by any vUSDCx holder when the vault has been
//// operationally inactive for ≥ 90 days. Closes the failure mode
//// where founder + governance both fail and Liqwid funds are
//// otherwise stranded.
////
//// On-chain layout:
////   - VaultDatum +1 field `community_sunset_triggered: Int` (0/1)
////   - vault_user.ak +1 redeemer `CommunitySunset`
////   - vault_recall.RecallFromLiqwid + vault_protocol.DeployToProtocol
////     bypass keeper auth when `community_sunset_triggered == 1`
////
//// Tests below exercise the two pure helpers
//// (validate_community_sunset_trigger_time +
//// validate_community_sunset_transition) directly. The full TX-level
//// gate (caller has vUSDCx + lower-bound bound to validity_range)
//// lives in vault_user.ak and is integration-tested via Preprod E2E.

use vault/tests/datum_helpers.{baseline_datum}
use vault/types.{LiqwidPosition, VaultDatum}
use vault/validation.{
  validate_community_sunset_transition, validate_community_sunset_trigger_time,
}

// 1 day in milliseconds
const day_ms = 86_400 * 1_000

// 90-day inactivity threshold (matches helper)
const inactivity_ms = 90 * day_ms

// Reference activity timestamp (well above min_valid_timestamp_ms 2023-11-14)
const ref_now = 1_780_000_000_000  // 2026-05-29

// ─────────────────────────────────────────────────────────────────────
// Trigger-time threshold tests
// ─────────────────────────────────────────────────────────────────────

test layer3_trigger_time_accepts_exact_90d_inactivity() {
  let last_compound = ref_now - inactivity_ms
  let last_realloc = ref_now - inactivity_ms
  validate_community_sunset_trigger_time(last_compound, last_realloc, ref_now)
}

test layer3_trigger_time_accepts_more_than_90d_inactivity() {
  let last_compound = ref_now - inactivity_ms - 30 * day_ms  // 120d ago
  let last_realloc = ref_now - inactivity_ms - 30 * day_ms
  validate_community_sunset_trigger_time(last_compound, last_realloc, ref_now)
}

test layer3_trigger_time_rejects_89d_inactivity() {
  let last_compound = ref_now - 89 * day_ms
  let last_realloc = ref_now - 89 * day_ms
  !validate_community_sunset_trigger_time(last_compound, last_realloc, ref_now)
}

test layer3_trigger_time_rejects_one_day_short() {
  // 89 days, 23 hours
  let last_compound = ref_now - inactivity_ms + day_ms
  let last_realloc = ref_now - inactivity_ms + day_ms
  !validate_community_sunset_trigger_time(last_compound, last_realloc, ref_now)
}

test layer3_trigger_time_uses_max_anchor_realloc_recent() {
  // last_compound 100d ago, last_realloc 30d ago → max = realloc = 30d
  // → 30d < 90d → reject (recent activity)
  let last_compound = ref_now - 100 * day_ms
  let last_realloc = ref_now - 30 * day_ms
  !validate_community_sunset_trigger_time(last_compound, last_realloc, ref_now)
}

test layer3_trigger_time_uses_max_anchor_compound_recent() {
  // Symmetric: last_compound 5d ago, last_realloc 200d ago → max = compound
  let last_compound = ref_now - 5 * day_ms
  let last_realloc = ref_now - 200 * day_ms
  !validate_community_sunset_trigger_time(last_compound, last_realloc, ref_now)
}

test layer3_trigger_time_both_old_accepts() {
  let last_compound = ref_now - 100 * day_ms
  let last_realloc = ref_now - 95 * day_ms
  // max = realloc = 95d > 90d → accept
  validate_community_sunset_trigger_time(last_compound, last_realloc, ref_now)
}

test layer3_trigger_time_rejects_zero_baseline() {
  // Defensive: a corrupt or unset timestamp (= 0) must NOT let any
  // TX trigger sunset prematurely. Sanity bound 1_700_000_000_000
  // (2023-11-14) catches this.
  let last_compound = 0
  let last_realloc = 0
  !validate_community_sunset_trigger_time(last_compound, last_realloc, ref_now)
}

test layer3_trigger_time_rejects_pre_2023_baseline() {
  // Any timestamp before 2023-11-14 should be rejected as obviously
  // invalid (V1 launches well after this date).
  let last_compound = 1_500_000_000_000  // 2017-07
  let last_realloc = 1_500_000_000_000
  !validate_community_sunset_trigger_time(last_compound, last_realloc, ref_now)
}

// ─────────────────────────────────────────────────────────────────────
// Datum transition tests
// ─────────────────────────────────────────────────────────────────────

test layer3_transition_accepts_pure_freeze_and_sunset_flip() {
  let old = baseline_datum()
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
    }
  validate_community_sunset_transition(old, new)
}

test layer3_transition_accepts_with_existing_positions() {
  let pos =
    LiqwidPosition { market_id: 0, qtokens_held: 18_455_676_369, supplied_value: 546_100_000 }
  let old = VaultDatum { ..baseline_datum(), liqwid_positions: [pos] }
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
    }
  validate_community_sunset_transition(old, new)
}

test layer3_transition_rejects_already_triggered() {
  // One-way: cannot re-fire if already triggered.
  let old = VaultDatum { ..baseline_datum(), community_sunset_triggered: 1 }
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
    }
  !validate_community_sunset_transition(old, new)
}

test layer3_transition_rejects_no_freeze_flip() {
  // Must atomically set frozen=1 alongside sunset_triggered=1.
  let old = baseline_datum()
  let new =
    VaultDatum {
      ..old,
      frozen: 0,
      community_sunset_triggered: 1,
    }
  !validate_community_sunset_transition(old, new)
}

test layer3_transition_rejects_no_sunset_flip() {
  // Must atomically set community_sunset_triggered=1 (otherwise
  // it's a regular freeze that shouldn't be using this redeemer).
  let old = baseline_datum()
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 0,
    }
  !validate_community_sunset_transition(old, new)
}

test layer3_transition_rejects_total_deposited_change() {
  let old = baseline_datum()
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
      total_deposited: old.total_deposited - 1,
    }
  !validate_community_sunset_transition(old, new)
}

test layer3_transition_rejects_total_shares_change() {
  let old = baseline_datum()
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
      total_shares: old.total_shares - 1,
    }
  !validate_community_sunset_transition(old, new)
}

test layer3_transition_rejects_idle_buffer_change() {
  let old = baseline_datum()
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
      idle_buffer: old.idle_buffer + 1,
    }
  !validate_community_sunset_transition(old, new)
}

test layer3_transition_rejects_liqwid_position_drop() {
  let pos =
    LiqwidPosition { market_id: 0, qtokens_held: 1000, supplied_value: 100 }
  let old = VaultDatum { ..baseline_datum(), liqwid_positions: [pos] }
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
      liqwid_positions: [],
    }
  !validate_community_sunset_transition(old, new)
}

test layer3_transition_rejects_policy_field_change() {
  let old = baseline_datum()
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
      performance_fee_bps: 99,
    }
  !validate_community_sunset_transition(old, new)
}

test layer3_transition_rejects_immutable_field_change() {
  let old = baseline_datum()
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
      vault_version: 99,
    }
  !validate_community_sunset_transition(old, new)
}

test layer3_transition_rejects_time_field_change() {
  let old = baseline_datum()
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
      last_compound_time: old.last_compound_time + 1,
    }
  !validate_community_sunset_transition(old, new)
}

// ─────────────────────────────────────────────────────────────────────
// Combined-attack regression
// ─────────────────────────────────────────────────────────────────────

test layer3_attacker_cannot_use_sunset_to_extract_value() {
  // Attacker scenario: even if attacker satisfies the 90-day inactivity
  // condition (system is genuinely dead), they cannot use CommunitySunset
  // to drain funds — the transition helper rejects any datum mutation
  // beyond the two flag flips. So sunset only OPENS recovery paths
  // (Recall + Swap + Withdraw still go through their own validators
  // which keep token preservation + slippage caps + per-output
  // destination pinning).
  let old = baseline_datum()
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      community_sunset_triggered: 1,
      idle_buffer: 0,  // attacker tries to "drain" idle_buffer via datum
      total_deposited: 0,  // and brick share_price
    }
  !validate_community_sunset_transition(old, new)
}
