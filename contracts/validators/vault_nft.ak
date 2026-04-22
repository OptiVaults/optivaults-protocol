/// vault_nft — Vault Identity NFT (PlutusV3 UTXO-ref one-shot)
///
/// Mint branch: parameterised UTXO must be consumed in the TX inputs;
/// exactly one token of asset name "OptiVault" with quantity +1.
/// Burn branch: unconditional (any holder can burn the NFT in any TX).
///
/// This is the strict V1 replacement for the internal-verification-era
/// native-script `{all: [sig, before(slot)]}` policy, which was
/// trust-based on mint and deadline-trapped on burn (locking ~15-20 ADA
/// per vault deploy after the deadline expired). PlutusV3 UTXO-ref is
/// strictly stronger on both axes.
///
/// Reference: spec/vault-nft.md

use aiken/collection/dict
use aiken/collection/list
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{OutputReference, Transaction}
use vault/constants.{vault_nft_token_name}

validator vault_nft(utxo_ref: OutputReference) {
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    let minted = dict.to_pairs(tokens(tx.mint, policy_id))
    when minted is {
      [pair] ->
        if pair.2nd == 1 {
          // Mint branch
          let utxo_consumed =
            list.any(
              tx.inputs,
              fn(input) { input.output_reference == utxo_ref },
            )
          and {
            pair.1st == vault_nft_token_name,
            utxo_consumed,
          }
        } else if pair.2nd == -1 {
          // Burn branch — unconditional (no deadline, no signer check).
          // The holder of the UTXO carrying this NFT must spend it (and
          // hence satisfy whichever validator guards that UTXO) for the
          // burn to occur, so the burn is implicitly authorised by the
          // current owner.
          pair.1st == vault_nft_token_name
        } else {
          False
        }
      _ -> False
    }
  }

  else(_) {
    fail @"vault_nft: unsupported purpose"
  }
}
