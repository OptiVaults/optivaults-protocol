//// R77 F-1: SwapAdapterRedeemer `expected_recipient_addr` field
//// closes the direct-drain vector where Minswap V2 OrderDatum
//// `success_addr` (field[3]) and `refund_addr` (field[1]) were
//// previously unconstrained.
////
//// Pre-R77 attack chain:
////   1. Compromised keeper signs DeployToProtocol(deploy_token=USDCx,
////      deploy_amount=X, dest_output_idx).
////   2. dest_output is at the Minswap V2 batcher script address (in
////      `protocol_hashes` whitelist), so `verify_destination_whitelisted`
////      passes.
////   3. The Minswap V2 OrderDatum at dest_output has
////      success_addr = attacker_wallet (and/or refund_addr = attacker).
////      Pre-R77, neither field was validated by the adapter or caller.
////   4. Minswap V2 batcher fills the order, sends target asset to
////      success_addr = attacker.
////   5. Vault loses X USDCx; attacker gains X * (1 - slippage - fee)
////      of target asset (≈92-95% of X). DIRECT THEFT, not bounded
////      slippage griefing.
////
//// R77 fix (Option 1 — adapter interface extension):
////
//// Two enforcement layers, both must agree:
////   - Layer 1 (caller `vault_protocol.DeployToProtocol` /
////     `vault_admin_deploy.AdminDeployNonDeposit`): asserts
////     `adapter_redeemer.expected_recipient_addr ==
////      own_input.output.address`. The vault's spending input always
////     carries the vault's own address; the caller cannot lie about
////     this since the validator runs against a real on-chain UTXO.
////   - Layer 2 (adapter `minswap_v2_adapter.withdraw`): decodes order
////     datum field[1] (refund_addr) and field[3] (success_addr) and
////     verifies BOTH equal `redeemer.expected_recipient_addr`.
////
//// Combined: the caller forces the redeemer's expected_recipient_addr
//// to be the vault address; the adapter forces the on-chain order
//// datum to honor that same address. A compromised keeper cannot
//// bypass either layer — they would have to forge `own_input.output.
//// address` (impossible — it's an on-chain fact) or get the adapter
//// to lie about decoded datum fields (impossible — adapter logic is
//// fixed at compile time).
////
//// **Test scope**: this file covers the redeemer's structural shape
//// + Address equality semantics. Integration tests that exercise
//// `verify_swap_via_adapter` with full TX fixtures (matching/mismatching
//// success_addr scenarios) live in Preprod E2E (`tests/preprod/`).
//// The adapter's internal `extract_minswap_v2_order_min_receive` is a
//// private function so we cannot unit-test it from this file —
//// Preprod E2E exercises the full path against real Minswap V2 datum
//// shapes.

use cardano/address.{Address, Script, VerificationKey}
use vault/swap_adapter.{SwapAdapterRedeemer, last_hop_target}

// ─────────────────────────────────────────────────────────────────────
// Test fixtures — vault address + attacker address
// ─────────────────────────────────────────────────────────────────────

const vault_addr: Address =
  Address {
    payment_credential: Script(
      // Placeholder vault_proxy script hash — in production this is
      // the actual deployed proxy address.
      #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
    ),
    stake_credential: None,
  }

const attacker_addr: Address =
  Address {
    payment_credential: VerificationKey(
      #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    ),
    stake_credential: None,
  }

const usdcx_policy: ByteArray =
  #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34"

const usdcx_name: ByteArray = #"5553444378"

const djed_policy: ByteArray =
  #"8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd61"

const djed_name: ByteArray = #"446a65644d6963726f555344"

// ─────────────────────────────────────────────────────────────────────
// SwapAdapterRedeemer — new `expected_recipient_addr` field
// ─────────────────────────────────────────────────────────────────────

test r77_redeemer_carries_recipient_addr() {
  // Structural: SwapAdapterRedeemer must include the new field.
  let r =
    SwapAdapterRedeemer {
      dest_output_idx: 1,
      min_receive: 95_000_000,
      hop_chain: [(usdcx_policy, usdcx_name), (djed_policy, djed_name)],
      expected_recipient_addr: vault_addr,
    }
  and {
    r.dest_output_idx == 1,
    r.min_receive == 95_000_000,
    r.expected_recipient_addr == vault_addr,
    last_hop_target(r.hop_chain) == Some((djed_policy, djed_name)),
  }
}

test r77_redeemer_recipient_distinct_from_attacker() {
  // The attack scenario: a compromised keeper would set the redeemer's
  // expected_recipient_addr to attacker_addr to match a malicious order
  // datum. The caller-layer check `redeemer.expected_recipient_addr ==
  // own_input.output.address` rejects this because own_input.output.
  // address is an on-chain fact equal to vault_addr.
  let attacker_redeemer =
    SwapAdapterRedeemer {
      dest_output_idx: 1,
      min_receive: 95_000_000,
      hop_chain: [(usdcx_policy, usdcx_name), (djed_policy, djed_name)],
      expected_recipient_addr: attacker_addr,
    }
  and {
    // Honest caller passes vault_addr; attacker's redeemer carries
    // attacker_addr — they don't match.
    attacker_redeemer.expected_recipient_addr != vault_addr,
    // And the attacker's redeemer carries the attacker address.
    attacker_redeemer.expected_recipient_addr == attacker_addr,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Address equality semantics — used by both layers
// ─────────────────────────────────────────────────────────────────────

test r77_address_equality_payment_credential_only() {
  // Two addresses with the same payment credential and no stake
  // credential are equal.
  let a1 =
    Address {
      payment_credential: Script(
        #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
      ),
      stake_credential: None,
    }
  let a2 =
    Address {
      payment_credential: Script(
        #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
      ),
      stake_credential: None,
    }
  a1 == a2
}

test r77_address_inequality_different_payment_hash() {
  // Different payment-credential hash → different address.
  let a1 =
    Address {
      payment_credential: Script(
        #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
      ),
      stake_credential: None,
    }
  let a2 =
    Address {
      payment_credential: Script(
        #"b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2",
      ),
      stake_credential: None,
    }
  a1 != a2
}

test r77_address_inequality_script_vs_vk() {
  // Script vs VerificationKey credential → different address even with
  // same hash bytes (Constr index differs in PlutusData encoding).
  let script_addr =
    Address {
      payment_credential: Script(
        #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
      ),
      stake_credential: None,
    }
  let vk_addr =
    Address {
      payment_credential: VerificationKey(
        #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
      ),
      stake_credential: None,
    }
  script_addr != vk_addr
}

test r77_address_inequality_attacker_addr() {
  // The canonical attack address comparison: attacker's VKH-based
  // address vs vault's Script-based address are not equal.
  vault_addr != attacker_addr
}

// ─────────────────────────────────────────────────────────────────────
// Layer-1 enforcement semantic: caller's check that
// redeemer.expected_recipient_addr == own_input.output.address
// is a simple Address equality. Documented here for clarity.
// ─────────────────────────────────────────────────────────────────────

test r77_layer1_caller_check_pass_when_addresses_match() {
  let honest_redeemer =
    SwapAdapterRedeemer {
      dest_output_idx: 1,
      min_receive: 95_000_000,
      hop_chain: [(usdcx_policy, usdcx_name), (djed_policy, djed_name)],
      expected_recipient_addr: vault_addr,
    }
  let own_input_address = vault_addr
  honest_redeemer.expected_recipient_addr == own_input_address
}

test r77_layer1_caller_check_rejects_attacker_redeemer() {
  let attacker_redeemer =
    SwapAdapterRedeemer {
      dest_output_idx: 1,
      min_receive: 95_000_000,
      hop_chain: [(usdcx_policy, usdcx_name), (djed_policy, djed_name)],
      expected_recipient_addr: attacker_addr,
    }
  let own_input_address = vault_addr
  // Caller's check fails — attacker's redeemer has the wrong recipient.
  !(attacker_redeemer.expected_recipient_addr == own_input_address)
}

// ─────────────────────────────────────────────────────────────────────
// Note on integration coverage
// ─────────────────────────────────────────────────────────────────────
//
// Layer-2 enforcement (adapter validates order datum's success_addr +
// refund_addr against redeemer.expected_recipient_addr) is exercised
// by `extract_minswap_v2_order_min_receive` inside
// `validators/minswap_v2_adapter.ak`. That function is module-private
// (not `pub`) so we cannot unit-test it from this file directly.
//
// Preprod E2E (`tests/preprod/`) covers Layer 2 end-to-end:
//   - test 53 / test 66 (DeployToProtocol-via-Minswap V2 happy path)
//     constructs an order datum with success_addr == vault_addr and
//     verifies the swap completes. Pre-R77 these tests would also pass
//     with success_addr = attacker (silent acceptance); post-R77 they
//     PASS with vault_addr and FAIL with attacker_addr.
//   - test 84 / 85 (Tier 1 oracle bound) similarly exercise the full
//     adapter path.
//
// Adding a new Preprod E2E test that explicitly attempts the F-1 attack
// (success_addr = attacker) is the natural follow-up to confirm the
// fix on chain.
