# Security Policy

## Reporting Vulnerabilities

If you discover a security vulnerability in OptiVaults smart contracts, please report it responsibly:

**Email:** optivaults@gmail.com

**Please include:**
- Description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Suggested fix (if any)

**Response timeline:**
- Acknowledgment: within 48 hours
- Initial assessment: within 1 week
- Fix deployment: depends on severity

## Scope

The following are in scope for security reports:

- Smart contract logic (`validators/vault_proxy.ak`, `validators/vault_core.ak`, `validators/vault_protocol.ak`, `validators/vault_liqwid.ak`, `validators/vault_nft.ak`, `validators/governance.ak`, `validators/vusdcx.ak`, `validators/order.ak`, `validators/registry.ak`)
- Validation logic (`lib/vault/validation.ak`, `lib/vault/helpers.ak`)
- Type definitions that affect on-chain behavior (`lib/vault/types.ak`, `lib/vault/order_types.ak`, `lib/vault/governance_types.ak`)

The following are **also in scope:**
- API server (`api/src/`)
- Frontend (`frontend/src/`)
- Keeper bot (`keeper/src/`)

The following are **out of scope:**
- Test files (`*_test.ak`, `*.test.ts`)
- Development scripts (`scripts/`)
- Social engineering attacks

## Security Model

### On-Chain Guarantees

1. **No admin drain** -- Admin operations validated on-chain; all tokens verified preserved (V3: `verify_all_tokens_preserved` checks every token in EmergencyWithdraw)
2. **Keeper/Admin separation** -- `keeper_pkh` for automated operations (compound/rebalance/batch/merge), `governance_policy/governance_name` for governance via MultisigGov (strategy/fee/emergency, m-of-n + 7d timelock)
3. **15 immutable fields + compile-time Vault NFT anchor** (V10) -- governance_policy, governance_name, keeper_pkh, fee_collector, vault_version, performance_fee_bps, early_withdraw_fee_bps, min_hold_seconds, buffer_target_bps, vusdcx_policy, deposit_token_policy, deposit_token_name, order_script_hash, registry_hash, registry_auth_policy checked on every operation (25-field VaultDatum V10). `vault_nft_policy` is a **compile-time parameter** on `vault_proxy` / `vusdcx` / `order` — physically baked into each validator's script hash at deploy time, providing a stronger trust anchor than datum-level immutability. R55 closed the self-referential phantom-vUSDCx attack path; R65 added symmetric `no_new_tokens` on Registry + EmergencyWithdraw token allowlist; R66 added soft allocation ceiling on EmergencyWithdraw.
4. **Emergency escape** -- Users can force-withdraw after 7 days of keeper inactivity
5. **Fee caps** -- Performance fee hard-capped at 4.5% (450 bps), immutable on-chain; adjustable within 0–4.5% via Governance UpdateFee with 7-day cooldown
6. **Anti-inflation** -- 1M share multiplier prevents ERC-4626 style inflation attacks
7. **Minimum deposit** -- 10 USDCx minimum prevents dust attacks
8. **Double satisfaction** -- Single vault input enforced per transaction (V3: MergeUtxo allows 2-5 with strict controls)
9. **Slippage protection** -- Order contract enforces minimum receive amounts (total value: lovelace+tokens)
10. **Allocation bounds** -- `alloc_sum + idle_buffer <= total_deposited` enforced on compound/rebalance/strategy/merge, max 10 entries
11. **Expire refund validation** -- Full order amount (total value) returned to owner
12. **Deposit exact match** -- Deposit amount validated with `==` to prevent overpayment exploits
13. **Compound cooldown** -- On-chain enforced cooldown between compound operations
14. **Compound exact value** -- Output value must increase by exactly `harvested_amount` (prevents phantom value theft)
15. **No-mint enforcement** -- All admin/keeper ops enforce `no_mint`
16. **Input validation** -- `amount > 0` and `idle_buffer >= 0` enforced on-chain
17. **Withdraw datum immutability** -- idle_buffer, strategy_allocations, last_compound_time validated immutable in Withdraw
18. **Full withdraw datum continuity** -- Full withdraw+fee validates continuing datum
19. **BatchProcess input validation** -- Requires order script inputs; order_script_hash from datum; order amounts summed on-chain
20. **Early withdrawal fee** -- Direct withdraw always 0.1% fee; batch orders free
21. **V3: MergeUtxo all-token verification** -- `flatten(total_input_value)` iterates every token; output must have `>=` each input token; prevents token theft during UTXO merge
22. **V3: MergeUtxo secondary NoDatum only** -- Secondary vault inputs must be NoDatum (blocks InlineDatum and DatumHash); prevents fake datum injection
23. **V3: EmergencyWithdraw buffer protection** -- `idle_buffer` can only increase (non-decrease enforced); `last_compound_time` immutable
24. **V3: RecallFromProtocol multi-token** -- `recall_token_policy/name` in redeemer enables DJED/USDM/USDCx recall; value check uses specified token
25. **V3: None datum gate** -- Datum-less vault inputs only allowed with MergeUtxo redeemer; all other redeemers require datum (fail with error message)
26. **Buffer-funded Compound** -- On-chain yield = `idle_buffer + non_deposit_value - total_deposited` (tamper-proof, no keeper injection); `allocs_empty` required
27. **burn_token triple validation** -- RecallFromProtocol burn_token verified: not deposit token, minted negative, decreased in output
28. **Loss compound support** -- Negative yield allowed with fee=0, prevents vault bricking on protocol losses
29. **vusdcx first deposit cap** -- 10^18 cap prevents initial mint dilution attacks
30. **on_chain_yield tamper-proof** -- Yield derived from on-chain state, not keeper-provided values
31. **NDV stable_tokens guard (R40)** -- `DeployToProtocol` and `RecallFromProtocol` only modify `non_deposit_value` for tokens in `registry.stable_tokens`; non-stable tokens (airdrops/garbage) cannot inflate or deflate NDV; `DeployToProtocol` enforces `NDV >= 0` floor to prevent negative-NDV DoS on Compound

### Test Coverage

| Category | Tests | Status |
|----------|-------|--------|
| Aiken smart contracts | 1,600 | All pass |
| Aiken property-based fuzz | 2,500 | All pass |
| Keeper vitest | 710 | All pass |
| API vitest | 131 | All pass |
| Frontend vitest | 461 | All pass |
| Preprod E2E | 19 | All pass (V10 7/7 + Vault 6/6 + Complete 6/6; vault_liqwid split + bounded ADA spend + Buffer-funded Compound verified on-chain) |
| **Total** | **5,267+** | **All pass** |

- Comprehensive automated test coverage
- 71 internal audit rounds, 268+ fixes, findings addressed, Q3 2026 third-party audit pending
- Preprod E2E: V10 full flow verified — 19/19 on-chain (7 V10-specific + 6 Vault core + 6 Complete; DeployToProtocol bounded ADA spend + UseLiqwid route + KeeperToggleMarket + FastUpdateMarkets + Buffer-funded Compound)
- 170+ tests covering MergeUtxo, multi-token Recall, EmergencyWithdraw token protection, None datum branch, boundary cases, vulnerability attacks
- Buffer-funded Compound, burn_token validation, loss compound, relaxed MergeUtxo bounds
- V9 MultisigGov governance, Withdraw-Zero pattern, stable_tokens NDV guard

## Security Audit Summary

Comprehensive automated test suite covering all components.

| Round | Scope | Fixes | Severity |
|-------|-------|-------|----------|
| 1-3 | Contract core | 19 | Deposit exact match, token preservation, mint/burn ratio |
| 4 | Frontend | 3 | Blind signing, slippage, CBOR handling |
| 5 | API + Keeper | 20 | JWT, CORS, key management, arithmetic precision |
| 6 | Contract + integration | 15 | Compound fee, batch burn, fair exchange pricing |
| 7 | ProtocolRegistry + datum | 8 | Registry whitelist, 18-field datum |
| 8-9 | Full withdraw + hardening | 15+ | Empty allocation, edge cases, E2E |
| 10 | V3: MergeUtxo + security | 10+ | Token drain, DatumHash injection, None datum bypass |
| 11-15 | V3 hardening + E2E | 20+ | Extended validation, Preprod E2E |
| 16 | Full re-audit | 12 | Non-deposit token theft (C-1/C-2), registry auth (H-1), mint bounds (H-2) |
| 17 | Security hardening | 9 | no_order_inputs (C-1), recall source (C-2), NDV/frozen (H-2~H-4) |
| 18-19 | Contract fixes + alignment | 11 | Full-drain NDV block (M-1), withdraw rounding, whitepaper-code sync |
| 20 | Verification audit | 0 | All R17-R19 fixes verified, 0 CRITICAL/HIGH/MEDIUM |
| 21 | Deep security audit | 5 | BatchProcess buffer floor (C-01), admin recall fallback (H-01), keeper token filter (H-02) |
| 22-25 | Contract hardening | 5+ | Additional validation, edge case fixes, +33 tests |
| 27 | Fee protection | 1 | Max fee 20%→10%, 7-day UpdateFee cooldown |
| 28 | V4 refactor audit | 0 | 0 CRITICAL, shared helpers refactor verified |
| 29-34 | V7 design + regression | ~20 | Buffer-funded compound, R34 regression tests |
| 36 (×4) | V8.1 split | 36 | Order injection (H-1), qToken (H-2), min_hold (H-3), token bloat (H-4) |
| 37-38 | V9 MultisigGov | 49 | Datum spoofing, governance checks, double satisfaction, token preservation |
| 39 | Full V9 production audit | 0 | 0 CRITICAL / 0 HIGH / 2 MEDIUM (not exploitable) |
| 40 | Defense-in-depth | 2 | NDV stable_tokens guard for Deploy/Recall + NDV >= 0 floor |
| 41 | Proxy + Liqwid hardening | 3 | Proxy vusdcx_policy defense, RecallFromLiqwid governance partial, EmergencyWithdraw position clear |
| 42 | Final hardening | 3 | Subset invariant, governance loss accounting, Cancel order_input_count |
| 43 | Full V9 re-audit + C-1 | 1 | R43 C-1 CRITICAL fake VaultDatum injection fix; 2 LOW + 4 INFO |
| 44 | Hacker-perspective audit | 0 | 10 attack paths analyzed, all blocked; 0 CRIT/HIGH/MED |
| 45 | Phantom vault + Vault NFT | 2 | R45 C-1 CRITICAL phantom vUSDCx (Vault NFT one-shot), M-1 NFT continuing output |
| 46 | Vault NFT preservation | 1 | Registry auth NFT preservation on UpdateRegistry |
| 47 | Full 24-redeemer matrix | 0 | 24 redeemers × 10 checks = 240 items verified; 0 CRIT/HIGH/MED |
| 48 | Withdraw anti-double-sat | 1 | M-1 receiver_output_idx hard binding (fixes list.any ambiguity) |
| 49 | Hacker-perspective deep audit | 2 | M-4 early withdraw fee drift (vault_core), L-6 governance emergency+empty_hash bypass |
| 50 | Adversarial R49 re-audit | 0 | R49 M-4 / L-6 regression-checked; empty-hash delegation path documented as design trade-off |
| 51 | External audit verification | 2 | **C-1 HIGH** vault_core BatchProcess `no_vusdcx_leak` (multi-order same-user vUSDCx diversion); H-1/M-3 governance signer floor `signers >= 3` (defense-in-depth vs misconfigured 2-of-2) |
| 52-54 | Corner-case sweep + hardening | 30+ | MergeUtxo token allowlist, NDV floors, gov-path orphan guards, reference-input NFT gate, payout uniqueness, exact mint/burn ratios |
| 55 | Compile-time Vault NFT anchor | 1 | **C-1 CRITICAL** phantom vUSDCx via self-referential datum NFT field → `vault_nft_policy` moved to compile-time parameter on `vault_proxy` / `vusdcx` / `order` |
| 56-58 | Deep sweeps + size optimization | 10+ | MergeUtxo whitelist, NDV ≥ 0, Order.Expire full-value, Withdraw full-drain NFT burn, `no_new_tokens` on helpers, Compound/UpdateFee validity-range width cap |
| 59-61 | Clean rounds + methodology | 3 INFO | Constant-delay cross-validator grep symmetry, invariant transitivity (RecallFromLiqwid gov-path liveness guards), value-flow conservation + boundary-value fuzzing |
| 62 | Property-based foundation | 0 | `aiken/fuzz` v2.2.0 + `property_fuzz_test.ak` + `property_fuzz_extended_test.ak` (25 properties × 100 iterations = 2,500 randomized checks) |
| 63 | Off-chain runtime audit | 10 | API/keeper R55 `vault_nft_policy` env param, `/submit-tx` auth, awaitTx-before-cooldown, Blockfrost key rotation, LRU cache cap, cooldown persistence, opti-gov empty-hash warning, frozen field index |
| 64 | Deploy pipeline audit | 10 | `RELEASE_TAG` gate, mixed-asset change bundling, per-script flushState, NFT deadline extensions, legacy filename primary-with-fallback, `placeholderHash` 56-hex, deprecation READMEs |
| 65 | R64-c follow-up batch | 3 | **N-1 MEDIUM** EmergencyWithdraw secondary allowlist (symmetric MergeUtxo R56 M-1); **N-2 LOW** Order.Expire full-value refund (MEV skim closure); **N-3 LOW** Registry `no_new_tokens` (symmetric R57 F-1) |
| 66 | R64-a L-2 + audit complete | 1 | **L-2 LOW** EmergencyWithdraw soft alloc ceiling (`alloc_sum + idle_buffer ≤ TD + NDV + liqwid_principal`) preventing governance mis-configuration soft-brick |
| 67 | V10 registry deadlock + keeper runbook | 2 | V10 deploy script keeper_pkh field backfill; keeper-outage-recovery runbook + V10 gov-fallback CLI skeletons |
| 68 | V10 Mainnet GO-LIVE | 0 | Task C gov-fallback Preprod E2E; V10-R71 mainnet ceremony 15 TX; role-separated 6 identities |
| 69-70 | Keeper self-healing + Settlement tier | 0 | 4-step auto-recovery chain (buffer-shortage → Recall → reverse swap → NDV consolidation); 4-tier TVL settlement schedule; 3-hop USDCx↔DJED via NIGHT route |
| 71 | V10 deploy pipeline audit | 3 | **M-1 MEDIUM** Registry `keeper_pkh` immutability on UpdateRegistry; **L-1 LOW** DeployToProtocol 10-USDCx minimum per-TX floor (anti-dust); **L-2 LOW** Registry KeeperToggleMarket no-op rejection |
| **Total** | **All components** | **268+** | |

Full audit details in `docs/audit-report.md`.

## Audit Status

- Comprehensive automated test suite
- 1,600 Aiken unit + 2,500 property-based fuzz + 607 keeper + 113 API + 428 frontend + 19 Preprod E2E = 5,267+ regression checks
- 71 audit rounds, 268+ fixes
- Internal findings addressed; **Q3 2026 third-party audit pending** (pre-audit 100K USDCx TVL cap enforced until external review completes)
- Community audit: contributions welcome

## Design Decisions (Documented)

The following items have been raised in audits and are confirmed as intentional design choices:

**"Immutable field" semantics:** When the audit reports and documentation refer to "15 immutable fields," this means the **datum field reference** cannot be altered by any redeemer — the field must remain present with the same type and meaning across every vault state transition. For most fields, this also means the **value** itself never changes after deployment (e.g., `keeper_pkh`, `fee_collector`, `deposit_token_policy`). One field is a deliberate exception: `performance_fee_bps` is an immutable field whose value can be adjusted within 0–4.5% by Governance via the two-step `UpdateFee` flow (m-of-n Queue → 7-day timelock → 1-of-n Execute, with 7-day cooldown between updates). The 4.5% hard cap itself is enforced on-chain and cannot be exceeded under any circumstance. In V10, the 16th anchor (`vault_nft_policy`) is no longer a datum field — it is a **compile-time parameter** baked into the `vault_proxy` / `vusdcx` / `order` validator script hashes (R55 C-1), which is a strictly stronger trust anchor than datum-level immutability. See whitepaper §3.2 and `contracts/docs/vault-state-machine.md` §4.7.

**Withdraw allowed during Emergency Freeze (R40 F-1):** The `Withdraw` redeemer intentionally does not check `frozen == 0`. This is a core design principle: user funds are never locked, regardless of vault state. The `frozen` flag blocks operational actions (Compound, BatchProcess, RebalanceBuffer, DeployToProtocol, SupplyToLiqwid) that could compound incorrect accounting, while Withdraw, Recall, and MergeUtxo remain available for fund recovery. The `idle_buffer >= base_withdraw` constraint naturally prevents over-withdrawal. Confirmed in R37, R37-a, R39 audits.

**BatchProcess zero-share edge case (R40 F-4):** When `total_shares > 0 && total_deposited == 0`, BatchProcess mints 0 shares. This state requires 100% fund loss — the vault is worthless and 0-share mint is the correct behavior. Under normal operation, `total_deposited > 0` ensures positive share calculations.

**Governance empty-hash delegation (R40 C-1 / R50 documented):** The `QueueAction` empty `target_tx_hash` path allows m-of-n governance to pre-authorize a VaultAdmin/RegistryAdmin capability that any 1-of-n signer can execute after a 14-day minimum timelock. This exists because `target_tx_hash` has an unavoidable circular dependency on the governance UTXO reference (tx.id depends on the queued datum which contains target_tx_hash). On-chain defenses retained during the execution window: `CancelAction` (1-of-n veto), `action_ttl_ms` 37-day absolute cap, `GovNFT == 1`, target script must be a spent input, ADA preservation, and all 16 immutable VaultDatum fields. **Off-chain operator obligations:** empty-hash `QueueAction` must be publicly broadcast within 1 hour, ≥1 honest signer must monitor the queue for 14–30 days and use `CancelAction` on any anomaly, and the signer set must include ≥2 non-colluding parties with independent monitoring. Prefer explicit `target_tx_hash` whenever the TX body can be pre-computed. Confirmed in R40, R49, R50 audits.

**Garbage token dust in vault UTXO (R40 F-5):** Airdropped garbage tokens absorbed by MergeUtxo with `NDV = 0` cannot be removed via AdminDeployNonDeposit. This is accepted: garbage tokens are inert dust. Full drain destroys the vault UTXO entirely, releasing all tokens.

## Bug Bounty

We plan to launch a formal bug bounty program before mainnet. In the meantime, responsible disclosures will be acknowledged and credited.
