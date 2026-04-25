# OptiVaults V1 — Treasury Specification

**Scope**: the on-chain treasury contract that holds protocol-fee revenue with category-bucketed accounting and governance-gated spend rules.

---

## 1. Purpose

The treasury validator holds the protocol's share of the performance fee harvested on every Compound operation. At V1 launch, this is 60% of the performance fee (keeper 40% / gov 0% / treasury 60% — keeper share at the validator hard cap to support open-source third-party keeper viability); Phase 2+ activates the governance pool via `UpdateFeeSplit` and treasury's share drops to 55% (Phase 2) or 50% (Phase 3, validator hard floor). See `spec/vault-datum.md` §2.2 for the fee-split hard caps and `spec/governance.md` §4.3 for the UpdateFeeSplit action.

Funds are segregated into four category buckets with distinct use cases, ratio-governed inflow, and per-category spend rules. The treasury is the on-chain accountability mechanism — any depositor or third party can inspect the treasury UTXO, verify inflows against Compound transactions, and audit spend actions against the governance log.

The treasury also receives **forfeited governance compensation** (§3.3 below) from signers who fail to qualify for quarterly distribution. This secondary inflow path routes entirely to the audit reserve category, strengthening the depositor-protection budget when governance is underperforming.

---

## 2. TreasuryDatum

```aiken
type SpendCategory {
  AuditReserve    // Target: accumulate toward third-party audits
  Operations      // Target: hosted infrastructure costs
  RD              // Target: protocol development, bounties, ecosystem grants
  Buffer          // Target: unexpected costs, legal, incident response
}

type TreasurySpendRecord {
  tx_hash: ByteArray,
  category: SpendCategory,
  amount: Int,
  recipient: Address,
  timestamp: Int,
}

type TreasuryDatum {
  // --- Category balances (cumulative USDCx held, per category) ---
  audit_reserve_balance: Int,
  operations_balance: Int,
  rd_balance: Int,
  buffer_balance: Int,

  // --- Inflow split ratios (basis points; sum must equal 10000) ---
  audit_bps: Int,        // Launch default: 4000 (40%) — bumped from 30% so audit-reserve accumulation rate stays at 24% of total fee under the 60% treasury share (60% × 40% = 24%, same as the prior 80% × 30%)
  ops_bps: Int,          // Launch default: 2500 (25%) — reduced from 40% because keeper now gets 40% direct share, no need to double-fund per-keeper infra via ops bucket
  rd_bps: Int,           // Launch default: 2500 (25%) — bumped from 20% to maintain absolute R&D budget under smaller treasury share
  buffer_bps: Int,       // Launch default: 1000 (10%) — unchanged

  // --- Spend cooldowns & limits (per-category) ---
  last_spend_time_audit: Int,        // POSIX ms — audit-reserve 24h cooldown anchor
  last_spend_time_ops: Int,          // POSIX ms — operations 24h cooldown anchor
  last_spend_time_rd: Int,           // POSIX ms — r&d 24h cooldown anchor
  last_spend_time_buffer: Int,       // POSIX ms — buffer 24h cooldown anchor
  last_param_update_time: Int,       // POSIX ms, UpdateParams cooldown anchor
  monthly_cap_audit: Int,            // Per-category monthly outflow cap (USDCx)
  monthly_cap_ops: Int,
  monthly_cap_rd: Int,
  monthly_cap_buffer: Int,

  // --- Recent spend log (bounded history) ---
  recent_spend_log: List<TreasurySpendRecord>,  // Last 50 entries

  // --- Immutable identity ---
  governance_policy: ByteArray,   // Governance NFT policy for spend authorization
  governance_name: ByteArray,
  min_audit_reserve: Int,         // Absolute floor on audit_reserve_balance
}
```

**Total fields**: 21. **Immutable after deploy**: 3 (`governance_policy`, `governance_name`, `min_audit_reserve`). **Mutable per-Receive**: balances only. **Mutable per-Spend**: target balance, **the matching `last_spend_time_<category>`** (others unchanged — each category has its own 24h cooldown anchor), `recent_spend_log`. **Mutable per-UpdateParams**: `*_bps` fields, `*_monthly_cap` fields, `last_param_update_time`.

---

## 3. Redeemers

### 3.1 `Receive` — passive inflow from Compound

Triggered when a Compound transaction pays the 60% protocol-fee share to the treasury UTXO at V1 launch (or a smaller share post Phase 2+ activation of the governance pool). The treasury validator validates that the new balances update correctly according to the split ratios.

```aiken
Receive { incoming_amount: Int }
```

**Validation**:
- `incoming_amount > 0`
- Split calculation:
  ```
  audit_delta   = incoming_amount * audit_bps / 10000
  ops_delta     = incoming_amount * ops_bps / 10000
  rd_delta      = incoming_amount * rd_bps / 10000
  buffer_delta  = incoming_amount - audit_delta - ops_delta - rd_delta   // residual
  ```
- New balance fields in the continuing datum:
  ```
  new.audit_reserve_balance == old.audit_reserve_balance + audit_delta
  new.operations_balance    == old.operations_balance + ops_delta
  new.rd_balance            == old.rd_balance + rd_delta
  new.buffer_balance        == old.buffer_balance + buffer_delta
  ```
- Treasury UTXO value (deposit-token denominated) increases by exactly `incoming_amount`
- All other TreasuryDatum fields unchanged
- No other redeemer type permits inflow; Receive is the only inflow path

**No authorization required for Receive beyond the Compound redeemer's own authorization — the Compound transaction is already keeper-authorized, and Receive merely validates that the inflow accounting is consistent.**

### 3.2 `Spend` — governance-gated outflow

Triggered by a MultisigGov `ExecuteAction` matching a queued `TreasurySpend` proposal.

```aiken
Spend {
  category: SpendCategory,
  amount: Int,
  recipient_idx: Int,
  audit_invoice_ref: Option<ByteArray>,  // Required for AuditReserve category
}
```

**Validation**:
- Transaction must contain a spent input from the `MultisigGov` validator address carrying the Governance NFT (validates governance authorization)
- `amount > 0`
- `amount <= target_category_balance` (cannot overdraw)
- **Monthly cap**: `amount + (sum of Spend amounts for this category in last 30 days per `recent_spend_log`) <= category's monthly_cap`. Entries older than 30 days excluded. Prevents single-governance-action from draining a full category.
- **24-hour per-category cooldown**: `tx.validity_range.lower - last_spend_time >= 86_400_000` for the specific category being spent.
- **Audit reserve floor**: if `category == AuditReserve`:
  - `amount + min_audit_reserve <= old.audit_reserve_balance`, i.e., post-spend balance still meets the immutable floor
  - `audit_invoice_ref` must be `Some(<hash>)` — proposal must reference an external audit invoice hash (honor-system; enforced at governance-proposal layer, logged on-chain for transparency)
- Output at `recipient_idx` is a valid non-treasury address (cannot self-loop)
- Output at `recipient_idx` receives exactly `amount` USDCx
- Treasury UTXO value decreases by exactly `amount` USDCx
- Target category balance in continuing datum decremented by exactly `amount`
- `last_spend_time` updated to `tx.validity_range.upper`
- `recent_spend_log` prepends a new `TreasurySpendRecord`; oldest entry dropped if list length > 50
- All other TreasuryDatum fields unchanged

### 3.3 `ReceiveGovForfeit` — forfeited signer compensation flow

Triggered when a MultisigGov `DistributeSignerCompensation` transaction has unqualified signers whose share is redirected to the treasury audit reserve (Y1 forfeit rule). The treasury UTXO must be consumed in the same transaction; its continuing output reflects the added forfeit amount to `audit_reserve_balance`.

```aiken
ReceiveGovForfeit { forfeit_amount: Int }
```

**Validation**:
- Transaction must also consume a MultisigGov UTXO whose redeemer is `DistributeSignerCompensation` (cross-validator binding: forfeit cannot be claimed without the matching gov action)
- `forfeit_amount > 0`
- Treasury UTXO value increases by exactly `forfeit_amount` USDCx (the incoming transfer from the gov TX)
- New continuing datum:
  - `audit_reserve_balance == old.audit_reserve_balance + forfeit_amount` (entire forfeit to audit reserve, **no split by ratios**)
  - All other balance fields unchanged
  - `operations_balance`, `rd_balance`, `buffer_balance` unchanged
- `last_spend_time`, `last_param_update_time`, ratios, caps, and immutable fields all unchanged

**Rationale for forfeit → audit reserve (not redistributed to qualified signers)**:
- Avoids "hope colleagues fail" perverse incentive
- Strengthens the most safety-critical budget category
- Reinforces depositor message: unqualified signers' share funds the audit schedule that protects everyone

### 3.4 `UpdateParams` — governance-gated ratio / cap adjustment

Triggered by a MultisigGov `ExecuteAction` matching a queued `UpdateTreasuryParams` proposal.

```aiken
UpdateParams {
  new_audit_bps: Int,
  new_ops_bps: Int,
  new_rd_bps: Int,
  new_buffer_bps: Int,
  new_monthly_cap_audit: Int,
  new_monthly_cap_ops: Int,
  new_monthly_cap_rd: Int,
  new_monthly_cap_buffer: Int,
}
```

**Validation**:
- MultisigGov input authorization (same as Spend)
- **Sum-to-10000 invariant**: `new_audit_bps + new_ops_bps + new_rd_bps + new_buffer_bps == 10_000`
- **Per-category bounds**: each `bps` value in `[0, 5000]` (no single category may exceed 50% of inflow)
- **Monthly cap bounds**: each cap in `[0, 100_000_000_000]` (100k USDCx upper sanity bound)
- **180-day update cooldown**: `tx.validity_range.lower - last_param_update_time >= 15_552_000_000`
- Update timelock on the MultisigGov side: 14 days (longer than the standard 7-day timelock, reflecting the systemic nature of the change)
- All category **balance** fields unchanged (UpdateParams only changes forward-looking split, not existing balances)
- `last_param_update_time` updated
- All identity fields unchanged

---

## 4. Spending the audit reserve

The audit-reserve category is treated with extra conservation compared to the other three:

1. **Immutable floor** (`min_audit_reserve`): set at deploy time; cannot be changed by any redeemer. Ensures a guaranteed minimum audit-funding reserve that no governance majority can vote away.
2. **Invoice reference requirement**: any Spend action with `category = AuditReserve` must carry a non-empty `audit_invoice_ref` parameter. Enforcement is honor-system at the governance-proposal stage (off-chain signers check that the invoice is real before co-signing), but the reference is logged on-chain in `recent_spend_log` for public audit.
3. **Longer timelock path option** (future, not V1): a V1.x or V2 upgrade may add a mandatory attestation-token mechanism where audit-reserve spend requires a signed "audit complete" attestation from the auditing firm; V1 operates on honor + transparency.

These three layers together represent the contract's commitment to depositors that audit-reserve funds accumulate reliably and are not diverted to operations or R&D.

---

## 5. Launch parameters

At V1 mainnet deploy, TreasuryDatum is initialized with:

| Field | Launch value | Rationale |
|-------|--------------|-----------|
| `audit_bps` | 4000 | 40% of inflow to audit reserve accumulates toward the ~USD 50K-150K target for the next third-party audit (24% of total fee under the V1 launch fee split — same accumulation rate as the historical 80%×30% allocation) |
| `ops_bps` | 2500 | 25% to platform-layer infrastructure: VPS (dual-instance keeper), Blockfrost paid tier, monitoring stack, domain/CDN, frontend hosting. Reduced from 40% because the new 40% keeper share absorbs per-keeper infra cost directly via Compound output |
| `rd_bps` | 2500 | 25% to protocol development, future bounty program (post-audit + TVL-scale per `docs/audit-scope.md §6.3`), ecosystem grants to contributors |
| `buffer_bps` | 1000 | 10% to unexpected costs, legal consultation, incident response |
| `monthly_cap_audit` | 500_000_000 (500 USDCx) | Prevents any single month's spend from draining audit reserve |
| `monthly_cap_ops` | 500_000_000 | Same-size cap across categories at launch for simplicity |
| `monthly_cap_rd` | 500_000_000 | Same |
| `monthly_cap_buffer` | 500_000_000 | Same |
| `min_audit_reserve` | 0 | At launch treasury starts empty; floor is non-binding until audit_reserve_balance naturally grows above it. Can be raised via a future UpdateParams (but once raised cannot be lowered). |

**Ratios and caps are governance-adjustable** via `UpdateParams` after launch, subject to the 180-day cooldown and per-category bounds.

---

## 6. Accounting math (honest disclosure)

At the pre-audit 100K USDCx TVL cap, assuming 6% gross APY:

- Performance fee revenue per year: `100K * 6% * 4.5% = 270 USDCx`
- Treasury inflow per year (60% share at V1 launch): `162 USDCx`
- Category annual inflow at launch ratios (40/25/25/10):
  - Audit reserve: `162 * 40% = 65 USDCx`
  - Operations: `162 * 25% = 41 USDCx`
  - R&D: `162 * 25% = 41 USDCx`
  - Buffer: `162 * 10% = 16 USDCx`

These numbers are not sufficient to fully fund OptiVaults' operating costs at the pre-audit cap — covering hosted infrastructure alone requires approximately 600–1,200 USDCx per year. V1 launches in a **bootstrapping phase** where protocol revenue does not fully cover operating costs until TVL reaches the self-sustaining range (approximately 500K–2.5M USDCx for baseline operations). Initial shortfalls are absorbed by the project's founding capital and are expected to resolve organically as TVL grows. Treasury transparency in V1 is about **making this gap visible and auditable**, not about claiming the pre-audit operation is already self-sufficient.

At approximately USD 1M TVL, the same math produces:

- Annual inflow (60% treasury share): `1,620 USDCx`
- Audit reserve: `648/yr` (24% of total fee = same accumulation rate as the historical allocation) → fills a USD 50K audit reserve in ~77 years at this TVL level, or ~8 years at USD 10M TVL
- Operations: `405/yr` — covers low-end VPS + Blockfrost (per-keeper infra now funded directly via the 40% keeper direct share, not from this bucket)
- R&D: `405/yr` — modest grant/bounty budget; 1-2 small bounties per year
- Buffer: `162/yr`

At USD 10M TVL:

- Annual inflow: `16,200 USDCx`
- Treasury becomes self-sustaining and begins generating surplus over the baseline operating cost. Audit reserve at $6,480/yr fills a $50K audit cushion in ~8 years; tier (c) full audit-cycle self-funding requires $25M+ TVL.

The TVL scale at which each category achieves its intended purpose is tracked transparently; the V1 whitepaper §9.2 and `docs/economics.md` discuss the path from subsidy-supported launch to treasury-self-sustaining operation.

---

## 7. Depositor-facing guarantees

A depositor reading this specification can rely on the following properties being contract-enforced:

1. **Inflow ratios are fixed on receive**: when a Compound pays the 60% protocol share to the treasury at V1 launch (or 55%/50% post Phase 2+ governance activation), the split across four categories follows exactly the ratios in the current TreasuryDatum. No keeper or governance action can redirect a specific Compound's inflow to a different category.
2. **Spend requires governance**: no category balance can decrease except via a `Spend` redeemer backed by a MultisigGov ExecuteAction with 7-day timelock and 1-of-n cancel veto.
3. **Audit reserve floor is immutable**: `min_audit_reserve` cannot be decreased by any governance action.
4. **Monthly caps limit single-action drains**: even if governance is compromised and queues a malicious `Spend`, the per-category monthly cap bounds the single-transaction damage.
5. **Ratio adjustments cooldown**: governance cannot oscillate ratios rapidly; `UpdateParams` has a 180-day cooldown and a 14-day timelock.
6. **Public audit trail**: every Spend is logged in `recent_spend_log` (last 50 entries on-chain) with TX hash, category, amount, recipient. A full historical log is reconstructable from Cardanoscan queries against the treasury script address.
