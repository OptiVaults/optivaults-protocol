# Pattern Rationale — MultiSig Governance + Timelock

**Status**: informational pattern rationale. Not a CIP, not a CIP draft. See `docs/cip-readiness-posture.md` for OptiVaults V1's overall position on Cardano Improvement Proposals.

**Scope**: a recurring pattern for protocol-policy governance combining (a) m-of-n threshold signature approval, (b) per-action timelock between approval and execution, (c) 1-of-n veto cancellation during the timelock window, (d) strict-monotonic nonce-bound action identifiers, (e) payload-hash binding so the queued action's effects cannot drift before execution, (f) post-timelock TTL ceilings so stale approvals do not linger. The pattern is generic; OptiVaults V1 instantiates it with 14 action kinds, documented as a case study in §6.

---

## 1. Problem

DeFi protocols that hold pooled depositor funds need an upgrade path. Some parameters must change over time — fee rates as market conditions shift, strategy allocations as opportunities appear and disappear, integration whitelists as DEX adapters are added or retired, signer membership as humans rotate in and out of the operating team. A protocol without an upgrade path is brittle.

But every upgrade path is also an attack surface. A single key controlling the upgrade is a single point of failure. A simple m-of-n multisig improves on the single-key shape but does not address two recurring failure modes:

- **Immediate execution.** When the m-of-n signatures land in the same transaction as the upgrade, depositors have no time to react. A compromised m-of-n quorum can drain a vault or replace a strategy with a malicious one before any monitoring detects the change.
- **Silent payload drift.** When the m-of-n signers approve "upgrade fee to 4%" in principle but the actual transaction carries the payload "upgrade fee to 40%", multisig signature schemes that sign a transaction hash rather than the parameter contents miss the discrepancy. Off-chain signing tools have repeatedly produced incidents of this shape in the multi-chain DeFi history.

A robust governance pattern must defend against (a) compromised key thresholds, (b) immediate execution, and (c) payload drift between approval and execution, while remaining simple enough that depositors can verify the protocol's governance rules without specialised tooling.

The MultiSig Governance + Timelock pattern is a structural response that composes six mechanisms — threshold, timelock, veto, nonce, payload-hash, TTL — to address each failure mode at the right point in the action's lifecycle.

---

## 2. The Pattern

The pattern uses a singleton governance state UTXO (anchored by an Identity NFT — see Pattern 1) and a three-phase lifecycle for every action:

```
Queue ──── timelock window ──── (Execute or Cancel) ──── TTL ceiling
   │              │                       │
   │              │                       │
   m-of-n         any-signer-can          m-of-n (Execute)
   approval +     1-of-n CANCEL           or
   payload                                no execution before TTL
   commitment                             ─→ action expires
```

### 2.1 m-of-n threshold signature

The governance UTXO carries a `signers: List<VerificationKeyHash>` field and a `threshold: Int` field. Every queue and execute transaction must be signed by at least `threshold` of the current `signers` set. Both fields are themselves mutable through a `RotateSigners` action kind — governance modifies its own composition through the same pattern it uses for everything else.

The threshold is chosen by the protocol; common choices are 2-of-3, 3-of-5, 4-of-7. Higher m provides more compromise-resistance at the cost of harder coordination on legitimate updates. The pattern does not pick m; it provides the substrate.

### 2.2 Per-action timelock

When an action is queued, the validator records `executable_at_ms = queued_at_ms + timelock_ms` in the queued action's datum entry. The execute path will refuse to run until the chain's current time has passed `executable_at_ms`. The timelock is chosen per action kind, baked into the queue redeemer, and bounded by per-action-kind floors and ceilings inside the validator (so a queue with `timelock_ms = 0` cannot bypass the protection for a sensitive action).

The timelock window's purpose is **detection time**. Off-chain monitoring scrapes the governance UTXO and surfaces every queued action to depositors. The window gives depositors time to act — exit the protocol, raise an alarm, prepare a contestation — before the action takes effect.

### 2.3 1-of-n cancel veto

During the timelock window, any single signer can cancel any queued action. The cancel path requires exactly one signature from `signers`, not m-of-n. This asymmetry is deliberate:

- **Offence is m-of-n.** Multiple signers must coordinate to push a change through.
- **Defence is 1-of-n.** Any single signer who notices a problem can stop the change unilaterally.

The threat model the asymmetry addresses: an attacker who has compromised m signers can queue malicious actions, but they cannot prevent the remaining n − m signers from cancelling. As long as at least one uncompromised signer is online and monitoring, the cancel path works.

### 2.4 Strict-monotonic nonce → action_id

The governance datum carries a `nonce: Int` that increments by exactly 1 on every action queued. Each queued action's `action_id` is computed as a hash over `(nonce, action_kind, target_script, target_tx_hash, payload_hash, queued_at_ms, executable_at_ms, expires_at_ms)`. The nonce ensures that:

- Two actions queued for the same effect at different times produce different `action_id`s.
- An attacker cannot replay a previously-cancelled action by re-queueing the identical parameters and reusing the old `action_id` (the new queue would compute a different nonce-derived `action_id`).
- The `action_id` is referenceable in subsequent transactions (the execute redeemer carries `action_id` to select which queued action it is executing).

### 2.5 Payload-hash binding

The queue redeemer commits to a `payload_hash: ByteArray` — a Blake2b-256 hash of the CBOR-serialised effect that the action will produce when executed. The hash is recorded in the queued action's datum entry. The execute path requires the actual effect transaction (the registry update CBOR, the fee parameter list, the strategy allocation map, ...) to hash to the same value.

Payload drift between queue and execute is therefore impossible: the queued action is bound by hash to its eventual effect. The signers approving a queue have committed to a specific concrete payload, not to an action kind in the abstract.

### 2.6 Post-timelock TTL ceiling

The queue redeemer also commits to a `ttl_ms` ceiling. The validator records `expires_at_ms = executable_at_ms + ttl_ms` in the queued action's datum entry. After `expires_at_ms`, the action can no longer be executed; queue authors can prune the entry with a cancel (the cancel path accepts expired actions as well).

The TTL ceiling prevents a stale-action attack: a queued action that was never executed for legitimate reasons (governance changed direction, signer rotation invalidated the original quorum) sits in the queue indefinitely otherwise, waiting for an opportunistic execution under different conditions than the signers originally evaluated.

---

## 3. Aiken Sketch

A minimal GovDatum + redeemer set:

```aiken
type ActionKind {
  UpdateFee
  UpdateStrategy
  RotateSigners
  // ... protocol-specific action kinds
}

type QueuedAction {
  action_id: ByteArray,
  action_kind: ActionKind,
  target_script: ByteArray,
  payload_hash: ByteArray,
  queued_at_ms: Int,
  executable_at_ms: Int,
  expires_at_ms: Int,
}

type GovDatum {
  signers: List<VerificationKeyHash>,
  threshold: Int,
  queued: List<QueuedAction>,
  nonce: Int,
}

type GovRedeemer {
  QueueAction {
    action_kind: ActionKind,
    target_script: ByteArray,
    payload_hash: ByteArray,
    timelock_ms: Int,
    ttl_ms: Int,
  }
  CancelAction { action_id: ByteArray }
  ExecuteAction { action_id: ByteArray }
  RotateSignersRedeemer { new_signers: List<VerificationKeyHash>, new_threshold: Int }
}

validator multisig_gov(gov_nft_policy: PolicyId, gov_nft_name: ByteArray) {
  spend(datum: Option<GovDatum>, redeemer: GovRedeemer, own_ref, tx) {
    expect Some(old) = datum
    expect Some(cont) = find_single_continuing(tx.outputs, own_script_hash)
    expect new: GovDatum = inline_datum_of(cont)

    // Gov NFT must be preserved on the continuing output
    expect nft_count(cont.value, gov_nft_policy, gov_nft_name) == 1

    when redeemer is {
      QueueAction { action_kind, target_script, payload_hash, timelock_ms, ttl_ms } -> {
        let signed = count_signers_in_tx(tx, old.signers) >= old.threshold
        let timelock_ok = timelock_floor(action_kind) <= timelock_ms
        let action_id = derive_action_id(old.nonce, action_kind, target_script,
                                          payload_hash, ...)
        let queued_entry = QueuedAction { action_id, ... }
        and {
          signed,
          timelock_ok,
          new.nonce == old.nonce + 1,
          new.queued == list.push(old.queued, queued_entry),
          new.signers == old.signers,
          new.threshold == old.threshold,
        }
      }
      CancelAction { action_id } -> {
        let one_signed = count_signers_in_tx(tx, old.signers) >= 1
        and {
          one_signed,
          new.queued == list.filter(old.queued, fn(a) { a.action_id != action_id }),
          // signers + threshold + nonce unchanged
        }
      }
      ExecuteAction { action_id } -> {
        expect Some(action) = list.find(old.queued, fn(a) { a.action_id == action_id })
        let signed = count_signers_in_tx(tx, old.signers) >= old.threshold
        let timelock_passed = tx_lower_bound(tx) >= action.executable_at_ms
        let not_expired = tx_lower_bound(tx) <= action.expires_at_ms
        let effect_matches = verify_effect_payload_hash(tx, action.target_script, action.payload_hash)
        and {
          signed,
          timelock_passed,
          not_expired,
          effect_matches,
          new.queued == list.filter(old.queued, fn(a) { a.action_id != action_id }),
        }
      }
      RotateSignersRedeemer { new_signers, new_threshold } -> {
        // RotateSigners runs ONLY via ExecuteAction with a queued RotateSigners
        // action; this redeemer is the destination-side effect. Verify the
        // queue entry exists, timelock passed, and the new_signers / threshold
        // bundle hashes match the queued payload_hash.
        ...
      }
    }
  }
}
```

The sketch shows the four redeemer paths plus the continuing-output NFT check that any consumer of Pattern 1 + Pattern 4 inherits. The `derive_action_id` function and the `verify_effect_payload_hash` function are protocol-specific; the pattern document treats them as required components without specifying their exact implementation.

---

## 4. Security Properties

### 4.1 Threshold security

An attacker controlling fewer than `threshold` signers cannot queue any action. The protocol's compromise-resistance is parameterised — increasing `threshold` strictly increases the number of distinct keys an attacker must control to make progress on offence.

### 4.2 Detectability via timelock

The chain provides a public record of every queued action between queue and execute. The timelock window is detection-time for off-chain monitoring. The pattern does not by itself enforce monitoring — that is an operational obligation on the protocol's depositors and ecosystem watchers — but the timelock makes monitoring possible.

A common attack pattern this defends against: governance-key compromise leading to immediate fund extraction. Even with the keys, an attacker must queue the extraction, wait the timelock, and execute. During the timelock, depositors withdraw or signers cancel. A protocol with `timelock_ms = 0` would have no such window.

### 4.3 1-of-n veto asymmetry

The cancel path's 1-of-n threshold inverts the offence-defence calculus: offence requires m compromised keys, defence requires 1 uncompromised key. For any reasonable m and n where `m ≤ n − 1`, the defence is structurally stronger than the offence. The asymmetry breaks when `m == n` (no uncompromised key would suffice to defend); the pattern document recommends `m < n` for that reason.

### 4.4 Replay resistance via strict-monotonic nonce

Re-queueing an action with identical parameters produces a different `action_id` (the nonce has incremented). An attacker cannot pre-compute a hash chain of actions, swap one out, and re-insert it under the same identifier.

### 4.5 Payload immutability between Queue and Execute

The execute path verifies the actual effect transaction's payload hashes to the value recorded at queue time. Drift is structurally impossible; any divergence rejects the execute transaction. Signers approving a queue have committed to the concrete payload, not the abstract action kind.

### 4.6 TTL ceiling against stale actions

Actions whose timelock has passed but which have not been executed eventually expire. The TTL ceiling prevents indefinite-pending entries from becoming opportunistic-execution surfaces months after the originally-evaluated conditions have changed.

### 4.7 Self-modification through the same path

`RotateSigners` is just another action kind, subject to the same threshold + timelock + payload-hash + TTL + cancel rules as any other action. There is no separate "meta" governance path. Governance changing its own composition is the same plumbing as governance changing a fee parameter; one less validator surface for bugs.

This property — *self-modification is not a special case* — is one of the pattern's structural cleanliness wins. Some heritage governance designs have separate "owner-only" paths for changing the owner set, which introduces a privileged surface that escapes the threshold + timelock guarantees.

---

## 5. Trade-offs vs Alternatives

| Approach | Compromise resistance | Detection time | Payload integrity | Self-modification |
|---|---|---|---|---|
| Single owner key | None beyond key holder | None | Implicit | Owner replaces owner |
| Plain m-of-n (immediate execute) | m-of-n | None | Depends on signing tool | Often a separate owner path |
| Token-weighted DAO voting | Token-supply-dependent | Proposal voting period | Payload commitment varies | Same path |
| **m-of-n + timelock + veto + nonce + payload-hash + TTL (this pattern)** | m-of-n on offence, 1-of-n on defence | Full timelock window | Cryptographically bound | Same path as any other action |
| CIP-1694-style on-chain DAO governance | Cardano-treasury-aware, parameterised | Per-action governance period | Within ledger framework | Constitution-bound |

The trade made by the pattern: accept the operational overhead of queue+wait+execute (vs single-TX execute) in exchange for a fully on-chain audit trail with cryptographic payload binding and a structurally asymmetric defence. For protocols holding pooled funds where any single misstep produces measurable depositor loss, the trade is heavily favourable.

The pattern is **complementary** to CIP-1694-style ecosystem governance, not in tension. CIP-1694 governs Cardano-ledger-level parameters (treasury, hard-fork-initiator); this pattern governs application-level protocol parameters (fee schedule, strategy allocations, whitelist content). Both can co-exist in a single deployment.

---

## 6. OptiVaults V1 Case Study

V1's MultisigGov validator is at `contracts/validators/multisig_gov.ak`, anchored by the Governance NFT (one of three Pattern-1 instantiations). The implementation is ~890 lines of Aiken and carries the following parameters:

| Component | V1 instantiation |
|---|---|
| Signer count | 3 at launch; capped at 20 (`max_signers`); `threshold ≥ 2` enforced; signer rotation through `RotateSigners` action |
| Threshold default | 3-of-3 at launch; intended to broaden over Phase 2+ community governance transition |
| Action kinds | 14 distinct kinds: `UpdateStrategy`, `UpdateFee`, `UpdateFeeSplit` (21-day timelock), `UpdateSlippagePolicy` (48-hour timelock), `EmergencyWithdraw` (0-day timelock with extra guards), `AdminDeployNonDeposit`, `UpdateRegistry`, `FastUpdateMarkets` (1-hour timelock), `UpdateKeeperAuth`, `TreasurySpend`, `UpdateTreasuryParams`, `RotateSigners`, `SlashBond` (Phase 3+), `ActDeregisterStake` (stake-credential cleanup) |
| Default timelock | 14 days for the broad action kinds; shortened for the operationally-time-sensitive ones (1-hour FastUpdateMarkets, 0-day EmergencyWithdraw) and lengthened for the most sensitive (21-day UpdateFeeSplit) |
| Queue capacity | 0..10 pending actions at any time |
| Signer-compensation pool | An additional GovDatum field tracking accumulated USDCx earmarked for signer compensation, distributed quarterly via a `DistributeSignerCompensation` keeper-callable path — see `spec/multisig-gov.md` §6 |
| Empty-hash flexible target mode | An action can be queued with `target_tx_hash = #""` (empty), permitting execution against any TX hash at the target script that matches the payload; vs a specific 32-byte target_tx_hash that pre-commits to one particular UTXO. See `spec/governance.md` for the trade-off discussion |
| Self-modification | `RotateSigners` is a normal `ActionKind` — same threshold + timelock + cancel rules as any other action |
| Replay anti-pattern resistance | `nonce` strictly monotonic, increments on queue. `action_id` = Blake2b-256 over the queue parameters + nonce |
| Payload-hash binding | Every action records the Blake2b-256 of the destination-side redeemer's CBOR-serialised payload; execute paths in `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`, `registry`, `treasury`, `keeper_stake_script` all verify the actual payload hashes to the queued value |

Two V1-specific elaborations the pattern document treats as project-policy (not protocol primitives):

- **Per-action-kind timelock floors and ceilings.** V1 hardcodes per-kind minimum + maximum timelocks (e.g., UpdateStrategy must be 7–30 days; UpdateFeeSplit must be ≥ 21 days; EmergencyWithdraw must be exactly 0 days). This prevents the queue from bypassing the protection by specifying `timelock_ms = 0` for a sensitive action. A future CIP might standardise the floor/ceiling list per action kind, or leave it project-policy.
- **Signer compensation pool + quarterly distribution.** V1 includes an operational economics layer — signers are compensated for the operational burden of monitoring + signing. The pool accrues from protocol fees and is distributed every 90 days via a non-governance path (`DistributeSignerCompensation`) callable by any signer with a 30-minute grace window. This is V1-instance-specific; the pattern document does not require it.

V1's audit history (Coverage area C — V1 Integration Flows; see `docs/audit-scope.md`) covered each of the six pattern mechanisms separately and verified the cross-validator payload-hash check at every governance-authorised consumer.

---

## 7. Open Questions for Future CIP Work

If this pattern is ever proposed for CIP standardisation, the discussion should resolve:

1. **Action-kind timelock floor table.** Should the per-action-kind minimum timelock be on-chain protocol-level (locked by CIP) or off-chain project-policy (each deployment picks)? V1 hardcodes its own table; a CIP might standardise.
2. **Empty-hash vs pre-committed target.** The pattern admits both modes. A CIP should articulate the trade-off and recommend a default.
3. **Signer rotation through governance vs separate path.** V1 routes `RotateSigners` through the same path as everything else. Some heritage designs have a separate owner-rotation path. The CIP should pick a default and justify.
4. **Signer compensation.** The compensation-pool field is V1-instance-policy; a CIP could either standardise it or leave it as out-of-scope operational concern.
5. **Composition with CIP-1694.** Where does application-level governance (this pattern) end and Cardano-ledger-level governance (CIP-1694) begin? The two should compose cleanly; a CIP could document the composition rules.
6. **Naming.** "MultisigGov" / "MultiSig Governance with Timelock" / "Queue-Execute-Cancel Pattern" all appear in informal Cardano DeFi discussion. A CIP would canonicalise.

---

## 8. See Also

- `contracts/validators/multisig_gov.ak` — reference implementation
- `contracts/validators/governance_nft.ak` — Pattern 1 instantiation #2 (Governance NFT)
- `contracts/lib/vault/types.ak` `GovDatum` / `QueuedAction` / `ActionKind` / `GovRedeemer` — V1's datum + redeemer shapes
- `spec/multisig-gov.md` — V1's implementation specification (~440 lines, deeper than this rationale)
- `spec/governance.md` — V1's public actions catalogue (each action kind's purpose + timelock + payload shape)
- `spec/pattern-rationale-validator-identity-nft.md` — Pattern 1, the Gov NFT anchoring substrate
- `spec/pattern-rationale-withdraw-zero-forwarding.md` — Pattern 3; V1's gov-authorised redeemers are routed through Withdraw-Zero into `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`
- `spec/pattern-rationale-registry-auth-nft.md` — Pattern 4; the Registry's `UpdateRegistry` redeemer is one of the 14 ActionKinds gated by this pattern
- `docs/cip-readiness-posture.md` — the overall CIP posture

---

**Document status**: informational pattern rationale. Reflects V1 design as of launch readiness. Revisions will follow the conditions stated in `cip-readiness-posture.md` §4.
