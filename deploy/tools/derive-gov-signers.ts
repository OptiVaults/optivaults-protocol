/**
 * Derive 3 distinct gov signer PKHs from the same BIP39 seed.
 *
 * V1 governance requires `gov_min_signers = 3` + `unique_n == n`. For
 * Preprod A2 verification we want the operator to control all 3 keys
 * (single mnemonic, different BIP32 account indices), so the full
 * Queue + Execute flow can be tested without coordinating with other
 * key holders. Threshold stays validator-constrained at >= 2.
 *
 * Output: prints 3 PKHs (accountIndex 0/1/2, addressType "Base",
 * standard CIP-1852 derivation path `m/1852'/1815'/i'/0/0`). Copy into
 * `v1/deploy/config/preprod.json` governance.signers.
 *
 * Usage:
 *   npx tsx v1/deploy/tools/derive-gov-signers.ts
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import * as net from "node:net";
import { CML } from "@lucid-evolution/lucid";

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

async function main() {
  const sock = process.env.KEY_DAEMON_SOCKET || "/home/chrissoft/claude-code-docker/data/key-daemon-preprod.sock";
  const mnemonic = await getMnemonic(sock);
  const { mnemonicToEntropy } = await import("bip39");
  const entropy = mnemonicToEntropy(mnemonic);
  const entropyBytes = new Uint8Array(entropy.match(/.{2}/g)!.map((b: string) => parseInt(b, 16)));
  const rootKey = CML.Bip32PrivateKey.from_bip39_entropy(entropyBytes, new Uint8Array());

  const pkhs: string[] = [];
  for (let account = 0; account < 3; account++) {
    const paymentKey = rootKey
      .derive(0x80000000 + 1852)
      .derive(0x80000000 + 1815)
      .derive(0x80000000 + account)
      .derive(0)
      .derive(0);
    const pubKey = paymentKey.to_raw_key().to_public();
    const pkh = pubKey.hash().to_hex();
    pkhs.push(pkh);
    console.log(`account ${account}: ${pkh}`);
  }

  console.log("\n--- preprod.json governance.signers array ---");
  console.log(JSON.stringify(pkhs, null, 2));
  console.log("\nThreshold to configure: 2 (minimum per gov_min_threshold)");
}

main().catch((e) => { console.error(e); process.exit(1); });
