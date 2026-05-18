# OptiVaults V1 — Preprod E2E Test Plan

**Status**: Draft. Implements the test cases listed below as TypeScript scripts under `tests/preprod/` once the V1 keeper / API / deploy pipeline is wired (currently pending — see `keeper/` and `contracts/` empty trees in README.md).

**Audience**: V1 implementation engineers + future external auditor. The plan enumerates every redeemer that V1 ships with and the minimum verification scenarios required before Mainnet ceremony.

**Reference contract artifacts**: `contracts/plutus.json` (regenerated via `aiken build`).

---

## 1. Scope

This plan covers **on-chain Preprod transaction submission and verification** for every V1 redeemer. Off-chain unit tests live in `contracts/lib/vault/tests/*.ak` (validation predicates) and `keeper/test/` (keeper engine TS tests, future).

**Out of scope** for this plan:
- Mainnet operations (covered by `docs/runbooks/v1-mainnet-ceremony.md` once written)
- Off-chain unit tests
- Property-based / fuzz tests (planned `lib/vault/tests/property_test.ak`)
- Long-running stability tests (e.g., 90-day quarterly distribution cycle)

---

## 2. Pre-requisites

Each E2E run requires:

1. **Preprod deploy artifacts** (one-time per release tag):
   - All 11 V1 validators deployed as reference scripts (CIP-33)
   - Vault NFT minted (one-shot UTXO consumed)
   - Governance NFT minted
   - Registry auth NFT minted
   - Initial Vault UTXO at vault_proxy address (26-field VaultDatum)
   - Initial MultisigGov UTXO (3-of-3 launch signers)
   - Initial Registry UTXO (whitelist + Liqwid markets)
   - Initial Treasury UTXO (4 buckets, all balances zero)
   - Initial KeeperAuth UTXO (GovernanceOnly mode, 1 founder PKH)
   - core/protocol/liqwid/keeper_stake_script stake credentials registered
2. **Test wallets** (TestUSDC funded):
   - `userA` — 1000 TestUSDC + 100 ADA
   - `userB` — 1000 TestUSDC + 100 ADA
   - `keeper` — 100 ADA + permission to sign
   - `gov_signer_1/2/3` — 50 ADA each
3. **Mock Liqwid stack** (for SupplyToLiqwid / RecallFromLiqwid):
   - Mock action validator + qToken minting policy
   - Pre-seeded liquidity for at least one underlying token
4. **Environment**:
   - Blockfrost Preprod API key (`BLOCKFROST_API_KEY_PREPROD`)
   - Optional Ogmios + Kupo for Lucid Evolution path (Phase 41 patterns)

---

## 3. Per-redeemer test matrix

Each row produces one or more on-chain TXs that MUST confirm + match the expected datum/balance delta. Rows are grouped by validator.

### 3.1 vault_nft / governance_nft / registry_auth_nft

| ID | Scenario | Expected | Notes |
|----|----------|----------|-------|
| NFT-1 | Mint vault NFT consuming the parameterised UTXO | TX confirms; `(vault_nft_policy, "OptiVault", 1)` minted | Compile-time UTXO ref check |
| NFT-2 | Re-mint attempt (UTXO already spent) | TX fails at submit (UTXO not in inputs) | Cryptographic one-shot guarantee |
| NFT-3 | Burn the vault NFT (full-drain branch) | TX confirms; total supply 0 | Burn unconditional |
| NFT-4 | Mint with wrong asset name | TX fails | Asset-name guard |
| NFT-5 | Mint with quantity ≠ 1 | TX fails | Quantity guard |
| NFT-6 | Same set of cases for `governance_nft` and `registry_auth_nft` | All pass / fail as above | Same pattern |

### 3.2 vault_proxy

| ID | Scenario | Expected |
|----|----------|----------|
| PROXY-1 | Spend with `UseUser` + matching vault_user zero-withdraw | TX confirms |
| PROXY-2 | Spend with `UseKeeperHot` + matching vault_keeper_hot zero-withdraw | TX confirms |
| PROXY-3 | Spend with `UseBatcher` + matching vault_batcher zero-withdraw | TX confirms |
| PROXY-4 | Spend with `UseSwapAda` + matching vault_swap_ada zero-withdraw | TX confirms |
| PROXY-5 | Spend with `UseProtocol` + matching vault_protocol zero-withdraw | TX confirms |
| PROXY-6 | Spend with `UseRecall` + matching vault_recall zero-withdraw | TX confirms |
| PROXY-7 | Spend with `UseLiqwid` + matching vault_liqwid zero-withdraw | TX confirms |
| PROXY-8 | Spend with `UseGovPolicy` + matching vault_gov_policy zero-withdraw | TX confirms |
| PROXY-9 | Spend with `UseGovEmergency` + matching vault_gov_emergency zero-withdraw | TX confirms |
| PROXY-10 | Spend with `UseAdminDeploy` + matching vault_admin_deploy zero-withdraw | TX confirms |
| PROXY-11 | Spend with `UseUser` BUT vault_user withdraw missing | TX fails |
| PROXY-12 | Spend with two staking validators triggered (e.g., user + keeper_hot) in same TX | TX fails (`withdrawal_count == 1`) |
| PROXY-13 | Spend with continuing output missing the Vault NFT | TX fails (`has_continuing_output`) |
| PROXY-14 | Spend with a fake VaultDatum at another script input present | TX fails (`no_foreign_vault_datum`) |
| PROXY-15 | NoDatum secondary UTXO consumed alongside primary (MergeUtxo path) | TX confirms |
| PROXY-16 | Full-drain Withdraw branch produces no continuing output | TX confirms |

### 3.3 vusdcx

| ID | Scenario | Expected |
|----|----------|----------|
| VUS-1 | Mint vUSDCx via Deposit with vault UTXO consumed and NFT present | TX confirms |
| VUS-2 | Mint with vault UTXO missing | TX fails |
| VUS-3 | Mint with vault UTXO missing the Vault NFT | TX fails |
| VUS-4 | Burn vUSDCx via Withdraw | TX confirms |
| VUS-5 | Mint quantity exceeds 10^18 cap | TX fails |
| VUS-6 | Mint with two asset names under the same policy | TX fails |

### 3.4 order

| ID | Scenario | Expected |
|----|----------|----------|
| ORD-1 | userA creates DepositOrder for 50 USDCx with `min_shares` set | UTXO at order script |
| ORD-2 | userA creates WithdrawOrder for 10 vUSDCx with `receiver` set | UTXO at order script |
| ORD-3 | Keeper Process consumes ORD-1 with valid payout to userA | TX confirms; vUSDCx delivered |
| ORD-4 | Keeper Process consumes ORD-2 with payout to `receiver` | TX confirms; USDCx delivered |
| ORD-5 | Keeper Process tries to redirect WithdrawOrder payout to keeper PKH | TX fails (`valid_recipient`) |
| ORD-6 | Owner Cancel before processing | TX confirms; full refund |
| ORD-7 | Anyone-can-trigger Expire after `expires_at` | TX confirms; full refund to owner |
| ORD-8 | Process TX provides `tip_output_idx ≠ -1` with tip > `max_batcher_tip` | TX fails |
| ORD-9 | Process with frozen vault | TX fails (`not_frozen`) |

### 3.5 registry

| ID | Scenario | Expected |
|----|----------|----------|
| REG-1 | UpdateRegistry signed by gov: add a new protocol_hash | TX confirms; new whitelist entry |
| REG-2 | UpdateRegistry attempts to mutate `keeper_pkh` | TX fails (internal-verification immutable) |
| REG-3 | UpdateRegistry attempts to mutate `governance_policy` | TX fails |
| REG-4 | UpdateRegistry adds Liqwid market with duplicate qtoken_policy/name | TX fails (`valid_markets_unique`) |
| REG-5 | KeeperToggleMarket flips DJED active → false | TX confirms |
| REG-6 | KeeperToggleMarket no-op TX (no actual toggle) | TX fails (internal verification `actually_toggled`) |
| REG-7 | KeeperToggleMarket attempts active false → true | TX fails |
| REG-8 | FastUpdateMarkets changes only `action_addr_hash` for one market | TX confirms |
| REG-9 | FastUpdateMarkets attempts to change `qtoken_policy` | TX fails |

### 3.6 multisig_gov

| ID | Scenario | Expected |
|----|----------|----------|
| GOV-1 | QueueAction (UpdateStrategy) with 2/3 sigs | TX confirms; queue length +1 |
| GOV-2 | QueueAction with 1/3 sig (below threshold) | TX fails |
| GOV-3 | QueueAction with `timelock_ms < per-action floor` | TX fails |
| GOV-4 | CancelAction with 1/3 sig | TX confirms; queue length -1 |
| GOV-5 | ExecuteAction before `executable_at_ms` | TX fails (timelock window) |
| GOV-6 | ExecuteAction inside window with matching `payload_hash` | TX confirms (cross-validator) |
| GOV-7 | ExecuteAction after `expires_at_ms` | TX fails (TTL) |
| GOV-8 | RotateSignersRedeemer with new set of 5 (3-of-5) | TX confirms; signer_joined_at preserved for retained |
| GOV-9 | RotateSigners with `len(new_signers) < 3` | TX fails (internal-verification floor) |
| GOV-10 | Heartbeat by signer A within 90-day cooldown | TX fails |
| GOV-11 | Heartbeat by non-signer | TX fails |
| GOV-12 | DistributeSignerCompensation with `pool > 0` and 2 qualified signers | TX confirms; per_signer + forfeit to treasury |
| GOV-13 | DistributeSignerCompensation with `pool == 0` | TX fails |
| GOV-14 | DistributeSignerCompensation with all signers disqualified | TX confirms; full pool forfeit to audit reserve |
| GOV-15 | ReceiveCompoundShare paired with vault_keeper_hot.Compound | TX confirms; pool += delta |
| GOV-16 | ReceiveCompoundShare standalone (no Compound spend in same TX) | TX fails (cross-validator binding via Compound's `valid_gov_share`) |

### 3.7 treasury

| ID | Scenario | Expected |
|----|----------|----------|
| TR-1 | Receive paired with vault_keeper_hot.Compound treasury output | TX confirms; balances split per ratios |
| TR-2 | Spend (Operations, 100 USDCx) signed by gov | TX confirms; recipient gets 100 USDCx |
| TR-3 | Spend (AuditReserve, 1000 USDCx) without `audit_invoice_ref` | TX fails |
| TR-4 | Spend (AuditReserve) that drops balance below `min_audit_reserve` | TX fails |
| TR-5 | Spend within 24h of last spend on same category | TX fails (cooldown) |
| TR-6 | Spend exceeds monthly cap | TX fails |
| TR-7 | UpdateParams sets sum != 10000 | TX fails |
| TR-8 | UpdateParams sets `audit_bps < 2000` | TX fails (treasury_audit_floor_bps) |
| TR-9 | UpdateParams within 180-day cooldown | TX fails |
| TR-10 | ReceiveGovForfeit paired with multisig_gov.DistributeSignerCompensation | TX confirms; audit_reserve += forfeit |

### 3.8 keeper_stake_script

| ID | Scenario | Expected |
|----|----------|----------|
| KAS-1 | WithdrawAsAuthorized by single founder keeper (active set size 1) | TX confirms; nonce++ |
| KAS-2 | WithdrawAsAuthorized by non-authorized PKH | TX fails |
| KAS-3 | WithdrawAsAuthorized without zero-withdraw on own credential | TX fails |
| KAS-4 | UpdateAuthDatum (gov-signed) adds 2nd authorized PKH | TX confirms |
| KAS-5 | After KAS-4: new keeper as primary in week 2 (rotation_period_ms = 7d) | TX confirms |
| KAS-6 | After KAS-4: non-primary keeper attempts WithdrawAsAuthorized within failover_window_ms | TX fails |
| KAS-7 | After KAS-4: non-primary after failover_window_ms expires | TX confirms |
| KAS-8 | UpdateAuthDatum mutates `governance_policy` | TX fails (immutable) |
| KAS-9 | UpdateAuthDatum within 24h cooldown | TX fails |
| KAS-10 | PostBond in `Mixed` mode | TX confirms; bond UTXO created |
| KAS-11 | PostBond in `GovernanceOnly` mode | TX fails |
| KAS-12 | RequestBondWithdrawal + WithdrawBond after 30d | TX confirms |
| KAS-13 | WithdrawBond before 30d cooldown | TX fails |
| KAS-14 | SlashBond with `active_bonds == []` (V1 launch state) | TX fails (`SlashBond` cannot find target) |

### 3.9 vault_user (Deposit + Withdraw)

| ID | Scenario | Expected |
|----|----------|----------|
| USER-1 | Direct Deposit 50 USDCx by userA | TX confirms; share-mint matches formula |
| USER-2 | Direct Withdraw 10 vUSDCx (within min_hold) | TX confirms; 0.1% early fee retained |
| USER-3 | Direct Withdraw past min_hold | TX confirms; no fee |
| USER-4 | Direct Withdraw 100% (full drain) | TX confirms; vault NFT burned, vault UTXO destroyed |
| USER-5 | Direct Withdraw 100% with shares ≠ total_shares | TX fails |
| USER-6 | Direct Withdraw with `validity_range > 1h` | TX fails (internal-verification width cap) |

### 3.10 vault_batcher (BatchProcess)

| ID | Scenario | Expected |
|----|----------|----------|
| BATCH-1 | BatchProcess of 3 mixed orders | TX confirms; per-order fair sums equal to mint/burn totals |
| BATCH-2 | BatchProcess where keeper diverts vUSDCx to non-owner output | TX fails (`no_vusdcx_leak`) |
| BATCH-3 | BatchProcess with two orders sharing `payout_output_index` | TX fails (`unique_payout_indices`) |
| BATCH-4 | BatchProcess without keeper zero-withdraw | TX fails (keeper_stake_script gate) |

### 3.11 vault_keeper_hot (Compound + RebalanceBuffer)

| ID | Scenario | Expected |
|----|----------|----------|
| KHOT-1 | Compound zero-yield (heartbeat) | TX confirms; only `last_realloc_time` advances |
| KHOT-2 | Compound buffer-funded with 1 USDCx yield (gov_fee_bps = 0) | TX confirms; treasury 60% + keeper 40% |
| KHOT-3 | Compound buffer-funded with `gov_fee_bps = 500` (Phase 2) | TX confirms; multisig_gov UTXO consumed + pool += 5% × fee |
| KHOT-4 | Compound with `validity_range > 1h` | TX fails (internal-verification width cap) |
| KHOT-5 | RebalanceBuffer (datum unchanged, allocations may rotate) | TX confirms |

### 3.12 vault_swap_ada (SwapAda)

| ID | Scenario | Expected |
|----|----------|----------|
| SWAP-1 | SwapAda when `vault.lovelace > ada_swap_threshold (15 ADA)` | TX fails |
| SWAP-2 | SwapAda 30 ADA → keeper gets ~15 USDCx (ADA dual-feed oracle returns price_bps=5_000) | TX confirms; vault ADA += 30, USDCx -= 15 |
| SWAP-3 | SwapAda within 1h of last_ada_swap_time | TX fails (cooldown) |
| SWAP-4 | SwapAda with `amount_ada < 10 ADA` | TX fails |
| SWAP-5 | SwapAda when `asset_oracles` has no ADA entry | TX fails (oracle unavailable) |
| SWAP-6 | SwapAda with stale oracle sample (> max_staleness_ms) | TX fails (oracle freshness) |
| SWAP-7 | SwapAda with dual-feed disagreement > max_disagreement_bps | TX fails (oracle disagreement) |

### 3.13 vault_protocol (DeployToProtocol)

| ID | Scenario | Expected |
|----|----------|----------|
| PROT-1 | DeployToProtocol (USDCx → Minswap order via SwapAdapter) within whitelist | TX confirms; idle_buffer -= deploy_amount |
| PROT-2 | DeployToProtocol to non-whitelisted destination | TX fails |
| PROT-3 | DeployToProtocol with `deploy_amount < min_order_amount` | TX fails |
| PROT-4 | DeployToProtocol consumes > `max_deploy_ada` ADA | TX fails |
| PROT-5 | DeployToProtocol leaves vault below `min_vault_ada` | TX fails |
| PROT-6 | DeployToProtocol with `min_receive` below peg-floor (Tier 2) | TX fails (SwapAdapter `check_peg_floor`) |
| PROT-7 | DeployToProtocol with adapter hash NOT in `swap_adapter_hashes` whitelist | TX fails |

### 3.14 vault_recall (RecallFromProtocol + MergeUtxo)

| ID | Scenario | Expected |
|----|----------|----------|
| RECALL-1 | RecallFromProtocol consumes Minswap fill, increments NDV | TX confirms |
| RECALL-2 | MergeUtxo with 2 secondary UTXOs (donations of stables) | TX confirms; non_deposit_value += sum |
| RECALL-3 | MergeUtxo with garbage token in secondary | TX fails (allowlist) |

### 3.15 vault_gov_policy (UpdateStrategy / UpdateFee / UpdateFeeSplit / UpdateSlippagePolicy)

| ID | Scenario | Expected |
|----|----------|----------|
| GPOL-1 | UpdateStrategy by gov with new allocations + buffer 30% | TX confirms |
| GPOL-2 | UpdateStrategy with `buffer_target_bps < 500` | TX fails |
| GPOL-3 | UpdateFee by gov: perf 4.0%, early 0.5%, hold 120s | TX confirms |
| GPOL-4 | UpdateFee with perf > 4.5% | TX fails |
| GPOL-5 | UpdateFeeSplit by gov: keeper 40%, gov 5% (Phase 2) | TX confirms |
| GPOL-6 | UpdateFeeSplit with sum > 50% | TX fails |
| GPOL-7 | UpdateSlippagePolicy: max_slippage 300 bps, min_peg 9500 bps | TX confirms |
| GPOL-8 | UpdateSlippagePolicy with `max_slippage_bps > 500` | TX fails (cap) |

### 3.16 vault_gov_emergency (EmergencyWithdraw)

| ID | Scenario | Expected |
|----|----------|----------|
| GEM-1 | EmergencyWithdraw by gov: freeze + clear Liqwid loss 10 USDCx | TX confirms; total_deposited -= 10, frozen=1 |
| GEM-2 | EmergencyWithdraw with `loss_amount > total_deposited` | TX fails (invariant floor) |

### 3.17 vault_admin_deploy (AdminDeployNonDeposit)

| ID | Scenario | Expected |
|----|----------|----------|
| ADEP-1 | AdminDeployNonDeposit while keeper still active (< 7d) | TX fails |
| ADEP-2 | AdminDeployNonDeposit after 7d keeper-inactive + 21d registry-stable | TX confirms |
| ADEP-3 | AdminDeployNonDeposit attempts to drain deposit token | TX fails (policy guard) |
| ADEP-4 | AdminDeployNonDeposit to non-whitelisted destination | TX fails |
| ADEP-5 | AdminDeployNonDeposit via adapter outside `swap_adapter_hashes` | TX fails |

### 3.18 vault_liqwid

| ID | Scenario | Expected |
|----|----------|----------|
| LIQ-1 | SupplyToLiqwid 10 USDCx → mock action validator | TX confirms; new LiqwidPosition created |
| LIQ-2 | SupplyToLiqwid for already-supplied market | TX fails (`no_duplicate_market`) |
| LIQ-3 | SupplyToLiqwid to inactive market | TX fails |
| LIQ-4 | RecallFromLiqwid (keeper) full position with `underlying_received >= supplied_value` | TX confirms |
| LIQ-5 | RecallFromLiqwid (keeper) with `underlying_received < supplied_value` | TX fails (strict >=) |
| LIQ-6 | RecallFromLiqwid (gov fallback) after 7d keeper-inactive, partial recall | TX confirms; loss written off |
| LIQ-7 | RecallFromLiqwid (gov) leaves orphan qToken in vault | TX fails (internal verification `all_qtokens_gone`) |
| LIQ-8 | RecallFromLiqwid that causes alloc invariant violation after loss | TX fails |

---

## 4. Cross-validator integration scenarios

These exercise the full TX patterns where multiple validators must succeed together. Each is one TX (or two-TX flow) on Preprod.

| ID | Flow | Validators involved |
|----|------|---------------------|
| INT-1 | userA Direct Deposit | vault_proxy.spend(UseUser) + vault_user.withdraw(Deposit) + vusdcx.mint |
| INT-2 | userA Direct Withdraw 10% | vault_proxy.spend(UseUser) + vault_user.withdraw(Withdraw) + vusdcx.mint(burn) |
| INT-3 | userA Queue Deposit + keeper BatchProcess | order.spend(Process) + vault_proxy.spend(UseBatcher) + vault_batcher.withdraw(BatchProcess) + vusdcx.mint + keeper_stake_script.withdraw |
| INT-4 | userA Cancel pending order | order.spend(Cancel) |
| INT-5 | Watchdog Expire pending order | order.spend(Expire) |
| INT-6 | Compound (zero-yield, gov_fee=0) | vault_proxy.spend(UseKeeperHot) + vault_keeper_hot.withdraw(Compound) + keeper_stake_script.withdraw + treasury.spend(Receive=0 OR omit) |
| INT-7 | Compound (buffer-funded, gov_fee=0) | vault_proxy.spend(UseKeeperHot) + vault_keeper_hot.withdraw(Compound) + keeper_stake_script.withdraw + treasury.spend(Receive=60% × fee) + keeper-share UTXO out |
| INT-8 | Compound (Phase 2, gov_fee=500) | INT-7 + multisig_gov.spend(ReceiveCompoundShare delta=5% × fee) |
| INT-9 | Strategy update flow: gov Queue → wait 7d → Execute UpdateStrategy | multisig_gov(QueueAction) → multisig_gov(ExecuteAction) + vault_gov_policy(UpdateStrategy) |
| INT-10 | Fee-split update: gov Queue UpdateFeeSplit → wait 21d → Execute | multisig_gov(QueueAction) + multisig_gov(ExecuteAction) + vault_gov_policy(UpdateFeeSplit) |
| INT-11 | RotateSigners 3→5 → next epoch Heartbeat by new signer | multisig_gov(QueueAction RotateSigners) + multisig_gov(RotateSignersRedeemer) + multisig_gov(Heartbeat) |
| INT-12 | DistributeSignerCompensation with 1 unqualified signer | multisig_gov(DistributeSignerCompensation) + treasury(ReceiveGovForfeit) |
| INT-13 | Liqwid full cycle: Supply USDCx → simulate yield → Recall + Compound | vault_liqwid(SupplyToLiqwid) → mock yield accrual → vault_liqwid(RecallFromLiqwid) → vault_keeper_hot(Compound buffer-funded) |
| INT-14 | EmergencyWithdraw freeze + governance recall write-off | multisig_gov(QueueAction EmergencyWithdraw) → multisig_gov(ExecuteAction) + vault_gov_emergency(EmergencyWithdraw) |
| INT-15 | SwapAda full cycle: vault ADA depleted → keeper triggers SwapAda | vault_proxy.spend(UseSwapAda) + vault_swap_ada.withdraw(SwapAda) + keeper_stake_script.withdraw + oracle reference UTXOs (dual-feed) |
| INT-16 | AdminDeployNonDeposit governance flow: gov Queue → wait 7d + verify keeper-inactive + registry-stable → Execute | multisig_gov(QueueAction) → multisig_gov(ExecuteAction) + vault_proxy.spend(UseAdminDeploy) + vault_admin_deploy.withdraw(AdminDeployNonDeposit) + SwapAdapter withdraw-zero dispatch |
| INT-17 | UpdateSlippagePolicy: gov Queue → wait 48h → Execute (max_slippage_bps + min_swap_peg_bps) | multisig_gov(QueueAction) → multisig_gov(ExecuteAction) + vault_gov_policy(UpdateSlippagePolicy) |
| INT-18 | UpdateRegistry adds second SwapAdapter hash (post-launch new DEX) | multisig_gov(QueueAction) → wait 14d → ExecuteAction + registry.spend(UpdateRegistry) |

---

## 5. Test execution conventions

- Each test script lives at `tests/preprod/<id>.test.ts` (TypeScript w/ Lucid Evolution or CML).
- Test reads/writes deploy state from `tests/preprod/state/v1-r0-preprod.json` (single-source canonical state file, atomic-write pattern; mirrors `data/v9.3-ref-scripts-preprod.json` from the internal-verification flow).
- Each test asserts on TX confirmation + on-chain datum/balance after `awaitTx`.
- Failing assertions throw with a clear message; successful runs print the TX hash + a one-line summary.
- A wrapper script `npm run e2e:v1` runs all tests in dependency order (NFT-1 first, then proxy/vusdcx/order, then redeemer-specific, then INT-*).

## 6. Non-functional acceptance gates

Before tagging V1 mainnet candidate:

- [ ] All 100+ E2E test cases pass (no skipped, no manual exceptions).
- [ ] Every redeemer in `plutus.json` exercised at least once.
- [ ] At least one negative-path test per redeemer (the "TX fails" rows above).
- [ ] At least one cross-validator integration scenario per witness combination.
- [ ] aiken unit-test suite (`contracts/lib/vault/tests/`) passes `aiken check` with 0 failures.
- [ ] Deploy ceremony (NFT-1 through KAS-1) re-run cleanly on a fresh Preprod address.
- [ ] Resource budget checks: every TX exec mem < 14 M, exec steps < 10 G (Conway era ceiling).
- [ ] CBOR-tag-258 / Conway ref-script fee workarounds verified (per `optivaults/contracts/SECURITY.md` §External Trust Boundaries).

## 6.1 Phase 1 governance safety — three-layer test cases (2026-04-25)

Added with the Phase 1 governance safety design (validator commit `9626e8e` + docs commit `257c04e`). These verify the validator-level recovery primitives that make founder-only Phase 1 governance an acceptable launch fallback. See `docs/security-model.md` §5.4 for the threat model + scenario walkthroughs.

**Per-layer scenario matrix** — 19 test cases across 3 layers. Numbered file naming convention: `40-l1-*.ts` for Layer 1, `50-l2-*.ts` for Layer 2, `60-l3-*.ts` for Layer 3. (Yes, `60-minswap-decoder-verify.ts` already exists at that prefix; if a number conflict surfaces, renumber to `70-l3-*.ts` etc.)

### Layer 1 — EmergencyWithdraw freeze-only

| Test | File | Scenario | Expected outcome |
|------|------|----------|------------------|
| L1-1 | `40-l1-emergency-freeze-happy.ts` | Governance executes `EmergencyWithdraw { loss_amount=0, freeze_flag=1 }` with no datum changes beyond `frozen` | TX confirms; on-chain `frozen=1`, every other field byte-identical to pre-state |
| L1-2 | `41-l1-emergency-reject-loss-amount.ts` | Same TX but with `loss_amount=100_000` (any non-zero) | TX rejected by validator (`validate_emergency_freeze_only` constraint `loss_amount == 0`) |
| L1-3 | `42-l1-emergency-reject-position-removal.ts` | Pre-state has 1 Liqwid position; TX attempts to remove it from `liqwid_positions` | TX rejected (`new.liqwid_positions == old.liqwid_positions` violated) |
| L1-4 | `43-l1-emergency-reject-total-deposited-change.ts` | TX attempts to reduce `total_deposited` by 50_000_000 | TX rejected (`new.total_deposited == old.total_deposited` violated) |
| L1-5 | `44-l1-withdraw-under-freeze.ts` | Post-L1-1 frozen state; user invokes `Withdraw` for proportional idle_buffer share | TX confirms; user receives proportional USDCx; vault `frozen` stays at 1 |
| L1-6 | `45-l1-emergency-unfreeze.ts` | Post-L1-1; governance executes `EmergencyWithdraw { loss_amount=0, freeze_flag=0 }` | TX confirms; `frozen` returns to 0 |

**Pre-state requirements**: vault with non-zero `total_deposited`, at least 1 Liqwid position (use mock Liqwid stack from Phase F if real Liqwid Preprod unavailable), governance UTxO available with multisig signers.

### Layer 2 — DeployToProtocol USDCx-exception under frozen

| Test | File | Scenario | Expected outcome |
|------|------|----------|------------------|
| L2-1 | `50-l2-frozen-blocks-supply.ts` | Vault frozen=1; keeper attempts `DeployToProtocol { deploy_token=USDCx, ... }` (Supply path) | TX rejected (`validate_deploy_frozen_gate` — `is_deploy_deposit_token == true` blocks under frozen) |
| L2-2 | `51-l2-frozen-allows-djed-swap.ts` | Vault frozen=1 + holds DJED in NDV; keeper executes `DeployToProtocol { deploy_token=DJED, dest=Minswap V2 adapter, ... }` | TX confirms; DJED moves to swap order; (downstream) Minswap fills + USDCx returns to vault |
| L2-3 | `52-l2-frozen-allows-usdm-swap.ts` | Same as L2-2 but USDM | TX confirms; USDM → swap order |
| L2-4 | `53-l2-unfrozen-allows-supply.ts` | Vault frozen=0 (normal); `DeployToProtocol { deploy_token=USDCx }` Supply path | TX confirms (sanity — Layer 2 didn't break the normal path) |
| L2-5 | `54-l2-frozen-swap-respects-peg-floor.ts` | Vault frozen=1; keeper attempts swap with `min_receive` below peg_floor (e.g., 89% of input) | TX rejected by SwapAdapter `verify_swap_via_adapter` (peg_floor cap) |
| L2-6 | `55-l2-frozen-swap-destination-pinned.ts` | Vault frozen=1; keeper attempts swap with destination address ≠ vault | TX rejected by SwapAdapter destination check |

**Pre-state requirements**: vault with NDV stable tokens (run a vaultSwap or simulated MergeUtxo donation first), governance UTxO + EmergencyFreeze TX to set frozen=1.

### Layer 3 — CommunitySunset dead-man-switch

| Test | File | Scenario | Expected outcome |
|------|------|----------|------------------|
| L3-1 | `60-l3-sunset-rejects-too-soon.ts` | `last_compound_time` 89 days ago; vUSDCx holder attempts `CommunitySunset` | TX rejected (`validate_community_sunset_trigger_time` — 90d threshold not met) |
| L3-2 | `61-l3-sunset-rejects-no-vusdcx.ts` | 90+ days inactive; caller has no vUSDCx in any TX input | TX rejected (`caller_has_vusdcx` constraint fails) |
| L3-3 | `62-l3-sunset-happy-trigger.ts` | 90+ days inactive; vUSDCx holder triggers | TX confirms; on-chain `frozen=1` + `community_sunset_triggered=1`, all accounting fields preserved |
| L3-4 | `63-l3-sunset-rejects-double-trigger.ts` | Post-L3-3; another vUSDCx holder attempts to re-trigger | TX rejected (`old.community_sunset_triggered == 0` fails — one-way) |
| L3-5 | `64-l3-sunset-rejects-accounting-mutation.ts` | 90+ days inactive; vUSDCx holder triggers but datum also drops `total_deposited` to 0 | TX rejected (`validate_community_sunset_transition` requires `total_deposited` unchanged) |
| L3-6 | `65-l3-post-sunset-permissionless-recall.ts` | Post-L3-3; non-keeper non-gov vUSDCx holder fires `RecallFromLiqwid` for an existing position | TX confirms (sunset bypasses `require_keeper_stake_script_or_governance_fallback`) |
| L3-7 | `66-l3-post-sunset-permissionless-swap.ts` | Post-L3-3 + post-L3-6; non-keeper holder fires `DeployToProtocol` Layer 2 swap (DJED → USDCx via Minswap V2) | TX confirms (sunset bypasses keeper signature requirement; SwapAdapter destination + peg_floor still enforced) |
| L3-8 | `67-l3-post-sunset-full-recovery-chain.ts` | End-to-end: trigger sunset → Recall (DJED + USDM) → Swap to USDCx → Withdraw all proportional shares | All 4-5 TXs confirm; final state: vault has 0 Liqwid positions, 0 NDV stable, idle_buffer ≈ 0 (or only stuck dust), every depositor has received their proportional USDCx |

**Pre-state requirements**: vault with non-zero Liqwid positions in DJED + USDM markets (mock Liqwid stack), realistic vUSDCx distribution across ≥ 2 user wallets, time-machine support for "90 days ago" `last_compound_time` (set during ceremony OR use validity-range manipulation if Preprod accepts past lower-bound).

### Cross-layer integration tests

| Test | File | Scenario | Expected outcome |
|------|------|----------|------------------|
| L-INT-1 | `68-int-grief-attack-l1-blocks.ts` | Simulates the pre-Layer-1 attack chain: governance fires `EmergencyWithdraw { loss_amount=full_TVL, positions=[] }` attempting to brick share_price | TX rejected by Layer 1; depositor `Withdraw` continues to function at unchanged share_price |
| L-INT-2 | `69-int-honest-keeper-recovery-under-freeze.ts` | Governance freezes (legitimate); keeper drives Recall + Layer 2 swap → USDCx in idle_buffer; users withdraw proportional share | All TXs confirm; depositors recover full proportional USDCx |
| L-INT-3 | `70-int-attacker-keeper-bounded-by-pegfloor.ts` | Frozen + attacker controls keeper; attacker fires Layer 2 swap repeatedly with max-slippage settings | Each TX confirms but slippage capped by peg_floor (≤ 5-7% per swap); USDCx still lands in vault, attacker gains 0; users still withdraw proportional |
| L-INT-4 | `71-int-sunset-end-to-end-recovery.ts` | Full Scenario E walkthrough from `docs/security-model.md` §5.4 | Recovery completes; depositors receive full proportional USDCx; ref-script ADA + stake deposits remain stuck (out-of-scope) |

### Test infrastructure dependencies

- **Mock Liqwid stack** (Phase F prerequisite). Layer 1+3 tests need governance-fallback Recall path which only fires after 7-day keeper-inactivity OR community sunset; mock stack avoids real Liqwid Preprod gating.
- **Time machine for sunset 90d threshold**. Either (a) ceremony-time `last_compound_time = now - 91d` for the L3 sub-suite, or (b) Preprod validity-range trick if lower-bound-in-past is accepted.
- **Multi-user vUSDCx distribution**. L3-2 needs an account WITHOUT vUSDCx; the existing test ceremonies fund all wallets with vUSDCx for B-phase tests, so L3 sub-suite needs a fresh wallet variant.
- **Simulated NDV stable**. Layer 2 tests need DJED/USDM in vault; reuse vaultSwap fill output OR send a `MergeUtxo` donation directly.

## 7. Open items / known gaps

- **Oracle source for SwapAda** — V1 ships with an MVP single-Int reference-input oracle reader. Preprod tests use a manually-published oracle UTXO. Production V1.x candidate: integrate Charli3 + Orcfax dual feeds with on-chain consensus check.
- **Mock Liqwid stack** — Liqwid Finance does not run on Preprod with the same hashes as Mainnet. Tests use a parallel mock action validator (PlutusV3 native script + native qToken minting policy) that mimics the Liqwid response shape.
- **Long-running cycle tests** — DistributeSignerCompensation has a 90-day cadence; the E2E test must use validity-range tricks to simulate "90 days elapsed" (Cardano accepts validity_range.lower in the past as long as the slot is now-or-future). Tests for full quarterly-cycle realism deferred to an integration sandbox.
- **Phase 2/3 fee-split activation** — INT-8 / INT-10 exercise the contract path but operational TVL/signer-set gates are off-chain policy; the validator only enforces hard caps.

---

## 8. References

- `spec/architecture.md` — 17-validator catalog (+ 4 one-shot NFT mint policies + `minswap_v2_adapter` + 2 SundaeSwap artefacts = 24 total artefacts; partitioning rationale in §4.1)
- `spec/governance.md` + `spec/multisig-gov.md` — gov action set
- `spec/treasury.md` — treasury redeemer details
- `spec/keeper-auth.md` — keeper rotation + bond mechanics
- `spec/order-batch.md` — order/batch invariants
- `spec/ada-swap.md` — SwapAda spec
- `spec/vault-nft.md` — Vault Identity NFT lifecycle
- `contracts/plutus.json` — generated blueprint
- `contracts/lib/vault/tests/validation_test.ak` — datum-transition unit tests
