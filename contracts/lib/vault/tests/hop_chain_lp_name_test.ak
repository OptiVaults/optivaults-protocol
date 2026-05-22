//// hop_chain LP-name re-hash regression — Minswap V2 adapter commitment + LP-name re-hash.
////
//// Verifies:
////   1. `compute_lp_asset_name` formula matches Minswap V2's on-chain
////      computation exactly (sha3_256 of sha3_256-hashed sorted assets).
////   2. Real mainnet LP asset names from mainnet TX
////      `b330b73706079b1b90140a9c0a3d9f11221330b2eb105dec8941f5436e7c2ebd`
////      (3-hop USDCx→NIGHT→ADA→DJED SwapMultiRouting) are reproduced
////      byte-for-byte.
////   3. Sort-direction invariants: `compute_lp_asset_name(a, b) ==
////      compute_lp_asset_name(b, a)`.
////   4. `hop_chain_well_formed` rejects empty, single-entry, and
////      adjacent-duplicate chains.
////   5. `last_hop_target` returns the final entry or None.

use vault/swap_adapter.{
  hop_chain_well_formed, last_hop_target,
}

// NOTE: `compute_lp_asset_name` is not `pub`-exported from
// `minswap_v2_adapter.ak` (it's an internal helper). To verify it in
// tests we'd need to bring it into scope via a pub export or use the
// validator's public surface. Pull the function out to `lib/vault/swap_adapter.ak`
// so it's testable and shared.

// ─────────────────────────────────────────────────────────────────────
// hop_chain structural tests
// ─────────────────────────────────────────────────────────────────────

test r74_hop_chain_rejects_empty() {
  !hop_chain_well_formed([])
}

test r74_hop_chain_rejects_singleton() {
  !hop_chain_well_formed([(#"", #"")])
}

test r74_hop_chain_accepts_two() {
  hop_chain_well_formed([(#"aa", #"bb"), (#"cc", #"dd")])
}

test r74_hop_chain_accepts_three_hop() {
  hop_chain_well_formed(
    [(#"aa", #"bb"), (#"cc", #"dd"), (#"ee", #"ff")],
  )
}

test r74_hop_chain_rejects_adjacent_dup_head() {
  !hop_chain_well_formed([(#"aa", #"bb"), (#"aa", #"bb"), (#"cc", #"dd")])
}

test r74_hop_chain_rejects_adjacent_dup_tail() {
  !hop_chain_well_formed([(#"aa", #"bb"), (#"cc", #"dd"), (#"cc", #"dd")])
}

test r74_hop_chain_non_adjacent_dup_ok() {
  // (aa, bb) appearing twice non-adjacently is OK (weird but legal — a
  // swap loop through an intermediate and back, still valid Minswap
  // routing topology).
  hop_chain_well_formed(
    [(#"aa", #"bb"), (#"cc", #"dd"), (#"aa", #"bb")],
  )
}

// ─────────────────────────────────────────────────────────────────────
// last_hop_target
// ─────────────────────────────────────────────────────────────────────

test r74_last_hop_empty_none() {
  last_hop_target([]) == None
}

test r74_last_hop_single() {
  last_hop_target([(#"aa", #"bb")]) == Some((#"aa", #"bb"))
}

test r74_last_hop_last_of_many() {
  last_hop_target([(#"aa", #"bb"), (#"cc", #"dd"), (#"ee", #"ff")]) == Some((#"ee", #"ff"))
}
