/// Equity-loss guard regression tests (2026-05-30).
///
/// Exercises two pure gate predicates at the unit level:
///
///   swap_adapter.swap_target_allowed — DeployToProtocol /
///     AdminDeployNonDeposit let the keeper swap vault USDCx out to ANY
///     hop_chain[last] target. The Tier-2 peg-floor compares min_receive
///     (target-asset units) to deploy_amount (USDCx micro-units) 1:1, and
///     the Tier-1 oracle is fail-open for targets with no oracle entry
///     (the launch state, asset_oracles=[]). A compromised keeper (or
///     post-sunset permissionless caller) could therefore route vault
///     value into an attacker-seeded junk-token pool and drain it. The fix
///     constrains the target to the deposit token or a registry stable.
///
///   helpers.gov_usdcx_preserved — the gov UTXO's
///     signer_compensation_pool USDCx was preserved only as a datum
///     counter, never physically, by Queue/Cancel/Execute/Rotate/Heartbeat.
///     A single rogue signer could reproduce the gov UTXO (same lovelace +
///     NFT + counter) while pocketing the pooled USDCx — an m-of-n bypass on
///     gov-controlled funds. The fix pins continuing-output USDCx >= input.

use cardano/address.{Address, Script}
use cardano/assets.{Value, from_asset, merge}
use cardano/transaction.{NoDatum, Output}
use vault/constants.{ada_swap_price_ceiling_bps, ada_swap_price_floor_bps}
use vault/helpers.{gov_usdcx_preserved}
use vault/swap_adapter.{swap_target_allowed}
use vault/types.{AssetOracleEntry, AssetOracleFeed, StableTokenEntry}
use vault/validation.{valid_asset_oracle_entry}

// ─────────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────────

const usdcx_policy: ByteArray = #"aa11"
const usdcx_name: ByteArray = #"55534443"

const djed_policy: ByteArray = #"bb22"
const djed_name: ByteArray = #"444a4544"

const usdm_policy: ByteArray = #"cc33"
const usdm_name: ByteArray = #"5553444d"

// An attacker-deployed worthless token (not the deposit token, not on the
// registry stable_tokens allowlist).
const junk_policy: ByteArray = #"deadbeef"
const junk_name: ByteArray = #"4a554e4b"

fn registry_stables() -> List<StableTokenEntry> {
  [
    StableTokenEntry { policy: djed_policy, name: djed_name },
    StableTokenEntry { policy: usdm_policy, name: usdm_name },
  ]
}

// ─────────────────────────────────────────────────────────────────────
// swap_target_allowed
// ─────────────────────────────────────────────────────────────────────

/// The legit "sunset / frozen NDV-drain" target: stable -> USDCx. The
/// deposit token itself must always be an allowed swap-out target.
test swap_target_accepts_deposit_token() {
  swap_target_allowed(
    usdcx_policy,
    usdcx_name,
    registry_stables(),
    usdcx_policy,
    usdcx_name,
  )
}

/// The legit "deposit -> stable yield deploy" target: a registry stable.
test swap_target_accepts_registry_stable() {
  swap_target_allowed(
    djed_policy,
    djed_name,
    registry_stables(),
    usdcx_policy,
    usdcx_name,
  ) && swap_target_allowed(
    usdm_policy,
    usdm_name,
    registry_stables(),
    usdcx_policy,
    usdcx_name,
  )
}

/// THE FIX: a junk target (attacker pool) is rejected even though the
/// peg-floor + recipient-binding + LP-name-rehash would otherwise pass.
/// This is the load-bearing equity-loss guard.
test swap_target_rejects_junk() {
  !swap_target_allowed(
    junk_policy,
    junk_name,
    registry_stables(),
    usdcx_policy,
    usdcx_name,
  )
}

/// A junk target is rejected even with a populated stable_tokens list —
/// i.e. the rejection is membership-based, not "list non-empty".
test swap_target_rejects_junk_with_nonempty_stables() {
  !swap_target_allowed(
    junk_policy,
    junk_name,
    registry_stables(),
    usdcx_policy,
    usdcx_name,
  )
}

/// With an EMPTY stable_tokens list, only the deposit token is allowed —
/// every other target (incl. one that WOULD be a stable once whitelisted)
/// is rejected. Pins the fail-closed default.
test swap_target_empty_stables_allows_only_deposit() {
  swap_target_allowed(usdcx_policy, usdcx_name, [], usdcx_policy, usdcx_name) && !swap_target_allowed(
    djed_policy,
    djed_name,
    [],
    usdcx_policy,
    usdcx_name,
  )
}

// ─────────────────────────────────────────────────────────────────────
// gov_usdcx_preserved
// ─────────────────────────────────────────────────────────────────────

const gov_hash: ByteArray = #"9999"

/// Build a gov-style Output carrying `usdcx_qty` USDCx + 5 ADA min-UTXO.
fn gov_output(usdcx_qty: Int) -> Output {
  let value: Value =
    if usdcx_qty > 0 {
      merge(
        from_asset(#"", #"", 5_000_000),
        from_asset(usdcx_policy, usdcx_name, usdcx_qty),
      )
    } else {
      from_asset(#"", #"", 5_000_000)
    }
  Output {
    address: Address {
      payment_credential: Script(gov_hash),
      stake_credential: None,
    },
    value,
    datum: NoDatum,
    reference_script: None,
  }
}

/// THE FIX: the gov UTXO holds 100 USDCx (`signer_compensation_pool`
/// backing); a continuing output that drops the USDCx to 0 (rogue signer
/// pocketing the pool while keeping lovelace + NFT + counter) is rejected.
test gov_usdcx_rejects_pool_drain() {
  let spent = gov_output(100_000_000)
  let cont = gov_output(0)
  !gov_usdcx_preserved(spent, cont, usdcx_policy, usdcx_name)
}

/// A partial skim (100 -> 40 USDCx) is also rejected — any decrease fails.
test gov_usdcx_rejects_partial_skim() {
  let spent = gov_output(100_000_000)
  let cont = gov_output(40_000_000)
  !gov_usdcx_preserved(spent, cont, usdcx_policy, usdcx_name)
}

/// Honest preservation (100 -> 100) passes — the guard does not block
/// legitimate Queue/Cancel/Execute/Rotate/Heartbeat transitions.
test gov_usdcx_accepts_preserved_pool() {
  let spent = gov_output(100_000_000)
  let cont = gov_output(100_000_000)
  gov_usdcx_preserved(spent, cont, usdcx_policy, usdcx_name)
}

/// An increase (>=) passes — e.g. a ReceiveCompoundShare-shaped credit is
/// never blocked by the `>=` guard used on the other redeemers.
test gov_usdcx_accepts_increased_pool() {
  let spent = gov_output(100_000_000)
  let cont = gov_output(150_000_000)
  gov_usdcx_preserved(spent, cont, usdcx_policy, usdcx_name)
}

// ─────────────────────────────────────────────────────────────────────
// oracle feed dedup (valid_asset_oracle_entry)
// ─────────────────────────────────────────────────────────────────────

// 28-byte feed identity components (the validator requires len==28).
const feed_a_hash: ByteArray =
  #"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
const feed_a_pol: ByteArray =
  #"b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1"
const feed_b_hash: ByteArray =
  #"c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2"
const feed_b_pol: ByteArray =
  #"d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2"

fn feed_a() -> AssetOracleFeed {
  AssetOracleFeed {
    feed_script_hash: feed_a_hash,
    feed_auth_policy: feed_a_pol,
    feed_auth_name: #"01",
  }
}

fn feed_b() -> AssetOracleFeed {
  AssetOracleFeed {
    feed_script_hash: feed_b_hash,
    feed_auth_policy: feed_b_pol,
    feed_auth_name: #"02",
  }
}

fn oracle_entry(feeds: List<AssetOracleFeed>, min_feeds: Int) -> AssetOracleEntry {
  AssetOracleEntry {
    asset_policy: djed_policy,
    asset_name: djed_name,
    feeds,
    max_disagreement_bps: 200,
    max_staleness_ms: 3_600_000,
    min_feeds,
  }
}

/// THE FIX: a "2-feed must-agree" entry whose two feeds are the SAME source
/// is rejected — otherwise both resolve to one ref UTXO at read time,
/// spread collapses to 0, and the disagreement circuit-breaker is inert.
test oracle_entry_rejects_duplicate_feeds() {
  !valid_asset_oracle_entry(oracle_entry([feed_a(), feed_a()], 2))
}

/// Two genuinely distinct feeds with min_feeds=2 → accepted.
test oracle_entry_accepts_distinct_feeds() {
  valid_asset_oracle_entry(oracle_entry([feed_a(), feed_b()], 2))
}

/// A single-feed entry (min_feeds=1) is still valid — dedup only rejects
/// repeated identities, it does not force redundancy.
test oracle_entry_accepts_single_feed() {
  valid_asset_oracle_entry(oracle_entry([feed_a()], 1))
}

// ─────────────────────────────────────────────────────────────────────
// SwapAda oracle price sanity band
// ─────────────────────────────────────────────────────────────────────

/// Pin the band's sanity: positive floor strictly below the ceiling, and
/// wide enough to never bind a realistic ADA price (floor ≤ $0.05/ADA,
/// ceiling ≥ $10/ADA in bps). Catches a future bad edit that would invert
/// or collapse the band (which would brick or no-op SwapAda).
test ada_swap_price_band_sane() {
  and {
    ada_swap_price_floor_bps > 0,
    ada_swap_price_floor_bps < ada_swap_price_ceiling_bps,
    ada_swap_price_floor_bps <= 500,
    ada_swap_price_ceiling_bps >= 100_000,
  }
}
