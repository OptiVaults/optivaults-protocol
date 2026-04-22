/// vault_proxy — Withdraw-Zero Forwarding entry point
///
/// Thin spending validator that holds the canonical vault UTXO and
/// forwards execution to one of ten staking validators
/// (vault_user / vault_keeper_hot / vault_batcher / vault_swap_ada /
///  vault_protocol / vault_recall / vault_liqwid / vault_gov_policy /
///  vault_gov_emergency / vault_admin_deploy) via a zero-amount
/// withdrawal entry. The staking validator runs the actual redeemer
/// logic in the same transaction.
///
/// Per spec/architecture.md §6, vault_proxy itself does NOT contain
/// any redeemer-specific business logic — it only enforces structural
/// invariants:
///   1. The selected staking validator's zero-withdrawal is present.
///   2. Exactly one of the ten vault staking validators is invoked
///      per TX (no double-routing).
///   3. The Vault Identity NFT (compile-time anchored) is present in
///      the input AND continuing output, except for the full-drain
///      branch where vault_user's Withdraw destroys the NFT.
///   4. No "phantom" VaultDatum exists at any other script input
///      (phantom-vault family, internal verification — closed at the proxy layer rather than relying on
///      each staking validator to re-check).
///
/// `vault_nft_policy` is a compile-time parameter — never read from
/// datum — so attacker-crafted fake VaultDatum UTXOs that declare
/// their own policy ID cannot pass `has_vault_nft`.
///
/// V1 split history:
///   - vault_admin was first extracted from vault_protocol when the
///     latter approached the 16 KB Plutus V3 ref-script ceiling.
///   - vault_admin was then further split into vault_gov_policy +
///     vault_gov_emergency (2026-04-21, §5.4 on-chain slippage
///     enforcement Phase 1) to make room for UpdateSlippagePolicy
///     while preserving semantic separation between slow deliberate
///     policy changes (14-21d timelock) and emergency/recovery paths.
///   - vault_core was split into vault_user + vault_keeper_hot
///     (2026-04-22 Phase 77, whitepaper §9.4) to free headroom for A2
///     `publish` handlers (ActDeregisterStake) on both halves so the
///     2 ADA Cardano stake-registration deposit becomes reclaimable.
///     Authorization boundary: vault_user holds Deposit / Withdraw /
///     BatchProcess (user path + mint/burn orchestration); vault_
///     keeper_hot holds Compound / RebalanceBuffer / SwapAda (keeper
///     hot path). All vUSDCx mint/burn remain on vault_user so the
///     vusdcx.ak minting policy binds to a single spend-authority.
///   - vault_protocol was split into vault_protocol + vault_recall
///     (2026-04-22 Phase 77) to reclaim bytecode headroom after the
///     SwapAdapter dispatch + Tier 1 oracle wire-up.
///   - SwapAda was extracted from vault_keeper_hot into a standalone
///     `vault_swap_ada` staking validator (2026-04-22 Phase 77b). The
///     §5.4 P5 dual-feed oracle reader + registry 6-tuple read were
///     ~4-5 KB used only by SwapAda; hoisting them out restores
///     headroom on Compound's host.
///   - AdminDeployNonDeposit was extracted from vault_gov_emergency
///     into a standalone `vault_admin_deploy` staking validator
///     (2026-04-22 Phase 77c). The SwapAdapter dispatch +
///     destination-whitelist check + 6-tuple registry read were
///     ~6-7 KB used only by AdminDeployNonDeposit; hoisting them out
///     restores headroom on EmergencyWithdraw's host and prevents
///     future SwapAdapter additions from growing the emergency-path
///     attack surface.
///   - BatchProcess was extracted from vault_user into a standalone
///     `vault_batcher` staking validator (2026-04-22 Phase 77d). The
///     4 fold loops + OrderDatum/OrderRedeemer decode + list.unique
///     + R51/R52 anti-leak invariants were ~9-11 KB used only by
///     BatchProcess; hoisting them out restores headroom on
///     vault_user, which also sheds its `keeper_stake_hash` compile-
///     time parameter (Deposit + Withdraw are permissionless).
///
/// vault_proxy now carries 11 compile-time parameters (10 stake hashes +
/// vault_nft_policy).

use aiken/collection/list
use cardano/address.{Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, OutputReference, Transaction}
use vault/constants.{vault_nft_token_name, vusdcx_token_name}
use vault/types.{VaultDatum}

pub type ProxyRedeemer {
  UseUser
  UseKeeperHot
  UseSwapAda
  UseProtocol
  UseRecall
  UseLiqwid
  UseGovPolicy
  UseGovEmergency
  UseAdminDeploy
  UseBatcher
}

validator vault_proxy(
  user_stake_hash: ByteArray,
  keeper_hot_stake_hash: ByteArray,
  swap_ada_stake_hash: ByteArray,
  protocol_stake_hash: ByteArray,
  recall_stake_hash: ByteArray,
  liqwid_stake_hash: ByteArray,
  gov_policy_stake_hash: ByteArray,
  gov_emergency_stake_hash: ByteArray,
  admin_deploy_stake_hash: ByteArray,
  batcher_stake_hash: ByteArray,
  vault_nft_policy: ByteArray,
) {
  spend(
    datum: Option<VaultDatum>,
    redeemer: ProxyRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) {
    when datum is {
      Some(_) -> {
        // Primary vault UTXO branch — InlineDatum present.
        let target_hash =
          when redeemer is {
            UseUser -> user_stake_hash
            UseKeeperHot -> keeper_hot_stake_hash
            UseSwapAda -> swap_ada_stake_hash
            UseProtocol -> protocol_stake_hash
            UseRecall -> recall_stake_hash
            UseLiqwid -> liqwid_stake_hash
            UseGovPolicy -> gov_policy_stake_hash
            UseGovEmergency -> gov_emergency_stake_hash
            UseAdminDeploy -> admin_deploy_stake_hash
            UseBatcher -> batcher_stake_hash
          }

        let withdrawal_present =
          list.any(
            tx.withdrawals,
            fn(pair) {
              let Pair(cred, amount) = pair
              cred == Script(target_hash) && amount == 0
            },
          )

        // Reject TXs that try to invoke more than one of the ten vault
        // staking validators in the same TX (would otherwise allow
        // smuggling Compound + DeployToProtocol, etc., into one TX).
        let withdrawal_count =
          list.foldl(
            tx.withdrawals,
            0,
            fn(pair, acc) {
              let Pair(cred, _) = pair
              if or {
                cred == Script(user_stake_hash),
                cred == Script(keeper_hot_stake_hash),
                cred == Script(swap_ada_stake_hash),
                cred == Script(protocol_stake_hash),
                cred == Script(recall_stake_hash),
                cred == Script(liqwid_stake_hash),
                cred == Script(gov_policy_stake_hash),
                cred == Script(gov_emergency_stake_hash),
                cred == Script(admin_deploy_stake_hash),
                cred == Script(batcher_stake_hash),
              } {
                acc + 1
              } else {
                acc
              }
            },
          )

        expect Some(own_input) =
          list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
        expect Some(vault_datum) = datum

        // Full-drain detection: a Withdraw that burns ALL outstanding
        // shares may legitimately produce no continuing vault output
        // (vault_user enforces full-drain rules including Vault NFT burn).
        let is_full_drain = {
          expect vault_datum.vusdcx_policy != #""
          let mint_qty =
            quantity_of(tx.mint, vault_datum.vusdcx_policy, vusdcx_token_name)
          and {
            mint_qty == -vault_datum.total_shares,
            vault_datum.total_shares > 0,
          }
        }

        // Phantom-vault defense: no other script input may carry a
        // VaultDatum-shaped inline datum at any address. (Internal-verification-era phantom-vault closure.)
        expect Some(own_hash) =
          when own_input.output.address.payment_credential is {
            Script(h) -> Some(h)
            _ -> None
          }
        let other_vault_datums =
          list.foldl(
            tx.inputs,
            0,
            fn(input, acc) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  if hash != own_hash {
                    when input.output.datum is {
                      InlineDatum(data) ->
                        if data is VaultDatum { vault_version, .. }: VaultDatum {
                          if vault_version >= 0 {
                            acc + 1
                          } else {
                            acc
                          }
                        } else {
                          acc
                        }
                      _ -> acc
                    }
                  } else {
                    acc
                  }
                _ -> acc
              }
            },
          )
        let no_foreign_vault_datum = other_vault_datums == 0

        // Vault Identity NFT must be present in the spent input under
        // the compile-time-anchored policy.
        let has_vault_nft =
          quantity_of(own_input.output.value, vault_nft_policy, vault_nft_token_name) == 1

        // Continuing output (same script address) must also carry the
        // NFT, except in the full-drain case where the vault is being
        // destroyed and the NFT is burned in the same TX.
        let has_continuing_output =
          is_full_drain || list.any(
            tx.outputs,
            fn(output) {
              and {
                output.address == own_input.output.address,
                quantity_of(output.value, vault_nft_policy, vault_nft_token_name) == 1,
              }
            },
          )

        and {
          withdrawal_present,
          withdrawal_count == 1,
          has_continuing_output,
          no_foreign_vault_datum,
          has_vault_nft,
        }
      }

      None -> {
        // NoDatum secondary UTXO — being consumed by MergeUtxo or
        // EmergencyWithdraw. Verify a primary VaultDatum input from
        // the same proxy is also being spent in this TX, and that one
        // of the six vault staking validators is invoked.
        expect Some(own_input) =
          list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
        expect Script(own_hash) = own_input.output.address.payment_credential

        let vault_count =
          list.foldl(
            tx.inputs,
            0,
            fn(input, acc) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  if hash == own_hash {
                    acc + 1
                  } else {
                    acc
                  }
                _ -> acc
              }
            },
          )
        expect vault_count >= 2
        expect vault_count <= 5

        let has_primary =
          list.any(
            tx.inputs,
            fn(input) {
              when input.output.address.payment_credential is {
                Script(hash) ->
                  if hash == own_hash && input.output_reference != own_ref {
                    when input.output.datum is {
                      InlineDatum(data) ->
                        if data is VaultDatum { .. }: VaultDatum {
                          True
                        } else {
                          False
                        }
                      _ -> False
                    }
                  } else {
                    False
                  }
                _ -> False
              }
            },
          )

        let has_authorized_withdrawal =
          list.any(
            tx.withdrawals,
            fn(pair) {
              let Pair(cred, _) = pair
              or {
                cred == Script(user_stake_hash),
                cred == Script(keeper_hot_stake_hash),
                cred == Script(swap_ada_stake_hash),
                cred == Script(protocol_stake_hash),
                cred == Script(recall_stake_hash),
                cred == Script(liqwid_stake_hash),
                cred == Script(gov_policy_stake_hash),
                cred == Script(gov_emergency_stake_hash),
                cred == Script(admin_deploy_stake_hash),
                cred == Script(batcher_stake_hash),
              }
            },
          )

        and {
          has_primary,
          has_authorized_withdrawal,
        }
      }
    }
  }

  else(_) {
    fail @"vault_proxy: unsupported purpose"
  }
}
