# Audit Is a Cap-Lift Gate, Not a Launch Gate: The Volunteer-Builder Framework

*OptiVaults V1 Economic Model Series — Part 4 of 4*

---

The most often-misunderstood aspect of V1's economic model: **external audit is not a mainnet launch prerequisite**.

The first reaction to "audit isn't a launch gate" is usually "so you shoot first, ask questions later?" No. V1's posture is **volunteer-builder + community-funded audit** — the founder builds V1 as a volunteer, raises no VC, issues no token, solicits no equity-style commitments; but the founder also **does not act as an audit underwriter**. External audit (per commission model, $50-$150K) is borne by a community-funded stack, not by the founder's personal runway.

This separation has concrete structural meaning: V1 launches on Cardano mainnet at a 100K USDCx hard cap on launch day, regardless of whether the §8.1 audit funding stack has materialized. When external audit lands, it **unlocks the cap** to Stage 2 / Stage 3 (post-audit $500K → $2M); if funding never materializes, V1 operates at 100K cap indefinitely.

This article unpacks the framework's structural rationale: why launch / cap-lift separation, why the founder isn't an underwriter, what the Options A-D contingency tree looks like in practice, and what this posture means substantively for depositors.

The whole protocol is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol).

---

## Dual-Track Sustainability Model

First, separate two commonly conflated problems:

**(1) Audit funding — one-time, external, approximately $50-$150K**

Problem: "Can V1's 100K cap unlock to Stage 2 / Stage 3?"

Bearer: community-funded stack (the four sources listed in whitepaper §8.1).

Non-bearer: founder (explicitly does not act as underwriter).

**(2) Operational runway — long-term, founder-borne, approximately $80-$200/yr depending on TVL**

Problem: "Can V1 keep running after launch?"

Bearer: founder, sustained from personal income.

Key property: completely decoupled from audit funding.

The traditional DeFi model that binds these two problems together is "founder raises a large capital base, builds on launch, pays for audit, runs operations, waits for growth." V1 splits them apart:

- Operations is the founder's long-term commitment (minimized model brings cost to $80-$200/yr, covered in [Part 3](./03-reference-implementation-mode.md)).
- Audit is the community's option (cap-lift path, doesn't affect protocol life-or-death).

This is the core structure of the volunteer-builder framework.

---

## Why Separate Launch from Cap-Lift

Under traditional DeFi logic, external audit is the launch gate — "not audited, no mainnet." Why does V1 refuse that logic?

Several structural reasons:

### Founder Isn't an Underwriter, So Naturally Refuses to Be a Single Point of Failure

If audit is the launch gate, then "can audit funding land in time" controls whether the protocol can launch. This means:

- The founder must commit to filling any funding gap with $50-$150K of personal capital, or V1 never launches.
- Project Catalyst's reopening timeline (paused / restructuring at the time of writing), Cardano Foundation's grant review speed, any single audit firm's pricing — any one external uncertainty stalls V1's entire launch.
- To avoid the pressure of "indefinite delay = failure," the founder may end up making "unhealthy" decisions (reduce audit scope, pick a worse audit firm, or abandon audit entirely).

Separating launch from cap-lift removes all this pressure:

- V1 can launch on mainnet when §1.5 launch gates are met; depositor risk at 100K cap is bounded and clearly disclosed.
- Audit can take its time, pick the right firm, run full scope — because it doesn't gate protocol life-or-death.
- The founder isn't burdened with the single-point-of-failure pressure "I didn't raise audit money = V1 doesn't exist."

### 100K Hard Cap Is Bounded Risk, Not "Shoot First, Ask Questions Later"

"Audit isn't a launch gate" can sound like reckless launch. But that read ignores V1's concrete posture:

- **100K USDCx hard cap** is enforced at the contract layer — operators cannot exceed it.
- **Prominent pre-audit risk disclosure** is clearly marked across frontend, whitepaper, docs.
- **Multiple rounds of internal audit** have been completed (details in whitepaper §5.1 + `docs/audit-scope.md`) — internal audit cannot replace external audit, but it significantly reduces the probability of external audit finding CRITICALs.
- **Three-layer governance safety** (Security Series Part 1) provides a depositor-recovery floor independent of audit status.

Depositors entering during the pre-audit phase are doing so **within the 100K risk envelope, with full transparency** — not "I deposited not knowing the risk." V1's framing doesn't ask depositors to ignore risk — it is "given this risk is bounded and disclosed, depositors decide for themselves whether to enter."

This is more valuable to the Cardano DeFi community as a whole than "force audit wait, indefinitely delay launch." Because in the "indefinite delay" world, no one can use V1, no one can verify the contracts' production behavior, no one can do meaningful adversarial testing — all feedback comes from testnet. V1's mainnet 100K launch equates to "doing large-scale production validation in a small-stakes environment," which is also better preparation for external audit itself.

### Audit May Never Happen — That's Also an Acceptable Outcome

V1 publicly acknowledges audit-funding uncertainty. Whitepaper §8.1's Options A-D contingency tree:

- **Option A** — full $50-$150K materializes: full-scope audit commissioned, cap unlocks to Stage 3.
- **Option B** — partial materialization: scope-reduced audit commissioned, cap unlocks to Stage 2 (e.g., $250K), future top-up audit unlocks Stage 3.
- **Option C** — community crowdfund covers the gap: community-led crowdfunding fills the shortfall.
- **Option D** — never materializes: **V1 stays at 100K cap on mainnet indefinitely**.

Option D is not "failure" — it's the community's preference expressed by "not funding the audit." Under Option D:

- V1 keeps running at 100K cap on Cardano mainnet, permissionless access for anyone willing to enter within this risk envelope.
- The founder continues operating keeper and infrastructure with the $80-$200/yr personal subsidy.
- Apache 2.0 open source lets other Cardano DeFi teams fork and decide for themselves whether to pay for their own audit version.

This posture is completely different from the "couldn't raise audit money = protocol dies" dilemma — V1's value as Cardano DeFi public-goods reference implementation at 100K cap exists regardless of audit funding.

---

## Scope of Founder Commitments

Translating the volunteer-builder framework into concrete founder personal commitments, honest disclosure:

| Item | Commitment | Meaning |
|------|-----------|---------|
| Seed working capital | ~$2K USDCx | Phase 1 launch working capital |
| Operational infrastructure (18 months) | ~$200-$500 USD | Under Reference Implementation Mode + minimized configuration |
| Annual operating subsidy | $80-$200/yr | Varies with TVL tier; absorbed from founder's personal income |
| Audit gap-fill cap | ~$15K USD | Bridges the micro-gap between funding stack and final quotation |

**Cumulative maximum commitment: low five-figures USD**, across the full pre-audit + launch + indefinite 100K cap window.

This figure is **orders of magnitude** lower than audit base price — audit full price of $100-$150K exceeds V1's personal-commitment cap by 10× or more. That's the concrete meaning of "founder isn't an underwriter": the founder commits to "build the product + run operations + fill micro-gaps," not "fill audit funding no matter what."

Correspondingly, the founder's financial exposure to V1 is bounded and clear — depositors can evaluate "the risk the founder may, at some point, fail and abandon V1" against this disclosure. At low-five-figures exposure, sustained absorption from the founder's personal income doesn't depend on V1's commercial success at all; V1 won't be forced to sunset because "personal subsidy becomes too heavy."

---

## Why Audit-Funding Failure Isn't a Sunset Trigger

V1's sunset triggers (whitepaper §9.2 + economics §7.2) are four:

- **Trigger A** — Post-audit growth failure (assuming audit happens): within 6 months of external audit completion, TVL fails to reach $500K. **Applies only to post-audit world**.
- **Trigger B** — Operational runway exhaustion: founder's operational runway falls below 6 months of forward burn. Under Reference Implementation Mode + $80-$200/yr, **structurally unreachable for many years**.
- **Trigger C** — Persistent Class A override: any §1.5 Class A override (Liqwid / USDCx / Cardano chain / oracle anomaly) persisting beyond remediation period.
- **Trigger D** — Explicit founder sunset decision: medical incapacity / personal force majeure / decision to stop maintaining.

**Audit-funding failure is NOT in these four triggers**. Option D (persistent non-materialization) keeps V1 at pre-audit 100K cap, **without activating sunset protocol**. The substantive meaning of this framework for depositors:

"V1 staying at $5K TVL forever is completely acceptable. What actually ends V1 is external infrastructure failure or the founder's active sunset decision — neither triggered by TVL nor by audit funding."

---

## Why This Separation Substantively Helps Depositors

Concentrate everything above into questions depositors actually care about:

**Question 1: "V1 on mainnet without audit — how risky is depositing?"**

Answer: 100K USDCx hard cap + multiple internal audit rounds + three-layer governance safety + self-serve exit paths + Apache 2.0 open source code reviewable by anyone adversarially. Risk isn't zero, clearly disclosed in whitepaper §5. Whether to enter is the depositor's choice, but the choice is made with full information.

**Question 2: "If audit funding never materializes, what happens to my deposit?"**

Answer: V1 keeps running on mainnet at 100K cap, your USDCx remains withdrawable any time. The 100K cap doesn't affect your withdraw ability — the cap only limits the protocol's acceptance of new deposits.

**Question 3: "Will the founder one day abruptly walk away?"**

Answer: Personal subsidy commitment of $80-$200/yr is low; absorbed from personal income, structurally sustainable. If the founder actually becomes incapacitated for 90+ days, Layer 3 CommunitySunset ([Security Series Part 1](../security/01-three-layer-governance-safety.md)) lets any vUSDCx holder trigger the permissionless recovery path without operator cooperation.

**Question 4: "Why not wait until audit passes to launch, like other DeFi?"**

Answer: "Wait until audit passes" assumes the founder can underwrite the full audit cost — that's the founder-funded commercial product model, not V1's volunteer-builder public-goods model. V1's posture is "launch mainnet within the 100K risk envelope with full transparency," giving the choice to depositors, not requiring the founder to act as a single-point-of-failure underwriter.

---

## Posture Toward External Audit Firms

V1's posture toward audit firms also differs from the "commercial underwriting model":

- **No commitment to a fixed audit timeline** — target Q2-Q3 2027, but actual timing depends on §8.1 funding stack and audit firms' calendars; we don't pick a worse firm to rush launch.
- **No commitment to a fixed audit scope** — if the funding stack only covers scope-reduced audit, we do scope-reduced first and a full-scope follow-up later.
- **No commitment to a fixed audit firm** — at the time of writing, the candidate list includes Anastasia Labs, MLabs, TxPipe, and a few independent Aiken auditors. The final choice will be publicly disclosed once funding is in place and the firm's calendar is confirmed.

This posture lets audit firms apply their public-goods discount (whitepaper §8.1 (b) lists 30-50% as a possibility) given V1's public-goods positioning, and lets the audit be sized appropriately for scope and depth without commercial underwriting pressure. It's a healthier relationship for both audit firms and depositors.

---

## Implications for the Cardano DeFi Ecosystem

V1 is the first Cardano DeFi vault product launching explicitly under the volunteer-builder + community-funded audit framework. If this model proves viable through V1, it offers other Cardano DeFi teams an alternative template:

- No need to raise $50-$150K personal audit budget for launch.
- No need to bake "growth pressure" into product design.
- Can launch with the more humble but more sustainable posture of "public-goods reference implementation."

Apache 2.0 open source lets V1's design template be forked and specialized by any Cardano team (different stablecoin mixes, different risk postures, different regional variants). If V1's volunteer-builder + community-funded framework proves reasonable in practice, its value to the Cardano DeFi ecosystem as a whole exceeds V1's own TVL scale.

That's the true meaning of V1's public-goods positioning — **not "I grow large myself," but "I provide a healthy template for Cardano DeFi."**

---

## Series Wrap-Up

Four articles to here:

- **[Part 1](./01-performance-fee-precise-semantics.md)**: 4.5% performance fee precise semantics + validator hard cap
- **[Part 2](./02-three-way-fee-split-evolution.md)**: keeper / gov pool / treasury three-stream allocation and evolution
- **[Part 3](./03-reference-implementation-mode.md)**: Reference Implementation Mode — low-TVL public-goods operation
- **Part 4 (this)**: Volunteer-builder + audit-as-cap-lift-gate

The overall posture of V1's economic model: **structurally locked fee rates / three-stream separation of powers / low-TVL mode decoupled from growth pressure / audit framework decoupled from founder underwriting**. Each piece corresponds to a concrete commitment in V1's public-goods positioning — what should be written into the contract is written into the contract, what should be honestly disclosed is clearly disclosed, what should be left to the community is truly left to the community.

OptiVaults V1's full source is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Internal audit rounds have addressed findings; external audit is targeted at Q2-Q3 2027 (when funding stack materializes).

V1 launches on mainnet with a 100,000 USDCx operational cap; when external audit completes, cap unlocks to Stage 2 / Stage 3. If the funding stack never materializes, V1 operates at 100K cap indefinitely. The whole project is positioned as a Cardano DeFi public-goods reference implementation — forks, specializations, and commercial use are welcome, and adversarial review via GitHub Issues or [Discord](https://discord.gg/HY5sy8cz8s) is invited.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app).*
