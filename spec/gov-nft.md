# OptiVaults V1 — Gov Signer NFT Specification

**Scope**: soul-bound, non-financial NFT issued to each governance signer as public recognition of their role.

---

## 1. Purpose

Governance signers at V1 launch (and through Phase 2-3 expansion) receive no significant monetary compensation — Phase 1 is $0, Phase 2 is ~$16–33/year per signer, Phase 3 is ~$100–200/year at typical TVL. The primary value of the role is non-financial:

- Reputation: "I am an OptiVaults governance signer" is a verifiable public claim
- Influence: signers shape fee policy, treasury spending, keeper authorization
- Accountability: signers' identities are public; their on-chain signatures are their record

The **Gov Signer NFT** is the on-chain artifact that makes the reputation claim verifiable. It is soul-bound (cannot be transferred), burns on rotation-out, and carries no voting or financial rights — those live in `multisig_gov`'s own datum.

---

## 2. Policy Design

### 2.1 Compile-time parameters

```aiken
validator gov_signer_nft(
  governance_policy: ByteArray,   // MultisigGov governance NFT policy
  governance_name: ByteArray,     // MultisigGov governance NFT asset name
) {
  mint(redeemer: GovSignerNFTRedeemer, policy_id: PolicyId, tx: Transaction) { ... }
}
```

Parameterizing by the Governance NFT policy + name cryptographically ties this minting policy to its specific MultisigGov instance. The Gov Signer NFTs are only mintable when the MultisigGov UTXO is spent in the same transaction — the two NFTs are co-dependent.

### 2.2 Asset-name schema

Each Gov Signer NFT has a unique asset name encoding the signer generation and identity:

```
<generation_byte><signer_index_byte><first_28_bytes_of_signer_pkh>

Examples:
  0x01 0x00 <founder_pkh[0..28]>    = Gen1 Signer #0 (founder)
  0x01 0x01 <ally_a_pkh[0..28]>     = Gen1 Signer #1 (ally A)
  0x01 0x02 <ally_b_pkh[0..28]>     = Gen1 Signer #2 (ally B)
  0x02 0x00 <new_pkh[0..28]>        = Gen2 Signer #0 (post first RotateSigners)
```

`generation_byte` increments on every `RotateSigners` TX that changes the signer set; `signer_index_byte` is the position in the new `signers` list. The first 28 bytes of the signer's PKH disambiguate identities across rotations.

Front-end displays the NFT as `OptiVaults Gov Signer #<n> (Gen <g>)` with the signer's publicly-disclosed identity.

---

## 3. Redeemer

```aiken
type GovSignerNFTRedeemer {
  MintForSignerSet {
    signer_indices: List<Int>,    // positions in gov_datum.signers to mint NFTs for
  }

  BurnRotatedOut {
    rotated_pkh: VerificationKeyHash,
  }
}
```

### 3.1 `MintForSignerSet`

Validation:
- Transaction consumes the MultisigGov UTXO (identified by carrying `governance_policy + governance_name`)
- That consumption's redeemer is `RotateSigners` OR this is the initial deploy TX (MintForSignerSet for the launch signers)
- For each `i ∈ signer_indices`:
  - `gov_datum.signers[i]` is defined (within bounds)
  - Exactly 1 token minted with asset name `<gen_byte><i_byte><signers[i][0..28]>`
  - Mint amount for each asset name is exactly `1`
- No burn in the mint set (handled by separate `BurnRotatedOut`)
- Total minted count == `list.length(signer_indices)`

### 3.2 `BurnRotatedOut`

Validation:
- Transaction consumes the MultisigGov UTXO with `RotateSigners` redeemer OR `ExecuteAction`-of-RotateSigners
- `rotated_pkh` is **not** in `new_gov_datum.signers` (confirms the rotation truly removed them)
- Exactly 1 token burned (`mint == -1`) for an asset name matching `<gen_byte><prev_index><rotated_pkh[0..28]>` where `<prev_index>` was that PKH's position in `old_gov_datum.signers`
- No minting in the same burn redeemer

### 3.3 Soul-bound enforcement

To make the NFT non-transferable, the minting policy's spend-path (when someone tries to spend a UTXO carrying the Gov Signer NFT) enforces:

- The NFT's UTXO output continues to the **original signer's payment address** (the PKH matches the NFT's asset name suffix)
- OR the NFT is burned in the same transaction via `BurnRotatedOut`

This prevents transfer to a third party while allowing the signer to move the NFT between their own UTXOs (for fee management, consolidation, etc.).

A malicious transfer attempt would fail this check and the transaction would be rejected.

---

## 4. Lifecycle

### 4.1 V1 launch minting

At V1 mainnet deploy, a single `MintForSignerSet` transaction:
- Is bundled with the MultisigGov initialization (GovInit) TX
- Mints 3 Gov Signer NFTs (one per founder-connected launch signer)
- Sends each NFT to the corresponding signer's payment address
- Record on-chain: the three NFTs are permanently tied to their recipients

### 4.2 Phase 2 / 3 rotation

When `RotateSigners` adds a new signer:
1. The rotation TX carries:
   - `multisig_gov` spend with `RotateSigners` redeemer → new `signers` list published
   - `gov_signer_nft` mint with `MintForSignerSet { signer_indices: [new_position] }` → new NFT issued to the joining signer
   - (If a signer rotated out simultaneously) `gov_signer_nft` burn with `BurnRotatedOut { rotated_pkh }`
2. All three actions atomic in one TX; no partial rotation states possible

### 4.3 Retirement / resignation

When a signer voluntarily rotates out (or is rotated out by governance majority):
- The `RotateSigners` TX includes a `BurnRotatedOut` for their NFT
- NFT is destroyed; signer no longer carries the on-chain claim

If a signer simply loses their key without an on-chain rotation, their NFT remains until the next rotation. Governance convention: promptly RotateSigners to remove any signer who has lost access.

---

## 5. What the NFT does NOT confer

Explicit non-rights, to prevent any confusion:

| Right | Granted by NFT? |
|-------|-----------------|
| Voting on governance actions | ❌ No — voting is via `gov_datum.signers` list + transaction signatures |
| Claim on treasury funds | ❌ No — treasury flows are via `TreasurySpend` redeemer, not NFT ownership |
| Share of performance fee | ❌ No — gov fee split goes into the MultisigGov UTXO's `signer_compensation_pool`, disbursed by `DistributeSignerCompensation` to signers' addresses, not NFT-gated |
| Transferability | ❌ No — soul-bound |
| Resale / secondary market | ❌ No — soul-bound means no NFT-marketplace listing |
| Representation in DAO snapshots | ❌ No — V1 does not use DAO snapshot governance |

**The NFT is purely a visible, verifiable claim of "I am / was a V1 governance signer."** Nothing more.

---

## 6. Display and UX

Front-end (optivaults.app/governance) displays:
- Current signer set (live from `multisig_gov` datum)
- Each signer's publicly-disclosed name / organization
- Their Gov Signer NFT's Cardanoscan link
- Their tenure (`signer_joined_at_ms` from GovDatum)
- Their quarterly qualification status (from `signer_last_qualified_ms`)

Signers can display their NFT in Cardano wallet UIs (Eternl, Lace, Vespr) as proof of their role. Some wallets may show it as a "collectible" — the signer can customize their own display.

---

## 7. Extensions (future)

V2+ may extend the NFT system with:
- **Generation metadata**: NFT metadata includes the signer's joining date, rotation history, any public statements attached
- **Contributor NFT**: similar pattern for open-source contributors (see `docs/contributor-program.md` when written)
- **Auditor NFT**: separate policy for firms that have performed audits, soul-bound to the audit-firm's wallet

These are **not V1 scope**. V1 ships with only the Gov Signer NFT described here.

---

## 8. Security considerations

- **NFT forgery**: impossible. Mint policy is parameterized by governance NFT policy/name, and mint requires consuming the governance UTXO. No other entity can mint.
- **NFT impersonation**: each NFT's asset name includes 28 bytes of the signer's PKH — an impostor cannot mint an NFT claiming a different signer's identity.
- **Lost signer NFT**: the signer can move it between their own UTXOs (soul-bound enforces same payment PKH). If the signer's wallet is entirely compromised, governance should `RotateSigners` them out and the NFT is burned. No recovery path is needed — the NFT is non-financial.
- **Deploy-time vs. rotation NFTs**: launch NFTs minted by the same policy as future rotation NFTs — consistent behavior, no special-case logic.

---

## 9. CIP-applicability (soul-bound recognition NFT)

The Gov Signer NFT is a working instance of the **Soul-Bound NFT pattern** — a non-transferable token minted to a specific holder under policy-enforced binding, intended for identity / recognition / role-claim use cases rather than financial value. The pattern appears informally across Cardano DeFi and adjacent ecosystems but has no current CIP standardising the on-chain shape.

### 9.1 What V1 demonstrates

The implementation in §2 (Policy Design) and §3 (Redeemer) carries the structural elements of an SBT under the Plutus V3 minting-policy model:

- **Identity binding** — asset name embeds 28 bytes of the holder's PKH, so a single policy supports many one-of-one tokens each cryptographically tied to a distinct holder.
- **Non-transferability** — enforced by the spending validator gating the UTXO containing the NFT: the NFT can move only between UTXOs sharing the same payment PKH (i.e., the signer's own wallet). Marketplace transfers fail at the validator level.
- **Authorised mint origin** — the mint precondition requires consuming the singleton Governance NFT UTXO, so only governance-approved transactions can mint or rotate the SBT. No third party can produce a token under this policy.
- **Authorised burn path** — the signer-rotation `RotateSigners` transaction burns the outgoing signer's SBT in the same TX, keeping the on-chain signer registry and the SBT set in lock-step.

These four elements together constitute the SBT pattern as V1 instantiates it. None is novel — variants of each have appeared across Cardano DeFi — but the V1 form is concrete, audit-traced, and chain-verified, making it suitable as a reference instantiation if a Soul-Bound NFT CIP is ever authored.

### 9.2 V1's posture toward CIP standardisation

V1 does **not** author a CIP for this pattern at the V1 stage. The four general gates documented in [`cip-readiness-posture.md`](../docs/cip-readiness-posture.md) §4 apply — external audit pending, no independent implementation, no community-governance transition past founder-only, and the production stress evidence is still pre-mainnet. The pattern's documented form in this file is the V1 reference, not a draft specification.

The §7 "Extensions (future)" entries — Contributor NFT, Auditor NFT — would each be additional instances of the same SBT pattern under different policy parameterisations. They are not V1 scope, and any future CIP discussion about Soul-Bound NFTs would address all three V1 instances (Gov Signer / Contributor / Auditor) under one umbrella rather than each separately.

### 9.3 Distinction from the Validator Identity NFT pattern

The Gov Signer NFT is **not** an instance of the [Validator Identity NFT pattern](./pattern-rationale-validator-identity-nft.md). The two patterns address different problems:

| Pattern | Cardinality | Role | V1 instances |
|---|---|---|---|
| Validator Identity NFT | One-to-one (one NFT anchors one canonical UTXO) | Compile-time anchor for validator identity | Vault NFT, Governance NFT (the *spending validator's anchor*, not this file's signer-recognition NFT), Registry Auth NFT |
| Soul-Bound NFT (this section) | One-per-holder | Identity / recognition claim, non-transferable | Gov Signer NFT (this file), future Contributor NFT, future Auditor NFT |

The Gov **Signer** NFT (this file) is distinct from the Gov **Identity** NFT (the singleton that anchors the `multisig_gov` UTXO — see [`pattern-rationale-validator-identity-nft.md`](./pattern-rationale-validator-identity-nft.md) §5.2). They share the word "Gov" but solve orthogonal problems.

### 9.4 Related pattern-rationale docs

- [`pattern-rationale-validator-identity-nft.md`](./pattern-rationale-validator-identity-nft.md) — the Governance Identity NFT (one-shot anchor) that this Gov Signer NFT's mint policy depends on for authorisation; the two NFTs co-exist with distinct roles
- [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md) — `RotateSigners` is the redeemer that mints / burns Gov Signer NFTs as signers join or leave the multisig set
- [`cip-readiness-posture.md`](../docs/cip-readiness-posture.md) — overall V1 stance on Cardano Improvement Proposals; Soul-Bound NFT is not in the five candidate-pattern list (the focus is on protocol-primitive patterns), but the §6 out-of-scope clarifications mention it implicitly

---

## 10. See Also

- `spec/governance.md` §8 — signer rotation roadmap and launch signer set
- `spec/multisig-gov.md` — MultisigGov validator internals
- `docs/security-model.md` §2 — governance trust model, signer role
- `docs/audit-scope.md` — NFT mint policy is part of V1 audit scope
