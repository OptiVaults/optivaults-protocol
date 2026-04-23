/// Pure validation predicates over `VaultDatum` field transitions and
/// authorization helpers. These functions are intentionally cargo-friendly
/// — they take "old" and "new" datum values and return Bool with no
/// side effects, so unit tests can construct synthetic datums without a
/// full transaction context.
///
/// Cross-references:
///   spec/vault-datum.md §3 — invariants enforced on every redeemer
///   spec/vault-datum.md §4 — state-transition matrix per redeemer

use aiken/collection/list
use aiken/interval.{Finite}
use aiken/primitive/bytearray
use cardano/address.{Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{Input, Transaction}
use vault/constants.{
  initial_share_multiplier, keeper_inactive_ms, max_allocations,
  max_early_withdraw_fee_bps, max_gov_fee_bps, max_keeper_fee_bps,
  max_keeper_plus_gov_bps, max_min_hold_seconds, max_performance_fee_bps,
  max_slippage_bps_cap, min_compound_yield, min_deposit, min_swap_peg_bps_ceiling,
  min_swap_peg_bps_floor, min_valid_timestamp_ms,
}
use vault/types.{Allocation, AssetOracleEntry, VaultDatum}

// ─────────────────────────────────────────────────────────────────────
// Authorization helpers
// ─────────────────────────────────────────────────────────────────────

/// Verify the TX is signed by the expected keeper PKH (extra_signatories).
///
/// V1 keeper authorization typically goes through `keeper_stake_script`
/// (zero-withdraw); this helper is for paths where the validator needs
/// to know which keeper signed (e.g. SwapAda routes USDCx to that
/// keeper's address — fee is per-signer, not per-stake-script).
pub fn require_keeper(tx: Transaction, keeper_pkh: ByteArray) -> Bool {
  list.has(tx.extra_signatories, keeper_pkh)
}

/// V1 keeper authorization gate: check that the TX includes a zero-value
/// withdrawal entry against the keeper_stake_script's stake credential.
/// This delegates the actual "is this PKH allowed to act as keeper?"
/// decision to the keeper_stake_script's WithdrawAsAuthorized redeemer
/// (which enforces rotation, mode, bond status, etc.).
///
/// Vault validators ONLY call this — they remain agnostic about which
/// keeper signed, which is exactly the architectural advantage of the
/// stake-script approach (see spec/keeper-auth.md §6).
pub fn require_keeper_stake_script(
  tx: Transaction,
  keeper_stake_hash: ByteArray,
) -> Bool {
  list.any(
    tx.withdrawals,
    fn(pair) {
      let Pair(cred, _amount) = pair
      cred == Script(keeper_stake_hash)
    },
  )
}

/// keeper_stake_script gate OR governance fallback after 7 days of
/// keeper inactivity (governance-signed via GovNFT spend).
pub fn require_keeper_stake_script_or_governance_fallback(
  tx: Transaction,
  keeper_stake_hash: ByteArray,
  governance_policy: ByteArray,
  governance_name: ByteArray,
  last_compound_time: Int,
) -> Bool {
  if require_keeper_stake_script(tx, keeper_stake_hash) {
    True
  } else {
    let governance_authorized =
      require_governance(tx, governance_policy, governance_name)
    let valid_baseline = last_compound_time > min_valid_timestamp_ms
    let keeper_timeout =
      when tx.validity_range.lower_bound.bound_type is {
        Finite(now) -> now >= last_compound_time + keeper_inactive_ms
        _ -> False
      }
    and {
      governance_authorized,
      valid_baseline,
      keeper_timeout,
    }
  }
}

/// Verify the GovNFT is consumed as a TX input (governance-authorized
/// redeemer). Checks BOTH policy and asset name (defense-in-depth).
pub fn require_governance(
  tx: Transaction,
  governance_policy: ByteArray,
  governance_name: ByteArray,
) -> Bool {
  list.any(
    tx.inputs,
    fn(input) {
      quantity_of(input.output.value, governance_policy, governance_name) == 1
    },
  )
}

/// Keeper-authorized redeemer with governance-fallback after 7 days of
/// keeper inactivity. Used by RecallFromLiqwid / RecallFromProtocol /
/// AdminDeployNonDeposit / SwapAda etc.
///
/// Either:
///   - The keeper has signed the TX, or
///   - GovNFT is consumed AND `last_compound_time + 7d < now`.
pub fn require_keeper_or_governance_fallback(
  tx: Transaction,
  keeper_pkh: ByteArray,
  governance_policy: ByteArray,
  governance_name: ByteArray,
  last_compound_time: Int,
) -> Bool {
  if list.has(tx.extra_signatories, keeper_pkh) {
    True
  } else {
    let governance_authorized =
      require_governance(tx, governance_policy, governance_name)
    let valid_baseline = last_compound_time > min_valid_timestamp_ms
    let keeper_timeout =
      when tx.validity_range.lower_bound.bound_type is {
        Finite(now) -> now >= last_compound_time + keeper_inactive_ms
        _ -> False
      }
    and {
      governance_authorized,
      valid_baseline,
      keeper_timeout,
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Order-input guard (defense-in-depth: prevents BatchProcess + other
// redeemers from being smuggled into the same TX).
// ─────────────────────────────────────────────────────────────────────

pub fn has_no_order_inputs(inputs: List<Input>, order_hash: ByteArray) -> Bool {
  !list.any(
    inputs,
    fn(input) {
      when input.output.address.payment_credential is {
        Script(hash) -> hash == order_hash
        _ -> False
      }
    },
  )
}

// ─────────────────────────────────────────────────────────────────────
// Immutable-field preservation (9 datum fields: vault_version + 8 identity
// anchors). Policy fields (performance_fee_bps / early_withdraw_fee_bps /
// min_hold_seconds / buffer_target_bps / keeper_fee_bps / gov_fee_bps)
// are governance-mutable and checked separately by
// `check_policy_fields_unchanged` — together they guard 15 fields across
// any non-governance redeemer. See spec/vault-datum.md §2.3.
// ─────────────────────────────────────────────────────────────────────

pub fn check_immutable_fields(old: VaultDatum, new: VaultDatum) -> Bool {
  and {
    new.vault_version == old.vault_version,
    new.governance_policy == old.governance_policy,
    new.governance_name == old.governance_name,
    new.deposit_token_policy == old.deposit_token_policy,
    new.deposit_token_name == old.deposit_token_name,
    new.vusdcx_policy == old.vusdcx_policy,
    new.order_script_hash == old.order_script_hash,
    new.registry_hash == old.registry_hash,
    new.registry_auth_policy == old.registry_auth_policy,
  }
}

/// All datum fields that no redeemer may modify mid-transaction. This
/// includes the immutable identity AND the policy parameters that change
/// only via dedicated UpdateFee / UpdateFeeSplit / UpdateStrategy /
/// UpdateSlippagePolicy redeemers (which preserve everything *else*).
pub fn check_policy_fields_unchanged(old: VaultDatum, new: VaultDatum) -> Bool {
  and {
    new.performance_fee_bps == old.performance_fee_bps,
    new.early_withdraw_fee_bps == old.early_withdraw_fee_bps,
    new.min_hold_seconds == old.min_hold_seconds,
    new.buffer_target_bps == old.buffer_target_bps,
    new.keeper_fee_bps == old.keeper_fee_bps,
    new.gov_fee_bps == old.gov_fee_bps,
    new.max_slippage_bps == old.max_slippage_bps,
    new.min_swap_peg_bps == old.min_swap_peg_bps,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Allocation soundness (used by Compound, RebalanceBuffer, UpdateStrategy,
// DeployToProtocol, RecallFromProtocol, EmergencyWithdraw).
// ─────────────────────────────────────────────────────────────────────

pub fn validate_allocations(
  allocs: List<Allocation>,
  total_deposited: Int,
  idle_buffer: Int,
) -> Bool {
  let valid_buffer = idle_buffer >= 0
  let valid_length = list.length(allocs) <= max_allocations
  let valid_entries =
    list.all(
      allocs,
      fn(a) {
        and {
          a.amount >= 0,
          a.expected_apy_bps >= 0,
          a.expected_apy_bps <= 10_000,
        }
      },
    )
  let alloc_sum = list.foldl(allocs, 0, fn(a, acc) { acc + a.amount })
  let valid_sum = alloc_sum + idle_buffer <= total_deposited
  and {
    valid_buffer,
    valid_length,
    valid_entries,
    valid_sum,
  }
}

// ─────────────────────────────────────────────────────────────────────
// R73 F-1 admissibility guard (vault_recall.MergeUtxo)
//
// MergeUtxo accepts donations — idle_buffer and non_deposit_value can
// both increase without changing total_deposited or liqwid_positions.
// The seven downstream redeemers that read the post-merge vault state
// (Compound / DeployToProtocol / RecallFromProtocol / Liqwid Supply +
// Recall / UpdateStrategy / AdminDeployNonDeposit / EmergencyWithdraw)
// each check some form of an allocation invariant:
//
//   stricter (validate_allocations helper):
//     alloc_sum + idle_buffer <= total_deposited
//
//   looser (vault_gov_emergency.EmergencyWithdraw inline):
//     alloc_sum + idle_buffer <= total_deposited + non_deposit_value
//                              + Σ liqwid_principal
//
// Without this guard, an attacker can donate USDCx via MergeUtxo to
// push idle_buffer past ANY of those denominators, bricking all seven
// redeemers until Compound yield catches up — a sub-dollar-per-day
// sustained DoS at Phase 1 TVL. Guarding the LOOSER form here is
// strictly sufficient, because non_deposit_value and liqwid_principal
// are always non-negative, so `<= TD` is a subset of
// `<= TD + NDV + liqwid_principal`. A MergeUtxo post-state that
// satisfies this check satisfies BOTH invariant forms downstream.
//
// See `SECURITY.md §"Known open findings" R73 F-1` + audit round
// report for the full scope + economic-viability analysis.
pub fn valid_merge_utxo_admissibility(new_datum: VaultDatum) -> Bool {
  let alloc_sum =
    list.foldl(
      new_datum.strategy_allocations,
      0,
      fn(a, acc) { acc + a.amount },
    )
  let liqwid_principal_sum =
    list.foldl(
      new_datum.liqwid_positions,
      0,
      fn(p, acc) { acc + p.supplied_value },
    )
  alloc_sum + new_datum.idle_buffer <= new_datum.total_deposited + new_datum.non_deposit_value + liqwid_principal_sum
}

// ─────────────────────────────────────────────────────────────────────
// Share-mint math (ERC-4626; integer division rounds toward favor of
// existing holders / vault).
// ─────────────────────────────────────────────────────────────────────

pub fn calculate_shares_to_mint(
  deposit_amount: Int,
  total_deposited: Int,
  total_shares: Int,
) -> Int {
  if total_shares == 0 {
    deposit_amount * initial_share_multiplier
  } else {
    expect total_deposited > 0
    deposit_amount * total_shares / total_deposited
  }
}

pub fn calculate_withdraw_amount(
  shares_to_burn: Int,
  total_deposited: Int,
  total_shares: Int,
) -> Int {
  expect total_shares > 0
  shares_to_burn * total_deposited / total_shares
}

pub fn calculate_early_fee(
  withdraw_amount: Int,
  early_withdraw_fee_bps: Int,
) -> Int {
  withdraw_amount * early_withdraw_fee_bps / 10_000
}

// ─────────────────────────────────────────────────────────────────────
// Per-redeemer validators (datum transitions only; physical token
// preservation lives in lib/vault/helpers.ak and per-validator code).
// ─────────────────────────────────────────────────────────────────────

/// Deposit: total_deposited += amount, idle_buffer += amount,
/// total_shares += fair_shares. All other fields preserved.
pub fn validate_deposit(
  old: VaultDatum,
  new: VaultDatum,
  deposit_amount: Int,
) -> Bool {
  let valid_amount = deposit_amount >= min_deposit
  let valid_deposited =
    new.total_deposited == old.total_deposited + deposit_amount
  let valid_buffer = new.idle_buffer == old.idle_buffer + deposit_amount
  let expected_shares =
    calculate_shares_to_mint(
      deposit_amount,
      old.total_deposited,
      old.total_shares,
    )
  let valid_shares = new.total_shares == old.total_shares + expected_shares
  let valid_other = and {
      new.non_deposit_value == old.non_deposit_value,
      new.last_compound_time == old.last_compound_time,
      new.last_realloc_time == old.last_realloc_time,
      new.last_fee_update_time == old.last_fee_update_time,
      new.last_ada_swap_time == old.last_ada_swap_time,
      new.strategy_allocations == old.strategy_allocations,
      new.liqwid_positions == old.liqwid_positions,
      new.frozen == old.frozen,
    }
  and {
    valid_amount,
    valid_deposited,
    valid_buffer,
    valid_shares,
    valid_other,
    check_immutable_fields(old, new),
    check_policy_fields_unchanged(old, new),
  }
}

/// Withdraw: deferred-yield rule (internal verification) — `total_deposited` decreases
/// by `base_withdraw - early_fee`, leaving the early-fee in vault as
/// share-price uplift for remaining holders.
pub fn validate_withdraw(
  old: VaultDatum,
  new: VaultDatum,
  shares_to_burn: Int,
  early_fee: Int,
) -> Bool {
  let valid_shares = shares_to_burn > 0 && shares_to_burn <= old.total_shares
  let valid_early = early_fee >= 0
  let base_withdraw =
    calculate_withdraw_amount(
      shares_to_burn,
      old.total_deposited,
      old.total_shares,
    )
  let withdraw_amount = base_withdraw - early_fee
  let valid_withdraw_amount = withdraw_amount >= 0
  let valid_deposited =
    new.total_deposited == old.total_deposited - withdraw_amount
  let valid_shares_update = new.total_shares == old.total_shares - shares_to_burn
  let valid_other = and {
      new.non_deposit_value == old.non_deposit_value,
      new.last_compound_time == old.last_compound_time,
      new.last_realloc_time == old.last_realloc_time,
      new.last_fee_update_time == old.last_fee_update_time,
      new.last_ada_swap_time == old.last_ada_swap_time,
      new.strategy_allocations == old.strategy_allocations,
      new.liqwid_positions == old.liqwid_positions,
      new.frozen == old.frozen,
    }
  and {
    valid_shares,
    valid_early,
    valid_withdraw_amount,
    valid_deposited,
    valid_shares_update,
    valid_other,
    check_immutable_fields(old, new),
    check_policy_fields_unchanged(old, new),
  }
}

/// Compound (3-way fee split). Two modes:
///   - Zero-yield (harvested == 0): allocation-only update; only
///     `last_realloc_time` advances; no fee, no buffer change.
///   - Buffer-funded (harvested > 0 OR < 0): on-chain yield computed as
///     `idle_buffer + non_deposit_value - total_deposited` (NDV must be 0
///     and liqwid_positions must be empty for buffer-funded mode);
///     performance fee = harvested * performance_fee_bps / 10_000;
///     keeper share = fee * keeper_fee_bps / 10_000;
///     gov pool share = fee * gov_fee_bps / 10_000;
///     treasury share = fee - keeper - gov pool; net = harvested - fee
///     added to `total_deposited`.
pub fn validate_compound(
  old: VaultDatum,
  new: VaultDatum,
  harvested_amount: Int,
  _new_allocations: List<Allocation>,
) -> Bool {
  let is_zero_yield = harvested_amount == 0
  let valid_harvest =
    if is_zero_yield {
      True
    } else {
      let allocs_empty = list.length(old.strategy_allocations) == 0
      let ndv_zero = old.non_deposit_value == 0
      let liqwid_empty = list.length(old.liqwid_positions) == 0
      let on_chain_yield = old.idle_buffer + old.non_deposit_value - old.total_deposited
      and {
        allocs_empty,
        ndv_zero,
        liqwid_empty,
        harvested_amount == on_chain_yield,
      }
    }

  let valid_min_yield =
    if !is_zero_yield && harvested_amount > 0 {
      harvested_amount >= min_compound_yield
    } else {
      True
    }

  let valid_has_shares = old.total_shares > 0

  // Performance fee (only on positive yield)
  let fee =
    if harvested_amount > 0 {
      harvested_amount * old.performance_fee_bps / 10_000
    } else {
      0
    }
  let net_yield = harvested_amount - fee

  let valid_deposited = new.total_deposited == old.total_deposited + net_yield
  let valid_deposited_floor = new.total_deposited >= 0
  let valid_shares = new.total_shares == old.total_shares
  let valid_buffer =
    if is_zero_yield {
      new.idle_buffer == old.idle_buffer
    } else {
      new.idle_buffer == old.idle_buffer - fee
    }
  let valid_buffer_floor = new.idle_buffer >= 0

  let valid_non_deposit = new.non_deposit_value == old.non_deposit_value
  let valid_frozen = new.frozen == old.frozen
  let valid_positions = new.liqwid_positions == old.liqwid_positions
  let valid_fee_time = new.last_fee_update_time == old.last_fee_update_time
  let valid_ada_swap_time = new.last_ada_swap_time == old.last_ada_swap_time

  // Time-anchor handling per spec/vault-datum.md §4
  let valid_time =
    if is_zero_yield {
      // last_compound_time preserved; last_realloc_time advances (validity-range bounded in vault_core)
      new.last_compound_time == old.last_compound_time
    } else {
      // last_compound_time advances; last_realloc_time also advances on productive Compound
      True
    }

  and {
    valid_harvest,
    valid_min_yield,
    valid_has_shares,
    valid_deposited,
    valid_deposited_floor,
    valid_shares,
    valid_buffer,
    valid_buffer_floor,
    valid_non_deposit,
    valid_frozen,
    valid_positions,
    valid_fee_time,
    valid_ada_swap_time,
    valid_time,
    check_immutable_fields(old, new),
    check_policy_fields_unchanged(old, new),
  }
}

/// UpdateFee — adjusts `performance_fee_bps`, `early_withdraw_fee_bps`,
/// `min_hold_seconds` only. All other fields preserved. Caps enforced.
pub fn validate_update_fee(
  old: VaultDatum,
  new: VaultDatum,
  new_perf_bps: Int,
  new_early_bps: Int,
  new_min_hold: Int,
) -> Bool {
  let valid_perf = new_perf_bps >= 0 && new_perf_bps <= max_performance_fee_bps
  let valid_early =
    new_early_bps >= 0 && new_early_bps <= max_early_withdraw_fee_bps
  let valid_hold = new_min_hold >= 0 && new_min_hold <= max_min_hold_seconds

  let valid_update = and {
      new.performance_fee_bps == new_perf_bps,
      new.early_withdraw_fee_bps == new_early_bps,
      new.min_hold_seconds == new_min_hold,
      // Other policy fields unchanged
      new.buffer_target_bps == old.buffer_target_bps,
      new.keeper_fee_bps == old.keeper_fee_bps,
      new.gov_fee_bps == old.gov_fee_bps,
      new.max_slippage_bps == old.max_slippage_bps,
      new.min_swap_peg_bps == old.min_swap_peg_bps,
    }

  let valid_accounting = and {
      new.total_deposited == old.total_deposited,
      new.total_shares == old.total_shares,
      new.idle_buffer == old.idle_buffer,
      new.non_deposit_value == old.non_deposit_value,
      new.last_compound_time == old.last_compound_time,
      new.last_realloc_time == old.last_realloc_time,
      new.last_ada_swap_time == old.last_ada_swap_time,
      new.strategy_allocations == old.strategy_allocations,
      new.liqwid_positions == old.liqwid_positions,
      new.frozen == old.frozen,
    }

  and {
    valid_perf,
    valid_early,
    valid_hold,
    valid_update,
    valid_accounting,
    check_immutable_fields(old, new),
  }
}

/// UpdateFeeSplit — adjusts the 3-way performance fee split. Hard caps:
/// keeper ≤ 25%, gov ≤ 10%, sum ≤ 30% (treasury floor 70%).
pub fn validate_update_fee_split(
  old: VaultDatum,
  new: VaultDatum,
  new_keeper_bps: Int,
  new_gov_bps: Int,
) -> Bool {
  let valid_keeper = new_keeper_bps >= 0 && new_keeper_bps <= max_keeper_fee_bps
  let valid_gov = new_gov_bps >= 0 && new_gov_bps <= max_gov_fee_bps
  let valid_sum = new_keeper_bps + new_gov_bps <= max_keeper_plus_gov_bps

  let valid_update = and {
      new.keeper_fee_bps == new_keeper_bps,
      new.gov_fee_bps == new_gov_bps,
      // Other policy fields unchanged
      new.performance_fee_bps == old.performance_fee_bps,
      new.early_withdraw_fee_bps == old.early_withdraw_fee_bps,
      new.min_hold_seconds == old.min_hold_seconds,
      new.buffer_target_bps == old.buffer_target_bps,
      new.max_slippage_bps == old.max_slippage_bps,
      new.min_swap_peg_bps == old.min_swap_peg_bps,
    }

  let valid_accounting = and {
      new.total_deposited == old.total_deposited,
      new.total_shares == old.total_shares,
      new.idle_buffer == old.idle_buffer,
      new.non_deposit_value == old.non_deposit_value,
      new.last_compound_time == old.last_compound_time,
      new.last_realloc_time == old.last_realloc_time,
      new.last_ada_swap_time == old.last_ada_swap_time,
      new.strategy_allocations == old.strategy_allocations,
      new.liqwid_positions == old.liqwid_positions,
      new.frozen == old.frozen,
    }

  and {
    valid_keeper,
    valid_gov,
    valid_sum,
    valid_update,
    valid_accounting,
    check_immutable_fields(old, new),
  }
}

/// UpdateSlippagePolicy (§5.4 Phase 2, 2026-04-21) — adjusts
/// `max_slippage_bps` (Tier 1 oracle fair-price bound) +
/// `min_swap_peg_bps` (Tier 2 peg-floor bound). Validator-enforced caps:
/// max_slippage ∈ [0, max_slippage_bps_cap] (0..500 bps = 0..5%),
/// peg ∈ [min_swap_peg_bps_floor, min_swap_peg_bps_ceiling] (9_300..9_950).
/// All other policy fields + accounting fields preserved.
pub fn validate_update_slippage_policy(
  old: VaultDatum,
  new: VaultDatum,
  new_max_slippage_bps: Int,
  new_min_swap_peg_bps: Int,
) -> Bool {
  let valid_slippage =
    new_max_slippage_bps >= 0 && new_max_slippage_bps <= max_slippage_bps_cap
  let valid_peg =
    new_min_swap_peg_bps >= min_swap_peg_bps_floor && new_min_swap_peg_bps <= min_swap_peg_bps_ceiling

  let valid_update = and {
      new.max_slippage_bps == new_max_slippage_bps,
      new.min_swap_peg_bps == new_min_swap_peg_bps,
      // Other policy fields unchanged
      new.performance_fee_bps == old.performance_fee_bps,
      new.early_withdraw_fee_bps == old.early_withdraw_fee_bps,
      new.min_hold_seconds == old.min_hold_seconds,
      new.buffer_target_bps == old.buffer_target_bps,
      new.keeper_fee_bps == old.keeper_fee_bps,
      new.gov_fee_bps == old.gov_fee_bps,
    }

  let valid_accounting = and {
      new.total_deposited == old.total_deposited,
      new.total_shares == old.total_shares,
      new.idle_buffer == old.idle_buffer,
      new.non_deposit_value == old.non_deposit_value,
      new.last_compound_time == old.last_compound_time,
      new.last_realloc_time == old.last_realloc_time,
      new.last_fee_update_time == old.last_fee_update_time,
      new.last_ada_swap_time == old.last_ada_swap_time,
      new.strategy_allocations == old.strategy_allocations,
      new.liqwid_positions == old.liqwid_positions,
      new.frozen == old.frozen,
    }

  and {
    valid_slippage,
    valid_peg,
    valid_update,
    valid_accounting,
    check_immutable_fields(old, new),
  }
}

// ─────────────────────────────────────────────────────────────────────
// Registry — asset_oracles entry structural validation
//
// Shared between registry.UpdateRegistry (enforcing every entry in
// the Registry datum is well-formed) and r72_test.ak regression
// coverage. Lives in validation.ak so both callers can import it
// (Aiken does not allow library modules to import validator modules).
// ─────────────────────────────────────────────────────────────────────

/// C7 (2026-04-22): per-entry structural validation for asset_oracles
/// prevents governance from committing an oracle config that can't
/// function or that short-circuits security checks.
///
/// R72 F-3 (2026-04-22): added upper-bound caps on
/// `max_disagreement_bps` and `max_staleness_ms`. Without caps a
/// compromised or inattentive governance could (via 14d UpdateRegistry)
/// commit a degenerate entry — e.g. `max_disagreement_bps = 100_000`
/// (1000% tolerance) or `max_staleness_ms = 1_000_000_000` (~11.5 days)
/// — that would make Tier 1 oracle enforcement trivially satisfiable
/// and effectively turn the dual-feed reader into a no-op. The caps
/// below preserve every reasonable operational configuration while
/// keeping the oracle surface meaningful:
///   - `max_disagreement_bps <= 1000` (10%) — Charli3+Orcfax typical
///     intra-sample spread is < 20 bps under normal conditions; 1000 bps
///     is a wide safety cushion that still rejects degenerate values.
///   - `max_staleness_ms <= 3_600_000` (1 hour) — matches the
///     validity-range width cap on every time-writing redeemer (§5.4
///     P5, internal-verification R58 F-1); an oracle sample older than
///     1 hour is stale by any reasonable yardstick.
pub fn valid_asset_oracle_entry(e: AssetOracleEntry) -> Bool {
  let feeds_ok =
    list.all(
      e.feeds,
      fn(f) {
        and {
          bytearray.length(f.feed_script_hash) == 28,
          or {
            f.feed_auth_policy == #"",
            bytearray.length(f.feed_auth_policy) == 28,
          },
        }
      },
    )
  and {
    feeds_ok,
    e.min_feeds >= 1,
    e.min_feeds <= list.length(e.feeds),
    e.max_disagreement_bps > 0,
    e.max_disagreement_bps <= 1_000,
    e.max_staleness_ms > 0,
    e.max_staleness_ms <= 3_600_000,
  }
}
