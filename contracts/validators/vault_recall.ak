/// vault_recall — recall + merge path (split from vault_protocol)
///
/// Staking validator invoked via Withdraw-Zero from vault_proxy with
/// `UseRecall` redeemer. Handles:
///
///   RecallFromProtocol   — keeper or governance fallback consumes
///                           protocol-fill UTXO back into the vault.
///   MergeUtxo            — keeper or governance fallback consolidates
///                           secondary NoDatum UTXOs (donation merges,
///                           batcher returns) into the primary vault
///                           UTXO. Allowlist: ADA + deposit_token +
///                           registry.stable_tokens.
///
/// Rationale (2026-04-22 split from vault_protocol):
///   B@launch=1 SwapAdapter dispatch + Tier 1 oracle wire-up pushed
///   vault_protocol past the 16 KB Plutus V3 ref-script ceiling (16,500 B
///   / −116 B headroom). Since DeployToProtocol carries the adapter
///   dispatch + Tier 1 Oracle logic (the size-heavy part) and doesn't
///   share invariants with Recall/Merge beyond common helpers, split
///   along that seam:
///     vault_protocol.ak → DeployToProtocol + publish only
///     vault_recall.ak   → RecallFromProtocol + MergeUtxo + publish
///
/// Authorization boundary:
///   Both redeemers are keeper-with-fallback (keeper primary, governance
///   m-of-n after 7d keeper_inactive). Same pattern as pre-split
///   vault_protocol.

use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{flatten, quantity_of}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{NoDatum, Transaction}
use vault/helpers.{
  empty_registry, find_vault_utxo, get_continuing_datum, get_mint_quantity,
  is_gov_authorized, payload_hash_deregister_stake, read_registry_datum,
  verify_multi_input_preserved, verify_other_tokens_preserved,
  verify_output_value_min, verify_protocol_fields_preserved,
}
use vault/types.{
  ActDeregisterStake, MergeUtxo, RecallFromProtocol, VaultRedeemer,
}
use vault/validation.{
  check_immutable_fields, check_policy_fields_unchanged,
  has_no_order_inputs as val_has_no_order_inputs,
  require_keeper_stake_script_or_governance_fallback, validate_allocations,
}

validator vault_recall(
  keeper_stake_hash: ByteArray,
  governance_nft_policy: ByteArray,
  governance_nft_name: ByteArray,
) {
  withdraw(redeemer: VaultRedeemer, account: Credential, tx: Transaction) {
    expect Script(_) = account
    let (own_input, old_datum, own_lovelace, vault_input_count, proxy_hash) =
      find_vault_utxo(tx.inputs)

    when redeemer is {
      // ══════════════════════════════════════════════════════
      // RecallFromProtocol — keeper or governance fallback
      // ══════════════════════════════════════════════════════
      RecallFromProtocol { recall_amount, new_allocations, recall_token_policy, recall_token_name } -> {
        expect vault_input_count == 1
        let authorized =
          require_keeper_stake_script_or_governance_fallback(
            tx,
            keeper_stake_hash,
            old_datum.governance_policy,
            old_datum.governance_name,
            old_datum.last_compound_time,
          )
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)
        expect recall_amount > 0
        expect recall_token_policy != #""

        let is_recall_deposit =
          recall_token_policy == old_datum.deposit_token_policy && recall_token_name == old_datum.deposit_token_name
        let valid_buffer =
          if is_recall_deposit {
            new_datum.idle_buffer == old_datum.idle_buffer + recall_amount
          } else {
            new_datum.idle_buffer == old_datum.idle_buffer
          }

        expect old_datum.registry_auth_policy != #""
        let (recall_whitelist, _, recall_stable_tokens, _) =
          read_registry_datum(
            tx.reference_inputs,
            old_datum.registry_hash,
            old_datum.registry_auth_policy,
          )
        let is_recall_stable =
          list.any(
            recall_stable_tokens,
            fn(st) {
              st.policy == recall_token_policy && st.name == recall_token_name
            },
          )
        let valid_non_deposit =
          if is_recall_deposit {
            new_datum.non_deposit_value == old_datum.non_deposit_value
          } else if is_recall_stable {
            new_datum.non_deposit_value == old_datum.non_deposit_value + recall_amount
          } else {
            new_datum.non_deposit_value == old_datum.non_deposit_value
          }

        let valid_ada = verify_output_value_min(cont_output, own_lovelace)
        let valid_other_tokens =
          verify_other_tokens_preserved(
            own_input.output,
            cont_output,
            recall_token_policy,
            recall_token_name,
            #"",
            #"",
          )
        let valid_token_recall = {
          let old_qty =
            quantity_of(own_input.output.value, recall_token_policy, recall_token_name)
          let new_qty =
            quantity_of(cont_output.value, recall_token_policy, recall_token_name)
          new_qty >= old_qty + recall_amount
        }
        let valid_alloc_match = new_datum.strategy_allocations == new_allocations
        let valid_allocs =
          validate_allocations(new_allocations, new_datum.total_deposited, new_datum.idle_buffer)
        let valid_preserved = verify_protocol_fields_preserved(old_datum, new_datum)
        let valid_source =
          list.any(
            tx.inputs,
            fn(input) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  if list.has(recall_whitelist, hash) {
                    quantity_of(input.output.value, recall_token_policy, recall_token_name) >= recall_amount
                  } else {
                    False
                  }
                _ -> False
              }
            },
          )

        and {
          authorized,
          valid_buffer,
          valid_preserved,
          valid_ada,
          valid_token_recall,
          valid_other_tokens,
          valid_alloc_match,
          valid_allocs,
          get_mint_quantity(tx, old_datum.vusdcx_policy) == 0,
          check_immutable_fields(old_datum, new_datum),
          check_policy_fields_unchanged(old_datum, new_datum),
          valid_source,
          valid_non_deposit,
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash),
        }
      }

      // ══════════════════════════════════════════════════════
      // MergeUtxo — keeper or governance fallback
      // ══════════════════════════════════════════════════════
      MergeUtxo { buffer_increase, non_deposit_increase } -> {
        expect vault_input_count >= 2
        expect vault_input_count <= 5
        expect buffer_increase >= 0
        expect non_deposit_increase >= 0
        let authorized =
          require_keeper_stake_script_or_governance_fallback(
            tx,
            keeper_stake_hash,
            old_datum.governance_policy,
            old_datum.governance_name,
            old_datum.last_compound_time,
          )
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let (_, _, stable_tokens, _) =
          if old_datum.registry_auth_policy != #"" {
            read_registry_datum(
              tx.reference_inputs,
              old_datum.registry_hash,
              old_datum.registry_auth_policy,
            )
          } else {
            empty_registry()
          }

        let own_ref = own_input.output_reference
        let (actual_secondary_tokens, actual_secondary_non_deposit, all_secondary_whitelisted) =
          list.foldl(
            tx.inputs,
            (0, 0, True),
            fn(input, acc) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  if hash == proxy_hash && input.output_reference != own_ref {
                    let dep_amt =
                      quantity_of(
                        input.output.value,
                        old_datum.deposit_token_policy,
                        old_datum.deposit_token_name,
                      )
                    let (non_dep_amt, ok) =
                      list.foldl(
                        flatten(input.output.value),
                        (0, acc.3rd),
                        fn(entry, inner_acc) {
                          let (policy, name, qty) = entry
                          if policy == #"" {
                            inner_acc
                          } else if policy == old_datum.deposit_token_policy && name == old_datum.deposit_token_name {
                            inner_acc
                          } else if list.any(
                            stable_tokens,
                            fn(st) { st.policy == policy && st.name == name },
                          ) {
                            (inner_acc.1st + qty, inner_acc.2nd)
                          } else {
                            (inner_acc.1st, False)
                          }
                        },
                      )
                    (acc.1st + dep_amt, acc.2nd + non_dep_amt, ok)
                  } else {
                    acc
                  }
                _ -> acc
              }
            },
          )
        let valid_buffer_backed = buffer_increase == actual_secondary_tokens
        let valid_buffer = new_datum.idle_buffer == old_datum.idle_buffer + buffer_increase
        let valid_allocs = new_datum.strategy_allocations == old_datum.strategy_allocations
        let valid_non_deposit_bounded = non_deposit_increase == actual_secondary_non_deposit
        let valid_non_deposit =
          new_datum.non_deposit_value == old_datum.non_deposit_value + non_deposit_increase
        let valid_multi_inputs =
          verify_multi_input_preserved(tx.inputs, proxy_hash, cont_output)
        let all_secondary_no_datum =
          list.all(
            tx.inputs,
            fn(input) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  if hash == proxy_hash && input.output_reference != own_ref {
                    when input.output.datum is {
                      NoDatum -> True
                      _ -> False
                    }
                  } else {
                    True
                  }
                _ -> True
              }
            },
          )
        let valid_preserved = verify_protocol_fields_preserved(old_datum, new_datum)

        and {
          authorized,
          valid_preserved,
          valid_buffer,
          valid_buffer_backed,
          valid_allocs,
          check_immutable_fields(old_datum, new_datum),
          check_policy_fields_unchanged(old_datum, new_datum),
          new_datum.idle_buffer >= 0,
          valid_multi_inputs,
          get_mint_quantity(tx, old_datum.vusdcx_policy) == 0,
          all_secondary_no_datum,
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash),
          valid_non_deposit_bounded,
          valid_non_deposit,
          all_secondary_whitelisted,
          new_datum.non_deposit_value >= 0,
        }
      }

      // Other redeemers handled by vault_protocol / vault_gov_policy /
      // vault_gov_emergency / vault_user / vault_keeper_hot / vault_liqwid.
      _ -> False
    }
  }

  /// A2 gov-gated stake deregister.
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
    fail @"vault_recall: unsupported purpose"
  }
}
