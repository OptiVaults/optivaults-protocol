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

**This repository's security scope is the protocol layer** — Aiken validators, deploy pipeline, protocol specification artefacts. Off-chain operator code (keeper runtime, API server, frontend, CLI tools) has its own separate repository [`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference) with its own [`SECURITY.md`](https://github.com/OptiVaults/optivaults-reference/blob/v1/SECURITY.md).

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
- **Allocation invariant.** Two variants enforced across the vault operational set — a stricter `alloc_sum + idle_buffer ≤ total_deposited` via the shared `validate_allocations` helper (used by `Compound` / `DeployToProtocol` / `RecallFromProtocol` / `UpdateStrategy` / `AdminDeployNonDeposit` / `vault_liqwid` ops) and a looser `alloc_sum + idle_buffer ≤ total_deposited + non_deposit_value + Σ liqwid_principal` inline check in `vault_gov_emergency.EmergencyWithdraw`. `vault_recall.MergeUtxo` guards the looser form at the source of donation-driven state changes via `valid_merge_utxo_admissibility` (R73 F-1 fix) — a MergeUtxo post-state that satisfies the looser form automatically satisfies the stricter form downstream because NDV and Σ liqwid_principal are non-negative.
- **First-depositor protection.** `initial_share_multiplier = 10^6` + `valid_deposited > 0` prevent ERC-4626-style inflation attacks.
- **Minimum deposit.** 10 USDCx minimum on Direct Deposit (queued Order bypasses for dust-safe batching; BatchProcess enforces non-zero share mint).
- **Anti-double-satisfaction.** `vault_user.Withdraw` enforces `receiver_output_idx` hard binding (R48 M-1). BatchProcess enforces `payout_output_index` uniqueness across multiple orders (R52 H-1).
- **No-vUSDCx-leak.** BatchProcess fails any TX minting vUSDCx to an address outside `(order_owner ∪ proxy_hash)` (R51 H-1).
- **Deferred-yield Withdraw.** `withdraw_amount = base_withdraw − early_fee`; the early-fee stays physically in vault → share price rises by `(early_fee / total_shares)` → remaining depositors benefit. R49 M-4 closed the prior accounting drift.
- **Compile-time Vault NFT anchor.** `vault_proxy` / `vusdcx` / `order` all parameterized on `vault_nft_policy` at deploy time, not datum. R55 C-1 closed the phantom-vUSDCx self-referential datum attack.
- **15 immutable VaultDatum fields.** `governance_policy` / `governance_name` / `keeper_pkh` / `fee_collector` / `vault_version` / `performance_fee_bps` / `early_withdraw_fee_bps` / `min_hold_seconds` / `buffer_target_bps` / `vusdcx_policy` / `deposit_token_policy` / `deposit_token_name` / `order_script_hash` / `registry_hash` / `registry_auth_policy`. The 16th anchor (`vault_nft_policy`) is stronger — compile-time, not datum. Note: `performance_fee_bps` is "immutable field" in the sense the schema position is fixed; the value adjusts within `[0, 450]` via Governance `UpdateFee`. See `contracts/docs/vault-state-machine.md` (or V1 spec/vault-datum.md) for full field semantics.
- **Governance cancel veto.** Every `QueueAction` has a 1-of-n `CancelAction` veto window; execution requires both m-of-n signatures AND action survives the timelock without cancellation.
- **Validity-range width cap.** Every time-writing redeemer (Compound / UpdateFee / RotateSigners / UpdateStrategy / SwapAda / RebalanceBuffer) caps `upper - now ≤ 1 hour` to bound timestamp-manipulation surface (R58 F-1).
- **Governance signer floor.** `valid_signer_set` requires `signers ≥ 3, threshold ≥ 2, threshold ≤ n, unique` (R51 H-1 + defense-in-depth).
- **Empty-hash governance delegation.** Documented design trade-off — see §"Known design decisions" below.

### Off-chain-dependent guarantees

The following depositor-facing promises depend on external infrastructure remaining available:

- **Withdraw settles in 1:1 USDCx.** Requires Cardano chain uptime + depositor wallet ADA for TX fees + Liqwid availability (if vault has Liqwid positions) + USDCx liquidity.
- **Share price tracks underlying yield accurately.** Requires keeper execution of periodic Compound cycles. If keeper is inactive for > 7 days, the 7-day waiver lets depositors exit without early-fee penalty (contract-enforced), but share price temporarily fails to reflect new Liqwid interest accrued during the dormancy window until a subsequent Compound.
- **Emergency self-serve recovery.** Requires Cardano chain + USDCx liquidity. The `emergency-withdraw` self-serve tool is packaged in the open-source source tree; any depositor can run it without operator coordination.

---

## Test coverage

| Category | Tests | Status |
|----------|------:|--------|
| Aiken unit tests (including 24 inline in `minswap_v2_adapter`) | 186 | All pass |
| Aiken property-based fuzz (`aiken/fuzz` v2.2.0) | 8 × ≤100 iter | All pass |
| Total via `aiken check` | 194 tests / 689 randomized checks | All pass |
| Preprod E2E scripts (`tests/preprod/`) | 16 scripts | See `EXECUTION-ORDER.md` — Phase B/C/D covered; E/F/H/I/J pending |
| Keeper vitest | 0 (implementation pending) | — |
| API vitest | 0 (not in V1 scope) | — |
| Frontend vitest | 0 (not in V1 scope) | — |

Preprod E2E verification state:
- **`v1-preprod-p3`** (2026-04-23, current): B1 Direct Deposit + B2 Partial Withdraw + A2 Queue on vault_user verified on-chain.
- **`v1-postphase77d-preprod`** (2026-04-22): B1-B9 + D1/D2/D4/D5/D6 + C1 + H1-H5 Queue/Cancel verified (Phase 84 session).

---

## Audit status

### Methodology

V1 uses a **coverage-area methodology** (areas A–F, see `docs/audit-scope.md §4`) for its internal audit history. This replaces the per-round numbering earlier internal-verification versions used. Coverage areas map to validator clusters + cross-validator integration flows rather than being tied to chronological audit rounds.

### Internal round history

Internal adversarial audit rounds executed against V1 contract code (additional rounds covered the internal-verification-phase heritage prior to V1 cutover — see `spec/architecture.md §4.1`):

| Round | Scope | Severity breakdown | Status |
|-------|-------|-------------------:|--------|
| R72 | Post-Phase-77d hacker-mindset on full V1 set (17 logic + 4 NFT + 1 adapter) | 0 CRIT / 0 HIGH / 1 MEDIUM / 3 LOW / 6 INFO | MEDIUM + 3 LOW fixed on-chain; INFO documented |
| R73 | `valid_allocs × vault_recall.MergeUtxo` admissibility gap | 0 CRIT / 0 HIGH / 1 MEDIUM | **FIXED** via `valid_merge_utxo_admissibility` in `lib/vault/validation.ak` + `vault_recall.MergeUtxo` invocation; 6 regression tests in `lib/vault/tests/r73_test.ak` |
| R74 | Phase O pre-mainnet Minswap V2 decoder byte-for-byte verification against real mainnet order | 0 CRIT / 1 HIGH / 0 MEDIUM | **FIXED** this commit — see R74 F-1 entry in "Recently fixed" below |

### Coverage-area status (pending external audit)

| Area | Scope | Status |
|------|-------|--------|
| A | Keeper authorization + stake-script state machine | Not started |
| B | Treasury + 4-bucket budget flows | Not started |
| C | Governance state machine + m-of-n + timelocks | Not started |
| D | Compound / fee split / keeper-gov-treasury triple flow | Not started |
| E | SwapAdapter dispatch + multi-DEX lifecycle | Not started |
| F | Cross-validator integration + full-drain + sunset paths | Not started |

### External audit

- **Target**: Q2-Q3 2027.
- **Candidate firms** (narrow list of teams with Plutus V3 + Aiken experience as of 2025-2026 publication): Anastasia Labs / MLabs / Certik-Cardano / TxPipe + independent Aiken reviewers. Final firm selection + scope will be publicly announced at least 2 weeks before engagement start.
- **Pre-engagement posture**: operator-enforced TVL cap of 100K USDCx (see whitepaper §8.2).

---

## Known open findings

_No currently open audit findings above LOW severity. See "Recently fixed" below for recently-closed entries._

---

## Recently fixed

### R74 F-1 — `minswap_v2_adapter` `lp_asset` decoder format mismatch (HIGH, FIXED)

**Discovery.** Phase O pre-mainnet Minswap V2 decoder byte-for-byte verification against a real mainnet 3-hop SwapMultiRouting order caught the adapter rejecting the order during decoding.

**Root cause.** `minswap_v2_adapter.ak::extract_target_from_lp` decoded the Minswap V2 order datum's `lp_asset` field as a 2-asset pair — either a 4-field flat `[policy_a, name_a, policy_b, name_b]` form or a 2-field nested `[Asset_a, Asset_b]` form. Real Minswap V2 `lp_asset` is a single LP-token identifier `Constr(0, [LP_policy_28B, LP_name_32B])` (the pool's LP-token asset, not its underlying pair). The nested-Constr branch invoked `un_constr_data` on the LP-name ByteArray and trapped in UPLC — every real Minswap V2 order would have been rejected on-chain.

**Severity rationale.** The adapter was effectively non-functional on mainnet, so no direct exploit was possible in the shipped form. But the class of bug — an adapter accepting DEX datums without independently verifying the swap's output asset — is a HIGH severity concern: a compromised keeper could in principle route vault stablecoins to an arbitrary non-whitelisted pool and deliver worthless tokens masquerading as the committed target asset. Graded HIGH and treated as a pre-mainnet blocker.

**Fix** (this commit): `SwapAdapterRedeemer` replaces the `target_asset_policy` + `target_asset_name` fields with `hop_chain: List<(ByteArray, ByteArray)>` — 2 entries for SwapExactIn (`[asset_in, target_out]`), N+1 entries for N-hop SwapMultiRouting. `minswap_v2_adapter.ak::compute_lp_asset_name` implements Minswap's canonical LP-name formula (`sha3_256(sha3_256(policy_a || name_a) || sha3_256(policy_b || name_b))`, with inputs canonically sorted policy-first-then-name). `verify_routing_chain` iterates each on-chain routing hop paired with adjacent `hop_chain` entries and rejects any TX where the on-chain LP name doesn't re-hash to the committed pair. `last_hop_target` exposes the chain's final entry for downstream Tier 2 peg-floor + optional Tier 1 oracle bound.

27 new tests exercise the formula (including Minswap's own test vector and three real mainnet LPs), chain-verification happy/failure paths, and structural rules (empty chain / single-entry / adjacent duplicates all rejected). `swap_test.ak` is updated to the new redeemer shape.

**Hash drift.** `minswap_v2_adapter`, `vault_protocol`, `vault_gov_emergency`, `vault_admin_deploy`, and the parameterised `vault_proxy` form all change. Any off-chain TX builder emitting the adapter redeemer must populate `hop_chain`.

Flagged for Q2-Q3 2027 external audit verification.

### R73 F-1 — `vault_recall.MergeUtxo` admissibility gap (MEDIUM, FIXED)

**Root cause.** `vault_recall.MergeUtxo` accepted deposit-token (USDCx) donations that pushed `idle_buffer` without bumping `total_deposited` / `non_deposit_value` / `liqwid_principal` correspondingly. Downstream, seven redeemers (`vault_keeper_hot.Compound`, `vault_protocol.DeployToProtocol`, `vault_recall.RecallFromProtocol`, `vault_liqwid` Supply/Recall, `vault_gov_policy.UpdateStrategy`, `vault_admin_deploy.AdminDeployNonDeposit`, `vault_gov_emergency.EmergencyWithdraw`) enforced an allocation invariant of `alloc_sum + idle_buffer ≤ RHS` where RHS was one of two forms (stricter `total_deposited` or looser `total_deposited + non_deposit_value + Σ liqwid_principal`). A donation that pushed `idle_buffer` past RHS bricked all seven until Compound yield caught up, giving an attacker sub-dollar-per-day sustained DoS on keeper + governance paths at Phase 1 TVL.

**Not fund theft** — donated USDCx accrued to existing depositors pro-rata on subsequent Withdraw activity; donor received nothing back. Attack class was DoS on operational + governance liveness, not principal loss. User `Withdraw` was never affected (no `validate_allocations` call on that path).

**Fix** (this commit): `valid_merge_utxo_admissibility` predicate in `lib/vault/validation.ak` enforces the looser-form invariant at the source of the state change (`vault_recall.MergeUtxo`). Guarding the looser form is strictly sufficient because NDV and Σ liqwid_principal are non-negative, so any post-merge state satisfying the looser form also satisfies the stricter form downstream. Attack prevented because the donation that would break the invariant is rejected at MergeUtxo time, so the vault never enters the broken state.

Six regression tests in `lib/vault/tests/r73_test.ak` cover: legitimate donation (pass), over-donation (reject), stable-token donation bumping NDV on both sides (pass), exact-boundary equality (pass), Liqwid principal contribution to RHS (pass), `alloc_sum` contribution to LHS with over-allocation (reject).

Flagged for Q2-Q3 2027 external audit verification.

---

## Known design decisions (documented, not findings)

### Withdraw allowed during Emergency Freeze

`vault_user.Withdraw` does **not** check `frozen == 0`. This is deliberate: depositor funds are never locked regardless of vault state. The `frozen` flag blocks operational actions that could compound incorrect accounting (Compound / BatchProcess / RebalanceBuffer / DeployToProtocol / SupplyToLiqwid), while Withdraw / RecallFromProtocol / RecallFromLiqwid / MergeUtxo remain available for fund recovery. The `idle_buffer ≥ base_withdraw` constraint naturally prevents over-withdrawal. Confirmed across multiple audit rounds.

### Governance empty-hash delegation

`multisig_gov.QueueAction` permits an empty `target_tx_hash` (`#""`), which lets m-of-n governance pre-authorize a `VaultAdmin` / `RegistryAdmin` capability that any 1-of-n signer can execute after the action kind's timelock (7-21 days depending on `ActionKind` per `lib/vault/constants.ak`).

This exists because `target_tx_hash` has an unavoidable circular dependency on the governance UTXO reference (TX body includes the queued datum which contains target_tx_hash — TX hash can't be known at queue time for actions whose executing TX hasn't been constructed yet).

**On-chain defenses retained during execution window**: `CancelAction` (1-of-n veto), `action_ttl_ms` 37-day absolute cap, `GovNFT == 1` uniqueness, target script must be a spent input, ADA preservation, all 15 immutable VaultDatum fields.

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
  deploy pipeline + keeper + API server + 22 compiled artefacts).
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
