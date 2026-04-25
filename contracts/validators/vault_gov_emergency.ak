/// vault_gov_emergency — V1 governance emergency path (EmergencyWithdraw only, post-Phase-77c split)
///
/// Staking validator invoked via Withdraw-Zero from vault_proxy with
/// `UseGovEmergency` redeemer. Handles the sole remaining emergency
/// redeemer:
///
///   EmergencyWithdraw — governance freeze + Liqwid loss write-off
///                       (0d timelock for rapid depeg / Liqwid
///                       bad-debt response; m-of-n consensus still
///                       required).
///
/// Split history:
///   (1) Phase 1 of §5.4 on-chain slippage enforcement (2026-04-21) —
///       vault_admin was split into vault_gov_policy + vault_gov_emergency
///       partitioned by response latency (policy vs emergency path).
///   (2) Phase 77c (2026-04-22) — AdminDeployNonDeposit was extracted
///       into standalone `vault_admin_deploy.ak`. The SwapAdapter
///       dispatch + destination-whitelist check + 6-tuple registry
///       read were ~6-7 KB of bytecode used ONLY by AdminDeployNonDeposit;
///       hoisting them out restores headroom on EmergencyWithdraw's
///       host and prevents future SwapAdapter additions from growing
///       the emergency-path attack surface.
///
/// "Emergency" here covers redeemers whose validation surface must be
/// self-contained because they run under adversarial conditions
/// (Liqwid bad-debt write-off, keeper failure). Keeping AdminDeployNonDeposit
/// out of this file preserves that invariant.
///
/// The `publish` handler implements A2 gov-gated stake deregister for this
/// validator's own stake credential; the 2 ADA registration deposit is
/// recoverable on sunset via `ActDeregisterStake` (14d timelock).

use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{flatten, quantity_of}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{Transaction}
use vault/constants.{max_allocations}
use vault/helpers.{
  find_vault_utxo, get_continuing_datum, get_mint_quantity, is_gov_authorized,
  payload_hash_deregister_stake, payload_hash_emergency_withdraw,
  verify_multi_input_preserved,
}
use vault/types.{
  ActDeregisterStake, ActEmergencyWithdraw, EmergencyWithdraw, VaultRedeemer,
}
use vault/validation.{
  check_immutable_fields, has_no_order_inputs as val_has_no_order_inputs,
  validate_emergency_freeze_only,
}

validator vault_gov_emergency(
  /// Governance NFT policy id — publish gate. Same rationale as in
  /// `vault_gov_policy`: publish handler cannot rely on a vault UTxO
  /// being present, so the gov identity is a compile-time parameter.
  governance_nft_policy: ByteArray,
  /// Governance NFT asset name.
  governance_nft_name: ByteArray,
) {
  withdraw(redeemer: VaultRedeemer, account: Credential, tx: Transaction) {
    expect Script(own_gov_hash) = account
    let (own_input, old_datum, _own_lovelace, vault_input_count, proxy_hash) =
      find_vault_utxo(tx.inputs)

    when redeemer is {
      // ══════════════════════════════════════════════════════
      // EmergencyWithdraw — governance: loss write-off + freeze
      // ══════════════════════════════════════════════════════
      EmergencyWithdraw { loss_amount, freeze_flag } -> {
        expect vault_input_count >= 1
        expect vault_input_count <= 5
        let expected_payload_hash =
          payload_hash_emergency_withdraw(loss_amount, freeze_flag)
        let governance_authorized =
          is_gov_authorized(
            tx,
            old_datum.governance_policy,
            old_datum.governance_name,
            ActEmergencyWithdraw,
            expected_payload_hash,
            own_gov_hash,
          )
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let own_ref = own_input.output_reference
        let all_secondaries_clean =
          list.all(
            tx.inputs,
            fn(input) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  if hash == proxy_hash && input.output_reference != own_ref {
                    list.all(
                      flatten(input.output.value),
                      fn(entry) {
                        let (policy, name, _) = entry
                        or {
                          policy == #"",
                          policy == old_datum.deposit_token_policy && name == old_datum.deposit_token_name,
                        }
                      },
                    )
                  } else {
                    True
                  }
                _ -> True
              }
            },
          )

        let alloc_sum =
          list.foldl(
            new_datum.strategy_allocations,
            0,
            fn(a, acc) { acc + a.amount },
          )
        let liqwid_principal =
          list.foldl(
            new_datum.liqwid_positions,
            0,
            fn(p, acc) { acc + p.supplied_value },
          )
        let valid_allocs = and {
            list.length(new_datum.strategy_allocations) <= max_allocations,
            list.all(
              new_datum.strategy_allocations,
              fn(a) {
                and {
                  a.amount >= 0,
                  a.expected_apy_bps >= 0,
                  a.expected_apy_bps <= 10_000,
                }
              },
            ),
            alloc_sum + new_datum.idle_buffer <= new_datum.total_deposited + new_datum.non_deposit_value + liqwid_principal,
          }
        let no_mint = get_mint_quantity(tx, old_datum.vusdcx_policy) == 0
        let no_order_inputs =
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash)
        let valid_multi_inputs =
          verify_multi_input_preserved(tx.inputs, proxy_hash, cont_output)

        let physical_deposit_token =
          quantity_of(
            cont_output.value,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
          )
        let valid_buffer = and {
            new_datum.idle_buffer >= old_datum.idle_buffer,
            new_datum.idle_buffer <= new_datum.total_deposited + new_datum.non_deposit_value,
            new_datum.idle_buffer <= physical_deposit_token,
          }
        let valid_non_deposit = and {
            new_datum.non_deposit_value >= 0,
            new_datum.non_deposit_value <= old_datum.non_deposit_value,
          }
        let valid_frozen = and {
            new_datum.frozen == freeze_flag,
            or {
              freeze_flag == 0,
              freeze_flag == 1,
            },
          }
        // Layer 3 (Dead-man-switch) preservation: EmergencyWithdraw must
        // not flip community_sunset_triggered. Sunset is owned by
        // vault_user.CommunitySunset (one-way 0 → 1 by community vote).
        let valid_sunset =
          new_datum.community_sunset_triggered == old_datum.community_sunset_triggered

        // Phase 1 governance safety (2026-04-25 — Layer 1 of three-layer
        // founder-only-acceptable design): EmergencyWithdraw is freeze-only.
        // See `validate_emergency_freeze_only` in lib/vault/validation.ak
        // for the rationale + design notes.
        let valid_deposited =
          validate_emergency_freeze_only(loss_amount, old_datum, new_datum)

        and {
          governance_authorized,
          valid_deposited,
          new_datum.total_shares == old_datum.total_shares,
          new_datum.last_compound_time == old_datum.last_compound_time,
          new_datum.last_realloc_time == old_datum.last_realloc_time,
          new_datum.last_fee_update_time == old_datum.last_fee_update_time,
          new_datum.last_ada_swap_time == old_datum.last_ada_swap_time,
          check_immutable_fields(old_datum, new_datum),
          new_datum.performance_fee_bps == old_datum.performance_fee_bps,
          new_datum.early_withdraw_fee_bps == old_datum.early_withdraw_fee_bps,
          new_datum.min_hold_seconds == old_datum.min_hold_seconds,
          new_datum.buffer_target_bps == old_datum.buffer_target_bps,
          new_datum.keeper_fee_bps == old_datum.keeper_fee_bps,
          new_datum.gov_fee_bps == old_datum.gov_fee_bps,
          new_datum.max_slippage_bps == old_datum.max_slippage_bps,
          new_datum.min_swap_peg_bps == old_datum.min_swap_peg_bps,
          valid_allocs,
          no_mint,
          no_order_inputs,
          valid_multi_inputs,
          all_secondaries_clean,
          valid_buffer,
          valid_non_deposit,
          valid_frozen,
          valid_sunset,
        }
      }

      // AdminDeployNonDeposit is now handled by vault_admin_deploy.ak
      // (Phase 77c split, 2026-04-22). Other redeemers are handled by
      // vault_gov_policy / vault_protocol / vault_recall / vault_user /
      // vault_keeper_hot / vault_swap_ada / vault_liqwid.
      _ -> False
    }
  }

  /// A2 gov-gated stake deregister — see vault_core publish comment for the
  /// handler-signature + payload-hash ceremony detail. Same pattern as the
  /// pre-split vault_admin's publish handler.
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
    fail @"vault_gov_emergency: unsupported purpose"
  }
}
