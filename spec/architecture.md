# OptiVaults V1 — Architecture

**Status**: V1 design specification
**Target audience**: protocol auditors, smart-contract developers, integrators, technically-literate depositors

---

## 1. Product in one paragraph

OptiVaults V1 is a non-custodial, on-chain auto-yield stablecoin vault on Cardano. Depositors lock USDCx and receive vUSDCx share tokens proportional to their deposit. An automated keeper deploys pooled capital across Liqwid Finance stablecoin lending markets (DJED, USDM) through Minswap V2 routing, harvests yield on-chain, and compounds it back into vault accounting so share price rises over time. All principal-affecting operations — deposits, withdrawals, share minting, yield calculation, fee extraction, protocol routing — are validated by Aiken PlutusV3 smart contracts. The protocol operator cannot extract user principal under any redeemer path.

V1 is the first public production release. A single user-facing vault instance runs on Cardano mainnet with an operator-enforced TVL ceiling of 100,000 USDCx until a third-party audit completes; at that point the ceiling schedule is disclosed in the audit report.

---

## 2. Actors

Five distinct actors interact with the V1 protocol. Role separation is contract-enforced where possible and disclosed with an honest human-controller map in `docs/security-model.md` where not.

| Actor | Role | Authorization source |
|-------|------|---------------------|
| **Depositor** | Deposits USDCx, receives vUSDCx; later burns vUSDCx to withdraw USDCx + accrued yield | Any CIP-30 wallet signature |
| **Keeper** | Executes automation: compound, batch-process orders, move capital between buffer and Liqwid markets, route through Minswap V2 | Holds a wallet whose PKH is listed in the `keeper_stake_script` authorization datum |
| **Governance (MultisigGov)** | Sets strategy, adjusts performance fee within `[0, 450]` bps range (4.5% upper bound is **immutable** — governance can lower it but not raise above the cap), freezes vault in emergency, rotates keeper set, spends treasury, rotates governance signers | m-of-n threshold signatures against an on-chain `MultisigGov` validator (3-of-3 unanimity at launch, TVL-gated staging to 4-of-5 then 5-of-7 — see §6.1 of the V1 whitepaper) |
| **Treasury** | Passive accumulator of protocol-fee share; category-bucketed; governance-spent with timelock | No direct actor — controlled entirely by governance redeemers into the `treasury` validator |
| **Third-party contracts** | Liqwid action validators and pool shards (for qToken mint/burn), Minswap V2 swap orders (for USDCx ↔ DJED/USDM routing) | Not under OptiVaults control; their correctness is a trust assumption documented in `docs/security-model.md` |

---

## 3. On-chain state

V1 maintains state in four distinct UTXO classes on Cardano. Each class has a single canonical UTXO at any moment (with the exception of pending Order UTXOs which may be many).

### 3.1 Vault UTXO

A single UTXO at the `vault_proxy` script address, marked by the one-shot **Vault Identity NFT**. Contains:

- All idle USDCx not deployed to yield sources (the "buffer")
- All non-deposit stablecoin positions (DJED / USDM) currently held at the vault address between swap and Liqwid supply
- qToken receipts for Liqwid positions
- Accounting datum (`VaultDatum`, 29 fields — see `spec/vault-datum.md`)
- A small ADA balance sufficient to cover minimum-UTXO requirements and fund DEX orders

The Vault NFT provides a compile-time trust anchor: the `vault_proxy`, `vusdcx`, and `order` validators all bake the Vault NFT minting policy into their script hashes. A UTXO at the `vault_proxy` address without the Vault NFT is not a valid vault and cannot be mistaken for one by any validator.

### 3.2 Treasury UTXO

A single UTXO at the `treasury` script address. Contains:

- Cumulative protocol-fee USDCx since V1 launch, categorised into four balance fields
- Accounting datum (`TreasuryDatum` — see `spec/treasury.md`)
- Minimum ADA for UTXO requirements

Category buckets:

| Bucket | Share of inflow | Purpose | Spend gating |
|--------|-----------------|---------|--------------|
| Audit reserve | 40% | Accumulate toward periodic third-party audits | Governance-gated; requires `audit_invoice_ref` in proposal |
| Operations | 25% | Platform-layer infrastructure (VPS for frontend / landing / API, Blockfrost platform queries, monitoring, domains, CDN); per-keeper infra is funded directly via the 40% keeper share at every Compound, not from this bucket | Governance-gated, 24h per-category cooldown |
| R&D | 25% | Protocol development, future bounty program (post-audit + TVL-scale per `docs/audit-scope.md §6.3`), ecosystem grants | Governance-gated, 24h per-category cooldown |
| Buffer | 10% | Unexpected costs, legal, incident response | Governance-gated, 24h per-category cooldown |

Category ratios are governance-adjustable within bounds (each category in [0%, 50%], sum to exactly 100%, update cooldown 180 days).

### 3.3 Governance UTXO

A single UTXO at the `multisig_gov` script address, marked by the one-shot **Governance NFT**. Contains:

- The governance signer set + threshold
- Queued action proposals with timelock timestamps
- A rotation cooldown timer
- Governance accounting datum (`GovDatum` — see `spec/governance.md`)

### 3.4 Order UTXOs (many)

Each deposit or withdrawal order from a user creates a transient UTXO at the `order` script address. Contains:

- The user's deposited USDCx (for DepositOrder) or their vUSDCx (for WithdrawOrder)
- User's owner address (for refund and payout routing)
- User-specified `max_batcher_tip` (ADA bound on keeper compensation)
- `expires_at` timestamp (24 hours from creation)
- Accounting datum (`OrderDatum` — see `spec/order-batch.md`)

Order UTXOs are processed by the keeper in batched transactions or refunded via `Cancel` (owner-signed) or `Expire` (anyone-can-trigger after expiry).

### 3.5 Keeper stake validator

The `keeper_stake_script` is a Cardano staking validator that holds the authorization rules for keeper actions. Its stake credential is registered on-chain. Keeper authorization checks in the vault validators are expressed as "this transaction contains a zero-withdraw entry against the `keeper_stake_script` stake credential", which delegates the authorization decision to the stake validator's redeemer.

The stake validator operates in one of three modes, tracked in its own datum:

| Mode | Who can withdraw (i.e., act as keeper) | Launch state |
|------|----------------------------------------|--------------|
| `GovernanceOnly` | Signers whose PKH appears in the `authorized_pkhs` list, governance-curated | **V1 launch mode** |
| `PermissionlessWithBond` | Anyone who posts a minimum ADA bond (bond_amount set by governance); bond slashable on proven misbehaviour | Available via governance mode-switch action, no contract migration |
| `Mixed` | `authorized_pkhs` OR bond-posters; for gradual transition | Available via governance mode-switch action |

Mode switching requires a governance action with the standard 7-day timelock. Switching from `GovernanceOnly` to `PermissionlessWithBond` is a **single on-chain event with no contract redeploy** — the vault validators only care that a zero-withdraw against `keeper_stake_script` is present; the stake script's internal rule evolves under governance.

### 3.6 Registry UTXO

A single UTXO at the `registry` script address, marked by an auth NFT. Contains the whitelist of acceptable protocol destinations (Liqwid action-validator hashes, Minswap V2 stake credentials), stable-token allowlist, Liqwid market metadata, and **asset oracles** (§5.4 P3, 2026-04-22) — a per-asset list of dual-feed oracle configurations used by `DeployToProtocol` peg-floor (P4) and `SwapAda` fair-price (P5) checks. Updated by governance with a 14-day timelock via `UpdateRegistry` and a 1-hour timelock for fast-path market updates via `FastUpdateMarkets` (Liqwid migration response). `asset_oracles` is mutable under `UpdateRegistry` only — `KeeperToggleMarket` and `FastUpdateMarkets` preserve it bit-for-bit.

The `asset_oracles` list holds `AssetOracleEntry` values pinning each priced asset to:

- `feeds: List<AssetOracleFeed>` — typically 2 entries (one Charli3 feed, one Orcfax feed), each identified by a reference-UTXO `(feed_script_hash, feed_auth_policy, feed_auth_name)` triple. The auth NFT prevents decoy UTXOs at the same script address.
- `max_disagreement_bps` — upper bound on the cross-feed price spread. Reads fail if feeds diverge beyond this window.
- `max_staleness_ms` — per-feed age bound vs `tx.validity_range.lower_bound`. Stale feeds are dropped from aggregation.
- `min_feeds` — minimum healthy feeds required to return a fair price. For V1 dual-feed entries this is 2 (both feeds must agree within bounds).

Feed datum format (InlineDatum on the feed UTXO): `PriceSample { price_bps: Int, timestamp_ms: Int }`. Off-chain oracle operator aggregates native Charli3 + Orcfax feeds into this canonical format — the operator identity is an external trust boundary documented in `spec/security-model.md`. V1 launches with `asset_oracles = []` and populates via governance `UpdateRegistry` as dual-feed coverage comes online per-asset (first DJED + USDM + ADA, then any additional Liqwid market adds).

---

## 4. Contract catalog

V1 ships with **17 logic validators + 4 NFT mint policies + 1 DEX adapter (`minswap_v2_adapter`) = 22 compiled artefacts total** (canonical count, used consistently across whitepaper §3.1, README size table, and `audit-scope.md` §6 scope statement). All are Aiken PlutusV3; compiled sizes recorded in `README.md`. Partitioning rationale (4 orthogonal seams: authorization-boundary, governance response-latency, bytecode-cost-center, size-fix) covered in §4.1 below.

| # | Validator | Role | Authorization model |
|---|-----------|------|---------------------|
| 1 | `vault_proxy` | Thin spending validator holding vault UTXO; forwards logic to staking validators via zero-withdraw | Compile-time parameterised by (user, keeper_hot, swap_ada, protocol, recall, liqwid, gov_policy, gov_emergency, admin_deploy, batcher stake_hashes + vault_nft_policy) — 11 params, 10 routes |
| 2 | `vault_user` | Staking validator: Deposit, Withdraw, CommunitySunset — permissionless user path (BatchProcess lives in the separate `vault_batcher` validator). CommunitySunset is the Phase 1 dead-man-switch; see `governance.md` §4.4.1. | Compile-time parameterised by (governance_nft_policy, governance_nft_name) — `keeper_stake_hash` no longer needed since all three redeemers are permissionless. CommunitySunset triggerable by any vUSDCx holder when `max(last_compound_time, last_realloc_time) + 90d ≤ now`. `publish` handler gated by ActDeregisterStake (A2). |
| 3 | `vault_keeper_hot` | Staking validator: Compound, RebalanceBuffer, SwapAda — keeper hot path | Compile-time parameterised by (keeper_stake_hash, treasury_hash, governance_nft_policy, governance_nft_name); all three redeemers keeper-auth via keeper_stake_script zero-withdraw; `publish` handler gated by ActDeregisterStake (A2) |
| 4 | `vault_protocol` | Staking validator: DeployToProtocol (DEX, via SwapAdapter dispatch) | Compile-time parameterised by (keeper_stake_hash, governance_nft_policy, governance_nft_name); keeper-auth only; `verify_swap_via_adapter` (from `lib/vault/swap_adapter.ak`) consolidates adapter invocation + Tier 2 peg-floor + optional Tier 1 oracle bound; `publish` handler gated by ActDeregisterStake (A2) |
| 5 | `vault_recall` | Staking validator: RecallFromProtocol, MergeUtxo | Compile-time parameterised by (keeper_stake_hash, governance_nft_policy, governance_nft_name); keeper-with-fallback (governance after 7d keeper-inactive); `publish` handler gated by ActDeregisterStake (A2) |
| 6 | `vault_gov_policy` | Staking validator: UpdateStrategy (7d), UpdateFee (14d), UpdateFeeSplit (21d), UpdateSlippagePolicy (48h) — slow deliberate policy mutations | Compile-time parameterised by (governance_nft_policy, governance_nft_name) for the A2 `publish` handler; governance via MultisigGov spent input for `withdraw` |
| 7 | `vault_gov_emergency` | Staking validator: EmergencyWithdraw (0d), AdminDeployNonDeposit (7d keeper-inactive + 21d registry-stable) — emergency / recovery paths. Also wires SwapAdapter dispatch for its DEX-swap branch. | Compile-time parameterised by (governance_nft_policy, governance_nft_name); governance via MultisigGov spent input |
| 8 | `vault_liqwid` | Staking validator: SupplyToLiqwid, RecallFromLiqwid | Compile-time parameterised by (keeper_stake_hash, governance_nft_policy, governance_nft_name); keeper-with-fallback; `publish` handler gated by ActDeregisterStake (A2) |
| 9 | `keeper_stake_script` | Staking validator authorizing keeper actions according to mode flag (GovernanceOnly / PermissionlessWithBond / Mixed) | Governance via MultisigGov for rule changes; own redeemer rules for execution |
| 10 | `treasury` | Spending validator holding treasury UTXO; receives inflow, gates outflow by category + cooldown | Compile-time parameterised by deposit token identity; governance via MultisigGov spent input |
| 11 | `multisig_gov` | Spending validator holding governance UTXO + queued proposals | Parameterised by GovNFT policy + name |
| 12 | `registry` | Spending validator holding protocol whitelist + `asset_oracles` (§5.4 P3) + `swap_adapter_hashes` (§B@launch=1) | Unparameterised; governance + keeper for fast-path market toggle |
| 13 | `order` | Spending validator holding user orders; Process / Cancel / Expire redeemers | Parameterised by vault_hash + vault_nft_policy |
| 14 | `vusdcx` | Minting policy for vUSDCx share tokens | Parameterised by vault_hash + vault_nft_policy |
| 15 | `vault_nft` | One-shot minting policy for the Vault Identity NFT — **PlutusV3 validator**, parameterised by a specific UTXO reference. Mint requires that UTXO to be in the TX inputs (cryptographic one-shot); burn has no constraint (always allowed). See `spec/vault-nft.md`. |
| 16 | `minswap_v2_adapter` | **SwapAdapter for Minswap V2 orders** (§B@launch=1). Staking validator invoked via zero-withdrawal by `vault_protocol.DeployToProtocol` + `vault_gov_emergency.AdminDeployNonDeposit`. Decodes Minswap V2 order datum (SwapExactIn / SwapMultiRouting) + verifies redeemer-committed min_receive + target_asset match on-chain datum. Unparameterised — hash whitelisted via Registry `swap_adapter_hashes`. Adding new DEX adapters post-launch goes through governance `UpdateRegistry` (14d timelock) — no V1 vault redeploy required. See `lib/vault/swap_adapter.ak` + `validators/minswap_v2_adapter.ak`. |

Two additional minting policies support the governance and registry actors. Both follow the **same PlutusV3 UTXO-ref one-shot pattern as `vault_nft`** (see `spec/vault-nft.md` §2) — no native-script deadlines, burn unconditional, cryptographic mint-once guarantee via consumed UTXO reference. Using the same pattern across all three one-shot identity NFTs keeps the security reasoning uniform and avoids the native-script deadline trap that blocked clean sunset for internal-verification-phase deployments.

- `governance_nft` — one-shot policy for the Governance NFT (single token, locked in MultisigGov UTXO; burnable at V1 sunset / V2 migration to prevent phantom-gov UTXO creation)
- `registry_auth_nft` — one-shot policy for the Registry auth NFT (single token, locked in Registry UTXO; burnable on sunset)

A fourth minting policy issues recognition-only NFTs to governance signers:

- `gov_signer_nft` — parameterised by `(governance_nft_policy, governance_nft_name)`; mint/burn gated on consuming the MultisigGov UTXO in the same TX, so only a multisig-authorised TX can issue or retire a signer NFT. Asset-name convention `<generation_byte><signer_index_byte><first_28_bytes_of_signer_pkh>` is frontend-enforced (validator accepts any asset name of any length — constraining the shape in-script would bloat a recognition-only artefact that confers no financial rights). Soul-bound enforcement is a social contract: if a signer transfers their NFT, governance RotateSigners + BurnRotatedOut removes them. See `spec/gov-nft.md` for the full lifecycle.

### 4.1 Validator partitioning rationale

V1's 17 logic validators (+ 4 NFT mint policies + 1 DEX adapter = 22 artefacts total) reflect partitioning along **four orthogonal seams**, each driven by the Plutus V3 16 KB reference-script ceiling:

- **(1) Authorization boundary** — separating permissionless redeemers from keeper-authorized + governance-authorized ones lets each half stay below ceiling and shrinks audit surface per validator. Examples: `vault_user` (permissionless Deposit/Withdraw) split from `vault_keeper_hot` (keeper-auth Compound/RebalanceBuffer); `vault_batcher` (keeper-auth BatchProcess) split from `vault_user` so the latter could drop its `keeper_stake_hash` param entirely.
- **(2) Governance response-latency boundary** — separating slow-deliberate policy mutations (7-21d timelocks) from emergency/recovery paths (0d + 7d-conditional) prevents future policy-feature additions from inadvertently bloating the emergency-path attack surface. Examples: `vault_gov_policy` (UpdateStrategy/Fee/FeeSplit/SlippagePolicy) split from `vault_gov_emergency` (EmergencyWithdraw); `vault_admin_deploy` (AdminDeployNonDeposit + SwapAdapter dispatch) further hoisted out of `vault_gov_emergency`.
- **(3) Bytecode-cost-center extraction** — when a single redeemer carries 4-5 KB of unique heavy machinery (oracle reader, decoder, fold suite) shared by no other redeemer in the same validator, hoisting it standalone gives the mother validator the full bytecode back as headroom. Examples: `vault_swap_ada` (dual-feed oracle reader + 6-tuple registry read, hoisted from `vault_keeper_hot`); `vault_admin_deploy` (SwapAdapter dispatch, hoisted from `vault_gov_emergency`).
- **(4) Size-fix forced extraction** — when adding a required feature pushes a validator over ceiling, splits along whichever of the above three seams is cheapest. Example: `vault_recall` (RecallFromProtocol + MergeUtxo) extracted from `vault_protocol` after SwapAdapter dispatch + Tier 1 oracle wiring pushed combined size to 16,500 B.

After all splits, `vault_proxy` carries **11 compile-time parameters** (10 staking validator hashes + `vault_nft_policy`) and routes **10 Withdraw-Zero paths** (`UseUser` / `UseKeeperHot` / `UseSwapAda` / `UseProtocol` / `UseRecall` / `UseLiqwid` / `UseGovPolicy` / `UseGovEmergency` / `UseAdminDeploy` / `UseBatcher`). The withdrawal-count invariant (exactly one vault staking validator per TX) scales with the number of routes. Tightest post-split headroom is `vault_liqwid` at 13,392 B (2,992 B free, 18.3% from ceiling). All 12 staking validators carry an A2 `publish` handler so each one's 2 ADA Cardano stake-deposit is reclaimable via governance after a 14d timelock — closing the V1-era "2 ADA permanent lock" trap that affected pre-split monolithic validators.

Per-extraction details (mother → daughter validator mapping, exact compile-time params, internal-audit findings on each split) live in the engineering memory store (not in the public repo). External audit firm engagement may request access to that document for the full extraction template.

---

## 5. Transaction patterns

The V1 protocol has **seven principal transaction patterns** from the user's perspective and **six from the keeper's**. All follow Cardano's eUTXO model — each transaction consumes input UTXOs and produces output UTXOs; intermediate state is encoded in datums.

### 5.1 User: Direct Deposit

User spends USDCx from their wallet into the vault UTXO, receives vUSDCx shares proportional to their deposit, in a single transaction they submit themselves.

- **Spends**: user's USDCx UTXOs; vault UTXO (consumed and reproduced with updated datum)
- **Mints**: vUSDCx (quantity = fair share amount)
- **Outputs**: new vault UTXO (idle_buffer += deposit_amount, total_deposited += deposit_amount, total_shares += shares); vUSDCx to user's address
- **Authorization**: user signature, keeper not involved

### 5.2 User: Direct Withdraw

User burns vUSDCx shares, receives USDCx from the vault's idle buffer. Applies 0.1% early-withdraw fee unless the keeper has been inactive for ≥ 7 days.

- **Spends**: user's vUSDCx UTXOs; vault UTXO
- **Burns**: vUSDCx
- **Outputs**: new vault UTXO (idle_buffer, total_deposited, total_shares all decrement); USDCx to user's declared receiver address
- **Authorization**: user signature, keeper not involved

### 5.3 User: Queue Deposit

User creates an Order UTXO at the `order` script address with `DepositOrder` action, funding it with their USDCx + a small ADA deposit + user-chosen `max_batcher_tip`.

- **Spends**: user's USDCx + ADA
- **Outputs**: Order UTXO at `order` script address
- **Authorization**: user signature
- Later: keeper processes this Order in a BatchProcess transaction (§5.8). If keeper does not process within 24 hours, anyone can trigger `Expire` and refund the full Order value back to the user.

### 5.4 User: Queue Withdraw

Analogous to Queue Deposit but `WithdrawOrder` action, funded with user's vUSDCx shares.

### 5.5 User: Cancel

Owner-signed cancellation of a pending Order UTXO.

- **Spends**: Order UTXO
- **Outputs**: full Order value refunded to owner's address
- **Authorization**: owner signature required

### 5.6 User: Emergency Withdraw

After 7 days of keeper inactivity (measured by `last_compound_time`), any vUSDCx holder can direct-withdraw with the early-withdraw fee waived. Contract-enforced; no governance action needed.

### 5.7 Anyone: Order Expire

After an Order UTXO's `expires_at` timestamp, anyone (not just the owner) can trigger the Expire redeemer to refund the Order value to the owner. This makes keeper downtime tolerable — queued orders are always recoverable regardless of keeper availability.

### 5.8 Keeper: BatchProcess

Keeper processes N pending Order UTXOs (mix of deposits and withdrawals) in a single batched transaction.

- **Spends**: N Order UTXOs; vault UTXO; keeper_stake_script zero-withdraw for authorization
- **Mints/burns**: vUSDCx proportional to net deposit/withdrawal in the batch
- **Outputs**: new vault UTXO; vUSDCx to deposit order owners; USDCx to withdraw order owners; ADA tips to keeper's address (each ≤ order's `max_batcher_tip`)
- **Authorization**: keeper stake script withdrawal

Orders in the batch are priced against the **pre-batch snapshot** (`total_deposited / total_shares` at transaction start). This keeps the per-order aggregate invariant (`Σ minted_shares == batch_mint_total`) mathematically exact; a consequence is that an order submitted while a large opposite-side order is in the same batch is priced at the pre-batch rate, not a running-accumulator rate. For typical order sizes at mature TVL this is a sub-basis-point effect; at the pre-audit 100K cap it can reach a few percent for a single 5K-order batch, which is why large deposits at low TVL should use Direct Deposit rather than batching.

### 5.9 Keeper: Compound

Keeper triggers yield harvest: the vault's current `idle_buffer + non_deposit_value - total_deposited` evaluates to the on-chain yield, of which 4.5% (or less, governance-set) is extracted as performance fee, split 40% to the executing keeper and 60% to the treasury at V1 launch (keeper share at validator hard cap to support open-source third-party keeper viability).

- **Spends**: vault UTXO; treasury UTXO; keeper_stake_script zero-withdraw
- **Outputs**:
  - New vault UTXO (total_deposited += net_yield, idle_buffer reflects redistribution)
  - New treasury UTXO (protocol_share split into four category buckets per current ratios)
  - USDCx transfer to keeper's address (40% of perf_fee)
- **Authorization**: keeper stake script withdrawal
- **Cooldown**: minimum 1 hour between compounds; validity range must be ≤ 1 hour wide to prevent timestamp-manipulation attacks
- **Zero-yield mode**: if `on_chain_yield == 0`, Compound runs as allocation-only update (no perf_fee, no keeper share, no treasury inflow); used to progress `last_compound_time` when no real yield is available

### 5.10 Keeper: Capital deployment cycle

Three keeper redeemer types coordinate to move capital between the vault and Liqwid lending markets:

1. `DeployToProtocol` — spend USDCx from vault to a whitelisted Minswap V2 swap order (e.g., USDCx → DJED)
2. `RecallFromProtocol` — consume the swap result UTXO back into the vault (the non-deposit token arrives, NDV increments)
3. `SupplyToLiqwid` — supply the non-deposit token (DJED/USDM) to Liqwid action validator, receive qToken receipts into the vault

Inverse cycle for returning to USDCx: `RecallFromLiqwid` (burn qTokens, receive stable) → `DeployToProtocol` (swap stable → USDCx) → `RecallFromProtocol` (back to vault).

- **Authorization**: keeper stake script withdrawal on all three
- **Whitelist enforcement**: destination must be listed in `registry.protocol_hashes` for DeployToProtocol; non-deposit token must be in `registry.stable_tokens` for NDV accounting to update
- **Accounting**: `non_deposit_value` is updated 1:1 with token amount moved (not via oracle) — keeper-reported + constrained by registry whitelist

### 5.11 Keeper: MergeUtxo

Merges batcher-returned UTXOs (orphan UTXOs at the vault address produced by Minswap V2 batch fills) back into the vault's main UTXO. Purely housekeeping; no accounting change beyond consolidating assets.

### 5.12 Governance: protocol-policy changes

All governance actions follow the same 3-step pattern:

1. `QueueAction` — m-of-n threshold signers propose an action with a target TX hash and timelock duration (7 days minimum, 14 days for sensitive operations like `UpdateTreasuryParams`)
2. **Timelock elapses** — during this window, any single signer can `CancelAction` as a 1-of-n veto
3. `ExecuteAction` — any single signer can trigger execution; the action's target transaction is submitted

Governance actions supported in V1:

- `UpdateStrategy` — change strategy_allocations
- `UpdateFee` — change performance_fee_bps within [0, 450] (4.5% hard cap is immutable)
- `EmergencyWithdraw` — set frozen=1 (pauses Compound / BatchProcess / DeployToProtocol; Withdraw always remains open)
- `AdminDeployNonDeposit` — swap stranded non-deposit stables back to USDCx via Minswap V2, gated by 7d keeper inactivity + 21d registry timelock
- `UpdateRegistry` — change protocol whitelist (7d governance timelock)
- `KeeperToggleMarket` — disable a specific Liqwid market (1h cooldown, keeper-authorized for rapid Liqwid migration response)
- `FastUpdateMarkets` — update Liqwid market metadata (1h governance cooldown, fast path for migration)
- `UpdateKeeperAuth` — change `keeper_stake_script` mode or authorized_pkhs list (7d timelock)
- `AddTreasurySpend` / `UpdateTreasuryParams` — treasury operations (7d or 14d timelock depending on action)
- `RotateSigners` — change governance signer set + threshold (30-day rotation cooldown)

---

## 6. Withdraw-Zero forwarding pattern

V1 uses the Withdraw-Zero forwarding pattern to keep the main vault UTXO at a single address while splitting redeemer logic across multiple staking validators.

**Why**: Cardano's 16 KB max-transaction-size limit caps compiled-script size for reference-script UTXOs. A single monolithic vault validator covering all user + keeper + governance flows would exceed this limit. Splitting into multiple staking validators, each addressing a coherent subset of the protocol's responsibilities, keeps each compiled script below the ceiling while preserving the single-UTXO accounting model.

**How it works**:

1. The main vault UTXO sits at the `vault_proxy` script address
2. Every transaction that touches the vault UTXO must contain a zero-withdrawal entry against one of the staking validators (`vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, `vault_gov_policy`, `vault_gov_emergency`, `vault_admin_deploy`, or `keeper_stake_script`)
3. The staking validator's redeemer carries the actual OptiVaults redeemer logic (Deposit, Compound, SupplyToLiqwid, etc.)
4. The `vault_proxy` validator performs only generic checks: Vault NFT presence, continuing-output presence, single-stake-validator-per-TX

**Benefits**:

- Each staking validator is smaller and auditable in isolation
- The set of staking validators can evolve (new staking validator added for new functionality) without redeploying the `vault_proxy` contract, **as long as the new staking credential is added to `vault_proxy`'s compile-time parameter set** — which itself requires a vault redeploy. This is a partial flexibility, not unlimited.
- The `keeper_stake_script` specifically takes advantage of this pattern: keeper authorization rules can evolve entirely within the stake validator's datum + redeemer logic, without any change to `vault_user`, `vault_keeper_hot`, `vault_batcher`, `vault_swap_ada`, `vault_protocol`, `vault_recall`, `vault_liqwid`, or `vault_proxy`.

---

## 7. External dependencies

V1 depends on three external Cardano-native protocols. None is contractually committed to OptiVaults' continued correctness; each is a trust assumption that is disclosed and mitigated but not eliminated.

### 7.1 USDCx (deposit asset)

- **Issuer**: Circle, via its xReserve crosschain reserve mechanism on Cardano (launched 2026-02)
- **Mainnet policy ID**: `1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34`
- **Asset name hex**: `5553444378` ("USDCx")
- **Vault dependency**: USDCx is the deposit-token policy; the vault's principal accounting is denominated in USDCx
- **Failure modes**: issuer insolvency / reserve event / sanction freeze → vault USDCx balance affected identically to any other holder
- **OptiVaults mitigation**: none at contract level; disclosed in whitepaper §1.2.5

### 7.2 Liqwid Finance (primary yield source)

- **Integration mode**: direct action-validator path for qToken mint/burn (V1 does not interact with Liqwid's borrow-side batcher)
- **Markets used**: DJED, USDM
- **Vault dependency**: `SupplyToLiqwid` mints qTokens at Liqwid action validator addresses; `RecallFromLiqwid` burns them. `strategy_allocations` and `liqwid_positions` track supplied vs held amounts.
- **Failure modes**: Liqwid protocol exploit / bad debt / market sunset / action-validator migration → qTokens may become non-redeemable at face value
- **OptiVaults mitigation**: 35% idle buffer as first-order liquidity insulation; `EmergencyWithdraw` governance write-off path for bad-debt scenarios; `AdminDeployNonDeposit` Minswap V2 recovery path independent of Liqwid; per-market `LiqwidPosition` isolation. Full analysis in `docs/security-model.md`.

### 7.3 Minswap V2 (DEX routing)

- **Integration mode**: V1 submits swap orders to whitelisted Minswap V2 pools; Minswap's batcher processes them; fills return to the vault address as orphan UTXOs that keeper consolidates via MergeUtxo
- **Pools used**: USDCx/DJED, USDCx/USDM direct pools; 3-hop routes via NIGHT hub when direct pool impact exceeds 2%
- **Vault dependency**: swap-result UTXOs at the vault address are merged by keeper and credited to `non_deposit_value` according to the amount received (1:1 token-unit accounting, not oracle-derived)
- **Failure modes**: Minswap V2 protocol bug / batcher downtime / stuck orders → swap legs may fail
- **OptiVaults mitigation**: keeper's off-chain swap engine enforces minReceive floor + max impact cap; failed swaps are refundable via Minswap V2's own cancel mechanism; `registry.protocol_hashes` whitelist prevents routing to attacker-controlled pools

---

## 7.5 Vault ADA lifecycle

The vault UTXO carries ADA for two concurrent purposes:

1. **Min-UTXO** (Cardano protocol requirement): the UTXO must hold enough lovelace to cover its own serialised output size + number of tokens. The 29-field VaultDatum serialises to approximately 400–600 bytes depending on `strategy_allocations` + `liqwid_positions` list lengths and current numeric values; combined with 2 tokens (Vault NFT + USDCx), min-UTXO sits in the 2.5–3.5 ADA range. Operators should treat this as approximate — measured exactly per deployment via Cardano protocol parameters.
2. **DEX-order operational buffer**: `DeployToProtocol` submits a Minswap V2 order carrying ~4 ADA (batcher fee + order min-UTXO). That ADA comes out of the vault's own lovelace balance. Each order eats ~4 ADA from the vault; on fill, Minswap's batcher consumes ~2 ADA as fee and the vault receives ~2 ADA back net, so each swap cycle has a net **~2 ADA loss** from vault lovelace to Minswap infrastructure.

### 7.5.1 Contract-enforced bounds (`max_deploy_ada`, `min_vault_ada`)

`vault_protocol.ak::DeployToProtocol` enforces two compile-time parameters that bound the vault-ADA decrement:

| Parameter | V1 launch value | Semantics |
|-----------|-----------------|-----------|
| `max_deploy_ada` | 5 ADA | Per-TX cap on lovelace decrease from vault |
| `min_vault_ada` | 10 ADA | Floor below which `DeployToProtocol` is rejected |

The validator check in `DeployToProtocol` is:

```aiken
out_ada >= own_lovelace - max_deploy_ada  -- cap per-TX spend
  && out_ada <= own_lovelace             -- cannot increase ADA via this redeemer
  && out_ada >= min_vault_ada            -- never drain below floor
```

Together these ensure:
- A compromised keeper cannot drain all vault ADA via a rapid swap loop (per-TX cap).
- An operational error that attempts to deploy when vault ADA is already low is rejected before it can leave the vault stuck below Cardano min-UTXO (floor).
- ADA cannot be injected into the vault mid-swap to mask accounting (ADA upper bound is `own_lovelace`).

### 7.5.2 SwapAda closed-loop replenishment

Vault ADA depletes over time because every `DeployToProtocol` TX contributes ~2 ADA net to Minswap V2 batcher fees (§7.5 above). Without a replenishment mechanism the vault would eventually hit `min_vault_ada` and block all further Deploy TXs until an operator manually top-ups — a liveness risk and an operational chore.

V1 closes this loop on-chain via the `SwapAda` redeemer (full spec: `spec/ada-swap.md`). Mechanics:

1. **Trigger condition** — keeper invokes `SwapAda` only when `vault.lovelace < ada_swap_threshold` (15 ADA compile-time constant).
2. **Atomic barter** — keeper contributes `amount_ada` (range 10–50 ADA, compile-time bounded) to the vault. The vault sends back equivalent USDCx at a reference oracle rate (Charli3 + Orcfax consensus, validator reads `ada_price_oracle_source` reference inputs).
3. **Cooldown + width cap** — `ada_swap_cooldown_ms = 1 h` between SwapAda TXs; `tx.validity_range.upper - now <= 1 h` (internal-verification width-cap pattern), preventing stale-oracle exploitation.
4. **Accounting invariants** — vault's `own_lovelace` increases by exactly `amount_ada`; vault's USDCx balance decreases by `amount_ada × ada_price_bps / 10^7`; `total_deposited` unchanged (swap does not alter vault TVL, only asset composition).
5. **`last_ada_swap_time` datum field** — updated on each SwapAda; included in the 1-hour-width-cap invariant (`vault-datum.md` §3 item 11).

**Economic framing.** A depositor's USDCx principal pays for DEX-order operational overhead through this mechanism — slowly, at Cardano-native cost, without an additional custody layer or fee. At 100K TVL with ~1 SwapAda per 2–4 weeks carrying 20–40 ADA (≈10–20 USDCx at current ADA price), the haircut is ~20 USDCx/year = 0.02% APY drag, negligible against 4–6% gross yield.

**Why not operator-funded top-up.** Operator top-up introduces a trust dependency (keeper must remember + have ADA + sign) and an incentive problem (why would a keeper donate ADA to the vault it operates?). SwapAda converts this into an on-chain, oracle-verified, cooldown-rate-limited atomic operation with no trust premise beyond the oracle feed — which the whole system already depends on for depeg monitoring.

**Why only ADA-in / USDCx-out (no reverse direction).** A reverse `WithdrawAda` redeemer (vault receives ADA, sends out USDCx-equivalent) was considered and rejected: keepers have no incentive to pull ADA out (they pay network fees in ADA), and the feature would add attack surface (keeper grinds oracle timing + extracts vault USDCx at a favorable rate) without closing any liveness gap.

### 7.5.3 Sunset / migration recovery

When the vault sunsets (`total_shares == 0`, full-drain Withdraw), the `nft_burned` requirement (see `spec/vault-nft.md`) destroys the Vault NFT and the vault UTXO's full lovelace balance flows to the withdrawing party. There is no residual lockup of vault ADA in V1 — the PlutusV3 UTXO-ref NFT policy ensures burn is always available.

(Contrast: the internal-verification-phase native-script NFT had a `before(slot)` deadline that blocked burn after expiry, leaving ~15–20 ADA per vault permanently stranded at sunset. That trap is closed in V1.)

### 7.5.4 Deploy-time ADA sizing guidance

Operators deploying V1 should seed the vault UTXO with **min_vault_ada + 5–10 ADA headroom ≈ 15–20 ADA** at deploy time:
- Enough for 2–3 concurrent Minswap orders without hitting the `min_vault_ada` floor (the operationally-observed bottleneck for swap-throughput cycles)
- Not so large that a hypothetical validator-level accounting bug could leak non-trivial ADA into a stuck state

V1 mainnet may exhibit different deploy-time ADA requirements than the seeded estimate — operators should monitor `vault.lovelace` for the first 30 days post-launch and adjust seed sizing via `MergeUtxo` (NoDatum ADA donation, then keeper folds in) if observed throughput patterns demand more headroom.

---

## 8. What V1 deliberately does not include

Several capabilities were considered for V1 and deliberately deferred:

- **Additional on-chain oracle integrations** — V1 consumes Charli3 + Orcfax + Minswap V2 TWAP for depeg monitoring at the keeper level (Cardano-native, 15-min sustained deviation). Further validator-level oracle reads (e.g., direct on-chain price feed integration into Deposit invariants) are deferred; the current pattern keeps the oracle dependency out of the vault validator's hot path
- **Multi-key keeper native-minting authorization** — V1 uses the stake-validator mode-flag approach which is strictly more flexible; separate multi-key authorization would be redundant
- **Permissionless BatchProcess** — V1 keeps BatchProcess license-gated; V2 may open it depending on actual Liqwid batcher precedent experience with user-tip incentive alignment
- **Multi-vault support** — a single vault at launch; multi-vault architecture (multiple deposit tokens, different risk profiles) is a post-V1 candidate once single-vault sustainability is proven
- **Governance token** — V1 uses PKH-based m-of-n multisig for governance; no protocol token, no token emissions, no yield-farming incentives. Token design is a standalone decision that may or may not fit V2/V3 direction
- **Slashing for misbehaving keepers** — V1 uses governance-revocation (remove from authorized_pkhs list); bonded slashing is overkill at current TVL tier and adds implementation complexity
- **Cross-chain** — V1 is Cardano-only

---

## 9. Reference to companion documents

- `spec/vault-datum.md` — exact VaultDatum field definitions, immutability classification, per-redeemer transition rules
- `spec/treasury.md` — TreasuryDatum, category math, spend redeemer rules, audit reserve lock mechanism
- `spec/keeper-auth.md` — keeper_stake_script modes, authorization logic, mode-switch flow
- `spec/order-batch.md` — OrderDatum, Process redeemer, user-tip mechanics, Expire semantics
- `spec/governance.md` — MultisigGov actions catalog, timelock rules, cancel/rotate flows
- `docs/economics.md` — fee structure, treasury flow math, sustainability thresholds
- `docs/security-model.md` — full threat model, trust boundaries, residual-risk disclosures
- `docs/migration.md` — transition plan for existing internal-verification phase depositors
- `docs/audit-scope.md` — pre-launch audit plan + Q2-Q3 2027 external audit scope
- `whitepaper/whitepaper.md` — V1 public whitepaper (summary of all of the above for non-developer audience)
