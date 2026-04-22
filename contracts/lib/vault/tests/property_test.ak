/// Property-based regression tests — §C6.
///
/// Uses `aiken/fuzz v2.2.0` to exercise:
///   - swap_adapter.check_peg_floor — monotonicity, scale invariance,
///     boundary correctness
///   - oracle.find_asset_oracle — list lookup properties

use aiken/fuzz
use vault/oracle.{find_asset_oracle}
use vault/swap_adapter.{check_peg_floor}
use vault/types.{AssetOracleEntry, AssetOracleFeed}

// ─────────────────────────────────────────────────────────────────────
// check_peg_floor properties
// ─────────────────────────────────────────────────────────────────────

fn peg_fuzz() -> Fuzzer<(Int, Int, Int)> {
  fuzz.map3(
    fuzz.int_between(1, 1_000_000_000_000),
    fuzz.int_between(0, 1_000_000_000_000),
    fuzz.int_between(0, 10_000),
    fn(d, m, p) { (d, m, p) },
  )
}

// Monotonicity: if peg-floor passes at peg_bps_high, it must also pass
// at any peg_bps ≤ peg_bps_high (lower peg = weaker requirement).
test prop_peg_floor_monotonic_in_peg_bps(args via peg_fuzz()) {
  let (deploy, min_receive, peg_bps_high) = args
  let peg_bps_low = peg_bps_high / 2
  let ok_high = check_peg_floor(deploy, min_receive, peg_bps_high)
  let ok_low = check_peg_floor(deploy, min_receive, peg_bps_low)
  !ok_high || ok_low
}

// Scale invariance: multiplying both deploy and min_receive by k
// preserves peg-floor result.
test prop_peg_floor_scale_invariant(args via peg_fuzz()) {
  let (deploy, min_receive, peg_bps) = args
  let k = 3
  check_peg_floor(deploy, min_receive, peg_bps) == check_peg_floor(
    deploy * k,
    min_receive * k,
    peg_bps,
  )
}

fn peg_exact_fuzz() -> Fuzzer<(Int, Int)> {
  // Bound deploy >= 10_000 so integer division deploy * peg_bps / 10_000
  // never rounds the "exact" boundary below the pass threshold. Smaller
  // values hit sub-unit precision limits inherent to integer math — not
  // a bug in check_peg_floor, a mathematical property of integer floor-
  // division.
  fuzz.map2(
    fuzz.int_between(10_000, 1_000_000_000_000),
    fuzz.int_between(1, 10_000),
    fn(d, p) { (d, p) },
  )
}

// Exact boundary: min_receive == ceil(deploy * peg_bps / 10_000) passes.
// For the integer-floor version to satisfy peg-floor exactly, we need
// deploy * peg_bps to be divisible by 10_000 OR we need min_receive to
// round up. Use the ceiling form to express the property safely.
test prop_peg_floor_exact_boundary(args via peg_exact_fuzz()) {
  let (deploy, peg_bps) = args
  // Ceiling division: (a + b - 1) / b rounds up when a positive.
  let exact_min = ( deploy * peg_bps + 9_999 ) / 10_000
  check_peg_floor(deploy, exact_min, peg_bps)
}

// Zero deploy always passes (degenerate but valid: 0 × anything = 0 ≤ min_receive).
test prop_peg_floor_zero_deploy(
  min_receive via fuzz.int_between(0, 1_000_000_000),
) {
  check_peg_floor(0, min_receive, 9_500)
}

// ─────────────────────────────────────────────────────────────────────
// find_asset_oracle properties
// ─────────────────────────────────────────────────────────────────────

fn sample_entry(tag: Int) -> AssetOracleEntry {
  AssetOracleEntry {
    asset_policy: if tag == 0 {
      #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    } else if tag == 1 {
      #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    } else {
      #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    },
    asset_name: #"",
    feeds: [
      AssetOracleFeed {
        feed_script_hash: #"1111111111111111111111111111111111111111111111111111111111",
        feed_auth_policy: #"",
        feed_auth_name: #"",
      },
    ],
    max_disagreement_bps: 200,
    max_staleness_ms: 600_000,
    min_feeds: 1,
  }
}

test prop_find_asset_oracle_empty_is_none() {
  when find_asset_oracle([], #"aaaa", #"") is {
    None -> True
    Some(_) -> False
  }
}

test prop_find_asset_oracle_roundtrip(idx via fuzz.int_between(0, 2)) {
  let registry = [sample_entry(0), sample_entry(1), sample_entry(2)]
  let target = sample_entry(idx)
  when find_asset_oracle(registry, target.asset_policy, target.asset_name) is {
    Some(got) -> got.asset_policy == target.asset_policy
    None -> False
  }
}

test prop_find_asset_oracle_miss_returns_none() {
  let registry = [sample_entry(0), sample_entry(1)]
  when find_asset_oracle(
    registry,
    #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    #"",
  ) is {
    None -> True
    Some(_) -> False
  }
}

// First-match semantics documented: governance can replace an oracle
// config by appending a new entry with the same key at head of list.
test prop_find_asset_oracle_first_match_wins() {
  let e0 = sample_entry(0)
  let alt =
    AssetOracleEntry {
      asset_policy: e0.asset_policy,
      asset_name: e0.asset_name,
      feeds: e0.feeds,
      max_disagreement_bps: 999,
      max_staleness_ms: 999,
      min_feeds: 1,
    }
  when find_asset_oracle([alt, e0], e0.asset_policy, e0.asset_name) is {
    Some(got) -> got.max_disagreement_bps == 999
    None -> False
  }
}
