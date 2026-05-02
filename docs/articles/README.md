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
| 2 | [The Withdraw-Zero Forwarding Pattern](./architecture/02-withdraw-zero-forwarding-pattern.md) | ~6 min |
| 3 | [Why OptiVaults V1 Has 17 Validators: Four Orthogonal Cuts](./architecture/03-seventeen-validators-four-cuts.md) | ~6 min |
| 4 | [Single-UTXO State and the Compile-Time Vault NFT Anchor](./architecture/04-vault-datum-and-nft-anchor.md) | ~7 min |

Articles are designed to be self-contained but build on each other. First-time readers benefit from reading 1 → 2 → 3 → 4 in sequence. Readers familiar with eUTXO trade-offs can skip Part 1.

---

## Medium mirrors

Each article is also mirrored on Medium with the canonical URL pointing back to this repository.

- *(Medium URLs will be added as articles are published.)*

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0. Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/4VZK6vdK4t).*
