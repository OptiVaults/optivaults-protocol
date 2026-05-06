/**
 * V1 deploy ceremony phase implementations.
 *
 * Each `runPhaseN` function is idempotent: it checks the persisted state
 * before every step and skips anything already committed. Halting
 * mid-ceremony is safe — rerun the same `deploy.ts` command with the
 * same `--releaseTag` to resume.
 *
 * Phase breakdown:
 *   PHASE 2 — Mint 3 one-shot NFTs (vault / governance / registry-auth)
 *   PHASE 3 — Publish 18 reference scripts (17 logic validators + 1 SwapAdapter, post §5.4 + Phase 77 + 77b/77c/77d splits)
 *   PHASE 4a — Register 12 stake credentials (user, keeper_hot, batcher, swap_ada, protocol, recall, liqwid, gov_policy, gov_emergency, admin_deploy, keeper_stake_script, minswap_v2_adapter)
 *   PHASE 4b — Initialize 5 state UTXOs (registry, treasury, keeperAuth, governance, vault)
 */
import * as fs from "fs";
import * as path from "path";
import {
  CML,
  Constr,
  Data,
  applyDoubleCborEncoding,
  mintingPolicyToId,
  paymentCredentialOf,
  validatorToAddress,
  validatorToRewardAddress,
  validatorToScriptHash,
} from "@lucid-evolution/lucid";
import type { LucidEvolution, Script } from "@lucid-evolution/lucid";
import type { DeployConfig } from "./config.js";
import type { CeremonyState } from "./state.js";
import { saveState } from "./state.js";
import type { CeremonyHashes } from "./datumBuilders.js";
import {
  buildGovDatum,
  buildKeeperAuthDatum,
  buildRegistryDatum,
  buildTreasuryDatum,
  buildVaultDatum,
} from "./datumBuilders.js";
import { buildPrequeueActions } from "./govPrequeue.js";

// ---------------------------------------------------------------------
// Logging + helpers
// ---------------------------------------------------------------------
const C = {
  reset: "\x1b[0m",
  green: "\x1b[1;92m",
  gray: "\x1b[90m",
  yellow: "\x1b[1;93m",
  cyan: "\x1b[1;96m",
  red: "\x1b[1;91m",
};
function log(level: "INFO" | "WARN" | "ERROR" | "STEP", msg: string) {
  const color =
    level === "INFO" ? C.green :
    level === "WARN" ? C.yellow :
    level === "ERROR" ? C.red :
    C.cyan;
  console.log(`${color}[${level}]${C.reset} ${msg}`);
}

async function awaitTxAndSettle(
  lucid: LucidEvolution,
  txHash: string,
  awaitSeconds: number,
): Promise<void> {
  log("INFO", `Waiting for TX ${txHash.slice(0, 12)}… to confirm`);
  await lucid.awaitTx(txHash, 180_000);
  log("INFO", `Confirmed. Sleeping ${awaitSeconds}s for indexer.`);
  await new Promise((r) => setTimeout(r, awaitSeconds * 1000));
}

/**
 * Auto-recover lost mint TX hashes from on-chain history.
 *
 * Run at the start of PHASE 2 to rehydrate `state.mints[*].txHash` if
 * a prior process died between `submit()` and `saveState()`. The
 * authoritative signal is Blockfrost's `assets/{policyId+assetName}/history`
 * endpoint — if a one-shot NFT mint TX exists for the offline-derived
 * compile-time policy hash, that TX is recorded into state. This
 * eliminates the manual Python state-patches that were required during
 * Preprod p5 ceremony recovery.
 *
 * Safe to call repeatedly — entries with non-empty txHash are skipped.
 */
async function recoverLostMintTxHashes(
  lucid: LucidEvolution,
  state: CeremonyState,
): Promise<void> {
  const policyOf = (utxoRef: { txHash: string; outputIndex: number } | undefined) => utxoRef ?? null;
  for (const k of ["vaultNft", "governanceNft", "registryAuthNft"] as const) {
    const m = state.mints[k];
    if (!m || m.txHash) continue;
    if (!m.policyId) continue; // PHASE 1 hasn't computed compile-time hash yet
    if (!policyOf(m.utxoRef)) continue;
    try {
      // Lucid Evolution doesn't expose a direct asset-history API, so
      // we use the underlying Blockfrost client through the provider.
      const provider: any = (lucid as any).provider;
      const url: string | undefined = provider?.url ?? provider?.blockfrostUrl;
      const projectId: string | undefined =
        provider?.projectId ?? provider?.bf?.projectId ?? provider?.headers?.project_id;
      if (!url || !projectId) continue;
      const unit = m.policyId + m.assetName;
      const histUrl = `${url}/assets/${unit}/history`;
      const res = await fetch(histUrl, { headers: { project_id: projectId } });
      if (!res.ok) continue;
      const arr = await res.json() as Array<{ tx_hash: string; action: string }>;
      const mint = arr.find((h) => h.action === "minted");
      if (mint?.tx_hash) {
        log("WARN", `  ${k}: recovered lost mint TX ${mint.tx_hash} from on-chain history`);
        state.mints[k] = { ...m, txHash: mint.tx_hash };
        saveState(state);
      }
    } catch {
      // Best-effort recovery — fall through to normal mint flow if
      // Blockfrost unreachable or asset name is wrong.
    }
  }
}

interface ScriptsBundle {
  vaultNft: Script;
  governanceNft: Script;
  registryAuthNft: Script;
  keeperStakeScript: Script;
  treasury: Script;
  vaultUser: Script;
  vaultKeeperHot: Script;
  vaultBatcher: Script;
  vaultSwapAda: Script;
  vaultProtocol: Script;
  vaultRecall: Script;
  vaultLiqwid: Script;
  vaultGovPolicy: Script;
  vaultGovEmergency: Script;
  vaultAdminDeploy: Script;
  vaultProxy: Script;
  order: Script;
  vusdcx: Script;
  multisigGov: Script;
  registry: Script;
  minswapV2Adapter: Script;
}

export function buildScriptsBundle(
  scriptsApplied: Record<string, { compiledCode: string; size: number }>,
): ScriptsBundle {
  const mk = (k: keyof typeof scriptsApplied): Script => ({
    type: "PlutusV3",
    script: scriptsApplied[k as string].compiledCode,
  });
  return {
    vaultNft: mk("vaultNft"),
    governanceNft: mk("governanceNft"),
    registryAuthNft: mk("registryAuthNft"),
    keeperStakeScript: mk("keeperStakeScript"),
    treasury: mk("treasury"),
    vaultUser: mk("vaultUser"),
    vaultKeeperHot: mk("vaultKeeperHot"),
    vaultBatcher: mk("vaultBatcher"),
    vaultSwapAda: mk("vaultSwapAda"),
    vaultProtocol: mk("vaultProtocol"),
    vaultRecall: mk("vaultRecall"),
    vaultLiqwid: mk("vaultLiqwid"),
    vaultGovPolicy: mk("vaultGovPolicy"),
    vaultGovEmergency: mk("vaultGovEmergency"),
    vaultAdminDeploy: mk("vaultAdminDeploy"),
    vaultProxy: mk("vaultProxy"),
    order: mk("order"),
    vusdcx: mk("vusdcx"),
    multisigGov: mk("multisigGov"),
    registry: mk("registry"),
    minswapV2Adapter: mk("minswapV2Adapter"),
  };
}

// ---------------------------------------------------------------------
// PHASE 2 — Mint 3 one-shot NFTs
// ---------------------------------------------------------------------

/**
 * Submit a one-shot NFT mint TX. Returns immediately on submit so the
 * caller can persist `txHash` to state BEFORE awaiting confirmation.
 * The await is then a separate call (`awaitTxAndSettle`) issued from
 * the caller after the state save lands on disk.
 *
 * Atomic-save rationale: prior versions did `submit + await + return`,
 * so a process death between submit (TX on-chain) and return
 * permanently lost the TX hash from the operator's perspective —
 * subsequent re-runs would resubmit, double-mint, and corrupt
 * one-shot UTxO selection. By splitting submit from await, the state
 * save anchors the on-chain effect at submit time.
 */
async function submitOneShotNftMint(
  lucid: LucidEvolution,
  script: Script,
  assetName: string,
  utxoRef: { txHash: string; outputIndex: number },
): Promise<{ txHash: string; policyId: string }> {
  const policyId = mintingPolicyToId(script);
  const unit = policyId + assetName;
  const addr = await lucid.wallet().address();
  const [refUtxo] = await lucid.utxosByOutRef([
    { txHash: utxoRef.txHash, outputIndex: utxoRef.outputIndex },
  ]);
  if (!refUtxo) {
    throw new Error(
      `UTxO ref ${utxoRef.txHash}#${utxoRef.outputIndex} not found on-chain — the wallet may have spent it between PHASE 0 and PHASE 2`,
    );
  }
  const tx = await lucid
    .newTx()
    .collectFrom([refUtxo])
    .mintAssets({ [unit]: 1n }, Data.void())
    .attach.MintingPolicy(script)
    .pay.ToAddress(addr, { lovelace: 2_000_000n, [unit]: 1n })
    .complete();
  const signed = await tx.sign.withWallet().complete();
  const txHash = await signed.submit();
  log("INFO", `  Mint ${policyId.slice(0, 12)}.${assetName} TX ${txHash}`);
  return { txHash, policyId };
}

export async function runPhase2Mints(
  lucid: LucidEvolution,
  scripts: ScriptsBundle,
  cfg: DeployConfig,
  state: CeremonyState,
  hashes: CeremonyHashes,
): Promise<void> {
  const vaultNftName = "4f7074695661756c74"; // hex of "OptiVault"

  log("STEP", "PHASE 2: minting one-shot NFTs");

  // Atomic submit-then-save-then-await pattern: each NFT is (1) submitted,
  // (2) immediately persisted with txHash, (3) awaited for confirmation.
  // If the process dies between (1) and (2), `recoverLostMintTxHashes`
  // (called at the start of every PHASE 2 invocation) reads the on-chain
  // policy history via Blockfrost and rehydrates the missing txHash.
  await recoverLostMintTxHashes(lucid, state);

  if (!state.mints.vaultNft!.txHash) {
    const utxoRef = state.mints.vaultNft!.utxoRef;
    const { txHash, policyId } = await submitOneShotNftMint(
      lucid,
      scripts.vaultNft,
      vaultNftName,
      utxoRef,
    );
    state.mints.vaultNft = {
      txHash,
      utxoRef,
      policyId,
      assetName: vaultNftName,
    };
    saveState(state);
    await awaitTxAndSettle(lucid, txHash, cfg.ceremonyOptions.awaitConfirmSeconds);
  } else {
    log("INFO", `  vaultNft already minted: ${state.mints.vaultNft!.txHash}`);
  }

  if (!state.mints.governanceNft!.txHash) {
    const utxoRef = state.mints.governanceNft!.utxoRef;
    const assetName = cfg.governance.governanceNftAssetName;
    const { txHash, policyId } = await submitOneShotNftMint(
      lucid,
      scripts.governanceNft,
      assetName,
      utxoRef,
    );
    state.mints.governanceNft = { txHash, utxoRef, policyId, assetName };
    saveState(state);
    await awaitTxAndSettle(lucid, txHash, cfg.ceremonyOptions.awaitConfirmSeconds);
  } else {
    log("INFO", `  governanceNft already minted: ${state.mints.governanceNft!.txHash}`);
  }

  if (!state.mints.registryAuthNft!.txHash) {
    const utxoRef = state.mints.registryAuthNft!.utxoRef;
    const assetName = cfg.governance.registryAuthAssetName;
    const { txHash, policyId } = await submitOneShotNftMint(
      lucid,
      scripts.registryAuthNft,
      assetName,
      utxoRef,
    );
    state.mints.registryAuthNft = { txHash, utxoRef, policyId, assetName };
    saveState(state);
    await awaitTxAndSettle(lucid, txHash, cfg.ceremonyOptions.awaitConfirmSeconds);
  } else {
    log("INFO", `  registryAuthNft already minted: ${state.mints.registryAuthNft!.txHash}`);
  }
}

// ---------------------------------------------------------------------
// PHASE 3 — Publish 18 reference scripts (one per TX for safety).
//   Post §5.4 Phase 73 splits: vault_admin → vault_gov_policy + vault_gov_emergency.
//   Post Phase 77 splits:      vault_core → vault_user + vault_keeper_hot;
//                              vault_protocol → vault_protocol + vault_recall.
//   Post §B@launch=1:          minswap_v2_adapter (SwapAdapter) added.
//   Post Phase 77b split:      SwapAda extracted from vault_keeper_hot
//                              into standalone vault_swap_ada.
//   Post Phase 77c split:      AdminDeployNonDeposit extracted from
//                              vault_gov_emergency into standalone
//                              vault_admin_deploy.
//   Post Phase 77d split:      BatchProcess extracted from vault_user
//                              into standalone vault_batcher;
//                              vault_user becomes purely permissionless
//                              (no keeper_stake_hash param).
// ---------------------------------------------------------------------

type RefScriptLabel =
  | "vaultProxy" | "vaultUser" | "vaultKeeperHot" | "vaultBatcher"
  | "vaultSwapAda" | "vaultProtocol" | "vaultRecall" | "vaultLiqwid"
  | "vaultGovPolicy" | "vaultGovEmergency" | "vaultAdminDeploy"
  | "keeperStakeScript" | "treasury" | "multisigGov"
  | "registry" | "order" | "vusdcx" | "minswapV2Adapter";

const REF_SCRIPT_ORDER: RefScriptLabel[] = [
  "vaultProxy",
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
  "treasury",
  "multisigGov",
  "registry",
  "order",
  "vusdcx",
  "minswapV2Adapter",
];

function estMinAda(size: number, multiplier: number): bigint {
  return BigInt(Math.ceil((size + 200) * 4310 * multiplier)) + 1_000_000n;
}

/**
 * Publish a single reference script. Uses the `deployRefScripts` helper
 * from `./deployRefScript.ts` (from `scripts/utils/deployRefScript.ts` original) which handles the Conway
 * per-byte ref-script fee that Lucid Evolution's own fee estimator
 * under-reports.
 */
async function publishOneRef(
  lucid: LucidEvolution,
  script: Script,
  label: string,
  minAda: bigint,
  bfUrl: string,
  bfKey: string,
): Promise<{ txHash: string; outputIndex: number; scriptHash: string; sizeBytes: number; minAda: string }> {
  const deployRefScripts = (await import("./deployRefScript.js")).deployRefScripts;
  const [r] = await deployRefScripts(lucid, [script], [minAda], bfUrl, bfKey);
  const sizeBytes = Math.floor(script.script.length / 2);
  const scriptHash = validatorToScriptHash(script);
  log("INFO", `  ${label.padEnd(20)} ${scriptHash.slice(0, 12)} ${sizeBytes}B TX ${r.txHash}`);
  return {
    txHash: r.txHash,
    outputIndex: r.outputIndex,
    scriptHash,
    sizeBytes,
    minAda: minAda.toString(),
  };
}

export async function runPhase3RefScripts(
  lucid: LucidEvolution,
  scripts: ScriptsBundle,
  cfg: DeployConfig,
  state: CeremonyState,
  bfUrl: string,
  bfKey: string,
): Promise<void> {
  log("STEP", "PHASE 3: publishing 18 reference scripts");
  const mult = cfg.ceremonyOptions.refScriptMinAdaMultiplier;
  const scriptMap: Record<RefScriptLabel, Script> = {
    vaultProxy: scripts.vaultProxy,
    vaultUser: scripts.vaultUser,
    vaultKeeperHot: scripts.vaultKeeperHot,
    vaultBatcher: scripts.vaultBatcher,
    vaultSwapAda: scripts.vaultSwapAda,
    vaultProtocol: scripts.vaultProtocol,
    vaultRecall: scripts.vaultRecall,
    vaultLiqwid: scripts.vaultLiqwid,
    vaultGovPolicy: scripts.vaultGovPolicy,
    vaultGovEmergency: scripts.vaultGovEmergency,
    vaultAdminDeploy: scripts.vaultAdminDeploy,
    keeperStakeScript: scripts.keeperStakeScript,
    treasury: scripts.treasury,
    multisigGov: scripts.multisigGov,
    registry: scripts.registry,
    order: scripts.order,
    vusdcx: scripts.vusdcx,
    minswapV2Adapter: scripts.minswapV2Adapter,
  };
  for (const label of REF_SCRIPT_ORDER) {
    if (state.refScripts[label]) {
      log("INFO", `  ${label}: already published (${state.refScripts[label]!.txHash})`);
      continue;
    }
    const s = scriptMap[label];
    const size = Math.floor(s.script.length / 2);
    const minAda = estMinAda(size, mult);
    try {
      const r = await publishOneRef(lucid, s, label, minAda, bfUrl, bfKey);
      state.refScripts[label] = r;
      saveState(state);
      await awaitTxAndSettle(lucid, r.txHash, cfg.ceremonyOptions.awaitConfirmSeconds);
    } catch (e) {
      log("ERROR", `Ref script ${label} failed: ${(e as Error).message?.slice(0, 500)}`);
      throw e;
    }
  }
}

// ---------------------------------------------------------------------
// PHASE 4a — Stake credential registrations (12 staking credentials).
//   Every credential that carries an A2 `publish` handler needs a
//   register.Stake certificate so (a) zero-withdrawal dispatch works
//   and (b) the 2 ADA deposit becomes reclaimable later via
//   ActDeregisterStake. See spec/governance.md §4.13.
// ---------------------------------------------------------------------

export interface StakeRegistration {
  target: string;
  rewardAddr: string;
  stakeHash: string;
  txHash: string;
}

async function isStakeRegistered(
  bfUrl: string,
  bfKey: string,
  rewardAddr: string,
): Promise<boolean> {
  try {
    const res = await fetch(`${bfUrl}/accounts/${rewardAddr}`, {
      headers: { project_id: bfKey },
      signal: AbortSignal.timeout(15000),
    });
    if (res.status === 404) return false;
    if (!res.ok) return false;
    const data = (await res.json()) as { active?: boolean };
    return !!data.active;
  } catch {
    return false;
  }
}

export async function runPhase4aStakes(
  lucid: LucidEvolution,
  scripts: ScriptsBundle,
  cfg: DeployConfig,
  state: CeremonyState,
  bfUrl: string,
  bfKey: string,
): Promise<void> {
  log("STEP", "PHASE 4a: registering 12 stake credentials");

  const targets: { target: string; script: Script }[] = [
    { target: "vaultUser",          script: scripts.vaultUser },
    { target: "vaultKeeperHot",     script: scripts.vaultKeeperHot },
    { target: "vaultBatcher",       script: scripts.vaultBatcher },
    { target: "vaultSwapAda",       script: scripts.vaultSwapAda },
    { target: "vaultProtocol",      script: scripts.vaultProtocol },
    { target: "vaultRecall",        script: scripts.vaultRecall },
    { target: "vaultLiqwid",        script: scripts.vaultLiqwid },
    { target: "vaultGovPolicy",     script: scripts.vaultGovPolicy },
    { target: "vaultGovEmergency",  script: scripts.vaultGovEmergency },
    { target: "vaultAdminDeploy",   script: scripts.vaultAdminDeploy },
    { target: "keeperStakeScript",  script: scripts.keeperStakeScript },
    { target: "minswapV2Adapter",   script: scripts.minswapV2Adapter },
  ];

  if (!state.stakeRegistrations) {
    (state as any).stakeRegistrations = {};
  }
  const regs = (state as any).stakeRegistrations as Record<string, StakeRegistration>;

  for (const t of targets) {
    if (regs[t.target]?.txHash) {
      log("INFO", `  ${t.target}: already registered (${regs[t.target].txHash})`);
      continue;
    }
    const rewardAddr = validatorToRewardAddress(cfg.network, t.script);
    const stakeHash = validatorToScriptHash(t.script);
    const alreadyOnChain = await isStakeRegistered(bfUrl, bfKey, rewardAddr);
    if (alreadyOnChain) {
      log("INFO", `  ${t.target}: already registered on-chain (${rewardAddr.slice(0, 40)}…)`);
      regs[t.target] = { target: t.target, rewardAddr, stakeHash, txHash: "preexisting" };
      saveState(state);
      continue;
    }
    log("INFO", `  ${t.target}: registering ${rewardAddr.slice(0, 40)}…`);
    try {
      const tx = await lucid.newTx().register.Stake(rewardAddr).complete();
      const signed = await tx.sign.withWallet().complete();
      const txHash = await signed.submit();
      log("INFO", `    TX ${txHash}`);
      regs[t.target] = { target: t.target, rewardAddr, stakeHash, txHash };
      saveState(state);
      await awaitTxAndSettle(lucid, txHash, cfg.ceremonyOptions.awaitConfirmSeconds);
    } catch (e) {
      const msg = (e as Error).message ?? String(e);
      if (/StakeKeyRegisteredDELEG|already[\s_-]?registered/i.test(msg)) {
        log("INFO", `    already registered (race) — recording`);
        regs[t.target] = { target: t.target, rewardAddr, stakeHash, txHash: "preexisting" };
        saveState(state);
        continue;
      }
      log("ERROR", `  ${t.target} stake registration failed: ${msg.slice(0, 400)}`);
      throw e;
    }
  }
}

// ---------------------------------------------------------------------
// PHASE 4b — Initialize 5 state UTXOs
// ---------------------------------------------------------------------

export async function runPhase4bStateUtxos(
  lucid: LucidEvolution,
  scripts: ScriptsBundle,
  cfg: DeployConfig,
  state: CeremonyState,
  hashes: CeremonyHashes,
): Promise<void> {
  log("STEP", "PHASE 4b: initializing 5 state UTXOs");
  const nowMs = Date.now();

  const registryAddr = validatorToAddress(cfg.network, scripts.registry);
  const treasuryAddr = validatorToAddress(cfg.network, scripts.treasury);
  const keeperAuthAddr = validatorToAddress(cfg.network, scripts.keeperStakeScript);
  const multisigGovAddr = validatorToAddress(cfg.network, scripts.multisigGov);
  const vaultAddr = validatorToAddress(cfg.network, scripts.vaultProxy);

  const vaultNftUnit = hashes.vaultNftPolicy + state.mints.vaultNft!.assetName;
  const govNftUnit = hashes.governanceNftPolicy + state.mints.governanceNft!.assetName;
  const authNftUnit = hashes.registryAuthPolicy + state.mints.registryAuthNft!.assetName;

  // --- Step 1: Registry (locks auth NFT) ---
  if (!state.stateUtxos.registry) {
    log("INFO", `  Registry at ${registryAddr.slice(0, 40)}…`);
    const datum = buildRegistryDatum(cfg, hashes, nowMs);
    const tx = await lucid
      .newTx()
      .pay.ToAddressWithData(
        registryAddr,
        { kind: "inline", value: datum as unknown as string },
        { lovelace: 3_000_000n, [authNftUnit]: 1n },
      )
      .complete();
    const signed = await tx.sign.withWallet().complete();
    const txHash = await signed.submit();
    log("INFO", `    Registry TX ${txHash}`);
    state.stateUtxos.registry = { txHash, outputIndex: 0, address: registryAddr };
    saveState(state);
    await awaitTxAndSettle(lucid, txHash, cfg.ceremonyOptions.awaitConfirmSeconds);
  } else {
    log("INFO", `  Registry already initialized: ${state.stateUtxos.registry.txHash}`);
  }

  // --- Step 2: Treasury ---
  if (!state.stateUtxos.treasury) {
    log("INFO", `  Treasury at ${treasuryAddr.slice(0, 40)}…`);
    const datum = buildTreasuryDatum(cfg, hashes);
    const tx = await lucid
      .newTx()
      .pay.ToAddressWithData(
        treasuryAddr,
        { kind: "inline", value: datum as unknown as string },
        { lovelace: 3_000_000n },
      )
      .complete();
    const signed = await tx.sign.withWallet().complete();
    const txHash = await signed.submit();
    log("INFO", `    Treasury TX ${txHash}`);
    state.stateUtxos.treasury = { txHash, outputIndex: 0, address: treasuryAddr };
    saveState(state);
    await awaitTxAndSettle(lucid, txHash, cfg.ceremonyOptions.awaitConfirmSeconds);
  } else {
    log("INFO", `  Treasury already initialized: ${state.stateUtxos.treasury.txHash}`);
  }

  // --- Step 3: KeeperAuth (at keeper_stake_script addr) ---
  if (!state.stateUtxos.keeperAuth) {
    log("INFO", `  KeeperAuth at ${keeperAuthAddr.slice(0, 40)}…`);
    const datum = buildKeeperAuthDatum(cfg, hashes, nowMs);
    const tx = await lucid
      .newTx()
      .pay.ToAddressWithData(
        keeperAuthAddr,
        { kind: "inline", value: datum as unknown as string },
        { lovelace: 3_000_000n },
      )
      .complete();
    const signed = await tx.sign.withWallet().complete();
    const txHash = await signed.submit();
    log("INFO", `    KeeperAuth TX ${txHash}`);
    state.stateUtxos.keeperAuth = { txHash, outputIndex: 0, address: keeperAuthAddr };
    saveState(state);
    await awaitTxAndSettle(lucid, txHash, cfg.ceremonyOptions.awaitConfirmSeconds);
  } else {
    log("INFO", `  KeeperAuth already initialized: ${state.stateUtxos.keeperAuth.txHash}`);
  }

  // --- Step 4: Governance (multisig_gov, locks gov NFT) ---
  if (!state.stateUtxos.governance) {
    log("INFO", `  Governance at ${multisigGovAddr.slice(0, 40)}…`);

    // Phase B (datum-backdate) pre-queue support — Preprod only.
    // Reads BACKDATE_FEE_DAYS / BACKDATE_STRATEGY_DAYS / BACKDATE_FEE_SPLIT_DAYS /
    // BACKDATE_REGISTRY_DAYS env vars (unset = 0 = no pre-queue).
    // Builds QueuedAction records with backdated queued_at_ms so production
    // timelocks have effectively elapsed by deploy completion. Live h-* tools
    // hit idempotency-skip on Queue + go straight to Execute.
    let prequeue: ReturnType<typeof buildPrequeueActions> = [];
    if (cfg.network === "Preprod") {
      const env = {
        feeDays:        parseInt(process.env.BACKDATE_FEE_DAYS        ?? "0", 10) || undefined,
        strategyDays:   parseInt(process.env.BACKDATE_STRATEGY_DAYS   ?? "0", 10) || undefined,
        feeSplitDays:   parseInt(process.env.BACKDATE_FEE_SPLIT_DAYS  ?? "0", 10) || undefined,
        registryDays:   parseInt(process.env.BACKDATE_REGISTRY_DAYS   ?? "0", 10) || undefined,
        deregisterDays: parseInt(process.env.BACKDATE_DEREGISTER_DAYS ?? "0", 10) || undefined,
      };
      const targets = {
        govPolicyStakeHash: state.hashes.govPolicyStakeHash,
        registryHash: state.hashes.registryHash,
        userStakeHash: state.hashes.userStakeHash,
      };
      prequeue = buildPrequeueActions(env, targets, nowMs);
      if (prequeue.length > 0) {
        log("INFO", `  ⏰ Pre-queueing ${prequeue.length} gov action(s) with backdated queued_at_ms:`);
        for (const a of prequeue) {
          log("INFO", `      kind=${a.actionKindIdx} queued_at=${a.queuedAtMs} executable_at=${a.executableAtMs} action_id=${a.actionId.slice(0, 16)}…`);
        }
      }
    } else if (
      process.env.BACKDATE_FEE_DAYS ||
      process.env.BACKDATE_STRATEGY_DAYS ||
      process.env.BACKDATE_FEE_SPLIT_DAYS ||
      process.env.BACKDATE_REGISTRY_DAYS ||
      process.env.BACKDATE_DEREGISTER_DAYS
    ) {
      throw new Error("buildGovDatum: Mainnet ceremony refuses BACKDATE_*_DAYS pre-queue flags");
    }
    const datum = buildGovDatum(cfg, nowMs, prequeue);
    const tx = await lucid
      .newTx()
      .pay.ToAddressWithData(
        multisigGovAddr,
        { kind: "inline", value: datum as unknown as string },
        { lovelace: 3_000_000n, [govNftUnit]: 1n },
      )
      .complete();
    const signed = await tx.sign.withWallet().complete();
    const txHash = await signed.submit();
    log("INFO", `    Governance TX ${txHash}`);
    state.stateUtxos.governance = { txHash, outputIndex: 0, address: multisigGovAddr };
    saveState(state);
    await awaitTxAndSettle(lucid, txHash, cfg.ceremonyOptions.awaitConfirmSeconds);
  } else {
    log("INFO", `  Governance already initialized: ${state.stateUtxos.governance.txHash}`);
  }

  // --- Step 5: Vault (locks vault NFT + seed ADA) ---
  if (!state.stateUtxos.vault) {
    log("INFO", `  Vault at ${vaultAddr.slice(0, 40)}…`);
    // Preprod backdate options (Preprod-only — Mainnet leaves them all
    // 0 by passing an empty object). All values are MILLISECONDS to
    // subtract from `nowMs` for the corresponding datum field.
    //
    //   - feeMs: 8 days → bypasses 7d fee_update_cooldown_ms (H-UpdateFee).
    //   - compoundMs: 91 days → bypasses 90d community_sunset threshold
    //     (Phase L3 dead-man-switch). Set via env BACKDATE_COMPOUND_DAYS;
    //     unset = 0 = no backdate. See tests/preprod/TIME-MACHINE.md.
    //   - adaSwapMs: backdates last_ada_swap_time so SwapAda's 1h cooldown
    //     is satisfied at deploy time. Without this, SwapAda E2E tests
    //     wait 1h after vault init before they can execute, because every
    //     redeemer EXCEPT SwapAda itself preserves last_ada_swap_time —
    //     leaving no off-chain way to advance it. Set via env
    //     BACKDATE_ADA_SWAP_HOURS (default 0 = no backdate). 2 hours is
    //     enough headroom for a multi-test session.
    const backdate =
      cfg.network === "Preprod"
        ? {
            feeMs: 8 * 86_400_000,
            compoundMs:
              parseInt(process.env.BACKDATE_COMPOUND_DAYS ?? "0", 10) * 86_400_000,
            adaSwapMs:
              parseInt(process.env.BACKDATE_ADA_SWAP_HOURS ?? "0", 10) * 3_600_000,
          }
        : {};
    if (cfg.network === "Mainnet" && Object.keys(backdate).length > 0) {
      throw new Error("buildVaultDatum: Mainnet ceremony refuses backdate flags");
    }
    if (backdate.compoundMs && backdate.compoundMs > 0) {
      log(
        "INFO",
        `  ⏰ Preprod backdate: last_compound_time/last_realloc_time -${backdate.compoundMs / 86_400_000}d ` +
          `(L3 sunset E2E enabled)`,
      );
    }
    if (backdate.adaSwapMs && backdate.adaSwapMs > 0) {
      log(
        "INFO",
        `  ⏰ Preprod backdate: last_ada_swap_time -${backdate.adaSwapMs / 3_600_000}h ` +
          `(SwapAda 1h cooldown bypass for E2E tests)`,
      );
    }
    const datum = buildVaultDatum(cfg, hashes, nowMs, backdate);
    const tx = await lucid
      .newTx()
      .pay.ToAddressWithData(
        vaultAddr,
        { kind: "inline", value: datum as unknown as string },
        {
          lovelace: BigInt(cfg.vaultInitialParams.seedLovelace),
          [vaultNftUnit]: 1n,
        },
      )
      .complete();
    const signed = await tx.sign.withWallet().complete();
    const txHash = await signed.submit();
    log("INFO", `    Vault TX ${txHash}`);
    state.stateUtxos.vault = { txHash, outputIndex: 0, address: vaultAddr };
    saveState(state);
    await awaitTxAndSettle(lucid, txHash, cfg.ceremonyOptions.awaitConfirmSeconds);
  } else {
    log("INFO", `  Vault already initialized: ${state.stateUtxos.vault.txHash}`);
  }
}
