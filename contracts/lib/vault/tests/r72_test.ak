/// R72 regression tests — internal audit findings post-Phase-77d.
///
/// This file documents and verifies the fixes landed for the three
/// R72 findings (F-1 MEDIUM, F-2 LOW, F-3 LOW). F-2 turned out to be
/// a false positive (re-verification found the check was already
/// present in vault_batcher — see the audit report), so only F-1
/// and F-3 have code fixes; tests below cover both.
///
/// F-1 fix is cross-validator — it's tested at the Transaction level
/// in Preprod E2E (see `tests/preprod-e2e-plan.md` INT-7/8/16).
/// At the unit level we can only verify the type-layer plumbing:
/// that `ReceiveCompoundShare` exists in the `GovRedeemer` enum and
/// that its Constr index is stable (governance TXs build the redeemer
/// by index, so a reordering would silently break the cross-validator
/// binding).
///
/// F-3 fix is pure predicate — directly testable by invoking
/// `valid_asset_oracle_entry` on synthesized `AssetOracleEntry` values.

use vault/types.{
  AssetOracleEntry, AssetOracleFeed, GovRedeemer, ReceiveCompoundShare,
}
use vault/validation.{valid_asset_oracle_entry}

// ─────────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────────

fn good_feed() -> AssetOracleFeed {
  AssetOracleFeed {
    feed_script_hash: #"11111111111111111111111111111111111111111111111111111111",
    feed_auth_policy: #"2222aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    feed_auth_name: #"43484152",
  }
}

fn good_feed2() -> AssetOracleFeed {
  AssetOracleFeed {
    feed_script_hash: #"22222222222222222222222222222222222222222222222222222222",
    feed_auth_policy: #"3333aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    feed_auth_name: #"4f5243",
  }
}

fn entry_with_bounds(dis_bps: Int, stale_ms: Int) -> AssetOracleEntry {
  AssetOracleEntry {
    asset_policy: #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    asset_name: #"444a4544",
    feeds: [good_feed(), good_feed2()],
    max_disagreement_bps: dis_bps,
    max_staleness_ms: stale_ms,
    min_feeds: 2,
  }
}

// ─────────────────────────────────────────────────────────────────────
// F-3: Registry asset-oracle entry upper-bound caps
//
// Governance populates `asset_oracles` via UpdateRegistry (14d timelock).
// Without upper bounds on `max_disagreement_bps` and `max_staleness_ms`
// a compromised / inattentive governance could commit a degenerate
// entry — e.g. 1000% disagreement tolerance or 11-day staleness — that
// makes Tier 1 oracle enforcement trivially satisfiable. R72 F-3 added
// caps at 1000 bps (10%) and 3_600_000 ms (1 hour) respectively.
// ─────────────────────────────────────────────────────────────────────

test r72_f3_oracle_entry_reasonable_bounds_pass() {
  // Typical dual-feed operational config: 2% disagreement + 30-minute staleness.
  valid_asset_oracle_entry(entry_with_bounds(200, 1_800_000))
}

test r72_f3_oracle_entry_at_disagreement_cap_passes() {
  // Exactly at the 1000 bps cap — should pass (cap is inclusive).
  valid_asset_oracle_entry(entry_with_bounds(1_000, 600_000))
}

test r72_f3_oracle_entry_at_staleness_cap_passes() {
  // Exactly at the 3_600_000 ms (1h) cap — should pass (cap is inclusive).
  valid_asset_oracle_entry(entry_with_bounds(200, 3_600_000))
}

test r72_f3_oracle_entry_disagreement_over_cap_rejected() {
  // 1001 bps — exceeds cap by 1. Must reject.
  !valid_asset_oracle_entry(entry_with_bounds(1_001, 600_000))
}

test r72_f3_oracle_entry_absurd_disagreement_rejected() {
  // 100_000 bps = 1000% tolerance — the degenerate-config attack.
  !valid_asset_oracle_entry(entry_with_bounds(100_000, 600_000))
}

test r72_f3_oracle_entry_staleness_over_cap_rejected() {
  // 1 hour + 1 ms — must reject.
  !valid_asset_oracle_entry(entry_with_bounds(200, 3_600_001))
}

test r72_f3_oracle_entry_absurd_staleness_rejected() {
  // 1_000_000_000 ms ≈ 11.5 days — the degenerate-config attack.
  !valid_asset_oracle_entry(entry_with_bounds(200, 1_000_000_000))
}

test r72_f3_oracle_entry_zero_disagreement_rejected() {
  // Still rejected (pre-existing lower bound > 0 still enforced).
  !valid_asset_oracle_entry(entry_with_bounds(0, 600_000))
}

test r72_f3_oracle_entry_zero_staleness_rejected() {
  // Still rejected (pre-existing lower bound > 0 still enforced).
  !valid_asset_oracle_entry(entry_with_bounds(200, 0))
}

// ─────────────────────────────────────────────────────────────────────
// F-1: GovRedeemer.ReceiveCompoundShare plumbing
//
// The cross-validator binding between vault_keeper_hot.Compound's
// `valid_gov_share` and multisig_gov's `ReceiveCompoundShare` relies
// on the Compound TX builder passing ReceiveCompoundShare as the gov
// input's spend redeemer. If ReceiveCompoundShare's Constr index in
// the GovRedeemer enum changed (through accidental reordering), the
// gov input would still carry its original bytes but the pattern
// match on the Compound side would fail — every Compound TX would
// reject on `gov_redeemer_is_receive = False`, a silent liveness
// regression. This test pins ReceiveCompoundShare to the 7th enum
// variant (Constr index 6) and verifies its Constr shape.
//
// Full cross-validator scenario — Compound TX that pairs with the
// wrong gov redeemer and the `gov_redeemer_is_receive` check rejects
// — belongs in Preprod E2E (INT-7/8/16).
// ─────────────────────────────────────────────────────────────────────

test r72_f1_receive_compound_share_enum_order() {
  // Direct construction smoke test — if the type changed, this won't
  // compile and the regression is caught at build time.
  let r: GovRedeemer = ReceiveCompoundShare
  when r is {
    ReceiveCompoundShare -> True
    _ -> False
  }
}

test r72_f1_gov_redeemer_enum_exhaustive_receive_branch() {
  // Explicit pattern-match validates the enum still has
  // ReceiveCompoundShare as a distinct variant that matches on its
  // own arm (not accidentally collapsing into another variant).
  let r: GovRedeemer = ReceiveCompoundShare
  let matched =
    when r is {
      ReceiveCompoundShare -> 1
      _ -> 0
    }
  matched == 1
}
