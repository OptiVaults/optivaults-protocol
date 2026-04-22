/// vusdcx — vUSDCx share-token minting policy
///
/// MintShares / BurnShares defer mint accounting to vault_core (which
/// enforces the exact `calculate_shares_to_mint` formula on Deposit
/// and the per-batch fair-shares aggregate on BatchProcess). This
/// policy only enforces:
///   1. The vault UTXO is consumed (and carries the real Vault NFT).
///   2. Only one asset name (vUSDCx) is minted under this policy.
///   3. Mint quantity is positive on MintShares, negative on BurnShares.
///   4. A defense-in-depth structural cap of 10^18 prevents catastrophic
///      over-mint that would slip past vault_core invariants.
///
/// Compile-time anchored to (vault_hash, vault_nft_policy) so the
/// vault-identity check is forgery-proof (phantom-vault family, internal verification).

use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Transaction}
use vault/constants.{vault_nft_token_name, vusdcx_token_name}
use vault/types.{BurnShares, MintRedeemer, MintShares, VaultDatum}

validator vusdcx(vault_hash: ByteArray, vault_nft_policy: ByteArray) {
  mint(redeemer: MintRedeemer, policy_id: PolicyId, tx: Transaction) {
    // 1. Vault UTXO must be consumed in this TX
    let vault_input =
      list.find(
        tx.inputs,
        fn(input) {
          when input.output.address.payment_credential is {
            Script(hash) -> hash == vault_hash
            _ -> False
          }
        },
      )
    expect Some(vi) = vault_input
    expect InlineDatum(old_data) = vi.output.datum
    expect old_datum: VaultDatum = old_data

    // Vault Identity NFT must be present under the compile-time policy
    expect quantity_of(vi.output.value, vault_nft_policy, vault_nft_token_name) == 1

    // Exactly one asset name minted under our own policy
    let minted_pairs = dict.to_pairs(tokens(tx.mint, policy_id))
    expect [pair] = minted_pairs
    let mint_quantity = pair.2nd
    let valid_token_name = pair.1st == vusdcx_token_name

    // 10^18 catastrophic over-mint guard (defense-in-depth; vault_core
    // enforces the exact share-issuance formula).
    let reasonable_max = 1_000_000_000_000_000_000

    when redeemer is {
      MintShares ->
        and {
          mint_quantity > 0,
          mint_quantity <= reasonable_max,
          valid_token_name,
        }
      BurnShares ->
        and {
          mint_quantity < 0,
          mint_quantity >= -old_datum.total_shares,
          valid_token_name,
        }
    }
  }

  else(_) {
    fail @"vusdcx: unsupported purpose"
  }
}
