/// vault_batcher — BatchProcess only (Phase 77d split from vault_user)
///
/// Staking validator invoked via Withdraw-Zero from vault_proxy with the
/// `UseBatcher` redeemer. Handles a single redeemer:
///
///   BatchProcess — keeper batches user Order UTXOs (DepositOrder /
///                  WithdrawOrder) into a single vault-state update with
///                  aggregate mint/burn of vUSDCx. Uses pre-batch
///                  snapshot pricing so every order in the batch sees
///                  the same total_deposited / total_shares — no
///                  running-accumulator MEV surface.
///
/// Split rationale (Phase 77d, 2026-04-22):
///   Pre-split vault_user carried Deposit + Withdraw + BatchProcess
///   and sat at 14,528 B / 1,856 B headroom. BatchProcess alone
///   accounts for ~9-11 KB of that — it's the heaviest redeemer in
///   V1 because it runs:
///     * 4 fold loops (order_sums 5-tuple, order_owners, vusdcx_leaked,
///       payout_indices) across all order inputs + outputs;
///     * OrderDatum decode with DepositOrder / WithdrawOrder variants;
///     * OrderRedeemer decode via `pairs.get_first` + `Spend` purpose;
///     * `list.unique` for anti-double-satisfaction on payout indices;
///     * 15+ explicit datum-field equality checks;
///     * R51 H-1 `no_vusdcx_leak` whitelist + R52 H-1
///       `unique_payout_indices` defense.
///
///   Authorization boundary: Deposit + Withdraw are permissionless
///   (user-signed); BatchProcess is keeper-authorized (via
///   `require_keeper_stake_script`). Extracting BatchProcess cleanly
///   separates permission domains and lets vault_user drop its
///   `keeper_stake_hash` compile-time param entirely (it becomes
///   purely permissionless).
///
///   Cross-validator consideration: vUSDCx mint/burn spans both
///   vault_user (Deposit mint / Withdraw burn) and vault_batcher
///   (BatchProcess net mint/burn). vusdcx.ak's cross-validator binding
///   is at the vault_proxy level (`vault_hash` = proxy hash), NOT at a
///   specific staking validator — so the split is architecturally
///   transparent to vusdcx.ak. vault_proxy's `withdrawal_count == 1`
///   invariant guarantees exactly one staking validator runs per TX,
///   so mix-and-match mint-authority attacks are impossible.
///
/// Compile-time anchors:
///   keeper_stake_hash      — zero-withdraw keeper auth on BatchProcess.
///   governance_nft_policy  — A2 publish handler gate.
///   governance_nft_name    — A2 publish handler gate.

use aiken/collection/list
use aiken/collection/pairs
use cardano/address.{Credential, Script, VerificationKey}
use cardano/assets.{quantity_of}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{InlineDatum, Spend, Transaction}
use vault/constants.{vusdcx_token_name}
use vault/helpers.{
  find_vault_utxo, get_continuing_datum, get_mint_quantity, is_gov_authorized,
  payload_hash_deregister_stake, verify_other_tokens_preserved,
  verify_output_value_min, verify_token_preserved,
}
use vault/types.{
  ActDeregisterStake, BatchProcess, DepositOrder, OrderDatum, OrderRedeemer,
  Process, VaultRedeemer, WithdrawOrder,
}
use vault/validation.{check_immutable_fields, require_keeper_stake_script}

validator vault_batcher(
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
      // BatchProcess — keeper batches Order UTXOs into a single
      //   vault-state update with aggregate mint/burn of vUSDCx.
      //
      // R72 F-2 verification note: `vault_input_count == 1` is
      // enforced below, same as every other redeemer host in V1.
      // `find_vault_utxo` returns the first matching vault input,
      // so this check prevents a malicious keeper TX from silently
      // picking one of two vault UTXOs and leaking the other. The
      // proxy's phantom-vault defense + Vault NFT anchor also cover
      // this path; the explicit check is defense-in-depth. (R72
      // audit initially flagged this as missing post-Phase-77d
      // extraction from vault_user; re-verification confirmed the
      // check was carried over correctly — no fix needed.)
      // ══════════════════════════════════════════════════════
      BatchProcess { total_deposit, total_withdraw, total_mint, total_burn } -> {
        expect vault_input_count == 1
        expect old_datum.frozen == 0
        let keeper_authorized = require_keeper_stake_script(tx, keeper_stake_hash)

        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let net_deposit = total_deposit - total_withdraw
        let net_mint = total_mint - total_burn

        let valid_deposited =
          new_datum.total_deposited == old_datum.total_deposited + net_deposit
        let valid_shares =
          new_datum.total_shares == old_datum.total_shares + net_mint
        let valid_buffer =
          new_datum.idle_buffer == old_datum.idle_buffer + net_deposit
        let buffer_non_negative = new_datum.idle_buffer >= 0
        let valid_value = verify_output_value_min(cont_output, own_lovelace)

        let valid_token =
          verify_token_preserved(
            own_input.output,
            cont_output,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
            -net_deposit,
          )
        let valid_other =
          verify_other_tokens_preserved(
            own_input.output,
            cont_output,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
            old_datum.vusdcx_policy,
            vusdcx_token_name,
          )

        let minted = get_mint_quantity(tx, old_datum.vusdcx_policy)
        let valid_mint = minted == net_mint

        let valid_imm = check_immutable_fields(old_datum, new_datum)

        // Aggregate fair-share / fair-withdraw sums per pre-batch snapshot
        // (internal verification — exact equality, no rounding surplus).
        let order_sums =
          list.foldl(
            tx.inputs,
            (0, 0, 0, 0, 0),
            fn(input, acc) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  if hash == old_datum.order_script_hash {
                    when input.output.datum is {
                      InlineDatum(data) -> {
                        expect od: OrderDatum = data
                        when od.order_type is {
                          DepositOrder -> {
                            let fair_shares =
                              if old_datum.total_shares > 0 && old_datum.total_deposited > 0 {
                                od.amount * old_datum.total_shares / old_datum.total_deposited
                              } else {
                                od.amount * 1_000_000
                              }
                            (
                              acc.1st + od.amount,
                              acc.2nd,
                              acc.3rd + 1,
                              acc.4th + fair_shares,
                              acc.5th,
                            )
                          }
                          WithdrawOrder -> {
                            let fair_withdraw =
                              if old_datum.total_shares > 0 {
                                od.amount * old_datum.total_deposited / old_datum.total_shares
                              } else {
                                0
                              }
                            (
                              acc.1st,
                              acc.2nd + od.amount,
                              acc.3rd + 1,
                              acc.4th,
                              acc.5th + fair_withdraw,
                            )
                          }
                        }
                      }
                      _ -> acc
                    }
                  } else {
                    acc
                  }
                _ -> acc
              }
            },
          )
        let has_order_inputs = order_sums.3rd > 0
        let has_work = total_deposit > 0 || total_withdraw > 0
        let valid_order_totals = and {
            total_deposit == order_sums.1st,
            total_burn == order_sums.2nd,
          }
        let valid_mint_ratio = total_mint == order_sums.4th
        let valid_burn_ratio = total_withdraw == order_sums.5th

        let valid_allocs = new_datum.strategy_allocations == old_datum.strategy_allocations
        let valid_time = new_datum.last_compound_time == old_datum.last_compound_time
        let valid_non_deposit = new_datum.non_deposit_value == old_datum.non_deposit_value
        let valid_frozen = new_datum.frozen == old_datum.frozen
        let valid_realloc_time = new_datum.last_realloc_time == old_datum.last_realloc_time
        let valid_fee_time = new_datum.last_fee_update_time == old_datum.last_fee_update_time

        // vUSDCx anti-leak (R51 H-1) — minted shares can only flow to
        // order owners or the proxy continuing output.
        let order_owners =
          list.foldl(
            tx.inputs,
            [],
            fn(input, acc) {
              when input.output.address.payment_credential is {
                Script(h) ->
                  if h == old_datum.order_script_hash {
                    when input.output.datum is {
                      InlineDatum(data) -> {
                        expect od: OrderDatum = data
                        [od.owner, ..acc]
                      }
                      _ -> acc
                    }
                  } else {
                    acc
                  }
                _ -> acc
              }
            },
          )
        let vusdcx_leaked =
          list.foldl(
            tx.outputs,
            0,
            fn(output, acc) {
              let qty =
                quantity_of(output.value, old_datum.vusdcx_policy, vusdcx_token_name)
              if qty <= 0 {
                acc
              } else {
                when output.address.payment_credential is {
                  VerificationKey(pkh) ->
                    if list.has(order_owners, pkh) {
                      acc
                    } else {
                      acc + qty
                    }
                  Script(h) ->
                    if h == proxy_hash {
                      acc
                    } else {
                      acc + qty
                    }
                }
              }
            },
          )
        let no_vusdcx_leak = vusdcx_leaked == 0

        // Anti-double-satisfaction: each order's payout_output_index is unique
        let payout_indices =
          list.foldl(
            tx.inputs,
            [],
            fn(input, acc) {
              when input.output.address.payment_credential is {
                Script(h) ->
                  if h == old_datum.order_script_hash {
                    when pairs.get_first(tx.redeemers, Spend(input.output_reference)) is {
                      Some(rdmr) -> {
                        expect or_: OrderRedeemer = rdmr
                        when or_ is {
                          Process { payout_output_index, tip_output_idx: _ } ->
                            [payout_output_index, ..acc]
                          _ -> acc
                        }
                      }
                      None -> acc
                    }
                  } else {
                    acc
                  }
                _ -> acc
              }
            },
          )
        let unique_payout_indices =
          list.length(payout_indices) == list.length(list.unique(payout_indices))

        and {
          keeper_authorized,
          total_deposit >= 0,
          total_withdraw >= 0,
          has_order_inputs,
          has_work,
          valid_order_totals,
          valid_deposited,
          valid_shares,
          valid_buffer,
          buffer_non_negative,
          valid_value,
          valid_token,
          valid_other,
          valid_mint,
          valid_mint_ratio,
          valid_burn_ratio,
          valid_allocs,
          valid_time,
          valid_imm,
          valid_non_deposit,
          valid_frozen,
          valid_realloc_time,
          valid_fee_time,
          new_datum.liqwid_positions == old_datum.liqwid_positions,
          new_datum.last_ada_swap_time == old_datum.last_ada_swap_time,
          new_datum.performance_fee_bps == old_datum.performance_fee_bps,
          new_datum.early_withdraw_fee_bps == old_datum.early_withdraw_fee_bps,
          new_datum.min_hold_seconds == old_datum.min_hold_seconds,
          new_datum.buffer_target_bps == old_datum.buffer_target_bps,
          new_datum.keeper_fee_bps == old_datum.keeper_fee_bps,
          new_datum.gov_fee_bps == old_datum.gov_fee_bps,
          new_datum.max_slippage_bps == old_datum.max_slippage_bps,
          new_datum.min_swap_peg_bps == old_datum.min_swap_peg_bps,
          no_vusdcx_leak,
          unique_payout_indices,
        }
      }

      // Other redeemers handled by vault_user / vault_keeper_hot /
      // vault_swap_ada / vault_protocol / vault_recall / vault_liqwid /
      // vault_gov_policy / vault_gov_emergency / vault_admin_deploy.
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
    fail @"vault_batcher: unsupported purpose"
  }
}
