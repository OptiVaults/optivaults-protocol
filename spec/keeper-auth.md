# OptiVaults V1 — Keeper Authorization Specification

**Scope**: the `keeper_stake_script` staking validator that authorizes all keeper-executed redeemers in the V1 vault contracts.

---

## 1. Purpose

OptiVaults V1 needs a way to authorize keeper actions that can evolve over time — starting as "only the specific wallets the protocol operator whitelisted" and potentially becoming "anyone posting a bond" — **without changing the vault contracts**. The `keeper_stake_script` provides this layer by encoding authorization rules in a Cardano staking validator that the vault contracts query via zero-withdraw checks.

The vault contracts (`vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`) do not encode keeper identity directly. Each keeper redeemer in those contracts includes a single check:

```aiken
expect list.any(tx.withdrawals, fn((cred, _amt)) ->
  cred == Inline(Script(keeper_stake_script_hash))
)
```

This check says "this transaction includes a zero-withdrawal entry whose stake credential resolves to the keeper_stake_script hash". The credential withdrawal triggers the staking validator's redeemer, which in turn enforces whatever authorization policy is currently active. As the policy evolves under governance control, the vault contracts remain unchanged.

---

## 2. KeeperAuthDatum

```aiken
type RegistrationMode {
  GovernanceOnly           // Only PKHs in authorized_pkhs can act as keepers
  Mixed                    // authorized_pkhs OR bond-posters
  PermissionlessWithBond   // Anyone who has an active bond
}

type KeeperBond {
  bond_owner: VerificationKeyHash,
  bond_amount: Int,            // Lovelace locked; slashable on governance-proven misbehavior
  posted_at: Int,              // POSIX ms
  withdrawal_requested_at: Option<Int>,  // Set by bond-owner to initiate withdrawal; 30-day cooldown before refund
}

type KeeperAuthDatum {
  registration_mode: RegistrationMode,
  authorized_pkhs: List<VerificationKeyHash>,   // Governance-curated keeper list (ordered; rotation basis)
  active_bonds: List<KeeperBond>,                // Permissionless-registered keepers with bonds
  bond_amount_required: Int,                     // Minimum bond in lovelace (e.g., 100_000_000 = 100 ADA)
  last_config_update_time: Int,                  // Governance UpdateKeeperAuth cooldown
  cooldown_ms: Int,                              // Minimum ms between same-PKH withdrawals (anti-spam)
  max_authorized_count: Int,                     // Upper bound on authorized_pkhs length

  // --- Weekly rotation fields (Phase 2+ multi-keeper coordination) ---
  rotation_epoch_start_ms: Int,                  // POSIX ms anchor for rotation arithmetic
  rotation_period_ms: Int,                       // 604_800_000 = 7 days
  failover_window_ms: Int,                       // 1_800_000 = 30 minutes
  last_successful_tx_at: Int,                    // Updated by every WithdrawAsAuthorized TX
  nonce: Int,                                    // Strict-monotonic anti-replay counter

  // --- Compile-time governance anchors ---
  governance_policy: ByteArray,                  // GovNFT policy (immutable anchor for governance actions)
  governance_name: ByteArray,
}
```

**Fields by mutability**:

- **Immutable after deploy**: `governance_policy`, `governance_name`
- **Governance-mutable via UpdateKeeperAuth action (14-day timelock)**: `registration_mode`, `authorized_pkhs`, `bond_amount_required`, `cooldown_ms`, `max_authorized_count`, `rotation_period_ms`, `failover_window_ms`, `last_config_update_time`
- **Re-anchored on allowlist change**: `rotation_epoch_start_ms` (set to `tx.validity_range.lower` when `authorized_pkhs` or `active_bonds` mutates)
- **Mutable via bond-posting / bond-withdrawal redeemers**: `active_bonds`
- **Mutable on every keeper TX**: `last_successful_tx_at`, `nonce`

---

## 3. Redeemers

### 3.1 `WithdrawAsAuthorized` — keeper executes a vault operation

Triggered when a keeper wishes to execute one of the keeper-authorized vault redeemers. The vault redeemer will fail unless the transaction includes a zero-withdrawal against `keeper_stake_script`; this redeemer authorizes that withdrawal.

**Keeper-authorized redeemer set (all routed through this gate).** Per-validator redeemer homes:
- `vault_keeper_hot.Compound` — productive + zero-yield heartbeat
- `vault_keeper_hot.RebalanceBuffer` — allocation-only idle-buffer rebalance
- `vault_batcher.BatchProcess` — fill queued deposit / withdraw orders
- `vault_swap_ada.SwapAda` — closed-loop vault-ADA replenishment via keeper↔vault oracle barter (see `spec/ada-swap.md`)
- `vault_protocol.DeployToProtocol` — submit DEX swap via SwapAdapter dispatch (bounded ADA spend)
- `vault_recall.RecallFromProtocol` — cancel / collect pending DEX order
- `vault_recall.MergeUtxo` — consolidate vault + NoDatum UTxOs
- `vault_admin_deploy.AdminDeployNonDeposit` — swap stranded non-deposit tokens to USDCx (gov-gated with 7d keeper-inactive + 21d registry-stable preconditions, NOT a routine keeper redeemer but still routed through the keeper_stake_script gate when the keeper is active)
- `vault_liqwid.SupplyToLiqwid` — deploy buffer → qToken
- `vault_liqwid.RecallFromLiqwid` — redeem qToken → buffer

Each of the above vault redeemers requires both the `tx.extra_signatories` keeper signature **and** the `keeper_stake_script` zero-withdraw (dual-check). Governance-only redeemers (UpdateStrategy, UpdateFee, UpdateFeeSplit, UpdateRegistry, TreasurySpend, UpdateKeeperAuth, RotateSigners, EmergencyWithdraw, UpdateOracleSource) bypass this gate — they authorize via `multisig_gov` m-of-n signatures instead.

After 7 days of keeper inactivity (measured by `last_compound_time`), governance gains the right to step in for the keeper-authorized redeemers listed above via the `require_keeper_or_governance_fallback` pattern in the vault validators; governance then signs the TX using GovNFT spend, and this `WithdrawAsAuthorized` redeemer is not invoked (the vault validator follows its gov-fallback branch instead).

```aiken
WithdrawAsAuthorized { keeper_pkh: VerificationKeyHash }
```

**V1 uses the "A-Plain" variant of authorization — every keeper TX must spend the single keeper_auth UTXO, producing a continuing output with `last_successful_tx_at` bumped to `tx.validity_range.lower` and `nonce` incremented by 1.** This binds every keeper action atomically to authorization state and avoids reference-input races.

**Validation**:

- `tx.extra_signatories` must contain `keeper_pkh` (the keeper actually signed)
- `keeper_pkh` must appear in the active keeper set (see authorization paths below)
- Zero-withdrawal constraint: the `tx.withdrawals` entry against this stake credential must be for `0` lovelace (so no accidental / adversarial stake-rewards drain)
- The single keeper_auth UTXO must appear both as an input and as a continuing output at this stake-script's spend address
- Continuing output datum must satisfy:
  - `new_datum.last_successful_tx_at == tx.validity_range.lower`
  - `new_datum.nonce == old_datum.nonce + 1`
  - All other fields bit-identical to input
- **Primary / failover check** (§4 below) must hold

**Authorization paths by `registration_mode`**:

- Mode `GovernanceOnly`: `keeper_pkh ∈ authorized_pkhs`
- Mode `Mixed`: `keeper_pkh ∈ authorized_pkhs` OR `∃ bond ∈ active_bonds. bond.bond_owner == keeper_pkh && bond.withdrawal_requested_at == None`
- Mode `PermissionlessWithBond`: `∃ bond ∈ active_bonds. bond.bond_owner == keeper_pkh && bond.withdrawal_requested_at == None`

**Primary / failover gate** (enforced whenever the active keeper set has ≥ 2 members):

- If `keeper_pkh == current_primary_pkh(auth, tx.validity_range.lower)` → primary path, allow
- Else (`keeper_pkh` is a valid non-primary keeper) → failover path, require `tx.validity_range.lower - old_datum.last_successful_tx_at >= failover_window_ms`

When the active set has exactly 1 member (V1 launch), `current_primary_pkh` always returns that single PKH and the failover gate is not exercised. The single founder keeper can submit TXs with no additional constraint.

**Anti-spam cooldown**: the on-chain `last_successful_tx_at` update means any same-PKH spam within `cooldown_ms` is naturally capped by TX timing; an explicit `cooldown_ms` check is only enforced when the validator sees a same-PKH TX attempted within that window — for V1 launch, `cooldown_ms = 60_000` (1 minute), well within normal keeper operating rhythm.

### 3.2 `PostBond` — third party registers as keeper via bond

Available only in modes `Mixed` and `PermissionlessWithBond`.

```aiken
PostBond { bond_owner: VerificationKeyHash }
```

**Validation**:
- `registration_mode != GovernanceOnly`
- `tx.extra_signatories` contains `bond_owner`
- Transaction locks exactly `bond_amount_required` lovelace into a dedicated bond output (either the stake-script address itself or a governance-parameterized bond-holding address)
- New `KeeperAuthDatum.active_bonds` contains an entry with:
  - `bond_owner == bond_owner` (from redeemer)
  - `bond_amount == bond_amount_required`
  - `posted_at == tx.validity_range.upper`
  - `withdrawal_requested_at == None`
- Existing `active_bonds` entries preserved
- All other KeeperAuthDatum fields unchanged
- No duplicate bonds: `bond_owner ∉ (active_bonds.map(bond_owner))` before this action

### 3.3 `RequestBondWithdrawal` — bond-owner initiates unstake

```aiken
RequestBondWithdrawal { bond_owner: VerificationKeyHash }
```

**Validation**:
- `tx.extra_signatories` contains `bond_owner`
- The matching `active_bonds` entry has `withdrawal_requested_at == None`
- New datum: the matching entry's `withdrawal_requested_at` set to `tx.validity_range.upper`
- All other fields unchanged
- **Effect**: the bond's authorization as a keeper ceases immediately (per `WithdrawAsAuthorized` check: `withdrawal_requested_at == None`). A 30-day cooldown then applies before the bond can be withdrawn.

### 3.4 `WithdrawBond` — refund bond after cooldown

```aiken
WithdrawBond { bond_owner: VerificationKeyHash }
```

**Validation**:
- `tx.extra_signatories` contains `bond_owner`
- The matching `active_bonds` entry has `withdrawal_requested_at == Some(t)`
- `tx.validity_range.lower - t >= 30 * 86_400 * 1000` (30-day cooldown elapsed)
- The refund output pays exactly the bond's `bond_amount` lovelace to the bond_owner's address
- The continuing `keeper_auth` output retains at least `own_input.lovelace - bond_amount` lovelace and preserves any remaining `active_bonds` lovelace that backs other bonds (i.e., the sum of remaining `active_bonds.bond_amount` values is covered by the continuing UTXO's lovelace balance)
- New datum: entry removed from `active_bonds`
- All other fields unchanged

**Implementation note — bond-backing UTXO invariant.** The `keeper_auth` UTXO must carry physical lovelace ≥ `Σ active_bonds.bond_amount + min_utxo`. When a keeper posts a bond (`PostBond` redeemer), the TX adds the bond's lovelace to the `keeper_auth` UTXO's balance alongside the datum update. `WithdrawBond` correspondingly subtracts the bond's lovelace on refund. Operators managing the `keeper_auth` UTXO must ensure it is never split or have lovelace extracted by any path other than `WithdrawBond` / `SlashBond`, or bond-refund invariant will fail and a keeper's bond becomes un-withdrawable. This is enforced at the validator layer by the continuing-lovelace check above; violating TXs are rejected.

### 3.5 `UpdateAuthDatum` — governance adjusts authorization rules

Triggered by a MultisigGov `ExecuteAction` matching a queued `UpdateKeeperAuth` proposal.

```aiken
UpdateAuthDatum {
  new_datum: KeeperAuthDatum,
}
```

**Validation**:
- Transaction contains a spent input from the `MultisigGov` validator carrying the Governance NFT
- `tx.validity_range.lower - old_datum.last_config_update_time >= 86_400_000` (minimum 24-hour cooldown between governance updates)
- **Immutable-field preservation**: `new_datum.governance_policy == old.governance_policy`, `new_datum.governance_name == old.governance_name`
- `len(new_datum.authorized_pkhs) <= new_datum.max_authorized_count`
- `new_datum.max_authorized_count <= 20` (hard ceiling on authorized keeper count)
- `new_datum.bond_amount_required >= 50_000_000` (minimum 50 ADA bond required; prevents bond-amount being zeroed)
- `new_datum.cooldown_ms in [60_000, 86_400_000]` (between 1 minute and 24 hours)
- `new_datum.rotation_period_ms in [86_400_000, 2_592_000_000]` (between 1 day and 30 days)
- `new_datum.failover_window_ms in [600_000, 7_200_000]` (between 10 minutes and 2 hours)
- `new_datum.active_bonds == old_datum.active_bonds` (governance cannot directly manipulate bonds — only create/remove via the bond redeemers)
- `new_datum.last_config_update_time == tx.validity_range.upper`
- `new_datum.nonce == old_datum.nonce + 1`
- **Rotation re-anchor rule**: if `new_datum.authorized_pkhs != old_datum.authorized_pkhs` OR mode change from any to/from `PermissionlessWithBond` (where active set composition could shift meaningfully), then `new_datum.rotation_epoch_start_ms == tx.validity_range.lower`. Otherwise `new_datum.rotation_epoch_start_ms == old_datum.rotation_epoch_start_ms`.
- All value preserved: stake-script UTXO output must carry the same (or greater) ADA as input
- **No downgrade of existing bonds**: if mode changes from `PermissionlessWithBond` to `GovernanceOnly`, existing bonded keepers remain authorized until they voluntarily `RequestBondWithdrawal` (their authorization is tied to the bond entry, not the mode). This prevents governance from unilaterally "deauthorizing all bonded keepers" without refunding their bonds.

### 3.6 `SlashBond` — governance slashes a misbehaving keeper's bond

> **Not reachable at V1 launch.** V1 ships with `RegistrationMode = GovernanceOnly`; no bonded keepers exist, so `active_bonds` is empty and no `SlashBond` TX can validate. Governance actions of kind `SlashKeeper` are defined in the MultisigGov action catalog (`governance.md` §4) for forward-compatibility but will be rejected by the MultisigGov `ExecuteAction` validator at execute time if attempted against an empty bond set. This section specifies the redeemer's shape for Phase 3+ readiness; do not assume slashing is available in V1.

Triggered (Phase 3+) by a MultisigGov `ExecuteAction` matching a queued `SlashKeeper` proposal. Intended for provable misbehavior (e.g., keeper routing swaps to attacker-controlled address despite registry whitelist — which the registry check would block on-chain, but if somehow a keeper griefs the protocol in a way not directly caught by vault validators, this is the recovery mechanism).

```aiken
SlashBond {
  bond_owner: VerificationKeyHash,
  evidence_ref: ByteArray,    // On-chain TX hash of the misbehavior evidence
  slash_amount: Int,          // Usually the full bond amount
}
```

**Validation**:
- MultisigGov governance input
- Matching `active_bonds` entry exists
- `slash_amount <= bond.bond_amount`
- Slashed lovelace flows to the treasury UTXO (not to governance signers; prevents perverse incentive)
- Entry removed from `active_bonds` (bond forfeit)
- `evidence_ref` logged in a slashing history record (new field in KeeperAuthDatum if needed, or in treasury's spend log)
- 14-day timelock on the SlashKeeper governance action (longer than standard 7-day, reflecting the adversarial nature of the claim)
- **Affected party's recourse**: 14-day timelock window allows the accused keeper to publicly respond; governance signers can CancelAction if evidence is weak.

Slashing is deliberately NOT available in V1 launch — V1 ships with mode = `GovernanceOnly` where keepers are manually curated and slashing is overkill (governance can simply remove them from `authorized_pkhs` via UpdateAuthDatum). The `SlashBond` redeemer is specified here for future modes where bonded permissionless keepers exist and slashing becomes the accountability mechanism.

---

## 4. Primary Rotation Mechanism (Multi-Keeper Coordination)

When the active keeper set has ≥ 2 members (Phase 2+), V1 implements **weekly round-robin rotation** to distribute keeper fee income fairly across all authorized keepers.

### 4.1 Core idea

- All authorized keepers take turns as "primary" for one full week at a time
- The primary may execute any vault redeemer at any time (`min_wait = 0`)
- Non-primary keepers stand by; they may execute only if the primary has been silent for `failover_window_ms` (30 min default)
- Over N rotation cycles, each keeper is primary ~1/N of the time and thus earns ~1/N of accumulated keeper fees

At V1 launch with 1 keeper, the "rotation" has period 1 and the single keeper is always primary — no actual rotation occurs.

### 4.2 Rotation formula (pure time-derived)

No explicit rotation trigger TX is required — rotation advances automatically with wall-clock time:

```aiken
fn active_keeper_set(auth: KeeperAuthDatum) -> List<VerificationKeyHash> {
  // In GovernanceOnly: the authorized_pkhs list
  // In Mixed: authorized_pkhs ++ active_bonds (excluding those with withdrawal_requested_at == Some)
  // In PermissionlessWithBond: active bonds only
  // Order-preserved; this is the rotation cycle
  build_active_set(auth)
}

fn current_primary_pkh(auth: KeeperAuthDatum, now_ms: Int) -> VerificationKeyHash {
  let set = active_keeper_set(auth)
  expect list.length(set) > 0
  let elapsed = now_ms - auth.rotation_epoch_start_ms
  let slot = elapsed / auth.rotation_period_ms
  let index = slot % list.length(set)
  list.at(set, index)
}
```

`now_ms` is taken from `tx.validity_range.lower`. Validity-range width cap (inherited from the vault redeemers' time-bounded windows) ensures `now_ms` cannot be manipulated to change the computed primary beyond the legitimate window.

### 4.3 Failover path

When the primary is offline, non-primary keepers can step in after 30 minutes of silence:

- Non-primary signer submits a TX with redeemer `WithdrawAsAuthorized`
- Validator reads `last_successful_tx_at` from the keeper_auth input datum
- Requires `tx.validity_range.lower - last_successful_tx_at >= failover_window_ms` (30 min)
- On success, `last_successful_tx_at` is updated → primary must also wait 30 min before reclaiming (creates natural handoff cadence)

If the primary returns within its own week, it may immediately resume the primary path (no wait — primary signer is always allowed). Only non-primary signers face the failover gate.

### 4.4 Re-anchor on authorized-set change

Whenever `authorized_pkhs` changes via `UpdateAuthDatum`, or when an active bond is created/withdrawn that materially alters the active keeper set, `rotation_epoch_start_ms` is reset to the current time. The rotation restarts from index 0 of the new active set.

Trade-off: a currently-serving primary's week may be cut short when a new keeper is added. This is mitigated by:
- `UpdateAuthDatum` has a 14-day governance timelock (outgoing primary can see the change coming and plan handoff)
- Bond `PostBond` adds to the set but does not re-anchor mid-rotation (the rotation picks up the new bonded keeper from next slot boundary — less disruptive than a governance add)

### 4.5 Fee distribution

100% of the keeper fee output goes to the signing keeper's PKH. There is no retainer for non-primary keepers; they earn nothing during weeks they are not primary (except the occasional failover TX fee when they step in during an outage).

Over multiple rotation cycles, income averages to approximately `1/N × total_keeper_fee` per keeper where N is the active set size. Keepers who experience more failover events (due to unreliable fellow-keepers) earn somewhat more than their rotation share; keepers who are unreliable themselves earn less.

### 4.6 Example: 3-keeper rotation at Phase 2

Configuration:
- `authorized_pkhs = [founder_pkh, ally_A_pkh, ally_B_pkh]` (3 keepers, governance-curated)
- `rotation_period_ms = 604_800_000` (7 days)
- `failover_window_ms = 1_800_000` (30 min)

Rotation cycle:

| Week | Primary | Secondary | Tertiary |
|------|---------|-----------|----------|
| 1 | founder | ally_A | ally_B |
| 2 | ally_A | ally_B | founder |
| 3 | ally_B | founder | ally_A |
| 4 | founder | ally_A | ally_B |

Each keeper is primary for 1 out of every 3 weeks, earning approximately 1/3 of that period's keeper-fee total.

### 4.7 Bond-weighted rotation (Phase 3+)

When `registration_mode` is `Mixed` or `PermissionlessWithBond` and at least one bonded keeper exists, `current_primary_pkh` switches from pure time-based round-robin to **bond-weighted time allocation**: a keeper's primary-time share is proportional to their bond amount.

```aiken
fn current_primary_pkh_weighted(auth: KeeperAuthDatum, now_ms: Int) -> VerificationKeyHash {
  let set = active_keeper_set(auth)             // List<(pkh, bond)>
  let total_bond = sum_bonds(set)
  let cycle_ms = auth.rotation_period_ms * list.length(set)  // one full cycle
  let elapsed_in_cycle = (now_ms - auth.rotation_epoch_start_ms) % cycle_ms

  // Walk cumulatively through set, picking the keeper whose bond-weighted slot
  // contains elapsed_in_cycle
  find_primary_by_cumulative_bond(set, elapsed_in_cycle, total_bond, cycle_ms)
}
```

**Equal bonds fallback**: if all active keepers have equal bonds (or `GovernanceOnly` mode with no bonds), the algorithm reduces to equal-time round-robin — identical to §4.2.

**Phase 3 activation**: this happens automatically when `registration_mode` is set to `Mixed` (via `UpdateAuthDatum` governance action). No governance quarterly evaluation of keeper order is needed — bonds decide the schedule.

**Phase 4 activation**: `PermissionlessWithBond` mode with open bond posting. Anyone can `PostBond` and enter the rotation at a bond-weighted slot proportion. Higher bonds buy more primary time — the bond is both a liveness commitment (slashable) and an economic signal.

**Safety properties**:
- A single keeper with disproportionately large bond cannot prevent others from earning — the weighted rotation still slices the cycle among all bonded keepers
- Minimum bond `bond_amount_required >= 50_000_000` (50 ADA) prevents zero-weight bonded entries
- Maximum bond-time-share for any single keeper is `bond[k] / total_bond` → capped at 100% only if all other bonds are zero; otherwise naturally bounded

### 4.8 V2 upgrade triggers (future scale)

The pure on-chain rotation mechanism described above serves V1 through Phase 3/4. V2 redeploy may introduce additional optimizations when all of the following hold: TVL ≥ 50M USDCx AND active keeper set size ≥ 10 AND monthly failover race events ≥ 3 for 3 consecutive months. Candidate V2 optimizations include reference-input-only primary validation (A-Optimized pattern) and dispute-resolution rounds. These are **not V1 scope**.

---

## 5. V1 launch configuration

At V1 mainnet deploy, KeeperAuthDatum is initialized with:

| Field | Launch value | Rationale |
|-------|--------------|-----------|
| `registration_mode` | `GovernanceOnly` | V1 ships with curated keeper set; permissionless registration deferred until there's genuine demand |
| `authorized_pkhs` | `[founder_pkh]` | Honest initial state — only the founder runs the keeper at launch |
| `active_bonds` | `[]` | No bonds at launch; permissionless mode not active |
| `bond_amount_required` | `100_000_000` (100 ADA) | Sane default for future permissionless activation; not used until mode changes |
| `last_config_update_time` | `tx.validity_range.upper` at launch | |
| `cooldown_ms` | `60_000` (1 minute) | Loose anti-spam at launch; can be tightened if needed |
| `max_authorized_count` | `10` | Hard cap on authorized list; deters governance from growing list without bound |
| `rotation_epoch_start_ms` | `tx.validity_range.upper` at launch | Anchor for rotation arithmetic |
| `rotation_period_ms` | `604_800_000` (7 days) | Weekly rotation once ≥ 2 keepers active |
| `failover_window_ms` | `1_800_000` (30 min) | Non-primary may step in after 30 min of primary silence |
| `last_successful_tx_at` | `tx.validity_range.upper` at launch | Initialized to deploy time |
| `nonce` | `0` | Strict-monotonic anti-replay counter |
| `governance_policy` | GovNFT policy | Immutable after deploy |
| `governance_name` | "OptiVaultsGovV1" asset name | Immutable after deploy |

**Active keeper set size at V1 launch = 1** (founder only). Rotation and failover logic are effectively dormant; `current_primary_pkh` deterministically returns the founder PKH regardless of time.

When a second keeper is added via governance (Phase 2, expected after TVL ≥ 500K USDCx), weekly rotation activates automatically from the re-anchored epoch.

---

## 5. Mode-switching flow (what the "run now, open later" design enables)

When TVL and ecosystem maturity justify permissionless keeper registration, the transition is a **single on-chain event** with no vault redeploy:

1. **Product owner proposes**: governance queues `UpdateKeeperAuth` with `new_datum.registration_mode = PermissionlessWithBond` (or `Mixed`) and desired `bond_amount_required`
2. **7-day timelock** — any gov signer can CancelAction as a 1-of-n veto
3. **Execute** — any signer executes; the stake-script datum updates
4. **Anyone can now bond**: third parties post bonds via `PostBond`, becoming authorized keepers
5. **Vault contracts unchanged** — `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid` all still check "is there a zero-withdraw against keeper_stake_script?" and don't care what the stake script's internal rules are

This is the **primary architectural benefit** of the stake-validator approach over alternatives (hardcoded PKH list, License NFT minting policy, etc.): authorization policy evolves within a single validator's own datum, invisible to the rest of the protocol.

**Layer scoping**: the `UpdateKeeperAuth` governance action above is a **protocol-layer** event — it mutates on-chain state that applies to a specific vault instance. The **operator layer** (`optivaults-reference`'s keeper TypeScript code, wallet key management, hosting infrastructure) is entirely independent — a fork operator choosing which keeper PKHs to register in their instance is a governance decision for that instance, separate from how the TypeScript keeper is coded. The same operator-layer code can run against any protocol-layer vault that whitelists its PKH.

---

## 6. Why not use a License NFT minting policy instead?

A License NFT approach (mint one NFT per authorized keeper; vault contracts check for NFT presence in keeper inputs) was considered and rejected in favor of the stake-validator approach for V1:

- **Rotation flexibility**: License NFT mint/burn requires a minting policy transaction per add/remove; stake-script datum update is a single UTXO consume + recreate, arguably cleaner.
- **Mode flexibility**: stake-validator can encode multiple modes (governance-only, mixed, permissionless) in its own datum logic; License NFT would need either multiple minting policies or a per-license "is this license valid?" runtime check.
- **Already using the pattern**: V1 already uses staking validators for `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`. Adding `keeper_stake_script` is architecturally consistent and doesn't require depositors to learn a new primitive.
- **Bond integration**: stake-validator naturally holds bond UTXOs directly at its own address; License NFT would require a separate bond contract.

A License NFT layer could be added as a supplementary credential check on top of the stake script in V2+ (e.g., "permissionless mode but the registration ceremony mints an NFT for UX purposes"), without contradicting the V1 architecture.

---

## 7. Depositor-facing guarantees

A depositor reading this specification can rely on the following properties being contract-enforced:

1. **Keeper identity is governance-curated at launch**: no third party can act as keeper without a governance `UpdateKeeperAuth` action adding their PKH, which requires the launch-time 3-of-3 multisig + 14-day timelock (per `governance.md` §3 action catalog).
2. **Mode transitions require governance**: no unilateral switch to permissionless can happen; governance must queue + wait + execute, with 1-of-n cancel veto window.
3. **Keeper cannot extract principal**: the `keeper_stake_script` authorizes keeper *actions* (Compound, BatchProcess, SupplyToLiqwid, etc.), but the vault validators enforce their own invariants (token preservation, fee cap, no-mint-outside-share-token, etc.) on top of the authorization. A keeper with a valid stake-script authorization still cannot drain the vault.
4. **Keeper compromise is scoped to operational DoS**: a compromised keeper wallet can block auto-compounding and delay batch processing, but cannot route funds to attacker-controlled destinations (DeployToProtocol + RecallFromProtocol both enforce `registry.protocol_hashes` whitelist).
5. **7-day emergency escape remains**: regardless of keeper state, `Withdraw` is always available to users, and `last_compound_time + 7d < now` triggers fee-free direct withdrawal.

---

## 8. Reference to companion documents

- `spec/architecture.md` §3.5 — summary of stake-validator role in protocol architecture
- `spec/governance.md` — `UpdateKeeperAuth` / `SlashKeeper` governance actions in full catalog
- `docs/security-model.md` — honest 6-identity human-controller map (which natural persons hold keeper PKH vs governance signatures)
- `docs/audit-scope.md` — stake-validator as a separately-audited subsystem in the V1 audit engagement

---

## 9. Stake credential lifecycle (A2, 2026-04-20)

Cardano ledger locks 2 ADA in a deposit every time `keeper_stake_script`'s stake credential is registered (once per V1 deploy, during ceremony PHASE 4a). Deregistering the credential refunds the 2 ADA to the deregister TX submitter.

`keeper_stake_script` carries a gov-gated `publish` handler (A2) that uses the standard `is_gov_authorized(ActDeregisterStake)` check against its existing compile-time `governance_nft_policy` + `governance_nft_name` params. Flow:

1. Governance queues `ActDeregisterStake` with `target_script = keeper_stake_script_hash` and `payload_hash = blake2b_256(cbor.serialise(keeper_stake_script_hash))`.
2. 14-day timelock elapses (1-hour on Preprod verification override — see `lib/vault/constants.ak`).
3. Any signer executes a TX that (a) consumes the `multisig_gov` UTxO with `ExecuteAction(action_id)`, (b) includes a Cardano `Deregister` certificate for `keeper_stake_script`'s stake credential, and (c) produces the continuing `multisig_gov` output with the matching state transition.

The Cardano ledger invokes `keeper_stake_script.publish` on the Deregister cert; our handler re-validates the gov authorization and returns True. Ledger accepts the cert + refunds 2 ADA.

Post-deregister, the vault is **not operable** — any TX attempting Withdraw-Zero against `keeper_stake_script` will fail (credential no longer registered). Deregister is therefore an end-of-life / decommission action, not a routine ops step. Post-Phase-77 + 77b/77c/77d the same pattern applies to all 12 V1 staking credentials (`vault_user` / `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada` / `vault_protocol` / `vault_recall` / `vault_liqwid` / `vault_gov_policy` / `vault_gov_emergency` / `vault_admin_deploy` / `keeper_stake_script` / `minswap_v2_adapter` SwapAdapter). The pre-Phase-77 16 KB ceiling limitation that previously blocked `vault_core`'s `publish` handler was resolved by splitting vault_core into `vault_user` + `vault_keeper_hot` — see `spec/governance.md` §4.13.
