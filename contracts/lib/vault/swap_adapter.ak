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
///   2. The `min_receive`, `target_asset_policy`, `target_asset_name`
///      in the redeemer match the decoded DEX datum.
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
///   6. (Optional) If registry.asset_oracles has an entry for
///      `(redeemer.target_asset_policy, redeemer.target_asset_name)`,
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
use cardano/address.{Script}
use cardano/transaction.{Transaction, Withdraw}
use vault/oracle.{check_tier1_bound, find_asset_oracle}
use vault/types.{AssetOracleEntry}

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
  /// Policy id of the asset this swap produces. Adapter MUST verify
  /// this matches the decoded DEX datum's target asset (typically
  /// derived from the pool's lp_asset + direction flag for SwapExactIn
  /// or the final hop for SwapMultiRouting).
  /// ADA convention: policy == #"".
  target_asset_policy: ByteArray,
  /// Asset name under `target_asset_policy`. ADA: name == #"".
  target_asset_name: ByteArray,
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
  expected_dest_idx: Int,
  deploy_amount: Int,
  min_swap_peg_bps: Int,
  max_slippage_bps: Int,
) -> Bool {
  when find_single_adapter_invocation(tx, adapter_hashes) is {
    Some(adapter_hash) ->
      when read_adapter_redeemer(tx, adapter_hash) is {
        Some(adapter_r) -> and {
            adapter_r.dest_output_idx == expected_dest_idx,
            check_peg_floor(
              deploy_amount,
              adapter_r.min_receive,
              min_swap_peg_bps,
            ),
            when find_asset_oracle(
              asset_oracles,
              adapter_r.target_asset_policy,
              adapter_r.target_asset_name,
            ) is {
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
        None -> False
      }
    None -> False
  }
}
