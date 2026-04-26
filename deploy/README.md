# V1 Deploy Pipeline

Parameterised Preprod / Mainnet deploy ceremony for the V1 Aiken contracts.

---

## Layout

```
deploy/
├── config/
│   ├── preprod.example.json    Template for Preprod
│   ├── mainnet.example.json    Template for Mainnet
│   ├── preprod.json            (gitignored — your real Preprod config)
│   └── mainnet.json            (gitignored — your real Mainnet config)
├── lib/
│   ├── config.ts               Config loader + validation
│   └── state.ts                Ceremony state checkpoint
├── state/                       (gitignored — runtime state per release)
├── compile.ts                  Apply params to 22 artefacts (17 logic + 4 NFT + 1 adapter) (offline)
├── deploy.ts                   Ceremony orchestrator (online)
└── README.md                   This file
```

---

## Status

- ✅ Config loader + validation (`lib/config.ts`) — supports `keyDaemonSocket` + env-var Blockfrost key (no secrets in the JSON).
- ✅ State checkpoint manager (`lib/state.ts`) — tracks mints, ref scripts, stake registrations, and state UTXOs.
- ✅ Offline compile step (`compile.ts`) — applies parameters to all **22 artefacts** (17 logic validators + 4 NFT mint policies + 1 DEX adapter) per the dependency graph, outputs `state/<network>-hashes.json` with every on-chain hash the ceremony will produce.
- ✅ Datum builders (`lib/datumBuilders.ts`) — pure, testable Constr builders for RegistryDatum (9 fields post §5.4 P3 + B@launch=1) / TreasuryDatum / KeeperAuthDatum / GovDatum / VaultDatum (29-field V1 schema post §5.4 P2 slippage caps + Phase 1 dead-man-switch).
- ✅ Phase functions (`lib/phases.ts`) — idempotent PHASE 2 (3 NFT mints + minswap_v2_adapter), PHASE 3 (**18 ref scripts**), PHASE 4a (**12 stake credential registrations**), PHASE 4b (5 state UTXO inits).
- ✅ Ceremony orchestrator (`deploy.ts`) — wires PHASE 0 → 4b end-to-end with resume-after-failure semantics per step.
- ⚠️ **Preprod verification status**: An earlier v1-a2-preprod ceremony was captured on a smaller validator topology and is STALE relative to the current 12-staking-credential / 18-ref-script set. Full re-verification required on the current topology before mainnet — see §11 in README.md Troubleshooting.

---

## Parameterisation

Every environment-specific value lives in `config/<network>.json`:

| Field                                    | Why it is environment-specific                 |
|------------------------------------------|------------------------------------------------|
| `blockfrost.url` / `projectId`           | Different Blockfrost host + key per network    |
| `wallet.seedPhrase`                      | Different deploy wallet per network            |
| `depositToken.policy` / `.name`          | USDCx on mainnet; test asset on Preprod        |
| `governance.signers` / `.threshold`      | Different real PKHs per network; threshold = 3 at launch for both per whitepaper §5.5 |
| `governance.governanceNftAssetName`      | Shared string but kept parameterised for future rebrand |
| `registryInitialParams.keeperPkh`        | Founder keeper PKH                              |
| `keeperAuthInitialParams.authorizedPkhs` | Founder keeper PKH                              |
| `vaultInitialParams.*`                   | Launch fee parameters (same math, separately set) |
| `treasuryInitialParams.*`                | Launch treasury split                           |
| `ceremonyOptions.awaitConfirmSeconds`    | Preprod 90s / Mainnet 120s (indexer lag)        |

`lib/config.ts` enforces the validator-level hard caps at config-load time so the ceremony cannot even start with an invalid config:

- `performance_fee_bps ≤ 450`   (4.5% perf cap)
- `early_withdraw_fee_bps ≤ 100` (1% cap)
- `min_hold_seconds ≤ 21600`   (6 hours — tightened from 24h post-internal-audit)
- `keeper_fee_bps ≤ 4000`, `gov_fee_bps ≤ 1000`, `keeper + gov ≤ 5000`
- `governance.threshold ∈ [2, signers]`, unanimity allowed (3-of-3 launch)
- `treasury inflow bps` must sum to 10000, `audit_bps ≥ 2000`
- `signers` must be 3–20 entries, all distinct, each valid 28-byte PKH hex
- `depositToken.policy` must be valid 28-byte hex
- Placeholder strings (`REPLACE_WITH_`, `TBD`, etc.) reject

---

## Quick start (Preprod)

```bash
# 1. Build V1 contracts (produces plutus.json)
cd contracts && rm -rf build plutus.json && aiken build && cd -

# 2. Copy the Preprod template and fill in your real values
cp deploy/config/preprod.example.json deploy/config/preprod.json
# Edit deploy/config/preprod.json:
#   - blockfrost.projectId   — your preprod Blockfrost key
#   - wallet.seedPhrase      — deploy wallet BIP39 seed (24 words)
#   - depositToken.policy/name — test USDCx token you'll use on Preprod
#   - governance.signers[0..2] — 3 PKH (28-byte hex) for test signers
#   - keeperAuthInitialParams.authorizedPkhs[0] — keeper PKH
#   - registryInitialParams.keeperPkh — same keeper PKH

# 3. Fund the deploy wallet (Preprod faucet → ≥ 500 ADA + test USDCx)
#    https://docs.cardano.org/cardano-testnet/tools/faucet

# 4. Dry-run: see the compiled hashes + UTxO-ref plan without submitting TXs
npx tsx deploy/deploy.ts --network Preprod --releaseTag v1-preprod-rc1 --dryRun

# 5. (When PHASE 2-4 is wired) Live ceremony
npx tsx deploy/deploy.ts --network Preprod --releaseTag v1-preprod-rc1

# 6. If the ceremony fails mid-way:
#    - Inspect state/preprod-v1-preprod-rc1.json
#    - Re-run the same command (resumes from last successful step)
#    - OR: --reset to archive state and start over
```

### Compile-only (offline)

Useful for (a) ceremony rehearsal (b) publishing "here's what the hashes WILL be" ahead of a mainnet announcement.

```bash
# Prepare a UTxO-refs file — for rehearsal you can use arbitrary placeholder
# refs; at real deploy time deploy.ts picks them from the wallet automatically.
cat > /tmp/utxorefs.json <<EOF
{
  "vaultNft":        { "txHash": "${'0'.repeat(64)}", "outputIndex": 0 },
  "governanceNft":   { "txHash": "${'0'.repeat(64)}", "outputIndex": 1 },
  "registryAuthNft": { "txHash": "${'0'.repeat(64)}", "outputIndex": 2 }
}
EOF

npx tsx deploy/compile.ts --network Preprod --utxoRefs /tmp/utxorefs.json
# outputs: deploy/state/preprod-hashes.json
#        + deploy/state/preprod-hashes-full.json (with applied CBOR)
```

---

## Dependency graph (what `compile.ts` walks)

```
                   utxo_ref_0                utxo_ref_1             utxo_ref_2
                       │                         │                      │
                       ▼                         ▼                      ▼
                  vault_nft                gov_nft               registry_auth_nft
                  (policy)                 (policy+name)           (policy+name)
                       │                         │                      │
                       │           ┌─────────────┘                      │
                       │           ▼                                    │
                       │      keeper_stake_script(gov_nft,gov_name)     │
                       │           │                                    │
                       │           │    ┌──deposit_token──┐             │
                       │           │    ▼                 ▼             │
                       │           │ treasury(dep_pol,dep_name)         │
                       │           │    │                               │
                       │           │    ├─vault_user(gov,govN)         │  (permissionless: Deposit + Withdraw)
                       │           │    ├─vault_keeper_hot(…,treasury,…)│  (Compound + RebalanceBuffer)
                       │           │    ├─vault_batcher(keeper,gov,…)   │  (BatchProcess)
                       │           │    ├─vault_swap_ada(…,treasury,…)  │  (SwapAda + dual-feed oracle)
                       │           │    ├─vault_protocol(keeper,gov,…)  │  (DeployToProtocol)
                       │           │    ├─vault_recall(keeper,gov,…)    │  (RecallFromProtocol + MergeUtxo)
                       │           │    ├─vault_liqwid(keeper,gov,…)    │
                       │           │    ├─vault_gov_policy(gov,govN)    │  (UpdateStrategy/Fee/FeeSplit/SlippagePolicy)
                       │           │    ├─vault_gov_emergency(gov,govN) │  (EmergencyWithdraw)
                       │           │    ├─vault_admin_deploy(gov,govN)  │  (AdminDeployNonDeposit)
                       │           │    ├─minswap_v2_adapter (unparam'd)│  (§B@launch=1 SwapAdapter)
                       │           │    │                               │
                       ▼           ▼    ▼                               │
              vault_proxy(11 params: user, keeperHot, swapAda, protocol, recall,
                          liqwid, govPolicy, govEmergency, adminDeploy, batcher,
                          vault_nft_policy)                              │
                       │                                                 │
           ┌───────────┼───────────┐                                     │
           ▼           ▼           ▼                                     │
       order(vault,nft) vusdcx(vault,nft)                                │
                                                                          │
    multisig_gov(gov_nft,gov_name,dep_pol,dep_name,treasury_hash)         │
                                                                          │
    registry (unparameterised — but registry_auth NFT gate is above)──────┘
```

**22 compiled artefacts total**:
- 4 one-shot NFT minting policies (vault_nft, governance_nft, registry_auth_nft, gov_signer_nft)
- 17 spend / withdraw validators (vault_proxy + 12 WZ-dispatched staking validators + treasury + keeper_stake_script + multisig_gov + registry + order + vusdcx)
- 1 DEX adapter (minswap_v2_adapter, §B@launch=1 SwapAdapter)

Partitioning rationale (4 orthogonal seams: authorization-boundary / response-latency / bytecode-cost-center / size-fix) is documented in `spec/architecture.md §4.1`. Per-extraction details live in the engineering memory store.

---

## Ceremony state format

`state/<network>-<releaseTag>.json` (human-readable; gitignored):

```json
{
  "network": "Preprod",
  "releaseTag": "v1-preprod-rc1",
  "startedAt": "...",
  "lastUpdatedAt": "...",
  "mints": {
    "vaultNft": { "txHash": "...", "utxoRef": {...}, "policyId": "...", "assetName": "..." },
    "governanceNft": {...},
    "registryAuthNft": {...}
  },
  "hashes": { ... all 23 compiled hashes (17 logic + 4 NFT + 1 adapter + governanceNftName + registryAuthName) ... },
  "refScripts": {
    "vaultProxy":      { "txHash": "...", "outputIndex": 0, "scriptHash": "...", "sizeBytes": 4576, "minAda": "..." },
    "vaultUser":       {...},
    "vaultKeeperHot":  {...},
    "vaultBatcher":    {...},
    "vaultSwapAda":    {...},
    "vaultProtocol":   {...},
    "vaultRecall":     {...},
    "vaultLiqwid":     {...},
    "vaultGovPolicy":  {...},
    "vaultGovEmergency": {...},
    "vaultAdminDeploy": {...},
    "keeperStakeScript": {...},
    "treasury":        {...},
    "multisigGov":     {...},
    "registry":        {...},
    "order":           {...},
    "vusdcx":          {...},
    "minswapV2Adapter": {...}   // §B@launch=1 SwapAdapter
    // 18 entries total — one per logic validator + 1 adapter
  },
  "stateUtxos": {
    "registry": {...}, "treasury": {...}, "keeperAuth": {...},
    "governance": {...}, "vault": {...}
  }
}
```

Each step writes to state immediately after its TX confirms. Re-running the ceremony after a failure: the loader reads the file, notices which step keys are present, and skips those — resuming from the first empty slot. No manual state editing required in the normal case.

---

## Known open items

1. **Datum encoders for the 5 state UTxOs** — shape is correct in `deploy.ts` RegistryDatum example, but Treasury / KeeperAuth / Governance / Vault full encoders still need per-field testing against the contract-side `Data`-parsing expectations.
2. **Staking credential registration** — post Phase 77b/77c/77d there are **12 staking credentials** needing `certificates.registerStake` TXs: `vault_user` / `vault_keeper_hot` / `vault_batcher` / `vault_swap_ada` / `vault_protocol` / `vault_recall` / `vault_liqwid` / `vault_gov_policy` / `vault_gov_emergency` / `vault_admin_deploy` / `keeper_stake_script` / `minswap_v2_adapter`. `runPhase4aStakes` in `lib/phases.ts` handles all 12 (one per stake cred × 12 TX, each reclaims its 2 ADA via A2 deregister `publish` handler post-sunset).
3. **Publishing ref scripts for vault_nft / governance_nft / registry_auth_nft** — currently we use inline scripts for NFT mint policies. Revisit if future burn TXs get frequent enough that ref scripts save gas.
4. **Live Preprod verification** — PHASE 2-4 wiring + an actual Preprod run is the next concrete test.

---

## Security notes

1. Never commit `config/<network>.json` (real values). `.gitignore` enforces this. Use the `.example.json` template + local copy.
2. Mainnet seed phrase should ideally not sit on disk at all — prefer hardware-wallet signing for mainnet deploys (tracked in `docs/runbooks/v1-mainnet-ceremony.md`).
3. Lockup reminder: the **18 ref-script UTxOs** at the deploy wallet address tie up **~870 ADA** (V1 Preprod 2026-04-22 measured 871.51 ADA exactly — Conway-era `minFeeRefScriptCostPerByte` × deploy script's 1.10× safety multiplier × actual compiled validator sizes 1,327 B–13,482 B), plus **12 staking-credential stake deposits** (2 ADA each = 24 ADA) for **~894 ADA reclaimable**, plus ~22 ADA in non-recoverable network TX fees + ~27 ADA in state-UTXO seed ADA = **~944 ADA total ceremony cost** (see whitepaper §8.2). The reclaimable portion: ref scripts via `tools/reclaim-refs.ts` (single TX, ~2.5 ADA fee) + stake deposits via A2 deregister `publish` path (12 Queue + 12 Execute TXs after 14d gov timelock). Budget at least **1,000 ADA** for ceremony with 5-10% headroom.
4. Pre-ceremony dry-run **should be standard practice** before mainnet — it prints the compiled hashes so governance signers can pre-announce the intended addresses publicly.
