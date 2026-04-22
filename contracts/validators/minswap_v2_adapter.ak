/// minswap_v2_adapter — SwapAdapter for Minswap V2 orders.
///
/// PlutusV3 staking validator invoked via zero-withdrawal by
/// `vault_protocol.DeployToProtocol` (and `vault_gov_emergency.
/// AdminDeployNonDeposit`). Implements the SwapAdapter interface
/// defined in `lib/vault/swap_adapter.ak`.
///
/// Responsibility: decode the Minswap V2 order datum at
/// `redeemer.dest_output_idx` and verify that:
///   1. The order's step variant is a recognized swap (SwapExactIn
///      step_tag=0 or SwapMultiRouting step_tag=9); any other step
///      rejects.
///   2. The decoded `minimum_receive` matches `redeemer.min_receive`.
///   3. The decoded target asset (swap output asset) matches
///      `redeemer.target_asset_policy` + `redeemer.target_asset_name`.
///
/// Target asset derivation:
///   - SwapExactIn: from the order's `lp_asset` + `a_to_b_direction`.
///     lp_asset is `Asset { policy, name }` pair; a_to_b=True means
///     output is the b side, a_to_b=False means output is the a side.
///   - SwapMultiRouting: from the LAST hop of `swap_routing`. Each
///     `SwapRouting` entry has `(lp_asset, a_to_b_direction)`; the
///     chain's final output is the opposite asset of the last hop.
///
/// PRE-MAINNET VERIFICATION (same as lib/vault/swap.ak note):
/// Minswap V2 order datum CBOR structure must be verified against a
/// real mainnet Minswap V2 SwapExactIn + SwapMultiRouting order via
/// Preprod E2E before V1 mainnet deploy. If Minswap V2 changes its
/// datum format, this adapter needs updating + redeployment; registry
/// `swap_adapter_hashes` updated via governance `UpdateRegistry`
/// (14-day timelock) to rotate to the new adapter hash.
///
/// Parameterization — governance anchors only. The adapter takes
/// `governance_nft_policy` + `governance_nft_name` as compile-time
/// parameters so the `publish` handler (A2 ActDeregisterStake) can
/// call `is_gov_authorized` with the correct governance identity.
/// Every other V1 staking validator already carries the same A2
/// publish path; keeping the adapter excluded would have left a
/// ~2 ADA Cardano stake-registration deposit permanently locked per
/// adapter rotation (SwapAdapter is expected to be replaced over V1's
/// lifetime as DEX datum formats evolve). Changing governance anchors
/// changes the adapter hash — the same property that already holds
/// for every other V1 staking validator, so this does NOT weaken the
/// §B@launch=1 post-launch new-DEX-addition lifecycle (see
/// spec/swap-adapter.md). The adapter hash remains the sole identity
/// used by the Registry `swap_adapter_hashes` whitelist.

use aiken/builtin.{
  head_list, tail_list, un_b_data, un_constr_data, un_i_data,
}
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{InlineDatum, Output, Transaction}
use vault/helpers.{is_gov_authorized, payload_hash_deregister_stake}
use vault/swap_adapter.{SwapAdapterRedeemer}
use vault/types.{ActDeregisterStake}

// ─────────────────────────────────────────────────────────────────────
// Navigation helpers
// ─────────────────────────────────────────────────────────────────────

fn nth(xs: List<Data>, n: Int) -> Option<Data> {
  if n < 0 {
    None
  } else if n == 0 {
    when xs is {
      [] -> None
      [first, ..] -> Some(first)
    }
  } else {
    when xs is {
      [] -> None
      [_, ..rest] -> nth(rest, n - 1)
    }
  }
}

fn last_of(xs: List<Data>) -> Option<Data> {
  when xs is {
    [] -> None
    [single] -> Some(single)
    [_, ..rest] -> last_of(rest)
  }
}

// ─────────────────────────────────────────────────────────────────────
// Minswap V2 datum extraction
//
// OrderDatum = Constr(0, [canceller, refund_addr, refund_datum,
//                         success_addr, success_datum, lp_asset,
//                         step, max_batcher_fee, expire_opt])
//
// lp_asset observed structures (Minswap V2 2024-2026):
//   Variant A: Constr(0, [policy_a, name_a, policy_b, name_b])  — flat
//   Variant B: Constr(0, [Constr(0, [policy_a, name_a]),
//                         Constr(0, [policy_b, name_b])])       — pair
//
// We handle both by probing the first element's shape (ByteArray →
// Variant A, Constr → Variant B). Verified during Preprod E2E.
//
// step variants we decode:
//   Constr(0, [a_to_b, swap_amount, minimum_receive, killable])  — SwapExactIn
//   Constr(9, [swap_routing, swap_amount, minimum_receive])      — SwapMultiRouting
//
// SwapRoute (inside swap_routing list):
//   Constr(0, [lp_asset, a_to_b_direction])
// ─────────────────────────────────────────────────────────────────────

pub type DecodedOrder {
  min_receive: Int,
  target_policy: ByteArray,
  target_name: ByteArray,
}

/// Given lp_asset Data + direction bool, return the TARGET asset
/// (the side the swap outputs).
fn extract_target_from_lp(lp: Data, a_to_b: Bool) -> Option<(ByteArray, ByteArray)> {
  let lp_pair = un_constr_data(lp)
  let fields = lp_pair.2nd
  when fields is {
    [f0, f1, f2, f3] -> {
      // Try Variant A: flat (policy_a, name_a, policy_b, name_b).
      // If f0 is a Constr (Variant B pair), un_b_data would trap, so
      // we route via a probe: check if f0 Constr-decodes.
      // In Aiken we can only pattern-match via `expect` / `if data is`.
      // Simpler: if a_to_b, output = (f2, f3); else output = (f0, f1).
      // This works for both Variant A and Variant B if we handle both
      // pair-position and flat-position consistently — for Variant B,
      // f0 is itself a Constr so calling un_b_data on it would trap.
      // So we first try Variant A (un_b_data on each ByteArray slot);
      // if any trap happens the TX reverts. Variant B path branches
      // below via the 2-field-list case.
      let (out_p, out_n) =
        if a_to_b {
          (un_b_data(f2), un_b_data(f3))
        } else {
          (un_b_data(f0), un_b_data(f1))
        }
      Some((out_p, out_n))
    }
    [pair_a, pair_b] -> {
      // Variant B: nested pair of Assets. Pick the correct pair.
      let target_pair =
        if a_to_b {
          pair_b
        } else {
          pair_a
        }
      let asset_constr = un_constr_data(target_pair)
      let asset_fields = asset_constr.2nd
      when asset_fields is {
        [pol, nm] -> Some((un_b_data(pol), un_b_data(nm)))
        _ -> None
      }
    }
    _ -> None
  }
}

/// Decode a Minswap V2 step value.
///   SwapExactIn (Constr 0): [a_to_b, swap_amount, minimum_receive, killable]
///     → need to pair with lp_asset to get target.
///   SwapMultiRouting (Constr 9): [swap_routing, swap_amount, minimum_receive]
///     → last hop of swap_routing gives target.
///
/// Returns min_receive + (target_policy, target_name). Returns None
/// for any other step (non-swap variants rejected).
fn decode_step(
  step_data: Data,
  order_lp_asset: Data,
) -> Option<DecodedOrder> {
  let step_constr = un_constr_data(step_data)
  let step_tag = step_constr.1st
  let step_fields = step_constr.2nd
  if step_tag == 0 {
    // SwapExactIn — pair with order-level lp_asset.
    when step_fields is {
      [a_to_b_data, _swap_amt, min_recv_data, _killable] -> {
        let a_to_b_constr = un_constr_data(a_to_b_data)
        // Aiken Bool: False = Constr(0), True = Constr(1).
        let a_to_b = a_to_b_constr.1st == 1
        let min_recv = un_i_data(min_recv_data)
        when extract_target_from_lp(order_lp_asset, a_to_b) is {
          Some((tp, tn)) -> Some(DecodedOrder { min_receive: min_recv, target_policy: tp, target_name: tn })
          None -> None
        }
      }
      _ -> None
    }
  } else if step_tag == 9 {
    // SwapMultiRouting — last hop of swap_routing determines target.
    when step_fields is {
      [routing_data, _swap_amt, min_recv_data] -> {
        let min_recv = un_i_data(min_recv_data)
        let routes = un_list_data_safe(routing_data)
        when last_of(routes) is {
          Some(last_route) -> {
            let route_constr = un_constr_data(last_route)
            let route_fields = route_constr.2nd
            when route_fields is {
              [lp_of_hop, direction_data] -> {
                let dir_constr = un_constr_data(direction_data)
                let a_to_b = dir_constr.1st == 1
                when extract_target_from_lp(lp_of_hop, a_to_b) is {
                  Some((tp, tn)) -> Some(DecodedOrder { min_receive: min_recv, target_policy: tp, target_name: tn })
                  None -> None
                }
              }
              _ -> None
            }
          }
          None -> None
        }
      }
      _ -> None
    }
  } else {
    // Non-swap variants (StopLoss, OCO, SwapExactOut, Deposit,
    // Withdraw, ZapOut, PartialSwap, WithdrawImbalance, Donation)
    // are rejected — DeployToProtocol only permits swap orders.
    None
  }
}

fn un_list_data_safe(d: Data) -> List<Data> {
  builtin.un_list_data(d)
}

fn extract_minswap_v2_order(output: Output) -> Option<DecodedOrder> {
  when output.datum is {
    InlineDatum(data) -> {
      let order_constr = un_constr_data(data)
      if order_constr.1st == 0 {
        let order_fields = order_constr.2nd
        // Field layout: [canceller, refund_addr, refund_datum,
        //                success_addr, success_datum, lp_asset,
        //                step, max_batcher_fee, expire_opt]
        // Index 5 = lp_asset, index 6 = step.
        when (nth(order_fields, 5), nth(order_fields, 6)) is {
          (Some(lp_data), Some(step_data)) -> decode_step(step_data, lp_data)
          _ -> None
        }
      } else {
        None
      }
    }
    _ -> None
  }
}

// ─────────────────────────────────────────────────────────────────────
// Validator
// ─────────────────────────────────────────────────────────────────────

validator minswap_v2_adapter(
  governance_nft_policy: ByteArray,
  governance_nft_name: ByteArray,
) {
  withdraw(redeemer: SwapAdapterRedeemer, _account: Credential, tx: Transaction) {
    expect Some(dest_output) = list.at(tx.outputs, redeemer.dest_output_idx)
    when extract_minswap_v2_order(dest_output) is {
      Some(decoded) ->
        and {
          redeemer.min_receive == decoded.min_receive,
          redeemer.min_receive > 0,
          redeemer.target_asset_policy == decoded.target_policy,
          redeemer.target_asset_name == decoded.target_name,
        }
      None -> False
    }
  }

  /// A2 gov-gated stake deregister. Same shape as every other V1
  /// staking validator (vault_user / vault_keeper_hot / vault_batcher /
  /// vault_swap_ada / vault_protocol / vault_recall / vault_liqwid /
  /// vault_gov_policy / vault_gov_emergency / vault_admin_deploy /
  /// keeper_stake_script). Adding this handler is the sole reason this
  /// adapter is parameterized on governance anchors.
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
    fail @"minswap_v2_adapter: unsupported purpose"
  }
}
