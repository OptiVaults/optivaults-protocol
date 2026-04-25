# OptiVaults V1

![License](https://img.shields.io/badge/license-Apache%202.0-blue)
![Aiken](https://img.shields.io/badge/aiken-v1.1.x-red)
[![CI](https://github.com/OptiVaults/optivaults-protocol/actions/workflows/aiken-check.yml/badge.svg?branch=v1)](https://github.com/OptiVaults/optivaults-protocol/actions/workflows/aiken-check.yml)
![Tests](https://img.shields.io/badge/tests-144%20passing-brightgreen)
![Checks](https://img.shields.io/badge/randomized%20checks-639-brightgreen)
![Audit Status](https://img.shields.io/badge/audit-RFP%20in%20progress-yellow)
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
8. **Withdraw-Zero forwarding pattern** — single vault UTXO delegates to 10 staking validators (`vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`) via `vault_proxy` for size compliance and clean role separation. Partitioning rationale (4 orthogonal seams: authorization-boundary, governance response-latency, bytecode-cost-center, size-fix) is documented in `spec/architecture.md §4.1`. Every staking credential (the 10 Withdraw-Zero dispatched validators + `keeper_stake_script` + `minswap_v2_adapter` SwapAdapter = 12 total) carries its own A2 `publish` handler, so all 12 stake-registration deposits are reclaimable at sunset via governance.
9. **Compile-time trust anchors** — Vault Identity NFT, governance NFT policy, treasury script, and keeper stake script all baked into validator script hashes at deploy time, not datum fields.
10. **Pre-audit TVL cap** — operator-enforced 100K USDCx ceiling until the Q2-Q3 2027 external audit completes; post-audit cap schedule disclosed with audit report.
11. **Public-goods positioning** — V1 is framed as a non-commercial public-goods reference implementation. The 4.5% performance fee covers operations + audit reserve + long-term runway, not founder/investor revenue. Apache 2.0 license enables forks and specializations (different stablecoin mixes, risk postures, regional variants). V1 may be the terminal state, or the basis on which other Cardano DeFi teams build — both are acceptable outcomes. Depositors enter with a "contributing to a public good + early validator" mindset, not as purchasers of a commercial service. See whitepaper §12 Disclosure for full implications.

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
│   └── swap-adapter.md         SwapAdapter interface + B@launch=1 post-launch DEX addition lifecycle
├── contracts/                  V1 Aiken PlutusV3 source — 17 logic validators + 4 NFT mint policies + 1 DEX adapter; 144 unit + property tests / 639 randomized checks; `aiken check` clean
├── keeper/                     V1 keeper reference implementation (pending)
├── deploy/                     Deploy pipeline
│   ├── deploy.ts               Single-command ceremony orchestrator (idempotent + resumable)
│   ├── compile.ts              Offline hash derivation (applyParams across 22 artefacts)
│   ├── lib/                    blockfrostProvider + config loader + state file + datum builders + phase helpers
│   ├── config/                 preprod.json (real) + mainnet.example.json (template) + preprod-mock.json
│   ├── state/                  Ceremony state checkpoints (gitignored — per-releaseTag JSON)
│   ├── tools/                  Operator CLI
│   │   ├── deregister-stakes.ts        Legacy (pre-A2)
│   │   ├── derive-gov-signers.ts       PKH derivation helper
│   │   ├── whoami-preprod.ts           Wallet sanity print
│   │   ├── a2-queue-deregister.ts      A2 Queue (idempotent — Phase 84 backport)
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
│   └── contributor-program.md  Open-source contributor rewards (Phase 2+ activation)
├── tests/
│   ├── preprod-e2e-plan.md     Specification-level scenario catalog (100+)
│   └── preprod/                Executable TS scripts (16 scripts — Phase B + C + D coverage;
│                                  Phase E/F/H/I/J pending)
│       ├── 00-ceremony-health.ts
│       ├── 10-deposit-direct.ts
│       ├── 11-withdraw-direct-partial.ts
│       ├── 12-withdraw-full-drain.ts
│       ├── 13-queue-deposit-order.ts
│       ├── 14-batch-process-single.ts
│       ├── 15-batch-multi-order.ts
│       ├── 16-order-cancel.ts
│       ├── 17-order-expire.ts
│       ├── 18-withdraw-queue-batch.ts
│       ├── 20-compound-zero-yield.ts
│       ├── 30-merge-ada-donation.ts
│       ├── 31-merge-deposit-token.ts
│       ├── 32-merge-multi-secondary.ts
│       ├── 33-merge-reject-datum.ts              (NEGATIVE path)
│       ├── 34-merge-reject-garbage-token.ts      (NEGATIVE path)
│       ├── helpers.ts
│       └── EXECUTION-ORDER.md
└── whitepaper/
    ├── whitepaper.md           V1 public whitepaper (EN)
    └── whitepaper-zh-TW.md     V1 public whitepaper (繁體中文)
```

Each document is written as a standalone V1 reference. No document in this tree assumes the reader has read prior-version documentation.

---

### Development history note

This repository was initialized at the **`v1-postphase77d-preprod`** release tag on 2026-04-22. The codebase has earlier development history (~1,000+ commits across prior internal-verification-phase iterations) that was consolidated at V1 cutover. The internal-verification phase is covered in `spec/architecture.md §4.1` (partitioning history) and `docs/migration.md` (sunset plan).

For audit engagement: the V1 audit baseline is the `v1-postphase77d-preprod` tag. Earlier development history is available on request under informal confidentiality.

---

## Status

V1 is in **early implementation phase**:

- ✅ Spec / docs / whitepaper complete (15 markdown files under `spec/` + `docs/` + `whitepaper/`).
- ✅ All 17 Aiken logic validators + 4 NFT mint policies + 1 DEX adapter (`minswap_v2_adapter`, §B@launch=1 SwapAdapter) implemented and `aiken check` passes (`contracts/`). Partitioning rationale documented in `spec/architecture.md` §4.1. `UpdateSlippagePolicy` + 2 VaultDatum fields (§5.4 Phase 2) and ref-script SwapAdapter dispatch + `minswap_v2_adapter` + Registry `swap_adapter_hashes` (§B@launch=1) all on-chain.
- ✅ Unit + property test suite — **144 tests passing, 639 total checks per `aiken check` run** (8 property tests × up to 100 iterations + deterministic cases including R72 + R73 + R74 regression coverage; R74 adds 24 inline tests in `minswap_v2_adapter` plus `tests/r74_test.ak` with 10 structural tests).
- ✅ Preprod E2E test plan drafted (`tests/preprod-e2e-plan.md`) with 100+ scenarios across all vault validators + 4 NFT one-shot policies + cross-validator integration flows.
- ✅ Preprod E2E test scripts (`tests/preprod/*.ts`) — 16 scripts covering ceremony health + Phase B (Deposit / Withdraw / Queue / Batch / Order Cancel+Expire / Queued-Withdraw) + Phase C (zero-yield Compound) + Phase D (MergeUtxo donation paths including 2 negative-path rejections). Phase E (real Minswap V2) / Phase F (mock Liqwid stack) / Phase H (governance state machine) pending.
- ✅ Two Preprod ceremonies executed — see "Preprod deploy status" below. 38 TX per ceremony, all phases verified on-chain.
- ✅ A2 governance-gated stake deregister tools (`deploy/tools/a2-{queue,execute,cancel}-deregister.ts`) with idempotency + CBOR-Constr payload encoding.
- ✅ Mainnet ceremony runbook drafted (`deploy/runbooks/v1-mainnet-ceremony.md`, 501 lines) — capital budget + pre-flight + phase-by-phase + partial-failure handling + post-ceremony backfill + sunset path.
- ✅ Off-chain byte-for-byte decoder `deploy/tools/verify-minswap-v2-decode.ts` exposes the Minswap V2 adapter's decode logic for pre-mainnet decode verification against historical on-chain TXs without re-submitting.
- ⏳ Keeper reference implementation (`keeper/`) — not started.
- ⏳ Internal audit rounds (coverage areas A-F, see `docs/audit-scope.md`) — R72 (post-Phase-77d, 1 MEDIUM + 3 LOW fixed), R73 (`valid_allocs × MergeUtxo` donation gap, 1 MEDIUM fixed), and R74 (pre-mainnet Minswap V2 decoder `lp_asset` format mismatch, 1 HIGH fixed — see `SECURITY.md §"Recently fixed"`) complete; areas A-F walkthrough pending.
- ⏳ External audit engagement — target Q2-Q3 2027, firm not yet selected.

### Preprod deploy status

| Release tag | Date | Vault address | Vault NFT policy | Notes |
|-------------|------|---------------|------------------|-------|
| `v1-preprod-p3` | 2026-04-23 | `addr_test1wz87t7qnkpk3cgy2057rsrnsz6px88ks23y3ktd46q0jzfg5zfddz` | `7a0eea53cfa90b949009729bd0eaa73e3cb9f2f8056cc235d57218c5` | Current. Ceremony after timelock constants shrunk to 60s for Preprod E2E iteration speed. B1 Deposit + B2 Partial Withdraw + A2 Queue on vault_user all verified on-chain. |
| `v1-postphase77d-preprod` | 2026-04-22 | `addr_test1wqca8hpe87tcfx0r0q7ju3uxf2thpr4jjcyjg44cc8kpvngysgja2` | — | Pre-timelock-shrink ceremony. Phase 84 E2E B1-B9 + D1/D2/D4/D5/D6 + C1 + H1-H5 Queue/Cancel verified on-chain. |

Both ceremonies' stake-registration deposits (12 × 2 ADA = 24 ADA per ceremony) + ref-script min-ADA lockups (~870 ADA per ceremony) are reclaimable via `deploy/tools/a2-{queue,execute}-deregister.ts` + `deploy/tools/reclaim-refs.ts`, contingent on the A2 governance flow (14d production timelock; 1h Preprod override for ceremony iteration).

Compiled validator sizes (all under the 16 KB PlutusV3 limit, sorted largest → smallest). Measured from the **current** `v1-preprod-p3` build; `timelock_*_ms` constants currently at Preprod override 60s for 11 action kinds (all governance paths except `timelock_emergency_ms=0`, `timelock_fast_update_markets_ms=1h`, `timelock_deregister_stake_ms=1h`). Production timelocks (7-21d) MUST be restored before any mainnet build — see `constants.ak` header note + `deploy/runbooks/v1-mainnet-ceremony.md` §0.

| Validator | Size (bytes) | Headroom |
|-----------|-------------:|---------:|
| vault_liqwid | 13,392 | 2,992 B |
| vault_recall | 13,337 | 3,047 B |
| vault_admin_deploy | 13,157 | 3,227 B |
| vault_protocol | 13,130 | 3,254 B |
| vault_gov_policy | 12,584 | 3,800 B |
| vault_keeper_hot | 12,381 | 4,003 B |
| vault_swap_ada | 12,164 | 4,220 B |
| vault_user | 11,885 | 4,499 B |
| vault_batcher | 11,553 | 4,831 B |
| vault_gov_emergency | 10,861 | 5,523 B |
| treasury | 9,851 | 6,533 B |
| keeper_stake_script | 8,774 | 7,610 B |
| registry | 8,504 | 7,880 B |
| multisig_gov | 8,233 | 8,151 B |
| minswap_v2_adapter | 5,020 | 11,364 B |
| vault_proxy | 4,912 | 11,472 B |
| order | 3,788 | 12,596 B |
| vusdcx | 1,255 | 15,129 B |
| gov_signer_nft | 399 | 15,985 B |
| vault_nft | 337 | 16,047 B |
| governance_nft | 319 | 16,065 B |
| registry_auth_nft | 319 | 16,065 B |

Tightest headroom is `vault_liqwid` at 2,992 B free (18.3% from ceiling). Production-timelock rebuild will shift `multisig_gov` back up by ~100-200 B (const-inlined constants are larger) but does not change non-multisig_gov validator hashes.

See [docs/audit-scope.md](docs/audit-scope.md) for the development / audit / launch timeline.

---

## License

OptiVaults V1 is released under the **Apache License, Version 2.0**. This applies to the entire repository — smart contracts, keeper reference implementation, API server, frontend, CLI tools, and documentation. Any team may fork, specialize, or integrate V1's architecture into derivative products consistent with the Apache 2.0 terms (see [LICENSE](../LICENSE)).

The permissive license choice is deliberate: V1's success metric explicitly includes the architecture being forked and specialized by other Cardano teams (see whitepaper §1 "Why we do this"). Restricting reuse during a pre-audit validation phase would contradict that contribution-oriented posture.

---

## Contact

- Website: [optivaults.app](https://optivaults.app)
- Protocol repo (this repo): [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol) (branch `v1`)
- Operator reference repo: [github.com/OptiVaults/optivaults-reference](https://github.com/OptiVaults/optivaults-reference) (branch `v1`)
- Security (protocol-layer): optivaults@gmail.com — see `SECURITY.md`
- Security (operator-layer): see [`optivaults-reference/SECURITY.md`](https://github.com/OptiVaults/optivaults-reference/blob/v1/SECURITY.md)
