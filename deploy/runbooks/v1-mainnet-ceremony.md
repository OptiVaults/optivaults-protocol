# V1 Mainnet Ceremony Runbook

**Purpose**: end-to-end procedure for the one-time V1 mainnet deploy ceremony.
**Audience**: operator executing the deploy. Assumes familiarity with `spec/architecture.md` + `docs/security-model.md` + having completed at least one full Preprod dry-run (`v1-preprod-p3` or later).
**Status**: pre-launch draft. Refine with concrete TX fees + mainnet protocol parameter deltas after next Preprod ceremony passes end-to-end.

---

## 0. Non-negotiable preconditions

Do NOT start this ceremony if any of these are false:

- [ ] External audit completed (Q2-Q3 2027 target — see `audit-scope.md §5`). All CRITICAL/HIGH findings remediated. Audit report published and reviewed by governance signers.
- [ ] `contracts/lib/vault/constants.ak` line ~141 reads **`pub const preprod_fast_timelocks: Bool = False`** (single-flag timelock gate at the top of the file). Run `grep -n "preprod_fast_timelocks" contracts/lib/vault/constants.ak` and confirm the binding resolves to `False` — every `timelock_*_ms` / `*_cooldown_ms` / `*_period_ms` constant below evaluates to its production value (`7d / 14d / 21d / 48h / 90d`) via the conditional expression. Spot-check by re-reading the timelock-constant block and confirming no `60_000` literal is on the active branch. Mainnet hash preview at `deploy/state/mainnet-hash-preview.txt` MUST match `aiken build` output byte-for-byte.
- [ ] No `--trace-level` / `--trace-filter` flags on the mainnet `aiken build`. Trace markers inflate validator CBOR substantially (a traced `multisig_gov` build was observed at ~30%+ over un-traced size, eating into the 16,384 B Plutus V3 ceiling). Mainnet build uses plain `aiken build` to preserve full size headroom. Trace builds are a Preprod-only debug aid.
- [ ] Preprod pre-flight ceremony with mainnet timelocks completed (see §A below). Numeric verification confirmed `executable_at_ms - queued_at_ms == production_timelock_ms` for all 11 governance redeemers. Short-timelock paths (emergency 0d, fast_update_markets 1h) executed end-to-end on Preprod.
- [ ] Minswap V2 adapter decoder byte-for-byte verified against real mainnet TXs per `spec/swap-adapter.md §9`.
- [ ] Governance signers confirmed: 3 distinct real key holders, each with independent hardware wallet (per whitepaper §5.5). Threshold 3 (unanimity at launch). PKHs documented in `deploy/config/mainnet.json` and cross-verified by each signer.
- [ ] Deploy wallet has ≥ 1,100 ADA. ~1,039 ADA goes into the ceremony (ref-scripts ~962 ADA + stake deposits 28 ADA + state seeds 27 ADA + network fees ~22 ADA); 50+ ADA headroom for retry + indexer wait + contingency.
- [ ] Deploy wallet has ≥ 15 USDCx (`1f3aec8b…` policy; actual mainnet deposit token) for the vault seed. Verified not-frozen on Circle side.
- [ ] **Deploy-wallet UTxO hygiene**. Run `tsx deploy/tools/scrub-deploy-wallet.ts --network Mainnet --releaseTag v1-mainnet-r0` BEFORE invoking `deploy.ts`. The scrub fold consolidates token-tank UTxOs into `tankAdaPerBucket = 30 ADA` bins and leaves the wallet with ≥ 1 pure-ADA UTxO ≥ 50 ADA at the front of the coin pool. **Why both halves matter**: (a) `deployRefScript.ts::consolidateTokensIfNeeded` re-folds existing tanks at exactly 30 ADA each — without a pure-ADA UTxO to absorb the ~600K-1.2M lovelace TX fee, the consolidator throws an actionable `[deployRefScript] consolidation BLOCKED: wallet has 0 pure-ADA UTxOs` (replaces the older opaque `change too small: -N` failure mask). (b) The stake-credential registration step now uses `fetchPureAdaUtxosForStakeReg` (Blockfrost-direct query that filters scriptRef-bearing + token-carrying + < 3 ADA UTxOs) instead of Lucid's wallet coin selector, preventing accidental ref-script destruction. A clean wallet keeps both helpers' inputs available. Confirm post-scrub by inspecting wallet UTxOs and checking that pure-ADA pool ≥ 100 ADA and at least one pure-ADA UTxO ≥ 3 ADA exists.
- [ ] Blockfrost Mainnet quota: ≥ 2,000 requests headroom (ceremony consumes ~400–600 requests over 10–15 min).
- [ ] Key daemon running on the deploy host with the mainnet deploy wallet seed unlocked. Socket path canonicalized.
- [ ] `git status` clean on the working tree. `aiken check` in `contracts/` passes with 0 failed tests on the ceremony commit.
- [ ] `deploy/state/mainnet-<releaseTag>.json` does NOT exist (or is archived). Starting fresh.

---

## 1. Capital commitment at a glance

| Bucket | Amount (ADA) | Reclaimable | When recoverable |
|--------|--------------|-------------|------------------|
| 20 reference-script min-UTxO lockup | 962.07 | Yes | V2 migration OR ceremony sunset via `tools/reclaim-refs.ts` |
| 14 stake credential deposits (14 × 2 ADA) | 28.00 | Yes | 14d after `ActDeregisterStake` governance Execute per credential |
| 5 state UTxO seeds (vault, registry, treasury, keeper-auth, governance) | ~27 | Partial | Vault + registry seeds consumed in normal ops; treasury + keeper-auth + governance survive until sunset |
| Network TX fees (42 TXs × ~0.2–1.3 ADA) | ~22 | No | Permanent sunk cost |
| **Total** | **~1,039 ADA** | **~990 ADA reclaimable, ~22 ADA sunk** | |

Mainnet wallet budget recommendation: **≥ 1,000 ADA** (as above, with headroom).

---

## 2. Pre-flight (T-24h)

### 2.1 Build + inspect contracts

```bash
cd contracts
rm -rf build plutus.json
aiken build                      # plain build — NO --trace-level / --trace-filter on mainnet
aiken check                      # all tests pass / 0 failed
```

**Pre-build constants audit** — partial-patch defence. Before `aiken build`, confirm the Preprod-vs-mainnet timelock posture via three greps against `contracts/lib/vault/constants.ak`:

```bash
# 1. Single-flag gate must resolve False on mainnet builds
grep -n "^pub const preprod_fast_timelocks" lib/vault/constants.ak
#    expected: pub const preprod_fast_timelocks: Bool = False

# 2. Spot-check a few timelock conditionals — active branches must be production values
grep -nE "if preprod_fast_timelocks" lib/vault/constants.ak | head
#    each line resolves to the else-branch (`7 * 86_400 * 1_000` etc.) when flag = False

# 3. Confirm no stray Preprod 60s literal sneaked into multisig_gov / registry / treasury / vault_admin_deploy
grep -nE "60_000\b|60 \* 1_000" multisig_gov.ak registry.ak treasury.ak vault_admin_deploy.ak \
       lib/vault/constants.ak
#    only acceptable hits are inside `if preprod_fast_timelocks { 60_000 } else { ... }` arms
```

Record the 24 artefact hashes for cross-check. Compare against:
- `deploy/state/mainnet-hash-preview.txt` — current mainnet-candidate snapshot (regenerate via `aiken build` from the same constants.ak)
- The post-audit baseline (same commit SHA as the external audit report references)

Tightest validators (must remain < 16,384 B Plutus V3 ceiling): vault_protocol 13,691 B / vault_admin_deploy 13,633 B / vault_recall 13,610 B / vault_liqwid 13,604 B. All 24 artefacts have ≥ 2,693 B headroom.

### 2.2 Configure mainnet

Copy `deploy/config/mainnet.example.json` → `deploy/config/mainnet.json`. Fill in:

- `blockfrost.projectIdEnv = "BLOCKFROST_API_KEY"` (and `projectIdBackupEnv = "BLOCKFROST_API_KEY_BACKUP"`).
- `wallet.keyDaemonSocket` — path to the local key daemon socket feeding the mainnet deploy wallet.
- `governance.signers` — 3 real PKHs. Cross-verify with each signer over a secure channel.
- `governance.threshold = 3` (unanimity at launch per whitepaper §5.5).
- `depositToken` — mainnet USDCx policy + name.
- `vaultInitialParams.performanceFeeBps = 450` (4.5% hard cap per constants; NEVER higher).
- `vaultInitialParams.earlyWithdrawFeeBps = 10` (0.1%) or 100 max.
- `vaultInitialParams.minHoldSeconds = 21_600` (6h cap). Consider 3600 (1h) or 0 at launch if you want frictionless early-exit UX; revisit in first governance UpdateFee cycle.
- `vaultInitialParams.bufferTargetBps = 3000` (30% idle buffer target, per whitepaper §5.2 — 45% DJED + 25% USDM + 30% USDCx).
- `vaultInitialParams.maxSlippageBps = 200` (2%), `minSwapPegBps = 9900` (99%).
- `treasuryInitialParams` — audit/ops/rd/buffer bps ratios + monthly caps. Whitepaper §4.3 baseline.

### 2.3 Dry run

```bash
tsx deploy/deploy.ts --network Mainnet --releaseTag v1-mainnet-r0 --dryRun
```

Expected: PHASE 0 fails with "Dry-run cannot pick real UTxO refs." That's the correct dryRun behaviour. It confirms config parses + path resolution works before committing real TXs.

### 2.4 Freeze release tag + state dir

Decide on `releaseTag` (e.g. `v1-mainnet-r0`). All ceremony artefacts (state file, ref-script TX hashes, vault address, Vault NFT policy) are keyed on this tag. Changing it mid-ceremony requires restart from PHASE 0.

Empty or archive `deploy/state/mainnet-<releaseTag>.json` if any stale residue exists. Confirm `git clean -dn deploy/state/` shows no surprises.

---

## 2.5 Preprod pre-flight validation (A+B strategy)

Production timelocks are 7d / 14d / 21d / 48h. A full Preprod E2E running real timelocks would take 21+ days of wall-clock time, which is impractical. The pre-flight validation strategy combines two complementary techniques:

**Toggle pattern** — `contracts/lib/vault/constants.ak` exposes a single `pub const preprod_fast_timelocks: Bool` flag at the top of the file. Every `timelock_*_ms` / `*_cooldown_ms` / `*_period_ms` constant below is a conditional `if preprod_fast_timelocks { 60_000 } else { production_value }`. This replaces an earlier layout with 14 individual `pub const` overrides, which had a partial-patch failure mode where editing one of several related constants while missing a sibling silently broke a Preprod test until manual reverse-engineering surfaced the gap.

- Preprod fast E2E run: set `preprod_fast_timelocks = True` (60s for everything), `aiken build`, deploy a Preprod ceremony, run the full test matrix in under a few hours of wall-clock time.
- Mainnet pre-flight + actual mainnet build: flip back to `preprod_fast_timelocks = False`, `aiken build`, all `timelock_*_ms` resolve to production values; `mainnet-hash-preview.txt` is captured from this build. **One flip, all timelocks consistent. No partial-patch bug class.**
- The §0 precondition above already verifies `False` on the mainnet build commit.

### A. Numeric verification (all 11 governance redeemers)

Goal: confirm `aiken build` produces the correct mainnet hashes, and that on-chain `executable_at_ms = queued_at_ms + production_timelock_ms` for each governance redeemer. This proves the Aiken build pipeline + off-chain TS encoding accept production timelock values without waiting for them to elapse.

```bash
# 0. Flip the timelock flag to False so the Preprod build mirrors mainnet timelocks.
#    Edit lib/vault/constants.ak: pub const preprod_fast_timelocks: Bool = False
#    Then rebuild contracts before deploying the pre-flight ceremony.
( cd contracts && rm -rf build plutus.json && aiken build && aiken check )

# 1. Fresh Preprod ceremony with mainnet timelocks (flag = False).
RELEASE_TAG=v1-preprod-mainnet-cfg BACKDATE_COMPOUND_DAYS=91 \
  npx tsx deploy/deploy.ts --network Preprod --releaseTag v1-preprod-mainnet-cfg

# 2. For each of 11 governance redeemers (UpdateStrategy / UpdateFee / UpdateFeeSplit /
#    UpdateRegistry / UpdateKeeperAuth / TreasurySpend / UpdateTreasuryParams /
#    RotateSigners / SlashBond / DeregisterStake / UpdateSlippagePolicy):
#       a. Build Queue TX → confirm submit + index
#       b. Decode the action's queued_at_ms + executable_at_ms from on-chain GovDatum
#       c. Assert `executable_at_ms - queued_at_ms == production_timelock_ms`
#       d. Cancel the action (any signer can cancel) → free the slot for next test
#
# Iterate via tools/h-*.ts scripts. Numeric assertion is added to each tool's output.
```

Expected result: all 11 redeemers pass numeric assertion. Skip Execute (cannot wait 14d).

### B. Datum-backdate (UpdateFee / UpdateStrategy / UpdateRegistry / UpdateFeeSplit happy paths)

Goal: actually run Queue → wait → Execute end-to-end on Preprod for the most-used governance actions, by initialising the vault datum's relevant `last_*_time` field N days in the past so production timelock is already "elapsed" at deploy time.

The mechanism already exists in `deploy/lib/datumBuilders.ts::BackdateOptions`:
- `feeMs: 14 * 86_400_000` → bypasses `fee_update_cooldown_ms` (UpdateFee 14d cooldown)
- `compoundMs: 91 * 86_400_000` → bypasses Phase L3 sunset 90d threshold (already used)
- (Extend `BackdateOptions` for any additional `last_*` field if a redeemer needs it.)

`deploy/lib/phases.ts` already programmatically refuses backdate flags on Mainnet (`cfg.network === "Mainnet"` throws). Preprod-only by construction.

```bash
# Preprod ceremony with all relevant backdates pre-applied
RELEASE_TAG=v1-preprod-mainnet-bd \
  BACKDATE_COMPOUND_DAYS=91 \
  BACKDATE_FEE_DAYS=15 \
  BACKDATE_STRATEGY_DAYS=8 \
  BACKDATE_FEE_SPLIT_DAYS=22 \
  BACKDATE_REGISTRY_DAYS=15 \
  npx tsx deploy/deploy.ts --network Preprod --releaseTag v1-preprod-mainnet-bd

# Then run h-update-fee / h-update-strategy / h-update-registry / h-update-fee-split
# Queue → Execute roundtrip on this ceremony — production timelock satisfied by datum
# backdating, governance Queue passes immediately, Execute fires after the ~5min Queue
# indexer wait.
```

Expected result: 4 governance redeemers run full Queue+Execute against production timelock values.

### Short timelock paths (no waiting required)

Two governance redeemers have production timelock ≤ 1 hour and remain runnable end-to-end on Preprod without any backdating:
- `EmergencyWithdraw` (timelock 0d, freeze-only) — Queue + Execute in same session
- `FastUpdateMarkets` (timelock 1h, registry market hot-fix) — Queue + wait 1h + Execute

### Pass criteria (all of)

- [ ] `aiken build && aiken check` clean on the Preprod ceremony commit (218 / 0 / 0)
- [ ] `mainnet-hash-preview.txt` matches `aiken build` output byte-for-byte
- [ ] All 20 ref scripts deploy on Preprod (visible via the ceremony's state file under `deploy/state/`)
- [ ] 11 governance redeemers pass numeric assertion (A)
- [ ] 4 high-frequency redeemers pass full Queue+Execute via backdate (B)
- [ ] EmergencyWithdraw + FastUpdateMarkets pass full Queue+Execute on production timelock
- [ ] Reclaim Preprod ceremony refs via `tools/reclaim-refs.ts` (~962 ADA recovered, ~28 ADA stake-deposit recovery via A2 deregister with 14d wait optional)

When all pass criteria are met, the mainnet ceremony is unblocked from a contract-correctness standpoint (other §0 preconditions still apply).

---

## 3. Ceremony execution (T-0)

### 3.1 Single command, resumable

```bash
tsx deploy/deploy.ts --network Mainnet --releaseTag v1-mainnet-r0
```

The script is **idempotent by releaseTag + state file**. Rerunning picks up at the last checkpointed step. Partial failures do NOT require manual cleanup — the state file captures (reserved UTxO refs / compiled hashes / minted NFTs / ref-script TX hashes / stake registrations / state UTxO initializations) piecewise.

**Built-in safety patches active in this script** — operators inheriting older mental models from earlier deploy.ts iterations should be aware:

- `deployRefScript.ts::consolidateTokensIfNeeded` raises an actionable error (`pure-ADA pool 0 ADA < target N ADA … run scrub-deploy-wallet.ts then re-launch deploy.ts`) instead of the prior opaque `change too small: -N` mask. If you see this error mid-ceremony, run the scrub once and resume — the state file picks up where it left off.
- `phases.ts::runPhase4aStakeRegs` no longer relies on Lucid's wallet coin selector. It calls `fetchPureAdaUtxosForStakeReg(addr, bfUrl, bfKey)` directly against Blockfrost (with the same multi-key rotation as the rest of deploy.ts), filters out scriptRef-bearing + token-carrying + < 3 ADA UTxOs, and uses `tx.collectFrom([cleanFeeUtxo])` to pin inputs. This closes a class of ref-script destruction observed when Lucid's coin selector consumed scriptRef UTxOs as fee inputs and dropped the script in change.
- PHASE 4a auto-retries `ConwayMempoolFailure "All inputs are spent"` (Blockfrost indexer-lag race) up to 5 times with 30s sleep between attempts, using a queue-based `while` loop with `queue.unshift` to re-process the same target after the indexer catches up. Operator does NOT need to intervene unless 5 retries are exhausted on the same stake registration.

### 3.2 Phase map (42 TXs)

| Phase | Step keys | TX count | Duration |
|-------|-----------|----------|----------|
| PHASE 0 | `pickUtxoRefs` | 0 (offline reservation) | <1s |
| PHASE 1 | `compile` | 0 (offline hash derivation) | 5-10s |
| PHASE 2 | `mintVaultNft`, `mintGovNft`, `mintRegistryAuthNft` | 3 | 30-60s |
| PHASE 3 | `refScript:<20 artefacts>` | 20 | 5-8 min |
| PHASE 4a | `registerStake:<14 credentials>` | 14 | 3-5 min |
| PHASE 4b | `initRegistry`, `initTreasury`, `initKeeperAuth`, `initGovernance`, `initVault` | 5 | 2-4 min |
| **Total** | | **42** | **10-15 min** |

Ceremony wait breakdown: TX submit (fast) + indexer wait (~10s per TX on Blockfrost mainnet) + one-shot NFT deadline margin (14400ms = 4h, set generously in deploy script).

### 3.3 Signatures

V1 ceremony mainnet uses **single-key deploy wallet signing**. The 3 governance signers do NOT sign ceremony TXs directly — the deploy wallet is the ceremony signer. Governance signatures enter the picture post-ceremony via the first `UpdateStrategy` / `UpdateFee` cycles.

For hardware-wallet governance signing (after the ceremony), see `deploy/tools/h-*` and `a2-*-deregister` tool CLI documentation.

### 3.4 Monitor progress

```bash
# In a second terminal while deploy.ts runs:
watch -n 10 'jq ".phase, .step, .lastTxHash" deploy/state/mainnet-v1-mainnet-r0.json'
```

Or tail the deploy log output for `[STEP] PHASE X: …` markers.

---

## 4. Partial failure handling

### 4.1 Most common failures (in order of likelihood)

1. **Blockfrost 402 quota exhausted** mid-ceremony.
   - Action: wait until quota resets (00:00 UTC next day) or switch to backup key (update `BLOCKFROST_API_KEY_BACKUP` env var, no code change needed — the blockfrostProvider rotates automatically).
   - Resume: re-run the same `tsx deploy/deploy.ts --network Mainnet --releaseTag v1-mainnet-r0` command. State file resumes from last checkpoint.

2. **Blockfrost indexer slow to see the just-submitted TX** (`BadInputsUTxO` on next TX attempting to spend a change UTxO from the previous TX).
   - Action: the script has built-in 60s+ wait after each TX submit. If a fresh `BadInputsUTxO` error appears, retry — the state file has the committed TX hash, and next invocation will see the UTxO.

3. **PHASE 4a `ConwayMempoolFailure "All inputs are spent"` after the 5x auto-retry exhaust**.
   - Cause: indexer lag exceeded the 5×30s window (rare; usually means Blockfrost is degraded). The script now writes per-target progress to the state file before throwing, so re-running deploy.ts only needs to redo the failed registration(s).
   - Action: wait 5–10 minutes for the indexer to settle, then re-run deploy.ts. Confirm the resumed run picks up at the failed `registerStake:<credential>` step.

4. **`deployRefScript` consolidator pool=0 actionable error** mid-PHASE-3.
   - Cause: prior PHASE-3 ref publishes drained the wallet's pure-ADA pool to 0 (only token-tank UTxOs remain). The consolidator can't re-fold tanks without a fresh pure-ADA input to absorb the TX fee.
   - Action: stop deploy.ts (Ctrl-C, the state file is preserved). Run `tsx deploy/tools/scrub-deploy-wallet.ts --network Mainnet --releaseTag v1-mainnet-r0` once — it consolidates dust + reserves a fresh pure-ADA UTxO. Re-run `deploy.ts`; it resumes at the last checkpointed ref-script step.

5. **`EPERM: operation not permitted` on tsx socket creation** (sandbox mode).
   - Action: disable sandbox for this command. Not normally an issue on bare-metal deploy host.

6. **Key daemon disconnect mid-ceremony**.
   - Action: verify daemon still running, socket still valid. Restart daemon ONLY if operator can manually re-enter the unlock password. Never restart silently.

### 4.2 One-shot NFT validity-range expiry

The 3 one-shot NFT mint TXs in PHASE 2 use a 4-hour validity range (`upperSlot = now + 14400000ms`). If the ceremony stalls for longer than 4h between PHASE 0 (UTxO reservation) and PHASE 2 (NFT mint), the NFT mint TX's validity window has expired and cannot be re-broadcast — that reserved UTxO is no longer mintable.

Recovery: start a NEW ceremony with a NEW `releaseTag`. The old state file is stranded but harmless. The previously reserved UTxO is still in the deploy wallet (unspent) and becomes free to reserve again under the new releaseTag.

**Prevention**: don't interrupt the ceremony. It's designed to run unattended for 10-15 min.

### 4.3 Governance NFT mint collision

Very unlikely but possible: two operators run ceremonies concurrently on the same deploy wallet, both reserve the same UTxO ref for the `governance_nft` mint, one wins the race.

Recovery: the losing run re-reserves a different UTxO ref and proceeds.

**Prevention**: only one operator runs the mainnet ceremony at a time.

---

## 5. Post-ceremony verification

### 5.1 On-chain sanity checks

After the deploy script completes (or hits a final success log line), verify from an independent Blockfrost query:

```bash
# Vault UTxO — should carry Vault NFT + 15M lovelace + initial datum
VAULT_ADDR=$(jq -r ".stateUtxos.vault.address" deploy/state/mainnet-v1-mainnet-r0.json)
curl -s -H "project_id: $BLOCKFROST_API_KEY" \
  "https://cardano-mainnet.blockfrost.io/api/v0/addresses/$VAULT_ADDR/utxos" | jq .

# Registry UTxO — should carry Registry Auth NFT + 3M lovelace + initial datum
REGISTRY_ADDR=$(jq -r ".stateUtxos.registry.address" deploy/state/mainnet-v1-mainnet-r0.json)
curl -s -H "project_id: $BLOCKFROST_API_KEY" \
  "https://cardano-mainnet.blockfrost.io/api/v0/addresses/$REGISTRY_ADDR/utxos" | jq .

# Governance UTxO — should carry Governance NFT + initial GovDatum with 3 signers + threshold 3
GOV_ADDR=$(jq -r ".stateUtxos.governance.address" deploy/state/mainnet-v1-mainnet-r0.json)
curl -s -H "project_id: $BLOCKFROST_API_KEY" \
  "https://cardano-mainnet.blockfrost.io/api/v0/addresses/$GOV_ADDR/utxos" | jq .

# 20 ref scripts at the deploy wallet — each should have the expected size
DEPLOY_ADDR=$(cardano-cli ... /wallet address ...)
curl -s -H "project_id: $BLOCKFROST_API_KEY" \
  "https://cardano-mainnet.blockfrost.io/api/v0/addresses/$DEPLOY_ADDR/utxos" | \
  jq 'map(select(.reference_script_hash)) | length'
# Expected: 20
```

### 5.2 Keeper / API backfill

After the ceremony, the following backend systems need the new mainnet ceremony addresses:

- [ ] **Keeper `.env`** — update:
  - `VAULT_ADDR`, `VAULT_NFT_POLICY`, `VUSDCX_POLICY`, `REGISTRY_ADDR`, `TREASURY_ADDR`, `GOVERNANCE_ADDR`, `KEEPER_AUTH_ADDR`
  - `PROXY_REF_SCRIPT_TX`, `USER_REF_SCRIPT_TX`, … (20 ref script TX hashes)
  - `EXPECTED_PROXY_HASH`, `EXPECTED_VAULT_USER_HASH`, …
- [ ] **API `.env`** — same set (API reads subset).
- [ ] **Key daemon mainnet socket** — persistent across host reboots (systemd unit or equivalent).
- [ ] **Restart keeper && restart api** after env sync.
- [ ] **Frontend** (`v1/reference/frontend/`) — set `VITE_NETWORK=mainnet` + per-field `VITE_*` env vars from `deploy/state/mainnet-<releaseTag>.json` (proxyAddr / vaultNftPolicy / vusdcxPolicy / registryAddr / registryAuthPolicy / liqwidMarketPolicy). The `MAINNET_PRESET` in `src/lib/v1Config.ts` already pins the canonical mainnet USDCx token (`1f3aec8b…`) — only ceremony-derived values need filling. `VITE_NETWORK=mainnet bash deploy.sh` rebuilds + Cloudflare Pages publishes.
- [ ] **Withdraw CLI** (`v1/reference/withdraw-cli/`) — replace `config/mainnet.json` (currently a placeholder with `_comment: "V1 mainnet ceremony has not been performed yet."`) with the published mainnet ceremony JSON (`deploy/state/mainnet-<releaseTag>.json` content). `npm run build && npm publish` republishes the package.
- [ ] **Emergency Withdraw SPA** (`v1/reference/emergency-withdraw/`) — copy `deploy/state/mainnet-<releaseTag>.json` to `public/v1-deploy-state.json`, then `vite build` + Cloudflare Pages publish (or expose via Worker URL via `?config=` query string).
- [ ] **Worker** (`v1/reference/worker/`) — if used for keeper-publish history (Block 4), update `AUTHORIZED_PKHS` Worker secret with the mainnet keeper PKH(s).

All of the above values are available in `deploy/state/mainnet-v1-mainnet-r0.json`; a sync script can auto-populate them (see `deploy/tools/backfill-vps-env.ts` — to be written after first successful Preprod ceremony end-to-end).

### 5.3 Smoke test

Pre-announce the ceremony completion is "cosmetic only — no depositors yet" for 6-12h. During that window:

- [ ] Operator deposits 15 USDCx (min_deposit). Verify `vUSDCx` arrives in operator wallet with correct share_price.
- [ ] Operator waits 6h (min_hold_seconds), withdraws 5 USDCx. Verify settlement amount ≈ 5 USDCx minus 0.1% early-withdraw fee if any.
- [ ] Operator waits 24-48h, verifies keeper runs a `Compound` cycle (even if zero-yield, the `last_compound_time` should advance).

Only after all three pass, announce the vault "open for deposits" to the pre-audit closed / community channels.

### 5.4 Governance first action (T+1 week)

Queue + Execute a benign `UpdateStrategy` with no actual allocation change (just `new_allocations = current_allocations, new_buffer_target_bps = current`) to verify the 3-sig workflow works end-to-end with the production hardware wallets. 7-day timelock applies. If the 3 signers can't sync to unanimously sign the Execute TX, that's a governance liveness problem worth catching BEFORE there's a real governance action needed.

---

## 6. Sunset / V2 migration

V1 is explicitly permissioned to sunset per whitepaper §9.2. The sunset path:

1. Governance queues `ActUpdateFee(performanceFeeBps=0, earlyWithdrawFeeBps=0, minHoldSeconds=0)`. 14d timelock.
2. Governance queues 14 `ActDeregisterStake` actions (one per staking credential). 14d timelock each.
3. Governance executes all 14 `ActDeregisterStake` after timelock. Each returns 2 ADA to the deploy wallet.
4. Governance announces 90d window for depositors to exit via normal `Withdraw` path.
5. After 90d, governance queues `ActEmergencyWithdraw` with `freeze=1`. Depositors who didn't exit during the window get migrated to V2 via V2 ceremony's deposit + migration script.
6. Operator runs `tsx deploy/tools/reclaim-refs.ts --network Mainnet --releaseTag v1-mainnet-r0` to reclaim the ~962 ADA ref-script lockup. Fresh TX with CML body rebuild workaround for Lucid's Conway ref-script fee bug.

Total ADA recoverable on sunset: ~990 ADA (~962 ref-scripts + 28 stake deposits). ~49 ADA sunk cost over the vault's lifetime (state UTxO seeds + network fees).

---

## 7. Open questions before first mainnet ceremony

These are non-blocking but worth resolving at external audit handoff:

- **Minswap V2 adapter decoder**: `spec/swap-adapter.md §9` specifies byte-for-byte verification against real mainnet TXs. That verification has not been done (it will require spending some TX on mainnet Minswap V2 with matching payload structures and comparing the adapter's decode against the on-chain datum format). Must happen before governance populates `swap_adapter_hashes` with the mainnet adapter.
- **Preprod pre-flight evidence**: a recent Preprod ceremony with `preprod_fast_timelocks = True` completed all 42 ceremony TXs with zero ref-script destruction, all 14 stake registrations confirmed, and an `ActAdminDeployNonDeposit` Queue action chain-verified end-to-end — demonstrating that the single-flag timelock gate wires through to `multisig_gov::min_timelock_ms` correctly. The mainnet ceremony is the same `deploy.ts` codepath with the flag flipped to `False`; no other deploy-side code differences between Preprod and Mainnet.
- **`valid_allocs × MergeUtxo donation gap` fix** (full description in `SECURITY.md` §"Known open findings"): Option A fix (~6 LOC in `vault_recall.MergeUtxo`) queued for next contract revision. If deployed before mainnet, changes `vault_recall` hash → one ref-script rewrite + one A2 deregister/re-register cycle. If deployed post-mainnet, a V2 migration is needed. Recommend: include in pre-mainnet revision.
- **Backfill automation**: the manual env-sync flow in §5.2 is error-prone. A `backfill-env.ts` tool to auto-generate `.env` content from state file should be written and tested on Preprod before mainnet.
- **3-sig governance signing protocol**: need a documented off-chain communication protocol for the 3 signers to coordinate on Queue/Execute payload_hash verification (how they independently reconstruct the payload, compare hashes, and sign only after consensus). This is a social-engineering surface, not a contract surface, but it's the critical governance-liveness piece.

---

## 8. Contact + escalation

Emergency contact for ceremony stalls: `optivaults@gmail.com` (PGP key on optivaults.app/security) + direct Discord to the on-duty operator.

Never commit a ceremony state file or mainnet config containing real signer PKHs / Blockfrost keys / wallet addresses to the public `optivaults-protocol` repo. The `.gitignore` covers `deploy/state/*.json`, `deploy/config/preprod.json`, and `deploy/config/mainnet.json` — verify before `git push` and keep operator-only material in your local `.env` or out-of-tree storage.
