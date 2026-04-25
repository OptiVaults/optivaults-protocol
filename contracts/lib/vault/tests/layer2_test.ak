//// Layer 2 — vault_protocol.DeployToProtocol freeze gate (2026-04-25).
////
//// Phase 1 governance-safety design layer 2 of three. Covers the
//// frozen=1 exception that lets the keeper drain NDV stable tokens
//// (DJED, USDM) back to USDCx via the registry-whitelisted SwapAdapter
//// even while the vault is frozen by EmergencyWithdraw.
////
//// Without Layer 2, every freeze permanently strands the NDV portion
//// until the 21-day `AdminDeployNonDeposit` governance fallback
//// executes — too slow for users who want to fully Withdraw their
//// share (which can only pay out USDCx, not stable tokens).
////
//// The discriminator is `deploy_token != deposit_token`:
////   - `deploy_token == USDCx` → Supply-to-Liqwid path → blocked
////     under freeze (don't put new capital at risk during emergency).
////   - `deploy_token == DJED` or `USDM` → swap-out via SwapAdapter →
////     allowed under freeze (recovery path, destination pinned to
////     vault by adapter validator, slippage capped by peg_floor).
////
//// Tests below exercise `validate_deploy_frozen_gate` directly — same
//// helper the validator calls.

use vault/validation.{validate_deploy_frozen_gate}

// Real-mainnet token identifiers used by V1 (Circle/xReserve USDCx +
// COTI DJED + Mehen USDM). Hardcoding these here makes the tests read
// like real attack scenarios.
const usdcx_policy = #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34"
const usdcx_name = #"5553444378"
const djed_policy = #"8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd61"
const djed_name = #"446a65644d6963726f555344"
const usdm_policy = #"c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"
const usdm_name = #"0014df105553444d"

// ─────────────────────────────────────────────────────────────────────
// Default rule: frozen == 0 lets every deploy_token through
// ─────────────────────────────────────────────────────────────────────

test layer2_unfrozen_allows_supply_usdcx() {
  // Normal Liqwid Supply (deploy_token == USDCx) when not frozen.
  validate_deploy_frozen_gate(
    0,
    usdcx_policy,
    usdcx_name,
    usdcx_policy,
    usdcx_name,
  )
}

test layer2_unfrozen_allows_swap_djed() {
  // Normal swap-out (deploy_token == DJED) when not frozen.
  validate_deploy_frozen_gate(
    0,
    djed_policy,
    djed_name,
    usdcx_policy,
    usdcx_name,
  )
}

test layer2_unfrozen_allows_swap_usdm() {
  validate_deploy_frozen_gate(
    0,
    usdm_policy,
    usdm_name,
    usdcx_policy,
    usdcx_name,
  )
}

// ─────────────────────────────────────────────────────────────────────
// Layer 2 exception: frozen == 1 permits swap-out only
// ─────────────────────────────────────────────────────────────────────

test layer2_frozen_allows_swap_djed() {
  // Recovery path: under freeze, drain DJED → USDCx so users can
  // withdraw the Liqwid portion.
  validate_deploy_frozen_gate(
    1,
    djed_policy,
    djed_name,
    usdcx_policy,
    usdcx_name,
  )
}

test layer2_frozen_allows_swap_usdm() {
  validate_deploy_frozen_gate(
    1,
    usdm_policy,
    usdm_name,
    usdcx_policy,
    usdcx_name,
  )
}

test layer2_frozen_allows_swap_arbitrary_non_deposit_token() {
  // Any non-deposit token can be swapped out under freeze. The
  // SwapAdapter whitelist + peg_floor + cooldown bound the abuse.
  let arbitrary_policy = #"deadbeef00112233445566778899aabbccddeeff00112233445566ff"
  let arbitrary_name = #"d00d"
  validate_deploy_frozen_gate(
    1,
    arbitrary_policy,
    arbitrary_name,
    usdcx_policy,
    usdcx_name,
  )
}

// ─────────────────────────────────────────────────────────────────────
// Layer 2 block: frozen == 1 still blocks Supply-to-Liqwid
// ─────────────────────────────────────────────────────────────────────

test layer2_frozen_blocks_supply_usdcx() {
  // Attacker tries to deploy USDCx (Supply to Liqwid) while frozen.
  // Blocked — don't put new capital at risk during emergency.
  !validate_deploy_frozen_gate(
    1,
    usdcx_policy,
    usdcx_name,
    usdcx_policy,
    usdcx_name,
  )
}

// ─────────────────────────────────────────────────────────────────────
// Defensive: malformed frozen flag
// ─────────────────────────────────────────────────────────────────────

test layer2_invalid_frozen_value_blocks_all() {
  // valid_frozen elsewhere in EmergencyWithdraw constrains
  // frozen ∈ {0, 1}, but defense-in-depth: any other value
  // (corrupted datum, governance bug) should not be treated as
  // unfrozen by Layer 2.
  !validate_deploy_frozen_gate(
    2,
    djed_policy,
    djed_name,
    usdcx_policy,
    usdcx_name,
  )
}

test layer2_negative_frozen_value_blocks_all() {
  !validate_deploy_frozen_gate(
    -1,
    usdcx_policy,
    usdcx_name,
    usdcx_policy,
    usdcx_name,
  )
}

// ─────────────────────────────────────────────────────────────────────
// Edge: same-policy different-name pair
// ─────────────────────────────────────────────────────────────────────

test layer2_same_policy_different_name_treated_as_non_deposit() {
  // If a token shares the deposit policy but has a different asset
  // name (multi-asset minting policy), it is NOT the deposit token —
  // swap-out under freeze is allowed.
  let other_name_under_usdcx = #"deadbeef"
  validate_deploy_frozen_gate(
    1,
    usdcx_policy,
    other_name_under_usdcx,
    usdcx_policy,
    usdcx_name,
  )
}

test layer2_different_policy_same_name_treated_as_non_deposit() {
  // Symmetric: different policy + same name is also NOT the deposit
  // token (e.g., a fake "USDCx" minted under a different policy).
  let fake_usdcx_policy = #"00000000000000000000000000000000000000000000000000000000"
  validate_deploy_frozen_gate(
    1,
    fake_usdcx_policy,
    usdcx_name,
    usdcx_policy,
    usdcx_name,
  )
}

// ─────────────────────────────────────────────────────────────────────
// Combined-attack regression
// ─────────────────────────────────────────────────────────────────────

test layer2_attacker_cannot_supply_under_freeze() {
  // Attack scenario: attacker keeps emergency freeze active
  // (legitimate operator response to depeg) but tries to also fire
  // SupplyToLiqwid via DeployToProtocol with USDCx during the
  // freeze window. Layer 2 blocks this, preventing capital being put
  // back at risk during an active emergency.
  !validate_deploy_frozen_gate(
    1,
    usdcx_policy,
    usdcx_name,
    usdcx_policy,
    usdcx_name,
  )
}

test layer2_honest_keeper_can_recover_djed_under_freeze() {
  // Honest scenario: governance freezes due to depeg / Liqwid bad debt,
  // keeper proceeds to swap NDV DJED → USDCx so user Withdraw can pay
  // out the full deposit-token share. Layer 2 allows this.
  validate_deploy_frozen_gate(
    1,
    djed_policy,
    djed_name,
    usdcx_policy,
    usdcx_name,
  )
}
