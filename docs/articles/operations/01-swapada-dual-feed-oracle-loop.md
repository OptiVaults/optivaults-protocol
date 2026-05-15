# SwapAda: A Dual-Feed Oracle On-Chain ADA Replenishment Loop

*OptiVaults V1 Operational Mechanics Series — Part 1 of 3*

---

Each `DeployToProtocol` TX costs the vault about 2 ADA net to Minswap V2's batchers. At 100K TVL, that runs to 20-50 DeployToProtocol calls per year, netting 40-100 ADA outflow.

Without a replenishment mechanism, the vault's ADA balance eventually hits the `min_vault_ada` floor — the validator then rejects all subsequent DeployToProtocol calls, jamming the keeper's automation.

Many vaults handle this problem with off-chain manual top-up: operators periodically send ADA from their wallet into the vault. This approach has a structural defect — it ties the vault's operational availability to the operator's personal wallet state and manual-ops process. Any time the operator is incapacitated or forgets to top up, the vault stalls.

V1 moves the mechanism on-chain: **the `SwapAda` redeemer auto-replenishes ADA at the contract layer, with fair price from a dual-feed oracle and all economic parameters enforced by the validator**. This article unpacks the loop's operation, why dual-feed rather than single-source, and the cost impact on depositors.

The whole protocol is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol); the validator discussed here is specified in `spec/ada-swap.md`.

---

## Why the Vault Needs ADA

Every transaction on Cardano requires ADA for network fees — conceptually similar to EVM gas, but with two key differences:

**(1) Every UTXO must carry min-UTXO ADA**. The Cardano ledger requires each UTXO to carry enough ADA to cover its own storage cost (computed by datum size and accompanying token count). The vault state UTXO holds a 29-field VaultDatum plus idle USDCx alongside various stablecoins / qTokens — so its min-UTXO works out to about 15-20 ADA.

**(2) Minswap V2 batch fees are paid in ADA by the TX initiator**. Each DeployToProtocol that does a USDCx ↔ DJED / USDM swap through Minswap V2 needs the vault to place a batcher fee (about 2 ADA) into the Minswap order UTXO. That ADA travels with the Minswap orderbook and is eventually claimed by the batcher — **the vault doesn't get it back**.

So the vault "leaks ADA" over time:

```
Initial vault ADA = 20 ADA (min-UTXO reserve)

Each DeployToProtocol:
  vault ADA → vault ADA − 2 ADA (Minswap batcher fee)

After 10 DeployToProtocol calls:
  vault ADA = 0 ADA → violates min-UTXO → all subsequent TXs fail
```

This leak isn't a V1 design defect — it's a structural feature of Cardano + Minswap V2 interaction. Any Cardano contract holding non-ADA tokens that needs DEX swaps hits the same issue.

---

## First (Insufficient) Solution: Manual Top-Up

The most intuitive solution: the operator periodically sends ADA from their wallet to the vault.

This is unacceptable because:

- **Vault availability is tied to the operator's personal wallet**. Anytime the operator's personal balance is insufficient, stolen, or forgotten, the vault stalls.
- **Cannot be verified by depositors**. How much the operator tops up and when can only be observed retrospectively on cardanoscan; depositors can't know "what the top-up policy is" in advance.
- **No fair-price constraint**. If the operator wants to simultaneously swap USDCx out of the vault (e.g., "I add 20 ADA, take 10 USDCx from the vault"), this swap's price has no validator enforcement; the operator can execute at any rate.

V1 rejects this approach, moving the ADA replenishment mechanism entirely on-chain.

---

## V1's Solution: the `SwapAda` Redeemer

`vault_swap_ada.SwapAda` is V1's dedicated redeemer for vault ADA replenishment. Flow:

```
[1] Keeper detects vault.lovelace < 15 ADA
[2] Keeper reads ADA/USD fair price from Cardano oracles
[3] Keeper constructs SwapAda TX:
    ├─ Input:  vault UTXO (with current USDCx + ADA)
    │          keeper's personal ADA UTXO (supplying 10-50 ADA)
    ├─ Output: vault UTXO (vault.ADA += swap_amount_ada,
    │                       vault.USDCx -= swap_amount_ada × oracle_price)
    │          keeper's personal UTXO (receives corresponding USDCx)
    └─ Redeemer: SwapAda { swap_amount_ada, oracle_proof }
[4] Validator checks:
    ├─ vault.lovelace < ada_below_threshold (15 ADA)
    ├─ swap_amount_ada ∈ [10, 50] ADA
    ├─ exchange rate matches oracle fair price (dual-feed median)
    ├─ validity_range.upper - now ≤ 1 hour
    ├─ time since last SwapAda ≥ 1 hour (cooldown)
    └─ no other vault state changes (frozen / total_deposited / liqwid_positions)
[5] TX submitted, ledger accepts
```

Several key properties:

**On-chain atomic exchange**. The vault receiving ADA and the keeper receiving USDCx are two outputs of the same TX — the validator forces them to match at oracle fair price. The keeper cannot say "I give the vault 10 ADA, but the vault gives me 1000 USDCx" — the validator rejects.

**Oracle fair-price verification**. The validator reads ADA/USD fair price from on-chain oracle data (Charli3 + Orcfax), recomputes expected USDCx amount, requires precise match with the redeemer's submitted amount.

**Per-swap amount cap**. Each swap is limited to 10-50 ADA — this blocks scale anomalies like a one-shot 1000-ADA top-up.

**1-hour cooldown**. SwapAda calls on the same vault must be spaced at least 1 hour apart — blocks "rapid consecutive SwapAda" draining vault USDCx.

**Validity-range cap**. Each SwapAda's time window is capped at 1 hour — blocks "claiming upper = now + 100 days" attempts to re-submit pre-signed TXs after oracle fair price moves.

With these constraints stacked, a compromised keeper's worst case is swapping 50 ADA per hour at the current fair price — a negligible impact on the vault, and the oracle fair price constrains the USDCx outflow to precisely match the ADA value received.

---

## Why Dual-Feed Oracle (Not Single-Source)

The oracle is SwapAda's trust precondition. If the oracle's reported ADA/USD price is manipulated, the vault's USDCx is drained at distorted rates. The oracle's security properties determine SwapAda's security properties.

V1 uses a dual-feed reader:

```aiken
fn read_oracle_price(asset_oracles: List<AssetOracle>, asset: AssetClass) -> Option<Int> {
  // Find oracle config entries for the asset in asset_oracles
  let oracle_entries = find_oracle_entries(asset_oracles, asset)

  // Read latest quotes + timestamps from Charli3 + Orcfax
  let charli3_sample = read_feed(oracle_entries.charli3, current_time)
  let orcfax_sample  = read_feed(oracle_entries.orcfax, current_time)

  // Check both feeds' freshness (≤ 10 minutes)
  expect is_fresh(charli3_sample, max_staleness_ms = 600_000)
  expect is_fresh(orcfax_sample,  max_staleness_ms = 600_000)

  // Check the two feeds' difference within tolerance (≤ 2%)
  let diff_bps = abs(charli3_sample.price - orcfax_sample.price) * 10_000
              / min(charli3_sample.price, orcfax_sample.price)
  expect diff_bps <= 200  // 2% disagreement window

  // Take median as fair price
  Some(median([charli3_sample.price, orcfax_sample.price]))
}
```

Several key properties:

**Only dual-source is accepted**. Single-source fails directly in this helper. Charli3 and Orcfax are two oracle protocols operating independently on Cardano — each has its own data sources, aggregation, publishing schedule. Compromising both requires two independent attacks.

**Disagreement window**. Two feeds must be within 2%. If Charli3 reports ADA/USD = $0.50 and Orcfax reports $0.45, an 11% gap — the helper rejects the price, and the entire SwapAda TX fails. This automatically detects "single-feed attacked but the other feed normal" as "oracle anomaly."

**Freshness window**. Each feed must be ≤ 10 minutes old. Oracles on Cardano typically update every few blocks (10-30 seconds), so 10-minute cap is loose for normal operation; but if an oracle stops updating (e.g., oracle self-malfunction), the freshness check blocks SwapAda.

**Median aggregation**. Dual-feed's two prices take median (with 2 samples, median equals average). If a third oracle is added in the future, the median provides structural resistance to single-feed outliers.

---

## Governance Control Over Oracle Configuration

V1 puts oracle configuration in `registry.asset_oracles` rather than hardcoding it in the validator, because **the oracle ecosystem may shift**:

- New oracle protocols appear (e.g., a third mature oracle on Cardano post-V1 launch).
- Existing oracles develop issues (e.g., a Charli3 feed deprecated, needing reference rotation).
- On-chain format adjustments to feeds (e.g., oracle upgrades datum schema).

The `UpdateRegistry` governance action (14-day timelock) can adjust `asset_oracles`: add oracle entries, deactivate feeds, rotate to new feeds. The `UpdateOracleSource` action (also 14-day timelock) has narrower authority dedicated to oracle source rotation, providing two layers of protection alongside `UpdateRegistry`.

**At V1 launch `asset_oracles = []`**. This design is critical: at launch, SwapAda is inactive because the helper directly fails when finding no ADA entry in `asset_oracles`. To activate SwapAda, governance must run the full `UpdateRegistry` action to seed ADA's oracle configuration.

Why inactive at launch? Because oracle configuration is itself a high-sensitivity config: once an incorrect oracle reference is seeded, all future SwapAdas execute at distorted rates. Placing this configuration behind a 14-day timelock gives the community ample time to inspect whether the seeded oracle truly corresponds to the correct feed. While SwapAda is inactive, the vault operates normally (until ADA truly runs out), providing a safety buffer before oracle seeding.

---

## Cost to Depositors: ~0.02% APY Drag

Two distinct costs are easy to conflate here, so separate them first.

**The Minswap batcher fees are a real operational cost — but they are not SwapAda's cost.** At 100K TVL the vault leaks roughly 50 ADA/month to Minswap V2 batchers (about 25 DeployToProtocol calls × 2 ADA each):

```
Minswap batcher cost ≈ 50 ADA/month × 12 × $0.50/ADA ≈ $300 / year
As a fraction of 100K TVL ≈ 0.30% / year
```

That 0.30% is simply the network gas cost of running a swap-based vault on Cardano — any Cardano vault that rebalances through a DEX pays a comparable figure. V1 surfaces it openly rather than burying it inside "total fees." SwapAda does not create this cost; it only replenishes the ADA the vault has already spent on it.

**SwapAda's own incremental drag is the ~0.02% figure cited in whitepaper §2.4.** It is *not* the batcher fees — those are a necessary protocol cost the vault would pay no matter how its ADA is topped up. SwapAda's incremental drag is the small unfairness of swapping ADA at the oracle median fair price: the vault always transacts at the 0% fair-price point, whereas a manual operator top-up could pick favorable timing for a slightly better rate. That spread — the dual-feed median versus the keeper's personally-optimal rate — is typically 0.01-0.05%.

How depositors should read this figure:

- **0.02% APY is negligible next to the 4.5% performance fee.** Even at the 0.05% upper bound, against a 4-6% gross yield it does not change a deposit decision.
- **The drag buys structural, no-manual-ops ADA replenishment.** Depositors absorb a 0-0.05% drag in exchange for a vault that never needs operator intervention to stay funded with ADA.
- **The drag shrinks on its own as oracle competition tightens.** A narrower median-vs-optimal spread lowers the figure automatically. V1 does not actively optimize it — it is already small enough — but a future V1.x / V2 may weigh whether adding more oracle sources is worthwhile.

---

## Why 1-Hour Cooldown + 1-Hour Validity-Range Cap

The two 1-hour limits each address a class of threat:

**Cooldown defends against high-frequency abuse**. Without cooldown, a compromised keeper could rapidly trigger SwapAda — e.g., 10 times in 1 minute at 50 ADA each, total 500 ADA. Vault USDCx outflow = 500 ADA × oracle fair price ≈ 250 USDCx. Even though each individual swap is at fair price, the cumulative scale far exceeds "ADA the vault actually needs." The 1-hour cooldown caps the maximum outflow rate at 50 ADA / hour; a compromised keeper can swap at most 1200 ADA / 600 USDCx per day — a low single-digit percentage of a 100K TVL, nowhere near enough to drain the vault.

**Validity-range cap defends against oracle stale-price abuse**. Without the cap, the keeper could construct a TX with `validity_range.upper = now + 10y` — this TX holds at the current oracle fair price, but if the oracle fair price moves significantly within 10 years, the attacker can re-submit this already-signed TX later, profiting from stale price. The 1-hour width cap compresses this attack surface to "TX must settle within 1 hour or expires" — oracle fair price moves within 1 hour are bounded, attack profit insufficient to justify attack cost.

Neither cap depends on the oracle itself; they're pure logical constraints on TX structure at the validator level. Even if the oracle is briefly compromised, both caps remain effective.

---

## Relationship to §5.4 Keeper Risk

The SwapAda mechanism is a concrete instance of V1's keeper risk management. Whitepaper §5.4 lists keeper risks: "the keeper's slippage / pricing policy for some operations is determined by keeper software, not necessarily contract-enforced." SwapAda inverts this keeper risk — **moving SwapAda's pricing enforcement from keeper software to contract layer**.

This design provides V1 a template:

- **Where keeper software policy can handle (e.g., Minswap V2 slippage tolerance 1.5%)**: expose the risk but mitigate via destination whitelist + public observation.
- **Where contract enforcement is required (e.g., SwapAda's oracle fair price)**: use the validator directly, removing the keeper from the trust path.

V1 continues to push this design line forward through P3-P5 slippage work (whitepaper §5.4 + spec/ada-swap.md) — moving more keeper-side policy to contract-layer enforcement. This is the watershed between "structural security vs trust-based security" in concrete operational mechanics.

---

## Next Article

Part 2 handles another contract mechanism directly related to keeper liveness: **7-day keeper-inactivity dead-man-switch**. When the keeper goes 7 consecutive days without sending productive Compound, three things auto-trigger — Direct Withdraw's early-withdraw fee auto-waived, governance fallback path opens, and emergency-withdraw becomes economically reasonable. The next article covers how this mechanism works, why 7 days, and why it can't be tricked by forged validity ranges from the TX submitter.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/HY5sy8cz8s).*
