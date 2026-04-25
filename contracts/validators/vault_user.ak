/// vault_user — permissionless user path (Deposit + Withdraw only, post Phase 77d)
///
/// Staking validator invoked via Withdraw-Zero from vault_proxy. Handles:
///   Deposit, Withdraw
///
/// Split history:
///   (1) 2026-04-22 Phase 77 — vault_core split into vault_user +
///       vault_keeper_hot along an authorization boundary. Each half
///       carries its own A2 `publish` handler so the Cardano stake
///       registration deposit (2 ADA) is reclaimable via governance
///       deregister at sunset.
///   (2) 2026-04-22 Phase 77d — BatchProcess extracted into standalone
///       `vault_batcher.ak` to hoist its ~9-11 KB bytecode footprint
///       (4 fold loops + OrderDatum/OrderRedeemer decode + list.unique
///       + 15+ datum equality checks + R51/R52 anti-leak invariants)
///       out of vault_user. The split also cleanly separates permission
///       domains: vault_user is now purely permissionless (no keeper
///       authorization), vault_batcher is keeper-authorized.
///
/// Authorization boundary (post Phase 77d):
///   Both remaining redeemers are permissionless — any wallet may sign
///   and submit. No `keeper_stake_hash` compile-time parameter is
///   required. BatchProcess (which IS keeper-authorized) lives in
///   vault_batcher.
///
/// vUSDCx mint/burn cross-validator binding:
///   vault_user mints vUSDCx on Deposit and burns on Withdraw. vault_
///   batcher does the aggregate net mint/burn on BatchProcess. Both
///   route through the same vault_proxy UTXO, and vusdcx.ak checks
///   "is the vault_proxy UTXO being spent?" (not "is a specific staking
///   validator running"), so the split is architecturally transparent
///   to the minting policy. vault_proxy's `withdrawal_count == 1`
///   invariant rules out mix-and-match mint-authority attacks.

use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{flatten, quantity_of}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{Transaction}
use aiken/interval.{Finite}
use vault/constants.{
  keeper_inactive_ms, min_valid_timestamp_ms, vault_nft_token_name,
}
use vault/helpers.{
  find_vault_utxo, get_continuing_datum, get_mint_quantity, is_gov_authorized,
  payload_hash_deregister_stake, verify_other_tokens_preserved,
  verify_output_value_min, verify_receiver_output, verify_token_preserved,
}
use vault/types.{
  ActDeregisterStake, CommunitySunset, Deposit, VaultRedeemer, Withdraw,
}
use vault/validation.{
  calculate_shares_to_mint, calculate_withdraw_amount, check_immutable_fields,
  has_no_order_inputs as val_has_no_order_inputs, validate_community_sunset_transition,
  validate_community_sunset_trigger_time, validate_deposit,
}

// ─────────────────────────────────────────────────────────────────────
// vault_user compile-time anchors (post Phase 77d)
//
//   governance_nft_policy  — A2 publish gate.
//   governance_nft_name    — A2 publish gate.
//
// keeper_stake_hash is NOT a parameter: neither Deposit nor Withdraw
// is keeper-authorized. BatchProcess, which is, lives in vault_batcher.
// ─────────────────────────────────────────────────────────────────────

validator vault_user(
  governance_nft_policy: ByteArray,
  governance_nft_name: ByteArray,
) {
  withdraw(redeemer: VaultRedeemer, account: Credential, tx: Transaction) {
    expect Script(_) = account
    let (own_input, old_datum, own_lovelace, vault_input_count, proxy_hash) =
      find_vault_utxo(tx.inputs)

    when redeemer is {
      // ══════════════════════════════════════════════════════
      // Deposit — user direct deposit
      // ══════════════════════════════════════════════════════
      Deposit { amount } -> {
        expect vault_input_count == 1
        expect old_datum.frozen == 0
        expect amount > 0
        expect old_datum.deposit_token_policy != #""

        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let expected_shares =
          calculate_shares_to_mint(
            amount,
            old_datum.total_deposited,
            old_datum.total_shares,
          )
        let minted = get_mint_quantity(tx, old_datum.vusdcx_policy)
        let valid_mint = minted == expected_shares

        let valid_value = {
          let old_qty =
            quantity_of(
              own_input.output.value,
              old_datum.deposit_token_policy,
              old_datum.deposit_token_name,
            )
          let new_qty =
            quantity_of(
              cont_output.value,
              old_datum.deposit_token_policy,
              old_datum.deposit_token_name,
            )
          and {
            new_qty == old_qty + amount,
            verify_output_value_min(cont_output, own_lovelace),
          }
        }

        let valid_other_tokens =
          verify_other_tokens_preserved(
            own_input.output,
            cont_output,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
            #"",
            #"",
          )

        let no_order_inputs =
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash)

        and {
          validate_deposit(old_datum, new_datum, amount),
          valid_mint,
          valid_value,
          valid_other_tokens,
          no_order_inputs,
        }
      }

      // ══════════════════════════════════════════════════════
      // Withdraw — user direct withdraw
      //
      // Two paths:
      //   - Full drain: burn ALL shares, destroy vault (no continuing
      //     output, must burn Vault NFT in same TX).
      //   - Partial: burn some shares, continuing output reduced by
      //     withdraw_amount (base_withdraw minus early_fee; R49 M-4
      //     deferred-yield — early_fee stays physically in vault).
      // ══════════════════════════════════════════════════════
      Withdraw { shares, receiver, receiver_output_idx } -> {
        expect vault_input_count == 1
        let burned = get_mint_quantity(tx, old_datum.vusdcx_policy)
        let valid_burn = burned == -shares

        let base_withdraw =
          calculate_withdraw_amount(
            shares,
            old_datum.total_deposited,
            old_datum.total_shares,
          )

        // Internal verification fix: the 7-day keeper-inactivity gate must
        // read `last_compound_time` only, not `max(last_realloc, last_compound)`.
        // Rationale from whitepaper §5.4: zero-yield heartbeat bumps
        // `last_realloc_time` and must NOT reset the 7-day fallback window,
        // otherwise a compromised keeper can game liveness by running
        // heartbeats without delivering real yield.
        let keeper_inactive =
          when tx.validity_range.lower_bound.bound_type is {
            Finite(now) ->
              and {
                old_datum.last_compound_time > min_valid_timestamp_ms,
                now >= old_datum.last_compound_time + keeper_inactive_ms,
              }
            _ -> False
          }
        let min_hold_ok =
          when tx.validity_range.lower_bound.bound_type is {
            Finite(now) ->
              or {
                old_datum.min_hold_seconds == 0,
                keeper_inactive,
                now >= old_datum.last_compound_time + old_datum.min_hold_seconds * 1_000,
              }
            _ -> False
          }
        expect min_hold_ok

        let early_fee =
          if keeper_inactive {
            0
          } else {
            base_withdraw * old_datum.early_withdraw_fee_bps / 10_000
          }
        let withdraw_amount = base_withdraw - early_fee

        let valid_receiver =
          verify_receiver_output(
            tx.outputs,
            receiver,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
            withdraw_amount,
            receiver_output_idx,
          )

        // Disallow full-drain with early fee (would create an off-chain race)
        expect !( shares == old_datum.total_shares && early_fee > 0 )

        if shares == old_datum.total_shares && early_fee == 0 {
          // ── Full drain ──
          let allocs_empty = list.is_empty(old_datum.strategy_allocations)
          let no_stranded = old_datum.non_deposit_value == 0
          let no_liqwid = list.is_empty(old_datum.liqwid_positions)
          let no_continuing =
            !list.any(
              tx.outputs,
              fn(output) {
                when output.address.payment_credential is {
                  Script(hash) -> hash == proxy_hash
                  _ -> False
                }
              },
            )

          // Full-drain NFT-burn: discover the real Vault NFT policy via a
          // single matching token entry (proxy layer's compile-time
          // vault_nft_policy anchor guarantees uniqueness). Defense-in-depth
          // `opti_vault_count == 1` catches any future drift.
          let opti_vault_count =
            list.foldl(
              flatten(own_input.output.value),
              0,
              fn(entry, acc) {
                let (_, name, qty) = entry
                if name == vault_nft_token_name && qty == 1 {
                  acc + 1
                } else {
                  acc
                }
              },
            )
          expect opti_vault_count == 1
          let real_nft_policy =
            list.foldl(
              flatten(own_input.output.value),
              #"",
              fn(entry, acc) {
                let (policy, name, qty) = entry
                if name == vault_nft_token_name && qty == 1 && acc == #"" {
                  policy
                } else {
                  acc
                }
              },
            )
          expect real_nft_policy != #""
          let nft_burned =
            quantity_of(tx.mint, real_nft_policy, vault_nft_token_name) == -1

          and {
            shares > 0,
            valid_burn,
            allocs_empty,
            no_stranded,
            no_liqwid,
            no_continuing,
            valid_receiver,
            nft_burned,
            val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash),
          }
        } else {
          // ── Partial ──
          let (cont_output, new_datum) =
            get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

          let valid_value = verify_output_value_min(cont_output, own_lovelace)
          let valid_token =
            verify_token_preserved(
              own_input.output,
              cont_output,
              old_datum.deposit_token_policy,
              old_datum.deposit_token_name,
              withdraw_amount,
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

          // Deferred-yield rule (R49 M-4): idle_buffer + total_deposited
          // reduce by `withdraw_amount` (NOT base_withdraw). The early
          // fee remains physically in the vault and surfaces as share-
          // price appreciation at the next Compound.
          expect withdraw_amount <= old_datum.idle_buffer
          let valid_buffer =
            new_datum.idle_buffer == old_datum.idle_buffer - withdraw_amount
          let valid_deposited =
            new_datum.total_deposited == old_datum.total_deposited - withdraw_amount
          let valid_shares_update =
            new_datum.total_shares == old_datum.total_shares - shares
          let valid_allocs =
            new_datum.strategy_allocations == old_datum.strategy_allocations
          let valid_time =
            new_datum.last_compound_time == old_datum.last_compound_time
          let valid_imm = check_immutable_fields(old_datum, new_datum)

          and {
            shares > 0,
            valid_burn,
            valid_value,
            valid_token,
            valid_other,
            valid_buffer,
            valid_deposited,
            valid_shares_update,
            valid_allocs,
            valid_time,
            valid_imm,
            valid_receiver,
            new_datum.liqwid_positions == old_datum.liqwid_positions,
            new_datum.non_deposit_value == old_datum.non_deposit_value,
            new_datum.frozen == old_datum.frozen,
            new_datum.community_sunset_triggered == old_datum.community_sunset_triggered,
            new_datum.last_realloc_time == old_datum.last_realloc_time,
            new_datum.last_fee_update_time == old_datum.last_fee_update_time,
            new_datum.last_ada_swap_time == old_datum.last_ada_swap_time,
            new_datum.performance_fee_bps == old_datum.performance_fee_bps,
            new_datum.early_withdraw_fee_bps == old_datum.early_withdraw_fee_bps,
            new_datum.min_hold_seconds == old_datum.min_hold_seconds,
            new_datum.buffer_target_bps == old_datum.buffer_target_bps,
            new_datum.keeper_fee_bps == old_datum.keeper_fee_bps,
            new_datum.gov_fee_bps == old_datum.gov_fee_bps,
            new_datum.max_slippage_bps == old_datum.max_slippage_bps,
            new_datum.min_swap_peg_bps == old_datum.min_swap_peg_bps,
            val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash),
          }
        }
      }

      // ══════════════════════════════════════════════════════
      // CommunitySunset — permissionless dead-man-switch
      // (Phase 1 governance safety, Layer 3, 2026-04-25)
      //
      // Any vUSDCx holder may invoke this redeemer when the vault has
      // been operationally inactive for ≥ 90 days. The threshold is
      // measured against `max(last_compound_time, last_realloc_time)`
      // — both are updated by the keeper (real-yield Compound + 5d
      // zero-yield heartbeat respectively), so 90 days of stagnation
      // means the keeper is entirely dead. Triggering sets:
      //
      //   - frozen = 1  (atomically halt productive ops)
      //   - community_sunset_triggered = 1  (one-way irreversible flag)
      //
      // Once set, the flag opens permissionless recovery paths in
      // vault_recall.RecallFromLiqwid + vault_protocol.DeployToProtocol
      // Layer 2 (skipping the keeper-active / keeper-signature gate
      // that those redeemers normally require). Any vUSDCx holder can
      // then drive Recall → swap → Withdraw to recover their full
      // proportional USDCx share, without any keeper or governance
      // intervention.
      //
      // Caller verification: the TX must consume an input carrying ≥ 1
      // vUSDCx. Spam-griefing is bounded — sunset is one-way, can only
      // fire once, and only when the 90-day stagnation precondition is
      // met (which itself requires the system to already be dead).
      // ══════════════════════════════════════════════════════
      CommunitySunset -> {
        expect vault_input_count == 1
        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        // Caller must hold ≥ 1 vUSDCx in some TX input. Anyone with a
        // legitimate stake in the vault can fire; full external attackers
        // would need to acquire vUSDCx first (which costs them money) and
        // can only fire once anyway.
        let caller_has_vusdcx =
          list.any(
            tx.inputs,
            fn(input) {
              quantity_of(input.output.value, old_datum.vusdcx_policy, "") > 0
            },
          )

        // 90-day inactivity threshold — see
        // validate_community_sunset_trigger_time docs.
        let inactivity_satisfied =
          when tx.validity_range.lower_bound.bound_type is {
            Finite(now) ->
              validate_community_sunset_trigger_time(
                old_datum.last_compound_time,
                old_datum.last_realloc_time,
                now,
              )
            _ -> False
          }

        // Datum transition: flip frozen + sunset_triggered, preserve
        // everything else.
        let valid_transition =
          validate_community_sunset_transition(old_datum, new_datum)

        // Token preservation: cont_output must carry the same Vault
        // NFT + same value as the old vault UTXO (no fund movement).
        let valid_value_preserved =
          verify_other_tokens_preserved(
            own_input.output,
            cont_output,
            #"",
            #"",
            #"",
            #"",
          )

        // Defense-in-depth: no order inputs, no mint, lovelace floor.
        let no_mint = get_mint_quantity(tx, old_datum.vusdcx_policy) == 0
        let no_order_inputs =
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash)

        and {
          caller_has_vusdcx,
          inactivity_satisfied,
          valid_transition,
          valid_value_preserved,
          no_mint,
          no_order_inputs,
        }
      }

      // BatchProcess moved to vault_batcher.ak (Phase 77d split,
      // 2026-04-22). Other redeemers handled by vault_keeper_hot /
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
    fail @"vault_user: unsupported purpose"
  }
}
