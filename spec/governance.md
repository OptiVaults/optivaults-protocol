# governance.md — MultisigGov Actions Catalog

*Public-facing companion to the [`multisig-gov.md`](./multisig-gov.md) implementation spec. V1 governance instantiates the **MultiSig Governance + Timelock Pattern** documented in [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md); this catalog enumerates the 14 V1 action kinds, their timelock floors, and the cross-validator authorization flow.*

V1 governance is an m-of-n multisig with timelock and cancel veto — the **MultiSig Governance + Timelock Pattern** instantiated for V1's specific action set. This document enumerates every governance-gated action, its timelock, its cancel window, and the on-chain authorization flow.

---

## 1. MultisigGov Overview

The `multisig_gov` validator holds one UTXO carrying a one-shot **Governance NFT** (minted at deploy, policy + name anchored at compile time into every validator that accepts governance authorization). The UTXO's datum is:

```aiken
type GovDatum {
  signers: List<VerificationKeyHash>,        // current m-of-n signer set
  signer_joined_at_ms: List<Int>,             // parallel list: each signer's tenure start time
  signer_last_qualified_ms: List<Int>,        // parallel list: last time signer performed a qualifying act (governance TX or heartbeat)
  threshold: Int,                              // m
  queued: List<QueuedAction>,                 // pending timelocked actions
  signer_compensation_pool: Int,              // Accumulated governance fee pool (lovelace, USDCx units denominated)
  last_distribute_ms: Int,                    // Last DistributeSignerCompensation execution
  distribute_period_ms: Int,                  // 90 days (quarterly)
  nonce: Int,                                  // monotonic, bumped on every state change
}

type QueuedAction {
  action_id: ByteArray,       // 32-byte content hash of the action
  target_script: ByteArray,   // validator hash the action will eventually spend
  target_tx_hash: ByteArray,  // optional pre-committed TX hash (empty = "unknown")
  action_kind: ActionKind,
  queued_at_ms: Int,
  executable_at_ms: Int,      // queued_at + timelock
  expires_at_ms: Int,         // executable_at + TTL
  payload_hash: ByteArray,    // hash of redeemer payload (verified at execute time)
}
```

Any state-changing governance redeemer requires **≥ threshold signatures** from `signers`.

---

## 2. Redeemer Catalog

### 2.1 QueueAction

Pushes a new entry onto `queued`. Signed by ≥ threshold signers. Cannot execute yet — only queues.

```aiken
QueueAction {
  action: ActionKind,
  target_script: ByteArray,
  target_tx_hash: ByteArray,
  payload_hash: ByteArray,
  timelock_ms: Int,            // must be >= min_timelock for action kind
  ttl_ms: Int,                 // execution window after executable_at
}
```

Validation:
- `threshold` signatures present
- `timelock_ms` >= per-action floor (§3)
- `ttl_ms` >= 1 day, <= 30 days
- `nonce` bumped by exactly 1
- `queued` length <= 10 (DoS cap)

### 2.2 CancelAction

Removes a queued entry. **1-of-n authorization** — any single signer can cancel, no threshold needed. This is the emergency brake against rogue signers colluding to queue malicious actions.

Validation:
- 1 signer signature present (any member of `signers`)
- Target `action_id` exists in `queued`
- `nonce` bumped by exactly 1

### 2.3 ExecuteAction

Consumes a queued action and spends the target validator's UTXO accordingly. Signed by ≥ threshold. Must be within `[executable_at_ms, expires_at_ms]`.

Validation:
- `threshold` signatures present
- Current slot time in `[executable_at_ms, expires_at_ms]`
- Redeemer payload hash matches `payload_hash`
- If `target_tx_hash != #""`, enforce `tx.id == target_tx_hash` (rare opt-in pattern for pre-signed recovery flows)
- Queued action removed; `nonce` bumped

### 2.4 RotateSigners

Changes `signers` + `threshold`. Same timelock as other governance actions (no shortcut).

Constraints at execute time:
- `list.length(new_signers) >= 3`
- `new_threshold >= 2`
- `new_threshold <= list.length(new_signers)` — unanimity (`threshold == n`) is explicitly allowed. V1 launches with 3-of-3 to force unanimity while the founder is also keeper operator. Post-audit Phase 2+ convention is to maintain `threshold < n` so that the non-quorum signer always has genuine 1-of-n cancel power, but this is operational policy not validator enforcement.
- All elements of `new_signers` are distinct
- For each `new_signers[i]` that also appears in `old_signers`: preserve `signer_joined_at_ms[i]` and `signer_last_qualified_ms[i]` from the old state
- For each new addition: `signer_joined_at_ms[i] = tx.validity_range.lower` and `signer_last_qualified_ms[i] = 0` (they must earn their first qualification)
- `nonce` bumped
- **Pre-rotation compensation**: if `signer_compensation_pool > 0` at rotation time, a DistributeSignerCompensation TX should be executed first (operator convention; not contract-enforced) to settle with outgoing signers

### 2.5 Heartbeat

Any current signer can submit a Heartbeat TX to attest liveness and extend their qualification for the current quarter. 1-of-self authorization.

```aiken
Heartbeat { signer: VerificationKeyHash }
```

Validation:
- `signer ∈ gov_datum.signers`
- `tx.extra_signatories` contains `signer`
- Rate limit: `tx.validity_range.lower - gov_datum.signer_last_qualified_ms[signer_index] >= 7_776_000_000` (90 days) — max 1 heartbeat per quarter per signer
- New datum: set `signer_last_qualified_ms[signer_index] = tx.validity_range.lower`
- All other fields unchanged except `nonce` incremented
- Bond: no treasury spend; a Heartbeat TX costs the signer their own ~0.2 ADA network fee

**Rationale**: Heartbeat is the cheap liveness signal for signers during quiet quarters when no QueueAction / ExecuteAction / CancelAction occurs. Without Heartbeat, a dormant signer would forfeit their quarterly compensation share under the X3 hybrid rule (§2.6).

### 2.6 DistributeSignerCompensation

Distributes the accumulated governance fee pool to qualified signers. 1-of-n authorization — any member of `signers` may trigger.

```aiken
DistributeSignerCompensation { triggering_signer: VerificationKeyHash }
```

Validation:
- `triggering_signer ∈ gov_datum.signers`
- `tx.extra_signatories` contains `triggering_signer`
- `tx.validity_range.lower - gov_datum.last_distribute_ms >= gov_datum.distribute_period_ms` (quarterly cadence)
- `gov_datum.signer_compensation_pool > 0` (nothing to distribute if empty)
- **Qualification check** for each signer `i`:
  - `gov_datum.signer_joined_at_ms[i] <= gov_datum.last_distribute_ms` (full-quarter tenure; joined before the quarter started)
  - `gov_datum.signer_last_qualified_ms[i] >= gov_datum.last_distribute_ms` (signed ≥ 1 qualifying TX during the quarter: Queue/Execute/Cancel/Rotate/Heartbeat)
- Let `qualified_signers = [signers[i] where qualification holds]`
- Let `per_signer_amount = gov_datum.signer_compensation_pool / max(len(qualified_signers), 1)`
- Transaction outputs:
  - One USDCx output per qualified signer: amount = `per_signer_amount`, address = signer's PKH-payment address
  - **Forfeit flow**: `forfeit_amount = gov_datum.signer_compensation_pool - (len(qualified_signers) * per_signer_amount)` + rounding remainder. This forfeit is sent to the Treasury UTXO's `audit_reserve_balance` via the `ReceiveGovForfeit` redeemer (see `spec/treasury.md` §3.3).
- Continuing gov output:
  - `signer_compensation_pool = 0` (pool drained)
  - `last_distribute_ms = tx.validity_range.lower`
  - All other fields unchanged except `nonce` incremented

**No qualified signers edge case**: if `len(qualified_signers) == 0`, entire pool is forfeited to the audit reserve. (Should not occur in practice with a healthy governance; defense-in-depth.)

---

## 3. Action Timelock Floors

Every `ActionKind` has a minimum timelock. Governance can queue with a **longer** timelock but not shorter.

| ActionKind              | Min Timelock | TTL Default | Cancel Window | Notes |
|-------------------------|--------------|-------------|---------------|-------|
| `UpdateStrategy`        | 7 days       | 7 days      | 7 days        | Buffer ratio, allocation caps, Liqwid on/off |
| `UpdateFee`             | 14 days      | 7 days      | 14 days       | Performance fee, early-withdraw fee, min_hold |
| `UpdateFeeSplit`        | **21 days**  | 7 days      | **21 days**   | **Keeper + gov fee-bps split (keeper_fee_bps, gov_fee_bps). Longer timelock because governance is adjusting its own pay.** |
| `EmergencyWithdraw`     | 0 days       | 1 day       | 0 days        | Immediate, but requires threshold + on-chain proof of insolvency condition |
| `AdminDeployNonDeposit` | 7 days       | 14 days     | 7 days        | Non-deposit token withdrawal (donations, unsupported airdrops) |
| `UpdateRegistry`        | 14 days      | 7 days      | 14 days       | Add/remove stable tokens, protocol whitelist, Liqwid markets |
| `KeeperToggleMarket`    | 0 (keeper)   | N/A         | N/A           | 1-hour keeper unilateral — not governance-gated |
| `FastUpdateMarkets`     | 1 hour       | 1 day       | 1 hour        | Governance fast-path for Liqwid pool migrations |
| `UpdateKeeperAuth`      | 14 days      | 7 days      | 14 days       | Change `keeper_stake_script` RegistrationMode or allowlist |
| `TreasurySpend`         | 7 days       | 14 days     | 7 days        | Move funds from treasury category buckets to external addresses |
| `UpdateTreasuryParams`  | 14 days      | 7 days      | 14 days       | Change category ratios, category caps |
| `RotateSigners`         | 14 days      | 7 days      | 14 days       | Change multisig membership or threshold |
| `SlashBond`             | 14 days      | 7 days      | 14 days       | **Phase 3+ only** (`active_bonds` non-empty); confiscate misbehaving keeper's bond. Not reachable at V1 launch. |
| `UpdateOracleSource`    | 14 days      | 7 days      | 14 days       | Switch SwapAda oracle source (Charli3/Orcfax feed rotation). See `spec/ada-swap.md` §7. |
| `DeregisterStake`       | 14 days      | 7 days      | 14 days       | Recover the 2 ADA Cardano stake-registration deposit per staking validator post-teardown. Covers all **14 V1 staking credentials**: `vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`, `keeper_stake_script`, `minswap_v2_adapter` (SwapAdapter), `sundaeswap_adapter`, `sundaeswap_cancel_guard`. |
| `Heartbeat`             | 0 (self)     | N/A         | N/A           | 1-of-self signer liveness; direct redeemer, not queued |
| `DistributeSignerCompensation` | 0 (1-of-n) | N/A     | N/A           | Quarterly pool distribution; direct redeemer, not queued |

**Rationale:** high-impact actions (fee changes, signer rotation, registry mutations) get 14-day windows — long enough that any depositor can withdraw before execution if they disagree. Low-impact or urgent actions (strategy, emergency recall) get 7 days or less. `UpdateFeeSplit` gets the longest 21-day window because it is the one action where governance is adjusting its own pay — the extra week is structural protection against self-dealing.

---

## 4. Per-Action Details

### 4.1 UpdateStrategy

**Purpose:** Adjust buffer target, allocation weights, enable/disable Liqwid markets.

**Payload:**
```aiken
type StrategyPayload {
  new_buffer_target_bps: Int,             // 0..10000
  new_allocations: List<StrategyAlloc>,   // sum <= 10000 bps
  liqwid_markets_enabled: List<ByteArray>,
}
```

**Invariants enforced at execute:**
- `new_buffer_target_bps >= 500` (5% floor — prevents governance from stranding users)
- `new_buffer_target_bps <= 5000` (50% ceiling — prevents gov from making vault idle)
- `sum(new_allocations.weight) + new_buffer_target_bps <= 10000`
- `liqwid_markets_enabled` ⊆ `registry.liqwid_markets`

### 4.2 UpdateFee

**Purpose:** Change fee parameters (performance fee rate, early-withdraw fee, minimum-hold period).

**Scope:** `performance_fee_bps`, `early_withdraw_fee_bps`, `min_hold_seconds`. Does **NOT** change the 3-way fee split — that is a separate action (§4.3 UpdateFeeSplit).

**Hard caps (enforced at validator level, cannot be changed by governance):**
- `performance_fee_bps <= 450` (4.5% absolute ceiling, internal-verification policy lock)
- `early_withdraw_fee_bps <= 100` (1% ceiling)
- `min_hold_seconds >= 0` and `<= 21600` (max 6 hours — tightened from an earlier 24h cap after whitepaper review; contract constant `max_min_hold_seconds` in `lib/vault/constants.ak`)

Governance cannot raise these caps — they are protocol constants in `lib/vault/constants.ak`, checked by the shared `validate_update_fee` helper that `vault_gov_policy.ak`'s `UpdateFee` redeemer calls.

### 4.3 UpdateFeeSplit

**Purpose:** Adjust the 3-way split of the performance fee between keeper, governance pool, and treasury.

**Scope:** `keeper_fee_bps`, `gov_fee_bps`. Treasury share is derived as `10000 - keeper_fee_bps - gov_fee_bps` and not stored.

**Hard caps (enforced at validator level):**
- `keeper_fee_bps <= 4000` (40% ceiling — set high to support open-source third-party keeper viability under V1's public-goods positioning)
- `gov_fee_bps <= 1000` (10% ceiling)
- `keeper_fee_bps + gov_fee_bps <= 5000` (treasury floor ≥ 50%)

**Timelock:** 21 days (**longest timelock of any governance action**, because governance is adjusting its own compensation).

**Rationale for 21-day timelock:** self-dealing is a structural risk. Governance may be pressured (internally or by rogue m-of-n collusion) to raise `gov_fee_bps` to the cap. A 21-day window gives:
- Depositors time to withdraw before the new split takes effect
- 1-of-n dissenting signers time to CancelAction
- Community time to evaluate and publicly discuss

**Public disclosure obligation:** signers must publicly announce the proposed new split, rationale, and expected TVL impact within 1 hour of queuing. Failure to disclose is grounds for public trust re-evaluation (not contract-enforced).

**Phase roadmap (indicative, each step requires its own UpdateFeeSplit TX):**
- Phase 1 (launch): `keeper 4000 / gov 0 / treasury 6000` — keeper at validator hard cap, gov pool disabled at launch
- Phase 2 (TVL ≥ 500K + external signer added via RotateSigners): `keeper 4000 / gov 500 / treasury 5500`
- Phase 3 (TVL ≥ 2M + community signer added): `keeper 4000 / gov 1000 / treasury 5000` — treasury at validator hard floor

### 4.3.1 UpdateSlippagePolicy

**Purpose:** Governance-gated adjustment of the two §5.4 Phase 2 slippage caps (`max_slippage_bps` Tier 1 oracle bound + `min_swap_peg_bps` Tier 2 peg-floor bound). Lets governance tune `DeployToProtocol` slippage strictness without a contract upgrade.

**Scope:** `max_slippage_bps`, `min_swap_peg_bps`. No other VaultDatum field may change.

**Hard caps (validator-enforced via `lib/vault/constants.ak`):**
- `0 <= new_max_slippage_bps <= max_slippage_bps_cap` (`max_slippage_bps_cap = 500` → 5% absolute ceiling)
- `min_swap_peg_bps_floor <= new_min_swap_peg_bps <= min_swap_peg_bps_ceiling` (9_300..9_950 → between 93% and 99.5% peg)

**Timelock:** 48 hours (`timelock_update_slippage_policy_ms`). Set short relative to fee actions because (a) the change strengthens or relaxes a safety bound rather than redirecting funds, and (b) market conditions (e.g., a brief depeg event) may require timely re-tuning.

**Payload-hash binding:** `payload_hash_update_slippage_policy(new_max_slippage_bps, new_min_swap_peg_bps)` (see `lib/vault/helpers.ak`). Payload bound at queue time; execute cannot swap the values.

**Composes with `vault_protocol.DeployToProtocol`:** every `DeployToProtocol` checks both `max_slippage_bps` (Tier 1, when `registry.asset_oracles` has the deploy asset) and `min_swap_peg_bps` (Tier 2, decoded from Minswap V2 route datum's `min_receive`). Tightening either bound takes effect on the next deploy after the new datum lands.

### 4.4 EmergencyWithdraw

**Purpose:** Atomically halt productive operations (`frozen = 1`) when governance observes a catastrophic protocol condition (sustained depeg, Liqwid bad-debt, or other emergency requiring an immediate stop).

**Preconditions:**
- Threshold signatures (m-of-n)
- `target_script == vault_gov_emergency_hash`
- Redeemer carries `loss_amount` and `freeze_flag` in the payload-hash binding, but `loss_amount` is **constrained to 0** by the validator (see "Layer 1 — freeze-only" below)

**Layer 1 — freeze-only (Phase 1 governance safety):** the validator enforces `valid_deposited` as `total_deposited` unchanged + `liqwid_positions` unchanged + `loss_amount == 0`. The redeemer **cannot** drop `total_deposited` or remove positions from datum. All real loss accounting happens in `vault_liqwid.RecallFromLiqwid`'s gov-fallback path which physically Recalls underlying USDCx and writes off only the actually-realized loss (`supplied_value − underlying_received`). This eliminates the griefing surface where a single-actor governance could drop `share_price` to zero by writing off positions from datum without the corresponding fund movement (qToken-orphan vector closed at validator level).

**Composes with Layer 2 (`vault_protocol.DeployToProtocol`):** under `frozen = 1`, the keeper can still drive a swap-out (`deploy_token != deposit_token`) via the registry-whitelisted SwapAdapter. This lets honest keepers convert NDV stable tokens (DJED / USDM) back to USDCx during an emergency freeze so user `Withdraw` can pay out the full proportional share.

### 4.4.1 CommunitySunset (vault_user, not governance)

**Purpose:** Phase 1 dead-man-switch. Permits any vUSDCx holder to break the operational deadlock when the keeper + governance have both failed for ≥ 90 days.

**Authorization:** permissionless — caller must hold ≥ 1 vUSDCx in some TX input.

**Preconditions:**
- `vault_input_count == 1`
- `max(old.last_compound_time, old.last_realloc_time) + 90 days ≤ tx.validity_range.lower_bound`
- `old.last_compound_time > 1_700_000_000_000` (sanity: protect against unset/zero timestamps)
- `old.community_sunset_triggered == 0`

**Effect:** `frozen = 1` and `community_sunset_triggered = 1` (one-way irreversible). All other fields preserved (`total_deposited`, `total_shares`, `idle_buffer`, `liqwid_positions`, every policy field, every immutable field).

**Composes with the recovery validators:**
- `vault_liqwid.RecallFromLiqwid` accepts any signer when `community_sunset_triggered == 1` (skips the keeper-active / 7-day-keeper-inactive gate). Loss-aware partial recall path applies same as the gov-fallback branch.
- `vault_protocol.DeployToProtocol` Layer 2 path accepts any signer when `community_sunset_triggered == 1` (skips the keeper signature requirement). SwapAdapter destination + peg-floor + slippage caps still apply.

After triggering, any vUSDCx holder can drive Recall → Swap → Withdraw without any keeper or governance intervention. The redeemer **only opens recovery paths** — it cannot mutate any value-bearing field; attackers cannot use it to drain or brick the vault.

**Out-of-scope:** does NOT recover the ~962 ADA in reference-script lockup (founder's deploy wallet) nor the ~28 ADA in stake-credential deposits (gov-only A2 ActDeregisterStake). These accept their own residual loss as part of single-actor governance cost.

### 4.5 AdminDeployNonDeposit

**Purpose:** Withdraw non-deposit tokens that have accumulated in the vault from:
1. Donations (anyone can send tokens to the proxy address)
2. Airdrops to vault address
3. DEX/protocol dust residue

**Constraints:**
- `token != deposit_token` (cannot drain user funds via this path)
- `token != vUSDCx` (cannot drain shares)
- `token != ADA` (cannot drain vault ADA below operational floor)
- `amount <= quantity_of(vault_input, token_policy, token_name)`
- `non_deposit_value` updated proportionally (if the token was counted as NDV)

### 4.6 UpdateRegistry

**Purpose:** Maintain protocol whitelist + stable token list + Liqwid market catalog.

**Scope limits:**
- `stable_tokens`: add/remove entries, each is `(policy, name)`
- `protocol_hashes`: add/remove script hashes allowed as DEX/swap destinations in `DeployToProtocol`
- `liqwid_markets`: add/remove market entries, each is `(market_id, action_addr_hash, qtoken_policy, qtoken_name, active)`
- `keeper_pkh`: **immutable** (internal verification — cannot be changed except by full redeploy)
- `registry_auth_policy`: immutable (anchored at registry deploy)

### 4.7 KeeperToggleMarket (keeper, not governance)

**Purpose:** Let the keeper instantly pause a Liqwid market when they detect degradation.

**Authorization:** signed by `keeper_pkh` only. No timelock. No governance sig.

**Direction:** `active: true → false` only. A keeper **cannot** re-enable a market.

**Rationale:** Keeper has real-time visibility into Liqwid health. Waiting 14 days for governance to pause a failing market could cost user funds. But keeper cannot **reactivate** a market — that requires governance review.

### 4.8 FastUpdateMarkets

**Purpose:** When Liqwid migrates pool shards, `action_addr_hash` changes. Normal `UpdateRegistry` has 14-day timelock — too slow for a live migration.

**Scope:** Only `action_addr_hash` for existing markets. Cannot add new markets, change `qtoken_policy/name`, or toggle `active`.

**Authorization:** threshold signatures, 1-hour timelock.

**Attack surface (disclosed):** A compromised governance (m signers colluding) could front-run a false Liqwid migration and redirect Supply/Recall to an attacker-controlled action address. Mitigation: 1-of-n cancel within 1 hour + off-chain monitoring + keeper can `KeeperToggleMarket` to `active: false` to halt all operations while governance is in question.

### 4.9 UpdateKeeperAuth

**Purpose:** Change the keeper authorization regime.

**V1 launch scope:** toggle `RegistrationMode` between `GovernanceOnly`, `Mixed`, `PermissionlessWithBond`. Update keeper allowlist (in `GovernanceOnly` mode).

**Later-phase scope:** Change bond parameters (amount, grace period, slashing conditions). Update `keeper_commission_bps` within treasury accounting.

### 4.10 TreasurySpend

**Purpose:** Move treasury funds to external addresses (audit payments, ops, R&D, founder repayment).

**Constraints:**
- `amount <= treasury.category_balances[category]`
- `category_balances` updated: `-amount`
- Receiver address NOT constrained on-chain — governance vouches for recipient off-chain
- Audit trail: TX-level CBOR contains action_id + category + amount + destination

### 4.11 UpdateTreasuryParams

**Purpose:** Change category ratios (V1 launch default 40/25/25/10 for audit/ops/R&D/buffer).

**Invariants:**
- Sum of all category ratios == 10000 bps (100%)
- No category ratio > 5000 bps (50%) — prevents governance from concentrating funds
- `audit_reserve_ratio >= 2000` (20% floor — audit reserve cannot be gutted)

### 4.12 RotateSigners

**Purpose:** Change multisig membership.

**Invariants (from §2.4):**
- `signer_count >= 3`
- `threshold >= 2`
- `threshold <= signer_count - 1`

**Timelock:** 14 days (tied with several other high-impact actions; `UpdateFeeSplit` at 21 days is the only one longer).

---

### 4.13 DeregisterStake (A2)

**Purpose:** Recover the 2 ADA Cardano stake-registration deposit posted per staking validator when its credential was registered during the V1 deploy ceremony. Addresses the V1 design-gap documented in the operator's deploy-verification notes, where the original staking validators' `else(_) { fail }` catch-all rejected the ledger's Publish purpose.

**Scope at V1 launch:**
- **All 14 V1 staking credentials** carry a gov-gated `publish` handler and are deregister-able via this action: `vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`, `keeper_stake_script`, the SwapAdapter `minswap_v2_adapter`, and the SundaeSwap pair `sundaeswap_adapter` + `sundaeswap_cancel_guard`. Partitioning rationale documented in `spec/architecture.md §4.1`.

**Publish handler pattern:**
```aiken
publish(_redeemer, credential, tx) {
  expect Script(own_hash) = credential
  is_gov_authorized(
    tx,
    governance_nft_policy,
    governance_nft_name,
    ActDeregisterStake,
    payload_hash_deregister_stake(own_hash),
    own_hash,
  )
}
```

`governance_nft_policy` + `governance_nft_name` are **compile-time parameters** on each of the 4 staking validators (keeper_stake_script already carried them pre-A2; vault_protocol / vault_liqwid / vault_admin each gained the pair). Anchoring at compile time — rather than reading from the vault datum via `find_vault_utxo` — decouples the deregister ordering: operators can deregister stake credentials AFTER vault full-drain (when the vault UTxO no longer exists) or BEFORE, in any order.

**Payload:** `payload_hash_deregister_stake(target_hash) = blake2b_256(cbor.serialise(target_hash))`. Off-chain tooling computes the same hash when queueing.

**Timelock:** 14 days (production). Matches `UpdateKeeperAuth` — same operator-credential-change tier. **Preprod build override:** when `preprod_fast_timelocks: Bool = True` in `lib/vault/constants.ak`, all gated timelocks (including this one) resolve to 60 s for end-to-end test turnaround. Mainnet build sets the flag to `False`; verifier `deploy/tools/verify-mainnet-build.sh` confirms no 60 s literal sneaks through to the active branch.

**Attack-surface analysis:**
- AT-1 (griefing): compromised m-of-n gov queues ActDeregisterStake → 14d timelock + 1-of-n cancel veto. Same defense profile as every other Act*.
- AT-2 (same-block race): atomic; post-deregister, vault TXs naturally fail because stake cred is gone.
- AT-3 (partial deregister inconsistent state): operator-side bookkeeping concern, no fund loss — withdraw-zero pattern breaks cleanly.
- AT-4 (third-party re-register): anyone can re-register a deregistered stake cred (Register cert is script-free per Cardano ledger rules) by paying 2 ADA themselves. Attacker loses 2 ADA, operator regains their 2 ADA. Net negative for attacker — not exploitable.
- AT-5 (gov signer compromise): not a new surface — compromised gov can already execute every other Act*.

**Tooling:** `deploy/tools/deregister-stakes.ts` (rewritten for gov flow: `--queue` queues ActDeregisterStake per target, `--execute` runs after timelock).

---

## 5. Empty-Hash Authorization Pattern

**Background:** `QueueAction` accepts `target_tx_hash == #""` (empty). When target is empty, `ExecuteAction` does **not** enforce `tx.id == target_tx_hash`. This is intentional.

**What empty-hash does NOT change:**

`ExecuteAction` always requires `signers_present >= gov.threshold` at execute time (`multisig_gov.ak:378` — `sig_ok = signers_present >= gov.threshold`). The empty-hash pattern only bypasses the `tx.id == action.target_tx_hash` binding; every other `ExecuteAction` invariant still applies:

- **≥ threshold signatures** at execute time (no "1-of-n can execute alone" path exists).
- **Payload-hash binding** (`blake2b_256(cbor.serialise(redeemer))` must match `action.payload_hash`). The target validator's redeemer parameters — new fee rates, new allocations, receiver addresses, amounts — are fixed at queue time and cannot be swapped at execute time.
- **Timelock window** (`tx.validity_range.lower >= action.executable_at_ms` and `upper < action.expires_at_ms`).
- **Validity-range width cap** (`upper - lower <= 1 hour`), which bounds `tx.id` tampering attempts.
- **GovNFT uniqueness** (`nft_in_input && nft_in_output`).

Common mischaracterization to avoid: "any 1-of-n signer can execute arbitrary admin after 14 days" — this is **not true**. `ExecuteAction` always requires the full threshold, regardless of whether `target_tx_hash` is empty.

**Why empty-hash exists:**

- Many governance actions cannot predict their exact future TX hash (the TX hash depends on inputs chosen at execution time, which cannot be known at queue time — most importantly, the fee-paying UTXO).
- Requiring a specific TX hash would make most governance actions impossible to queue, except in narrow cases (e.g. a self-contained `MultisigGov` spend whose inputs are known ahead of time).
- Parallel `tx.id ↔ target_tx_hash` circular dependency: computing `target_tx_hash` at queue time would require knowing the full execute-time TX body, which includes `target_tx_hash` itself.

**Which actions accept empty hash (V1 current):**

- `UpdateFee`, `UpdateFeeSplit`, `UpdateRegistry`, `RotateSigners`, `TreasurySpend`, `UpdateTreasuryParams`, `UpdateKeeperAuth` — all accept empty hash.
- `EmergencyWithdraw`, `AdminDeployNonDeposit`, `FastUpdateMarkets` — also accept empty hash (queue precedes execute-time state by design).
- `Heartbeat`, `DistributeSignerCompensation`, `CancelAction` — not queued actions (direct 1-of-n or 1-of-self redeemers).

**Actual residual risk (accurately stated):**

The remaining attack surface when empty-hash is used:

1. **`m` colluding signers** can queue an action (14-30 days in advance per `timelock_ms`).
2. After the timelock elapses, `m` colluding signers execute the action. The payload is fully bound by `payload_hash`, so the post-execute on-chain state is exactly what they queued — no "swap-in arbitrary redeemer" is possible. What empty-hash does free up is the TX *shape* (which UTXOs pay the fee, which outputs are added beyond the required ones, etc.) but that freedom does not change the payload's intent.
3. **Defense — 1-of-n CancelAction** (`multisig_gov.ak::CancelAction`, `sig_ok >= 1`): any single signer not participating in the collusion can cancel the queued action at any time during the timelock window.
4. **Defense — off-chain obligations** (operator charter, not validator-enforced):
   - Broadcast every non-trivial queue within 1 hour of signing (public Discord announcement + on-chain CBOR decode so any party can parse the payload).
   - Maintain ≥1 honest signer monitoring every queue.
   - Recruit signers such that ≥2 signers are non-colluding (charter requirement; V1 launch satisfies this via 1 founder + 2 independent Cardano SPOs).

**V1 launch note (3-of-3 unanimity).** At launch, `threshold == n == 3`, so "m colluding" means "all 3 signers colluding". 1-of-n cancel = any 1 of 3 signers can veto during timelock. Structurally this is stronger than typical threshold setups because the queue itself requires unanimity; the concern only has teeth once Phase 2+ switches to `threshold < n` (5 signers / threshold 4), where 4 colluding signers + 1 silent honest signer can push an action through if monitoring fails.

**Historically closed variant:** the specific "1-signer CancelAction + timelock=0 emergency path" grief — where a malicious signer could have griefed a legitimate action via a 0-timelock abuse — was closed during internal verification. Current `min_timelock_ms(action_kind)` floors every action (including `EmergencyWithdraw`) at ≥ its documented minimum (§3).

---

## 6. Nonce and Replay Protection

`GovDatum.nonce` is strictly monotonic, bumped on every state change (Queue, Cancel, Execute, Rotate). This prevents:
- Replay attacks (same redeemer twice)
- Ambiguous state reads by off-chain observers
- Inconsistent views across reorgs

Every governance redeemer's Plutus eval reads `old_nonce + 1 == new_nonce`. If violated, the TX fails.

---

## 7. Cross-Validator Authorization Flow

When `vault_protocol` receives a `VaultAdmin` redeemer (e.g., `UpdateFee`), it runs:

```aiken
validate_gov_admin: fn(tx) -> Bool {
  // 1. Find MultisigGov input
  let gov_input = find_input_by_script(tx.inputs, governance_policy)
  expect gov_input: Input

  // 2. Parse GovDatum and find queued action
  let gov_datum = parse_gov_datum(gov_input.output.datum)
  let action_id = compute_action_id(redeemer)
  let queued = list.find(gov_datum.queued, fn(q) { q.action_id == action_id })
  expect Some(action): Option<QueuedAction> = queued

  // 3. Verify timelock window
  expect tx.validity_range.lower >= action.executable_at_ms
  expect tx.validity_range.upper < action.expires_at_ms

  // 4. Verify target matches
  expect action.target_script == vault_protocol_hash

  // 5. Verify payload hash
  expect compute_payload_hash(redeemer) == action.payload_hash

  // 6. Verify continuing gov output has action removed + nonce bumped
  // (done by multisig_gov validator on its own spend path)

  True
}
```

Every governance-gated redeemer in `vault_protocol`, `registry`, `treasury`, and `keeper_stake_script` delegates to this pattern. The MultisigGov validator is the single source of truth for authorization.

---

## 8. V1 Launch Signer Set

Launch with **3 founder-connected signers, threshold 3** (3-of-3 unanimity). All identities disclosed in public whitepaper + on-chain at deploy.

**Why unanimity at launch:** the founder also operates the keeper. A 2-of-3 launch would let the founder push a governance action through with the help of only ONE other signer. Requiring 3-of-3 forces the founder to convince BOTH of the other two independently-recruited signers for every governance action. This trade-off loses the "structural dissent signer" property (if all three collude, no one outside the quorum to veto), but at launch all three signers are already founder-connected so this property was already weak; the enforced unanimity is the stronger guarantee.

**Rotation roadmap:**
- Phase 1 (launch → audit pass): 3 founder-connected signers, **threshold 3 (3-of-3)**
- Phase 2 (post-audit, TVL > 500K): 5 signers (add 1–2 external — candidates: whale depositors, peer-protocol founders, technical community members), **threshold 4 (4-of-5)** — structural dissent signer restored
- Phase 3 (TVL > 2M): 7 signers (add community-elected positions; election mechanism **TBD**, decided ahead of Phase 3 activation — vUSDCx holding is explicitly **NOT** used as vote weight to avoid plutocracy), **threshold 5 (5-of-7)**
- Phase 4 (mature, TVL > 10M): explore DAO migration

Each rotation is a `RotateSigners` TX with full 14-day timelock. Public disclosure of new signer identities is part of the governance charter.

**Gov Signer NFT:** each signer receives a soul-bound **OptiVaults Gov Signer** NFT upon joining the set. The NFT has no on-chain voting or financial rights — it is recognition only, and is burned when the signer rotates out. Mint policy and catalog managed via a minting policy parameterized by `governance_policy` so that Governance NFT and Gov Signer NFTs are cryptographically linked. See `spec/gov-nft.md` for the detailed NFT spec.

---

## 9. Signer Compensation Mechanics

This section summarizes how governance signer compensation flows through the contract stack (full details in §2.5–§2.6 above and in `docs/economics.md`).

### 9.1 Accumulation
Every Compound TX splits the performance fee 3 ways per `VaultDatum.keeper_fee_bps` / `gov_fee_bps`:
- Keeper share → signing keeper's PKH address
- Governance share → MultisigGov UTXO's `signer_compensation_pool` (accumulates across Compounds)
- Treasury share → Treasury UTXO's category balances

### 9.2 Qualification (X3 Hybrid Rule)
A signer qualifies for distribution in quarter Q if BOTH:
1. **Tenure**: `signer_joined_at_ms[i] <= last_distribute_ms` (joined before Q started)
2. **Activity**: `signer_last_qualified_ms[i] >= last_distribute_ms` (signed ≥1 of: QueueAction, ExecuteAction, CancelAction, RotateSigners, Heartbeat during Q)

Heartbeat exists specifically so that signers in quiet quarters can still qualify.

### 9.3 Distribution
- Quarterly (90 days) via `DistributeSignerCompensation` redeemer
- 1-of-n authorization — any current signer can trigger
- Pool divided equally among qualified signers
- **Forfeit flow**: unqualified signers' share flows to Treasury audit reserve category (Y1 design — no reward redistribution among qualified signers to avoid perverse "hope others fail" incentive)

### 9.4 Launch State
- `gov_fee_bps = 0` at V1 launch → no pool accumulation → no compensation
- Phase 2 activation (TVL ≥ 500K) raises `gov_fee_bps` via `UpdateFeeSplit` (21-day timelock)
- Projected income: see `docs/economics.md` §Gov Signer Compensation

---

## 10. Pattern Extraction

The catalog of 14 ActionKinds in §4 is the V1-specific instantiation of the **MultiSig Governance + Timelock Pattern**. The generic pattern — m-of-n threshold approval, per-action timelock, 1-of-n cancel veto, strict-monotonic nonce-bound `action_id`, payload-hash binding, post-timelock TTL ceiling — is documented in [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md), along with trade-offs against alternatives and open CIP design questions. The companion file [`multisig-gov.md`](./multisig-gov.md) §10 captures the implementation-side boundary between the pattern and V1's operational elaborations.

### 10.1 What this catalog is

- A **public-facing enumeration** of which ActionKinds V1 supports, what each one mutates, and on whose authority.
- A **timelock-floor reference** (§3) — operational policy specific to OptiVaults V1, not part of the generic pattern.
- A **cross-validator authorization flow** (§7) — the wiring between MultisigGov's payload-hash check and each consuming validator's payload-recomputation step.

### 10.2 What this catalog is NOT

- It is **not** the security argument for the pattern. The security argument is in [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md) §4 (threshold security / detection time / veto asymmetry / replay resistance / payload immutability / TTL ceiling) and applies to any conforming implementation.
- It is **not** a CIP draft. V1 does not author a CIP at the V1 stage; see [`cip-readiness-posture.md`](../docs/cip-readiness-posture.md) §4 for the four gates before V1 would consider authoring.
- It is **not** the validator-level enforcement detail. That lives in [`multisig-gov.md`](./multisig-gov.md) §3–§9 (signer membership invariants, action_id computation, payload_hash computation, redeemer implementations, cross-validator authorization helpers, size considerations, regression test surface).

### 10.3 Where to read next, by question

- *"What guarantees does this governance design give a depositor?"* → [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md) §4 (the generic security argument)
- *"How does V1 enforce those guarantees in Aiken?"* → [`multisig-gov.md`](./multisig-gov.md) §3–§9 (the implementation spec)
- *"What can V1 governance do and how long does each action take?"* → this file's §4 (the action catalog)
- *"What V1-specific choices sit on top of the pattern?"* → [`multisig-gov.md`](./multisig-gov.md) §10 (timelock floors, signer compensation, empty-hash mode)
- *"How does V1's governance design relate to Cardano-ledger-level CIP-1694 governance?"* → [`pattern-rationale-multisig-gov-timelock.md`](./pattern-rationale-multisig-gov-timelock.md) §5 (complementary, not in tension)

---

## 11. See Also

- `spec/architecture.md` — validator catalog, governance's role in the trust model
- `spec/keeper-auth.md` — how governance authorizes keepers via `UpdateKeeperAuth`
- `spec/treasury.md` — how governance spends treasury via `TreasurySpend`, forfeit accumulation path
- `spec/gov-nft.md` — Gov Signer NFT mint policy and lifecycle
- `spec/vault-datum.md` §2.2 — fee-split hard caps enforced at validator level
- `docs/security-model.md` — full threat model including governance-compromise scenarios
- `docs/economics.md` — 3-way fee split math, compensation projections by TVL
