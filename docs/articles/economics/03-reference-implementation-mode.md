# Reference Implementation Mode: Public-Goods Operation at Low TVL

*OptiVaults V1 Economic Model Series — Part 3 of 4*

---

V1 launches with a 100K USDCx hard cap. Internal estimates put Phase 1 (pre-audit) organic TVL roughly in the $500-$25K range — far below the cap, and far below the protocol's self-sustaining scale (baseline ~$500K).

A typical DeFi vault facing this gap has two options: (a) push for short-term TVL using a "growth" posture (marketing budget, incentives, subsidies) to cross the self-sustaining threshold quickly; (b) shut the product down because "slow growth = failure."

V1 takes neither — and the refusal itself is written into operational policy. **Reference Implementation Mode** is V1's legitimate operating mode in the low-TVL range: scaling operational cadence down to match the real revenue base, down to a level where "even if TVL stays at $5K forever, V1 can keep running indefinitely."

This article unpacks the mode's details: when it activates, what it adjusts, what it does not adjust, and why this design reflects V1's true positioning as "Cardano DeFi public-goods reference implementation."

The whole protocol is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol).

---

## The Problem: At Low TVL, the Default Compound Cadence Is Uneconomic

V1's default Compound schedule is tiered by TVL (whitepaper §2.6):

| `total_deposited` tier | Compound schedule | Zero-yield heartbeat |
|------------------------|-------------------|----------------------|
| < 300 USDCx | Wait until accrued yield > $1 | Every 30 days |
| 300-750 USDCx | Once a month | Every 5 days |
| 750-1,200 USDCx | Every two weeks | Every 5 days |
| 1,200+ USDCx | Every Saturday | Every 5 days |

Each Compound TX on Cardano mainnet costs about 1.5-2.5 ADA. Each heartbeat costs about 0.5-1 ADA. Add these up and the 1,200+ tier's weekly schedule costs roughly 70-80 ADA per year (≈ $35-40 at current ADA price).

That cost is reasonable at 100K TVL — 100K × 6% gross × 4.5% × 40% keeper share ≈ $108/yr, just enough to cover an independent operator's minimum operating cost.

But the math at $1-5K TVL is completely different:

```
TVL = $5,000
Gross yield 6%/year = $300
Performance fee 4.5% = $13.5
Keeper share 40% = $5.4

Default cadence yearly keeper gas (weekly Compound + heartbeat)
  ≈ 70-80 ADA
  ≈ $35-40

Net: keeper -$30-35
Protocol income: $13.5/year (entirely to treasury + founder keeper share)
```

At this scale, default cadence's on-chain gas exceeds the keeper's extraction from the vault, let alone covering VPS / monitoring infrastructure. **Running $5K TVL under default cadence is economically unreasonable and contradicts V1's public-goods positioning**.

Reference Implementation Mode is V1's contract-plus-operational-layer response.

---

## Activation Conditions: Both Must Hold

Reference Implementation Mode isn't "activate whenever you want" — it requires **both conditions to hold simultaneously**:

1. V1 mainnet TVL stays below $25K for 30+ days.
2. Average qToken yield per Compound interval over the past 4 weeks falls below 5× the on-chain TX cost for that Compound (i.e., yield can't sustain the default Compound frequency).

The "5×" in condition 2 is an economic-reasonableness buffer — if yield exactly equals TX cost, Compound is "break-even"; only with a 5× buffer does default cadence not become "Compound for the sake of Compound."

Deactivation: TVL crosses $25K and stays above for 30+ days, switching back to Default Mode; if TVL drops again, re-enter Reference Implementation Mode. Mode switching can happen in both directions.

**This mode falls under operational policy exercised by the keeper under whitepaper §4.5's economic-reasonableness discretion — it does not require `UpdateStrategy` governance**. It's keeper operational autonomy, not a contract-enforced condition. But the keeper must publicly disclose the current active mode on a dashboard (detailed later).

---

## Operational Adjustments Under the Mode

| Operation | Default cadence | Reference Implementation Mode |
|-----------|-----------------|-------------------------------|
| Productive Compound | 1,200+ tier weekly | Trigger when accrued yield > $5 USDCx; at $1-5K TVL, typically once per quarter to once per year |
| Liveness heartbeat | Every 5 days | Approximately every 80 days (kept under the 90-day CommunitySunset threshold) |
| Rebalance | When triggers fire | Only when allocation drift exceeds band; not scheduled |
| SwapAda | When `vault.lovelace < 15 ADA` | Same trigger; deployment ceremony pre-seeds ADA up to 20+ ADA to delay first call |
| Discord operational notifications | Every Compound + heartbeat | Switch to quarterly + annual summaries; weekly reports paused |

Several subtle design choices:

**Heartbeat cannot stop entirely — must stay under the 90-day sunset threshold**. Heartbeat's purpose is to update `last_realloc_time` to avoid triggering Layer 3 CommunitySunset ([Security Series Article 1](../security/01-three-layer-governance-safety.md)). Pushing heartbeat out to 80 days falls just under the 90-day sunset threshold — maximizing gas savings while preserving vault liveness.

**SwapAda trigger unchanged — just more pre-seeded ADA**. SwapAda triggers on `vault.lovelace < 15 ADA`; the mode doesn't change this contract condition, but the deployment ceremony pre-seeds 5-10 extra ADA to push first SwapAda invocation further out.

**Discord notification frequency reduced**. Weekly reports aren't read at $5K TVL — who wants 52 reports of "this week's vault yield $0.26"? Quarterly + annual summaries fit the "public-goods reference implementation" positioning better.

---

## What This Mode Does NOT Surrender (Zero Compromise)

Important disclosure: **Reference Implementation Mode is keeper cadence policy, not contract-layer loosening**. The following protections are unaffected:

- **All contract invariants** — no fee changes, no governance bypass, no validator detour.
- **All depositor protections** — `emergency-withdraw`, 4.5% / 1% / 6h hard caps, `withdraw-cli`.
- **Three-layer governance safety** (Security Series Part 1) — Layer 1 freeze-only, Layer 2 swap-out, Layer 3 CommunitySunset all normal.
- **Share-price NAV accuracy** — qToken values still read on-demand; `total_*` datum fields still update at Compound as designed.
- **7-day keeper-inactivity gate** — reads `last_compound_time`, unaffected by heartbeat cadence slowdown.

The 7-day gate is especially important. It means even if the keeper, under Reference Implementation Mode, doesn't send productive Compound for months, **as long as actual yield < heartbeat threshold, this scenario does not activate the 7-day fallback**. But if the keeper completely stops (including not sending heartbeat), the 7-day gate still triggers on `last_compound_time` basis — Direct Withdraw's early-withdraw fee auto-waived, emergency-withdraw becomes economically reasonable.

This separation gives Reference Implementation Mode a clear boundary between "legitimate low-TVL mode" and "keeper anomaly halt": the former keeps vault service running without triggering fallback; the latter triggers fallback immediately to give depositors an exit path.

---

## What This Mode Changes

- **Off-chain indexer-observed staleness**: `last_realloc_time` updates less frequently; frontend dashboards need to tolerate this. Under Reference Implementation Mode, stale is normal, not a failure signal.
- **Performance-fee crystallization timing**: deferred to withdraw events or sparse Compounds; accrued performance fee **amount unchanged**, just timing of recognition delayed.
- **Treasury accrual rate**: extraction ratio from yield unchanged, just fewer transfers — once Compound triggers, Treasury still accrues precisely.

What depositors should note: **share price under Reference Implementation Mode "moves in steps"** — not gradual weekly rises, but jumps every few months. Long-term holders ultimately receive the same NAV (or more, with gas savings); short-term holders observe "lumpy" accrued yield.

---

## Why It's an 85-90% Operational Cost Reduction

Compute default cadence vs Reference Implementation Mode's annual on-chain gas:

**Default cadence (weekly Compound + 5-day heartbeat)**:
- Compound × 52 × 1.5-2.5 ADA ≈ 80-130 ADA
- Heartbeat × 73 × 0.5-1 ADA ≈ 35-70 ADA
- **Total ≈ 115-200 ADA/year**

**Reference Implementation Mode (quarterly Compound + 80-day heartbeat)**:
- Compound × 1-4 × 1.5-2.5 ADA ≈ 1.5-10 ADA
- Heartbeat × 4-5 × 0.5-1 ADA ≈ 2-5 ADA
- **Total ≈ 4-15 ADA/year**

Reduction roughly 85-95%. Combined with "no need for high-tier keeper VPS plan" (single ARM VPS at about $50/yr suffices under Reference Implementation Mode), V1's low-TVL operational cost drops to about **$80/yr** — the figure listed in whitepaper §4.3.1's cost-scaling table's lowest range.

$80/yr is a critical threshold. It means the founder's burden absorbing this cost from personal income is light enough that "no founding-capital runway needs to be drawn down" — that's the concrete meaning of V1's "structurally sustainable" claim.

---

## Mode Switch Disclosure Requirements

The keeper publicly discloses the current operational mode on the OptiVaults dashboard, including:

- Currently-active mode (Default / Reference Implementation).
- Conditions triggering the current mode.
- Time since entering the current mode.
- Next planned Compound time and estimated yield.
- Next planned heartbeat time.

Depositors can independently verify the dashboard's claims against on-chain `last_compound_time`, `last_realloc_time`, `total_deposited`. This disclosure doesn't rely on trust — depositors can reconcile against cardanoscan data.

---

## Mode Switch Mechanics

When TVL crosses $25K and deactivation conditions hold:

1. The keeper announces on the dashboard the upcoming switch back to Default Mode (notification to depositors).
2. Within 7 days, execute the next productive Compound to harvest accrued yield in one go.
3. Heartbeat cadence returns to default (every 5 days).
4. Rebalance triggers revert to default conditions.

The switch is initiated by the keeper under whitepaper §4.5 discretion. If future governance decides to automate the switch, it can run an `UpdateStrategy` action to codify trigger conditions; V1 doesn't require it.

---

## Why This Mode Reflects V1's True Positioning

The final section pulls Reference Implementation Mode back to V1's overall posture.

Many DeFi products implicitly assume "grow to self-sustaining scale = success; didn't grow = failure." Under this frame, low-TVL phases are seen as "transitional," to be crossed quickly via marketing budgets, incentives, subsidies, token releases.

V1 doesn't take this frame. **V1 is Cardano DeFi's public-goods reference implementation** — its value proposition isn't "maximize TVL," it's "implement the first non-custodial multi-stablecoin auto-yield vault on Cardano the right way." If this implementation has only $5K organic demand given Cardano ecosystem's current maturity, then operating indefinitely at $5K TVL under $80/yr operational mode is a reasonable terminal state.

This posture has several practical implications for depositors:

- **V1 has no "grow or die" time pressure**. Reference Implementation Mode is structurally sustainable — it doesn't "burn through runway and shut down."
- **V1's sunset triggers don't include TVL stuck at low levels**. What actually ends V1 is whitepaper §1.5 Class A overrides (USDCx incident, Liqwid incident, Cardano chain halt, oracle anomaly) or an explicit founder sunset decision.
- **Apache 2.0 open source means V1's value doesn't depend on it growing**. Even if V1 stays at $5K TVL, the source can still be forked and specialized by other Cardano DeFi teams — V1's contribution to the Cardano ecosystem doesn't change with its own TVL scale.

Reference Implementation Mode is the philosophy translated into concrete operational policy. **"For a vault currently operating as a public reference implementation rather than a yield product, this is the honest operational mode."**

---

## Next Article

Part 4 handles the most often-misunderstood aspect of V1's public-goods positioning: **external audit isn't a launch gate; it's a cap-lift gate**. The founder is not an underwriter for the audit; V1 launches on mainnet with a 100K USDCx hard cap regardless of audit funding status. The next article covers this volunteer-builder + community-funded audit framework's structural rationale.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/HY5sy8cz8s).*
