/**
 * One-off helper: connect to the Preprod key daemon, derive the deploy
 * wallet address + payment PKH, and print current balance. Used once
 * during V1 config wiring to fill in registryInitialParams.keeperPkh
 * + keeperAuthInitialParams.authorizedPkhs in deploy/config/preprod.json.
 *
 * Usage:
 *   npx tsx deploy/tools/whoami-preprod.ts
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import * as net from "node:net";
import { Lucid, paymentCredentialOf } from "@lucid-evolution/lucid";
import { createBlockfrostProvider } from "../lib/blockfrostProvider.js";
import { getKeyDaemonSocket } from "../lib/keyDaemon.js";

const SOCK = getKeyDaemonSocket();
const BF_KEY = process.env.BLOCKFROST_API_KEY_PREPROD;

async function getMnemonic(sock: string): Promise<string> {
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
  if (!BF_KEY) throw new Error("BLOCKFROST_API_KEY_PREPROD not set (check keeper/.env)");
  const mnemonic = await getMnemonic(SOCK);
  const wc = mnemonic.trim().split(/\s+/).length;
  console.log("mnemonic words:", wc);

  const provider = createBlockfrostProvider(
    "https://cardano-preprod.blockfrost.io/api/v0",
    BF_KEY as string,
    process.env.BLOCKFROST_API_KEY_PREPROD_BACKUP,
  );
  const lucid = await Lucid(provider as any, "Preprod");
  lucid.selectWallet.fromSeed(mnemonic);
  const addr = await lucid.wallet().address();
  const cred = paymentCredentialOf(addr);
  console.log("addr:", addr);
  console.log("paymentCredHash (28-byte PKH):", cred.hash);

  const utxos = await lucid.wallet().getUtxos();
  const totalAda = utxos.reduce((a, u) => a + (u.assets.lovelace ?? 0n), 0n);
  console.log(`utxos: ${utxos.length}  approxADA: ${(Number(totalAda) / 1e6).toFixed(2)}`);

  const pureAda = utxos.filter(
    (u) => Object.keys(u.assets).length === 1 && (u.assets.lovelace ?? 0n) >= 5_000_000n,
  );
  console.log(`pure-ADA UTxOs >= 5 ADA: ${pureAda.length} (need 3 for NFT one-shot mints)`);

  const nonAda = new Map<string, bigint>();
  for (const u of utxos) {
    for (const [k, v] of Object.entries(u.assets)) {
      if (k === "lovelace") continue;
      nonAda.set(k, (nonAda.get(k) ?? 0n) + (v as bigint));
    }
  }
  console.log("non-ADA assets:");
  for (const [unit, qty] of nonAda.entries()) {
    const policy = unit.slice(0, 56);
    const name = unit.slice(56);
    console.log(`   policy=${policy}  name=${name}  qty=${qty}`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
