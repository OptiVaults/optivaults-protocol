# OptiVaults V1

**OptiVaults V1 is a Cardano DeFi public-goods reference implementation — a non-custodial, on-chain auto-yield stablecoin vault, published as an open-source Apache-2.0-licensed reference for the Cardano DeFi commons. It is not optimized for commercial scale.** See whitepaper Executive Summary + §12 Disclosure for depositor-expectation framing, funding strategy, and regulatory posture.

This directory contains the V1 design, specification, implementation, and migration documentation. All content here is written for V1 on its own terms — it is not a carry-over or patch of prior versions.

---

## Version definition

- **V1** — First public production release. Designed, specified, and audited as an independent product. Entry point for public depositors.
- **Prior versions (Internal verification phase)** — Internal verification phase. Sequence of architectural iterations that ran on Cardano mainnet under a pre-audit 100K USDCx cap to validate contract invariants under real market conditions. internal-verification phase is the final internal verification version and will be sunset upon V1 mainnet launch.

V1 is not "internal verification with patches" — it is a standalone release with its own architecture, its own audit history (V1 pre-launch internal rounds + Q3 2026 third-party audit), and its own public launch criteria.

---

## V1 core properties (summary)

OptiVaults V1 is characterized by the following architectural decisions. Each is expanded in its own document under this directory.

1. **Non-custodial on-chain vault** — user funds are controlled exclusively by Aiken PlutusV3 smart contracts; no operator key can extract principal.
2. **USDCx as deposit asset** — Cardano-native USD-pegged stablecoin issued by Circle via its xReserve crosschain reserve mechanism. The vault routes deposits to Liqwid Finance stablecoin markets (DJED, USDM) and Minswap V2 DEX paths for diversified yield.
3. **Governance by m-of-n MultisigGov** — all protocol-policy changes (strategy, fee rate, emergency freeze) gated by multi-signature with 7-day timelock and 1-of-n cancel veto.
4. **On-chain treasury** — 80% of performance-fee revenue flows to a governance-managed treasury contract with contract-enforced category buckets (audit reserve / operations / R&D / operational buffer).
5. **Stake-validator keeper authorization** — keeper operations are authenticated via a stake validator with a mode flag, allowing the authorization rules to evolve (governance-approved list → permissionless-with-bond) without redeploying the main vault contracts.
6. **20% keeper fee share** — executing keeper receives 20% of performance fee per Compound as operational compensation; 80% to treasury.
7. **User-set batch tip** — Order UTXO carries a user-specified maximum tip; keepers collect within that bound when processing batched orders.
8. **Withdraw-Zero forwarding pattern** — single vault UTXO delegates to 10 staking validators (`vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`) via `vault_proxy` for size compliance and clean role separation. Partitioning rationale (4 orthogonal seams: authorization-boundary, governance response-latency, bytecode-cost-center, size-fix) is documented in `spec/architecture.md §4.1`. Every staking credential (the 10 Withdraw-Zero dispatched validators + `keeper_stake_script` + `minswap_v2_adapter` SwapAdapter = 12 total) carries its own A2 `publish` handler, so all 12 stake-registration deposits are reclaimable at sunset via governance.
9. **Compile-time trust anchors** — Vault Identity NFT, governance NFT policy, treasury script, and keeper stake script all baked into validator script hashes at deploy time, not datum fields.
10. **Pre-audit TVL cap** — operator-enforced 100K USDCx ceiling until the Q3 2026 external audit completes; post-audit cap schedule disclosed with audit report.
11. **Public-goods positioning** — V1 is framed as a non-commercial public-goods reference implementation. The 4.5% performance fee covers operations + audit reserve + long-term runway, not founder/investor revenue. Apache 2.0 license enables forks and specializations (different stablecoin mixes, risk postures, regional variants). V1 may be the terminal state, or the basis on which other Cardano DeFi teams build — both are acceptable outcomes. Depositors enter with a "contributing to a public good + early validator" mindset, not as purchasers of a commercial service. See whitepaper §12 Disclosure for full implications.

---

## Directory layout

```
optivaults-protocol/
├── README.md                   This file
├── LICENSE                     Apache License, Version 2.0
├── contracts/                  V1 Aiken PlutusV3 source — 17 logic validators + 4 NFT mint policies + 1 DEX adapter; 104 unit + property tests / 599 randomized checks; `aiken check` clean
├── spec/                       V1 protocol specification
│   ├── architecture.md         High-level protocol architecture
│   ├── vault-datum.md          VaultDatum fields, invariants, transitions
│   ├── treasury.md             Treasury contract specification
│   ├── keeper-auth.md          Keeper stake-validator specification
│   ├── order-batch.md          Order + BatchProcess + user-tip specification
│   ├── governance.md           MultisigGov actions + timelock rules
│   ├── multisig-gov.md         Multisig internals
│   ├── gov-nft.md              Governance NFT one-shot design
│   ├── vault-nft.md            Vault Identity NFT design
│   ├── ada-swap.md             ADA top-up oracle + SwapAda redeemer
│   └── swap-adapter.md         Ref-script dispatched DEX adapter interface
├── docs/
│   ├── product-overview.md     Pragmatic user-facing overview (EN) — what you deposit, what you receive, risks in user terms
│   ├── product-overview-zh-TW.md  繁體中文 product overview
│   ├── migration.md            internal verification sunset → V1 depositor transition
│   ├── economics.md            Fee structure, treasury flows, sustainability math
│   ├── security-model.md       Trust boundaries, threat model, known residual risks
│   ├── audit-scope.md          Pre-audit internal round plan + external audit scope
│   ├── integration-playbook.md Operator SOP for adding new DEX routes / Liqwid markets
│   └── contributor-program.md  Open-source contributor rewards (Phase 2+ activation)
├── deploy/                     Reproducible ceremony: compile + 5-phase deploy orchestrator + tools (reclaim-refs, sunset-ceremony, derive-gov-signers, full-drain helpers) + config templates (preprod-mock, preprod.example, mainnet.example)
├── tests/                      V1 regression tests — unit suite under `contracts/lib/vault/tests/`; Preprod E2E plan `preprod-e2e-plan.md` drafted; Preprod TS scripts pending
└── whitepaper/
    ├── whitepaper.md           V1 public whitepaper (EN)
    └── whitepaper-zh-TW.md     V1 public whitepaper (繁體中文)
```

**Note:** keeper reference implementation lives in a separate repository. See `docs/integration-playbook.md` for operator integration.

Each document is written as a standalone V1 reference. No document in this tree assumes the reader has read prior-version documentation.

---

## Status

V1 is in **early implementation phase**:

- ✅ Spec / docs / whitepaper complete (15 markdown files under `spec/` + `docs/` + `whitepaper/`).
- ✅ All 17 Aiken logic validators + 4 NFT mint policies + 1 DEX adapter (`minswap_v2_adapter`, §B@launch=1 SwapAdapter) implemented and `aiken check` passes (`contracts/`). Partitioning rationale documented in `spec/architecture.md` §4.1. `UpdateSlippagePolicy` + 2 VaultDatum fields (§5.4 Phase 2) and ref-script SwapAdapter dispatch + `minswap_v2_adapter` + Registry `swap_adapter_hashes` (§B@launch=1) all on-chain.
- ✅ Unit + property test suite — **104 tests passing, 599 total checks per `aiken check` run** (8 property tests × up to 100 iterations + deterministic cases including R72 regression coverage).
- ✅ Preprod E2E test plan drafted (`tests/preprod-e2e-plan.md`) with 100+ scenarios across all vault validators + 4 NFT one-shot policies + cross-validator integration flows. First end-to-end Preprod ceremony executed (38 TX, all phases verified on-chain).
- ⏳ Keeper reference implementation (separate repository) — not started.
- ⏳ Preprod E2E test scripts (`tests/preprod/*.test.ts`) — not started.
- ⏳ Internal audit rounds (coverage areas A-F, see `docs/audit-scope.md`) — not started.
- ⏳ External audit engagement — target Q3 2026, firm not yet selected.
- ⏳ Mainnet ceremony runbook — not yet written.

Compiled validator sizes (all under the 16 KB PlutusV3 limit, sorted largest → smallest):

| Validator | Size (bytes) | Headroom |
|-----------|-------------:|---------:|
| vault_liqwid | 13,482 | 2,902 B |
| vault_recall | 13,428 | 2,956 B |
| vault_admin_deploy | 13,213 | 3,171 B |
| vault_protocol | 13,219 | 3,165 B |
| vault_gov_policy | 12,640 | 3,744 B |
| vault_keeper_hot | 12,505 | 3,879 B |
| vault_swap_ada | 12,254 | 4,130 B |
| vault_user | 11,940 | 4,444 B |
| vault_batcher | 11,643 | 4,741 B |
| vault_gov_emergency | 10,917 | 5,467 B |
| treasury | 9,902 | 6,482 B |
| keeper_stake_script | 8,830 | 7,554 B |
| registry | 8,504 | 7,880 B |
| multisig_gov | 8,392 | 7,992 B |
| vault_proxy | 5,296 | 11,088 B |
| minswap_v2_adapter | 5,075 | 11,309 B |
| order | 3,861 | 12,523 B |
| vusdcx | 1,327 | 15,057 B |
| gov_signer_nft | 399 | 15,985 B |
| vault_nft | 337 | 16,047 B |
| governance_nft | 319 | 16,065 B |
| registry_auth_nft | 319 | 16,065 B |

Sizes measured from V1 Preprod deploy 2026-04-22 (release tag `v1-postphase77d-preprod`). Tightest headroom is `vault_liqwid` at 2,902 B free (17.7% from ceiling).

See [docs/audit-scope.md](docs/audit-scope.md) for the development / audit / launch timeline.

---

## License

OptiVaults V1 is released under the **Apache License, Version 2.0**. This applies to the entire repository — smart contracts, keeper reference implementation, API server, frontend, CLI tools, and documentation. Any team may fork, specialize, or integrate V1's architecture into derivative products consistent with the Apache 2.0 terms (see [LICENSE](LICENSE)).

The permissive license choice is deliberate: V1's success metric explicitly includes the architecture being forked and specialized by other Cardano teams (see whitepaper §1 "Why we do this"). Restricting reuse during a pre-audit validation phase would contradict that contribution-oriented posture.

---

## Contact

- Website: [optivaults.app](https://optivaults.app)
- Source (open-source mirror): github.com/OptiVaults/optivaults-protocol (repo / branch structure set up separately)
- Security: optivaults@gmail.com
