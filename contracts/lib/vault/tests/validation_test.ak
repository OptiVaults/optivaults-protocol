/// Unit tests for `vault/validation.ak` — datum-transition predicates.
///
/// Each test constructs an old/new VaultDatum pair using the baseline
/// fixture + 1-line mutators, then asserts that the validator's
/// per-redeemer predicate accepts the happy case and rejects key
/// invariant violations.

use vault/helpers.{
  payload_hash_admin_deploy, payload_hash_emergency_withdraw,
  payload_hash_treasury_spend, payload_hash_update_fee,
  payload_hash_update_fee_split, payload_hash_update_slippage_policy,
  payload_hash_update_strategy,
}
use vault/tests/datum_helpers.{baseline_datum}
use vault/types.{Allocation, Liqwid, VaultDatum}
use vault/validation.{
  calculate_early_fee, calculate_shares_to_mint, calculate_withdraw_amount,
  check_immutable_fields, check_policy_fields_unchanged, validate_allocations,
  validate_compound, validate_deposit, validate_update_fee,
  validate_update_fee_split, validate_update_slippage_policy, validate_withdraw,
}

// ─────────────────────────────────────────────────────────────────────
// Share-mint math
// ─────────────────────────────────────────────────────────────────────

test mint_first_depositor_uses_multiplier() {
  // First depositor: shares = amount × 10^6 multiplier
  calculate_shares_to_mint(10_000_000, 0, 0) == 10_000_000_000_000
}

test mint_second_depositor_proportional() {
  // total_deposited=100M, total_shares=100B.
  // Add 10M USDCx → 10M × 100B / 100M = 10B shares.
  calculate_shares_to_mint(10_000_000, 100_000_000, 100_000_000_000_000) == 10_000_000_000_000
}

test withdraw_amount_proportional() {
  // 50B shares burned out of 100B total, with 100M total_deposited.
  // base_withdraw = 50B × 100M / 100B = 50M.
  calculate_withdraw_amount(50_000_000_000_000, 100_000_000, 100_000_000_000_000) == 50_000_000
}

test early_fee_at_10_bps() {
  // 100 USDCx × 0.1% = 0.1 USDCx (6-decimal: 100K).
  calculate_early_fee(100_000_000, 10) == 100_000
}

// ─────────────────────────────────────────────────────────────────────
// Immutable / policy field preservation
// ─────────────────────────────────────────────────────────────────────

test immutable_baseline_self_eq() {
  let d = baseline_datum()
  check_immutable_fields(d, d)
}

test immutable_rejects_governance_policy_change() {
  let old = baseline_datum()
  let new = VaultDatum { ..old, governance_policy: #"deadbeef" }
  !check_immutable_fields(old, new)
}

test policy_fields_baseline_self_eq() {
  let d = baseline_datum()
  check_policy_fields_unchanged(d, d)
}

test policy_fields_rejects_perf_fee_change() {
  let old = baseline_datum()
  let new = VaultDatum { ..old, performance_fee_bps: 100 }
  !check_policy_fields_unchanged(old, new)
}

// ─────────────────────────────────────────────────────────────────────
// Allocation soundness
// ─────────────────────────────────────────────────────────────────────

test alloc_empty_passes() {
  validate_allocations([], 100_000_000, 35_000_000)
}

test alloc_sum_within_total_passes() {
  let allocs = [Allocation { protocol: Liqwid, amount: 50_000_000, expected_apy_bps: 1184 }]
  validate_allocations(allocs, 100_000_000, 35_000_000)
}

test alloc_sum_exceeds_total_rejects() {
  // alloc 80M + buffer 35M = 115M > total_deposited 100M
  let allocs = [Allocation { protocol: Liqwid, amount: 80_000_000, expected_apy_bps: 1184 }]
  !validate_allocations(allocs, 100_000_000, 35_000_000)
}

test alloc_negative_amount_rejects() {
  let allocs = [Allocation { protocol: Liqwid, amount: -1, expected_apy_bps: 100 }]
  !validate_allocations(allocs, 100_000_000, 35_000_000)
}

// ─────────────────────────────────────────────────────────────────────
// validate_deposit
// ─────────────────────────────────────────────────────────────────────

test deposit_happy_path() {
  let amount = 10_000_000
  let old = baseline_datum()
  let expected_shares = calculate_shares_to_mint(amount, old.total_deposited, old.total_shares)
  let new = VaultDatum {
    ..old,
    total_deposited: old.total_deposited + amount,
    total_shares: old.total_shares + expected_shares,
    idle_buffer: old.idle_buffer + amount,
  }
  validate_deposit(old, new, amount)
}

test deposit_below_min_rejects() {
  let old = baseline_datum()
  let amount = 1_000_000  // 1 USDCx, below 10 USDCx min
  let new = VaultDatum {
    ..old,
    total_deposited: old.total_deposited + amount,
    total_shares: old.total_shares + amount * old.total_shares / old.total_deposited,
    idle_buffer: old.idle_buffer + amount,
  }
  !validate_deposit(old, new, amount)
}

test deposit_wrong_buffer_rejects() {
  let amount = 10_000_000
  let old = baseline_datum()
  let new = VaultDatum {
    ..old,
    total_deposited: old.total_deposited + amount,
    total_shares: old.total_shares + 10_000_000_000_000,
    idle_buffer: old.idle_buffer + amount + 1,
  }
  !validate_deposit(old, new, amount)
}

// ─────────────────────────────────────────────────────────────────────
// validate_withdraw — deferred-yield rule (internal verification)
// ─────────────────────────────────────────────────────────────────────

test withdraw_partial_with_early_fee() {
  let old = baseline_datum()
  // Burn 10B shares (10% of supply) for ~10M USDCx; 0.1% early fee = 10K
  let shares = 10_000_000_000_000
  let base = calculate_withdraw_amount(shares, old.total_deposited, old.total_shares)
  let early_fee = calculate_early_fee(base, old.early_withdraw_fee_bps)
  let withdraw_amount = base - early_fee
  let new = VaultDatum {
    ..old,
    total_deposited: old.total_deposited - withdraw_amount,
    total_shares: old.total_shares - shares,
  }
  validate_withdraw(old, new, shares, early_fee)
}

test withdraw_zero_fee_after_keeper_inactive() {
  let old = baseline_datum()
  let shares = 5_000_000_000_000
  let base = calculate_withdraw_amount(shares, old.total_deposited, old.total_shares)
  let new = VaultDatum {
    ..old,
    total_deposited: old.total_deposited - base,
    total_shares: old.total_shares - shares,
  }
  // early_fee == 0 (keeper-inactive branch) → withdraw_amount == base_withdraw
  validate_withdraw(old, new, shares, 0)
}

test withdraw_excess_shares_rejects() {
  let old = baseline_datum()
  let bad_shares = old.total_shares + 1
  let base = calculate_withdraw_amount(bad_shares, old.total_deposited, old.total_shares)
  let new = VaultDatum {
    ..old,
    total_deposited: old.total_deposited - base,
    total_shares: old.total_shares - bad_shares,
  }
  !validate_withdraw(old, new, bad_shares, 0)
}

// ─────────────────────────────────────────────────────────────────────
// validate_compound — 3-way fee split scenario
// ─────────────────────────────────────────────────────────────────────

test compound_zero_yield_only_advances_realloc() {
  let old = baseline_datum()
  let new = VaultDatum {
    ..old,
    last_realloc_time: old.last_realloc_time,  // V1 spec: zero-yield runs even without bumping in this stub
  }
  validate_compound(old, new, 0, [])
}

test compound_buffer_funded_extracts_fee() {
  // Scenario: idle_buffer == total_deposited + 1 USDCx yield
  let old = VaultDatum { ..baseline_datum(), idle_buffer: 101_000_000, total_deposited: 100_000_000 }
  // harvested = idle + ndv - td = 101M + 0 - 100M = 1M
  let harvested = 1_000_000
  let fee = harvested * old.performance_fee_bps / 10_000  // 1M × 4.5% = 45_000
  let net = harvested - fee
  let new = VaultDatum {
    ..old,
    total_deposited: old.total_deposited + net,
    idle_buffer: old.idle_buffer - fee,
  }
  validate_compound(old, new, harvested, [])
}

test compound_rejects_share_dilution() {
  let old = VaultDatum { ..baseline_datum(), idle_buffer: 101_000_000, total_deposited: 100_000_000 }
  let harvested = 1_000_000
  let fee = harvested * old.performance_fee_bps / 10_000
  let net = harvested - fee
  // Mutating total_shares is forbidden during Compound
  let new = VaultDatum {
    ..old,
    total_deposited: old.total_deposited + net,
    total_shares: old.total_shares + 1,
    idle_buffer: old.idle_buffer - fee,
  }
  !validate_compound(old, new, harvested, [])
}

// ─────────────────────────────────────────────────────────────────────
// validate_update_fee — caps + cooldown
// ─────────────────────────────────────────────────────────────────────

test update_fee_within_caps_passes() {
  let old = baseline_datum()
  let new = VaultDatum {
    ..old,
    performance_fee_bps: 300,
    early_withdraw_fee_bps: 50,
    min_hold_seconds: 120,
  }
  validate_update_fee(old, new, 300, 50, 120)
}

test update_fee_above_perf_cap_rejects() {
  let old = baseline_datum()
  let new = VaultDatum {
    ..old,
    performance_fee_bps: 500,
    early_withdraw_fee_bps: old.early_withdraw_fee_bps,
    min_hold_seconds: old.min_hold_seconds,
  }
  !validate_update_fee(old, new, 500, old.early_withdraw_fee_bps, old.min_hold_seconds)
}

test update_fee_above_min_hold_cap_rejects() {
  // Cap tightened from 86_400 (24h) to 21_600 (6h) after whitepaper
  // review. 21_601 is 1 second over the 6h cap.
  let old = baseline_datum()
  let new = VaultDatum { ..old, min_hold_seconds: 21_601 }
  !validate_update_fee(
    old,
    new,
    old.performance_fee_bps,
    old.early_withdraw_fee_bps,
    21_601,
  )
}

// ─────────────────────────────────────────────────────────────────────
// validate_update_fee_split — V1 3-way split
// ─────────────────────────────────────────────────────────────────────

test fee_split_phase1_launch() {
  // keeper 40% / gov 0% / treasury 60% — V1 launch default
  let old = baseline_datum()
  let new = VaultDatum { ..old, keeper_fee_bps: 4000, gov_fee_bps: 0 }
  validate_update_fee_split(old, new, 4000, 0)
}

test fee_split_phase2_5_pct_gov() {
  // keeper 40% / gov 5% / treasury 55%
  let old = baseline_datum()
  let new = VaultDatum { ..old, keeper_fee_bps: 4000, gov_fee_bps: 500 }
  validate_update_fee_split(old, new, 4000, 500)
}

test fee_split_phase3_10_pct_gov() {
  // keeper 40% / gov 10% / treasury 50% — at the validator hard floor
  let old = baseline_datum()
  let new = VaultDatum { ..old, keeper_fee_bps: 4000, gov_fee_bps: 1000 }
  validate_update_fee_split(old, new, 4000, 1000)
}

test fee_split_above_keeper_cap_rejects() {
  // 4001 > max_keeper_fee_bps (4000)
  let old = baseline_datum()
  let new = VaultDatum { ..old, keeper_fee_bps: 4001, gov_fee_bps: 0 }
  !validate_update_fee_split(old, new, 4001, 0)
}

test fee_split_above_gov_cap_rejects() {
  let old = baseline_datum()
  let new = VaultDatum { ..old, keeper_fee_bps: 0, gov_fee_bps: 1001 }
  !validate_update_fee_split(old, new, 0, 1001)
}

test fee_split_treasury_floor_violated_rejects() {
  // keeper 4500 + gov 600 = 5100 > 5000 cap → treasury floor 50% violated
  let old = baseline_datum()
  let new = VaultDatum { ..old, keeper_fee_bps: 4500, gov_fee_bps: 600 }
  !validate_update_fee_split(old, new, 4500, 600)
}

// ─────────────────────────────────────────────────────────────────────
// validate_update_slippage_policy — §5.4 Phase 2 caps + preservation
// ─────────────────────────────────────────────────────────────────────

test update_slippage_within_caps_passes() {
  let old = baseline_datum()
  let new = VaultDatum {
    ..old,
    max_slippage_bps: 300,
    min_swap_peg_bps: 9_800,
  }
  validate_update_slippage_policy(old, new, 300, 9_800)
}

test update_slippage_boundary_zero_slippage_passes() {
  // 0 bps slippage allowed — effectively disables Tier 1 oracle check
  // while still accepting the peg-floor. Corresponds to "only Tier 2
  // enforcement" operator stance.
  let old = baseline_datum()
  let new = VaultDatum { ..old, max_slippage_bps: 0, min_swap_peg_bps: 9_850 }
  validate_update_slippage_policy(old, new, 0, 9_850)
}

test update_slippage_above_cap_rejects() {
  // max_slippage_bps_cap = 500 bps (5%); 501 exceeds cap.
  let old = baseline_datum()
  let new = VaultDatum { ..old, max_slippage_bps: 501 }
  !validate_update_slippage_policy(old, new, 501, old.min_swap_peg_bps)
}

test update_slippage_peg_below_floor_rejects() {
  // min_swap_peg_bps_floor = 9_300. 9_299 means accepting > 7% peg breakage.
  let old = baseline_datum()
  let new = VaultDatum { ..old, min_swap_peg_bps: 9_299 }
  !validate_update_slippage_policy(old, new, old.max_slippage_bps, 9_299)
}

test update_slippage_peg_above_ceiling_rejects() {
  // min_swap_peg_bps_ceiling = 9_950. 9_951 would reject normal Minswap
  // V2 swaps at V1 scale.
  let old = baseline_datum()
  let new = VaultDatum { ..old, min_swap_peg_bps: 9_951 }
  !validate_update_slippage_policy(old, new, old.max_slippage_bps, 9_951)
}

test update_slippage_mutates_other_policy_field_rejects() {
  // Must preserve every policy field except max_slippage + min_swap_peg.
  // Here we attempt to also bump perf fee — validation must reject.
  let old = baseline_datum()
  let new = VaultDatum {
    ..old,
    max_slippage_bps: 300,
    min_swap_peg_bps: 9_800,
    performance_fee_bps: 400,
  }
  !validate_update_slippage_policy(old, new, 300, 9_800)
}

test payload_hash_update_slippage_policy_deterministic() {
  payload_hash_update_slippage_policy(300, 9_800) == payload_hash_update_slippage_policy(300, 9_800)
}

test payload_hash_update_slippage_policy_sensitive_to_slippage() {
  payload_hash_update_slippage_policy(300, 9_800) != payload_hash_update_slippage_policy(301, 9_800)
}

test payload_hash_update_slippage_policy_sensitive_to_peg() {
  payload_hash_update_slippage_policy(300, 9_800) != payload_hash_update_slippage_policy(300, 9_801)
}

test update_slippage_preserves_accounting() {
  // Cap-within-bounds + accounting field mutation should be rejected:
  // slippage policy must not touch total_deposited/total_shares/etc.
  let old = baseline_datum()
  let new = VaultDatum {
    ..old,
    max_slippage_bps: 300,
    min_swap_peg_bps: 9_800,
    total_deposited: old.total_deposited + 1,
  }
  !validate_update_slippage_policy(old, new, 300, 9_800)
}

// ─────────────────────────────────────────────────────────────────────
// V1 internal audit regression: governance payload-hash determinism
//
// These tests only check the caller-side `payload_hash_*` helpers —
// the full `is_gov_authorized` cross-validator flow requires a TX
// context and is covered by Preprod E2E scenarios. Pure-function hash
// determinism is the critical off/on-chain-must-agree invariant.
// ─────────────────────────────────────────────────────────────────────

test payload_hash_update_fee_deterministic() {
  payload_hash_update_fee(300, 50, 120) == payload_hash_update_fee(300, 50, 120)
}

test payload_hash_update_fee_sensitive_to_perf() {
  payload_hash_update_fee(300, 50, 120) != payload_hash_update_fee(301, 50, 120)
}

test payload_hash_update_fee_sensitive_to_early() {
  payload_hash_update_fee(300, 50, 120) != payload_hash_update_fee(300, 51, 120)
}

test payload_hash_update_fee_sensitive_to_min_hold() {
  payload_hash_update_fee(300, 50, 120) != payload_hash_update_fee(300, 50, 121)
}

test payload_hash_update_fee_split_deterministic() {
  payload_hash_update_fee_split(2000, 500) == payload_hash_update_fee_split(
    2000,
    500,
  )
}

test payload_hash_update_fee_split_sensitive() {
  // Phase 2 (2000 keeper / 500 gov) vs Phase 3 (2000 keeper / 1000 gov)
  payload_hash_update_fee_split(2000, 500) != payload_hash_update_fee_split(
    2000,
    1000,
  )
}

test payload_hash_emergency_withdraw_deterministic() {
  payload_hash_emergency_withdraw(1000, 1) == payload_hash_emergency_withdraw(
    1000,
    1,
  )
}

test payload_hash_emergency_withdraw_sensitive_to_freeze() {
  // same loss_amount but different freeze_flag → different hash
  payload_hash_emergency_withdraw(1000, 0) != payload_hash_emergency_withdraw(
    1000,
    1,
  )
}

test payload_hash_admin_deploy_deterministic() {
  let policy = #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34"
  let name = #"5553444378"
  payload_hash_admin_deploy(1_000_000, policy, name) == payload_hash_admin_deploy(
    1_000_000,
    policy,
    name,
  )
}

test payload_hash_admin_deploy_sensitive_to_token() {
  let amount = 1_000_000
  let policy_a = #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34"
  let policy_b = #"8d18d786e92776c824607fd8e193ec535c79dc61ea2405ddf3b09fe3"
  let name = #"5553444378"
  payload_hash_admin_deploy(amount, policy_a, name) != payload_hash_admin_deploy(
    amount,
    policy_b,
    name,
  )
}

test payload_hash_update_strategy_deterministic() {
  let allocs =
    [Allocation { protocol: Liqwid, amount: 45_000_000, expected_apy_bps: 1184 }]
  payload_hash_update_strategy(allocs, 3500) == payload_hash_update_strategy(
    allocs,
    3500,
  )
}

test payload_hash_update_strategy_sensitive_to_buffer() {
  let allocs = []
  payload_hash_update_strategy(allocs, 3500) != payload_hash_update_strategy(
    allocs,
    5000,
  )
}

// ─────────────────────────────────────────────────────────────────────
// Treasury spend payload includes the recipient — crucial so governance
// cannot queue P_good (honest recipient) and execute P_evil (attacker
// recipient) with the same amount.
// ─────────────────────────────────────────────────────────────────────

test payload_hash_treasury_spend_sensitive_to_amount() {
  let cat_tag = #"01"
  let addr_data: Data = #"deadbeef"
  let invoice = #"aabbcc"
  payload_hash_treasury_spend(cat_tag, 1_000, addr_data, invoice) != payload_hash_treasury_spend(
    cat_tag,
    2_000,
    addr_data,
    invoice,
  )
}

test payload_hash_treasury_spend_sensitive_to_recipient() {
  let cat_tag = #"01"
  let addr_a: Data = #"aaaaaa"
  let addr_b: Data = #"bbbbbb"
  let invoice = #"aabbcc"
  payload_hash_treasury_spend(cat_tag, 1_000, addr_a, invoice) != payload_hash_treasury_spend(
    cat_tag,
    1_000,
    addr_b,
    invoice,
  )
}
