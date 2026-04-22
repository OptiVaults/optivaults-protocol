/// gov_signer_nft — Soul-bound recognition NFT for MultisigGov signers.
///
/// Mint/burn authority is gated on consumption of the MultisigGov UTXO
/// in the same TX (identified by the governance NFT policy + name that
/// parameterise this policy). Because every mint/burn therefore requires
/// the governance multisig threshold to sign, only governance can issue
/// or retire a signer NFT.
///
/// Asset-name convention (validator-permissive, frontend-enforced):
///   <generation_byte><signer_index_byte><first_28_bytes_of_signer_pkh>
///
/// The validator does not parse the asset name — constraining it here
/// would bloat the script for a recognition-only artefact with no
/// financial rights. The MultisigGov signers that authorise the mint
/// are responsible for sending each NFT to the correct signer's address.
/// If a mis-named NFT is issued, the same governance can burn it via
/// a later TX (burn is allowed so long as MultisigGov is consumed).
///
/// Soul-bound enforcement is a social contract: the NFT sits at each
/// signer's own wallet address, not at a custom script address. If a
/// signer transfers the NFT to an impostor, governance should
/// `RotateSigners` to remove them and `BurnRotatedOut` the stale NFT.
/// This is acceptable at V1 because the NFT confers no financial or
/// voting rights — it is recognition-only. See spec/gov-nft.md §5.
///
/// Aggregate mint-and-burn in a single TX is not rejected; governance
/// may atomically rotate (burn previous-gen NFT + mint new-gen NFT) in
/// the same RotateSigners transaction, which is the documented flow
/// in spec/gov-nft.md §4.2.

use aiken/collection/dict
use aiken/collection/list
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{Transaction}

validator gov_signer_nft(
  governance_policy: ByteArray,
  governance_name: ByteArray,
) {
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    // Require the MultisigGov UTXO to be consumed in this TX. That UTXO
    // carries exactly one governance NFT; spending it forces the TX to
    // satisfy multisig_gov's own validator (threshold signatures, action
    // kind, etc.), which is the effective authorisation source.
    let gov_consumed =
      list.any(
        tx.inputs,
        fn(input) {
          quantity_of(input.output.value, governance_policy, governance_name) == 1
        },
      )
    expect gov_consumed

    // Every token movement under this policy must be ±1. This blocks
    // accidental or malicious bulk minting of many tokens under a single
    // asset name and keeps NFT semantics clean.
    let minted = dict.to_pairs(tokens(tx.mint, policy_id))
    list.all(minted, fn(pair) { pair.2nd == 1 || pair.2nd == -1 })
  }

  else(_) {
    fail @"gov_signer_nft: unsupported purpose"
  }
}
