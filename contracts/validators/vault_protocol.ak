/// vault_protocol — V1 DEX deploy redeemer (post split)
///
/// Staking validator invoked via Withdraw-Zero from vault_proxy with
/// `UseProtocol` redeemer. Post 2026-04-22 split for B@launch=1
/// SwapAdapter dispatch, vault_protocol holds ONLY DeployToProtocol.
/// Recall + Merge redeemers moved to `vault_recall.ak`.
///
///   DeployToProtocol     — keeper sends USDCx (or stables) to a
///                           registry-whitelisted protocol (Minswap
///                           V2 batcher via SwapAdapter). Bounded ADA
///                           spend per TX (max 5 ADA, vault floor 10 ADA).
///                           Adapter dispatch + Tier 2 peg-floor +
///                           optional Tier 1 oracle bound via
///                           `verify_swap_via_adapter`.

use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{lovelace_of, quantity_of}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{Transaction}
use vault/constants.{
  max_deploy_ada, min_order_amount, min_vault_ada,
}
use vault/helpers.{
  find_vault_utxo, get_continuing_datum, get_mint_quantity, is_gov_authorized,
  payload_hash_deregister_stake, read_registry_datum_full,
  verify_destination_whitelisted, verify_other_tokens_preserved,
  verify_protocol_fields_preserved,
}
use vault/swap_adapter.{verify_swap_via_adapter}
use vault/types.{ActDeregisterStake, DeployToProtocol, VaultRedeemer}
use vault/validation.{
  check_immutable_fields, check_policy_fields_unchanged,
  has_no_order_inputs as val_has_no_order_inputs, require_keeper_stake_script,
  validate_allocations, validate_deploy_frozen_gate,
}

validator vault_protocol(
  keeper_stake_hash: ByteArray,
  /// Governance NFT policy id (A2, 2026-04-20) — publish gate.
  governance_nft_policy: ByteArray,
  /// Governance NFT asset name (A2).
  governance_nft_name: ByteArray,
) {
  withdraw(redeemer: VaultRedeemer, account: Credential, tx: Transaction) {
    expect Script(_) = account
    let (own_input, old_datum, own_lovelace, vault_input_count, proxy_hash) =
      find_vault_utxo(tx.inputs)

    when redeemer is {
      // ══════════════════════════════════════════════════════
      // DeployToProtocol — keeper, bounded ADA spend
      // ══════════════════════════════════════════════════════
      DeployToProtocol { deploy_amount, new_allocations, deploy_token_policy, deploy_token_name, dest_output_idx } -> {
        expect vault_input_count == 1
        // Phase 1 governance safety — Layer 2 (2026-04-25): freeze gate
        // permits swap-out (deploy_token != deposit_token) under
        // frozen=1 so keeper can drain NDV stable → USDCx for user
        // withdraw even during emergency freeze. See
        // `validate_deploy_frozen_gate` in lib/vault/validation.ak for
        // attack-surface analysis + protection bounds. Supply-to-Liqwid
        // (deploy_token == deposit_token) remains blocked under freeze.
        expect
          validate_deploy_frozen_gate(
            old_datum.frozen,
            deploy_token_policy,
            deploy_token_name,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
          )
        // Phase 1 governance safety — Layer 3 (2026-04-25): under
        // CommunitySunset, the keeper authorization is bypassed so any
        // vUSDCx holder can drive a swap-out via SwapAdapter (combined
        // with the Layer 2 frozen-gate exception above). The
        // SwapAdapter validator still enforces destination=vault +
        // peg_floor, so the sunset bypass only relaxes who can
        // *initiate* the swap, not where the resulting USDCx lands.
        let keeper_authorized = or {
            require_keeper_stake_script(tx, keeper_stake_hash),
            old_datum.community_sunset_triggered == 1,
          }
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        expect deploy_amount > 0
        expect deploy_amount >= min_order_amount
        expect deploy_token_policy != #""

        let is_deploy_deposit =
          deploy_token_policy == old_datum.deposit_token_policy && deploy_token_name == old_datum.deposit_token_name
        let valid_buffer =
          if is_deploy_deposit {
            new_datum.idle_buffer == old_datum.idle_buffer - deploy_amount
          } else {
            new_datum.idle_buffer == old_datum.idle_buffer
          }

        expect old_datum.registry_auth_policy != #""
        let (deploy_whitelist, _, deploy_stable_tokens, _, asset_oracles, adapter_hashes) =
          read_registry_datum_full(
            tx.reference_inputs,
            old_datum.registry_hash,
            old_datum.registry_auth_policy,
          )
        let is_stable =
          list.any(
            deploy_stable_tokens,
            fn(st) {
              st.policy == deploy_token_policy && st.name == deploy_token_name
            },
          )
        let valid_non_deposit =
          if is_deploy_deposit {
            new_datum.non_deposit_value == old_datum.non_deposit_value
          } else if is_stable {
            and {
              new_datum.non_deposit_value == old_datum.non_deposit_value - deploy_amount,
              new_datum.non_deposit_value >= 0,
            }
          } else {
            new_datum.non_deposit_value == old_datum.non_deposit_value
          }

        let valid_ada = {
          let out_ada = lovelace_of(cont_output.value)
          and {
            out_ada >= own_lovelace - max_deploy_ada,
            out_ada <= own_lovelace,
            out_ada >= min_vault_ada,
          }
        }

        let valid_token_deploy = {
          let old_qty =
            quantity_of(own_input.output.value, deploy_token_policy, deploy_token_name)
          let new_qty =
            quantity_of(cont_output.value, deploy_token_policy, deploy_token_name)
          new_qty == old_qty - deploy_amount
        }
        let valid_other_tokens =
          verify_other_tokens_preserved(
            own_input.output,
            cont_output,
            deploy_token_policy,
            deploy_token_name,
            #"",
            #"",
          )
        let valid_alloc_match = new_datum.strategy_allocations == new_allocations
        let valid_allocs =
          validate_allocations(new_allocations, new_datum.total_deposited, new_datum.idle_buffer)
        let valid_preserved = verify_protocol_fields_preserved(old_datum, new_datum)
        let valid_destination =
          verify_destination_whitelisted(
            tx.outputs,
            deploy_whitelist,
            deploy_amount,
            deploy_token_policy,
            deploy_token_name,
            dest_output_idx,
          )

        // §B@launch=1 adapter dispatch — consolidates adapter detection,
        // redeemer read, Tier 2 peg-floor + optional Tier 1 oracle bound
        // into a single verify_swap_via_adapter call (see
        // lib/vault/swap_adapter.ak). Moves ~400-600 B of boilerplate
        // out of vault_protocol's bytecode.
        let valid_swap =
          verify_swap_via_adapter(
            tx,
            adapter_hashes,
            asset_oracles,
            dest_output_idx,
            deploy_amount,
            old_datum.min_swap_peg_bps,
            old_datum.max_slippage_bps,
          )

        and {
          keeper_authorized,
          valid_buffer,
          valid_preserved,
          valid_ada,
          valid_token_deploy,
          valid_other_tokens,
          valid_alloc_match,
          valid_allocs,
          get_mint_quantity(tx, old_datum.vusdcx_policy) == 0,
          check_immutable_fields(old_datum, new_datum),
          check_policy_fields_unchanged(old_datum, new_datum),
          valid_destination,
          valid_swap,
          valid_non_deposit,
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash),
        }
      }

      // Other redeemers handled by vault_recall / vault_gov_policy /
      // vault_gov_emergency / vault_user / vault_keeper_hot / vault_liqwid.
      _ -> False
    }
  }

  /// A2 gov-gated stake deregister (see vault_core publish comment for the
  /// Certificate / Credential signature rationale).
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
    fail @"vault_protocol: unsupported purpose"
  }
}
