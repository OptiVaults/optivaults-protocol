//// SundaeSwap V3 / Stableswaps order datum decoding for the V1
//// SwapAdapter.
////
//// Both SundaeSwap "V3" (constant-product) and "Stableswaps" pool
//// versions share an identical swap `OrderDatum`. Verified 2026-05-15
//// against the on-chain Aiken source `sundae-contracts/lib/types/
//// order.ak` and the SundaeSwap SDK contract blueprints
//// (`Contract.v3.ts` / `Contract.Stableswaps.ts`).
////
//// OrderDatum (Constr 0, 6 fields):
////   0 pool_ident       Option<Ident>     (ignored — value is bound by
////                                         min_received + peg-floor)
////   1 owner            MultisigScript
////   2 max_protocol_fee Int               (ignored)
////   3 destination      Destination
////   4 details          Order
////   5 extension        Data              (ignored)
////
//// MultisigScript variant ctor indices: Signature 0, AllOf 1, AnyOf 2,
//// AtLeast 3, Before 4, After 5, Script 6.
////
//// Destination: `Fixed { address, datum }` = Constr 0; `Self` = Constr 1.
////
//// Order::Swap = Constr 1 `[offer: SingletonValue, min_received:
//// SingletonValue]`. Swap is Constr 1 in BOTH the V3 and Stableswaps
//// order unions — the only divergence between them is that Stableswaps
//// has no `Donation` variant, which shifts `Record` but never `Swap`.
////
//// SingletonValue = (PolicyId, AssetName, Int) — an Aiken 3-tuple,
//// Plutus-encoded as a List of three elements.
////
//// PRE-MAINNET VERIFICATION: like `minswap_v2_adapter`, this decoding
//// must be confirmed against a real on-chain SundaeSwap swap-order
//// UTxO (Preprod has a live `USDCx/USDR` Stableswap pool) before the
//// adapter is whitelisted on mainnet via governance UpdateRegistry.

use aiken/builtin.{un_b_data, un_constr_data, un_i_data, un_list_data}
use aiken/collection/list
use cardano/address.{Address, Script}
use cardano/assets.{Value, flatten, merge, quantity_of, zero}
use cardano/transaction.{InlineDatum, Input, Output}

/// A "value" known to hold exactly one token: (policy, name, amount).
pub type SingletonValue =
  (ByteArray, ByteArray, Int)

/// The decoded subset of a SundaeSwap swap `OrderDatum` that V1 needs.
pub type SundaeSwapOrder {
  /// Asset offered into the swap (policy, name, amount).
  offer: SingletonValue,
  /// Minimum the swap must return (policy, name, amount).
  min_received: SingletonValue,
  /// Address the swap output is paid to, from `Destination::Fixed`.
  /// `Destination::Self` is rejected by the decoder — V1 always pins an
  /// explicit vault address.
  destination_addr: Address,
  /// `Some(script_hash)` when `owner` is the `MultisigScript::Script`
  /// variant; `None` for every other owner variant.
  owner_script_hash: Option<ByteArray>,
}

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

/// `Some(script_hash)` if `owner` is `MultisigScript::Script` (ctor 6);
/// `None` for Signature / AllOf / AnyOf / AtLeast / Before / After.
fn owner_script(owner_data: Data) -> Option<ByteArray> {
  let c = un_constr_data(owner_data)
  if c.1st == 6 {
    when c.2nd is {
      [hash_data] -> Some(un_b_data(hash_data))
      _ -> None
    }
  } else {
    None
  }
}

/// Extract the destination address. `Destination::Fixed` (ctor 0) ->
/// `Some(address)`; `Destination::Self` (ctor 1) or anything else ->
/// `None`.
fn destination_address(dest_data: Data) -> Option<Address> {
  let c = un_constr_data(dest_data)
  if c.1st == 0 {
    when c.2nd is {
      [addr_data, _datum_data] ->
        if addr_data is a: Address {
          Some(a)
        } else {
          None
        }
      _ -> None
    }
  } else {
    None
  }
}

/// Decode a SingletonValue (Aiken 3-tuple, Plutus List of 3).
fn decode_singleton(d: Data) -> Option<SingletonValue> {
  when un_list_data(d) is {
    [p, n, q] -> Some((un_b_data(p), un_b_data(n), un_i_data(q)))
    _ -> None
  }
}

/// Decode `Order::Swap` (ctor 1) -> `Some((offer, min_received))`.
/// Every non-Swap order variant -> `None`.
fn swap_details(details_data: Data) -> Option<(SingletonValue, SingletonValue)> {
  let c = un_constr_data(details_data)
  if c.1st == 1 {
    when c.2nd is {
      [offer_data, min_recv_data] ->
        when (decode_singleton(offer_data), decode_singleton(min_recv_data)) is {
          (Some(offer), Some(min_received)) -> Some((offer, min_received))
          _ -> None
        }
      _ -> None
    }
  } else {
    None
  }
}

/// Decode a SundaeSwap swap `OrderDatum` from raw datum `Data`.
/// `None` if the datum is not a Constr-0 6-field OrderDatum or `details`
/// is not a `Swap`.
pub fn decode_order_datum(data: Data) -> Option<SundaeSwapOrder> {
  let c = un_constr_data(data)
  if c.1st == 0 {
    let fields = c.2nd
    when (nth(fields, 1), nth(fields, 3), nth(fields, 4)) is {
      (Some(owner_data), Some(dest_data), Some(details_data)) ->
        when (destination_address(dest_data), swap_details(details_data)) is {
          (Some(addr), Some((offer, min_received))) ->
            Some(
              SundaeSwapOrder {
                offer,
                min_received,
                destination_addr: addr,
                owner_script_hash: owner_script(owner_data),
              },
            )
          _ -> None
        }
      _ -> None
    }
  } else {
    None
  }
}

/// Decode a SundaeSwap swap order from an output's inline datum.
/// `None` if the output carries no inline datum or the datum does not
/// decode (see `decode_order_datum`).
pub fn decode_order(output: Output) -> Option<SundaeSwapOrder> {
  when output.datum is {
    InlineDatum(data) -> decode_order_datum(data)
    _ -> None
  }
}

/// Verify a decoded SundaeSwap order satisfies the V1 SwapAdapter
/// invariants for a single-hop swap:
///   - destination pinned to the vault (SwapAdapter recipient-address binding — swap output cannot be
///     redirected to an attacker);
///   - owner pinned to the cancel-guard script (B2 — SundaeSwap's
///     `Cancel` imposes no output constraint, so the owner is the sole
///     gate on the un-filled-order drain path);
///   - the order's committed `min_received` amount equals the
///     caller-committed `min_receive` (the caller then applies the
///     Tier 2 peg-floor + optional Tier 1 oracle bound);
///   - `hop_chain` has exactly two entries binding the offered asset
///     and the target asset. SundaeSwap orders execute against a single
///     pool, and the assets are explicit in the order datum, so this is
///     a direct compare — no LP-name re-hash (cf. `minswap_v2_adapter`).
pub fn verify_swap_order(
  order: SundaeSwapOrder,
  expected_recipient_addr: Address,
  cancel_guard_hash: ByteArray,
  min_receive: Int,
  hop_chain: List<(ByteArray, ByteArray)>,
) -> Bool {
  let (offer_policy, offer_name, _offer_amount) = order.offer
  let (target_policy, target_name, target_amount) = order.min_received
  and {
    order.destination_addr == expected_recipient_addr,
    order.owner_script_hash == Some(cancel_guard_hash),
    min_receive == target_amount,
    min_receive > 0,
    when hop_chain is {
      [(hp_in, hn_in), (hp_out, hn_out)] -> and {
          hp_in == offer_policy,
          hn_in == offer_name,
          hp_out == target_policy,
          hn_out == target_name,
        }
      _ -> False
    },
  }
}

// ─────────────────────────────────────────────────────────────────────
// Cancel-guard value conservation (B2 drain-proof cancel)
// ─────────────────────────────────────────────────────────────────────

/// If `input` is a SundaeSwap order UTxO — its address payment
/// credential is one of the two known order scripts AND its decoded
/// `owner` is `Script(guard_hash)` — return its full value; otherwise
/// `None`. Filtering by the order address first guarantees the datum at
/// the input is a real `OrderDatum` before it is decoded — an arbitrary
/// input's inline datum could otherwise abort `un_constr_data`.
fn protected_order_value(
  input: Input,
  guard_hash: ByteArray,
  order_hash_a: ByteArray,
  order_hash_b: ByteArray,
) -> Option<Value> {
  when input.output.address.payment_credential is {
    Script(h) ->
      if h == order_hash_a || h == order_hash_b {
        when decode_order(input.output) is {
          Some(order) ->
            if order.owner_script_hash == Some(guard_hash) {
              Some(input.output.value)
            } else {
              None
            }
          None -> None
        }
      } else {
        None
      }
    _ -> None
  }
}

/// Verify a SundaeSwap order cancel preserves value — the B2 drain-proof
/// guarantee enforced by `sundaeswap_cancel_guard`.
///
/// Every *protected order* (an input at one of the two known SundaeSwap
/// order addresses whose decoded `owner` is `Script(guard_hash)`) must
/// land its full value — ADA included — in the vault as a NET increase:
/// `quantity_of(Σ outputs@vault) − quantity_of(Σ inputs@vault) ≥ qty`
/// for every asset of the protected set. The canceller pays the tx fee
/// from a separate input.
///
/// **Net, not gross (H-1)**: an earlier version compared the *gross* sum
/// of outputs at the vault payment credential against the protected
/// value. When the cancel TX also spends and recreates the vault UTxO —
/// which `vault_proxy` does not block, since its `withdrawal_count == 1`
/// counts only the ten routed vault staking validators, not this guard —
/// the recreated vault output's pre-existing balance satisfied the gross
/// check by itself, letting a compromised keeper redirect the cancelled
/// order value to any output. Subtracting `Σ inputs@vault` closes it: a
/// co-spent vault contributes 0 net, so the order value must genuinely
/// increase the vault. The normal flow (cancel → a NoDatum secondary at
/// the vault address, with no vault input) is unaffected — `Σ inputs@
/// vault` is then `zero`.
///
/// **Fail-closed (M-1)**: an empty protected set returns `False`. This
/// check is security-relevant only when at least one guard-owned order
/// is being spent; an empty set means either no such order is present,
/// or — the dangerous case — `order_hash_a/_b` are mis-parameterized
/// for the deployment network so the real order address was never
/// matched. `list.all` over an empty list is vacuously `True`, which
/// would otherwise grant an unconstrained drain. Returning `False`
/// makes that misconfiguration fail closed (cancel rejected), not open.
pub fn verify_cancel_value_conservation(
  inputs: List<Input>,
  outputs: List<Output>,
  guard_hash: ByteArray,
  vault_script_hash: ByteArray,
  order_hash_a: ByteArray,
  order_hash_b: ByteArray,
) -> Bool {
  // Total value of every protected order input.
  let protected =
    list.foldl(
      inputs,
      zero,
      fn(input, acc) {
        when
          protected_order_value(input, guard_hash, order_hash_a, order_hash_b)
        is {
          Some(v) -> merge(acc, v)
          None -> acc
        }
      },
    )
  // Total value of every output paid to the vault payment credential.
  let to_vault =
    list.foldl(
      outputs,
      zero,
      fn(output, acc) {
        when output.address.payment_credential is {
          Script(h) ->
            if h == vault_script_hash {
              merge(acc, output.value)
            } else {
              acc
            }
          _ -> acc
        }
      },
    )
  // H-1: total value of every INPUT at the vault payment credential.
  // Subtracted from `to_vault` so a co-spent + recreated vault UTxO
  // cannot satisfy the conservation check with its own pre-existing
  // balance — only a genuine net increase to the vault counts.
  let from_vault =
    list.foldl(
      inputs,
      zero,
      fn(input, acc) {
        when input.output.address.payment_credential is {
          Script(h) ->
            if h == vault_script_hash {
              merge(acc, input.output.value)
            } else {
              acc
            }
          _ -> acc
        }
      },
    )
  when flatten(protected) is {
    // M-1: no protected order matched — fail closed (see above).
    [] -> False
    protected_flat ->
      list.all(
        protected_flat,
        fn(entry) {
          let (policy, name, qty) = entry
          quantity_of(to_vault, policy, name) - quantity_of(from_vault, policy, name) >= qty
        },
      )
  }
}
