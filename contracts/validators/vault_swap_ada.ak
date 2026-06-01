/// vault_swap_ada — closed-loop ADA replenishment (2026-04-22 swap-ada extraction from vault_keeper_hot)
///
/// Staking validator invoked via Withdraw-Zero from vault_proxy with
/// the `UseSwapAda` redeemer. Handles a single redeemer:
///
///   SwapAda — swap USDCx → ADA via the dual-feed oracle, depositing
///             ADA into the vault and paying USDCx to the keeper's
///             output at an oracle-derived fair rate. See
///             `spec/ada-swap.md` for the full specification.
///
/// Split rationale (swap-ada extraction, 2026-04-22):
///   Pre-split vault_keeper_hot carried Compound + RebalanceBuffer +
///   SwapAda and sat at 15,437 B / 947 B headroom. The §5.4 P5 dual-
///   feed oracle reader (`find_asset_oracle` + `read_fair_price`) plus
///   the registry 6-tuple read `read_registry_datum_full` — both
///   needed ONLY by SwapAda — were accounting for ~4-5 KB of
///   vault_keeper_hot's footprint. Extracting SwapAda into its own
///   validator:
///     - Removes the oracle machinery + registry read from vault_
///       keeper_hot (restores ~4-5 KB headroom on Compound's host).
///     - Gives SwapAda its own stake credential, A2 publish path, and
///       UseSwapAda Withdraw-Zero route in vault_proxy.
///     - Matches the B@launch=1 architecture pattern already used by
///       minswap_v2_adapter: a standalone staking validator with a
///       single specialised responsibility.
///
/// Operational note: at V1 launch `asset_oracles = []` in the Registry.
/// SwapAda is inactive until governance populates the ADA entry (policy
/// + name both empty — the ADA convention) via `UpdateRegistry` with
/// a 14-day timelock. Bootstrap vault ADA via MergeUtxo donation if
/// needed before SwapAda is armed.
///
/// Compile-time anchors:
///   keeper_stake_hash      — zero-withdraw keeper auth on SwapAda.
///   governance_nft_policy  — A2 publish handler gate.
///   governance_nft_name    — A2 publish handler gate.

use aiken/collection/list
use aiken/interval.{Finite}
use cardano/address.{Credential, Script, VerificationKey}
use cardano/assets.{lovelace_of, quantity_of}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{Transaction}
use vault/constants.{
  ada_swap_max, ada_swap_min, ada_swap_price_ceiling_bps,
  ada_swap_price_floor_bps, ada_swap_threshold, max_validity_range_ms,
  one_hour_ms,
}
use vault/helpers.{
  find_vault_utxo, get_continuing_datum, get_mint_quantity, is_gov_authorized,
  payload_hash_deregister_stake, read_registry_datum_full,
  verify_other_tokens_preserved,
}
use vault/oracle.{find_asset_oracle, read_fair_price}
use vault/types.{ActDeregisterStake, SwapAda, VaultRedeemer}
use vault/validation.{
  check_immutable_fields, has_no_order_inputs as val_has_no_order_inputs,
  require_keeper_stake_script,
}

validator vault_swap_ada(
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
      // SwapAda — closed-loop ADA replenishment (spec/ada-swap.md)
      //
      // §5.4 P5 — dual-feed oracle: ADA price is read from the
      // registry's `asset_oracles` entry for (#"", #"") (ADA convention
      // policy+name). The entry pins two feed UTXOs (typically one
      // Charli3 + one Orcfax), each carrying an InlineDatum
      // `PriceSample { price_bps, timestamp_ms }`. `read_fair_price`
      // checks freshness + cross-feed disagreement before returning
      // the midpoint. If the ADA oracle entry is missing or fails
      // validation (stale / disagreeing / degenerate), SwapAda fails.
      //
      // V1 launches with `asset_oracles = []` — SwapAda is inactive
      // until governance `UpdateRegistry` populates the ADA entry via
      // 14d timelock. During the bootstrap window, the vault can be
      // topped up via MergeUtxo donations if needed (operator path).
      // ══════════════════════════════════════════════════════
      SwapAda { amount_ada, keeper_output_idx } -> {
        expect vault_input_count == 1
        expect old_datum.frozen == 0
        let keeper_authorized = require_keeper_stake_script(tx, keeper_stake_hash)

        let (cont_output, new_datum) =
          get_continuing_datum(tx.outputs, proxy_hash, own_input.output)

        let amount_in_range = and {
            amount_ada >= ada_swap_min,
            amount_ada <= ada_swap_max,
          }
        let ada_below_threshold = own_lovelace < ada_swap_threshold

        // ADA flows IN to vault
        let ada_added = lovelace_of(cont_output.value) == own_lovelace + amount_ada

        // Read ADA fair price via dual-feed oracle (§5.4 P5). Returns
        // price_bps in USDCx-per-ADA × 10_000. Example: ada_price_bps ==
        // 5_000 means 1 ADA = 0.5 USDCx.
        //
        // Divisor is 10_000 (= 10^4). Dimensional analysis:
        //   amount_ada is in lovelace (ADA × 10^6);
        //   ada_price_bps is dimensionless × 10^4 (oracle.ak convention);
        //   target output is microUSDCx (USDCx × 10^6).
        //   amount_ada × ada_price_bps / 10^4
        //     = (ADA × 10^6) × (dimensionless × 10^4) / 10^4
        //     = ADA × dimensionless × 10^6
        //     = USDCx × 10^6 = microUSDCx ✓
        // Both ADA and USDCx have 6 decimals, so the microunit-to-
        // whole-unit ratios cancel cleanly. This formula MUST stay
        // synchronised with `oracle.ak::check_tier1_bound`, which uses
        // the same /10^4 divisor on the same `read_fair_price` return.
        expect old_datum.registry_auth_policy != #""
        let (_, _, _, _, asset_oracles_list, _) =
          read_registry_datum_full(
            tx.reference_inputs,
            old_datum.registry_hash,
            old_datum.registry_auth_policy,
          )
        expect Some(ada_entry) = find_asset_oracle(asset_oracles_list, #"", #"")
        expect Some(ada_price_bps) = read_fair_price(tx, ada_entry)
        // (2026-05-30): absolute sanity band on the oracle price.
        // read_fair_price already enforces the dual-feed disagreement guard
        // (distinct-feed quorum); this wide band ($0.01–$100/ADA) is
        // a backstop against a both-feeds-broken / mis-decoded degenerate
        // value mis-pricing the keeper's USDCx-for-ADA fill.
        expect ada_price_bps >= ada_swap_price_floor_bps
        expect ada_price_bps <= ada_swap_price_ceiling_bps
        let usdcx_out_expected = amount_ada * ada_price_bps / 10_000

        let usdcx_in_input =
          quantity_of(
            own_input.output.value,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
          )
        let usdcx_in_output =
          quantity_of(
            cont_output.value,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
          )
        let usdcx_deducted = usdcx_in_input == usdcx_in_output + usdcx_out_expected

        // Keeper receives the USDCx.
        let valid_keeper_output =
          if usdcx_out_expected > 0 {
            expect Some(kout) = list.at(tx.outputs, keeper_output_idx)
            when kout.address.payment_credential is {
              VerificationKey(pkh) ->
                and {
                  list.has(tx.extra_signatories, pkh),
                  quantity_of(
                    kout.value,
                    old_datum.deposit_token_policy,
                    old_datum.deposit_token_name,
                  ) >= usdcx_out_expected,
                }
              _ -> False
            }
          } else {
            False
          }

        // Cooldown + validity-range width cap on last_ada_swap_time
        let valid_cooldown =
          when (
            tx.validity_range.lower_bound.bound_type,
            tx.validity_range.upper_bound.bound_type,
          ) is {
            (Finite(now), Finite(upper)) ->
              and {
                now >= old_datum.last_ada_swap_time + one_hour_ms,
                upper - now <= max_validity_range_ms,
                new_datum.last_ada_swap_time >= now,
                new_datum.last_ada_swap_time <= upper,
              }
            _ -> False
          }

        // Datum: only last_ada_swap_time + idle_buffer change; everything
        // else preserved.
        let valid_datum_other = and {
            new_datum.total_deposited == old_datum.total_deposited,
            new_datum.total_shares == old_datum.total_shares,
            new_datum.idle_buffer == old_datum.idle_buffer - usdcx_out_expected,
            new_datum.non_deposit_value == old_datum.non_deposit_value,
            new_datum.last_compound_time == old_datum.last_compound_time,
            new_datum.last_realloc_time == old_datum.last_realloc_time,
            new_datum.last_fee_update_time == old_datum.last_fee_update_time,
            new_datum.strategy_allocations == old_datum.strategy_allocations,
            new_datum.liqwid_positions == old_datum.liqwid_positions,
            new_datum.frozen == old_datum.frozen,
            new_datum.community_sunset_triggered == old_datum.community_sunset_triggered,
            new_datum.performance_fee_bps == old_datum.performance_fee_bps,
            new_datum.early_withdraw_fee_bps == old_datum.early_withdraw_fee_bps,
            new_datum.min_hold_seconds == old_datum.min_hold_seconds,
            new_datum.buffer_target_bps == old_datum.buffer_target_bps,
            new_datum.keeper_fee_bps == old_datum.keeper_fee_bps,
            new_datum.gov_fee_bps == old_datum.gov_fee_bps,
            new_datum.max_slippage_bps == old_datum.max_slippage_bps,
            new_datum.min_swap_peg_bps == old_datum.min_swap_peg_bps,
            check_immutable_fields(old_datum, new_datum),
            new_datum.idle_buffer >= 0,
          }

        let valid_other_tokens_preserved =
          verify_other_tokens_preserved(
            own_input.output,
            cont_output,
            old_datum.deposit_token_policy,
            old_datum.deposit_token_name,
            #"",
            #"",
          )
        let no_mint = get_mint_quantity(tx, old_datum.vusdcx_policy) == 0
        let no_order_inputs =
          val_has_no_order_inputs(tx.inputs, old_datum.order_script_hash)

        and {
          keeper_authorized,
          amount_in_range,
          ada_below_threshold,
          ada_added,
          usdcx_deducted,
          valid_keeper_output,
          valid_cooldown,
          valid_datum_other,
          valid_other_tokens_preserved,
          no_mint,
          no_order_inputs,
        }
      }

      // Other redeemers handled by vault_user / vault_keeper_hot /
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
    fail @"vault_swap_ada: unsupported purpose"
  }
}
