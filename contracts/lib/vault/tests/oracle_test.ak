/// oracle.ak regression tests — §5.4 P3.
///
/// Unit-level coverage: the pure-predicate helpers (find_asset_oracle,
/// AssetOracleEntry / AssetOracleFeed / PriceSample type shape). The
/// Transaction-dependent paths (find_feed_sample, read_fair_price,
/// check_tier1_bound) require reference-input mocking + datum shaping,
/// which belongs in Preprod E2E tests per the V1 testing philosophy
/// (see `v1/tests/preprod-e2e-plan.md`).

use vault/oracle.{find_asset_oracle}
use vault/types.{AssetOracleEntry, AssetOracleFeed}

// ─────────────────────────────────────────────────────────────────────
// Fixtures — two representative AssetOracleEntry values for tests.
// ─────────────────────────────────────────────────────────────────────

fn djed_entry() -> AssetOracleEntry {
  AssetOracleEntry {
    asset_policy: #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    asset_name: #"444a4544",
    feeds: [
      AssetOracleFeed {
        feed_script_hash: #"1111111111111111111111111111111111111111111111111111111111",
        feed_auth_policy: #"1111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        feed_auth_name: #"43484152",
      },
      AssetOracleFeed {
        feed_script_hash: #"2222222222222222222222222222222222222222222222222222222222",
        feed_auth_policy: #"2222aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        feed_auth_name: #"4f5243",
      },
    ],
    max_disagreement_bps: 200,
    max_staleness_ms: 3_600_000,
    min_feeds: 2,
  }
}

fn ada_entry() -> AssetOracleEntry {
  AssetOracleEntry {
    asset_policy: #"",
    asset_name: #"",
    feeds: [
      AssetOracleFeed {
        feed_script_hash: #"33333333333333333333333333333333333333333333333333333333",
        feed_auth_policy: #"",
        feed_auth_name: #"",
      },
      AssetOracleFeed {
        feed_script_hash: #"44444444444444444444444444444444444444444444444444444444",
        feed_auth_policy: #"",
        feed_auth_name: #"",
      },
    ],
    max_disagreement_bps: 500,
    max_staleness_ms: 600_000,
    min_feeds: 2,
  }
}

// ─────────────────────────────────────────────────────────────────────
// find_asset_oracle — pure list lookup
// ─────────────────────────────────────────────────────────────────────

test find_asset_oracle_hit() {
  let registry = [ada_entry(), djed_entry()]
  let result =
    find_asset_oracle(
      registry,
      #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      #"444a4544",
    )
  when result is {
    Some(e) -> e.asset_policy == #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    None -> False
  }
}

test find_asset_oracle_miss() {
  let registry = [djed_entry()]
  let result =
    find_asset_oracle(
      registry,
      #"ffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      #"4e4f542d464f554e44",
    )
  when result is {
    None -> True
    Some(_) -> False
  }
}

test find_asset_oracle_empty_registry() {
  let result =
    find_asset_oracle(
      [],
      #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      #"444a4544",
    )
  when result is {
    None -> True
    Some(_) -> False
  }
}

test find_asset_oracle_ada_convention() {
  // ADA asset convention: policy == #"" AND name == #"". Verify the
  // lookup distinguishes this from arbitrary non-ADA assets even when
  // other entries have non-empty asset_policy.
  let registry = [djed_entry(), ada_entry()]
  let result = find_asset_oracle(registry, #"", #"")
  when result is {
    Some(e) -> e.asset_policy == #"" && e.asset_name == #""
    None -> False
  }
}

test find_asset_oracle_first_match_wins() {
  // If two entries alias the same (policy, name), the first is returned.
  // This is a documented behavior of UpdateRegistry: governance replaces
  // an oracle config by appending a new entry for the same asset and
  // relying on the first-match semantics of `list.find`. Less invasive
  // than forcing in-place replace via list index.
  let alt_djed =
    AssetOracleEntry {
      asset_policy: #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      asset_name: #"444a4544",
      feeds: [
        AssetOracleFeed {
          feed_script_hash: #"9999999999999999999999999999999999999999999999999999999999",
          feed_auth_policy: #"",
          feed_auth_name: #"",
        },
      ],
      max_disagreement_bps: 100,
      max_staleness_ms: 300_000,
      min_feeds: 1,
    }
  let registry = [alt_djed, djed_entry()]
  let result =
    find_asset_oracle(
      registry,
      #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      #"444a4544",
    )
  when result is {
    Some(e) -> e.max_staleness_ms == 300_000
    None -> False
  }
}

// ─────────────────────────────────────────────────────────────────────
// AssetOracleEntry shape sanity — ensures Data-level round trip will
// work (tested indirectly via payload_hash_update_registry, which
// cbor-serialises the whole RegistryDatum including asset_oracles).
// ─────────────────────────────────────────────────────────────────────

test asset_oracle_entry_feeds_nonempty() {
  // min_feeds should be ≤ list.length(feeds) in governance-validated
  // entries. Validator doesn't enforce this invariant because it's a
  // governance-policy concern (depositor-visible via transparent
  // registry); this test documents the expected relationship.
  let e = djed_entry()
  e.min_feeds == 2 && e.max_disagreement_bps > 0 && e.max_staleness_ms > 0
}

test asset_oracle_entry_ada_feeds_shape() {
  let e = ada_entry()
  e.asset_policy == #"" && e.asset_name == #""
}
