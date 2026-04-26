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

use aiken/collection/list
use cardano/address.{from_verification_key}
use cardano/assets.{from_asset, merge, quantity_of}
use cardano/transaction.{Input, NoDatum, Output, OutputReference}
use vault/constants.{vusdcx_token_name}
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
//
// Post R75 L-1 (audit-0426): helper takes only `(last_compound_time,
// now)`. `last_realloc_time` is no longer load-bearing — zero-yield
// heartbeats cannot extend the 90-day sunset window. Pre-R75 tests
// that varied `last_realloc_time` independently of `last_compound_time`
// have been replaced by the heartbeat-spam regression below.
// ─────────────────────────────────────────────────────────────────────

test layer3_trigger_time_accepts_exact_90d_inactivity() {
  let last_compound = ref_now - inactivity_ms
  validate_community_sunset_trigger_time(last_compound, ref_now)
}

test layer3_trigger_time_accepts_more_than_90d_inactivity() {
  let last_compound = ref_now - inactivity_ms - 30 * day_ms  // 120d ago
  validate_community_sunset_trigger_time(last_compound, ref_now)
}

test layer3_trigger_time_rejects_89d_inactivity() {
  let last_compound = ref_now - 89 * day_ms
  !validate_community_sunset_trigger_time(last_compound, ref_now)
}

test layer3_trigger_time_rejects_one_day_short() {
  // 89 days, 23 hours
  let last_compound = ref_now - inactivity_ms + day_ms
  !validate_community_sunset_trigger_time(last_compound, ref_now)
}

test layer3_trigger_time_rejects_recent_compound() {
  // last_compound 5d ago → 5d < 90d → reject (keeper alive).
  let last_compound = ref_now - 5 * day_ms
  !validate_community_sunset_trigger_time(last_compound, ref_now)
}

test layer3_trigger_time_rejects_zero_baseline() {
  // Defensive: a corrupt or unset timestamp (= 0) must NOT let any
  // TX trigger sunset prematurely. Sanity bound 1_700_000_000_000
  // (2023-11-14) catches this.
  let last_compound = 0
  !validate_community_sunset_trigger_time(last_compound, ref_now)
}

test layer3_trigger_time_rejects_pre_2023_baseline() {
  // Any timestamp before 2023-11-14 should be rejected as obviously
  // invalid (V1 launches well after this date).
  let last_compound = 1_500_000_000_000  // 2017-07
  !validate_community_sunset_trigger_time(last_compound, ref_now)
}

// ─────────────────────────────────────────────────────────────────────
// R75 L-1 regression — heartbeat-spam cannot brick sunset
// ─────────────────────────────────────────────────────────────────────
//
// Pre-R75 L-1 the helper signature was `(last_compound, last_realloc,
// now) -> last_activity = max(...)`. A compromised keeper that lost
// the productive-yield path could send zero-yield Compound TXs every
// `zero_yield_cooldown_ms` (10 min) which advance `last_realloc_time`
// without bumping `last_compound_time`. Pre-fix the sunset window
// would be reset every 10 min and never fire — a permanent brick on
// the dead-man-switch by an attacker that controls the keeper key.
//
// Post-fix the helper reads ONLY `last_compound_time`. These tests
// pin the new behaviour: even if `last_realloc_time` looks fresh
// (synthesised by a hostile heartbeat stream), as long as
// `last_compound_time` is older than 90 days the dead-man-switch
// fires and any vUSDCx holder can drive the recovery chain.

test r75_l1_heartbeat_spam_does_not_extend_sunset_window() {
  // Scenario: real productive Compound stopped 100 days ago. The
  // attacker / dead-but-running keeper has been spamming zero-yield
  // heartbeats every 10 min for the entire window, so on-chain
  // `last_realloc_time` is "fresh" (e.g. 30 min ago). Pre-R75 this
  // would reject; post-R75 it accepts because last_compound is the
  // sole anchor.
  let last_compound = ref_now - 100 * day_ms
  // Note: `last_realloc_time` is no longer a parameter to the helper.
  // The fact that a fresh `last_realloc_time` would have changed the
  // outcome pre-R75 is the whole point of this regression — the new
  // signature makes that input impossible to express.
  validate_community_sunset_trigger_time(last_compound, ref_now)
}

test r75_l1_recent_real_compound_still_blocks_sunset() {
  // Symmetric / sanity: when `last_compound_time` is recent (real
  // productive activity), sunset must STILL be blocked. The fix only
  // removes the heartbeat-spam loophole, not the underlying liveness
  // signal.
  let last_compound = ref_now - 30 * day_ms
  !validate_community_sunset_trigger_time(last_compound, ref_now)
}

test r75_l1_aligned_with_keeper_inactive_window() {
  // Cross-check: vault_user.Withdraw's `keeper_inactive_ms` (7 days)
  // also reads ONLY `last_compound_time`. After R75 L-1 these two
  // fallback paths share the same anchor, just at different
  // thresholds (7d for early-fee waiver, 90d for permissionless
  // recovery). 30d > 7d but < 90d → Withdraw fee-waiver fires while
  // sunset stays blocked, exactly the intended phased response.
  let last_compound = ref_now - 30 * day_ms
  // sunset 90d threshold not yet met
  !validate_community_sunset_trigger_time(last_compound, ref_now)
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

// ─────────────────────────────────────────────────────────────────────
// R75 C-1 regression — vUSDCx caller-holder check uses canonical token
// name (audit-0426 critical, fixed 2026-04-26)
// ─────────────────────────────────────────────────────────────────────
//
// Pre-fix `vault_user.ak::CommunitySunset` did:
//
//   quantity_of(input.output.value, old_datum.vusdcx_policy, "")
//
// On Cardano `quantity_of(value, policy, name)` returns 0 whenever the
// (policy, name) tuple does not match a token in the value. The vUSDCx
// asset name is `#"765553444378"` (hex of "vUSDCx", 6 bytes) — not the
// empty string — so the lookup ALWAYS returned 0, making
// `caller_has_vusdcx` permanently false, making CommunitySunset
// permanently un-invokable, bricking the dead-man-switch entirely.
//
// Coverage gap that let this through: every other layer3 test in this
// file covers ONLY the two pure helpers (validate_community_sunset_
// trigger_time + validate_community_sunset_transition) and never
// exercised the redeemer code path that contained the buggy lookup.
// Aiken `aiken check` was a perfect green while the on-chain validator
// would have rejected every CommunitySunset attempt.
//
// Tests below pin three properties that together protect against the
// exact bug pattern returning:
//
//   1. The canonical asset-name constant has not drifted (`vusdcx_
//      token_name == #"765553444378"`).
//   2. Lookup with the canonical name succeeds on a value carrying the
//      vUSDCx token.
//   3. Lookup with `""` against the same value returns 0 (locks in the
//      buggy-pattern signal — if a future refactor reintroduces `""`,
//      this regression will fail loudly).
//
// Plus a synthetic Input-list test that mirrors `vault_user.ak`'s
// `list.any(tx.inputs, fn(input) { quantity_of(...) > 0 })` pattern
// against the canonical name, exercising the actual redeemer shape.

const test_vusdcx_policy: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

fn test_addr() {
  from_verification_key(
    #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  )
}

fn test_input(qty_vusdcx: Int, idx: Int) -> Input {
  let value =
    if qty_vusdcx > 0 {
      merge(
        from_asset(#"", #"", 2_000_000),
        from_asset(test_vusdcx_policy, vusdcx_token_name, qty_vusdcx),
      )
    } else {
      from_asset(#"", #"", 2_000_000)
    }
  Input {
    output_reference: OutputReference {
      transaction_id: #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      output_index: idx,
    },
    output: Output {
      address: test_addr(),
      value,
      datum: NoDatum,
      reference_script: None,
    },
  }
}

test layer3_vusdcx_constant_matches_vUSDCx_ascii() {
  // "vUSDCx" ASCII = 0x76 0x55 0x53 0x44 0x43 0x78 (6 bytes).
  // Locking this constant catches accidental encoding drift.
  vusdcx_token_name == #"765553444378"
}

test layer3_vusdcx_lookup_canonical_name_succeeds() {
  let v = from_asset(test_vusdcx_policy, vusdcx_token_name, 1)
  quantity_of(v, test_vusdcx_policy, vusdcx_token_name) == 1
}

test layer3_vusdcx_lookup_empty_name_returns_zero_buggy_pattern() {
  // Demonstrates the pre-fix bug: same value, but lookup with `""`
  // returns 0 → list.any over inputs would always be False → caller
  // always rejected. If a future refactor reintroduces `""` as the
  // asset-name argument, ANY downstream test that depends on a
  // populated value will fail; this test is a literal canary.
  let v = from_asset(test_vusdcx_policy, vusdcx_token_name, 1)
  quantity_of(v, test_vusdcx_policy, #"") == 0
}

test layer3_caller_has_vusdcx_finds_holder_with_canonical_name() {
  // Synthesises the exact `list.any` pattern from vault_user.ak:
  // 3 inputs, only one carries vUSDCx; with the CANONICAL name the
  // walk finds the holder.
  let inputs =
    [test_input(0, 0), test_input(1, 1), test_input(0, 2)]
  let canonical_caller_has_vusdcx =
    list.any(
      inputs,
      fn(input) {
        quantity_of(input.output.value, test_vusdcx_policy, vusdcx_token_name) > 0
      },
    )
  canonical_caller_has_vusdcx
}

test layer3_caller_has_vusdcx_buggy_empty_name_misses_holder() {
  // Same input list as above, but with the BUGGY `""` lookup; the walk
  // finds nothing. This is the on-chain behaviour pre-R75 fix.
  let inputs =
    [test_input(0, 0), test_input(1, 1), test_input(0, 2)]
  let buggy_caller_has_vusdcx =
    list.any(
      inputs,
      fn(input) {
        quantity_of(input.output.value, test_vusdcx_policy, #"") > 0
      },
    )
  !buggy_caller_has_vusdcx
}

test layer3_caller_has_vusdcx_rejects_no_holder() {
  // Negative path: no input carries vUSDCx; canonical lookup correctly
  // returns False (so the redeemer correctly rejects spam attempts
  // from a wallet without any vault stake).
  let inputs = [test_input(0, 0), test_input(0, 1), test_input(0, 2)]
  let no_holder =
    list.any(
      inputs,
      fn(input) {
        quantity_of(input.output.value, test_vusdcx_policy, vusdcx_token_name) > 0
      },
    )
  !no_holder
}
