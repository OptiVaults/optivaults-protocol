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
///   3. Each on-chain routing hop's LP asset name rehashes (via
///      Minswap's canonical `sha3_256(sha3_256(policy_a||name_a) ||
///      sha3_256(policy_b||name_b))` formula, with sorted inputs)
///      to match the corresponding adjacent pair in
///      `redeemer.hop_chain` (R74 F-1 Option C). Target asset is
///      `hop_chain[last]`.
///
/// Routing topology (hop_chain shape):
///   - SwapExactIn: `hop_chain` has exactly 2 entries `[asset_in,
///     target_out]`. The order's `lp_asset` must re-hash to
///     `compute_lp_asset_name(hop_chain[0], hop_chain[1])`.
///   - SwapMultiRouting: `hop_chain` has N+1 entries
///     `[asset_in, mid_1, ..., mid_{N-1}, target_out]` for an N-hop
///     route. Each `swap_routing[i].lp_asset` must re-hash to
///     `compute_lp_asset_name(hop_chain[i], hop_chain[i+1])`.
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

use aiken/builtin.{un_b_data, un_constr_data, un_i_data}
use aiken/collection/list
use aiken/crypto.{sha3_256}
use aiken/primitive/bytearray
use cardano/address.{Credential, Script}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{InlineDatum, Output, Transaction}
use vault/helpers.{is_gov_authorized, payload_hash_deregister_stake}
use vault/swap_adapter.{SwapAdapterRedeemer, last_hop_target}
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
// Minswap V2 datum extraction (R74 F-1 — hop_chain LP-name re-hash)
//
// OrderDatum = Constr(0, [canceller, refund_addr, refund_datum,
//                         success_addr, success_datum, lp_asset,
//                         step, max_batcher_fee, expire_opt])
//
// lp_asset format (verified against Minswap V2 source + mainnet TX
// b330b73706079b1b…):
//   Constr(0, [LP_policy: ByteArray, LP_name: ByteArray])
// — a SINGLE LP token identifier, NOT a 2-asset pair. The target asset
// cannot be derived from the order datum alone; it must be committed
// in the adapter redeemer and verified by re-computing the Minswap V2
// LP asset-name formula and matching against each routing hop.
//
// step variants we decode:
//   Constr(0, [a_to_b, swap_amount, minimum_receive, killable])  — SwapExactIn
//   Constr(9, [swap_routing, swap_amount, minimum_receive])      — SwapMultiRouting
//
// SwapRoute (inside swap_routing list):
//   Constr(0, [lp_asset: Constr(0, [LP_policy, LP_name]),
//              a_to_b_direction: Constr(0|1, [])])
// ─────────────────────────────────────────────────────────────────────

/// Minswap V2 `compute_lp_asset_name` (from minswap-dex-v2
/// lib/amm_dex_v2/utils.ak). The LP asset name is the sha3_256 hash of
/// two sha3_256-hashed asset identifiers, sorted canonically first:
///
///   asset_a_ident = sha3_256(policy_a || name_a)
///   asset_b_ident = sha3_256(policy_b || name_b)
///   LP_name       = sha3_256(asset_a_ident || asset_b_ident)
///
/// where (asset_a, asset_b) is Minswap-sorted: policy_id bytewise first,
/// then name bytewise on ties.
///
/// Validated against 4 real data points:
///   - Minswap's own test vector (ADA/MIN) = `82e2b1fd…`
///   - Mainnet hop0 USDCx/NIGHT = `70cabd53…`
///   - Mainnet hop1 NIGHT/ADA   = `e74c5297…`
///   - Mainnet hop2 ADA/DJED    = `a939812d…`
pub fn compute_lp_asset_name(
  policy_a: ByteArray,
  name_a: ByteArray,
  policy_b: ByteArray,
  name_b: ByteArray,
) -> ByteArray {
  // Canonically sort pair before hashing (Minswap's `sorted_asset`):
  // compare policy_id first, then fall through to asset_name on ties.
  let policy_cmp = bytearray.compare(policy_a, policy_b)
  let swap =
    when policy_cmp is {
      Greater -> True
      Less -> False
      Equal -> bytearray.compare(name_a, name_b) == Greater
    }
  let (pa, na, pb, nb) =
    if swap {
      (policy_b, name_b, policy_a, name_a)
    } else {
      (policy_a, name_a, policy_b, name_b)
    }
  let a_ident = sha3_256(bytearray.concat(pa, na))
  let b_ident = sha3_256(bytearray.concat(pb, nb))
  sha3_256(bytearray.concat(a_ident, b_ident))
}

/// Decode a Minswap V2 step value and verify each routing hop's
/// on-chain LP name matches the LP name re-computed from the
/// corresponding `hop_chain` pair. This binds the routing topology
/// to the adapter-committed asset sequence — a compromised keeper
/// cannot smuggle in a different pool.
///
///   SwapExactIn (Constr 0): [a_to_b, swap_amount, minimum_receive, killable]
///     → single-hop; verify order.lp_asset.name == compute_lp_asset_name
///       of hop_chain[0] + hop_chain[1]. Must have len(hop_chain) == 2.
///   SwapMultiRouting (Constr 9): [swap_routing, swap_amount, minimum_receive]
///     → N hops; verify each route[i].lp_asset.name == compute_lp_asset_name
///       of (hop_chain[i], hop_chain[i+1]). Must have len(hop_chain) == N+1.
///
/// Returns `Some(min_receive)` on success. Rejects:
///   - Non-swap step variants
///   - hop_chain length mismatch
///   - Any hop LP-name mismatch
fn decode_step(
  step_data: Data,
  order_lp_asset: Data,
  hop_chain: List<(ByteArray, ByteArray)>,
) -> Option<Int> {
  let step_constr = un_constr_data(step_data)
  let step_tag = step_constr.1st
  let step_fields = step_constr.2nd
  if step_tag == 0 {
    // SwapExactIn — single hop using the order-level lp_asset.
    when step_fields is {
      [_a_to_b_data, _swap_amt, min_recv_data, _killable] -> {
        let min_recv = un_i_data(min_recv_data)
        // hop_chain must have exactly 2 entries for single-hop.
        when hop_chain is {
          [(pol_in, name_in), (pol_out, name_out)] -> {
            let expected_lp_name =
              compute_lp_asset_name(pol_in, name_in, pol_out, name_out)
            when lp_asset_matches(order_lp_asset, expected_lp_name) is {
              True -> Some(min_recv)
              False -> None
            }
          }
          _ -> None
        }
      }
      _ -> None
    }
  } else if step_tag == 9 {
    // SwapMultiRouting — verify hop_chain.length == routing.length + 1
    // and each route[i].lp_name == compute_lp_asset_name(chain[i], chain[i+1]).
    when step_fields is {
      [routing_data, _swap_amt, min_recv_data] -> {
        let min_recv = un_i_data(min_recv_data)
        let routes = un_list_data_safe(routing_data)
        when verify_routing_chain(routes, hop_chain) is {
          True -> Some(min_recv)
          False -> None
        }
      }
      _ -> None
    }
  } else {
    // Non-swap variants rejected (StopLoss / OCO / SwapExactOut / Deposit /
    // Withdraw / ZapOut / PartialSwap / WithdrawImbalance / Donation).
    None
  }
}

/// Pair up `routes` with consecutive `hop_chain` pairs and verify each
/// route's on-chain LP name matches the formula-computed expected LP
/// name. Both lists must have compatible lengths:
/// `len(routes) == len(hop_chain) - 1`.
fn verify_routing_chain(
  routes: List<Data>,
  hop_chain: List<(ByteArray, ByteArray)>,
) -> Bool {
  when (routes, hop_chain) is {
    // Empty routing is invalid (need at least 1 hop + 2 chain entries).
    ([], _) -> False
    (_, []) -> False
    (_, [_]) -> False
    ([route], [(pol_a, name_a), (pol_b, name_b)]) -> {
      // Last hop — chain must end here.
      let expected =
        compute_lp_asset_name(pol_a, name_a, pol_b, name_b)
      lp_asset_matches_from_route(route, expected)
    }
    ([route, ..rest_routes], [(pol_a, name_a), (pol_b, name_b), ..rest_chain]) -> {
      let expected =
        compute_lp_asset_name(pol_a, name_a, pol_b, name_b)
      if lp_asset_matches_from_route(route, expected) {
        verify_routing_chain(rest_routes, [(pol_b, name_b), ..rest_chain])
      } else {
        False
      }
    }
  }
}

/// Pull the LP name (lp_asset.fields[1]) out of a SwapRoute Constr and
/// compare with the expected LP name.
fn lp_asset_matches_from_route(route: Data, expected_lp_name: ByteArray) -> Bool {
  let route_constr = un_constr_data(route)
  let route_fields = route_constr.2nd
  when route_fields is {
    [lp_of_hop, _direction_data] -> lp_asset_matches(lp_of_hop, expected_lp_name)
    _ -> False
  }
}

/// Verify `lp_asset` is `Constr(0, [LP_policy, expected_lp_name])`.
/// Ignores the LP_policy byte value (Minswap V2 uses a single universal
/// LP mint policy, but the formula's strength is the LP_name hash alone).
fn lp_asset_matches(lp: Data, expected_lp_name: ByteArray) -> Bool {
  let lp_constr = un_constr_data(lp)
  let fields = lp_constr.2nd
  when fields is {
    [_lp_policy, lp_name_data] -> un_b_data(lp_name_data) == expected_lp_name
    _ -> False
  }
}

fn un_list_data_safe(d: Data) -> List<Data> {
  builtin.un_list_data(d)
}

fn extract_minswap_v2_order_min_receive(
  output: Output,
  hop_chain: List<(ByteArray, ByteArray)>,
) -> Option<Int> {
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
          (Some(lp_data), Some(step_data)) ->
            decode_step(step_data, lp_data, hop_chain)
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
    when last_hop_target(redeemer.hop_chain) is {
      // hop_chain must be well-formed (≥ 2 entries) and have a last
      // entry we can expose as the target asset.
      Some(_target) ->
        when extract_minswap_v2_order_min_receive(dest_output, redeemer.hop_chain) is {
          Some(decoded_min_receive) ->
            and {
              redeemer.min_receive == decoded_min_receive,
              redeemer.min_receive > 0,
            }
          None -> False
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

// ─────────────────────────────────────────────────────────────────────
// R74 F-1 tests — Minswap V2 LP asset-name formula
// ─────────────────────────────────────────────────────────────────────

/// Validated against Minswap V2's own self-test: `compute_lp_asset_name`
/// for (ADA, MIN) must equal the specific constant in their repo.
/// Source: minswap/minswap-dex-v2 lib/amm_dex_v2/utils.ak
test r74_lp_name_minswap_docs_vector() {
  compute_lp_asset_name(
    #"",
    #"",
    #"29d222ce763455e3d7a09a665ce554f00ac89d2e99a1a83d267170c6",
    #"4d494e",
  ) == #"82e2b1fd27a7712a1a9cf750dfbea1a5778611b20e06dd6a611df7a643f8cb75"
}

/// Real mainnet data: USDCx/NIGHT pool LP name from mainnet TX
/// `b330b737…` hop[0].lp_asset.name.
test r74_lp_name_usdcx_night_mainnet() {
  compute_lp_asset_name(
    // USDCx
    #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34",
    #"5553444378",
    // NIGHT
    #"0691b2fecca1ac4f53cb6dfb00b7013e561d1f34403b957cbb5af1fa",
    #"4e49474854",
  ) == #"70cabd53edd98d4ffc20d46d9f246ed14b61b3fa7c681c268e86c2a196b0947d"
}

/// Real mainnet data: NIGHT/ADA pool LP name from mainnet TX
/// `b330b737…` hop[1].lp_asset.name.
test r74_lp_name_night_ada_mainnet() {
  compute_lp_asset_name(
    // NIGHT
    #"0691b2fecca1ac4f53cb6dfb00b7013e561d1f34403b957cbb5af1fa",
    #"4e49474854",
    // ADA
    #"",
    #"",
  ) == #"e74c52975908a612d5ce68327040d449aae99f8b463bb6de046a1b23c5713169"
}

/// Real mainnet data: ADA/DJED pool LP name from mainnet TX
/// `b330b737…` hop[2].lp_asset.name.
test r74_lp_name_ada_djed_mainnet() {
  compute_lp_asset_name(
    // ADA
    #"",
    #"",
    // DJED
    #"8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd61",
    #"446a65644d6963726f555344",
  ) == #"a939812d08cfb6066e17d2914a7272c6b8c0197acdf68157d02c73649cc3efc0"
}

/// Sort-order invariant: swapping arg positions yields the same LP name
/// because the function sorts canonically before hashing.
test r74_lp_name_sort_invariant() {
  let forward =
    compute_lp_asset_name(
      #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34",
      #"5553444378",
      #"0691b2fecca1ac4f53cb6dfb00b7013e561d1f34403b957cbb5af1fa",
      #"4e49474854",
    )
  let reverse =
    compute_lp_asset_name(
      #"0691b2fecca1ac4f53cb6dfb00b7013e561d1f34403b957cbb5af1fa",
      #"4e49474854",
      #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34",
      #"5553444378",
    )
  forward == reverse
}

/// Different asset pairs MUST produce different LP names (collision
/// resistance of sha3_256 + pair discrimination).
test r74_lp_name_different_pairs_different_names() {
  let usdcx_night =
    compute_lp_asset_name(
      #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34",
      #"5553444378",
      #"0691b2fecca1ac4f53cb6dfb00b7013e561d1f34403b957cbb5af1fa",
      #"4e49474854",
    )
  let usdcx_djed =
    compute_lp_asset_name(
      #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34",
      #"5553444378",
      #"8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd61",
      #"446a65644d6963726f555344",
    )
  usdcx_night != usdcx_djed
}

/// ByteArray sort must be bytewise, not numeric. Edge case: policy
/// bytes differ but first-byte tie → name bytes break the tie.
test r74_lp_name_same_policy_different_name_sorts_by_name() {
  // Synthetic fixture — not real on-chain data — testing the sort edge.
  let ab =
    compute_lp_asset_name(#"aa", #"01", #"aa", #"02")
  let ba =
    compute_lp_asset_name(#"aa", #"02", #"aa", #"01")
  ab == ba
}

// ─────────────────────────────────────────────────────────────────────
// R74 negative-path tests — `verify_routing_chain` + `decode_step`
//
// Fixture builders use `cbor.diagnostic` + manual Constr construction.
// Since Aiken tests run the real `decode_step`, these prove the fix
// actually catches bad inputs.
// ─────────────────────────────────────────────────────────────────────

// Helper: fabricate a SwapRoute Constr (Minswap V2 routing hop).
//   Constr(0, [Constr(0, [LP_policy, LP_name]), Constr(dir, [])])
//
// direction: 0 = False (!a_to_b), 1 = True (a_to_b).
fn mk_route(lp_policy: ByteArray, lp_name: ByteArray, direction: Int) -> Data {
  let lp_asset: Data =
    builtin.constr_data(
      0,
      [builtin.b_data(lp_policy), builtin.b_data(lp_name)],
    )
  let dir: Data = builtin.constr_data(direction, [])
  builtin.constr_data(0, [lp_asset, dir])
}

// Helper: Minswap V2 universal LP policy (real mainnet).
const minswap_v2_lp_policy: ByteArray =
  #"f5808c2c990d86da54bfc97d89cee6efa20cd8461616359478d96b4c"

// Fixture helpers for well-known USDCx/NIGHT/ADA/DJED assets.
const usdcx_policy: ByteArray =
  #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34"
const usdcx_name: ByteArray = #"5553444378"
const night_policy: ByteArray =
  #"0691b2fecca1ac4f53cb6dfb00b7013e561d1f34403b957cbb5af1fa"
const night_name: ByteArray = #"4e49474854"
const djed_policy: ByteArray =
  #"8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd61"
const djed_name: ByteArray = #"446a65644d6963726f555344"

// ─── verify_routing_chain success paths ─────────────────────────────

test r74_verify_routing_chain_single_hop_pass() {
  // One route, two-entry hop_chain: USDCx → DJED via USDCx/DJED pool.
  let lp_name =
    compute_lp_asset_name(usdcx_policy, usdcx_name, djed_policy, djed_name)
  let routes = [mk_route(minswap_v2_lp_policy, lp_name, 0)]
  let chain =
    [(usdcx_policy, usdcx_name), (djed_policy, djed_name)]
  verify_routing_chain(routes, chain)
}

test r74_verify_routing_chain_three_hop_pass() {
  // Real mainnet 3-hop: USDCx → NIGHT → ADA → DJED.
  let route0 =
    mk_route(
      minswap_v2_lp_policy,
      compute_lp_asset_name(usdcx_policy, usdcx_name, night_policy, night_name),
      0,
    )
  let route1 =
    mk_route(
      minswap_v2_lp_policy,
      compute_lp_asset_name(night_policy, night_name, #"", #""),
      0,
    )
  let route2 =
    mk_route(
      minswap_v2_lp_policy,
      compute_lp_asset_name(#"", #"", djed_policy, djed_name),
      1,
    )
  let routes = [route0, route1, route2]
  let chain =
    [
      (usdcx_policy, usdcx_name),
      (night_policy, night_name),
      (#"", #""),
      (djed_policy, djed_name),
    ]
  verify_routing_chain(routes, chain)
}

// ─── verify_routing_chain negative paths ────────────────────────────

test r74_verify_routing_chain_rejects_empty_routes() {
  let chain = [(usdcx_policy, usdcx_name), (djed_policy, djed_name)]
  !verify_routing_chain([], chain)
}

test r74_verify_routing_chain_rejects_empty_chain() {
  let lp_name =
    compute_lp_asset_name(usdcx_policy, usdcx_name, djed_policy, djed_name)
  let routes = [mk_route(minswap_v2_lp_policy, lp_name, 0)]
  !verify_routing_chain(routes, [])
}

test r74_verify_routing_chain_rejects_singleton_chain() {
  let lp_name =
    compute_lp_asset_name(usdcx_policy, usdcx_name, djed_policy, djed_name)
  let routes = [mk_route(minswap_v2_lp_policy, lp_name, 0)]
  !verify_routing_chain(routes, [(usdcx_policy, usdcx_name)])
}

test r74_verify_routing_chain_rejects_wrong_lp_name() {
  // Keeper claims chain USDCx→DJED but submits a pool with wrong LP name.
  let bad_lp_name: ByteArray =
    #"deadbeef00000000000000000000000000000000000000000000000000000000"
  let routes = [mk_route(minswap_v2_lp_policy, bad_lp_name, 0)]
  let chain = [(usdcx_policy, usdcx_name), (djed_policy, djed_name)]
  !verify_routing_chain(routes, chain)
}

test r74_verify_routing_chain_rejects_middle_hop_mismatch() {
  // 3-hop chain where HOP 1's LP name is garbage. Should reject even
  // though hop 0 and hop 2 LP names are correct.
  let route0 =
    mk_route(
      minswap_v2_lp_policy,
      compute_lp_asset_name(usdcx_policy, usdcx_name, night_policy, night_name),
      0,
    )
  let bad_mid_lp: ByteArray =
    #"baaaadbaaaadbaaaadbaaaadbaaaadbaaaadbaaaadbaaaadbaaaadbaaaad0000"
  let route1 = mk_route(minswap_v2_lp_policy, bad_mid_lp, 0)
  let route2 =
    mk_route(
      minswap_v2_lp_policy,
      compute_lp_asset_name(#"", #"", djed_policy, djed_name),
      1,
    )
  let routes = [route0, route1, route2]
  let chain =
    [
      (usdcx_policy, usdcx_name),
      (night_policy, night_name),
      (#"", #""),
      (djed_policy, djed_name),
    ]
  !verify_routing_chain(routes, chain)
}

test r74_verify_routing_chain_rejects_chain_longer_than_routes() {
  // Keeper claims 3-hop chain but submits only 2 routes — reject.
  let route0 =
    mk_route(
      minswap_v2_lp_policy,
      compute_lp_asset_name(usdcx_policy, usdcx_name, night_policy, night_name),
      0,
    )
  let route1 =
    mk_route(
      minswap_v2_lp_policy,
      compute_lp_asset_name(night_policy, night_name, djed_policy, djed_name),
      0,
    )
  let routes = [route0, route1]
  let chain =
    [
      (usdcx_policy, usdcx_name),
      (night_policy, night_name),
      (#"", #""),
      (djed_policy, djed_name),
    ]
  // 2 routes but 3 expected hops (chain len 4 → 3 consecutive pairs).
  !verify_routing_chain(routes, chain)
}

test r74_verify_routing_chain_rejects_routes_longer_than_chain() {
  // Routes submitted exceed the committed chain length — reject.
  let route0 =
    mk_route(
      minswap_v2_lp_policy,
      compute_lp_asset_name(usdcx_policy, usdcx_name, djed_policy, djed_name),
      0,
    )
  let route1 =
    mk_route(
      minswap_v2_lp_policy,
      compute_lp_asset_name(djed_policy, djed_name, night_policy, night_name),
      0,
    )
  let routes = [route0, route1]
  // 2 routes but only 1 expected hop (chain len 2).
  let chain =
    [(usdcx_policy, usdcx_name), (djed_policy, djed_name)]
  !verify_routing_chain(routes, chain)
}

test r74_verify_routing_chain_rejects_chain_asset_swap() {
  // Keeper claims USDCx → DJED but commits USDCx → NIGHT chain.
  // The LP name the keeper submits must match its committed chain,
  // NOT a different chain end.
  let lp_name_usdcx_djed =
    compute_lp_asset_name(usdcx_policy, usdcx_name, djed_policy, djed_name)
  let routes = [mk_route(minswap_v2_lp_policy, lp_name_usdcx_djed, 0)]
  // Claimed chain: USDCx → NIGHT. But LP is USDCx→DJED pool.
  let chain = [(usdcx_policy, usdcx_name), (night_policy, night_name)]
  !verify_routing_chain(routes, chain)
}

// ─── decode_step negative: step_tag variants beyond 0 and 9 ─────────

test r74_decode_step_rejects_step_tag_1() {
  // StopLoss / alternative swap variants beyond SwapExactIn/SwapMultiRouting.
  let step_data: Data = builtin.constr_data(1, [builtin.i_data(1)])
  let lp_data: Data =
    builtin.constr_data(
      0,
      [builtin.b_data(minswap_v2_lp_policy), builtin.b_data(#"deadbeef")],
    )
  let chain = [(usdcx_policy, usdcx_name), (djed_policy, djed_name)]
  decode_step(step_data, lp_data, chain) == None
}

test r74_decode_step_rejects_step_tag_3_oco() {
  // OCO / other non-swap variants — rejected by `else` branch.
  let step_data: Data = builtin.constr_data(3, [])
  let lp_data: Data =
    builtin.constr_data(
      0,
      [builtin.b_data(minswap_v2_lp_policy), builtin.b_data(#"00")],
    )
  let chain = [(usdcx_policy, usdcx_name), (djed_policy, djed_name)]
  decode_step(step_data, lp_data, chain) == None
}

test r74_decode_step_swap_exact_in_rejects_3_hop_chain() {
  // SwapExactIn can only have 2-entry hop_chain (single hop). A 3-entry
  // chain implies routing via an intermediate — but SwapExactIn doesn't
  // support routing. Reject.
  let ab_to_b_true: Data = builtin.constr_data(1, [])
  let swap_amt: Data = builtin.i_data(100_000_000)
  let min_recv: Data = builtin.i_data(95_000_000)
  let killable: Data = builtin.constr_data(0, [])
  let step_data: Data =
    builtin.constr_data(0, [ab_to_b_true, swap_amt, min_recv, killable])
  let lp_name =
    compute_lp_asset_name(usdcx_policy, usdcx_name, djed_policy, djed_name)
  let lp_data: Data =
    builtin.constr_data(
      0,
      [builtin.b_data(minswap_v2_lp_policy), builtin.b_data(lp_name)],
    )
  // 3-entry chain → decode_step's SwapExactIn branch pattern-matches
  // `[(pol_in, name_in), (pol_out, name_out)]` only; with 3 entries
  // returns None.
  let chain =
    [
      (usdcx_policy, usdcx_name),
      (night_policy, night_name),
      (djed_policy, djed_name),
    ]
  decode_step(step_data, lp_data, chain) == None
}

test r74_decode_step_swap_exact_in_pass_with_correct_chain() {
  // SwapExactIn happy path: 2-entry chain matching the order's lp_asset.
  let a_to_b_false: Data = builtin.constr_data(0, [])
  let swap_amt: Data = builtin.i_data(100_000_000)
  let min_recv: Data = builtin.i_data(95_000_000)
  let killable: Data = builtin.constr_data(0, [])
  let step_data: Data =
    builtin.constr_data(0, [a_to_b_false, swap_amt, min_recv, killable])
  let lp_name =
    compute_lp_asset_name(usdcx_policy, usdcx_name, djed_policy, djed_name)
  let lp_data: Data =
    builtin.constr_data(
      0,
      [builtin.b_data(minswap_v2_lp_policy), builtin.b_data(lp_name)],
    )
  let chain = [(usdcx_policy, usdcx_name), (djed_policy, djed_name)]
  decode_step(step_data, lp_data, chain) == Some(95_000_000)
}

test r74_decode_step_swap_exact_in_rejects_wrong_chain_asset() {
  // Keeper claims chain USDCx→NIGHT but submits USDCx/DJED LP pool.
  // The LP name does NOT match hash(USDCx, NIGHT) so reject.
  let a_to_b: Data = builtin.constr_data(0, [])
  let swap_amt: Data = builtin.i_data(100_000_000)
  let min_recv: Data = builtin.i_data(95_000_000)
  let killable: Data = builtin.constr_data(0, [])
  let step_data: Data =
    builtin.constr_data(0, [a_to_b, swap_amt, min_recv, killable])
  let lp_name_djed =
    compute_lp_asset_name(usdcx_policy, usdcx_name, djed_policy, djed_name)
  let lp_data: Data =
    builtin.constr_data(
      0,
      [builtin.b_data(minswap_v2_lp_policy), builtin.b_data(lp_name_djed)],
    )
  let chain = [(usdcx_policy, usdcx_name), (night_policy, night_name)]
  decode_step(step_data, lp_data, chain) == None
}

test r74_decode_step_swap_multi_routing_pass_with_mainnet_data() {
  // Full integration: mainnet 3-hop data, correct chain, formula
  // re-hash matches on-chain LP names.
  let routing_data: Data =
    builtin.list_data(
      [
        mk_route(
          minswap_v2_lp_policy,
          #"70cabd53edd98d4ffc20d46d9f246ed14b61b3fa7c681c268e86c2a196b0947d",
          0,
        ),
        mk_route(
          minswap_v2_lp_policy,
          #"e74c52975908a612d5ce68327040d449aae99f8b463bb6de046a1b23c5713169",
          0,
        ),
        mk_route(
          minswap_v2_lp_policy,
          #"a939812d08cfb6066e17d2914a7272c6b8c0197acdf68157d02c73649cc3efc0",
          1,
        ),
      ],
    )
  let swap_amt_wrapped: Data =
    builtin.constr_data(0, [builtin.i_data(205_966_744)])
  let min_recv: Data = builtin.i_data(201_331_843)
  let step_data: Data =
    builtin.constr_data(9, [routing_data, swap_amt_wrapped, min_recv])
  let dummy_lp_data: Data =
    builtin.constr_data(
      0,
      [builtin.b_data(minswap_v2_lp_policy), builtin.b_data(#"")],
    )
  let chain =
    [
      (usdcx_policy, usdcx_name),
      (night_policy, night_name),
      (#"", #""),
      (djed_policy, djed_name),
    ]
  decode_step(step_data, dummy_lp_data, chain) == Some(201_331_843)
}

test r74_decode_step_swap_multi_routing_rejects_len_mismatch() {
  // Keeper claims 3-hop chain but submits only 2 routes. decode_step
  // via verify_routing_chain should return None.
  let routing_data: Data =
    builtin.list_data(
      [
        mk_route(
          minswap_v2_lp_policy,
          compute_lp_asset_name(usdcx_policy, usdcx_name, night_policy, night_name),
          0,
        ),
        mk_route(
          minswap_v2_lp_policy,
          compute_lp_asset_name(night_policy, night_name, djed_policy, djed_name),
          0,
        ),
      ],
    )
  let swap_amt: Data =
    builtin.constr_data(0, [builtin.i_data(100_000_000)])
  let min_recv: Data = builtin.i_data(95_000_000)
  let step_data: Data =
    builtin.constr_data(9, [routing_data, swap_amt, min_recv])
  let dummy_lp_data: Data =
    builtin.constr_data(
      0,
      [builtin.b_data(minswap_v2_lp_policy), builtin.b_data(#"")],
    )
  // 2 routes but 4-entry chain (3 expected hops).
  let chain =
    [
      (usdcx_policy, usdcx_name),
      (night_policy, night_name),
      (#"", #""),
      (djed_policy, djed_name),
    ]
  decode_step(step_data, dummy_lp_data, chain) == None
}

