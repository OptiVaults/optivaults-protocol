/**
 * Reclaim V1 ref script UTXOs.
 *
 * Ref scripts are at the deploy wallet's own payment credential, so a
 * standard (non-Plutus) TX can collect them and send the ADA back to
 * the wallet. The Conway-era per-byte ref-script fee is larger than
 * Lucid Evolution's fee estimator can compute: Lucid's internal formula
 * produces fractional lovelace amounts that crash `BigInt(<float>)`
 * when the spent ref-script total crosses ~50 KB. V1 aggregate ref-script
 * bytes is ~176 KB across 18 scripts, which triggers this bug.
 *
 * Solution (same pattern documented in the V10-era admin reclaim tool):
 *   1. Strip `scriptRef` + `datum` from the in-memory UTXO copies before
 *      handing them to Lucid. Lucid now sees them as plain value carriers
 *      and does NOT engage the broken Conway ref-script fee calculator.
 *   2. Let Lucid build a skeleton TX with `collectFrom(cleanRefs)`.
 *   3. Re-open the TX body with CML. Replace the outputs with a single
 *      consolidated output to the destination wallet, and set the fee
 *      to a fixed safety value that exceeds what Conway requires on chain
 *      (the network still sees the original ref-script-bearing inputs
 *      because the TransactionInput refs resolve against on-chain state,
 *      not our in-memory strip — so we must pay the real Conway fee).
 *   4. Emit unsigned CBOR, sign via Lucid wallet (key daemon-backed),
 *      submit via Blockfrost.
 *
 * Fee sizing (2026-04-23 protocol params):
 *   V1 aggregate ref-script bytes = ~176 KB. Conway tiered per-byte cost
 *   with 15 lovelace/byte base × 1.2^tier multiplier per 25 KB tier
 *   gives ~4.9 ADA theoretical. We set 6 ADA as the fixed fee — ~20%
 *   buffer above the theoretical minimum to absorb protocol-param drift
 *   + covers the ~0.5 ADA base TX fee. If network rejects with
 *   FeeTooSmallUTxO, bump to 8 ADA and retry (edit FIXED_FEE_LOVELACE
 *   below).
 *
 * Topology-agnostic: iterates `Object.keys(state.refScripts)` dynamically,
 * so automatically handles any ref-script count without code changes.
 * Missing / already-spent ref UTxOs are skipped (partial reclaim is OK —
 * re-run to pick up any missed ones later).
 *
 * Usage:
 *   npx tsx deploy/tools/reclaim-refs.ts --network Preprod --releaseTag v1-preprod-p2
 *
 * Flags:
 *   --network      Preprod | Mainnet (default Preprod)
 *   --releaseTag   Ceremony tag (default v1-preprod-e2e)
 *   --dest <addr>  Destination wallet for reclaimed ADA (default: self-send)
 *   --dryRun       Build but do not submit (prints unsigned CBOR + sizes)
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
import { createBlockfrostProvider } from "../lib/blockfrostProvider.js";

type Net = "Preprod" | "Mainnet";

/** Fixed fee in lovelace. 6 ADA covers V1's 18-script / ~176 KB
 *  aggregate ref-script Conway per-byte cost plus base TX fee with
 *  ~20% buffer. Increase to 8 ADA if network rejects with
 *  FeeTooSmallUTxO. */
const FIXED_FEE_LOVELACE = 6_000_000n;

function parseArgs(): {
  network: Net;
  releaseTag: string;
  dryRun: boolean;
  dest?: string;
} {
  const a = process.argv.slice(2);
  let network: Net = "Preprod";
  let releaseTag = "v1-preprod-e2e";
  let dryRun = false;
  let dest: string | undefined;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--network") network = a[++i] as Net;
    else if (a[i] === "--releaseTag") releaseTag = a[++i];
    else if (a[i] === "--dryRun" || a[i] === "--dry-run") dryRun = true;
    else if (a[i] === "--dest") dest = a[++i];
  }
  return { network, releaseTag, dryRun, dest };
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

function resolveStatePath(network: Net, releaseTag: string): string {
  // Check multiple candidate roots; env override wins.
  if (process.env.V1_DEPLOY_STATE_PATH) return process.env.V1_DEPLOY_STATE_PATH;
  const lc = network.toLowerCase();
  const candidates = [
    `deploy/state/${lc}-${releaseTag}.json`,        // run from crypto-claude/
    `deploy/state/${lc}-${releaseTag}.json`,      // run from crypto-claude/
    `../deploy/state/${lc}-${releaseTag}.json`,      // run from deploy/
  ];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  throw new Error(
    `Ceremony state not found. Tried: ${candidates.join(", ")}. ` +
    `Set V1_DEPLOY_STATE_PATH env var to override.`,
  );
}

async function main() {
  const { network, releaseTag, dryRun, dest } = parseArgs();
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
  const destAddr = dest || addr;
  console.log(`wallet:      ${addr.slice(0, 30)}…${addr.slice(-8)}`);
  console.log(`destination: ${destAddr.slice(0, 30)}…${destAddr.slice(-8)}`);
  console.log(`network:     ${network}`);
  console.log(`releaseTag:  ${releaseTag}`);

  const statePath = resolveStatePath(network, releaseTag);
  console.log(`state file:  ${statePath}`);
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
  let totalSizeBytes = 0;
  for (const label of labels) {
    const r = refScripts[label];
    try {
      const [u] = await lucid.utxosByOutRef([
        { txHash: r.txHash, outputIndex: r.outputIndex },
      ]);
      if (!u) {
        console.log(`  ${label.padEnd(20)} (already spent / not found — skipping)`);
        continue;
      }
      refUtxos.push(u);
      totalLovelace += u.assets.lovelace!;
      totalSizeBytes += r.sizeBytes;
      console.log(`  ${label.padEnd(20)} ${(Number(u.assets.lovelace!) / 1e6).toFixed(6)} ADA  (${r.sizeBytes}B)`);
    } catch (e) {
      console.log(`  ${label.padEnd(20)} fetch failed: ${(e as Error).message?.slice(0, 80)}`);
    }
  }
  if (refUtxos.length === 0) {
    console.log("Nothing to reclaim");
    return;
  }
  console.log(
    `Total reclaimable: ${(Number(totalLovelace) / 1e6).toFixed(6)} ADA from ${refUtxos.length} ref scripts ` +
    `(${(totalSizeBytes / 1024).toFixed(1)} KB aggregate script payload)`,
  );

  // ── CML-only build (Lucid fee estimator skipped by stripping scriptRef) ──
  //
  // Stripping scriptRef + datum from the in-memory UTXO copies does NOT
  // alter on-chain state — the network still sees the original ref-script-
  // bearing inputs and will charge the full Conway per-byte fee. The strip
  // only prevents Lucid's internal fee estimator from running its broken
  // float-to-BigInt path.
  console.log("Building TX (Lucid first pass, scriptRef stripped to bypass broken fee estimator)...");
  const cleanRefs = refUtxos.map((u) => ({
    ...u,
    datum: undefined,
    datumHash: undefined,
    scriptRef: undefined,
  }));

  const txBuilder = lucid
    .newTx()
    .collectFrom(cleanRefs)
    .addSignerKey(pkh)
    .validFrom(Date.now() - 120_000)
    .validTo(Date.now() + 900_000);

  const built = await txBuilder.complete({
    localUPLCEval: false,
    changeAddress: destAddr,
  });
  const cbor0 = built.toCBOR();

  // ── CML post-process: single output + fixed fee ──
  console.log("Rebuilding TX body with fixed Conway fee...");
  const txObj0 = CML.Transaction.from_cbor_hex(cbor0);
  const body0 = txObj0.body();
  const existingFee = BigInt(body0.fee().toString());

  const newFee = FIXED_FEE_LOVELACE;
  const newOutputAmt = totalLovelace - newFee;
  if (newOutputAmt < 1_000_000n) {
    throw new Error(
      `Reclaimable ADA (${totalLovelace}) minus fee (${newFee}) leaves ${newOutputAmt} < 1 ADA min-UTXO`,
    );
  }
  console.log(`  existing fee (Lucid): ${existingFee} lovelace`);
  console.log(`  new fee (fixed):      ${newFee} lovelace (${(Number(newFee) / 1e6).toFixed(2)} ADA)`);
  console.log(`  output:               ${(Number(newOutputAmt) / 1e6).toFixed(6)} ADA → ${destAddr.slice(0, 30)}…`);

  // Single consolidated output to destination.
  const addrCml = CML.Address.from_bech32(destAddr);
  const newOut = CML.TransactionOutput.new(
    addrCml,
    CML.Value.new(newOutputAmt, CML.MultiAsset.new()),
  );
  const newOutList = CML.TransactionOutputList.new();
  newOutList.add(newOut);

  const bodyB = CML.TransactionBody.new(body0.inputs(), newOutList, newFee);
  const validFrom = body0.validity_interval_start();
  const validTo = body0.ttl();
  if (validFrom !== undefined) bodyB.set_validity_interval_start(validFrom);
  if (validTo !== undefined) bodyB.set_ttl(validTo);
  const reqSigners = CML.Ed25519KeyHashList.new();
  reqSigners.add(CML.Ed25519KeyHash.from_hex(pkh));
  bodyB.set_required_signers(reqSigners);

  const emptyWs = CML.TransactionWitnessSet.new();
  const finalTx = CML.Transaction.new(bodyB, emptyWs, true);
  const finalCbor = finalTx.to_cbor_hex();
  console.log(`unsigned TX: ${finalCbor.length / 2} bytes`);

  if (dryRun) {
    console.log(`[dryRun] not submitting. Net reclaim would be ~${(Number(newOutputAmt) / 1e6).toFixed(2)} ADA (after ${(Number(newFee) / 1e6).toFixed(2)} ADA fee)`);
    return;
  }

  // ── Sign + submit ──
  console.log("Signing with key-daemon-backed wallet...");
  const witnessSet = await lucid.wallet().signTx(
    CML.Transaction.from_cbor_hex(finalCbor),
  );
  const signed = CML.Transaction.new(bodyB, witnessSet, true);
  const signedCbor = signed.to_cbor_hex();
  const txHash = await submitViaBf(signedCbor, bfUrl, bfKey);
  console.log(`✅ Reclaim TX: ${txHash}`);
  console.log(
    `   ~${(Number(newOutputAmt) / 1e6).toFixed(2)} ADA to ${destAddr.slice(0, 30)}… (fee ${(Number(newFee) / 1e6).toFixed(2)} ADA)`,
  );
  const network_lc = network.toLowerCase();
  const scanUrl = network === "Mainnet"
    ? `https://cardanoscan.io/transaction/${txHash}`
    : `https://preprod.cardanoscan.io/transaction/${txHash}`;
  console.log(`   ${scanUrl}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
