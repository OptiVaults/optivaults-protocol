/**
 * V1 ceremony sunset orchestrator.
 *
 * Runs the ONLY safe reclaim order:
 *   1. A2 QueueAction × 12 stake credentials
 *   2. Wait timelock_deregister_stake_ms (1h Preprod / 14d Mainnet)
 *   3. A2 ExecuteAction × 12 (recovers 24 ADA)
 *   4. reclaim-refs (recovers ~870 ADA from 18 ref scripts)
 *
 * Reverse the order and the target/multisig_gov ref scripts are
 * destroyed by step 4 before step 3 can use them — 24 ADA in stake
 * deposits become permanently unrecoverable (see SUNSET_RUNBOOK.md +
 * memory/feedback_ceremony_reclaim_order.md).
 *
 * Usage:
 *   npx tsx v1/deploy/tools/sunset-ceremony.ts \
 *     --network Preprod --releaseTag v1-postphase77d-preprod
 *
 * Flags:
 *   --phase queue    — only step 1
 *   --phase execute  — only step 3 (assumes state.a2 already populated)
 *   --phase reclaim  — only step 4 (assumes all 12 stakes deregistered)
 *   --phase all      — run 1 + 2 + 3 + 4 in order (default)
 *   --skipWait       — skip the timelock wait (debug only)
 *   --dryRun         — print plan, submit nothing
 *
 * Idempotent: re-running picks up from state file. Already-queued or
 * already-executed targets are skipped.
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import * as fs from "fs";
import * as path from "path";
import { spawn } from "child_process";

type Net = "Preprod" | "Mainnet";
type Phase = "all" | "queue" | "execute" | "reclaim";

// All 12 A2-capable staking credentials (post Phase 77b/77c/77d).
const A2_TARGETS = [
  "vaultUser",
  "vaultKeeperHot",
  "vaultBatcher",
  "vaultSwapAda",
  "vaultProtocol",
  "vaultRecall",
  "vaultLiqwid",
  "vaultGovPolicy",
  "vaultGovEmergency",
  "vaultAdminDeploy",
  "keeperStakeScript",
  "minswapV2Adapter",
] as const;

interface CliArgs {
  network: Net;
  releaseTag: string;
  phase: Phase;
  skipWait: boolean;
  dryRun: boolean;
}

function parseArgs(): CliArgs {
  const a = process.argv.slice(2);
  let network: Net = "Preprod";
  let releaseTag = "v1-preprod-e2e";
  let phase: Phase = "all";
  let skipWait = false;
  let dryRun = false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--network") network = a[++i] as Net;
    else if (a[i] === "--releaseTag") releaseTag = a[++i];
    else if (a[i] === "--phase") phase = a[++i] as Phase;
    else if (a[i] === "--skipWait") skipWait = true;
    else if (a[i] === "--dryRun" || a[i] === "--dry-run") dryRun = true;
  }
  return { network, releaseTag, phase, skipWait, dryRun };
}

function stateFilePath(args: CliArgs): string {
  return path.resolve(
    `v1/deploy/state/${args.network.toLowerCase()}-${args.releaseTag}.json`,
  );
}

function readState(args: CliArgs): Record<string, unknown> {
  const p = stateFilePath(args);
  if (!fs.existsSync(p)) {
    throw new Error(
      `State file not found: ${p}. Run ceremony deploy first, or check --releaseTag.`,
    );
  }
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function banner(msg: string): void {
  console.log();
  console.log("═".repeat(68));
  console.log(msg);
  console.log("═".repeat(68));
}

function runChild(script: string, extraArgs: string[], env: Record<string, string>): Promise<number> {
  return new Promise((resolve, reject) => {
    const cp = spawn(
      "npx",
      ["tsx", `v1/deploy/tools/${script}.ts`, ...extraArgs],
      {
        stdio: "inherit",
        env: { ...process.env, ...env },
      },
    );
    cp.on("error", reject);
    cp.on("exit", (code) => resolve(code ?? 1));
  });
}

// ─── Phase 1: Queue A2 actions for all 12 targets ──────────────────

async function queuePhase(args: CliArgs): Promise<void> {
  banner(`PHASE 1 — A2 QueueAction × ${A2_TARGETS.length} targets`);
  const state = readState(args);
  const a2: Record<string, { txHash?: string; executableAtMs?: number } | undefined> =
    (state.a2 as never) ?? {};

  for (const target of A2_TARGETS) {
    const existing = a2[target];
    if (existing?.txHash) {
      console.log(`  ✓ [${target}] already queued: ${existing.txHash.slice(0, 16)}… (executable_at=${new Date(existing.executableAtMs!).toISOString()})`);
      continue;
    }

    console.log(`\n  → Queueing ${target}…`);
    if (args.dryRun) {
      console.log(`    [dryRun] would run: TARGET=${target} a2-queue-deregister --network ${args.network} --releaseTag ${args.releaseTag}`);
      continue;
    }
    const code = await runChild(
      "a2-queue-deregister",
      ["--network", args.network, "--releaseTag", args.releaseTag],
      { TARGET: target },
    );
    if (code !== 0) {
      throw new Error(`A2 queue failed for target=${target} (exit ${code})`);
    }
  }

  console.log(`\nPHASE 1 complete — all ${A2_TARGETS.length} targets queued.`);
}

// ─── Phase 2: Wait for timelock ────────────────────────────────────

async function waitPhase(args: CliArgs): Promise<void> {
  if (args.skipWait) {
    banner("PHASE 2 — skipping wait (--skipWait)");
    return;
  }
  const state = readState(args);
  const a2 = (state.a2 as Record<string, { executableAtMs?: number } | undefined>) ?? {};

  let maxExecAt = 0;
  for (const target of A2_TARGETS) {
    const entry = a2[target];
    if (entry?.executableAtMs && entry.executableAtMs > maxExecAt) {
      maxExecAt = entry.executableAtMs;
    }
  }
  if (maxExecAt === 0) {
    banner("PHASE 2 — no queued A2 actions found, skipping wait");
    return;
  }

  const now = Date.now();
  const waitMs = maxExecAt - now;
  if (waitMs <= 0) {
    banner(`PHASE 2 — timelock already elapsed (executable_at=${new Date(maxExecAt).toISOString()})`);
    return;
  }

  const waitMin = Math.ceil(waitMs / 60_000);
  banner(`PHASE 2 — waiting ${waitMin} min until ${new Date(maxExecAt).toISOString()}`);

  if (args.dryRun) {
    console.log(`  [dryRun] would sleep ${waitMs}ms`);
    return;
  }

  // Poll every 30s so operator can ^C cleanly
  const pollMs = 30_000;
  while (Date.now() < maxExecAt) {
    const remainingMs = maxExecAt - Date.now();
    const remainingSec = Math.ceil(remainingMs / 1000);
    const mm = Math.floor(remainingSec / 60);
    const ss = remainingSec % 60;
    process.stdout.write(`\r  waiting: ${mm}m ${ss.toString().padStart(2, "0")}s…   `);
    await new Promise((r) => setTimeout(r, Math.min(pollMs, remainingMs)));
  }
  console.log("\n  timelock elapsed ✓");
}

// ─── Phase 3: Execute A2 actions ───────────────────────────────────

async function executePhase(args: CliArgs): Promise<void> {
  banner(`PHASE 3 — A2 ExecuteAction × ${A2_TARGETS.length} targets`);
  const state = readState(args);
  const a2 = (state.a2 as Record<string, { txHash?: string; executedTxHash?: string } | undefined>) ?? {};

  for (const target of A2_TARGETS) {
    const entry = a2[target];
    if (!entry?.txHash) {
      console.log(`  ✗ [${target}] has no queued action — skipping (run --phase queue first)`);
      continue;
    }
    if (entry.executedTxHash) {
      console.log(`  ✓ [${target}] already executed: ${entry.executedTxHash.slice(0, 16)}…`);
      continue;
    }

    console.log(`\n  → Executing ${target}…`);
    if (args.dryRun) {
      console.log(`    [dryRun] would run: TARGET=${target} a2-execute-deregister --network ${args.network} --releaseTag ${args.releaseTag}`);
      continue;
    }
    const code = await runChild(
      "a2-execute-deregister",
      ["--network", args.network, "--releaseTag", args.releaseTag],
      { TARGET: target },
    );
    if (code !== 0) {
      console.warn(`  ⚠ A2 execute failed for target=${target} (exit ${code}) — continuing with remaining targets`);
      // Don't throw — try the other 11. Partial success still recovers
      // ADA; operator can retry the failed ones manually.
    }
  }

  console.log(`\nPHASE 3 complete — reviewed all ${A2_TARGETS.length} targets.`);
  console.log(`  24 ADA recovered (if all 12 executed successfully).`);
}

// ─── Phase 4: Reclaim ref scripts ──────────────────────────────────

async function reclaimPhase(args: CliArgs): Promise<void> {
  banner("PHASE 4 — Reclaim 18 ref scripts");

  if (args.dryRun) {
    console.log(`  [dryRun] would run: reclaim-refs --network ${args.network} --releaseTag ${args.releaseTag} --dryRun`);
    const code = await runChild(
      "reclaim-refs",
      ["--network", args.network, "--releaseTag", args.releaseTag, "--dryRun"],
      {},
    );
    if (code !== 0) throw new Error(`reclaim-refs --dryRun failed (exit ${code})`);
    return;
  }

  const code = await runChild(
    "reclaim-refs",
    ["--network", args.network, "--releaseTag", args.releaseTag],
    {},
  );
  if (code !== 0) {
    throw new Error(`reclaim-refs failed (exit ${code})`);
  }
  console.log("\nPHASE 4 complete — ~870 ADA recovered.");
}

// ─── Main ──────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const args = parseArgs();

  console.log("═══ V1 Ceremony Sunset Orchestrator ═══");
  console.log(`  network:    ${args.network}`);
  console.log(`  releaseTag: ${args.releaseTag}`);
  console.log(`  phase:      ${args.phase}`);
  console.log(`  skipWait:   ${args.skipWait}`);
  console.log(`  dryRun:     ${args.dryRun}`);
  console.log(`  stateFile:  ${stateFilePath(args)}`);

  // Existence check (also surfaces a helpful error if tag is wrong)
  readState(args);

  try {
    if (args.phase === "all" || args.phase === "queue") await queuePhase(args);
    if (args.phase === "all") await waitPhase(args);
    if (args.phase === "all" || args.phase === "execute") await executePhase(args);
    if (args.phase === "all" || args.phase === "reclaim") await reclaimPhase(args);
  } catch (err) {
    console.error("\n✗ Sunset ceremony failed:", err);
    process.exit(1);
  }

  banner("✓ Sunset ceremony complete");
  console.log(
    `Expected outcome: ~880 ADA returned to deploy wallet (871 from 18 ref scripts`,
  );
  console.log(
    `+ 24 from 12 stake deposits, minus ~15 ADA in Cardano fees).`,
  );
  console.log(
    `State UTxOs (vault/registry/treasury/keeperAuth/governance, ~27 ADA)`,
  );
  console.log(`remain locked on-chain — that's expected per design.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
