/// SwapAdapter interface — §B@launch=1 ref-script dispatched DEX adapter.
///
/// A SwapAdapter is a PlutusV3 staking validator implementing a single
/// `withdraw` handler. It is invoked by `vault_protocol.DeployToProtocol`
/// (and `vault_gov_emergency.AdminDeployNonDeposit`) via a zero-amount
/// withdrawal, at which point the ledger runs the adapter's `withdraw`
/// and verifies:
///
///   1. The dest output at `redeemer.dest_output_idx` carries a valid
///      order datum for THIS adapter's target DEX.
///   2. The `min_receive` and `hop_chain` in the redeemer match the
///      decoded DEX datum (hop_chain LP-name re-hash: hop_chain is a list of
///      `(policy, name)` pairs committing the routing topology
///      asset-by-asset; each on-chain routing hop's LP name must
///      re-hash to the canonical formula of the matching chain pair).
///
/// vault_protocol (the caller) then:
///
///   1. Reads registry.swap_adapter_hashes.
///   2. Verifies the adapter invoked is in the whitelist.
///   3. Reads the adapter's redeemer via
///      `pairs.get_first(tx.redeemers, Withdraw(Script(adapter_hash)))`.
///   4. Verifies `redeemer.dest_output_idx` == own redeemer's
///      `dest_output_idx`.
///   5. Applies Tier 2 peg-floor on `redeemer.min_receive` vs
///      `deploy_amount * min_swap_peg_bps`.
///   6. (Optional) If registry.asset_oracles has an entry for the
///      target asset (derived from `last_hop_target(redeemer.hop_chain)`),
///      applies Tier 1 fair-price bound via `oracle.check_tier1_bound`.
///
/// Policy separation: adapter decodes DEX-specific datum (DEX-format
/// trust boundary); vault_protocol enforces V1 policy bounds (peg-
/// floor + optional oracle). Adapters are per-DEX; vault_protocol is
/// DEX-agnostic. Governance maintains the whitelist of approved
/// adapters via `UpdateRegistry` (14-day timelock + 1-of-n cancel).
///
/// Adding a new DEX post-launch:
///   1. Third party develops + audits a new `*_adapter.ak` validator.
///   2. Deploys its PlutusV3 reference script to mainnet.
///   3. Governance queues `UpdateRegistry` adding the new adapter's
///      script hash to `swap_adapter_hashes`.
///   4. 14-day observation window + 1-of-n cancel veto.
///   5. Governance executes → adapter is active; keeper can route to
///      the new DEX without any V1 vault redeploy.
///
/// This is the cornerstone architectural choice that makes V1
/// multi-DEX-extensible without forcing depositor migration.

use aiken/collection/list
use aiken/collection/pairs
use cardano/address.{Address, Script}
use cardano/transaction.{Transaction, Withdraw}
use vault/oracle.{check_tier1_bound, find_asset_oracle}
use vault/types.{AssetOracleEntry, StableTokenEntry}

// ─────────────────────────────────────────────────────────────────────
// Adapter redeemer shape
// ─────────────────────────────────────────────────────────────────────

pub type SwapAdapterRedeemer {
  /// Index into `tx.outputs` identifying the DEX order UTXO this
  /// adapter is validating.
  dest_output_idx: Int,
  /// Minimum receive amount the order commits to. Adapter MUST
  /// verify this matches the decoded DEX datum's `minimum_receive`
  /// field; callers (vault_protocol) apply peg-floor on this value.
  min_receive: Int,
  /// Asset chain: `[asset_in, mid_1, mid_2, ..., target_out]`. For a
  /// single-hop SwapExactIn this has exactly 2 entries (`[in, target]`);
  /// for an N-hop SwapMultiRouting it has N+1 entries, one per pool
  /// boundary.
  ///
  /// **Security rationale (hop_chain LP-name re-hash)**: Minswap V2 order datum's
  /// `lp_asset` field is a single LP token identifier
  /// `(LP_policy, LP_name)` — NOT a 2-asset pair. The target asset
  /// cannot be derived from the order datum alone.
  ///
  /// The adapter re-computes the expected Minswap V2 LP name from each
  /// consecutive `(hop_chain[i], hop_chain[i+1])` pair and verifies it
  /// matches the on-chain routing's lp_asset name. This binds the
  /// routing topology + final target asset to what governance / the
  /// adapter witness committed — a compromised keeper cannot route to
  /// an arbitrary non-whitelisted target.
  ///
  /// Each entry is `(policy_id, asset_name)`. ADA: `(#"", #"")`.
  /// `hop_chain[0]` MUST equal the swap input asset; `hop_chain[last]`
  /// is the target asset callers expose for oracle + peg-floor checks.
  hop_chain: List<(ByteArray, ByteArray)>,
  /// **Security rationale (SwapAdapter recipient-address binding)**: Minswap V2 OrderDatum carries
  /// a `success_addr` (where swap output lands on fill) and `refund_addr`
  /// (where funds return on cancel/expire) that, prior to this fix, were
  /// not constrained by V1 contracts — `verify_destination_whitelisted`
  /// only checked the order script address, leaving the order datum's
  /// internal routing fields completely unvalidated. A compromised keeper
  /// (or post-sunset permissionless caller) could set both fields to an
  /// attacker wallet and direct-drain the vault at slippage rate.
  ///
  /// This field commits the recipient address that the adapter MUST
  /// verify against the DEX order datum's success_addr AND refund_addr.
  /// vault_protocol / vault_admin_deploy enforce
  /// `expected_recipient_addr == own_input.output.address` so the
  /// recipient is always the vault itself; the adapter forces the order
  /// datum to match. Both layers must agree — the keeper cannot bypass.
  expected_recipient_addr: Address,
}

// ─────────────────────────────────────────────────────────────────────
// Caller-side helpers (used by vault_protocol / vault_gov_emergency)
// ─────────────────────────────────────────────────────────────────────

/// Locate exactly ONE authorized adapter's zero-withdrawal in the TX.
///
/// Returns `Some(adapter_hash)` on clean match. Returns `None` if:
///   - No matching withdrawal
///   - More than one authorized adapter is invoked (double-routing)
///   - A withdrawal exists for an un-whitelisted script
///
/// The caller then uses the returned hash to look up the adapter's
/// redeemer via `read_adapter_redeemer`.
pub fn find_single_adapter_invocation(
  tx: Transaction,
  authorized_adapter_hashes: List<ByteArray>,
) -> Option<ByteArray> {
  // Pass 1: count withdrawals to authorized adapters + collect the
  // first one for the happy path.
  let (count, first_hash) =
    list.foldl(
      tx.withdrawals,
      (0, #""),
      fn(pair, acc) {
        let (n, h) = acc
        let Pair(cred, amount) = pair
        when cred is {
          Script(script_hash) ->
            if amount == 0 && list.has(authorized_adapter_hashes, script_hash) {
              if n == 0 {
                (1, script_hash)
              } else {
                (n + 1, h)
              }
            } else {
              (n, h)
            }
          _ -> (n, h)
        }
      },
    )
  if count == 1 {
    Some(first_hash)
  } else {
    None
  }
}

/// Read the adapter's SwapAdapterRedeemer from the TX's redeemer set.
/// Uses `pairs.get_first(tx.redeemers, Withdraw(Script(adapter_hash)))`.
/// Returns `None` if not found or the data doesn't decode.
pub fn read_adapter_redeemer(
  tx: Transaction,
  adapter_hash: ByteArray,
) -> Option<SwapAdapterRedeemer> {
  when pairs.get_first(tx.redeemers, Withdraw(Script(adapter_hash))) is {
    Some(r) ->
      if r is sr: SwapAdapterRedeemer {
        Some(sr)
      } else {
        None
      }
    None -> None
  }
}

/// Extract `hop_chain`'s final entry (target asset) — the asset the
/// swap produces. Returns `None` if the chain is empty.
pub fn last_hop_target(
  hop_chain: List<(ByteArray, ByteArray)>,
) -> Option<(ByteArray, ByteArray)> {
  when hop_chain is {
    [] -> None
    [only] -> Some(only)
    [_, ..rest] -> last_hop_target(rest)
  }
}

/// Structural sanity check on a hop_chain. Requires at least 2 entries
/// (input + output) and no adjacent duplicates (a no-op hop would
/// pass Minswap's LP name binding only by mapping to a dead pool).
pub fn hop_chain_well_formed(
  hop_chain: List<(ByteArray, ByteArray)>,
) -> Bool {
  when hop_chain is {
    [] -> False
    [_] -> False
    [a, b, ..rest] ->
      if a == b {
        False
      } else {
        hop_chain_non_adjacent_dup([b, ..rest])
      }
  }
}

fn hop_chain_non_adjacent_dup(xs: List<(ByteArray, ByteArray)>) -> Bool {
  when xs is {
    [] -> True
    [_] -> True
    [a, b, ..rest] ->
      if a == b {
        False
      } else {
        hop_chain_non_adjacent_dup([b, ..rest])
      }
  }
}

/// (2026-05-30): is `target` an allowed swap-out destination
/// asset? Allowed iff it is the deposit token (USDCx) or a registry-
/// whitelisted stable token. The Tier-2 peg-floor compares `min_receive`
/// (target-asset native units) to `deploy_amount` (USDCx micro-units) 1:1,
/// so any target whose per-unit value differs from USDCx slips past the
/// floor — an attacker-seeded junk-token pool could then absorb vault USDCx
/// for worthless units. This allowlist is the load-bearing bound (Tier-1
/// oracle is fail-open for targets with no oracle entry, which is the launch
/// state). Extracted as a pure predicate so it is unit-testable in
/// isolation.
pub fn swap_target_allowed(
  target_policy: ByteArray,
  target_name: ByteArray,
  stable_tokens: List<StableTokenEntry>,
  deposit_token_policy: ByteArray,
  deposit_token_name: ByteArray,
) -> Bool {
  or {
    target_policy == deposit_token_policy && target_name == deposit_token_name,
    list.any(
      stable_tokens,
      fn(st) { st.policy == target_policy && st.name == target_name },
    ),
  }
}

/// Tier 2 peg-floor on an adapter-committed `min_receive`.
///
///   min_receive × 10_000 >= deploy_amount × peg_bps
///
/// Typical V1 peg_bps = 9_500 (95%). Caller must independently verify
/// the adapter was invoked + is authorized + redeemer was read.
pub fn check_peg_floor(
  deploy_amount: Int,
  min_receive: Int,
  min_swap_peg_bps: Int,
) -> Bool {
  min_receive * 10_000 >= deploy_amount * min_swap_peg_bps
}

/// Composite verification used by vault_protocol.DeployToProtocol and
/// vault_gov_emergency.AdminDeployNonDeposit. Consolidates the whole
/// adapter dispatch + bound enforcement into a single function so
/// calling validators don't each inline 400-600 B of boilerplate.
///
/// Flow:
///   1. Find exactly one authorized adapter withdrawal (zero-amount).
///   2. Read that adapter's SwapAdapterRedeemer.
///   3. Verify adapter's dest_output_idx matches caller's expected idx
///      — anti-confusion guard between multiple DEX outputs.
///   4. Tier 2 peg-floor on adapter-committed min_receive.
///   5. Tier 1 (optional): if asset_oracles has an entry for the
///      adapter-committed target asset, apply oracle fair-price bound.
///
/// Returns True only if all steps pass. Single-call API keeps each
/// caller validator's bytecode lean.
pub fn verify_swap_via_adapter(
  tx: Transaction,
  adapter_hashes: List<ByteArray>,
  asset_oracles: List<AssetOracleEntry>,
  /// registry stable-token allowlist. The swap target
  /// (`hop_chain[last]`) MUST be the deposit token or one of these.
  stable_tokens: List<StableTokenEntry>,
  /// deposit-token identity (USDCx) — the other allowed target.
  deposit_token_policy: ByteArray,
  deposit_token_name: ByteArray,
  expected_dest_idx: Int,
  deploy_amount: Int,
  min_swap_peg_bps: Int,
  max_slippage_bps: Int,
  /// Recipient-address binding: caller's vault address. Adapter redeemer's
  /// `expected_recipient_addr` MUST equal this (caller-layer check); the
  /// adapter then validates the on-chain DEX order datum's
  /// success_addr + refund_addr equal the redeemer's value (adapter-
  /// layer check). Both layers must agree to pass — closes the direct
  /// drain vector where success_addr was previously unconstrained.
  expected_recipient_addr: Address,
) -> Bool {
  when find_single_adapter_invocation(tx, adapter_hashes) is {
    Some(adapter_hash) ->
      when read_adapter_redeemer(tx, adapter_hash) is {
        Some(adapter_r) -> and {
            adapter_r.dest_output_idx == expected_dest_idx,
            adapter_r.expected_recipient_addr == expected_recipient_addr,
            check_peg_floor(
              deploy_amount,
              adapter_r.min_receive,
              min_swap_peg_bps,
            ),
            when last_hop_target(adapter_r.hop_chain) is {
              Some((target_policy, target_name)) -> and {
                  // (2026-05-30): the swap target asset must be the
                  // deposit token (USDCx) or a registry-whitelisted stable
                  // token — see `swap_target_allowed`. Without this a
                  // compromised keeper (or post-sunset permissionless caller)
                  // could route vault value into an attacker-seeded junk-token
                  // pool (peg-floor satisfied in worthless units) and drain it.
                  swap_target_allowed(
                    target_policy,
                    target_name,
                    stable_tokens,
                    deposit_token_policy,
                    deposit_token_name,
                  ),
                  when find_asset_oracle(asset_oracles, target_policy, target_name) is {
                    Some(entry) ->
                      check_tier1_bound(
                        tx,
                        entry,
                        deploy_amount,
                        adapter_r.min_receive,
                        max_slippage_bps,
                      )
                    None -> True
                  },
                }
              // hop_chain LP-name re-hash: hop_chain must have >= 2 entries (in + target) for
              // a meaningful swap. Empty / single-asset hop_chain is rejected.
              None -> False
            },
            // hop_chain non-degeneracy: at least 2 entries, no duplicate
            // consecutive entries (protects against no-op swaps).
            hop_chain_well_formed(adapter_r.hop_chain),
          }
        None -> False
      }
    None -> False
  }
}
