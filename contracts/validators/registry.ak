/// registry — Protocol whitelist + Liqwid market catalog
///
/// Three redeemers (no payload args; new RegistryDatum is read from the
/// continuing output's InlineDatum and per-redeemer invariants are
/// checked against the old datum):
///
///   - UpdateRegistry      Governance-gated; updates protocol_hashes /
///                          stable_tokens / liqwid_markets. governance_*
///                          and keeper_pkh are immutable here (internal verification).
///   - KeeperToggleMarket  Keeper unilateral; flips liqwid_markets[*]
///                          .active from True to False (one-way).
///                          Requires at least one actual toggle (internal verification).
///   - FastUpdateMarkets   Governance fast-path for Liqwid migrations;
///                          updates only action_addr_hash + active.
///
/// All three preserve the auth NFT and the Registry UTXO's lovelace.

use aiken/collection/list
use aiken/interval.{Finite}
use aiken/primitive/bytearray
use cardano/address.{Script}
use cardano/assets.{flatten as assets_flatten, lovelace_of, quantity_of}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}
use vault/constants.{one_hour_ms}
use vault/helpers.{is_gov_authorized, payload_hash_update_registry}
use vault/types.{
  ActFastUpdateMarkets, ActUpdateRegistry, FastUpdateMarkets,
  KeeperToggleMarket, RegistryDatum, RegistryRedeemer, UpdateRegistry,
}
use vault/validation.{valid_asset_oracle_entry}

/// `valid_asset_oracle_entry` now lives in `lib/vault/validation.ak`
/// (extracted after the oracle-validation audit round) so the pure
/// predicate can be imported by both this validator and its regression
/// test. See validation.ak for the C7 structural checks + upper-bound
/// caps on Registry-mutable fields (max_disagreement_bps ≤ 1000,
/// max_staleness_ms ≤ 1h).

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

validator registry {
  spend(
    datum: Option<RegistryDatum>,
    redeemer: RegistryRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) {
    expect Some(reg) = datum

    when redeemer is {
      UpdateRegistry -> {
        expect Some(own_input) =
          list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
        expect Script(own_hash) = own_input.output.address.payment_credential
        expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
        expect InlineDatum(new_data) = cont_output.datum
        expect new_reg: RegistryDatum = new_data

        // H-1: payload-hash binding — governance commits to the exact new
        // RegistryDatum at queue time.
        let expected_payload_hash = payload_hash_update_registry(new_reg)
        let governance_authorized =
          is_gov_authorized(
            tx,
            reg.governance_policy,
            reg.governance_name,
            ActUpdateRegistry,
            expected_payload_hash,
            own_hash,
          )

        // Governance + keeper_pkh immutable (internal verification)
        let valid_governance = and {
            new_reg.governance_policy == reg.governance_policy,
            new_reg.governance_name == reg.governance_name,
            new_reg.keeper_pkh == reg.keeper_pkh,
          }

        let valid_list = !list.is_empty(new_reg.protocol_hashes)
        let valid_length = list.length(new_reg.protocol_hashes) <= 20
        let valid_stable_length = list.length(new_reg.stable_tokens) <= 50
        let valid_markets_length = list.length(new_reg.liqwid_markets) <= 20
        // §5.4 P3: cap asset_oracles to 20 (each entry holds 2-3 feeds,
        // so 20 × 3 = 60 reference inputs worst-case; keeps tx evaluation
        // bounded). No structural invariants on entries themselves —
        // asset_policy+name can alias an existing entry to replace it
        // (by convention only, uniqueness not enforced here; downstream
        // readers use `list.find` which returns first match).
        let valid_oracles_length = list.length(new_reg.asset_oracles) <= 20
        // C7 structural validation — each entry must be well-formed.
        let valid_oracles_entries =
          list.all(new_reg.asset_oracles, valid_asset_oracle_entry)

        // §B@launch=1: swap_adapter_hashes cap + structural validation.
        // Each hash must be 28 bytes (Plutus V3 script hash length).
        let valid_adapters_length = list.length(new_reg.swap_adapter_hashes) <= 10
        let valid_adapters_shape =
          list.all(
            new_reg.swap_adapter_hashes,
            fn(h) { bytearray.length(h) == 28 },
          )
        let valid_adapters_unique =
          list.length(new_reg.swap_adapter_hashes) == list.length(
            list.unique(new_reg.swap_adapter_hashes),
          )

        // liqwid_markets append-only by length (existing market_id stays valid)
        let valid_markets_monotonic =
          list.length(new_reg.liqwid_markets) >= list.length(reg.liqwid_markets)

        // Existing market entries: qtoken + underlying immutable
        let valid_markets_immutable =
          list.all(
            list.zip(reg.liqwid_markets, new_reg.liqwid_markets),
            fn(pair) {
              let (old_m, new_m) = pair
              and {
                old_m.qtoken_policy == new_m.qtoken_policy,
                old_m.qtoken_name == new_m.qtoken_name,
                old_m.underlying_policy == new_m.underlying_policy,
                old_m.underlying_name == new_m.underlying_name,
              }
            },
          )

        // No qToken collision (would corrupt RecallFromLiqwid governance fallback)
        let valid_markets_unique = {
          let qtoken_ids =
            list.map(
              new_reg.liqwid_markets,
              fn(m) { (m.qtoken_policy, m.qtoken_name) },
            )
          list.length(qtoken_ids) == list.length(list.unique(qtoken_ids))
        }

        let valid_value =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)

        // Auth NFT + every other token preserved
        let valid_auth_nft =
          list.all(
            list.filter(
              assets_flatten(own_input.output.value),
              fn(entry) {
                let (policy, _, _) = entry
                policy != #""
              },
            ),
            fn(entry) {
              let (policy, name, qty) = entry
              quantity_of(cont_output.value, policy, name) >= qty
            },
          )

        // No new token policies in continuing output
        let no_new_tokens =
          list.all(
            assets_flatten(cont_output.value),
            fn(entry) {
              let (policy, name, _) = entry
              if policy == #"" {
                True
              } else {
                quantity_of(own_input.output.value, policy, name) > 0
              }
            },
          )

        let no_duplicates =
          list.length(new_reg.protocol_hashes) == list.length(
            list.unique(new_reg.protocol_hashes),
          )

        // last_update_time anchored to TX validity lower bound + 1h cooldown
        // + 1h validity-range width cap (internal-verification family).
        let valid_update_time =
          when (
            tx.validity_range.lower_bound.bound_type,
            tx.validity_range.upper_bound.bound_type,
          ) is {
            (Finite(now), Finite(upper)) ->
              and {
                new_reg.last_update_time == now,
                now >= reg.last_update_time + one_hour_ms,
                upper - now <= one_hour_ms,
              }
            _ -> False
          }

        and {
          governance_authorized,
          valid_governance,
          valid_list,
          valid_length,
          valid_stable_length,
          valid_markets_length,
          valid_oracles_length,
          valid_oracles_entries,
          valid_adapters_length,
          valid_adapters_shape,
          valid_adapters_unique,
          valid_markets_monotonic,
          valid_markets_immutable,
          valid_markets_unique,
          valid_value,
          valid_auth_nft,
          no_new_tokens,
          no_duplicates,
          valid_update_time,
        }
      }

      KeeperToggleMarket -> {
        expect reg.keeper_pkh != #""
        let keeper_authorized = list.has(tx.extra_signatories, reg.keeper_pkh)

        expect Some(own_input) =
          list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
        expect Script(own_hash) = own_input.output.address.payment_credential
        expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
        expect InlineDatum(new_data) = cont_output.datum
        expect new_reg: RegistryDatum = new_data

        let valid_unchanged = and {
            new_reg.governance_policy == reg.governance_policy,
            new_reg.governance_name == reg.governance_name,
            new_reg.protocol_hashes == reg.protocol_hashes,
            new_reg.last_update_time == reg.last_update_time,
            new_reg.stable_tokens == reg.stable_tokens,
            new_reg.asset_oracles == reg.asset_oracles,
            new_reg.swap_adapter_hashes == reg.swap_adapter_hashes,
            new_reg.keeper_pkh == reg.keeper_pkh,
            list.length(new_reg.liqwid_markets) == list.length(reg.liqwid_markets),
          }

        // Per-market: identity + addr immutable; active can only go T→F
        let valid_toggle =
          list.all(
            list.zip(reg.liqwid_markets, new_reg.liqwid_markets),
            fn(pair) {
              let (old_m, new_m) = pair
              and {
                old_m.action_addr_hash == new_m.action_addr_hash,
                old_m.qtoken_policy == new_m.qtoken_policy,
                old_m.qtoken_name == new_m.qtoken_name,
                old_m.underlying_policy == new_m.underlying_policy,
                old_m.underlying_name == new_m.underlying_name,
                old_m.active == new_m.active || !new_m.active,
              }
            },
          )

        // Internal verification: at least one True→False transition required
        let actually_toggled =
          list.any(
            list.zip(reg.liqwid_markets, new_reg.liqwid_markets),
            fn(pair) {
              let (old_m, new_m) = pair
              old_m.active && !new_m.active
            },
          )

        let valid_value =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)
        let valid_auth_nft =
          list.all(
            list.filter(
              assets_flatten(own_input.output.value),
              fn(entry) {
                let (policy, _, _) = entry
                policy != #""
              },
            ),
            fn(entry) {
              let (policy, name, qty) = entry
              quantity_of(cont_output.value, policy, name) >= qty
            },
          )
        let no_new_tokens =
          list.all(
            assets_flatten(cont_output.value),
            fn(entry) {
              let (policy, name, _) = entry
              policy == #"" || quantity_of(
                own_input.output.value,
                policy,
                name,
              ) > 0
            },
          )

        and {
          keeper_authorized,
          valid_unchanged,
          valid_toggle,
          actually_toggled,
          valid_value,
          valid_auth_nft,
          no_new_tokens,
        }
      }

      FastUpdateMarkets -> {
        expect Some(own_input) =
          list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
        expect Script(own_hash) = own_input.output.address.payment_credential
        expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
        expect InlineDatum(new_data) = cont_output.datum
        expect new_reg: RegistryDatum = new_data

        // H-1: payload-hash binding — governance commits to the exact new
        // RegistryDatum at queue time.
        let expected_payload_hash = payload_hash_update_registry(new_reg)
        let governance_authorized =
          is_gov_authorized(
            tx,
            reg.governance_policy,
            reg.governance_name,
            ActFastUpdateMarkets,
            expected_payload_hash,
            own_hash,
          )

        let valid_unchanged = and {
            new_reg.governance_policy == reg.governance_policy,
            new_reg.governance_name == reg.governance_name,
            new_reg.protocol_hashes == reg.protocol_hashes,
            new_reg.stable_tokens == reg.stable_tokens,
            new_reg.asset_oracles == reg.asset_oracles,
            new_reg.swap_adapter_hashes == reg.swap_adapter_hashes,
            new_reg.keeper_pkh == reg.keeper_pkh,
            list.length(new_reg.liqwid_markets) == list.length(reg.liqwid_markets),
          }

        // Per-market: qtoken + underlying immutable; addr + active updatable
        let valid_markets =
          list.all(
            list.zip(reg.liqwid_markets, new_reg.liqwid_markets),
            fn(pair) {
              let (old_m, new_m) = pair
              and {
                old_m.qtoken_policy == new_m.qtoken_policy,
                old_m.qtoken_name == new_m.qtoken_name,
                old_m.underlying_policy == new_m.underlying_policy,
                old_m.underlying_name == new_m.underlying_name,
              }
            },
          )

        let valid_unique = {
          let ids =
            list.map(
              new_reg.liqwid_markets,
              fn(m) { (m.qtoken_policy, m.qtoken_name) },
            )
          list.length(ids) == list.length(list.unique(ids))
        }

        let valid_time =
          when (
            tx.validity_range.lower_bound.bound_type,
            tx.validity_range.upper_bound.bound_type,
          ) is {
            (Finite(now), Finite(upper)) ->
              and {
                new_reg.last_update_time == now,
                now >= reg.last_update_time + one_hour_ms,
                upper - now <= one_hour_ms,
              }
            _ -> False
          }

        let valid_value =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)
        let valid_auth_nft =
          list.all(
            list.filter(
              assets_flatten(own_input.output.value),
              fn(entry) {
                let (policy, _, _) = entry
                policy != #""
              },
            ),
            fn(entry) {
              let (policy, name, qty) = entry
              quantity_of(cont_output.value, policy, name) >= qty
            },
          )
        let no_new_tokens =
          list.all(
            assets_flatten(cont_output.value),
            fn(entry) {
              let (policy, name, _) = entry
              policy == #"" || quantity_of(
                own_input.output.value,
                policy,
                name,
              ) > 0
            },
          )

        and {
          governance_authorized,
          valid_unchanged,
          valid_markets,
          valid_unique,
          valid_time,
          valid_value,
          valid_auth_nft,
          no_new_tokens,
        }
      }
    }
  }

  else(_) {
    fail @"registry: unsupported purpose"
  }
}
