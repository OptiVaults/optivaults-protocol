/**
 * Reclaim V1 ref script UTXOs.
 *
 * Ref scripts are at the deploy wallet's own payment credential, so a
 * standard (non-Plutus) TX can collect them and send the ADA back to
 * the wallet. The only catch is the Conway-era per-byte refScript fee
 * which Lucid Evolution's fee estimator under-reports for outputs that
 * SPEND ref-script-bearing inputs. We use the same CML-rebuild pattern
 * documented in `scripts/admin/reclaim-v10-refs.ts`:
 *   1. Build TX via Lucid
 *   2. Re-parse body with CML
 *   3. Bump fee to a safety-margined empirical value (2.5 ADA covers
 *      ~100 KB of spent ref scripts + Conway tier multiplier, enough
 *      for the full post-Phase-77d V1 topology at 18 ref scripts /
 *      ~110-120 KB aggregate script payload)
 *   4. Emit unsigned CBOR, sign via Lucid wallet, submit via Blockfrost.
 *
 * Topology-agnostic: iterates `Object.keys(state.refScripts)` dynamically,
 * so automatically handles 11 / 13 / 18 / future ref-script counts without
 * code changes. Missing or already-spent ref UTxOs are skipped (partial
 * reclaim is supported — re-run to pick up any missed ones later).
 *
 * Usage:
 *   npx tsx v1/deploy/tools/reclaim-refs.ts --network Preprod --releaseTag v1-preprod-e2e
 *
 * Flags:
 *   --dryRun   build but do not submit (prints TX hash of unsigned body)
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import * as fs from "fs";
import * as net from "node:net";
import {
  CML,
  Lucid,
  paymentCredentialOf,
} from "@lucid-evolution/lucid";
import type { LucidEvolution, UTxO } from "@lucid-evolution/lucid";
import { createBlockfrostProvider } from "../../../scripts/utils/blockfrostProvider.js";

type Net = "Preprod" | "Mainnet";

function parseArgs(): { network: Net; releaseTag: string; dryRun: boolean } {
  const a = process.argv.slice(2);
  let network: Net = "Preprod";
  let releaseTag = "v1-preprod-e2e";
  let dryRun = false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--network") network = a[++i] as Net;
    else if (a[i] === "--releaseTag") releaseTag = a[++i];
    else if (a[i] === "--dryRun" || a[i] === "--dry-run") dryRun = true;
  }
  return { network, releaseTag, dryRun };
}

async function getMnemonic(sockPath: string): Promise<string> {
  if (process.env.KEEPER_MNEMONIC) return process.env.KEEPER_MNEMONIC!;
  return new Promise((res, rej) => {
    const c = net.createConnection(sockPath, () => c.write("GET_MNEMONIC"));
    let buf = "";
    c.on("data", (d) => { buf += d.toString(); });
    c.on("end", () => res(buf.startsWith("OK:") ? buf.slice(3).trim() : buf.trim()));
    c.on("error", rej);
    setTimeout(() => rej(new Error("timeout")), 5000);
  });
}

async function submitViaBf(
  signedCbor: string,
  bfUrl: string,
  bfKey: string,
): Promise<string> {
  const res = await fetch(`${bfUrl}/tx/submit`, {
    method: "POST",
    headers: { "Content-Type": "application/cbor", project_id: bfKey },
    body: Buffer.from(signedCbor, "hex"),
    signal: AbortSignal.timeout(30000),
  });
  const body = await res.text();
  if (res.ok) return body.replace(/"/g, "").trim();
  throw new Error(`submit failed: ${body}`);
}

async function main() {
  const { network, releaseTag, dryRun } = parseArgs();
  const bfUrl = network === "Preprod"
    ? "https://cardano-preprod.blockfrost.io/api/v0"
    : "https://cardano-mainnet.blockfrost.io/api/v0";
  const bfKey = network === "Preprod"
    ? process.env.BLOCKFROST_API_KEY_PREPROD!
    : process.env.BLOCKFROST_API_KEY!;
  if (!bfKey) throw new Error("Missing Blockfrost key");

  const sock = process.env.KEY_DAEMON_SOCKET || "/home/chrissoft/claude-code-docker/data/key-daemon-preprod.sock";

  const provider = createBlockfrostProvider(bfUrl, bfKey);
  const lucid = await Lucid(provider as any, network);
  const mnemonic = await getMnemonic(sock);
  lucid.selectWallet.fromSeed(mnemonic);
  const addr = await lucid.wallet().address();
  const pkh = paymentCredentialOf(addr).hash;
  console.log(`wallet: ${addr.slice(0, 30)}…${addr.slice(-8)}`);

  // Load ceremony state
  const statePath = `v1/deploy/state/${network.toLowerCase()}-${releaseTag}.json`;
  const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
  const refScripts = state.refScripts as Record<
    string,
    { txHash: string; outputIndex: number; scriptHash: string; sizeBytes: number; minAda: string }
  >;
  const labels = Object.keys(refScripts);
  console.log(`Found ${labels.length} ref scripts in state`);

  // Fetch each ref-script UTxO fresh from Blockfrost to verify it still
  // exists + to get current lovelace (Blockfrost sometimes reports a
  // slightly different minAda than what we saved at deploy time).
  const refUtxos: UTxO[] = [];
  let totalLovelace = 0n;
  for (const label of labels) {
    const r = refScripts[label];
    try {
      const [u] = await lucid.utxosByOutRef([
        { txHash: r.txHash, outputIndex: r.outputIndex },
      ]);
      if (!u) {
        console.log(`  ${label}: already spent / not found — skipping`);
        continue;
      }
      refUtxos.push(u);
      totalLovelace += u.assets.lovelace!;
      console.log(`  ${label.padEnd(20)} ${Number(u.assets.lovelace!) / 1e6} ADA  (${r.sizeBytes}B)`);
    } catch (e) {
      console.log(`  ${label}: fetch failed: ${(e as Error).message?.slice(0, 80)}`);
    }
  }
  if (refUtxos.length === 0) {
    console.log("Nothing to reclaim");
    return;
  }
  console.log(`Total reclaimable: ${Number(totalLovelace) / 1e6} ADA from ${refUtxos.length} ref scripts`);

  // Lucid will fetch wallet UTxOs automatically for fees + change; no need to list them.
  // We pass the ref script UTxOs via .collectFrom.
  const txBuilder = lucid.newTx().collectFrom(refUtxos);
  const tx = await txBuilder.complete();
  const txCbor = tx.toCBOR();

  // CML post-process: ensure fee is at least our safety floor. Lucid
  // Evolution v0.4.x sometimes under-estimates Conway per-byte ref-script
  // fees when an input carries a scriptRef (V10 reclaim history). If
  // Lucid's estimate is already higher than our floor, use that;
  // otherwise bump up.
  const tBody = CML.Transaction.from_cbor_hex(txCbor).body();
  const currentFee = tBody.fee();
  const safetyFloor = 2_500_000n; // 2.5 ADA — covers ~100KB ref-script + tier multiplier + safety margin
  const newFee = currentFee >= safetyFloor ? currentFee : safetyFloor;
  const feeBump = newFee - currentFee;
  console.log(`fee: ${currentFee} → ${newFee} (delta ${feeBump})`);

  if (feeBump === 0n) {
    // Lucid's estimate already meets our floor; submit as-is.
    console.log(`Lucid's fee estimate meets safety floor — no CML rewrite needed`);
    if (dryRun) { console.log(`[dryRun] would submit via Lucid`); return; }
    const signed = await tx.sign.withWallet().complete();
    const txHash = await signed.submit();
    console.log(`✅ Reclaim TX: ${txHash}`);
    console.log(`   ~${Number(totalLovelace) / 1e6} ADA back to wallet (minus ~${Number(newFee) / 1e6} ADA fee)`);
    return;
  }

  // Bump path: shave feeBump lovelace off the change output + rebuild body
  const outputs = tBody.outputs();
  let changeIdx = -1;
  for (let i = 0; i < outputs.len(); i++) {
    const o = outputs.get(i);
    if (o.address().to_bech32(undefined) === addr) { changeIdx = i; break; }
  }
  if (changeIdx < 0) throw new Error("No change output found");
  const changeOut = outputs.get(changeIdx);
  const origAmount = changeOut.amount().coin();
  const newAmount = origAmount - feeBump;
  if (newAmount < 1_000_000n) throw new Error(`change too small after fee bump: ${newAmount}`);

  const newOutputs = CML.TransactionOutputList.new();
  for (let i = 0; i < outputs.len(); i++) {
    if (i === changeIdx) {
      const val = CML.Value.new(newAmount, changeOut.amount().multi_asset());
      newOutputs.add(CML.TransactionOutput.new(changeOut.address(), val));
    } else {
      newOutputs.add(outputs.get(i));
    }
  }
  const newBody = CML.TransactionBody.new(tBody.inputs(), newOutputs, newFee);
  if (tBody.ttl()) newBody.set_ttl(tBody.ttl()!);
  if (tBody.validity_interval_start()) newBody.set_validity_interval_start(tBody.validity_interval_start()!);
  const reqSigners = CML.Ed25519KeyHashList.new();
  reqSigners.add(CML.Ed25519KeyHash.from_hex(pkh));
  newBody.set_required_signers(reqSigners);

  const ws = CML.TransactionWitnessSet.new();
  const newUnsigned = CML.Transaction.new(newBody, ws, true);
  const newUnsignedCbor = newUnsigned.to_cbor_hex();
  console.log(`unsigned size: ${newUnsignedCbor.length / 2} B`);

  if (dryRun) { console.log(`[dryRun] would submit ${newUnsignedCbor.length / 2} B TX`); return; }

  const witnessSet = await lucid.wallet().signTx(CML.Transaction.from_cbor_hex(newUnsignedCbor));
  const signed = CML.Transaction.new(newBody, witnessSet, true);
  const signedCbor = signed.to_cbor_hex();
  const txHash = await submitViaBf(signedCbor, bfUrl, bfKey);
  console.log(`✅ Reclaim TX: ${txHash}`);
  console.log(`   ~${Number(totalLovelace) / 1e6} ADA back to wallet (minus ~${Number(newFee) / 1e6} ADA fee)`);
}

main().catch((e) => { console.error(e); process.exit(1); });
