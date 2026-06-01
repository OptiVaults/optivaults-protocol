/// treasury_nft — One-shot Treasury identity NFT (PlutusV3 UTXO-ref).
///
/// Same one-shot UTXO-ref pattern as vault_nft / registry_auth_nft. The
/// canonical treasury UTXO must carry this NFT to be considered authentic;
/// every treasury spend branch requires
/// `quantity_of(own_input.value, this_policy, asset_name) == 1` and forces
/// the continuing output to preserve the NFT, and the two fee consumers
/// (vault_keeper_hot.Compound's treasury share, multisig_gov.Distribute's
/// forfeit) route only to the NFT-bearing output.
///
/// Before this validator existed, treasury.ak was parameterized only on the
/// deposit-token identity, so anyone could create decoy UTXOs at the
/// treasury script address with forged datums (attacker-chosen
/// governance_policy, inflated balances) → accounting fragmentation, and the
/// fee consumers routed to "a" treasury output rather than the canonical
/// one. The compile-time UTXO-ref anchor makes the NFT a one-shot the
/// operator mints at deploy time; no subsequent mint is possible because the
/// anchor UTXO is consumed.

use aiken/collection/dict
use aiken/collection/list
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{OutputReference, Transaction}

validator treasury_nft(
  utxo_ref: OutputReference,
  asset_name: ByteArray,
) {
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    let minted = dict.to_pairs(tokens(tx.mint, policy_id))
    when minted is {
      [pair] ->
        if pair.2nd == 1 {
          let utxo_consumed =
            list.any(
              tx.inputs,
              fn(input) { input.output_reference == utxo_ref },
            )
          and {
            pair.1st == asset_name,
            utxo_consumed,
          }
        } else if pair.2nd == -1 {
          pair.1st == asset_name
        } else {
          False
        }
      _ -> False
    }
  }

  else(_) {
    fail @"treasury_nft: unsupported purpose"
  }
}
