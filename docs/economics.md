# OptiVaults V1 — Economics

**Scope**: how money flows through the protocol, who pays for what, and when the protocol becomes self-sustaining.

**Layer scoping (important)**: all fee figures in this document describe **the OptiVaults-operated vault instance** running at `optivaults.app` — specifically the interaction between depositors and the operator layer ([`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference)). The **protocol layer** ([`optivaults-protocol`](https://github.com/OptiVaults/optivaults-protocol)) is zero-fee: forks of the Aiken contracts owe OptiVaults nothing regardless of their operational choices. When governance sets `performance_fee_bps`, it sets the rate **for that specific vault instance**; the 4.5% hard cap in the contract is a protocol-level constraint on *any* vault running those validators, not a flow of funds to OptiVaults itself. See `whitepaper §3.5` for the full two-layer framing.

---

## 1. Fee structure at a glance

### 1.1 Deposit side

- **Direct Deposit**: no fee; user sends N USDCx, receives fair share of vUSDCx based on current share price
- **Queue Deposit** (order-batched): no protocol fee; user pays approximately 0.5 ADA in network + batcher tip (user-specified `max_batcher_tip`)

### 1.2 Withdrawal side

- **Direct Withdraw**: 0.1% of the withdrawal amount in USDCx retained in the vault (accrues to remaining holders via share-price increase); waived when the keeper has been inactive ≥ 7 days
- **Queue Withdraw** (order-batched): no protocol fee; user pays approximately 1 ADA in network + batcher tip
- **Emergency Withdraw** (user-triggered after 7 days of keeper inactivity): no fee (contract-enforced)

### 1.3 Yield side

- **Performance fee**: 4.5% of harvested yield, extracted on each Compound operation
- **Hard cap**: 4.5% — enforced at contract level; governance cannot raise performance fee above this under any redeemer
- **Loss compound**: when on-chain yield is negative, the fee is forced to zero (no fee taken on losses)
- **Zero-yield compound**: when on-chain yield is zero, allocation-only Compound progresses `last_realloc_time` but extracts no fee

Performance fee is split 3 ways, governed by `VaultDatum.keeper_fee_bps` and `VaultDatum.gov_fee_bps` (treasury share derived):

| Phase | Trigger | Keeper | Gov pool | Treasury |
|-------|---------|--------|----------|----------|
| V1 launch | Deploy default | 40% | 0% (disabled) | 60% |
| Phase 2 | TVL ≥ 500K + external signer added | 40% | 5% | 55% |
| Phase 3 | TVL ≥ 2M + community signer added | 40% | 10% | 50% |

**Hard caps** (enforced in `vault_gov_policy.ak` UpdateFeeSplit redeemer via the shared `validate_update_fee_split` helper, cannot be changed by any governance action):
- `keeper_fee_bps <= 4000` (40% — set high to support open-source third-party keeper viability under V1's public-goods positioning)
- `gov_fee_bps <= 1000` (10%)
- `keeper_fee_bps + gov_fee_bps <= 5000` (treasury floor ≥ 50%)

**Each fee-split change is a separate `UpdateFeeSplit` governance TX with 21-day timelock** (§4.3 of `spec/governance.md`) — longest timelock of any action, because governance is adjusting its own pay.

Keeper share: paid in USDCx directly to the signing keeper's address. If multiple keepers share duties, income distributes across them per the weekly rotation mechanism (see `spec/keeper-auth.md` §4).

Gov pool share: accumulates into MultisigGov UTXO's `signer_compensation_pool` field, distributed quarterly via `DistributeSignerCompensation` redeemer (see §6 Gov Signer Compensation below).

Treasury share: split across four category buckets per `spec/treasury.md`.

---

## 2. Revenue at various TVL levels

Performance-fee annual revenue assuming 6% gross APY and 4.5% fee rate:

| TVL | Gross yield/yr | Perf fee 4.5% | Keeper 40% | Treasury 60% |
|-----|----------------|---------------|------------|--------------|
| 100K USDCx (pre-audit cap) | 6,000 | 270 | 108 | 162 |
| 500K USDCx | 30,000 | 1,350 | 540 | 810 |
| 1M USDCx (sustainability threshold) | 60,000 | 2,700 | 1,080 | 1,620 |
| 10M USDCx | 600,000 | 27,000 | 10,800 | 16,200 |
| 100M USDCx | 6,000,000 | 270,000 | 108,000 | 162,000 |

All figures in USDCx. Numbers are illustrative reference points, not forecasts.

---

## 3. Treasury category flow

60% treasury share flows into four buckets at launch ratios 40/25/25/10 (governance-adjustable within bounds — sub-allocation rebalanced from the historical 30/40/20/10 to keep audit-reserve accumulation at 24% of total fee under the smaller treasury share, since the new 40% keeper direct share absorbs per-keeper infra cost that the ops bucket previously double-funded):

| Category | Ratio | $/yr at 100K TVL | $/yr at 1M TVL | $/yr at 10M TVL | Purpose |
|----------|-------|------------------:|----------------:|----------------:|---------|
| Audit reserve (40%) | 65 | 648 | 6,480 | Accumulates toward the next third-party audit invoice (24% of total fee, same accumulation rate as historical 80%×30%) |
| Operations (25%) | 41 | 405 | 4,050 | Platform-layer infrastructure: VPS (frontend/landing/API), Blockfrost (platform queries), monitoring, domains, CF Pages — per-keeper infra now funded directly via 40% keeper share, not from this bucket |
| R&D (25%) | 41 | 405 | 4,050 | Protocol development, future bounty program (post-audit + TVL-scale, `docs/audit-scope.md §6.3`), ecosystem grants |
| Buffer (10%) | 16 | 162 | 1,620 | Unexpected costs, legal consultation, incident response |

---

## 4. Operating cost of V1 protocol infrastructure

A minimum-viable V1 deployment requires:

| Item | Cost (order of magnitude) | Notes |
|------|---------------------------|-------|
| VPS for keeper (dual-instance for HA) | $10–25/mo × 2 instances = $20–50/mo | Hetzner / DO / similar. Dual-instance preferred for keeper high-availability (see whitepaper §8.4). |
| Blockfrost API access | $0–100/mo | Free tier supports ~50 req/min sustained; paid tier required above that or for dedicated key rotation |
| Monitoring + alerting | $5–20/mo | Grafana Cloud free tier, or self-hosted stack |
| Domain + CDN (frontend + landing) | $2–10/mo | Cloudflare Pages free for static; domain registrar |
| Email / Discord / communication | $0–10/mo | Mostly free, optional paid relay for deliverability |
| **Total** | **$30–200/mo** = **$360–2,400/yr** | Steady-state range for V1-scale operations |

At the pre-audit 100K TVL cap, treasury operations bucket receives ~41 USDCx/yr (~$41) under the new 60%×25% allocation, while the keeper directly receives ~108 USDCx/yr from the 40% direct share. Combined keeper-related budget ~$149/yr at 100K. **This still does not cover the low-end operating cost estimate** ($360-$2,400/yr) — the gap is absorbed by the protocol operator's out-of-pocket subsidy during the pre-audit phase. E2's split shifts subsidy from "indirect via TreasurySpend reimbursement of keeper infra costs" to "direct via 40% keeper share at every Compound", removing one layer of governance friction while leaving the absolute Phase 1 shortfall unchanged.

---

## 5. Path to sustainability

### 5.1 Revenue-vs-cost crossover

Under E2 launch sub-allocation (25% of 60% = 15% of fees to operations bucket):

- **15% of `(TVL * 6% * 4.5%)` = annual ops budget**
- Crossover (ops budget = $360/yr low-end cost): `TVL = $360 / (6% * 4.5% * 15%) ≈ $889,000`
- Crossover (ops budget = $2,400/yr high-end cost): `TVL = $2,400 / (6% * 4.5% * 15%) ≈ $5.93M`

The "operations bucket alone covers basic infrastructure" threshold is approximately **USD 900K TVL** for minimum viability, **USD 6M TVL** for comfortable margin under E2 — pushed back ~2× from the pre-E2 numbers because ops bucket shrunk from 32% to 15% of fee. **The shift is offset by the 40% keeper direct share absorbing per-keeper infra cost directly** (combined keeper-related budget actually slightly increased, from 52% of fee to 55% of fee). Platform-layer ops (frontend, landing, API server, treasury monitoring) is what the smaller ops bucket needs to cover — individual keeper VPS / Blockfrost / monitoring is funded by the keeper's own 40% share.

Below this, V1 operates in a **bootstrapping phase** where running costs exceed treasury inflow. Initial shortfalls are absorbed by the project's founding capital. Above the crossover, OptiVaults' own revenue funds the baseline protocol operation, and higher TVL incrementally funds audit reserve + R&D + buffer categories.

### 5.2 Audit reserve fill rate

Target third-party audit cost: approximately **USD 50–150K per engagement**, with one engagement anticipated every 12–24 months at mature operation.

Annual audit-reserve accumulation at various TVL levels:

| TVL | Audit reserve/yr | Years to $50K reserve | Years to $100K reserve |
|-----|------------------|-----------------------|-------------------------|
| 100K | 65 | 770 | — (not viable) |
| 500K | 324 | 155 | — |
| 1M | 648 | 77 | 155 |
| 5M | 3,240 | 15 | 31 |
| 10M | 6,480 | 8 | 15 |
| 25M | 16,200 | 3 | 6 |
| 50M | 32,400 | 1.5 | 3 |

Reading: **audit reserve self-funds the next full audit at approximately 25–50M TVL** on an 18-month cycle. Below this scale, audits are funded via a non-dilutive stack of external sources (see §5.2.1 below).

### 5.2.1 Audit funding stack under public-goods path (V1 pre-audit)

V1's public-goods positioning (see whitepaper §8.1 + Executive Summary) enables a stack of non-dilutive funding sources to cover the external audit (Q2-Q3 2027 target — see `audit-scope.md §5`) without VC / token / SAFE / SAFT exposure:

| Source | Expected amount | Status | Reference |
|--------|-----------------|--------|-----------|
| (a) Cardano Project Catalyst grant | $30K-$50K | **Catalyst paused / restructuring as of writing — no confirmed Round timeline.** V1 retains (a) as candidate pending resumption but does not depend on it. | Whitepaper §8.1 |
| (b) Audit-firm public-goods rate | 30-50% discount on $100K-$150K full price | Outreach pending | Whitepaper §8.1 |
| (c) Scope reduction via extensive internal audit history | -$15K-$25K from full scope | Heritage audit work | `audit-scope.md §1` |
| (d) Founder self-fund remainder | $20K-$40K if (a) lands; **$50K-$90K if (a) does not materialise before audit kickoff** | Founding-capital allocation | Whitepaper §4.1 |

Audit timeline (Q2-Q3 2027 target — see `audit-scope.md §5`) is set explicitly later than the original Q3 2026 plan to accommodate (i) Catalyst Round resumption probability, (ii) Cardano Foundation / Intersect / Aiken Foundation alternative grant outreach, and (iii) founder runway accumulation if (a)/(b) outcomes are conservative. Total expected founder out-of-pocket after stack: **$20K-$40K** in the (a)-lands scenario, scaling up to **$50K-$90K** in the (a)-does-not-land scenario. This stack lets V1 complete external audit without VC / token fundraising / diluting Apache 2.0 public-goods posture. Status updates for each source published via GitHub issue labeled `audit-funding-status` as they progress.

### 5.3 Keeper share viability

Keeper share is 40% of performance fee at V1 launch; per-year = `TVL × gross_APY × 0.018`. The table below assumes 6% current reference blended APY + a **3-keeper rotation** each taking ⅓ of keeper pool + $360/yr VPS-amortised infrastructure cost per keeper:

| TVL | Keeper pool/yr | Per keeper (3 active) | Net of $360/yr VPS cost |
|-----|-----------------|------------------------|--------------------------|
| 100K | 108 | 36 | −324 (loss) |
| 500K | 540 | 180 | −180 (loss) |
| 1M | 1,080 | 360 | 0 (break-even) |
| 5M | 5,400 | 1,800 | +1,440 (economically viable) |
| 10M | 10,800 | 3,600 | +3,240 (attractive) |
| 100M | 108,000 | 36,000 | +35,640 (highly attractive) |

**Reading**: in the 3-keeper rotation configuration above, third-party keepers become economically viable at approximately **USD 5–10M TVL**. Below that, keepers run at a loss unless they're amortizing infrastructure across multiple protocols (e.g., already running batchers/keepers for other Cardano DeFi products).

This is why V1 ships with `RegistrationMode = GovernanceOnly` — there's no point opening permissionless keeper registration when there's no economic incentive to attract third parties. The mechanism becomes economically meaningful around $5M TVL, at which point governance can flip to `PermissionlessWithBond` mode with a single on-chain action (no contract migration required — see `spec/keeper-auth.md` §5).

**Three self-sustain tiers — different configurations give very different thresholds.** The table above assumes a specific configuration (3 active keepers, $360/yr each). V1 actually has three distinct self-sustainability thresholds, depending on who runs the keeper and under what APY conditions:

| Tier | What it covers | Annual cost | Breakeven TVL (6% current APY) | Breakeven TVL (2% pessimistic APY) |
|------|---------------|------------:|------------------------------:|------------------------------------:|
| (a) Single founder-keeper, marginal ops | Founder absorbs own labour and shares existing infra | $100–$300 | $185K – $555K | $555K – $1.67M |
| (b) Single non-founder professional keeper | Independent operator, dedicated VPS + monitoring | $400–$800 | $740K – $1.48M | $2.22M – $4.44M |
| (b') 3-keeper rotation (table above) | 3 independent operators each absorbing $360/yr | $1,080 total | ~$2M | ~$6M |
| (c) Institutional-grade ops + audit-reserve accrual | Full protocol self-sustain including future audit cost ($30–50K every 18–24 months amortised) | $1,500–$3,000 + audit amortisation | $20M+ | $50M+ |

**The $5–10M figure** in the table above corresponds to **tier (b') 3-keeper rotation under pessimistic 1–2% APY** (a deliberately conservative framing so that V1 remains viable even when Liqwid rates compress, not just under current reference conditions). Under **6% current APY + single non-founder keeper (tier b)**, viability resolves at $740K–$1.48M — much earlier. V1's actual self-sustain target is tier (a)/(b), not tier (c); tier (c) is explicitly covered by the §5.1 four-source audit funding stack (Catalyst + public-goods rate + scope reduction + founder self-fund), not by protocol-revenue accrual. This is consistent with V1's non-commercial public-goods positioning — V1 does not need to scale to $20M+ TVL to be "fully self-sustaining." Whitepaper §4.3 has the depositor-facing version of this breakdown.

**SwapAda impact on keeper viability.** Prior internal-verification-phase operations required the keeper to top up vault ADA out-of-pocket (vault burns ~2 ADA per Minswap V2 order; without on-chain replenishment the founder-keeper had to manually send ADA to the vault every ~2–4 weeks). V1's `SwapAda` redeemer (`spec/ada-swap.md`) closes this loop on-chain: the keeper contributes ADA in exchange for oracle-priced USDCx from the vault — a **fair barter**, not a donation. Keeper-side economic impact: the ADA-for-USDCx conversion the founder previously executed off-chain on Minswap (and paid slippage on) is now a validator-gated atomic TX. Net effect on the keeper viability table above: **neutral to mildly positive** — per-cycle ADA network fees for SwapAda (~1 ADA/TX × ~15 TX/year = 15 ADA ≈ $10/yr at 100K TVL) are fully absorbed by eliminating the equivalent Minswap slippage/fee cost the keeper used to pay. The depositor side bears the Minswap V2 batcher fees via a slow USDCx drain (~0.02% APY at 100K TVL); this drag is factored into the "Expected net APY" row in §6.2. In a multi-keeper rotation (Phase 2+ Mixed/PermissionlessWithBond mode), SwapAda operations are distributed across keepers in the same fair-share rotation as Compound / BatchProcess — no single keeper is disproportionately burdened.

---

## 6. Depositor return expectations

### 6.1 Net APY formulas

For a depositor:

- **Net APY** = gross APY × (1 − performance_fee_rate) − other frictions
- With 4.5% fee: net APY ≈ gross × 0.955
- With 0.1% direct-withdraw fee: one-time 0.1% cost on exit (or zero if using Queue Withdraw / Emergency Withdraw)

### 6.2 Scenarios

Illustrative scenarios (not forecasts; actual yield depends on Liqwid market conditions and strategy allocation). Launch allocation is 45% DJED + 25% USDM + 30% idle USDCx buffer (buffer = 0% yield at V1 launch; see whitepaper §2.3 for future-adjustability note):

| Scenario | Assumed Liqwid rates | Gross APY math | Gross APY | Net APY (after 4.5% fee) |
|----------|----------------------|-----------------|-----------|---------------------------|
| Pessimistic (DJED/USDM rate compression, weak borrow demand) | DJED 2-3%, USDM 1-2% | `(0.45×2-3%) + (0.25×1-2%) + (0.30×0%)` | 1.15–1.85% | 1.10–1.77% |
| Current reference (2026-04-21 Liqwid snapshot) | DJED ~11.84%, USDM ~5.33% | `(0.45×11.84%) + (0.25×5.33%) + (0.30×0%)` | ~6.66% | ~6.36% |
| Optimistic (sustained high borrow + governance-approved buffer yield of ~1%) | DJED 13-16%, USDM 6-8%, buffer 1% yield via UpdateStrategy | `(0.45×13-16%) + (0.25×6-8%) + (0.30×1%)` | 7.65–9.50% | 7.31–9.07% |

The `(0.30 × 0%)` buffer term at launch reflects the explicit design decision to keep the idle USDCx buffer liquid (see whitepaper §2.3 for why). Governance can redirect some or all of the buffer into a yield-bearing position via `UpdateStrategy` — this would lift the buffer term from 0% upward. Any such change is publicly disclosed + timelocked 7 days before execution.

### 6.3 Honest comparison to alternatives

For a depositor already holding USDCx (the deposit-asset universe — no ADA price exposure):

| Alternative to OptiVaults | Typical net APY | Risk stack |
|---------------------------|------------------|------------|
| Hold USDCx in wallet (do nothing) | 0% | Issuer only |
| Liqwid direct USDCx supply | ~0.5–2% (variable, typically well below vault blend) | Liqwid + issuer |
| Minswap V2 stable-pair LP | Variable + impermanent loss | Minswap + IL + issuer |
| **OptiVaults V1** (pessimistic) | 1.05–1.67% | Vault + Liqwid + keeper + governance + depeg + issuer |
| **OptiVaults V1** (current reference) | ~6.08% | Same |

At the pessimistic end, OptiVaults' return is broadly comparable to a careful direct-Liqwid strategy but with additional risk layers (vault contracts, keeper, governance, depeg monitor). The value proposition is stronger in mid-to-high rate environments where the keeper's diversification and auto-compounding overhead amortization materially outperform manual-allocation alternatives.

**ADA native staking (~2.3–2.4%)** is not a direct comparable — it requires holding ADA and introduces ADA price exposure. A depositor who has chosen to hold USDCx has (implicitly or explicitly) decided not to take ADA price risk.

---

## 7. Bootstrapping-phase disclosure

At the pre-audit 100K TVL cap, OptiVaults' own revenue does not cover its operating costs. The gap — on the order of **USD 300–2,000 per year** depending on infrastructure choices — is absorbed by the project's **founding capital** during the pre-audit / initial-deposit phase. This is a normal bootstrapping state for a new DeFi protocol and is expected to resolve organically as TVL reaches the self-sustaining range.

### 7.1 Continuity posture

V1's operational posture: **"continuation of operations through the Q2-Q3 2027 audit window (see `audit-scope.md §5`) and the post-audit TVL ramp-up period, up to the limits of available founding capital"** — **not** a contractually-enforceable long-term guarantee.

A prudent planning horizon for prospective depositors is therefore: "assume the product continues operating normally through the audit + a 6–12 month post-audit ramp period; re-evaluate at each milestone."

### 7.2 Orderly-sunset protocol (if founding capital is exhausted before sustainability)

If the bootstrapping runway ends and TVL has not yet grown into the self-sustaining zone:

1. A public wind-down notice is published (Discord + GitHub issue + on-chain governance action) **with at least 30 days of lead time**
2. Governance executes `EmergencyWithdraw { frozen: 1 }` on V1 vault — freezes Compound / Batch / Deploy; **Withdraw remains open**
3. Governance drains all deployed capital back to idle buffer via `RecallFromLiqwid` + `MergeUtxo` + (if any stranded non-USDCx) `AdminDeployNonDeposit` → Minswap V2 → USDCx
4. Users withdraw via Direct Withdraw (fee-free after 7d keeper inactivity) or the self-serve `withdraw-cli` / `emergency-withdraw` tools
5. Once `total_deposited == 0`, the vault UTXO is destroyed and the protocol is fully retired

**Minimum on-chain operating-capital reserve at sunset trigger**: the founding entity commits to retaining at least ~150 ADA earmarked from founding capital to cover the 90-day settlement window's on-chain fees (keeper heartbeat + Liqwid full recall + Minswap V2 router gas + Conway-era ref-script fee surcharge + safety buffer). See whitepaper §4.1 for the itemised breakdown. This guarantees the sunset window has independent funding even if primary founding capital is exhausted (which is itself one of the sunset triggers), so depositors do not face "withdrawal TXs failing because the operator ran out of ADA."

### 7.3 Non-enforceability of the 30-day notice

The 30-day notice commitment has **no contract-level enforcement mechanism**. It relies on:

1. Project team's self-discipline and governance
2. Reputational cost of a silent shutdown in the Cardano ecosystem
3. The independent on-chain guarantee that user principal is **never trapped** — Withdraw is always open, and after 7 days of keeper inactivity the early-withdraw fee is automatically waived

Users do not depend on the 30-day notice to be made whole; it is a courtesy, not a prerequisite for exit.

---

## 7A. Governance-signer compensation mechanics

Phase 2+ activates a governance-signer compensation pool via `UpdateFeeSplit` raising `gov_fee_bps` from 0 to 500 (5%) or 1000 (10%).

### 7A.1 Accumulation

Each Compound TX routes `gov_fee_bps / 10000` of the performance fee into the MultisigGov UTXO's `signer_compensation_pool` field. Pool accrues continuously; distribution is quarterly (§7A.3).

### 7A.2 Qualification (X3 hybrid rule)

A signer qualifies for quarter Q's distribution if BOTH hold:

1. **Full-quarter tenure**: signer joined before Q started (`signer_joined_at_ms <= last_distribute_ms`)
2. **Actual participation**: during Q, the signer signed ≥ 1 of:
   - `QueueAction`, `ExecuteAction`, `CancelAction`, `RotateSigners` (operational governance work)
   - `Heartbeat` (explicit liveness attestation — rate-limited to 1 per 90 days per signer)

Rationale: quiet quarters with no governance actions shouldn't disqualify all signers — Heartbeat is the fallback signal. Conversely, a signer who joins mid-quarter must wait for next quarter to qualify (prevents gaming the tenure rule via last-minute rotation).

### 7A.3 Quarterly distribution

Any current signer can trigger `DistributeSignerCompensation` (1-of-n) after the 90-day cadence elapses. The pool is divided equally among qualified signers, paid in USDCx to each qualified signer's address.

### 7A.4 Forfeit flow (Y1: forfeit to audit reserve)

Unqualified signers' shares are forfeited to the Treasury `audit_reserve_balance` via `ReceiveGovForfeit` on the treasury side, bypassing the normal 4-category split. Rationale:

- Avoids the "hope my colleagues fail" perverse incentive (if forfeit redistributed to qualified signers)
- Strengthens the most safety-critical budget category
- Consistent with depositor protection as the highest priority

### 7A.5 Projected compensation (yield assumption: 5.5% gross APY)

| TVL | Phase | gov_fee_bps | Pool / year | Signers | Per signer / year (qualified) |
|-----|-------|-------------|-------------|---------|-------------------------------|
| 100K | 1 | 0 | $0 | 3 | $0 |
| 500K | 2 | 500 | $82 | 5 | ~$16 |
| 1M | 2 | 500 | $165 | 5 | ~$33 |
| 2M | 3 | 1000 | $660 | 7 | ~$94 |
| 5M | 3 | 1000 | $1,650 | 7 | ~$236 |
| 10M | 3 | 1000 | $3,300 | 7 | ~$471 |
| 50M | 3 | 1000 | $16,500 | 7 | ~$2,357 |

**Honest read**: signer compensation is symbolic below USD 5M TVL. Signers participate primarily for non-financial reasons (reputation, influence, alignment with protocol success). See `docs/security-model.md` §2 for the signer identity model and `spec/gov-nft.md` for the soul-bound Gov Signer NFT that formalizes the reputation claim.

---

## 7B. Keeper compensation with multi-keeper rotation

Phase 2+ can add additional authorized keepers via `UpdateKeeperAuth`. From that point, the keeper fee rotates across all authorized keepers via **weekly round-robin** primary assignment (see `spec/keeper-auth.md` §4).

### 7B.1 Fee flow

Each Compound / MergeUtxo / BatchProcess / Supply / Recall TX routes `keeper_fee_bps / 10000` of the relevant fee or yield directly to the signing keeper's PKH address. Over one full rotation cycle, each authorized keeper earns approximately `1/N × keeper_total_fee` where N is the active set size.

### 7B.2 Keeper operating costs

| Cost item | Low-end | Standard | High-availability |
|-----------|---------|----------|-------------------|
| VPS (keeper instance) | $60/yr | $240/yr | $600/yr |
| Blockfrost keys ×2 | $360/yr | $720/yr | $1,800/yr |
| Monitoring + alerting | $50/yr | $200/yr | $500/yr |
| Backup / HA tooling | $0 | $100/yr | $500/yr |
| **Total** | **~$470/yr** | **~$1,260/yr** | **~$3,400/yr** |

### 7B.3 Keeper net income at various TVL (standard cost tier)

Additional per-TX cost from the A-Plain authorization pattern (keeper_auth UTXO spend on every keeper TX): approximately $292/yr at 8 TX/day steady state. Budgeted as keeper operating overhead.

| TVL | Gross keeper fee 40% | Standard ops + A-Plain cost | Net |
|-----|----------------------|-----------------------------|-----|
| 100K | $108 | $1,552 | **-$1,444** (founding-capital subsidy absorbs gap) |
| 500K | $540 | $1,552 | -$1,012 |
| 1M | $1,080 | $1,588 | **-$508** (still below break-even, but ~half the prior gap at 20%) |
| 5M | $5,400 | $1,734 | **+$3,666** |
| 10M | $10,800 | $1,810 | **+$8,990** |
| 25M | $27,000 | $2,078 | **+$24,922** |

**Break-even TVL**: approximately USD 3–4M for standard-tier keeper economics. Below that, keepers operate at a loss; non-founder operators are not economically viable. Phase 4 `PermissionlessWithBond` activation is gated on TVL reaching this threshold.

---

## 7C. Treasury R&D category — integration bounties and contributor program

The R&D category (25% of treasury inflow at V1 launch) funds:

1. **New protocol integrations** — new DEX routes, new Liqwid markets, new lending protocols (see `docs/integration-playbook.md` when written, for the 7-step SOP)
2. **Contributor bounties** — open-source contributions to keeper / frontend / docs (Phase 2+ formalization pending; see `docs/contributor-program.md` when written)
3. **Tooling development** — monitoring extensions, recovery tools, auditor tooling

**V1 launch contributor-reward posture**: informal at 100K TVL. Task-based bounty programs activate when R&D balance accumulates to approximately USD 500 (approximately Phase 2 timing). Until then, recognition is informal — a Contributor NFT is pending design alongside the formal bounty program.

**R&D budget availability**:

| TVL | R&D category annual inflow | Practical bounty capacity |
|-----|----------------------------|---------------------------|
| 100K | ~$43/yr | None — recognition only |
| 500K | ~$216/yr | ~1 small bounty ($150–250) |
| 1M | ~$432/yr | ~2 small bounties |
| 5M | ~$2,160/yr | ~4–6 bounties + 1 major integration |
| 10M | ~$4,320/yr | Full program with formal RetroPGF-style rounds |

---

## 8. Post-audit cap schedule

Post-audit (Q2-Q3 2027 target — see `audit-scope.md §5`), the 100K USDCx TVL cap is expected to be relaxed in stages. The exact schedule will be published in the audit report and is not committed here in advance; the current intention is a staged ramp that correlates audit findings remediation with each cap-raise milestone. A representative illustrative schedule:

| Stage | Trigger | TVL cap |
|-------|---------|---------|
| V1 launch | Pre-audit | 100K USDCx |
| Stage 2 | Audit findings fully remediated + 30-day clean operation | 500K USDCx |
| Stage 3 | 6-month clean operation post-audit + no outstanding medium+ findings | 2M USDCx |
| Stage 4 | 12-month clean operation + community governance fully staged per whitepaper §8.6 | Uncapped |

These are indicative — actual schedule TBD post-audit. The only committed property is that **cap increases are gated on externally-verifiable milestones**, not discretionary operator decisions.

---

## 9. Liqwid / Minswap / USDCx — fee leakage to external protocols

OptiVaults' own fee structure is only one part of the depositor's net-yield calculation. Additional frictions:

| Friction | Typical magnitude | Who captures |
|----------|-------------------|--------------|
| Liqwid protocol (qToken rate spread) | Minimal (pass-through) | Liqwid Labs + liquidity providers |
| Minswap V2 swap fees | ~0.3% per swap leg | Minswap pools |
| Cardano network fees (per transaction) | ~0.2–1 ADA | Cardano protocol (burned) |
| Blockfrost / Ogmios rate-limit upgrades | Included in operations bucket | Blockfrost Labs |

Depositor net-yield formula (approximately):

```
Net Yield ≈ Gross Liqwid yield
           × (1 − 4.5%)                       [performance fee]
           − (swap leg frictions, amortized over deploy/recall cycles)
           − (Cardano network fees on deposit/withdraw)
           − (one-time 0.1% if Direct Withdraw, else zero)
```

For an average deposit holding 12+ months, network + swap frictions are typically < 0.5% of principal amortized, so the dominant rate-driver remains the 4.5% performance fee plus Liqwid's own market rate.

---

## 10. Summary for depositors

**In plain terms**:

- You deposit USDCx. The vault gives you vUSDCx shares.
- Yield accrues via auto-compounding; no action needed.
- Fees you pay: **none on deposits, 0.1% on direct withdrawals**, 4.5% of harvested yield (never your principal).
- Fees the keeper earns: **40% of the 4.5% harvest fee** at V1 launch (≈ 1.8% of yield, set high to support open-source third-party keeper viability). The other 60% (2.7% of yield) goes to on-chain treasury with category-bucketed spend rules.
- **V1 launches in a bootstrapping phase** — at 100K TVL, revenue does not fully cover operating costs. V1 has three self-sustain tiers (§5.3): (a) founder-keeper marginal ops break even at $185K–$555K TVL (current APY) / $555K–$1.67M (pessimistic APY); (b) non-founder professional keeper at $740K–$1.48M / $2.22M–$4.44M; (c) institutional ops + audit-reserve accrual at $20M+ / $50M+. V1's actual target is tier (a)/(b); tier (c) is deliberately NOT a target — audit funding comes from §5.1 four-source stack (Catalyst + public-goods rate + scope reduction + founder self-fund), not from treasury accrual. Initial Phase 1 shortfalls are absorbed by the project's founding capital; if growth stalls below tier (a), §7.2 sunset protocol engages.
- **Your principal is never trapped** — Withdraw is always available on-chain regardless of keeper state, hosted infrastructure availability, or founder status.

See `whitepaper/whitepaper.md` for the full depositor-facing document with risk disclosures, and `docs/security-model.md` for trust-boundary analysis.
