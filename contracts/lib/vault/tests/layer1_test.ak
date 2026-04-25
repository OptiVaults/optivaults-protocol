//// Layer 1 — EmergencyWithdraw freeze-only invariant (2026-04-25).
////
//// Phase 1 governance-safety design layer 1 of three:
////   - Layer 1 (this file): EmergencyWithdraw cannot reduce
////     `total_deposited` or modify `liqwid_positions`. Only the
////     `frozen` flag (and `loss_amount==0` payload) is settable.
////   - Layer 2: vault_protocol.DeployToProtocol allows swap-out
////     under frozen=1 (NDV stable → USDCx via SwapAdapter).
////   - Layer 3 (Phase 2 candidate): user-driven EmergencySwapAndWithdraw
////     for fully trustless self-recovery.
////
//// Threat model: single-actor (founder-only) governance whose key is
//// compromised. Without Layer 1, the attacker can fire one EmergencyWithdraw
//// to (a) freeze the vault and (b) remove every Liqwid position from datum,
//// reducing `total_deposited` by `cleared_principal` — share_price drops
//// proportionally without any actual fund movement, leaving qTokens
//// orphaned in the vault. With Layer 1, this datum-only griefing path
//// is closed: real loss accounting must go through
//// vault_liqwid.RecallFromLiqwid (gov-fallback) which physically Recalls
//// underlying and writes off only the actually-realized loss.
////
//// Tests below exercise the helper directly (validate_emergency_freeze_only
//// in lib/vault/validation.ak) — same function the validator calls.

use vault/tests/datum_helpers.{baseline_datum}
use vault/types.{LiqwidPosition, VaultDatum}
use vault/validation.{validate_emergency_freeze_only}

// ─────────────────────────────────────────────────────────────────────
// Happy path: pure freeze
// ─────────────────────────────────────────────────────────────────────

test layer1_accepts_pure_freeze_no_positions() {
  let old = baseline_datum()
  // Same datum but frozen flag flipped 0 → 1
  let new = VaultDatum { ..old, frozen: 1 }
  validate_emergency_freeze_only(0, old, new)
}

test layer1_accepts_pure_freeze_with_existing_positions() {
  let pos =
    LiqwidPosition { market_id: 0, qtokens_held: 18_455_676_369, supplied_value: 546_100_000 }
  let old = VaultDatum { ..baseline_datum(), liqwid_positions: [pos] }
  let new = VaultDatum { ..old, frozen: 1 }
  // Positions preserved exactly + total_deposited unchanged + loss=0 → PASS
  validate_emergency_freeze_only(0, old, new)
}

test layer1_accepts_unfreeze() {
  // freeze_flag=0 path (governance ending an emergency) is symmetric.
  let pos =
    LiqwidPosition { market_id: 1, qtokens_held: 9_694_842_957, supplied_value: 235_550_000 }
  let old = VaultDatum { ..baseline_datum(), frozen: 1, liqwid_positions: [pos] }
  let new = VaultDatum { ..old, frozen: 0 }
  validate_emergency_freeze_only(0, old, new)
}

// ─────────────────────────────────────────────────────────────────────
// Reject: loss_amount field abuse
// ─────────────────────────────────────────────────────────────────────

test layer1_rejects_nonzero_loss_amount() {
  // Even if the datum is otherwise unchanged, a non-zero loss_amount in
  // the redeemer payload is rejected — closes the attack where attacker
  // queues `EmergencyWithdraw { loss_amount: TVL, freeze_flag: 1 }`
  // hoping to write off via the redeemer field rather than the datum.
  let old = baseline_datum()
  let new = VaultDatum { ..old, frozen: 1 }
  !validate_emergency_freeze_only(100, old, new)
}

test layer1_rejects_loss_amount_with_position_match() {
  // Even if loss_amount exactly equals the supplied_value of a removed
  // position (the pre-Layer-1 cleared_principal path), Layer 1 rejects
  // because the freeze-only constraint requires loss_amount == 0.
  let pos =
    LiqwidPosition { market_id: 0, qtokens_held: 1000, supplied_value: 100 }
  let old = VaultDatum { ..baseline_datum(), liqwid_positions: [pos] }
  let new = VaultDatum { ..old, frozen: 1, liqwid_positions: [], total_deposited: old.total_deposited - 100 }
  !validate_emergency_freeze_only(100, old, new)
}

// ─────────────────────────────────────────────────────────────────────
// Reject: total_deposited mutation (the primary griefing surface)
// ─────────────────────────────────────────────────────────────────────

test layer1_rejects_total_deposited_decrease() {
  let old = baseline_datum()
  let new = VaultDatum { ..old, frozen: 1, total_deposited: old.total_deposited - 50_000_000 }
  !validate_emergency_freeze_only(0, old, new)
}

test layer1_rejects_total_deposited_zero_brick() {
  // Worst-case attack: attacker tries to write off entire TVL via datum,
  // bricking share_price → 0. Layer 1 rejects.
  let old = baseline_datum()
  let new = VaultDatum { ..old, frozen: 1, total_deposited: 0 }
  !validate_emergency_freeze_only(0, old, new)
}

test layer1_rejects_total_deposited_increase() {
  // Symmetric guard: attacker can't inflate total_deposited either,
  // which would dilute remaining share holders if combined with other
  // governance moves.
  let old = baseline_datum()
  let new = VaultDatum { ..old, frozen: 1, total_deposited: old.total_deposited + 50_000_000 }
  !validate_emergency_freeze_only(0, old, new)
}

// ─────────────────────────────────────────────────────────────────────
// Reject: liqwid_positions mutation (closes the orphan-qToken vector)
// ─────────────────────────────────────────────────────────────────────

test layer1_rejects_position_removal() {
  let pos =
    LiqwidPosition { market_id: 0, qtokens_held: 18_455_676_369, supplied_value: 546_100_000 }
  let old = VaultDatum { ..baseline_datum(), liqwid_positions: [pos] }
  // Position dropped from datum (the pre-Layer-1 griefing move). Layer 1
  // rejects regardless of what happens to total_deposited because removing
  // a position from datum without physically Recalling underlying leaves
  // the qTokens stranded.
  let new = VaultDatum { ..old, frozen: 1, liqwid_positions: [] }
  !validate_emergency_freeze_only(0, old, new)
}

test layer1_rejects_partial_position_removal() {
  // Two positions; attacker tries to remove just one. Still rejected.
  let djed =
    LiqwidPosition { market_id: 0, qtokens_held: 18_455_676_369, supplied_value: 546_100_000 }
  let usdm =
    LiqwidPosition { market_id: 1, qtokens_held: 9_694_842_957, supplied_value: 235_550_000 }
  let old = VaultDatum { ..baseline_datum(), liqwid_positions: [djed, usdm] }
  let new = VaultDatum { ..old, frozen: 1, liqwid_positions: [djed] }
  !validate_emergency_freeze_only(0, old, new)
}

test layer1_rejects_position_qtokens_decrease() {
  // qToken balance can't be reduced without actual burn. Layer 1
  // catches the datum-only mutation.
  let pos =
    LiqwidPosition { market_id: 0, qtokens_held: 18_455_676_369, supplied_value: 546_100_000 }
  let pos_modified =
    LiqwidPosition { market_id: 0, qtokens_held: 1000, supplied_value: 546_100_000 }
  let old = VaultDatum { ..baseline_datum(), liqwid_positions: [pos] }
  let new = VaultDatum { ..old, frozen: 1, liqwid_positions: [pos_modified] }
  !validate_emergency_freeze_only(0, old, new)
}

test layer1_rejects_position_supplied_value_decrease() {
  // supplied_value reduction without underlying recovery is the
  // exact griefing pattern Layer 1 closes.
  let pos =
    LiqwidPosition { market_id: 0, qtokens_held: 18_455_676_369, supplied_value: 546_100_000 }
  let pos_modified =
    LiqwidPosition { market_id: 0, qtokens_held: 18_455_676_369, supplied_value: 1 }
  let old = VaultDatum { ..baseline_datum(), liqwid_positions: [pos] }
  let new = VaultDatum { ..old, frozen: 1, liqwid_positions: [pos_modified] }
  !validate_emergency_freeze_only(0, old, new)
}

test layer1_rejects_position_addition() {
  // Adding new positions via EmergencyWithdraw bypasses SupplyToLiqwid's
  // accounting checks — closed.
  let pos =
    LiqwidPosition { market_id: 0, qtokens_held: 1000, supplied_value: 100 }
  let old = baseline_datum()
  let new = VaultDatum { ..old, frozen: 1, liqwid_positions: [pos] }
  !validate_emergency_freeze_only(0, old, new)
}

test layer1_rejects_market_id_change() {
  // Position reassignment to a different market_id (e.g. attacker
  // swaps DJED claim for USDM claim) is rejected even when other
  // fields look identical.
  let pos_djed =
    LiqwidPosition { market_id: 0, qtokens_held: 1000, supplied_value: 100 }
  let pos_usdm =
    LiqwidPosition { market_id: 1, qtokens_held: 1000, supplied_value: 100 }
  let old = VaultDatum { ..baseline_datum(), liqwid_positions: [pos_djed] }
  let new = VaultDatum { ..old, frozen: 1, liqwid_positions: [pos_usdm] }
  !validate_emergency_freeze_only(0, old, new)
}

// ─────────────────────────────────────────────────────────────────────
// Combined-attack regression
// ─────────────────────────────────────────────────────────────────────

test layer1_rejects_full_grief_attack_pre_layer1_path() {
  // Reproduces the exact pre-Layer-1 attack chain that the freeze-only
  // constraint closes:
  //   - Attacker holds compromised gov key
  //   - Queues EmergencyWithdraw with loss_amount = full Liqwid principal,
  //     freeze_flag = 1
  //   - Submits TX that removes both Liqwid positions from datum and
  //     reduces total_deposited by their combined supplied_value
  //   - Result (pre-Layer-1): share_price drops proportionally, qTokens
  //     orphaned, depositors lose claim on the Liqwid portion
  //   - Result (post-Layer-1): TX rejected
  let djed =
    LiqwidPosition { market_id: 0, qtokens_held: 18_455_676_369, supplied_value: 546_100_000 }
  let usdm =
    LiqwidPosition { market_id: 1, qtokens_held: 9_694_842_957, supplied_value: 235_550_000 }
  let liqwid_principal = 546_100_000 + 235_550_000
  let old = VaultDatum { ..baseline_datum(), liqwid_positions: [djed, usdm] }
  let new =
    VaultDatum {
      ..old,
      frozen: 1,
      liqwid_positions: [],
      total_deposited: old.total_deposited - liqwid_principal,
    }
  !validate_emergency_freeze_only(liqwid_principal, old, new)
}
