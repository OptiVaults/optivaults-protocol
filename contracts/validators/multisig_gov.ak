/// multisig_gov — m-of-n governance state machine
///
/// Single UTXO at this script address carrying the one-shot Governance
/// NFT. Holds:
///   - signer set + threshold + per-signer tenure / qualification times
///   - timelocked queued actions
///   - signer compensation pool (accumulates from Compound's gov fee
///     share; quarterly distributed)
///   - strict-monotonic nonce
///
/// Six redeemers — see spec/multisig-gov.md §6 for full validation
/// rules. Implementation notes per redeemer are inline below.
///
/// Compile-time anchored to (governance_nft_policy, governance_nft_name)
/// — the gov UTXO must carry this token to be recognized as legitimate
/// by every validator that delegates authorization here.

use aiken/builtin
use aiken/cbor
use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/interval.{Finite}
use cardano/address.{Script, VerificationKey}
use cardano/assets.{lovelace_of, quantity_of}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}
use vault/constants.{
  distribute_period_ms, gov_max_queued, gov_max_signers, gov_max_ttl_ms,
  gov_min_signers, gov_min_threshold, gov_min_ttl_ms, one_hour_ms,
  timelock_admin_deploy_ms, timelock_deregister_stake_ms, timelock_emergency_ms,
  timelock_fast_update_markets_ms, timelock_rotate_signers_ms,
  timelock_slash_bond_ms, timelock_treasury_spend_ms, timelock_update_fee_ms,
  timelock_update_fee_split_ms, timelock_update_keeper_auth_ms,
  timelock_update_registry_ms, timelock_update_slippage_policy_ms,
  timelock_update_strategy_ms, timelock_update_treasury_params_ms,
}
use vault/types.{
  ActAdminDeployNonDeposit, ActDeregisterStake, ActEmergencyWithdraw,
  ActFastUpdateMarkets, ActRotateSigners, ActSlashBond, ActTreasurySpend,
  ActUpdateFee, ActUpdateFeeSplit, ActUpdateKeeperAuth, ActUpdateRegistry,
  ActUpdateSlippagePolicy, ActUpdateStrategy, ActUpdateTreasuryParams,
  ActionKind, CancelAction, DistributeSignerCompensation, ExecuteAction,
  GovDatum, GovRedeemer, Heartbeat, QueueAction, QueuedAction,
  ReceiveCompoundShare, RotateSignersRedeemer,
}

// ─────────────────────────────────────────────────────────────────────
// action_id and per-kind timelock helpers
// ─────────────────────────────────────────────────────────────────────

fn action_kind_byte(k: ActionKind) -> ByteArray {
  when k is {
    ActUpdateStrategy -> #"01"
    ActUpdateFee -> #"02"
    ActUpdateFeeSplit -> #"03"
    ActEmergencyWithdraw -> #"04"
    ActAdminDeployNonDeposit -> #"05"
    ActUpdateRegistry -> #"06"
    ActFastUpdateMarkets -> #"07"
    ActUpdateKeeperAuth -> #"08"
    ActTreasurySpend -> #"09"
    ActUpdateTreasuryParams -> #"0a"
    ActRotateSigners -> #"0b"
    ActSlashBond -> #"0c"
    ActDeregisterStake -> #"0e"
    ActUpdateSlippagePolicy -> #"0f"
  }
}

fn min_timelock_ms(k: ActionKind) -> Int {
  when k is {
    ActUpdateStrategy -> timelock_update_strategy_ms
    ActUpdateFee -> timelock_update_fee_ms
    ActUpdateFeeSplit -> timelock_update_fee_split_ms
    ActEmergencyWithdraw -> timelock_emergency_ms
    ActAdminDeployNonDeposit -> timelock_admin_deploy_ms
    ActUpdateRegistry -> timelock_update_registry_ms
    ActFastUpdateMarkets -> timelock_fast_update_markets_ms
    ActUpdateKeeperAuth -> timelock_update_keeper_auth_ms
    ActTreasurySpend -> timelock_treasury_spend_ms
    ActUpdateTreasuryParams -> timelock_update_treasury_params_ms
    ActRotateSigners -> timelock_rotate_signers_ms
    ActSlashBond -> timelock_slash_bond_ms
    ActDeregisterStake -> timelock_deregister_stake_ms
    ActUpdateSlippagePolicy -> timelock_update_slippage_policy_ms
  }
}

/// action_id = blake2b_256(kind_tag || target || payload_hash || queued_at_be8 || nonce_be8)
fn compute_action_id(
  kind: ActionKind,
  target_script: ByteArray,
  payload_hash: ByteArray,
  queued_at_ms: Int,
  nonce: Int,
) -> ByteArray {
  let tag = action_kind_byte(kind)
  let preimage =
    builtin.append_bytearray(
      tag,
      builtin.append_bytearray(
        target_script,
        builtin.append_bytearray(
          payload_hash,
          builtin.append_bytearray(
            cbor.serialise(queued_at_ms),
            cbor.serialise(nonce),
          ),
        ),
      ),
    )
  blake2b_256(preimage)
}

// ─────────────────────────────────────────────────────────────────────
// Continuing-output / signer-set helpers
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

/// Count how many of `signers` appear in `tx.extra_signatories`. Used
/// to verify ≥threshold signatures.
fn count_signers_present(
  tx: Transaction,
  signers: List<ByteArray>,
) -> Int {
  list.foldl(
    signers,
    0,
    fn(s, acc) {
      if list.has(tx.extra_signatories, s) {
        acc + 1
      } else {
        acc
      }
    },
  )
}

/// Update each `signer_last_qualified_ms[i]` to `now` for every signer
/// that signed this TX; preserve others.
fn refresh_qualification(
  signers: List<ByteArray>,
  last_qualified: List<Int>,
  signed_set: List<ByteArray>,
  now: Int,
) -> List<Int> {
  list.map(
    list.zip(signers, last_qualified),
    fn(pair) {
      let (s, ts) = pair
      if list.has(signed_set, s) {
        now
      } else {
        ts
      }
    },
  )
}

/// Validate signer-set / threshold invariants.
///
/// - `n >= 3`: internal verification floor. Needed so that at Phase 2+
///   (n >= 5) there's structural room for threshold < n — i.e., at
///   least one non-quorum signer who can 1-of-n cancel a colluding
///   quorum.
/// - `threshold >= 2`: genuine multi-sig, no single-sig governance.
/// - `threshold <= n`: allows `threshold == n` (unanimity). V1 launch
///   uses 3-of-3 specifically because the founder is also the keeper
///   operator — unanimity forces the founder to convince BOTH other
///   signers (each separately recruited), not just one. Post-audit
///   Phase 2+ best practice is threshold < n to restore the structural
///   dissent-cancel property, but the contract does not enforce it.
fn valid_signer_set(signers: List<ByteArray>, threshold: Int) -> Bool {
  let n = list.length(signers)
  let unique_n = list.length(list.unique(signers))
  and {
    n >= gov_min_signers,
    n <= gov_max_signers,
    threshold >= gov_min_threshold,
    threshold <= n,
    unique_n == n,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Validator
// ─────────────────────────────────────────────────────────────────────

validator multisig_gov(
  governance_nft_policy: ByteArray,
  governance_nft_name: ByteArray,
  /// H-2 fix: USDCx identity anchored at deploy so ReceiveCompoundShare
  /// can verify `delta` USDCx actually flowed into this UTXO, and
  /// DistributeSignerCompensation pays in USDCx not lovelace.
  deposit_token_policy: ByteArray,
  deposit_token_name: ByteArray,
  /// H-2 (c): treasury_hash anchored so DistributeSignerCompensation can
  /// verify the forfeit output is routed through treasury.ReceiveGovForfeit
  /// (cross-validator binding).
  treasury_hash: ByteArray,
) {
  spend(
    datum: Option<GovDatum>,
    redeemer: GovRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) {
    expect Some(gov) = datum
    expect valid_signer_set(gov.signers, gov.threshold)

    expect Some(own_input) =
      list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
    expect Script(own_hash) = own_input.output.address.payment_credential

    // Gov NFT must be present in the spent input under the compile-time
    // policy + name.
    let nft_in_input =
      quantity_of(own_input.output.value, governance_nft_policy, governance_nft_name) == 1

    when redeemer is {
      // ══════════════════════════════════════════════════════
      // QueueAction
      // ══════════════════════════════════════════════════════
      QueueAction {
        action_kind,
        target_script,
        target_tx_hash,
        payload_hash,
        timelock_ms,
        ttl_ms,
      } -> {
        let signers_present = count_signers_present(tx, gov.signers)
        let sig_ok = signers_present >= gov.threshold
        let timelock_ok = timelock_ms >= min_timelock_ms(action_kind)
        let ttl_ok = ttl_ms >= gov_min_ttl_ms && ttl_ms <= gov_max_ttl_ms
        let payload_size_ok = builtin.length_of_bytearray(payload_hash) == 32
        let target_tx_ok =
          builtin.length_of_bytearray(target_tx_hash) == 0 || builtin.length_of_bytearray(
            target_tx_hash,
          ) == 32

        expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
        let nft_in_output =
          quantity_of(cont_output.value, governance_nft_policy, governance_nft_name) == 1
        let value_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)

        expect InlineDatum(new_data) = cont_output.datum
        expect new_gov: GovDatum = new_data

        // Validity range used as the queue timestamp (use upper bound
        // so attackers cannot front-run with a wide range).
        expect Finite(upper) = tx.validity_range.upper_bound.bound_type
        let action_id =
          compute_action_id(
            action_kind,
            target_script,
            payload_hash,
            upper,
            gov.nonce,
          )
        let new_action =
          QueuedAction {
            action_id,
            action_kind,
            target_script,
            target_tx_hash,
            payload_hash,
            queued_at_ms: upper,
            executable_at_ms: upper + timelock_ms,
            expires_at_ms: upper + timelock_ms + ttl_ms,
          }

        let queued_size_ok = list.length(gov.queued) + 1 <= gov_max_queued

        let valid_datum = and {
            new_gov.signers == gov.signers,
            new_gov.threshold == gov.threshold,
            new_gov.signer_joined_at_ms == gov.signer_joined_at_ms,
            new_gov.signer_compensation_pool == gov.signer_compensation_pool,
            new_gov.last_distribute_ms == gov.last_distribute_ms,
            new_gov.distribute_period_ms == gov.distribute_period_ms,
            new_gov.nonce == gov.nonce + 1,
            // queued = old + new_action (append)
            new_gov.queued == list.push(gov.queued, new_action),
            // signer_last_qualified_ms updates for signers who signed this TX
            new_gov.signer_last_qualified_ms == refresh_qualification(
              gov.signers,
              gov.signer_last_qualified_ms,
              tx.extra_signatories,
              upper,
            ),
          }

        and {
          nft_in_input,
          nft_in_output,
          value_ok,
          sig_ok,
          timelock_ok,
          ttl_ok,
          payload_size_ok,
          target_tx_ok,
          queued_size_ok,
          valid_datum,
        }
      }

      // ══════════════════════════════════════════════════════
      // CancelAction (1-of-n veto)
      // ══════════════════════════════════════════════════════
      CancelAction { action_id } -> {
        let signers_present = count_signers_present(tx, gov.signers)
        let sig_ok = signers_present >= 1

        let action_exists =
          list.any(gov.queued, fn(a) { a.action_id == action_id })
        let new_queued =
          list.filter(gov.queued, fn(a) { a.action_id != action_id })

        expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
        let nft_in_output =
          quantity_of(cont_output.value, governance_nft_policy, governance_nft_name) == 1
        let value_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)

        expect InlineDatum(new_data) = cont_output.datum
        expect new_gov: GovDatum = new_data

        expect Finite(upper) = tx.validity_range.upper_bound.bound_type
        let valid_datum = and {
            new_gov.signers == gov.signers,
            new_gov.threshold == gov.threshold,
            new_gov.signer_joined_at_ms == gov.signer_joined_at_ms,
            new_gov.signer_compensation_pool == gov.signer_compensation_pool,
            new_gov.last_distribute_ms == gov.last_distribute_ms,
            new_gov.distribute_period_ms == gov.distribute_period_ms,
            new_gov.nonce == gov.nonce + 1,
            new_gov.queued == new_queued,
            new_gov.signer_last_qualified_ms == refresh_qualification(
              gov.signers,
              gov.signer_last_qualified_ms,
              tx.extra_signatories,
              upper,
            ),
          }

        and {
          nft_in_input,
          nft_in_output,
          value_ok,
          sig_ok,
          action_exists,
          valid_datum,
        }
      }

      // ══════════════════════════════════════════════════════
      // ExecuteAction (≥threshold sigs; timelock window)
      // ══════════════════════════════════════════════════════
      ExecuteAction { action_id } -> {
        let signers_present = count_signers_present(tx, gov.signers)
        let sig_ok = signers_present >= gov.threshold

        expect Some(action) =
          list.find(gov.queued, fn(a) { a.action_id == action_id })

        // Timelock window: lower >= executable_at_ms; upper < expires_at_ms
        // 1-hour validity-range width cap (internal-verification family) — bounds tx.validity
        // tampering attempts.
        let time_window_ok =
          when (
            tx.validity_range.lower_bound.bound_type,
            tx.validity_range.upper_bound.bound_type,
          ) is {
            (Finite(lo), Finite(up)) ->
              and {
                lo >= action.executable_at_ms,
                up < action.expires_at_ms,
                up - lo <= one_hour_ms,
              }
            _ -> False
          }

        // If target_tx_hash is non-empty, enforce tx.id == target_tx_hash
        let tx_hash_ok =
          builtin.length_of_bytearray(action.target_tx_hash) == 0 || tx.id == action.target_tx_hash

        let new_queued =
          list.filter(gov.queued, fn(a) { a.action_id != action_id })

        expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
        let nft_in_output =
          quantity_of(cont_output.value, governance_nft_policy, governance_nft_name) == 1
        let value_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)

        expect InlineDatum(new_data) = cont_output.datum
        expect new_gov: GovDatum = new_data

        expect Finite(upper) = tx.validity_range.upper_bound.bound_type
        let valid_datum = and {
            new_gov.signers == gov.signers,
            new_gov.threshold == gov.threshold,
            new_gov.signer_joined_at_ms == gov.signer_joined_at_ms,
            new_gov.signer_compensation_pool == gov.signer_compensation_pool,
            new_gov.last_distribute_ms == gov.last_distribute_ms,
            new_gov.distribute_period_ms == gov.distribute_period_ms,
            new_gov.nonce == gov.nonce + 1,
            new_gov.queued == new_queued,
            new_gov.signer_last_qualified_ms == refresh_qualification(
              gov.signers,
              gov.signer_last_qualified_ms,
              tx.extra_signatories,
              upper,
            ),
          }

        and {
          nft_in_input,
          nft_in_output,
          value_ok,
          sig_ok,
          time_window_ok,
          tx_hash_ok,
          valid_datum,
        }
      }

      // ══════════════════════════════════════════════════════
      // RotateSignersRedeemer
      // ══════════════════════════════════════════════════════
      RotateSignersRedeemer { new_signers, new_threshold } -> {
        let signers_present = count_signers_present(tx, gov.signers)
        let sig_ok = signers_present >= gov.threshold
        let signer_set_ok = valid_signer_set(new_signers, new_threshold)

        // The rotation must match a queued ActRotateSigners whose
        // payload_hash binds to (new_signers, new_threshold).
        let payload_hash =
          blake2b_256(cbor.serialise((new_signers, new_threshold)))
        let matching =
          list.find(
            gov.queued,
            fn(a) {
              and {
                a.action_kind == ActRotateSigners,
                a.payload_hash == payload_hash,
              }
            },
          )
        expect Some(action) = matching

        let time_window_ok =
          when (
            tx.validity_range.lower_bound.bound_type,
            tx.validity_range.upper_bound.bound_type,
          ) is {
            (Finite(lo), Finite(up)) ->
              and {
                lo >= action.executable_at_ms,
                up < action.expires_at_ms,
                up - lo <= one_hour_ms,
              }
            _ -> False
          }

        expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
        let nft_in_output =
          quantity_of(cont_output.value, governance_nft_policy, governance_nft_name) == 1
        let value_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)
        expect InlineDatum(new_data) = cont_output.datum
        expect new_gov: GovDatum = new_data

        expect Finite(upper) = tx.validity_range.upper_bound.bound_type

        // For each new_signer:
        //   - If present in old.signers: preserve signer_joined_at_ms
        //     and signer_last_qualified_ms.
        //   - If new addition: signer_joined_at_ms = upper, last_qual = 0.
        let expected_joined =
          list.map(
            new_signers,
            fn(s) {
              when list.index_of(gov.signers, s) is {
                Some(idx) ->
                  when list.at(gov.signer_joined_at_ms, idx) is {
                    Some(t) -> t
                    None -> upper
                  }
                None -> upper
              }
            },
          )
        let expected_last_qual =
          list.map(
            new_signers,
            fn(s) {
              when list.index_of(gov.signers, s) is {
                Some(idx) ->
                  when list.at(gov.signer_last_qualified_ms, idx) is {
                    Some(t) -> t
                    None -> 0
                  }
                None -> 0
              }
            },
          )

        let new_queued =
          list.filter(
            gov.queued,
            fn(a) { a.action_id != action.action_id },
          )

        let valid_datum = and {
            new_gov.signers == new_signers,
            new_gov.threshold == new_threshold,
            new_gov.signer_joined_at_ms == expected_joined,
            new_gov.signer_last_qualified_ms == expected_last_qual,
            new_gov.signer_compensation_pool == gov.signer_compensation_pool,
            new_gov.last_distribute_ms == gov.last_distribute_ms,
            new_gov.distribute_period_ms == gov.distribute_period_ms,
            new_gov.nonce == gov.nonce + 1,
            new_gov.queued == new_queued,
          }

        and {
          nft_in_input,
          nft_in_output,
          value_ok,
          sig_ok,
          signer_set_ok,
          time_window_ok,
          valid_datum,
        }
      }

      // ══════════════════════════════════════════════════════
      // Heartbeat (1-of-self; 90-day cooldown)
      // ══════════════════════════════════════════════════════
      Heartbeat { signer } -> {
        let in_set = list.has(gov.signers, signer)
        let signed = list.has(tx.extra_signatories, signer)

        expect Some(idx) = list.index_of(gov.signers, signer)
        expect Some(prev_qual) = list.at(gov.signer_last_qualified_ms, idx)

        expect Finite(lo) = tx.validity_range.lower_bound.bound_type
        let cooldown_ok = lo - prev_qual >= distribute_period_ms

        expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
        let nft_in_output =
          quantity_of(cont_output.value, governance_nft_policy, governance_nft_name) == 1
        let value_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)
        expect InlineDatum(new_data) = cont_output.datum
        expect new_gov: GovDatum = new_data

        let expected_qual =
          list.map(
            list.zip(gov.signers, gov.signer_last_qualified_ms),
            fn(pair) {
              let (s, ts) = pair
              if s == signer {
                lo
              } else {
                ts
              }
            },
          )

        let valid_datum = and {
            new_gov.signers == gov.signers,
            new_gov.threshold == gov.threshold,
            new_gov.signer_joined_at_ms == gov.signer_joined_at_ms,
            new_gov.signer_last_qualified_ms == expected_qual,
            new_gov.queued == gov.queued,
            new_gov.signer_compensation_pool == gov.signer_compensation_pool,
            new_gov.last_distribute_ms == gov.last_distribute_ms,
            new_gov.distribute_period_ms == gov.distribute_period_ms,
            new_gov.nonce == gov.nonce + 1,
          }

        and {
          nft_in_input,
          nft_in_output,
          value_ok,
          in_set,
          signed,
          cooldown_ok,
          valid_datum,
        }
      }

      // ══════════════════════════════════════════════════════
      // ReceiveCompoundShare — Compound-time gov pool top-up.
      //
      // Authorization: this validator does NOT require signer signatures.
      // Trust is delegated to the Compound TX's vault_keeper_hot staking
      // validator (post-Phase-77 home of Compound): vault_keeper_hot.
      // Compound enforces that `delta` matches the gov-share computed
      // from `harvested_amount × performance_fee_bps × gov_fee_bps`, so
      // any TX that calls ReceiveCompoundShare without a matching
      // vault_keeper_hot.Compound spend will fail at vault_keeper_hot.
      //
      // Cross-validator binding works in both directions:
      //   - vault_keeper_hot requires this gov UTXO to be spent + datum updated
      //   - this validator requires the gov NFT to remain in continuing output
      // ══════════════════════════════════════════════════════
      ReceiveCompoundShare -> {
        expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
        let nft_in_output =
          quantity_of(cont_output.value, governance_nft_policy, governance_nft_name) == 1
        let value_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)

        // V1 internal audit (auto-derived delta): `delta` is DERIVED from the UTXO's USDCx
        // increment, not supplied by the redeemer. This means the pool
        // counter always matches the physical USDCx that arrived — no
        // drift possible. vault_keeper_hot.Compound enforces `new_usdcx >=
        // old_usdcx + gov_share` on its side, so the gov-share USDCx
        // cannot be under-delivered either.
        let old_usdcx =
          quantity_of(
            own_input.output.value,
            deposit_token_policy,
            deposit_token_name,
          )
        let new_usdcx =
          quantity_of(cont_output.value, deposit_token_policy, deposit_token_name)
        let derived_delta = new_usdcx - old_usdcx
        let amount_ok = derived_delta > 0

        expect InlineDatum(new_data) = cont_output.datum
        expect new_gov: GovDatum = new_data
        let valid_datum = and {
            new_gov.signers == gov.signers,
            new_gov.threshold == gov.threshold,
            new_gov.signer_joined_at_ms == gov.signer_joined_at_ms,
            new_gov.signer_last_qualified_ms == gov.signer_last_qualified_ms,
            new_gov.queued == gov.queued,
            new_gov.distribute_period_ms == gov.distribute_period_ms,
            new_gov.last_distribute_ms == gov.last_distribute_ms,
            new_gov.signer_compensation_pool == gov.signer_compensation_pool + derived_delta,
            new_gov.nonce == gov.nonce + 1,
          }

        and {
          nft_in_input,
          nft_in_output,
          value_ok,
          amount_ok,
          valid_datum,
        }
      }

      // ══════════════════════════════════════════════════════
      // DistributeSignerCompensation (1-of-n trigger; quarterly)
      // ══════════════════════════════════════════════════════
      DistributeSignerCompensation { triggering_signer, forfeit_output_idx } -> {
        let in_set = list.has(gov.signers, triggering_signer)
        let signed = list.has(tx.extra_signatories, triggering_signer)
        let pool_ok = gov.signer_compensation_pool > 0

        expect Finite(lo) = tx.validity_range.lower_bound.bound_type
        let cadence_ok =
          lo - gov.last_distribute_ms >= gov.distribute_period_ms

        // Qualification per signer i:
        //   joined_at[i] <= last_distribute_ms (full quarter tenure)
        //   last_qual[i] >= last_distribute_ms (acted in quarter)
        let qualified_count =
          list.foldl(
            list.zip(
              list.zip(gov.signers, gov.signer_joined_at_ms),
              gov.signer_last_qualified_ms,
            ),
            0,
            fn(triple, acc) {
              let ((_signer, joined), last_qual) = triple
              if and {
                joined <= gov.last_distribute_ms,
                last_qual >= gov.last_distribute_ms,
              } {
                acc + 1
              } else {
                acc
              }
            },
          )

        let per_signer =
          if qualified_count == 0 {
            0
          } else {
            gov.signer_compensation_pool / qualified_count
          }
        let forfeit_amount =
          gov.signer_compensation_pool - qualified_count * per_signer

        // H-2 (c): each qualified signer must receive `per_signer` USDCx
        // (was lovelace — spec violation; see V1 internal audit report).
        let payouts_ok =
          if qualified_count == 0 {
            True
          } else {
            list.all(
              list.zip(
                list.zip(gov.signers, gov.signer_joined_at_ms),
                gov.signer_last_qualified_ms,
              ),
              fn(triple) {
                let ((signer, joined), last_qual) = triple
                if and {
                  joined <= gov.last_distribute_ms,
                  last_qual >= gov.last_distribute_ms,
                } {
                  let received =
                    list.foldl(
                      tx.outputs,
                      0,
                      fn(out, acc) {
                        when out.address.payment_credential is {
                          VerificationKey(pkh) ->
                            if pkh == signer {
                              acc + quantity_of(
                                out.value,
                                deposit_token_policy,
                                deposit_token_name,
                              )
                            } else {
                              acc
                            }
                          _ -> acc
                        }
                      },
                    )
                  received >= per_signer
                } else {
                  True
                }
              },
            )
          }

        // H-2 (c) forfeit binding: if forfeit_amount > 0, an output at
        // forfeit_output_idx must route to the treasury script address
        // with at least forfeit_amount USDCx. treasury.ReceiveGovForfeit
        // enforces its audit_reserve_balance accounting on the same TX.
        let forfeit_ok =
          if forfeit_amount > 0 {
            when list.at(tx.outputs, forfeit_output_idx) is {
              Some(forfeit_out) ->
                when forfeit_out.address.payment_credential is {
                  Script(h) ->
                    and {
                      h == treasury_hash,
                      quantity_of(
                        forfeit_out.value,
                        deposit_token_policy,
                        deposit_token_name,
                      ) >= forfeit_amount,
                    }
                  _ -> False
                }
              None -> False
            }
          } else {
            True
          }

        expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
        let nft_in_output =
          quantity_of(cont_output.value, governance_nft_policy, governance_nft_name) == 1

        // USDCx value: continuing UTXO loses exactly `signer_compensation_pool`
        // USDCx (split between signer wallets and treasury forfeit).
        let old_usdcx =
          quantity_of(
            own_input.output.value,
            deposit_token_policy,
            deposit_token_name,
          )
        let new_usdcx =
          quantity_of(cont_output.value, deposit_token_policy, deposit_token_name)
        let usdcx_value_ok =
          new_usdcx >= old_usdcx - gov.signer_compensation_pool
        // Lovelace must be preserved (min-UTXO + any ADA the pool UTXO holds).
        let lovelace_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)

        expect InlineDatum(new_data) = cont_output.datum
        expect new_gov: GovDatum = new_data
        let valid_datum = and {
            new_gov.signers == gov.signers,
            new_gov.threshold == gov.threshold,
            new_gov.signer_joined_at_ms == gov.signer_joined_at_ms,
            new_gov.signer_last_qualified_ms == gov.signer_last_qualified_ms,
            new_gov.queued == gov.queued,
            new_gov.distribute_period_ms == gov.distribute_period_ms,
            new_gov.signer_compensation_pool == 0,
            new_gov.last_distribute_ms == lo,
            new_gov.nonce == gov.nonce + 1,
          }

        and {
          nft_in_input,
          nft_in_output,
          usdcx_value_ok,
          lovelace_ok,
          in_set,
          signed,
          pool_ok,
          cadence_ok,
          payouts_ok,
          forfeit_ok,
          valid_datum,
        }
      }
    }
  }

  else(_) {
    fail @"multisig_gov: unsupported purpose"
  }
}
