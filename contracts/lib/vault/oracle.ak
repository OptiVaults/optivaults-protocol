/// Dual-feed oracle reader — §5.4 P3.
///
/// This module centralises the read-path for Tier 1 oracle-based fair-
/// price bounds used by:
///   - vault_protocol.DeployToProtocol (P4) — peg-floor on DEX swap
///     min_receive vs deploy_amount × oracle_fair_price.
///   - vault_keeper_hot.SwapAda (P5) — ADA-for-USDCx oracle bound.
///
/// Canonical V1 oracle datum format (InlineDatum on the feed UTXO):
///
///   PriceSample { price_bps: Int, timestamp_ms: Int }
///
/// Where price_bps = (asset_price_usdcx × 10_000). e.g. $1.00 DJED =
/// 10_000, $0.50 ADA = 5_000. Off-chain oracle operator is responsible
/// for aggregating Charli3 + Orcfax native feeds into this canonical
/// format and publishing as a reference UTXO. The operator identity
/// is an external trust boundary documented in `spec/security-model.md`.
///
/// Each oracle feed is pinned by (feed_script_hash, feed_auth_policy,
/// feed_auth_name) — the script hash narrows the search space, the auth
/// NFT prevents an attacker from publishing a decoy UTXO at the same
/// address. An `AssetOracleEntry` ties an asset (policy, name) to a list
/// of redundant feeds + staleness bound + cross-feed disagreement bound.
///
/// The reader protects against:
///   1. Missing oracle — caller must check `find_asset_oracle` returned
///      `Some` before calling `read_fair_price`.
///   2. Too few feeds — requires `entry.min_feeds` healthy feeds present.
///   3. Stale samples — any feed older than
///      `tx.validity_range.lower_bound - entry.max_staleness_ms` fails.
///   4. Cross-feed disagreement — spread between max and min sample
///      price_bps must be ≤ `entry.max_disagreement_bps`.
///   5. Zero / negative prices — rejected as degenerate.
///
/// Return value: the MIDPOINT of the min/max price_bps samples —
/// conservative choice that penalises neither side of a swap. (Median
/// not used because lists typically have 2 feeds so midpoint == median.)

use aiken/collection/list
use aiken/interval.{Finite}
use cardano/address.{Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, Input, Transaction}
use vault/types.{AssetOracleEntry, AssetOracleFeed, PriceSample}

// ─────────────────────────────────────────────────────────────────────
// Registry lookup
// ─────────────────────────────────────────────────────────────────────

/// Find the oracle entry for a given (policy, name) asset pair.
/// Returns `None` if the registry has no entry — caller decides
/// whether to fail closed (strict Tier 1) or fall back to Tier 2
/// peg-floor.
pub fn find_asset_oracle(
  asset_oracles: List<AssetOracleEntry>,
  asset_policy: ByteArray,
  asset_name: ByteArray,
) -> Option<AssetOracleEntry> {
  list.find(
    asset_oracles,
    fn(e) {
      e.asset_policy == asset_policy && e.asset_name == asset_name
    },
  )
}

// ─────────────────────────────────────────────────────────────────────
// Single-feed sample reading
// ─────────────────────────────────────────────────────────────────────

/// Locate the reference input for one feed + decode its PriceSample.
/// Returns `None` if the feed UTXO is missing, the auth NFT is absent,
/// or the inline datum doesn't decode to PriceSample.
pub fn find_feed_sample(
  ref_inputs: List<Input>,
  feed: AssetOracleFeed,
) -> Option<PriceSample> {
  let match =
    list.find(
      ref_inputs,
      fn(i) {
        when i.output.address.payment_credential is {
          Script(h) ->
            if h == feed.feed_script_hash {
              if feed.feed_auth_policy == #"" {
                True
              } else {
                quantity_of(
                  i.output.value,
                  feed.feed_auth_policy,
                  feed.feed_auth_name,
                ) >= 1
              }
            } else {
              False
            }
          _ -> False
        }
      },
    )
  when match is {
    Some(ri) ->
      when ri.output.datum is {
        InlineDatum(data) ->
          if data is ps: PriceSample {
            Some(ps)
          } else {
            None
          }
        _ -> None
      }
    None -> None
  }
}

// ─────────────────────────────────────────────────────────────────────
// Fair-price aggregation
// ─────────────────────────────────────────────────────────────────────

/// Collect all healthy samples (present + fresh) for an entry's feeds.
/// "Fresh" means `now - sample.timestamp_ms <= entry.max_staleness_ms`
/// where `now` is the TX's `validity_range.lower_bound` (finite).
fn collect_healthy_samples(
  tx: Transaction,
  entry: AssetOracleEntry,
) -> List<PriceSample> {
  when tx.validity_range.lower_bound.bound_type is {
    Finite(now) ->
      list.foldr(
        entry.feeds,
        [],
        fn(feed, acc) {
          when find_feed_sample(tx.reference_inputs, feed) is {
            Some(ps) ->
              if ps.price_bps > 0 && now - ps.timestamp_ms <= entry.max_staleness_ms {
                [ps, ..acc]
              } else {
                acc
              }
            None -> acc
          }
        },
      )
    _ -> []
  }
}

/// Min / max price_bps across a list of samples. Returns (0, 0) for
/// empty list — caller must check count first.
fn price_bps_extent(samples: List<PriceSample>) -> (Int, Int) {
  when samples is {
    [] -> (0, 0)
    [first, ..rest] ->
      list.foldl(
        rest,
        (first.price_bps, first.price_bps),
        fn(ps, acc) {
          let (lo, hi) = acc
          let new_lo = if ps.price_bps < lo { ps.price_bps } else { lo }
          let new_hi = if ps.price_bps > hi { ps.price_bps } else { hi }
          (new_lo, new_hi)
        },
      )
  }
}

/// Read the fair price for an asset. Returns `None` on ANY failure:
///   - fewer than entry.min_feeds healthy samples
///   - cross-feed spread exceeds entry.max_disagreement_bps
///   - degenerate (zero/negative) prices
///   - validity_range.lower_bound is not finite
///
/// On success, returns the midpoint of (min_price, max_price) in
/// asset/USDCx × 10_000 bps.
pub fn read_fair_price(
  tx: Transaction,
  entry: AssetOracleEntry,
) -> Option<Int> {
  let healthy = collect_healthy_samples(tx, entry)
  let count = list.length(healthy)
  if count < entry.min_feeds {
    None
  } else {
    let (lo, hi) = price_bps_extent(healthy)
    if lo <= 0 {
      None
    } else {
      let spread_bps =
        if lo == 0 { 0 } else { ( hi - lo ) * 10_000 / lo }
      if spread_bps > entry.max_disagreement_bps {
        None
      } else {
        // Midpoint — conservative vs median for 2-feed case (equivalent).
        Some(( lo + hi ) / 2)
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Tier 1 swap bound
// ─────────────────────────────────────────────────────────────────────

/// Tier 1 oracle-based fair-price bound for a DEX swap.
///
///   fair_out_amount = (amount_in × price_bps) / 10_000
///   acceptable_min_receive = fair_out_amount × (10_000 - slippage_bps) / 10_000
///
/// Returns True if `min_receive` is >= the computed acceptable bound.
/// Returns False on any oracle failure (missing entry, stale feed,
/// feed disagreement, etc.) — caller must then fall back to Tier 2
/// (peg-floor on stablecoin output) or abort the swap entirely.
///
/// Usage pattern in P4 (DeployToProtocol):
///
///   let tier1_ok = check_tier1_bound(tx, oracle_entry, deploy_amount,
///                                     min_receive, vault.max_slippage_bps)
///   let tier2_ok = min_receive * 10_000 >= deploy_amount * vault.min_swap_peg_bps
///   let swap_ok = tier1_ok || (tier2_ok && entry_is_stablecoin)
pub fn check_tier1_bound(
  tx: Transaction,
  entry: AssetOracleEntry,
  amount_in: Int,
  min_receive: Int,
  max_slippage_bps: Int,
) -> Bool {
  when read_fair_price(tx, entry) is {
    Some(price_bps) -> {
      let fair_out = amount_in * price_bps / 10_000
      let bound = fair_out * ( 10_000 - max_slippage_bps ) / 10_000
      min_receive >= bound
    }
    None -> False
  }
}
