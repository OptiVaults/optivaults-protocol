/// vault_gov_policy — V1 governance policy redeemers (one half of the former vault_admin)
///
/// Staking validator invoked via Withdraw-Zero from vault_proxy with
/// `UseGovPolicy` redeemer. Handles all long-cooldown governance-authorized
/// VaultDatum policy mutations:
///
///   UpdateStrategy   — change allocations + buffer_target_bps (7d timelock)
///   UpdateFee        — change perf / early / min_hold within caps (14d timelock)
///   UpdateFeeSplit   — change keeper_fee_bps + gov_fee_bps (21d timelock)
///
/// Split rationale (Phase 1 of §5.4 on-chain slippage enforcement, 2026-04-21):
/// the pre-split `vault_admin` reached 15,519 B and retained only 865 B of
/// headroom — insufficient to absorb the new `UpdateSlippagePolicy` arm
/// (Phase 2) + associated payload-hash + cap helpers. Partitioning governance
/// mutations by response latency — "policy" (14-21d) vs "emergency" (0-7d
/// fallback) — preserves the semantic boundary between slow deliberate
/// changes and fast recovery paths, and gives each half ~6 KB of future
/// headroom without touching `vault_core` / `vault_protocol` / `vault_liqwid`.
///
/// The `publish` handler implements A2 gov-gated stake deregister for this
/// validator's own stake credential; the 2 ADA registration deposit is
/// recoverable on sunset via `ActDeregisterStake` (14d timelock).

use aiken/collection/list
use aiken/interval.{Finite}
use cardano/address.{Credential, Script}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{Transaction}
use vault/constants.{fee_update_cooldown_ms, max_validity_range_ms}
use vault/helpers.{
  find_vault_utxo, get_continuing_datum, get_mint_quantity, is_gov_authorized,
  payload_hash_deregister_stake, payload_hash_update_fee,
  payload_hash_update_fee_split, payload_hash_update_slippage_policy,
  payload_hash_update_strategy, verify_all_tokens_preserved,
  verify_protocol_fields_preserved,
}
use vault/types.{
  ActDeregisterStake, ActUpdateFee, ActUpdateFeeSplit, ActUpdateSlippagePolicy,
  ActUpdateStrategy, UpdateFee, UpdateFeeSplit, UpdateSlippagePolicy,
  UpdateStrategy, VaultRedeemer,
}
use vault/validation.{
  check_immutable_fields, has_no_order_inputs as val_has_no_order_inputs,
  validate_allocations, validate_update_fee, validate_update_fee_split,
  validate_update_slippage_policy,
}

validator vault_gov_policy(
  /// Governance NFT policy id — publish gate.
  /// vault_gov_policy's withdraw path reads gov info from the vault datum
  /// (see `old_datum.governance_policy` usage below), but publish runs
  /// without guaranteed access to the vault UTxO, so we anchor the gov
  /// identity at compile time here too.
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
      // UpdateStrategy — governance: allocations + buffer_target
      // ══════════════════════════════════════════════════════
      UpdateStrategy { new_allocations, new_buffer_target_bps } -> {
        expect vault_input_count == 1
        let expected_payload_hash =
          payload_hash_update_strategy(new_allocations, new_buffer_target_bps)
        let governance_authorized =
          is_gov_authorized(
            tx,
            old_datum.governance_policy,
            old_datum.governance_name,
            ActUpdateStrategy,
            expected_payload_hash,
            own_gov_hash,
          )
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let buffer_bounds_ok = and {
            new_buffer_target_bps >= 500,
            new_buffer_target_bps <= 5000,
          }

        let valid_datum = and {
            verify_protocol_fields_preserved(old_datum, new_datum),
            new_datum.idle_buffer == old_datum.idle_buffer,
            new_datum.non_deposit_value == old_datum.non_deposit_value,
            check_immutable_fields(old_datum, new_datum),
            new_datum.performance_fee_bps == old_datum.performance_fee_bps,
            new_datum.early_withdraw_fee_bps == old_datum.early_withdraw_fee_bps,
            new_datum.min_hold_seconds == old_datum.min_hold_seconds,
            new_datum.keeper_fee_bps == old_datum.keeper_fee_bps,
            new_datum.gov_fee_bps == old_datum.gov_fee_bps,
            new_datum.max_slippage_bps == old_datum.max_slippage_bps,
            new_datum.min_swap_peg_bps == old_datum.min_swap_peg_bps,
            new_datum.buffer_target_bps == new_buffer_target_bps,
          }
        let valid_alloc_match = new_datum.strategy_allocations == new_allocations
        let valid_allocs =
          validate_allocations(new_allocations, new_datum.total_deposited, new_datum.idle_buffer)
        let valid_value = verify_all_tokens_preserved(own_input.output, cont_output)

        and {
          governance_authorized,
          buffer_bounds_ok,
          valid_datum,
          valid_alloc_match,
          valid_allocs,
          valid_value,
          get_mint_quantity(tx, old_datum.vusdcx_policy) == 0,
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash),
        }
      }

      // ══════════════════════════════════════════════════════
      // UpdateFee — governance: perf + early + min_hold
      // ══════════════════════════════════════════════════════
      UpdateFee { new_performance_fee_bps, new_early_withdraw_fee_bps, new_min_hold_seconds } -> {
        expect vault_input_count == 1
        let expected_payload_hash =
          payload_hash_update_fee(
            new_performance_fee_bps,
            new_early_withdraw_fee_bps,
            new_min_hold_seconds,
          )
        let governance_authorized =
          is_gov_authorized(
            tx,
            old_datum.governance_policy,
            old_datum.governance_name,
            ActUpdateFee,
            expected_payload_hash,
            own_gov_hash,
          )
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let valid_update =
          validate_update_fee(
            old_datum,
            new_datum,
            new_performance_fee_bps,
            new_early_withdraw_fee_bps,
            new_min_hold_seconds,
          )
        let valid_value = verify_all_tokens_preserved(own_input.output, cont_output)
        let no_mint = get_mint_quantity(tx, old_datum.vusdcx_policy) == 0
        let no_order_inputs =
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash)

        let valid_time =
          when (
            tx.validity_range.lower_bound.bound_type,
            tx.validity_range.upper_bound.bound_type,
          ) is {
            (Finite(now), Finite(upper)) ->
              and {
                upper - now <= max_validity_range_ms,
                new_datum.last_fee_update_time <= upper,
                new_datum.last_fee_update_time >= now,
                now >= old_datum.last_fee_update_time + fee_update_cooldown_ms,
              }
            _ -> False
          }

        and {
          governance_authorized,
          valid_update,
          valid_value,
          no_mint,
          no_order_inputs,
          valid_time,
        }
      }

      // ══════════════════════════════════════════════════════
      // UpdateFeeSplit — governance, 21-day timelock (enforced by multisig_gov)
      // ══════════════════════════════════════════════════════
      UpdateFeeSplit { new_keeper_fee_bps, new_gov_fee_bps } -> {
        expect vault_input_count == 1
        let expected_payload_hash =
          payload_hash_update_fee_split(new_keeper_fee_bps, new_gov_fee_bps)
        let governance_authorized =
          is_gov_authorized(
            tx,
            old_datum.governance_policy,
            old_datum.governance_name,
            ActUpdateFeeSplit,
            expected_payload_hash,
            own_gov_hash,
          )
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let valid_update =
          validate_update_fee_split(
            old_datum,
            new_datum,
            new_keeper_fee_bps,
            new_gov_fee_bps,
          )
        let valid_value = verify_all_tokens_preserved(own_input.output, cont_output)
        let no_mint = get_mint_quantity(tx, old_datum.vusdcx_policy) == 0
        let no_order_inputs =
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash)

        let valid_time =
          when (
            tx.validity_range.lower_bound.bound_type,
            tx.validity_range.upper_bound.bound_type,
          ) is {
            (Finite(now), Finite(upper)) -> upper - now <= max_validity_range_ms
            _ -> False
          }

        and {
          governance_authorized,
          valid_update,
          valid_value,
          no_mint,
          no_order_inputs,
          valid_time,
        }
      }

      // ══════════════════════════════════════════════════════
      // UpdateSlippagePolicy — governance, 48-hour timelock (§5.4 Phase 2)
      // ══════════════════════════════════════════════════════
      UpdateSlippagePolicy { new_max_slippage_bps, new_min_swap_peg_bps } -> {
        expect vault_input_count == 1
        let expected_payload_hash =
          payload_hash_update_slippage_policy(
            new_max_slippage_bps,
            new_min_swap_peg_bps,
          )
        let governance_authorized =
          is_gov_authorized(
            tx,
            old_datum.governance_policy,
            old_datum.governance_name,
            ActUpdateSlippagePolicy,
            expected_payload_hash,
            own_gov_hash,
          )
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let valid_update =
          validate_update_slippage_policy(
            old_datum,
            new_datum,
            new_max_slippage_bps,
            new_min_swap_peg_bps,
          )
        let valid_value = verify_all_tokens_preserved(own_input.output, cont_output)
        let no_mint = get_mint_quantity(tx, old_datum.vusdcx_policy) == 0
        let no_order_inputs =
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash)

        let valid_time =
          when (
            tx.validity_range.lower_bound.bound_type,
            tx.validity_range.upper_bound.bound_type,
          ) is {
            (Finite(now), Finite(upper)) -> upper - now <= max_validity_range_ms
            _ -> False
          }

        and {
          governance_authorized,
          valid_update,
          valid_value,
          no_mint,
          no_order_inputs,
          valid_time,
        }
      }

      // Other redeemers handled by vault_gov_emergency / vault_protocol /
      // vault_core / vault_liqwid.
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
    fail @"vault_gov_policy: unsupported purpose"
  }
}
