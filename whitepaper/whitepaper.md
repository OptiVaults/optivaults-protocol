# OptiVaults V1 Whitepaper

**Version 1.4.2 — Public Launch Candidate**
**Target Network: Cardano Mainnet**
**Deposit Token: USDCx**

---

## 0. Project Philosophy & Phasing

OptiVaults is built on a single conviction: **launching at the right moment matters more than launching first**.

Cardano DeFi is in a structural transition. USDCx integration via Circle's xReserve (February 2026) introduced institutional-grade stablecoin liquidity for the first time. Pogun's BTC DeFi rollout (2026 Q2 onwards) will, if executed, introduce the borrow-side demand that has been structurally absent from Cardano stablecoin lending markets. Leios scaling and Midnight's DeFi Kernel are scheduled to mature throughout 2027.

A stablecoin yield vault that launches before these catalysts is solving a problem that does not yet exist at scale. A stablecoin yield vault that launches after these catalysts is positioned to capture them.

We have therefore organised the project as follows:

**Phase 1 — Pre-Catalyst (Preprod-only; until §1.5 launch gates clear)**
- Smart contracts deployed and validated on Cardano preprod testnet
- Source code public on GitHub under Apache 2.0
- Whitepaper, documentation, and design specifications maintained openly
- Three-axis trigger framework (§1.5) monitored and reported monthly
- Parallel development of complementary products (fixed-rate vault, Pogun adapter) per §1.7
- **No V1 mainnet operation yet.** A separate **internal-verification-era deployment** (pre-V1 contract iteration) exists on Cardano mainnet with founder-gated frontend access for internal testing only — this is **not** the V1 design described in this whitepaper, and is disclosed in §0.1 so readers understand which deployment they are reading about. That deployment will be fully unwound before the V1 mainnet launch ceremony.

**Phase 2 — Pre-Audit Mainnet (Stages 1 / 1.5 / 2 per §1.5; TVL cap $10K → $100K)**
- V1 launches on Cardano mainnet **at the pre-audit cap** when §1.5 launch gates are met (§1.5 Class A overrides clear + axis state at One-Yellow or better + internal audit complete + Preprod E2E + deploy ceremony dry-run — see §8.1)
- External audit is **not** a launch precondition; V1 operates on mainnet with prominent pre-audit risk disclosure (§8.2)
- TVL caps progress $10K → $25K → $100K as axis state improves per §1.5 Stage matrix
- Founder operates as keeper + governance signer (1-of-3 under configuration (a) with independent SPOs / all 3 under base-case configuration (b) with HD-key separation per §7.4) under §4.3.1 minimal-operations policy (~$80–$200/year operating subsidy, no large founding-capital draw)
- Reversal conditions automatically downgrade caps if external infrastructure deteriorates (§1.5)

**Phase 3 — Audit + Cap-Lift Window (parallel to Phase 2; activates when §8.1 audit funding stack delivers)**
- External audit engaged with funded scope — Anastasia Labs / MLabs / TxPipe / independent Aiken auditors, depending on §8.1 (a)–(d) outcome
- Audit completion **lifts the cap** from 100K toward Stage 3 ($500K initial, ramp to $2M per §1.5 ramp schedule)
- Mainnet operation continues uninterrupted at 100K cap throughout the audit window
- If §8.1 funding stack underperforms, Options A–D apply — all four options keep V1 live on mainnet at the 100K cap (see §8.1)

**Phase 4 — Operational (Stage 3+ post-audit; conditional on Phase 3 success)**
- Multi-product offering aligned with mature Cardano DeFi ecosystem
- Governance phasing toward community DAO (§6.1 rotation path)
- Treasury self-sustaining through performance fee accrual at ≥ $500K TVL (§4.1 baseline)
- If Phase 3 never completes (audit funding never lands — §8.1 Option D), V1 stays in Phase 2 indefinitely (mainnet, 100K cap) rather than transitioning to Phase 4

**What we do not promise**
- We do not commit to a calendar date for mainnet launch.
- We do not commit to capturing first-mover narrative.
- We do not adjust TVL caps or launch timing for marketing reasons.

**What we do commit to**
- Continuous, publicly verifiable development progress (monthly dev reports).
- Transparent trigger conditions, monitored on a public dashboard.
- User funds prioritised over protocol survival under any adverse condition.
- Honest disclosure of what we do not know, including ecosystem timing risks.

This document describes the V1 design as it will be deployed *when* §1.5 launch gates are met (per §8.1's "Required for mainnet launch under the 100K USDCx pre-audit cap" checklist). It is not a launch announcement: the launch gates are forward-looking criteria, and V1 has not yet executed the mainnet launch ceremony as of v1.4 publication.

### 0.1 Current state vs the V1 described in this document

Because OptiVaults has had a publicly-visible Cardano mainnet presence since 2026-04-17, readers who searched for "OptiVaults launch" or inspected Cardanoscan during that window may have seen a deployed vault and reasonably assumed it is the V1 covered by this whitepaper. **It is not.** To remove that ambiguity:

- **The current mainnet deployment** (vault hash prefix `vault_v10-r71`, deployed 2026-04-17) is an **internal-verification-era contract iteration**, not the V1 design described in this document. It exists at a separate vault address and is identifiable on Cardanoscan by its contract hashes (which differ from V1's). The contract code is published in the same public repository under a separate version tag.
- **No third-party deposits.** The frontend's deposit page (`vault.optivaults.app`) is gated to a single founder-controlled allowlist (`Deposit.tsx ALLOWED_ADDRESSES`); deposits from any other address are rejected client-side. The deployment's working capital is **founder-internal test capital** funded from founding capital, used for live-network behavioural validation (governance flows, Liqwid Supply/Recall, Compound, depeg monitoring, emergency paths). Withdraw remains open to all addresses unconditionally — that asymmetry is intentional, mirroring the §1.6.1 "self-serve exit always works" principle even during pre-V1 phases.
- **Architectural diff vs V1.** The current deployment is a **pre-split** contract topology (roughly 9 logic validators built on a single `vault_core` + `vault_protocol` partitioning). V1 as described in this whitepaper is the **post-split architecture documented in `spec/architecture.md` §4.1** (17 logic validators + 4 NFT mint policies + `minswap_v2_adapter` + 2 SundaeSwap artefacts = 24 artefacts), which closes design gaps in slippage enforcement (§5.4 P3-P5), oracle integration (`SwapAda`), multi-validator A2 `publish` coverage (§6.2), and adapter-pattern Withdraw-Zero fan-out (§3.2). V1 is a clean redeploy from a different ref-script ceremony, not an upgrade of the current contract — there is no on-chain migration path from the current vault to V1.
- **Disposition before V1 ceremony.** The current deployment will be **fully unwound before the V1 pre-audit mainnet launch ceremony** (Phase 2 entry per §0; Stage 1 / 1.5 / 2 launch under §1.5): Path A `ActDeregisterStake` × 4 staking credentials is currently queued (14-day timelock executes 2026-05-23 ~16:55-17:11 UTC), followed by full vault drain (`RecallFromLiqwid` + Minswap V2 swap-to-USDCx + Direct Withdraw to the founder wallet), then `reclaim-refs.ts` to recover ref-script lockup ADA. The vault address will be left empty + frozen, and **any subsequent communication about V1 launch refers to the fresh pre-audit mainnet deployment at a new address**, not a continuation of the current one. The V1 launch ceremony is itself the Phase 2 entry event — it predates external audit completion (audit is Phase 3 cap-lift gate per §0).
- **External references should be read with this in mind.** Any prior public reference to OptiVaults being "live on mainnet" — whether from the founder's social posts, third-party Cardano DeFi trackers, or community channels — describes this **internal-verification milestone**, not the public V1 launch. Public V1 launch has not happened and is governed by the §1.5 trigger framework.

This section exists because the gap between "we have a contract on mainnet" and "V1 has launched" was not previously surfaced explicitly enough; honest projects should not require readers to reconstruct that distinction from contract hash diffs alone.

### 0.2 Funding posture: V1 is a volunteer-built, community-funded launch

V1 is built by a single founder volunteering their time plus a small seed (~$2K USDCx as Phase 1 working capital + an estimated ~$120 over the 18-month pre-audit window for infrastructure under §2.6.1 / §4.3.1 minimal-cost configuration). **The founder does not have the financial capacity to self-fund the external audit** ($50–$150K depending on engagement model — see §8.1), and V1 does not raise from VCs, does not issue tokens, and does not solicit equity-style commitments.

This means **V1 launches on Cardano mainnet under the pre-audit 100K USDCx hard cap with prominent risk-disclosure framing, regardless of whether external audit funding has landed by launch day**. External audit is **not a precondition for mainnet launch**; it is the precondition for **lifting the 100K cap toward §1.5 Stage 2 / Stage 3 levels**. The funding stack at §8.1 enumerates realistic non-dilutive sources for the audit (Project Catalyst, Cardano Foundation, Intersect Member Committee, Aiken Foundation, audit-firm public-goods rates, community / DAO contribution pool). If those sources never deliver, **V1 remains on mainnet indefinitely at the 100K pre-audit cap** — depositors continue to have access at small scale, but the cap is never lifted via the audit-driven Stage 2+ path.

**Two-track sustainability model.** V1 separates two questions that are commonly conflated:

1. **Audit funding** (one-time, external, ~$50–$150K) — solves "can V1's 100K cap be lifted toward Stage 2 / Stage 3?" — gated on §8.1 funding stack delivery, founder is **not** the underwriter. **Does NOT gate initial mainnet launch.**
2. **Operating runway** (ongoing, founder-committed, ~$80–$200/year scaling with TVL — see §4.3.1) — solves "can V1 stay running?" — sustainable indefinitely from founder personal income, decoupled from audit funding.

This is the practical meaning of "public-goods reference implementation": the founder ships the engineering, operates the keeper as an ongoing volunteer commitment, and **launches V1 on mainnet pre-audit under strict disclosure + the 100K USDCx hard cap**; the community decides whether the engineering is worth funding through external audit to lift the cap further. Depositors entering during the pre-audit cap period understand and accept the elevated risk profile (undetected CRITICAL bug possible; see §1.5 Stage 1 framing + §8.2 sub-scenarios).

---

## Executive Summary

OptiVaults V1 is a non-custodial, USDCx-denominated multi-stablecoin yield vault on Cardano. Depositors send USDCx to a smart-contract-controlled vault and receive vUSDCx share tokens. A keeper compounds yield and rebalances the vault across USDCx, DJED, and USDM on Liqwid Finance, within governance-set bounds; fees split between keeper operations and a transparent treasury.

**Governance at launch.** The vault runs under one of two signer configurations, both bound by the same contract guarantees:

- **(a) 3-of-3 multisig** — founder + 2 independent Cardano SPOs, unanimity required. This is the target, conditional on SPO recruitment landing before the mainnet ceremony.
- **(b) Founder-controlled with HD-key separation** — the Phase 1 fallback (§7.4).

Given the expected Phase 1 TVL of $500–$25K (§8.2), **depositors should assume configuration (b) at launch** — recruitment is a stretch goal, not a base-case assumption. Depositor recovery does not depend on which configuration is active: it depends on the three contract-level safety layers in §5.5.1, which work identically either way. Timelocks are 7–21 days with a 1-of-n cancel veto, and depositors can withdraw at any time — even with the keeper offline — through the self-serve emergency path.

**What depositors hold.** Share price reflects the vault's current blended-stablecoin exposure, not a pure USDCx claim. The launch target allocation is 45% DJED + 25% USDM + 30% USDCx buffer (§5.2). Depositors bear the depeg risk of whichever stablecoin the vault holds at any given moment.

**The 100K cap and the bootstrapping phase.** V1 launches on Cardano mainnet at a 100,000 USDCx pre-audit hard cap. At that TVL, protocol revenue is roughly $270/year — not enough to cover operating costs. V1 therefore operates in a bootstrapping phase: the operating shortfall is absorbed by the founder's minimal-operations subsidy from personal income (~$80–$200/year, per §4.3.1 — an ongoing subsidy, not a large pre-committed reserve). The protocol becomes self-sustaining as TVL grows into the $135K–$1.8M range (baseline ~$500K; see §4.1).

**Audit is a cap-lift gate, not a launch gate.** V1 launches on mainnet at the 100K cap with prominent risk disclosure, whether or not the §8.1 audit-funding stack has landed. When a third-party external audit completes, it **lifts** the cap toward Stage 3 ($500K → $2M; target Q2–Q3 2027). If audit funding never materialises, V1 continues to operate on mainnet at the 100K cap indefinitely (§8.1 Option D) — the protocol stays live, only the audit-path cap lift does not happen. The founder is a volunteer builder, not the audit underwriter: the commitment is a small seed (~$2K Phase 1 working capital + the ~$80–$200/year operating subsidy + a $15K audit gap-fill cap), **not** self-funding the $50–$150K external audit. Depositors should treat any Stage 2+ cap lift as community-funding-conditional.

**Operating durability.** Post-launch keeper operation runs under the §4.3.1 minimal-operations policy — a single self-hosted server, free-tier providers, low-TVL cadence — for roughly $80–$200/year, absorbed from founder personal income. This does not draw down a reserve, so the operating-runway sunset trigger is effectively unreachable. V1's real failure modes are §1.5 Class A overrides (a USDCx, Liqwid, Cardano-chain, or oracle incident) or an explicit founder sunset decision — not runway exhaustion, and not audit-funding failure (which only holds the cap at 100K, it does not end the protocol).

**Positioning: a public-goods reference implementation.** V1 is a non-commercial public-goods artifact, not a product optimised for growth or equity-style return. The 4.5% performance fee covers protocol operations, the audit reserve, and long-term runway. There is no equity, no token, and no investor distribution; the Apache 2.0 license lets other Cardano teams fork and specialise (alternative stablecoin mixes, risk postures, regional variants). V1 may be the terminal state, or the basis other teams build on — both are acceptable. Depositors should enter with a "contributing to a public good and being an early validator" mindset, not as purchasers of a commercial service (§12).

**Disclosure: the keeper share.** The 4.5% performance fee splits 40% to the keeper and 60% to the treasury (§2.4). Because the founder runs the keeper at launch, that keeper 40% — about 1.8% of yield — flows to the founder's keeper wallet as compensation for infrastructure, monitoring, and on-call responsibility. So USDCx **does** flow to the founder; "no revenue to founder" would be the wrong reading. The honest reading is the opposite of profit: at the 100K cap the keeper share is ~$108/year, while keeper operation costs ~$80/year at the §4.3.1 minimal footprint (and $400–$1,000/year under a fuller posture). The net Phase 1 result is a ~$30–$75/year shortfall the founder absorbs from personal income. There is no equity-style distribution and no token — only a small USDCx receipt line that does not cover its own costs (§4.3).

**How this product came about.** The founder is a Cardano self-custody user — ADA native staker, small-BTC holder, Midnight NIGHT redeem participant, Minswap V2 LP, current USDCx holder. V1 was not born from spotting a market opportunity. The founder wanted a non-custodial, auto-compounding USDCx vault that returns USDCx directly on small withdrawals — instead of a full recall-and-swap-back for every exit — and no such thing existed on Cardano, so the founder built one. Core user protections are contract invariants, not operational promises (§1.6).

This whitepaper describes what V1 does, how it works, what trust assumptions depositors accept, and the honest limits of the launch design.

---

## 1. Problem and Positioning

### 1.1 What Cardano DeFi is missing

Cardano has:
- Lending markets (Liqwid, Indigo's iAssets).
- DEXes (Minswap, SundaeSwap, Splash, CSWAP).
- Stablecoins (DJED, USDM, USDCx).

What it lacks: a **non-custodial, audited, multi-stablecoin yield vault denominated in USDCx** that automatically compounds across Liqwid's USDCx / DJED / USDM markets. Users who want passive stablecoin yield today must manually monitor APYs across the three Liqwid stable markets, swap between them through Minswap V2, manage impermanent loss in DEX LP positions, and re-enter when yields shift. V1 automates this through a keeper that rebalances the vault's stablecoin mix within governance-bounded allocations; the user's share is denominated in USDCx (via vUSDCx) but economically represents a claim on whatever mix of USDCx + DJED + USDM the vault holds at that moment.

**V1 is NOT a multi-protocol yield aggregator.** All yield comes from Liqwid — a single lending protocol. Minswap V2 acts only as a swap router between stablecoins, not a yield source. V1's value proposition is a convenience layer for Cardano stablecoin supply-side yield: one deposit gets you three Liqwid market exposures + automatic rebalancing + depeg monitoring + self-serve exit guarantees. If you want a genuine cross-protocol diversified yield aggregator, V1 is not yet that product. Its future evolution will evaluate integrating other mature, stable supply-side protocols as they emerge on Cardano — but **V1 today operates on Liqwid only**.

### 1.2 Why USDCx

USDCx is a USD-pegged stablecoin launched on Cardano in February 2026, issued by **Circle** through its **xReserve** crosschain reserve mechanism:

- Backed 1:1 by Circle's USDC locked in the xReserve smart contract (USDC itself is backed 1:1 by USD reserves held by Circle, attested monthly by Deloitte).
- Uses Cardano **native asset format** (multi-asset ledger), not a smart-contract-wrapped token — directly consumable on-chain without a wrapping layer.
- Interoperable with Circle's global USDC network, with access to crosschain USDC liquidity via xReserve.
- Existing Liqwid money market with live borrower/lender pools.
- Minswap V2 / SundaeSwap / Splash liquidity against DJED, USDM, ADA, NIGHT.

**Important disclosure**: USDCx is functionally a Cardano representation of Circle's USDC, connected to other chains via the xReserve bridge mechanism. While the USDCx token on Cardano uses native asset format (no wrapping smart contract), the issuance and redemption flow relies on Circle's xReserve infrastructure, Circle's USD reserve management, and Circle's compliance and audit processes. USDCx is **not** a fully chain-isolated stablecoin — its trust chain extends to Circle and xReserve.

**Issuance status (as of whitepaper version 1.3, 2026-05-11).** This section's description reflects USDCx + xReserve + Liqwid USDCx market operational state at v1.3 publication. Specifically:

- USDCx token on Cardano: operational since February 2026 (native-asset format, no wrapping contract).
- xReserve bridge: live for USDCx issuance / redemption flow; production-grade in Circle's xReserve infrastructure.
- Liqwid USDCx market: live with thin borrow demand (supply APY 0.5–2% as of writing, per §4.4 snapshot).
- Native USDC direct redemption path back to Circle: via Circle USDC redemption + xReserve bridge out of Cardano.

V1 mainnet launch is contingent on USDCx remaining at the launch-readiness threshold described in §1.5 Axis B. If USDCx never reaches Axis B Yellow tier ($40M+ circulating), or its operational status materially regresses, V1's deposit token may be re-evaluated via governance `UpdateRegistry` (14-day timelock). Candidates include native USDC if Circle ships directly to Cardano without xReserve, or alternative Tier-1 fiat stablecoins reaching Cardano-native operation. Readers should verify current state via Circle's official channels and Liqwid's governance forum before deposit decisions.

**V1's due diligence checklist for USDCx:**

| Check | Status |
|-------|--------|
| Public issuer identity | Yes — Circle (via xReserve mechanism) |
| Published backing attestation | Yes — Circle's monthly USDC reserve attestation by Deloitte, with xReserve on-chain auditability |
| Redemption path (USDCx → USD) | Yes — via Circle's USDC redemption + xReserve bridge out of Cardano |
| Protocol support | Natively supported by Liqwid, Minswap, SundaeSwap at launch |
| On-chain float | Sufficient for V1's 100K USDCx pre-audit cap |
| Audit history | Circle's Tier-1 compliance posture + xReserve smart contract audits |

V1 does not provide a substitute for a depositor's own due diligence on USDCx. If the depositor does not trust Circle's USDC issuance model, xReserve's bridge mechanism, or Circle's compliance framework, they should not use V1.

### 1.3 Target user

**OptiVaults V1 is built primarily for small-to-medium USDCx holders** (think: $100–$10,000 positions) who want passive stablecoin yield on Cardano but do not want to run their own DeFi operations. The economics, UX, and safety rails are all tuned around this profile. **Timing note**: the $100–$10,000 range applies to the **post-audit era** (currently targeted **2027 Q2-Q3+**, after external audit passes and the TVL cap is lifted; see §8.1 for funding-stack uncertainty). During the pre-audit period, the operator-enforced 100K USDCx TVL cap constrains aggregate deposits. A first deposit noticeably below the target-range lower bound — e.g. $200–$2K as a test position — is recommended. Full pre-audit context is in §8.2.

- **Small positions amortize entry + exit gas worst.** A $200 USDCx holder going direct to Liqwid pays one-time entry gas (swap USDCx → DJED + Liqwid supply ≈ 2 TXs; if diversifying into DJED + USDM, ≈ 4 TXs) plus similar exit gas (recall qToken + swap back). At current Cardano network + Minswap batcher fees that is roughly 3–5 ADA each direction, so ~$2–4 USD round-trip — on a $200 position that is 1–2 % of principal in one-time friction, before any yield accrues. V1 batches the multi-market allocation at vault level — one Compound serves the entire TVL. So per-depositor entry is a single CIP-30 TX regardless of how many underlying markets V1 is in, and exit is a single vUSDCx burn, not a multi-step Liqwid-recall + Minswap-swap chain.
- **No daily monitoring required.** V1's keeper watches Liqwid APY shifts and rebalances automatically within governance-set bounds. A small-holder depositor does not need to track DJED/USDM/USDCx supply rates.
- **Self-serve exit works even at small size.** The `withdraw-cli` + `emergency-withdraw` tools let a single depositor unwind their position without operator help, regardless of size.
- **Accepts smart contract risk + stablecoin issuer risk** (this is the explicit trust boundary for any Cardano DeFi product).

V1 is probably not the right fit for:
- **Large institutional desks** ($500K+ per wallet) — the pre-audit 100K cap is immediately binding, and desks of that size can typically afford custom off-chain rebalancing infrastructure that captures more yield than V1's automated layer.
- **Users seeking principal-protected yield** — V1 is not principal-protected; Liqwid bad debt or stablecoin depeg can reduce share price (see §5).
- **Users requiring regulatory assurance** — V1 makes no regulatory representation; jurisdictional compliance remains each user's own responsibility.
- **Users who want to decide based only on the Product Overview summary.** V1 is designed assuming depositors will read the full §5 Risks disclosure. If you prefer to skip the risk chapters and decide from the summary alone, we recommend either waiting for post-audit cap lift before considering V1, or choosing Direct Liqwid DJED supply for a mechanically simpler alternative.

### 1.3.1 What depositors actually get (product advantages)

Listed in rough order of how often a small-holder's wallet benefits:

1. **Multi-market diversification in one transaction.** Deposit once → exposure to 45% DJED + 25% USDM + 30% USDCx idle buffer (launch allocation). Replicating this manually requires 2–3 Minswap V2 swaps + 2 Liqwid supply TXs + periodic rebalance — each a separate network fee. V1 bundles strategy execution at vault level.
2. **Automated Compound at network-fee scale.** V1 pays Minswap V2 batcher + Cardano network fees once per vault cycle; a direct-Liqwid user pays them once per *user* per cycle. Small-holder net APY catches up to large-holder net APY.
3. **Share-token abstraction** (vUSDCx). Deposit snapshot is one token in your wallet; no manual position tracking, no spreadsheet needed. Transferable between wallets if you want to give/sell your share.
4. **Self-serve exit guarantees.** `withdraw-cli` + `emergency-withdraw` tools work without operator cooperation; after 7 days of keeper inactivity, early-withdraw fee is automatically waived on-chain. Your principal is never trapped.
5. **Depeg monitoring + halt procedure.** Keeper watches Charli3 + Orcfax + Minswap V2 TWAP for sustained (15 min) deviations; sustained depeg → governance queues `EmergencyWithdraw` (freeze=1) and operators halt new deposits. A direct-Liqwid depositor must build and run this monitoring themselves.
6. **Transparent fee structure.** 4.5% of realized yield (hard-capped by validator), 0% deposit fee, 0.1% early-withdraw fee only if exiting within `min_hold_seconds`, plus a small ~0.02% APY drag from SwapAda (the on-chain mechanism that replenishes vault operating ADA via oracle-priced USDCx barter — see §4.5). No AUM fee, no management fee, no performance-fee sleight of hand.
7. **On-chain governance with 1-of-n cancel veto.** Fee caps and protocol whitelists are gated by 7–21-day timelocks with public disclosure obligation. You have time to withdraw before any policy change takes effect.

**When to choose V1 vs. direct Liqwid.**

| Scenario | Choose V1 | Choose direct Liqwid |
|----------|-----------|----------------------|
| Position $200–10K | ✅ one TX in, one TX out; multi-market allocation at vault level | ❌ entry + exit gas ~$2–4 each direction ≈ 1–2 % of a $200 position round-trip |
| Want three-stablecoin blended exposure | ✅ one-TX setup | ❌ need 2-3 swaps + 3 supplies |
| < 30 min/week of DeFi monitoring | ✅ keeper handles it | ❌ you track 3 market APYs yourself |
| Automatic depeg protection | ✅ contract freeze + 15 min sustained detection | ❌ roll your own oracle monitor |
| Want transferable share token (vUSDCx) | ✅ native support | ❌ qTokens bound to your wallet |
| Position > $40K and strong DJED-only conviction | ❌ 4.5% perf fee eats edge | ✅ capture 100% of DJED APY |
| Want stablecoin other than DJED/USDM/USDCx | ❌ V1 only supports these three | ✅ pick your own market |
| Unwilling to accept m-of-n governance risk | ❌ governance layer exists | ✅ only Liqwid protocol risk |
| Want to avoid ~0.02% SwapAda drag | ❌ V1 has it (§4.5) | ✅ no equivalent |

**Honest break-even — two-component framing (canonical table)**. Choosing V1 over Direct Liqwid involves two distinct value components, and an honest break-even has to account for both. The same table also appears as the canonical reference in §4.4; the two sections now share one framing instead of presenting different numbers.

**Component A: Pure time cost** — what manually managing a Direct Liqwid position actually costs you in time × your hourly value (15 hrs/year × hourly rate ÷ 5.44% gap).

**Component B: Risk-management outsourcing** — the value V1 provides on top of yield: depeg monitoring, multi-stablecoin diversification, contract-level freeze response, automatic compounding, and self-serve emergency-withdraw. Direct Liqwid users must build these themselves or accept the unmitigated exposures.

| User profile | (A) Pure time break-even | (B) Perceived risk-mgmt value | **Practical break-even** |
|---|---|---|---|
| $10/hr time value, low DeFi experience | ~$2,800 | ~$30K (high — building monitoring is daunting) | **~$33K** |
| $20/hr time value, medium experience | ~$5,500 | ~$25K | **~$30K** |
| $50/hr time value, high experience | ~$14K | ~$15K | **~$29K** |
| $100/hr time value, DeFi professional | ~$28K | ~$5–10K (already has workflows) | **~$28–38K** |

**Honest implications**:

- For most realistic profiles, the practical break-even sits in the **$25K–$40K range** — not the Component-A-only $5K–$15K range. Below that range, V1 typically delivers net-positive value because building monitoring + response infrastructure yourself is real work, and a mistake during a depeg event can easily dwarf the yield gap.
- Above ~$40K with relevant DeFi experience, **Direct Liqwid DJED is the better choice on pure math** — V1 stops adding net value above that point and we say so.
- Users who explicitly **do not value Component B** (sophisticated holders with their own monitoring + response stack) should read the Component-A column only and pick Direct Liqwid above the lower break-even. V1 does not try to inflate Component B for these readers.

V1's genuine addressable segment is therefore: depositors in the $25K–$40K-and-below range who do not already have their own DeFi operational stack, plus users who refuse CEX custody on principle, plus users who actively want the dual-stablecoin-issuer allocation. We disclose this in two places (here + §4.4) using the same numbers, rather than hide it behind an averaged figure.

**Plainly**: you get Liqwid's 3-market supply yield + auto-rebalance + self-serve recovery in a single CIP-30 deposit TX. You pay 4.5% of realized yield for it. For $200–$10,000 positions, a direct-Liqwid setup costs about 1–2 % of principal in one-time entry + exit gas — V1's convenience saving is genuine, but whether it beats the 4.5% performance fee over your actual holding period still depends on your time horizon and hourly wage (see break-even table above).

### 1.4 Cardano Stablecoin Lending Reality

Understanding why V1 is structured as a single-protocol Liqwid vault requires acknowledging the current state of Cardano stablecoin lending infrastructure.

#### Single mature lending venue

As of 2026 Q2, Liqwid Finance is the only Cardano-native lending protocol with operational stablecoin markets at meaningful scale. Other Cardano lending protocols are either inactive, focused on non-stablecoin collateral, or operating at TVL levels that preclude meaningful integration:

- **Lenfi (formerly Aada Finance)**: Following a December 2024 smart contract vulnerability incident (transparently handled by the team via white-hack recovery — see Lenfi's official post-incident disclosure on their blog / Twitter from December 2024), TVL has declined from an approximate prior peak of $5M to around $230K (DefiLlama protocol TVL history, accessed 2026-05-12). The protocol remains operational but is no longer at a scale that can serve as a viable second venue for vault diversification. *Figures are external public-data snapshots and may move; readers should re-verify against DefiLlama at the time of reading.*
- **Levvy**: Acquired by Angels Finance, currently in V3 development. Focused on NFT-collateralized lending, not stablecoin markets.
- **FluidTokens**: NFT-collateralized lending only.
- **Smaller venues** (Yamfore, Cherry Lend, others): Operating at TVL levels below $100K per market.

This is not a temporary state. Cardano stablecoin borrowing demand has been structurally constrained by the absence of valuable non-stablecoin collateral at scale (no equivalent of ETH/wstETH on Ethereum). Pogun's BTC DeFi rollout in 2026–2027 may change this, but the change is prospective, not current.

#### Implications for V1 design

The "multi-stablecoin diversification" provided by V1 (USDCx / USDM / DJED) operates at the **asset layer** but not at the **smart contract layer**. All three markets share a single set of Liqwid smart contracts. A critical Liqwid bug would affect all three positions simultaneously.

V1 does not present this as a chosen tradeoff; it is a constraint imposed by ecosystem maturity. We document this constraint explicitly because:
- Future depositors deserve to understand the actual risk topology, not a marketed version.
- The V2 roadmap (§1.6.3) is conditioned on this constraint changing, with explicit external triggers.
- The Launch Readiness Framework (§1.5) accounts for this in its Liqwid-specific monitoring axis.

#### Oracle concentration

Cardano's mature oracle infrastructure consists primarily of Charli3 and Orcfax. Both protocols are used by Liqwid, Indigo, and most production DeFi applications on Cardano. This means oracle risk on Cardano is structurally non-diversifiable at the protocol level. V1 mitigates this through dual-source oracle reading (§3.4) but cannot escape the underlying concentration. This is acknowledged as an irreducible residual risk.

#### When the constraint changes

The V1 single-protocol design will be re-evaluated when external conditions change. Specifically, V2 multi-protocol expansion is conditioned on the emergence of a second mature Cardano stablecoin lending venue (defined in §1.6.3). Until that emergence, additional protocols introduce attack surface without producing meaningful smart contract diversification.

#### Adjacent Cardano products (for context)

The Cardano DeFi landscape includes several products that overlap with some but not all of V1's functions. Depositors evaluating V1 should know what else exists:

| Product | What it does | How it differs from OptiVaults V1 |
|---------|--------------|-----------------------------------|
| **Liqwid Finance (direct supply)** | USDCx / DJED / USDM / ADA money market | Single-market exposure, no automated cross-market reallocation, no share-token abstraction. Depositor handles rebalancing and compound manually. |
| **Indigo Protocol (iAssets + iUSD stability pool)** | Mints synthetic assets (iUSD, iBTC, iETH) collateralized by ADA; stability pool earns liquidation fees | Different risk model: iUSD is an algorithmic CDP-backed synthetic, not a fiat-backed stablecoin. Stability pool depositors bear ADA liquidation risk. |
| **Minswap / SundaeSwap stable-pair LP** | Provides liquidity to USDCx/DJED, USDM/DJED, USDC/USDCx pools, earns swap fees | LP positions carry impermanent loss risk on depeg events; V1 explicitly avoids LP by supply-side-only yield. |
| **Genius Yield (historical) / Encoins** | Previous-generation Cardano DeFi products | Not active competitors at V1 launch; mentioned for completeness. |
| **ADA native staking** | Delegate ADA to a stake pool, earn ~2.3-2.4% | Not a USDCx-denominated yield; requires holding ADA and accepting ADA price exposure. |

The honest positioning: **V1 is a convenience layer plus multi-market diversification layer over Liqwid's supply-side APY** (with Minswap V2 used as a swap router between stablecoins). A depositor who wants the absolute minimum counterparty risk and is willing to do manual allocation should use Liqwid directly. A depositor who wants diversified stablecoin yield without operating their own keeper is the fit for V1.

### 1.5 Launch Readiness Framework

V1 mainnet launch timing and TVL capacity are governed by a three-axis trigger framework. Cap levels are not adjustable by team discretion; they are determined by the framework state and enforced through governance multisig with 7-day timelock.

#### Three-axis monitoring

**Axis A: Pogun BTC Supply TVL**

The presence of substantive Bitcoin DeFi activity on Cardano is the primary external catalyst capable of generating sustained borrow-side demand for stablecoin lending markets.

| Tier | Threshold | Implication |
|------|-----------|-------------|
| 🔴 Red | < $5M, or Pogun mainnet not live | No launch trigger from this axis |
| 🟡 Yellow | $5M – $15M | Catalyst forming, monitoring continues |
| 🟢 Green | > $15M sustained 60 days | Substantive borrow demand established |

Measurement: 60-day rolling average of BTC TVL supplied to Pogun lending markets, sourced from DefiLlama and verified against Pogun's official metrics.

**Axis B: USDCx Circulating Supply**

Vault TAM is bounded by USDCx circulating supply on Cardano. The post-subsidy organic growth trajectory (post Q1 2026 IOG bridging fee subsidy) determines whether the asset has product-market fit independent of promotional support.

| Tier | Threshold | Implication |
|------|-----------|-------------|
| 🔴 Red | < $40M, or 30-day net outflow > 10% | Insufficient TAM, declining base |
| 🟡 Yellow | $40M – $100M, trend stable | Adequate TAM, validates organic demand |
| 🟢 Green | > $100M with positive 30-day net inflow | Institutional adoption confirmed |

Measurement: On-chain USDCx mint/burn events tracked via Blockfrost, cross-validated against Circle's USDCx official statistics and DefiLlama Cardano stablecoin metrics.

> **Threshold caveat (2026 Q2)**: Current USDCx circulation is approximately $10–$20M, well below the Red threshold. The $40M Yellow target reflects what we believe is the minimum size at which V1 can serve a non-trivial portion of organic USDCx demand without becoming a dominant share of supply. If by 2027 Q1 USDCx circulation has not reached the Yellow threshold, the threshold itself will be re-evaluated rather than the launch indefinitely deferred — see "Maximum deferral" below.

**Axis C: Liqwid Blended Supply APY**

This axis represents product viability. Below 5% blended yield, V1's value proposition (outsourced auto-compounding for a 4.5% performance fee) cannot be honestly justified for typical user deposit sizes.

| Tier | Threshold | Implication |
|------|-----------|-------------|
| 🔴 Red | 90-day blended < 5% | Product economics unviable |
| 🟡 Yellow | 5% – 7% | Marginal economics, break-even challenging |
| 🟢 Green | > 7% sustained 60 days | Strong economics, value proposition clear |

Measurement: Daily reading of Liqwid USDCx, USDM, and DJED supply APY, weighted by V1 strategy allocation (45/25/30 default), 90-day rolling average.

#### Override conditions

Two classes of overrides apply, with **different effects** (see §0.2 / §8.1 for the volunteer-builder framing on why these are separated):

**Class A — Launch-blocking overrides (any trigger blocks mainnet launch entirely).** Regardless of axis state, mainnet launch is blocked while any of the following hold — these reflect external infrastructure failures that make V1 operation itself unsafe:

1. Liqwid Finance has experienced a high or critical severity smart contract incident within the past 12 months.
2. USDCx issuer (Circle, via the xReserve smart contract and its Cardano-side integration deployed by IOG) has experienced a material operational incident.
3. Cardano mainnet has experienced a critical chain halt within the past 6 months.
4. Charli3 or Orcfax oracle has experienced sustained anomaly (>24 hours) within the past 30 days.

**Class B — Cap-lift overrides (V1 launches on mainnet at the pre-audit 100K cap; these conditions only hold the cap at 100K and block progression to Stage 2 / Stage 3).** V1 does **NOT** stay in Preprod under these conditions — it operates on mainnet under the existing 100K USDCx cap with prominent pre-audit risk disclosure (see §8.2):

5. V1 external audit not yet passed. Mainnet operation continues at 100K; Stage 2 / Stage 3 cap lift requires audit completion.
6. External audit funding has not reached the §8.1 cost threshold by 2027 Q4. V1 continues to operate at the pre-audit 100K mainnet cap indefinitely; cap-lift via the audit-driven path is deferred until funding lands (or never, if §8.1 Option D outcome). See §0.2 funding posture and §8.1 Options A–D contingency tree — none of these options forces V1 off mainnet, they only determine the cap-lift pathway. The §0 maximum-deferral path is invoked only when **Class A** override conditions hold for an extended period or when the §1.5 axis-state trigger framework signals product-premise failure (no axis Yellow by 2027 Q4 — see "Maximum deferral" below).

#### Stage matrix

| State | A | B | C | Stage | TVL Cap | Audit required? |
|-------|---|---|---|-------|---------|-----------------|
| Pre-Catalyst | 🔴 | * | * | Stage 0 — Preprod only | 0 (mainnet inactive) | — |
| One-Yellow | 🟡 | * | * | Stage 1 — Limited Pilot | $10K (permissionless, with prominent pre-audit risk warnings; **no invitation gate, no whitelist** — see §8.2) | **No** (pre-audit) |
| Two-Yellow / One-Green | varies | varies | varies, no Red | Stage 1.5 — Open Pilot | $25K (publicly accessible, capped) | **No** (pre-audit) |
| Two-Green, no Red | 🟢🟢🟡 in any combination | | | Stage 2 — Soft Launch | $100K | **No** (pre-audit; cap held at 100K) |
| All-Green, no Red | 🟢 | 🟢 | 🟢 | Stage 3 — Full Launch | $500K initial, ramp to $2M | **Yes** — external audit complete (§8.1 cap-lift gate) |

Stages 1 / 1.5 / 2 are **pre-audit mainnet stages** — V1 launches on mainnet under the relevant cap as soon as the axis state qualifies (per §1.5 Override conditions Class A clear + §8.1 launch checklist). Stage 3 cap lift requires external audit to have completed (per §8.1 cap-lift checklist). If §8.1 funding stack never delivers, V1 stays at Stage 2 (100K cap) indefinitely on mainnet — see §8.1 Option D. Stages 1 → 2 → 3 are **not** time-gated; they progress as axis state and audit outcome warrant.

#### Stage 3 ramp-up schedule

Following Stage 3 activation, TVL cap increases follow this schedule, contingent on continued All-Green status, zero high-severity bugs in the prior 30 days, and no governance pause proposal pending:

- Month 1: $500K
- Month 3: $1M
- Month 6: $1.5M
- Month 12: $2M

Caps do not auto-increase based on calendar alone. Each step requires verified state at the time of increase.

#### Reversal conditions

Once mainnet is active, the following conditions automatically downgrade stage:

| Condition | Action |
|-----------|--------|
| Any axis Red sustained 30 days | New deposits paused, monitoring intensified |
| Two axes Red sustained 7 days | New deposits paused, governance 24h emergency assessment |
| Liqwid high-severity incident | Immediate pause, emergency withdrawal path activated |
| USDCx depeg event | Immediate pause, sunset protocol evaluation |
| Internal audit finding critical bug | Immediate pause, emergency fix |

In all reversal cases, existing user funds remain withdrawable. Reversals affect only new deposits.

#### Public dashboard and governance binding

The current state of all three axes, the active Stage, and the resulting TVL cap are published on a public dashboard updated daily. The dashboard is non-decorative: it is the canonical source of truth for the cap, and the cap value embedded in the on-chain VaultDatum must match the dashboard state.

Cap changes require:
1. Trigger state verification (cryptographic proof of dashboard state at time of change)
2. Governance multisig approval
3. 7-day timelock before activation

This binding ensures that "we will launch when conditions are met" is a verifiable commitment, not a marketing statement.

#### Maximum deferral

If, by 2027 Q4, no axis has reached Yellow status, the project enters strategic re-evaluation. Possible outcomes include:
- Extended deferral with revised triggers
- Pivot to fixed-rate vault as primary launch product (§1.7)
- Repurposing accumulated work for adjacent products
- Sunset and contribution of code to the Cardano ecosystem under Apache 2.0

The 2027 Q4 deadline is included to prevent indefinite deferral and ensure decision accountability.

### 1.6 V1's origin — a Cardano-native builder's own product

OptiVaults's founder is a Cardano self-custody user who happens to be a typical member of V1's target user segment (professional background is in §7.4, as additional context):

- **ADA holder + native staker since 2025** — delegated to a stake pool for protocol-native yield.
- **Small-BTC holder since 2025** — multi-chain scarce-asset allocation, same self-custody posture.
- **Participated in Midnight's NIGHT redeem** — claimed NIGHT via the Cardano-eligible asset snapshot. (The NIGHT tokens later ended up paired with ADA on Minswap V2 — see the next bullet — but that was subsequent behaviour, not a planned "build a portfolio" sequence.)
- **Minswap V2 ADA/NIGHT LP since 2026** — active Cardano DeFi participant, not a passive holder. Has hands-on experience with Minswap batcher behavior, cancel paths, pool migrations, impermanent loss on ADA-paired positions.
- **Current USDCx holder** (USDCx launched on Cardano via Circle's xReserve in February 2026) — Tier-1 fiat-backed stablecoin and V1's deposit token.

**V1 started as a specific personal problem.** USDCx was in the founder's wallet and the realistic options were:

- **(a) Send it to a CEX earn product** — rejected on self-custody principle.
- **(b) Supply directly on Liqwid's USDCx market** — roughly 0.5–2% APY, inflation-negative in real terms, basically not worth the effort.
- **(c) Swap USDCx to DJED and supply on Liqwid for ~11.8% APY** — decent yield. Entry is 2 TXs (swap + Liqwid supply). Exit, or each partial withdraw, is its own 2-TX recall + swap-back round-trip. DJED + USDM diversification is ~4 TXs in, with two parallel positions to manage. Between entry and exit the qToken sits in your wallet with its rate auto-accruing — no per-cycle chore. On a $200 position, one entry + one exit round-trip is roughly $2-4 USD in gas + batcher fees, i.e. 1-2 % of principal — the longer you hold, the more that one-time friction amortizes.
- **(d) Just hodl USDCx in the wallet** — 0% yield, same USDCx issuer risk.

None of these was what the founder actually wanted, which was simply: **"deposit USDCx, let it auto-compound on Liqwid, and when I need some USDCx back later just take it out directly — without running a recall-qToken + swap-back chain every time."** That small-withdraw friction matters: a $50–100 partial withdraw done manually can easily lose 5–10 % of the withdrawn amount to gas + batcher fees alone. A non-custodial, audit-track, auto-compounding USDCx vault that avoided this did not exist on Cardano — so V1 was built to be exactly that product, starting from the founder's own deposit need rather than from a market-sizing exercise.

**V1 is the implementation of "what I was personally looking for but couldn't find."** That is the origin story, and it doubles as the product-market-fit argument: the founder is shipping the product the founder wanted to use. "First persona" of the target-user list is the founder.

**The Minswap LP experience is directly relevant.** Being an actual Minswap V2 LP (not a user who read Minswap's docs) means the founder has:
- Seen batcher delays in practice — sometimes fills are instant, sometimes they back up when pool state is contested. V1's keeper design budgets for this (Queue Withdraw path with <1 hr settlement is a response to batcher-cycle reality, not a theoretical SLA).
- Hit cancel-path edge cases firsthand — `StakeCredential::Constr(0,[])` vs `Constr(1,[])` encoding differences, pool-shard migration issues — which is why V1's integration playbook (`docs/integration-playbook.md`) treats cancel paths as mandatory reverse-engineering work, not optional.
- Experienced impermanent loss on ADA-paired LPs — which is why V1 explicitly avoids LP positions (§2.3) and only takes supply-side Liqwid yield. That design choice is an experience-driven preference, not a theoretical risk framework.

### 1.6.1 V1's user protections: what's a contract invariant, what depends on externals

V1's user protections split into two layers. Depositors should understand clearly which layer they are relying on in any given scenario.

> **Core user protections are contract invariants, not operational promises.** Why are V1's promises credible? Because **the code simply doesn't allow us to break them.** Several specific promises are structurally foreclosed at the validator-hash level:
>
> - No redeemer lets `idle_buffer` go to any address that isn't a depositor.
> - `performance_fee_bps` is hard-capped at 450 (4.5%) by the shared `validate_update_fee` helper that `vault_gov_policy.ak`'s `UpdateFee` redeemer calls — no governance action can raise it past that ceiling.
> - No "pause withdrawals" admin button exists.
>
> These are properties of the deployed validator hashes that any user can verify.

> **Not every protection is a pure contract invariant.** Three protections are in-contract, unconditional: (a) no admin-drain redeemer, (b) immutable 4.5% fee cap, (c) automatic early-withdraw fee waiver after 7 days of keeper inactivity (§5.4). Others depend on external infrastructure availability: successful withdrawal requires Cardano chain + Liqwid (for positions held there) + Minswap V2 (if routing is needed) + USDCx liquidity (for the final output). If any of those external pieces fails, the depositor's on-chain claim remains enforceable but may settle in whatever assets the vault currently holds, not necessarily 1:1 USDCx. The self-serve `emergency-withdraw` tool still operates, but its output quality tracks external-protocol state. This is the honest posture, not "withdraw always works regardless of conditions."

V1 is framed around flexibility and yield ergonomics with on-chain-enforced user protection. Three things define that framing:

- **Fees.** No AUM fee, no management fee — the only charge is a 4.5% performance fee on realized yield.
- **Exit paths.** Self-serve `withdraw-cli` / `emergency-withdraw` ship alongside the main product as a primary feature, not a fallback.
- **Release cadence.** Pre-audit mainnet launch at the 100K USDCx hard cap with prominent risk disclosure and multi-round internal audit, then external-audit-gated cap-lift toward Stage 2 / Stage 3. §8.1 explains why audit is a cap-lift gate rather than a launch gate.

Depositors entering pre-audit do so under the §8.2 sub-scenario framework with full risk transparency, not under a "launch and figure it out later" stance. The contract-level safety design — §5.5.1 three-layer governance protection, §6.3 hard caps, and self-serve emergency exit — provides a depositor-recovery floor that is **independent of audit status**. V1 does not sidestep the inherent trust boundaries of DeFi: your wallet private key controls your principal, finalised TXs are irreversible, and both the contract and its external dependencies can fail. Those are fully disclosed in §5.1, §9.1, and §12.

### 1.6.2 Why Cardano, why now

A fair skeptic asks: Aave, Compound, and Yearn shipped conceptually similar vault-aggregator patterns on Ethereum years ago. Why is OptiVaults V1 being built on Cardano in 2026, rather than earlier or on a different chain?

Honest answer: **the preconditions that make this product viable on Cardano have only recently aligned.** Building V1 two years earlier would have required compromising on core properties; building it on a different chain would have missed the architectural fit Cardano's eUTXO + Plutus model provides.

- **USDCx launch (February 2026).** Before Circle released USDCx via the xReserve mechanism, Cardano lacked a Tier-1 fiat-backed stablecoin with institutional backing + monthly reserve attestations. An auto-yield vault denominated in DJED alone (ADA-collateralized) or USDM alone (smaller fiat issuer) would have concentrated the product on single-issuer risk. USDCx closes the core-asset gap.
- **Liqwid stablecoin-market maturity (2024-2025).** DJED and USDM markets on Liqwid needed sufficient borrow demand + supply depth before a supply-side aggregator could route meaningful amounts without distorting market rates. That depth arrived in late 2024 and has held since.
- **Cardano SPO-operator ecosystem.** V1's governance model (3-of-3 with two independent SPO signers — see §5.5) depends on a pool of mature, publicly-identified stake-pool operators with long-lived economic stakes in Cardano. The SPO community reached the breadth and reputational depth needed for credibly-independent governance signers only in recent epochs.
- **Aiken + PlutusV3 tooling maturity.** V1's contract architecture (Withdraw-Zero forwarding, multi-validator staking delegation, PlutusV3 reference scripts with Conway-era fee structure) depends on tooling that was experimental as recently as 2023. Aiken reaching `v1.1.x` with stable `stdlib` support makes the implementation feasible on a realistic audit budget.

V1 is not the first auto-yield vault in DeFi history. It is the **first version of this product whose architectural preconditions are actually satisfied on Cardano**. Shipping earlier would have required either compromising on core properties or deferring primitives that did not yet exist.

### 1.6.3 V2 Multi-Protocol Aggregator: Conditions

V2 expansion to a multi-protocol stablecoin yield aggregator is contingent on external ecosystem conditions, not on internal team timeline. The conditions below must all be satisfied for V2 development to commence:

**Required conditions (all must hold)**

1. **Second mature lending venue.** A Cardano stablecoin lending protocol other than Liqwid must reach and sustain $5M+ TVL for 12 consecutive months.
2. **Audit parity.** The second venue must have completed at least two independent external audits of equivalent depth to Liqwid's audit history, with no high-severity findings open.
3. **Operational track record.** The second venue must have operated without high-severity smart contract incidents for 12 consecutive months.
4. **V1 maturity.** V1 mainnet must have completed external audit and operated for 12 months with TVL above $500K.
5. **Treasury reserve.** OptiVaults treasury must hold reserves equivalent to 6 months of operating runway, providing budget for V2 audit without external funding dependency.

**Current status as of 2026 Q2**: 0 of 5 conditions met.

**Transparent monitoring**

The status of each condition is monitored on the public OptiVaults dashboard. We publish a monthly summary indicating which conditions remain unmet and which conditions have been newly satisfied since the prior month.

**Why these conditions, specifically**

The conditions listed are not arbitrary. Each addresses a real risk that V2 multi-protocol expansion would otherwise introduce:
- Conditions 1–3 ensure that adding a second venue increases diversification rather than substituting Liqwid's mature risk profile with an unproven one.
- Conditions 4–5 ensure that V2 development does not jeopardize V1 stability or exhaust resources required to maintain V1 in good operational standing.

**No timeline commitment**

We do not commit to V2 by a specific date. Based on current Cardano DeFi development trajectory, V2 conditions are unlikely to be satisfied before 2028. We will not artificially modify these conditions to accelerate V2 timing.

**Alternative paths if conditions remain unmet**

If by 2028 Q4 the second-venue conditions remain unmet, V2 will be deferred indefinitely. In that case, OptiVaults will focus expansion on:
- Fixed-rate vault product (§1.7) — does not require multi-protocol diversification
- Pogun BTC-collateralized routing (§1.7) — extends V1 within Liqwid framework
- Privacy-enabled vault on Midnight (§1.7) — orthogonal to multi-protocol path

**V1 may be the terminal state — and that is an acceptable outcome.** If none of the V2.x or V3.0 paths materialise either, V1 remains a single-protocol Liqwid wrapper with three stablecoin exposures and m-of-n governance — a narrower value proposition than "future multi-protocol aggregator." We encourage depositors to value V1 on what it offers today: **automatic compounding + dual-issuer stablecoin allocation + self-serve exit guarantees + audited-and-capped fee structure**, costing 4.5% of realised yield. Whether that bundle justifies the fee is a personal call that depends on your own alternatives (Direct Liqwid DJED, CEX earn, or simply holding USDCx — all compared in §4.4).

**License posture (connects to the goal).** OptiVaults is not trying to become Cardano's largest vault. The explicit goal is to put a complete, audited, Apache-2.0-licensed reference implementation into the Cardano open-source commons — so that other teams can fork and specialize V1 (different stablecoin baskets, different risk postures, vertical or regional variants) whether or not OptiVaults itself grows. A BSL / source-available license would have protected V1's competitive position against direct forks until 2028 at the cost of blocking exactly that Cardano-wide architecture adoption. Apache 2.0 is the license that matches the goal.

### 1.7 Future Product Roadmap

OptiVaults is a single-product launch (V1 variable-rate vault), but the project is structured to expand into adjacent products as Cardano DeFi infrastructure matures. Each future product is contingent on specific external triggers, not internal timeline.

#### V1.0 — Variable-Rate Stablecoin Vault (this document)

- **Status**: Preprod testnet deployed, awaiting launch readiness conditions (§1.5)
- **Trigger**: Two-Yellow axis state plus external audit completion
- **Estimated activation**: 2027 Q2 – Q3 (centrist scenario)

#### V1.5 — Fixed-Rate USDCx Vault

A complementary product offering term-locked, fixed-rate yield on USDCx deposits (e.g., 4.0% APY for 6 months). Designed to serve institutional and DAO treasury users who require predictable returns for financial planning.

**Mechanism summary**: User deposits USDCx into a fixed-rate cohort (3, 6, or 12-month maturity). Capital is deployed via the V1 mechanism (Liqwid multi-market). Spread between realized yield and promised rate accumulates in a reserve fund. Reserve covers shortfalls during low-yield periods. Black Swan Clause defines conditions under which fixed rate is suspended (Liqwid critical failure, USDCx depeg, etc.).

**Trigger conditions**:
- V1 mainnet operating for 6+ months
- Treasury reserve above $5K
- Liqwid 90-day blended APY consistently above 4.5% (provides margin for 3.0% offered rate)

**Estimated activation**: 2027 H2 (centrist scenario)

**Why this product**: Cardano has no fixed-rate stablecoin yield infrastructure. Pendle does not operate on Cardano. The market segment of "stablecoin holders requiring predictable returns" is unserved.

#### V2.0 — Multi-Protocol Aggregator

See §1.6.3 for full conditions. Expansion to a multi-protocol stablecoin yield aggregator pending second mature lending venue emergence.

**Estimated activation**: 2028+ if conditions met, indefinitely deferred otherwise.

#### V2.x — Pogun BTC-Collateralized Yield Routing

Extension of V1 to incorporate Liqwid markets that are utilized by Pogun BTC borrowers. As BTC holders deposit BTC as collateral and borrow stablecoins via Pogun, V1 can be the supply-side counterparty, capturing the resulting yield.

This is not a new vault product; it is an addition to V1's market routing logic. No separate audit required if Pogun integrates with existing Liqwid markets.

**Trigger conditions**:
- Pogun lending mainnet operational
- Pogun BTC TVL above $15M sustained 60 days
- Pogun audit history verified (at least one external audit, no high-severity open findings)

**Estimated activation**: 2027 Q2 – Q4 (depending on Pogun rollout timing)

#### V3.0 — Privacy-Enabled Institutional Vault on Midnight

A privacy-preserving variant of OptiVaults deployed on Midnight, leveraging the Midnight DeFi Kernel for shielded position management. Designed for institutional users requiring auditable but non-public DeFi exposure.

**Mechanism summary**: User deposits on Midnight, receiving shielded position certificates. Yield generation continues through Cardano-based Liqwid (publicly), but ownership is private to the user. Selective disclosure available to auditors and regulators per Midnight's design.

**Trigger conditions**:
- Midnight DeFi Kernel released as production version
- Compact (Midnight ZK DSL) toolchain audit-ready
- Cardano ↔ Midnight cross-chain message passing infrastructure mature
- V1 audit completed and stable for 12+ months

**Estimated activation**: 2028 H2 – 2029

#### Dependencies and prioritization

| Product | Depends on | Independent of |
|---------|-----------|----------------|
| V1.0 | Liqwid, USDCx, audit firm capacity | – |
| V1.5 | V1.0 operational | Multi-protocol |
| V2.0 | Second venue + 5 conditions | V1.5 |
| V2.x | Pogun rollout | V2.0, V3.0 |
| V3.0 | Midnight DeFi Kernel | V2.0, V2.x |

V1.5 is prioritized over V2.0 because its trigger conditions are within OptiVaults' control (V1 operational stability) rather than external (second venue emergence). V2.x is prioritized over V2.0 because Pogun's planned 2026–2027 timeline is more concrete than the indeterminate emergence of a second mature lending venue.

#### Sustainability of roadmap

This roadmap is designed to remain meaningful even if individual triggers do not fire:

- If Pogun fails or is significantly delayed: V2.x is deferred, but V1.5 and other products proceed.
- If multi-protocol conditions never materialize: V2.0 is deferred indefinitely, but V1.5, V2.x, and V3.0 remain available.
- If Midnight DeFi Kernel does not mature: V3.0 is deferred, but other products are unaffected.

Multiple parallel paths reduce single-point-of-failure risk in the OptiVaults expansion plan.

---

## 2. Product Overview

### 2.1 Deposit flow

1. User visits optivaults.app/deposit.
2. Connects Cardano wallet (Eternl, Lace, Vespr, Typhon, Yoroi). CIP-30-compliant wallets generally work; the listed wallets are the actively-tested set at launch.
3. Enters USDCx amount and confirms.
4. Wallet signs the TX (built server-side by the OptiVaults API).
5. TX submits to Cardano.
6. On confirmation, user receives vUSDCx at the current share price.

vUSDCx is a Cardano native token. It represents a proportional claim on the vault's assets. As the vault accrues yield, share price grows.

### 2.2 Withdraw flow

1. User visits optivaults.app/withdraw.
2. Enters vUSDCx amount to burn.
3. Wallet signs TX.
4. Vault burns vUSDCx and sends USDCx to the user's address.

**Three withdrawal modes:**
- **Instant** (if idle buffer is sufficient and the `min_hold_seconds` cooldown window after the last Compound has elapsed): fully handled in 1 TX, user pays only network fees. See §2.4 for the cooldown mechanism.
- **Queued** (if buffer is insufficient): user's withdraw order sits in the proxy address; keeper aggregates into a BatchProcess TX in the next batcher cycle. Expected settlement time is typically under 1 hour in normal operation (the keeper runs a batcher cycle every 5-15 minutes and processes pending orders each cycle), but this is an **operational target, not a contract-enforced SLA**. The user's funds remain in the order UTXO and are refundable at any time via `Cancel` (any block) or automatic `Expire` (after the order's on-chain `expires_at` timestamp, default 24 hours).
- **Self-serve emergency** (if keeper is offline for >7 days): user runs `withdraw-cli` locally or uses the emergency-withdraw web tool to build and submit the TX themselves.

### 2.3 Yield Sources and Fee Definition

#### Sole yield source: Liqwid qToken interest

V1 generates yield through a single mechanism: supply-side interest from Liqwid stablecoin lending markets. Deposited USDCx is converted (where appropriate) and supplied to USDCx, USDM, and DJED markets, with Liqwid issuing qTokens that accrue value as borrowers pay interest.

V1 does not earn:
- Liquidity mining rewards from Liqwid (Liqwid does not emit LQ tokens to stablecoin suppliers as of 2026 Q2; this is a structural feature of Liqwid's fee model, not an oversight in V1's keeper logic).
- DEX trading fees (V1 does not provide liquidity to AMM pools).
- Liquidation rewards (V1 does not participate in stability pools).
- Protocol governance fee distributions (V1 does not stake governance tokens).

The single-source design reduces accounting complexity, eliminates reward token volatility exposure, and produces NAV that is monotonic under normal market conditions.

#### Performance fee precise definition

The 4.5% performance fee is calculated as follows at each Compound event:

```
fee_amount = 0.045 × max(0, NAV_now − NAV_last_compound − realised_rebalance_slippage)
```

Where:
- `NAV_now` = total vault value at Compound event time, denominated in USDCx
- `NAV_last_compound` = NAV at the previous Compound event
- `realised_rebalance_slippage` = sum of all slippage costs from inter-market rebalances since last Compound, where slippage is the difference between oracle-fair price and execution price

Key properties:
- **Negative periods generate zero fee.** If NAV declines (e.g., due to USDM depeg), no fee is taken at that Compound. The cumulative loss is borne entirely by share holders.
- **Slippage is borne by the protocol, not the user directly.** Realised rebalance slippage reduces the fee base, not the user's NAV directly (the slippage was already realised when the rebalance executed; this clause ensures the fee is computed on net-of-slippage yield).
- **The fee applies to realised yield only.** Unrealised qToken accrual that has not yet been measured at Compound time does not generate fee until the next Compound.
- **No high-water mark.** Each Compound is computed independently against the previous Compound's NAV. NAV recovery from a previous high does not trigger a "make-up fee" on the recovery portion. Whether HWM is added in V1.5 or later is a governance-level decision and is not currently planned for V1.

#### Launch-day target allocation

(Set by governance `UpdateStrategy`, adjustable within bounds defined in §2.5):

| Asset | Target | Role | Yield contribution at launch |
|-------|--------|------|------------------------------|
| DJED (Liqwid supply) | 45% | Primary yield — algorithmic stablecoin, highest borrow demand at launch | Full Liqwid DJED supply APY on this share |
| USDM (Liqwid supply) | 25% | Secondary yield — fiat-backed, smaller Liqwid market TVL (but ~11.6M USDCx/USDM direct DEX pool is actually deeper than USDCx/DJED paths; see §5.2) | Full Liqwid USDM supply APY on this share |
| USDCx (idle buffer) | 30% | **Withdrawal liquidity — 0% yield at V1 launch** (buffer USDCx sits idle at the vault address; it is NOT supplied to Liqwid's USDCx market at launch) | **0%** — see note below |

#### Why the USDCx buffer earns 0% at launch, and how that can change

The buffer's purpose is to serve Direct Withdraw requests in a single transaction without routing through Liqwid's Recall path (which would add gas cost + potential liquidity friction). To serve that purpose reliably, the buffer must stay liquid — i.e., not tied up in a Liqwid supply position that would require a Recall TX to unwind.

Historically (internal-verification era) V1's predecessors experimented with parking the buffer in Liqwid's USDCx market at ~0.5–2% APY. The experiment showed that (a) Liqwid USDCx market depth is thin enough that unwinding the buffer to serve a ~5% TVL withdrawal already introduces slippage, and (b) the per-cycle Recall+Supply gas cost on a low-APY market consumes more than the yield. **V1 launch therefore ships with buffer = 0% yield, idle at the vault address.**

#### Idle buffer drag — quantified

The buffer's drag on overall yield is measured against the alternative of supplying it to Liqwid's USDCx market at the prevailing supply APY:

```
buffer_drag = buffer_ratio × Liqwid_USDCx_supply_APY
```

At Liqwid USDCx supply APY of 1.5% (current 2026 estimate) and buffer ratio 30%, this represents approximately **45 bps of yield foregone** (30% × 1.5% = 0.45%) relative to a fully-deployed configuration where the buffer is also supplied to Liqwid USDCx. Note: this drag figure measures the buffer's cost vs supplying to Liqwid USDCx specifically, not vs the highest-APY single market.

The buffer becomes governance-activatable for partial Liqwid USDCx deployment under the following conditions, which are 7-day timelock governance parameters:

- Liqwid USDCx market depth exceeds $10M
- Liqwid USDCx market 90-day average APY exceeds 3%
- Outstanding withdrawal queue is below 5% of vault TVL

Activation reduces the idle ratio to 15% (deploying 50% of the buffer to Liqwid USDCx) while preserving sufficient liquidity for normal redemption flow.

**Governance-adjustable — explicit reservation for future Liqwid USDCx allocation.** V1 launches with an explicit **0% allocation to Liqwid USDCx** for conservative reasons, but reserves the right to reallocate a portion of the idle buffer into Liqwid's USDCx supply market via governance `UpdateStrategy` (7-day timelock) when the conditions above hold. Triggering conditions also include: a better-yielding low-risk home for the buffer emerging (e.g., a future Cardano Treasury T-bill wrapper, a deeper stablecoin money market). None require a contract change — they are policy adjustments within existing validator logic. Governance will publicly disclose the rationale + expected yield uplift + unwind plan before any such `UpdateStrategy` is executed; depositors have the 7-day timelock window to exit if they disagree.

#### Inter-market routing and rebalancing

V1 dynamically allocates supplied capital across USDCx, USDM, and DJED Liqwid markets. Rebalancing between markets is triggered by:

- APY spread between markets exceeding 200 bps for 7+ days
- Single-market utilization exceeding 90% for 24+ hours (rebalance away)
- Single-stablecoin price deviation exceeding 50 bps from peg for 1+ hour (rebalance away)
- Governance-initiated weight adjustment (7-day timelock)

The complete rebalance algorithm specification, including slippage budgets, DEX path selection, and frequency limits, is published as `spec/rebalance-policy.md` in the OptiVaults GitHub repository. Source code is the canonical reference; the whitepaper provides only the high-level mechanism description.

This is not a pure-USDCx product. The 70% DJED + USDM exposure is core to the value proposition (deeper borrow markets, higher APY than idle USDCx), but depositors bear the depeg / liquidity risk of all three stablecoins in proportion to the vault's current mix. See §5.2 for the multi-stablecoin depeg disclosure.

**V1 does NOT use:**
- DEX LP positions (impermanent loss risk).
- Algorithmic yield farming (governance token emissions).
- Leveraged positions.
- Cross-chain bridges.

Yield is strictly the interest differential between Liqwid supply APY (blended across the three markets) and the 4.5% performance fee OptiVaults charges on realised yield.

### 2.4 Fee structure

- **Performance fee: 4.5%** (`performance_fee_bps = 450`) of gross yield at each Compound event, paid in **USDCx** (not ADA) out of the realized yield before it is re-added to `total_deposited`. Hard cap validated in `vault_gov_policy.ak`'s `UpdateFee` redeemer (via the shared `validate_update_fee` helper): 4.5%. Governance cannot exceed this cap under any redeemer.
- **Early-withdraw fee: 0.1%** (`early_withdraw_fee_bps = 10`) charged on every Direct Withdraw while the keeper is active (automatically waived after 7 days of keeper inactivity). Paid in **USDCx** as a reduction of the withdrawn amount; fee retained in the vault, accrues to remaining holders as share-price appreciation. Hard cap: 1% (100 bps).
- **`min_hold_seconds` (Direct Withdraw gating, not a lock):** after every Compound, Direct Withdraw is gated for `min_hold_seconds` before it can be submitted again; the Queue Withdraw path remains open throughout. Launch value is 60 seconds. Governance can raise it via `UpdateFee` (14-day timelock), subject to a validator-enforced hard cap of **6 hours (`max_min_hold_seconds = 21_600`)**. Tightened from an earlier 24-hour design (see §6.3 and §2.4 rationale below): a 6-hour cap blocks at most ~3.6% of a weekly-Compound cycle's Direct Withdraw availability even at the extreme, and the Queue path is never affected — so user funds are never locked, only routed through a different path with ~5–15 min settlement.
- **SwapAda operational drag: ~0.02% APY at 100K TVL** (quantified in §4.5). Not a protocol-level fee — this is the USDCx cost borne by depositors when the on-chain `SwapAda` redeemer tops up vault operating ADA at the Charli3 + Orcfax oracle rate. Roughly 10–20 USDCx/year at 100K TVL, fully absorbed into share-price progression. Disclosed because it is a real economic flow out of the vault, even though it's not charged as a "fee" in the traditional sense.
- **No deposit fee.**
- **No management fee (AUM fee).**

**3-way fee split (V1).** Each Compound splits the performance fee according to `VaultDatum.keeper_fee_bps` and `VaultDatum.gov_fee_bps`. Keeper share goes directly to the signing keeper's address in USDCx; gov pool share accumulates in the MultisigGov UTXO's `signer_compensation_pool` field (quarterly distribution, economics.md §7A); treasury share flows to the treasury script address.

| Phase | Trigger | Keeper | Gov pool | Treasury |
|-------|---------|--------|----------|----------|
| V1 launch | Deploy default | 40% | 0% (disabled) | 60% |
| Phase 2 | TVL ≥ 500K + external signer added | 40% | 5% | 55% |
| Phase 3 | TVL ≥ 2M + community signer added | 40% | 10% | 50% |

**Hard caps**: `keeper_fee_bps ≤ 4000` (40%), `gov_fee_bps ≤ 1000` (10%), `keeper + gov ≤ 5000` (treasury floor ≥ 50%). Changes require `UpdateFeeSplit` with **21-day timelock** (longest of any governance action — the governance is adjusting its own pay). The 40% keeper cap is set explicitly to support open-source third-party keeper viability under V1's public-goods positioning — at 40% the Phase 2+ non-founder-keeper breakeven drops to ~$1M TVL (from ~$1.5M at the historical 25% cap).

**V1-era disclosure on the three-way split.** Keeper / gov pool / treasury are three distinct on-chain flows in terms of address, redeemer authorization, and timelock. At V1 launch, however, the **human controllers** of these three flows overlap significantly — the founder operates the keeper and holds governance signer seats, and treasury spending also requires governance signatures (see §9.1). The three-way split in V1 is therefore **structural preparation for decentralization, not realized decentralization today**. See §6.1 (Six-identity separation target) for the rotation path to economic independence of the three pockets.

Prior internal-verification deployments sent 100% of fees to a single operator wallet. V1 separates these flows on-chain with a rotating keeper model (§7 "Run Now, Open Later") and a soul-bound Gov Signer NFT (`spec/gov-nft.md`) for reputation accountability. The Gov Signer NFT's soul-bound property is **enforced via the minting policy's spending-script check** (not a native ledger feature): any TX that spends a UTXO carrying a Gov Signer NFT must either return the NFT to an output paying the signer's original PKH (derived from the NFT's asset-name suffix) or burn the NFT via `BurnRotatedOut`. Third-party transfers fail the script check and are rejected by the ledger. The NFT carries no voting or financial rights (those live in MultisigGov's datum); it is recognition only.

### 2.5 Strategy Weight Sensitivity

The default strategy allocation (45% DJED / 25% USDM / 30% USDCx idle buffer) is a launch position, not a permanent configuration. This section documents the conditions under which governance can adjust weights and the bounds within which adjustments must remain.

#### Why launch at 45% DJED rather than higher

DJED currently offers the highest single-market APY among Liqwid stablecoin markets (approximately 11.8%). A higher weight to DJED would increase blended yield. We launch at 45% rather than a higher percentage because:

1. **DJED collateral is ADA-denominated.** A severe ADA decline (>30% in <72 hours) reduces DJED's collateralization ratio and risks depeg. Concentration above 50% would produce unacceptable NAV volatility in tail scenarios.
2. **Liquidity depth on Cardano DEXes for DJED conversion is finite.** Larger DJED positions face higher rebalance slippage during stress periods.
3. **Stablecoin issuer diversification matters.** DJED is a Coti-issued algorithmic stable; USDM is Mehen-issued fiat-backed; USDCx is Circle-issued via xReserve. 45% DJED preserves issuer diversity.

#### Adjustment triggers (governance, 7-day timelock)

The following parameters can be adjusted by governance multisig with 7-day timelock:

| Parameter | Range | Default | Adjustment trigger conditions |
|-----------|-------|---------|------------------------------|
| DJED weight | 30% – 55% | 45% | DJED collateral ratio, ADA volatility, Liqwid DJED utilization |
| USDM weight | 15% – 35% | 25% | USDM Liqwid market depth, USDM peg stability |
| USDCx weight | 0% – 30% (deployed) | 0% (idle buffer) | Liqwid USDCx market depth, market APY |
| Idle buffer minimum | 10% – 30% | 30% | Withdrawal queue length, vault TVL stability |

#### Conditions for raising DJED weight (toward upper bound)

DJED weight may be increased toward 55% only if all of the following hold:

- DJED system collateral ratio above 500% sustained 30 days
- ADA 30-day historical volatility below 60%
- DJED-USDC Cardano DEX depth above $5M (for rebalance liquidity)
- Liqwid DJED market utilization between 40% – 80% (avoid extremes)

#### Conditions for lowering DJED weight (toward lower bound)

DJED weight is automatically reduced toward 30% if any of the following hold:

- DJED collateral ratio below 300%
- ADA 30-day historical volatility above 100%
- Liqwid DJED market experiencing utilization above 95% for 24+ hours
- DJED-USDC peg deviation exceeding 50 bps for 1+ hour

Lowering is automatic (Keeper-triggered with on-chain validation), not subject to timelock, because the conditions are themselves stress signals where speed matters.

#### Public publication of current weights

Current strategy weights and the conditions of any pending adjustment proposals are published on the OptiVaults dashboard. Governance proposals for weight changes are publicly documented with rationale, expected impact analysis, and minority opinions if any are submitted by signers.

### 2.6 Compound cadence

Compound schedule is driven by TVL tiers (internal-verification-era operational policy, not contract-enforced):

| `total_deposited` tier | Compound schedule | Zero-yield heartbeat |
|------------------------|-------------------|----------------------|
| < 300 USDCx | deferred until accrued yield > $1 | every 30 days |
| 300–750 USDCx | monthly | every 5 days |
| 750–1,200 USDCx | biweekly | every 5 days |
| 1,200+ USDCx | **weekly, anchored on Saturday** | every 5 days |

- **Weekly Saturday Compound** (1,200+ tier): once TVL enters the weekly tier, Compound runs every Saturday to settle that week's yield in a single scheduled cycle.
- **Zero-yield Compound**: the 5-day heartbeat advances `last_realloc_time` even when there's no real yield, so off-chain indexers can see the vault remains active.
- **Buffer-funded Compound**: when Liqwid `supplied_value` has grown since last Compound, the performance fee is deducted directly from buffer USDCx — no Recall needed first.

**The 100K cap is a ceiling, not where Phase 1 actually sits.** §8.2 documents that realistic Phase 1 TVL is a $500–$25K range, and the (a) sub-scenario explicitly contemplates V1 operating at $500–$5K. The table above is therefore the **full** TVL-tier schedule the keeper uses — not legacy V2-migration recovery branches. The keeper picks the tier matching live `total_deposited` at each cadence decision. §2.6.1 describes the corresponding low-TVL operational mode.

Keeper must sign each Compound TX. Fallback: if keeper is inactive for >7 days, governance can execute Compound via m-of-n signatures.

### 2.6.1 Reference Implementation Mode (low-TVL operational policy)

When V1 sustainably operates at TVL below the threshold where the §2.6 default cadence is economically rational, the keeper switches to **Reference Implementation Mode** — a relaxed operational policy that maintains contract liveness without consuming on-chain gas disproportionate to accrued yield. This mode is the operational counterpart of §0's "Cardano DeFi public-goods reference implementation" framing during the low-TVL period: V1 stays fully functional as a deployed reference without burning operating budget on cadence that the yield base cannot justify.

#### Activation conditions

Reference Implementation Mode activates when **both**:

1. V1 mainnet TVL has been below $25K for 30+ consecutive days, AND
2. The 4-week trailing average of accrued qToken yield per Compound interval would be less than 5× the on-chain TX cost (i.e., yield does not justify Compound frequency).

Deactivation: triggered when TVL crosses $25K and remains above for 30+ days. Re-activation if TVL drops back. The mode is operational policy exercised by the keeper under §4.5 economic-rationality discretion — it does **not** require an `UpdateStrategy` governance action.

#### Operational adjustments under this mode

| Operation | §2.6 Default cadence | Reference Implementation Mode |
|---|---|---|
| Productive Compound | Weekly (Saturday-anchored) at 1,200+ tier | Only when accrued yield > $5 USDCx; typically quarterly to annually at $1–5K TVL |
| Liveness heartbeat | Every 5 days | ~80-day cadence (kept below the 90-day §5.5.1 Layer 3 CommunitySunset threshold) |
| Rebalance | When §2.5 trigger conditions met | When allocation drift exceeds §2.5 band; not scheduled |
| SwapAda | When `vault.lovelace < 15 ADA` | Same trigger; pre-deposit ceremony seed extended to 20+ ADA to reduce first-call frequency |
| Discord ops alerts | Per-Compound + per-heartbeat | Quarterly + annual summary; weekly digest dropped |

#### What this preserves (no compromise)

- All contract invariants — no fee changes, no governance shortcut, no validator bypass.
- All depositor protections — `emergency-withdraw`, hard caps, `withdraw-cli`.
- All §5.5.1 three-layer governance safety — Layer 1 freeze-only, Layer 2 swap-out, Layer 3 CommunitySunset all functional.
- Share-price NAV accuracy — qToken value is read on demand; the `total_*` datum fields update at Compound time as designed.
- 7-day keeper-inactivity gate (§5.4) works as documented — it reads `last_compound_time`, not affected by reduced heartbeat cadence.

#### What this changes

- **Off-chain indexer staleness**: `last_realloc_time` updates infrequently. Frontend dashboards must accommodate this — staleness is normal under Reference Implementation Mode, not a fault signal.
- **Performance fee crystallization**: deferred to withdraw events or sparse Compounds. Cumulative perf-fee amount is identical; only timing differs.
- **Treasury accrual rate**: same percentage of yield but less frequent transfers — treasury still accumulates correctly when Compound fires.

#### Why this exists

At $1–5K TVL, the §2.6 weekly Compound cadence costs approximately $50–75/year in keeper gas while harvesting only $1–4/year in performance fees. Operating at default cadence in this scenario is economically irrational and contradicts §4.5's stated principle that "Compound frequency is a ceiling, not a target."

Reference Implementation Mode reduces operational cost by approximately 85–90% while preserving all contract guarantees, aligning V1's operational footprint with its §0 non-commercial public-goods positioning during the small-TVL period. This is the honest operational mode for a deposit-tier where V1 is functioning as a public reference rather than as a yield product.

#### Disclosure requirements

The keeper publishes the current operational mode on the OptiVaults dashboard. The disclosure includes: active mode (Default / Reference Implementation), the trigger condition that activated current mode, time since mode activation, next anticipated Compound (with estimated USDCx yield to be harvested), and next anticipated heartbeat. Depositors can independently verify mode activation by checking `last_compound_time`, `last_realloc_time`, and `total_deposited` on-chain against the dashboard's claims.

#### Mode transition mechanics

When TVL crosses $25K and the deactivation conditions are met:

1. Keeper publishes intent to switch back to Default Mode on dashboard (depositor notification).
2. Next productive Compound fires within 7 days, harvesting all accrued yield.
3. Heartbeat cadence resumes to the §2.6 default (every 5 days).
4. Rebalance triggers per §2.5 conditions.

Transitions are keeper-initiated under §4.5 discretion. If a future governance deems automatic transition desirable, an `UpdateStrategy` action can codify the trigger; v1.3 spec does not require this.

---

## 3. Technical Architecture

### 3.1 Smart contract stack

V1 deploys **17 logic validators** (one of which, `vusdcx`, is the share-token minting policy — see #17 in the list below), **4 one-shot NFT minting policies** (`vault_nft` / `governance_nft` / `registry_auth_nft` / `gov_signer_nft`), **1 DEX adapter** (`minswap_v2_adapter`), and the **2-artefact SundaeSwap adapter pair** (`sundaeswap_adapter` + `sundaeswap_cancel_guard`). Total: 17 + 4 + 1 + 2 = **24 compiled artefacts**.

1. **vault_proxy** — entry point, forwards spends via Withdraw-Zero pattern (10 routes: User / KeeperHot / Batcher / SwapAda / Protocol / Recall / Liqwid / GovPolicy / GovEmergency / AdminDeploy; see §3.2).
2. **vault_user** — Deposit, Withdraw only. Purely permissionless — no keeper authorization required.
3. **vault_keeper_hot** — Compound, RebalanceBuffer. Keeper hot-path; Compound's 3-way fee split treasury output binding lives here.
4. **vault_batcher** — BatchProcess only. Keeper-authorized staking validator that owns the 4 fold loops (order_sums / order_owners / vusdcx_leaked / payout_indices) + OrderDatum / OrderRedeemer decoding + `list.unique` + anti-leak invariants. See `spec/order-batch.md`.
5. **vault_swap_ada** — SwapAda only. Owns the §5.4 P5 dual-feed oracle reader + 6-tuple registry read. Inactive at V1 launch until governance populates the ADA entry in `asset_oracles`; see `spec/ada-swap.md`.
6. **vault_protocol** — DeployToProtocol (SwapAdapter dispatch + bounded ADA spend).
7. **vault_recall** — RecallFromProtocol, MergeUtxo.
8. **vault_liqwid** — SupplyToLiqwid, RecallFromLiqwid (per-market position tracking).
9. **vault_gov_policy** — UpdateStrategy, UpdateFee, UpdateFeeSplit, UpdateSlippagePolicy (governance policy changes; 7d–48h timelocks).
10. **vault_gov_emergency** — EmergencyWithdraw only (0d timelock). Keeps the fast-response governance path on a tight validator whose attack surface cannot grow by future SwapAdapter additions.
11. **vault_admin_deploy** — AdminDeployNonDeposit only. Governance non-deposit-token recovery path (7d keeper-inactive + 21d registry-stable gates). Owns the SwapAdapter dispatch + destination-whitelist check + 6-tuple registry read.
12. **keeper_stake_script** — pluggable keeper authorization (GovernanceOnly at V1 launch; PermissionlessWithBond reserved for Phase 3+).
13. **treasury** — holds non-keeper fee share, 4-category budget (audit reserve / ops / R&D / buffer).
14. **multisig_gov** — m-of-n governance state machine with timelock + 1-of-n cancel + signer-compensation pool.
15. **registry** — stable-token whitelist, protocol-address whitelist, Liqwid market catalog, `asset_oracles`, `swap_adapter_hashes`.
16. **order** — user deposit/withdraw order queue validator.
17. **vusdcx** — share token minting policy.

Plus 4 mint-only one-shot NFT policies:

- `vault_nft` — one-shot Vault Identity NFT minting policy (cryptographic one-shot via consumed UTXO ref; see `spec/vault-nft.md`).
- `governance_nft` — one-shot Governance NFT (locks the single MultisigGov UTXO).
- `registry_auth_nft` — one-shot Registry auth NFT (locks the single Registry UTXO).
- `gov_signer_nft` — recognition-only soul-bound NFT issued to each governance signer. Mint / burn gated on consuming the MultisigGov UTXO in the same TX. Carries no voting or financial rights. See `spec/gov-nft.md`.

Plus 3 swap-adapter artefacts:

- `minswap_v2_adapter` — SwapAdapter interface implementation (see `spec/swap-adapter.md`). Parameterized on governance anchors (solely to enable the A2 `publish` handler for stake-deposit recovery — see §5.1 + §6.2 `ActDeregisterStake`); adapter hash is the sole identity used by the Registry `swap_adapter_hashes` whitelist.
- `sundaeswap_adapter` — V1's second SwapAdapter, targeting SundaeSwap V3 + Stableswaps and bound at deploy-ceremony init (see `spec/swap-adapter.md` §8).
- `sundaeswap_cancel_guard` — small staking validator that makes an un-filled SundaeSwap order's cancel drain-proof (the full order value must return to the vault address).

Total compiled artefacts: **17 logic validators + 4 NFT mint policies + `minswap_v2_adapter` + 2 SundaeSwap artefacts = 24**.

**Second DEX adapter — SundaeSwap.** V1's second SwapAdapter targets SundaeSwap V3 + Stableswaps: `sundaeswap_adapter` (the adapter itself) plus `sundaeswap_cancel_guard` (a small staking validator that makes an un-filled SundaeSwap order's cancel drain-proof — the full order value must return to the vault address). The pair is **bound at deploy-ceremony init**: the ceremony config carries a `sundaeswap` block, the two artefacts are folded into the hash DAG, published as reference scripts, and seeded into the Registry whitelist. SundaeSwap's role is V1's USDM leg — its `USDCx/USDM` stableswap pool gives lower like-asset slippage — plus a liveness backstop if the Minswap V2 batcher stalls; the DJED leg stays on Minswap V2. SundaeSwap is therefore part of every V1 launch deploy, and the ceremony-cost figures quoted elsewhere in this whitepaper (~962 ADA reference-script lockup, 20 reference scripts, ~42 ceremony TXs) already include it. See `spec/swap-adapter.md` §8.

**Topology rationale.** The 24-artefact count reflects partitioning along four orthogonal seams (authorization-boundary, governance response-latency, bytecode-cost-center, size-fix) driven primarily by the Plutus V3 16 KB reference-script ceiling — not arbitrary subdivision. Engineering rationale + post-split sizes live in `spec/architecture.md §4.1`; this whitepaper does not enumerate the chronological commit-by-commit history, which has no bearing on depositor decisions.

See `spec/architecture.md` for full redeemer details and `spec/vault-datum.md` for the VaultDatum schema (29 fields after §5.4 Phase 2 + Phase 1 governance safety dead-man-switch).

### 3.2 Withdraw-Zero Forwarding Pattern

Cardano Plutus V3 has a 16 KB limit on validator reference script size. V1's vault logic exceeds this. The solution: split the vault across multiple staking validators (`vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`) and use `vault_proxy` as a spend-path forwarder.

**Flow:**
1. Spending a vault UTXO triggers `vault_proxy`.
2. `vault_proxy` requires the TX to have a zero-amount withdrawal from the correct staking script, selected by the proxy's `ProxyRedeemer` (`UseUser` / `UseKeeperHot` / `UseBatcher` / `UseSwapAda` / `UseProtocol` / `UseRecall` / `UseLiqwid` / `UseGovPolicy` / `UseGovEmergency` / `UseAdminDeploy`).
3. The staking withdrawal triggers the actual validator (which has the full redeemer-specific logic).
4. The staking validator returns success → proxy allows the spend.

This pattern means every vault spend is actually two validator invocations: proxy (cheap, ~4.9 KB) + one of ten staking validators (heavy, up to 16 KB each). A `withdrawal_count` invariant in `vault_proxy` ensures exactly one staking validator is invoked per TX, preventing double-routing.

### 3.3 Compile-time trust anchors

V1 extensively uses compile-time parameters to anchor trust at deploy time. Fields baked into validator hashes include:
- **Vault NFT policy** — anchors vault identity across `vault_proxy` / `vusdcx` / `order`
- **Governance NFT policy + name** — baked into `multisig_gov` / `keeper_stake_script` / `vault_gov_policy` / `vault_gov_emergency` / `vault_admin_deploy` / `vault_protocol` / `vault_recall` / `vault_liqwid` / `vault_user` / `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada` / `minswap_v2_adapter`; used by every governance-gated validator (and every staking validator's A2 `publish` handler, see §6.2 `ActDeregisterStake`) to verify the real gov UTXO is being consumed
- **Keeper stake-script hash** — baked into `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada` / `vault_protocol` / `vault_recall` / `vault_liqwid`; keeper authorization is delegated to `keeper_stake_script` (see `spec/keeper-auth.md`), so the authorized PKH set can change without redeploying the vault. Note: `vault_user` does NOT take this anchor — post-Phase-77d it is purely permissionless (Deposit + Withdraw are user-signed only).
- **Staking validator hashes** — `user_stake_hash` / `keeper_hot_stake_hash` / `batcher_stake_hash` / `swap_ada_stake_hash` / `protocol_stake_hash` / `recall_stake_hash` / `liqwid_stake_hash` / `gov_policy_stake_hash` / `gov_emergency_stake_hash` / `admin_deploy_stake_hash` baked into `vault_proxy` for the 10 Withdraw-Zero dispatch routes
- **Treasury script hash** — baked into `vault_keeper_hot` (Compound fee routing) and `multisig_gov` (DistributeSignerCompensation forfeit routing)
- **Deposit token policy + name** — baked into `treasury` and `multisig_gov`
- **vUSDCx minting policy** — deployed as a policy parameterized by `vault_hash` + `vault_nft_policy`

Changing any anchor requires a full redeploy (new validator hashes, new vault address, migration). This is the structural defense against the "phantom vault" class of attacks identified during internal verification.

**Vault Identity NFT design — PlutusV3 UTXO-ref one-shot.** V1's Vault Identity NFT minting policy is a **PlutusV3 validator** parameterised by a specific UTXO reference, not a Cardano native script. The mint branch requires the parameterised UTXO to be in the transaction's inputs (consumed-UTXOs-cannot-be-replayed → cryptographic one-shot); the burn branch is unconditional (burn always succeeds, enabling clean vault sunset). This design replaces the `{all: [sig, before(slot)]}` native-script pattern used in internal-verification phase deployments — that pattern was trust-based (relied on the keeper not double-minting) and deadline-trapped on burn (once the `before` slot expired, burning became impossible, permanently locking the vault's min-ADA ≈ 15–20 ADA per vault deploy). The PlutusV3 pattern is strictly stronger on both axes at the cost of a modest script-size increase. Full specification: `spec/vault-nft.md`.

### 3.4 External dependencies

| Dependency | Purpose | Trust Delegation | Fallback |
|------------|---------|------------------|----------|
| Liqwid Finance | Money market yield | qToken rate accuracy, bad-debt prevention | EmergencyWithdraw + KeeperToggleMarket |
| Minswap V2 | DEX swaps | Batcher execution, fill pricing | Order Cancel/Expire refund |
| USDCx issuer (Circle via xReserve) | 1:1 USDC backing + crosschain reserve integrity | Stable $1 peg | Depeg monitoring + manual halt |
| Charli3 + Orcfax oracles | ADA/USD price feed for the `SwapAda` replenishment redeemer + P4 Tier 1 oracle-based fair-price bound on DEX swaps | Fair price + freshness — via the shared `lib/vault/oracle.ak` dual-feed aggregator (≥ 2 healthy samples within 2% cross-feed disagreement window, each ≤ 10-minute stale, returns midpoint). Oracle config lives in the registry's `asset_oracles`, managed via governance `UpdateRegistry` (14-day timelock). | Governance `UpdateOracleSource` (14-day timelock) can rotate feeds if one source degrades; V1 launch ships with `asset_oracles = []` — SwapAda is inactive until governance enables the ADA entry (bootstrap via `MergeUtxo` donations) |
| Blockfrost / Ogmios | Chain indexing for keeper + API | UTXO state accuracy | Multi-source, on-chain truth |

### 3.5 Two-layer code organisation

V1's source code is split across **two separate public repositories**, each with its own audit scope, release cycle, and security-disclosure channel:

| Layer | Repository | What lives there | Fee | Fork implications |
|-------|-----------|------------------|-----|-------------------|
| **Protocol layer** | [`optivaults-protocol`](https://github.com/OptiVaults/optivaults-protocol) | Aiken validators, spec, whitepaper, deploy pipeline | **Zero fee** — anyone may fork and launch a vault instance without paying OptiVaults anything | Forking the protocol layer produces a new, independent vault |
| **Operator layer** | [`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference) | TypeScript keeper, API server, frontend, CLI tools (self-serve Withdraw / Emergency) | 4.5% of realised yield on the **OptiVaults-operated instance** at `optivaults.app` | Forks are encouraged; a fork operator sets their own fee (or zero) and runs their own hosted infrastructure |

**The 4.5% performance fee is a property of the operator instance, not of the protocol.** A team that forks `optivaults-protocol` and deploys their own vault — with their own keeper wallet running their own fork of `optivaults-reference`, or with a completely rewritten keeper — owes OptiVaults nothing. The contract-enforced 4.5% hard cap applies to the performance fee paid by depositors of a given vault instance; it constrains what governance of that specific vault can set, not what fork operators can charge their own depositors.

**Security-disclosure routing.** Protocol-layer findings (Aiken validator bugs, datum injection, on-chain invariant violations) go to `optivaults-protocol/SECURITY.md`. Operator-layer findings (keeper runtime bugs, API authentication, frontend XSS, CLI parsing) go to `optivaults-reference/SECURITY.md`. When in doubt, protocol-layer is the default channel — triage will forward.

**Audit scope parallels the layer split.** The Q2-Q3 2027 external audit targets the protocol layer specifically (see §8.1 and `docs/audit-scope.md`). Operator-layer code is audited separately on its own schedule; its trust properties are narrower because its failure modes are bounded by the on-chain protocol's invariants (a compromised keeper can cause operational DoS but cannot extract principal).

---

## 4. Economic Model

### 4.1 Launch economics

At 100K USDCx TVL and ~5-6% net yield (current-reference scenario from `docs/economics.md §6.2`; buffer=0% math yields ~6.36% net at 2026-Q2 Liqwid rates, with the low end covering rate compression):

| Metric | Value |
|--------|-------|
| Gross yield/year (conservative 5%) | $5,000 |
| Gross yield/year (optimistic 8%) | $8,000 |
| Performance fee (4.5% of gross) | $225-360 |
| Keeper share (40% at V1 launch) | $90-144 |
| Gov pool (0% at launch, activated Phase 2+) | $0 |
| Treasury share (60% at V1 launch) | $135-216 |
| Operating costs (keeper + infra + audit reserve) | $360-2,400 |

**Reality: protocol revenue does not cover operating costs at 100K TVL.**

V1 operates in a **bootstrapping phase** until TVL reaches the self-sustaining range, which spans approximately **$135K–$1.8M across the §4.1 sensitivity scenarios** (optimistic / baseline / conservative respectively) with **baseline centred around $500K**. Below that threshold, initial operating shortfalls are absorbed by the project's founding capital — this is a normal early-protocol state for new DeFi launches on Cardano. Above the threshold, OptiVaults' own revenue funds baseline operations, and higher TVL incrementally funds audit reserve, R&D, and buffer categories.

**Phase 1 expectation reset** (to be clear with depositors up front). The **$135K–$1.8M self-sustaining range (baseline ~$500K)** is, by construction, a **Phase 2+ post-audit reference milestone** under §2.6 Default cadence — it cannot be reached inside the pre-audit 100K USDCx cap. Our internal estimate for Phase 1 (pre-audit, under the 100K cap) TVL is a **$500-$25K** range over the first 6-12 months, based on conservative user-acquisition assumptions and the permissionless-only stance (no closed-beta gate, no invitation list — actual TVL depends entirely on organic discovery); this is a speculative range rather than a forecast, and we state it to be honest about modelling assumptions — not as a commitment. The 100K ceiling is a risk envelope, not a sales target. Under the §4.3.1 volunteer-operator model, Phase 1 operational shortfall (protocol revenue < operating cost) is absorbed by the founder's ongoing personal-income subsidy (~$80–$200/year), **not** drawn from a pre-committed founding-capital reserve sized to include audit budget. See §0.2 + §4.3.1 for the funding posture and §8.2 for the full Phase-1-is-protocol-validation framing.

**Sensitivity of the self-sustaining TVL threshold** (as a function of Liqwid supply APY + operating cost). The **$135K–$1.8M range** in §4.1 spans the three sensitivity scenarios below (optimistic / baseline / conservative), computed for both the §2.6 Default cadence and the §2.6.1 Reference Implementation Mode; baseline self-sustain is ~$500K:

| Scenario | Liqwid APY | Operating cost (Default Mode) | Self-sustaining TVL (Default) | Operating cost (Reference Implementation Mode) | Self-sustaining TVL (Reference) |
|----------|------------|--------------------------------|-------------------------------|------------------------------------------------|---------------------------------|
| Optimistic | 10% (strong borrow demand) | $600 (low end) | ~$135K | $80 | ~$18K |
| Baseline | 6% (recent Liqwid level) | $1,200 | ~$500K | $150 | ~$56K |
| Conservative | 3% (borrow-demand contraction) | $2,400 (high end with audit-reserve expansion) | ~$1.8M | $250 | ~$185K |

Formula: `self-sustaining TVL ≈ annual operating cost / (gross APY × performance fee rate 0.045)`. Under the conservative-Default scenario, reaching the threshold from external-audit completion could take **3-5 years** of TVL ramp (post-audit cap lift + multiple marketing cycles + overall Cardano DeFi TVL growth). **Under the §4.3.1 volunteer-operator model, V1 does not require self-sustainability to remain operational** — operating cost is absorbed from founder personal income at ~$80–$200/year indefinitely (§4.3.1 cost-scaling table). The thresholds in the sensitivity table above are therefore **reference milestones for a hypothetical "no-subsidy" operating posture**, not financial-survival targets V1 must reach. The live sunset triggers are §1.5 Class A overrides or explicit founder decision (§4.1 Trigger A–D + §9.2), not founding-capital-runway exhaustion. This framing matters for depositors: V1 staying at $25K TVL forever is operationally fine; what would end V1 is external infrastructure failure or founder explicit sunset, neither of which is gated on TVL.

**Interpretation of the Reference Implementation Mode column.** Under §2.6.1 cadence at baseline assumptions, V1's self-sustaining TVL drops from $500K to approximately $56K — a roughly 9× reduction. This makes V1's economics viable at a much smaller scale, supporting the §8.2 (b) "small organic" sub-scenario operational profile. This is not a free lunch — it simply reflects the operational reality that low-TVL vaults should not run at the same cadence as $100K+ vaults. Reference Implementation Mode aligns the cost base with the actual yield base. The Default and Reference columns are not alternatives the keeper picks for optics; the mode is governed by the §2.6.1 activation/deactivation conditions and tracked publicly on the dashboard.

**The Reference $56K self-sustain does NOT change the sunset trigger.** The sunset condition stated below — "TVL < $500K at 6 months post external-audit completion" — is a **post-audit Default-cadence** threshold, set against V1's post-launch growth profile under §2.6 default cadence. The $56K figure describes **pre-audit / low-TVL** sustainability under §2.6.1; it does not lower the post-audit growth bar. v1.3 surfaces both numbers in the same table for transparency, but they describe different operational regimes and are not interchangeable. A reader who conflates them would mistakenly conclude V1 can "self-sustain at $56K" all the way through Phase 2 — which is not the case once §2.6 default cadence resumes.

**The $25K–$500K gap (Default mode, not "self-sustaining" but operationally fine under the volunteer model).** Between the §2.6.1 deactivation threshold ($25K — keeper exits Reference Implementation Mode) and the hypothetical no-subsidy self-sustain figure (~$500K), V1 operates in §2.6 Default cadence **while protocol revenue alone does not cover operating cost**. Concretely: at $50K TVL × 6% gross × 4.5% perf fee = $135/year protocol revenue vs $200–$500/year operating cost under §4.3.1's TVL-band ($25K–$100K) configuration = ~$0–$200/year shortfall absorbed by the founder from personal income (§4.3.1 cost-scaling table). **This is not a sunset trigger.** Under the volunteer-operator model the shortfall is structurally durable — it does not draw down a finite runway. The §8.2 sub-scenario (c) "$25K–$100K cap-approach" sits inside this gap; sub-scenario (b) $5K–$25K stays in Reference Implementation Mode and runs below ~$80/year operating cost. Sunset triggers are §1.5 Class A overrides or explicit founder decision (§4.1 Triggers A–D), not TVL stalling in this gap.

**Founding-capital commitment is intentionally minimal — operations only, not audit.** Founding capital committed to V1 by the founder is sized **solely for operations + minimal contingency, NOT for self-funding the external audit**. Concretely the commitment covers: (a) ~$2K USDCx seed as Phase 1 working capital, (b) ~$200–$500 USD over the 18-month pre-audit window for infrastructure (single-server minimal setup under §2.6.1 Reference Implementation Mode + §4.3.1 minimal-operations policy), (c) a small ongoing operating subsidy (~$80–$200/year scaling with TVL — see §4.3.1 cost-scaling table) that the founder absorbs from personal income, and (d) an audit-funding **gap-fill cap of approximately $15K** that the founder commits to bridge small shortfalls between the §8.1 funding stack and the final audit price (NOT to underwrite the full audit cost).

**Audit is funded entirely externally.** The external audit ($50–$150K depending on engagement model — see §8.1) is funded from external sources only (Project Catalyst, Cardano Foundation, Intersect Member Committee, Aiken Foundation, audit-firm public-goods rate, community contribution pool). The founder commits up to ~$15K personal gap-fill (per item (d) above) to bridge small shortfalls, but **explicitly does NOT commit to underwriting the full audit cost in any scenario**. If the funding stack underperforms beyond gap-fill capacity, V1 does not proceed to mainnet — see §8.1 Options A–D for the contingency tree (timeline extension / scope-reduced audit / community crowdfund / permanent Preprod under Apache 2.0).

**Sunset trigger semantics under the volunteer + cap-lift-by-audit model.** §4.1's nominal sunset condition ("runway < 6 months forward burn") interprets "runway" as the founder's operating-side commitment, not as audit commitment. At ~$80–$200/year minimal operating burn, the operating runway is **structurally durable** — even a few hundred USD covers years; sustaining it from personal income is realistic for an extended period. **Audit-funding outcome is NOT a sunset trigger.** Audit funding determines whether the cap lifts above 100K (per §8.1 Options A–D); it does not determine whether V1 keeps running. The live sunset triggers for V1 are §1.5 Class A overrides (USDCx incident, Liqwid incident, Cardano chain halt, oracle anomaly persisting), or explicit founder sunset decision under §9.2. **Operating-runway sunset is essentially unreachable** under the §4.3.1 minimal-cost model. §8.1 Option D ("permanent pre-audit 100K cap") is the right framing for sustained audit-funding failure — V1 continues on mainnet at 100K, not in sunset.

**Sunset triggers and mechanics** (§9.2 + economics.md §7.2). Under the volunteer-builder + β cap-lift-by-audit model, V1 has **four independent sunset triggers**; if any one fires, the orderly-sunset protocol below activates:

- **Trigger A — Post-audit growth failure (conditional on audit happening):** TVL < $500K at **6 months post external-audit completion**. This trigger only applies in the post-audit world — Stage 3 cap-lift has happened but TVL did not follow. If audit never lands (§8.1 Option D), this trigger never fires; V1 simply stays at the pre-audit 100K cap indefinitely.
- **Trigger B — Operating-runway exhaustion:** founder operating-side runway drops below 6 months of forward burn. Under the §4.3.1 minimal-operations policy (~$80–$200/year, absorbed from personal income), this trigger is **structurally unreachable** for years; it is preserved as a formal trigger only so the framework cannot be silently broken by a future operator decision to inflate operating costs.
- **Trigger C — Class A override persistent:** any §1.5 Class A override condition (Liqwid / USDCx / Cardano chain halt / oracle anomaly) persists beyond the remediation horizon — typically operationalised as 30+ days for sustained-incident triggers, immediate for chain-halt or USDCx insolvency. The sunset protocol then absorbs the external-infrastructure failure into a controlled exit rather than passive degradation.
- **Trigger D — Explicit founder sunset decision:** founder explicitly invokes the sunset protocol under §9.2 (e.g., medical incapacity beyond the medium-term incapacity fallback in §9.2, personal-life force majeure, decision to discontinue maintenance).

**Audit-funding failure is NOT a sunset trigger.** Sustained audit-funding gap (§8.1 Option D) keeps V1 in pre-audit Phase 2 on mainnet at the 100K cap; it does not invoke the sunset protocol. The sunset protocol below applies to the four triggers A–D above:

1. **90-day depositor notice** (up from an earlier 30-day draft — extended to match DeFi migration realities). Notice published on-chain via `governance.QueuedAction` + off-chain via website banner + Discord + all existing user channels.
2. **Preconditions before the notice period starts** (all three must be complete before the 90-day clock starts):
   - All Liqwid qToken positions fully recalled to USDCx
   - All in-flight Minswap V2 orders canceled or expired
   - Governance-queued `UpdateFee` action taking `performance_fee_bps → 0` (the "fee-to-zero commitment during sunset")
3. **During the 90-day window:** no new deposits (frontend gates + keeper refuses BatchProcess deposit orders), withdraws fully open, 0% performance fee, keeper continues to post zero-yield Compound heartbeats to keep the 7-day inactivity guard valid.
4. **After 90 days:** remaining deposits < dust threshold can be consolidated via governance `EmergencyWithdraw`; ref-script capital is reclaimed via `deploy/tools/reclaim-refs.ts` (to be published with V1 implementation).

**Minimum operating-capital reserve at sunset trigger.** When the sunset protocol triggers, the founding entity commits to retaining at least **~150 ADA** (approximately $75-100 USD at prevailing ADA prices) earmarked from founding capital to cover the on-chain fees required for the 90-day settlement window: (a) 90-day keeper operations cycle (zero-yield heartbeat every 5 days + Saturday-scheduled Compound + Liqwid market monitoring) ≈ 60-80 ADA; (b) 1× Liqwid full recall across 3 markets ≈ 6 ADA; (c) Minswap V2 router gas for stables → USDCx conversion ≈ 6 ADA; (d) Conway-era ref-script fee surcharge (~1.2 ADA × 40 TX) ≈ 48 ADA; (e) 20% safety buffer. This 150-ADA reserve, combined with the fee-to-zero commitment, forms the operational guarantee during sunset — even if primary founding capital is exhausted (which is itself one of the sunset triggers), the 90-day settlement window still has independent funding, so depositors do not face the scenario of "withdrawal TXs failing because the operator ran out of ADA."

The 90-day notice + fee-to-zero + pre-clean preconditions is a strong depositor commitment — it gives any holder ≥ 3 months to exit without paying a performance fee and guarantees the vault state is already withdraw-ready before the clock starts. This is deliberately more generous than a naive 30-day notice would be: V1 is a pre-audit product, and migration friction for user deposits during sunset is the dominant loss we want to minimize.

See `docs/economics.md` for detailed math and TVL-tier projections.

### 4.2 Treasury model

Treasury accumulates 60% of performance fees in **USDCx** at V1 launch (3-way fee split: keeper 40% / gov pool 0% disabled / treasury 60% — see §2.4 for the phase activation table). Category allocation at launch:

- **Audit reserve: 40% of inflow** — funds future audits + future security researcher programs (V1 launches with a Responsible Disclosure Policy + ex gratia recognition framework rather than a structured bounty — see `docs/audit-scope.md §6` and §6.3 for preconditions under which a structured bounty would be introduced). Audit allocation was raised from the historical 30% to maintain audit-reserve accumulation at 24% of total fee under the smaller 60% treasury share (60% × 40% = 24%, identical to the prior 80% × 30%). Governance-hard-floored by two independent mechanisms:
  - **Inflow-ratio floor**: `audit_bps ≥ 2000` (20% of every Compound's fee inflow) — enforced by `treasury.ak` on `UpdateParams`; governance cannot set the audit inflow ratio below 20%.
  - **Balance floor**: `audit_reserve_balance ≥ min_audit_reserve` — `min_audit_reserve` is an **immutable** datum field set at deploy (V1 launch value: 0, i.e., non-binding at start). Once a future `UpdateParams` raises the floor, it cannot be lowered. No governance action can spend below the current `min_audit_reserve`.
- **Operations: 25%** — platform-layer infrastructure (frontend / landing / API hosting, Blockfrost platform queries, monitoring, domains, CDN). Per-keeper infra (individual keeper infrastructure, Blockfrost key, monitoring) is funded directly via the 40% keeper share at every Compound, not from this bucket — that's the structural reason ops shrank from the prior 40% to 25%.
- **R&D: 25%** — V2+ development, new integrations, contributor bounties (post-audit + TVL-scale).
- **Buffer: 10%** — discretionary reserve for emergencies.

The 40 / 25 / 25 / 10 launch split is **soft per-category** — governance can adjust the inflow ratios via `UpdateTreasuryParams` (14-day timelock + 180-day cooldown, each category bounded at [audit floor 20%, hard ceiling 50%]). Outflows happen per-category through `TreasurySpend` (7-day timelock), subject to monthly per-category cap + 24-hour per-category cooldown.

The only category with a hard floor is audit reserve (20% inflow + immutable balance floor). Operations / R&D / Buffer have inflow bounds [0%, 50%] but no balance floor.

**USDCx → USD off-ramp.** Operational costs (infrastructure, Blockfrost subscriptions, domain renewals, contractor invoices) are invoiced in USD or EUR. Treasury USDCx is converted as needed via: (a) Circle USDC redemption through an institutional account, (b) CEX off-ramp via Minswap-to-Wrapped-USDC-to-Coinbase/Kraken bridge path, or (c) the founding entity fronting USD against later USDCx reimbursement. All three paths carry KYC / minimum amounts / timing friction; the founding entity's treasury-operations runbook documents current procedure. Category accounting remains USDCx-denominated; USD conversion rate applied at time of spend is logged in the treasury-operations ledger.

Treasury spending requires a governance `TreasurySpend` action with 7-day timelock.

### 4.3 Keeper economics

At V1 launch, the founder operates the keeper. Other operators are not economically viable at 100K TVL:
- Keeper share at 100K = ~$108/year (at 6% reference APY × 4.5% × 40% keeper share; see `docs/economics.md` §2).
- Keeper infrastructure + monitoring = $400-1000/year.
- **Net loss: $292-892/year** for a non-founder keeper.

**At the realistic Phase 1 TVL range** (**$500-$25K** over the first 6-12 months per §8.2, not the 100K cap), the keeper-share math is even more lopsided — annualised keeper share is effectively **under $30/year**. The Phase 1 founder-keeper arrangement is therefore **a volunteer-operator design choice subsidised from founder personal income, not a commercial equilibrium**. Phase 1 keeper operation is an explicit cost centre funded ~$30–$75/year from the founder's ongoing §4.3.1 minimal-operations subsidy; it is not framed as self-sustaining at launch TVL, and it does not deplete a pre-committed founding-capital reserve.

**Path to opening keeper registration:** at ~$2.5-5M TVL under pessimistic 1-2% APY, keeper share becomes $600-1200/year, approaching break-even for a low-cost operator. V1's `keeper_stake_script` already supports `PermissionlessWithBond` mode but it is **disabled at launch** (`RegistrationMode = GovernanceOnly`). Activation requires a governance `UpdateKeeperAuth` action and, honestly, TVL growth that makes it economically rational — a Phase 3+ event, not a Phase 1 / Phase 2 concern.

**Three-tier self-sustain thresholds — an honest breakdown.** V1 has three distinct self-sustainability thresholds, not a single number, and they differ by an order of magnitude depending on APY assumptions. Keeper share per year = `TVL × gross_APY × 0.018` (40% of 4.5% performance fee at V1 launch).

| Tier | What it covers | Annual cost | Breakeven TVL (6% current APY) | Breakeven TVL (2% pessimistic APY) |
|------|---------------|------------:|------------------------------:|------------------------------------:|
| (a) Founder-keeper marginal ops | Bootstrapping only; founder absorbs own labor and shares existing infra | $100–$300 | $93K – $278K | $278K – $833K |
| (b) Non-founder professional keeper | Independent operator, dedicated server + monitoring | $400–$800 | $370K – $740K | $1.11M – $2.22M |
| (c) Institutional-grade ops + audit-reserve accrual | Full protocol self-sustain including future audit-cost accrual ($30–50K every 18–24 months) | $1,500–$3,000 ops + amortised audit | $20M+ | $50M+ |

The "$2.5–5M" figure earlier in this section corresponds to tier (b) under **pessimistic 1–2% APY** assumptions (keeper share = TVL × APY × 0.018). Under current reference 6% APY conditions, tier (b) resolves at $370K–$740K. The conservative framing in the opening paragraphs is deliberate — V1 should remain resilient to compressed Liqwid rate environments, not just viable under current reference conditions. Note: tier (c)'s breakeven is **dominated by audit-reserve accrual** (audit needs $15-33K/yr amortised vs. $1.5-3K/yr ops), and the audit-reserve trajectory is unchanged under E2 (60% × 40% = 24% of total fee, identical to the prior 80% × 30%) — so tier (c) at $20M+ / $50M+ is the same number whether keeper share is 20% or 40%.

**Three dimensions of self-sustain — read before the table.** The tier (a)/(b)/(c) breakevens above are computed on "keeper share covers keeper ops cost." That is **one of three distinct self-sustain dimensions**:

- **(i) Keeper ops self-sustain** — keeper share (40% of 4.5% perf fee) ≥ keeper's own infra cost. **Tiers (a)/(b) above correspond to this dimension**. Keeper share was raised from the historical **25% cap** to 40% to bring the Phase 2+ non-founder-keeper breakeven down to **~$1M TVL** (from ~$1.5M at the prior 25% cap; math: 25%/40% = 0.625, $1.5M × 0.625 ≈ $0.94M ≈ $1M).
- **(ii) Treasury ops self-sustain** — the treasury 60% share covers basic ops ($360/yr) + R&D ($432/yr) + operational buffer. Tier (b) TVL ($740K–$1.48M) generates treasury inflow of ~$1,620–$3,240/yr, **still comfortably covering this second dimension** at the smaller treasury percentage because keeper share already absorbs per-keeper infra cost directly.
- **(iii) Audit-reserve self-funding** — the yearly audit-reserve allocation (40% of treasury inflow under E2's 40/25/25/10 sub-allocation = 24% of total fee, identical to the prior 80%×30% = 24% accumulation rate) accumulates enough to cover the next audit cost ($30–50K every 18–24 months). This dimension still requires **$20M+ TVL**, corresponding to tier (c). The shift from 20%→40% keeper does not change the audit-reserve trajectory.

So when reading the tier table: **tier (a)/(b) is "keeper breaks even," treasury ops is automatically comfortably covered at the same TVL, but audit-reserve accrual is NOT — audit funding comes from the §8.1 four-source stack, not from protocol revenue**. This is by design, not a gap.

**V1's actual self-sustain target is tier (a)/(b), not tier (c).** Tier (c) is explicitly covered by the §8.1 funding stack (grants + audit-firm public-goods rate + scope reduction via internal-audit history + capped founder gap-fill per §8.1 (d) — see §0.2 for the volunteer-builder framing of why the founder is not the audit underwriter), not by protocol-revenue accrual. This matches the non-commercial public-goods positioning — V1 does not need to scale to $20M+ TVL to be "fully self-sustaining." If Phase 1 + post-audit growth reaches tier (a)/(b) ($500K–$1M TVL) by 2027–2028, V1 has succeeded on its own terms. If growth stalls below tier (a), §9.2 sunset protocol engages.

See `spec/keeper-auth.md` for the RegistrationMode state machine.

### 4.3.1 Post-launch minimal-operations policy

V1 separates two sustainability questions that are commonly conflated:

1. **Audit funding** (one-time, external, ~$50–$150K) — solves "can V1 launch on mainnet?" — see §0.2 / §8.1; the founder is **not** the underwriter.
2. **Operating runway** (ongoing, founder-committed, ~$80–$200/year scaling with TVL) — solves "can V1 stay running?" once launched — sustainable indefinitely from founder personal income, decoupled from audit funding.

This section specifies the operating side. The launch side is in §8.1.

**Operating budget at launch and during Phase 1 (TVL $500–$25K under §2.6.1 Reference Implementation Mode):**

| Item | Configuration | Annual cost |
|------|---------------|-------------|
| Server (keeper) | Single small ARM instance — **no dual-instance HA at this TVL** | ~$50 |
| Blockfrost API | Free tier with 5-key rotation per §3.6 | $0 |
| Monitoring + alerting | Self-hosted Grafana / Discord webhook | $0 |
| Domain (`optivaults.app`) | Amortised | ~$10 |
| On-chain fees | ~12–24 TXs/year under §2.6.1 cadence × ~$1 each | ~$20 |
| **Total** | | **~$80/year** |

This is the **launch-state operating model**, not a temporary scarcity-mode setting we plan to outgrow. It is sustainable for **as long as it takes** to either (a) reach a TVL band that justifies fuller infrastructure, or (b) gracefully sunset under §9.2.

At ~$80/year operating commitment, the founder's ongoing burden is **easily absorbable from personal income**, not a runway-depletion concern. This makes the operating-side commitment credible even without a large founding-capital reserve, and **decouples the launch decision (audit-funding-gated per §0.2 / §8.1) from the post-launch sustainability decision (founder-committed, structurally durable)**.

**Cost scaling with TVL** (operator-discretion transitions, not contract-enforced):

| TVL band | Annual operating cost | Annual protocol revenue (6% gross × 4.5% perf fee) | Founder-absorbed shortfall |
|----------|-----------------------|---------------------------------------------------|----------------------------|
| $500–$2K (sub-scenario a) | ~$80 | $1–$5 | ~$75–$79/year |
| $2K–$25K (sub-scenario b) | ~$80–$100 | $5–$67 | ~$30–$75/year |
| $25K–$100K (sub-scenario c) | ~$200–$500 (Default cadence resumes) | $65–$270 | ~$0–$200/year |
| $100K+ (post-cap, post-audit) | ~$400–$1,200 (HA + paid monitoring) | $270+ | Progressively self-funding |

At every TVL band, the founder's per-year absorbed shortfall stays in the **low-three-figures USD range**, never requiring a large lump-sum commitment. This is what makes the minimal-operations model decouple cleanly from the audit-funding question.

**HA / dual-server upgrade threshold.** `docs/economics.md §4` lists dual-instance HA as the "minimum-viable" recommended configuration. V1's launch model intentionally **trades HA for minimum cost until TVL crosses approximately $50K** — at that point the absorbed shortfall justifies the second server for resilience. Pre-$50K TVL, a single-server outage means keeper goes offline; the 7-day keeper-inactivity contract fallback (§5.4.1) ensures depositor withdraw remains unblocked and `early_withdraw_fee` is waived during the outage. A single-server outage is therefore an acceptable trade for early Phase 1.

**What this enables:**

- V1 launches on mainnet at the pre-audit 100K cap from launch day without requiring founder runway to cover audit; external audit, when funded, lifts the cap toward Stage 2 / Stage 3 (§1.5) rather than gating launch itself
- Post-launch, V1 can operate at $500–$25K TVL **indefinitely** if community discovery is slow — and equally at the 100K cap indefinitely if audit funding never lands (§8.1 Option D)
- TVL growth is decoupled from operating sustainability — V1 is **not under time pressure to "grow or die"** — and audit funding is decoupled from continued mainnet operation
- The §4.1 / §9.2 sunset trigger is **not** driven by operating-runway exhaustion (structurally durable under this model) **nor** by audit-funding failure (which only holds the cap at 100K under §8.1 Option D, not the live status of the protocol) — sunset triggers are §1.5 Class A overrides (USDCx / Liqwid / Cardano chain / oracle incidents) or explicit founder sunset decision
- Founder commitment is bounded and known: ~$2K seed + ~$80–$200/year operating subsidy + ~$15K audit gap-fill cap. Total founder financial exposure to V1 is **a low-five-figures USD upper bound** across the full pre-audit + launch + indefinite-100K-cap window — orders of magnitude below the audit base price, and consistent with the public-goods volunteer-builder framing in §0.2.

### 4.4 Honest Comparison

The right benchmark for V1 is **not** direct Liqwid USDCx supply (0.5–2% APY, thin borrow demand, rarely used by experienced Cardano DeFi users). The correct benchmark is **direct Liqwid DJED supply**, which is what a sophisticated user would do if they did the work manually.

**Reference Liqwid supply APYs as of 2026-04-21** (snapshot; rates float with borrow demand, re-checked at each rebalance): DJED ~11.8%, USDM ~5.3%, USDCx ~0.5–2%.

#### V1 yield decomposition

We present V1's yield mechanics with explicit separation of structural drag from fee impact. Numbers below use 2026 Q2 reference rates.

| Component | Annual Contribution |
|-----------|---------------------|
| 45% DJED Liqwid (11.84%) + 25% USDM Liqwid (5.33%) + 30% USDCx idle buffer (0%) | 5.33% + 1.33% + 0% = 6.66% gross |
| Idle buffer drag relative to "buffer also supplied to Liqwid USDCx at 1.5%" | 30% × 1.5% = -0.45% (45 bps foregone vs deployed-to-Liqwid-USDCx alternative) |
| Performance fee: 4.5% × 6.66% gross | -0.30% |
| **Net APY to user** | **6.36%** |

Note: the 6.66% gross figure already accounts for the 30% buffer earning 0%. The 45 bps "buffer drag" line measures the cost of NOT supplying that buffer to Liqwid's USDCx market (1.5% APY as of 2026 Q2), it does NOT subtract from the 6.66% — it is the policy choice's cost vs the alternative (deploy buffer to Liqwid USDCx). The policy is conscious: the buffer provides instant withdrawal capacity and emergency liquidity in conditions where Liqwid utilization spikes.

#### Comparison: V1 vs direct Liqwid DJED supply

A user with sufficient capital and operational capacity can replicate higher yield by directly supplying to a single Liqwid market. The most aggressive single-market option is DJED:

| Parameter | V1 (passive) | Direct Liqwid DJED |
|-----------|--------------|---------------------|
| Net APY | 6.36% | 11.80% |
| Annualised gap | – | -544 bps |
| Required user effort | None | Active monitoring + manual compound |
| Concentration risk | Diversified across 3 stablecoins + 30% buffer | 100% DJED, 100% Liqwid |
| ADA correlation exposure | ~45% (DJED collateral) | ~100% (DJED collateral) |
| Withdrawal liquidity | Buffer-backed instant + queue path | Subject to Liqwid utilization |

The gap is real. Anyone with enough DeFi experience to safely manage their own DJED position manually will earn nearly double what V1 delivers net-of-fee. **V1 is not trying to beat that strategy on pure yield.** If that is you, direct Liqwid DJED supply is the right product.

#### What V1's 544 bps gap buys

1. **Operational burden reduction.** Single-TX entry (no manual swap + supply chain), single-TX exit via vUSDCx burn (no Liqwid recall + Minswap swap-back chain per withdraw), automatic cross-market allocation whenever governance shifts the strategy (no manual rebalance TX), and depeg-response freeze runs at the contract layer (no manual oracle-watching required). Note that Liqwid qToken redeemability across pool-shard migrations is handled by Liqwid itself for both V1 and direct users — V1 does not uniquely save you from that concern.
2. **Dual-issuer allocation.** The launch 45% DJED + 25% USDM split spreads exposure across two distinct stablecoin issuers (COTI for DJED, Mehen for USDM). This protects against **issuer-specific** failure modes (Mehen insolvency, COTI DJED reserve depletion) — it does **not** protect against ADA flash-crash scenarios that stress both simultaneously (§5.2 covers this explicitly). A manual user can replicate the allocation themselves, at the cost of managing two Liqwid positions in parallel.
3. **Withdraw liveness.** The 30% USDCx idle buffer (0% yield by design — see §2.3) lets most withdrawals settle in one transaction without waiting for a Liqwid Recall round-trip. Manual DJED supply has no such buffer — a Recall from Liqwid DJED takes a full TX and is subject to the market's current underlying-available balance.
4. **Self-serve exit guarantees.** Principal is recoverable via `emergency-withdraw` even if the keeper is offline for 7+ days (§5.4). A manually-constructed position has no equivalent if the user loses access to the tooling they originally used.
5. **Multi-stablecoin depeg monitor.** V1's keeper halts new Deploy on sustained depeg signals (§5.2). A manual position requires the user to build their own monitor.

#### Break-even analysis — see §1.3.1 for the canonical table

The break-even between V1 and Direct Liqwid is the two-component framework introduced in §1.3.1 (time cost + risk-management outsourcing). **That table is the canonical reference; v1.3 consolidates both sections to use the same numbers** rather than presenting two parallel break-even calculations that drift. This section covers the math and rationale behind the components but does not re-print the table — read §1.3.1's table for the numbers.

**Component A: Pure time-cost break-even.** Approximating user time cost as 15 hours/year × hourly rate, divided by the 544 bps yield gap:

```
break_even_deposit_A = (annual_hours_required × hourly_rate) / yield_gap_bps
                     ≈ (15 × $20) / 5.44%
                     ≈ $5,500
```

By this calculation alone, users with deposits above ~$5K and 15 hours/year available for manual management would outperform V1 net-of-time-cost. **But Component A alone is not the right framing for most depositors** — it under-prices what V1 delivers beyond yield (Component B below).

**Component B: Risk-management outsourcing premium.** V1 covers operational and risk-handling work that Direct Liqwid users must build themselves or accept un-mitigated:

- **Diversification value**: holding 100% DJED carries concentration risk that V1's 45/25/30 split avoids. A user who values 30% allocation reduction in a flash-crash scenario at, say, 1–2% of deposit/year is paying that as part of V1's fee.
- **Auto-compounding NAV math**: Direct Liqwid users who do not manually compound lose ~30–50 bps/year vs theoretical-perfect compounding. V1 does it automatically.
- **Depeg response infrastructure**: V1's contract-level freeze + keeper depeg monitoring + emergency-withdraw self-serve path. A Direct Liqwid user must build their own monitoring + response plan.
- **Operational error avoidance**: failed Recall, batcher delays, swap routing, pool-shard migration — V1's keeper handles these. Direct user must learn + handle.

A reasonable estimate for the Component B premium is 200–300 bps/year for deposits at $5K–$50K, declining to ~100–150 bps as user sophistication scales with deposit size (sophisticated $1M holders typically already have these workflows). The §1.3.1 table converts this into a perceived-value column per user profile.

**Combined honest break-even**: practical break-even sits in the **$25K–$40K range** for most realistic user profiles — see [§1.3.1 break-even table](#131-what-depositors-actually-get-product-advantages) for the full per-profile numbers. Above ~$40K with relevant DeFi experience, Direct Liqwid DJED is genuinely the better choice.

#### When V1 is the right choice

V1 is structured to serve users for whom one or more of the following apply:

- Deposit size below ~$30K, where time + risk-management cost exceeds the yield gap × time value
- Concentration aversion: unwilling to hold 100% DJED due to ADA-correlation risk in flash-crash scenarios
- Operational unwillingness or inability to monitor Liqwid health, manage rebalancing, or respond to depeg events
- Preference for non-custodial passive exposure with auditable on-chain operations and explicit emergency protocols

#### When V1 is not the right choice

We recommend against V1 for users who:

- Hold deposits exceeding ~$40K and have time available for manual management
- Have strong conviction in a single stablecoin (typically DJED for highest yield) and are willing to bear concentration risk
- Require yield above 6% for the strategy to be economically meaningful
- Need fixed-rate exposure rather than variable-rate (a future product, see §1.7, will address this)

We do not artificially inflate the V1 value proposition. The 544 bps gap to direct DJED supply is real; for users who can capture it themselves, they should.

#### Future product positioning (forward reference)

The fixed-rate vault product described in §1.7 (V1.5) addresses a market segment unserved by either V1 or direct Liqwid supply: users requiring predictable, term-locked returns suitable for institutional treasury planning. V1 and the fixed-rate vault are complementary, not competitive.

#### Economic honesty at 100K TVL

At the pre-audit cap, V1's own revenue (~$270/year perf fee assuming 6% gross on 100K) does not cover operating costs (~$360–2,400/year, economics.md §4). The bootstrapping shortfall is absorbed by founding capital — **not** passed through to depositors as a higher fee. Depositors pay 4.5% regardless of how small V1 is when they deposit. As TVL grows toward the **$135K–$1.8M self-sustaining range (baseline ~$500K, see §4.1)**, the same 4.5% covers real operating costs + treasury accumulation.

If governance later activates a yield-bearing home for the USDCx buffer (see §2.3), the 0% buffer term lifts and the blended gross rises — e.g., a 30% × 1.5% buffer-side yield adds ~45 bps to gross. This would be disclosed publicly before the `UpdateStrategy` TX queues, narrowing but not closing the gap vs direct DJED supply.

Reference `docs/economics.md` §4 (operating cost), §6.2 (net-APY scenarios), §6.3 (depositor alternatives table), §9 (fee-leakage decomposition).

### 4.5 Compound cadence + per-cycle network cost

> **Scope note.** This section describes per-cycle network cost under §2.6 Default cadence at the 100K-cap reference point. **For Phase 1 sub-scenario operating costs ($500–$25K TVL under §2.6.1 Reference Implementation Mode), see §4.3.1's cost-scaling table** — that is the volunteer-operator launch budget. This §4.5 covers the post-cap-lift Default-cadence cost profile.

Compound frequency in §2.6 is a **ceiling, not a target**. The keeper runs Compound only when accrued yield × remaining-settlement-window justifies the on-chain fee outlay; otherwise it waits. The zero-yield heartbeat (every 5 days) still fires to advance `last_realloc_time` even when yield is economically insignificant.

Internal-verification operations established a TVL-adaptive cadence that V1 inherits as operational policy (not contract-enforced). The tiers are expressed in vault **total_deposited** (USDCx equivalent), carried over from the sub-$1,000 early-testing window when cadence had to be rate-limited to keep per-cycle network fee a reasonable fraction of yield:

| total_deposited tier | Productive Compound frequency | Zero-yield heartbeat |
|----------------------|-------------------------------|----------------------|
| < 300 USDCx | deferred until accrued yield > $1 | every 30 days |
| 300–750 USDCx | monthly | every 5 days |
| 750–1,200 USDCx | biweekly | every 5 days |
| 1,200+ USDCx | weekly | every 5 days |

**V1 at the pre-audit 100K USDCx cap sits in the weekly tier under §2.6 Default cadence, with Compound anchored on Saturday** — the sub-$1,200 tiers above are the keeper's live policy for any period the vault spends under that threshold (notably the Phase 1 small-TVL window per §8.2 sub-scenarios (a)–(b), and the §2.6.1 Reference Implementation Mode which applies whenever total_deposited < $25K). V1 launch-day expectations at the 100K cap: **one scheduled Compound every Saturday** + a zero-yield heartbeat every 5 days. If launch TVL begins below $25K, expect the lower-tier cadences in the table above instead until threshold crossings move the vault into the next tier (see §2.6.1 mode transition mechanics).

At the 100K TVL scale this cadence cuts roughly 85% of the naive "every 3 days" network-fee outlay. The contract validator accepts any Compound TX that satisfies validity-range + cooldown invariants (`spec/vault-datum.md` §3 items 6 and 11) — the keeper chooses when to submit.

**Per-Compound on-chain cost** (order of magnitude on Cardano mainnet, Conway era with reference scripts):

| TX type | Cardano fee | Who pays |
|---------|-------------|----------|
| Scheduled Compound (buffer-funded) | 1.5-2.5 ADA | Keeper (from keeper_fee share) |
| BatchProcess (N orders per TX) | 2-3 ADA amortized across N users | Keeper (from keeper_fee share) |
| VaultSwap (Minswap V2 routed) | 2 ADA network + 2 ADA DEX order fee | Keeper (from keeper_fee share) |
| SupplyToLiqwid / RecallFromLiqwid | 1.5-2 ADA | Keeper |
| MergeUtxo (consolidation) | 0.5-1 ADA | Keeper |

At 100K TVL on the weekly tier (~52 Compounds/year + ~12 heartbeats + ~20 rebalance/supply cycles), keeper on-chain cost is approximately **$50-80/year** (ADA denominated, paid by the keeper wallet).

**Vault ADA replenishment — the `SwapAda` closed loop.** Every `DeployToProtocol` (VaultSwap) TX costs the vault ~2 ADA net to Minswap V2 batcher fees; without replenishment the vault would drain to its `min_vault_ada` floor and block further Deploy TXs. V1 closes this loop on-chain via the `SwapAda` redeemer (spec: `spec/ada-swap.md`): when `vault.lovelace < 15 ADA`, the keeper invokes `SwapAda` giving the vault 10–50 ADA and receiving equivalent USDCx at the Charli3 + Orcfax oracle rate. Validator-enforced: 1h cooldown, 1h validity-range width cap, fair oracle-priced atomic barter — no trust premise beyond the oracle feed the system already depends on for depeg monitoring. Depositors bear Minswap batcher fees as a slow USDCx drain — at 100K TVL with ~1 SwapAda per 2–4 weeks (20–40 ADA per call ≈ 10–20 USDCx), this haircut is ~0.02% APY drag, negligible against 4–6% gross yield.

Keeper side: the keeper receives its 40% fee share in **USDCx** and may periodically convert USDCx → ADA on Minswap for the Cardano network fees on its own wallet; that conversion costs ~60 bps per swap (quarterly → ~2.4 bps/year of keeper share friction, negligible at 100K TVL but grows linearly with keeper share). Structurally absorbable by the 40% keeper share ($108/year at 6% gross at 100K TVL) only when the keeper amortises other sunk costs (founder operating model), or once TVL crosses ~$1M (where the 40% share alone covers a low-end non-founder keeper standalone-ops budget). The 40% cap (set at validator hard cap) was chosen specifically to bring this third-party-keeper viability point down to ~$1M TVL — see §4.3 for the full breakeven matrix.

#### 4.5.1 Per-depositor on-chain fees (Direct vs Queue, side-by-side)

What a user actually pays in ADA when they operate themselves:

| Operation | TX pattern | User pays (ADA) | Settlement time | Notes |
|-----------|-----------|------------------|------------------|-------|
| **Direct Deposit** | Single TX, wallet-signed directly into vault | **~0.5 ADA** network fee | Immediate (on TX confirm) | Touches the vault UTXO directly; during busy periods may need a retry if another TX claims the vault UTXO first. |
| **Queue Deposit** | Order UTXO → keeper BatchProcess | **~0.5 ADA network + `max_batcher_tip`** | Typically < 1 hour (keeper runs a batcher cycle every 5–15 min; operational target, not contract-enforced SLA) | User sets `max_batcher_tip` at order creation (suggested 0.1–0.5 ADA); keeper collects up to this ceiling when processing. Funds sit in the Order UTXO — cancellable by owner any block (`Cancel`), or auto-refunded after 24h (`Expire`). **`max_batcher_tip` is distinct from Minswap V2's own batcher fee** — that one is absorbed by the vault on VaultSwap, not paid by the depositor. |
| **Direct Withdraw** | Single TX, wallet-signed, spends vault UTXO directly | **~1–1.5 ADA** network fee | Immediate | More expensive than Direct Deposit because it spends the vault UTXO through the proxy, triggering Withdraw-Zero forwarding = one proxy invocation + one staking validator invocation (§3.2). |
| **Queue Withdraw** | Order UTXO → keeper BatchProcess | **~1 ADA network + `max_batcher_tip`** | Typically < 1 hour | Batched alongside other orders; useful when the vault UTXO is contested. Shares sit in the Order UTXO — same `Cancel`/`Expire` safety net as Queue Deposit. |
| **Emergency Withdraw** | User builds + signs TX via CLI or web tool | **~1.5–2 ADA** network fee | Immediate | Available after 7+ days of keeper inactivity; early-withdraw fee waived automatically. This path requires zero operator cooperation. |

**Which one should a depositor pick?**

- **Small position (< $500)**: Direct Deposit + Direct Withdraw is simplest, friction splits cleanly.
- **Medium position ($500–$2,500)**: Queue orders batch nicely when the vault is busy; set `max_batcher_tip` in the 0.2–0.5 ADA range so the keeper prioritizes your order.
- **Large position (≥ 5% of current TVL)**: Prefer Direct paths. At the 100K TVL cap, a single $5K+ order batched with other large orders will experience the pre-batch pricing drift described in `spec/order-batch.md` §5.

**Concrete sizing example:** a user depositing $100 USDCx pays ~0.5 ADA (~$0.25) in network fees — about 0.25% of principal. This is real entry friction at very small sizes, but it's not a protocol fee (V1 charges 0% at the protocol level for deposits); it's the fixed Cardano network cost that every on-chain operation requires.

---

## 5. Risk Framework

### 5.1 Smart contract risk

V1 launches with:
- A multi-round internal audit inherited from the internal-verification-phase validator base. An "internal audit round" is a discrete adversarial read of every validator against a specific threat model, producing a written report with findings categorized CRITICAL / HIGH / MEDIUM / LOW / INFO. Each round ends only when every non-INFO finding is resolved in code and a regression test is added. See `docs/audit-scope.md` §2 for the round-level methodology.
- Additional internal audit coverage on V1-specific new scope (treasury, keeper_stake_script, integration flows, deploy pipeline, off-chain runtime). Coverage is organized by area (A–F), not by sequential round number; see `docs/audit-scope.md` §4.
- **Pending third-party audit** (target Q2-Q3 2027 — see §8.1 funding-stack disclosure) gating TVL cap removal.

**Example of the iterative-fix methodology — the A2 design-gap closure.** Internal audit surfaced that every V1 staking validator originally shipped with `withdraw(...)` + `else(_) { fail }` catch-all. Cardano's ledger validates stake-credential `Deregister` certificates under the Publish purpose, which hits the `else` branch → deregister always rejects → the 2 ADA Cardano stake-registration deposit posted at ceremony PHASE 4a is permanently locked per staking validator. The fix ("A2") added a gov-gated `publish` handler using the already-in-use `is_gov_authorized(ActDeregisterStake, payload_hash_deregister_stake(own_hash))` helper. Coverage now extends across **all 14 V1 staking credentials** (canonical list in §6.2 `ActDeregisterStake`). The validator partitioning that gave each credential the bytecode headroom for its `publish` handler is documented in `spec/architecture.md §4.1`. Design decisions recorded in `spec/governance.md` §4.13 + `spec/keeper-auth.md` §9. This iteration demonstrates the V1 development mode: surface → spec → fix → regression test → ship → document. Depositors can verify the A2 fix on-chain once the Preprod ceremony's ActDeregisterStake flow completes execution.

**Reader framing.** Internal audit is prerequisite effort, not a substitute for a third-party audit. The primary security signal for V1 is the upcoming external audit report — internal rounds reduce the probability that the external auditor finds CRITICAL issues but do not eliminate it. The 100K USDCx TVL cap is an explicit acknowledgment that V1 is pre-external-audit software.

Until external audit: **100K USDCx TVL cap, operator-enforced**. No promises beyond this.

#### 5.1.1 Adversarial chain-replay coverage

Internal audit's static-read methodology is complemented by an adversarial chain-replay surface: hand-crafted attack transactions are submitted to a Preprod ceremony build against live validators, and the contract's rejection (or acceptance) is recorded as on-chain evidence. This converts theoretical defense layers (identified during audit rounds) into observable rejection patterns indexed by transaction hash.

The coverage below describes the categories of defense layer exercised; it is **not** a quantitative claim that every conceivable attack has been tested. External audit remains the primary security signal — chain replay complements unit + property-based tests by adding an end-to-end "build attack TX → ledger says no" trace.

**Defense-layer categories exercised on Preprod**

- **Vault primary spend (`vault_proxy.ak`)** — `withdrawal_count == 1` (single staking-validator dispatch per vault primary spend), `no_foreign_vault_datum` (rejects InlineDatum-shaped `VaultDatum` at non-proxy script addresses), `is_full_drain` NFT-burn requirement, `vault_count ∈ [2, 5]` NoDatum-secondary bound, `all_secondary_no_datum` MergeUtxo gate.

- **User-path redeemers (`vault_user.ak`)** — `Deposit` mint-equality (`vUSDCx mint == expected_shares`), `Deposit` `min_deposit` floor, `Withdraw` burn-equality (`vUSDCx burn == -shares`), `verify_receiver_output` strict pkh equality (receiver field bound to actual output recipient), `verify_receiver_output` Script-credential rejection (receiver must be a verification-key wallet, not a locked script), `CommunitySunset` 90-day time threshold.

- **Keeper-path redeemers (`vault_keeper_hot.ak`, `vault_swap_ada.ak`)** — validity-range width cap on every time-writing redeemer (`upper - now ≤ 1 hour`), `vault_swap_ada` amount-in-range bounds (10–50 ADA per swap), `ada_below_threshold` replenishment gate.

- **Protocol-routing redeemers (`vault_protocol.ak`)** — `DeployToProtocol` destination whitelist (`registry.protocol_hashes`), SwapAdapter recipient binding (caller-layer + adapter-layer agreement on `expected_recipient_addr`), Tier 2 peg-floor on adapter-committed `min_receive` (`min_receive × 10_000 ≥ deploy_amount × min_swap_peg_bps`), `min_order_amount` lower bound for non-deposit swap-out.

- **Mint policies (`vusdcx.ak`, `vault_nft.ak`)** — `vUSDCx` single-asset-name discipline (rejects multi-asset mint under the same policy), `vault_nft` PlutusV3 UTXO-ref one-shot (parameterized UTXO must appear in `tx.inputs` for mint; structurally one-shot after consumption).

- **Order branch (`order.ak`)** — `signed_by_owner` strict signer authentication on `CancelAction`, `valid_refund` recipient pinning on `ExpireOrder` (refund must go to original `ord.owner`).

- **Multisig governance (`multisig_gov.ak`)** — `valid_signer_set` rotation floor (`n ≥ 3 signers`), `time_window_ok` `lower_bound ≥ executable_at_ms` (no early ExecuteAction before timelock elapses), `payload_hash` binding (apply-side payload must hash to a value matching a queued action — RotateSigners + UpdateFee + UpdateRegistry + TreasurySpend all enforce the same pattern), `expected_payload_hash` re-computation in `is_gov_authorized` (cross-validator helper).

- **Emergency / fee governance (`vault_gov_emergency.ak`, `vault_gov_policy.ak`)** — `validate_emergency_freeze_only` (`loss_amount == 0` invariant — EmergencyWithdraw can ONLY toggle the `frozen` flag, never reduce `total_deposited`), `max_performance_fee_bps` (450 bps cap on `UpdateFee` even with full gov authorization), payload-binding sister-layer to `multisig_gov` (Treasury Spend / UpdateFee / RotateSigners all share the same `is_gov_authorized` helper).

- **CIP-69 purpose isolation** — every PlutusV3 validator declares its handled purposes (e.g., staking validator declares `withdraw` + `publish`); `else(_) { fail "<validator>: unsupported purpose" }` catches any other purpose invocation including Spend / Mint / Vote / Propose. A planted UTXO at `payment_credential = <staking script hash>` is permanently locked because no Spend handler exists for that script.

- **Share-price invariant (`total_deposited` / `total_shares`)** — every mutation path is constrained: Deposit + Withdraw use `calculate_shares_to_mint` / `calculate_withdraw_amount` exact equality; Compound moves `total_deposited` only (yield → share-price up by design); BatchProcess uses per-order fair-share rounding; eight other redeemers preserve `total_deposited == old.total_deposited && total_shares == old.total_shares` via `verify_protocol_fields_preserved` / `verify_liqwid_invariants` / `verify_emergency_freeze_only` / `verify_datum_unchanged`. Source review covers every path; no manufacturable break of the ratio outside intentional design (Compound yield, deferred-yield withdraw fee).

**Outcome**: each chain-replay category above produced an observable rejection on Preprod (Ogmios `evaluate` or `tx/submit` returning a structured script-error trace at the validator + purpose level), preserved in regression scripts under `tests/preprod/`. **No exploitable attack was found that the contract did not already reject.** This is consistent with the iterative methodology — most surfaces are exercised both by unit tests and property tests well before chain replay — but the on-chain evidence is a third independent confirmation.

**One category was deferred to a fresh Preprod ceremony**: a `UpdateRegistry`-injected fake Liqwid `action_addr_hash`, then a Supply attempt routed to that fake address. The defense (`qtoken_delta > 0` invariant at `vault_liqwid.SupplyToLiqwid` — a fake action validator cannot mint real qTokens under the immutable per-market qToken policy) is covered by Aiken unit tests in `lib/vault/tests/`; chain replay was deferred because the ceremony setup (queue UpdateRegistry → wait timelock → attempt Supply) is heavy relative to the marginal audit-narrative value beyond unit-test coverage.

**What chain replay does NOT cover**: external-system failure modes (Liqwid bad-debt, USDCx redemption freeze, oracle staleness — these are §5.3 / §5.2 / §5.4 risk surfaces, not contract defenses), keeper-key compromise scenarios that require simulating a malicious operator (covered by source review and the §5.4 keeper risk discussion), and behaviour beyond build-specific state (e.g., on a vault with full Liqwid allocation, certain partial-withdraw paths require Recall before they can fire — these are operational paths, not security defenses).

Regression scripts are part of the open-source release; auditors and integrators can re-run them against a fresh Preprod ceremony to reproduce the rejection traces independently. The methodology itself (build attack TX → submit → record contract reject as TX hash or eval-trace) is a reusable template for future V1.x and V2 audit rounds.

### 5.2 Stablecoin depeg risk (multi-asset)

V1 holds three stablecoins simultaneously: USDCx (deposit token), DJED (Liqwid allocation), USDM (Liqwid allocation). **This is dual-issuer allocation within a single-ecosystem exposure, not true risk diversification.** Each stablecoin carries its own depeg risk, and depositors bear the risk of whichever stablecoin the vault holds at the moment of a depeg event — not just USDCx.

**What the multi-stablecoin allocation DOES protect against** (issuer-specific failure modes, statistically near-independent):

- **Mehen insolvency / attestation failure** — USDM's fiat backing evaporates but DJED (ADA-collateralized) and USDCx (Circle-backed) are unaffected.
- **COTI DJED reserve depletion** — DJED's collateral ratio collapses but USDM (fiat) and USDCx (Circle) are unaffected.
- **Circle compliance event freezing USDC** — USDCx's redemption path breaks but DJED (ADA) and USDM (Mehen fiat) keep trading.

**What the multi-stablecoin allocation DOES NOT protect against** (correlated-failure modes, the more realistic stress scenarios on Cardano):

- **ADA flash crash.** DJED's collateral is ADA; a sharp ADA decline triggers DJED depeg. At the same time, Cardano DEX liquidity thins, so reverse swaps (DJED → USDCx, USDM → USDCx) execute at depeg-discount prices before the keeper's freeze trigger can fire. V1 treats the three stablecoins as independent in allocation targets but **does not assume statistical independence in failure modes**. An ADA flash crash is the most likely trigger for a correlated multi-stablecoin stress event.
- **Cardano-ecosystem systemic event** (chain halt, protocol-level exploit, regulatory action against Cardano stablecoin issuers as a class).
- **Black-swan simultaneous independent depeg** — all three failing at once without a common trigger. Tail scenario not priced into V1's design.

**V1 is probably a reasonable fit if** you are comfortable treating "Cardano stablecoin basket" as a single correlated exposure with diversification only against issuer-specific blowups. **V1 is likely not the right fit if** you are looking for the multi-asset allocation to protect against an ADA crash — it does not.

---

**USDCx** depends on Circle's operational integrity, xReserve bridge security, and the USDC redemption path. If USDCx depegs, V1's keeper halts deposits and depositors can withdraw (though withdrawn USDCx may itself be depegged).

**DJED** is Cardano's native overcollateralized algorithmic stablecoin, backed by ADA reserves. DJED has historically experienced depeg events during ADA price volatility when the reserve ratio compressed. When the vault is allocated to DJED at Compound time, share-price accounting reflects DJED's current market value — a DJED depeg translates to a proportional share-price decrease for all vUSDCx holders.

**USDM** is issued by Mehen with fiat backing. **The Liqwid USDM market has smaller total TVL than the Liqwid DJED market** (reflected in DJED's 11.84% APY vs USDM's 5.33% as of 2026-04-21, indicating stronger DJED borrow demand) — under a stress event with USDM market utilization at 100%, a large Recall would need to wait for borrower repayment. This is V1's **Liqwid-side pressure risk** on USDM positions. **On DEX swap depth, the picture is actually reversed**: Minswap V2's direct USDCx/USDM pool (~11.6M reserves per side as of 2026-04) is **deeper than any USDCx/DJED route** (no direct large pool; must hop via ADA 2-hop or NIGHT 3-hop), so reverse-swap (USDM → USDCx) at small-to-medium sizes incurs *less* impact than DJED → USDCx, not more. These two liquidity dimensions (Liqwid market TVL vs DEX pool depth) should not be conflated.

**What the depositor actually holds:** a claim on the vault's current asset mix, not a pure USDCx claim. If the vault is (hypothetically) 90% allocated to DJED and DJED depegs 20%, share price drops ~18% regardless of what happens to USDCx.

**V1 mitigations:**
- **Per-asset depeg monitoring** — keeper watches Cardano-native oracle feeds (Charli3 + Orcfax) and Minswap V2 TWAP for sustained (15 min) deviations > 1%. No cross-chain oracle bridges are used, consistent with §2.3's "no cross-chain bridges" commitment. Sustained depeg triggers `frozen = 1` via `EmergencyWithdraw` governance action and routes an operator alert.
- **Allocation caps** — `UpdateStrategy` maintains allocation bounds per stablecoin (current operational target: 45% DJED + 25% USDM + 30% USDCx buffer). Governance cannot set a single-market allocation above governance-policy limits without explicit `UpdateStrategy` action + 7-day timelock.
- **Liqwid market isolation via `KeeperToggleMarket`** — keeper can unilaterally disable new supply to a specific Liqwid market (one-way flag) without governance delay; used as the fast-response layer ahead of a full `frozen = 1` freeze.

**What V1 does not mitigate:**
- In-flight swap slippage during a rapid depeg. Reverse swaps (DJED → USDCx) may execute at depeg-discount prices before the freeze trigger fires.
- **Correlated depeg risk.** DJED's collateral is ADA; USDM's backing is fiat reserves; USDCx's backing is Circle USDC. These are nominally independent trust chains, but historical market stress events have shown Cardano-stablecoin depegs correlate: a sharp ADA decline triggers DJED depeg AND reduces DEX liquidity for USDM/USDCx exits simultaneously. V1 treats the three as independent in allocation targets but does not assume statistical independence in failure modes. An ADA flash crash is the most likely trigger for a correlated stress event.
- **Black-swan simultaneous multi-stablecoin depeg.** All three stablecoins fail independently is a tail scenario not priced into V1's design; the correlated case above is the more realistic multi-asset stress mode.
- Issuer-initiated redemption freezes (Circle compliance event, Mehen attestation failure). On-chain tokens remain transferable but may be unredeemable for USD.

**Flash-loan interaction with early-withdraw fee retention.** V1's early-withdraw fee (§2.4) accrues to remaining holders via share-price appreciation — i.e., the withdrawn user's fee stays inside the vault as buffer, lifting all remaining shares' claim. An attacker could theoretically flash-loan vUSDCx, immediately withdraw inside the `min_hold_seconds` window to pay the fee, and re-enter to claim the fee back — but: (a) flash-loaning vUSDCx requires an existing lending market for vUSDCx which does not exist at launch, (b) the fee accrues proportionally to all remaining shares including the attacker's re-entry, so the round-trip is net-zero ex post, and (c) the attacker still pays network TX fees + Minswap slippage for the flash cycle. No known profitable flash-loan attack exists on this design; V1 monitors for new vUSDCx lending markets and will revisit if one appears.

### 5.2.1 Cardano ecosystem evolution scenarios

V1's risk profile is not static. Several anticipated Cardano DeFi infrastructure milestones will materially shift V1's risk profile if they ship — sometimes reducing risk, sometimes introducing new risk surfaces. This subsection documents the conditional sensitivities depositors should be aware of, separately from V1's own design (§5.1–5.6). These are **not predictions or commitments** — they are explicit assumptions about external state that depositors deserve to see.

**Pogun BTC DeFi rollout (2026 Q2 lending → Q3 yield → Q4 BitVM bridge).** Pogun's introduction of Bitcoin-collateralized lending on Cardano, if it ships on schedule, would materially increase the borrow-side demand on Liqwid stablecoin markets — which has been structurally absent and is the underlying reason Liqwid stablecoin APYs are concentrated rather than diversified. Higher and more stable borrow demand would (a) lift V1's blended yield, (b) reduce the probability of Liqwid utilization spikes that block keeper Recall, and (c) eventually unlock V2.x BTC-collateralized yield routing (§1.7). **Risk:** Pogun is currently a publicly-announced roadmap from IO with mainnet timeline targets but no firm ship dates. If Pogun delays past 2027 Q2, V1 stays in the current single-protocol Liqwid posture indefinitely, and Axis A of the Launch Readiness Framework (§1.5) remains red.

**Leios scaling (testnet end-2026, mainnet 2027).** Cardano's Leios upgrade targets 10–65× transaction throughput improvement. For V1, Leios reduces (a) network fees per Compound / BatchProcess / Swap TX, (b) latency from order submission to batch fill, and (c) Minswap V2 batcher congestion during depeg events. Net effect: V1's operational cost base shrinks by an estimated 30–60% post-Leios, which lowers the §4.3 keeper break-even TVL accordingly. **Risk:** Leios is itself a major protocol upgrade with timeline uncertainty. If Leios delays past 2028, V1 keeper economics stay on the current cost curve, and the §4.3 self-sustain threshold pushes toward the upper end of the $740K–$1.48M tier (b) range.

**Midnight DeFi Kernel maturation (research-stage, production target 2028+).** Midnight's announced privacy-preserving DeFi infrastructure, when it matures, would unlock V3.0 institutional privacy vault (§1.7). For V1 itself, Midnight maturity is **not** a risk-changing factor — V1 is a Cardano-mainnet-public product and does not depend on Midnight in any way. Midnight is purely forward optionality for V3.0; V1's risk profile is unaffected by Midnight's trajectory either direction. **Risk:** Midnight DeFi Kernel is currently at research-paper level concept, not production code. The announced 2028+ timeline reflects substantial uncertainty; V3.0 evaluation does not begin until Midnight Kernel ships in production form. If Midnight does not mature, V1 + V1.5 + V2.x remain the protocol's product surface — V3.0 simply does not happen, and that is an acceptable outcome.

**USDCx subsidy expiry (post Q1 2026 IOG bridging fee subsidy).** The first months of USDCx availability on Cardano have been supported by an IOG-funded bridging fee subsidy that lowered the friction of moving USDC into and out of Cardano via xReserve. Once that subsidy expires (post Q1 2026), the natural cost of USDCx mint/burn re-emerges — a small but non-zero per-trip friction that may dampen organic USDCx supply growth on Cardano. For V1, this is monitored via Axis B of the Launch Readiness Framework (§1.5): if 30-day net USDCx outflow exceeds 10% post-subsidy, Axis B turns red and V1 launch is gated. **Risk:** If USDCx supply contracts post-subsidy (net outflow > 10% over 30 days), this is a material signal that organic Cardano USDCx demand is below threshold and V1's TAM thesis (§1.2) needs re-examination. Conversely, if supply continues to grow post-subsidy, Axis B confirmation is one of the strongest signals that V1's market positioning is structurally sound.

**NIGHT solar drop continued release schedule (450-day thawing period).** NIGHT token thawing schedule continues to release supply over a 450-day period from each holder's snapshot date. The relevance to V1 is indirect: the founder's Minswap V2 ADA/NIGHT LP exposure (§1.6) is part of the founder's personal portfolio, and continued NIGHT release affects ADA/NIGHT pool dynamics on Minswap V2 — which is the same DEX V1 uses for stablecoin routing. Pool depth changes on Minswap V2 (any pair, since the AMM shares liquidity-provider attention) marginally affect V1's swap impact estimates. This is a low-magnitude effect — Minswap V2 stablecoin pools are sized largely independently of NIGHT-related liquidity — but worth flagging for completeness because the founder's NIGHT/ADA LP is one of the bias sources documented in §1.6.

**What V1 does not assume.** The conditional sensitivities above are documented to inform depositors of how V1's risk profile will evolve as Cardano DeFi infrastructure matures, **not as predictions or commitments**. V1 is designed to operate within its current posture (single-protocol Liqwid wrapper, Cardano-mainnet-only, USDCx-denominated) regardless of which scenarios materialize. If Pogun delays, V1 keeps shipping with current yields. If Leios delays, V1 keeper economics stay where they are. If Midnight does not mature, V3.0 does not happen — V1 is unaffected. The Launch Readiness Framework (§1.5) is the formal mechanism by which external state changes feed into V1's TVL cap progression; this subsection makes the underlying assumptions and triggers explicit so depositors can independently track them.

### 5.3 Liqwid protocol risk

**The intentional-scope-boundary framing from §1.1 is also a risk vector here.** §1.1 explicitly positions V1 as "NOT a multi-protocol yield aggregator" — a deliberate product-scope choice, not an oversight. That same design choice becomes a depositor-facing risk when examined from the threat-model side: if the single protocol V1 routes to fails, V1 has no live alternative to switch to. This section is the honest risk-side reading of the §1.1 product-scope positioning — both descriptions are of the same fact, viewed from different angles.

**Single-protocol concentration risk (V1-specific).** All V1 yield comes from one protocol — Liqwid — not because we believe Liqwid dominates every competitor, but because Cardano's current stablecoin supply-side landscape has no second protocol clearing the combined bar of depth + audit maturity + Aiken integration feasibility. If Liqwid suffers a protocol-level failure (contract vulnerability, liquidation breakdown, governance attack), V1 **has no fallback protocol to migrate to quickly** — the response path is governance `EmergencyWithdraw` (freeze) + self-serve depositor exit. Mitigation: (a) Liqwid has itself been through multiple third-party audits and one+ year of mainnet operation; (b) any anomaly can trigger `EmergencyWithdraw` to freeze the vault, and the depositor-side `withdraw-cli` self-serve path **does not depend on Liqwid availability** — only on Cardano ledger uptime; (c) future V2+ evolution adding a second supply-side protocol (the §1.1 direction, gated on maturity per §1.6.3) will reduce this concentration. Until that V2+ evolution ships, depositors should treat Liqwid protocol risk as **V1's single largest on-chain risk source** — higher than governance risk, and higher than any individual stablecoin depeg risk.

V1's Liqwid exposure comes from supplying USDCx, DJED, and USDM to Liqwid's action validators and holding qToken receipts in the vault UTXO. This introduces several protocol-risk vectors:

- **Bad debt**: if Liqwid's own liquidation + reserve mechanics fail to cover under-collateralised loans, the qToken-to-underlying rate drops. The vault's supplied positions lose value proportionally, visible as a share-price decrease at the next Compound.
- **qToken rate miscalculation or manipulation**: V1 trusts Liqwid's on-chain rate model for the qToken ↔ underlying conversion. A compromised rate would mis-account vault position value.
- **Pool migration**: Liqwid occasionally migrates pool shards (new `action_addr_hash`). If the vault's keeper tries to Recall against a stale pool, Recall fails. V1 handles this via `FastUpdateMarkets` (1-hour governance timelock) to point at the new pool.
- **Action validator upgrade**: a Liqwid contract upgrade that changes the Supply/Recall interface could break keeper logic. Vault funds remain safe (the validator upgrade doesn't move user funds), but yield accrual stops until keeper code is updated.

V1 mitigations:

- **Share-price transparency** — losses surface on the next Compound, not hidden. Depositors can see them in vault accounting before the next allocation decision.
- **`EmergencyWithdraw`** — governance can freeze the vault for recovery planning (0-day timelock). Phase 1 governance safety constraint: this redeemer is **freeze-only** at the validator level — it cannot reduce `total_deposited` or modify `liqwid_positions`. Real loss accounting happens via `vault_liqwid.RecallFromLiqwid`'s gov-fallback path which physically Recalls underlying USDCx and writes off only the actually-realized shortfall (see §5.5.1 Layer 1 + `docs/security-model.md` §5.4).
- **`KeeperToggleMarket`** — keeper can unilaterally disable new Supply to a specific Liqwid market (one-way flag `active: True → False`) without governance delay. This is the fast-response layer when keeper sees anomalies but governance hasn't yet convened.
- **Per-market position isolation** — `LiqwidPosition { market_id, qtokens_held, supplied_value }` is tracked per Liqwid market independently, so contagion from one market's bad debt does not automatically write off the other markets.

### 5.4 Keeper risk

Keeper is a trust delegation bounded on-chain by:
- **Invariant checks** — `no_vusdcx_leak` (BatchProcess cannot route vUSDCx to anyone outside `order_owners ∪ proxy_hash`), `verify_other_tokens_preserved` (non-deposit tokens at vault cannot be extracted by keeper), `slippage_ok` (per-order; the keeper-built BatchProcess TX must honor each user's `min_shares` on deposit orders and `max_shares_burn` on withdraw orders — these are user-specified bounds, not a fixed percentage; the user controls their own acceptable deviation at order-creation time).
- **Keeper-side swap slippage policy (V1 current state, honest)** — for keeper-initiated DEX swaps through `DeployToProtocol` (USDCx ↔ DJED / USDM routing on Minswap V2 during rebalance), the keeper applies a 1.5% tolerance on `minReceive` and aborts routes with > 2% price impact. **This is operational policy in the keeper software, not contract-enforced at V1 launch.** A compromised keeper can theoretically submit a wider-slippage TX and the V1 contract will accept it — the vault's balance shrinks by the slippage delta and all vUSDCx holders' share-price drops proportionally. Per-order `min_shares` / `max_shares_burn` user-side bounds protect BatchProcess paths but do NOT cap keeper-initiated DEX swap loss on the vault balance. Theoretical upper bound on single-swap loss = maximum slippage that Minswap V2's current pool depth permits at the vault's swap size (low single-digit % at 100K TVL given current pool depths; pool depth is public). Current mitigations are operational: (a) `protocol_hashes` Registry whitelist keeps the counterparty to Minswap V2 itself so funds cannot be routed to a keeper-controlled script, (b) the founder-keeper bears personal reputation + sunk-cost risk, (c) on-chain TX history is public — a wide-slippage swap is immediately visible and triggers the 7-day early-fee-waived exit window.

    **V1.x pre-audit prerequisite — contract-enforced slippage bound** (commitment, not deferred). Shipping peg-floor + oracle-based slippage enforcement is on the critical path to external audit, not to post-audit iteration. The datum-level mechanism is:

    - Add `max_slippage_bps` + `min_swap_peg_bps` to `VaultDatum` under a new `UpdateSlippagePolicy` governance redeemer (48 h timelock for depeg-response agility, 1-of-n cancel preserved).
    - `DeployToProtocol` decodes the Minswap V2 route order datum, extracts `minReceive` and `amount_in`, and enforces `min_receive × 10_000 >= deploy_amount × min_swap_peg_bps` as the Tier 2 peg-floor bound (catches the `minReceive = 1` extreme-slippage class of attack without requiring oracle feeds). Multi-hop is transparent — the bound applies to the FINAL output.
    - Tier 1 (oracle-based fair-price `minReceive >= fair_out × (10_000 − max_slippage_bps) / 10_000`) activates per-asset as Charli3 + Orcfax dual-feed coverage reaches that asset via governance-`UpdateRegistry` population of a new `asset_oracles` list.
    - SwapAda (§3.4 + §4.5) upgrades from its single-Int MVP oracle to the same dual-feed reader, closing a known concern with the single-feed MVP design.

    Implementation timing: pre-external-audit, same deploy ceremony as the audit commit. The full P1–P5 slippage stack ships **on-chain**, not as an operational-policy layer; "V1 Pre-Launch Candidate" refers to this fully-enforced contract delta (subject to external audit).

    **Current status — by verification stage:**

    | Item | Code landed | Unit tested | Preprod E2E | External audit |
    |------|:-----------:|:-----------:|:-----------:|:--------------:|
    | P1 vault_admin split | ✓ | ✓ | ✓ | Q2-Q3 2027 |
    | P2 UpdateSlippagePolicy + datum fields | ✓ | ✓ | ✓ | Q2-Q3 2027 |
    | P3 Tier 1 dual-feed oracle | ✓ | ✓ | partial — registry validator deployed; `asset_oracles` empty at launch (governance populates post-mainnet) | Q2-Q3 2027 |
    | P4 Minswap V2 decoder + peg-floor | ✓ | ✓ | **outstanding** — decoder must be validated byte-for-byte against real on-chain `SwapExactIn` + `SwapMultiRouting` TX (`spec/swap-adapter.md §9`) | Q2-Q3 2027 |
    | P5 SwapAda dual-feed upgrade | ✓ | ✓ | partial — vault_swap_ada deployed; `asset_oracles[ADA]` empty at launch (SwapAda inactive until governance populates) | Q2-Q3 2027 |
    | A2 deregister `publish` on 14 staking credentials | ✓ | ✓ | partial — initial verification on a subset of staking credentials; full 14-credential Preprod re-verification outstanding before mainnet | Q2-Q3 2027 |

    "Code landed" + 194 unit + property tests passing (689 total randomized checks per `aiken check`) does not substitute for Preprod E2E or external audit. All 24 artefacts (17 logic validators + 4 NFT mint policies + `minswap_v2_adapter` + 2 SundaeSwap artefacts) remain under the 16 KB Plutus V3 ceiling; tightest headroom is `vault_liqwid` at 2,992 B free. (`docs/audit-scope.md §3` describes a different test-count metric — "30 properties × 100 iterations = 3,000 fuzz runs per build" — which counts only the `aiken/fuzz` randomized iteration ceiling. The 689 figure here is what `aiken check` summary line emits across the full suite. See `audit-scope.md §3` for the full reconciliation.)

    **Audit scope + funding implication (summary).** The pre-audit slippage-enforcement work above adds roughly +$15-25K to the $50–$150K engaged-amount range (per-engagement, post-possible-discount; pre-discount base $100–$150K — see §8.1) and +6-12 weeks to Phase 3-5 development (detailed breakdown in `docs/economics.md §5.2`: scope additions, cost modelling, funding-stack impact). Under the §0.2 + §8.1 (d) volunteer-builder framework, the audit cost itself is **not** founder-underwritten — it flows through the §8.1 (a)–(d) funding stack with founder gap-fill capped at ~$15K. The +$15-25K scope delta therefore feeds the funding stack's required amount, not a private founder runway figure; if the stack underperforms, Options A–D apply (timeline extension / scope reduction / community crowdfund / permanent 100K cap on mainnet) per §8.1. The reason we ship the slippage work pre-audit rather than deferring to "V1.x post-audit" is trust posture: leaving a compromised-keeper wide-slippage attack path open during an advertised launch is a worse trade than the audit-scope delta.
- **Destination whitelist** — `protocol_hashes` in Registry limits DeployToProtocol destinations to governance-approved scripts (Minswap V2 orderbook, Liqwid action validators). Any other address is rejected by `vault_protocol.ak`.
- **Keeper inactivity fallback** — on-chain judged by `last_compound_time`. When `last_compound_time + 7d < tx.validity_range.upper`, three things happen automatically: (a) Direct Withdraw waives `early_withdraw_fee` at the contract level regardless of `min_hold_seconds`; (b) the `require_keeper_or_governance_fallback` gate on keeper-authorized redeemers (RecallFromLiqwid / RecallFromProtocol / AdminDeployNonDeposit) opens the governance m-of-n fallback path (same redeemer, governance signs in place of keeper); (c) `Emergency Withdraw` self-serve becomes economically rational since users pay no early-fee. No off-chain keeper-health oracle is needed — the absence of a keeper TX within the window is the signal. This comparison is **not** forgeable via a wide `validity_range.upper`: both `vault_user.ak` and `vault_keeper_hot.ak` enforce `validity_range.upper - validity_range.lower <= 1 hour` on every time-anchored redeemer (internal-verification width-cap family, per `spec/vault-datum.md` §3 item 11), so a TX claiming `upper = now + 10y` is simply rejected. The keeper-inactivity check therefore works on live ledger time, not TX-submitter claims.

**Relationship between `last_compound_time` and `last_realloc_time`.** These are **two distinct datum fields** (see `spec/vault-datum.md` §2.1):

- `last_compound_time` is updated only by productive Compound (real yield harvested > 0).
- `last_realloc_time` is updated by zero-yield Compound (heartbeat) and by any allocation-only update (RebalanceBuffer / UpdateStrategy / reconciliation).

The 7-day keeper-inactivity gate reads `last_compound_time` only. The zero-yield heartbeat is primarily a liveness signal that keeps `last_realloc_time` fresh for off-chain indexers; it does not reset the 7-day fallback window. Governance-fallback execution is therefore strictly a function of real yield activity, not keeper pings.

Worst case: keeper stops operating. Users can still withdraw via Direct Withdraw (fee waived after day 7) or `emergency-withdraw` self-serve at any time.

### 5.5 Governance risk

Launch configuration is **3-of-3 multisig** (3 signers, threshold 3 — unanimity required). The signer slate is **1 founder signer + 2 independent well-known Cardano SPOs**, with all three identities disclosed on the website. The 3-of-3 unanimity requirement is deliberate: even if the founder's key is compromised or the founder makes a unilateral decision error, **the founder cannot queue any governance action alone** — 2 independent SPOs must also sign; conversely, the founder colluding with any one SPO only yields 2-of-3, still insufficient. The 1-of-3 cancel asymmetry is preserved: any single signer (including either independent SPO) can veto a queued action during its timelock window.

Independent SPO recruitment is the **target** for completion before mainnet ceremony but is **not a contract-level launch blocker** — the §5.5.1 three-layer governance safety design provides an acceptable fallback if recruitment lags (V1 may launch with founder-only governance, with SPO recruitment continuing in the post-launch window; this is a contingency path, not a target). Selection criteria: Cardano mainnet SPO operating ≥ 2 years, on-chain public identity (pool ticker + website), no prior commercial partnership with the founder, strong community / technical reputation, and ideally at least one signer outside the Asia time zone for governance response-time diversity.

**SPO signer role framing — Cardano community service.** The two independent SPO signers at V1 launch are committing to a **Cardano community-service role, not an economic-incentive role**. Phase 2+ `UpdateFeeSplit` to 5-10% gov pool share (gated on $500K TVL) is upside, not primary motivation. SPOs take this role because: (a) they support Cardano DeFi public-goods infrastructure, (b) their stake-pool-operator identity provides structural dissent-veto protection for V1 depositors, (c) the role extends their reputation asset, analogous to DRep commitment. If V1 stays in Phase 1 terminal state (§1.6.3 + §8.2 scenario), SPO commitment is not expected to yield financial return — this aligns with V1's non-commercial public-goods positioning and community-service role framing. SPO recruitment outreach is conducted with this framing explicit to avoid signer expectation / actual-incentive-structure mismatch.

**SPO recruitment phasing — tied to operational TVL.** SPO recruitment activity scales with V1's actual operational scope. The phases below replace any earlier framing where SPO seats were treated as a fixed mainnet-day deliverable:

- **Phase 0 (Pre-mainnet)** — SPO recruitment **may be deferred** if §1.5 launch-readiness conditions are not yet met. Founder-solo governance + the §5.5.1 three-layer safety design provides the depositor protection floor. Inviting SPOs into pre-launch governance is acceptable but optional; SPOs who prefer to wait until mainnet operations begin are honoured.
- **Phase 1 small-TVL ($500–$25K)** — V1 operates in Reference Implementation Mode (§2.6.1). Governance activity is minimal (occasional `UpdateStrategy`, possible emergency response). SPOs may be invited at this stage **with full disclosure that governance load will be light**. Recruiting SPOs purely for credibility-signalling without explaining the low expected workload is not appropriate.
- **Phase 1 moderate-TVL ($25–100K)** — Active SPO recruitment with clear framing of expected governance load and timeframe to Phase 2.
- **Phase 2 trigger ($100K+ TVL, post-audit)** — Full 3-of-3 multisig operational. All three SPO seats active. Governance load reflects the real depositor base.

The founder retains the option to recruit SPOs earlier than TVL would warrant if doing so produces material credibility uplift for V1's external positioning (e.g., for audit-firm engagement, Cardano Foundation outreach, or Catalyst evaluation panels). But the SPO commitment is honoured as community service per the framing above, and is **not expected to produce meaningful governance work until material TVL exists**. If V1 stays in Phase 1 indefinitely (the §1.6.3 terminal-state scenario), SPO involvement may remain symbolic / standby — with §5.5.1's three-layer safety design as the operational substitute. This is an acceptable terminal outcome and is **not** a failure of governance design.

Disclosed:

- All three signer identities are public on the website (1 founder + 2 SPOs, including pool tickers).
- 14-day timelock on fee / signer changes; 21-day timelock on `UpdateFeeSplit`.
- Any single signer can 1-of-n cancel a queued action during its entire timelock window.
- Orderly wind-down protocol (§9.2) if signers cannot continue.

Residual risk: **3-of-3 collusion** (all three signers acting together to push a malicious action). Mitigated by three layers:

- **Public reputation stakes across all three identities** — each SPO maintains an independent stake pool whose reputation has long-lived economic weight
- **Timelock-window exit** — the 14-day (or 21-day) withdrawal window during which depositors can exit before any change takes effect
- **Validator-level hard caps** (§6.3) — even a fully-colluding governance cannot touch them

**Post-audit roadmap.** Once the external audit passes and TVL grows, governance rotates per §6.1 Phase 2/3/4. From Phase 2 onward (5+ signers with a community-selected signer added), threshold drops to `n-1` (e.g., 4-of-5) so that at least one signer is always outside the passing quorum and can exercise genuine 1-of-n structural dissent — strengthening the 3-of-3 launch property ("founder can be blocked by any single SPO") into "a quorum-outside independent signer always exists".

### 5.5.1 Three-layer governance safety design

Independent of signer slate composition, the V1 validator set carries three layers of structural protection against governance-key compromise. These layers were designed to make **single-actor governance an acceptable Phase 1 fallback** in the event SPO recruitment lags — depositor recovery does not depend on the precise number or independence of governance signers.

**Layer 1 — EmergencyWithdraw is freeze-only.** The `EmergencyWithdraw` redeemer in `vault_gov_emergency` cannot reduce `total_deposited`, cannot remove or modify any `liqwid_positions` entry, and cannot accept a non-zero `loss_amount`. Its sole effect is flipping the `frozen` flag (0 ↔ 1). All loss accounting must go through `vault_liqwid.RecallFromLiqwid`'s gov-fallback path which physically Recalls underlying USDCx + writes off only the actual realized loss (`supplied_value − underlying_received`). A compromised governance key cannot drop the share price by writing off positions from datum without the corresponding fund movement — the qToken-orphan griefing vector is closed at the validator level.

**Layer 2 — DeployToProtocol stays open under freeze for swap-out.** When `frozen == 1` and the redeemer's `deploy_token != deposit_token`, the keeper can still drive a swap-out via the registry-whitelisted SwapAdapter (Minswap V2). The destination is pinned to the vault's own address by the SwapAdapter validator, so an attacker controlling the keeper key cannot redirect output; the worst they can force is the Tier 2 peg-floor-bounded slippage (≤ 5-7%), and the resulting USDCx still lands in the vault for users to withdraw. Without this exception, a freeze would permanently strand the NDV portion until the 21-day `AdminDeployNonDeposit` governance fallback executes — Layer 2 closes that long window.

**Layer 3 — CommunitySunset dead-man-switch.** When the vault has been operationally inactive for ≥ 90 days (`max(last_compound_time, last_realloc_time) + 90 days ≤ now`), any vUSDCx holder can invoke the permissionless `CommunitySunset` redeemer in `vault_user`. This atomically sets `frozen = 1` and `community_sunset_triggered = 1` (one-way irreversible). Once triggered:

- `vault_liqwid.RecallFromLiqwid` accepts any signer (no keeper or governance signature required).
- `vault_protocol.DeployToProtocol` Layer 2 path accepts any signer (same).

Any vUSDCx holder can then drive the full recovery chain — Recall → Swap → Withdraw — without any keeper or governance intervention. The 90-day threshold corresponds to ≈ 18 missed zero-yield heartbeats (5-day cadence), proving the keeper is fully dead. The sunset path **only opens recovery** — it cannot mutate `total_deposited`, `total_shares`, `idle_buffer`, `liqwid_positions`, or any policy / immutable field. Validator preservation invariants ensure the SwapAdapter destination + peg-floor + slippage bounds still apply during sunset, so an attacker cannot use the open recovery paths to drain value.

**Corner case: heartbeat-only keeper behavior.** Because Layer 3 triggers on `max(last_compound_time, last_realloc_time) + 90d`, a keeper who maintains heartbeats but ceases productive Compound activity could theoretically delay Layer 3 indefinitely. This is not a defect — it is intentional design, and depositors remain adequately protected even in that scenario:

1. **The 7-day inactivity gate (§5.4) reads `last_compound_time` only** and **does** activate after 7 days without productive Compound, regardless of heartbeats. This: (a) waives the early-withdraw fee for Direct Withdraw, (b) opens the governance m-of-n fallback for keeper-authorized redeemers, (c) makes Emergency Withdraw economical for depositors.
2. **Direct Withdraw remains fully operational** with auto-waived fees, allowing depositors to exit without keeper cooperation.
3. **Real yield not being compounded is reflected in stagnant share price**, visible in vault accounting at any time.
4. **The Withdraw-Zero `vault_user` validator** is permissionless on Direct Withdraw — no keeper signature required.

Layer 3 is therefore the **last-resort** recovery path, not the primary protection. Layers 1–2 + 7-day gate + self-serve withdraw infrastructure cover keeper-sabotage scenarios long before Layer 3 would trigger.

**Why `max(both)` and not `last_compound_time` alone.** The Layer 3 trigger uses `max(last_compound_time, last_realloc_time)` rather than `last_compound_time` only. This choice is intentional and supports two legitimate operational scenarios:

- **Reference Implementation Mode (§2.6.1)**: heartbeat-only cadence at low TVL is legitimate. Using `last_compound_time` alone would prematurely trigger Layer 3 in that mode.
- **Migration / V2 deploy scenarios**: governance may legitimately pause productive Compound during migration windows while keeping vault state alive via RebalanceBuffer or `UpdateStrategy` actions, both of which update `last_realloc_time`.

A keeper-sabotage scenario where the keeper maintains heartbeats specifically to delay Layer 3 is real but bounded by the other protections above. The cost-benefit analysis (legitimate use cases preserved vs. attack-delay extension) favored `max(both)`. This is documented for future auditors who will examine Layer 3 design choices.

**What this means in practice.** If the founder is honest but solo-signing, the system runs as a normal 1-of-1 multisig with timelock + cancel safety primitives. If the founder's key is compromised, the attacker cannot extract value (Layer 1 closes the brick path; Layer 2 keeps recovery flowing; hard caps in §6.3 limit fee abuse). **If the founder stops paying the §4.3.1 ~$80/year operating subsidy without formally invoking §9.2 sunset** (the v1.4 volunteer-model scenario noted in §9.2 (c)), the keeper goes offline → §5.4 7-day inactivity gate auto-activates (Direct Withdraw with fee waived) → and at 90 days Layer 3 below becomes triggerable. **If the founder is incapacitated for 90+ days for any reason**, depositors execute Layer 3 community sunset and recover their USDCx without any operator cooperation. Recovery does NOT cover the ~962 ADA in reference-script lockup nor the ~28 ADA in stake-credential deposits — those funds are bound to the founder's deploy wallet and to A2 governance, respectively, and accept their own residual loss as part of single-actor governance cost.

This three-layer design is what makes founder-only governance an **acceptable Phase 1 fallback** rather than a critical risk. SPO recruitment remains the preferred path for the credibility + structural dissent benefits, but it is not a launch blocker.

### 5.6 Pre-audit risk

Despite multiple rounds of internal audit, V1 has not yet had a third-party audit. **The 100K cap is the explicit acknowledgment of this risk.** Depositors deposit at their own risk. Full recovery paths (self-serve withdraw) exist regardless of audit status.

---

## 6. Trust Model and Governance

### 6.1 Six-identity separation target (NOT achieved at launch — disclosed honestly)

V1 targets six distinct human controllers: keeper, 3 governance signers, ref-script deployer, founder subsidy wallet. **At V1 launch this separation is partially achieved, not complete** — the section title is the long-term target, not the launch state.

At launch the founder directly controls **3 of the 6 identity slots**, expressed by these four roles which map to 3 independent on-chain positions (the ref-script deployer and founder subsidy wallet share a single founder-controlled wallet at launch, hence the 4 → 3 collapse; full address mapping in `docs/security-model.md` §2):

- **(1) Keeper operator** — runs the keeper instance; signs Compound / Recall / Supply / VaultSwap TXs.
- **(2) 1 of 3 governance signer seats** — founder's signature on `MultisigGov` quorum.
- **(3) Combined ref-script deployer + founder subsidy wallet** — single founder wallet that (a) holds the 20 ref-script UTXOs (§8.2 ~962 ADA lockup) and (b) funds the founding-capital subsidy flow into Phase 1 operations. The collapse to one wallet is an honest disclosure: separating them costs ceremony complexity without changing the underlying single-signer SPOF in Phase 1.

The other 2 governance signer seats are held by independent Cardano SPOs outside founder control, **assuming the §5.5 SPO recruitment has landed**; under the §5.5.1 / §7.4 fallback the founder may hold all 3 signer seats with key separation. The §5.5.1 three-layer governance safety design exists precisely so depositor recovery does not depend on whether full six-identity separation has been reached. **V2 deployment ceremony plans a multi-sig ref-deployer wallet that splits role (3) into two distinct keys** — see §9.2 + `docs/security-model.md` §2 for the planned rotation.

**Rotation path** (notation: `threshold-of-total` for signer configs):

- **Phase 1** (launch → external audit pass): 3 signers (**1 founder + 2 independent Cardano SPOs**), **threshold 3 (3-of-3 unanimity)** — founder is structurally a minority (1/3); see §7.4 for rationale.
- **Phase 2** (post-audit + TVL > 500K): 5 signers (add 1 community-selected signer), **threshold 4 (4-of-5)** — structural dissent-signer restored: `n - threshold = 1` signer always outside the passing quorum and thus able to 1-of-n cancel.
- **Phase 3** (TVL > 2M): 7 signers (add community-elected positions — election mechanism TBD, vUSDCx holding explicitly NOT used as vote weight), **threshold 5 (5-of-7)** — `n - threshold = 2` outside-quorum signers.
- **Phase 4** (mature, TVL > 10M): explore DAO migration.

### 6.2 Governance actions

Governance ActionKinds catalogued in `spec/governance.md` §4. Sorted by minimum timelock (the validator may enforce longer, never shorter):

| Min Timelock | ActionKind | Category |
|--------------|------------|----------|
| 0 days (no minimum wait — see note below) | `EmergencyWithdraw` | Emergency response |
| 1 hour | `FastUpdateMarkets` | Liqwid pool-shard migration |
| 48 hours | `UpdateSlippagePolicy` | Safety-bound tuning (§5.4) |
| 7 days | `UpdateStrategy` | Allocation / buffer parameter |
| 7 days | `TreasurySpend` | Treasury category outflow |
| 7 days | `AdminDeployNonDeposit` | Non-deposit-token recovery |
| 14 days | `UpdateFee` | Performance / early-fee / min-hold |
| 14 days | `UpdateRegistry` | Stable tokens / Liqwid markets / oracles |
| 14 days | `UpdateKeeperAuth` | Keeper allowlist / rotation |
| 14 days | `UpdateTreasuryParams` | Category ratios / caps |
| 14 days | `RotateSigners` | Multisig membership / threshold |
| 14 days | `SlashBond` | Phase 3+ — not reachable at V1 launch |
| 14 days | `UpdateOracleSource` | SwapAda Charli3 / Orcfax feed rotation |
| 14 days | `ActDeregisterStake` | End-of-life: 2 ADA × 14 staking validators |
| 21 days | `UpdateFeeSplit` | **Governance is adjusting its own pay — longest timelock** |

Direct (not queued) redeemers also exist: `KeeperToggleMarket` (1-hour keeper unilateral disable of a single Liqwid market — see §5.3, not governance-gated), `Heartbeat` (1-of-self signer liveness), `DistributeSignerCompensation` (1-of-n quarterly pool distribution). These do not flow through the queue→timelock→execute pipeline and are documented in `spec/governance.md` §5.

> **About the 0-day `EmergencyWithdraw` timelock.** 0 days means there is no *minimum wait* between QueueAction and ExecuteAction — it does **not** bypass governance consensus. Every `EmergencyWithdraw` execution still requires the full **3-of-3 signatures at launch** (per §5.5 unanimity), still exposes the queued action to **1-of-n cancel veto** during whatever window elapses between queueing and execution, and still enforces the payload-hash binding below. What 0 days buys is *response speed* — governance can queue and execute within the same signing session when a sustained depeg or Liqwid incident demands immediate freeze. Keeper cannot trigger `EmergencyWithdraw` unilaterally; the keeper's fast-response lever is `KeeperToggleMarket` (see §5.3), which only disables new Supply to a single Liqwid market and cannot freeze the vault or move funds.

`ActDeregisterStake` is V1's operator-facing "end-of-life" path: it unwinds the 2 ADA Cardano stake-registration deposit that was posted for each staking validator at ceremony PHASE 4a, gated by the standard m-of-n gov flow + 14-day timelock + 1-of-n cancel. **All 14 V1 staking credentials participate**: `vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`, `keeper_stake_script`, the SwapAdapter `minswap_v2_adapter`, and the SundaeSwap pair `sundaeswap_adapter` + `sundaeswap_cancel_guard` (each parameterized on governance anchors solely to enable this path). Every governance action has:

- **Minimum timelock enforced by `multisig_gov.ak`** — governance may queue with a longer timelock but never shorter.
- **Payload hash committed at QueueAction time** — prevents payload substitution at ExecuteAction time (every target validator calls `is_gov_authorized` which recomputes `blake2b_256(cbor.serialise(payload))` and compares to the queued hash).
- **1-of-n cancel available during the entire timelock window** — any single signer can `CancelAction` unilaterally.
- **Target-script binding** — the queued action's `target_script` must equal the target validator's own script hash, so an action queued for one validator cannot be executed against another.

### 6.3 What governance cannot do

Hard caps baked into validators, immune to governance:
- `performance_fee_bps` > 450 (4.5%) — rejected by `UpdateFee` redeemer in `vault_gov_policy.ak`
- `early_withdraw_fee_bps` > 100 (1%) — rejected by `UpdateFee`
- `min_hold_seconds` > 21600 (6 hours) — rejected by `UpdateFee`. Rationale: on V1's weekly Compound cadence, even at the maximum 6h setting the Direct Withdraw gate is active for only ~3.6% of the week; the Queue Withdraw path is never observed by this gate, so user funds cannot be locked regardless of the setting. Tightened from an earlier 24h cap — see §2.4.
- `keeper_fee_bps` > 4000 (40%) or `gov_fee_bps` > 1000 (10%) or `keeper_fee_bps + gov_fee_bps` > 5000 (treasury floor 50%) — rejected by `UpdateFeeSplit`
- `signers` < 3 or `threshold` < 2 or `threshold` > `signers` (unanimity `threshold == signers` explicitly allowed — V1 launch uses 3-of-3)
- Any change to compile-time anchors (requires full redeploy)

`buffer_target_bps` is an advisory target consulted by the keeper when selecting between Supply and Recall, not a validator-enforced bound. Governance can set it anywhere in [0, 10000] via `UpdateStrategy`, but the keeper does not act on economically irrational values.

---

## 7. Keeper Model — "Run Now, Open Later"

### 7.1 V1 launch: founder-only keeper

V1 deploys `keeper_stake_script` with `RegistrationMode = GovernanceOnly` and an allowlist containing only the founder's keeper pubkey. This is the **honest launch state**:
- Keeper economics don't work for non-founder operators at 100K TVL.
- Pretending otherwise would be misleading.
- The architectural piece for opening keeper is in place and audited.

### 7.2 Future opening: PermissionlessWithBond

When TVL reaches a level that makes keeper operations viable (~$5-10M+), governance can `UpdateKeeperAuth` to switch `RegistrationMode` to `PermissionlessWithBond`. At that point:
- Any party can post a bond (amount set by governance) and become an authorized keeper.
- Keepers are ranked by bond size + performance.
- Slashing conditions enforce behavior.

The full bond + slashing state machine is specified in `spec/keeper-auth.md` and will be audited as part of V1 scope, even though inactive at launch.

### 7.3 Why publish now instead of waiting

1. **Commitment signal.** V1's path to decentralization is architectural, not promissory. Opening keepers later is a 1-TX governance action, not a protocol redesign.
2. **Audit efficiency.** Auditing the full mechanism once, rather than twice (launch + future upgrade), reduces cost and risk.
3. **Community input.** Publishing the design invites examination from future keeper operators before the switch flips.

### 7.4 Founder as keeper operator and one of three governance signers

**Under the base-case Phase 1 small-TVL configuration (b)** — which depositors should assume at launch per Executive Summary, given the §8.2 $500–$25K Phase 1 TVL range — the founder operates the keeper instance **and** holds all 3 governance signer seats with HD-key separation (multiple HD-derived keys held in physically separate signing environments). **Under the stretch-target configuration (a)** — conditional on independent SPO recruitment landing before mainnet ceremony — the founder runs the keeper and holds **1 of 3 governance signer seats**, with the other 2 seats held by independent Cardano SPOs (see §5.5). The §5.5.1 three-layer governance safety design + §6.3 hard caps preserve depositor recovery paths regardless of signer-slate composition; the (a)/(b) distinction affects governance dissent semantics but not contract-level depositor protections. Either way, this arrangement is disclosed in §6.1 as a **single-operator risk at launch** — scope limited to the keeper-operator choice (and, under (b), the governance signer slate); it does not extend to the contract source (fully open-source) or to the keeper source (fully open-source and on-chain-switchable via `UpdateKeeperAuth`).

**What 3-of-3 unanimity at Phase 1 actually does** (honest framing):

- **Accidental-action protection.** No single signer — including the founder — can unilaterally queue a governance action by mistake, compromised key, coercion, or impairment (drunk, rushed, hacked wallet). This is a real operational safety property, independent of trust.
- **Founder alone cannot pass governance.** Even founder + one SPO colluding only yields 2-of-3 — still insufficient to execute any action. Either independent SPO can refuse and stop the action entirely.
- **1-of-3 cancel asymmetry.** Queueing needs 3 signatures; stopping needs 1. Any signer — including either independent SPO — can unilaterally cancel during the timelock window.
- **Public timelock observation window.** 14-day timelocks (21-day for `UpdateFeeSplit`) on high-impact actions publicly expose every queued change for depositor examination + independent scrutiny before execution.
- **Hard invariants governance cannot move at all** — validator-level caps (fee max 4.5%, alloc bounds, immutable identity fields). See §6.3.

**What Phase 1 3-of-3 does NOT do** (also honest):

- **Keeper operator is a single party at launch** (not keeper-code centralization). The entire keeper source is open-source; anyone can read, audit, and self-host an instance. The founder runs the live instance at launch as a single contractual responsibility concentration, not because others are prevented from running one. Governance `UpdateKeeperAuth` (14-day timelock + 1-of-n cancel) can rotate the authorized keeper PKH at any time — e.g., assigning a different operator once Phase 2 TVL thresholds are met, or activating `PermissionlessWithBond` to open keeper registration in Phase 3 (the contract supports this already; launch config is `RegistrationMode = GovernanceOnly`, disabled). If the current keeper key is compromised, the 7-day keeper-inactivity gate opens the governance m-of-n fallback automatically; during that window Compound / swap / DeployToProtocol pause, but Direct Withdraw has `early_withdraw_fee` auto-waived and principal remains safe.
- **SPO social distance is real but finite.** Independent SPOs are not founder-recruited, but the Cardano SPO community is not unboundedly large; some baseline community interaction exists. Read "independence" here as economic + technical independence, not absence of community contact.

**Honest depositor framing:** Phase 1 governance is **"1 founder + 2 independent Cardano SPOs co-governing; keeper instance still operated solely by founder with on-chain-switchable authorization; structural protection comes from timelocks + hard caps + self-serve exit paths"**. Phase 2 (post-audit + TVL > $500K) expands to 5 signers and switches to 4-of-5, restoring the structural dissent-veto property.

**Phase 1 small-TVL governance posture (operational contingency).** If V1 launches into a Phase 1 small-TVL scenario ($500–$25K — the (a) "personal reference" or (b) "small organic" sub-scenarios described in §8.2), SPO recruitment may be deferred or held in symbolic / standby form during this period, consistent with §5.5's TVL-phased recruitment framing. In this scenario, the founder operates governance as **de facto solo-signer** — with the option to consult invited SPOs, but not requiring their signature for routine governance actions. The §5.5.1 three-layer safety design provides the structural protection that would otherwise come from genuine multi-signer dissent veto.

This is documented as a **contingency operational mode**, not a deviation from §5.5's 3-of-3 launch target. The 3-of-3 target remains correct for moderate-and-above TVL scenarios; in the small-TVL scenario, it is over-engineered relative to actual governance activity, and §5.5.1 fallback is the more appropriate operational posture. When TVL crosses the moderate-TVL threshold ($25K+ sustained), full SPO seating activates per the §5.5 phasing.

**Founder's professional background — disclosed here as context, not as the primary origin story.** The founder's professional work before OptiVaults was in the wealth-management / private-client-services side of the traditional-finance industry. That background is disclosed in this section (not in §1.6) as **additional context for readers who find the information relevant**: some V1 design choices — 4-bucket treasury with audit-reserve floor, 21-day timelock specifically on `UpdateFeeSplit` (the longest timelock, because governance is adjusting its own pay), multi-tier Compound cadence aligned to traditional-finance product release cadence rather than crypto-launch cadence — draw on product-design patterns familiar from the traditional-finance side. But V1 is **not positioned as a traditional-finance-insight product**; the primary origin story (§1.6) is founder-as-user. Auditors, Catalyst panel members, and investors who want the professional-background context can use this paragraph; depositors should evaluate V1 on what the contract does, not on the founder's résumé.

### 7.5 Conway-era DRep stance

V1's vault UTXO carries ADA only as min-UTXO and operational buffer (gas for rebalance / compound cycles). The treasury script accumulates USDCx performance fees rather than ADA. As a result, V1 has no material ADA position for Conway-era DRep vote delegation; the vault is not a stake pool delegator at scale, and the treasury does not take on-chain governance positions on Cardano protocol parameters. Should post-launch operations accumulate material idle ADA (e.g., from a future stake-based keeper-bond program), governance can delegate via a dedicated `TreasuryDelegateDRep` action introduced at that point.

---

## 8. Roadmap and Milestones

### 8.1 Pre-launch gates

**Required for mainnet launch under the 100K USDCx pre-audit cap (Stage 1 / 1.5 / 2 per §1.5):**

- [ ] V1 contracts complete, all tests pass, internal audit rounds complete
- [ ] Preprod deployment + E2E verification (all 17 logic validators + 4 NFT mint policies + `minswap_v2_adapter` + 2 SundaeSwap artefacts, full flow)
- [ ] Deploy ceremony dry-run on Preprod
- [ ] §1.5 Class A override conditions (Liqwid / USDCx / Cardano chain / oracle) all clear
- [ ] §1.5 axis state at One-Yellow or better (per Stage matrix)

**Required for cap lift toward Stage 3 ($500K → $2M per §1.5 ramp):**

- [ ] External audit engaged and complete
- [ ] Audit findings resolved
- [ ] §1.5 axis state at All-Green sustained 60 days

**External audit is NOT a launch gate; it is a cap-lift gate.** V1 launches on mainnet at the 100K USDCx pre-audit cap when the launch gates above are met. The external audit completes Stage 3 cap lift when funding lands; if funding never lands, V1 stays on mainnet at the 100K cap indefinitely. This separation is the structural reason §0.2 and §4.3.1 articulate the volunteer-builder + community-funded audit framework — the founder commits to operating V1 on mainnet at 100K from launch onward; the community funds audit if it wants V1 to grow beyond that cap.

**External audit engagement (target Q2-Q3 2027 if funding lands).** The audit firm has not yet been selected or contracted at the time of this whitepaper; engagement is gated on V1 Aiken implementation being feature-complete with internal verification passing **and** the §8.1 funding stack delivering enough to cover the engagement. Candidate firms will be short-listed from the set of auditors with prior Cardano Plutus V3 + Aiken experience — this is a narrow set (Anastasia Labs, MLabs, TxPipe, and a handful of independent Aiken auditors at publication time). The engaged firm and scope will be announced publicly at least 2 weeks prior to audit kickoff.

**Audit contingency (when audit happens).** If external audit surfaces CRITICAL findings, findings requiring contract redesign, or systemic design flaws, **the Stage 2+ cap lift is postponed** until remediation + re-audit confirms resolution. Mainnet operation at the 100K cap continues during this remediation window unless the finding is severe enough to invoke §1.5 Class A override (e.g., a CRITICAL leading to emergency freeze via §5 governance). If audit finds a systemic flaw that cannot be fixed within the current architecture, the cap stays at 100K indefinitely, the architectural reset is published publicly, and V1 has **no external-contributor funding / no token pre-sale / no SAFE / SAFT obligations** to settle — unspent founding capital stays with the founding entity for use in any revised design.

Funding for the external audit is drawn from the project's founding capital (not from existing deposits — the internal-verification-phase deployment has a separate operational budget). The USD **$50–$150K per-engagement range** in `docs/economics.md §5.2` is based on public pricing indications from Cardano-capable audit firms (Anastasia Labs, MLabs, TxPipe) circa 2025-2026 for comparable Plutus V3 scopes — this range **spans pre-discount base price (~$100K–$150K) at the upper end and post-public-goods-discount engaged amount (~$50K–$90K) at the lower end**. The actual engaged amount will be disclosed publicly at contract signing.

**Audit funding strategy (sustainability under the public-goods path).** V1's public-goods positioning allows us to tap multiple non-dilutive funding sources to reduce the audit cost burden:

- **(a) Cardano Project Catalyst + Cardano Foundation + Intersect Member Committee + Aiken Foundation grants**: V1's "Cardano DeFi public-goods reference implementation" positioning fits each body's DeFi / Infrastructure / Open Source themes directly. Combined best case across the four bodies is **$80–150K** (per funding-stack table below); Catalyst alone, when a Round opens, realistically secures **$30–50K**; Cardano Foundation / Intersect Member Committee / Aiken Foundation independently typically fund **$10–30K each** for public-goods Cardano DeFi infrastructure (visible from their 2024–2026 grant histories). **Status as of writing: Cardano Project Catalyst is in a paused / restructuring state with no confirmed timeline for the next Round resumption** — the other three bodies remain active and continue to accept proposals on rolling or batched cycles. V1 retains (a) as a candidate funding source across all four channels but does not depend on any single one; the audit timeline (Q2-Q3 2027 target) is set to allow for either Catalyst re-opening within this window or for the funding to be sourced from non-Catalyst (a) channels + (b)+(c)+(d) entirely.
- **(b) Audit firm public-goods pricing**: Apache 2.0 + non-commercial positioning may qualify for a **30-50% discount**, reducing full price $100K-$150K to approximately $50K-$90K;
- **(c) Scope reduction via extensive internal audit**: the accumulated internal audit history serves as preparatory material, allowing external audit scope to focus on critical paths (2-3 most critical validators + cross-validator integration flows) rather than all 17 logic validators + 1 adapter, saving another **$15K-$25K**;
- **(d) Founder gap-fill contribution (capped, not underwriter)**: the founder commits **up to approximately $15K personal out-of-pocket** to bridge small shortfalls between (a)/(b)/(c) delivery and the final audit price. The founder **explicitly does NOT commit to underwriting the full $50–$150K audit cost in any scenario**. This cap is set deliberately small relative to the audit base price — V1 is a volunteer-built public good (§0.2), not a founder-underwritten product. If the funding stack underperforms beyond the $15K gap-fill capacity, V1 follows the Options A–D contingency tree below rather than escalating founder self-funding.

**Distribution under the volunteer + capped-gap-fill model.** The funding stack outcome distribution (audit base price $50–$150K — lower end achievable via multi-firm engagement model, scope reduction via internal-audit reliance, or audit-firm public-goods rate; upper end is the pre-discount single-firm full-scope price):

| Source | Best case | Middle case | Worst case |
|--------|-----------|-------------|------------|
| (a) Catalyst + Cardano Foundation + Intersect + Aiken Foundation grants | $80–150K combined | $30–60K | $0 (none resumed / approved by audit start) |
| (b) Audit-firm public-goods discount | 50% off (−$50–75K) | 30% off (−$30–45K) | 0% off (full price applied) |
| (c) Scope reduction via internal-audit history | −$25K | −$15K | −$0 (auditor requires full scope) |
| (d) Founder gap-fill cap | $0 (stack covers full price) | $0–$15K | **$15K (hard cap reached)** |
| Outcome under worst case | — | — | **Funding gap of $35–$135K remains; Options A–D activate** |

**Worst-case is NOT "founder out-of-pocket $100–150K".** Under the volunteer-builder framework, the worst case is "(a)+(b)+(c)+(d) underperform such that a funding gap of $35–$135K remains beyond the $15K gap-fill cap, and V1 follows the Options A–D contingency tree rather than reaching mainnet on the original timeline". This is materially different from the v1.3-era worst case which had founder self-fund expanding indefinitely; here the founder commitment is **capped at the $15K gap-fill** and the worst case has the project, not the founder's bank account, absorb the shortfall (by deferring / scope-reducing / crowdfunding / staying in Preprod).

**Contingency tree when funding stack underperforms beyond gap-fill capacity.** If by 2027 Q1 the committed funding from (a)+(b)+(c) plus the $15K (d) gap-fill totals less than the engaged audit price, the following alternatives will be evaluated **publicly** (not silently absorbed):

- **Option A — Audit timeline extension (preferred).** Audit timeline pushed to Q4 2027 or H1 2028. **V1 continues to operate on mainnet at the pre-audit 100K USDCx cap throughout.** This buys time for Catalyst Round resumption, additional grant outreach, or growth of the community-funding pool. The founder's $80–$200/year operating commitment continues; depositors who entered under the pre-audit cap remain at the same risk profile they entered under. Cap stays at 100K; Stage 2+ progression awaits audit landing.
- **Option B — Scope-reduced audit.** Audit scope narrowed to "critical-path validators only" (typically the 5–7 most security-critical of the 17 logic validators) to fit available funding. Remaining validators audited in a future Phase 2 round. **V1 mainnet operation continues at the 100K cap before, during, and after this scope-reduced audit.** Completion of scope-reduced audit may justify a partial cap lift (e.g., 100K → 200K) but not full Stage 3 lift; disclosure of scope-limited badge to depositors at the point of any partial cap lift is mandatory.
- **Option C — Community / DAO crowdfund.** A transparent, non-equity, non-token contribution pool requesting Cardano community funding for the audit. Pre-announced budget + post-audit transparent accounting + the Apache 2.0 codebase remains the only "return" to contributors. This is a real path on Cardano (Catalyst alternatives + ad-hoc community pools have funded public-goods audits in adjacent ecosystems), but conditional on community interest materialising at the scale needed. **V1 mainnet operation continues at the 100K cap during the crowdfund window.**
- **Option D — Permanent pre-audit 100K cap.** If none of A/B/C lands, **V1 continues to operate on mainnet at the 100K USDCx cap indefinitely**, with no audit-driven cap lift. Depositors continue to have permissionless access at small scale; the protocol stays live, the keeper continues to operate under §4.3.1, governance remains active, and the codebase remains Apache 2.0 public-goods. This is the §0 / §0.2 "V1 may be the terminal state" outcome — V1 settles into a permanent small-scale public-goods reference implementation **on mainnet**, not as a Preprod-only artefact. The "terminal state" framing means cap is never lifted via the audit path, not that V1 stops operating. **Sunset under §9.2** is a separate path triggered only by §1.5 Class A overrides (USDCx / Liqwid / Cardano / oracle incidents) or by founder explicit decision — not by Option D itself.

  **Option D depositor risk disclosure (specific to sustained Option D operation).** "V1 operating at 100K cap for years without external audit" is a materially different depositor risk profile from "V1 operating pre-audit while waiting for audit funding to land within months". Depositors entering V1 during sustained Option D operation should specifically understand:

  (a) **The contract has never been independently audited and may never be.** Protection against undetected CRITICAL bugs depends entirely on internal audit history (~70+ rounds at v1.4 publication) + §5.5.1's three contract-level safety layers (Layer 1 freeze-only EmergencyWithdraw / Layer 2 swap-out-under-freeze / Layer 3 90-day permissionless CommunitySunset) + §6.3 validator-enforced hard caps. There is no third-party audit endorsement and there is no commitment that one will ever materialise.

  (b) **The founder-incapacitation risk is structurally higher under Option D** than under the audit-funded path, because Option D extends Phase 1's single-operator concentration indefinitely rather than transitioning to Phase 2's expanded signer set (per §6.1 rotation roadmap). §5.5.1 Layer 3 (90-day CommunitySunset) remains the absolute backstop — any vUSDCx holder can permissionlessly trigger full self-serve recovery if the founder ever ceases operation — but the structural-protection profile is "code-level safety, not human-redundancy safety". Depositors should size positions accordingly.

  (c) **External-audit signalling is permanently absent under Option D**, which is a real informational asymmetry depositors are accepting. In adjacent ecosystems (Ethereum DeFi) "multi-year unaudited contract running in production" is read as a negative OpSec signal regardless of internal-audit history. V1's Apache 2.0 + §5.5.1 architecture is technically defensible at the contract layer, but the **external-perception consequence of permanent pre-audit state is real and is borne by depositors via narrower discovery + less third-party validation**.

  (d) **The deposit decision under sustained Option D is best framed as "long-duration acceptance of pre-audit risk profile,"** not "waiting for audit". A depositor who specifically values external-audit signalling as a precondition for deposit should treat Option D as a permanent disqualifier and not enter V1; a depositor who values the §5.5.1 + §6.3 contract-level safety design + the public-goods reference-implementation positioning sufficiently to accept the audit-permanence-uncertainty can enter, with eyes open about the trade-off.

We commit to transparency about the funding gap rather than soft-pedalling the issue. The public dashboard tracks the current state of (a)+(b)+(c)+(d) commitments monthly during the funding-stack period, so depositors and observers can independently evaluate which option is likely.

**Linkage to §4.1 sunset trigger — clarified under the volunteer model.** §4.1's nominal sunset condition ("runway < 6 months forward burn") interprets "runway" as the founder's **operating-side commitment** (~$80–$200/year per §4.3.1), not as audit commitment. Under the volunteer-builder framework, operating runway is structurally durable from personal income and is essentially unreachable as a sunset trigger; the live failure modes are §1.5 Class A overrides (USDCx / Liqwid / Cardano / oracle incidents) and explicit founder sunset decision. **Audit-funding failure is NOT a sunset trigger** — it merely keeps V1 at the 100K cap under Option D. V1 continues to operate on mainnet through all four (A/B/C/D) audit-funding outcomes.

**Audit timeline reflects funding-stack uncertainty.** The Q2-Q3 2027 target is set explicitly later than the original Q3 2026 plan to accommodate (i) Catalyst Round resumption probability, (ii) parallel Cardano Foundation / Intersect / Aiken Foundation grant outreach, and (iii) the community / DAO contribution-pool path (Option C above) maturing if (a)/(b) outcomes are conservative. V1 operates on mainnet at the 100K pre-audit cap throughout this period; if 2027 Q4 arrives without the funding stack reaching the cost threshold, §1.5 Override condition 6 fires (cap stays at 100K indefinitely — V1 remains on mainnet, no Preprod retreat). The audit itself is **conditional on funding materialising**, not on a calendar date — see §8.1 Options A-D above and §0.2 funding posture for the volunteer-builder framing.

Status of each funding source is tracked in `docs/economics.md §5.2`. This stack lets V1 complete its external audit without entering VC / token fundraising / diluting its Apache 2.0 public-goods posture.

### 8.2 Launch (TVL cap 100K USDCx)

**What Phase 1 actually is — honestly labeled.** V1 launch under the 100K USDCx cap is **protocol validation under adversarial conditions**, not a commercial TVL-scale launch. The 100K cap is a **ceiling, not a target**. Our internal expectation is that Phase 1 TVL lands in the **$500-$25K range over the first 6-12 months** — this is a speculative range, not a forecast, based on conservative user-acquisition assumptions and the permissionless-only stance (no closed-beta gate, so the lower bound could be very low if organic discovery is slow); actual outcomes may vary significantly in either direction. Readers modelling Phase 1 around a "filled cap" scenario should know this is not the outcome we're planning around.

**Pre-audit operational stance.** During the pre-audit period V1 does no marketing push; the landing page serves organic SEO only. The contract itself is a permissionless smart contract — any depositor who understands and accepts the pre-audit risk profile (undetected CRITICAL bug possible, TVL will not grow quickly, founder bandwidth limited) may decide to enter on their own judgment. There is no invitation gate and no whitelist. But **honestly expect**: this is not an opening-sale phase, it is a validation phase. Depositors seeking scale entry or yield maximisation should wait for post-audit cap lift or choose Direct Liqwid DJED supply directly.

**Phase 1 TVL is a range, not a target.** Earlier whitepaper drafts assumed Phase 1 TVL would land in $5K-$25K via ~10-15 founder-network depositors during what was framed as a "closed beta." That framing has been removed in favour of pure permissionless + risk-disclosure. As a consequence: **actual Phase 1 TVL will depend entirely on organic discovery and individual depositor risk-assessment**, with significantly lower predictability than the closed-beta framing implied. Possible outcomes: (a) **$500–$5K** (only founder + 1-2 community depositors; Phase 1 still served its validation purpose under smaller real-user volume — counts as a successful Phase 1 if no CRITICAL bug surfaces); (b) **$5K-$25K** (the prior expectation, now treated as a midpoint scenario); (c) **$25K-$100K** (above the prior expectation; would trigger additional frontend warnings reminding users of pre-audit risk density, but no contract-level limits beyond the existing 100K cap). All three outcomes are acceptable Phase 1 endings; none represents a "failure" by itself. Phase 1 success is measured by §8.2 success criteria (a)-(d) below, not by TVL achieved.

**Sub-scenarios mapped to operational mode, SPO posture, and framing.** v1.3 makes the operational-mode mapping explicit so depositors can read the sub-scenario they are currently in directly off the table:

| Sub-scenario | TVL range | Likely # of depositors | Operational mode | SPO governance | Audit / external framing |
|---|---|---|---|---|---|
| (a) Personal reference | $500–$5K | Founder + 1–2 community | Reference Implementation Mode (§2.6.1) — quarterly-to-annual Compound | Deferred / symbolic | "Cardano reference vault implementation" |
| (b) Small organic | $5K–$25K | 5–20 depositors | Reference Implementation Mode (§2.6.1) — cadence tilts toward monthly–biweekly Compound as TVL approaches the $25K deactivation threshold | Optional SPO recruitment with full load disclosure | Standard non-commercial public-goods |
| (c) Phase 1 cap-approach | $25K–$100K | 20–100 depositors | §2.6 Default cadence (weekly Compound) | Full 3-of-3 SPO seats active | Standard product audit |

Each sub-scenario is an acceptable Phase 1 endpoint per the §8.2 success criteria (a)–(d) below. Transitions between modes are keeper-operational policy under §4.5 discretion; they do **not** require a governance action unless TVL repeatedly crosses thresholds (which would suggest formalizing as `UpdateStrategy`).

If V1 launches at sub-scenario (a) and TVL grows organically into (b) over 6–12 months, the keeper publishes mode-transition notice on the dashboard and shifts cadence — depositors see the transition transparently. If TVL contracts back (e.g., from (c) to (b) after major withdrawals), the keeper shifts mode in the reverse direction with similar dashboard notice. This is the intended adaptive behaviour, not a sign of distress.

This stance is grounded in two simultaneous facts:

1. **The $135K–$1.8M self-sustaining TVL range (baseline ~$500K) is, by definition, a Phase 2+ post-audit goal under §2.6 Default cadence.** It cannot be reached inside the $100K cap era. Pre-audit TVL growth beyond ~$25K would be ahead of the risk envelope depositors should accept.
2. **Pre-audit honest success criteria are NOT "fill the cap":**
   - (a) No CRITICAL exploits against the deployed contracts during the audit window
   - (b) Automation (keeper + API + frontend) operates correctly under real user traffic at meaningful-but-small scale
   - (c) Community trust built via transparent governance actions + published incident history
   - (d) Launch handed off to external auditor with a working system the auditor can actually stress-test

Hitting all four with $15K TVL would be a **successful Phase 1**. Hitting $80K TVL while any of the four remains unverified would be a **failure disguised by a number**.

**What Phase 1 launch looks like operationally:**

- V1 mainnet deploy ceremony (~42 TX: 3 one-shot ceremony NFT mints (Vault Identity / Governance / Registry Auth) + 20 reference-script deployments (17 logic-validator ref scripts + `minswap_v2_adapter` + the 2 SundaeSwap artefacts, one ref script per TX) + 14 stake-credential registrations + 5 state-UTXO inits (vault / registry / governance / treasury / keeper_stake); gov_signer_nft mints happen incrementally as signers join and are outside the 42)
- Public announcement + migration window for internal-verification-era depositors
- First 100 migrating wallets: early-withdraw fee subsidized from audit reserve
- **Outward messaging stance**: the ask is clearly "small deposits welcome to help us validate under real conditions" — V1 is not a yield-farming opportunity. This signal is meant to steer yield-maximizing users away (Direct Liqwid DJED serves them better on pure math); it is not V1 being selective about who is welcome.

**Deploy-ceremony partial-failure handling.** The V1 deploy ceremony is a sequence of roughly 42 transactions: mint the three one-shot NFTs (Vault Identity, Governance, Registry Auth), publish **20** reference scripts (17 logic validators + `minswap_v2_adapter` + the 2 SundaeSwap artefacts, one per TX), register the 14 stake credentials, initialize Registry + Governance + Treasury + Keeper Stake UTXOs, and finally initialize the vault UTXO itself. Each TX is idempotent-safe: state is checkpointed to local JSON after every successful TX, and the deploy script can resume from the last checkpoint on rerun. A partial failure does not leave the system in a broken state — the in-progress ceremony holds reference scripts and identity NFTs at a deploy-wallet address until the vault UTXO initialization TX completes. The only non-recoverable failure mode is a minted one-shot NFT whose deploy-time validity range expired before the ceremony finished; that case is handled by starting a fresh ceremony under a new `RELEASE_TAG` and reclaiming locked ADA from the orphaned reference scripts via a separate sweep TX. Full runbook: `docs/runbooks/v1-mainnet-ceremony.md` (to be published with V1 implementation).

**Reference-script capital lockup.** Each of V1's 17 logic validators plus the `minswap_v2_adapter` SwapAdapter and the 2 SundaeSwap artefacts is published as a Cardano **reference script UTXO** (CIP-33) at a deploy-wallet address. Reference scripts carry Conway-era min-ADA that scales with serialised script size; at current protocol parameters with the operator's 1.10× safety multiplier, a ~5.6 KB proxy script locks ~29 ADA, a ~10 KB validator ~50 ADA, and the largest ~14 KB validators ~70 ADA each. Summed across the 20 reference scripts (17 logic validators + `minswap_v2_adapter` + the 2 SundaeSwap artefacts), V1 deploy locks approximately **962 ADA (a low-three-figure USD amount at recent ADA prices)** as reference-script min-UTXO. (V1 Preprod deploy measured exactly 962.07 ADA across the 20 ref scripts.) Plus an additional **28 ADA in stake-credential deposits** (14 staking validators × 2 ADA each, all reclaimable via the A2 deregister `publish` handler after a 14d governance timelock — see §6.2). Total ceremony capital commitment: **~990 ADA reclaimable**, plus ~22 ADA in non-recoverable network TX fees and ~27 ADA in state-UTXO seed ADA (vault / registry / treasury / keeper-auth / governance script addresses) for a grand-total around **~1,039 ADA** at ceremony close. The deploy-wallet address holds the 20 ref-script UTXOs — they are **spendable reference inputs** for every vault TX but **not recoverable** without spending the UTXO itself (which would decommission the reference script). V2 migration plan: when a new version is deployed, the V1 reference script UTXOs are spent-and-drained in a one-time reclaim transaction that sends the locked ADA back to the deploy wallet, net of a ~2.5 ADA TX fee per ceremony. The deploy-wallet signing key is held by the founding entity; the lockup is disclosed here so depositors understand that ~962 ADA of founding capital is committed to V1 at deploy time and is recoverable only on sunset / V2 migration.

### 8.3 Post-launch Milestones

| Milestone | Trigger | Actions |
|-----------|---------|---------|
| External audit complete | Auditor signoff | Raise TVL cap to 1M USDCx |
| TVL reaches 500K | — | Phase 2 governance rotation (add external signer) |
| TVL reaches 2M | — | Phase 3 rotation (community signers) |
| TVL reaches 5M | — | Evaluate `PermissionlessWithBond` keeper opening |
| TVL reaches 10M | — | Consider DAO migration exploration |

Milestones are targets, not commitments. Actual timing depends on audit availability, market conditions, and community readiness.

### 8.4 Migration-stability milestone

A discrete milestone V1 wants to hit: **12 months of continuous V1 operation with no migration or redeploy**. Previous internal deployments (V1 → internal-verification-era) underwent multiple redeploys as contract bugs were discovered. V1's goal is to remain the same deployed hashes for 12 months — a measure of maturity.

If a critical bug requires V2, migration follows the same fresh-deploy pattern documented in `docs/migration.md`.

---

## 9. Honest Limits

### 9.1 What V1 is not

- **Not insured.** No principal protection. Losses can occur via smart contract bugs, Liqwid bad debt, USDCx depeg.
- **Not decentralized at launch.** Founder operates keeper + holds gov seats + controls deploy wallet. V1 is founder-run software released publicly, not a DAO.
- **Not yield-maximizing at all costs.** V1 declines yield farming opportunities that expose depositors to governance token volatility or bridge risk.
- **Not a substitute for financial advice.** Depositors must evaluate their own risk tolerance.

### 9.2 What V1 commits to

- **Source code public** before mainnet launch.
- **Audit reports public** as they complete.
- **Governance actions public** — every QueueAction announced within 1 hour, on-chain history is canonical.
- **Wind-down protocol public** — if any of §4.1's four sunset triggers fires (A: TVL < $500K @ 6m post-audit IF audit lands; B: operating-runway exhaustion; C: Class A override persistent; D: founder explicit decision), 90-day notice + fee-to-zero + Liqwid-positions-pre-recalled precondition apply per §4.1 sunset mechanics, plus the EmergencyWithdraw governance path + `emergency-withdraw` self-serve tool. **Hard-failure backstop**: even if both founder and any SPO co-signers are completely unreachable for 90 days, any vUSDCx holder can invoke the permissionless `CommunitySunset` redeemer (vault_user) to atomically freeze the vault and open permissionless `RecallFromLiqwid` + swap-to-USDCx paths for full self-serve depositor recovery — see §5.5.1 Layer 3 + `docs/security-model.md` §5.4 scenario E. **Note**: sustained audit-funding gap (§8.1 Option D) is NOT a sunset trigger — it keeps V1 at the pre-audit 100K cap on mainnet; the wind-down protocol does not activate in that scenario.
- **No rug-pull architecture.** Every invariant that could drain funds is closed at the validator level, not the social level.
- **Founder incapacitation protocol.** The V1 launch has the founder simultaneously serving as keeper operator, governance signer (1-of-3 under configuration (a) with SPOs / all 3 under base-case configuration (b) per §7.4), and ref-deployer-wallet controller; individual-level single-point-of-failure risk is real. Response mechanisms: (a) **Short-term absence (< 7 days)** — the 7-day keeper-inactivity window in the contract automatically activates; Direct Withdraw remains fully operational and the early-withdraw fee is waived; (b) **Medium-term incapacity (7-30 days)** — under configuration (a) the two independent SPOs can queue `UpdateKeeperAuth` (14-day timelock + 1-of-n cancel) to rotate the keeper PKH to a community successor; under configuration (b) the founder's HD-key-separated signing environments provide some redundancy, but if all are inaccessible this falls through to (c) below; (c) **Operating-subsidy cessation without formal sunset** (v1.4-era scenario under the volunteer model) — founder healthy but stops paying the ~$80/year infra subsidy without formally invoking §9.2. Outcome chain: keeper goes offline → §5.4 7-day inactivity gate auto-activates (early-withdraw fee waived) → Direct Withdraw remains operational → vault remains in "founder-keeper offline, contract alive" hybrid state until 90 days elapse → §5.5.1 Layer 3 `CommunitySunset` becomes triggerable by any vUSDCx holder for full self-serve recovery. This path is real under the v1.4 volunteer-operator model and is documented here so depositors understand recovery does not require founder cooperation; (d) **Permanent incapacity** — under (a), the two SPOs trigger the §4.1 sunset path (90-day notice + fee=0 + depositor self-serve exit); under (b), §5.5.1 Layer 3 `CommunitySunset` is the absolute backstop at 90 days. The ref-deployer wallet key is currently controlled solely by the founder; if that key is lost or inaccessible, approximately **~962 ADA** of ref-script capital + **~28 ADA** of stake-credential deposits are permanently locked (per §8.2 measured 962.07 ADA + 14 × 2 ADA) — but **this does not block depositor withdrawals**, since ref-scripts remain available as reference inputs. V2 deployment ceremony will incorporate a multi-sig ref-deployer wallet or community key-escrow mechanism to eliminate this SPOF.

### 9.3 What could still go wrong

Even after multiple rounds of internal audit has addressed the findings surfaced so far:
- **Unknown vulnerabilities** in V1-specific new scope (treasury, keeper_stake_script) could exist until external audit.
- **Novel attacks** leveraging interactions we haven't considered.
- **External protocol failures** (Liqwid, Minswap, Circle / xReserve / USDC) cascading to V1.

The 100K cap is not a suggestion — it is an acknowledgment that V1 is production software that has not yet been externally audited.

### 9.4 Known V1 limits (disclosed rather than hidden)

- **All 14 V1 staking-credential 2 ADA stake deposits are reclaimable** (canonical list in §6.2 `ActDeregisterStake`). Each carries its own A2 gov-gated `publish` handler — total **28 ADA reclaimable** via governance at sunset (14-day timelock + 1-of-n cancel). Of the 14: 10 are vault-proxy Withdraw-Zero routes per §3.2; the additional 4 — `keeper_stake_script`, `minswap_v2_adapter`, `sundaeswap_adapter`, and `sundaeswap_cancel_guard` — carry their own staking credentials for delegation independence and operate outside the vault-proxy dispatch. Earlier monolithic-validator topologies had a 2 ADA permanent-lock caveat on the largest validator due to a 16 KB ceiling collision with the `publish` handler; the partitioning documented in `spec/architecture.md §4.1` resolved this.
- **100K TVL cap is NOT enforced at the contract level** — it is operator-enforced via frontend deposit gating + keeper `tvlCapMonitor` alerts. This is a deliberate V1 design choice, not an oversight. A contract-level cap was designed (`max_tvl` datum field + `ActUpdateTvlCap` 7-day-timelock governance action, internally labelled "Option B") but not shipped for two reasons: (1) The cap exists only to signal pre-audit prudence; post-external-audit the cap is either raised unlimited or the V2 deploy removes it, making a gov-adjustable on-chain mechanism single-use lifecycle overhead. (2) At V1 launch gov runs 3-of-3 unanimity with 1 founder + 2 independent SPO signers (§5.5); while 3-of-3 blocks unilateral founder action, cap-sizing judgment is not SPOs' core domain (they are stake pool operators, not vault economic-model designers) — handing the cap to SPO-gated governance during the pre-audit phase is not a meaningful check either — so the honest label "operator-enforced" is stronger than the appearance of "contract-enforced". Depositors who want belt-and-suspenders contract-level deposit limits should wait for Phase 2 gov rotation (external signer added, §6.1) — at that point an on-chain cap would have meaningful dissent-veto semantics and V2 will reconsider.
- **Reference-script capital lockup.** V1's 20 reference-script UTXOs at the deploy wallet address (17 logic validators + `minswap_v2_adapter` + the 2 SundaeSwap artefacts) tie up ~962 ADA (Conway-era per-byte `minFeeRefScriptCostPerByte` × 1.10× operator safety multiplier — V1 Preprod measured 962.07 ADA exactly), recoverable via `deploy/tools/reclaim-refs.ts` once the operator decides to sunset the deployment. Plus 28 ADA in stake-credential deposits (14 × 2 ADA) reclaimable via A2 governance after a 14d timelock. See §8.2 for the pre-launch audit context.
- **Architectural complexity growth.** V1's first cut was 12 validators; the current topology is **24 artefacts** (17 logic validators + 4 NFT mint policies + `minswap_v2_adapter` + 2 SundaeSwap artefacts), driven by the Plutus V3 16 KB reference-script ceiling and the §5.4 P3-P5 slippage-stack additions. Each new validator added (a) an independent audit scope surface, (b) an additional compile-time anchor set, (c) an additional reference-script UTXO (~48 ADA each on average at current parameters), and (d) an additional deploy-ceremony TX. Net effect on first deploy: ref-script lockup grew from earlier estimates of ~400 ADA to actual measured 962.07 ADA (+140%), and ceremony TX count grew from ~18 to ~42 (+133%). External audit budget impact: **14 staking-credential A2 `publish` handlers must each be audited individually** (instead of the previously-locked single `vault_core` lock that was outside audit scope), so the resolution of "vault_core 2 ADA permanent lock" came at the cost of expanded audit surface. Future feature additions risk further splits — the trajectory from 12 → 24 in one V1 cycle suggests V2 may need to either (a) accept higher artefact counts as the new baseline, or (b) consolidate via on-chain dispatch tables. V1 chose (a) explicitly because the design freeze-then-audit-then-launch sequence does not allow for late re-architecture; V2 will reconsider.
- **Circle / xReserve trust chain.** USDCx's value depends on Circle's USD reserve integrity + xReserve's cross-chain bridge security. Both are publicly audited by their respective teams; V1 does not add trust assumptions on top.

These are disclosed here, not buried in the spec, because depositors deserve to know the edges of what V1 actually does vs. what any high-level summary or outward messaging might suggest.

---

## 10. Reproducibility

The canonical source of truth for V1 is the open-source mirror at https://github.com/OptiVaults/optivaults-protocol (mirror of the private development repository; the mirror is published at V1 mainnet launch per §9.2). Every validator hash published on-chain is reproducible from the source via:

```bash
aiken --version    # must match the pinned version below
aiken build        # produces plutus.json
scripts/verify-hashes.sh  # compares plutus.json hashes vs on-chain
```

**Pinned tooling versions** (mandatory for bit-identical hash reproduction — Aiken's optimizer output is version-sensitive):

| Tool | Pinned version | Why |
|------|----------------|-----|
| Aiken compiler | **v1.1.x** (exact patch version fixed at commit of final audit) | Plutus V3 cost-model shifts between patches alter exec-unit hashes |
| aiken-lang/stdlib | matching Aiken release | module namespacing changes |
| aiken-lang/fuzz | v2.2.0 | property-based test reproducibility |

The exact `aiken` patch version is committed to `.tool-versions` in the repository and re-affirmed in the audit report so any third party can reproduce the deployed hash from source at the audit commit.

Deploy scripts + runbooks in the public repo let any operator independently verify the deployed hashes match the source at the commit referenced on the website.

Every governance QueueAction's payload hash can be reverse-engineered from CBOR — depositors can verify that a queued fee change, for example, actually matches the numerical values published off-chain.

---

## 11. Related Documents

**Specs** (under `spec/`):
- `architecture.md` — **17-logic-validator catalog** with redeemer details (+ 4 one-shot NFT mint policies + `minswap_v2_adapter` + 2 SundaeSwap artefacts = 24 total artefacts); §4.1 partitioning rationale (4 orthogonal seams: authorization-boundary, response-latency, bytecode-cost-center, size-fix)
- `vault-datum.md` — VaultDatum schema (**29 fields** post §5.4 Phase 2 + Phase 1 governance safety; adds `max_slippage_bps` + `min_swap_peg_bps` + `community_sunset_triggered` on top of the prior 26-field layout), immutable vs governance-mutable vs operationally-mutable classification, per-redeemer state-transition matrix
- `governance.md` — 15 queued governance ActionKinds (full table in §6.2; includes `ActDeregisterStake` for operator-side stake-deposit recovery), plus 3 direct/non-queued redeemers (`KeeperToggleMarket`, `Heartbeat`, `DistributeSignerCompensation`); timelock floors, launch signer set + rotation roadmap
- `multisig-gov.md` — MultisigGov validator internals, action_id / payload_hash computation, `is_gov_authorized` cross-validator helper
- `gov-nft.md` — Gov Signer soul-bound NFT minting policy (reputation-only, non-transferable)
- `keeper-auth.md` — `keeper_stake_script` state machine, weekly rotation, A-Plain authorization, PermissionlessWithBond mode
- `treasury.md` — TreasuryDatum schema, 4-category budget, Receive / Spend / ReceiveGovForfeit / UpdateParams redeemers
- `order-batch.md` — OrderDatum + BatchProcess, pre-batch snapshot pricing, user-set batcher tip
- `ada-swap.md` — SwapAda redeemer (vault ADA replenishment closed loop), Charli3 + Orcfax oracle reading
- `vault-nft.md` — Vault Identity NFT PlutusV3 UTXO-ref one-shot design
- `swap-adapter.md` — SwapAdapter interface (Tier 2 peg-floor decoder, byte-for-byte order-datum validation; `minswap_v2_adapter` + the SundaeSwap adapter pair in §8; referenced by §3.4, §5.4 P4)
- `rebalance-policy.md` — Complete rebalance algorithm (slippage budgets, DEX path selection, frequency limits; canonical source for the §2.5 high-level mechanism description)

**Docs** (under `docs/`):
- `security-model.md` — adversary classes, 6-identity separation target, attack surface catalog, residual-risk summary
- `economics.md` — 3-way fee split math, TVL-tier projections, bootstrapping-phase disclosure, signer compensation mechanics
- `migration.md` — internal-verification-era → V1 user migration guide
- `audit-scope.md` — internal coverage areas A–F + external audit plan
- `integration-playbook.md` — 7-step SOP for adding new DEX routes / Liqwid markets (Type A/B/C/D)
- `contributor-program.md` — open-source contributor rewards (Phase 2+ activation)

**Other language**:
- `whitepaper/whitepaper-zh-TW.md` — 繁體中文 version

---

## 12. Disclosure

**Non-investment product / non-solicitation.** V1 is a Cardano DeFi public-goods reference implementation (see the positioning declaration in the Executive Summary); **it is not an investment product, not a fund, not a managed service**. The 4.5% performance fee covers protocol operations and treasury accumulation (audit reserve / R&D / buffer); **there is no equity, no token, no investor distribution**. **Disclosure on the keeper share**: 40% of the performance fee (~1.8% of yield) goes to the keeper wallet as operational compensation; because the founder runs the keeper at V1 launch (§7.4), **USDCx does flow to the founder's keeper wallet during Phase 1** (~$108/year at the 100K cap; <$30/year in the realistic Phase 1 sub-scenarios per §8.2). This is **below the keeper's own infra cost** even at the §4.3.1 minimal-operations footprint (~$80/year infrastructure + on-chain fees), so the keeper position is a **net cost-centre, not a profit line**, for the founder — the shortfall is absorbed from personal income on an ongoing basis (§4.3.1 cost-scaling table), not drawn from a pre-committed founding-capital reserve. The honest reading is: no equity-style profit distribution, no token, but a small USDCx receipt that does not cover its own operating costs. §0 + §0.2 + §4.3 + §4.3.1 + §7.4 document the full structure. This whitepaper is a **factual description** of V1's design and launch conditions, not investment advice or a solicitation of any kind. Smart contract deposits involve risk of total loss.

**Geographical posture.** V1 is a permissionless on-chain Cardano smart contract; technically any Cardano-wallet holder can interact with it. But V1 is designed for Cardano-native users, and **does not actively offer services to residents of any jurisdiction**. Depositors must determine on their own whether their jurisdiction (notably US, EU, UK, China, OFAC sanctions-list countries) permits use of non-custodial DeFi public-goods infrastructure; compliance responsibility rests entirely with the depositor. V1's frontend (optivaults.app) may, based on legal opinion, **display a warning or block access from specific jurisdictions**; this is a **frontend-only soft signal** and does not restrict the underlying on-chain smart contract — users who bypass the frontend and interact with the contract directly (e.g. via `withdraw-cli` or a hand-built TX) assume full jurisdictional-compliance responsibility. **The V1 contract itself does not implement address whitelisting or geographic restriction**; doing so would contradict the non-custodial + permissionless design and is not on the roadmap. Any frontend geoblock change is announced publicly (optivaults.app + Discord). If your jurisdiction explicitly prohibits use of non-custodial DeFi or unregistered financial services, **do not use V1** — even if you technically can by bypassing the frontend.

**Code-is-law posture.** V1 is open source / Apache 2.0 / post-deploy validator hashes are immutable. Depositors, upon deposit, accept that "the contract executes on-chain in the form it was deployed" — no individual, team, or governance action can modify the contract logic itself (governance can only adjust within ranges the contract authorises). If a contract bug causes loss, the self-serve `emergency-withdraw` tool is the only recovery path; **no legal recourse can reverse a confirmed on-chain transaction**. This is not a bug — it is V1's core design choice. The price of not having your funds under an intermediary's control is that the intermediary cannot recover accidents for you.

**Depositor due diligence.** Depositors must conduct their own due diligence on OptiVaults V1, USDCx (Circle / xReserve), Liqwid, Minswap V2, and Cardano itself. **Any expectation that "V1 manages risk for me" is a misreading of the positioning** — V1 exposes, diversifies, and architects the risks such that you can always exit (see §5 Risks for full disclosure + §6.3 governance hard caps); it does not insulate you from them. V1 is not insurance, not an advisory service, not a wealth manager.

**Contact.** Security disclosures (PGP key at optivaults.app/security), migration subsidy claims, and general inquiries: `optivaults@gmail.com`. Live discussion: Discord (link at optivaults.app).

---

## Changelog

### v1.4.2 — 2026-05-14

**Added**
- §5.1.1 Adversarial chain-replay coverage — new subsection categorising the defense layers exercised by hand-crafted attack transactions against a Preprod ceremony build. Nine semantic categories (vault primary spend / user-path / keeper-path / protocol-routing / mint policies / order branch / multisig governance / emergency-fee governance / CIP-69 purpose isolation) plus a source-review note on the share-price invariant. Includes explicit "what chain replay does NOT cover" caveats (external-system failure modes, keeper-key compromise scenarios, build-specific state assumptions) and discloses one category deferred to a fresh Preprod ceremony (UpdateRegistry-injected fake Liqwid `action_addr_hash` — already covered by Aiken unit tests in `lib/vault/tests/`).

**Tone**
- §5.1.1 frames the methodology as complementary to unit + property tests + external audit, not as a replacement; emphasises that the primary security signal remains the upcoming external audit report. No quantitative "X tests passed" claim; the section instead categorises the defense layers and points readers to `tests/preprod/` regression scripts for reproduction.

### v1.4.1 — 2026-05-12

Internal-consistency pass over v1.4. No structural framework change — v1.4's volunteer-builder + audit-as-cap-lift-gate model remains as published; this revision sweeps residual v1.3-era phrasing that survived the v1.4 rewrite in three sections (§4.1 / §1.6.1 / §7.4) and tightens cross-section alignment.

**Aligned to volunteer-builder funding model**
- §4.1 — removed "18-month runway covers development + audit + 6-month post-audit ramp" framing across five paragraphs (Phase-1 expectation reset, sensitivity-table closing, $25K–$500K gap discussion, Executive Summary keeper-share disclosure, §12 Disclosure keeper-share). All five now describe operating shortfall as founder personal-income subsidy per §4.3.1, not draw-down on a pre-committed runway sized to include audit.
- §4.3 + §5.4 — corresponding "audit cost flows through §8.1 funding stack, not founder runway" alignment.
- §1.6.1 — removed "not 'launch first, audit later'" framing, which contradicted §0 + §1.5 + §8.1's new "pre-audit mainnet launch + audit-gated cap-lift" structure. Cross-references §0.2 + §8.1.

**Executive Summary alignment**
- §7.4 — opens with base-case configuration (b) (founder operates keeper + holds all 3 governance signer seats with HD-key separation), then describes configuration (a) (founder + 2 independent SPOs) as the stretch target. Order matches Executive Summary's "depositors should assume configuration (b) at launch" framing.
- §8.1 Option D — new depositor-facing risk disclosure for sustained Option D operation (permanent unaudited mainnet at 100K cap): (a) permanent unaudited status implications, (b) elevated founder-incapacitation risk under indefinite single-operator configuration, (c) external-audit-signalling absence as a real informational asymmetry, (d) explicit framing as "long-duration acceptance of pre-audit risk profile" rather than "waiting for audit".

**Cross-references**
- §4.5 — opening scope note pointing low-TVL readers to §4.3.1: "§4.5 covers post-cap-lift Default-cadence cost profile; for Phase 1 sub-scenario costs ($500–$25K TVL under §2.6.1), see §4.3.1."
- §9.2 — new scenario (c) operating-subsidy cessation: founder healthy but ceases the ~$80/year operating subsidy without formally invoking §9.2 sunset. Full recovery path documented (§5.4 7-day gate → Direct Withdraw remains → §5.5.1 Layer 3 at 90 days).
- §5.5.1 "What this means in practice" — cross-references the subsidy-cessation scenario as an intermediate layer between "key compromised" and "incapacitated 90+ days".
- §8.1 (a) — funding-source paragraph now describes Catalyst + Cardano Foundation + Intersect Member Committee + Aiken Foundation as four parallel grant channels, matching the funding-stack table's "$80–150K combined" figure.
- §0 Phase 2 + §9.2 founder-incapacitation block — governance signer phrasing made conditional on (a)/(b) configuration.

### v1.4 — 2026-05-12

**Added**
- §0.1 — explicit disclosure of the relationship between the existing internal-verification-era mainnet deployment (founder-allowlist-gated, no third-party deposits, pre-V1 contract iteration) and the V1 design described in this whitepaper. Includes the planned unwind sequence (ActDeregisterStake × 4 staking-cred queue → full vault drain → ref-script reclaim) before V1 mainnet ceremony.
- §0.2 — funding posture declaration: V1 is volunteer-built with capped founder commitment (~$2K seed + ~$80–$200/year operating subsidy + ~$15K audit gap-fill cap). External audit is funded through the §8.1 four-source stack, not founder underwriting.
- §4.3.1 — post-launch minimal-operations policy: ~$80/year operating budget at $500–$25K TVL under §2.6.1, TVL-scaling cost table, single-server-until-$50K HA upgrade threshold. Operating shortfall absorbed from founder personal income, not from a pre-committed founding-capital reserve.
- §1.4 — Lenfi statement enriched with citation pointer (Lenfi official December 2024 post-incident disclosure + DefiLlama protocol TVL history) and caveat that figures are external public-data snapshots subject to change.

**Replaced**
- Executive Summary governance line — two configurations under the same contract guarantees now presented as parallel branches: (a) 3-of-3 with independent SPOs (stretch target, conditional on recruitment) and (b) founder-controlled with HD-key separation (base case at Phase 1 small-TVL per §7.4). Depositors should assume (b) at launch given §8.2's $500–$25K Phase 1 TVL range. Depositor recovery does not depend on which configuration is active — it depends on §5.5.1's three contract-level safety layers.
- §1.5 Override conditions split into Class A (blocks launch — external infrastructure failures: Liqwid / USDCx / Cardano chain / oracle incidents) and Class B (holds cap at 100K — audit not passed or audit funding not landed). V1 launches on mainnet pre-audit under the existing 100K cap; Class B only gates Stage 2+ progression.
- §1.5 Override condition 3 — "USDCx issuer (Circle, via the xReserve smart contract and its Cardano-side integration deployed by IOG)", separating Circle (issuer) from IOG (Cardano-side integrator).
- §4.1 sunset trigger restructured into 4 explicit conditional triggers: Trigger A (post-audit TVL < $500K, conditional on audit happening), Trigger B (operating runway exhaustion, structurally unreachable under §4.3.1), Trigger C (Class A override persistent), Trigger D (founder explicit decision). Audit-funding failure is NOT a sunset trigger — it keeps V1 at the 100K cap on mainnet under §8.1 Option D.
- §4.5 weekly-tier paragraph — the lower Compound tiers are documented as keeper's live policy for any period the vault spends under $1,200 USDCx (notably Phase 1 small-TVL sub-scenarios and §2.6.1 Reference Implementation Mode), not "legacy scheduling branches".
- §6.2 governance action list — converted to a sorted table (Min Timelock | ActionKind | Category) with the three direct / non-queued redeemers (KeeperToggleMarket, Heartbeat, DistributeSignerCompensation) flagged separately.
- §8.1 funding stack — (d) Founder commitment now capped at ~$15K gap-fill, not underwriter. Worst-case is no longer "founder pays $100–$150K" but "Options A–D cap-lift contingency tree activates": A (audit timeline extension), B (scope-reduced audit), C (community / DAO crowdfund), D (permanent pre-audit 100K cap on mainnet). All four options keep V1 live on mainnet; they only determine the cap-lift pathway.
- §8.1 pre-launch gates split into two checklists: (i) "Required for mainnet launch under 100K pre-audit cap" (internal audit + Preprod E2E + dry-run + Class A overrides clear + axis One-Yellow) and (ii) "Required for cap lift toward Stage 3" (external audit complete + findings resolved + axis All-Green). External audit moved from launch-gate to cap-lift-gate.

**Phasing**
- §0 — 3-phase model expanded to 4 phases: Phase 1 (Pre-Catalyst, Preprod only), Phase 2 (Pre-Audit Mainnet at Stages 1 / 1.5 / 2 with $10K → $100K cap), Phase 3 (Audit + Cap-Lift Window, parallel to Phase 2), Phase 4 (Operational, Stage 3+ post-audit).
- §1.5 Stage matrix — added "Audit required?" column making clear that Stages 1 / 1.5 / 2 are pre-audit and Stage 3 is post-audit. Stages are not time-gated; they progress as axis state and audit outcome warrant.

**Modified**
- §5 + §9.2 — verbatim 14-name lists of staking credentials consolidated to cross-reference §6.2 ActDeregisterStake's canonical list. Numeric "28 ADA / 14 × 2 ADA each" disclosure preserved at the four locations where it carries load-bearing context (§8.2 ref-script lockup, §9 founder-incapacitation, §9.2 sunset, §9.4 honest-limits).
- §1.6 — origin-story closing sentence reworded to remove repetition vs the Executive Summary.
- §0.1 disposition paragraph — "V1 mainnet ceremony" specified as "V1 pre-audit mainnet launch ceremony (Phase 2 entry per §0; Stage 1 / 1.5 / 2 launch per §1.5)" so the ceremony framing is unambiguous about pre-audit timing.
- §9.2 wind-down protocol bullet — explicitly lists all 4 sunset triggers (with A noted as audit-conditional) and adds a footer note that sustained audit-funding gap (Option D) is NOT a sunset trigger.

**Tone**
- "V1 will launch on mainnet pre-audit at 100K USDCx hard cap with prominent risk disclosure" replaces v1.3-era "100K cap until audit completes" implying audit will complete.
- All "lower Compound tiers = recovery only" framing removed; lower tiers now documented as keeper's live policy at the corresponding TVL band.

### v1.3 — 2026-05-11

**Added**
- §1.2 — timestamped issuance-status snapshot of USDCx + xReserve + Liqwid USDCx market as of v1.3 publication, with re-evaluation path via `UpdateRegistry` if state regresses.
- §2.6.1 Reference Implementation Mode — operational mode for sustained low-TVL (<$25K) periods; relaxed Compound + heartbeat cadence preserving all contract invariants while reducing operational cost ~85–90%. Activated by keeper under §4.5 economic-rationality discretion, not by governance action.
- §5.5.1 — explicit treatment of the "heartbeat-only keeper" sabotage scenario, design rationale for `max(last_compound_time, last_realloc_time)` Layer 3 trigger semantics, alignment with §2.6.1 legitimate use cases.
- §8.1 — four-source funding-stack distribution with explicit best / middle / worst cases; four contingency options for funding-stack underperformance (timeline extension / scope reduction / indefinite deferral / §0-framed sunset) with monthly public-dashboard tracking commitment.
- §8.2 — sub-scenario × operational-mode mapping table linking Phase 1 sub-scenarios (a) / (b) / (c) to operational modes, SPO governance posture, and external framing.
- §4.1 — Reference Implementation Mode threshold column showing self-sustaining TVL drops from $500K to ~$56K under §2.6.1, supporting sub-scenario (b) viability.
- §7.4 — Phase 1 small-TVL governance posture paragraph documenting the de facto solo-signer contingency when launch lands in (a) / (b) sub-scenarios.

**Replaced**
- §1.3.1 + §4.4 — break-even analysis unified to a single two-component framing (time cost + risk-management premium → practical break-even $25–$40K). §1.3.1 carries the canonical break-even table; §4.4 references it instead of duplicating.

**Modified**
- §2.6 — removed "lower tiers exist only for V2 migration recovery" framing; the full tier table is now documented as keeper's live policy, with §2.6.1 covering the low-TVL operational mode explicitly.
- §5.5 — SPO recruitment phasing tied to TVL sub-scenarios, with explicit framing of governance-load expectations during pre-launch + Phase 1 small-TVL. SPO commitment honoured as community service if V1 stays in terminal Phase 1 state.

**Disclosure adjustments**
- §0 + §12 — clarified that "no revenue to founder / investors" applies to equity / token distributions only. The 40% keeper share is a USDCx receipt line to the founder during Phase 1 as operational compensation, but stays below keeper infrastructure cost, so the keeper position is a net cost-centre even for the founder.
- §0 Pre-Catalyst Phase — explicit disclosure of the internal-verification-era mainnet deployment with founder-gated access, separate from the V1 design.
- §6.1 — section title amended to "Six-identity separation target (NOT achieved at launch — disclosed honestly)" with body text stating the launch state clearly.
- §1.5 Stage matrix — Stage 1 renamed to "Limited Pilot (permissionless, with prominent pre-audit risk warnings; no invitation gate, no whitelist)" matching §8.2's removal of closed-beta framing.
- §8.1 — candidate audit-firm short-list adjusted to Anastasia Labs, MLabs, TxPipe + independent Aiken auditors (publicly verifiable Cardano-Aiken practice).
- §4.1 — added paragraph clarifying that §2.6.1's $56K self-sustain figure does not alter the §4.1 / §9.2 $500K post-audit sunset trigger; the two numbers measure different operational regimes.

**Tone**
- Reinforces v1.2's "public-goods reference implementation" positioning with operational counterparts (§2.6.1, §5.5, §8.1 sunset option).
- $500–$5K TVL personal-reference sub-scenario explicitly acknowledged as a legitimate Phase 1 endpoint.

### v1.2 — 2026-05-08

**Added**
- §5.2.1 Cardano Ecosystem Evolution Scenarios — five conditional sensitivities (Pogun BTC DeFi rollout, Leios scaling, Midnight DeFi Kernel maturation, USDCx subsidy expiry, NIGHT solar drop release schedule) explicitly framed as external assumptions, not predictions or commitments. Closes the §5 Risk Framework gap where prior versions discussed external triggers in §1.5 Launch Readiness Framework but did not document how V1's risk profile evolves as those triggers fire.

**Tone shift**
- Reinforces "V1 is a Cardano DeFi public-goods reference implementation, not a commitment to ship in 2028" framing — V1 keeps shipping under current posture regardless of which evolution scenarios materialize.

### v1.1 — 2026-05-06

**Added**
- §0 Project Philosophy & Phasing — pre-launch posture as Cardano DeFi public-goods reference implementation, trigger-based not calendar-based launch.
- §1.4 Cardano Stablecoin Lending Reality — single mature lending venue acknowledgment (Liqwid only at scale; Lenfi/Levvy/FluidTokens situation), oracle concentration disclosure. Existing "Adjacent Cardano products" table preserved as final subsection.
- §1.5 Launch Readiness Framework — three-axis trigger system (Pogun BTC TVL, USDCx circulating supply, Liqwid blended APY) with 5-stage TVL cap matrix, override conditions, reversal conditions, public dashboard binding, 2027 Q4 maximum deferral.
- §1.7 Future Product Roadmap — V1.5 fixed-rate vault, V2.0 multi-protocol, V2.x Pogun BTC routing, V3.0 Midnight privacy vault. Each with explicit external trigger conditions.
- §2.5 Strategy Weight Sensitivity — adjustable weight bounds (DJED 30-55%, USDM 15-35%, USDCx 0-30%, buffer min 10-30%) with raise/lower conditions, governance 7d timelock for raises, automatic Keeper-triggered lowering for stress signals.

**Replaced**
- §2.3 Yield Sources and Fee Definition — precise performance fee formula `fee = 4.5% × max(0, NAV_now - NAV_last_compound - slippage)` with explicit "no high-water mark" + "negative periods generate zero fee" properties; LQ liquidity-mining clarification; idle buffer drag quantified at 30% × 1.5% = 45 bps relative to Liqwid USDCx supply alternative; rebalancing trigger conditions; spec/rebalance-policy.md cross-reference.
- §1.6.3 V2 Multi-Protocol Aggregator Conditions (formerly §1.5.3) — replaced narrative "design direction" framing with 5 explicit external conditions (second mature lending venue 12-month track record, audit parity, V1 maturity 12 months + $500K TVL, treasury reserve 6-month runway). Current status: 0/5 met.
- §4.4 Honest Comparison (formerly "Who V1 is for") — explicit yield decomposition table; corrected buffer drag math (45 bps not 270 bps); two-component break-even framing (pure time cost ~$5K + risk-management premium $25-35K = practical $25-40K); forward reference to V1.5 fixed-rate vault.

**Renumbered (numbering cascade)**
- Existing §1.5 (founder origin) → §1.6
- §1.5.1 (user protections) → §1.6.1
- §1.5.2 (why Cardano, why now) → §1.6.2
- §1.5.3 (V1 today, V2 as direction) → §1.6.3 (content also replaced as above)
- §2.5 (Compound cadence) → §2.6
- All cross-references updated.

**Tone shifts**
- From "we designed a conservative product" to "we build on Cardano DeFi phase realities".
- From timeline-based pre-audit framing to trigger-based launch framework.
- From single break-even number ($40K) to two-component framing (time cost + risk-management premium).

### v1.0 — 2026-04-21

Initial release. Production-ready V1 design specification. Single-protocol Liqwid wrapper, three-stablecoin allocation (45/25/30), 4.5% performance fee, 0.1% early-withdraw fee, 100K USDCx pre-audit TVL cap, 3-of-3 governance multisig, Withdraw-Zero forwarding pattern, compile-time Vault NFT anchor, hacker-mindset adversarial audit.

---

**End of Whitepaper V1.4.2**
