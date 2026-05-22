/// MergeUtxo donation admissibility regression tests.
///
/// Internal audit documented that `vault_recall.MergeUtxo` accepts deposit-
/// token donations that can push `idle_buffer` past `total_deposited +
/// non_deposit_value + Σ liqwid_principal`, which breaks the allocation
/// invariant required by seven downstream redeemers (Compound /
/// DeployToProtocol / RecallFromProtocol / Liqwid Supply+Recall /
/// UpdateStrategy / AdminDeployNonDeposit / EmergencyWithdraw).
///
/// The fix lands in `lib/vault/validation.ak::valid_merge_utxo_
/// admissibility` + is invoked from `vault_recall.MergeUtxo`. This file
/// tests the predicate directly at the unit level against four
/// scenarios that collectively cover the fix's contract:
///
///   1. Legitimate donation preserving the invariant → accepted.
///   2. Donation pushing idle_buffer past the RHS → rejected.
///   3. Stable-token donation bumping NDV (both sides rise equally) →
///      accepted (NDV contributes to RHS, matching the fix's looser
///      guard form).
///   4. Exact equality at the boundary → accepted (`≤` is inclusive).
///
/// Cross-validator Transaction-level behaviour (MergeUtxo TX that would
/// have bricked Compound pre-fix now rejected at MergeUtxo time) is
/// exercised in Preprod E2E `tests/preprod-e2e-plan.md` INT-D.

use vault/tests/datum_helpers.{baseline_datum}
use vault/types.{Allocation, Liqwid, LiqwidPosition, VaultDatum}
use vault/validation.{valid_merge_utxo_admissibility}

// ─────────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────────

fn datum_with(
  td: Int,
  idle: Int,
  ndv: Int,
  allocs: List<Allocation>,
  positions: List<LiqwidPosition>,
) -> VaultDatum {
  let b = baseline_datum()
  VaultDatum {
    ..b,
    total_deposited: td,
    idle_buffer: idle,
    non_deposit_value: ndv,
    strategy_allocations: allocs,
    liqwid_positions: positions,
  }
}

fn alloc(amount: Int) -> Allocation {
  Allocation {
    protocol: Liqwid,
    amount,
    expected_apy_bps: 500,
  }
}

fn position(supplied: Int) -> LiqwidPosition {
  LiqwidPosition {
    market_id: 0,
    qtokens_held: supplied * 2,
    supplied_value: supplied,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Test 1 — Legitimate donation preserving the invariant
//
// Pre-donation: td=1000, idle=400, ndv=0, allocs=[], positions=[]
// Attacker donates 200 USDCx via MergeUtxo → new_idle=600, everything
// else unchanged. Check: 0 + 600 ≤ 1000 + 0 + 0 = 1000 ✓
// ─────────────────────────────────────────────────────────────────────

test legitimate_donation_passes() {
  let new_datum = datum_with(1000, 600, 0, [], [])
  valid_merge_utxo_admissibility(new_datum)
}

// ─────────────────────────────────────────────────────────────────────
// Test 2 — Donation pushing idle_buffer past RHS → rejected
//
// This is the donation-DoS attack scenario. Pre-donation: td=1000, idle=900,
// ndv=0. Attacker donates 200 → new_idle=1100. Check:
// 0 + 1100 ≤ 1000 + 0 + 0 → 1100 ≤ 1000 ✗
// ─────────────────────────────────────────────────────────────────────

test over_donation_rejected() {
  let new_datum = datum_with(1000, 1100, 0, [], [])
  !valid_merge_utxo_admissibility(new_datum)
}

// ─────────────────────────────────────────────────────────────────────
// Test 3 — Stable-token donation bumps NDV on both sides
//
// MergeUtxo with secondary holding a whitelisted stable token (DJED,
// USDM) moves value into `non_deposit_value`, which appears on the RHS
// of the admissibility invariant. Pre-merge: td=500, idle=100, ndv=0.
// Merge brings 300 USDM donation → idle unchanged (300 is non-deposit),
// ndv=300. Check: 0 + 100 ≤ 500 + 300 + 0 = 800 ✓
// ─────────────────────────────────────────────────────────────────────

test stable_donation_ndv_balanced_passes() {
  let new_datum = datum_with(500, 100, 300, [], [])
  valid_merge_utxo_admissibility(new_datum)
}

// ─────────────────────────────────────────────────────────────────────
// Test 4 — Exact boundary case (≤ is inclusive)
//
// td=500, idle=500, ndv=0, allocs=[], positions=[]. Check:
// 0 + 500 ≤ 500 + 0 + 0 = 500 ✓ (equality passes). Proves the fix
// doesn't reject at-exact-RHS states — which matters because normal
// operational MergeUtxos can leave the vault at the boundary without
// over-shooting.
// ─────────────────────────────────────────────────────────────────────

test boundary_equality_passes() {
  let new_datum = datum_with(500, 500, 0, [], [])
  valid_merge_utxo_admissibility(new_datum)
}

// ─────────────────────────────────────────────────────────────────────
// Test 5 (bonus) — liqwid_principal contributes to RHS
//
// Post-recent-SupplyToLiqwid a vault might have td=500, idle=100,
// ndv=0, liqwid_positions=[{supplied=300}]. A subsequent legitimate
// merge donation of 300 → new_idle=400 should pass because the Liqwid
// principal contributes to RHS. Check: 0 + 400 ≤ 500 + 0 + 300 = 800 ✓
// ─────────────────────────────────────────────────────────────────────

test liqwid_principal_counts_toward_rhs() {
  let new_datum = datum_with(500, 400, 0, [], [position(300)])
  valid_merge_utxo_admissibility(new_datum)
}

// ─────────────────────────────────────────────────────────────────────
// Test 6 (bonus) — allocs + idle together counted on LHS
//
// Post-DeployToProtocol state: td=1000, idle=300, allocs=[500],
// ndv=0, positions=[]. Check: 500 + 300 ≤ 1000 + 0 + 0 = 1000 ✓
// (alloc_sum counts toward LHS — if it didn't, a vault with
// alloc_sum > 0 would pass this check too permissively).
// Over-allocation scenario: allocs=[600], idle=500 → 600+500=1100 >
// 1000 ✗ — rejected, catching the class of deploy-bugs that inflate
// alloc amounts beyond underlying.
// ─────────────────────────────────────────────────────────────────────

test allocs_counted_toward_lhs() {
  let ok_datum = datum_with(1000, 300, 0, [alloc(500)], [])
  let bad_datum = datum_with(1000, 500, 0, [alloc(600)], [])
  and {
    valid_merge_utxo_admissibility(ok_datum),
    !valid_merge_utxo_admissibility(bad_datum),
  }
}
