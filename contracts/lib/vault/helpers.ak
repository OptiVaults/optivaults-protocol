/// Transaction-context helpers shared across the vault stake validators
/// (vault_core / vault_protocol / vault_liqwid). These touch the Cardano
/// `Transaction` type — unlike `lib/vault/validation.ak` which only
/// reasons about datum-to-datum transitions.
///
/// References:
///   spec/architecture.md §3.6 (Registry layout)
///   spec/architecture.md §6 (Withdraw-Zero forwarding)
///   spec/vault-datum.md §3 (no_garbage_tokens / NDV / etc.)
///   spec/multisig-gov.md §7 (is_gov_authorized cross-validator pattern)

use aiken/cbor
use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{blake2b_256}
use aiken/interval.{Finite}
use cardano/address.{Inline, Script, VerificationKey}
use cardano/assets.{
  PolicyId, flatten, lovelace_of, merge, quantity_of, tokens, zero as value_zero,
}
use cardano/transaction.{InlineDatum, Input, Output, Spend, Transaction}
use vault/types.{
  ActionKind, Allocation, AssetOracleEntry, ExecuteAction, GovDatum,
  GovRedeemer, LiqwidMarketEntry, RegistryDatum, StableTokenEntry, VaultDatum,
}
use vault/validation.{check_immutable_fields, has_no_order_inputs}

// ─────────────────────────────────────────────────────────────────────
// Registry reading
// ─────────────────────────────────────────────────────────────────────

pub fn empty_registry() -> (
  List<ByteArray>,
  Int,
  List<StableTokenEntry>,
  List<LiqwidMarketEntry>,
) {
  ([], 0, [], [])
}

/// Read the canonical Registry UTXO from the TX's reference inputs —
/// backwards-compatible 4-tuple variant (no asset_oracles).
///
/// The Registry UTXO must be at `registry_hash` AND carry the Registry
/// auth NFT (`auth_policy`). Both are required: hash defends against
/// a wrong UTXO; auth NFT defends against a forged datum at the right
/// address (phantom-vault analogue, internal verification).
///
/// §5.4 P3 note: callers that need `asset_oracles` should use
/// `read_registry_datum_full` below instead.
pub fn read_registry_datum(
  ref_inputs: List<Input>,
  registry_hash: ByteArray,
  auth_policy: ByteArray,
) -> (
  List<ByteArray>,
  Int,
  List<StableTokenEntry>,
  List<LiqwidMarketEntry>,
) {
  let (a, b, c, d, _, _) =
    read_registry_datum_full(ref_inputs, registry_hash, auth_policy)
  (a, b, c, d)
}

/// Read the canonical Registry UTXO — full 6-tuple including
/// `asset_oracles` (§5.4 P3 oracle integration) and
/// `swap_adapter_hashes` (§B@launch=1 SwapAdapter dispatch).
pub fn read_registry_datum_full(
  ref_inputs: List<Input>,
  registry_hash: ByteArray,
  auth_policy: ByteArray,
) -> (
  List<ByteArray>,
  Int,
  List<StableTokenEntry>,
  List<LiqwidMarketEntry>,
  List<AssetOracleEntry>,
  List<ByteArray>,
) {
  let registry_input =
    list.find(
      ref_inputs,
      fn(input) {
        when input.output.address.payment_credential is {
          Script(hash) ->
            if hash == registry_hash {
              if auth_policy == #"" {
                True
              } else {
                dict.size(tokens(input.output.value, auth_policy)) > 0
              }
            } else {
              False
            }
          _ -> False
        }
      },
    )
  when registry_input is {
    Some(ri) ->
      when ri.output.datum is {
        InlineDatum(data) -> {
          expect reg: RegistryDatum = data
          (
            reg.protocol_hashes,
            reg.last_update_time,
            reg.stable_tokens,
            reg.liqwid_markets,
            reg.asset_oracles,
            reg.swap_adapter_hashes,
          )
        }
        _ -> ([], 0, [], [], [], [])
      }
    None -> ([], 0, [], [], [], [])
  }
}

// ─────────────────────────────────────────────────────────────────────
// Destination whitelist (DeployToProtocol / AdminDeployNonDeposit)
// ─────────────────────────────────────────────────────────────────────

/// Anti-double-satisfaction: verify destination at exact output index
/// (not via `list.any`). The destination address must:
///   - Have payment-credential script hash in `whitelist`
///   - Either no stake credential, OR a stake credential whose script
///     hash is also in `whitelist` (covers Minswap V2 addr1z type-1
///     where stake is a script credential)
///   - Carry at least `min_amount` of (deposit_token_policy, name)
pub fn verify_destination_whitelisted(
  outputs: List<Output>,
  whitelist: List<ByteArray>,
  min_amount: Int,
  deposit_token_policy: ByteArray,
  deposit_token_name: ByteArray,
  dest_output_idx: Int,
) -> Bool {
  expect Some(output) = list.at(outputs, dest_output_idx)
  when output.address.payment_credential is {
    Script(hash) ->
      if list.has(whitelist, hash) {
        let stake_ok =
          when output.address.stake_credential is {
            None -> True
            Some(cred) ->
              when cred is {
                Inline(inner) ->
                  when inner is {
                    Script(stake_hash) -> list.has(whitelist, stake_hash)
                    VerificationKey(stake_hash) -> list.has(whitelist, stake_hash)
                  }
                _ -> False
              }
          }
        if !stake_ok {
          False
        } else {
          quantity_of(output.value, deposit_token_policy, deposit_token_name) >= min_amount
        }
      } else {
        False
      }
    _ -> False
  }
}

// ─────────────────────────────────────────────────────────────────────
// Token preservation
// ─────────────────────────────────────────────────────────────────────

pub fn verify_output_value_min(output: Output, min_lovelace: Int) -> Bool {
  lovelace_of(output.value) >= min_lovelace
}

/// Verify a single token quantity is preserved within `allowed_decrease`.
/// Used for redeemers that intentionally spend a bounded amount of one
/// specific token (e.g. Withdraw spends `withdraw_amount` of deposit token).
pub fn verify_token_preserved(
  old_input: Output,
  cont_output: Output,
  policy: ByteArray,
  name: ByteArray,
  allowed_decrease: Int,
) -> Bool {
  let old_qty = quantity_of(old_input.value, policy, name)
  let new_qty = quantity_of(cont_output.value, policy, name)
  new_qty >= old_qty - allowed_decrease
}

/// Strictly stronger than `verify_other_tokens_preserved`: every token
/// in old_input must survive at >= old qty AND no new tokens may appear.
/// Used by RebalanceBuffer / UpdateStrategy / UpdateFee / UpdateFeeSplit
/// where the vault should not move ANY token (datum-only update).
pub fn verify_all_tokens_preserved(
  old_input: Output,
  cont_output: Output,
) -> Bool {
  let all_old_preserved =
    list.all(
      flatten(old_input.value),
      fn(entry) {
        let (policy, name, old_qty) = entry
        quantity_of(cont_output.value, policy, name) >= old_qty
      },
    )
  let no_new_tokens =
    list.all(
      flatten(cont_output.value),
      fn(entry) {
        let (policy, name, _) = entry
        or {
          policy == #"",
          quantity_of(old_input.value, policy, name) > 0,
        }
      },
    )
  and {
    all_old_preserved,
    no_new_tokens,
  }
}

/// All non-change tokens must be preserved at >= old qty AND no new
/// token policies may be introduced (internal-verification dual-layer fix). ADA
/// (policy `#""`) is always exempt — callers must check ADA separately
/// via `verify_output_value_min` or a custom bounded check.
///
/// Two change-allowed (policy, name) tuples can be specified; pass
/// `(#"", #"")` for the second pair if only one change is allowed.
pub fn verify_other_tokens_preserved(
  old_input: Output,
  cont_output: Output,
  change_policy_1: ByteArray,
  change_name_1: ByteArray,
  change_policy_2: ByteArray,
  change_name_2: ByteArray,
) -> Bool {
  let old_preserved =
    list.all(
      flatten(old_input.value),
      fn(entry) {
        let (policy, name, old_qty) = entry
        if policy == #"" {
          True
        } else if policy == change_policy_1 && name == change_name_1 {
          True
        } else if change_policy_2 != #"" && policy == change_policy_2 && name == change_name_2 {
          True
        } else {
          quantity_of(cont_output.value, policy, name) >= old_qty
        }
      },
    )
  let no_garbage_tokens =
    list.all(
      flatten(cont_output.value),
      fn(entry) {
        let (policy, name, _) = entry
        or {
          policy == #"",
          policy == change_policy_1 && name == change_name_1,
          change_policy_2 != #"" && policy == change_policy_2 && name == change_name_2,
          quantity_of(old_input.value, policy, name) > 0,
        }
      },
    )
  and {
    old_preserved,
    no_garbage_tokens,
  }
}

/// MergeUtxo helper: aggregate multiple vault-script inputs and verify
/// the single continuing output preserves their summed value.
pub fn verify_multi_input_preserved(
  inputs: List<Input>,
  own_hash: ByteArray,
  cont_output: Output,
) -> Bool {
  let total_input_value =
    list.foldl(
      inputs,
      value_zero,
      fn(input, acc) {
        when input.output.address.payment_credential is {
          Script(hash) ->
            if hash == own_hash {
              merge(acc, input.output.value)
            } else {
              acc
            }
          _ -> acc
        }
      },
    )
  let valid_tokens =
    list.all(
      flatten(total_input_value),
      fn(entry) {
        let (policy, name, input_qty) = entry
        quantity_of(cont_output.value, policy, name) >= input_qty
      },
    )
  let valid_ada = lovelace_of(cont_output.value) >= lovelace_of(total_input_value)
  let no_injection =
    list.length(flatten(cont_output.value)) <= list.length(flatten(total_input_value))
  and {
    valid_tokens,
    valid_ada,
    no_injection,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Receiver / fee / keeper output binding (anti-double-satisfaction)
// ─────────────────────────────────────────────────────────────────────

/// Verify that the output at `output_idx` pays at least `min_amount` of
/// (token_policy, token_name) to a wallet whose payment-credential PKH
/// matches `receiver`. For ADA, pass `token_policy = #""`.
pub fn verify_receiver_output(
  outputs: List<Output>,
  receiver: ByteArray,
  token_policy: ByteArray,
  token_name: ByteArray,
  min_amount: Int,
  output_idx: Int,
) -> Bool {
  expect Some(output) = list.at(outputs, output_idx)
  when output.address.payment_credential is {
    VerificationKey(pkh) ->
      if pkh == receiver {
        if token_policy == #"" {
          lovelace_of(output.value) >= min_amount
        } else {
          quantity_of(output.value, token_policy, token_name) >= min_amount
        }
      } else {
        False
      }
    _ -> False
  }
}

// ─────────────────────────────────────────────────────────────────────
// Datum helpers
// ─────────────────────────────────────────────────────────────────────

/// Return the unique continuing vault output (at `own_hash` script
/// address) and its parsed VaultDatum. Fails if 0 or >1 such outputs
/// exist; the staking validator that calls this must ensure a single
/// continuing output via the calling redeemer's invariants.
///
/// Also enforces stake-credential preservation between input and
/// continuing output (defense-in-depth against stake-credential swap).
pub fn get_continuing_datum(
  outputs: List<Output>,
  own_hash: ByteArray,
  own_input: Output,
) -> (Output, VaultDatum) {
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
  expect [cont_output] = matching
  expect own_input.address.stake_credential == cont_output.address.stake_credential
  expect InlineDatum(data) = cont_output.datum
  expect new_datum: VaultDatum = data
  (cont_output, new_datum)
}

/// Net minted quantity for a specific minting policy (positive for mint,
/// negative for burn, 0 for absent). Fails if multiple asset names are
/// minted under the same policy in the same TX (we only ever mint one
/// asset at a time under our own policies).
pub fn get_mint_quantity(tx: Transaction, policy_id: PolicyId) -> Int {
  let minted = tokens(tx.mint, policy_id)
  let pairs = dict.to_pairs(minted)
  when pairs is {
    [] -> 0
    [pair] -> pair.2nd
    _ -> fail @"Multiple token names minted under one policy"
  }
}

pub fn count_script_inputs(
  inputs: List<Input>,
  script_hash: ByteArray,
) -> Int {
  list.foldl(
    inputs,
    0,
    fn(input, acc) {
      when input.output.address.payment_credential is {
        Script(hash) ->
          if hash == script_hash {
            acc + 1
          } else {
            acc
          }
        _ -> acc
      }
    },
  )
}

/// Find the primary vault UTXO from TX inputs. Returns `(input,
/// old_datum, own_lovelace, vault_input_count, discovered_proxy_hash)`.
///
/// Unparameterised by design — security depends on:
///   - vault_proxy's `has_vault_nft` continuing-output check
///   - vault_proxy's `no_foreign_vault_datum` (rejects fake VaultDatum
///     UTXOs at the proxy address that lack the NFT)
///   - `get_continuing_datum`'s stake-credential preservation
///   - vault_input_count==1 (or MergeUtxo's bounded multi-input rule)
pub fn find_vault_utxo(
  inputs: List<Input>,
) -> (Input, VaultDatum, Int, Int, ByteArray) {
  let vault_input =
    list.find(
      inputs,
      fn(input) {
        when input.output.address.payment_credential is {
          Script(_hash) ->
            when input.output.datum is {
              InlineDatum(data) ->
                if data is VaultDatum { vault_version, .. }: VaultDatum {
                  vault_version >= 0
                } else {
                  False
                }
              _ -> False
            }
          _ -> False
        }
      },
    )
  expect Some(vi) = vault_input
  expect InlineDatum(data) = vi.output.datum
  expect old_datum: VaultDatum = data
  expect Script(discovered_proxy_hash) = vi.output.address.payment_credential
  let own_lovelace = lovelace_of(vi.output.value)
  let vault_input_count = count_script_inputs(inputs, discovered_proxy_hash)
  (vi, old_datum, own_lovelace, vault_input_count, discovered_proxy_hash)
}

// ─────────────────────────────────────────────────────────────────────
// Datum-preservation predicates (vault_protocol / vault_liqwid common)
// ─────────────────────────────────────────────────────────────────────

/// RebalanceBuffer-style "datum unchanged" — exhaustive equality on
/// every field whose modification is not part of the redeemer's own
/// allowed mutation set.
pub fn verify_datum_unchanged(old: VaultDatum, new: VaultDatum) -> Bool {
  and {
    new.total_deposited == old.total_deposited,
    new.total_shares == old.total_shares,
    new.idle_buffer == old.idle_buffer,
    new.non_deposit_value == old.non_deposit_value,
    new.last_compound_time == old.last_compound_time,
    new.last_realloc_time == old.last_realloc_time,
    new.last_fee_update_time == old.last_fee_update_time,
    new.last_ada_swap_time == old.last_ada_swap_time,
    new.strategy_allocations == old.strategy_allocations,
    new.liqwid_positions == old.liqwid_positions,
    new.frozen == old.frozen,
    check_immutable_fields(old, new),
    new.performance_fee_bps == old.performance_fee_bps,
    new.early_withdraw_fee_bps == old.early_withdraw_fee_bps,
    new.min_hold_seconds == old.min_hold_seconds,
    new.buffer_target_bps == old.buffer_target_bps,
    new.keeper_fee_bps == old.keeper_fee_bps,
    new.gov_fee_bps == old.gov_fee_bps,
    new.max_slippage_bps == old.max_slippage_bps,
    new.min_swap_peg_bps == old.min_swap_peg_bps,
  }
}

/// vault_protocol common preservation: 8 fields fixed across DeployToProtocol
/// / RecallFromProtocol / MergeUtxo / AdminDeployNonDeposit / UpdateStrategy.
pub fn verify_protocol_fields_preserved(
  old: VaultDatum,
  new: VaultDatum,
) -> Bool {
  and {
    new.total_deposited == old.total_deposited,
    new.total_shares == old.total_shares,
    new.frozen == old.frozen,
    new.last_compound_time == old.last_compound_time,
    new.last_realloc_time == old.last_realloc_time,
    new.last_fee_update_time == old.last_fee_update_time,
    new.last_ada_swap_time == old.last_ada_swap_time,
    new.liqwid_positions == old.liqwid_positions,
  }
}

// ─────────────────────────────────────────────────────────────────────
// vault_liqwid common pre-checks
// ─────────────────────────────────────────────────────────────────────

pub fn find_liqwid_market(
  tx: Transaction,
  old_datum: VaultDatum,
  market_id: Int,
) -> LiqwidMarketEntry {
  expect old_datum.registry_auth_policy != #""
  let (_, _, _, markets) =
    read_registry_datum(
      tx.reference_inputs,
      old_datum.registry_hash,
      old_datum.registry_auth_policy,
    )
  expect Some(market) = list.at(markets, market_id)
  market
}

pub fn check_liqwid_core(
  old: VaultDatum,
  new: VaultDatum,
  cont_output: Output,
  own_lovelace: Int,
  tx: Transaction,
) -> Bool {
  and {
    verify_liqwid_invariants(old, new),
    verify_output_value_min(cont_output, own_lovelace),
    get_mint_quantity(tx, old.vusdcx_policy) == 0,
    has_no_order_inputs(tx.inputs, old.order_script_hash),
    new.idle_buffer >= 0,
    new.non_deposit_value >= 0,
  }
}

pub fn verify_liqwid_invariants(old: VaultDatum, new: VaultDatum) -> Bool {
  and {
    new.total_deposited == old.total_deposited,
    new.total_shares == old.total_shares,
    new.strategy_allocations == old.strategy_allocations,
    new.last_compound_time == old.last_compound_time,
    new.frozen == old.frozen,
    new.last_realloc_time == old.last_realloc_time,
    new.last_fee_update_time == old.last_fee_update_time,
    new.last_ada_swap_time == old.last_ada_swap_time,
    check_immutable_fields(old, new),
    new.performance_fee_bps == old.performance_fee_bps,
    new.early_withdraw_fee_bps == old.early_withdraw_fee_bps,
    new.min_hold_seconds == old.min_hold_seconds,
    new.buffer_target_bps == old.buffer_target_bps,
    new.keeper_fee_bps == old.keeper_fee_bps,
    new.gov_fee_bps == old.gov_fee_bps,
    new.max_slippage_bps == old.max_slippage_bps,
    new.min_swap_peg_bps == old.min_swap_peg_bps,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Validity-range width helpers (internal verification)
// ─────────────────────────────────────────────────────────────────────

/// Returns `Some((lower, upper))` if the TX validity range has finite
/// bounds, else `None`. Time-anchored redeemers must reject when this
/// returns `None`.
pub fn finite_validity_range(tx: Transaction) -> Option<(Int, Int)> {
  when tx.validity_range.lower_bound.bound_type is {
    Finite(lo) ->
      when tx.validity_range.upper_bound.bound_type is {
        Finite(hi) -> Some((lo, hi))
        _ -> None
      }
    _ -> None
  }
}

/// True if the TX validity-range width <= `max_ms` AND finite.
/// Use with `vault/constants.max_validity_range_ms` (1 hour) for any
/// redeemer that writes a time-anchored datum field.
pub fn validity_range_width_ok(tx: Transaction, max_ms: Int) -> Bool {
  when finite_validity_range(tx) is {
    Some((lo, hi)) -> hi - lo <= max_ms
    None -> False
  }
}

/// Returns the lower bound (`now`) if finite, else fails with a clear
/// error message.
pub fn finite_lower(tx: Transaction) -> Int {
  expect Finite(lo) = tx.validity_range.lower_bound.bound_type
  lo
}

pub fn finite_upper(tx: Transaction) -> Int {
  expect Finite(hi) = tx.validity_range.upper_bound.bound_type
  hi
}

// ─────────────────────────────────────────────────────────────────────
// Governance authorization (V1 internal audit fix)
//
// Every validator that accepts governance-gated redeemers delegates
// authorization here. Spec: multisig-gov.md §7. Previously only
// `require_governance` was used — that merely checks "GovNFT is in
// tx.inputs somewhere", which allows m-of-n signers to queue a benign
// payload P1 (public disclosure during 1-of-n cancel window) and
// execute a different payload P2 in the same TX. `is_gov_authorized`
// closes that hole by requiring the queued QueuedAction's action_kind,
// target_script, and payload_hash to match the caller's expectations.
// ─────────────────────────────────────────────────────────────────────

/// Cross-validator governance-authorization predicate.
///
/// Verifies (all must hold):
///   1. The MultisigGov UTXO (carrying `(governance_policy, governance_name)`)
///      is consumed in this TX.
///   2. Its spend redeemer is `GovRedeemer::ExecuteAction { action_id }`.
///   3. The GovDatum has a queued action with matching `action_id`.
///   4. `queued.action_kind == expected_action_kind`.
///   5. `queued.target_script == own_script_hash` (caller-bound).
///   6. `queued.payload_hash == expected_payload_hash` (caller-bound).
///
/// The caller MUST pre-compute `expected_payload_hash` with the same
/// canonical CBOR tuple layout that was used when QueueAction stored
/// it. Use one of the `payload_hash_*` helpers below, or compute inline
/// with `blake2b_256(cbor.serialise(tuple))`.
pub fn is_gov_authorized(
  tx: Transaction,
  governance_policy: ByteArray,
  governance_name: ByteArray,
  expected_action_kind: ActionKind,
  expected_payload_hash: ByteArray,
  own_script_hash: ByteArray,
) -> Bool {
  let gov_input =
    list.find(
      tx.inputs,
      fn(i) {
        quantity_of(i.output.value, governance_policy, governance_name) == 1
      },
    )
  when gov_input is {
    Some(gi) -> {
      let datum_ok =
        when gi.output.datum is {
          InlineDatum(d) ->
            if d is _: GovDatum {
              True
            } else {
              False
            }
          _ -> False
        }
      if !datum_ok {
        False
      } else {
        expect InlineDatum(gov_data) = gi.output.datum
        expect gov: GovDatum = gov_data
        when pairs.get_first(tx.redeemers, Spend(gi.output_reference)) is {
          Some(redeemer_data) ->
            if redeemer_data is _: GovRedeemer {
              expect gov_redeemer: GovRedeemer = redeemer_data
              when gov_redeemer is {
                ExecuteAction { action_id } -> {
                  let action =
                    list.find(gov.queued, fn(a) { a.action_id == action_id })
                  when action is {
                    Some(a) ->
                      and {
                        a.action_kind == expected_action_kind,
                        a.target_script == own_script_hash,
                        a.payload_hash == expected_payload_hash,
                      }
                    None -> False
                  }
                }
                _ -> False
              }
            } else {
              False
            }
          None -> False
        }
      }
    }
    None -> False
  }
}

// ─────────────────────────────────────────────────────────────────────
// Canonical payload-hash helpers (one per governance-gated redeemer).
//
// These MUST match off-chain tooling at QueueAction time. If you change
// the tuple layout here you must update `scripts/governance/opti-gov.ts`
// in lock-step, or the hash will diverge and execution will fail.
// ─────────────────────────────────────────────────────────────────────

/// UpdateStrategy: (new_allocations, new_buffer_target_bps)
pub fn payload_hash_update_strategy(
  new_allocations: List<Allocation>,
  new_buffer_target_bps: Int,
) -> ByteArray {
  blake2b_256(cbor.serialise((new_allocations, new_buffer_target_bps)))
}

/// UpdateFee: (new_performance_fee_bps, new_early_withdraw_fee_bps, new_min_hold_seconds)
pub fn payload_hash_update_fee(
  new_performance_fee_bps: Int,
  new_early_withdraw_fee_bps: Int,
  new_min_hold_seconds: Int,
) -> ByteArray {
  blake2b_256(
    cbor.serialise(
      (new_performance_fee_bps, new_early_withdraw_fee_bps, new_min_hold_seconds),
    ),
  )
}

/// UpdateFeeSplit: (new_keeper_fee_bps, new_gov_fee_bps)
pub fn payload_hash_update_fee_split(
  new_keeper_fee_bps: Int,
  new_gov_fee_bps: Int,
) -> ByteArray {
  blake2b_256(cbor.serialise((new_keeper_fee_bps, new_gov_fee_bps)))
}

/// UpdateSlippagePolicy (§5.4 Phase 2):
///   (new_max_slippage_bps, new_min_swap_peg_bps)
/// Payload-hash domain separation — a governance action with the same
/// action_kind but different (max_slippage, min_swap_peg) tuple cannot
/// replay another's executable proposal. Governance signs this hash at
/// queue time; vault_gov_policy rebuilds + compares at execute time.
pub fn payload_hash_update_slippage_policy(
  new_max_slippage_bps: Int,
  new_min_swap_peg_bps: Int,
) -> ByteArray {
  blake2b_256(cbor.serialise((new_max_slippage_bps, new_min_swap_peg_bps)))
}

/// EmergencyWithdraw: (loss_amount, freeze_flag)
pub fn payload_hash_emergency_withdraw(
  loss_amount: Int,
  freeze_flag: Int,
) -> ByteArray {
  blake2b_256(cbor.serialise((loss_amount, freeze_flag)))
}

/// AdminDeployNonDeposit: (deploy_amount, deploy_token_policy, deploy_token_name)
///
/// new_allocations + dest_output_idx are NOT part of the payload hash —
/// they're operational choices that governance does not pre-commit to.
pub fn payload_hash_admin_deploy(
  deploy_amount: Int,
  deploy_token_policy: ByteArray,
  deploy_token_name: ByteArray,
) -> ByteArray {
  blake2b_256(
    cbor.serialise((deploy_amount, deploy_token_policy, deploy_token_name)),
  )
}

/// UpdateRegistry / FastUpdateMarkets: hash of the full new RegistryDatum
/// (governance commits to exact new registry state at queue time).
pub fn payload_hash_update_registry(new_registry: RegistryDatum) -> ByteArray {
  blake2b_256(cbor.serialise(new_registry))
}

/// UpdateKeeperAuth: hash of the full new KeeperAuthDatum.
/// Note: caller passes the new datum value; we hash it here.
pub fn payload_hash_update_keeper_auth(new_datum: Data) -> ByteArray {
  blake2b_256(cbor.serialise(new_datum))
}

/// TreasurySpend: (category_tag_byte, amount, recipient_address, audit_invoice_ref)
pub fn payload_hash_treasury_spend(
  category_tag: ByteArray,
  amount: Int,
  recipient: Data,
  audit_invoice_ref: ByteArray,
) -> ByteArray {
  blake2b_256(
    cbor.serialise((category_tag, amount, recipient, audit_invoice_ref)),
  )
}

/// UpdateTreasuryParams: (audit_bps, ops_bps, rd_bps, buffer_bps,
///                        cap_audit, cap_ops, cap_rd, cap_buffer)
pub fn payload_hash_treasury_params(
  audit_bps: Int,
  ops_bps: Int,
  rd_bps: Int,
  buffer_bps: Int,
  cap_audit: Int,
  cap_ops: Int,
  cap_rd: Int,
  cap_buffer: Int,
) -> ByteArray {
  blake2b_256(
    cbor.serialise(
      (
        audit_bps,
        ops_bps,
        rd_bps,
        buffer_bps,
        cap_audit,
        cap_ops,
        cap_rd,
        cap_buffer,
      ),
    ),
  )
}

/// SlashBond: (bond_owner, evidence_ref, slash_amount)
pub fn payload_hash_slash_bond(
  bond_owner: ByteArray,
  evidence_ref: ByteArray,
  slash_amount: Int,
) -> ByteArray {
  blake2b_256(cbor.serialise((bond_owner, evidence_ref, slash_amount)))
}

/// DeregisterStake (A2, 2026-04-20): single-field payload pinning the
/// target stake validator's script hash. The `target_script` field of the
/// queued action *also* pins this, but encoding it into the payload hash
/// matches the uniform payload_hash_* pattern used by every other
/// governance-gated action and guards against any off-chain tooling that
/// builds a QueueAction with target_script ≠ payload hash input.
pub fn payload_hash_deregister_stake(target_hash: ByteArray) -> ByteArray {
  blake2b_256(cbor.serialise(target_hash))
}

// Category tags for treasury spend payload hashing (stable across
// on/off-chain so off-chain tooling can compute the same hash).
pub const cat_tag_audit: ByteArray = #"01"
pub const cat_tag_ops: ByteArray = #"02"
pub const cat_tag_rd: ByteArray = #"03"
pub const cat_tag_buffer: ByteArray = #"04"
