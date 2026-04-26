# V1 Mainnet Ceremony Runbook

**Purpose**: end-to-end procedure for the one-time V1 mainnet deploy ceremony.
**Audience**: operator executing the deploy. Assumes familiarity with `spec/architecture.md` + `docs/security-model.md` + having completed at least one full Preprod dry-run (`v1-preprod-p3` or later).
**Status**: pre-launch draft. Refine with concrete TX fees + mainnet protocol parameter deltas after next Preprod ceremony passes end-to-end.

---

## 0. Non-negotiable preconditions

Do NOT start this ceremony if any of these are false:

- [ ] External audit completed (Q2-Q3 2027 target — see `audit-scope.md §5`). All CRITICAL/HIGH findings remediated. Audit report published and reviewed by governance signers.
- [ ] `contracts/lib/vault/constants.ak::timelock_deregister_stake_ms` reverted to `14 * 86_400 * 1_000` (14 days). Preprod override removed. Hash diff vs. any Preprod build expected on multisig_gov only; but re-run `aiken build` and compare all 22 artefacts — anything unexpected aborts.
- [ ] Minswap V2 adapter decoder byte-for-byte verified against real mainnet TXs per `spec/swap-adapter.md §9`.
- [ ] Governance signers confirmed: 3 distinct real key holders, each with independent hardware wallet (per whitepaper §5.5). Threshold 3 (unanimity at launch). PKHs documented in `deploy/config/mainnet.json` and cross-verified by each signer.
- [ ] Deploy wallet has ≥ 1,000 ADA. 944 ADA goes into the ceremony (ref-scripts ~870 ADA + stake deposits 24 ADA + state seeds 27 ADA + network fees ~22 ADA); 50+ ADA headroom for retry + indexer wait + contingency.
- [ ] Deploy wallet has ≥ 15 USDCx (`1f3aec8b…` policy; actual mainnet deposit token) for the vault seed. Verified not-frozen on Circle side.
- [ ] Blockfrost Mainnet quota: ≥ 2,000 requests headroom (ceremony consumes ~400–600 requests over 10–15 min).
- [ ] Key daemon running on the deploy host with the mainnet deploy wallet seed unlocked. Socket path canonicalized.
- [ ] `git status` clean on the working tree. `aiken check` in `contracts/` passes 194 tests / 689 checks / 0 errors.
- [ ] `deploy/state/mainnet-<releaseTag>.json` does NOT exist (or is archived). Starting fresh.

---

## 1. Capital commitment at a glance

| Bucket | Amount (ADA) | Reclaimable | When recoverable |
|--------|--------------|-------------|------------------|
| 18 reference-script min-UTxO lockup | 871.51 | Yes | V2 migration OR ceremony sunset via `tools/reclaim-refs.ts` |
| 12 stake credential deposits (12 × 2 ADA) | 24.00 | Yes | 14d after `ActDeregisterStake` governance Execute per credential |
| 5 state UTxO seeds (vault, registry, treasury, keeper-auth, governance) | ~27 | Partial | Vault + registry seeds consumed in normal ops; treasury + keeper-auth + governance survive until sunset |
| Network TX fees (27-30 TXs × ~0.2–1.3 ADA) | ~22 | No | Permanent sunk cost |
| **Total** | **~944.51 ADA** | **~922 ADA reclaimable, ~22 ADA sunk** | |

Mainnet wallet budget recommendation: **≥ 1,000 ADA** (as above, with headroom).

---

## 2. Pre-flight (T-24h)

### 2.1 Build + inspect contracts

```bash
cd contracts
rm -rf build plutus.json
aiken build
aiken check                      # 194 tests / 689 checks / 0 failed
```

Record the 22 artefact hashes for cross-check. Compare against the post-audit baseline (same commit SHA as audit report references).

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
- `vaultInitialParams.bufferTargetBps = 3500` (35% idle buffer target, per whitepaper §5.2 — 45% DJED + 25% USDM + 30% USDCx; the 30/35 pick is a governance choice).
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

## 3. Ceremony execution (T-0)

### 3.1 Single command, resumable

```bash
tsx deploy/deploy.ts --network Mainnet --releaseTag v1-mainnet-r0
```

The script is **idempotent by releaseTag + state file**. Rerunning picks up at the last checkpointed step. Partial failures do NOT require manual cleanup — the state file captures (reserved UTxO refs / compiled hashes / minted NFTs / ref-script TX hashes / stake registrations / state UTxO initializations) piecewise.

### 3.2 Phase map (27-30 TXs)

| Phase | Step keys | TX count | Duration |
|-------|-----------|----------|----------|
| PHASE 0 | `pickUtxoRefs` | 0 (offline reservation) | <1s |
| PHASE 1 | `compile` | 0 (offline hash derivation) | 5-10s |
| PHASE 2 | `mintVaultNft`, `mintGovNft`, `mintRegistryAuthNft` | 3 | 30-60s |
| PHASE 3 | `refScript:<18 validators>` | 18 | 5-8 min |
| PHASE 4a | `registerStake:<12 credentials>` | 12 | 3-5 min |
| PHASE 4b | `initRegistry`, `initTreasury`, `initKeeperAuth`, `initGovernance`, `initVault` | 5 | 2-4 min |
| **Total** | | **38** | **10-15 min** |

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

3. **`EPERM: operation not permitted` on tsx socket creation** (sandbox mode).
   - Action: disable sandbox for this command. Not normally an issue on bare-metal deploy host.

4. **Key daemon disconnect mid-ceremony**.
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

# 18 ref scripts at the deploy wallet — each should have the expected size
DEPLOY_ADDR=$(cardano-cli ... /wallet address ...)
curl -s -H "project_id: $BLOCKFROST_API_KEY" \
  "https://cardano-mainnet.blockfrost.io/api/v0/addresses/$DEPLOY_ADDR/utxos" | \
  jq 'map(select(.reference_script_hash)) | length'
# Expected: 18
```

### 5.2 VPS / keeper / API backfill

After the ceremony, the following backend systems need the new mainnet ceremony addresses:

- [ ] **VPS keeper `.env`** — update:
  - `VAULT_ADDR`, `VAULT_NFT_POLICY`, `VUSDCX_POLICY`, `REGISTRY_ADDR`, `TREASURY_ADDR`, `GOVERNANCE_ADDR`, `KEEPER_AUTH_ADDR`
  - `PROXY_REF_SCRIPT_TX`, `USER_REF_SCRIPT_TX`, … (18 ref script TX hashes)
  - `EXPECTED_PROXY_HASH`, `EXPECTED_VAULT_USER_HASH`, …
- [ ] **VPS API `.env`** — same set (API reads subset).
- [ ] **Key daemon mainnet socket** — persistent across VPS reboots (systemd unit or equivalent).
- [ ] **pm2 restart keeper && pm2 restart api** on VPS after env sync.
- [ ] **Frontend `optivaults/frontend/src/config/mainnet.ts`** — vault address, Vault NFT policy, vUSDCx policy, registry address.

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
2. Governance queues 12 `ActDeregisterStake` actions (one per staking credential). 14d timelock each.
3. Governance executes all 12 `ActDeregisterStake` after timelock. Each returns 2 ADA to the deploy wallet.
4. Governance announces 90d window for depositors to exit via normal `Withdraw` path.
5. After 90d, governance queues `ActEmergencyWithdraw` with `freeze=1`. Depositors who didn't exit during the window get migrated to V2 via V2 ceremony's deposit + migration script.
6. Operator runs `tsx deploy/tools/reclaim-refs.ts --network Mainnet --releaseTag v1-mainnet-r0` to reclaim the 871 ADA ref-script lockup. Fresh TX with CML body rebuild workaround for Lucid's Conway ref-script fee bug.

Total ADA recoverable on sunset: ~895 ADA (871 ref-scripts + 24 stake deposits). ~49 ADA sunk cost over the vault's lifetime (state UTxO seeds + network fees).

---

## 7. Open questions before first mainnet ceremony

These are non-blocking but worth resolving at external audit handoff:

- **`timelock_deregister_stake_ms` production value**: constants.ak has a Preprod override at 1h; production is 14d. Runbook `§0` enforces the revert but a `grep` hook in CI or an explicit mainnet-build sanity check would be safer.
- **Minswap V2 adapter decoder**: `spec/swap-adapter.md §9` specifies byte-for-byte verification against real mainnet TXs. That verification has not been done (it will require spending some TX on mainnet Minswap V2 with matching payload structures and comparing the adapter's decode against the on-chain datum format). Must happen before governance populates `swap_adapter_hashes` with the mainnet adapter.
- **R73 `valid_allocs × MergeUtxo donation gap` fix** (full description in `SECURITY.md` §"Known open findings"): Option A fix (~6 LOC in `vault_recall.MergeUtxo`) queued for next contract revision. If deployed before mainnet, changes `vault_recall` hash → one ref-script rewrite + one A2 deregister/re-register cycle. If deployed post-mainnet, a V2 migration is needed. Recommend: include in pre-mainnet revision.
- **VPS backfill automation**: the manual env-sync flow in §5.2 is error-prone. `backfill-vps-env.ts` tool to auto-generate `.env` content from state file should be written and tested on Preprod before mainnet.
- **3-sig governance signing protocol**: need a documented off-chain communication protocol for the 3 signers to coordinate on Queue/Execute payload_hash verification (how they independently reconstruct the payload, compare hashes, and sign only after consensus). This is a social-engineering surface, not a contract surface, but it's the critical governance-liveness piece.

---

## 8. Contact + escalation

Emergency contact for ceremony stalls: `optivaults@gmail.com` (PGP key on optivaults.app/security) + direct Discord to the on-duty operator.

Never commit a ceremony state file or mainnet config containing real signer PKHs / Blockfrost keys / wallet addresses to the public `optivaults-protocol` repo. The `.gitignore` covers `deploy/state/*.json`, `deploy/config/preprod.json`, and `deploy/config/mainnet.json` — verify before `git push` and keep operator-only material in your local `.env` or out-of-tree storage.
