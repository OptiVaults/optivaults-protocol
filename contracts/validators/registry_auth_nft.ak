/// registry_auth_nft — One-shot Registry Auth NFT (PlutusV3 UTXO-ref).
///
/// Same pattern as vault_nft / governance_nft. The Registry UTXO must
/// carry this NFT to be considered authentic; vault validators reading
/// the registry as a reference input verify the NFT presence (see
/// helpers.read_registry_datum's auth_policy check) — defense against
/// a forged-datum UTXO at the registry script address.

use aiken/collection/dict
use aiken/collection/list
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{OutputReference, Transaction}

validator registry_auth_nft(
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
    fail @"registry_auth_nft: unsupported purpose"
  }
}
