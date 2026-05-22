/// vault_admin_deploy — AdminDeployNonDeposit recovery path (2026-04-22 admin-deploy extraction from vault_gov_emergency)
///
/// Staking validator invoked via Withdraw-Zero from vault_proxy with
/// the `UseAdminDeploy` redeemer. Handles a single redeemer:
///
///   AdminDeployNonDeposit — governance-authorized non-deposit-token
///                           deployment (7d keeper-inactive + 21d
///                           registry-stable preconditions). Used to
///                           move stranded non-deposit tokens out of
///                           the vault via a whitelisted SwapAdapter
///                           dispatch when the keeper hot path is
///                           unavailable.
///
/// Split rationale (admin-deploy extraction, 2026-04-22):
///   Pre-split vault_gov_emergency carried EmergencyWithdraw + Admin-
///   DeployNonDeposit and sat at 15,425 B / 959 B headroom. The
///   SwapAdapter dispatch (`verify_swap_via_adapter`) + destination-
///   whitelist check + 6-tuple registry read — all needed ONLY by
///   AdminDeployNonDeposit — were accounting for ~6-7 KB of vault_
///   gov_emergency's footprint. Extracting AdminDeployNonDeposit:
///     - Removes the SwapAdapter machinery + registry read from
///       vault_gov_emergency (restores ~6-7 KB headroom on the
///       EmergencyWithdraw host).
///     - Keeps EmergencyWithdraw on a tight emergency validator whose
///       attack surface cannot grow by future SwapAdapter additions.
///     - Gives AdminDeployNonDeposit its own stake credential, A2
///       publish path, and UseAdminDeploy Withdraw-Zero route in
///       vault_proxy.
///
/// Authorization: governance-only (m-of-n + payload-hash bind +
/// 7d timelock) plus the additional on-chain gates:
///   - `last_compound_time + 7d < now`       (keeper inactive)
///   - `registry.last_update_time + 21d < now` (registry stable)
///   - destination address in `registry.protocol_hashes` whitelist
///   - SwapAdapter dispatch validates against registry's
///     `swap_adapter_hashes` + `asset_oracles`
///
/// Compile-time anchors:
///   governance_nft_policy  — governance + A2 publish handler gate.
///   governance_nft_name    — governance + A2 publish handler gate.

use aiken/collection/list
use aiken/interval.{Finite}
use cardano/address.{Credential, Script}
use cardano/assets.{quantity_of}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{Transaction}
use vault/constants.{
  admin_deploy_registry_cooldown_ms, keeper_inactive_ms, min_valid_timestamp_ms,
}
use vault/helpers.{
  find_vault_utxo, get_continuing_datum, get_mint_quantity, is_gov_authorized,
  payload_hash_admin_deploy, payload_hash_deregister_stake,
  read_registry_datum_full, verify_destination_whitelisted,
  verify_other_tokens_preserved, verify_output_value_min,
  verify_protocol_fields_preserved,
}
use vault/swap_adapter.{verify_swap_via_adapter}
use vault/types.{
  ActAdminDeployNonDeposit, ActDeregisterStake, AdminDeployNonDeposit,
  VaultRedeemer,
}
use vault/validation.{
  check_immutable_fields, has_no_order_inputs as val_has_no_order_inputs,
  validate_allocations,
}

validator vault_admin_deploy(
  governance_nft_policy: ByteArray,
  governance_nft_name: ByteArray,
) {
  withdraw(redeemer: VaultRedeemer, account: Credential, tx: Transaction) {
    expect Script(own_gov_hash) = account
    let (own_input, old_datum, own_lovelace, vault_input_count, proxy_hash) =
      find_vault_utxo(tx.inputs)

    when redeemer is {
      // ══════════════════════════════════════════════════════
      // AdminDeployNonDeposit — governance, 7d keeper-inactive + 21d registry timelock
      // ══════════════════════════════════════════════════════
      AdminDeployNonDeposit { deploy_amount, new_allocations, deploy_token_policy, deploy_token_name, dest_output_idx } -> {
        expect vault_input_count == 1
        expect deploy_amount > 0
        expect deploy_token_policy != #""
        expect !( deploy_token_policy == old_datum.deposit_token_policy && deploy_token_name == old_datum.deposit_token_name )
        expect old_datum.non_deposit_value >= deploy_amount
        // L-7: frozen-block relaxed — AdminDeployNonDeposit is a recovery path
        // for stranded non-deposit tokens; governance-gated + 7d keeper
        // inactive + 21d registry stable are the real gates. Per vault-datum.md
        // §2.4, frozen=1 blocks productive ops (Compound/Batch/Deploy) but
        // not recovery paths (Recall/Merge/Withdraw/Emergency). AdminDeployNonDeposit
        // was previously incorrectly bucketed with productive ops.
        expect old_datum.registry_auth_policy != #""
        let expected_payload_hash =
          payload_hash_admin_deploy(
            deploy_amount,
            deploy_token_policy,
            deploy_token_name,
          )
        let governance_authorized =
          is_gov_authorized(
            tx,
            old_datum.governance_policy,
            old_datum.governance_name,
            ActAdminDeployNonDeposit,
            expected_payload_hash,
            own_gov_hash,
          )
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)
        let (whitelist, registry_last_update, _, _, asset_oracles, adapter_hashes) =
          read_registry_datum_full(
            tx.reference_inputs,
            old_datum.registry_hash,
            old_datum.registry_auth_policy,
          )

        let keeper_inactive =
          when tx.validity_range.lower_bound.bound_type is {
            Finite(now) ->
              and {
                old_datum.last_compound_time > min_valid_timestamp_ms,
                now >= old_datum.last_compound_time + keeper_inactive_ms,
              }
            _ -> False
          }
        let registry_stable =
          when tx.validity_range.lower_bound.bound_type is {
            Finite(now) ->
              and {
                registry_last_update > 0,
                now >= registry_last_update + admin_deploy_registry_cooldown_ms,
              }
            _ -> False
          }
        let old_qty =
          quantity_of(own_input.output.value, deploy_token_policy, deploy_token_name)

        and {
          governance_authorized,
          keeper_inactive,
          registry_stable,
          verify_protocol_fields_preserved(old_datum, new_datum),
          new_datum.idle_buffer == old_datum.idle_buffer,
          new_datum.non_deposit_value == old_datum.non_deposit_value - deploy_amount,
          new_datum.non_deposit_value >= 0,
          new_datum.strategy_allocations == new_allocations,
          check_immutable_fields(old_datum, new_datum),
          new_datum.performance_fee_bps == old_datum.performance_fee_bps,
          new_datum.early_withdraw_fee_bps == old_datum.early_withdraw_fee_bps,
          new_datum.min_hold_seconds == old_datum.min_hold_seconds,
          new_datum.buffer_target_bps == old_datum.buffer_target_bps,
          new_datum.keeper_fee_bps == old_datum.keeper_fee_bps,
          new_datum.gov_fee_bps == old_datum.gov_fee_bps,
          new_datum.max_slippage_bps == old_datum.max_slippage_bps,
          new_datum.min_swap_peg_bps == old_datum.min_swap_peg_bps,
          quantity_of(cont_output.value, deploy_token_policy, deploy_token_name) == old_qty - deploy_amount,
          verify_output_value_min(cont_output, own_lovelace),
          verify_other_tokens_preserved(own_input.output, cont_output, deploy_token_policy, deploy_token_name, #"", #""),
          validate_allocations(new_allocations, new_datum.total_deposited, new_datum.idle_buffer),
          get_mint_quantity(tx, old_datum.vusdcx_policy) == 0,
          // `?` marker emits an Aiken trace on False return so trace-
          // instrumented ceremony builds surface whitelist-mismatch
          // failures directly instead of producing an empty `traces: []`
          // dead-end. Zero size impact on production builds without
          // `--trace-level verbose`.
          verify_destination_whitelisted(tx.outputs, whitelist, deploy_amount, deploy_token_policy, deploy_token_name, dest_output_idx)?,
          // See vault_protocol.ak for the same expected_recipient_addr
          // argument rationale.
          verify_swap_via_adapter(
            tx,
            adapter_hashes,
            asset_oracles,
            dest_output_idx,
            deploy_amount,
            old_datum.min_swap_peg_bps,
            old_datum.max_slippage_bps,
            own_input.output.address,
          )?,
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash),
        }
      }

      // Other redeemers handled by vault_gov_emergency / vault_gov_policy /
      // vault_protocol / vault_recall / vault_user / vault_keeper_hot /
      // vault_swap_ada / vault_liqwid.
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
    fail @"vault_admin_deploy: unsupported purpose"
  }
}
