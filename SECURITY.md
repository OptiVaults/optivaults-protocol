# Security Policy — OptiVaults V1

## Reporting Vulnerabilities

If you discover a security vulnerability in OptiVaults V1 smart contracts, deploy tooling, or reference implementations, please report it privately. **Do not open a public issue.**

**Email:** `optivaults@gmail.com`
**PGP key:** `optivaults.app/security` (encrypt sensitive technical details)

**Please include:**
- Description of the vulnerability
- Steps to reproduce (or theoretical attack walkthrough if exploit is not implemented)
- Potential impact assessment (severity + affected validator / redeemer)
- Suggested fix (if any)

**Response timeline:**
- Acknowledgment: within 72 hours
- Initial triage: within 7 days
- Fix + patch notice: depends on severity; CRITICAL / HIGH findings target 30-day remediation with operator-mitigation notice published immediately

---

## Scope

**This repository's security scope is the protocol layer** — Aiken validators, deploy pipeline, protocol specification artefacts. Off-chain operator code (keeper runtime, API server, frontend, CLI tools) has its own separate repository [`optivaults-reference`](../optivaults-reference) with its own [`SECURITY.md`](../optivaults-reference/SECURITY.md).

**When in doubt, default to this repo's disclosure channel.** Triage will route to `optivaults-reference` if the finding is operator-layer.

### In scope

- **Aiken smart contracts** under `contracts/validators/`:
  - `vault_proxy.ak` — Withdraw-Zero forwarding + phantom-vault defense
  - `vault_user.ak` — Deposit / Withdraw / full-drain
  - `vault_keeper_hot.ak` — Compound / RebalanceBuffer / SwapAda (gov-share binding)
  - `vault_batcher.ak` — BatchProcess (payout uniqueness + no-vUSDCx-leak)
  - `vault_swap_ada.ak` — SwapAda dual-feed oracle reader
  - `vault_protocol.ak` — DeployToProtocol (adapter-dispatched peg-floor + Tier 1 oracle)
  - `vault_recall.ak` — RecallFromProtocol / MergeUtxo (secondary allowlist)
  - `vault_liqwid.ak` — SupplyToLiqwid / RecallFromLiqwid (gov-path orphan guard)
  - `vault_gov_policy.ak` — UpdateStrategy / UpdateFee / UpdateFeeSplit / UpdateSlippagePolicy
  - `vault_gov_emergency.ak` — EmergencyWithdraw (loss write-off + freeze)
  - `vault_admin_deploy.ak` — AdminDeployNonDeposit (7d keeper-inactive fallback)
  - `multisig_gov.ak` — m-of-n governance state machine + ExecuteAction + RotateSigners
  - `treasury.ak` — 4-bucket budget + 24h cooldown + audit-reserve floor
  - `keeper_stake_script.ak` — keeper authorization (GovernanceOnly at launch)
  - `registry.ak` — protocol whitelist + stable_tokens + liqwid_markets + asset_oracles + swap_adapter_hashes
  - `order.ak` — Order UTXO + Cancel + Expire + Process via BatchProcess
  - `vusdcx.ak` — vUSDCx share minting policy + 10^18 over-mint cap
  - `minswap_v2_adapter.ak` — SwapAdapter (§B@launch=1)
  - `sundaeswap_adapter.ak` — SwapAdapter for SundaeSwap V3 + Stableswaps (in scope when the SundaeSwap adapter pair is deployed — opt-in, see `spec/swap-adapter.md`)
  - `sundaeswap_cancel_guard.ak` — drain-proof cancel authority for SundaeSwap orders (deployed alongside `sundaeswap_adapter`)

- **NFT mint policies**:
  - `vault_nft.ak` — one-shot Vault Identity NFT (compile-time anchor on proxy / vusdcx / order)
  - `governance_nft.ak` — one-shot Governance NFT (anchors `is_gov_authorized`)
  - `gov_signer_nft.ak` — soul-bound signer recognition NFT
  - `registry_auth_nft.ak` — one-shot Registry Auth NFT

- **Shared validation + helper libraries**:
  - `contracts/lib/vault/constants.ak`
  - `contracts/lib/vault/types.ak` — VaultDatum (29 fields) / GovDatum / RegistryDatum / TreasuryDatum / OrderDatum / etc.
  - `contracts/lib/vault/validation.ak` — per-redeemer datum-transition predicates
  - `contracts/lib/vault/helpers.ak` — `is_gov_authorized` / `find_vault_utxo` / token preservation / payload hashing
  - `contracts/lib/vault/oracle.ak` — dual-feed oracle reader (§5.4 P3)
  - `contracts/lib/vault/swap_adapter.ak` — SwapAdapter dispatch + Tier 2 peg-floor (§5.4 P4)

- **Deploy pipeline** (`deploy/`): off-chain failures that could leak operator keys, misconfigure ceremony state, or produce invalid on-chain identity anchors.

### Out of scope (for V1)

- **Keeper reference implementation** — not yet started (`keeper/` empty). Findings welcome once implementation lands.
- **API server** — no public API ships with V1 source tree. External integrators building their own API do so under their own security posture.
- **Frontend** — V1 open-source release focuses on the contract layer + deploy tooling. Frontend security posture (CIP-30 wallet integration, JWT handling, etc.) is part of the operator's own deployment, not V1's scope.
- **Test files** (`*_test.ak`, `*.test.ts`) — intentionally adversarial; failures there are a feature.
- **Social engineering attacks** against governance signers, operators, or depositors.
- **Third-party infrastructure** — Cardano node / Blockfrost / Ogmios / Kupo / Liqwid Finance / Minswap V2 / Circle xReserve — each has its own disclosure process.

---

## Security model

### On-chain guarantees (contract-enforced)

Three guarantees hold unconditionally in deployed V1 Aiken validators, independent of any operator action:

1. **No admin-drain redeemer.** No redeemer moves vault principal to a non-depositor address. Emergency paths route through `vault_gov_emergency.EmergencyWithdraw` with governance multi-sig + public disclosure.
2. **4.5% performance-fee cap is immutable.** `max_performance_fee_bps = 450` in `constants.ak` is compile-time-anchored via the shared `validate_update_fee` helper called from `vault_gov_policy.UpdateFee`. Governance CAN adjust `performance_fee_bps` within `[0, 450]` but CANNOT exceed the cap under any circumstance.
3. **7-day keeper-inactivity waiver.** When `now > last_compound_time + 7 days`, `vault_user.Withdraw` automatically waives `early_withdraw_fee_bps` per the `keeper_inactive_ms` check. Depositors can exit fee-free if the keeper goes permanently silent.

Additional invariants enforced on-chain (not exhaustive — see `docs/audit-scope.md §1`):

- **Non-deposit token preservation.** `verify_other_tokens_preserved` pattern on 7+ redeemers prevents silent token injection or extraction.
- **Allocation invariant.** Two variants enforced across the vault operational set — a stricter `alloc_sum + idle_buffer ≤ total_deposited` via the shared `validate_allocations` helper (used by `Compound` / `DeployToProtocol` / `RecallFromProtocol` / `UpdateStrategy` / `AdminDeployNonDeposit` / `vault_liqwid` ops) and a looser `alloc_sum + idle_buffer ≤ total_deposited + non_deposit_value + Σ liqwid_principal` inline check in `vault_gov_emergency.EmergencyWithdraw`. `vault_recall.MergeUtxo` guards the looser form at the source of donation-driven state changes via `valid_merge_utxo_admissibility` — a MergeUtxo post-state that satisfies the looser form automatically satisfies the stricter form downstream because NDV and Σ liqwid_principal are non-negative.
- **First-depositor protection.** `initial_share_multiplier = 10^6` + `valid_deposited > 0` prevent ERC-4626-style inflation attacks.
- **Minimum deposit.** 10 USDCx minimum on Direct Deposit (queued Order bypasses for dust-safe batching; BatchProcess enforces non-zero share mint).
- **Anti-double-satisfaction.** `vault_user.Withdraw` enforces `receiver_output_idx` hard binding. BatchProcess enforces `payout_output_index` uniqueness across multiple orders.
- **No-vUSDCx-leak.** BatchProcess fails any TX minting vUSDCx to an address outside `(order_owner ∪ proxy_hash)`.
- **Deferred-yield Withdraw.** `withdraw_amount = base_withdraw − early_fee`; the early-fee stays physically in vault → share price rises by `(early_fee / total_shares)` → remaining depositors benefit. An earlier accounting drift on this path has been closed.
- **Compile-time Vault NFT anchor.** `vault_proxy` / `vusdcx` / `order` all parameterized on `vault_nft_policy` at deploy time, not datum — this closes the phantom-vUSDCx self-referential datum attack.
- **9 immutable + 8 policy-locked VaultDatum fields, plus the compile-time Vault NFT anchor.** Immutable (9 — never change after deploy): `vault_version` + the 8 identity anchors `governance_policy` / `governance_name` / `deposit_token_policy` / `deposit_token_name` / `vusdcx_policy` / `order_script_hash` / `registry_hash` / `registry_auth_policy`. Policy-locked (8 — governance-mutable within hard bounds via the dedicated UpdateFee / UpdateFeeSplit / UpdateStrategy redeemers): `performance_fee_bps` (`[0, 450]`) / `early_withdraw_fee_bps` / `min_hold_seconds` / `buffer_target_bps` / `keeper_fee_bps` / `gov_fee_bps` / `max_slippage_bps` / `min_swap_peg_bps`. The Vault NFT policy itself is stronger than any datum field — it is a compile-time parameter on `vault_proxy` / `vusdcx` / `order`, anchored at deploy time and unchangeable without a full redeploy. See `spec/vault-datum.md` for full per-field semantics.
- **Governance cancel veto.** Every `QueueAction` has a 1-of-n `CancelAction` veto window; execution requires both m-of-n signatures AND action survives the timelock without cancellation.
- **Validity-range width cap.** Every time-writing redeemer (Compound / UpdateFee / RotateSigners / UpdateStrategy / SwapAda / RebalanceBuffer) caps `upper - now ≤ 1 hour` to bound timestamp-manipulation surface.
- **Governance signer floor.** `valid_signer_set` requires `signers ≥ 3, threshold ≥ 2, threshold ≤ n, unique` (defense-in-depth).
- **Empty-hash governance delegation.** Documented design trade-off — see §"Known design decisions" below.

### Off-chain-dependent guarantees

The following depositor-facing promises depend on external infrastructure remaining available:

- **Withdraw settles in 1:1 USDCx.** Requires Cardano chain uptime + depositor wallet ADA for TX fees + Liqwid availability (if vault has Liqwid positions) + USDCx liquidity.
- **Share price tracks underlying yield accurately.** Requires keeper execution of periodic Compound cycles. If keeper is inactive for > 7 days, the 7-day waiver lets depositors exit without early-fee penalty (contract-enforced), but share price temporarily fails to reflect new Liqwid interest accrued during the dormancy window until a subsequent Compound.
- **Emergency self-serve recovery.** Requires Cardano chain + USDCx liquidity. The `emergency-withdraw` self-serve tool is packaged in the open-source source tree; any depositor can run it without operator coordination.

---

## Test coverage

| Category | Coverage | Status |
|----------|----------|--------|
| Aiken unit tests | Deterministic cases across all 24 artefacts + cross-validator integration flows; includes inline tests in `minswap_v2_adapter`. Exact count reproducible via `cd contracts && aiken check` at the deployed commit. | All pass |
| Aiken property-based fuzz (`aiken/fuzz` v2.2.0) | Property tests in `contracts/lib/vault/tests/property_test.ak` with iteration-cap discipline (default 100 iter per property, early-exit on first failure). Exact property count reproducible via `aiken check`. | All pass |
| Preprod E2E scripts (`tests/preprod-e2e-plan.md`) | Multi-phase coverage: ceremony health, user flows (Deposit / Withdraw / Queue / Batch / Order Cancel+Expire / Queued-Withdraw), zero-yield Compound, MergeUtxo donation paths (including negative-path rejections), governance state-machine flows (Queue / Execute / Cancel), oracle E2E (Tier 1 + Tier 2 + stale / disagreement / no-entry rejection), SwapAdapter dispatch (attacker-recipient chain replay), and mock-Liqwid Supply / Recall / Compound / Distribute end-to-end. | All chain-verified on the relevant ceremonies |
| Keeper vitest | Reference keeper implementation lives in the operator repo; test suite scoped there. | — |
| API vitest | Not in V1 scope (V1 covers protocol layer only — see `README.md` two-layer architecture). | — |
| Frontend vitest | Not in V1 scope (V1 covers protocol layer only — see `README.md` two-layer architecture). | — |

Preprod ceremonies have exercised the full deploy pipeline + post-deploy operational flows across multiple release tags. Per-ceremony chain TX evidence lives in `deploy/state/<network>-<release-tag>.json` (operator-only, gitignored). Internal-audit fixes are re-verified on a fresh post-fix ceremony before they are considered closed — including the attacker-recipient chain-replay defence (`SwapAdapterRedeemer.expected_recipient_addr` Layer-1 / Layer-2 enforcement).

---

## Audit status

### Methodology

V1 uses a **coverage-area methodology** (areas A–F, see `docs/audit-scope.md §4`) for its internal audit history. This replaces the per-round numbering earlier internal-verification versions used. Coverage areas map to validator clusters + cross-validator integration flows rather than being tied to chronological audit rounds.

### Internal audit history

V1's contract code has undergone multiple rounds of internal adversarial audit, organised by coverage area (areas A–F — see `docs/audit-scope.md`). Each round is a structured adversarial read against a defined threat model; all non-INFO findings surfaced to date have been resolved in code with regression tests added. Per-finding detail is consolidated internally for the forthcoming third-party audit rather than enumerated here.

### Coverage-area status (pending external audit)

Area definitions track `docs/audit-scope.md §4` — the source of truth for V1's internal audit plan. Each area has a defined exit criterion (0 CRIT / 0 HIGH / 0 MEDIUM for areas A–C and E; structural pass for D; 0 CRIT for F).

| Area | Scope | Status |
|------|-------|--------|
| A | Treasury — `treasury.ak` (TreasurySpend / UpdateTreasuryParams / ReceiveGovForfeit via `multisig_gov`) | Not started |
| B | Keeper Stake Script — `keeper_stake_script.ak` (UpdateKeeperAuth / weekly rotation / bond lifecycle) | Not started |
| C | V1 Integration Flows — cross-validator (Compound 3-way fee split / TreasurySpend under m-of-n / DistributeSignerCompensation + ReceiveGovForfeit binding / three-layer governance safety) | Not started |
| D | V1 Regression — heritage regression tests re-run against V1 validators (cascade-impact flagging from new compile-time parameters) | Not started |
| E | Off-chain V1 — keeper / API / frontend / CLI lives in [`optivaults-reference`](../optivaults-reference); see that repo's `SECURITY.md` | Not started |
| F | Deploy Pipeline V1 — treasury UTXO init + keeper_stake_script UTXO init in the deploy ceremony state machine | Not started |

### External audit

- **Target**: Q2-Q3 2027.
- **Candidate firms** (narrow list of teams with Plutus V3 + Aiken experience as of 2025-2026 publication): Anastasia Labs / MLabs / Certik-Cardano / TxPipe + independent Aiken reviewers. Final firm selection + scope will be publicly announced at least 2 weeks before engagement start.
- **Pre-engagement posture**: operator-enforced TVL cap of 100K USDCx (see whitepaper §8.2).

---

## Known open findings

_No currently open findings above LOW severity from internal audit._

---

## Known design decisions (documented, not findings)

### Withdraw allowed during Emergency Freeze

`vault_user.Withdraw` does **not** check `frozen == 0`. This is deliberate: depositor funds are never locked regardless of vault state. The `frozen` flag blocks operational actions that could compound incorrect accounting (Compound / BatchProcess / RebalanceBuffer / DeployToProtocol / SupplyToLiqwid), while Withdraw / RecallFromProtocol / RecallFromLiqwid / MergeUtxo remain available for fund recovery. The `idle_buffer ≥ base_withdraw` constraint naturally prevents over-withdrawal. Confirmed across multiple audit rounds.

### Governance empty-hash delegation

`multisig_gov.QueueAction` permits an empty `target_tx_hash` (`#""`), which lets m-of-n governance pre-authorize a `VaultAdmin` / `RegistryAdmin` capability that any 1-of-n signer can execute after the action kind's timelock — bounded by `ActionKind` per `contracts/lib/vault/constants.ak`, ranging from 0 (emergency) and 48h (slippage / per-market liveness toggles) up to 21 days (longest, `UpdateFeeSplit`).

This exists because `target_tx_hash` has an unavoidable circular dependency on the governance UTXO reference (TX body includes the queued datum which contains target_tx_hash — TX hash can't be known at queue time for actions whose executing TX hasn't been constructed yet).

**On-chain defenses retained during execution window**: `CancelAction` (1-of-n veto), `action_ttl_ms` 37-day absolute cap, `GovNFT == 1` uniqueness, target script must be a spent input, ADA preservation, the full immutable + policy-locked VaultDatum envelope (9 immutable + 8 policy-locked fields, see "Hard guarantees" above), plus the compile-time Vault NFT anchor.

**Off-chain operator obligations**:
- Empty-hash `QueueAction` must be publicly broadcast within 1 hour.
- ≥1 honest signer must monitor the governance queue for the full timelock + TTL window and use `CancelAction` on any anomaly.
- The signer set must include ≥2 non-colluding parties with independent monitoring infrastructure.
- Prefer explicit `target_tx_hash` whenever the executing TX body can be pre-computed.

### Governance zero-share BatchProcess edge case

When `total_shares > 0 && total_deposited == 0`, BatchProcess correctly mints 0 shares. This state requires 100% fund loss (vault is worthless), and 0-share mint is the correct behavior. Under normal operation `total_deposited > 0` ensures positive share calculations.

### Garbage token dust in vault UTXO

Airdropped tokens absorbed into a vault UTXO via `MergeUtxo` with `non_deposit_increase = 0` are preserved but cannot be removed via `AdminDeployNonDeposit` (which only routes whitelisted `stable_tokens`). This is accepted: garbage tokens are inert dust. Full drain destroys the vault UTXO entirely, releasing all tokens.

---

## Responsible disclosure + ex gratia recognition

V1 does **not** operate a structured bug bounty program at launch.
Bounty tier matrices work when the protocol is post-external-audit and
TVL is large enough that the audit-reserve accrual supports market-
competitive payouts. V1's Phase 1 scale ($500–$25K TVL) cannot support
that without a sub-market tier structure — a design that looks like a
commitment but isn't competitive, invites "scale mismatch" critique
from audit firms, and contradicts V1's non-commercial public-goods
positioning.

Instead, V1 ships a standard Responsible Disclosure Policy + ex gratia
recognition framework. Full terms in `docs/audit-scope.md §6`.
Summary:

- **Scope**: matches the §"In scope" list above (Aiken contracts +
  deploy pipeline + 24 compiled artefacts). Operator-layer findings
  (keeper / API / frontend) are still accepted and triage-routed to
  `optivaults-reference` per the §Scope note above.
- **Disclosure window**: 90 days from triage (extendable by 30 days if
  remediation requires extended coordination with Liqwid / Minswap V2 /
  Circle-xReserve).
- **Acknowledgement**: within 72 hours; triage + initial remediation
  plan within 7 days.
- **Recognition (discretionary, ex gratia)**: public credit in the V1
  audit report + repository, co-authored case-study collaboration on
  the finding + fix, priority access to future internal-audit drafts +
  pre-mainnet test deployments, and an operator-discretionary
  appreciation payment from founder founding capital (explicitly not a
  market-rate bounty — V1 Phase 1 treasury audit-reserve accrual
  cannot fund that; see `docs/audit-scope.md §6.2`).
- **No legal threats** for good-faith disclosure operating under this
  policy.

A structured bounty tier program is a post-external-audit + post-TVL-
scale consideration (preconditions in `docs/audit-scope.md §6.3`), not
a V1 launch commitment.

---

## Contact

- **Security disclosure**: `optivaults@gmail.com` (PGP on `optivaults.app/security`)
- **General / non-sensitive**: Discord (invite on `optivaults.app`)
- **Commercial / partnership**: not solicited — V1 is a public-goods reference implementation, not a commercial service

---

## See also

- `whitepaper/whitepaper.md` §5 (Risks) + §6 (Trust + Governance) + §12 (Disclosure)
- `docs/security-model.md` — trust boundaries + threat model + residual risks
- `docs/audit-scope.md` — full coverage-area methodology + external audit plan
- `spec/governance.md` — MultisigGov action kinds + timelock rules
- `spec/swap-adapter.md` — SwapAdapter threat model + post-launch DEX addition lifecycle
- `CONTRIBUTING.md` — contribution + disclosure workflow
