/// order — User Deposit / Withdraw Order Queue
///
/// Holds individual user order UTXOs at this script's address. The
/// keeper consumes them in batches via vault_batcher.BatchProcess
/// (post-Phase-77d; migrated from vault_core → vault_user → vault_batcher
/// as BatchProcess was successively split out of its original host);
/// users can Cancel any time; anyone can trigger Expire after `expires_at`.
///
/// V1 differences from internal-verification:
///   - OrderDatum carries an explicit `receiver: Address` so withdraw
///     payout goes to the user-chosen address (not necessarily the
///     same as the owner's PKH-derived wallet).
///   - `max_batcher_tip` bounds the keeper tip per order.
///
/// Compile-time anchored to (vault_hash, vault_nft_policy) — the
/// vault-identity check uses the NFT policy parameter so a
/// phantom-vault datum cannot pass `find_vault_datum`.

use aiken/collection/list
use aiken/interval.{Finite}
use cardano/address.{Script, VerificationKey}
use cardano/assets.{flatten, lovelace_of, quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction}
use vault/constants.{min_order_amount, vault_nft_token_name, vusdcx_token_name}
use vault/types.{
  Cancel, DepositOrder, Expire, OrderDatum, OrderRedeemer, Process, VaultDatum,
  WithdrawOrder,
}

// ─────────────────────────────────────────────────────────────────────
// Local helpers
// ─────────────────────────────────────────────────────────────────────

fn owner_lovelace_received(outputs: List<Output>, owner: ByteArray) -> Int {
  list.foldl(
    outputs,
    0,
    fn(output, acc) {
      when output.address.payment_credential is {
        VerificationKey(hash) ->
          if hash == owner {
            acc + lovelace_of(output.value)
          } else {
            acc
          }
        _ -> acc
      }
    },
  )
}

fn owner_token_received(
  outputs: List<Output>,
  owner: ByteArray,
  policy: ByteArray,
  name: ByteArray,
) -> Int {
  list.foldl(
    outputs,
    0,
    fn(output, acc) {
      when output.address.payment_credential is {
        VerificationKey(hash) ->
          if hash == owner {
            acc + quantity_of(output.value, policy, name)
          } else {
            acc
          }
        _ -> acc
      }
    },
  )
}

/// Find vault datum from spent inputs (BatchProcess path). Vault NFT
/// presence is required — forged datum UTXOs without the NFT yield None.
fn find_vault_datum(
  inputs: List<Input>,
  vault_hash: ByteArray,
  vault_nft_policy: ByteArray,
) -> Option<VaultDatum> {
  let vault_input =
    list.find(
      inputs,
      fn(input) {
        when input.output.address.payment_credential is {
          Script(hash) -> hash == vault_hash
          _ -> False
        }
      },
    )
  when vault_input is {
    Some(vi) ->
      when vi.output.datum is {
        InlineDatum(data) -> {
          expect datum: VaultDatum = data
          let has_nft =
            quantity_of(vi.output.value, vault_nft_policy, vault_nft_token_name) == 1
          if has_nft {
            Some(datum)
          } else {
            None
          }
        }
        _ -> None
      }
    None -> None
  }
}

/// Find vault datum from reference inputs (Cancel path — vault is not
/// being consumed). Same NFT-presence check; safe-fallback to None.
fn find_vault_datum_ref(
  ref_inputs: List<Input>,
  vault_hash: ByteArray,
  vault_nft_policy: ByteArray,
) -> Option<VaultDatum> {
  let vault_ref =
    list.find(
      ref_inputs,
      fn(input) {
        when input.output.address.payment_credential is {
          Script(hash) -> hash == vault_hash
          _ -> False
        }
      },
    )
  when vault_ref is {
    Some(vi) ->
      when vi.output.datum is {
        InlineDatum(data) -> {
          expect datum: VaultDatum = data
          let has_nft =
            quantity_of(vi.output.value, vault_nft_policy, vault_nft_token_name) == 1
          if has_nft {
            Some(datum)
          } else {
            None
          }
        }
        _ -> None
      }
    None -> None
  }
}

fn output_at_index(outputs: List<Output>, idx: Int) -> Option<Output> {
  if idx < 0 {
    None
  } else {
    do_output_at_index(outputs, idx, 0)
  }
}

fn do_output_at_index(
  outputs: List<Output>,
  target: Int,
  current: Int,
) -> Option<Output> {
  when outputs is {
    [] -> None
    [head, ..tail] ->
      if current == target {
        Some(head)
      } else {
        do_output_at_index(tail, target, current + 1)
      }
  }
}

// ─────────────────────────────────────────────────────────────────────
// validator
// ─────────────────────────────────────────────────────────────────────

validator order(vault_hash: ByteArray, vault_nft_policy: ByteArray) {
  spend(
    datum: Option<OrderDatum>,
    redeemer: OrderRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) {
    expect Some(ord) = datum

    when redeemer is {
      Process { payout_output_index, tip_output_idx } -> {
        // 1. Vault UTXO must be consumed in this TX
        let vault_is_spent =
          list.any(
            tx.inputs,
            fn(input) {
              when input.output.address.payment_credential is {
                Script(hash) -> hash == vault_hash
                _ -> False
              }
            },
          )

        // 2. Order amount >= protocol minimum
        let valid_amount = ord.amount >= min_order_amount

        // 3. Anti-double-satisfaction: payout at exact output index
        expect Some(payout_output) = output_at_index(tx.outputs, payout_output_index)

        // Vault datum lookup (cached for not_frozen + slippage_ok)
        let maybe_vault_datum = find_vault_datum(tx.inputs, vault_hash, vault_nft_policy)

        let not_frozen =
          when maybe_vault_datum is {
            Some(vault_datum) -> vault_datum.frozen == 0
            None -> False
          }

        let not_expired =
          when tx.validity_range.upper_bound.bound_type is {
            Finite(upper) -> upper < ord.expires_at
            _ -> False
          }

        // Recipient + slippage check, per order_type
        let slippage_ok =
          when maybe_vault_datum is {
            Some(vault_datum) ->
              when ord.order_type is {
                DepositOrder -> {
                  // vUSDCx delivered to the owner's payment address
                  let valid_recipient =
                    when payout_output.address.payment_credential is {
                      VerificationKey(hash) -> hash == ord.owner
                      _ -> False
                    }
                  let vusdcx_in_output =
                    quantity_of(
                      payout_output.value,
                      vault_datum.vusdcx_policy,
                      vusdcx_token_name,
                    )
                  let fair_shares =
                    if vault_datum.total_shares > 0 && vault_datum.total_deposited > 0 {
                      ord.amount * vault_datum.total_shares / vault_datum.total_deposited
                    } else {
                      ord.amount * 1_000_000
                    }
                  let required =
                    if ord.min_receive > fair_shares {
                      ord.min_receive
                    } else {
                      fair_shares
                    }
                  and {
                    valid_recipient,
                    vusdcx_in_output >= required,
                  }
                }
                WithdrawOrder -> {
                  // Deposit token delivered to the user-specified receiver
                  // address (carried in OrderDatum.receiver, not derived
                  // from owner PKH).
                  let valid_recipient = payout_output.address == ord.receiver
                  let fair_amount =
                    if vault_datum.total_shares > 0 {
                      ord.amount * vault_datum.total_deposited / vault_datum.total_shares
                    } else {
                      0
                    }
                  let required =
                    if ord.min_receive > fair_amount {
                      ord.min_receive
                    } else {
                      fair_amount
                    }
                  let amount_ok =
                    quantity_of(
                      payout_output.value,
                      vault_datum.deposit_token_policy,
                      vault_datum.deposit_token_name,
                    ) >= required
                  and {
                    valid_recipient,
                    amount_ok,
                  }
                }
              }
            None -> False
          }

        // Tip cap: if keeper claims a tip, validate it against
        // `max_batcher_tip`. tip_output_idx == -1 means "no tip".
        //
        // R75 M-2 fix (audit-0426): tip_output_idx must NOT alias
        // payout_output_index. Pre-fix the keeper could point both
        // at the same output, double-counting the payout (which is
        // already required to satisfy the order's payout in vUSDCx
        // / deposit-token) as the lovelace tip — extracting up to
        // `max_batcher_tip` extra ADA from a payout the user already
        // signed for. The per-order `max_batcher_tip` cap still
        // bounded the damage at the user's stated maximum, but
        // distinct outputs is the hygienic invariant: the tip
        // belongs to the keeper, the payout belongs to the user,
        // they should not be the same UTxO. (Cross-order uniqueness
        // — preventing two orders pointing the same tip output —
        // is intentionally NOT enforced here: each order's
        // `max_batcher_tip` is the user's own ceiling, and the
        // batcher rationally aggregates tips into a single output
        // per batch as long as no individual cap is exceeded.)
        let tip_ok =
          if tip_output_idx < 0 {
            True
          } else if tip_output_idx == payout_output_index {
            False
          } else {
            when output_at_index(tx.outputs, tip_output_idx) is {
              Some(tip_out) -> lovelace_of(tip_out.value) <= ord.max_batcher_tip
              None -> False
            }
          }

        and {
          vault_is_spent,
          not_frozen,
          not_expired,
          valid_amount,
          slippage_ok,
          tip_ok,
        }
      }

      Cancel -> {
        let signed_by_owner = list.has(tx.extra_signatories, ord.owner)

        // Anti-double-satisfaction: only one order spend per Cancel TX
        expect Some(own_input) =
          list.find(tx.inputs, fn(input) { input.output_reference == own_ref })
        expect Script(own_hash) = own_input.output.address.payment_credential
        let order_input_count =
          list.foldl(
            tx.inputs,
            0,
            fn(input, acc) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  if hash == own_hash {
                    acc + 1
                  } else {
                    acc
                  }
                _ -> acc
              }
            },
          )
        expect order_input_count == 1

        // Refund logic: prefer refund-by-token when vault datum is
        // visible via reference input; otherwise full-value refund.
        let refund_ok =
          when find_vault_datum_ref(tx.reference_inputs, vault_hash, vault_nft_policy) is {
            Some(vault_datum) ->
              when ord.order_type is {
                DepositOrder ->
                  owner_token_received(
                    tx.outputs,
                    ord.owner,
                    vault_datum.deposit_token_policy,
                    vault_datum.deposit_token_name,
                  ) >= ord.amount
                WithdrawOrder ->
                  owner_token_received(
                    tx.outputs,
                    ord.owner,
                    vault_datum.vusdcx_policy,
                    vusdcx_token_name,
                  ) >= ord.amount
              }
            None -> {
              let ada_ok =
                owner_lovelace_received(tx.outputs, ord.owner) >= lovelace_of(
                  own_input.output.value,
                )
              let tokens_ok =
                list.all(
                  flatten(own_input.output.value),
                  fn(entry) {
                    let (policy, name, qty) = entry
                    if policy == #"" {
                      True
                    } else {
                      owner_token_received(tx.outputs, ord.owner, policy, name) >= qty
                    }
                  },
                )
              and {
                ada_ok,
                tokens_ok,
              }
            }
          }

        and {
          signed_by_owner,
          refund_ok,
        }
      }

      Expire -> {
        // Anyone can trigger after expires_at; full-value refund to owner.
        expect Some(own_input) =
          list.find(tx.inputs, fn(input) { input.output_reference == own_ref })
        expect Script(own_hash) = own_input.output.address.payment_credential
        let order_input_count =
          list.foldl(
            tx.inputs,
            0,
            fn(input, acc) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  if hash == own_hash {
                    acc + 1
                  } else {
                    acc
                  }
                _ -> acc
              }
            },
          )
        expect order_input_count == 1

        let valid_refund = {
          let ada_ok =
            owner_lovelace_received(tx.outputs, ord.owner) >= lovelace_of(
              own_input.output.value,
            )
          let tokens_ok =
            list.all(
              flatten(own_input.output.value),
              fn(entry) {
                let (policy, name, qty) = entry
                if policy == #"" {
                  True
                } else {
                  owner_token_received(tx.outputs, ord.owner, policy, name) >= qty
                }
              },
            )
          and {
            ada_ok,
            tokens_ok,
          }
        }

        let is_expired =
          when tx.validity_range.lower_bound.bound_type is {
            Finite(time) -> time >= ord.expires_at
            _ -> False
          }

        and {
          is_expired,
          valid_refund,
        }
      }
    }
  }

  else(_) {
    fail @"order: unsupported purpose"
  }
}
