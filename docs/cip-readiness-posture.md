# cip-readiness-posture.md — OptiVaults V1 Posture Toward Cardano Improvement Proposals

**Scope**: OptiVaults V1's relationship with the Cardano Improvement Proposal process — what V1 already uses, what V1 implements that could one day become a CIP, and the conditions under which V1 would actually author or co-author a submission.

This document is **informational**. It is not a CIP, not a CIP draft, and not a commitment that any of the patterns described will ever be standardised. It is the project's public statement of intent so that the community can decide how seriously to take V1's internal documentation when it discusses "pattern rationale" alongside concrete contract code.

---

## 1. Posture

OptiVaults V1 **uses existing CIPs where they exist**, and **prepares — but does not submit — pattern documentation that could one day support CIP proposals**. V1 will not author a CIP submission at the V1 release stage.

The reasoning is straightforward. A CIP author should have:

1. A working implementation that has run on mainnet under real load.
2. Independent confirmation that the design is sound — at minimum a completed external security audit.
3. Evidence that the pattern is general enough to be useful outside the originating project — ideally a second implementation by an unrelated team.
4. A community discussion period where rough corners are surfaced before specification.

V1 currently has none of (1)–(4) in finished form. Mainnet launch is pending, the external audit is scheduled for Q2–Q3 2027, no second implementation exists, and broader community discussion of the patterns is premature. Submitting a CIP without this groundwork would either produce a specification that needs to be retracted, or worse, anchor a sub-optimal pattern in the ecosystem before its weaknesses are visible.

The V1 documentation therefore takes the form of **pattern-rationale notes** colocated with the V1 spec (`spec/pattern-rationale-*.md`). These notes describe each pattern in generic terms, cite the concrete V1 instantiation as an example, and explicitly defer standardisation language to a future Phase 3+ effort.

---

## 2. Patterns OptiVaults V1 Documents for Future CIP Consideration

| # | Pattern (public name) | V1 implementation | Rationale doc |
|---|---|---|---|
| 1 | Validator Identity NFT | Vault NFT, Governance NFT, Registry Auth NFT (one-shot mint, UTXO-ref-anchored) | `spec/pattern-rationale-validator-identity-nft.md` |
| 2 | MultiSig Governance + Timelock | `multisig_gov.ak` — m-of-n approve, per-action timelock, 1-of-n cancel, nonce-bound action_id | `spec/pattern-rationale-multisig-gov-timelock.md` |
| 3 | Withdraw-Zero Forwarding | `vault_proxy` + ten routed staking validators; the 16 KB script-size budget is split across validators without enlarging the user TX | `spec/pattern-rationale-withdraw-zero-forwarding.md` |
| 4 | Registry + Auth NFT Whitelist | `registry.ak` carrying a governance-mutable whitelist datum, anchored by a one-shot Registry Auth NFT | `spec/pattern-rationale-registry-auth-nft.md` |
| 5 | VaultDatum Tiered Immutability | 29-field VaultDatum split across four tiers (identity-immutable / governance-mutable / accounting / operational), enforced via the `check_immutable_fields` helper | `spec/pattern-rationale-vault-datum-tiered.md` |

None of the five is fundamentally novel — variants of each appear in other Cardano DeFi protocols. What V1 contributes is **a documented, audit-traced, and chain-verified instantiation** suitable as a reference implementation when the pattern is eventually proposed.

---

## 3. Cardano CIPs V1 Already Consumes

The following CIPs are **dependencies**, not candidates — V1 uses them as-is and would not propose modifications.

| CIP | V1 usage | Notes |
|---|---|---|
| CIP-30 | Wallet ↔ dApp connection on the V1 frontend; all deposit / withdraw transactions are CIP-30 TXs signed by the user's wallet | The actively-tested wallet set at launch is Eternl, Lace, Vespr, Typhon, and Yoroi; any CIP-30-compliant wallet should work |
| CIP-25 | Reference shape only for NFT metadata; V1's Validator Identity NFTs (Vault NFT, Governance NFT, Registry Auth NFT) intentionally **do not** carry CIP-25 metadata because their on-chain role is anchor identification, not display | The pattern-rationale doc for Validator Identity NFT discusses why the no-metadata variant is appropriate here |
| CIP-68 | Not used by V1's identity NFTs (no datum-carrying NFT design); V1 keeps state in validator datums, not in reference NFT datums | Future work (Phase 3+) may revisit whether a CIP-68 reference-NFT variant would simplify cross-protocol indexing |
| CIP-69 | Plutus V3 mint-policy redeemer shape — V1's minting policies (`vault_nft`, `governance_nft`, `registry_auth_nft`, `vusdcx`) follow CIP-69 spending-and-minting semantics by virtue of compiling against Plutus V3 | No project-specific extension |

The following CIPs are **adjacent** to patterns V1 documents, but V1's patterns are **not framed as extensions of these CIPs** at the V1 stage. Any future relationship would be developed during the community discussion preceding a hypothetical submission.

| CIP | V1 pattern with potential overlap | V1 stance |
|---|---|---|
| CIP-72 (DApp Registration & Discovery) | CIP-72 is a dApp's **outward identity claim** (metadata about the dApp, signed by the owner key, consumed by wallets and explorers for discovery). The V1 Registry is an **inward authorization datum** (the destinations the keeper may route to, consumed only by V1's own validators) | The two sit on orthogonal axes — V1 could publish a CIP-72 claim and maintain the Registry datum simultaneously, with zero interaction between them. They share only the English word "registry". |
| CIP-95 (Web-Wallet Bridge for Conway) | OptiVaults V1 is not currently a delegation-aware dApp; depositors stake ADA independently of vault participation | If a future version of V1 surfaces a delegation feature, CIP-95 would be the natural integration point |

---

## 4. Conditions Under Which V1 Would Author a CIP

The project's commitment is the following: when **all** of (a)–(d) hold, the OptiVaults team will publish a formal CIP authoring intent for community discussion. Until then, the pattern-rationale documents stand alone.

(a) The external audit (Q2–Q3 2027) has completed and findings have been published.

(b) V1 has been running on mainnet for at least one full year, with TVL above the §6.3 pre-audit cap, with at least one realized depeg or external-protocol stress event survived without principal loss.

(c) At least one independent team has either (i) deployed a derivative work using one of the documented patterns, or (ii) raised concrete questions about a pattern in a public forum (Cardano forums, GitHub issue threads on this repo, ecosystem working groups) demonstrating that the pattern matters beyond OptiVaults.

(d) Community governance transition (whitepaper §10) has progressed past the founder-controlled stage so that CIP authorship is not effectively single-actor.

If conditions (a)–(d) are not all met, the documentation stays as informational pattern rationale. The patterns themselves continue to be useful to anyone reading the V1 codebase — they just are not standardised yet.

---

## 5. How the Community Can Engage Now

While V1 is pre-mainnet, the most useful community contributions are:

- **Read the pattern-rationale docs** and file GitHub issues if a design choice is unclear, inconsistent with existing CIPs, or has a strictly better-known variant.
- **Compare against your own protocol's design** if you build similar primitives. A second implementation is exactly what raises a "this is just an OptiVaults idiosyncrasy" pattern into "this is a recognisable Cardano-DeFi pattern".
- **Surface adjacent CIP work** — if a CIP draft exists in the pipeline that overlaps with one of the five patterns, please link it on the relevant pattern-rationale doc's GitHub thread so V1 can either align early or discuss the divergence.

Direct CIP discussion at this stage is welcome on the OptiVaults repo, but the project will not open a CIP repository PR until §4's gates are met.

---

## 6. What Is Explicitly Not a CIP Candidate

For clarity, the following V1 components are project-specific and are not framed as CIP candidates either now or in any planned future work:

- The 29-field VaultDatum schema (specific to V1's strategy + accounting; not generalisable).
- The Liqwid integration shape (specific to Liqwid V2's per-market action-validator design).
- The Minswap V2 adapter `hop_chain` decoder (specific to Minswap V2's order datum encoding).
- The SundaeSwap adapter cancel-guard (specific to SundaeSwap V3 + Stableswaps order shape).
- The keeper authorization stake-script pattern. The underlying *primitive* — a stake-script used as an evolvable authorization gateway — is already captured by the Withdraw-Zero Forwarding pattern (#3). What sits on top in V1 (the three-mode spectrum from governance-only allowlist to bonded permissionless, the weekly rotation arithmetic, the slashable bond economics, the anti-replay nonce, and the per-PKH anti-spam cooldown) is operational policy specific to OptiVaults's keeper model — useful as a reference implementation, not a protocol primitive.

These are documented for reproducibility and audit traceability, not standardisation.

---

**Document status**: informational. Reflects project intent as of V1 launch readiness. Will be revised when §4's conditions are met or when ecosystem context changes materially.
