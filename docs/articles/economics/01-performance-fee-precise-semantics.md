# The 4.5% Performance Fee: Formula, Invariants, and the Validator-Level Hard Cap

*OptiVaults V1 Economic Model Series — Part 1 of 4*

---

V1's only protocol-level fee charged to depositors is a 4.5% performance fee. No AUM fee, no management fee, no deposit fee. The 4.5% is charged only on realised yield, at the moment yield is realised.

This is V1's design choice to reduce the most depositor-visible number to one field, one redeemer path, one structural hard cap. This article unpacks the fee's precise semantics: the formula, when it's charged versus not, and why governance cannot move the 4.5% cap under any scenario.

The whole protocol is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol).

---

## The Formula

On each Compound event, the validator computes the period's performance fee using:

```
fee_amount = 0.045 × max(0, NAV_now − NAV_last_compound − realised_rebalance_slippage)
```

Three variable definitions:

- `NAV_now` — vault's total value at the Compound event, denominated in USDCx.
- `NAV_last_compound` — NAV at the previous Compound event.
- `realised_rebalance_slippage` — sum of slippage costs from cross-market rebalances since the last Compound. Slippage = oracle fair price minus execution price.

All three variables are computed by the keeper when constructing the Compound TX, and re-verified by the validator before the fee is released. An attacker cannot say "I claim this period's NAV rose by 100" and get the validator to release the corresponding fee — the validator verifies that NAV traces to actual on-chain holdings valuation.

---

## Four Key Properties

### Negative Periods Yield Zero Fee

The `max(0, ...)` in the formula is critical. If `NAV_now < NAV_last_compound` (for example, DJED depegs or USDM Liqwid market takes bad debt), the period's performance fee is 0 — no "carry forward," no "amortize," no "deduct from next period."

What this property means: **vault holder downside aligns with operator incentive**. If the vault performs poorly, the operator earns zero. This structurally differs from the traditional asset-management model of "charge 1% AUM regardless of performance" — under V1, when NAV drops, the operator's income drops to 0.

Practical impact: if you happen to enter during a depeg period, the share price will reflect the loss, but the vault doesn't extract additional fee from you during that period. The next time NAV rises above the prior Compound's level, fee calculation resumes from that baseline.

### The Protocol Absorbs Slippage, Not the User

This detail is easy to misread.

In the formula, `realised_rebalance_slippage` is **subtracted** from the fee base — meaning rebalance slippage reduces the fee base, not directly the user's NAV.

This sounds like users still absorb slippage, since NAV is affected by slippage anyway. But the real meaning is "fee is calculated on yield net of slippage" — the keeper cannot say "more slippage doesn't matter, it all enters the fee base anyway" as an excuse to be cavalier with slippage.

Concrete example:

```
In one period:
  - Liqwid yield accrual: 1000 USDCx
  - Rebalance swap slippage loss: 100 USDCx

NAV_now − NAV_last_compound = 1000 − 100 = 900 USDCx
realised_rebalance_slippage = 100 USDCx

fee_amount = 0.045 × (900 − 100) = 0.045 × 800 = 36 USDCx
```

Without subtracting slippage, the fee would be `0.045 × 900 = 40.5 USDCx` — users would pay an extra 4.5 USDCx as "fee on slippage." V1's design treats slippage as "operational cost the protocol should absorb," not passing it into fee calculation.

### The Fee Is Charged Only on Realised Yield

qToken accruals not yet measured at a Compound event (unrealised) don't generate fee until the next Compound.

Practical impact: after you deposit, share price appreciation that hasn't reached a Compound moment hasn't had fee deducted yet. If you Withdraw between two Compounds, your share value includes the "unrealised accrual" — but in V1's design, share value already reflects the Compound-time NAV calculation. So an early exit doesn't "escape" owed fee, and conversely it doesn't pay fee that hasn't yet been incurred.

### No High-Water Mark (HWM)

Each Compound is independently computed against the prior Compound's NAV. Recovery from a previous high doesn't trigger "back-fee."

Example:

```
Compound A: NAV = 100,000 → fee_basis = 100,000 (rose vs prior) → fee charged
Compound B: NAV = 95,000  → fee_basis = max(0, 95,000−100,000) = 0 → no fee
Compound C: NAV = 98,000  → fee_basis = max(0, 98,000−95,000)  = 3,000 → fee charged
```

Note Compound C: NAV hasn't yet recovered to Compound A's 100,000 high, but it rose 3,000 versus Compound B, so this 3,000 incurs fee. Under HWM, Compound C wouldn't be fee'd (since NAV hasn't yet exceeded HWM = 100,000).

V1's choice to not use HWM is deliberate: HWM is contentious in asset management; depositors entering at different times find HWM's "back-fee" logic unfairly exempts late entrants. V1 uses "each Compound versus prior" linear settlement, so every depositor's fee ratio at any time is the same.

Whether HWM enters V1.5 or later is a governance-layer decision; V1 doesn't plan it.

---

## Validator-Level Hard Cap: 4.5% Structurally Locked

The formula is settled. But more important than the formula is: **how is the 4.5% locked?**

Many vault designs put fee rate as a mutable field set by multisig. This means "we promise not to push fee above 4.5%" is a social commitment, not an enforceable property — if the multisig colludes, fee can be pushed arbitrarily high.

V1's `vault_gov_policy.ak` enforces this cap on the `UpdateFee` redeemer path:

```aiken
fn validate_update_fee(...) {
  expect performance_fee_bps <= max_performance_fee_bps  // 450 bps = 4.5%
  expect early_withdraw_fee_bps <= max_early_withdraw_fee_bps  // 100 bps = 1%
  expect min_hold_seconds <= max_min_hold_seconds  // 21,600 sec = 6 hours
  // ... other checks
}
```

`max_performance_fee_bps` is the hard-coded `450` — not a datum field, not a redeemer parameter, but a constant inside the validator bytecode. To change this value, one must:

1. Fork the entire validator source.
2. Re-compile to produce a new script hash.
3. Redeploy the whole protocol at a new address.
4. Migrate all depositors to the new contract.

V1's compile-time anchor ([Architecture Series Article 4](../architecture/04-vault-datum-and-nft-anchor.md) + [Security Series Article 4](../security/04-phantom-vault-and-compile-time-anchor.md)) closes this path — the new contract's script hash differs entirely from V1; frontend / indexer / vusdcx / order all don't recognize it; depositors are unaffected.

So the scenario "governance pushes fee to 5%" **cannot be done on V1's deployed vault**. It isn't "we promise not to do it"; it's "the contract structurally disallows it." Anyone can verify this against the deployed script hash: disassemble the Plutus bytecode (or check against GitHub source) and confirm the constant `max_performance_fee_bps = 450` is indeed baked in.

---

## One Helper Guards All Related Caps

`validate_update_fee` doesn't only guard `performance_fee_bps`; it simultaneously guards three related fields:

| Field | Cap | Meaning |
|------|-----|---------|
| `performance_fee_bps` | 450 (4.5%) | performance-fee cap |
| `early_withdraw_fee_bps` | 100 (1%) | early-withdraw-fee cap |
| `min_hold_seconds` | 21,600 (6 hours) | direct-withdraw cooldown cap |

Why guard these three together in `UpdateFee`? Because they're economically correlated:

- `early_withdraw_fee_bps` capped at 1%, lower than `performance_fee_bps` — this blocks "governance pushes early-withdraw fee to 10%" predatory designs.
- `min_hold_seconds` capped at 6 hours — blocks "governance pushes direct-withdraw cooldown to 7 days" capital-trapping designs. Note: **the queue-withdraw path is never observed by `min_hold_seconds`**; user funds are never locked regardless of the setting. The 6-hour cap only affects the "direct withdraw vs queued path" routing choice.

The `min_hold_seconds` cap was tightened in the whitepaper from an original 24 hours to 6 hours, after deliberate review: under weekly Compound cadence, even at the 6-hour cap, the direct-withdraw gate closes only about 3.6% of any given week's time. Changing 24 hours to 6 hours strengthens depositor protection while practical impact is negligible.

---

## Comparison: Why This Structural Lock Matters

A common depositor question when picking a vault: "Will they sneak the fee up to 10%?"

Traditional answer: "We won't" — but this commitment can only be verified by social signal, not cryptography.

V1's answer: "They can't" — and this guarantee is verifiable against ledger data:

```
[1] Clone source from https://github.com/OptiVaults/optivaults-protocol
[2] Look in contracts/lib/vault/constants.ak for
    max_performance_fee_bps = 450
[3] Run aiken build; get plutus.json and vault_gov_policy script hash
[4] Query the V1-deployed vault_gov_policy script hash from Cardano
[5] The two hashes should be byte-identical — if they differ, the
    deployed validator isn't this source
[6] If hashes match → the constant max_performance_fee_bps = 450
    inside the deployed validator bytecode is a fact on the ledger
```

Anyone can independently run these six steps without trusting the founder or the operator.

That's the watershed between "structural security" and "promise-based security." V1 prefers structural security wherever possible; the 4.5% hard cap is the representative case.

---

## A Secondary But Related Disclosure: SwapAda Operational Friction

Strictly, V1 has only one "protocol-level fee" on depositors — the 4.5% performance fee. But there's one less-obvious cost stream worth honestly noting: **SwapAda operational friction**.

Mechanism: each time the vault runs `DeployToProtocol` doing a Minswap V2 swap, it pays roughly 2 ADA to batchers. Without a replenishment mechanism, the vault's ADA eventually hits the `min_vault_ada` floor. V1's `SwapAda` redeemer closes this loop on-chain: when `vault.lovelace < 15 ADA`, the keeper invokes `SwapAda`, giving the vault 10-50 ADA and exchanging for equivalent USDCx at the Charli3 + Orcfax oracle fair price.

The cost of this loop is borne by depositors — USDCx slowly drains as Minswap batch fees. At 100K TVL, roughly one SwapAda every 2-4 weeks (20-40 ADA ≈ 10-20 USDCx each), full-year friction about 0.02% APY drag — practically negligible against 4-6% gross yield.

This isn't a "fee" in the traditional sense, but it does cause vault funds to flow out, so whitepaper §2.4 and this series disclose it openly. SwapAda's contract-enforced conditions (1-hour cooldown, validity-range upper width ≤ 1 hour, oracle-fair atomic swap) are covered in depth in Operations series Part 1.

---

## Next Article

Part 2 covers **how** the 4.5% performance fee is **allocated**. Each Compound splits the fee into three streams: keeper / gov pool / treasury. V1's launch allocation is 40/0/60, evolving in future phases to 40/5/55 → 40/10/50. Why those ratios, why the keeper share is deliberately set high, why the treasury always stays at ≥ 50% — the next article covers it.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/HY5sy8cz8s).*
