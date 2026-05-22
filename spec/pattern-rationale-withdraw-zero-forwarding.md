# Pattern Rationale — Withdraw-Zero Forwarding

**Status**: informational pattern rationale. Not a CIP, not a CIP draft. See `docs/cip-readiness-posture.md` for OptiVaults V1's overall position on Cardano Improvement Proposals.

**Scope**: a recurring pattern for moving on-chain business logic out of a spending validator and into one or more staking validators, triggered by zero-amount withdrawals. The pattern is generic; OptiVaults V1 uses it as the structural backbone of the entire vault (1 proxy validator + 10 routed staking validators), documented as a case study in §6.

---

## 1. Problem

Cardano's eUTXO model imposes four constraints on any protocol that wants to keep state on chain:

1. **No mutable global state.** All state lives in UTXOs. A protocol with a singleton state object (a vault holding pooled funds, a registry holding governance configuration) consumes its current state UTXO and produces a new one in every state-changing transaction.
2. **Every input triggers its validator in full.** A spending validator runs whenever its UTXO is consumed, with no way to skip evaluation. If the validator carries the union of all possible business checks for a singleton state UTXO, every transaction pays the full Plutus evaluation cost of all those checks.
3. **The 16 KB script-size ceiling.** Each compiled validator must fit within Cardano's per-script byte budget. A non-trivial protocol — multi-action vault, multi-redeemer governance, multi-market lending — quickly exceeds 16 KB if compiled monolithically.
4. **Reference-script fee scales with size.** Even when validators are deployed as reference scripts, every transaction that uses them pays a fee proportional to the referenced bytes. A monolithic 16 KB validator imposes that cost on every transaction, whether the operation in question needs the validator's full logic or only a sliver of it.

Constraint (1) is structural — singleton state UTXOs are unavoidable for protocols that pool funds. Constraints (2), (3), (4) together create the **monolithic validator problem**: as protocol scope grows, the spending validator that guards the state UTXO accretes business logic until it hits the 16 KB wall, at which point further protocol growth is blocked.

The Withdraw-Zero Forwarding Pattern is a structural response. It moves business logic out of the spending validator and into one or more staking validators, while keeping the singleton state UTXO at a single address.

---

## 2. The Pattern

A protocol implementing Withdraw-Zero Forwarding deploys two kinds of validators:

- **One spending validator** (here called *proxy*) that guards the singleton state UTXO. The proxy contains no business logic. Its single job is to confirm that the transaction triggers one of a fixed, compile-time-known set of staking validators by means of a zero-amount withdrawal entry against that staking validator's credential.
- **N staking validators** (here called *routes*) that carry the actual business logic. Each route handles one logical slice of the protocol — deposit / withdraw, compound, governance, swap, lending integration. Each is compiled independently; each is bounded under 16 KB independently.

The trigger mechanism is the curious-but-deliberate **zero-amount withdrawal**. A Cardano transaction can include withdrawals from stake credentials; if the stake credential is bound to a staking validator, that validator runs as part of the transaction validation. The withdrawal amount can be zero, in which case no ADA actually moves — but the staking validator still runs. This converts the staking validator into a "logic module that the transaction's author opts into by adding a zero-withdraw entry".

The key Cardano-ledger property that makes this work: **a spending validator and a staking validator triggered in the same transaction see the same transaction context**. They observe the same inputs, the same outputs, the same mints, the same withdrawals, the same validity range. Validation work can therefore be delegated from the spending validator (which must run on every consume of the state UTXO) to a staking validator (which the transaction's author selects), without losing any context the validation depends on.

Schematically:

```
                    ┌────────────────────────────────────────┐
       ┌────────────│       Transaction (TX context)         │────────────┐
       │            └────────────────────────────────────────┘            │
       │                                                                  │
       ▼                                                                  ▼
  proxy validator                                              route N staking validator
  (runs because singleton                                      (runs because TX includes
   state UTXO is spent)                                         zero-withdraw against it)
       │                                                                  │
       │ Sees: full TX                                                    │ Sees: same full TX
       │ Checks: TX contains a zero-withdraw                              │ Checks: deposit amount,
       │   entry against ONE of the {1..N}                                │   share math, datum
       │   approved route stake credentials                               │   delta, output addresses, ...
       │ Decides: pass / fail                                             │ Decides: pass / fail
       ▼                                                                  ▼
                              Both must pass for TX to validate.
```

The state UTXO continues to live at the proxy address. Business logic now lives across N route validators. The composition of which route is active is decided by the transaction author by choosing which zero-withdraw entry to include, subject to the proxy's pinned set of acceptable routes.

---

## 3. Aiken Sketch

A minimal proxy:

```aiken
type ProxyRedeemer { Use(Int) }  // index into the pinned routes list

validator proxy(routes: List<ByteArray>) {
  spend(_datum, redeemer: ProxyRedeemer, _own_ref, tx: Transaction) {
    expect Use(idx) = redeemer
    expect Some(target_stake_hash) = list.at(routes, idx)
    list.any(tx.withdrawals, fn(pair) {
      let (cred, amount) = pair
      cred == Inline(Script(target_stake_hash)) && amount == 0
    })
  }
}
```

`routes` is a compile-time parameter — a fixed list of staking validator hashes baked into the proxy's compiled bytecode. The proxy refuses to route to anything not in the list; adding a new route requires a redeploy.

A minimal route validator (here a "deposit" route as an illustration):

```aiken
validator deposit_route(...compile-time-params...) {
  withdraw(redeemer: DepositRedeemer, _stake_cred, tx: Transaction) {
    // Read the state UTXO from tx.inputs
    // Verify expected datum delta, share-math, fee accounting, ...
    // Return True iff all checks pass.
    ...
  }
}
```

The route validator's `withdraw` handler runs because the transaction includes the zero-withdraw entry. It reads the state UTXO from `tx.inputs` (the same UTXO the proxy is currently being invoked against — the ledger guarantees the contexts match), and verifies whatever business rules apply to the deposit slice of the protocol.

Two clean separations fall out of this shape:

- **Routing legitimacy is the proxy's job.** "Is one of the approved routes being triggered?"
- **Business validity is the route's job.** "Given that this route is the active one, does this transaction satisfy this route's specific rules?"

Neither concern needs to know anything about the other. The proxy never reads the state UTXO's datum. The route never enumerates the other routes.

---

## 4. Security Properties

### 4.1 Same-TX-context guarantee

The pattern's correctness rests on the ledger property that all validators triggered by the same transaction observe identical transaction context. A proxy that "trusts" that some route was triggered is not trusting the route's *integrity* — it is trusting the ledger to have run the route's logic on the same transaction the proxy is approving. The ledger's TX-context determinism makes the delegation safe.

### 4.2 Route enumeration is closed at deploy

The proxy's compile-time `routes` parameter pins the set of acceptable staking validator hashes at deploy time. After deployment, no additional route can be added without producing a different proxy hash, which corresponds to a different on-chain address — i.e., a different protocol. The state UTXO at the original proxy address remains gated by the original route set.

This closure is important. If routes could be added at runtime, the protocol's authorization surface would grow without bound. By contrast, **changing what a single route allows** (by upgrading the route's logic, or by mutating any datum the route consumes) is governable via whatever mechanism the protocol chooses — staking validators carry no datum themselves, so route upgrades go through stake-credential rotation, not a simple datum mutation. The protocol can decide whether route upgrade is something it wants to support; most do not.

### 4.3 Singleton enforcement is orthogonal

The pattern as stated does not by itself enforce that exactly one state UTXO exists at the proxy address. Anyone can pay ADA into the proxy address with arbitrary inline datum, creating "phantom" state UTXOs. Two defences are common:

- **Identity-NFT anchoring.** The proxy additionally verifies that the spent UTXO carries a specific minting-policy token (see `pattern-rationale-validator-identity-nft.md`). The route validators do the same for any state UTXO they read. Forged UTXOs fail the NFT check.
- **Datum shape gating.** The proxy or routes reject UTXOs whose inline datum does not match the expected schema. This is weaker than NFT anchoring because attackers can produce well-shaped datums; it is useful as defence-in-depth.

V1 uses both. The pattern document treats anchoring as a complementary pattern (Pattern 1, Validator Identity NFT) rather than baking it into Withdraw-Zero Forwarding itself.

### 4.4 Stake-credential registration is a precondition

Each route's stake credential must be registered on chain before the first zero-withdraw against it can succeed. Registration is a separate transaction with its own deposit (typically 2 ADA per credential on Cardano mainnet, refunded on deregistration). For a protocol with N routes, the deploy ceremony performs N stake registrations.

This is operationally significant: the deploy ceremony's complexity grows linearly with route count, and the protocol's permanent ADA float includes N × 2 ADA in stake-deposit holdings.

### 4.5 Reference script ordering

Routes are typically deployed as reference scripts to amortise per-transaction costs. Each route is referenced only by the transactions that actually use it — a deposit transaction references the proxy and the deposit route, but not the compound route. This is the Constraint (4) mitigation in §1: reference-script fee scales with what each transaction actually needs.

---

## 5. Trade-offs vs Alternatives

| Approach | 16 KB ceiling | Ref-script fee on the common path | Authorisation isolation | Deploy complexity |
|---|---|---|---|---|
| Monolithic spending validator | Hit at moderate protocol size | Pays for full logic on every TX | All checks share one validator scope | Single validator |
| Multi-UTXO state at multiple script addresses | Not hit (each address has its own validator) | Pays per address | Per-address | Many validators, but no zero-withdraw plumbing |
| **Withdraw-Zero Forwarding (this pattern)** | Not hit (each route ≤ 16 KB) | Pays for proxy + one route | Per-route stake credential | Proxy + N stake registrations |
| Mint-policy delegation (mint a "permission token" per redeemer) | Not hit | Pays for mint policy | Per-token | Each redeemer becomes a mint TX |

The trade made by Withdraw-Zero Forwarding: accept the per-route stake-registration ADA deposit and the linear growth of deploy-ceremony complexity, in exchange for the structural ability to grow protocol scope without hitting 16 KB and without paying the cost of unused logic in every transaction.

Mint-policy delegation is mechanically similar (both pull validation work out of the spending validator) but is awkward when the protocol needs to express "this redeemer changes the state UTXO's datum" — mint policies don't naturally read or assert on spending validator outputs unless you wire it carefully. Withdraw-Zero is structurally the cleaner fit for state-UTXO protocols.

The multi-UTXO-state alternative is appropriate when the protocol's logical slices operate on **disjoint** state (e.g., one UTXO per user position, no shared pool). For pooled-state protocols where every operation reads and updates the same singleton, splitting state across addresses introduces concurrency contention and ordering bugs; keeping state singleton + splitting logic is the cleaner factoring.

---

## 6. OptiVaults V1 Case Study

V1 deploys this pattern at full scale: **1 proxy validator + 10 routed staking validators + supporting validators (governance, registry, swap adapter, ...)**. The proxy is `vault_proxy.ak` (~4.9 KB compiled), parameterised by the 10 route stake hashes plus the Vault Identity NFT policy.

The 10 routes split V1's vault logic along **four orthogonal cuts**, each cut motivated by a specific authorisation or operational concern:

1. **Permissionless vs keeper-authorised** — splits user paths (`vault_user`) from keeper paths (`vault_keeper_hot`, `vault_batcher`).
2. **Hot path vs governance path** — splits keeper-hot operations from governance-mutation operations (`vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`).
3. **In-vault math vs external-protocol interaction** — splits internal compound/rebalance from external-protocol routing (`vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_swap_ada`).
4. **Synchronous vs queued** — splits direct user actions from batched/queued actions (`vault_batcher`).

The full reasoning behind the four cuts is in the long-form architecture article `docs/articles/architecture/03-seventeen-validators-four-cuts.md`. The companion narrative on the pattern itself is `docs/articles/architecture/02-withdraw-zero-forwarding-pattern.md`. This rationale document is the generic-pattern counterpart to those two narratives.

A concrete result: the largest single-route compiled size in V1 is `vault_liqwid` at ~13.4 KB (about 3 KB of headroom under the 16 KB ceiling). Aggregate validator bytecode across all routes is roughly 140 KB — would be impossible as a monolith. Per-transaction reference-script load is bounded by 4.9 KB (proxy) + the single active route — typically 18–25 KB per transaction, well-amortised by the per-transaction protocol fee schedule.

V1 also uses Withdraw-Zero as the substrate for **keeper authorisation**: the keeper's authority is enforced by a separate `keeper_stake_script` whose zero-withdraw is required in every keeper-authorised TX. That validator is a *consumer* of the Withdraw-Zero pattern (it uses the staking-validator entry point for a different purpose — gating an externally-controlled authority rather than carrying a slice of vault business logic). See `spec/keeper-auth.md` for the keeper-authorisation details; the pattern itself is the same.

---

## 7. Open Questions for Future CIP Work

If this pattern is ever proposed for CIP standardisation, the discussion should resolve:

1. **Conway-era ref-script fee curve interaction.** Reference-script fee on Cardano Conway is non-linear in cumulative referenced bytes. Withdraw-Zero protocols routinely reference 4–6 scripts per transaction. A CIP should document the fee-curve implications for typical Withdraw-Zero deployments.
2. **Stake-credential lifecycle.** The N × 2 ADA stake-deposit overhead and the route-deregistration path are operationally significant for medium-sized protocols. A CIP could standardise route lifecycle (registration, rotation, retirement) and provide reference deploy tooling.
3. **Aiken-side ergonomics.** A consistent code-generation macro / template for "compile N route validators with shared compile-time parameters and a single proxy hashing over the resulting hashes" would reduce boilerplate. Currently each protocol writes its own deploy script.
4. **Naming.** "Withdraw-Zero Forwarding" / "Staking Validator Delegation" / "Proxy-Plus-Routes Pattern" all appear in informal Cardano DeFi discussion. A CIP would canonicalise one.
5. **Composition with CIP-95** (web-wallet bridge for Conway delegation flows). Stake-script registration touches Conway delegation primitives. Whether a Withdraw-Zero protocol's deploy tooling should hook CIP-95 deserves discussion.

---

## 8. See Also

- `docs/articles/architecture/01-eutxo-vault-design-constraints.md` — narrative article on the four eUTXO constraints this pattern responds to
- `docs/articles/architecture/02-withdraw-zero-forwarding-pattern.md` — long-form narrative of the V1 instantiation, including a full Compound TX walk-through
- `docs/articles/architecture/03-seventeen-validators-four-cuts.md` — narrative on the four orthogonal cuts V1 uses to choose how many routes to split into
- `spec/architecture.md` §4 — V1 validator catalogue
- `spec/pattern-rationale-validator-identity-nft.md` — Pattern 1, frequently composed with this one for singleton enforcement
- `spec/pattern-rationale-registry-auth-nft.md` — Pattern 4, which uses both Withdraw-Zero (for the validators reading the Registry) and Identity NFT (for Registry singleton anchoring)
- `spec/keeper-auth.md` — V1's keeper-authorisation stake-script, a Withdraw-Zero consumer
- `docs/cip-readiness-posture.md` — the overall CIP posture
- `contracts/validators/vault_proxy.ak` — the reference proxy implementation

---

**Document status**: informational pattern rationale. Reflects V1 design as of launch readiness. Revisions will follow the conditions stated in `cip-readiness-posture.md` §4.
