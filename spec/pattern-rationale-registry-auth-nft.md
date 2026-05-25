# Pattern Rationale — Registry + Auth NFT Whitelist

**Status**: informational pattern rationale. Not a CIP, not a CIP draft. See `docs/cip-readiness-posture.md` for OptiVaults V1's overall position on Cardano Improvement Proposals.

**Scope**: a recurring pattern for maintaining a governance-mutable on-chain configuration object — typically a whitelist of allowed destinations, a market catalogue, or a parameter table — anchored by a one-shot identity NFT, with differential mutation rules per redeemer. The pattern composes Pattern 1 (Validator Identity NFT) with a singleton-state validator and a per-redeemer mutation policy. OptiVaults V1 uses it as its protocol-destination + Liqwid-market + swap-adapter registry (case study in §6).

---

## 1. Problem

DeFi protocols frequently need to externalise some piece of configuration that:

- Must be **trusted** by the protocol's own validators (e.g., "is this destination address one that the keeper is allowed to route funds to?").
- Must be **updatable post-deploy** under governance control (e.g., adding a new DEX adapter, pausing a problematic lending market, refreshing a price-feed reference).
- Must be **read efficiently** by many transactions per day without each read paying the cost of full datum-mutation validation.
- Must resist **forgery** — an attacker who plants a UTXO with an attacker-favourable inline datum at the configuration script address must not be able to convince the consuming validators that their UTXO is the real configuration.

Approaches that fall short:

1. **Compile-time-only configuration.** Bake the whitelist into each consuming validator's compile-time parameters. Simple and forgery-proof, but **immutable** — any whitelist change requires a redeploy, which on a deposit-holding protocol means migrating user funds.
2. **Per-consumer datum copies.** Each consumer validator carries its own copy of the whitelist as a mutable datum. Avoids redeploy, but multiplies the surface area for forgery, multiplies the governance plumbing, and creates consistency bugs when copies drift.
3. **Centralised off-chain configuration.** Keep the whitelist off-chain and feed it to the validators via redeemer arguments. Removes on-chain authenticity entirely — the keeper or the user can supply any value.

The Registry + Auth NFT Whitelist pattern is a structural response: a single on-chain configuration UTXO, anchored by an identity NFT, updatable through a constrained set of redeemers, readable cheaply via reference inputs.

---

## 2. The Pattern

A Registry implementation defines:

- **A Registry validator** with one or more redeemer paths. The validator owns a single canonical state UTXO (the *Registry UTXO*) at its script address. The validator's logic per redeemer specifies (a) which fields of the inline datum are allowed to change, and (b) what authorisation is required for the change (e.g., governance signature, keeper-only unilateral toggle, time-based cooldown).
- **An Identity NFT minting policy** (Pattern 1) parameterised by a deploy-time UTXO reference. Exactly one Registry Auth NFT is minted and held in the Registry UTXO from deploy onward. The NFT's policy ID is the protocol's "the real registry is the one carrying this token" claim.
- **A consumer-side authenticated read helper** that any validator wanting to read the Registry calls. The helper verifies the supplied Registry UTXO carries the expected Auth NFT policy + name, then returns the inline datum. UTXOs at the Registry address that lack the NFT are rejected.

The Registry datum carries whatever configuration the protocol externalises. Common shapes:

- `protocol_hashes: List<ByteArray>` — allowed destination script hashes
- `markets: List<MarketEntry>` — per-market metadata (address, NFT policy, action validator)
- `oracle_feeds: List<OracleEntry>` — price feed policy + asset references
- `governance_anchor: (PolicyId, AssetName)` — the governance NFT this Registry's update path defers to
- Cooldowns / timestamps / bounds — operational metadata that governs *when* updates may happen

The redeemer set typically distinguishes between:

- **Slow update path** — multi-day governance timelock, broad field-mutation rights. Used for adding a new DEX adapter, replacing a market, changing oracle parameters.
- **Fast update path** (optional) — short or zero governance timelock, narrow field-mutation rights (typically only "the world changed, update *this* one URL"). Used for emergency migrations where the slow path would be too slow.
- **Unilateral pause path** (optional) — a non-governance authority (often the keeper) can flip a single boolean from `active=True` to `active=False`. Used for circuit-breaker behaviour where any party with operational visibility can stop bad routes without waiting for governance.

Each redeemer encodes which fields are mutable and which are immutable. The validator enforces the per-redeemer mutation envelope by comparing the old datum (read from the spent input) with the new datum (read from the continuing output) field by field.

---

## 3. Aiken Sketch

A minimal Registry validator with two redeemers:

```aiken
type RegistryDatum {
  governance_anchor: (PolicyId, AssetName),
  whitelist: List<ByteArray>,
  last_update_time: Int,
}

type RegistryRedeemer {
  UpdateWhitelist           // Governance-gated, slow path
  PauseEntry { index: Int } // Operator-unilateral, narrow effect
}

validator registry(cooldown_ms: Int) {
  spend(datum: Option<RegistryDatum>, redeemer: RegistryRedeemer, own_ref, tx) {
    expect Some(old) = datum
    expect Some(own_input) = list.find(tx.inputs, fn(i) { i.output_reference == own_ref })
    expect Script(own_hash) = own_input.output.address.payment_credential
    expect Some(cont) = find_single_continuing(tx.outputs, own_hash)
    expect InlineDatum(new_data) = cont.datum
    expect new: RegistryDatum = new_data

    // Auth NFT preserved on the continuing output (forgery defence)
    let nft_preserved = nft_count(cont.value, auth_nft_policy, auth_nft_name) == 1

    // Cooldown enforced
    let cooldown_ok = new.last_update_time >= old.last_update_time + cooldown_ms

    // Per-redeemer mutation envelope
    let envelope_ok = when redeemer is {
      UpdateWhitelist ->
        and {
          new.governance_anchor == old.governance_anchor,        // anchor immutable
          gov_signed(tx, old.governance_anchor),                 // governance must sign
          list.length(new.whitelist) <= 20,                      // upper bound
        }
      PauseEntry { index: _ } ->
        and {
          new.governance_anchor == old.governance_anchor,
          new.whitelist == old.whitelist,                        // unchanged here
          operator_signed(tx),
          // PauseEntry would also touch a hypothetical `active: Bool` per
          // entry — elided from this sketch for clarity.
        }
    }

    and { nft_preserved, cooldown_ok, envelope_ok }
  }
}
```

The consumer-side authenticated read (used by any validator that wants to read the Registry as a reference input):

```aiken
fn read_registry_datum(
  ref_inputs: List<Input>,
  expected_auth_policy: PolicyId,
  expected_auth_name: AssetName,
) -> RegistryDatum {
  expect Some(found) = list.find(ref_inputs, fn(i) {
    nft_count(i.output.value, expected_auth_policy, expected_auth_name) == 1
  })
  expect InlineDatum(d) = found.output.datum
  expect parsed: RegistryDatum = d
  parsed
}
```

A consumer validator that wants to check "is this destination address whitelisted" calls `read_registry_datum`, then does `list.has(reg.whitelist, target_hash)`. The NFT check inside `read_registry_datum` is the consumer's only forgery defence.

---

## 4. Security Properties

### 4.1 Singleton enforcement via Identity NFT

Exactly one Registry UTXO carrying the Auth NFT can exist at any time. Pattern 1's cryptographic one-shot guarantee — the NFT is mintable at most once over the validator's lifetime — propagates to the Registry: a forged "second" Registry UTXO at the same address cannot carry the same NFT, so consumers reject it on the NFT check.

The Registry validator itself preserves the NFT on the continuing output on every mutation, so the NFT travels with the canonical state UTXO across every update.

### 4.2 Read-side authentication is the consumer's responsibility

The Registry validator only runs when the Registry UTXO is spent (i.e., updated). A reader that uses the Registry as a **reference input** does not invoke the Registry validator at all — the reader must independently verify the supplied Registry UTXO carries the expected Auth NFT. The `read_registry_datum` helper centralises this check; protocols using the pattern should standardise on a single helper function and route every Registry read through it.

A bug class to watch: a consumer that reads the Registry UTXO without the NFT check is trivially exploitable. Code review for this pattern should grep for "reference input" near "Registry" and confirm every such call site goes through the authenticated read helper.

### 4.3 Per-redeemer mutation envelopes

Each redeemer declares which fields it is allowed to mutate. The validator enforces the envelope by comparing old datum and new datum field by field. This factors a complex multi-redeemer policy into a checkable matrix:

| Field | Slow update | Fast update | Unilateral pause |
|---|---|---|---|
| `governance_anchor` | immutable | immutable | immutable |
| `whitelist` | mutable | immutable | immutable |
| `oracle_feeds` | mutable | immutable | immutable |
| `market_action_hash` | mutable | mutable | immutable |
| `market.active` | mutable | mutable | mutable (one-way False) |
| `last_update_time` | enforced + cooldown | enforced + cooldown | enforced |

The matrix is auditable in a single pass — for each redeemer, every field is one of {immutable, mutable, one-way}. Bugs that allowed a low-authority redeemer to mutate a high-authority field would surface as a missing equality check in the validator's per-redeemer branch.

### 4.4 Upper-bound caps on list sizes

Each list-valued field (`whitelist`, `markets`, `oracle_feeds`, ...) carries an upper-bound cap (e.g., `≤ 20`). Without a cap, a malicious governance proposal could grow the Registry datum unboundedly, eventually causing consumer transactions to fail on memory limits during the authenticated-read step. With a cap, consumer cost is bounded.

### 4.5 Time-cooldowns

A `last_update_time` field + cooldown check (typically 1 hour to 1 day) prevents an attacker who has captured the governance key from launching a rapid succession of malicious updates. Combined with timelock on the governance side, this gives off-chain monitoring time to detect and contest a single suspicious update before the next one can land.

---

## 5. Trade-offs vs Alternatives

| Approach | Update without redeploy | Forgery resistance | Per-read cost | Inter-validator consistency |
|---|---|---|---|---|
| Compile-time parameters only | No | Strong (compiled in) | Free | Trivially consistent |
| Per-consumer datum copies | Yes | Weak per copy; needs full validator-per-copy | Per copy | Copies drift |
| Off-chain config + redeemer args | Yes | None (redeemer-provided) | Free | Caller-controlled |
| **Registry + Auth NFT (this pattern)** | Yes | Strong (NFT-anchored) | One NFT check | Single source of truth |

The trade made by the pattern: pay one NFT-check per read in exchange for runtime updatability + singleton anchoring + a single source of truth across all consumers. For configuration that changes 1–10 times per year and is read 100s–1000s of times per day, this trade is clearly favourable.

**On CIP-72**: CIP-72 describes a dApp publishing outward identity metadata. The Registry + Auth NFT pattern is the inverse direction — protocol-internal configuration consumed by the protocol's own validators. The two solve orthogonal problems and would not be combined under a single CIP. See `docs/cip-readiness-posture.md` §3 for the full CIP-72 stance.

---

## 6. OptiVaults V1 Case Study

V1's Registry is at `contracts/validators/registry.ak`, anchored by `registry_auth_nft.ak` (one of three Pattern-1 instantiations). The Registry datum (`RegistryDatum` in `contracts/lib/vault/types.ak`) carries 9 fields:

| Field | Mutability | Purpose |
|---|---|---|
| `governance_policy` | immutable | Governance NFT policy ID — the anchor for the slow-path UpdateRegistry redeemer's authorisation check |
| `governance_name` | immutable | Companion to `governance_policy` |
| `keeper_pkh` | immutable | Keeper identity for the unilateral `KeeperToggleMarket` redeemer's authorisation check |
| `protocol_hashes` | mutable (slow path, capped at 20) | Whitelist of destination script hashes the keeper may route funds to via DeployToProtocol |
| `stable_tokens` | mutable (slow path, capped at 50) | Stable-token policy+name allowlist for NDV scanning |
| `liqwid_markets` | mutable (slow path, capped at 20) + per-market `active` flag (unilateral pause one-way) + per-market `action_addr_hash` (fast path) | Per-market metadata for Liqwid integration |
| `asset_oracles` | mutable (slow path, capped at 20) | Dual-feed (Charli3 + Orcfax) oracle references per asset |
| `swap_adapter_hashes` | mutable (slow path, capped at 10) | Whitelist of audited DEX adapter validator hashes |
| `last_update_time` | enforced + 1-hour cooldown | Anti-rapid-update protection |

Three redeemers (per `RegistryRedeemer`):

- **`UpdateRegistry`** — slow governance path (14-day timelock + 1-hour cooldown). Broad mutation rights, but the three immutable fields (`governance_policy`, `governance_name`, `keeper_pkh`) cannot change. Carries a payload-hash binding so the governance Queue+Execute flow commits to the exact new datum.
- **`KeeperToggleMarket`** — keeper unilateral pause. Single-direction one-way: any `liqwid_markets[i].active` may flip `True → False`, never the reverse. Used as a fast circuit-breaker if a Liqwid market becomes problematic.
- **`FastUpdateMarkets`** — short governance path (1-hour timelock + 1-hour cooldown). Only `action_addr_hash` + `active` are mutable per market. Used for Liqwid action-validator migration events where the slow path would force the protocol to deploy in a broken state during the migration window.

The authenticated read is `helpers.read_registry_datum` in `contracts/lib/vault/helpers.ak`. Every consumer (`vault_protocol.DeployToProtocol`, `vault_admin_deploy.AdminDeployNonDeposit`, the keeper-side router) calls into this helper rather than reading the reference input directly.

Internal verification confirmed that all current consumer call sites route through the authenticated read; defence-in-depth audit checks for this invariant are part of the standing regression suite (`audit-scope.md` Coverage area C — V1 Integration Flows).

---

## 7. Open Questions for Future CIP Work

If this pattern is ever proposed for CIP standardisation, the discussion should resolve:

1. **Schema versioning of the datum.** The Registry datum is consumed by multiple validators with different deploy lifetimes; an upgrade adds new fields. A CIP should specify how to evolve the schema without breaking heritage readers (proto3-style optional fields, version-tagged unions, side-by-side Registry deployment with a migration redeemer).
2. **Authenticated-read helper conventions.** The pattern's correctness rests on every reader going through the NFT-check helper. A CIP could standardise the helper's signature and provide a reference Aiken library so protocols don't write it ad hoc.
3. **Cap discovery.** Bounded list sizes are a soft contract between the writer and the reader. A CIP could specify cap discovery — caps published in a known-location field of the datum, or as a separate CIP-25-style metadata document.
4. **Composition with CIP-68.** Whether the Auth NFT should simultaneously serve as a CIP-68 reference NFT for discovery is open; the current pattern keeps the NFT metadata-free.
5. **Naming.** "Registry" is heavily overloaded in Cardano DeFi vocabulary. A CIP might pick a sharper name (e.g., "Configuration Anchor" or "Protocol Parameter UTXO") to reduce collision with CIP-72-style outward registration.

---

## 8. See Also

- `contracts/validators/registry.ak` — reference Registry validator
- `contracts/validators/registry_auth_nft.ak` — Auth NFT (Pattern 1 instantiation #3)
- `contracts/lib/vault/helpers.ak` `read_registry_datum` — the authenticated read helper
- `contracts/lib/vault/types.ak` `RegistryDatum` / `RegistryRedeemer` — V1's datum shape
- `spec/pattern-rationale-validator-identity-nft.md` — Pattern 1, composed with this one
- `spec/pattern-rationale-withdraw-zero-forwarding.md` — Pattern 3; V1's Registry consumers use Withdraw-Zero to invoke the validators that read the Registry
- `spec/pattern-rationale-multisig-gov-timelock.md` — Pattern 2; the governance system that gates `UpdateRegistry` and `FastUpdateMarkets`
- `docs/cip-readiness-posture.md` — the overall CIP posture; §3 specifically addresses CIP-72

---

**Document status**: informational pattern rationale. Reflects V1 design as of launch readiness. Revisions will follow the conditions stated in `cip-readiness-posture.md` §4.
