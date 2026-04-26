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

- Smart contract logic (`validators/vault_proxy.ak`, `validators/vault_core.ak`, `validators/vault_protocol.ak`, `validators/vault_liqwid.ak`, `validators/governance.ak`, `validators/vusdcx.ak`, `validators/order.ak`, `validators/registry.ak`)
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

1. **No admin drain** -- Admin operations validated on-chain; all tokens verified preserved (`verify_all_tokens_preserved` checks every token in EmergencyWithdraw)
2. **Keeper/Admin separation** -- `keeper_pkh` for automated operations (compound/rebalance/batch/merge), `governance_policy/governance_name` for governance via MultisigGov (strategy/fee/emergency, m-of-n + 7d timelock)
3. **15 immutable fields** (V10-R71) -- governance_policy, governance_name, keeper_pkh, fee_collector, vault_version, performance_fee_bps, early_withdraw_fee_bps, min_hold_seconds, buffer_target_bps, vusdcx_policy, deposit_token_policy, deposit_token_name, order_script_hash, registry_hash, registry_auth_policy -- checked on every operation (25-field VaultDatum V10-R71). R65 added symmetric `no_new_tokens` on Registry UpdateRegistry + EmergencyWithdraw secondary allowlist; R66 added soft allocation ceiling (`alloc_sum + idle_buffer <= total_deposited + NDV + Σ liqwid_principal`) preventing governance mis-configuration from soft-bricking the vault. **R71** pinned `keeper_pkh` as immutable on registry `UpdateRegistry` (preventing governance from de-syncing the on-chain vault's `keeper_pkh` from Registry's cached copy).
32. **Compile-time Vault Identity NFT anchor (R55 C-1)** -- `vault_nft_policy` is a compile-time parameter on `vault_proxy` / `vusdcx` / `order` (not a datum field). Each validator's script hash encodes the real one-shot policy at deploy time, so the NFT-preservation check cannot be spoofed by attacker-crafted fake `VaultDatum` UTXOs declaring their own policy. R55 closed the R54-followup phantom vUSDCx attack path where the self-referential `datum.vault_nft_policy` check (pre-R55 R45/R46/R54) allowed attackers to deploy their own `vault_nft(attacker_utxo_ref)`, mint a legal 1-unit token under the fresh policy, and drain full TVL via phantom vUSDCx mints.
33. **Anti-double-satisfaction receiver binding (R48 M-1)** -- Withdraw enforces `receiver_output_idx` hard binding (replaces `list.any` ambiguity)
34. **Early withdraw fee deferral (R49 M-4)** -- `withdraw_amount` (net of early fee) used in buffer/total_deposited deduction so physical early_fee accrues as share price increase for remaining holders
35. **Governance emergency TX binding (R49 L-6)** -- `emergency=true` QueueAction forbids empty `target_tx_hash`, preventing 1-of-n arbitrary execution after emergency queue
4. **Emergency escape** -- Users can force-withdraw after 7 days of keeper inactivity
5. **Fee caps** -- Performance fee hard-capped at 4.5% (450 bps), immutable on-chain; adjustable within 0–4.5% via Governance UpdateFee with 7-day cooldown
6. **Anti-inflation** -- 1M share multiplier prevents ERC-4626 style inflation attacks
7. **Minimum deposit** -- 10 USDCx minimum prevents dust attacks
8. **Double satisfaction** -- Single vault input enforced per transaction (MergeUtxo allows 2-5 with strict controls)
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
21. **MergeUtxo all-token verification** -- `flatten(total_input_value)` iterates every token; output must have `>=` each input token; prevents token theft during UTXO merge
22. **MergeUtxo secondary NoDatum only** -- Secondary vault inputs must be NoDatum (blocks InlineDatum and DatumHash); prevents fake datum injection
23. **EmergencyWithdraw buffer protection** -- `idle_buffer` can only increase (non-decrease enforced); `last_compound_time` immutable
24. **RecallFromProtocol multi-token** -- `recall_token_policy/name` in redeemer enables DJED/USDM/USDCx recall; value check uses specified token
25. **None datum gate** -- Datum-less vault inputs only allowed with MergeUtxo redeemer; all other redeemers require datum (fail with error message)
26. **Buffer-funded Compound** -- On-chain yield = `idle_buffer + non_deposit_value - total_deposited` (tamper-proof, no keeper injection); `allocs_empty` required
27. **burn_token triple validation** -- RecallFromProtocol burn_token verified: not deposit token, minted negative, decreased in output
28. **Loss compound support** -- Negative yield allowed with fee=0, prevents vault bricking on protocol losses
29. **vusdcx first deposit cap** -- 10^18 cap prevents initial mint dilution attacks
30. **on_chain_yield tamper-proof** -- Yield derived from on-chain state, not keeper-provided values
31. **NDV stable_tokens guard (R40)** -- `DeployToProtocol` and `RecallFromProtocol` only modify `non_deposit_value` for tokens in `registry.stable_tokens`; non-stable tokens (airdrops/garbage) cannot inflate or deflate NDV; `DeployToProtocol` enforces `NDV >= 0` floor to prevent negative-NDV DoS on Compound

### Test Coverage

| Category | Tests | Status |
|----------|-------|--------|
| Aiken smart contracts (unit) | 1,600 | All pass |
| Aiken property-based fuzz | 2,500 | All pass |
| Keeper vitest | 607 | All pass |
| API vitest | 113 | All pass |
| Frontend vitest | 428 | All pass |
| Preprod E2E | 19 | All pass (V10-R71 full stack: vault_core + vault_protocol + vault_liqwid verified on-chain) |
| **Total** | **5,267+** | **All pass** |

- Comprehensive automated test coverage
- 71 internal audit rounds (R1-R71), 268+ fixes, findings addressed, **Q2-Q3 2027 third-party audit pending**
- Preprod E2E: V10-R71 full stack verified -- 19/19 on-chain (7 V10-specific + 6 Vault core + 6 Complete flow; DeployToProtocol bounded ADA spend + UseLiqwid routing + KeeperToggleMarket + FastUpdateMarkets + Buffer-funded Compound share-price accrual)
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
| 10 | MergeUtxo + security | 10+ | Token drain, DatumHash injection, None datum bypass |
| 11-15 | Hardening + E2E | 20+ | Extended validation, Preprod E2E |
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
| 43 | Full V9 re-audit | 1 | R43 C-1 fake VaultDatum injection fix; 2 LOW + 4 INFO |
| 44 | Hacker-perspective audit | 0 | 10 attack paths analyzed, all blocked |
| 45 | Phantom vault + Vault NFT | 2 | **R45 C-1 CRITICAL** phantom vUSDCx → Vault Identity NFT (one-shot); M-1 NFT continuing output |
| 46 | Vault NFT preservation | 1 | Registry auth NFT preservation on UpdateRegistry |
| 47 | Full 24-redeemer matrix | 0 | 24 × 10 = 240 checks verified |
| 48 | Withdraw anti-double-sat | 1 | M-1 `receiver_output_idx` hard binding |
| 49 | Hacker-perspective deep audit | 2 | **HIGH M-4** early withdraw fee drift (vault_core), **HIGH L-6** governance emergency+empty_hash bypass |
| 50 | Adversarial R49 re-audit | 0 | R49 regression verified; empty-hash delegation path documented |
| 51 | External audit verification | 2 | **C-1 HIGH** vault_core BatchProcess `no_vusdcx_leak` (multi-order same-user vUSDCx diversion); H-1/M-3 governance signer floor `signers >= 3` |
| 52-54 | Corner-case sweep + hardening | 30+ | MergeUtxo token allowlist, NDV floors, gov-path orphan guards, reference-input NFT gate, payout uniqueness, exact mint/burn ratios |
| 55 | Compile-time Vault NFT anchor | 1 | **C-1 CRITICAL** phantom vUSDCx via self-referential datum NFT field → compile-time parameter on `vault_proxy` / `vusdcx` / `order` |
| 56-58 | Deep sweeps + size optimization | 10+ | MergeUtxo whitelist, NDV ≥ 0, Order.Expire full-value, Withdraw full-drain NFT burn, helper `no_new_tokens`, validity-range width caps |
| 59-61 | Clean rounds + methodology | 3 INFO | Constant-delay cross-validator grep symmetry, invariant transitivity, value-flow conservation + boundary-value fuzzing |
| 62 | Property-based foundation | 0 | `aiken/fuzz` v2.2.0 + 25 properties × 100 iterations = 2,500 randomized checks |
| 63 | Off-chain runtime audit | 10 | API/keeper R55 env params, `/submit-tx` auth, awaitTx-before-cooldown, key rotation, LRU cap, cooldown persistence |
| 64 | Deploy pipeline audit | 10 | `RELEASE_TAG` gate, mixed-asset change bundling, per-script flushState, NFT deadline extensions |
| 65 | R64-c follow-up batch | 3 | **N-1 MEDIUM** EmergencyWithdraw secondary allowlist; **N-2 LOW** Order.Expire full-value refund; **N-3 LOW** Registry `no_new_tokens` |
| 66 | R64-a L-2 + audit complete | 1 | **L-2 LOW** EmergencyWithdraw soft alloc ceiling preventing governance mis-configuration soft-brick |
| 67-68 | R68 hardening | 3 | vusdcx source hash update, additional regression tests |
| 69-70 | R70 yield cycle + reverse swap | 10+ | Liqwid V2 integration, keeper CML builders, Discord notify, ref script reclaim |
| 71 | V10 deploy pipeline audit | 3 | **M-1 MEDIUM** Registry `keeper_pkh` immutability on UpdateRegistry; **L-1 LOW** DeployToProtocol 10-USDCx minimum per-TX floor (anti-dust); **L-2 LOW** Registry KeeperToggleMarket no-op rejection |
| 72 | Post-Phase-77d hacker-mindset | 2 | **F-1 MEDIUM** vault_keeper_hot Compound gov_share cross-validator binding (R72 F-1 — verify gov input redeemer is `ReceiveCompoundShare`); **F-3 LOW** registry asset_oracles upper-bound caps (max_disagreement_bps ≤ 1000, max_staleness_ms ≤ 1h) |
| 73 | MergeUtxo donation admissibility | 1 | **F-1 LOW** vault_recall.MergeUtxo deposit-token donation could push `idle_buffer` past `total_deposited + non_deposit_value + Σ liqwid_principal`, breaking the allocation invariant required by 7 downstream redeemers — `valid_merge_utxo_admissibility` guard added |
| 74 | Minswap V2 LP-name decoder | 1 | **F-1 HIGH** pre-mainnet blocker — Minswap V2 `lp_asset` is a single LP token identifier, not a 2-asset pair; SwapAdapter Variant B branch crashed on every real Minswap V2 order. Rewrote redeemer to commit a `hop_chain` + on-chain `compute_lp_asset_name` (sha3-256 canonical pair hash) re-verification |
| 75 | External audit-0426 | 4 | **C-1 CRITICAL** vault_user.CommunitySunset vUSDCx caller check used `""` instead of `vusdcx_token_name` → dead-man-switch permanently un-invokable; **L-1 LOW** sunset trigger `last_compound_time only` (was `max(last_compound, last_realloc)` — keeper zero-yield heartbeat spam could brick the dead-man-switch); **M-2 MEDIUM** order.Process `tip_output_idx ≠ payout_output_index` (prevent payout-as-tip aliasing); **L-4 LOW** vault_proxy NoDatum branch enforces `withdrawal_count == 1` (defense-in-depth symmetry with primary branch). 7 other findings (M-3 / L-2 / L-3 / L-5 / I-1 / I-2 / I-3) accepted defense-in-depth or already-mitigated — see "audit-0426 Disposition" section below |
| **Total** | **All components** | **280+** | |

Full audit details in `docs/audit-report.md` and `audit-0426.md`.

## Audit Status

- Comprehensive automated test suite
- 1,625+ Aiken unit + 2,500 property-based fuzz + 607 keeper + 113 API + 428 frontend + 19 Preprod E2E = 5,290+ regression checks
- 75 audit rounds (R1-R75), 280+ fixes
- Internal findings addressed; **Q2-Q3 2027 third-party audit pending** (pre-audit 100K USDCx TVL cap enforced until external review completes)
- Community audit: contributions welcome

## audit-0426 Disposition (R75)

External audit `audit-0426.md` (2026-04-26) flagged 11 findings:
1 CRITICAL (C-1), 2 MEDIUM (M-2 / M-3), 5 LOW (L-1 through L-5),
3 INFO (I-1 / I-2 / I-3). 4 received code fixes (C-1 / L-1 / M-2 /
L-4). The remaining 7 are documented below with the rationale for
NOT changing the code, and each comes with a future-revisit trigger.

**M-3 LOW (was filed Medium) — Phantom-vault detection relies on CBOR type-matching: ACCEPTED defense-in-depth.**
The `vault_proxy::no_foreign_vault_datum` check uses Aiken's
`is VaultDatum {..}` pattern which matches any datum with the same
Constr tag + field count. The audit correctly flags that this is
not a strict structural check. **Real defense:** the compile-time
`vault_nft_policy` parameter on `vault_proxy` (R55 fix) — the Vault
NFT one-shot minting policy guarantees exactly one Vault NFT exists
in the universe, and `has_vault_nft` on the primary input enforces
that the spent UTXO carries it. An attacker would have to forge the
Vault NFT (impossible by the one-shot UTXO-ref policy) to reach a
state where the phantom check matters. The CBOR-shape check is a
secondary signal, not the primary gate. The `vault_version >= 0`
tautology in the inner check is intentional: it forces the
type-cast `is VaultDatum` to actually evaluate (rather than being
optimised away), thereby triggering the field-count match check.
Removing it would weaken the secondary signal further with no
upside. **Future-revisit trigger:** if R55 compile-time NFT anchor
is ever weakened, OR if a multi-Vault-NFT future emerges (V2 with
isolated vault tenants sharing the proxy script), revisit and
upgrade the check to a strict structural validation against a
sentinel field value.

**L-2 LOW — MergeUtxo doesn't enforce total_deposited increase: ALREADY MITIGATED by R73 F-1 admissibility guard.**
MergeUtxo accepts deposit-token donations into `idle_buffer`
without bumping `total_deposited` (the latter represents
share-claim, not physical token presence). The audit correctly
notes that this could let `idle_buffer > total_deposited` if an
attacker donates large amounts. **Mitigation:** `valid_merge_utxo_
admissibility` (R73 F-1 / `lib/vault/validation.ak::valid_merge_
utxo_admissibility`) explicitly enforces `alloc_sum + idle_buffer
<= total_deposited + non_deposit_value + Σ liqwid_principal`. So
donations can grow `idle_buffer` only up to the bound where the
total-fund accounting still closes — donations beyond that are
rejected at MergeUtxo time, not later when downstream redeemers
might choke. **Future-revisit trigger:** none — the invariant is
proven sufficient.

**L-3 LOW — ReceiveCompoundShare has no signer requirement: ACCEPTED, cross-validator binding via R72 F-1.**
`multisig_gov::ReceiveCompoundShare` (the gov input spend handler
that accepts the gov-share USDCx delta from a Compound) does not
require any governance signer signature. **Cross-validator gate:**
`vault_keeper_hot::Compound::valid_gov_share` (post-R72 F-1) reads
the gov input's spend redeemer via `pairs.get_first(tx.redeemers,
Spend(gi.output_reference))` and `expect`s it to be specifically
`ReceiveCompoundShare`. Pairing Compound with any other GovRedeemer
(Heartbeat / QueueAction / etc.) would physically move gov_share
USDCx but leave `signer_compensation_pool` un-credited — and
post-R72 that pairing is rejected. So `ReceiveCompoundShare` is
only ever invoked atomically with a valid keeper-authorised
Compound, which is itself gated by `vault_keeper_hot`'s full math.
A standalone `ReceiveCompoundShare` invocation would still need
to satisfy the gov-output continuity check (NFT in continuing
output + datum preservation + nonce bump + delta-derived USDCx
increment) but cannot extract value because the only mover of
USDCx into the gov UTXO is the Compound TX itself, and that
requires keeper authorisation + valid vault math. **Future-revisit
trigger:** if vault_keeper_hot's R72 F-1 binding is ever weakened
or removed, this lib must add a signer requirement.

**L-5 LOW — Preprod timelock overrides in `constants.ak`: OPERATIONAL — must-revert flagged on mainnet ceremony pre-flight.**
11 governance-action timelocks are set to 60 seconds for Preprod
testing (Phase 84+ session-bounded H-path E2E) instead of the
production 7d / 14d / 21d / 37d values. Plus
`timelock_deregister_stake_ms` is overridden to 1 hour from 14d.
Plus `timelock_update_slippage_policy_ms` is 60s vs 48h.
**Mitigation in code:** every overridden constant carries a
`/// PREPROD OVERRIDE` comment block + `MUST revert before any
mainnet build` warning + the production value is recorded inline.
**Mitigation in process:** `deploy/runbooks/v1-mainnet-ceremony.md`
pre-flight checklist requires verifying every constant against the
spec file (`spec/governance.md` + `spec/keeper-auth.md`).
**Future-revisit trigger:** mainnet ceremony pre-flight run will
revert these and re-build. Audit re-verification on the
production-hash artefacts is REQUIRED before mainnet deployment.

**I-1 INFO — `vault_gov_policy` fail message says wrong validator name: SELF-CORRECTED in audit.**
The audit initially flagged this then verified it correct.
`vault_gov_policy.ak:306` correctly says
`"vault_gov_policy: unsupported purpose"`. No change.

**I-2 INFO — Full-drain NFT discovery scans by token name, not compile-time policy: ACCEPTED.**
`vault_user.ak::Withdraw` full-drain branch scans `own_input.value`
for any token entry with `name == vault_nft_token_name && qty == 1`
and uses the discovered policy as the burn target. The
discovered-policy approach is necessary because the Vault NFT
policy isn't directly available as a compile-time parameter at the
vault_user level (only at the proxy level). **Defense-in-depth:**
`opti_vault_count == 1` enforces uniqueness, so even if multiple
NFT entries with the canonical name existed (impossible under the
one-shot policy), the burn would be ambiguous and fail. The
compile-time `vault_nft_policy` anchor is enforced at the proxy
layer, which is the gating layer for all vault spends. **Future-
revisit trigger:** if vault_user is ever made directly responsible
for NFT validation (e.g. via a future architecture refactor),
parameterise it on `vault_nft_policy` and use compile-time anchor.

**I-3 INFO — BatchProcess integer division truncation favors vault: ACCEPTED — correct bias.**
`vault_batcher.ak::BatchProcess` and `vault_user.ak::Deposit`
share `fair_shares = od.amount * old_total_shares /
old_total_deposited`. Aiken integer division floors towards zero,
so the output rounds DOWN. This favours the vault (existing
shareholders) over new depositors — the standard ERC-4626
convention and the correct bias for share-pricing in a vault. The
sub-1-unit dust per order accumulates in the vault as bonus value
for remaining holders. No change.

## Design Decisions (Documented)

The following items have been raised in audits and are confirmed as intentional design choices:

**BatchProcess no early_withdraw_fee:** Batched withdrawals via the order queue are exempt from early withdrawal fees. The queuing mechanism (create Order UTXO → wait for keeper processing) inherently prevents same-block flash-loan attacks. See whitepaper §3.3.

**Early withdrawal fee as deferred yield (R49 M-4 updated):** When a direct Withdraw charges `early_fee`, both `idle_buffer` and `total_deposited` decrease by `withdraw_amount` (base_withdraw - early_fee), so the physical `early_fee` tokens remain in the vault value AND the datum accounting matches the physical token preservation check (`verify_token_preserved` only allows decrease of `withdraw_amount`). This immediately raises share price for remaining holders rather than waiting for the next compound cycle. R49 M-4 fix. See whitepaper §3.2.

**Governance empty-hash delegation (R40 C-1 / R50 documented):** The `QueueAction` empty `target_tx_hash` path allows m-of-n governance to pre-authorize a VaultAdmin/RegistryAdmin capability that any 1-of-n signer can execute after a 14-day minimum timelock. This exists because `target_tx_hash` has an unavoidable circular dependency on the governance UTXO reference. On-chain defenses retained during the window: `CancelAction` (1-of-n veto), 37-day `action_ttl_ms` cap, `GovNFT == 1`, target script spent input, ADA preservation, 16 immutable VaultDatum fields. Off-chain obligations: empty-hash `QueueAction` must be broadcast publicly within 1 hour, ≥1 honest signer must monitor the queue and use `CancelAction` on any anomaly, signer set must include ≥2 non-colluding parties. Prefer explicit `target_tx_hash` whenever the TX body is predictable. Confirmed R40 C-1, R49 L-6, R50.

**min_hold_seconds uses global timestamp:** The minimum hold period uses `last_compound_time` (global) rather than per-user deposit time, because Cardano's eUTXO model stores all state in a single shared datum. The early withdrawal fee (0.1%) and 24-hour hold period provide sufficient protection. See whitepaper §5.4.

**keeper_pkh / fee_collector immutable:** These fields cannot be changed after deployment, even by governance. Key rotation requires vault migration. This is a conservative design choice — immutability prevents governance key compromise from redirecting keeper operations or fee collection.

**Order owner = VerificationKey only:** Order recipients must be wallet addresses (not script addresses). This is an intentional security decision after analyzing the attack surface of Script owner support:
- **Cancel authorization forgery:** Cardano has no `msg.sender` — Cancel uses `extra_signatories` (PKH signatures). Script addresses cannot sign, so Cancel would need to check for a spent script input instead. However, if the owner is a low-threshold script (e.g., always-true), anyone could spend a UTXO at that address and cancel other users' orders, stealing their refunds.
- **Refund locking:** Refund outputs to script addresses may lack the required datum for the script to spend them, permanently locking the refunded tokens.
- **MEV amplification:** Script-based automation enables same-block deposit→withdraw cycles that bypass the queuing delay designed to prevent flash-loan attacks.
- **Composability trade-off:** DeFi protocols (DAOs, yield aggregators) that need vault access can use a wrapper pattern — a VerificationKey-controlled wallet that proxies operations on behalf of the script. This preserves security while enabling integration.

**"Immutable field" semantics:** "15 immutable fields" (V10-R71, retained from V9.3-R55) means the **datum field reference** cannot be altered by any redeemer — the field must remain present with the same type across every vault state transition (enforced by `check_immutable_fields` in `lib/vault/validation.ak`). For most fields the **value** is also constant after deployment. The one deliberate exception is `performance_fee_bps`: the field is immutable (cannot be removed or retyped), but its numeric value can be adjusted within `[0, 450]` bps (0–4.5%) by Governance via the two-step `UpdateFee` flow (m-of-n QueueAction → 7-day timelock → 1-of-n ExecuteAction, with 7-day cooldown between updates enforced by `last_fee_update_time`). The 4.5% hard cap is enforced on-chain in the UpdateFee validation and cannot be exceeded. R55 removed `vault_nft_policy` from the datum entirely — it is now a **compile-time parameter** on `vault_proxy` / `vusdcx` / `order`, providing a stronger anchor than a datum-level immutability check (a datum field can still be attacker-controlled in a *fake* UTXO, whereas a compile-time parameter is encoded in the validator's script hash and cannot be spoofed). See `validators/vault_protocol.ak` UpdateFee branch, `contracts/docs/vault-state-machine.md` §4.7, and `audit-r55.md`.

**Registry auth NFT policy-only check:** The registry UTXO authentication checks for any token under `registry_auth_policy` without verifying the specific token name. This is safe because the auth NFT uses a one-shot minting policy that can only ever produce one token. If a future deployment uses a multi-token policy, the check should be extended to include `auth_name`.

**Withdraw allowed during Emergency Freeze (R40 F-1):** The `Withdraw` redeemer intentionally does not check `frozen == 0`. This is a core design principle: user funds are never locked, regardless of vault state. The `frozen` flag blocks operational actions (Compound, BatchProcess, RebalanceBuffer, DeployToProtocol, SupplyToLiqwid) that could compound incorrect accounting, while Withdraw, Recall, and MergeUtxo remain available for fund recovery. The `idle_buffer >= base_withdraw` constraint (vault_core.ak) naturally prevents over-withdrawal — if funds are lost, the reduced buffer causes large withdrawals to fail. First-come-first-served during stress is standard DeFi behavior; blocking withdrawals during freeze would trap user funds and increase risk. Confirmed in R37, R37-a, R39 audits.

**BatchProcess zero-share edge case (R40 F-4):** When `total_shares > 0 && total_deposited == 0`, BatchProcess mints 0 shares. This state requires 100% fund loss to be compounded — the vault is worthless and 0-share mint is the correct behavior (preventing deposits into a dead vault). Under normal operation, `total_deposited > 0` ensures positive share calculations.

**Garbage token dust in vault UTXO (R40 F-5, superseded by R56 M-1):** Pre-R56 any principal could donate a NoDatum UTXO containing arbitrary tokens (garbage NFTs, vUSDCx self-injection, unrelated policies) to the proxy address, and the next MergeUtxo call would absorb them into the vault cont_output via `verify_multi_input_preserved`. This has been closed in R56 M-1: the MergeUtxo validator now rejects any secondary UTXO carrying a token outside the allowlist `{ADA, deposit_token, registry.stable_tokens}`. Full drain remains the only path to shed any residual dust from pre-R56 deployments.

## External Trust Boundaries

OptiVaults relies on a small set of external Cardano components whose correctness is treated as a trust assumption rather than an on-chain invariant. These boundaries are documented here so integrators and auditors can reason about the protocol's failure modes when an external component is compromised.

**Liqwid qToken exchange rate (R56 I-1):** `SupplyToLiqwid` validates that the vault sends `supply_amount` of underlying to the Liqwid action address and receives *some* qTokens in return (`qtoken_delta > 0`). It does NOT verify that the ratio of qTokens received to underlying supplied matches any particular fairness bound — OptiVaults fully delegates rate enforcement to Liqwid's own action validator. If Liqwid is compromised (protocol upgrade with broken rate curve, oracle manipulation, governance-controlled action script pointing at an unfair pool), a compromised OptiVaults keeper could pair that with a `supplied_value = supply_amount` datum update that records far less on-chain value than the physical tokens supplied. Mitigation path: OptiVaults' own registry timelock (21-day cooldown before AdminDeployNonDeposit can exfiltrate tokens), keeper-not-fee-collector separation, and the 4.5% fee hard cap bound the extractable damage, but the base integrity rests on Liqwid's own action script correctness.

**Registry auth NFT policy correctness:** The registry UTXO is identified by the presence of any token under `registry_auth_policy`, which is a bytes field baked into each vault deployment. The protocol assumes this policy is a **one-shot native script** minting exactly one token at deploy time. If the deploy pipeline mints the auth NFT under a loose minting policy (e.g., a policy that can mint more tokens after deployment), an attacker who obtains signing rights to that policy could produce a second "authorized" registry UTXO and insert an arbitrary whitelist or stable_tokens list. Mitigation: `scripts/deploy/init-registry-vault-v9-preprod.ts` uses `{sig=walletPkh, before=deadline_slot}` which is one-shot by construction; production deploys MUST follow the same pattern.

**Blockfrost / Ogmios indexing correctness:** The off-chain API, keeper, and Phase C test script read UTXO state via Blockfrost and Ogmios. A compromised or incorrect indexer can return stale UTXOs or omit recently-created ones. This does not affect on-chain security — every TX is still validated by the Aiken validators — but it can cause TX construction to fail with `CannotCreateEvaluationContext` / "unknown input" errors or produce transactions that reference now-spent inputs. Mitigation: the Phase C E2E flow explicitly waits 45–60s between dependent TXs to let the indexer catch up, and the keeper retries on `missing_utxo` errors.

**Cardano ledger correctness:** OptiVaults assumes Cardano ledger enforcement of standard eUTXO invariants (no negative balances, exact value preservation across inputs/outputs, enforced datum hashes, etc.). A ledger-layer bug would affect every Cardano protocol and is out of scope for application-layer audits.

## Property-Based Fuzz Testing (R62 Foundation)

After 61 rounds of human-reasoning audits reached diminishing returns (R59 + R61 both produced zero new findings; R60 surfaced only governance-trust-boundary observations), the audit methodology has shifted to **property-based fuzz testing** using Aiken's native `aiken/fuzz` support (v2.2.0 package).

The foundation test suite `lib/vault/tests/property_fuzz_test.ak` encodes 12 load-bearing arithmetic invariants that must hold across randomized state:

| Property | Description |
|----------|-------------|
| P1 round-trip | `withdraw(deposit(x)) ≤ x` (no free money via deposit+withdraw) |
| P2 equal deposits | Identical deposit amounts produce identical shares |
| P3 compound monotonic | Positive yield cannot decrease user payout |
| P4 deferred yield (R49 M-4) | Partial withdraw with early fee strictly increases share price for remaining holders |
| P5 rounding direction | Every share calculation rounds in favor of the vault |
| P6 first-depositor cap | First deposit shares = amount × 1,000,000 (anti-inflation) |
| P7 withdraw floor | `calculate_withdraw_amount` returns the floor of `shares × TD / TS` |
| P8 fee bound | Compound fee ≤ harvested amount, ≥ 0 |
| P9 sequential compound | Share price never decreases under repeated positive compounds |
| P10 withdraw ≤ TD | No withdrawal can exceed `total_deposited` |
| P11 early fee bound | Early withdrawal fee never exceeds the withdraw amount |
| P12 multi-depositor fairness | Later deposits cannot dilute earlier holders' principal |

Each property runs 100 randomized iterations per `aiken check` invocation (seed configurable via `--seed`). The Aiken compiler automatically shrinks any failing input to a minimal counter-example. This gives continuous regression coverage over the entire (TD, TS, amount, fee_bps) state space that manual review cannot exhaustively enumerate.

**R62 Part 2 extension (P13-P25)**: `property_fuzz_extended_test.ak` adds 13 validator-helper properties covering `validate_allocations` boundary acceptance and rejection, `verify_protocol_fields_preserved` identity plus per-field mutation rejection (frozen, total_deposited, last_compound_time), and `check_immutable_fields` identity plus keeper_pkh / governance_policy mutation rejection. Combined P1-P25: 25 properties × 100 iterations = 2,500 randomized checks per `aiken check` run.

**Coverage extension roadmap**: Future rounds should add property suites for (a) `on_chain_yield` formula invariants in Compound, (b) generator-based synthesis of full Transaction fixtures to exercise the end-to-end validator logic, and (c) `list.unique` edge cases in registry `valid_markets_unique` (R57 F-5).

This approach is meant to complement — not replace — scheduled human white-hat reviews. Property tests surface regressions in encoded invariants; human audits surface new adversarial patterns that no property yet captures.

## Off-Chain Runtime Audit (R63)

R63 is the first audit round that focused on TypeScript/JavaScript rather than Aiken. Threat model: **liveness degradation + recovery UX failure**, NOT principal loss. The on-chain validators (R1-R62) already protect funds; the off-chain scope covers whether users can reach those validators in the first place.

Scope: `deploy/api/src` (server + routes), `deploy/keeper/src` (compound + rebalance + batch engines + provider utils), `optivaults/withdraw-cli` (self-serve recovery CLI), `optivaults/opti-gov` (governance CLI).

10 findings, all closed:

| ID | Severity | Summary |
|---|---|---|
| F-1 | HIGH | API + keeper `loadBlueprint` / `loadV9VaultConfig` missing R55 `vault_nft_policy` compile-time parameter — production API returned "vault not found" for every user after R55 deploy; keeper queried wrong proxy address. Fix: `VAULT_NFT_POLICY` + `EXPECTED_PROXY_HASH` env vars + conditional `isV9 ? [..., NFT] : [...]` at every `applyParamsToScript` callsite + startup sanity-check abort. |
| F-2 | HIGH | `withdraw-cli/src/config.ts V9_PREPROD` stuck at Phase 40 R42 addresses — self-serve recovery promise unenforceable. Fix: `VaultNetwork` interface gains `vaultNftPolicy` field + V9_PREPROD constants refreshed to V9.3-R55 deployment. |
| F-3 | MED | `/api/submit-tx` missing JWT auth — IP rotation could drain Blockfrost quota. Fix: `requireAuth` middleware. |
| F-4 | MED | Keeper Compound cooldown recorded at mempool-accept, not chain-confirm — reorg or adversarial Deposit front-run could silently drop Compound. Fix: `await lucid.awaitTx(txHash, 90_000)` before `recordExecution`; timeout/fail returns `{success:false}` so next cycle re-evaluates. |
| F-5 | MED | 4 `/api/build-*` endpoints missing JWT auth — IP-rotated resource amplification against plutus.json parse + applyParams + Lucid complete (~500ms CPU + ~10 provider calls per request). Fix: `requireAuth` on all four. |
| F-6 | MED | `/api/submit-tx` Blockfrost fallback used static `BF_KEY` — once evaluate-tx rotated away, submit permanently 402'd. Fix: wrap in rotating key loop with `getActiveBfKey()` + `rotateBfKey(status)` symmetric to evaluate-tx path. |
| F-7 | LOW | `blockfrostScriptCache` was unbounded `Map` — adversary posting ~5000 ADA of dummy ref scripts to proxy address could OOM keeper. Fix: LRU cap `MAX_CACHE_ENTRIES = 500` with touch-on-hit eviction (both keeper + API copies). |
| F-8 | LOW | `opti-gov queue` accepted empty `targetTxHash` silently — R40 C-1 empty-hash path delegates m-of-n authority to 1-of-n executor over the timelock window and is the highest-stakes governance misconfiguration available. Fix: `--empty-hash` + `--confirm-empty-hash` flags with forced interactive "yes, I understand" TTY confirmation. |
| F-9 | LOW | `build-deposit-tx` logged `frozen=rawFields[19]` but V9 25-field layout has NDV at 19 and frozen at 20; no early reject on `frozen == 1` wasted CPU + provider quota building doomed TXs. Fix: correct index via `length >= 25 ? 20 : 16` + server-side 503 `VAULT_FROZEN` response. |
| F-10 | INFO | Keeper cooldown Map in-memory only; crash/pm2-restart reset all cooldowns. Fix: persist to `data/cooldowns.json` via `.tmp` + rename atomic write on every `recordExecution`. |

Commits: `52fe2a6` (P0 + P1) + `b74afea` (audit report) + `67c2528` (P2). Full audit report in `audit-r63.md` at the project root.

## Deploy Pipeline Audit (R64)

R64 is the first audit round that focused on deployment scripts themselves. Threat model: **script runs to completion but produces inconsistent on-chain state**, or **aborts mid-deploy leaving partial state**. Principal not at risk, but liveness and operator recovery paths are.

Scope: `scripts/deploy/deploy-ref-scripts-v8-split-preprod.ts`, `scripts/deploy/init-registry-vault-v9-preprod.ts`, `scripts/deploy/deploy-governance-preprod.ts`, `scripts/utils/deployRefScript.ts`, `deploy/keeper/src/utils/v9Config.ts` (state file consumption side).

11 findings (1 CRITICAL + 2 HIGH + 4 MED + 2 LOW + 1 INFO), all closed:

- **F-1 CRITICAL — cross-release state file contamination**. Pass 0 Vault NFT mint idempotency `if (!vaultNftPolicyId) mint()` was correct for same-release resume but catastrophic across releases: R55 `data/v9.3-ref-scripts-preprod.json` records a policyId whose `before(deadline)` is long expired and whose NFT token is physically locked in the R55 vault UTXO. An R60 build reading this state file would silently reuse the stale policyId, fail at init-registry-vault Step 3, and be unable to remint. **Fix**: `RELEASE_TAG` env var gate aborts on `state.release !== EXPECTED_RELEASE` with explicit archive instructions; wallet NFT presence check warns if state records a policy whose token is not in the operator wallet.
- **F-2 HIGH — `deployRefScript` lovelace-only UTXO filter**. `Object.keys === 1` rejected change UTXOs that naturally carried vaultNftUnit/govNftUnit/TestUSDC mixed with lovelace after Pass 0 / Gov Step 1. **Fix**: removed the constraint, added `buildChangeMultiAsset()` helper that aggregates input tokens into the change output via CML `MultiAsset`.
- **F-3 HIGH — `init-registry-vault-v9-preprod.ts` cross-release gap**. Same pattern as F-1 but for registry + vault init steps. Step 2/3 `if (!state.xTx)` guards would silently skip against stale state, producing a "looks successful" deploy with no R60 vault or registry on-chain. **Fix**: same `RELEASE_TAG` gate + `state.registryHash === refState.registryHash` cross-check.
- **F-4 MED — per-script progress persistence**. `results[]` was in-memory only between loop iterations; a crash between script-N success and loop-exit `writeFileSync` would lose 1-5 ref script TX hashes as orphan UTXOs. **Fix**: `flushState()` helper called after each successful script + `completedLabels` Set for resume.
- **F-5 MED — NFT deadlines too tight**. Vault NFT deadline 3600 slot (1h) + Gov NFT 600 slot (10 min) insufficient under Blockfrost retry headroom. **Fix**: Vault 3600→14400 (4h), Gov 600→3600 (1h).
- **F-6 MED — `last_compound_time = now - 2h` test backdate leak**. E2E-specific shortcut leaked into generic deploy script. **Fix**: `BigInt(Date.now())`.
- **F-7 MED — legacy dual-write filename drift**. `deploy-ref-scripts` wrote both `data/v9.3-ref-scripts-preprod.json` (primary) and `data/v8.1-ref-scripts-preprod.json` (legacy compat); operator editing one copy could leave the other stale. **Fix**: dual-write removed; consumers (keeper `v9Config`, `init-registry-vault`) read primary with legacy fallback + deprecation warning.
- **F-8 LOW — `placeholderHash` 58 hex**. Dead code under R55 unparameterized core/protocol but would crash any future re-parameterization. **Fix**: `"00".repeat(28)`.
- **F-9 LOW — 13+ legacy V1-V8 deploy scripts with no deprecation markers**. **Fix**: new `scripts/deploy/README.md` documents the canonical V9.3-R60 flow, the deprecation table, `RELEASE_TAG` error recovery, and the post-deploy runbook checklist (including withdraw-cli sync + API/keeper ENV + pm2 restart).
- **F-10 INFO — withdraw-cli post-deploy manual sync runbook**. Documented in the new README.

Commits: `224cbfa` (10 fixes) + `28497e1` (audit report). Full audit report in `audit-r64.md` at the project root.

## Pre-flight checklist for V10-R71 Preprod redeployment

After R63, R64, and R71, a safe redeployment requires:

1. **Archive old release state files** (one-time manual step):
   ```bash
   mkdir -p data/archive
   mv data/v9.3-ref-scripts-preprod.json data/archive/v9.3-<prev-tag>-ref-scripts-preprod.json
   mv data/v9-init-preprod.json          data/archive/v9-<prev-tag>-init-preprod.json
   mv data/v9-governance-preprod.json    data/archive/v9-<prev-tag>-governance-preprod.json
   ```
2. **Run deploy scripts with RELEASE_TAG** (V10 canonical flow):
   ```bash
   RELEASE_TAG=v10-r71 NETWORK=Preprod \
     npx tsx scripts/deploy/deploy-ref-scripts-v10-preprod.ts
   npx tsx scripts/deploy/deploy-governance-preprod.ts
   RELEASE_TAG=v10-r71 npx tsx scripts/deploy/init-registry-vault-v10-preprod.ts
   for target in core protocol liqwid; do
     STAKE_TARGET=$target npx tsx scripts/deploy/register-stake-v10-preprod.ts
   done
   npx tsx scripts/deploy/e2e-v10-preprod.ts
   ```
3. **Post-deploy environment sync**:
   ```bash
   export VAULT_NFT_POLICY=$(jq -r .vaultNftPolicyId data/v9.3-ref-scripts-preprod.json)
   export EXPECTED_PROXY_HASH=$(jq -r .proxyHash data/v9.3-ref-scripts-preprod.json)
   pm2 restart api keeper
   ```
4. **Withdraw-CLI sync** (manual): update `optivaults/withdraw-cli/src/config.ts` `V9_PREPROD` with the fresh hashes and `npm publish` a new version.

See `deploy/README.md` for the complete runbook and `deploy/runbooks/v1-mainnet-ceremony.md` for the mainnet ceremony procedure. The operator-side keeper / API / frontend live in the sibling repo [`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference).

## Bug Bounty

We plan to launch a formal bug bounty program before mainnet. In the meantime, responsible disclosures will be acknowledged and credited.
