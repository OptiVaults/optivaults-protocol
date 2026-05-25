//// Unit tests for `vault/sundaeswap` — SundaeSwap order datum decoding
//// + SwapAdapter invariant verification.
////
//// Fixtures construct OrderDatum `Data` directly via `builtin.*_data`,
//// mirroring the `minswap_v2_adapter` test style. They prove the
//// decoder + `verify_swap_order` logic; the assumption that SundaeSwap
//// encodes its on-chain order datum in this exact shape is closed by a
//// real-UTxO check before mainnet whitelisting (see `sundaeswap.ak`).

use aiken/builtin.{b_data, constr_data, i_data, list_data}
use aiken/cbor
use cardano/address.{Address, Script}
use cardano/assets.{Value, from_asset, merge}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, OutputReference}
use vault/sundaeswap.{
  decode_order, decode_order_datum, verify_cancel_value_conservation,
  verify_swap_order,
}

// ─── fixture constants ──────────────────────────────────────────────

const usdcx_policy: ByteArray =
  #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34"

const usdcx_name: ByteArray = #"5553444378"

const djed_policy: ByteArray =
  #"8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd61"

const djed_name: ByteArray = #"446a65644d6963726f555344"

const vault_hash: ByteArray =
  #"11111111111111111111111111111111111111111111111111111111"

const guard_hash: ByteArray =
  #"22222222222222222222222222222222222222222222222222222222"

const attacker_hash: ByteArray =
  #"33333333333333333333333333333333333333333333333333333333"

const pool_ident_hash: ByteArray =
  #"44444444444444444444444444444444444444444444444444444444"

fn vault_address() -> Address {
  Address { payment_credential: Script(vault_hash), stake_credential: None }
}

fn attacker_address() -> Address {
  Address { payment_credential: Script(attacker_hash), stake_credential: None }
}

// ─── fixture builders ───────────────────────────────────────────────

/// SingletonValue (PolicyId, AssetName, Int) — Aiken 3-tuple = Plutus
/// List of 3.
fn singleton(policy: ByteArray, name: ByteArray, amount: Int) -> Data {
  list_data([b_data(policy), b_data(name), i_data(amount)])
}

/// `MultisigScript::Script(hash)` (ctor 6).
fn owner_script(hash: ByteArray) -> Data {
  constr_data(6, [b_data(hash)])
}

/// `MultisigScript::Signature(pkh)` (ctor 0).
fn owner_signature(pkh: ByteArray) -> Data {
  constr_data(0, [b_data(pkh)])
}

/// `Destination::Fixed { address, datum = NoDatum }` (ctor 0).
fn destination_fixed(addr: Address) -> Data {
  let addr_data: Data = addr
  constr_data(0, [addr_data, constr_data(0, [])])
}

/// `Destination::Self` (ctor 1).
fn destination_self() -> Data {
  constr_data(1, [])
}

/// `Order::Swap { offer, min_received }` (ctor 1).
fn details_swap(offer: Data, min_received: Data) -> Data {
  constr_data(1, [offer, min_received])
}

/// `Order::Deposit { .. }` (ctor 2) — a non-swap order.
fn details_deposit() -> Data {
  constr_data(2, [list_data([])])
}

/// Assemble a full `OrderDatum` (Constr 0, 6 fields).
/// pool_ident = Some(ident) (Constr 0); extension = VOID_BYTES (the
/// `d87980` unit CBOR carried as a bytestring) — both match the
/// SundaeSwap SDK V3 datum encoding.
fn order_datum(owner: Data, destination: Data, details: Data) -> Data {
  constr_data(
    0,
    [
      constr_data(0, [b_data(pool_ident_hash)]),
      owner,
      i_data(2_000_000),
      destination,
      details,
      b_data(#"d87980"),
    ],
  )
}

/// A well-formed USDCx -> DJED swap order owned by the cancel-guard,
/// paying out to the vault.
fn good_order() -> Data {
  order_datum(
    owner_script(guard_hash),
    destination_fixed(vault_address()),
    details_swap(
      singleton(usdcx_policy, usdcx_name, 10_000_000),
      singleton(djed_policy, djed_name, 9_500_000),
    ),
  )
}

fn good_hop_chain() -> List<(ByteArray, ByteArray)> {
  [(usdcx_policy, usdcx_name), (djed_policy, djed_name)]
}

// ─── decode_order_datum ─────────────────────────────────────────────

test decode_good_order() {
  expect Some(order) = decode_order_datum(good_order())
  and {
    order.offer == (usdcx_policy, usdcx_name, 10_000_000),
    order.min_received == (djed_policy, djed_name, 9_500_000),
    order.destination_addr == vault_address(),
    order.owner_script_hash == Some(guard_hash),
  }
}

test decode_owner_signature_yields_none_owner_hash() {
  // Owner is a plain signature, not a Script — owner_script_hash None.
  expect Some(order) =
    decode_order_datum(
      order_datum(
        owner_signature(attacker_hash),
        destination_fixed(vault_address()),
        details_swap(
          singleton(usdcx_policy, usdcx_name, 10_000_000),
          singleton(djed_policy, djed_name, 9_500_000),
        ),
      ),
    )
  order.owner_script_hash == None
}

test decode_destination_self_rejected() {
  // Destination::Self carries no address — whole decode must fail.
  decode_order_datum(
    order_datum(
      owner_script(guard_hash),
      destination_self(),
      details_swap(
        singleton(usdcx_policy, usdcx_name, 10_000_000),
        singleton(djed_policy, djed_name, 9_500_000),
      ),
    ),
  ) == None
}

test decode_non_swap_order_rejected() {
  // A Deposit order is not a swap — decode must fail.
  decode_order_datum(
    order_datum(
      owner_script(guard_hash),
      destination_fixed(vault_address()),
      details_deposit(),
    ),
  ) == None
}

test decode_wrong_outer_constructor_rejected() {
  // OrderDatum must be Constr 0.
  decode_order_datum(constr_data(1, [])) == None
}

// ─── verify_swap_order ──────────────────────────────────────────────

test verify_happy_path() {
  expect Some(order) = decode_order_datum(good_order())
  verify_swap_order(
    order,
    vault_address(),
    guard_hash,
    9_500_000,
    good_hop_chain(),
  )
}

test verify_rejects_wrong_destination() {
  // Recipient-address binding: order pays out to an attacker address.
  expect Some(order) =
    decode_order_datum(
      order_datum(
        owner_script(guard_hash),
        destination_fixed(attacker_address()),
        details_swap(
          singleton(usdcx_policy, usdcx_name, 10_000_000),
          singleton(djed_policy, djed_name, 9_500_000),
        ),
      ),
    )
  !verify_swap_order(
    order,
    vault_address(),
    guard_hash,
    9_500_000,
    good_hop_chain(),
  )
}

test verify_rejects_owner_not_cancel_guard() {
  // B2: owner pinned to an attacker script instead of the cancel-guard.
  expect Some(order) =
    decode_order_datum(
      order_datum(
        owner_script(attacker_hash),
        destination_fixed(vault_address()),
        details_swap(
          singleton(usdcx_policy, usdcx_name, 10_000_000),
          singleton(djed_policy, djed_name, 9_500_000),
        ),
      ),
    )
  !verify_swap_order(
    order,
    vault_address(),
    guard_hash,
    9_500_000,
    good_hop_chain(),
  )
}

test verify_rejects_owner_signature() {
  // Owner is a signature — owner_script_hash None, cannot equal guard.
  expect Some(order) =
    decode_order_datum(
      order_datum(
        owner_signature(attacker_hash),
        destination_fixed(vault_address()),
        details_swap(
          singleton(usdcx_policy, usdcx_name, 10_000_000),
          singleton(djed_policy, djed_name, 9_500_000),
        ),
      ),
    )
  !verify_swap_order(
    order,
    vault_address(),
    guard_hash,
    9_500_000,
    good_hop_chain(),
  )
}

test verify_rejects_min_receive_mismatch() {
  expect Some(order) = decode_order_datum(good_order())
  // Caller claims a higher min_receive than the order actually commits.
  !verify_swap_order(
    order,
    vault_address(),
    guard_hash,
    9_900_000,
    good_hop_chain(),
  )
}

test verify_rejects_zero_min_receive() {
  expect Some(order) =
    decode_order_datum(
      order_datum(
        owner_script(guard_hash),
        destination_fixed(vault_address()),
        details_swap(
          singleton(usdcx_policy, usdcx_name, 10_000_000),
          singleton(djed_policy, djed_name, 0),
        ),
      ),
    )
  !verify_swap_order(order, vault_address(), guard_hash, 0, good_hop_chain())
}

test verify_rejects_hop_chain_wrong_target() {
  expect Some(order) = decode_order_datum(good_order())
  // hop_chain claims the target is USDCx, but the order targets DJED.
  !verify_swap_order(
    order,
    vault_address(),
    guard_hash,
    9_500_000,
    [(usdcx_policy, usdcx_name), (usdcx_policy, usdcx_name)],
  )
}

test verify_rejects_hop_chain_wrong_offer() {
  expect Some(order) = decode_order_datum(good_order())
  // hop_chain claims the input is DJED, but the order offers USDCx.
  !verify_swap_order(
    order,
    vault_address(),
    guard_hash,
    9_500_000,
    [(djed_policy, djed_name), (djed_policy, djed_name)],
  )
}

test verify_rejects_single_entry_hop_chain() {
  expect Some(order) = decode_order_datum(good_order())
  !verify_swap_order(
    order,
    vault_address(),
    guard_hash,
    9_500_000,
    [(usdcx_policy, usdcx_name)],
  )
}

test verify_rejects_three_entry_hop_chain() {
  // SundaeSwap orders are single-pool — hop_chain must be exactly 2.
  expect Some(order) = decode_order_datum(good_order())
  !verify_swap_order(
    order,
    vault_address(),
    guard_hash,
    9_500_000,
    [
      (usdcx_policy, usdcx_name),
      (djed_policy, djed_name),
      (djed_policy, djed_name),
    ],
  )
}

// ─── cross-stack: keeper TS encoder <-> Aiken decoder ───────────────

test keeper_builder_cbor_cross_stack() {
  // CBOR emitted by the keeper `sundaeSwapBuilder.buildSundaeSwapOrder
  // Datum` for the identical fixture (cancel_guard 0x22*28, vault
  // 0x11*28, USDCx 10_000_000 -> DJED 9_500_000, max_protocol_fee
  // 2_000_000). Byte equality with the Aiken fixture proves the keeper
  // TypeScript encoder and this module's decoder agree on the SundaeSwap
  // OrderDatum wire format — a cross-stack round-trip without a chain.
  cbor.serialise(good_order()) == #"d8799fd8799f581c44444444444444444444444444444444444444444444444444444444ffd87f9f581c22222222222222222222222222222222222222222222222222222222ff1a001e8480d8799fd8799fd87a9f581c11111111111111111111111111111111111111111111111111111111ffd87a80ffd87980ffd87a9f9f581c1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e344555534443781a00989680ff9f581c8db269c3ec630e06ae29f74bc39edd1f87c819f1056206e879a1cd614c446a65644d6963726f5553441a0090f560ffff43d87980ff"
}

// ─── cancel-guard value conservation fixtures ───────────────────────

const order_hash_a: ByteArray =
  #"55555555555555555555555555555555555555555555555555555555"

const order_hash_b: ByteArray =
  #"66666666666666666666666666666666666666666666666666666666"

/// Value of a typical SundaeSwap order UTxO — 4 ADA + 10 USDCx.
fn order_value() -> Value {
  merge(
    from_asset(#"", #"", 4_000_000),
    from_asset(usdcx_policy, usdcx_name, 10_000_000),
  )
}

/// An `Output` at `addr_hash` carrying `value` + an inline SundaeSwap
/// swap-order datum with the given `owner` (paying out to the vault).
fn order_output(addr_hash: ByteArray, owner: Data, value: Value) -> Output {
  Output {
    address: Address {
      payment_credential: Script(addr_hash),
      stake_credential: None,
    },
    value,
    datum: InlineDatum(
      order_datum(
        owner,
        destination_fixed(vault_address()),
        details_swap(
          singleton(usdcx_policy, usdcx_name, 10_000_000),
          singleton(djed_policy, djed_name, 9_500_000),
        ),
      ),
    ),
    reference_script: None,
  }
}

/// Wrap an `Output` as a transaction `Input`.
fn input_of(output: Output) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"0000000000000000000000000000000000000000000000000000000000000000",
      output_index: 0,
    },
    output,
  }
}

/// A datum-less `Output` to `addr_hash` carrying `value` — the shape of
/// a cancel refund landing back at the vault address.
fn plain_output(addr_hash: ByteArray, value: Value) -> Output {
  Output {
    address: Address {
      payment_credential: Script(addr_hash),
      stake_credential: None,
    },
    value,
    datum: NoDatum,
    reference_script: None,
  }
}

// ─── verify_cancel_value_conservation ───────────────────────────────

test cancel_conservation_happy() {
  // One protected order (guard-owned, at order address A); a single
  // vault output covers its full value.
  let inputs =
    [input_of(order_output(order_hash_a, owner_script(guard_hash), order_value()))]
  let outputs = [plain_output(vault_hash, order_value())]
  verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_rejects_token_underpay() {
  // Vault output is short 1 USDCx vs the protected order.
  let inputs =
    [input_of(order_output(order_hash_a, owner_script(guard_hash), order_value()))]
  let outputs =
    [
      plain_output(
        vault_hash,
        merge(
          from_asset(#"", #"", 4_000_000),
          from_asset(usdcx_policy, usdcx_name, 9_999_999),
        ),
      ),
    ]
  !verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_rejects_ada_underpay() {
  // ADA is conserved too — vault output is short 1 lovelace.
  let inputs =
    [input_of(order_output(order_hash_a, owner_script(guard_hash), order_value()))]
  let outputs =
    [
      plain_output(
        vault_hash,
        merge(
          from_asset(#"", #"", 3_999_999),
          from_asset(usdcx_policy, usdcx_name, 10_000_000),
        ),
      ),
    ]
  !verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_rejects_empty_protected() {
  // M-1 fail-closed: no protected order in the tx — the handler must
  // not vacuously pass (`list.all` over `[]` would otherwise be True).
  let outputs = [plain_output(vault_hash, order_value())]
  !verify_cancel_value_conservation(
    [],
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_rejects_wrong_owner() {
  // Order sits at a known order address but its owner is an attacker
  // script, not the guard — not counted as protected → empty → fail.
  let inputs =
    [input_of(order_output(order_hash_a, owner_script(attacker_hash), order_value()))]
  let outputs = [plain_output(attacker_hash, order_value())]
  !verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_rejects_wrong_order_address() {
  // M-1: a guard-owned order at an address that is NOT one of the two
  // configured order hashes is not recognized — this is the
  // misconfiguration surface. Protected set stays empty → fail closed.
  let inputs =
    [input_of(order_output(attacker_hash, owner_script(guard_hash), order_value()))]
  let outputs = [plain_output(attacker_hash, order_value())]
  !verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_multi_order() {
  // Two protected orders (one at A, one at B) — the vault outputs must
  // cover the SUM; order_hash_b is recognized alongside A.
  let inputs =
    [
      input_of(order_output(order_hash_a, owner_script(guard_hash), order_value())),
      input_of(order_output(order_hash_b, owner_script(guard_hash), order_value())),
    ]
  let outputs =
    [
      plain_output(
        vault_hash,
        merge(
          from_asset(#"", #"", 8_000_000),
          from_asset(usdcx_policy, usdcx_name, 20_000_000),
        ),
      ),
    ]
  verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_multi_order_partial_cover_rejected() {
  // Two protected orders but the vault outputs cover only one — fail.
  let inputs =
    [
      input_of(order_output(order_hash_a, owner_script(guard_hash), order_value())),
      input_of(order_output(order_hash_b, owner_script(guard_hash), order_value())),
    ]
  let outputs = [plain_output(vault_hash, order_value())]
  !verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_extra_to_vault_ok() {
  // Over-paying the vault (>= per asset) is fine — conservation is a
  // floor, not an equality.
  let inputs =
    [input_of(order_output(order_hash_a, owner_script(guard_hash), order_value()))]
  let outputs =
    [
      plain_output(
        vault_hash,
        merge(
          from_asset(#"", #"", 5_000_000),
          from_asset(usdcx_policy, usdcx_name, 10_000_001),
        ),
      ),
    ]
  verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_split_vault_outputs() {
  // The protected value may be returned across multiple vault outputs —
  // they are summed before the per-asset floor check.
  let inputs =
    [input_of(order_output(order_hash_a, owner_script(guard_hash), order_value()))]
  let outputs =
    [
      plain_output(vault_hash, from_asset(#"", #"", 4_000_000)),
      plain_output(vault_hash, from_asset(usdcx_policy, usdcx_name, 10_000_000)),
    ]
  verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_rejects_vault_cospend_drain() {
  // H-1: the cancel TX co-spends + recreates the vault UTxO. The
  // recreated vault output carries the vault's own pre-existing balance,
  // which satisfies a *gross* to-vault check on its own — while the
  // protected order's value is siphoned to an attacker output. The net
  // check (outputs@vault − inputs@vault) must reject this.
  let vault_balance =
    merge(
      from_asset(#"", #"", 50_000_000),
      from_asset(usdcx_policy, usdcx_name, 100_000_000),
    )
  let inputs =
    [
      input_of(order_output(order_hash_a, owner_script(guard_hash), order_value())),
      input_of(plain_output(vault_hash, vault_balance)),
    ]
  let outputs =
    [
      // vault recreated, balance unchanged — order value did NOT fold in
      plain_output(vault_hash, vault_balance),
      // order value siphoned to the attacker
      plain_output(attacker_hash, order_value()),
    ]
  !verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

test cancel_conservation_vault_cospend_genuine_fold_ok() {
  // Mirror case: the order is co-spent with the vault AND its value
  // genuinely folds in — the recreated vault output exceeds the vault
  // input by exactly the protected order value. Net ≥ protected → ok.
  let vault_in =
    merge(
      from_asset(#"", #"", 50_000_000),
      from_asset(usdcx_policy, usdcx_name, 100_000_000),
    )
  let vault_out =
    merge(
      from_asset(#"", #"", 54_000_000),
      from_asset(usdcx_policy, usdcx_name, 110_000_000),
    )
  let inputs =
    [
      input_of(order_output(order_hash_a, owner_script(guard_hash), order_value())),
      input_of(plain_output(vault_hash, vault_in)),
    ]
  let outputs = [plain_output(vault_hash, vault_out)]
  verify_cancel_value_conservation(
    inputs,
    outputs,
    guard_hash,
    vault_hash,
    order_hash_a,
    order_hash_b,
  )
}

// ─── decode_order (Output-level) ────────────────────────────────────

test decode_order_rejects_no_inline_datum() {
  // An output carrying no inline datum cannot be a SundaeSwap order.
  decode_order(plain_output(order_hash_a, order_value())) == None
}
