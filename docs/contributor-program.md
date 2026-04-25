# OptiVaults V1 — Open-Source Contributor Program

**Scope**: how contributors to OptiVaults' open-source codebase are recognized and rewarded. Covers V1's current (informal) posture and the roadmap to formal activation at Phase 2.

---

## 1. Current posture (V1 launch through Phase 1)

**The contributor reward program is NOT formally active at V1 launch.**

Treasury R&D category inflow at the pre-audit 100K TVL cap is approximately US$43/year — insufficient to fund a structured bounty program. Contributors during Phase 1 receive:

- **Public acknowledgment**: in repo commit logs, release notes, and (for substantial contributions) a public callout in the Discord `#contributions` channel
- **Contributor NFT** (Phase 2 onwards, not active at launch): see §3 below
- **Future retroactive recognition**: if the project reaches TVL scales where the program formally activates, past contributors are eligible for retroactive recognition via the mechanisms in §2 below

This is honest. At 100K TVL, V1 is in a bootstrapping phase; there is no budget for cash rewards. Contributions are made for the project's success, not for compensation. V1 makes no claim otherwise.

---

## 2. Phase 2 activation (target: TVL ≥ 500K or treasury R&D ≥ US$500)

When Treasury R&D category balance reaches approximately US$500 (typically around 500K TVL), the structured program activates with four mechanisms:

### Mechanism A: Task-based bounties

**How it works:**
1. Before work begins, governance (via `QueueAction` → `TreasurySpend`) earmarks a bounty for a specific task (e.g., "Implement Splash V2 integration — US$500 bounty")
2. The task is posted publicly on GitHub + Discord
3. Contributors submit pull requests
4. Keeper operator + at least one additional reviewer approve the PR on technical merit
5. Governance executes `TreasurySpend` to the contributor's Cardano wallet

**Bounty sizing** (illustrative, governance sets per-task):
| Task type | Typical bounty |
|-----------|---------------|
| Small bug fix (< 4 hours effort) | US$25–75 |
| Small feature (4–20 hours) | US$100–500 |
| Integration — Type A Liqwid market | US$300–750 |
| Integration — Type B DEX route | US$1,000–3,000 |
| Security disclosure (coordinated, HIGH severity) | US$500–5,000 (see `docs/audit-scope.md`) |
| Integration — Type C new protocol | US$3,000–10,000 |

**Governance timelock**: bounty `QueueAction` carries a 7-day timelock (same as other `TreasurySpend` actions). Cancel veto applies.

**Anti-rug provisions:**
- Bounty is **not** paid before PR is merged
- Work done before bounty is announced is not automatically eligible (but governance may retroactively fund via Mechanism B)

### Mechanism B: Retroactive recognition

**How it works:**
1. Each quarter, governance reviews the open-source contribution log
2. Identifies contributions that added lasting value but were not pre-bountied
3. Proposes retroactive `TreasurySpend` to contributors, sized per judgment
4. Contributors may also nominate themselves via GitHub issue

**Typical retroactive amounts**: US$50–500 per recognized contribution.

**Purpose**: acknowledges the reality that open-source contributions are sometimes unpredictable — a contributor may write something the project didn't know it needed. Pure pre-bounty programs miss this.

### Mechanism C: Contributor NFT (soul-bound)

A soul-bound NFT similar in spirit to the Gov Signer NFT (`spec/gov-nft.md`). Details:

```
policy: OptiVaultsContributorNFT (one-shot per generation)
tokens:
  Gen1-<contributor_label>  × 1  → recognized contributor
  Gen2-<contributor_label>  × 1
  ...
```

**Properties:**
- Non-transferable (soul-bound)
- No financial or voting rights
- Visible in Cardano wallets as a "collectible"
- Minted by governance upon recognition, attached to contributor's wallet
- Burned if the contribution is later proven to be malicious (extremely rare, safety valve)

**Minting criteria**: at governance discretion; typically awarded after a contributor has passed three distinct merged PRs or completed one significant bounty.

### Mechanism D: Retroactive Public Goods Funding (Phase 4+ when TVL ≥ 10M)

At larger scale, V1 may adopt a quarterly RetroPGF-style funding round (inspired by Optimism's model):

- Governance earmarks a quarterly R&D budget (e.g., US$2,000)
- Community submits contributions / nominations
- Governance signers rank contributions and allocate funds
- Published rankings + rationale

This is aspirational. V1 does not commit to RetroPGF at launch. Its feasibility depends on TVL growth and community size.

---

## 3. Contributor roles

The program recognizes these categories of contribution:

| Role | Target repo | What they do | Typical reward mechanism |
|------|-------------|-------------|--------------------------|
| **Integration contributor** | `optivaults-protocol` (new DEX adapter / Liqwid market entry) + `optivaults-reference` (keeper support) | Implements new DEX routes, Liqwid markets, other protocol integrations | Mechanism A (pre-bountied) |
| **Keeper engineer** | `optivaults-reference` | Improves keeper reliability, monitoring, recovery tools | Mechanism A + B |
| **Frontend contributor** | `optivaults-reference` | React UI improvements, i18n, UX polish | Mechanism B (retroactive) |
| **Security researcher** | `optivaults-protocol` (validator / deploy) OR `optivaults-reference` (operator) — see each repo's `SECURITY.md` for scope | Discloses vulnerabilities via coordinated process | Mechanism A (bounty per `docs/audit-scope.md` tiers) |
| **Documentation contributor** | `optivaults-protocol` (spec / whitepaper / docs) OR `optivaults-reference` (operator docs) | Whitepaper updates, guides, translations | Mechanism B |
| **Auditor (formal engagement)** | `optivaults-protocol` (primary, external audit target) + `optivaults-reference` (separate track) | Third-party security audit | Funded from Treasury audit reserve, not R&D |
| **Tool developer** | `optivaults-reference` (primarily) — depends on tool purpose | CLI improvements, monitoring bots, block-explorer dashboards | Mechanism A + B |

Every role may receive a Contributor NFT (Mechanism C) in addition to cash compensation.

---

## 4. Eligibility rules

### 4.1 What qualifies

- Merged pull request to any official OptiVaults GitHub repo
- Accepted issue / writeup / disclosure
- Completed bounty task
- Substantial Discord / community support (e.g., helping users, writing guides — governance discretion)

### 4.2 What does not qualify

- Forked code (contributions must upstream back to the official repo)
- Plagiarized work
- Work that violates the contribution guidelines (e.g., introduces a license conflict, contains secrets)
- Contributions for which the contributor has a conflict of interest unless disclosed (e.g., affiliated with a DEX V1 is integrating)

### 4.3 Multi-party contributions

If multiple people contribute to a single work (e.g., two people co-author an integration):
- Bounty is split by explicit agreement in the PR description
- If no agreement specified, governance decides on proportional split based on contribution weight

---

## 5. Budget availability

Integration and reward budgets scale with TVL (reproduced from `docs/economics.md` §7C):

| TVL | R&D category annual inflow | Practical reward capacity |
|-----|----------------------------|---------------------------|
| 100K (launch) | ~$43/year | No structured program — acknowledgment only |
| 500K | ~$216/year | 1 small bounty per year |
| 1M | ~$432/year | 2–3 small bounties per year |
| 5M | ~$2,160/year | 4–6 bounties + 1 major integration per year |
| 10M | ~$4,320/year | Full program including RetroPGF-style quarterly rounds |
| 50M+ | ~$21,600/year | Mature program competitive with other Cardano DeFi treasuries |

Each year's program budget is set by governance based on prior-year R&D balance and anticipated integration roadmap.

---

## 6. Governance interaction

All structured rewards flow through governance `TreasurySpend`:

- Proposals: any contributor or community member may propose a bounty or retroactive payment
- Review: governance signers evaluate the proposal's merit
- Queue: 7-day timelock per `TreasurySpend` action
- Cancel: 1-of-n signer veto during timelock
- Execute: governance signs off after timelock

This keeps the contributor program on the public audit trail (every payout is an on-chain TX) and prevents any single party from controlling the reward stream.

**Conflict of interest rule**: a governance signer who is also the contributor for a specific bounty must recuse themselves from the signature. The recusal is publicly documented.

---

## 7. Relationship to security disclosure

Security disclosures are **not** handled through this contributor
program. V1's responsible disclosure posture is a **Responsible
Disclosure Policy + ex gratia recognition** framework — described in
`docs/audit-scope.md` §6. Ex gratia appreciation payments for valid
disclosures are funded from founder founding capital, not from
Treasury audit reserve (Phase 1 treasury accrual at $500–$25K TVL is
too slow to offer a predictable source).

This document (§3 Mechanism A table row for "Security researcher") is
a cross-reference to that policy, not a separate bounty scheme.

A structured bounty tier program is a post-external-audit + post-TVL-
scale consideration (preconditions in `docs/audit-scope.md §6.3`),
**not** a V1 launch commitment. When and if such a program is
introduced, it will:
- Fund from Treasury `audit_reserve` accrual (which by then will be
  large enough to support market-competitive payouts without drawing
  on founder capital).
- Pass a governance-ratified `UpdateTreasuryParams` that authorises
  the audit-reserve outflow backing it.
- Use a documented tier structure reviewed and approved by V1's then-
  active governance signer set.
- Vulnerability disclosure requires tighter coordination (NDA windows, responsible disclosure) than generic contributor work

---

## 8. Public-goods stance

OptiVaults is a **public-goods protocol**: its source code, audit reports, whitepaper, and operational runbooks are all public. Contributions to this public artifact strengthen not only the protocol but the broader Cardano DeFi ecosystem.

The contributor program's purpose is to align individual contributors' incentives with public-goods outcomes, without creating a financial speculation layer on top of the protocol. The Contributor NFT is non-transferable specifically to avoid this — reputation and recognition are the long-term reward, with cash bounties as short-term motivation.

---

## 9. Timeline

| Milestone | Trigger | Action |
|-----------|---------|--------|
| V1 launch | TVL at 100K cap, pre-audit | No program; informal acknowledgment only |
| Phase 2 activation | Treasury R&D ≥ US$500 OR TVL ≥ 500K | Task-based bounties (Mechanism A) + Retroactive (Mechanism B) + Contributor NFT (Mechanism C) formal |
| Phase 3 maturity | Treasury R&D balance ≥ US$2,000 stable | First RetroPGF-style quarterly round (Mechanism D) |
| Phase 4 (mature) | TVL ≥ 10M | Program is competitive with other Cardano DeFi protocols; expect dozens of bounty-eligible contributors |

Specific dates are announced 14 days ahead of activation via Discord and governance action.

---

## 10. How to contribute today (V1 launch)

Before the formal program activates:

1. **Read** the V1 documentation in this repository (this is a good start)
2. **Pick** an issue labeled `good-first-issue` on GitHub, or propose one
3. **Discuss** in the Discord `#contributions` channel before investing significant effort
4. **Submit** a pull request following the style guidelines (`CONTRIBUTING.md` at repo root)
5. **Expect**: acknowledgment in merge commit + Discord announcement. Cash reward is not available yet; know this going in.

**If your contribution is significant** (substantial new feature, security research, full protocol integration), your name goes on the retroactive recognition list for Phase 2 activation. Governance has stated publicly that founding-era contributors are eligible for retroactive bounties once the program activates.

---

## 11. See also

- `docs/economics.md` §7C — R&D budget math and TVL projections
- `docs/audit-scope.md` §6 — Responsible Disclosure Policy + ex gratia recognition framework for security disclosures
- `spec/gov-nft.md` — soul-bound NFT mechanism that inspires the Contributor NFT design
- `spec/governance.md` §4.10 TreasurySpend — on-chain authorization for bounty payouts
- `spec/treasury.md` §3.4 UpdateParams — how governance can adjust R&D allocation over time
- `docs/integration-playbook.md` — process for proposing and completing integration bounties
