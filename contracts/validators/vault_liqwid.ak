/// vault_liqwid — V1 Liqwid integration redeemers
///
/// Staking validator invoked via Withdraw-Zero from vault_proxy. Handles:
///   SupplyToLiqwid — supply USDCx/DJED/USDM to a Liqwid market, receive qTokens
///   RecallFromLiqwid — burn qTokens, receive underlying + interest
///
/// Keeper path requires `underlying_received >= position.supplied_value`
/// (strict). Governance fallback path (m-of-n + 7d keeper-inactive)
/// permits partial recall, with shortfall written off against
/// total_deposited (orphan-qToken guard, internal verification: governance must zero
/// out qToken holding to prevent registry-manipulation re-materialization).

use aiken/collection/list
use cardano/address.{Credential, Inline, Script}
use cardano/assets.{quantity_of}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{Transaction}
use vault/constants.{max_allocations}
use vault/helpers.{
  check_liqwid_core, find_liqwid_market, find_vault_utxo, get_continuing_datum,
  get_mint_quantity, is_gov_authorized, payload_hash_deregister_stake,
  read_registry_datum, verify_other_tokens_preserved, verify_output_value_min,
}
use vault/types.{
  ActDeregisterStake, LiqwidPosition, RecallFromLiqwid, SupplyToLiqwid,
  VaultRedeemer,
}
use vault/validation.{
  check_immutable_fields, has_no_order_inputs as val_has_no_order_inputs,
  require_keeper_stake_script, require_keeper_stake_script_or_governance_fallback,
}

validator vault_liqwid(
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
      // SupplyToLiqwid
      // ══════════════════════════════════════════════════════
      SupplyToLiqwid { market_id, supply_amount, dest_output_idx } -> {
        expect vault_input_count == 1
        expect supply_amount > 0
        expect old_datum.frozen == 0
        let keeper_authorized = require_keeper_stake_script(tx, keeper_stake_hash)

        let market = find_liqwid_market(tx, old_datum, market_id)
        expect market.active
        let u_pol = market.underlying_policy
        let u_name = market.underlying_name
        let q_pol = market.qtoken_policy
        let q_name = market.qtoken_name
        expect u_pol != #""

        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)
        let in_val = own_input.output.value
        let out_val = cont_output.value

        let valid_underlying_decrease =
          quantity_of(out_val, u_pol, u_name) == quantity_of(in_val, u_pol, u_name) - supply_amount
        let qtoken_delta =
          quantity_of(out_val, q_pol, q_name) - quantity_of(in_val, q_pol, q_name)
        let valid_qtoken_increase = qtoken_delta > 0

        // Anti-double-satisfaction: dest_output_idx + stake credential check.
        let valid_destination = {
          expect Some(dest_output) = list.at(tx.outputs, dest_output_idx)
          when dest_output.address.payment_credential is {
            Script(hash) ->
              if hash == market.action_addr_hash {
                let stake_ok =
                  when dest_output.address.stake_credential is {
                    None -> True
                    Some(cred) ->
                      when cred is {
                        Inline(inner) ->
                          when inner is {
                            Script(stake_hash) -> stake_hash == market.action_addr_hash
                            _ -> False
                          }
                        _ -> False
                      }
                  }
                and {
                  stake_ok,
                  quantity_of(dest_output.value, u_pol, u_name) >= supply_amount,
                }
              } else {
                False
              }
            _ -> False
          }
        }

        let is_underlying_deposit =
          u_pol == old_datum.deposit_token_policy && u_name == old_datum.deposit_token_name
        let expected_buffer =
          if is_underlying_deposit {
            old_datum.idle_buffer - supply_amount
          } else {
            old_datum.idle_buffer
          }
        let expected_ndv =
          if is_underlying_deposit {
            old_datum.non_deposit_value
          } else {
            old_datum.non_deposit_value - supply_amount
          }

        expect list.length(old_datum.liqwid_positions) < max_allocations
        let no_duplicate_market =
          list.all(old_datum.liqwid_positions, fn(p) { p.market_id != market_id })
        let new_position =
          LiqwidPosition {
            market_id,
            qtokens_held: qtoken_delta,
            supplied_value: supply_amount,
          }

        let valid_other_tokens =
          verify_other_tokens_preserved(
            own_input.output,
            cont_output,
            u_pol,
            u_name,
            q_pol,
            q_name,
          )

        and {
          keeper_authorized,
          valid_underlying_decrease,
          valid_qtoken_increase,
          // (2026-05-30): bind the credited qtokens to a real
          // in-TX mint — symmetric to the recall burn-binding (line ~230,
          // `get_mint_quantity == -qtokens_held`). Without it, qtoken_delta
          // could be satisfied by pre-existing / fabricated qtokens routed
          // into the vault output instead of freshly market-minted claims,
          // recording a position whose qtokens are not provably redeemable.
          // (The recall `>=` floor defends downstream; this closes the
          // provenance gap at supply time.)
          get_mint_quantity(tx, q_pol) == qtoken_delta,
          valid_destination,
          valid_other_tokens,
          no_duplicate_market,
          new_datum.liqwid_positions == list.push(old_datum.liqwid_positions, new_position),
          new_datum.idle_buffer == expected_buffer,
          new_datum.non_deposit_value == expected_ndv,
          check_liqwid_core(old_datum, new_datum, cont_output, own_lovelace, tx),
          new_datum.last_ada_swap_time == old_datum.last_ada_swap_time,
        }
      }

      // ══════════════════════════════════════════════════════
      // RecallFromLiqwid — keeper strict, governance fallback partial
      // ══════════════════════════════════════════════════════
      RecallFromLiqwid { market_id } -> {
        expect vault_input_count == 1
        // Phase 1 governance safety — Layer 3 (2026-04-25): under
        // CommunitySunset, any vUSDCx holder can drive RecallFromLiqwid
        // without keeper or gov signature. The downstream `is_keeper`
        // check still gates strict-principal (keeper) vs partial-loss
        // accounting (everyone else), so sunset uses the same partial
        // path as governance fallback — physical underlying recovered,
        // any shortfall written off as actual realized loss.
        let authorized = or {
            require_keeper_stake_script_or_governance_fallback(
              tx,
              keeper_stake_hash,
              old_datum.governance_policy,
              old_datum.governance_name,
              old_datum.last_compound_time,
            ),
            old_datum.community_sunset_triggered == 1,
          }

        let market = find_liqwid_market(tx, old_datum, market_id)
        let u_pol = market.underlying_policy
        let u_name = market.underlying_name
        let q_pol = market.qtoken_policy
        let q_name = market.qtoken_name
        expect u_pol != #""

        expect Some(position) =
          list.find(old_datum.liqwid_positions, fn(p) { p.market_id == market_id })

        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)
        let in_val = own_input.output.value
        let out_val = cont_output.value

        // Distinguish keeper vs governance branch
        let is_keeper = require_keeper_stake_script(tx, keeper_stake_hash)

        let valid_qtoken_exit =
          if is_keeper {
            quantity_of(out_val, q_pol, q_name) == quantity_of(in_val, q_pol, q_name) - position.qtokens_held
          } else {
            let exit_qty =
              quantity_of(in_val, q_pol, q_name) - quantity_of(out_val, q_pol, q_name)
            and {
              exit_qty >= 0,
              exit_qty <= position.qtokens_held,
            }
          }
        let valid_qtoken_burn =
          if is_keeper {
            get_mint_quantity(tx, q_pol) == -position.qtokens_held
          } else {
            let burned = get_mint_quantity(tx, q_pol)
            and {
              burned >= -position.qtokens_held,
              burned <= 0,
            }
          }

        expect old_datum.registry_auth_policy != #""
        let (whitelist, _, _, _) =
          read_registry_datum(
            tx.reference_inputs,
            old_datum.registry_hash,
            old_datum.registry_auth_policy,
          )
        let valid_source =
          list.any(
            tx.inputs,
            fn(input) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  list.has(whitelist, hash) || hash == market.action_addr_hash
                _ -> False
              }
            },
          )

        let underlying_received =
          quantity_of(out_val, u_pol, u_name) - quantity_of(in_val, u_pol, u_name)
        let valid_principal =
          if is_keeper {
            underlying_received >= position.supplied_value
          } else {
            underlying_received >= 0
          }

        let is_underlying_deposit =
          u_pol == old_datum.deposit_token_policy && u_name == old_datum.deposit_token_name
        let expected_buffer =
          if is_underlying_deposit {
            old_datum.idle_buffer + underlying_received
          } else {
            old_datum.idle_buffer
          }
        let expected_ndv =
          if is_underlying_deposit {
            old_datum.non_deposit_value
          } else {
            old_datum.non_deposit_value + underlying_received
          }

        let valid_other_tokens =
          verify_other_tokens_preserved(
            own_input.output,
            cont_output,
            q_pol,
            q_name,
            u_pol,
            u_name,
          )

        let loss_amount =
          if !is_keeper && underlying_received < position.supplied_value {
            position.supplied_value - underlying_received
          } else {
            0
          }
        let valid_deposited = and {
            new_datum.total_deposited == old_datum.total_deposited - loss_amount,
            new_datum.total_deposited > 0,
          }

        let valid_alloc_invariant =
          if loss_amount > 0 {
            let alloc_sum =
              list.foldl(
                new_datum.strategy_allocations,
                0,
                fn(a, acc) { acc + a.amount },
              )
            alloc_sum + new_datum.idle_buffer <= new_datum.total_deposited
          } else {
            True
          }

        // Orphan-qToken guard (internal verification): governance must zero out qToken holding.
        let all_qtokens_gone =
          is_keeper || quantity_of(out_val, q_pol, q_name) == 0

        and {
          authorized,
          valid_qtoken_exit,
          valid_qtoken_burn,
          all_qtokens_gone,
          valid_principal,
          valid_source,
          valid_other_tokens,
          valid_deposited,
          valid_alloc_invariant,
          new_datum.liqwid_positions == list.filter(
            old_datum.liqwid_positions,
            fn(p) { p.market_id != market_id },
          ),
          new_datum.idle_buffer == expected_buffer,
          new_datum.non_deposit_value == expected_ndv,
          new_datum.idle_buffer >= 0,
          new_datum.non_deposit_value >= 0,
          new_datum.total_shares == old_datum.total_shares,
          new_datum.strategy_allocations == old_datum.strategy_allocations,
          new_datum.last_compound_time == old_datum.last_compound_time,
          new_datum.frozen == old_datum.frozen,
          new_datum.community_sunset_triggered == old_datum.community_sunset_triggered,
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
          verify_output_value_min(cont_output, own_lovelace),
          get_mint_quantity(tx, old_datum.vusdcx_policy) == 0,
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash),
        }
      }

      _ -> False
    }
  }

  /// A2 gov-gated stake deregister (see vault_core publish comment).
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
    fail @"vault_liqwid: unsupported purpose"
  }
}
