# OptiVaults V1 Articles

Long-form technical writing about OptiVaults V1's design choices. These articles complement the formal specification in [`spec/`](../../spec/) and the [whitepaper](../../whitepaper/whitepaper.md) by walking through the *why* behind specific architectural decisions in narrative form.

Articles are open source under Apache 2.0 along with the rest of the protocol.

中文版見 [README-zh-TW.md](./README-zh-TW.md).

---

## Series

Articles are organized by topic into series subfolders.

### [Architecture](./architecture/) (4 parts)

A complete walkthrough of V1's contract architecture: from the four eUTXO design constraints, through the Withdraw-Zero Forwarding Pattern, to the 17-validator split and the compile-time Vault NFT anchor.

| # | Article | Reading time |
|---|---------|--------------|
| 1 | [Four Design Constraints for Building a Vault on Cardano's eUTXO](./architecture/01-eutxo-vault-design-constraints.md) | ~6 min |
| 2 | [The Withdraw-Zero Forwarding Pattern: Moving Vault Logic to Staking Validators](./architecture/02-withdraw-zero-forwarding-pattern.md) | ~6 min |
| 3 | [Why OptiVaults V1 Has 17 Validators: Four Orthogonal Cuts](./architecture/03-seventeen-validators-four-cuts.md) | ~6 min |
| 4 | [Single-UTXO State and the Compile-Time Vault NFT Anchor](./architecture/04-vault-datum-and-nft-anchor.md) | ~7 min |

Articles are designed to be self-contained but build on each other. First-time readers benefit from reading 1 → 2 → 3 → 4 in sequence. Readers familiar with eUTXO trade-offs can skip Part 1.

### [Security](./security/) (4 parts)

V1's contract-layer security design: three-layer governance safety, adversarial chain-replay methodology, honest disclosure of multi-stablecoin risk, and the phantom-vault attack vector with compile-time NFT anchor.

| # | Article | Reading time |
|---|---------|--------------|
| 1 | [Three-Layer Governance Safety: Preserving Depositor Recovery Under Single-Signer Governance](./security/01-three-layer-governance-safety.md) | ~7 min |
| 2 | [Adversarial Chain Replay: Turning "The Contract Should Reject" Into "The Contract Did Reject"](./security/02-adversarial-chain-replay-methodology.md) | ~9 min |
| 3 | [Multi-Stablecoin Configuration ≠ Real Risk Diversification](./security/03-multi-stablecoin-depeg-not-real-diversification.md) | ~7 min |
| 4 | [Phantom-Vault Attack Vector: Why Compile-Time Anchors Beat Runtime Checks](./security/04-phantom-vault-and-compile-time-anchor.md) | ~11 min |

The Security series complements the Architecture series on the security side. Recommended to read after the Architecture series; Part 4 here pairs with Architecture Part 4 for the full picture.

### [Economics](./economics/) (4 parts)

V1's economic design: precise semantics of the 4.5% performance fee, three-stream fee-split evolution, low-TVL public-goods operation mode, and the volunteer-builder + audit-as-cap-lift-gate framework.

| # | Article | Reading time |
|---|---------|--------------|
| 1 | [The 4.5% Performance Fee: Formula, Invariants, and the Validator-Level Hard Cap](./economics/01-performance-fee-precise-semantics.md) | ~9 min |
| 2 | [3-Way Fee Split: keeper / gov pool / treasury Evolution](./economics/02-three-way-fee-split-evolution.md) | ~10 min |
| 3 | [Reference Implementation Mode: Public-Goods Operation at Low TVL](./economics/03-reference-implementation-mode.md) | ~9 min |
| 4 | [Audit Is a Cap-Lift Gate, Not a Launch Gate: The Volunteer-Builder Framework](./economics/04-volunteer-builder-audit-cap-lift-gate.md) | ~10 min |

The Economics series is independent of the Architecture and Security series; readers wanting to understand V1's "why public goods, not a commercial product" posture should start here. Part 4 is the core disclosure of V1's overall posture.

### [Operations](./operations/) (3 parts)

V1's operational-layer mechanics: SwapAda on-chain ADA replenishment loop, 7-day keeper-inactivity dead-man-switch, and the three withdraw paths compared.

| # | Article | Reading time |
|---|---------|--------------|
| 1 | [SwapAda: A Dual-Feed Oracle On-Chain ADA Replenishment Loop](./operations/01-swapada-dual-feed-oracle-loop.md) | ~11 min |
| 2 | [7-Day Keeper-Inactivity Dead-Man-Switch: Depositors Don't Have to Trust the Keeper](./operations/02-seven-day-keeper-inactivity-dead-man-switch.md) | ~10 min |
| 3 | [Three Withdraw Paths: Choosing Among Direct / Queue / Emergency](./operations/03-three-withdraw-paths.md) | ~12 min |

The Operations series leans on practical details, suitable for readers preparing to deposit or wanting to know how V1 "actually runs" on mainnet. Part 3 is useful for all depositors and reads independently of the other series.

---

## Companion reference documentation

Alongside the four narrative series above, V1 ships a parallel set of **reference-style documents** that describe recurring Cardano DeFi patterns in generic terms, citing the V1 instantiation as a worked example:

| Document | What it covers |
|---|---|
| [Validator Identity NFT](../../spec/pattern-rationale-validator-identity-nft.md) | UTXO-ref one-shot NFT as a compile-time identity anchor — V1 instances: Vault NFT, Governance NFT, Registry Auth NFT |
| [MultiSig Governance + Timelock](../../spec/pattern-rationale-multisig-gov-timelock.md) | m-of-n approve + per-action timelock + 1-of-n cancel veto + nonce-bound action_id |
| [Withdraw-Zero Forwarding](../../spec/pattern-rationale-withdraw-zero-forwarding.md) | Splitting business logic across staking validators routed by a thin spending validator — breaks the 16 KB ceiling without inflating per-TX ref-script fee |
| [Registry + Auth NFT Whitelist](../../spec/pattern-rationale-registry-auth-nft.md) | Governance-mutable whitelist datum anchored by a one-shot Registry Auth NFT |
| [VaultDatum Tiered Immutability](../../spec/pattern-rationale-vault-datum-tiered.md) | Datum field tiers (identity-immutable / governance-mutable / accounting / operational) enforced via `check_immutable_fields` |

These pair with the architecture articles: Architecture Part 3 ("17 Validators: Four Orthogonal Cuts") is the OptiVaults-specific catalog, while the **Withdraw-Zero Forwarding** rationale doc is the generic pattern the catalog instantiates.

V1's broader stance on these patterns and the Cardano Improvement Proposal process — informational; V1 prepares pattern documentation but does not submit a CIP at the V1 release stage — is in [`docs/cip-readiness-posture.md`](../cip-readiness-posture.md).

---

## Medium mirrors

Each article is also mirrored on Medium with the canonical URL pointing back to this repository.

- *(Medium URLs will be added as articles are published.)*

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0. Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/HY5sy8cz8s).*
