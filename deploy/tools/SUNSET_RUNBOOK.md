# V1 Ceremony Sunset Runbook

**Critical rule**: when winding down a V1 ceremony (Preprod or Mainnet),
the reclaim order is **fixed** and non-negotiable:

```
1. A2 QueueAction × 12 stake credentials
2. Wait   timelock_deregister_stake_ms
           (Preprod: 1 hour ; Mainnet: 14 days)
3. A2 ExecuteAction × 12 stake credentials  → recovers 24 ADA
4. reclaim-refs                              → recovers ~870 ADA
```

Reverse this order and **~24 ADA in stake deposits become permanently
unrecoverable on-chain**. This runbook explains why and how to avoid it.

---

## Why the order matters

Step 3 (A2 ExecuteAction) needs TWO ref scripts on-chain at TX evaluation time:

1. **`multisig_gov` ref script** — MultisigGov UTXO is spent with the
   `ExecuteAction` redeemer; validator runs via Lucid's ref-input path.
2. **Target staking validator's ref script** — the Cardano ledger's
   `Deregister` certificate triggers the target validator's `publish`
   handler, which runs the `is_gov_authorized` check. That validator
   bytecode must be available as a reference input, else the TX fails
   with `missingRequiredScripts`.

Both ref scripts are **destroyed** when step 4 (`reclaim-refs`) spends
their UTXOs back to the wallet. Once destroyed, they can only be
re-created by re-deploying them (each ~40-65 ADA min-UTXO) — which
costs more than the 24 ADA being recovered.

**Historical incident**: 2026-04-22 `v1-postphase77d-preprod` sunset.
Reclaim-refs was run before A2. All 18 ref scripts consumed. Attempt to
queue A2 deregister for `vaultUser` failed with:

```
[ERROR] multisig_gov ref script not found on-chain
```

24 ADA in stake deposits locked permanently on that release.
Lesson captured in `memory/feedback_ceremony_reclaim_order.md`.

---

## The 12 stake credentials

A2 must run against **all 12** (order is irrelevant — they're independent
governance actions, but each needs its own Queue + Execute round-trip):

```
vaultUser              vaultKeeperHot          vaultBatcher
vaultSwapAda           vaultProtocol           vaultRecall
vaultLiqwid            vaultGovPolicy          vaultGovEmergency
vaultAdminDeploy       keeperStakeScript       minswapV2Adapter
```

Each stake credential carries 2 ADA of Cardano-protocol deposit that is
returned on successful deregister.

---

## Running the orchestrator

One command does the whole sunset sequence:

```bash
# Preprod
npx tsx v1/deploy/tools/sunset-ceremony.ts \
  --network Preprod \
  --releaseTag v1-<release-tag>

# Mainnet (DO NOT run casually — 14-day timelock)
npx tsx v1/deploy/tools/sunset-ceremony.ts \
  --network Mainnet \
  --releaseTag v1-<release-tag>
```

Flags:

- `--phase queue` — only queue A2 actions (step 1), then stop.
- `--phase execute` — only execute A2 (step 3), assumes queue already done.
- `--phase reclaim` — only reclaim refs (step 4). Safe to run AFTER step 3.
- `--phase all` *(default)* — run all 4 steps in order, waiting for
  timelock between 1 and 3.
- `--skipWait` — skip the timelock wait (testing only; TXs will fail if
  actually submitted too early).
- `--dryRun` — print the plan, don't submit any TX.

The orchestrator is **idempotent**: rerunning after a partial completion
picks up from the state file (`v1/deploy/state/<network>-<tag>.json`).
Already-queued targets are skipped; already-executed targets are skipped.
Already-reclaimed ref scripts are filtered out by Blockfrost
`utxosByOutRef`.

---

## Runtime cost estimate

Preprod:

| Step | TX count | Per-TX fee | Total fee | Recovered |
|------|----------|-----------:|----------:|----------:|
| Queue A2 × 12 | 12 | ~0.35 ADA | ~4.2 ADA | — |
| Wait | — | — | — | — |
| Execute A2 × 12 | 12 | ~0.5 ADA | ~6 ADA | 24 ADA |
| Reclaim 18 refs | 1 | 5.11 ADA | 5.11 ADA | 871 ADA |
| **Net** | **25** | — | **~15.3 ADA** | **895 ADA** |

Net recovery: **~880 ADA per sunset** (post Phase 77b/77c/77d topology).

---

## Manual fallback (if orchestrator fails midway)

Each step can be run independently:

```bash
# 1. Queue one target
TARGET=vaultUser npx tsx v1/deploy/tools/a2-queue-deregister.ts \
  --network Preprod --releaseTag <tag>

# Repeat for all 12 targets.

# 2. Wait 1h (Preprod) or 14d (Mainnet).

# 3. Execute one target
TARGET=vaultUser npx tsx v1/deploy/tools/a2-execute-deregister.ts \
  --network Preprod --releaseTag <tag>

# Repeat for all 12.

# 4. Reclaim refs (ONLY after all 12 executes succeeded).
npx tsx v1/deploy/tools/reclaim-refs.ts \
  --network Preprod --releaseTag <tag>
```

---

## Things that are permanently locked regardless

Even with a correctly-ordered sunset, ~27 ADA in **state UTXOs** stays
on-chain forever (vault seed ~15 ADA + registry / treasury / keeperAuth /
governance ~3 ADA each = ~27 ADA). The payment credentials on these
UTXOs are the script validators; their ref scripts are consumed by
step 4, and the Plutus-V3 validator bytecode is too large (8-13 KB each)
to inline in a spend TX under the 16 KB `maxTxSize` ceiling.

Expect net sunset loss per release: **~27 ADA + ~15 ADA in fees =
~42 ADA** (≈ $27 USD at $0.64/ADA). Reclaimable: ~895 ADA from 18 ref
scripts + 12 stake deposits.

---

## Pre-flight checklist

Before starting any sunset:

- [ ] State file exists: `v1/deploy/state/<network>-<tag>.json`
- [ ] Deploy wallet has ≥ 20 ADA for fees
- [ ] Governance signer keys are accessible (2 of 3 signers needed for
      every Queue + Execute TX; at least 2 signers' keys must be available)
- [ ] On Mainnet: you have 14 days before you need those 24 ADA back.
      On Preprod: 1 hour.
- [ ] No operational keeper activity expected during sunset (a Compound
      or BatchProcess running concurrently wouldn't break anything but
      makes state confusing).

---

## Related files

- `v1/deploy/tools/a2-queue-deregister.ts` — single-target queue
- `v1/deploy/tools/a2-execute-deregister.ts` — single-target execute
- `v1/deploy/tools/reclaim-refs.ts` — bulk ref-script reclaim
- `v1/deploy/tools/sunset-ceremony.ts` — orchestrator (this document's subject)
- `v1/contracts/lib/vault/constants.ak::timelock_deregister_stake_ms` — on-chain timelock
- `memory/feedback_ceremony_reclaim_order.md` — the lesson that produced this runbook
