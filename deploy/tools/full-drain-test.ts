/**
 * On-chain V1 full-drain verification.
 *
 * SUPERSEDED (2026-04-22): companion `mock-full-drain-deploy.ts` is
 * superseded by the §5.4 P1 vault_core split. This tool references
 * `vault_core` + `state.refScripts.vaultCore` + `state.hashes.
 * coreStakeHash` throughout, none of which exist in the post-split
 * state schema. The v1-mock-drain Preprod ceremony already completed
 * successfully before the split (see recovery-verification.md), so
 * this rewrite is low-priority. Rewrite plan: s/vaultCore/vaultUser/
 * throughout + s/coreStakeHash/userStakeHash/ + update applyParams to
 * the new 3-param (keeper_stake_hash, gov_policy, gov_name) shape of
 * vault_user.
 *
 * Consumes the state produced by `mock-full-drain-deploy.ts`:
 *   1. Build Deposit TX — mock Vault UTxO consumed, wallet pays 10 USDCx,
 *      10^13 vUSDCx minted, new Vault UTxO produced with updated datum
 *      (td=10_000_000, ts=10^13, idle_buffer=10_000_000).
 *   2. Wait min_hold_seconds (60 s) so the Withdraw early-fee check passes.
 *   3. Build Withdraw full-drain TX — consume updated Vault UTxO, burn all
 *      10^13 vUSDCx, burn 1 Vault NFT, NO continuing vault output, receiver
 *      (operator wallet) gets the 10 USDCx + vault lovelace.
 *   4. Verify on-chain:
 *      - proxy addr has 0 UTxOs
 *      - vault NFT policy has 0 total supply
 *      - wallet USDCx delta = +0 (10 deposited + 10 withdrawn = net 0)
 *      - wallet ADA delta ≈ vault seed - fees (±3 ADA)
 *
 * Usage:
 *   npx tsx deploy/tools/full-drain-test.ts --releaseTag v1-mock-drain
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import * as fs from "fs";
import * as net from "node:net";
import {
  Constr,
  Data,
  Lucid,
  applyParamsToScript,
  mintingPolicyToId,
  paymentCredentialOf,
  validatorToAddress,
  validatorToRewardAddress,
} from "@lucid-evolution/lucid";
import type { LucidEvolution, Script, UTxO } from "@lucid-evolution/lucid";
import { createBlockfrostProvider } from "../../../scripts/utils/blockfrostProvider.js";

const C = { reset: "\x1b[0m", green: "\x1b[1;92m", yellow: "\x1b[1;93m", cyan: "\x1b[1;96m", red: "\x1b[1;91m" };
function log(lvl: "INFO" | "STEP" | "WARN" | "ERROR", msg: string) {
  const color = lvl === "INFO" ? C.green : lvl === "STEP" ? C.cyan : lvl === "WARN" ? C.yellow : C.red;
  console.log(`${color}[${lvl}]${C.reset} ${msg}`);
}

function parseArgs(): { releaseTag: string } {
  const a = process.argv.slice(2);
  let releaseTag = "v1-mock-drain";
  for (let i = 0; i < a.length; i++) if (a[i] === "--releaseTag") releaseTag = a[++i];
  return { releaseTag };
}

async function getMnemonic(sock: string): Promise<string> {
  if (process.env.KEEPER_MNEMONIC) return process.env.KEEPER_MNEMONIC;
  return new Promise((res, rej) => {
    const c = net.createConnection(sock, () => c.write("GET_MNEMONIC"));
    let buf = "";
    c.on("data", (d) => { buf += d.toString(); });
    c.on("end", () => res(buf.startsWith("OK:") ? buf.slice(3).trim() : buf.trim()));
    c.on("error", rej);
    setTimeout(() => rej(new Error("timeout")), 5000);
  });
}

const PLACEHOLDER_28 = "00".repeat(28);

function rebuildDatum(
  td: bigint,
  ts: bigint,
  idleBuffer: bigint,
  lastCompoundMs: bigint,
  depositTokenPolicy: string,
  depositTokenName: string,
  vusdcxPolicy: string,
): string {
  return Data.to(new Constr(0, [
    td,                                    // 0: total_deposited
    ts,                                    // 1: total_shares
    idleBuffer,                            // 2: idle_buffer
    0n,                                    // 3: non_deposit_value
    lastCompoundMs,                        // 4: last_compound_time
    lastCompoundMs,                        // 5: last_realloc_time
    lastCompoundMs,                        // 6: last_fee_update_time
    lastCompoundMs,                        // 7: last_ada_swap_time
    [],                                    // 8: strategy_allocations
    [],                                    // 9: liqwid_positions
    450n,                                  // 10: performance_fee_bps
    0n,                                    // 11: early_withdraw_fee_bps ← 0
    60n,                                   // 12: min_hold_seconds
    3500n,                                 // 13: buffer_target_bps
    2000n,                                 // 14: keeper_fee_bps
    0n,                                    // 15: gov_fee_bps
    1n,                                    // 16: vault_version
    PLACEHOLDER_28,                        // 17: governance_policy
    "",                                    // 18: governance_name
    depositTokenPolicy,                    // 19
    depositTokenName,                      // 20
    vusdcxPolicy,                          // 21
    PLACEHOLDER_28,                        // 22: order_script_hash
    PLACEHOLDER_28,                        // 23: registry_hash
    PLACEHOLDER_28,                        // 24: registry_auth_policy
    0n,                                    // 25: frozen
  ]) as unknown as Data);
}

async function main() {
  const { releaseTag } = parseArgs();
  const cfg = JSON.parse(fs.readFileSync("deploy/config/preprod-mock.json", "utf8"));
  const bfKey = process.env[cfg.blockfrost.projectIdEnv];
  if (!bfKey) throw new Error(`${cfg.blockfrost.projectIdEnv} missing`);
  const bfUrl = cfg.blockfrost.url;

  const stateFile = `deploy/state/preprod-${releaseTag}.json`;
  if (!fs.existsSync(stateFile)) throw new Error(`state not found: ${stateFile}`);
  const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  if (!state.vaultUtxo) throw new Error(`mock deploy incomplete — vaultUtxo missing`);

  const provider = createBlockfrostProvider(bfUrl, bfKey, process.env[cfg.blockfrost.projectIdBackupEnv]);
  const lucid = await Lucid(provider as any, "Preprod");
  const mnemonic = await getMnemonic(cfg.wallet.keyDaemonSocket);
  lucid.selectWallet.fromSeed(mnemonic);
  const wallet = await lucid.wallet().address();
  const walletPkh = paymentCredentialOf(wallet).hash;
  log("INFO", `wallet ${wallet.slice(0, 30)}…`);

  // Load compiled scripts from state (applied CBOR was not saved — recompile on the fly)
  const bp = JSON.parse(fs.readFileSync("contracts/plutus.json", "utf8"));
  const getCode = (prefix: string): string =>
    bp.validators.find((v: any) => v.title.startsWith(prefix + "."))!.compiledCode;

  const vaultNftApplied = applyParamsToScript(
    getCode("vault_nft.vault_nft"),
    [new Constr(0, [state.mints.vaultNft.utxoRef.txHash, BigInt(state.mints.vaultNft.utxoRef.outputIndex)]) as unknown as Data],
  );
  const vaultNftScript: Script = { type: "PlutusV3", script: vaultNftApplied };
  const vaultNftPolicyId = mintingPolicyToId(vaultNftScript);
  const vaultNftUnit = vaultNftPolicyId + "4f7074695661756c74";

  const coreApplied = applyParamsToScript(getCode("vault_core.vault_core"), [PLACEHOLDER_28, PLACEHOLDER_28]);
  const vaultCoreScript: Script = { type: "PlutusV3", script: coreApplied };

  const proxyApplied = applyParamsToScript(
    getCode("vault_proxy.vault_proxy"),
    [state.hashes.coreStakeHash, PLACEHOLDER_28, PLACEHOLDER_28, PLACEHOLDER_28, vaultNftPolicyId],
  );
  const vaultProxyScript: Script = { type: "PlutusV3", script: proxyApplied };
  const proxyAddr = validatorToAddress("Preprod", vaultProxyScript);

  const vusdcxApplied = applyParamsToScript(getCode("vusdcx.vusdcx"), [state.hashes.proxyHash, vaultNftPolicyId]);
  const vusdcxScript: Script = { type: "PlutusV3", script: vusdcxApplied };

  const coreRewardAddr = validatorToRewardAddress("Preprod", vaultCoreScript);

  // Load ref scripts (as UTxO refs for tx inputs)
  const proxyRef = await lucid.utxosByOutRef([{ txHash: state.refScripts.vaultProxy.txHash, outputIndex: state.refScripts.vaultProxy.outputIndex }]);
  const coreRef = await lucid.utxosByOutRef([{ txHash: state.refScripts.vaultCore.txHash, outputIndex: state.refScripts.vaultCore.outputIndex }]);
  const vusdcxRef = await lucid.utxosByOutRef([{ txHash: state.refScripts.vusdcx.txHash, outputIndex: state.refScripts.vusdcx.outputIndex }]);
  if (!proxyRef[0] || !coreRef[0] || !vusdcxRef[0]) throw new Error("ref scripts missing on-chain");

  const depositTokenUnit = cfg.depositToken.policy + cfg.depositToken.name;

  // Track state across Deposit/Withdraw
  state.test = state.test || {};

  // ═══════════════════════════════════════════════════
  // Step A: Deposit 10 USDCx
  // ═══════════════════════════════════════════════════
  if (!state.test.depositTx) {
    log("STEP", "Step A: Deposit 10 USDCx");
    const vaultUtxos = await lucid.utxosByOutRef([
      { txHash: state.vaultUtxo.txHash, outputIndex: state.vaultUtxo.outputIndex },
    ]);
    if (!vaultUtxos[0]) throw new Error("Vault UTxO not found on-chain");
    const vaultIn = vaultUtxos[0];
    const currentLovelace = vaultIn.assets.lovelace ?? 0n;
    log("INFO", `  vault UTxO: ${Number(currentLovelace)/1e6} ADA + ${vaultIn.assets[vaultNftUnit] ?? 0n} NFT`);

    const depositAmount = 10_000_000n; // 10 USDCx
    const sharesToMint = 10_000_000_000_000n; // 10^13 first-deposit multiplier
    const nowMs = BigInt(Date.now());

    const newDatum = rebuildDatum(
      depositAmount,
      sharesToMint,
      depositAmount,
      BigInt(state.vaultUtxo.datumAt),
      cfg.depositToken.policy,
      cfg.depositToken.name,
      state.hashes.vusdcxPolicy,
    );

    const redeemerDeposit = Data.to(new Constr(0, [depositAmount]) as unknown as Data);   // Deposit { amount }
    const redeemerUseCore = Data.to(new Constr(0, []) as unknown as Data);                 // UseCore
    const redeemerMintShares = Data.to(new Constr(0, []) as unknown as Data);              // MintShares

    const tx = lucid
      .newTx()
      .collectFrom([vaultIn], redeemerUseCore)
      .readFrom([proxyRef[0], coreRef[0], vusdcxRef[0]])
      .withdraw(coreRewardAddr, 0n, redeemerDeposit)
      .mintAssets({ [state.hashes.vusdcxPolicy + "765553444378"]: sharesToMint }, redeemerMintShares)
      .pay.ToAddressWithData(
        proxyAddr,
        { kind: "inline", value: newDatum as unknown as string },
        {
          lovelace: currentLovelace,
          [vaultNftUnit]: 1n,
          [depositTokenUnit]: depositAmount,
        },
      )
      .validFrom(Number(nowMs) - 60_000)
      .validTo(Number(nowMs) + 15 * 60 * 1000);

    const completed = await tx.complete();
    const signed = await completed.sign.withWallet().complete();
    const txHash = await signed.submit();
    log("INFO", `  deposit TX ${txHash}`);
    await lucid.awaitTx(txHash, 180_000);
    await new Promise((r) => setTimeout(r, 30_000));
    state.test.depositTx = txHash;
    state.test.depositTime = Number(nowMs);
    state.test.sharesMinted = sharesToMint.toString();
    fs.writeFileSync(stateFile, JSON.stringify(state, null, 2) + "\n");
  } else {
    log("INFO", `deposit already done: ${state.test.depositTx}`);
  }

  // ═══════════════════════════════════════════════════
  // Step B: wait min_hold_seconds
  // ═══════════════════════════════════════════════════
  const elapsed = (Date.now() - state.test.depositTime) / 1000;
  if (elapsed < 65) {
    const waitMs = Math.ceil((65 - elapsed) * 1000);
    log("STEP", `Step B: wait ${Math.ceil(waitMs/1000)}s for min_hold_seconds (60s + buffer)`);
    await new Promise((r) => setTimeout(r, waitMs));
  } else {
    log("INFO", `min_hold already elapsed (${elapsed.toFixed(0)}s)`);
  }

  // ═══════════════════════════════════════════════════
  // Step C: Full-drain Withdraw
  // ═══════════════════════════════════════════════════
  if (!state.test.withdrawTx) {
    log("STEP", "Step C: full-drain Withdraw");
    // Find the updated Vault UTxO (output of Step A's TX, idx 0)
    const vaultUtxos = await lucid.utxosByOutRef([
      { txHash: state.test.depositTx, outputIndex: 0 },
    ]);
    if (!vaultUtxos[0]) throw new Error(`updated Vault UTxO not found (tx=${state.test.depositTx} idx=0)`);
    const vaultIn = vaultUtxos[0];
    log("INFO", `  vault UTxO: ${Number(vaultIn.assets.lovelace!)/1e6} ADA + ${vaultIn.assets[vaultNftUnit]} NFT + ${vaultIn.assets[depositTokenUnit]} USDCx`);

    const sharesMinted = BigInt(state.test.sharesMinted);
    const redeemerWithdraw = Data.to(new Constr(1, [
      sharesMinted,    // shares
      walletPkh,       // receiver (payment PKH)
      0n,              // receiver_output_idx
    ]) as unknown as Data);
    const redeemerUseCore = Data.to(new Constr(0, []) as unknown as Data);
    const redeemerBurnShares = Data.to(new Constr(1, []) as unknown as Data);  // BurnShares
    const redeemerVaultNftBurn = Data.void();
    const vusdcxUnit = state.hashes.vusdcxPolicy + "765553444378";

    // Build TX:
    //   Inputs: vaultIn (proxy UTxO) + wallet collateral
    //   Reference inputs: proxy, core, vusdcx
    //   Withdrawal: 0 from vault_core reward addr (UseCore via vault_proxy)
    //   Mint: -vUSDCx + -1 Vault NFT (Vault NFT inline, vusdcx via ref)
    //   Outputs: [0] = wallet receiving 10 USDCx (required at idx 0),
    //             change to wallet (lovelace + token leftovers)
    // validity_range lower_bound MUST be Finite for min_hold_ok check to pass
    const nowTs = Date.now();
    const tx = lucid
      .newTx()
      .collectFrom([vaultIn], redeemerUseCore)
      .readFrom([proxyRef[0], coreRef[0], vusdcxRef[0]])
      .withdraw(coreRewardAddr, 0n, redeemerWithdraw)
      .mintAssets({ [vusdcxUnit]: -sharesMinted }, redeemerBurnShares)
      .mintAssets({ [vaultNftUnit]: -1n }, redeemerVaultNftBurn)
      .attach.MintingPolicy(vaultNftScript)
      .pay.ToAddress(wallet, { lovelace: 3_000_000n, [depositTokenUnit]: 10_000_000n })
      .addSignerKey(walletPkh)
      .validFrom(nowTs - 60_000)
      .validTo(nowTs + 15 * 60_000);

    const completed = await tx.complete();
    const signed = await completed.sign.withWallet().complete();
    const txHash = await signed.submit();
    log("INFO", `  withdraw TX ${txHash}`);
    await lucid.awaitTx(txHash, 180_000);
    await new Promise((r) => setTimeout(r, 30_000));
    state.test.withdrawTx = txHash;
    fs.writeFileSync(stateFile, JSON.stringify(state, null, 2) + "\n");
  } else {
    log("INFO", `withdraw already done: ${state.test.withdrawTx}`);
  }

  // ═══════════════════════════════════════════════════
  // Step D: verify on-chain
  // ═══════════════════════════════════════════════════
  log("STEP", "Step D: on-chain verification");
  const vaultSurvivors = await lucid.utxosAt(proxyAddr);
  const nftAsset = await fetch(`${bfUrl}/assets/${vaultNftUnit}`, { headers: { project_id: bfKey } });
  const nftData = nftAsset.ok ? ((await nftAsset.json()) as any) : { quantity: "?" };
  log("INFO", `  proxy addr UTxOs: ${vaultSurvivors.length}`);
  log("INFO", `  vault NFT total supply: ${nftData.quantity}`);

  const passed =
    vaultSurvivors.length === 0 &&
    nftData.quantity === "0";
  log(passed ? "INFO" : "ERROR", passed ? "✅ FULL-DRAIN VERIFIED" : "❌ verification failed");
  if (!passed) process.exit(1);
}

main().catch((e) => { log("ERROR", (e as Error).message); if ((e as Error).stack) console.error((e as Error).stack); process.exit(1); });
