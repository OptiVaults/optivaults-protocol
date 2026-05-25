# OptiVaults V1 — MultisigGov Validator Specification

*Implementation of the MultiSig Governance + Timelock Pattern (see [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md) for the generic pattern, trade-off discussion, and open CIP questions).*

**Scope**: the internal implementation details of the `multisig_gov` validator — action_id computation, GovDatum spend/transition rules, cross-validator authorization helpers, and the separation of concerns between this validator and `governance.md` (the public actions catalog).

This document is the implementation-level companion to `spec/governance.md`. If `governance.md` answers "what can governance do and when?", this document answers "how does the validator enforce those rules?".

---

## 1. Validator structure

`multisig_gov` is a **spending validator** (single-UTXO state machine) parameterized at compile time by:

```aiken
validator multisig_gov(
  governance_nft_policy: PolicyId,
  governance_nft_name: ByteArray,
) {
  spend(
    datum: Option<GovDatum>,
    redeemer: GovRedeemer,
    own_ref: OutputReference,
    tx: Transaction,
  ) { ... }
}
```

Deploy produces exactly one UTXO at this validator's address carrying the one-shot Governance NFT `(governance_nft_policy, governance_nft_name, 1)`. The NFT is minted exactly once, at deploy. Burning is not a normal operation (the Gov UTXO is permanent as long as V1 is live).

---

## 2. GovDatum schema (canonical)

```aiken
type GovDatum {
  // --- Signer state ---
  signers: List<VerificationKeyHash>,              // Current m-of-n set (3..20 entries)
  signer_joined_at_ms: List<Int>,                   // Parallel to signers; tenure start
  signer_last_qualified_ms: List<Int>,              // Parallel to signers; last qualifying TX
  threshold: Int,                                   // m (2..signer_count — unanimity allowed)

  // --- Timelocked action queue ---
  queued: List<QueuedAction>,                       // 0..10 pending actions

  // --- Signer compensation pool ---
  signer_compensation_pool: Int,                   // Lovelace (USDCx units) accumulated
  last_distribute_ms: Int,                          // Last DistributeSignerCompensation TX
  distribute_period_ms: Int,                        // 7_776_000_000 (90 days) quarterly

  // --- Anti-replay ---
  nonce: Int,                                       // Strictly monotonic
}

type QueuedAction {
  action_id: ByteArray,                             // 32-byte hash (see §4)
  action_kind: ActionKind,
  target_script: ByteArray,                         // Validator hash the action executes against
  target_tx_hash: ByteArray,                        // Empty (#"") or 32-byte pre-committed TX hash
  payload_hash: ByteArray,                          // Blake2b-256 of redeemer payload CBOR
  queued_at_ms: Int,
  executable_at_ms: Int,                            // queued_at + timelock_ms
  expires_at_ms: Int,                               // executable_at + ttl_ms
}

type ActionKind {
  UpdateStrategy                                    // §governance.md 4.1
  UpdateFee                                         // §4.2
  UpdateFeeSplit                                    // §4.3 (21d timelock)
  EmergencyWithdraw                                 // §4.4
  AdminDeployNonDeposit                             // §4.5
  UpdateRegistry                                    // §4.6
  FastUpdateMarkets                                 // §4.8 (1h timelock)
  UpdateKeeperAuth                                  // §4.9
  TreasurySpend                                     // §4.10
  UpdateTreasuryParams                              // §4.11
  RotateSigners                                     // §4.12
  SlashBond                                         // Phase 3+ only; confiscate keeper bond
  UpdateSlippagePolicy                              // §4.3.1 — on-chain slippage policy adjustment (48h timelock)
  ActDeregisterStake                                // §4.13 (A2) stake-credential deregister + 2 ADA deposit refund
}

type GovRedeemer {
  QueueAction { ... }
  CancelAction { action_id: ByteArray }
  ExecuteAction { action_id: ByteArray }
  RotateSignersRedeemer { new_signers: List<VerificationKeyHash>, new_threshold: Int }
  Heartbeat { signer: VerificationKeyHash }
  DistributeSignerCompensation { triggering_signer: VerificationKeyHash }
}
```

**List-parallel invariant**: `list.length(signers) == list.length(signer_joined_at_ms) == list.length(signer_last_qualified_ms)`. Every redeemer that mutates any of these three lists must preserve this invariant — breaking it would cause off-by-one reads and mis-allocate quarterly compensation.

---

## 3. Signer membership invariants

Enforced by every redeemer that mutates `signers`:

- `3 <= list.length(signers) <= 20` (min 3 for meaningful multi-sig with 1-of-n cancel; max 20 to cap datum size)
- `2 <= threshold <= list.length(signers)` (min 2 for genuine multi-sig; unanimity `threshold == n` explicitly **allowed**). Rationale: V1 launches with **3-of-3 (threshold = n = 3)** because the founder is also the keeper operator and sits on governance — unanimity forces the founder to convince BOTH other signers to pass any action, rather than just one. Post-audit Phase 2+ best practice is `threshold < n` so that at least one signer is always outside the passing quorum and can 1-of-n cancel — but this is an operational-policy convention, not a validator-enforced constraint.
- All `signers` entries distinct
- All `signer_joined_at_ms[i] > 0` (non-zero timestamp)
- All `signer_last_qualified_ms[i] >= 0` (0 means "never qualified since joining")

---

## 4. action_id computation

Every `QueuedAction.action_id` is a deterministic Blake2b-256 hash computed as:

```aiken
fn compute_action_id(
  action_kind: ActionKind,
  target_script: ByteArray,
  payload_hash: ByteArray,
  queued_at_ms: Int,
  nonce_at_queue: Int,
) -> ByteArray {
  let preimage = bytearray.concat([
    action_kind_byte(action_kind),        // 1 byte tag
    target_script,                         // 28 bytes
    payload_hash,                          // 32 bytes
    int_to_bytes_be(queued_at_ms, 8),     // 8 bytes big-endian
    int_to_bytes_be(nonce_at_queue, 8),   // 8 bytes big-endian
  ])
  blake2b_256(preimage)                    // 32 bytes
}
```

**Uniqueness property**: `nonce_at_queue` is strictly monotonic across the entire GovDatum lifetime, so two actions queued at the same `queued_at_ms` with identical `payload_hash` still produce distinct `action_id` values.

**Replay protection**: because `action_id` is part of `queued`, and `queued` entries are removed on `CancelAction` / `ExecuteAction`, the same `(action_kind, target_script, payload_hash)` tuple can be queued again after removal — but with a new `nonce_at_queue` and therefore a new `action_id`. Legitimate re-queuing is possible; double-execution of the same queue entry is not.

---

## 5. payload_hash computation

For each `ActionKind`, the payload is the redeemer that will be passed to the target validator at ExecuteAction time. The payload is CBOR-encoded and hashed:

```aiken
payload_hash = blake2b_256(cbor.serialise(payload))
```

Payload types per ActionKind (matches `governance.md` §4):

| ActionKind | Canonical payload tuple (must match `contracts/lib/vault/helpers.ak:payload_hash_*`) |
|------------|----------------------------------------------------------------------------|
| UpdateStrategy | `(new_allocations, new_buffer_target_bps)` |
| UpdateFee | `(new_performance_fee_bps, new_early_withdraw_fee_bps, new_min_hold_seconds)` |
| UpdateFeeSplit | `(new_keeper_fee_bps, new_gov_fee_bps)` |
| EmergencyWithdraw | `(loss_amount, freeze_flag)` — note: `loss_amount` is constrained to 0 by `vault_gov_emergency` per Layer 1 of the Phase 1 governance safety design (freeze-only). The field is preserved in payload-hash for backward compatibility with action_id derivation. See `governance.md` §4.4. |
| AdminDeployNonDeposit | `(deploy_amount, deploy_token_policy, deploy_token_name)` — `new_allocations` + `dest_output_idx` are operational choices, not pre-committed |
| UpdateRegistry | `<new_registry_datum>` (entire RegistryDatum value is the payload) |
| FastUpdateMarkets | `<new_registry_datum>` (entire RegistryDatum value) |
| UpdateKeeperAuth | `<new_keeper_auth_datum>` (entire KeeperAuthDatum value) |
| TreasurySpend | `(category_tag_byte, amount, recipient_address, audit_invoice_ref)` — category tag: `#"01"` audit / `#"02"` ops / `#"03"` rd / `#"04"` buffer |
| UpdateTreasuryParams | `(audit_bps, ops_bps, rd_bps, buffer_bps, cap_audit, cap_ops, cap_rd, cap_buffer)` |
| RotateSigners | `(new_signers, new_threshold)` |
| SlashBond | `(bond_owner, evidence_ref, slash_amount)` |
| UpdateSlippagePolicy | `(new_max_slippage_bps, new_min_swap_peg_bps)` — on-chain slippage policy adjustment for DeployToProtocol swap routing (48h timelock; bounded by `max_slippage_bps_cap = 500` and `min_swap_peg_bps ∈ [9_300, 9_950]`). See `spec/governance.md` §4.3.1. |
| ActDeregisterStake | `target_hash` — the stake validator's own 28-byte script hash. `payload_hash_deregister_stake(target_hash) = blake2b_256(cbor.serialise(target_hash))`. Redundant-looking (the action's `target_script` field also pins this) but preserves the uniform `payload_hash_*` pattern used across every other ActionKind and guards against off-chain tooling that builds a QueueAction where `target_script ≠ payload_hash_input`. Covered validators: `vault_protocol`, `vault_liqwid`, `vault_admin`, `keeper_stake_script`. **Not covered**: `vault_core` (publish handler omitted due to 16 KB ceiling — see governance.md §4.13). |

At ExecuteAction, the validator recomputes `payload_hash` from the actual redeemer passed to the target validator and compares to the queued `payload_hash`. Mismatch → reject.

---

## 6. Redeemer implementations

### 6.1 QueueAction

```aiken
QueueAction {
  action_kind: ActionKind,
  target_script: ByteArray,
  target_tx_hash: ByteArray,
  payload_hash: ByteArray,
  timelock_ms: Int,
  ttl_ms: Int,
}
```

**Validation**:
1. Gov UTXO is spent; continuing output is at the same validator address carrying the Governance NFT
2. `tx.extra_signatories` contains ≥ `threshold` members of `signers`
3. `timelock_ms >= min_timelock(action_kind)` (per governance.md §3 table):
   - UpdateStrategy: 7d
   - UpdateFee: 14d
   - **UpdateFeeSplit: 21d**
   - EmergencyWithdraw: 0
   - AdminDeployNonDeposit: 7d
   - UpdateRegistry: 14d
   - FastUpdateMarkets: 1h (3_600_000 ms)
   - UpdateKeeperAuth: 14d
   - TreasurySpend: 7d
   - UpdateTreasuryParams: 14d
   - RotateSigners: 14d
4. `86_400_000 <= ttl_ms <= 2_592_000_000` (1 day to 30 days)
5. `target_tx_hash` is either `#""` (empty, allowed for most actions) or exactly 32 bytes
6. `len(queued_old) + 1 <= 10` (DoS cap)
7. `payload_hash` is exactly 32 bytes
8. Continuing datum:
   - `signers, threshold, signer_joined_at_ms, signer_last_qualified_ms` unchanged (except `signer_last_qualified_ms[i]` updated for each signer whose signature appears on this TX — they "qualified" for this quarter)
   - `signer_compensation_pool, last_distribute_ms, distribute_period_ms` unchanged
   - `nonce = old.nonce + 1`
   - `queued = old.queued ++ [new_queued_action]` where:
     ```
     new_queued_action = QueuedAction {
       action_id: compute_action_id(action_kind, target_script, payload_hash, tx.validity_range.upper, old.nonce),
       action_kind, target_script, target_tx_hash, payload_hash,
       queued_at_ms: tx.validity_range.upper,
       executable_at_ms: tx.validity_range.upper + timelock_ms,
       expires_at_ms: tx.validity_range.upper + timelock_ms + ttl_ms,
     }
     ```

### 6.2 CancelAction

```aiken
CancelAction { action_id: ByteArray }
```

**Validation**:
1. Gov UTXO spent; continuing output at same address with Gov NFT
2. `tx.extra_signatories` contains **≥ 1** member of `signers` (1-of-n authorization)
3. `∃ i. old.queued[i].action_id == action_id` (target exists)
4. Continuing datum:
   - `queued = list.remove_at(old.queued, i)`
   - `signer_last_qualified_ms[j]` updated for each `signers[j]` who signed (they get qualification credit for canceling)
   - `nonce = old.nonce + 1`
   - All other fields unchanged

**Rationale for 1-of-n authorization**: this is the emergency brake. Any single signer — including one who voted against the original queue — can cancel. Requiring multi-sig to cancel would let the quorum queue malicious actions and block their own cancels.

### 6.3 ExecuteAction

```aiken
ExecuteAction { action_id: ByteArray }
```

**Validation**:
1. Gov UTXO spent; continuing output at same address with Gov NFT
2. `tx.extra_signatories` contains ≥ `threshold` members of `signers`
3. `∃ i. old.queued[i].action_id == action_id` (target exists)
4. Let `action = old.queued[i]`:
   - `tx.validity_range.lower >= action.executable_at_ms` (timelock elapsed)
   - `tx.validity_range.upper < action.expires_at_ms` (not expired)
   - If `action.target_tx_hash != #""`: `tx.id == action.target_tx_hash`
5. **Cross-validator binding**: the target validator's UTXO must also be consumed in this transaction. The target validator, reading its own redeemer, recomputes `blake2b_256(cbor.serialise(redeemer)) == action.payload_hash`. If mismatch, target rejects → whole TX fails.
6. **Target-side authorization check** (running on target validator): the target validator looks up the Gov UTXO as a spent input, reads the ExecuteAction redeemer, confirms `action.action_kind` matches what the target expected, and enforces `action.target_script == self.script_hash`.
7. Continuing datum:
   - `queued = list.remove_at(old.queued, i)`
   - `signer_last_qualified_ms[j]` updated for each signer who signed
   - `nonce = old.nonce + 1`
   - All other fields unchanged

### 6.4 RotateSignersRedeemer

This is the on-chain execution of a `RotateSigners` action that was previously QueueAction'd. Because `RotateSigners` mutates the signer list itself (a critical state change), it is its own redeemer rather than going through `ExecuteAction`. This ensures the signer rotation happens atomically with the datum transition.

```aiken
RotateSignersRedeemer {
  new_signers: List<VerificationKeyHash>,
  new_threshold: Int,
}
```

**Validation**:
1. Gov UTXO spent; continuing output at same address with Gov NFT
2. `tx.extra_signatories` contains ≥ `old.threshold` members of `old.signers`
3. A queued `RotateSigners` action exists with matching `payload_hash` (verifies this rotation was pre-approved):
   - `∃ i. old.queued[i].action_kind == RotateSigners`
   - `old.queued[i].payload_hash == blake2b_256(cbor.serialise((new_signers, new_threshold)))`
   - `tx.validity_range.lower >= old.queued[i].executable_at_ms`
   - `tx.validity_range.upper < old.queued[i].expires_at_ms`
4. New signer invariants (§3):
   - `3 <= list.length(new_signers) <= 20`
   - `2 <= new_threshold <= list.length(new_signers) - 1`
   - All `new_signers` distinct
5. Continuing datum:
   - `signers = new_signers`
   - `threshold = new_threshold`
   - `signer_joined_at_ms = [preserve_if_retained(s, i) for (s, i) in zip(new_signers, indices)]`:
     - For each `new_signers[i]` that equals some `old.signers[j]`: `signer_joined_at_ms[i] = old.signer_joined_at_ms[j]` (tenure preserved)
     - For each new addition: `signer_joined_at_ms[i] = tx.validity_range.lower`
   - `signer_last_qualified_ms` similarly preserves for retained signers; resets to 0 for new additions
   - `queued = list.remove_at(old.queued, i)` (the RotateSigners queue entry is consumed)
   - `signer_compensation_pool` unchanged (note: operator convention says to run DistributeSignerCompensation first if pool > 0, but this is not contract-enforced — see governance.md §2.4)
   - `nonce = old.nonce + 1`

### 6.5 Heartbeat

```aiken
Heartbeat { signer: VerificationKeyHash }
```

**Validation**:
1. Gov UTXO spent; continuing output at same address with Gov NFT
2. `tx.extra_signatories` contains `signer`
3. `∃ i. signers[i] == signer` (signer is current member)
4. `tx.validity_range.lower - old.signer_last_qualified_ms[i] >= 7_776_000_000` (90 days, 1 per quarter)
5. Continuing datum:
   - `signer_last_qualified_ms[i] = tx.validity_range.lower`
   - All other fields unchanged except `nonce = old.nonce + 1`

**Gas cost**: ~0.2 ADA network fee, paid by the signer. No treasury spend.

### 6.6 DistributeSignerCompensation

```aiken
DistributeSignerCompensation { triggering_signer: VerificationKeyHash }
```

**Validation**:
1. Gov UTXO spent; continuing output at same address with Gov NFT
2. `triggering_signer ∈ old.signers`; `tx.extra_signatories` contains `triggering_signer`
3. `tx.validity_range.lower - old.last_distribute_ms >= old.distribute_period_ms` (quarterly cadence, 90d)
4. `old.signer_compensation_pool > 0` (nothing to distribute)
5. **Qualification check** (per signer `i`):
   - `qualified[i] = (old.signer_joined_at_ms[i] <= old.last_distribute_ms) AND (old.signer_last_qualified_ms[i] >= old.last_distribute_ms)`
6. Let `qualified_signers = [(signers[i], i) for i in range if qualified[i]]`
7. Let `per_signer = old.signer_compensation_pool / max(len(qualified_signers), 1)`
8. Let `forfeit_total = old.signer_compensation_pool - (len(qualified_signers) * per_signer)`
9. **TX outputs**:
   - For each `(signer_pkh, _) ∈ qualified_signers`: one UTXO to `signer_pkh`'s payment address carrying exactly `per_signer` USDCx
   - **Forfeit output**: the Treasury UTXO is also spent in this TX, and its continuing output has `audit_reserve_balance += forfeit_total` (triggered by treasury's `ReceiveGovForfeit` redeemer — see `spec/treasury.md` §3.3)
10. Continuing gov datum:
    - `signer_compensation_pool = 0`
    - `last_distribute_ms = tx.validity_range.lower`
    - All other fields unchanged except `nonce = old.nonce + 1`

**Cross-validator atomicity**: if the Treasury UTXO's continuing output fails to absorb the forfeit correctly (wrong amount, wrong datum update), the treasury validator rejects → whole TX fails, gov datum unchanged.

**Zero-qualified edge case**: if `len(qualified_signers) == 0`, the entire pool forfeits to audit reserve. The distribute TX still runs (pool drained, timer advanced), but no signer receives USDCx. Expected to be rare; indicates governance-health concern warranting public discussion.

---

## 7. Cross-validator authorization helper

**Implemented** in `contracts/lib/vault/helpers.ak::is_gov_authorized` (added in the V1 internal audit fix). Every governance-gated redeemer in `vault_admin`, `registry`, `treasury`, and `keeper_stake_script` calls this helper. The canonical implementation:

```aiken
pub fn is_gov_authorized(
  tx: Transaction,
  governance_policy: ByteArray,
  governance_name: ByteArray,
  expected_action_kind: ActionKind,
  expected_payload_hash: ByteArray,
  own_script_hash: ByteArray,
) -> Bool {
  // 1. Find the MultisigGov UTXO via the Governance NFT
  let gov_input = list.find(tx.inputs, fn(i) {
    quantity_of(i.output.value, governance_policy, governance_name) == 1
  })
  // 2. Parse the GovDatum (InlineDatum + defensive type-check)
  // 3. Read the redeemer passed to multisig_gov (must be ExecuteAction)
  // 4. Find the queued action by action_id
  // 5. Verify:
  //    - action.action_kind == expected_action_kind
  //    - action.target_script == own_script_hash
  //    - action.payload_hash == expected_payload_hash
  // (timelock + TTL are enforced inside multisig_gov's own ExecuteAction spend path)
  ...
}
```

Callers precompute `expected_payload_hash` using one of the `payload_hash_*` helpers (also in `helpers.ak`) that match the canonical tuple layout above. Example — `vault_admin.UpdateFee`:

```aiken
let expected_payload_hash = payload_hash_update_fee(
  new_performance_fee_bps, new_early_withdraw_fee_bps, new_min_hold_seconds,
)
let governance_authorized = is_gov_authorized(
  tx,
  old_datum.governance_policy, old_datum.governance_name,
  ActUpdateFee,
  expected_payload_hash,
  own_admin_hash,  // from `expect Script(own_admin_hash) = account` in staking validator
)
```

**Off-chain obligation.** Whoever submits `QueueAction` must precompute the SAME payload hash off-chain using the same canonical tuple layout (`scripts/governance/opti-gov.ts` must mirror `payload_hash_*` byte-for-byte), otherwise execution will reject.

This closes a V1 internal-audit finding: prior V1 drafts only checked "GovNFT is in tx.inputs", which allowed m-of-n signers to queue a benign payload (public disclosure during timelock + 1-of-n cancel window) and execute a different payload in the same TX — bypassing the public-scrutiny defense entirely.

---

## 8. Size and optimization considerations

Estimated compiled script sizes (subject to actual Aiken compilation):

| Component | Size estimate |
|-----------|--------------|
| multisig_gov spend path | ~6-8 KB |
| All redeemer branches | ~2 KB per branch × 6 = ~12 KB |
| Total | ~14-16 KB (fits 16 KB Plutus V3 validator limit) |

Optimizations applied:
- `ActionKind` is a single-byte tag, not a full sum type in the action_id preimage
- `action_id` uses blake2b_256 (native primitive, cheaper than sha2_256 composed)
- Parallel lists (`signers`, `signer_joined_at_ms`, `signer_last_qualified_ms`) share indexing; single traversal processes all three

If the compiled size exceeds 16 KB, the fallback is to split `multisig_gov` into two validators (one for queue/cancel/execute, one for rotate/heartbeat/distribute) joined by a Withdraw-Zero pattern — similar to how `vault_core` / `vault_protocol` / `vault_liqwid` are split.

---

## 9. Testing surface

Critical test cases for `multisig_gov_test.ak` (V1 internal-audit regression set, scope in `docs/audit-scope.md`):

1. **QueueAction with `timelock_ms` below floor** → reject
2. **QueueAction when `queued` has 10 entries** → reject (DoS cap)
3. **CancelAction with 0 signatures** → reject
4. **CancelAction with 1 signature but signer not in `signers`** → reject
5. **CancelAction legitimate** → `queued` reduced by 1, nonce+1
6. **ExecuteAction before `executable_at_ms`** → reject
7. **ExecuteAction after `expires_at_ms`** → reject
8. **ExecuteAction with wrong `action_id`** → reject (not found)
9. **ExecuteAction with correct `action_id` but target validator mismatches** → target rejects (cross-validator test)
10. **ExecuteAction payload_hash mismatch** → target rejects
11. **RotateSigners with signer count < 3** → reject
12. **RotateSigners with threshold > signers** → reject (unanimity allowed; only threshold strictly greater than n is rejected)
13. **RotateSigners preserves existing signers' `signer_joined_at_ms`** → confirmed via datum diff
14. **Heartbeat within 90-day rate limit** → reject (too soon)
15. **Heartbeat as non-member** → reject
16. **DistributeSignerCompensation before `distribute_period_ms`** → reject
17. **DistributeSignerCompensation with `pool == 0`** → reject
18. **DistributeSignerCompensation with all signers disqualified** → pool fully forfeits to audit reserve
19. **DistributeSignerCompensation partial qualification** → correct per-signer + forfeit amounts
20. **nonce monotonicity violated** → reject (detected in every redeemer)

---

## 10. Pattern Extraction

The validator described in §1–§9 is V1's concrete instantiation of the **MultiSig Governance + Timelock Pattern**. The generic pattern is documented separately in [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md), which discusses trade-offs against alternatives, open CIP design questions, and the security argument that does not depend on V1's specific implementation choices. This section captures the boundary: which behaviour is *the pattern* (and therefore appears unchanged in any conforming implementation) versus which behaviour is *V1's operational policy on top of the pattern* (and therefore would change in a different deployment).

### 10.1 What V1 inherits from the generic pattern

All six mechanisms in [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md) §2 are enforced by `multisig_gov.ak` without modification:

| Mechanism | V1 enforcement point |
|---|---|
| m-of-n threshold signature | `count_signers_in_tx(tx, signers) >= threshold` checked on QueueAction + ExecuteAction + RotateSignersRedeemer |
| Per-action timelock | `executable_at_ms = queued_at_ms + timelock_ms` recorded at queue; ExecuteAction rejects until `tx.validity_range.lower_bound >= executable_at_ms` |
| 1-of-n cancel veto | CancelAction requires exactly one signer signature, not m-of-n |
| Strict-monotonic nonce → `action_id` | `GovDatum.nonce` increments by 1 per QueueAction; `action_id` derived from `(nonce, action_kind, target_script, target_tx_hash, payload_hash, queued_at_ms, executable_at_ms, expires_at_ms)` — see §4 |
| Payload-hash binding | `payload_hash` recorded at queue; downstream validators (`vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`, `registry`, `treasury`, `keeper_stake_script`) re-verify their actual payload's Blake2b-256 against this hash — see §5 + §7 |
| Post-timelock TTL ceiling | `expires_at_ms = executable_at_ms + ttl_ms` recorded at queue; ExecuteAction rejects past `expires_at_ms` |

Anyone reviewing or porting the pattern reads the generic rationale doc for these mechanisms' security reasoning; this V1 spec carries the concrete enforcement-point references.

### 10.2 V1-specific elaborations beyond the pattern

V1 adds three structural elaborations on top of the generic pattern. None is required by the pattern itself; each reflects an operational choice for the OptiVaults V1 deployment.

**(a) Per-action-kind timelock floors and ceilings.** The generic pattern allows the queue redeemer to specify any `timelock_ms` value. V1 hardcodes a per-action-kind floor + ceiling table inside the validator so that a queue with `timelock_ms = 0` cannot bypass the protection for a sensitive action. Concrete values appear in `spec/governance.md` §4 per action — for example UpdateFeeSplit is constrained to a 21-day floor (most depositor-sensitive), EmergencyWithdraw to 0 days exactly (the emergency path), FastUpdateMarkets to a 1-hour floor (Liqwid migration agility). A future CIP could either standardise this floor/ceiling table or leave it as deployment policy; V1 picks deployment policy.

**(b) Signer compensation pool + quarterly distribution.** `GovDatum` carries `signer_compensation_pool`, `last_distribute_ms`, `distribute_period_ms` (90 days) and supports `Heartbeat` + `DistributeSignerCompensation` redeemers — operational economics for the human signers monitoring the queue and signing legitimate actions. The pattern itself has no opinion on signer incentives; V1 embeds this layer because the OptiVaults deployment compensates signers from a slice of protocol fees. A different deployment could omit this layer entirely (smaller `GovDatum`, no Heartbeat / DistributeSignerCompensation redeemers, no quarterly distribution).

**(c) Empty-hash flexible target mode.** Each queued action records a `target_tx_hash: ByteArray`. The pattern allows `target_tx_hash` to be either a specific 32-byte commitment (pre-commits to one TX hash at the target) or empty (`#""` — permits execution against any TX hash at the target that matches the `payload_hash`). V1 supports both modes through the same redeemer. The trade-off and selection guidance live in `spec/governance.md`. A future CIP-track discussion is suggested in the rationale doc's §7 open questions.

### 10.3 Where this implementation departs from the pattern's recommendations

The generic pattern recommends `threshold < signer_count` so the 1-of-n veto asymmetry is structurally meaningful. V1's launch configuration is 3-of-3 (i.e., `threshold == signer_count`), which violates this recommendation. The trade-off is explicit in `whitepaper.md` §8.6: V1 launches with a small founder-trusted signer set where unanimous approval reflects the actual operating reality, and the protocol's intended Phase 2+ trajectory (whitepaper §10) broadens the signer set to where `threshold < signer_count` becomes meaningful. The current configuration is acknowledged as a structural launch-stage limitation, not the long-term governance posture.

### 10.4 Related pattern-rationale docs

- [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md) — the generic pattern (this validator's primary rationale)
- [`pattern-rationale-validator-identity-nft.md`](./pattern-rationale-validator-identity-nft.md) — the Governance NFT (one-shot mint anchor) that this validator depends on for canonical-UTXO authentication; see §3.2 of that doc for the V1 Governance NFT instantiation
- [`pattern-rationale-registry-auth-nft.md`](./pattern-rationale-registry-auth-nft.md) — the Registry validator's `UpdateRegistry` redeemer is one of the 14 ActionKinds gated by this pattern
- [`pattern-rationale-vault-datum-tiered.md`](./pattern-rationale-vault-datum-tiered.md) — VaultDatum Tier 2 (policy) mutation requires governance actions through this validator
- [`pattern-rationale-withdraw-zero-forwarding.md`](./pattern-rationale-withdraw-zero-forwarding.md) — vault-side governance redeemers (in `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`) are reached through the Withdraw-Zero pattern with their payload bound by `payload_hash` to the queue recorded here
- [`cip-readiness-posture.md`](../docs/cip-readiness-posture.md) — overall V1 stance on Cardano Improvement Proposals

---

## 11. See also

- `spec/governance.md` — public-facing actions catalog, timelock rules, signer lifecycle
- `spec/gov-nft.md` — Gov Signer NFT minted alongside signer rotations
- `spec/treasury.md` §3.3 — `ReceiveGovForfeit` redeemer cross-validator pair
- `spec/architecture.md` §4 validators table — multisig_gov's place in the 12-validator V1 stack (+3 aux NFT policies)
- `docs/audit-scope.md` §2.4 — multisig_gov is part of V1-specific internal-audit scope
- `docs/security-model.md` §3.2, §3.5 — governance-compromise threat model
