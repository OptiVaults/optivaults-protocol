# Pattern Rationale — Validator Identity NFT

**Status**: informational pattern rationale. Not a CIP, not a CIP draft. See `docs/cip-readiness-posture.md` for OptiVaults V1's overall position on Cardano Improvement Proposals.

**Scope**: a recurring pattern for binding a single canonical UTXO to a specific on-chain script across the lifetime of a protocol, using a one-shot mint policy parameterised by a consumed UTXO reference. The pattern is generic; OptiVaults V1 uses it in three places, documented as case studies in §5.

---

## 1. Problem

Many on-chain protocols designate exactly one UTXO as the protocol's "self" — the singleton state UTXO that the validators read or update on every transaction. Examples include the canonical vault UTXO in a yield protocol, the singleton governance state UTXO carrying signers and queued actions, or the single configuration UTXO that other validators reference for routing whitelists.

The protocol's validators then need a way to recognise "this UTXO is the real one" — distinguish the canonical UTXO from any other UTXO that happens to sit at the same script address (the script address is public; anyone can send tokens or ADA to it, and anyone can build a forged UTXO at it with whatever inline datum they like).

Three approaches are common:

1. **Trust the address.** Read whatever UTXO appears at the script address. This is wrong: an attacker can send a UTXO with a forged inline datum to the same address and the protocol cannot tell the difference. The recent history of Cardano DeFi includes incidents where this naïve approach was exploited.
2. **Trust a key.** Sign the canonical UTXO's creation with the protocol operator's key, and recognise the UTXO by checking that signature on every read. This is operationally heavy (requires the operator to be online when the UTXO is consumed-and-replaced) and inherits all the risks of key compromise.
3. **Anchor by NFT.** Mint a single token, lock it in the canonical UTXO, and have every validator check that the UTXO it is reading carries that token. The protocol's identity becomes the policy ID of the NFT — a cryptographic value baked into the validator's compile-time parameters.

This document is about the third approach. The Validator Identity NFT pattern is the disciplined implementation of (3) on Plutus V3.

---

## 2. The Pattern

A Validator Identity NFT is implemented as a Plutus V3 minting-policy validator that is **parameterised at compile time by a specific UTXO reference**. The validator has exactly two paths:

```aiken
validator identity_nft(utxo_ref: OutputReference, asset_name: ByteArray) {
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    let minted = dict.to_pairs(tokens(tx.mint, policy_id))
    when minted is {
      [pair] ->
        if pair.2nd == 1 {
          // Mint branch: exactly one token of `asset_name`,
          // and the parameterised UTXO must be consumed as input.
          and {
            pair.1st == asset_name,
            list.any(tx.inputs, fn(i) { i.output_reference == utxo_ref }),
          }
        } else if pair.2nd == -1 {
          // Burn branch: exactly one token of `asset_name`,
          // unconditional otherwise.
          pair.1st == asset_name
        } else {
          False
        }
      _ -> False  // Reject zero-quantity, multi-asset-name, or quantity ≠ ±1.
    }
  }

  else(_) {
    fail @"identity_nft: unsupported purpose"
  }
}
```

Two compile-time parameters:

- `utxo_ref` — a specific `OutputReference` chosen by the deployer at compile time. The mint branch requires this exact UTXO to appear as an input of the mint transaction.
- `asset_name` — the chosen token name. Some implementations omit this parameter when the protocol only ever mints one fixed name (then the name is a hardcoded constant inside the validator).

Two redeemer paths, partitioned by mint quantity sign:

- **Mint** (`quantity == +1`): permitted exactly once over the validator's lifetime. The precondition `utxo_ref ∈ tx.inputs` enforces uniqueness — the Cardano ledger guarantees each UTXO is consumed at most once.
- **Burn** (`quantity == -1`): permitted at any time with no further constraint. The holder of the NFT must spend the UTXO containing it for the burn to occur, so authorisation is implicit in ownership.

Mixed mint-and-burn within the same transaction is rejected by the `_ -> False` fallthrough. Multi-quantity (`+2`, `-3`, etc.) is also rejected. The validator handles exactly the two clean cases.

The **identity** of the resulting NFT is the validator's compiled script hash. Because `utxo_ref` (and `asset_name`, if used) is a compile-time parameter, two different UTXO references produce two different validator hashes and therefore two different policy IDs. An attacker cannot construct a "fake OptiVault NFT" by deploying their own copy of the validator: their validator hash differs, so their policy ID differs, so any consumer that checks against the original policy ID will reject the attacker's token.

---

## 3. Security Properties

### 3.1 Cryptographic one-shot

The mint branch requires `utxo_ref` to be consumed as a transaction input. UTXOs on Cardano are consumed at most once; once spent, they do not exist in any subsequent ledger state. Therefore the mint branch succeeds at most once across the chain's history, regardless of how many transactions attempt it. No key compromise, no timing accident, no operator error can produce a second mint.

This is **cryptographic** in the sense that the guarantee derives from a ledger invariant, not from a key holder's behaviour. Native-script alternatives based on `{all: [sig(key), before(slot)]}` (the common pre-Plutus-V3 approach) are **trust-based**: the guarantee depends on the key holder not signing a second mint before the deadline. A compromised key before the deadline expires breaks the singleton property.

### 3.2 Burn always available

The burn branch has no time constraint and no signer constraint. The only requirement is that the burn quantity matches the asset name. Because the NFT is locked in a UTXO controlled by a spending validator, the spending validator's own rules govern *when* the NFT can be moved (and thereby burned in the same transaction). Once those rules allow the holder to act, the burn cannot be blocked.

This is the property that distinguishes the Plutus V3 design from the native-script `{all: [sig, before(slot)]}` shape. The native-script form **shares the same deadline for mint and burn** — once the deadline passes, neither path is reachable. Heritage Cardano DeFi deployments using this shape have produced permanently-unburnable NFTs, locking the min-ADA of the UTXO carrying them on chain forever.

The pattern's split — keep the mint path constrained, leave the burn path free — is the deliberate fix.

### 3.3 Mint-quantity safety

The match `[pair]` accepts only single-token-entry mints. The `pair.2nd == 1` check rejects any mint quantity other than exactly one. Combined with the one-time consumption of `utxo_ref`, this guarantees exactly one `(policy_id, asset_name)` token exists in the global ledger over the validator's lifetime.

A common subtle bug in alternative designs uses `quantity > 0` instead of `quantity == 1`, which would allow minting many tokens of the same name in the mint transaction. The pattern uses strict equality.

### 3.4 Defence against rogue-policy injection

Validators that consume the canonical UTXO bake the identity NFT's policy ID into their compile-time parameters and check `quantity_of(utxo.value, expected_policy, expected_name) == 1` whenever they read the UTXO. An attacker deploying their own copy of the identity-NFT validator (with a different `utxo_ref` they control) produces a different policy ID — their token cannot satisfy the consumer-side check.

This closes a class of attacks where an adversary creates a UTXO at the same script address with a forged inline datum: even if the datum shape matches, the missing or wrong-policy NFT causes the consumer validator to reject the UTXO.

---

## 4. Trade-offs vs Alternatives

| Approach | One-shot guarantee | Burn after deadline | Approx. script size | Plutus eval cost |
|---|---|---|---|---|
| `{all: [sig, before(slot)]}` native script | Trust-based (key + time) | Blocked | A few bytes | None (ledger fast path) |
| Plutus V2 minting policy with `tx.validity_range.upper_bound < slot` mint guard | Same trust shape (with extra UTXO-ref check possible but uncommon in heritage code) | Configurable but commonly blocked | ~1 KB | Low |
| **Plutus V3 UTXO-ref one-shot (this pattern)** | Cryptographic (ledger invariant) | Always available | ~1.5 KB | Low (small validator, simple checks) |
| CIP-68 reference NFT with embedded datum | Same one-shot via spec, plus metadata-carrying capability | Per the user-token / reference-token split | Larger (CIP-68 metadata helpers) | Higher (datum manipulation) |

The trade made by the Validator Identity NFT pattern: pay ~1.5 KB of script size and a small evaluation cost in exchange for the cryptographic one-shot + unconditional burn. For a singleton state UTXO whose lifetime is indefinite and whose min-ADA recovery on sunset is economically meaningful, this is the right trade.

**CIP-68 stance**: the identity NFT pattern as documented here intentionally does **not** carry metadata. The NFT's job is anchor identification, not display. A future variant that combines this pattern with CIP-68 reference NFTs for display metadata is plausible — both can co-exist — but is out of scope for the V1 instantiation. See `docs/cip-readiness-posture.md` §3 for the full CIP-68 / CIP-25 stance.

---

## 5. OptiVaults V1 Case Studies

V1 instantiates the pattern in three places. Each instantiation is a single 40–60-line validator file. The differences are which compile-time parameters are exposed, and which downstream validators bake the resulting policy ID as their own compile-time anchor.

### 5.1 Vault Identity NFT — `contracts/validators/vault_nft.ak`

```aiken
validator vault_nft(utxo_ref: OutputReference) {
  // asset_name hardcoded as vault/constants.vault_nft_token_name = "OptiVault"
  ...
}
```

- One compile-time parameter (`utxo_ref`); asset name is the constant `"OptiVault"` baked into the validator.
- Anchors `vault_proxy`, `vusdcx`, and `order` validators at compile time. Any UTXO at the vault address lacking this NFT is not recognised as a vault by any of these validators — the "phantom vault" attack class is closed.
- The single canonical V1 vault UTXO sits at the `vault_proxy` script address carrying one of these NFTs from the deploy ceremony onward.
- Full discussion in `spec/vault-nft.md` (security history, lifecycle, why-not-native-script).

### 5.2 Governance NFT — `contracts/validators/governance_nft.ak`

```aiken
validator governance_nft(utxo_ref: OutputReference, gov_name: ByteArray) {
  ...
}
```

- Two compile-time parameters: `utxo_ref` + `gov_name`. The name parameter lets the same validator code be reused for governance NFTs across forks of V1 with different deployment-specific names.
- Anchors `vault_protocol`, `registry`, `treasury`, and `keeper_stake_script` — the four validators that accept governance-authorised actions check that the governance UTXO's NFT policy matches at compile time. Forged governance UTXOs at the governance script address are rejected.
- The single MultisigGov UTXO carries this NFT. Every queued or executed governance action consumes-and-replaces this UTXO, preserving the NFT across the transition.
- Full discussion in `spec/multisig-gov.md` §4 (governance UTXO authenticity) + `spec/governance.md`.

### 5.3 Registry Auth NFT — `contracts/validators/registry_auth_nft.ak`

```aiken
validator registry_auth_nft(utxo_ref: OutputReference, asset_name: ByteArray) {
  ...
}
```

- Two compile-time parameters: `utxo_ref` + `asset_name`. Same shape as the Governance NFT.
- Anchors the canonical Registry UTXO. When `vault_protocol` reads the Registry as a reference input to check whether a destination address is in the whitelist, it verifies the Registry UTXO carries this specific NFT policy. Without the NFT check, an attacker could plant a forged Registry UTXO with a permissive whitelist at the Registry script address.
- The NFT presence check is enforced inside `helpers.read_registry_datum` so that every validator reading the Registry goes through the same authenticated read path.
- Full discussion in `spec/pattern-rationale-registry-auth-nft.md` (Pattern 4 — Registry + Auth NFT Whitelist) which builds on this pattern.

### 5.4 What is shared across the three

The three case studies share approximately 35 of their 50 lines verbatim — the same mint/burn partition, the same `[pair]` dict-entry match, the same UTXO-ref consumption check. The differences are entirely in the compile-time parameter signature and in which downstream validator anchors to the resulting policy ID.

A reasonable future refactor (post-V1, post-audit) is to extract the shared core into a single `lib/identity_nft.ak` helper module and have the three validators call into it. Whether to do this refactor depends on whether the inlined-per-validator form continues to read more cleanly than the deduplicated form; the current preference is to keep each validator self-contained for audit traceability.

---

## 6. Out-of-Scope Variants

The following variants are **not** what the Validator Identity NFT pattern covers, and would be separate patterns if standardised:

- **Per-user identity NFTs** (one NFT per depositor). That is a position-token pattern, with one-to-many cardinality. The identity NFT pattern is one-to-one (one NFT per protocol singleton).
- **Threshold-mint NFTs** (mint authorised by m-of-n signature). That belongs to MultiSig Governance + Timelock (Pattern 2).
- **Metadata-carrying NFTs** (CIP-25 / CIP-68 reference tokens). Compatible to add on top, but the identity NFT pattern itself is meta-data-agnostic.

---

## 7. Open Questions for Future CIP Work

If this pattern is ever proposed for CIP standardisation, the discussion should resolve:

1. **`asset_name` constant vs parameter** — V1 uses both forms across the three instantiations. A CIP would need to pick one shape (or formally allow both).
2. **Burn branch authorisation** — V1 makes the burn unconditional. Some protocols would prefer "burn requires the same signer as the spending validator that owns the UTXO carrying the NFT", which adds a constraint. The CIP should state the trade-off and pick one default.
3. **Interaction with CIP-68 reference NFTs** — whether and how an identity NFT can simultaneously serve as a CIP-68 reference NFT for display purposes. This is a co-existence question, not a conflict.
4. **Naming convention** — "Identity NFT" / "Singleton NFT" / "Anchor NFT" / "Witness NFT" all appear in informal Cardano DeFi discussion. A CIP would canonicalise one name.

---

## 8. See Also

- `spec/vault-nft.md` — concrete V1 instantiation #1 (Vault Identity NFT)
- `spec/multisig-gov.md` §4 + `spec/gov-nft.md` — concrete V1 instantiation #2 (Governance NFT)
- `spec/pattern-rationale-registry-auth-nft.md` — concrete V1 instantiation #3 (Registry Auth NFT, with whitelist datum on top)
- `spec/pattern-rationale-withdraw-zero-forwarding.md` — Pattern 3, used together with Identity NFT to enforce "the singleton UTXO must be the one our validator anchors to"
- `docs/cip-readiness-posture.md` — the overall CIP posture
- `contracts/validators/vault_nft.ak` / `governance_nft.ak` / `registry_auth_nft.ak` — the three reference implementations

---

**Document status**: informational pattern rationale. Reflects V1 design as of launch readiness. Revisions will follow the conditions stated in `cip-readiness-posture.md` §4.
