/**
 * Mock deploy for on-chain V1 full-drain verification.
 *
 * SUPERSEDED (2026-04-22): after the §5.4 P1 vault_core split into
 * vault_user + vault_keeper_hot, full-drain Withdraw now lives in
 * vault_user. This tool still compiles `vault_core.vault_core` and
 * will fail at `getCompiledCode()` — see preprod-mock.json `_comment`
 * for the rewrite plan. The v1-mock-drain Preprod ceremony already
 * completed (Vault NFT `9cd81a56…` burned, proxy addr emptied —
 * documented in `v1/deploy/state/recovery-verification.md`), so this
 * rewrite is low-priority archival maintenance.
 *
 * Original description:
 *
 * Deploys the minimal 4-validator subset required to exercise
 * full-drain Withdraw:
 *   - vault_nft (mint policy)
 *   - vault_user (staking validator, was vault_core pre-split)
 *   - vault_proxy (spend validator)
 *   - vusdcx (mint policy)
 *
 * Compiles other staking validators (vault_keeper_hot / vault_protocol /
 * vault_liqwid / vault_gov_policy / vault_gov_emergency) with all-zero
 * placeholder params — those are never triggered during Deposit/
 * Withdraw, so placeholder hashes are fine for parameterising
 * vault_proxy + computing the proxy address.
 *
 * Compiles vault_user with placeholder keeper_stake_hash + placeholder
 * gov NFT policy/name — those are only consulted in BatchProcess
 * (keeper) and A2 publish handler (governance), never in Deposit/
 * Withdraw.
 *
 * Writes state to `v1/deploy/state/preprod-<releaseTag>.json` for the
 * companion `full-drain-test.ts` to consume.
 *
 * Usage:
 *   npx tsx v1/deploy/tools/mock-full-drain-deploy.ts --releaseTag v1-mock-drain
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import * as fs from "fs";
import * as net from "node:net";
import * as path from "path";
import {
  Constr,
  Data,
  Lucid,
  applyParamsToScript,
  mintingPolicyToId,
  paymentCredentialOf,
  validatorToAddress,
  validatorToRewardAddress,
  validatorToScriptHash,
} from "@lucid-evolution/lucid";
import type { LucidEvolution, Script } from "@lucid-evolution/lucid";
import { createBlockfrostProvider } from "../../../scripts/utils/blockfrostProvider.js";
import { deployRefScripts } from "../../../scripts/utils/deployRefScript.js";

const C = { reset: "\x1b[0m", green: "\x1b[1;92m", yellow: "\x1b[1;93m", cyan: "\x1b[1;96m", red: "\x1b[1;91m" };
function log(lvl: "INFO" | "STEP" | "WARN" | "ERROR", msg: string) {
  const color = lvl === "INFO" ? C.green : lvl === "STEP" ? C.cyan : lvl === "WARN" ? C.yellow : C.red;
  console.log(`${color}[${lvl}]${C.reset} ${msg}`);
}

function parseArgs(): { releaseTag: string } {
  const a = process.argv.slice(2);
  let releaseTag = "v1-mock-drain";
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--releaseTag") releaseTag = a[++i];
  }
  return { releaseTag };
}

async function getMnemonic(sockPath: string): Promise<string> {
  if (process.env.KEEPER_MNEMONIC) return process.env.KEEPER_MNEMONIC;
  return new Promise((res, rej) => {
    const c = net.createConnection(sockPath, () => c.write("GET_MNEMONIC"));
    let buf = "";
    c.on("data", (d) => { buf += d.toString(); });
    c.on("end", () => res(buf.startsWith("OK:") ? buf.slice(3).trim() : buf.trim()));
    c.on("error", rej);
    setTimeout(() => rej(new Error("timeout")), 5000);
  });
}

async function awaitTxAndSettle(lucid: LucidEvolution, txHash: string, settleSec: number) {
  log("INFO", `Awaiting ${txHash.slice(0, 12)}…`);
  await lucid.awaitTx(txHash, 180_000);
  await new Promise((r) => setTimeout(r, settleSec * 1000));
}

const PLACEHOLDER_28 = "00".repeat(28);
const NFT_TOKEN_NAME = "4f7074695661756c74"; // "OptiVault" hex

interface Blueprint {
  validators: { title: string; compiledCode: string; parameters?: any[] }[];
}

function loadBlueprint(): Blueprint {
  const p = path.join("v1", "contracts", "plutus.json");
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function getCode(bp: Blueprint, prefix: string): string {
  const v = bp.validators.find((x) => x.title.startsWith(prefix + "."));
  if (!v) throw new Error(`${prefix} not found`);
  return v.compiledCode;
}

async function main() {
  const { releaseTag } = parseArgs();
  const cfg = JSON.parse(fs.readFileSync("v1/deploy/config/preprod-mock.json", "utf8"));
  const bfKey = process.env[cfg.blockfrost.projectIdEnv];
  if (!bfKey) throw new Error(`${cfg.blockfrost.projectIdEnv} not set`);
  const bfUrl = cfg.blockfrost.url;

  const provider = createBlockfrostProvider(bfUrl, bfKey, process.env[cfg.blockfrost.projectIdBackupEnv]);
  const lucid = await Lucid(provider as any, "Preprod");
  const mnemonic = await getMnemonic(cfg.wallet.keyDaemonSocket);
  lucid.selectWallet.fromSeed(mnemonic);
  const wallet = await lucid.wallet().address();
  const walletPkh = paymentCredentialOf(wallet).hash;
  log("INFO", `wallet ${wallet.slice(0, 30)}…${wallet.slice(-8)}`);

  const stateFile = `v1/deploy/state/preprod-${releaseTag}.json`;
  const state: any = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, "utf8")) : {
    network: "Preprod",
    releaseTag,
    startedAt: new Date().toISOString(),
    mints: {},
    refScripts: {},
    stake: {},
    vaultUtxo: null,
  };
  const save = () => {
    state.lastUpdatedAt = new Date().toISOString();
    fs.writeFileSync(stateFile, JSON.stringify(state, null, 2) + "\n");
  };

  const bp = loadBlueprint();
  const awaitSec = cfg.ceremonyOptions.awaitConfirmSeconds;

  // ───────────────────────────── STEP 1: pick UTxO ref for Vault NFT ─
  if (!state.mints.vaultNft) {
    log("STEP", "Step 1: pick UTxO ref for vault_nft mint");
    const utxos = await lucid.wallet().getUtxos();
    const pureAda = utxos.filter((u) => Object.keys(u.assets).length === 1 && (u.assets.lovelace ?? 0n) >= 10_000_000n);
    if (pureAda.length < 1) throw new Error("need ≥1 pure-ADA UTxO with ≥10 ADA");
    pureAda.sort((a, b) => (a.assets.lovelace! > b.assets.lovelace! ? -1 : 1));
    const u = pureAda[0];
    state.mints.vaultNft = {
      utxoRef: { txHash: u.txHash, outputIndex: u.outputIndex },
    };
    save();
    log("INFO", `  picked ${u.txHash}#${u.outputIndex} (${Number(u.assets.lovelace!) / 1e6} ADA)`);
  }

  // ───────────────────────────── STEP 2: compile stack ─
  const vaultNftUtxoRef = state.mints.vaultNft.utxoRef;
  const vaultNftAppliedCode = applyParamsToScript(
    getCode(bp, "vault_nft.vault_nft"),
    [new Constr(0, [vaultNftUtxoRef.txHash, BigInt(vaultNftUtxoRef.outputIndex)]) as unknown as Data],
  );
  const vaultNftScript: Script = { type: "PlutusV3", script: vaultNftAppliedCode };
  const vaultNftPolicyId = mintingPolicyToId(vaultNftScript);
  const vaultNftUnit = vaultNftPolicyId + NFT_TOKEN_NAME;
  log("INFO", `vault_nft policy: ${vaultNftPolicyId}`);

  // vault_core: placeholder keeper_stake_hash + placeholder treasury_hash.
  // These are only referenced in Compound/Rebalance/Batch/SwapAda — never in Deposit/Withdraw.
  const vaultCoreApplied = applyParamsToScript(
    getCode(bp, "vault_core.vault_core"),
    [PLACEHOLDER_28, PLACEHOLDER_28],
  );
  const vaultCoreScript: Script = { type: "PlutusV3", script: vaultCoreApplied };
  const coreStakeHash = validatorToScriptHash(vaultCoreScript);
  log("INFO", `vault_core stake hash: ${coreStakeHash}`);

  // vault_proxy: real core_hash + vault_nft_policy; placeholder for protocol/liqwid/admin
  // (Withdraw-Zero routing only triggers one staking validator per TX, and our tests only
  // exercise UseCore, so the other three hashes can stay placeholder.)
  const vaultProxyApplied = applyParamsToScript(
    getCode(bp, "vault_proxy.vault_proxy"),
    [coreStakeHash, PLACEHOLDER_28, PLACEHOLDER_28, PLACEHOLDER_28, vaultNftPolicyId],
  );
  const vaultProxyScript: Script = { type: "PlutusV3", script: vaultProxyApplied };
  const proxyHash = validatorToScriptHash(vaultProxyScript);
  const proxyAddr = validatorToAddress("Preprod", vaultProxyScript);
  log("INFO", `vault_proxy hash: ${proxyHash}`);
  log("INFO", `vault addr:       ${proxyAddr}`);

  // vusdcx: parameterised by proxy_hash + vault_nft_policy
  const vusdcxApplied = applyParamsToScript(
    getCode(bp, "vusdcx.vusdcx"),
    [proxyHash, vaultNftPolicyId],
  );
  const vusdcxScript: Script = { type: "PlutusV3", script: vusdcxApplied };
  const vusdcxPolicy = validatorToScriptHash(vusdcxScript);
  log("INFO", `vusdcx policy:    ${vusdcxPolicy}`);

  state.hashes = { vaultNftPolicy: vaultNftPolicyId, coreStakeHash, proxyHash, proxyAddr, vusdcxPolicy };
  save();

  // ───────────────────────────── STEP 3: mint Vault NFT ─
  if (!state.mints.vaultNft.txHash) {
    log("STEP", "Step 3: mint Vault NFT (one-shot)");
    const refUtxos = await lucid.utxosByOutRef([vaultNftUtxoRef]);
    if (refUtxos.length !== 1) throw new Error(`picked UTxO gone — refetch state or rerun`);
    const tx = await lucid
      .newTx()
      .collectFrom(refUtxos)
      .mintAssets({ [vaultNftUnit]: 1n }, Data.void())
      .attach.MintingPolicy(vaultNftScript)
      .pay.ToAddress(wallet, { lovelace: 2_000_000n, [vaultNftUnit]: 1n })
      .complete();
    const signed = await tx.sign.withWallet().complete();
    const txHash = await signed.submit();
    state.mints.vaultNft.txHash = txHash;
    save();
    log("INFO", `  mint TX ${txHash}`);
    await awaitTxAndSettle(lucid, txHash, awaitSec);
  } else {
    log("INFO", `Vault NFT already minted: ${state.mints.vaultNft.txHash}`);
  }

  // ───────────────────────────── STEP 4: publish 3 ref scripts ─
  const refScriptPlan: { label: string; script: Script; hash: string; size: number }[] = [
    { label: "vaultProxy", script: vaultProxyScript, hash: proxyHash, size: Math.floor(vaultProxyApplied.length / 2) },
    { label: "vaultCore", script: vaultCoreScript, hash: coreStakeHash, size: Math.floor(vaultCoreApplied.length / 2) },
    { label: "vusdcx", script: vusdcxScript, hash: vusdcxPolicy, size: Math.floor(vusdcxApplied.length / 2) },
  ];
  for (const r of refScriptPlan) {
    if (state.refScripts[r.label]) {
      log("INFO", `ref ${r.label}: already published (${state.refScripts[r.label].txHash})`);
      continue;
    }
    log("STEP", `Step 4.${r.label}: publish ref script (${r.size}B)`);
    const minAda = BigInt(Math.ceil((r.size + 200) * 4310 * 1.1)) + 1_000_000n;
    const [res] = await deployRefScripts(lucid, [r.script], [minAda], bfUrl, bfKey);
    state.refScripts[r.label] = {
      txHash: res.txHash,
      outputIndex: res.outputIndex,
      scriptHash: r.hash,
      sizeBytes: r.size,
      minAda: minAda.toString(),
    };
    save();
    log("INFO", `  TX ${res.txHash}`);
    await awaitTxAndSettle(lucid, res.txHash, awaitSec);
  }

  // ───────────────────────────── STEP 5: register vault_core stake cred ─
  if (!state.stake.vaultCore) {
    log("STEP", "Step 5: register vault_core stake credential");
    const rewardAddr = validatorToRewardAddress("Preprod", vaultCoreScript);
    // Check on-chain status first
    const res = await fetch(`${bfUrl}/accounts/${rewardAddr}`, { headers: { project_id: bfKey } });
    if (res.status === 200) {
      log("INFO", `  already registered on-chain: ${rewardAddr.slice(0, 40)}…`);
      state.stake.vaultCore = { txHash: "preexisting", rewardAddr, stakeHash: coreStakeHash };
    } else {
      try {
        const tx = await lucid.newTx().register.Stake(rewardAddr).complete();
        const signed = await tx.sign.withWallet().complete();
        const txHash = await signed.submit();
        state.stake.vaultCore = { txHash, rewardAddr, stakeHash: coreStakeHash };
        save();
        log("INFO", `  TX ${txHash}`);
        await awaitTxAndSettle(lucid, txHash, awaitSec);
      } catch (e) {
        const msg = (e as Error).message;
        if (/StakeKeyRegistered|already/i.test(msg)) {
          log("INFO", `  race-recorded as preexisting`);
          state.stake.vaultCore = { txHash: "preexisting", rewardAddr, stakeHash: coreStakeHash };
          save();
        } else { throw e; }
      }
    }
    save();
  } else {
    log("INFO", `vault_core stake already registered: ${state.stake.vaultCore.txHash}`);
  }

  // ───────────────────────────── STEP 6: init mock Vault UTxO ─
  if (!state.vaultUtxo) {
    log("STEP", "Step 6: init mock Vault UTxO at proxy addr");
    const nowMs = Date.now();
    // Mock VaultDatum (26 fields). Accounting fields all zero at init.
    // Full-drain only reads: total_shares, vusdcx_policy, deposit_token_policy,
    //  deposit_token_name, strategy_allocations, liqwid_positions, non_deposit_value,
    //  last_compound_time, min_hold_seconds, early_withdraw_fee_bps, order_script_hash.
    // Everything else can be placeholder.
    const datum = Data.to(new Constr(0, [
      0n,                           // 0: total_deposited
      0n,                           // 1: total_shares
      0n,                           // 2: idle_buffer
      0n,                           // 3: non_deposit_value
      BigInt(nowMs),                // 4: last_compound_time
      BigInt(nowMs),                // 5: last_realloc_time
      BigInt(nowMs),                // 6: last_fee_update_time
      BigInt(nowMs),                // 7: last_ada_swap_time
      [],                           // 8: strategy_allocations
      [],                           // 9: liqwid_positions
      BigInt(cfg.vaultInitialParams.performanceFeeBps),   // 10
      BigInt(cfg.vaultInitialParams.earlyWithdrawFeeBps), // 11 ← 0 (key for full-drain)
      BigInt(cfg.vaultInitialParams.minHoldSeconds),      // 12
      BigInt(cfg.vaultInitialParams.bufferTargetBps),     // 13
      BigInt(cfg.vaultInitialParams.keeperFeeBps),        // 14
      BigInt(cfg.vaultInitialParams.govFeeBps),           // 15
      BigInt(cfg.vaultInitialParams.vaultVersion),        // 16: vault_version
      PLACEHOLDER_28,               // 17: governance_policy (placeholder — not read by full-drain)
      "",                           // 18: governance_name (empty — not read)
      cfg.depositToken.policy,      // 19: deposit_token_policy
      cfg.depositToken.name,        // 20: deposit_token_name
      vusdcxPolicy,                 // 21: vusdcx_policy
      PLACEHOLDER_28,               // 22: order_script_hash (placeholder — "no inputs at this hash" check passes)
      PLACEHOLDER_28,               // 23: registry_hash (placeholder)
      PLACEHOLDER_28,               // 24: registry_auth_policy (placeholder)
      0n,                           // 25: frozen
    ]) as unknown as Data);
    const tx = await lucid
      .newTx()
      .pay.ToAddressWithData(
        proxyAddr,
        { kind: "inline", value: datum as unknown as string },
        { lovelace: BigInt(cfg.vaultInitialParams.seedLovelace), [vaultNftUnit]: 1n },
      )
      .complete();
    const signed = await tx.sign.withWallet().complete();
    const txHash = await signed.submit();
    state.vaultUtxo = { txHash, outputIndex: 0, address: proxyAddr, vaultNftUnit, datumAt: nowMs };
    save();
    log("INFO", `  Vault UTxO TX ${txHash} at idx 0`);
    await awaitTxAndSettle(lucid, txHash, awaitSec);
  } else {
    log("INFO", `Vault UTxO already initialised: ${state.vaultUtxo.txHash}`);
  }

  log("INFO", "=== Mock deploy complete ===");
  log("INFO", `  state: ${stateFile}`);
  log("INFO", `  vault addr: ${proxyAddr}`);
  log("INFO", `  vault NFT: ${vaultNftPolicyId}`);
  log("INFO", `  vusdcx: ${vusdcxPolicy}`);
  log("INFO", `Next: npx tsx v1/deploy/tools/full-drain-test.ts --releaseTag ${releaseTag}`);
}

main().catch((e) => { log("ERROR", (e as Error).message); if ((e as Error).stack) console.error((e as Error).stack); process.exit(1); });
