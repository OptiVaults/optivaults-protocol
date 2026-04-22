/// treasury — V1 protocol-fee treasury with 4-bucket category accounting.
///
/// Receives the treasury share of the 3-way fee split on every Compound
/// (driven by vault_keeper_hot.Compound post-Phase-77 — Compound migrated
/// from vault_core to vault_keeper_hot during the authorization-boundary
/// split — which pays USDCx into a treasury output and triggers Receive).
/// Forfeit-to-audit-reserve is driven by multisig_gov.
/// DistributeSignerCompensation when some signers fail to qualify for
/// quarterly distribution.
///
/// Outflows are governance-gated only: every Spend / UpdateParams must
/// be paired with a multisig_gov.ExecuteAction whose payload_hash matches.
///
/// Hard floors:
///   - audit_bps + ops_bps + rd_bps + buffer_bps == 10_000
///   - each *_bps in [0, 5_000] (no single bucket > 50%)
///   - audit_bps >= treasury_audit_floor_bps (2000 = 20%) per spec/treasury.md §6
///   - audit_reserve_balance never falls below `min_audit_reserve` (deploy-time floor)

use aiken/collection/list
use aiken/interval.{Finite}
use cardano/address.{Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}
use vault/constants.{
  treasury_audit_floor_bps, treasury_log_cap, treasury_monthly_window_ms,
  treasury_param_cooldown_ms, treasury_spend_cooldown_ms,
}
use vault/helpers.{
  cat_tag_audit, cat_tag_buffer, cat_tag_ops, cat_tag_rd, is_gov_authorized,
  payload_hash_treasury_params, payload_hash_treasury_spend,
}
use vault/types.{
  ActTreasurySpend, ActUpdateTreasuryParams, AuditReserve, Buffer, Operations,
  RD, Receive, ReceiveGovForfeit, Spend, SpendCategory, TreasuryDatum,
  TreasuryRedeemer, TreasurySpendRecord, UpdateParams,
}

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

fn find_continuing(outputs: List<Output>, own_hash: ByteArray) -> Option<Output> {
  let matching =
    list.filter(
      outputs,
      fn(output) {
        when output.address.payment_credential is {
          Script(hash) -> hash == own_hash
          _ -> False
        }
      },
    )
  when matching is {
    [single] -> Some(single)
    _ -> None
  }
}

fn output_at(outputs: List<Output>, idx: Int) -> Option<Output> {
  if idx < 0 {
    None
  } else {
    list.at(outputs, idx)
  }
}

/// USDCx held in a treasury UTXO (treasury balances are deposit-token
/// denominated; we trust the Receive redeemer to verify the deposit
/// token identity at the call site).
fn usdcx_qty(
  output: Output,
  policy: ByteArray,
  name: ByteArray,
) -> Int {
  quantity_of(output.value, policy, name)
}

fn category_balance(t: TreasuryDatum, c: SpendCategory) -> Int {
  when c is {
    AuditReserve -> t.audit_reserve_balance
    Operations -> t.operations_balance
    RD -> t.rd_balance
    Buffer -> t.buffer_balance
  }
}

fn category_last_spend(t: TreasuryDatum, c: SpendCategory) -> Int {
  when c is {
    AuditReserve -> t.last_spend_time_audit
    Operations -> t.last_spend_time_ops
    RD -> t.last_spend_time_rd
    Buffer -> t.last_spend_time_buffer
  }
}

fn category_monthly_cap(t: TreasuryDatum, c: SpendCategory) -> Int {
  when c is {
    AuditReserve -> t.monthly_cap_audit
    Operations -> t.monthly_cap_ops
    RD -> t.monthly_cap_rd
    Buffer -> t.monthly_cap_buffer
  }
}

/// Sum of Spend amounts for `c` in the recent log within the last 30 days.
fn monthly_spent(
  log: List<TreasurySpendRecord>,
  c: SpendCategory,
  now: Int,
) -> Int {
  list.foldl(
    log,
    0,
    fn(rec, acc) {
      if rec.category == c && now - rec.timestamp <= treasury_monthly_window_ms {
        acc + rec.amount
      } else {
        acc
      }
    },
  )
}

// ─────────────────────────────────────────────────────────────────────
// Validator
// ─────────────────────────────────────────────────────────────────────

/// Compile-time anchored to the deposit token identity (USDCx) so the
/// treasury cannot be tricked into accounting for a non-USDCx asset.
validator treasury(
  deposit_token_policy: ByteArray,
  deposit_token_name: ByteArray,
) {
  spend(
    datum: Option<TreasuryDatum>,
    redeemer: TreasuryRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) {
    expect Some(t) = datum
    expect Some(own_input) =
      list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
    expect Script(own_hash) = own_input.output.address.payment_credential
    expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
    expect InlineDatum(new_data) = cont_output.datum
    expect new_t: TreasuryDatum = new_data

    // Identity preservation
    let identity_ok = and {
        new_t.governance_policy == t.governance_policy,
        new_t.governance_name == t.governance_name,
        new_t.min_audit_reserve == t.min_audit_reserve,
      }

    let in_usdcx = usdcx_qty(own_input.output, deposit_token_policy, deposit_token_name)
    let out_usdcx = usdcx_qty(cont_output, deposit_token_policy, deposit_token_name)

    when redeemer is {
      // ══════════════════════════════════════════════════════
      // Receive — passive accounting transition for Compound's
      // treasury fee output.
      // ══════════════════════════════════════════════════════
      Receive { incoming_amount } -> {
        let amount_ok = incoming_amount > 0
        let usdcx_delta_ok = out_usdcx == in_usdcx + incoming_amount

        let audit_delta = incoming_amount * t.audit_bps / 10_000
        let ops_delta = incoming_amount * t.ops_bps / 10_000
        let rd_delta = incoming_amount * t.rd_bps / 10_000
        let buffer_delta = incoming_amount - audit_delta - ops_delta - rd_delta

        let bal_ok = and {
            new_t.audit_reserve_balance == t.audit_reserve_balance + audit_delta,
            new_t.operations_balance == t.operations_balance + ops_delta,
            new_t.rd_balance == t.rd_balance + rd_delta,
            new_t.buffer_balance == t.buffer_balance + buffer_delta,
          }

        let static_ok = and {
            new_t.audit_bps == t.audit_bps,
            new_t.ops_bps == t.ops_bps,
            new_t.rd_bps == t.rd_bps,
            new_t.buffer_bps == t.buffer_bps,
            new_t.last_spend_time_audit == t.last_spend_time_audit,
            new_t.last_spend_time_ops == t.last_spend_time_ops,
            new_t.last_spend_time_rd == t.last_spend_time_rd,
            new_t.last_spend_time_buffer == t.last_spend_time_buffer,
            new_t.last_param_update_time == t.last_param_update_time,
            new_t.monthly_cap_audit == t.monthly_cap_audit,
            new_t.monthly_cap_ops == t.monthly_cap_ops,
            new_t.monthly_cap_rd == t.monthly_cap_rd,
            new_t.monthly_cap_buffer == t.monthly_cap_buffer,
            new_t.recent_spend_log == t.recent_spend_log,
          }

        and {
          identity_ok,
          amount_ok,
          usdcx_delta_ok,
          bal_ok,
          static_ok,
        }
      }

      // ══════════════════════════════════════════════════════
      // ReceiveGovForfeit — entire forfeit_amount routes to
      // audit_reserve_balance (no per-bucket split).
      // ══════════════════════════════════════════════════════
      ReceiveGovForfeit { forfeit_amount } -> {
        let amount_ok = forfeit_amount > 0
        let usdcx_delta_ok = out_usdcx == in_usdcx + forfeit_amount
        let bal_ok = and {
            new_t.audit_reserve_balance == t.audit_reserve_balance + forfeit_amount,
            new_t.operations_balance == t.operations_balance,
            new_t.rd_balance == t.rd_balance,
            new_t.buffer_balance == t.buffer_balance,
          }
        let static_ok = and {
            new_t.audit_bps == t.audit_bps,
            new_t.ops_bps == t.ops_bps,
            new_t.rd_bps == t.rd_bps,
            new_t.buffer_bps == t.buffer_bps,
            new_t.last_spend_time_audit == t.last_spend_time_audit,
            new_t.last_spend_time_ops == t.last_spend_time_ops,
            new_t.last_spend_time_rd == t.last_spend_time_rd,
            new_t.last_spend_time_buffer == t.last_spend_time_buffer,
            new_t.last_param_update_time == t.last_param_update_time,
            new_t.monthly_cap_audit == t.monthly_cap_audit,
            new_t.monthly_cap_ops == t.monthly_cap_ops,
            new_t.monthly_cap_rd == t.monthly_cap_rd,
            new_t.monthly_cap_buffer == t.monthly_cap_buffer,
            new_t.recent_spend_log == t.recent_spend_log,
          }
        and {
          identity_ok,
          amount_ok,
          usdcx_delta_ok,
          bal_ok,
          static_ok,
        }
      }

      // ══════════════════════════════════════════════════════
      // Spend — governance-gated outflow
      // ══════════════════════════════════════════════════════
      Spend { category, amount, recipient_idx, audit_invoice_ref } -> {
        let amount_ok = amount > 0
        let cur_balance = category_balance(t, category)
        let balance_ok = amount <= cur_balance

        // 24-hour cooldown per category
        expect Finite(now) = tx.validity_range.lower_bound.bound_type
        expect Finite(upper) = tx.validity_range.upper_bound.bound_type
        let cooldown_ok =
          now - category_last_spend(t, category) >= treasury_spend_cooldown_ms

        // Validity-range width cap (1h) — anchors `now` for log timestamp
        let range_width_ok = upper - now <= 3_600_000

        // Monthly cap
        let monthly_used = monthly_spent(t.recent_spend_log, category, now)
        let monthly_cap_ok =
          monthly_used + amount <= category_monthly_cap(t, category)

        // Audit-reserve floor
        let audit_floor_ok =
          when category is {
            AuditReserve ->
              and {
                t.audit_reserve_balance - amount >= t.min_audit_reserve,
                // honor-system: invoice ref must be non-empty
                audit_invoice_ref != #"",
              }
            _ -> True
          }

        // Output at recipient_idx receives `amount` USDCx (anti-double-satisfaction)
        expect Some(recip_out) = output_at(tx.outputs, recipient_idx)

        // H-1: payload-hash binding for governance authorization
        let cat_tag =
          when category is {
            AuditReserve -> cat_tag_audit
            Operations -> cat_tag_ops
            RD -> cat_tag_rd
            Buffer -> cat_tag_buffer
          }
        let expected_payload_hash =
          payload_hash_treasury_spend(
            cat_tag,
            amount,
            recip_out.address,
            audit_invoice_ref,
          )
        let governance_authorized =
          is_gov_authorized(
            tx,
            t.governance_policy,
            t.governance_name,
            ActTreasurySpend,
            expected_payload_hash,
            own_hash,
          )
        // Recipient must NOT be this treasury script address (no self-loop)
        let not_self_loop =
          when recip_out.address.payment_credential is {
            Script(h) -> h != own_hash
            _ -> True
          }
        let recipient_amount_ok =
          usdcx_qty(recip_out, deposit_token_policy, deposit_token_name) >= amount

        // Treasury USDCx delta = -amount
        let usdcx_delta_ok = out_usdcx == in_usdcx - amount

        // Continuing balance reflects the spend
        let bal_ok =
          when category is {
            AuditReserve -> and {
                new_t.audit_reserve_balance == t.audit_reserve_balance - amount,
                new_t.operations_balance == t.operations_balance,
                new_t.rd_balance == t.rd_balance,
                new_t.buffer_balance == t.buffer_balance,
              }
            Operations -> and {
                new_t.audit_reserve_balance == t.audit_reserve_balance,
                new_t.operations_balance == t.operations_balance - amount,
                new_t.rd_balance == t.rd_balance,
                new_t.buffer_balance == t.buffer_balance,
              }
            RD -> and {
                new_t.audit_reserve_balance == t.audit_reserve_balance,
                new_t.operations_balance == t.operations_balance,
                new_t.rd_balance == t.rd_balance - amount,
                new_t.buffer_balance == t.buffer_balance,
              }
            Buffer -> and {
                new_t.audit_reserve_balance == t.audit_reserve_balance,
                new_t.operations_balance == t.operations_balance,
                new_t.rd_balance == t.rd_balance,
                new_t.buffer_balance == t.buffer_balance - amount,
              }
          }

        // last_spend_time updated for the spent category only; others unchanged
        let last_spend_ok =
          when category is {
            AuditReserve -> and {
                new_t.last_spend_time_audit == now,
                new_t.last_spend_time_ops == t.last_spend_time_ops,
                new_t.last_spend_time_rd == t.last_spend_time_rd,
                new_t.last_spend_time_buffer == t.last_spend_time_buffer,
              }
            Operations -> and {
                new_t.last_spend_time_audit == t.last_spend_time_audit,
                new_t.last_spend_time_ops == now,
                new_t.last_spend_time_rd == t.last_spend_time_rd,
                new_t.last_spend_time_buffer == t.last_spend_time_buffer,
              }
            RD -> and {
                new_t.last_spend_time_audit == t.last_spend_time_audit,
                new_t.last_spend_time_ops == t.last_spend_time_ops,
                new_t.last_spend_time_rd == now,
                new_t.last_spend_time_buffer == t.last_spend_time_buffer,
              }
            Buffer -> and {
                new_t.last_spend_time_audit == t.last_spend_time_audit,
                new_t.last_spend_time_ops == t.last_spend_time_ops,
                new_t.last_spend_time_rd == t.last_spend_time_rd,
                new_t.last_spend_time_buffer == now,
              }
          }

        // Static fields preserved
        let static_ok = and {
            new_t.audit_bps == t.audit_bps,
            new_t.ops_bps == t.ops_bps,
            new_t.rd_bps == t.rd_bps,
            new_t.buffer_bps == t.buffer_bps,
            new_t.last_param_update_time == t.last_param_update_time,
            new_t.monthly_cap_audit == t.monthly_cap_audit,
            new_t.monthly_cap_ops == t.monthly_cap_ops,
            new_t.monthly_cap_rd == t.monthly_cap_rd,
            new_t.monthly_cap_buffer == t.monthly_cap_buffer,
          }

        // recent_spend_log: prepend new record, drop tail to honor cap
        let new_record =
          TreasurySpendRecord {
            tx_hash: tx.id,
            category,
            amount,
            recipient: recip_out.address,
            timestamp: now,
          }
        let proposed_log = list.push(t.recent_spend_log, new_record)
        let log_ok =
          new_t.recent_spend_log == list.take(proposed_log, treasury_log_cap)

        and {
          identity_ok,
          governance_authorized,
          amount_ok,
          balance_ok,
          cooldown_ok,
          range_width_ok,
          monthly_cap_ok,
          audit_floor_ok,
          not_self_loop,
          recipient_amount_ok,
          usdcx_delta_ok,
          bal_ok,
          last_spend_ok,
          static_ok,
          log_ok,
        }
      }

      // ══════════════════════════════════════════════════════
      // UpdateParams — governance-gated ratio + cap adjustment
      // ══════════════════════════════════════════════════════
      UpdateParams {
        new_audit_bps,
        new_ops_bps,
        new_rd_bps,
        new_buffer_bps,
        new_monthly_cap_audit,
        new_monthly_cap_ops,
        new_monthly_cap_rd,
        new_monthly_cap_buffer,
      } -> {
        // H-1: payload-hash binding for governance authorization
        let expected_payload_hash =
          payload_hash_treasury_params(
            new_audit_bps,
            new_ops_bps,
            new_rd_bps,
            new_buffer_bps,
            new_monthly_cap_audit,
            new_monthly_cap_ops,
            new_monthly_cap_rd,
            new_monthly_cap_buffer,
          )
        let governance_authorized =
          is_gov_authorized(
            tx,
            t.governance_policy,
            t.governance_name,
            ActUpdateTreasuryParams,
            expected_payload_hash,
            own_hash,
          )
        let sum_ok =
          new_audit_bps + new_ops_bps + new_rd_bps + new_buffer_bps == 10_000
        let bps_bounds_ok = and {
            new_audit_bps >= treasury_audit_floor_bps,
            new_audit_bps <= 5_000,
            new_ops_bps >= 0,
            new_ops_bps <= 5_000,
            new_rd_bps >= 0,
            new_rd_bps <= 5_000,
            new_buffer_bps >= 0,
            new_buffer_bps <= 5_000,
          }
        let cap_bounds_ok = and {
            new_monthly_cap_audit >= 0,
            new_monthly_cap_audit <= 100_000_000_000,
            new_monthly_cap_ops >= 0,
            new_monthly_cap_ops <= 100_000_000_000,
            new_monthly_cap_rd >= 0,
            new_monthly_cap_rd <= 100_000_000_000,
            new_monthly_cap_buffer >= 0,
            new_monthly_cap_buffer <= 100_000_000_000,
          }

        expect Finite(now) = tx.validity_range.lower_bound.bound_type
        let cooldown_ok =
          now - t.last_param_update_time >= treasury_param_cooldown_ms

        let usdcx_delta_ok = out_usdcx == in_usdcx
        let bal_ok = and {
            new_t.audit_reserve_balance == t.audit_reserve_balance,
            new_t.operations_balance == t.operations_balance,
            new_t.rd_balance == t.rd_balance,
            new_t.buffer_balance == t.buffer_balance,
          }
        let new_fields_ok = and {
            new_t.audit_bps == new_audit_bps,
            new_t.ops_bps == new_ops_bps,
            new_t.rd_bps == new_rd_bps,
            new_t.buffer_bps == new_buffer_bps,
            new_t.monthly_cap_audit == new_monthly_cap_audit,
            new_t.monthly_cap_ops == new_monthly_cap_ops,
            new_t.monthly_cap_rd == new_monthly_cap_rd,
            new_t.monthly_cap_buffer == new_monthly_cap_buffer,
          }
        let other_unchanged = and {
            new_t.last_spend_time_audit == t.last_spend_time_audit,
            new_t.last_spend_time_ops == t.last_spend_time_ops,
            new_t.last_spend_time_rd == t.last_spend_time_rd,
            new_t.last_spend_time_buffer == t.last_spend_time_buffer,
            new_t.last_param_update_time == now,
            new_t.recent_spend_log == t.recent_spend_log,
          }

        and {
          identity_ok,
          governance_authorized,
          sum_ok,
          bps_bounds_ok,
          cap_bounds_ok,
          cooldown_ok,
          usdcx_delta_ok,
          bal_ok,
          new_fields_ok,
          other_unchanged,
        }
      }
    }
  }

  else(_) {
    fail @"treasury: unsupported purpose"
  }
}
