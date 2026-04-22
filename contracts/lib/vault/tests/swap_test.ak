/// swap.ak regression tests — §5.4 P4.
///
/// Unit-level coverage: peg-floor math helpers + SwapBound shape.
/// The Transaction-dependent paths (extract_minswap_v2_swap_bound,
/// check_swap_order, check_swap_order_at) require Minswap V2 datum
/// mocking with Output fixtures, which belongs in Preprod E2E tests
/// per the V1 testing philosophy. Preprod scenario
/// `DeployToProtocol-swap` in `tests/preprod-e2e-plan.md` MUST
/// exercise both:
///   - Real Minswap V2 SwapExactIn order → decoder extracts min_receive
///   - Crafted min_receive = 1 order → peg-floor rejects
/// to confirm the decoder matches Minswap V2's actual on-chain datum
/// layout (see lib/vault/swap.ak PRE-MAINNET VERIFICATION note).

use vault/swap_adapter.{SwapAdapterRedeemer, check_peg_floor}

// ─────────────────────────────────────────────────────────────────────
// check_peg_floor — core bound arithmetic
//
// peg-floor holds: min_receive × 10_000 >= deploy_amount × peg_bps
// Equivalently: min_receive / deploy_amount >= peg_bps / 10_000
// i.e. (receive / deploy) × 100% >= (peg_bps / 10_000) × 100%
//
// Typical V1 peg_bps = 9_500 (95%). DJED / USDM / USDCx swaps among
// each other should receive within 5% of face value.
// ─────────────────────────────────────────────────────────────────────

test peg_floor_exact_boundary_accepts() {
  // Edge of acceptance: min_receive exactly matches peg_bps floor.
  //   deploy = 100_000_000 (100 USDCx), peg = 9_500
  //   required min_receive >= 100_000_000 × 9_500 / 10_000 = 95_000_000
  check_peg_floor(100_000_000, 95_000_000, 9_500)
}

test peg_floor_above_boundary_accepts() {
  // Comfortable margin — 98% receive rate on a 95% peg floor.
  check_peg_floor(100_000_000, 98_000_000, 9_500)
}

test peg_floor_below_boundary_rejects() {
  // Barely below floor — 94.99% receive rate on a 95% peg.
  // 100_000_000 × 9_500 / 10_000 = 95_000_000; 94_990_000 < that.
  !check_peg_floor(100_000_000, 94_990_000, 9_500)
}

test peg_floor_extreme_slippage_attack_rejects() {
  // The canonical attack the peg-floor exists to block: compromised
  // keeper submits min_receive = 1 for a 100 USDCx swap. With
  // peg_bps = 9_500, required ≥ 95_000_000 lovelace-units; 1 << that.
  !check_peg_floor(100_000_000, 1, 9_500)
}

test peg_floor_zero_deploy_trivially_accepts() {
  // deploy_amount = 0 makes the RHS zero, so any non-negative
  // min_receive satisfies. Not a meaningful real case (DeployToProtocol
  // enforces deploy_amount >= min_order_amount elsewhere), but the
  // helper alone has no such gate.
  check_peg_floor(0, 0, 9_500)
}

test peg_floor_peg_zero_trivially_accepts() {
  // peg_bps = 0 disables the floor (accepts any min_receive). Would
  // be a governance mis-configuration — UpdateSlippagePolicy caps
  // enforce peg_bps ∈ [9_300, 9_950] to prevent this.
  check_peg_floor(100_000_000, 0, 0)
}

test peg_floor_peg_at_ceiling_tight() {
  // Upper peg — 99.5% cap from UpdateSlippagePolicy caps.
  // Any receive ≥ 99.5% of deploy passes.
  check_peg_floor(100_000_000, 99_500_000, 9_950)
}

test peg_floor_peg_at_ceiling_strict() {
  // 99.4% receive against 99.5% peg — rejected.
  !check_peg_floor(100_000_000, 99_400_000, 9_950)
}

test peg_floor_large_values_no_overflow() {
  // Aiken Int is arbitrary-precision (no overflow risk). Exercise
  // a large-value case anyway — 10M USDCx × 10_000 wouldn't overflow
  // a naive int64 (it's ~10^14) but Aiken is unbounded so this is
  // belt-and-braces.
  check_peg_floor(10_000_000_000_000, 9_500_000_000_000, 9_500)
}

test peg_floor_exact_equality_large() {
  // Exact boundary at a realistic 10,000 USDCx scale.
  //   deploy = 10_000 × 10^6 = 10_000_000_000
  //   required = deploy × 9_500 / 10_000 = 9_500_000_000
  check_peg_floor(10_000_000_000, 9_500_000_000, 9_500)
}

// ─────────────────────────────────────────────────────────────────────
// SwapAdapterRedeemer — shape
// ─────────────────────────────────────────────────────────────────────

test swap_adapter_redeemer_shape() {
  // Realistic SwapAdapterRedeemer for a 100 USDCx → DJED swap.
  let r =
    SwapAdapterRedeemer {
      dest_output_idx: 2,
      min_receive: 95_000_000,
      target_asset_policy: #"8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd61",
      target_asset_name: #"4472697020537461626c65",
    }
  and {
    r.dest_output_idx == 2,
    r.min_receive > 0,
    r.target_asset_policy != #"",
  }
}

test swap_adapter_redeemer_ada_target() {
  // ADA target uses empty policy + name (Cardano lovelace convention).
  let r =
    SwapAdapterRedeemer {
      dest_output_idx: 0,
      min_receive: 48_000_000,
      target_asset_policy: #"",
      target_asset_name: #"",
    }
  and {
    r.target_asset_policy == #"",
    r.target_asset_name == #"",
  }
}
