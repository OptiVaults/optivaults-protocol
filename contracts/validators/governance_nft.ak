/// governance_nft — One-shot Governance NFT (PlutusV3 UTXO-ref).
///
/// Mint branch: parameterised UTXO must be consumed in the TX inputs;
/// exactly one token of asset name `gov_name` with quantity +1.
/// Burn branch: unconditional (clean V1 sunset / V2 migration burn).
///
/// The Governance NFT is locked in the single MultisigGov UTXO. Every
/// validator that accepts governance authorization (vault_protocol,
/// registry, treasury, keeper_stake_script) anchors to this policy at
/// compile time, so the NFT's policy + name acts as a forgery-proof
/// "is the real governance UTXO consumed?" predicate.
///
/// Same security pattern as vault_nft (spec/vault-nft.md §3): the
/// consumed UTXO ref provides cryptographic mint-once; burn always
/// available because we never want a deadline-trap on the gov UTXO.

use aiken/collection/dict
use aiken/collection/list
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{OutputReference, Transaction}

validator governance_nft(utxo_ref: OutputReference, gov_name: ByteArray) {
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
            pair.1st == gov_name,
            utxo_consumed,
          }
        } else if pair.2nd == -1 {
          pair.1st == gov_name
        } else {
          False
        }
      _ -> False
    }
  }

  else(_) {
    fail @"governance_nft: unsupported purpose"
  }
}
