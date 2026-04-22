/// Test fixture: synthetic VaultDatum builders.
///
/// V1 unit tests reason about VaultDatum-to-VaultDatum transitions
/// (validation.ak predicates) without constructing full TX contexts.
/// These helpers provide a known-good baseline datum + 1-line mutators
/// for each field so each test is short.

use vault/types.{Allocation, LiqwidPosition, VaultDatum}

/// Baseline VaultDatum used by every test as the "happy" starting point.
///   total_deposited: 100M USDCx (100 USDCx in 6-decimal units)
///   total_shares:    100B (multiplier 10^6)
///   idle_buffer:     35M (35% of TVL)
///   non_deposit_value: 0
///   strategy_allocations / liqwid_positions: empty
///   policy fields: launch defaults (450 perf / 10 early / 60 hold / 3500 buffer
///                   / 2000 keeper / 0 gov)
///   identity fields: deterministic non-zero placeholders
pub fn baseline_datum() -> VaultDatum {
  VaultDatum {
    total_deposited: 100_000_000,
    total_shares: 100_000_000_000_000,
    idle_buffer: 35_000_000,
    non_deposit_value: 0,
    last_compound_time: 1_750_000_000_000,
    last_realloc_time: 1_750_000_000_000,
    last_fee_update_time: 1_750_000_000_000,
    last_ada_swap_time: 1_750_000_000_000,
    strategy_allocations: [],
    liqwid_positions: [],

    performance_fee_bps: 450,
    early_withdraw_fee_bps: 10,
    min_hold_seconds: 60,
    buffer_target_bps: 3500,
    keeper_fee_bps: 2000,
    gov_fee_bps: 0,
    max_slippage_bps: 200,
    min_swap_peg_bps: 9_850,

    vault_version: 1,
    governance_policy: #"00112233445566778899aabbccddeeff00112233445566778899aabb",
    governance_name: #"4f70746956617573466f7647",
    deposit_token_policy: #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34",
    deposit_token_name: #"5553444378",
    vusdcx_policy: #"aabbccddeeff00112233445566778899aabbccddeeff001122334455",
    order_script_hash: #"33445566778899aabbccddeeff00112233445566778899aabbccddee",
    registry_hash: #"556677889900aabbccddeeff00112233445566778899aabbccddee00",
    registry_auth_policy: #"66778899aabbccddeeff00112233445566778899aabbccddeeff0011",

    frozen: 0,
  }
}

/// Empty allocation list (most happy-path tests use this).
pub fn no_allocs() -> List<Allocation> {
  []
}

/// Empty Liqwid position list.
pub fn no_positions() -> List<LiqwidPosition> {
  []
}
