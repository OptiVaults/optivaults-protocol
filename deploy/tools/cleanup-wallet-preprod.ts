/**
 * One-off wallet cleanup: produce N pure-ADA UTxOs by sending ADA to
 * self. Lucid handles input selection + token-bearing change.
 *
 * Usage:
 *   BLOCKFROST_API_KEY_PREPROD=... npx tsx deploy/tools/cleanup-wallet-preprod.ts
 */
import * as net from "node:net";
import { getKeyDaemonSocket } from "../lib/keyDaemon.js";
import { Lucid } from "@lucid-evolution/lucid";
import { createBlockfrostProvider } from "../lib/blockfrostProvider.js";

const PURE_ADA_OUTPUT = 100_000_000n;
const PURE_OUTPUTS_TO_CREATE = 4;

function getMnemonic(sock: string): Promise<string> {
  return new Promise((res, rej) => {
    const c = net.createConnection(sock, () => c.write("GET_MNEMONIC"));
    let buf = "";
    c.on("data", (d) => { buf += d.toString(); });
    c.on("end", () => res(buf.startsWith("OK:") ? buf.slice(3).trim() : buf.trim()));
    c.on("error", rej);
    setTimeout(() => rej(new Error("key daemon timeout")), 5000);
  });
}

async function main() {
  const BF_KEY = process.env.BLOCKFROST_API_KEY_PREPROD!;
  const BF_BACKUP = process.env.BLOCKFROST_API_KEY_PREPROD_BACKUP;
  const SOCK = getKeyDaemonSocket();
  const mn = await getMnemonic(SOCK);

  const provider = createBlockfrostProvider(
    "https://cardano-preprod.blockfrost.io/api/v0",
    BF_KEY,
    BF_BACKUP,
  );
  const lucid = await Lucid(provider as any, "Preprod");
  lucid.selectWallet.fromSeed(mn);
  const addr = await lucid.wallet().address();
  console.log("wallet addr:", addr);

  // CRITICAL: explicitly collectFrom only NON-ref-script UTxOs.
  // Lucid's auto coin selection (when `pay.ToAddress` is called without
  // `collectFrom`) ignores `scriptRef` and will happily consume
  // reference-script UTxOs as inputs, producing change outputs that
  // DROP the script ref — silently destroying deployed reference
  // scripts. The ceremony's earlier deploy iterations lost ~8 ref
  // scripts to this exact bug. Filter explicitly + collectFrom.
  const all = await lucid.wallet().getUtxos();
  const spendable = all
    .filter(u => !u.scriptRef)
    .filter(u => (u.assets.lovelace as bigint) >= 2_000_000n);
  console.log(`spendable (non-ref-script): ${spendable.length} of ${all.length} total`);

  // Build TX: just N × 100 ADA outputs to self.
  let tx = lucid.newTx().collectFrom(spendable);
  for (let i = 0; i < PURE_OUTPUTS_TO_CREATE; i++) {
    tx = tx.pay.ToAddress(addr, { lovelace: PURE_ADA_OUTPUT });
  }

  const completed = await tx.complete();
  const signed = await completed.sign.withWallet().complete();
  const txHash = await signed.submit();
  console.log("cleanup TX submitted:", txHash);

  console.log("Waiting for confirmation...");
  await lucid.awaitTx(txHash, 180_000);
  console.log("Confirmed. Sleeping 30s for Blockfrost indexer...");
  await new Promise(r => setTimeout(r, 30_000));

  const fresh = await lucid.wallet().getUtxos();
  const pureAda = fresh.filter(u =>
    !u.scriptRef &&
    Object.keys(u.assets).length === 1 &&
    (u.assets.lovelace as bigint) >= 99_000_000n,
  );
  console.log(`post-cleanup: ${fresh.length} total utxos, ${pureAda.length} pure-ADA ≥ 99 ADA`);
}

main().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
