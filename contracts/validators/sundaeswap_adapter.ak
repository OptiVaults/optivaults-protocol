//// sundaeswap_adapter — SwapAdapter for SundaeSwap V3 + Stableswaps.
////
//// PlutusV3 staking validator invoked via zero-withdrawal by
//// `vault_protocol.DeployToProtocol` (and `vault_admin_deploy.
//// AdminDeployNonDeposit`). Implements the SwapAdapter interface in
//// `lib/vault/swap_adapter.ak`.
////
//// Responsibility: decode the SundaeSwap order datum at
//// `redeemer.dest_output_idx` and verify that:
////   1. `destination` is `Fixed { address = vault, .. }` — the swap
////      output is paid to the vault, never an attacker (SwapAdapter recipient-address binding).
////   2. `owner` is `MultisigScript::Script(cancel_guard_hash)` — the
////      sibling `sundaeswap_cancel_guard`. SundaeSwap's order `Cancel`
////      path imposes NO output constraint (`order.ak`: "we impose no
////      additional constraints"), so the `owner` is the sole gate on a
////      cancelled (un-filled) order. Pinning it to the cancel-guard
////      makes that path drain-proof (the B2 design).
////   3. The order's `min_received` amount equals `redeemer.min_receive`
////      (the caller then applies the Tier 2 peg-floor + Tier 1 oracle).
////   4. `redeemer.hop_chain` is exactly `[offer_asset, target_asset]`,
////      matching the order datum's `offer` + `min_received` assets.
////      SundaeSwap orders are single-pool; the assets are explicit in
////      the datum, so this is a direct compare — no LP-name re-hash.
////
//// One adapter serves BOTH SundaeSwap V3 (constant-product) and
//// Stableswaps pools: their swap order datum is identical (Swap is
//// Constr 1 in both order unions). See `lib/vault/sundaeswap.ak`.
////
//// This adapter validates only the order DATUM. It does NOT check the
//// address the order output sits at — that is `vault_protocol`'s job:
//// `verify_destination_whitelisted` requires `tx.outputs[dest_output_
//// idx]` to bear a payment (and stake) credential listed in the
//// Registry `deploy_whitelist`. Consequently the SundaeSwap V3 +
//// Stableswaps `order.spend` script hashes MUST be seeded into the
//// Registry `deploy_whitelist` (alongside this adapter's hash in
//// `swap_adapter_hashes`) or `DeployToProtocol` cannot route here.
////
//// PRE-MAINNET VERIFICATION: the SundaeSwap order datum CBOR structure
//// must be confirmed against a real on-chain SundaeSwap swap order
//// (Preprod has a live `USDCx/USDR` Stableswap pool) before this
//// adapter's hash is added to the Registry `swap_adapter_hashes`
//// whitelist via governance UpdateRegistry (14-day timelock).
////
//// Parameterization — governance anchors + cancel-guard hash. The
//// adapter takes `governance_nft_policy` + `governance_nft_name` so the
//// `publish` handler (A2 ActDeregisterStake) can call `is_gov_
//// authorized` — identical to every other V1 staking validator, so the
//// ~2 ADA stake-registration deposit is reclaimable on adapter
//// rotation. It additionally takes `cancel_guard_hash`: the order
//// `owner` it requires. The cancel-guard is parameterized on the vault
//// (not on this adapter), so there is no parameter cycle — deploy the
//// cancel-guard first, then this adapter with the resulting hash.

use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{Transaction}
use vault/helpers.{is_gov_authorized, payload_hash_deregister_stake}
use vault/sundaeswap.{decode_order, verify_swap_order}
use vault/swap_adapter.{SwapAdapterRedeemer}
use vault/types.{ActDeregisterStake}

validator sundaeswap_adapter(
  governance_nft_policy: ByteArray,
  governance_nft_name: ByteArray,
  cancel_guard_hash: ByteArray,
) {
  withdraw(redeemer: SwapAdapterRedeemer, _account: Credential, tx: Transaction) {
    expect Some(dest_output) = list.at(tx.outputs, redeemer.dest_output_idx)
    when decode_order(dest_output) is {
      Some(order) ->
        verify_swap_order(
          order,
          redeemer.expected_recipient_addr,
          cancel_guard_hash,
          redeemer.min_receive,
          redeemer.hop_chain,
        )
      None -> False
    }
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
    fail @"sundaeswap_adapter: unsupported purpose"
  }
}
