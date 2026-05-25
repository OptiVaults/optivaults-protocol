//// sundaeswap_cancel_guard — drain-proof cancel authority for V1's
//// SundaeSwap orders (the B2 design).
////
//// SundaeSwap's order `Cancel` path imposes NO constraint on the
//// transaction outputs (`sundae-contracts/validators/order.ak`: "we
//// impose no additional constraints"). Whoever satisfies the order's
//// `owner` MultisigScript may spend an un-filled order UTxO to ANY
//// destination. SundaeSwap has no `refund_addr` field, so — unlike
//// Minswap V2 — the destination cannot be pinned in the datum.
////
//// V1 therefore sets every SundaeSwap order's `owner` to
//// `MultisigScript::Script(this validator's hash)`. To cancel, the
//// canceller must invoke this staking validator via a zero-withdrawal
//// (SundaeSwap's `multisig.satisfied` checks the script appears in
//// `tx.withdrawals`). This `withdraw` handler then enforces that the
//// full value of every protected order being cancelled flows to the
//// vault address. A compromised keeper can still TRIGGER a cancel
//// (operationally useful when a scooper fails to fill the order) but
//// cannot redirect the funds.
////
//// This validator is intentionally separate from `sundaeswap_adapter`:
//// the adapter's `withdraw` redeemer is the `SwapAdapterRedeemer` that
//// `vault_protocol`/`swap_adapter.ak` decode directly, so the cancel
//// path cannot share that handler. Keeping the guard separate also
//// means NO V1 vault contract is modified — the entire cancel-safety
//// surface lives in this new file.
////
//// Parameterization:
////   governance_nft_policy / governance_nft_name — A2 publish anchors.
////   vault_script_hash      — payment script hash of the V1 vault
////                            (vault_proxy); cancelled order value must
////                            land at an output bearing this credential.
////   sundae_order_hash_a/_b — SundaeSwap V3 + Stableswaps `order.spend`
////                            script hashes; inputs at these addresses
////                            are the candidate orders this guard
////                            protects.

use cardano/address.{Credential, Script}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{Transaction}
use vault/helpers.{is_gov_authorized, payload_hash_deregister_stake}
use vault/sundaeswap.{verify_cancel_value_conservation}
use vault/types.{ActDeregisterStake}

validator sundaeswap_cancel_guard(
  governance_nft_policy: ByteArray,
  governance_nft_name: ByteArray,
  vault_script_hash: ByteArray,
  sundae_order_hash_a: ByteArray,
  sundae_order_hash_b: ByteArray,
) {
  withdraw(_redeemer: Data, account: Credential, tx: Transaction) {
    expect Script(own_hash) = account
    // Drain-proof cancel (B2): every protected order's full value — ADA
    // included — must flow to the vault address. The conservation logic
    // and the M-1 fail-closed empty-protected-set guard live in
    // `verify_cancel_value_conservation` (lib/vault/sundaeswap.ak) so
    // they are directly unit-testable.
    verify_cancel_value_conservation(
      tx.inputs,
      tx.outputs,
      own_hash,
      vault_script_hash,
      sundae_order_hash_a,
      sundae_order_hash_b,
    )
  }

  /// A2 gov-gated stake deregister — identical shape to every other V1
  /// staking validator.
  publish(_redeemer: Data, certificate: Certificate, tx: Transaction) {
    expect UnregisterCredential { credential, .. } = certificate
    expect Script(own_hash) = credential
    is_gov_authorized(
      tx,
      governance_nft_policy,
      governance_nft_name,
      ActDeregisterStake,
      payload_hash_deregister_stake(own_hash),
      own_hash,
    )
  }

  else(_) {
    fail @"sundaeswap_cancel_guard: unsupported purpose"
  }
}
