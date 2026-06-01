/// vault_keeper_hot — keeper hot-path redeemers (split from vault_core, SwapAda extracted via the swap-ada extraction)
///
/// Staking validator invoked via Withdraw-Zero from vault_proxy. Handles:
///   Compound, RebalanceBuffer
///
/// Rationale:
///   (1) 2026-04-22 authorization-boundary split from vault_core —
///       partition by authorization boundary. Pre-split vault_core carried 6 redeemers and was
///       15,462 B / 922 B headroom — no room for an `ActDeregisterStake`
///       (A2) publish handler. vault_core was split into vault_user
///       (permissionless Deposit / Withdraw / BatchProcess) + this file
///       (keeper-auth Compound / RebalanceBuffer / SwapAda). Each half
///       carries its own A2 publish handler so the Cardano stake
///       registration deposit (2 ADA) is reclaimable via governance
///       deregister after a clean sunset.
///   (2) 2026-04-22 swap-ada extraction — SwapAda extracted into standalone
///       `vault_swap_ada.ak`. The §5.4 P5 dual-feed oracle reader plus
///       the 6-tuple registry read were ~4-5 KB of bytecode used ONLY
///       by SwapAda; hoisting them out restores headroom on Compound's
///       host for future additions.
///
/// Authorization boundary:
///   Both remaining redeemers require keeper authorization via
///   `require_keeper_stake_script`. Compound's 3-way fee split uses
///   `treasury_hash` as a compile-time anchor for the treasury-share
///   output destination.

use aiken/collection/list
use aiken/collection/pairs
use aiken/interval.{Finite}
use cardano/address.{Credential, Script, VerificationKey}
use cardano/assets.{quantity_of}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{Spend, Transaction}
use vault/constants.{
  max_validity_range_ms, one_hour_ms, zero_yield_cooldown_ms,
}
use vault/helpers.{
  find_vault_utxo, get_continuing_datum, get_mint_quantity, is_gov_authorized,
  payload_hash_deregister_stake, verify_all_tokens_preserved,
  verify_datum_unchanged, verify_other_tokens_preserved,
  verify_output_value_min, verify_token_preserved,
}
use vault/types.{
  ActDeregisterStake, Compound, GovRedeemer, RebalanceBuffer, ReceiveCompoundShare,
  VaultRedeemer,
}
use vault/validation.{
  has_no_order_inputs as val_has_no_order_inputs, require_keeper_stake_script,
  validate_allocations, validate_compound,
}

// ─────────────────────────────────────────────────────────────────────
// vault_keeper_hot compile-time anchors
//
//   keeper_stake_hash      — required as zero-withdraw on every redeemer.
//   treasury_hash          — Compound's treasury fee share destination.
//   governance_nft_policy  — A2 publish gate.
//   governance_nft_name    — A2 publish gate.
// ─────────────────────────────────────────────────────────────────────

validator vault_keeper_hot(
  keeper_stake_hash: ByteArray,
  treasury_hash: ByteArray,
  governance_nft_policy: ByteArray,
  governance_nft_name: ByteArray,
  treasury_nft_policy: ByteArray,
  treasury_nft_name: ByteArray,
) {
  withdraw(redeemer: VaultRedeemer, account: Credential, tx: Transaction) {
    expect Script(_) = account
    let (own_input, old_datum, own_lovelace, vault_input_count, proxy_hash) =
      find_vault_utxo(tx.inputs)

    when redeemer is {
      // ══════════════════════════════════════════════════════
      // Compound — V1 3-way fee split (keeper / gov pool / treasury)
      // ══════════════════════════════════════════════════════
      Compound { harvested_amount, new_allocations, fee_output_idx, keeper_output_idx } -> {
        expect vault_input_count == 1
        expect old_datum.frozen == 0
        let keeper_authorized = require_keeper_stake_script(tx, keeper_stake_hash)

        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let is_zero_yield = harvested_amount == 0

        let valid_compound =
          validate_compound(old_datum, new_datum, harvested_amount, new_allocations)

        let valid_alloc_match = new_datum.strategy_allocations == new_allocations
        let valid_alloc_check =
          validate_allocations(new_allocations, new_datum.total_deposited, new_datum.idle_buffer)
        let valid_allocs = valid_alloc_match && valid_alloc_check

        // 3-way split (only on positive-yield buffer-funded Compound)
        let total_fee =
          if !is_zero_yield && harvested_amount > 0 {
            harvested_amount * old_datum.performance_fee_bps / 10_000
          } else {
            0
          }
        let keeper_share = total_fee * old_datum.keeper_fee_bps / 10_000
        let gov_share = total_fee * old_datum.gov_fee_bps / 10_000
        let treasury_share = total_fee - keeper_share - gov_share

        let valid_deposit_token =
          verify_token_preserved(
            own_input.output,
            cont_output,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
            total_fee,
          )
        let valid_other =
          verify_other_tokens_preserved(
            own_input.output,
            cont_output,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
            #"",
            #"",
          )
        let valid_ada = verify_output_value_min(cont_output, own_lovelace)
        let valid_value = and {
            valid_deposit_token,
            valid_other,
            valid_ada,
          }

        let no_mint = get_mint_quantity(tx, old_datum.vusdcx_policy) == 0
        let no_order_inputs =
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash)

        // Cooldown + 1h validity-range width cap.
        let valid_cooldown =
          when (
            tx.validity_range.lower_bound.bound_type,
            tx.validity_range.upper_bound.bound_type,
          ) is {
            (Finite(now), Finite(upper)) -> {
              expect upper - now <= max_validity_range_ms
              if is_zero_yield {
                and {
                  now >= old_datum.last_realloc_time + zero_yield_cooldown_ms,
                  new_datum.last_realloc_time >= now,
                  new_datum.last_realloc_time <= upper,
                }
              } else {
                and {
                  now >= old_datum.last_compound_time + one_hour_ms,
                  new_datum.last_compound_time >= now,
                  new_datum.last_compound_time <= upper,
                }
              }
            }
            _ -> False
          }

        // Treasury share output binding (anti-double-satisfaction).
        let valid_treasury =
          if treasury_share > 0 {
            expect Some(fee_out) = list.at(tx.outputs, fee_output_idx)
            when fee_out.address.payment_credential is {
              Script(h) ->
                and {
                  h == treasury_hash,
                  quantity_of(
                    fee_out.value,
                    old_datum.deposit_token_policy,
                    old_datum.deposit_token_name,
                  ) >= treasury_share,
                  // Route only to the canonical NFT-bearing treasury output.
                  quantity_of(fee_out.value, treasury_nft_policy, treasury_nft_name) == 1,
                }
              _ -> False
            }
          } else {
            True
          }

        // Keeper share output binding.
        let valid_keeper =
          if keeper_share > 0 {
            expect Some(kout) = list.at(tx.outputs, keeper_output_idx)
            when kout.address.payment_credential is {
              VerificationKey(pkh) ->
                and {
                  list.has(tx.extra_signatories, pkh),
                  quantity_of(
                    kout.value,
                    old_datum.deposit_token_policy,
                    old_datum.deposit_token_name,
                  ) >= keeper_share,
                }
              _ -> False
            }
          } else {
            True
          }

        // V1 internal audit (gov-compensation binding): check the gov UTXO's
        // USDCx balance grew by at least `gov_share`. multisig_gov.
        // ReceiveCompoundShare on its side derives `delta` from the same
        // USDCx increment and writes `pool += delta`, so pool accounting
        // cannot drift from physical value.
        //
        // Compound cross-validator binding (2026-04-22): require the gov input's spend redeemer
        // to be ReceiveCompoundShare. Without this check, pairing Compound
        // with any other gov redeemer (Heartbeat / QueueAction / CancelAction
        // / ExecuteAction / RotateSignersRedeemer / DistributeSignerCompensation)
        // would physically move gov_share USDCx into the gov UTXO but leave
        // signer_compensation_pool unchanged — the gov USDCx balance would
        // grow but DistributeSignerCompensation would never pay it out
        // (since `per_signer = pool / qualified_count`). Orphaned funds
        // outcome. The fix forces the only gov redeemer that updates the
        // pool counter to be the one that accepts the Compound-driven
        // top-up.
        let valid_gov_share =
          if gov_share > 0 {
            let gov_input =
              list.find(
                tx.inputs,
                fn(i) {
                  quantity_of(
                    i.output.value,
                    old_datum.governance_policy,
                    old_datum.governance_name,
                  ) == 1
                },
              )
            let gov_continuing =
              list.find(
                tx.outputs,
                fn(o) {
                  quantity_of(
                    o.value,
                    old_datum.governance_policy,
                    old_datum.governance_name,
                  ) == 1
                },
              )
            when (gov_input, gov_continuing) is {
              (Some(gi), Some(gco)) -> {
                let old_gov_usdcx =
                  quantity_of(
                    gi.output.value,
                    old_datum.deposit_token_policy,
                    old_datum.deposit_token_name,
                  )
                let new_gov_usdcx =
                  quantity_of(
                    gco.value,
                    old_datum.deposit_token_policy,
                    old_datum.deposit_token_name,
                  )
                // Cross-validator binding: look up the gov UTXO's spend redeemer and
                // require ReceiveCompoundShare.
                let gov_redeemer_is_receive =
                  when pairs.get_first(tx.redeemers, Spend(gi.output_reference)) is {
                    Some(rdmr) -> {
                      expect gr: GovRedeemer = rdmr
                      when gr is {
                        ReceiveCompoundShare -> True
                        _ -> False
                      }
                    }
                    None -> False
                  }
                and {
                  new_gov_usdcx >= old_gov_usdcx + gov_share,
                  gov_redeemer_is_receive,
                }
              }
              _ -> False
            }
          } else {
            True
          }

        and {
          keeper_authorized,
          valid_compound,
          valid_allocs,
          valid_value,
          no_mint,
          no_order_inputs,
          valid_cooldown,
          valid_treasury,
          valid_keeper,
          valid_gov_share,
        }
      }

      // ══════════════════════════════════════════════════════
      // RebalanceBuffer — allocation-only datum touch
      // ══════════════════════════════════════════════════════
      RebalanceBuffer -> {
        expect vault_input_count == 1
        expect old_datum.frozen == 0
        let keeper_authorized = require_keeper_stake_script(tx, keeper_stake_hash)
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let valid_datum = verify_datum_unchanged(old_datum, new_datum)
        let valid_value = verify_all_tokens_preserved(own_input.output, cont_output)
        let no_mint = get_mint_quantity(tx, old_datum.vusdcx_policy) == 0
        let no_order_inputs =
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash)
        let valid_cooldown =
          when tx.validity_range.lower_bound.bound_type is {
            Finite(now) -> now >= old_datum.last_compound_time + one_hour_ms
            _ -> False
          }

        and {
          keeper_authorized,
          valid_datum,
          valid_value,
          no_mint,
          no_order_inputs,
          valid_cooldown,
        }
      }

      // SwapAda is now handled by vault_swap_ada.ak (swap-ada extraction,
      // 2026-04-22). Other redeemers are handled by vault_user /
      // vault_protocol / vault_recall / vault_liqwid / vault_gov_*.
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
    fail @"vault_keeper_hot: unsupported purpose"
  }
}
