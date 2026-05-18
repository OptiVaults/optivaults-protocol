# SwapAdapter interface — V1 multi-DEX extension point

**Status:** V1 ships two DEX adapters — `minswap_v2_adapter` and the SundaeSwap pair (`sundaeswap_adapter` plus its companion `sundaeswap_cancel_guard`) — both bound at the deploy ceremony (see §8). Beyond those, further DEX adapters can be deployed + whitelisted post-launch via governance `UpdateRegistry` (14-day timelock + 1-of-n cancel) **without redeploying V1 or forcing depositor migration**.

## 1. Motivation

V1's DEX-swap path (`vault_protocol.DeployToProtocol` and its governance-gated cousin `vault_gov_emergency.AdminDeployNonDeposit`) must decode the destination DEX's order datum to enforce a trustless peg-floor on `minimum_receive`. Different DEXes use different datum formats (Minswap V2 uses a Constr-tagged `OrderDatum` + `OrderStep` pattern; SundaeSwap V3 + Stableswaps use a shared `OrderDatum` + `Order::Swap` structure). Hard-coding all DEX decoders into `vault_protocol` creates two problems:

1. **Audit surface bloat** — every DEX integration would require re-auditing the entire `vault_protocol` validator.
2. **Migration pressure** — adding a new DEX post-launch would force a V1.x redeploy + depositor migration (burn old vUSDCx, deposit into new vault), cost of $50K-$80K + several months + 5-15% stranded funds per migration event in historical DeFi experience.

The SwapAdapter pattern decouples DEX datum parsing into per-DEX validators dispatched at runtime, with governance controlling the whitelist.

## 2. Architecture

```
┌───────────────────────────────────┐
│ vault_protocol.DeployToProtocol   │
│ (or vault_gov_emergency.          │
│  AdminDeployNonDeposit)           │
└────────────┬──────────────────────┘
             │  verify_swap_via_adapter(
             │    tx,
             │    registry.swap_adapter_hashes,
             │    registry.asset_oracles,
             │    ...
             │  )
             ▼
┌───────────────────────────────────┐
│ lib/vault/swap_adapter.ak         │
│  1. find_single_adapter_invocation│
│  2. read_adapter_redeemer         │
│  3. check_peg_floor               │
│  4. check_tier1_bound (optional)  │
└────────────┬──────────────────────┘
             │  via zero-withdrawal
             ▼
┌───────────────────────────────────┐
│ minswap_v2_adapter (Plutus V3)    │
│                                    │
│  withdraw(r: SwapAdapterRedeemer,  │
│           _: Credential,           │
│           tx: Transaction) {       │
│    1. Decode tx.outputs[r.idx]     │
│       as Minswap V2 order datum    │
│    2. Verify r.min_receive         │
│       == decoded minimum_receive   │
│    3. Verify r.target_asset        │
│       == decoded output asset      │
│  }                                 │
└───────────────────────────────────┘
```

## 3. SwapAdapterRedeemer

Defined in `lib/vault/swap_adapter.ak`:

```aiken
pub type SwapAdapterRedeemer {
  dest_output_idx: Int,
  min_receive: Int,
  hop_chain: List<(ByteArray, ByteArray)>,
}
```

- `dest_output_idx` — index into `tx.outputs` of the DEX order UTXO this adapter is validating.
- `min_receive` — the adapter-committed `minimum_receive` field from the order datum; vault_protocol applies peg-floor on this.
- `hop_chain` — the asset sequence the swap traverses: `[asset_in, mid_1, ..., target_out]`. A single-hop SwapExactIn has 2 entries (`[in, out]`); an N-hop SwapMultiRouting has N+1 entries, one per pool boundary. Each entry is `(policy_id, asset_name)`; ADA is `(#"", #"")`. The target asset (what the swap produces) is `hop_chain[last]`; `vault_protocol` exposes it for `asset_oracles` Tier 1 lookup via the `last_hop_target` helper.

**Why hop_chain instead of target_asset**: Minswap V2's order-datum `lp_asset` is a single LP-token identifier (`[LP_policy, LP_name]`), not a 2-asset pair. The target asset cannot be derived from the order datum alone. The adapter verifies each routing hop's on-chain LP name byte-for-byte against `compute_lp_asset_name(chain[i], chain[i+1])` — binding the routing topology and endpoint asset to the committed chain. A compromised keeper cannot route to an arbitrary non-whitelisted pool because the LP name would not match. The internal-audit history of this design choice is summarised in the project SECURITY.md "Known open findings" section.

## 4. Adapter contract

A SwapAdapter is a PlutusV3 staking validator with one `withdraw` handler. When invoked:

1. It reads `tx.outputs[redeemer.dest_output_idx]`.
2. It decodes that output's inline datum using its DEX-specific format knowledge.
3. It verifies:
   - The datum represents a **swap** order (not LP deposit, withdraw, etc.).
   - The decoded `minimum_receive` equals `redeemer.min_receive`.
   - `redeemer.hop_chain` is well-formed (≥ 2 entries, no adjacent duplicates).
   - For each routing hop (SwapMultiRouting) or the single SwapExactIn `lp_asset`, the on-chain LP name matches `compute_lp_asset_name(chain[i], chain[i+1])` where `compute_lp_asset_name` is the DEX's canonical LP-asset-name formula.
4. It returns `True` iff all checks pass.

If any check fails the ledger runs the adapter's `withdraw → False`, the TX reverts, and vault_protocol never sees an adapter success.

## 5. Caller contract (vault_protocol + vault_gov_emergency)

Single helper call consolidates the verification:

```aiken
verify_swap_via_adapter(
  tx,
  adapter_hashes,       // from registry.swap_adapter_hashes
  asset_oracles,        // from registry.asset_oracles
  expected_dest_idx,    // from caller's own redeemer (DeployToProtocol / AdminDeployNonDeposit)
  deploy_amount,
  min_swap_peg_bps,     // from VaultDatum
  max_slippage_bps,     // from VaultDatum
) -> Bool
```

Internally it:

1. Scans `tx.withdrawals` for exactly one zero-amount withdrawal whose script hash is in `adapter_hashes`. Multiple adapter invocations in the same TX are rejected (anti-double-routing).
2. Reads that adapter's redeemer via `pairs.get_first(tx.redeemers, Withdraw(Script(adapter_hash)))`.
3. Verifies `redeemer.dest_output_idx == expected_dest_idx` (anti-confusion between concurrent DEX outputs).
4. **Tier 2 peg-floor** (always applied): `redeemer.min_receive × 10_000 ≥ deploy_amount × min_swap_peg_bps`. Since the adapter has already verified `min_receive` matches the on-chain DEX datum, this bound is trustless.
5. **Tier 1 oracle bound** (applied iff `asset_oracles` has an entry for `(target_asset_policy, target_asset_name)`): `redeemer.min_receive ≥ fair_out × (10_000 − max_slippage_bps) / 10_000` where `fair_out = deploy_amount × oracle_fair_price_bps / 10_000`. At V1 launch `asset_oracles = []` so Tier 1 is dormant until governance populates per-asset oracle configs.

## 6. Registry whitelist

`RegistryDatum.swap_adapter_hashes: List<ByteArray>` holds the authorized adapter script hashes.

- **Cap**: 10 adapter entries (see `registry.ak`).
- **Format**: each entry is exactly 28 bytes (Plutus V3 script hash length).
- **Uniqueness**: no duplicate hashes.
- **Update path**: `UpdateRegistry` redeemer with 14-day timelock + 1-of-n cancel veto. Preserved bit-for-bit in `KeeperToggleMarket` + `FastUpdateMarkets`.

V1 launches with the `minswap_v2_adapter` script hash (computed at deploy time from `plutus.json`); a SundaeSwap-enabled ceremony seeds the `sundaeswap_adapter` hash at init as well (§8.3). Further adapters are appended post-launch via §7.

## 7. Adding a new DEX adapter (post-launch lifecycle)

1. **Develop** a new `*_adapter.ak` validator conforming to the adapter contract (§4).
2. **Audit** the adapter in isolation — the caller (`vault_protocol`) has no knowledge of the DEX's internals, so the audit scope is only the adapter's datum decoder + assertions. Cost estimate: $10K-$20K per DEX.
3. **Preprod E2E**: submit a real order on Preprod's instance of the target DEX + verify the adapter decodes correctly + peg-floor rejects malicious `minimum_receive` attempts.
4. **Deploy** the audited adapter's reference script to mainnet (Cardano stake script deposit: 2 ADA + per-byte ref-script min-ADA ≈ 25-40 ADA depending on adapter size).
5. **Governance queue**: submit `UpdateRegistry` with `new_reg.swap_adapter_hashes = reg.swap_adapter_hashes ++ [new_adapter_hash]`. This triggers a 14-day timelock.
6. **Observation window**: community + any 1 of the n governance signers can cancel the queued action during the timelock. Any depositor who disapproves of the new adapter can exit in the 14-day window.
7. **Governance execute**: after timelock, the registry UTXO is updated and the new adapter becomes active. Keepers can now route through it; the V1 vault address and existing vUSDCx holdings are unchanged.

## 8. SundaeSwap — the bundled second adapter

V1 ships a second SwapAdapter for **SundaeSwap V3 + Stableswaps**, bound at the deploy ceremony rather than added post-launch. The V1 deploy ceremony folds it in via a `sundaeswap` block in the ceremony config, so it is part of every V1 launch deploy: V1's canonical artefact count is **24** (the two artefacts below included) and its reference-script count is 20. (A deployment that omits the `sundaeswap` config block would be 22 artefacts / 18 reference scripts, but that is not V1's canonical configuration.)

### 8.1 Why a second DEX

`vault_protocol.DeployToProtocol` routes the vault's USDCx ↔ DJED/USDM swaps through a SwapAdapter. A second adapter buys two things:

- **Lower stablecoin slippage.** V1 swaps like-assets (USDCx ↔ DJED/USDM). A stableswap-curve AMM cuts the constant-product slippage of a generic pool to a fraction of a percent. SundaeSwap's `USDCx/USDM` Stableswaps pool is the deepest like-asset venue available to V1.
- **Liveness backstop.** If the Minswap V2 batcher stalls, the keeper can route the same swap through SundaeSwap.

SundaeSwap is a **USDM-leg DEX** for V1: it has deep `USDCx/USDM` stableswap liquidity but no usable DJED liquidity, so the keeper routes USDM swaps through SundaeSwap and keeps the DJED leg on Minswap V2.

### 8.2 Two artefacts

| Artefact | Type | Role |
|---|---|---|
| `sundaeswap_adapter` | SwapAdapter (staking validator) | Decodes a SundaeSwap order datum + verifies the redeemer-committed `min_receive` and routing against the on-chain order. Conforms to the adapter contract of §4. |
| `sundaeswap_cancel_guard` | Staking validator | Owns un-filled SundaeSwap orders; makes their `Cancel` drain-proof. |

**`sundaeswap_adapter`** is structurally simpler than `minswap_v2_adapter`. SundaeSwap's order datum carries both swap assets explicitly — `Order::Swap { offer, min_received }`, each a `(policy_id, asset_name, amount)` triple — so the adapter compares `hop_chain[0]` against `offer` and `hop_chain[last]` against `min_received` directly. There is no LP-name rehash (the machinery `minswap_v2_adapter` needs because Minswap's order datum carries only an LP-token identifier from which the target asset cannot be derived). One adapter handles both SundaeSwap V3 (constant-product) and Stableswaps pools — the two share a byte-identical swap order datum; the pool-type difference lives in the pool datum, which the adapter never reads.

**`sundaeswap_cancel_guard`** exists because of how SundaeSwap authorises cancellation. A SundaeSwap order's `OrderRedeemer::Cancel` is authorised by the order datum's `owner` field (a `MultisigScript`). If `owner` were a plain keeper key, a compromised keeper could cancel a vault-funded order and pocket the refund. V1 instead sets `owner` to the `sundaeswap_cancel_guard` script. Every cancel of a guard-owned order must then satisfy the guard's `verify_cancel_value_conservation` check: the **net** value leaving the vault address (outputs at the vault minus inputs from the vault) must return the full order value to the vault address. The keeper can cancel a stuck order, but cannot redirect a single lovelace of it.

Minswap V2 needs no equivalent guard — its order datum pins the refund destination directly, so a Minswap cancel can only refund to the address baked into the order at creation.

### 8.3 Binding modes

A SundaeSwap-enabled V1 reaches the same end state — `sundaeswap_adapter` in `swap_adapter_hashes` and the SundaeSwap `order.spend` hashes in `protocol_hashes` — by either of two paths:

- **(a) Init-binding.** The deploy ceremony, seeing the `sundaeswap` config block, resolves the adapter pair into the hash DAG (`vault_proxy → sundaeswap_cancel_guard → sundaeswap_adapter`), publishes their reference scripts, and seeds the Registry at init with both the adapter hash (in `swap_adapter_hashes`) and the SundaeSwap V3 + Stableswaps `order.spend` hashes (in `protocol_hashes`, the `DeployToProtocol` destination whitelist). This is how a SundaeSwap-enabled V1 launches.
- **(b) Governance add-path.** The post-launch lifecycle of §7 — an `UpdateRegistry` action (14-day timelock + 1-of-n cancel) appends the adapter hash and the order hashes to the live Registry. This is the path for a 3rd or 4th DEX adapter, and the fallback if a launch ceremony omitted the `sundaeswap` block.

Both the adapter hash **and** the SundaeSwap `order.spend` hashes must be whitelisted for a SundaeSwap swap to route — `swap_adapter_hashes` authorises the adapter, `protocol_hashes` authorises the order address that `DeployToProtocol` sends value to. Seeding only the adapter leaves SundaeSwap routing inert until `protocol_hashes` is updated too.

### 8.4 Cancel-guard parameterization

`sundaeswap_cancel_guard` is parameterized at compile time on the set of SundaeSwap `order.spend` hashes it protects. Two consequences:

- The guard's `verify_cancel_value_conservation` is **fail-closed** on an empty protected set — a guard compiled with no order hashes rejects every cancel rather than vacuously accepting it. A mis-parameterized guard never silently degrades into an unconstrained one.
- The protected hash set is network-specific. The keeper resolves it from operator config and fails loud on mainnet if it is unset, so the guard is never deployed against the wrong hashes.

The conservation check cannot be satisfied by co-spending and recreating the vault UTXO in the same cancel TX: it measures the **net** flow (vault outputs minus vault inputs), so the vault's own balance cannot be counted toward the returned order value.

## 9. Security properties

**What adapter governance can NOT do**:

- Bypass the Tier 2 peg-floor — `verify_swap_via_adapter` always applies it on adapter-committed `min_receive`.
- Route to a script outside `registry.protocol_hashes` — `verify_destination_whitelisted` still applies independently.
- Drain vault funds to an arbitrary address — the adapter's `withdraw` handler validates the swap datum but doesn't spend vault UTXOs; all value movement happens through `vault_protocol.DeployToProtocol`'s own token-preservation checks.

**What adapter governance CAN do** (the threat model):

- Approve a malicious adapter that lies about `min_receive` — an adapter that returns `True` on any `SwapAdapterRedeemer` regardless of the actual DEX datum would bypass Tier 2. **Mitigation**: adapter source is open + on-chain audit-able via its script hash; governance signers are m-of-n with public identities; 14-day timelock + 1-of-n cancel gives depositors time to exit.
- Remove `minswap_v2_adapter` from the whitelist — would halt Minswap V2 routing. **Mitigation**: would be immediately visible; depositors can exit in the 14-day observation window; 1-of-n cancel.

## 10. Pre-mainnet verification checklist

Before mainnet deploy (tracked as part of V1 external audit scope):

- [ ] Submit real Minswap V2 `SwapExactIn` order on Preprod → `extract_minswap_v2_order` correctly decodes `minimum_receive` + target asset.
- [ ] Submit real Minswap V2 `SwapMultiRouting` order on Preprod → correct decode of last-hop target asset.
- [ ] Submit crafted order with `min_receive = 1` → `verify_swap_via_adapter` rejects via peg-floor.
- [ ] Submit two concurrent adapter invocations → `find_single_adapter_invocation` rejects (`count != 1`).
- [ ] Submit adapter invocation with unwhitelisted hash → rejected.
- [ ] Governance `UpdateRegistry` adds a mock second adapter → 14-day timelock observed → execute succeeds → second adapter invocable.
- [ ] Governance `UpdateRegistry` removes `minswap_v2_adapter` from whitelist → subsequent DeployToProtocol reverts.

## 11. Out of scope for V1

- **Automated adapter registration**. V1 requires human governance review for each new adapter. Permissionless adapter registration (anyone can deploy + immediately use) would require a more elaborate trust framework and is deferred to V2+.
- **Adapter versioning**. If Minswap V3 ships with new datum format, the operator deploys `minswap_v3_adapter` as a separate validator and governance whitelists it. Old `minswap_v2_adapter` stays listed (handles legacy V2 routes) or is removed (clean cutover). There is no in-adapter version-bump mechanism.
- **Adapter-internal cost bounds**. Each adapter sets its own compute envelope. V1 relies on ledger evaluation limits to prevent runaway execution; no cross-adapter budget enforcement.

## 12. References

- Code: `lib/vault/swap_adapter.ak`, `validators/minswap_v2_adapter.ak`, `validators/sundaeswap_adapter.ak`, `validators/sundaeswap_cancel_guard.ak`, `lib/vault/sundaeswap.ak`
- Whitepaper: §3.4 external dependencies (multi-DEX extensibility), §5.3 DEX slippage protection (Tier 2 peg-floor + Tier 1 oracle)
- Spec: `spec/architecture.md` §3.6 (Registry layout), §4 (validator catalog)
- Related: `spec/oracle.md` (Tier 1 oracle reader used by adapter callers)
