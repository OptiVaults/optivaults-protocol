# Phantom-Vault Attack Vector: Why Compile-Time Anchors Beat Runtime Checks

*OptiVaults V1 Security Design Series — Part 4 of 4*

---

[Architecture Series Article 4](../architecture/04-vault-datum-and-nft-anchor.md) introduced the high-level concept of V1's compile-time Vault NFT Anchor: a PlutusV3 UTXO-ref one-shot mints the unique Vault Identity NFT, and the NFT's minting policy is baked into the compile-time parameters of three validators (`vault_proxy` / `vusdcx` / `order`).

That article covered "what the solution is." This article covers "why this solution is necessary" — unpacking the phantom-vault attack vector, walking through designs that look like solutions but don't actually hold, and explaining why the compile-time anchor is the only way on Cardano to structurally close this attack surface.

Within V1's security posture, this design line is the most representative example of "locking the trust chain at compile time."

The whole protocol is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol).

---

## The Starting Point: Cardano Has No Native Concept of UTXO Identity

[Architecture Series Article 1](../architecture/01-eutxo-vault-design-constraints.md) covered Constraint 4: your vault state UTXO and any UTXO someone else produces at the same script address **look identical from the ledger's perspective**.

Cardano has no native concept of "this UTXO is the real vault state." Anyone can send a UTXO to the `vault_proxy` address, with any datum attached. The validator runs when its UTXO is spent; the validator logic can only inspect "is this TX's context reasonable" — it cannot directly query "of the UTXOs at this script address, which one is the real vault state."

Lay this constraint on top of the vault's functional requirements, and you hit a structural attack surface.

---

## The Concrete Form of a Phantom-Vault Attack

The attacker's goal usually isn't to steal the vault's state UTXO (that requires bypassing the full spending validator logic, which is hard). It's to **trick another contract into treating a phantom UTXO as the real vault** — and use that misjudgment to mint share tokens.

A concrete walkthrough. `vusdcx` is V1's share-token minting policy, with roughly this rule: "In a TX that spends a vault UTXO, you can mint shares according to the `expected_shares` formula."

If `vusdcx`'s notion of "vault UTXO" isn't strict enough, an attacker can do this:

```
[1] Attacker creates a phantom UTXO
    ├─ Address: vault_proxy's address (anyone can send a UTXO there)
    ├─ Attached datum: fabricated VaultDatum
    │             — total_deposited = 0
    │             — total_shares = 0
    │             — other fields filled with plausible values
    └─ Attached token: an NFT minted by the attacker, pretending to
                       be vault identity

[2] Attacker builds a TX
    ├─ Input: phantom UTXO (triggers vault_proxy's spending validator)
    ├─ Mint:  request vusdcx policy to mint a large quantity of shares
    └─ Output: all shares routed to attacker's wallet

[3] Attacker's hope
    └─ vusdcx's policy sees "a vault UTXO is being spent + carries NFT"
        → approves the mint request
        → attacker gets newly-minted shares
        → uses V1's frontend to Direct Withdraw and convert to USDCx
```

If this attack path works, V1's entire economic guarantee collapses — the attacker can mint shares from thin air and drain other depositors' principal.

The crux: **how does `vusdcx`'s policy determine "this UTXO is the real vault"?**

---

## First (Insufficient) Solution: Check the Script Address

The most intuitive check is "the input comes from `vault_proxy`'s script address."

This isn't enough. The attacker's phantom UTXO is exactly at `vault_proxy`'s script address — that address is open to anyone, no one can prevent UTXOs being sent there. Any judgment of the form "any UTXO at vault_proxy's address counts as the vault" treats the phantom UTXO as real.

`vault_proxy`'s spending validator does run on a phantom UTXO spend — but `vault_proxy` only checks "is the TX's structure valid," it has no way to distinguish "is the entity triggering this spend the real vault."

---

## Second (Still Insufficient) Solution: Check NFT Info in Datum

Next intuitive solution: add a `vault_nft_policy: PolicyId` field in the datum, and have `vusdcx` check "the spent UTXO carries an NFT under the corresponding policy":

```aiken
fn is_real_vault(utxo: Output, datum: VaultDatum) -> Bool {
  quantity_of(utxo.value, datum.vault_nft_policy, vault_nft_name) == 1
}
```

This also doesn't hold. The attacker can:

1. Create their own minting policy `attacker_nft_policy` and mint an NFT.
2. Set `vault_nft_policy = attacker_nft_policy` in the phantom UTXO's datum.
3. Attach `attacker_nft_policy.vault_nft` to the UTXO.

`is_real_vault()` returns `true` — the datum self-declares the NFT policy, and the UTXO does carry the corresponding NFT. But that NFT has nothing to do with V1's real Vault NFT; it's something the attacker minted separately.

The root issue: **`datum.vault_nft_policy` is a value the validator reads at runtime; the attacker can set it arbitrarily**. If the validator's identity check depends on runtime info, the identity can be forged at runtime.

---

## Third (Closer But Still Insufficient) Solution: Encode the NFT Policy in the Validator's Redeemer or a Constant

Next intuition: don't read the NFT policy from the datum; read it from some fixed source in the validator itself.

But if that "fixed source" is the redeemer, the attacker can supply any value when constructing the TX. If it's a constant returned by some helper function inside the validator — unless that constant is truly "bound to a unique identity from this validator's deployment," the attacker can redeploy a fork validator with a different constant and pair it with their phantom UTXO.

The endpoint of this design line is "make the NFT policy a compile-time parameter of the validator" — exactly what V1 does.

---

## V1's Solution: Compile-Time Parameters

```aiken
validator vault_proxy(
  // ...other stake hash parameters...
  vault_nft_policy: PolicyId,  // ← compile-time constant
) { ... }

validator vusdcx(
  vault_hash: ByteArray,
  vault_nft_policy: PolicyId,  // ← same compile-time constant
) { ... }

validator order(
  vault_hash: ByteArray,
  vault_nft_policy: PolicyId,  // ← same compile-time constant
) { ... }
```

When the deployment ceremony runs `aiken build`, this `vault_nft_policy` gets baked into the validator bytecode. **The deployed `vault_proxy` script hash uniquely corresponds to one `vault_nft_policy`** — you cannot use the same `vault_proxy` to hold NFTs from different policies, because the `vault_proxy` script hash *is* "hash after baking in that NFT policy."

Further, `vusdcx` and `order` are baked with the **same compile-time parameter**. Three independent script hashes are **all locked to the same vault_nft_policy**.

Apply this mechanism back to the phantom-vault attack:

```
Attacker constructs phantom UTXO
  ↓
The phantom UTXO must be sent to "some vault_proxy script address"
to trigger a spending validator
  ↓
If sent to V1's actually-deployed vault_proxy script address:
  → vault_proxy's spending validator checks "the spent UTXO carries
     an NFT minted by vault_nft_policy"
  → vault_nft_policy is baked-in; the attacker cannot modify it
  → phantom UTXO carries only attacker_nft, not the real Vault NFT
  → validator rejects

If sent to "a vault_proxy fork the attacker deployed":
  → The forked vault_proxy carries a different vault_nft_policy param
  → Therefore its hash differs from V1's deployed vault_proxy
  → The attacker's fork script address is a completely different
     address from V1
  → V1's frontend / indexer / vusdcx / order all don't recognize this
     address
  → Even if the attacker successfully spends their phantom UTXO, the
     shares they mint aren't V1's vUSDCx (different policy hash) and
     cannot be redeemed for USDCx at V1's vault
```

The whole trust chain is locked at compile time; runtime has no flexibility to be fooled.

---

## Why All Three Validators Must Bind the Same NFT Policy

Baking `vault_nft_policy` only into `vault_proxy` isn't enough.

If `vusdcx` doesn't also bind this policy, the attacker can take this detour:

1. Fork `vault_proxy` swapping in their `attacker_nft_policy` → deploy to a new script address.
2. Mint a fake Vault NFT at the new address, create a phantom UTXO, send the share-mint request to V1's original `vusdcx`.
3. If `vusdcx` only checks "a vault UTXO is being spent in the TX" without checking "which specific script address that vault UTXO is at," the attack succeeds.

V1's response is to bake the same `vault_nft_policy` into `vusdcx` — at execution time, `vusdcx` checks "the spent vault UTXO must carry an NFT minted by `vault_nft_policy`." A fork's vault_proxy uses a different NFT policy, so this check fails directly.

The same logic applies to `order` — it manages the deposit/withdraw queue, another script that interacts with the vault. All three share the same compile-time anchor; even if a phantom UTXO somehow reaches one script's trigger path, another script blocks it.

---

## The NFT Itself: PlutusV3 UTXO-ref One-Shot

Baking `vault_nft_policy` into the validator's compile-time parameters has a precondition: "that NFT policy is truly globally unique on-chain and unforgeable." If the NFT policy itself can be arbitrarily minted by an attacker, the whole anchoring collapses.

V1 mints the Vault NFT using a PlutusV3 UTXO-ref one-shot pattern:

```aiken
validator vault_nft(utxo_ref: OutputReference) {
  mint(_redeemer, _own_policy, tx) {
    // When minting, this specific utxo_ref must be in the inputs (consumed)
    list.any(tx.inputs, fn(i) { i.output_reference == utxo_ref })?
  }
  // burn path unconditionally allowed
}
```

`utxo_ref` is a UTXO picked at the start of the deployment ceremony (typically an ordinary ADA UTXO held by the deploy wallet). The minting condition is "this UTXO is spent in the mint TX" — a UTXO can be spent only once, so this NFT can be minted only once in its entire lifetime.

After the mint completes, the chosen utxo_ref is consumed and can never reappear. **No one can trigger a re-mint** — even with the mint script source, even with the deploy wallet's private key, even forking the entire V1. **Mint capability is permanently closed at the ledger level**.

This pattern isn't V1's invention — the Cardano community has used it for several years — but V1 applies it across three layers of anchoring:

| Anchor | NFT | Purpose |
|--------|-----|---------|
| Vault identity | `vault_nft` | Identify the real vault state UTXO |
| Governance identity | `governance_nft` | Identify the real MultisigGov UTXO (lock down required-input for governance actions) |
| Registry authentication | `registry_auth_nft` | Identify the real Registry UTXO (lock down protocol whitelist) |

All three use the same PlutusV3 UTXO-ref one-shot pattern. Each anchor handles its own class of phantom attack: phantom vault state, phantom governance UTXO, phantom registry.

---

## Why This Is Cleaner Than the Old Native-Script Approach

Another common NFT one-shot pattern on Cardano is a native script with `before` deadline:

```
{ all: [signature(deploy_pkh), before(deadline_slot)] }
```

Mechanism: deploy wallet signs + mints before some deadline. After deadline passes, the NFT policy can mint nothing further — "one-shot" achieved via time limit.

This has two structural flaws:

**(a) Trust the deploy wallet**. Any time before the deadline, the holder of the deploy wallet's private key can re-mint another NFT. The "one-shot" property rests on "we trust the deploy wallet not to re-mint before the deadline" — that's a trust assumption, not a structural guarantee.

**(b) Cannot burn after deadline**. Once the deadline expires, the entire native script becomes invalid — including the burn path. If the vault wants to sunset and burn the Vault NFT to clean up state, this is impossible past the deadline. The Vault NFT gets stuck in the vault UTXO, and the UTXO's min-ADA (about 15-20 ADA) is permanently locked.

V1's PlutusV3 UTXO-ref one-shot strictly improves on both:

- **Trust property**: mint capability stems from UTXO non-reproducibility (ledger-level guarantee), not from "we trust the deploy wallet."
- **Burn path**: burn branch is always allowed, no time limit — sunset can execute cleanly.

The cost is that a PlutusV3 mint policy's script size is slightly larger than a native script (an Aiken validator checking a UTXO-ref typically lands at 1-2 KB), but this cost is acceptable.

---

## Why This Design Line Deserves a Dedicated Article

V1 has many defense mechanisms — slippage boundaries, payload-hash binding, registry whitelists, validity-range caps — every one matters. But the phantom-vault anchor line has a unique property:

**It locks the trust chain at compile time; runtime cannot be fooled.**

Many Cardano DeFi contracts, during their internal audit process, discover that some runtime checks can be cleverly bypassed by crafted datum or redeemer. Each discovery adds a check, a require, an invariant. These patches work, but each adds surface area — future audits must verify "this check runs in all scenarios."

Compile-time anchors are different: they aren't checks, they're identity bindings. The deployed `vault_proxy` script hash *is* "hash after baking in that specific NFT policy" — this isn't a runtime condition, it's the definition of the script hash. To bypass it, an attacker would have to redeploy a fork validator with a different NFT policy — and that fork is a completely different script address from V1, with no on-chain connection to V1's deployed vault.

That's the watershed between "structural security" and "check-based security." V1 prefers structural security wherever possible; the compile-time anchor is the representative case of this principle.

---

## Series Wrap-Up

Four articles to here:

- **[Part 1](./01-three-layer-governance-safety.md)**: how three-layer governance safety makes single-signer governance an acceptable fallback
- **[Part 2](./02-adversarial-chain-replay-methodology.md)**: adversarial chain replay — turning "the contract should reject" into "the contract did reject"
- **[Part 3](./03-multi-stablecoin-depeg-not-real-diversification.md)**: multi-stablecoin configuration is not real diversification, honest disclosure of correlation risk
- **Part 4 (this)**: phantom-vault attack vector and the compile-time NFT anchor

OptiVaults V1's full source is published under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Internal audit rounds have addressed findings; external audit is targeted at Q2-Q3 2027.

V1 launches on mainnet with a 100,000 USDCx operational cap until external audit completes. The whole project is positioned as a Cardano DeFi public-goods reference implementation — forks, specializations, and commercial use are welcome, and adversarial review via GitHub Issues or [Discord](https://discord.gg/HY5sy8cz8s) is invited.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app).*
