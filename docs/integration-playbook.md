# OptiVaults V1 — Integration Playbook

**Scope**: the operational process for adding new DEX routes, new lending markets, and new protocol integrations to V1 without compromising safety.

This document is the canonical SOP that operators and governance signers must follow before proposing a `UpdateRegistry` or keeper-code change that adds a new external protocol. It exists because integration mistakes are the leading cause of preventable fund loss in Cardano DeFi — not smart-contract bugs, not market events, but skipping validation steps.

---

## 1. Historical context

V1 inherits lessons from integration failures encountered in the pre-V1 internal-verification phase. Representative losses (all preventable by following this playbook):

| Date | Cause | Loss |
|------|-------|------|
| 2026-03-29 | CSWAP cancel redeemer pattern not reverse-engineered before mainnet submit | ~102 ADA |
| 2026-03-31 | CSWAP datum format assumed rather than verified | ~9 ADA |
| 2026-03-31 | Minswap V2 order submitted when batcher was inactive; cancel path untested | ~20 USDCx + 8 ADA |
| 2026-03-31 | `StakeCredential` encoded as `Constr(0, [])` instead of `Constr(1, [])` — validator crashed, cancel impossible | ~11 USDCx + 12 ADA |
| 2026-04-03 | Non-idempotent debug script double-sent ADA to vault; permanently locked | 10 ADA |

**Total preventable loss: on the order of US$270 across the V1 development phase.** None were smart-contract exploits. All were integration SOP failures. This playbook exists so V1 depositors do not bear the cost of re-learning these lessons.

---

## 2. Integration types

| Type | Examples | Typical scope | Governance path |
|------|----------|---------------|-----------------|
| **A. New Liqwid market** | Adding a new stable-coin market (e.g., USDA, a hypothetical USDE) | Registry `liqwid_markets` entry; keeper Supply/Recall builder extension | `UpdateRegistry` (14-day timelock) |
| **B. New DEX route** | Splash, new Minswap pool shard, a new DEX protocol | Registry `protocol_hashes` entry; keeper swap builder; new DEX order/cancel TX builders | `UpdateRegistry` (14-day timelock) |
| **C. New lending protocol** | Entirely new protocol like Aada, Lenfi | Potentially new vault validator logic; significant audit scope | V2 redeploy (full migration cycle) |
| **D. Protocol migration** | Liqwid pool-shard `action_addr_hash` rotation after maintenance | Registry field update only | `FastUpdateMarkets` (1-hour timelock) |

Cost and audit surface grow roughly linearly from A to C. Type D is operational (governance tooling already exists for rapid response).

---

## 3. Seven-step integration SOP

Every integration proposal must pass **all seven steps** before going to governance for `UpdateRegistry`. Skipping any step voids the proposal.

### Step 1 — Identify

**Inputs:** APY scan, community discussion, protocol announcement, operator observation.

**Outputs:**
- Brief integration summary (protocol name, why it's worth adding, expected TVL impact, risk class A/B/C/D)
- Public announcement in Discord at the `#integration-proposals` channel (or equivalent)
- Feasibility is reviewed openly for 7 days before moving to Step 2

**Not allowed:** private proposals that skip community visibility.

### Step 2 — Feasibility analysis

**Outputs** (must be documented in a GitHub issue):

1. **Is the protocol live?** Must have been on mainnet for ≥ 90 days with no exploit history.
2. **Does it have active usage?** Batcher / keeper / sequencer must have submitted ≥ 50 successful TXs in the last 30 days. Inactive protocols block user funds in unexpected ways.
3. **Is the source code public?** If the validator source is not public, the audit scope grows substantially. V1 prefers integrating with open-source Cardano protocols.
4. **Is there a cancel / refund path for user-submitted orders?** Verified from at least 3 real on-chain cancel TXs. If no cancel path, V1 **refuses** to integrate — user funds must never be uncancellable.
5. **What is the realistic downside?** Worst-case loss if the protocol mis-behaves (e.g., batcher routes to wrong address): quantify this against V1's 100K TVL cap.

**Exit gate:** all five answered, with sources cited.

### Step 3 — Reverse-engineer from real mainnet activity

**Outputs:**

1. Five to ten real mainnet TXs of the intended operation (Deposit/Swap/Supply/Withdraw/Cancel). Decoded CBOR for each, stored in `v1/contracts/integrations/<protocol>/traces/`.
2. Datum schema — byte-level precise — derived from the traces. No guessing. If three independent TXs agree, the schema is "locked"; if they disagree, investigate before proceeding.
3. Redeemer schema — including the **cancel** and **expire** redeemers. These are often different from the main execution redeemer and are easy to overlook.
4. Stake credential encoding — `Constr(0, [...])` vs `Constr(1, [...])` — verified from real TXs, not assumed. (This is the 2026-03-31 lesson.)
5. Reference-input dependencies — which UTXOs must be present as references, what their datum contents must be.

**Exit gate:** the GitHub issue includes the decoded CBOR, schema, and at least one peer reviewer's sign-off on the reverse-engineering.

### Step 4 — Implement on Preprod

**Outputs:**

1. Keeper code implementing the new builder (e.g., `optivaults/optivaults-vps/keeper/src/engines/newProtocolEngine.ts`).
2. Preprod end-to-end test on the Preprod deployment with a tiny amount (e.g., 1 test USDCx).
3. **Cancel / refund test specifically**: submit an order, then cancel it. Verify the user's funds return cleanly. This is the single most important pre-mainnet check.
4. Preprod TX log attached to the GitHub issue.

**Exit gate:** both the main-path TX and the cancel TX succeed on Preprod. Without both, do not proceed.

### Step 5 — Governance proposal

**Outputs:**

1. `opti-gov queue --action update-registry --target <target_hash> --timelock 14d` proposing the registry changes (new `liqwid_markets` entry or `protocol_hashes` entry).
2. Proposal description published on GitHub with:
   - Integration type (A/B/C/D)
   - Summary of Steps 1–4 outputs
   - Risk assessment (worst-case loss, mitigation)
3. Governance signers review for 14 days. During this window, 1-of-n cancel is available.
4. `opti-gov execute --index <n>` after the timelock expires (if no cancel).

**For Type D migrations (1-hour timelock)**: `FastUpdateMarkets` action may be used. The 1-hour window is sufficient for emergency pool-shard rotation but does not preclude community monitoring.

### Step 6 — Mainnet smoke test

**Outputs:**

1. Smallest permitted amount (usually 5 ADA or the protocol's minimum order size) submitted on mainnet.
2. Verify the TX confirms on-chain, the main-path operation succeeds.
3. Verify the cancel path works with a small test order (if applicable to the operation).
4. Smoke test log attached to the GitHub issue.

**Exit gate:** smoke TX confirmed AND cancel verified. Do not enable the new route in production keeper config until both are confirmed.

### Step 7 — Production enablement

**Outputs:**

1. Keeper configuration updated to include the new route / market.
2. Monitoring + Discord alerts configured for the new operation.
3. Post-launch review scheduled 7 days later: check TVL impact, any anomalies, user feedback.
4. Documentation updated: `optivaults/frontend/FAQ.md`, `optivaults/whitepaper.md` §3 (integrations list), `optivaults-vps/README.md` (keeper capabilities).

**Exit gate:** production enabled, monitoring green, no anomalies after 24 hours.

---

## 4. Six non-negotiable safety rules

Every step-3 through step-7 action must comply with **all six** of these rules. Rule violation voids the integration:

### Rule 1. A real user must have completed the operation on the protocol's official frontend first.

V1 does not integrate with protocols whose main flows are untested in the wild. If no user has successfully used the protocol's Deposit / Swap / Supply flow on mainnet, V1 is not the first integrator. We learn from others' production experience, not discover bugs on depositor funds.

### Rule 2. Datum format must be reverse-engineered from ≥ 3 real mainnet TXs.

Assumption is banned. If the protocol publishes schema documentation but three on-chain TXs show it's wrong, trust the chain, not the docs.

### Rule 3. Redeemer format must be reverse-engineered from both fill AND cancel TXs.

Missing the cancel redeemer pattern costs funds when a user needs to abort. Document both paths before integrating.

### Rule 4. The cancel / refund path must be Preprod-tested end-to-end.

Preprod cancel success is the gate for mainnet. No exceptions.

### Rule 5. The protocol's batcher / keeper / sequencer must be active.

Before a mainnet smoke test, check the batcher has been operational within the last 10 minutes. A quiet batcher means orders will sit indefinitely. This is why Minswap V2 orders submitted in 2026-03-31 could not be recovered — the batcher was down for unrelated reasons and V1 had no automated detection.

### Rule 6. First mainnet test must use the smallest allowed amount.

Typically 5 ADA or the protocol's minimum order value. Using more than this on the first test is wasting money if anything goes wrong.

---

## 5. Governance vs. operator authority

| Action | Who decides | Mechanism | Timelock |
|--------|-------------|-----------|----------|
| Proposing integration (Steps 1–4) | Any contributor (community or operator) | Public GitHub issue + Discord discussion | — |
| Preprod validation (Step 4) | Keeper operator + peer reviewer | No governance involvement | — |
| `UpdateRegistry` queue (Step 5) | Governance signers (threshold) | On-chain `QueueAction` | 14d |
| `UpdateRegistry` cancel | Any single signer | On-chain `CancelAction` | 0 (immediate veto) |
| `UpdateRegistry` execute (Step 5) | Governance signers (threshold) | On-chain `ExecuteAction` | — (post-timelock) |
| `FastUpdateMarkets` (emergency Liqwid action_addr_hash rotation) | Governance signers (threshold) | On-chain redeemer in `registry.ak` | 1h cooldown only (no 14d wait) |
| `KeeperToggleMarket` — emergency disable a Liqwid market | Keeper operator (unilateral) | On-chain redeemer in `registry.ak`; `active: true → false` only | 0 (immediate, keeper-only) |
| Re-enabling a `KeeperToggleMarket`-disabled market | Governance signers (threshold) | On-chain `UpdateRegistry` | 14d |
| Mainnet smoke test (Step 6) | Keeper operator | Keeper wallet | — |
| Production enablement (Step 7) | Keeper operator (post-execute) | Keeper config push | — |

**Operator authority limit**: the keeper operator can never add a protocol or market to the whitelist unilaterally — registry additions always go through governance (14d timelock). The keeper **can** (a) refuse to use a whitelisted protocol (skip a risky route), and (b) immediately **disable** a Liqwid market via `KeeperToggleMarket` if it detects a bad-debt signal or pool-migration anomaly that would otherwise trap vault funds. Re-enabling a keeper-disabled market requires governance — this is the one-way operational escape hatch pattern (keeper breaks glass, governance reviews and reseals).

**Community authority**: any community member can propose integrations via Step 1 and pressure governance to prioritize them. Governance is not obligated to act on community proposals, but must respond publicly to significant ones.

---

## 6. Cost and timeline per integration type

### Type A: New Liqwid market

- Reverse-engineering effort: 5–10 hours
- Keeper code: 10–15 hours
- Preprod + mainnet smoke: 5–10 hours
- **Total operator time**: ~20–40 hours
- **Direct costs**: ~10–30 ADA (gas)
- **Calendar time from proposal to production**: 3–4 weeks (mostly 14-day governance timelock)
- **Audit scope**: none (reuses existing Liqwid action-validator integration)

### Type B: New DEX route

- Reverse-engineering effort: 15–25 hours
- Keeper code: 15–25 hours
- Preprod + mainnet smoke: 10–15 hours
- **Total operator time**: ~40–80 hours
- **Direct costs**: ~50–150 ADA
- **Calendar time**: 4–6 weeks
- **Audit scope**: 1–2 internal rounds (~US$500–2,000 if externally audited)

### Type C: New lending protocol

- Reverse-engineering effort: 30+ hours
- Contract changes: 40+ hours (possibly new vault validator)
- Full audit: 1–2 external rounds
- **Total operator time**: ~120–300 hours
- **Direct costs**: ~300–1,000 ADA + audit fees
- **Calendar time**: 3–6 months (V2-style fresh deploy)
- **Audit scope**: ~US$10–25K external audit + internal rounds

### Type D: Protocol migration

- Reverse-engineering: 3–5 hours (only `action_addr_hash` update)
- Code: 1–3 hours
- Smoke: 2–5 hours
- **Total operator time**: ~5–15 hours
- **Direct costs**: ~5–20 ADA
- **Calendar time**: same day (1-hour `FastUpdateMarkets`)
- **Audit scope**: none

---

## 7. Funding integrations

Integration work is funded by the treasury R&D category (see `docs/economics.md` §3 and §7C). At low TVL, integration work is effectively volunteer — the founder or a contributor absorbs the cost. As TVL grows, treasury R&D funds become meaningful enough to justify operator compensation:

| TVL | R&D category annual inflow | Type A frequency achievable | Type B frequency | Type C |
|-----|----------------------------|-----------------------------|------------------|--------|
| 100K | ~$43 | 0 (volunteer only) | 0 | 0 |
| 500K | ~$216 | 1 | 0 | 0 |
| 1M | ~$432 | 2 | 0 | 0 |
| 5M | ~$2,160 | 4 | 1 | 0 |
| 10M | ~$4,320 | 6 | 2 | 0 |
| 50M+ | ~$21,600+ | 10+ | 5 | 1 |

This is honest — integrations scale with TVL and treasury fill. Below US$1M TVL, expect ≤ 2 integrations per year. Above US$10M, integration cadence meaningfully accelerates.

---

## 8. Post-launch review and rollback

### 8.1 Post-launch review (T+7 days)

Every production integration undergoes a 7-day review:

- TVL impact: has the integration actually been used?
- TX success rate: did the keeper's executions succeed cleanly?
- User-reported issues via Discord
- Any operational anomalies (unexpected fees, stuck orders, batcher mis-behavior)

A good integration passes the 7-day mark with no concerns. A problematic one may be rolled back.

### 8.2 Rollback procedure

If a production integration causes unexpected issues:

1. **Immediate**: Keeper operator disables the route in keeper config (no governance needed — operator can always stop using a whitelisted route)
2. **Short-term**: Governance queues `UpdateRegistry` removal of the protocol hash (14-day timelock, 1-of-n cancel veto)
3. **Emergency**: If the integration is actively losing funds (not just inefficient), governance can `EmergencyWithdraw` to freeze the vault while the issue is investigated

Rollbacks are a normal operating pattern, not a failure. V1's registry is designed to be mutable under governance oversight precisely so that integration mistakes can be corrected.

---

## 9. Integration checklist (pre-submit summary)

Before a governance signer co-signs a `UpdateRegistry` proposal adding a new protocol, they must verify:

- [ ] Step 1 public proposal completed with 7-day open comment period
- [ ] Step 2 feasibility analysis in GitHub issue, five questions answered
- [ ] Step 3 reverse-engineering complete with decoded CBOR from ≥ 3 TXs
- [ ] Cancel / refund redeemer reverse-engineered
- [ ] Step 4 Preprod end-to-end test: main path AND cancel path both pass
- [ ] Protocol has been mainnet-live for ≥ 90 days with no exploit
- [ ] Batcher / keeper / sequencer active within last 10 min at time of proposal
- [ ] Step 6 mainnet smoke test succeeds (planned for post-execute, 5 ADA or minimum)
- [ ] Worst-case loss bounded below 1% of current TVL

Any unchecked box is grounds for not executing the proposal.

---

## 10. See also

- `docs/economics.md` §7C — R&D budget availability for integration funding
- `spec/governance.md` §4.6 UpdateRegistry — on-chain authorization mechanism
- `spec/governance.md` §4.8 FastUpdateMarkets — 1-hour expedited path for protocol migrations
- `docs/security-model.md` §3 — integration-related attack surface and threat model
- GitHub repo: `v1/contracts/integrations/` (per-protocol trace archives and schema locks)
