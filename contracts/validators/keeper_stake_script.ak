/// keeper_stake_script — staking validator that authorizes keeper actions.
///
/// V1 uses the "A-Plain" variant per spec/keeper-auth.md §3.1: every
/// keeper TX both invokes a zero-amount withdrawal against this stake
/// credential AND consumes the single keeper_auth UTXO (spend), updating
/// `last_successful_tx_at` + `nonce`.
///
/// Three execution paths:
///   - Spend (KeeperAuthRedeemer)  → manage the keeper_auth UTXO
///       (`WithdrawAsAuthorized`, `PostBond`, `RequestBondWithdrawal`,
///        `WithdrawBond`, `UpdateAuthDatum`, `SlashBond`)
///   - Withdraw                    → zero-withdrawal trigger that
///       Compound/BatchProcess/etc. require; passes only if a matching
///       spend is present in the same TX.
///   - Else                        → fail
///
/// Compile-time anchored to (governance_nft_policy, governance_nft_name)
/// so UpdateAuthDatum + SlashBond authorization checks the real Gov NFT.

use aiken/collection/list
use aiken/interval.{Finite}
use cardano/address.{Credential, Script, VerificationKey}
use cardano/assets.{lovelace_of}
use cardano/certificate.{Certificate, UnregisterCredential}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}
use vault/constants.{
  bond_withdrawal_cooldown_ms, keeper_auth_update_cooldown_ms,
  keeper_cooldown_ms_max, keeper_cooldown_ms_min, max_authorized_keepers,
  min_keeper_bond,
}
use vault/helpers.{
  is_gov_authorized, payload_hash_deregister_stake, payload_hash_slash_bond,
  payload_hash_update_keeper_auth,
}
use vault/types.{
  ActDeregisterStake, ActSlashBond, ActUpdateKeeperAuth, GovernanceOnly,
  KeeperAuthDatum, KeeperAuthRedeemer, KeeperBond, Mixed, PermissionlessWithBond,
  PostBond, RegistrationMode, RequestBondWithdrawal, SlashBond, UpdateAuthDatum,
  WithdrawAsAuthorized, WithdrawBond,
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

/// Active keeper set: GovernanceOnly → authorized_pkhs only,
/// Mixed → authorized_pkhs ++ unblocked active_bonds,
/// PermissionlessWithBond → unblocked active_bonds only.
fn active_keeper_set(auth: KeeperAuthDatum) -> List<ByteArray> {
  let bonded =
    list.filter_map(
      auth.active_bonds,
      fn(b) {
        when b.withdrawal_requested_at is {
          None -> Some(b.bond_owner)
          _ -> None
        }
      },
    )
  when auth.registration_mode is {
    GovernanceOnly -> auth.authorized_pkhs
    Mixed -> list.concat(auth.authorized_pkhs, bonded)
    PermissionlessWithBond -> bonded
  }
}

/// Time-derived primary keeper. With single-keeper sets the primary is
/// always that one; with N keepers it rotates weekly per spec/keeper-auth.md §4.2.
fn current_primary_pkh(
  auth: KeeperAuthDatum,
  now_ms: Int,
) -> Option<ByteArray> {
  let set = active_keeper_set(auth)
  let n = list.length(set)
  if n == 0 {
    None
  } else {
    let elapsed = now_ms - auth.rotation_epoch_start_ms
    let slot = elapsed / auth.rotation_period_ms
    let idx = ( slot % n + n ) % n
    list.at(set, idx)
  }
}

fn datum_static_fields_eq(a: KeeperAuthDatum, b: KeeperAuthDatum) -> Bool {
  and {
    a.governance_policy == b.governance_policy,
    a.governance_name == b.governance_name,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Validator
// ─────────────────────────────────────────────────────────────────────

validator keeper_stake_script(
  governance_nft_policy: ByteArray,
  governance_nft_name: ByteArray,
) {
  spend(
    datum: Option<KeeperAuthDatum>,
    redeemer: KeeperAuthRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) {
    expect Some(auth) = datum
    expect Some(own_input) =
      list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
    expect Script(own_hash) = own_input.output.address.payment_credential
    expect Some(cont_output) = find_continuing(tx.outputs, own_hash)
    expect InlineDatum(new_data) = cont_output.datum
    expect new_auth: KeeperAuthDatum = new_data

    let identity_ok = datum_static_fields_eq(auth, new_auth)

    when redeemer is {
      // ══════════════════════════════════════════════════════
      // WithdrawAsAuthorized — authorize a vault keeper TX
      // ══════════════════════════════════════════════════════
      WithdrawAsAuthorized { keeper_pkh } -> {
        let signed = list.has(tx.extra_signatories, keeper_pkh)
        let in_active_set = list.has(active_keeper_set(auth), keeper_pkh)

        // Zero-withdraw against own credential must be present
        let zero_withdraw =
          list.any(
            tx.withdrawals,
            fn(pair) {
              let Pair(cred, amount) = pair
              cred == Script(own_hash) && amount == 0
            },
          )

        expect Finite(now) = tx.validity_range.lower_bound.bound_type

        // Primary / failover gate (only meaningful with ≥2 keepers)
        let set = active_keeper_set(auth)
        let primary_ok =
          when current_primary_pkh(auth, now) is {
            Some(primary) ->
              if list.length(set) <= 1 || keeper_pkh == primary {
                True
              } else {
                now - auth.last_successful_tx_at >= auth.failover_window_ms
              }
            None -> False
          }

        // Continuing UTXO updates last_successful_tx_at + nonce; all else preserved
        let valid_datum = and {
            new_auth.registration_mode == auth.registration_mode,
            new_auth.authorized_pkhs == auth.authorized_pkhs,
            new_auth.active_bonds == auth.active_bonds,
            new_auth.bond_amount_required == auth.bond_amount_required,
            new_auth.last_config_update_time == auth.last_config_update_time,
            new_auth.cooldown_ms == auth.cooldown_ms,
            new_auth.max_authorized_count == auth.max_authorized_count,
            new_auth.rotation_epoch_start_ms == auth.rotation_epoch_start_ms,
            new_auth.rotation_period_ms == auth.rotation_period_ms,
            new_auth.failover_window_ms == auth.failover_window_ms,
            new_auth.last_successful_tx_at == now,
            new_auth.nonce == auth.nonce + 1,
          }

        // Lovelace preservation (bond pool)
        let lovelace_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)

        and {
          identity_ok,
          signed,
          in_active_set,
          zero_withdraw,
          primary_ok,
          valid_datum,
          lovelace_ok,
        }
      }

      // ══════════════════════════════════════════════════════
      // PostBond — register as keeper via bond
      // ══════════════════════════════════════════════════════
      PostBond { bond_owner } -> {
        let mode_ok =
          when auth.registration_mode is {
            GovernanceOnly -> False
            _ -> True
          }
        let signed = list.has(tx.extra_signatories, bond_owner)
        let no_duplicate =
          !list.any(auth.active_bonds, fn(b) { b.bond_owner == bond_owner })

        expect Finite(upper) = tx.validity_range.upper_bound.bound_type
        let new_bond =
          KeeperBond {
            bond_owner,
            bond_amount: auth.bond_amount_required,
            posted_at: upper,
            withdrawal_requested_at: None,
          }

        let valid_datum = and {
            new_auth.registration_mode == auth.registration_mode,
            new_auth.authorized_pkhs == auth.authorized_pkhs,
            new_auth.active_bonds == list.push(auth.active_bonds, new_bond),
            new_auth.bond_amount_required == auth.bond_amount_required,
            new_auth.last_config_update_time == auth.last_config_update_time,
            new_auth.cooldown_ms == auth.cooldown_ms,
            new_auth.max_authorized_count == auth.max_authorized_count,
            new_auth.rotation_epoch_start_ms == auth.rotation_epoch_start_ms,
            new_auth.rotation_period_ms == auth.rotation_period_ms,
            new_auth.failover_window_ms == auth.failover_window_ms,
            new_auth.last_successful_tx_at == auth.last_successful_tx_at,
            new_auth.nonce == auth.nonce + 1,
          }

        // Continuing UTXO must absorb the bond's lovelace
        let lovelace_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value) + auth.bond_amount_required

        and {
          identity_ok,
          mode_ok,
          signed,
          no_duplicate,
          valid_datum,
          lovelace_ok,
        }
      }

      // ══════════════════════════════════════════════════════
      // RequestBondWithdrawal — start 30-day unstake cooldown
      // ══════════════════════════════════════════════════════
      RequestBondWithdrawal { bond_owner } -> {
        let signed = list.has(tx.extra_signatories, bond_owner)
        expect Finite(upper) = tx.validity_range.upper_bound.bound_type

        let new_bonds =
          list.map(
            auth.active_bonds,
            fn(b) {
              if b.bond_owner == bond_owner {
                KeeperBond { ..b, withdrawal_requested_at: Some(upper) }
              } else {
                b
              }
            },
          )

        let target_was_active =
          list.any(
            auth.active_bonds,
            fn(b) {
              and {
                b.bond_owner == bond_owner,
                b.withdrawal_requested_at == None,
              }
            },
          )

        let valid_datum = and {
            new_auth.registration_mode == auth.registration_mode,
            new_auth.authorized_pkhs == auth.authorized_pkhs,
            new_auth.active_bonds == new_bonds,
            new_auth.bond_amount_required == auth.bond_amount_required,
            new_auth.last_config_update_time == auth.last_config_update_time,
            new_auth.cooldown_ms == auth.cooldown_ms,
            new_auth.max_authorized_count == auth.max_authorized_count,
            new_auth.rotation_epoch_start_ms == auth.rotation_epoch_start_ms,
            new_auth.rotation_period_ms == auth.rotation_period_ms,
            new_auth.failover_window_ms == auth.failover_window_ms,
            new_auth.last_successful_tx_at == auth.last_successful_tx_at,
            new_auth.nonce == auth.nonce + 1,
          }

        let lovelace_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)

        and {
          identity_ok,
          signed,
          target_was_active,
          valid_datum,
          lovelace_ok,
        }
      }

      // ══════════════════════════════════════════════════════
      // WithdrawBond — refund bond after 30d cooldown
      // ══════════════════════════════════════════════════════
      WithdrawBond { bond_owner } -> {
        let signed = list.has(tx.extra_signatories, bond_owner)
        expect Some(target) =
          list.find(auth.active_bonds, fn(b) { b.bond_owner == bond_owner })
        expect Some(req_at) = target.withdrawal_requested_at
        expect Finite(now) = tx.validity_range.lower_bound.bound_type
        let cooldown_ok = now - req_at >= bond_withdrawal_cooldown_ms

        // Refund lovelace to bond_owner's wallet
        let refund_ok =
          list.any(
            tx.outputs,
            fn(out) {
              when out.address.payment_credential is {
                VerificationKey(pkh) ->
                  pkh == bond_owner && lovelace_of(out.value) >= target.bond_amount
                _ -> False
              }
            },
          )

        let new_bonds =
          list.filter(auth.active_bonds, fn(b) { b.bond_owner != bond_owner })

        let valid_datum = and {
            new_auth.registration_mode == auth.registration_mode,
            new_auth.authorized_pkhs == auth.authorized_pkhs,
            new_auth.active_bonds == new_bonds,
            new_auth.bond_amount_required == auth.bond_amount_required,
            new_auth.last_config_update_time == auth.last_config_update_time,
            new_auth.cooldown_ms == auth.cooldown_ms,
            new_auth.max_authorized_count == auth.max_authorized_count,
            new_auth.rotation_epoch_start_ms == auth.rotation_epoch_start_ms,
            new_auth.rotation_period_ms == auth.rotation_period_ms,
            new_auth.failover_window_ms == auth.failover_window_ms,
            new_auth.last_successful_tx_at == auth.last_successful_tx_at,
            new_auth.nonce == auth.nonce + 1,
          }

        let lovelace_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value) - target.bond_amount

        and {
          identity_ok,
          signed,
          cooldown_ok,
          refund_ok,
          valid_datum,
          lovelace_ok,
        }
      }

      // ══════════════════════════════════════════════════════
      // UpdateAuthDatum — governance updates rules
      // ══════════════════════════════════════════════════════
      UpdateAuthDatum { new_datum } -> {
        // H-1: payload-hash binding — governance commits to exact new
        // KeeperAuthDatum at queue time.
        let new_datum_data: Data = new_datum
        let expected_payload_hash = payload_hash_update_keeper_auth(new_datum_data)
        let governance_authorized =
          is_gov_authorized(
            tx,
            governance_nft_policy,
            governance_nft_name,
            ActUpdateKeeperAuth,
            expected_payload_hash,
            own_hash,
          )
        expect Finite(now) = tx.validity_range.lower_bound.bound_type
        let cooldown_ok =
          now - auth.last_config_update_time >= keeper_auth_update_cooldown_ms

        // L-6 fix: removed redundant `max_authorized_count <= gov_max_signers + 13`
        // check (line 367 already enforces <= max_authorized_keepers == 20).
        let bounds_ok = and {
            list.length(new_datum.authorized_pkhs) <= new_datum.max_authorized_count,
            new_datum.max_authorized_count <= max_authorized_keepers,
            new_datum.bond_amount_required >= min_keeper_bond,
            new_datum.cooldown_ms >= keeper_cooldown_ms_min,
            new_datum.cooldown_ms <= keeper_cooldown_ms_max,
            new_datum.rotation_period_ms >= 86_400_000,
            new_datum.rotation_period_ms <= 30 * 86_400_000,
            new_datum.failover_window_ms >= 600_000,
            new_datum.failover_window_ms <= 7_200_000,
          }

        // Bonds: governance cannot mutate them directly
        let bonds_ok = new_datum.active_bonds == auth.active_bonds

        // Identity preserved
        let identity_ok2 = and {
            new_datum.governance_policy == auth.governance_policy,
            new_datum.governance_name == auth.governance_name,
          }

        // Re-anchor rotation epoch on auth set change OR mode-toggle into permissionless
        let auth_set_changed = new_datum.authorized_pkhs != auth.authorized_pkhs
        let mode_changed_perm = mode_touches_permissionless(
          auth.registration_mode,
          new_datum.registration_mode,
        )
        let rotation_anchor_ok =
          if auth_set_changed || mode_changed_perm {
            new_datum.rotation_epoch_start_ms == now
          } else {
            new_datum.rotation_epoch_start_ms == auth.rotation_epoch_start_ms
          }

        // last_config_update_time + nonce
        let time_ok = new_datum.last_config_update_time == now
        let nonce_ok = new_datum.nonce == auth.nonce + 1
        let last_tx_ok = new_datum.last_successful_tx_at == auth.last_successful_tx_at

        // Continuing output's datum equals new_datum exactly
        let new_eq = new_auth == new_datum

        let lovelace_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value)

        and {
          governance_authorized,
          cooldown_ok,
          bounds_ok,
          bonds_ok,
          identity_ok2,
          rotation_anchor_ok,
          time_ok,
          nonce_ok,
          last_tx_ok,
          new_eq,
          lovelace_ok,
        }
      }

      // ══════════════════════════════════════════════════════
      // SlashBond — Phase 3+; not reachable at V1 launch (active_bonds == [])
      // ══════════════════════════════════════════════════════
      SlashBond { bond_owner, evidence_ref, slash_amount } -> {
        // H-1: payload-hash binding
        let expected_payload_hash =
          payload_hash_slash_bond(bond_owner, evidence_ref, slash_amount)
        let governance_authorized =
          is_gov_authorized(
            tx,
            governance_nft_policy,
            governance_nft_name,
            ActSlashBond,
            expected_payload_hash,
            own_hash,
          )
        expect Some(target) =
          list.find(auth.active_bonds, fn(b) { b.bond_owner == bond_owner })
        let amount_ok = slash_amount > 0 && slash_amount <= target.bond_amount

        // Continuing UTXO loses the slash_amount lovelace; treasury TX
        // (executed in same TX) absorbs it via its own Receive-style path.
        let lovelace_ok =
          lovelace_of(cont_output.value) >= lovelace_of(own_input.output.value) - slash_amount

        let new_bonds =
          list.filter(auth.active_bonds, fn(b) { b.bond_owner != bond_owner })

        let valid_datum = and {
            new_auth.registration_mode == auth.registration_mode,
            new_auth.authorized_pkhs == auth.authorized_pkhs,
            new_auth.active_bonds == new_bonds,
            new_auth.bond_amount_required == auth.bond_amount_required,
            new_auth.last_config_update_time == auth.last_config_update_time,
            new_auth.cooldown_ms == auth.cooldown_ms,
            new_auth.max_authorized_count == auth.max_authorized_count,
            new_auth.rotation_epoch_start_ms == auth.rotation_epoch_start_ms,
            new_auth.rotation_period_ms == auth.rotation_period_ms,
            new_auth.failover_window_ms == auth.failover_window_ms,
            new_auth.last_successful_tx_at == auth.last_successful_tx_at,
            new_auth.nonce == auth.nonce + 1,
          }

        and {
          identity_ok,
          governance_authorized,
          amount_ok,
          lovelace_ok,
          valid_datum,
        }
      }
    }
  }

  // Withdraw branch — A-Plain enforcement (internal review 2026-04-20).
  //
  // `spec/keeper-auth.md` §A-Plain requires every keeper TX to spend the
  // single keeper_auth UTxO so that keeper_stake_script's own spend
  // handler runs the real authorization checks (signer ∈ authorized_pkhs,
  // primary rotation / failover, nonce bump, last_successful_tx_at
  // update). Pre-review the check here was just "some script input with
  // inline datum exists", which the vault UTxO satisfies trivially —
  // making the A-Plain commitment a no-op. Fixed by requiring at least
  // one input at *this* validator's own script address (i.e., a
  // keeper_auth UTxO), which forces the spend handler to run.
  withdraw(_redeemer: Data, credential: Credential, tx: Transaction) {
    expect Script(own_hash) = credential
    list.any(
      tx.inputs,
      fn(input) {
        when input.output.address.payment_credential is {
          Script(hash) -> hash == own_hash
          _ -> False
        }
      },
    )
  }

  /// A2 gov-gated stake deregister (2026-04-20). Reuses the validator's
  /// existing compile-time (governance_nft_policy, governance_nft_name)
  /// params — no new anchors needed. Matches the publish handlers on
  /// vault_protocol / vault_liqwid / vault_gov_policy / vault_gov_emergency.
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
    fail @"keeper_stake_script: unsupported purpose"
  }
}

// ─────────────────────────────────────────────────────────────────────
// Mode-touch helper — returns True when the mode change involves
// PermissionlessWithBond on either side.
// ─────────────────────────────────────────────────────────────────────

fn mode_touches_permissionless(
  old: RegistrationMode,
  new: RegistrationMode,
) -> Bool {
  let old_perm =
    when old is {
      PermissionlessWithBond -> True
      _ -> False
    }
  let new_perm =
    when new is {
      PermissionlessWithBond -> True
      _ -> False
    }
  old_perm != new_perm
}
