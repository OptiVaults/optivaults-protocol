# audit-scope.md — V1 Audit Plan

V1 adds new validators (`keeper_stake_script`, `treasury`, `vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_recall`, `vault_admin_deploy`, `minswap_v2_adapter`) and modifies several others (compile-time parameter changes on `vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_proxy`, `vusdcx`, `order`). The V1 audit plan covers the full contract set under a coverage-area methodology (areas A–F, see §4), with all heritage regression tests required to pass as a precondition.

---

## 1. Design Invariants Carried Forward

The V1 validator set inherits the following architectural invariants from the internal-verification-era design. These are preserved as hard checks in the V1 contracts; the coverage-area plan (§4) verifies each invariant remains enforced after the V1 refactor.

| Invariant | V1 enforcement point |
|-----------|----------------------|
| Non-deposit token preservation (no silent token injection or extraction) | `verify_other_tokens_preserved` pattern in `vault_user`, `vault_keeper_hot`, `vault_protocol`, `vault_recall`, `vault_liqwid`; `verify_all_tokens_preserved` symmetric helper for datum-only-writing redeemers |
| Performance-fee hard cap 450 bps (4.5%) | `performance_fee_bps <= 450` at `vault_gov_policy.ak` UpdateFee entry (via shared `validate_update_fee` helper); `early_withdraw_fee_bps` has its own ≤ 100 bps (1%) cap per `vault-datum.md` §2.2 |
| Buffer floor + non-empty allocations | `buffer_target_bps >= 500` on UpdateStrategy; `strategy_allocations` non-empty check |
| Multisig governance architecture | `multisig_gov.ak` m-of-n state machine with per-action timelocks |
| Governance empty-hash mode + timelock floors | `QueueAction` timelock floor + TTL ceiling; 1-of-n cancel veto |
| Compile-time Vault NFT anchor | `vault_proxy` / `vusdcx` / `order` all parameterized by `vault_nft_policy` at deploy time; datum no longer carries this field |
| Withdraw anti-double-satisfaction | `receiver_output_idx` enforcement on Direct Withdraw |
| Deferred-yield Withdraw semantics | `withdraw_amount = base_withdraw − early_fee`; early fee stays physically in vault |
| Governance security model | `multisig_gov.ak` file-header comments + `spec/governance.md` design rationale |
| No-vusdcx-leak + ≥3 signer floor | BatchProcess no-leak check + RotateSigners signer_count ≥ 3 |
| Order NFT reference-input authenticity | `find_vault_datum_ref` NFT enforcement on order.ak Expire path |
| Corner-case sweep (token whitelist, NDV floors) | MergeUtxo secondary whitelist; Supply/Recall/AdminDeployNonDeposit `idle_buffer >= 0` + `non_deposit_value >= 0` floors |
| Time-field validity-range width cap | 1-hour upper bound on all time-writing redeemers (Compound, UpdateFee, UpdateStrategy, RotateSigners, SwapAda) |
| Allocation invariant + first-depositor floor | `valid_deposited > 0` everywhere; `alloc_sum + idle_buffer <= total_deposited + NDV + Σ liqwid_principal` |
| Off-chain compile-time parameter synchronization | Keeper/API/CLI config stays in lock-step with on-chain validator hashes via `VAULT_NFT_POLICY` + `EXPECTED_PROXY_HASH` env gating |
| Deploy pipeline state isolation | `RELEASE_TAG` gate + per-script flushState + extended NFT deadlines |
| Registry identity-field immutability | `RegistryDatum.keeper_pkh` (identity reference, not the active authorized keeper set), `deposit_token_policy`, `deposit_token_name`, ref-script hashes locked once set. Note: the **active keeper rotation** path is **`keeper_stake_script.authorized_pkhs`** (governed via `UpdateKeeperAuth`, see `spec/keeper-auth.md`) — that is what changes when keepers are added/rotated/removed without redeploying the vault. The two fields are distinct: `RegistryDatum.keeper_pkh` is a deploy-time identity reference frozen for indexing / discovery; `keeper_stake_script.authorized_pkhs` is the runtime authorization list that the validator gates on. |

**Regression tests:** the heritage regression test suite must continue to pass against V1 validators as a precondition for each coverage-area exit. Any failure is a blocker.

---

## 2. V1-Specific New Audit Scope

### 2.1 `keeper_stake_script.ak`

**New validator. Full audit round required.**

Scope:
- `RegistrationMode` enum correctness (GovernanceOnly / Mixed / PermissionlessWithBond)
- `keeper_auth_datum` state machine transitions
- Bond slashing conditions (specified but not active at V1 launch — audit for future readiness)
- `WithdrawAsAuthorized` redeemer integration with `vault_user`/`vault_keeper_hot`/`vault_protocol`/`vault_recall`/`vault_liqwid` via Withdraw-Zero
- Grace period timing for bond withdrawal
- Cross-validator authorization flow (gov-path vs keeper-path)

**Target findings:** 0 CRIT / 0 HIGH / 0 MEDIUM before launch.

### 2.2 `treasury.ak`

**New validator. Full audit round required.**

Scope:
- `TreasuryDatum` 18-field correctness
- `Receive` redeemer accepts Compound fee output without datum manipulation
- `Spend` redeemer enforces `amount <= category_balance[category]`
- `UpdateParams` enforces ratio invariants (sum = 10000, audit_reserve_ratio >= 2000, no category > 5000)
- Interaction with `multisig_gov` (TreasurySpend, UpdateTreasuryParams authorizations)
- Front-running resistance on category balance reads
- Donation handling (receiving tokens outside Compound flow)

**Target findings:** 0 CRIT / 0 HIGH / 0 MEDIUM before launch.

### 2.3 Modified Validators

**`vault_user.ak` + `vault_keeper_hot.ak` + `vault_batcher.ak` + `vault_swap_ada.ak`:**
- Compile-time parameters: `keeper_stake_hash` (auth via `keeper_stake_script` zero-withdraw — rotation without redeploy) on `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada`; `vault_keeper_hot` and `vault_swap_ada` additionally take `treasury_hash` (USDCx fees + ADA-swap proceeds route to a script address, not a wallet PKH). `vault_user` is purely permissionless (no `keeper_stake_hash` required).
- Authorization model: `vault_user` holds Deposit + Withdraw (permissionless, user signature). `vault_keeper_hot` holds Compound + RebalanceBuffer (keeper-auth). `vault_batcher` holds BatchProcess (keeper-auth, multi-order vUSDCx mint/burn orchestration). `vault_swap_ada` holds SwapAda (keeper-auth, ADA→USDCx swap with dual-feed oracle reader, see `spec/ada-swap.md`).
- Compound redeemer (on `vault_keeper_hot`) splits fee **3-way** between keeper / gov pool / treasury per `keeper_fee_bps` + `gov_fee_bps` (launch 2000 / 0 / 8000; caps enforced by UpdateFeeSplit — see `spec/vault-datum.md` §2.2).
- Verify fee split correctness (no skim in rounding).
- Verify treasury output datum is preserved correctly on Compound (cross-validator to `treasury.Receive`).
- Verify gov-pool physical USDCx flow matches `gov_share` (cross-validator binding with `multisig_gov.ReceiveCompoundShare`).
- Verify `validate_compound` still enforces all prior invariants.
- Verify BatchProcess `no_vusdcx_leak` invariant on `vault_batcher`.

**`vault_protocol.ak` + `vault_recall.ak`:**
- `vault_protocol` carries DeployToProtocol only (plus A2 `publish`). DEX swaps dispatch through the SwapAdapter interface (see `spec/swap-adapter.md`); `minswap_v2_adapter` is the launch adapter.
- `vault_recall` carries RecallFromProtocol + MergeUtxo (plus A2 `publish`).
- Compile-time parameter changes cascade to `vault_proxy` (11 params, 10 Withdraw-Zero routes).
- Verify `UpdateKeeperAuth` interaction with `keeper_stake_script`.
- Verify `UpdateTreasuryParams` and `TreasurySpend` do not bypass existing invariants.

**`vault_proxy.ak`, `vusdcx.ak`, `order.ak`:**
- Compile-time parameter changes (new hashes for core/protocol/liqwid/treasury/keeper_stake)
- Verify applied forms produce expected hashes
- No logic changes expected — audit is cascade verification

**`vault_liqwid.ak`:**
- staking validator split validator carried forward unchanged
- Audit as regression — confirm heritage Liqwid findings still closed (Supply/Recall accounting, market_id uniqueness, qToken rate semantics)

### 2.4 Governance Additions

`multisig_gov.ak` gains new `ActionKind` variants:
- `UpdateKeeperAuth`
- `TreasurySpend`
- `UpdateTreasuryParams`

Each requires:
- Timelock floor audit (14d for UpdateKeeperAuth and UpdateTreasuryParams; 7d for TreasurySpend)
- Payload hash computation audit
- Cross-validator authorization flow audit

### 2.5 Registry Additions

`registry.ak` may add:
- Reference to `treasury_hash` (read-only)
- Reference to `keeper_stake_script_hash` (read-only)

These are **read-only anchors** — no new redeemers, no state change. Audit: verify new fields are immutable or correctly gated by existing `UpdateRegistry` redeemer.

---

## 3. Property-Based Test Additions

Existing `property_fuzz_test.ak` + `property_fuzz_extended_test.ak` cover 25 properties × 100 iterations. V1 adds:

| Property | Description | Iterations |
|----------|-------------|------------|
| P26: Treasury category floor | `audit_reserve_balance >= min_audit_reserve` (immutable floor) | 100 |
| P27: Compound fee split | `keeper_fee + treasury_fee == total_fee` exactly (no rounding skim) | 100 |
| P28: Treasury ratios sum | `Σ category_ratios == 10000` invariant | 100 |
| P29: Bond slashing bounds | `slash_amount <= posted_bond` | 100 |
| P30: Keeper authorization transitivity | If redeemer claims `WithdrawAsAuthorized`, then `keeper_stake_script` output must show updated bond state | 100 |

Total fuzz runs expand from 2,500 → 3,000 per build.

**Cross-reference (test-count metrics).** This file's "30 properties × 100 iterations = 3,000 fuzz runs" is **one specific metric** about property-based fuzz coverage. The whitepaper §5.4 figure of "104 unit + property tests / 599 randomized checks per `aiken check` run" refers to the **full Aiken test suite** (54 validation + 4 deregister + 8 split + 7 oracle + 12 swap + 8 property × per-iteration deterministic + 11 r72 = 104 test functions; the "599 checks" is what `aiken check` summary line emits, counting deterministic case + each `aiken/fuzz` property invocation as 1 check). The two metrics are not contradictory — they describe different layers (this doc focuses on `aiken/fuzz` randomized iterations specifically; the whitepaper aggregates). The 3,000 fuzz-runs figure here counts the maximum iterations possible if every property runs to its 100-iteration cap; in practice early-exit on first failure means some properties may report fewer.

---

## 4. Internal Audit Coverage Plan

V1-specific internal audit work is organized by coverage area rather than enumerated round numbers. Each area is tracked independently; the round count depends on finding density and scope refinement during review.

**Coverage area A — Treasury**
Focus: `treasury.ak` entire validator, `TreasurySpend` + `UpdateTreasuryParams` + `ReceiveGovForfeit` via `multisig_gov`. Exit: 0 CRIT / 0 HIGH / 0 MEDIUM findings.

**Coverage area B — Keeper Stake Script**
Focus: `keeper_stake_script.ak` entire validator, `UpdateKeeperAuth` via `multisig_gov`, weekly rotation mechanism, bond lifecycle. Exit: 0 CRIT / 0 HIGH / 0 MEDIUM findings.

**Coverage area C — V1 Integration Flows**
Focus: cross-validator flows for Compound (3 fee outputs: keeper + gov pool + treasury), `UpdateKeeperAuth` triggering keeper_auth state changes, `TreasurySpend` under m-of-n, `DistributeSignerCompensation` + `ReceiveGovForfeit` cross-validator binding. Exit: 0 CRIT / 0 HIGH / 0 MEDIUM findings.

**Coverage area D — V1 Regression**
Re-run all heritage regression tests against V1 validators. Flag any cascade impact from new compile-time parameters. Exit: all prior tests still pass after V1 refactor.

**Coverage area E — Off-chain V1**
Keeper, API, frontend, CLI all updated for V1 stack. Specific surfaces: keeper slippage policy bounds (cross-validator with `vault_gov_policy.UpdateSlippagePolicy`), API JWT signature-verification flow, withdraw-cli + emergency-withdraw HTML invariants (frontend-independent self-serve recovery path), TVL cap enforcement at frontend deposit gating + keeper `tvlCapMonitor` alerts. **Severity tiers**: CRITICAL = direct user-fund loss / unauthorized fund movement; HIGH = silent state desync between off-chain and on-chain; MEDIUM = liveness degradation requiring operator intervention; LOW = cosmetic / observability gaps. **Exit**: 0 CRIT / 0 HIGH on keeper, 0 CRIT on API + CLI. (Off-chain code is not in the same blast radius as on-chain validators — depositor funds are protected by on-chain checks regardless of off-chain bugs — but off-chain CRIT/HIGH still warrant fix-before-launch because they can degrade the user-facing experience to the point that depositors cannot exit without operator help.)

**Coverage area F — Deploy Pipeline V1**
V1 adds treasury UTXO init + keeper_stake_script UTXO init to deploy ceremony. Deploy-pipeline audit methodology applied to new deploy steps. Exit: 0 CRIT findings on state machine; documented runbook.

---

## 5. External Audit

**Target: Q3 2026.**

Candidate firms (to be evaluated): Runtime Verification, CertiK, Tweag, MLabs, Anastasia Labs.

**Scope requested from external auditor:**
- Full Aiken source review of V1 validators.
- Invariant preservation across all redeemers.
- Formal verification of core invariants (deferred-yield Withdraw semantics, BatchProcess mint-ratio equality, MergeUtxo secondary-source whitelist) where feasible.
- Compile-time parameter audit (confirm all anchors are set at deploy).
- Off-chain audit of keeper, API, CLI is optional but preferred.
- Deploy ceremony dry-run audit.

**Gate:**
- 0 CRITICAL findings unresolved.
- 0 HIGH findings without documented operator acceptance + community disclosure.
- External auditor signs off on V1's on-chain invariant set.

**Post-audit actions:**
- Publish audit report (IPFS + website).
- Raise TVL cap from 100K to 1M USDCx.
- Announce audit milestone via governance QueueAction (audit report hash committed on-chain).

---

## 6. Bug Bounty

**Launched at V1 audit completion.**

**Scope:** V1 validators (**17 logic validators + 4 one-shot NFT mint policies + 1 DEX adapter = 22 compiled artefacts total** — see `spec/architecture.md` §4.1 for partitioning rationale), deploy scripts, keeper code, API server.

**Severity tiers (USDCx from treasury audit reserve):**
| Severity | Payout |
|----------|--------|
| CRITICAL (fund loss) | **2,000 USDCx floor** (from treasury audit reserve), scaling up to 10,000 USDCx or 10% of TVL at discovery, whichever is lower |
| HIGH (fund freeze, operational DoS) | 2,000 USDCx |
| MEDIUM (invariant violation without fund loss) | 500 USDCx |
| LOW (defense-in-depth) | 100 USDCx |

**Phase 1 below-market-rate disclosure.** During pre-audit Phase 1 (TVL range $500–$25K per `whitepaper §8.2`), the 10%-of-TVL formula yields CRITICAL payouts of $50–$2,500 — well below the $50K–$500K market rate offered by mature DeFi bug bounties (e.g., on Immunefi). The **2,000 USDCx floor** above ensures a baseline that's at least proportionate to a competent reviewer's time investment for a CRITICAL finding, and the floor is funded from treasury audit reserve regardless of vault TVL at discovery time. This intentionally below-market structure reflects V1's pre-audit, public-goods positioning + operating-capital constraints; post-external-audit cap lift + TVL growth scale the upper tier toward market norms automatically.

**Submission:** `optivaults@gmail.com` with PGP encryption (public key at optivaults.app/security).

**Coordinated disclosure:** 90-day window from triage, extendable by 30 days if operator needs to prepare a fix TX.

---

## 7. Ongoing Audit Cadence

Post-launch, internal audit rounds continue on a monthly basis, focused on:
- Any new redeemer or validator introduced via `UpdateRegistry` scope expansion.
- New DEX integrations (new `protocol_hashes` whitelist entries).
- New Liqwid markets.
- Keeper code changes (especially `vaultSwapEngine.ts`, `strategyRouter.ts`).

Every 6 months: full regression of the heritage test suite plus V1-era coverage-area tests against current deployed hashes.

Every 12 months: external audit refresh (smaller scope, delta since last full audit).

---

## 8. Public Transparency

All audit reports (internal and external) are published:
- GitHub: `/audit/` directory with reports, test artifacts, plutus.json hashes, reproducibility scripts.
- Website: optivaults.app/audit with summary + download links.
- On-chain: IPFS hash of each audit report committed as a no-op `QueueAction` in `multisig_gov` (cancelable, but the IPFS pin survives).

This creates a tamper-evident public record: every audit is part of the on-chain history.

---

## 8.5 Audit Funding Posture (Public-Goods Path)

V1 is positioned as a non-commercial Cardano DeFi public-goods reference implementation. Audit engagement is funded via a non-dilutive stack:

- **(a) Cardano Project Catalyst grant**: expected $30K-$50K (Round 15+ submission 2026 Q2-Q3)
- **(b) Audit-firm public-goods rate**: 30-50% discount on $100K-$150K full price (outreach pending)
- **(c) Scope reduction via extensive internal audit history** (heritage work in §1): lets external audit focus on critical paths rather than full 17-logic-validator + 1-DEX-adapter scope (22 artefacts total — see §6 for full count), saving $15K-$25K
- **(d) Founder self-fund remainder**: $20K-$40K out-of-pocket after mitigations

This positioning may be relevant for audit firms evaluating engagement:

- **Apache 2.0 license**: full fork-welcome, open-source reference-implementation status
- **No commercial profit motive**: 4.5% performance fee covers operations + audit reserve + long-term runway, not founder/investor revenue
- **No token / no VC / no SAFE / no SAFT**: engagement is not entangled with securities-related obligations
- **Audit report publication mandate**: full report public on completion (§8 above) — suitable for firms prioritizing public-goods portfolio

Audit firms offering public-goods pricing for Cardano DeFi reference implementations are invited to contact `optivaults@gmail.com`. See whitepaper §8.1 + `economics.md §5.2.1` for the detailed funding stack.

---

## 9. See Also

- `docs/security-model.md` — V1 threat model
- `spec/architecture.md` — V1 validator catalog
- `spec/governance.md` — Timelock floors and action payloads
- `spec/treasury.md` — TreasuryDatum invariants
- `spec/keeper-auth.md` — keeper_stake_script and bond lifecycle
