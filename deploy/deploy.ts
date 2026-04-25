/**
 * V1 ceremony orchestrator.
 *
 * End-to-end deploy pipeline that walks through the 27-30 ceremony
 * transactions described in whitepaper §8.2, writes state to
 * `deploy/state/<network>-<releaseTag>.json` after every successful TX,
 * and resumes cleanly if interrupted.
 *
 * Pipeline phases (step keys in brackets — used by state.ts for resume):
 *
 *   PHASE 0 — Pick UTxO refs             [pickUtxoRefs]
 *     Reserve 3 distinct UTxOs from the deploy wallet. These must NOT be
 *     spent by any subsequent TX until the 3 NFT mints consume them as
 *     their one-shot anchors.
 *
 *   PHASE 1 — Compile hashes              [compile]
 *     Offline: apply UTxO refs + config params to all 22 artefacts
 *     (17 logic validators + 4 NFT mint policies + 1 DEX adapter) per
 *     the dependency graph in compile.ts. Writes hashes into state.
 *
 *   PHASE 2 — Mint 3 one-shot NFTs        [mintVaultNft, mintGovNft, mintRegistryAuthNft]
 *     Each TX consumes one of the reserved UTxO refs + mints its NFT to
 *     the deploy wallet address. UTxO-ref one-shot guarantees exactly-once.
 *
 *   PHASE 3 — Publish 18 reference scripts
 *     One TX per validator. Each ref-script UTxO lives at the deploy wallet
 *     address forever (per whitepaper §8.2 ref-script capital lockup).
 *
 *     Sub-steps:  [refScript:vault_proxy, …:vault_user, …:vault_keeper_hot,
 *                  …:vault_batcher, …:vault_swap_ada, …:vault_protocol,
 *                  …:vault_recall, …:vault_liqwid, …:vault_gov_policy,
 *                  …:vault_gov_emergency, …:vault_admin_deploy,
 *                  …:keeper_stake_script, …:treasury, …:multisig_gov,
 *                  …:registry, …:order, …:vusdcx, …:minswap_v2_adapter]
 *
 *   PHASE 4a — Register 12 stake credentials   [registerStake:<target>]
 *     Each staking validator (vault_user, vault_keeper_hot, vault_batcher,
 *     vault_swap_ada, vault_protocol, vault_recall, vault_liqwid,
 *     vault_gov_policy, vault_gov_emergency, vault_admin_deploy,
 *     keeper_stake_script, minswap_v2_adapter) gets its stake credential
 *     registered so Withdraw-Zero + A2 deregister `publish` handlers can
 *     activate. Registration is idempotent across ceremony retries.
 *
 *   PHASE 4b — Initialize 5 state UTxOs    [initRegistry, initTreasury,
 *                                           initKeeperAuth, initGovernance,
 *                                           initVault]
 *     Each state UTxO carries the correct auth NFT (where required) + initial
 *     datum matching the config's initial-params section.
 *
 * Usage:
 *   npx tsx deploy/deploy.ts --network Preprod --releaseTag v1-launch-rc1
 *
 *   # Dry-run (no TXs submitted, just logs what would happen):
 *   npx tsx deploy/deploy.ts --network Preprod --releaseTag v1-launch-rc1 --dryRun
 *
 *   # Resume a failed ceremony (re-reads state file, picks up where it left off):
 *   (same command; idempotent)
 *
 *   # Reset state and start over:
 *   npx tsx deploy/deploy.ts --network Preprod --releaseTag v1-launch-rc1 --reset
 *
 * Preprod verification notes:
 *   - Requires deploy wallet with ≥ 500 ADA (400 for ref-script lockup + 50
 *     for TX fees + 50 headroom) and ≥ 15 test-USDCx for vault seed.
 *   - Blockfrost Preprod key (`preprod…`) must be in config/preprod.json.
 *   - Ceremony typically completes in 10-15 minutes including indexer wait.
 */
import * as dotenv from "dotenv";
// Load the local keeper .env first (has BLOCKFROST_API_KEY_PREPROD +
// KEY_DAEMON_SOCKET), then fall back to a bare .env in the working dir.
dotenv.config({ path: "keeper/.env" });
dotenv.config();

import * as fs from "fs";
import * as net from "net";
import * as path from "path";
import {
  Lucid,
  Blockfrost,
  Data,
  Constr,
  fromText,
  mintingPolicyToId,
  paymentCredentialOf,
  stakeCredentialOf,
  validatorToAddress,
  validatorToRewardAddress,
  validatorToScriptHash,
  type LucidEvolution,
  type Script,
  type UTxO,
  type Assets,
} from "@lucid-evolution/lucid";
import { loadConfig, type DeployConfig, type NetworkName } from "./lib/config.js";
import { loadState, saveState, resetState, type CeremonyState } from "./lib/state.js";
import { acquireLock, releaseLock } from "./lib/deployLock.js";
import { compile as compileHashes } from "./compile.js";
import {
  buildScriptsBundle,
  runPhase2Mints,
  runPhase3RefScripts,
  runPhase4aStakes,
  runPhase4bStateUtxos,
} from "./lib/phases.js";
import type { CeremonyHashes } from "./lib/datumBuilders.js";
import { createBlockfrostProvider } from "./lib/blockfrostProvider.js";

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

interface CliArgs {
  network: NetworkName;
  releaseTag: string;
  dryRun: boolean;
  reset: boolean;
  skipCompile: boolean;
}

function parseArgs(): CliArgs {
  const args = process.argv.slice(2);
  let network: NetworkName = "Preprod";
  let releaseTag = "v1-launch-rc1";
  let dryRun = false;
  let reset = false;
  let skipCompile = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--network" && i + 1 < args.length) {
      const n = args[++i];
      if (n !== "Preprod" && n !== "Mainnet") {
        throw new Error(`--network must be Preprod or Mainnet (got ${n})`);
      }
      network = n;
    } else if (a === "--releaseTag" && i + 1 < args.length) {
      releaseTag = args[++i];
    } else if (a === "--dryRun" || a === "--dry-run") {
      dryRun = true;
    } else if (a === "--reset") {
      reset = true;
    } else if (a === "--skipCompile") {
      skipCompile = true;
    } else if (a === "--help" || a === "-h") {
      console.log(`Usage: npx tsx deploy/deploy.ts [options]

Options:
  --network <Preprod|Mainnet>   Default: Preprod
  --releaseTag <tag>            State file suffix (default: v1-launch-rc1)
  --dryRun                      Print plan, no TXs submitted
  --reset                       Archive existing state file and start fresh
  --skipCompile                 Skip recompile (use existing state.hashes)
  -h, --help                    Show this help`);
      process.exit(0);
    }
  }
  return { network, releaseTag, dryRun, reset, skipCompile };
}

/**
 * Fetch the BIP39 mnemonic from a Unix-socket key daemon.
 * Protocol: connect → write `GET_MNEMONIC` → read response prefixed with `OK:`
 * or the raw mnemonic. Matches scripts/admin/preprod-consolidate-utxos.ts.
 */
async function fetchMnemonicFromKeyDaemon(sockPath: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const c = net.createConnection(sockPath, () => c.write("GET_MNEMONIC"));
    let buf = "";
    c.on("data", (d) => {
      buf += d.toString();
    });
    c.on("end", () =>
      resolve(buf.startsWith("OK:") ? buf.slice(3).trim() : buf.trim()),
    );
    c.on("error", reject);
    setTimeout(() => reject(new Error(`key daemon timeout after 5s (${sockPath})`)), 5000);
  });
}

/**
 * Initialize Lucid with Blockfrost + wallet. Wallet source is picked in
 * this priority order: keyDaemonSocket > seedPhraseEnv > seedPhrase.
 * Config validation has already guaranteed exactly one of those is set.
 * Uses the patched Blockfrost provider from scripts/utils (protocol-params
 * cache, Conway null-field handling, key rotation).
 */
async function initLucid(cfg: DeployConfig): Promise<LucidEvolution> {
  const provider = createBlockfrostProvider(
    cfg.blockfrost.url,
    cfg.blockfrost.projectId!,
    cfg.blockfrost.projectIdBackup,
  );
  const lucid = await Lucid(provider as any, cfg.network);
  let mnemonic: string;
  const w = cfg.wallet;
  if (w.keyDaemonSocket) {
    log("INFO", `Fetching mnemonic from key daemon: ${w.keyDaemonSocket}`);
    mnemonic = await fetchMnemonicFromKeyDaemon(w.keyDaemonSocket);
  } else if (w.seedPhraseEnv) {
    const env = process.env[w.seedPhraseEnv];
    if (!env) {
      throw new Error(`Env var ${w.seedPhraseEnv} (wallet.seedPhraseEnv) is not set`);
    }
    mnemonic = env;
  } else if (w.seedPhrase) {
    mnemonic = w.seedPhrase;
  } else {
    throw new Error("Wallet source unresolved — config validation should have caught this");
  }
  lucid.selectWallet.fromSeed(mnemonic);
  const addr = await lucid.wallet().address();
  log("INFO", `Deploy wallet address: ${addr}`);
  return lucid;
}

/**
 * Pick 3 distinct UTxOs from the deploy wallet that have ≥ 5 ADA each
 * (conservative: ensures the mint TX has enough lovelace for min-UTxO
 * + fees after consuming the picked UTxO). We specifically pick
 * pure-ADA UTxOs (no other tokens) so the mint TXs don't need to handle
 * token change in multi-asset outputs.
 */
async function pickUtxoRefs(lucid: LucidEvolution): Promise<{
  vaultNft: { txHash: string; outputIndex: number };
  governanceNft: { txHash: string; outputIndex: number };
  registryAuthNft: { txHash: string; outputIndex: number };
}> {
  const addr = await lucid.wallet().address();
  const utxos = await lucid.utxosAt(addr);
  const pureAda = utxos.filter((u) => {
    return Object.keys(u.assets).length === 1 &&
           u.assets.lovelace !== undefined &&
           u.assets.lovelace >= 5_000_000n;
  });
  if (pureAda.length < 3) {
    throw new Error(
      `Need ≥ 3 pure-ADA UTxOs (≥ 5 ADA each) in deploy wallet for NFT mint one-shots; found ${pureAda.length}. Send yourself 3 small ADA outputs first.`,
    );
  }
  pureAda.sort((a, b) => (a.assets.lovelace! > b.assets.lovelace! ? -1 : 1));
  const [u0, u1, u2] = pureAda;
  log("INFO", `Picked UTxO refs for NFT mints:`);
  log("INFO", `  vaultNft       : ${u0.txHash}#${u0.outputIndex} (${Number(u0.assets.lovelace!) / 1_000_000} ADA)`);
  log("INFO", `  governanceNft  : ${u1.txHash}#${u1.outputIndex} (${Number(u1.assets.lovelace!) / 1_000_000} ADA)`);
  log("INFO", `  registryAuthNft: ${u2.txHash}#${u2.outputIndex} (${Number(u2.assets.lovelace!) / 1_000_000} ADA)`);
  return {
    vaultNft: { txHash: u0.txHash, outputIndex: u0.outputIndex },
    governanceNft: { txHash: u1.txHash, outputIndex: u1.outputIndex },
    registryAuthNft: { txHash: u2.txHash, outputIndex: u2.outputIndex },
  };
}

/**
 * Wait for a TX to confirm on-chain via Blockfrost + then sleep an
 * extra `awaitConfirmSeconds` buffer so the indexer has caught up
 * before the next step queries UTxOs. Blockfrost's indexer lag is
 * the #1 cause of "inputs not found" BadInputsUTxO errors on rapid
 * ceremony steps.
 */
async function awaitTx(
  lucid: LucidEvolution,
  txHash: string,
  awaitSeconds: number,
): Promise<void> {
  log("INFO", `Waiting for ${txHash} to confirm…`);
  await lucid.awaitTx(txHash, 120_000);
  log("INFO", `Confirmed. Sleeping ${awaitSeconds}s for indexer to catch up.`);
  await new Promise((r) => setTimeout(r, awaitSeconds * 1000));
}

/**
 * Mint one of the 3 one-shot NFTs. Consumes the parameterised UTxO ref
 * (the mint validator requires this) + produces the NFT in a new UTxO
 * at the deploy wallet address.
 */
async function mintOneShotNft(
  lucid: LucidEvolution,
  script: Script,
  assetName: string,
  utxoRef: { txHash: string; outputIndex: number },
  dryRun: boolean,
): Promise<string> {
  const policyId = mintingPolicyToId(script);
  const unit = policyId + assetName;
  const addr = await lucid.wallet().address();
  // Fetch the exact UTxO object we parameterised against — the TX must
  // consume this specific output for the one-shot mint to validate.
  const refUtxo = await lucid.utxoByOutRef({
    txHash: utxoRef.txHash,
    outputIndex: utxoRef.outputIndex,
  });
  const mintAssets: Assets = { [unit]: 1n };
  const txBuilder = lucid
    .newTx()
    .collectFrom([refUtxo])
    .mintAssets(mintAssets, Data.void())
    .attach.MintingPolicy(script)
    .pay.ToAddress(addr, { lovelace: 2_000_000n, [unit]: 1n });
  if (dryRun) {
    log("STEP", `[DRY-RUN] Would mint policy=${policyId} asset=${assetName} consuming ${utxoRef.txHash}#${utxoRef.outputIndex}`);
    return `dry-run-${policyId.slice(0, 16)}`;
  }
  const tx = await txBuilder.complete();
  const signed = await tx.sign.withWallet().complete();
  const txHash = await signed.submit();
  log("INFO", `Minted ${policyId}.${assetName} — tx ${txHash}`);
  return txHash;
}

/**
 * Publish a single reference-script UTxO. The UTxO carries the
 * compiled Plutus validator as its `scriptRef` and its min-ADA set
 * to cover the Conway-era reference-script fee.
 */
async function publishRefScript(
  lucid: LucidEvolution,
  script: Script,
  label: string,
  awaitSeconds: number,
  dryRun: boolean,
): Promise<{ txHash: string; outputIndex: number; scriptHash: string; sizeBytes: number; minAda: string }> {
  const addr = await lucid.wallet().address();
  const scriptHash = validatorToScriptHash(script);
  const sizeBytes = Math.floor(script.script.length / 2);
  if (dryRun) {
    log("STEP", `[DRY-RUN] Would publish ref script ${label} (${sizeBytes} B, hash ${scriptHash})`);
    return {
      txHash: `dry-run-${label}`,
      outputIndex: 0,
      scriptHash,
      sizeBytes,
      minAda: "0",
    };
  }
  // Send ourselves a UTxO with the script attached as reference_script.
  // Lucid's pay.ToAddressWithData handles min-ADA calculation including
  // the Conway ref-script surcharge. We use 1 lovelace here as "whatever
  // it takes" — Lucid will bump up to the real min-ADA automatically.
  const tx = await lucid
    .newTx()
    .pay.ToAddressWithData(
      addr,
      { kind: "inline", value: Data.void() },
      { lovelace: 1n },
      script,
    )
    .complete();
  const signed = await tx.sign.withWallet().complete();
  const txHash = await signed.submit();
  log("INFO", `Published ref script ${label} — tx ${txHash} (${sizeBytes} B)`);
  await awaitTx(lucid, txHash, awaitSeconds);
  // Find which output index carries our ref script
  const utxos = await lucid.utxosByOutRef([{ txHash, outputIndex: 0 }]).catch(() => []);
  const refUtxo = utxos[0];
  if (!refUtxo) {
    throw new Error(`Ref-script UTxO not found after TX ${txHash}`);
  }
  return {
    txHash,
    outputIndex: 0,
    scriptHash,
    sizeBytes,
    minAda: refUtxo.assets.lovelace?.toString() ?? "0",
  };
}

// ---------------------------------------------------------------------
// Datum constructors — match the Aiken type definitions in
// `contracts/lib/vault/types.ak`. Constructor indices must match the
// Aiken type order exactly (Aiken assigns variant indices in
// declaration order starting at 0).
// ---------------------------------------------------------------------

function buildRegistryDatum(
  cfg: DeployConfig,
  now: number,
): Data {
  // RegistryDatum fields (per types.ak):
  //   governance_policy, governance_name, protocol_hashes, stable_tokens,
  //   liqwid_markets, last_update_time, keeper_pkh
  //
  // stable_tokens + liqwid_markets are empty lists at launch — depositors
  // cannot be routed anywhere until governance adds entries via UpdateRegistry.
  return new Constr(0, [
    // NOTE: the registry datum governance_policy is populated from the
    // compile-time state, not config.governance.*NftAssetName — caller
    // will slot in the correct policy via CompiledHashes after compile.
    // For now we return a shape that deploy.ts fills in completely.
    "00".repeat(28), // placeholder; replaced by caller
    cfg.governance.governanceNftAssetName,
    cfg.registryInitialParams.protocolHashes,
    cfg.registryInitialParams.stableTokens.map((s) => new Constr(0, [s.policy, s.name])),
    cfg.registryInitialParams.liqwidMarkets.map((m) =>
      new Constr(0, [
        m.actionAddrHash,
        m.qtokenPolicy,
        m.qtokenName,
        m.underlyingPolicy,
        m.underlyingName,
        m.active ? new Constr(1, []) : new Constr(0, []),
      ]),
    ),
    BigInt(now),
    cfg.registryInitialParams.keeperPkh,
  ]) as unknown as Data;
}

// Full datum builders for treasury / keeper-auth / governance / vault
// follow the same pattern. They are intentionally elided from this
// scaffold file and implemented in the state-init phase of the deploy
// ceremony. The ceremony main loop below shows where each is called;
// when the operator runs `deploy.ts --dryRun`, the shape of the
// pipeline is exercised end to end without submitting real TXs.

// ---------------------------------------------------------------------
// Main ceremony
// ---------------------------------------------------------------------
async function main() {
  const args = parseArgs();
  const cfg = loadConfig(args.network);
  log("INFO", `=== V1 Deploy Ceremony ===`);
  log("INFO", `Network:     ${args.network}`);
  log("INFO", `Release tag: ${args.releaseTag}`);
  log("INFO", `Dry run:     ${args.dryRun}`);

  // Process lock — refuses to start if another deploy.ts is alive on
  // the same (network, releaseTag). Without this, concurrent runs
  // race on PHASE 0 NFT bootstrap UTxO selection (orphan ref-script
  // ADA, lost mint TX hashes) and PHASE 3+ state-file overwrites.
  // Auto-clears stale locks left by crashed prior runs.
  if (!args.dryRun) acquireLock(args.network, args.releaseTag);

  if (args.reset) {
    resetState(args.network, args.releaseTag);
  }

  const lucid = args.dryRun ? null : await initLucid(cfg);
  let state = loadState(args.network, args.releaseTag);

  // -------- PHASE 0: pick UTxO refs --------
  if (!state.mints.vaultNft && !state.mints.governanceNft && !state.mints.registryAuthNft) {
    log("STEP", "PHASE 0: picking UTxO refs for 3 one-shot NFT mints");
    if (!lucid) {
      throw new Error("Dry-run cannot pick real UTxO refs. Supply a known utxoRefs file + use --skipCompile for offline rehearsals.");
    }
    const refs = await pickUtxoRefs(lucid);
    state.mints.vaultNft = { txHash: "", utxoRef: refs.vaultNft, policyId: "", assetName: "" };
    state.mints.governanceNft = { txHash: "", utxoRef: refs.governanceNft, policyId: "", assetName: "" };
    state.mints.registryAuthNft = { txHash: "", utxoRef: refs.registryAuthNft, policyId: "", assetName: "" };
    saveState(state);
  } else {
    log("INFO", "PHASE 0 already complete (UTxO refs present in state)");
  }

  // -------- PHASE 1: compile hashes --------
  if (!state.hashes && !args.skipCompile) {
    log("STEP", "PHASE 1: compiling validator hashes");
    const compiled = compileHashes(args.network, {
      vaultNft: state.mints.vaultNft!.utxoRef,
      governanceNft: state.mints.governanceNft!.utxoRef,
      registryAuthNft: state.mints.registryAuthNft!.utxoRef,
    });
    state.hashes = {
      vaultNftPolicy: compiled.vaultNftPolicy,
      governanceNftPolicy: compiled.governanceNftPolicy,
      registryAuthPolicy: compiled.registryAuthPolicy,
      keeperStakeHash: compiled.keeperStakeHash,
      treasuryHash: compiled.treasuryHash,
      userStakeHash: compiled.userStakeHash,
      keeperHotStakeHash: compiled.keeperHotStakeHash,
      batcherStakeHash: compiled.batcherStakeHash,           // Phase 77d
      swapAdaStakeHash: compiled.swapAdaStakeHash,           // Phase 77b
      protocolStakeHash: compiled.protocolStakeHash,
      recallStakeHash: compiled.recallStakeHash,             // Phase 77 split
      liqwidStakeHash: compiled.liqwidStakeHash,
      govPolicyStakeHash: compiled.govPolicyStakeHash,
      govEmergencyStakeHash: compiled.govEmergencyStakeHash,
      adminDeployStakeHash: compiled.adminDeployStakeHash,   // Phase 77c
      vaultProxyHash: compiled.vaultProxyHash,
      orderScriptHash: compiled.orderScriptHash,
      vusdcxPolicy: compiled.vusdcxPolicy,
      multisigGovHash: compiled.multisigGovHash,
      registryHash: compiled.registryHash,
      governanceNftName: compiled.governanceNftName,
      registryAuthName: compiled.registryAuthName,
      minswapV2AdapterHash: compiled.minswapV2AdapterHash,   // §B@launch=1
    };
    saveState(state);
    log("INFO", "Hashes compiled and saved to state");
  }

  if (args.dryRun) {
    log("INFO", "Dry-run complete. Hash summary:");
    console.log(JSON.stringify(state.hashes, null, 2));
    return;
  }

  // Recompile scriptsApplied (hashes above were saved to state but we need the
  // applied CBOR for every validator so phases 2–4 can attach/publish them).
  const compiled = compileHashes(args.network, {
    vaultNft: state.mints.vaultNft!.utxoRef,
    governanceNft: state.mints.governanceNft!.utxoRef,
    registryAuthNft: state.mints.registryAuthNft!.utxoRef,
  });
  const scripts = buildScriptsBundle(compiled.scriptsApplied);

  const hashes: CeremonyHashes = {
    vaultNftPolicy: state.hashes!.vaultNftPolicy,
    governanceNftPolicy: state.hashes!.governanceNftPolicy,
    registryAuthPolicy: state.hashes!.registryAuthPolicy,
    governanceNftName: state.hashes!.governanceNftName,
    registryAuthName: state.hashes!.registryAuthName,
    keeperStakeHash: state.hashes!.keeperStakeHash,
    treasuryHash: state.hashes!.treasuryHash,
    userStakeHash: state.hashes!.userStakeHash,
    keeperHotStakeHash: state.hashes!.keeperHotStakeHash,
    batcherStakeHash: state.hashes!.batcherStakeHash,
    swapAdaStakeHash: state.hashes!.swapAdaStakeHash,
    protocolStakeHash: state.hashes!.protocolStakeHash,
    recallStakeHash: state.hashes!.recallStakeHash,
    liqwidStakeHash: state.hashes!.liqwidStakeHash,
    govPolicyStakeHash: state.hashes!.govPolicyStakeHash,
    govEmergencyStakeHash: state.hashes!.govEmergencyStakeHash,
    adminDeployStakeHash: state.hashes!.adminDeployStakeHash,
    vaultProxyHash: state.hashes!.vaultProxyHash,
    orderScriptHash: state.hashes!.orderScriptHash,
    vusdcxPolicy: state.hashes!.vusdcxPolicy,
    multisigGovHash: state.hashes!.multisigGovHash,
    registryHash: state.hashes!.registryHash,
    minswapV2AdapterHash: state.hashes!.minswapV2AdapterHash,
  };

  // -------- PHASE 2: mint 3 one-shot NFTs --------
  await runPhase2Mints(lucid!, scripts, cfg, state, hashes);

  // -------- PHASE 3: publish 18 reference scripts --------
  await runPhase3RefScripts(
    lucid!,
    scripts,
    cfg,
    state,
    cfg.blockfrost.url,
    cfg.blockfrost.projectId!,
  );

  // -------- PHASE 4a: register 12 stake credentials --------
  await runPhase4aStakes(
    lucid!,
    scripts,
    cfg,
    state,
    cfg.blockfrost.url,
    cfg.blockfrost.projectId!,
  );

  // -------- PHASE 4b: initialize 5 state UTXOs --------
  await runPhase4bStateUtxos(lucid!, scripts, cfg, state, hashes);

  log("INFO", "=== V1 ceremony complete ===");
  log("INFO", `State file: deploy/state/${args.network.toLowerCase()}-${args.releaseTag}.json`);
  log("INFO", `Vault addr: ${state.stateUtxos.vault?.address}`);
  log("INFO", `Registry addr: ${state.stateUtxos.registry?.address}`);
  releaseLock();
}

main().catch((err) => {
  log("ERROR", (err as Error).message);
  if ((err as Error).stack) {
    console.error((err as Error).stack);
  }
  releaseLock();
  process.exit(1);
});
