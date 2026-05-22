# OptiVaults V1 — Vault Identity NFT Specification

*Implementation of the Validator Identity NFT pattern (see [`pattern-rationale-validator-identity-nft.md`](./pattern-rationale-validator-identity-nft.md) for the generic pattern, trade-offs against native-script alternatives, and open CIP design questions). V1 instantiates the same pattern three times — Vault NFT (this file), Governance NFT (see `gov-nft.md`), Registry Auth NFT (see `pattern-rationale-registry-auth-nft.md`). This file is the V1 case study for the Vault-NFT instantiation specifically.*

**Scope**: the one-shot Vault Identity NFT minting policy and its role as a compile-time trust anchor.

---

## 1. Purpose

The Vault Identity NFT is the on-chain marker that distinguishes the single canonical V1 vault UTXO from any other UTXO that might share the `vault_proxy` script address. Its design responsibilities:

1. **Unique mint** — exactly one NFT exists across the entire lifetime of V1 (no re-mint possible).
2. **Compile-time anchor** — the NFT minting policy is a compile-time parameter of `vault_proxy`, `vusdcx`, and `order` validators. A UTXO at the vault address lacking the NFT is not treated as a vault by any of these validators, closing the "phantom vault" class of attacks identified during internal verification.
3. **Burn path available forever** — when the vault eventually sunsets (TVL drains, `total_shares == 0`), the NFT must be burnable so the final vault UTXO can be destroyed and its min-ADA recovered. V1's design explicitly requires burn to be possible **without any time deadline** (this is why V1 does not use the native-script deadline pattern inherited from internal-verification phase — see §5 "Why not a native script").

---

## 2. Minting policy

The Vault NFT is implemented as a **PlutusV3 minting-policy validator** parameterised by a specific UTXO reference:

```aiken
use aiken/crypto.{ScriptHash}
use cardano/transaction.{Transaction, OutputReference, flatten}
use aiken/collection/list

// Compile-time parameter: the UTXO reference whose consumption grants
// authorisation to mint. Chosen at deploy time — any UTXO the deployer
// controls that has not been previously spent works.
validator vault_nft(utxo_ref: OutputReference) {
  mint(_redeemer: Data, policy_id: ScriptHash, tx: Transaction) {
    let mint_entries = flatten(tx.mint)
    let own_entries =
      list.filter(mint_entries, fn(entry) {
        let (policy, _, _) = entry
        policy == policy_id
      })
    // Partition own_entries into burns (qty < 0) vs mints (qty > 0).
    let is_burn = list.all(own_entries, fn(entry) {
      let (_, _, qty) = entry
      qty < 0
    })
    let is_mint = list.all(own_entries, fn(entry) {
      let (_, _, qty) = entry
      qty > 0
    })
    when (is_burn, is_mint) is {
      (True, _) ->
        // Burn branch: permitted unconditionally. Anyone holding a
        // Vault NFT UTXO can spend it and burn the token in the same
        // transaction. No time constraint, no signer constraint.
        True
      (_, True) ->
        // Mint branch: exactly one token named "OptiVault" with
        // quantity 1, and the parameterised UTXO reference must be
        // consumed as a TX input (UTXOs can only be spent once, so
        // this firmly bounds the mint to a single event ever).
        and {
          list.length(own_entries) == 1,
          expect_one_opti_vault_mint(own_entries),
          list.any(tx.inputs, fn(i) { i.output_reference == utxo_ref }),
        }
      _ ->
        // Mixed mint + burn of own_policy in same TX: reject.
        // Clean semantics; only pure-mint or pure-burn allowed.
        False
    }
  }
  else(_) {
    // No spending or withdrawal purpose on this validator.
    False
  }
}

fn expect_one_opti_vault_mint(entries: List<(ByteArray, ByteArray, Int)>) -> Bool {
  when entries is {
    [(_, name, qty)] -> name == "OptiVault" && qty == 1
    _ -> False
  }
}
```

**Deploy-time choice of `utxo_ref`**: during V1 mainnet deploy ceremony, the operator selects a specific UTXO they control that has not yet been spent. This UTXO becomes the compile-time parameter, and the first mint TX consumes it. After consumption, no future TX can replay the mint (the UTXO is gone from the ledger).

---

## 3. Security properties

### 3.1 Cryptographic one-shot (vs trust-based)

Prior internal-verification deployments used a **native-script** minting policy of the form `{all: [sig(keeper_pkh), before(slot)]}`. That design is **trust-based**:

- Primary guarantee — only `keeper_pkh` can mint; the system relies on the keeper promising not to mint more than once.
- Secondary guarantee — `before(slot)` puts a hard deadline on when any mint can happen. After the deadline, no mint is possible.
- Vulnerability — if `keeper_pkh` is compromised before the deadline expires, an attacker can mint a second Vault NFT under the same policy and present a phantom vault.

V1's PlutusV3 design is **cryptographic one-shot**:

- The mint precondition (`utxo_ref` present as input) is a ledger-level fact that can be satisfied exactly once — the UTXO is consumed by the mint TX and does not exist in subsequent states.
- No keeper trust required on the mint branch. A compromised keeper key cannot mint a second NFT because there is no second instance of the `utxo_ref` UTXO to consume.

### 3.2 Burn always available (vs deadline-trapped)

The native-script pattern uses the same script expression for both mint and burn, meaning the `before(slot)` deadline blocks burn after expiry alongside mint. In internal-verification-era deployments this caused heritage mainnet vaults to become **permanently undrainable** after the deadline (≈2–5 days post-deploy), leaving ~15–20 ADA per vault locked as reference-UTXO min-ADA for the lifetime of the chain.

V1's PlutusV3 design partitions the script by redeemer quantity sign. The burn branch imposes no constraint beyond ownership (the UTXO holding the NFT must be spendable by its holder — normal ledger rules) and is valid at any slot. This preserves the vault's sunset path:

1. All depositors withdraw their shares (partial Withdraw).
2. Last holder does full-drain Withdraw with `total_shares → 0`, burning the Vault NFT in the same TX (the `vault_user.ak` `Withdraw` redeemer full-drain branch — migrated from vault_core during the authorization-boundary split — requires `quantity_of(tx.mint, vault_nft_policy, "OptiVault") == -1`).
3. The `vault_nft` validator's burn branch passes (no constraint).
4. The vault UTXO is destroyed; min-ADA returns to the withdrawing user.

No ADA is permanently locked.

### 3.3 Mint-quantity safety

The mint branch enforces `quantity == 1` and `asset_name == "OptiVault"`. Attempted multi-mint, zero-mint, or wrong-asset-name mints are rejected. Combined with the one-time consumption of `utxo_ref`, this guarantees exactly one `(policy_id, "OptiVault")` token exists in the global ledger over V1's lifetime.

### 3.4 Defence against rogue-policy injection

Even if an attacker deploys their own `vault_nft` validator parameterised by a different UTXO they control and mints a token they name "OptiVault", the resulting policy ID differs from V1's (because the UTXO ref parameter differs, so the compiled script hash differs). The `vault_proxy` / `vusdcx` / `order` validators bake V1's specific `vault_nft_policy` into their own compile-time parameters, so they reject any UTXO at the vault address that does not carry V1's specific NFT policy token. Phantom vault attacks are closed at the validator-anchor level, not at the policy-name level.

---

## 4. Lifecycle

### 4.1 Mint (deploy)

During the V1 mainnet deploy ceremony (`docs/runbooks/v1-mainnet-ceremony.md`):

1. Operator selects an unspent UTXO they control as the compile-time parameter
2. Operator compiles `vault_nft` validator with that UTXO ref → produces `vault_nft_policy`
3. Operator compiles `vault_proxy`, `vusdcx`, `order` with `vault_nft_policy` as compile-time parameter
4. Operator builds vault-init TX consuming `utxo_ref` and minting 1 × "OptiVault" token
5. Mint TX outputs the token to the vault UTXO at `vault_proxy` address (alongside initial vault datum + any seed USDCx)
6. Post-mint, `utxo_ref` no longer exists on ledger → no future mint is possible

### 4.2 Ongoing (vault operation)

The Vault NFT stays in the vault UTXO across every TX (Deposit, Withdraw, Compound, BatchProcess, DeployToProtocol, etc.). The `vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_gov_emergency`, and `vault_admin_deploy` validators each enforce `quantity_of(output.value, vault_nft_policy, "OptiVault") == 1` on the continuing output — the NFT is physically preserved in the vault UTXO.

### 4.3 Burn (sunset / V2 migration)

Full-drain Withdraw (`total_shares = 0` after withdrawal) requires the NFT to be burned in the same TX:

- Keeper or founder builds a Withdraw TX with `withdraw_amount == vault_total` and `tx.mint` including `(vault_nft_policy, "OptiVault", -1)`
- `vault_user.ak` full-drain branch checks `nft_burned == -1`
- `vault_nft` validator burn branch passes (no constraint)
- Vault UTXO is destroyed; the min-ADA + any residual tokens go to the receiver address specified in the Withdraw redeemer

No second NFT can ever be minted under the same policy (the parameterised UTXO was consumed long ago). The policy is effectively decommissioned.

### 4.4 Emergency burn

If V1 needs to be emergency-wound down via `EmergencyWithdraw` governance action without going through full-drain Withdraw, the governance TX can include a direct NFT burn — the burn branch always validates. This is unusual but supported: useful if a bug in vault_core prevents the full-drain path from executing.

---

## 5. Why not a native script

Internal-verification phase used `{all: [sig, before(slot)]}` native scripts for vault NFT minting. That choice optimised for:

- **Small script size** — native scripts are a handful of bytes; PlutusV3 validators are a few KB.
- **Zero Plutus evaluation cost at mint** — native script evaluation is a ledger-native fast path; PlutusV3 evaluation consumes mem/steps.

The trade-offs V1 accepts in exchange for PlutusV3:

- Cryptographic (not trust-based) one-shot guarantee — closes keeper-key-compromise mint attack.
- Burn path not deadline-locked — enables clean sunset without permanent ADA lockup.
- Slightly larger reference-script min-UTXO (~10–20 ADA more than native, one-time at deploy).
- Minor Plutus eval cost on mint and burn (a few hundred thousand mem units).

For a vault whose target lifetime is indefinite and where the sunset-path ADA recovery is a real economic consideration, PlutusV3 is the correct trade.

---

## 6. CIP-applicability

The Vault NFT is V1's reference instantiation of the **Validator Identity NFT** pattern documented in [`pattern-rationale-validator-identity-nft.md`](./pattern-rationale-validator-identity-nft.md). The pattern is a candidate for future Cardano Improvement Proposal standardisation; V1 does not author a CIP at the V1 stage. See [`cip-readiness-posture.md`](../docs/cip-readiness-posture.md) for the overall posture.

### 6.1 What V1 inherits from the generic pattern

| Pattern property | V1 Vault NFT enforcement |
|---|---|
| Compile-time UTXO-ref anchor | `vault_nft` validator parameterised by `utxo_ref: OutputReference`; the parameter is selected at the V1 mainnet deploy ceremony |
| Cryptographic one-shot (mint at most once over chain history) | `list.any(tx.inputs, fn(i) { i.output_reference == utxo_ref })` precondition on the mint branch — the UTXO is consumed on first mint and cannot be re-consumed |
| Burn always available (no time constraint) | Burn branch is unconditional — verifies only `asset_name` and `quantity == -1`. The spending validator guarding the UTXO containing the NFT gates *when* the burn can happen |
| Mint-quantity safety | `pair.2nd == 1` strict equality on the mint branch (not `> 0`) |
| Rogue-policy injection defence | `vault_proxy`, `vusdcx`, and `order` validators bake V1's specific `vault_nft_policy` into their own compile-time parameters; an attacker-deployed copy of the validator with a different UTXO-ref produces a different policy ID, which fails the consumer-side check |

§3.1–§3.4 above provide the V1-specific security argument; the generic pattern's security reasoning in the rationale doc applies unchanged.

### 6.2 V1-specific design choice

`asset_name` is hardcoded to the constant `vault_nft_token_name = "OptiVault"` rather than exposed as a compile-time parameter. The pattern document admits both forms (see its §7 open question 1). V1 picks the hardcoded form because the deployment is single-instance — no fork-customisation is intended at V1 stage; the validator code is identical across any conforming V1 deploy. A different deployment that intends to support distinct vault instances under one codebase would expose `asset_name` as a second parameter, matching the shape used by V1's `governance_nft.ak` and `registry_auth_nft.ak` (which do expose `gov_name` / `asset_name` because their reuse profile differs).

### 6.3 Related pattern-rationale docs

- [`pattern-rationale-validator-identity-nft.md`](./pattern-rationale-validator-identity-nft.md) — the generic pattern (V1's primary rationale for the Vault NFT)
- [`pattern-rationale-withdraw-zero-forwarding.md`](./pattern-rationale-withdraw-zero-forwarding.md) §4.3 — the singleton-enforcement composition: Withdraw-Zero alone does not bound how many UTXOs sit at the vault address; the Vault NFT closes that gap
- [`pattern-rationale-vault-datum-tiered.md`](./pattern-rationale-vault-datum-tiered.md) — VaultDatum's identity-tier fields include the compile-time-anchored token references that depend on this NFT being authentic
- [`cip-readiness-posture.md`](../docs/cip-readiness-posture.md) — overall V1 stance on Cardano Improvement Proposals

---

## 7. Related specs

- `spec/architecture.md` §4 — validator #11 summary row
- `spec/vault-datum.md` §2.3 — how `vault_nft_policy` is used as a compile-time anchor on `vault_proxy`, `vusdcx`, `order`
- `docs/security-model.md` — phantom vault attack analysis and internal-verification fix history
