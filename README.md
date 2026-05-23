# OptiVaults V1

![License](https://img.shields.io/badge/license-Apache%202.0-blue)
![Aiken](https://img.shields.io/badge/aiken-v1.1.x-red)
[![CI](https://github.com/OptiVaults/optivaults-protocol/actions/workflows/aiken-check.yml/badge.svg?branch=v1)](https://github.com/OptiVaults/optivaults-protocol/actions/workflows/aiken-check.yml)
![Audit Status](https://img.shields.io/badge/audit-pending%20Q2--Q3%202027-yellow)
![Mainnet](https://img.shields.io/badge/mainnet-pre--launch-orange)

> **Active development branch: `v1`.** There is no `main` branch — V1 is the first public release, and we use the version tag as the branch name by convention. Future major versions (V2, V3, ...) will live on their own parallel branches.

**OptiVaults V1 is a Cardano DeFi public-goods reference implementation — a non-custodial, on-chain auto-yield stablecoin vault, published as an open-source Apache-2.0-licensed reference for the Cardano DeFi commons. It is not optimized for commercial scale.** See whitepaper Executive Summary + §12 Disclosure for depositor-expectation framing, funding strategy, and regulatory posture.

This directory contains the V1 design, specification, implementation, and migration documentation. All content here is written for V1 on its own terms — it is not a carry-over or patch of prior versions.

---

## Two-layer architecture

OptiVaults V1 is intentionally split across **two repositories**, reflecting two fundamentally different things:

- **`optivaults-protocol`** (this repo) — the **protocol layer**. Aiken validators, protocol specification, whitepaper, deploy pipeline. **Zero fee** at this layer; any team may fork and launch their own vault without paying anything. Pure Cardano DeFi commons contribution.
- **[`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference)** — the **operator reference implementation**. TypeScript keeper, API server, frontend, CLI tools. Runs the `optivaults.app` live vault instance. Funded by the contract-enforced 4.5% performance fee (40% keeper / 60% treasury at launch — keeper share at the validator hard cap to support open-source third-party keeper viability; no founder dividend, no investor return, no token). Apache 2.0 — forks welcome.

The **4.5% fee happens only at the operator layer**. The protocol itself costs nothing to use if you run your own instance. See `docs/economics.md` for the full fee breakdown and `docs/security-model.md §2` for the trust model across the two layers.

---

## Version definition

- **V1** — First public production release. Designed, specified, and audited as an independent product. Entry point for public depositors.
- **Prior versions (Internal verification phase)** — Internal verification phase. Sequence of architectural iterations that ran on Cardano mainnet under a pre-audit 100K USDCx cap to validate contract invariants under real market conditions. internal-verification phase is the final internal verification version and will be sunset upon V1 mainnet launch.

V1 is not "internal verification with patches" — it is a standalone release with its own architecture, its own audit history (V1 pre-launch internal rounds + Q2-Q3 2027 third-party audit), and its own public launch criteria.

---

## V1 core properties (summary)

OptiVaults V1 is characterized by the following architectural decisions. Each is expanded in its own document under this directory.

1. **Non-custodial on-chain vault** — user funds are controlled exclusively by Aiken PlutusV3 smart contracts; no operator key can extract principal.
2. **USDCx as deposit asset** — Cardano-native USD-pegged stablecoin issued by Circle via its xReserve crosschain reserve mechanism. The vault routes deposits to Liqwid Finance stablecoin markets (DJED, USDM) and Minswap V2 DEX paths for diversified yield.
3. **Governance by m-of-n MultisigGov** — all protocol-policy changes (strategy, fee rate, emergency freeze) gated by multi-signature with 7-day timelock and 1-of-n cancel veto.
4. **On-chain treasury** — 60% of performance-fee revenue flows to a governance-managed treasury contract with contract-enforced category buckets (audit reserve / operations / R&D / operational buffer; launch sub-allocation 40/25/25/10 keeps audit-reserve accumulation rate at 24% of total fee — same as the prior 80%×30% allocation).
5. **Stake-validator keeper authorization** — keeper operations are authenticated via a stake validator with a mode flag, allowing the authorization rules to evolve (governance-approved list → permissionless-with-bond) without redeploying the main vault contracts.
6. **40% keeper fee share** — executing keeper receives 40% of performance fee per Compound as operational compensation (validator hard cap); 60% to treasury. Set high to support post-audit Phase 2+ third-party keeper viability under the public-goods positioning.
7. **User-set batch tip** — Order UTXO carries a user-specified maximum tip; keepers collect within that bound when processing batched orders.
8. **Withdraw-Zero forwarding pattern** — single vault UTXO delegates to 10 staking validators (`vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`) via `vault_proxy` for size compliance and clean role separation. Partitioning rationale (4 orthogonal seams: authorization-boundary, governance response-latency, bytecode-cost-center, size-fix) is documented in `spec/architecture.md §4.1`. Every staking credential (the 10 Withdraw-Zero dispatched validators + `keeper_stake_script` + `minswap_v2_adapter` SwapAdapter + `sundaeswap_adapter` + `sundaeswap_cancel_guard` = 14 total) carries its own A2 `publish` handler, so all 14 stake-registration deposits are reclaimable at sunset via governance.
9. **Compile-time trust anchors** — Vault Identity NFT, governance NFT policy, treasury script, and keeper stake script all baked into validator script hashes at deploy time, not datum fields.
10. **Pre-audit TVL cap** — operator-enforced 100K USDCx ceiling until the Q2-Q3 2027 external audit completes; post-audit cap schedule disclosed with audit report.
11. **Public-goods positioning** — V1 is framed as a non-commercial public-goods reference implementation. The 4.5% performance fee covers operations + audit reserve + long-term runway, not founder/investor revenue. Apache 2.0 license enables forks and specializations (different stablecoin mixes, risk postures, regional variants). V1 may be the terminal state, or the basis on which other Cardano DeFi teams build — both are acceptable outcomes. Depositors enter with a "contributing to a public good + early validator" mindset, not as purchasers of a commercial service. See whitepaper §12 Disclosure for full implications.

---

## Further reading

The [`docs/articles/`](docs/articles/) directory contains long-form narrative explanations of V1's design choices, complementing the formal spec in `spec/` with the *why* behind specific decisions. The first series — [Architecture (4 parts)](docs/articles/architecture/) — covers the four eUTXO design constraints, the Withdraw-Zero Forwarding Pattern, the 17-validator split, and the compile-time Vault NFT anchor. ~25 min total reading time.

Articles are mirrored on Medium with canonical URLs pointing back to this repository.

V1 also publishes **pattern-rationale notes** for five recurring Cardano DeFi patterns it implements: Validator Identity NFT, MultiSig Governance + Timelock, Withdraw-Zero Forwarding, Registry + Auth NFT Whitelist, and VaultDatum Tiered Immutability. Each note describes the pattern in generic terms and cites the V1 instantiation as a concrete example. See [`docs/cip-readiness-posture.md`](docs/cip-readiness-posture.md) for the project's posture toward the Cardano Improvement Proposal process — V1 prepares pattern documentation but does not submit a CIP at the V1 release stage — and [`spec/pattern-rationale-*.md`](spec/) for the five per-pattern notes.

---

## Directory layout

```
.
├── README.md                   This file
├── spec/                       V1 protocol specification
│   ├── architecture.md         High-level protocol architecture (incl. §4.1 split history)
│   ├── vault-datum.md          VaultDatum fields, invariants, transitions (29 fields)
│   ├── treasury.md             Treasury contract specification
│   ├── keeper-auth.md          Keeper stake-validator specification
│   ├── order-batch.md          Order + BatchProcess + user-tip specification
│   ├── governance.md           MultisigGov actions + timelock rules (14 ActionKind variants)
│   ├── multisig-gov.md         MultisigGov internals + is_gov_authorized cross-validator predicate
│   ├── gov-nft.md              Governance signer soul-bound NFT
│   ├── ada-swap.md             SwapAda redeemer + dual-feed oracle reader
│   ├── vault-nft.md            Vault Identity NFT one-shot mint pattern
│   ├── swap-adapter.md         SwapAdapter interface + B@launch=1 post-launch DEX addition lifecycle
│   ├── pattern-rationale-validator-identity-nft.md     Generic Validator Identity NFT pattern (V1 case study)
│   ├── pattern-rationale-multisig-gov-timelock.md      Generic m-of-n + timelock + cancel veto pattern
│   ├── pattern-rationale-withdraw-zero-forwarding.md   Generic Withdraw-Zero Forwarding pattern (size + per-TX-fee split)
│   ├── pattern-rationale-registry-auth-nft.md          Generic governance-mutable whitelist + auth NFT pattern
│   └── pattern-rationale-vault-datum-tiered.md         Generic tiered-immutability datum pattern
├── contracts/                  V1 Aiken PlutusV3 source — 17 logic validators + 4 NFT mint policies + `minswap_v2_adapter` + 2 SundaeSwap artefacts; `aiken check` passing (run against the deployed commit for the current test summary)
├── deploy/                     Deploy pipeline
│   ├── README.md               Deploy pipeline overview + checklist
│   ├── deploy.ts               Single-command ceremony orchestrator (idempotent + resumable)
│   ├── compile.ts              Offline hash derivation (applyParams across 24 artefacts)
│   ├── lib/                    blockfrostProvider + config loader + state file + datum builders + ref-script deploy + phase helpers
│   ├── config/                 preprod.example.json + mainnet.example.json (templates) + preprod-mock.json (operator-supplied real configs are gitignored)
│   ├── state/                  Ceremony state checkpoints (gitignored — per-releaseTag JSON)
│   ├── tools/                  Operator CLI
│   │   ├── deregister-stakes.ts        Legacy (pre-A2)
│   │   ├── derive-gov-signers.ts       PKH derivation helper
│   │   ├── whoami-preprod.ts           Wallet sanity print
│   │   ├── a2-queue-deregister.ts      A2 Queue (idempotent)
│   │   ├── a2-execute-deregister.ts    A2 Execute (idempotent)
│   │   ├── a2-cancel-deregister.ts     A2 Cancel (idempotent)
│   │   ├── h-emergency-benign.ts       ActEmergencyWithdraw(0,0) Queue+Execute smoke
│   │   ├── verify-minswap-v2-decode.ts Off-chain Minswap V2 order decoder verifier
│   │   ├── reclaim-refs.ts             Ref-script ADA reclaim at sunset
│   │   ├── full-drain-test.ts          SUPERSEDED (pre-Phase-77 topology)
│   │   ├── mock-full-drain-deploy.ts   SUPERSEDED (pre-Phase-77 topology)
│   │   ├── sunset-ceremony.ts          Orchestrate full-sunset flow
│   │   └── SUNSET_RUNBOOK.md           Operator sunset SOP
│   └── runbooks/
│       └── v1-mainnet-ceremony.md      V1 mainnet deploy runbook (pre-flight + phases + failure handling + sunset)
├── docs/
│   ├── product-overview.md     Pragmatic user-facing overview (EN) — what you deposit, what you receive, risks in user terms
│   ├── product-overview-zh-TW.md  繁體中文 product overview
│   ├── migration.md            internal verification sunset → V1 depositor transition
│   ├── economics.md            Fee structure, treasury flows, sustainability math
│   ├── security-model.md       Trust boundaries, threat model, known residual risks
│   ├── audit-scope.md          Pre-audit internal round plan + external audit scope
│   ├── integration-playbook.md Operator SOP for adding new DEX routes / Liqwid markets
│   ├── contributor-program.md  Open-source contributor rewards (Phase 2+ activation)
│   ├── cip-readiness-posture.md   V1's posture toward the Cardano Improvement Proposal process (informational)
│   └── articles/               Long-form narrative architecture walkthrough (4-part series, bilingual)
├── tests/
│   └── preprod-e2e-plan.md     Specification-level scenario catalog (100+); executable TS scripts live in `optivaults-reference` (operator repo)
└── whitepaper/
    ├── whitepaper.md           V1 public whitepaper (EN)
    └── whitepaper-zh-TW.md     V1 public whitepaper (繁體中文)
```

Each document is written as a standalone V1 reference. No document in this tree assumes the reader has read prior-version documentation.

---

### Development history note

This repository was published as the V1 branch in April 2026, consolidating roughly 1,000+ commits of prior internal-verification-phase iterations. The internal-verification phase context is covered in `spec/architecture.md §4.1` (partitioning history) and `docs/migration.md` (sunset plan).

For audit engagement: the V1 audit baseline will be the v1-branch commit pinned at the time the engagement letter is signed. Earlier development history is available on request under informal confidentiality.

---

## Status

V1 is in **mainnet pre-flight phase**:

- ✅ Spec / docs / whitepaper complete (15 markdown files under `spec/` + `docs/` + `whitepaper/`).
- ✅ All 17 Aiken logic validators + 4 NFT mint policies + `minswap_v2_adapter` + 2 SundaeSwap artefacts implemented and `aiken check` passes (`contracts/`). Partitioning rationale documented in `spec/architecture.md` §4.1. `UpdateSlippagePolicy` + 2 VaultDatum fields (§5.4 Phase 2) and ref-script SwapAdapter dispatch + `minswap_v2_adapter` + Registry `swap_adapter_hashes` (§B@launch=1) all on-chain.
- ✅ Unit + property test suite — `aiken check` passes against the deployed commit (run `cd contracts && aiken check` for the current summary; property tests use `aiken/fuzz` iteration discipline with early-exit on first failure).
- ✅ Preprod E2E test plan drafted (`tests/preprod-e2e-plan.md`) with 100+ scenarios across all vault validators + 4 NFT one-shot policies + cross-validator integration flows.
- ✅ Preprod E2E test scripts — multi-phase coverage including ceremony health + user flows (Deposit / Withdraw / Queue / Batch / Order Cancel+Expire / Queued-Withdraw) + zero-yield Compound + MergeUtxo donation paths (including negative-path rejections) + governance state-machine flows + oracle / SwapAdapter chain replay. Scripts published in the operator reference repo.
- ✅ Multiple Preprod ceremonies executed — 42 TX per ceremony, all phases verified on-chain. Recent ceremonies have exercised governance Queue/Execute multisig flows, mock-Liqwid Supply/Recall/Compound/Distribute end-to-end, oracle E2E with stale-feed / disagreement / no-entry rejection paths, and the attacker-recipient chain-replay defence.
- ✅ A2 governance-gated stake deregister tools (`deploy/tools/a2-{queue,execute,cancel}-deregister.ts`) with idempotency + CBOR-Constr payload encoding.
- ✅ Mainnet ceremony runbook drafted (`deploy/runbooks/v1-mainnet-ceremony.md`, 501 lines) — capital budget + pre-flight + phase-by-phase + partial-failure handling + post-ceremony backfill + sunset path.
- ✅ Off-chain byte-for-byte decoder `deploy/tools/verify-minswap-v2-decode.ts` exposes the Minswap V2 adapter's decode logic for pre-mainnet decode verification against historical on-chain TXs without re-submitting.
- ⏳ Keeper reference implementation — lives in `optivaults-reference` (operator repo), not started.
- ⏳ Internal audit rounds (coverage areas A-F, see `docs/audit-scope.md`) — multiple internal adversarial rounds complete, organised by coverage area; all non-INFO findings surfaced to date resolved in code with regression tests added (`SECURITY.md` carries the qualitative summary). Third-party audit pending.
- ⏳ External audit engagement — target Q2-Q3 2027, firm not yet selected.

### Preprod deploy status

Multiple Preprod ceremonies have been executed against the V1 contract set to exercise the full deploy pipeline + governance state machine + Liqwid integration + SwapAdapter dispatch + oracle E2E. Each ceremony's per-validator hashes and on-chain TX evidence are captured in the ceremony's state JSON under `deploy/state/<network>-<release-tag>.json` (operator-only, gitignored). The most recent ceremony's `mainnet-hash-preview.txt` snapshot is regenerated via `deploy/tools/verify-mainnet-build.sh` (which now includes a pre-flight TIMELOCK_MS audit gate on every `h-*.ts` operator tool).

Stake-registration deposits (14 × 2 ADA = 28 ADA per ceremony) + ref-script min-ADA lockups (~962 ADA per ceremony) are reclaimable via `deploy/tools/a2-{queue,execute}-deregister.ts` + `deploy/tools/reclaim-refs.ts`, contingent on the A2 governance flow (14d production timelock).

Compiled validator sizes — all 24 artefacts remain under the 16 KB Plutus V3 ceiling. The exact per-validator bytes at any commit are reproducible via `cd contracts && aiken build && node -e "..."` against `plutus.json`; we intentionally do not pin specific sizes in this document so it does not drift relative to the source of truth as the contract surface evolves across audit-round fixes.

See [docs/audit-scope.md](docs/audit-scope.md) for the development / audit / launch timeline.

---

## License

OptiVaults V1 is released under the **Apache License, Version 2.0**. This repo (`optivaults-protocol`) covers the protocol layer — smart contracts, deploy pipeline, CLI tools, and documentation. The operator layer (keeper reference implementation, API server, frontend, preprod E2E scripts) lives in the sibling repo [`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference) under the same Apache 2.0 license. Any team may fork, specialize, or integrate V1's architecture into derivative products consistent with the Apache 2.0 terms (see [LICENSE](../LICENSE)).

The permissive license choice is deliberate: V1's success metric explicitly includes the architecture being forked and specialized by other Cardano teams (see whitepaper §1 "Why we do this"). Restricting reuse during a pre-audit validation phase would contradict that contribution-oriented posture.

---

## Contact

- Website: [optivaults.app](https://optivaults.app)
- Protocol repo (this repo): [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol) (branch `v1`)
- Operator reference repo: [github.com/OptiVaults/optivaults-reference](https://github.com/OptiVaults/optivaults-reference) (branch `v1`)
- Security (protocol-layer): optivaults@gmail.com — see `SECURITY.md`
- Security (operator-layer): see [`optivaults-reference/SECURITY.md`](https://github.com/OptiVaults/optivaults-reference/blob/v1/SECURITY.md)
