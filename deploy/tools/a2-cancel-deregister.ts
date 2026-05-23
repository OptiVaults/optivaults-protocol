/**
 * A2 — Cancel a queued ActDeregisterStake before Execute.
 *
 * Counterpart to `a2-queue-deregister.ts` / `a2-execute-deregister.ts`.
 * Reads the queued action info from `state.a2.<target>`, submits a
 * CancelAction TX with 1-of-n sigs (much lighter than Execute's
 * threshold requirement). Removes the action from `GovDatum.queued`.
 *
 * Usage:
 *   TARGET=vaultUser npx tsx deploy/tools/a2-cancel-deregister.ts \
 *     --network Preprod --releaseTag v1-preprod-p2
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import * as fs from "fs";
import * as net from "node:net";
import {
  CML,
  Constr,
  Data,
  Lucid,
} from "@lucid-evolution/lucid";
import type { LucidEvolution, UTxO } from "@lucid-evolution/lucid";
import { createBlockfrostProvider } from "../lib/blockfrostProvider.js";
import { getKeyDaemonSocket } from "../lib/keyDaemon.js";

type Net = "Preprod" | "Mainnet";
type Target =
  | "vaultUser"
  | "vaultKeeperHot"
  | "vaultBatcher"
  | "vaultSwapAda"
  | "vaultProtocol"
  | "vaultRecall"
  | "vaultLiqwid"
  | "vaultGovPolicy"
  | "vaultGovEmergency"
  | "vaultAdminDeploy"
  | "keeperStakeScript"
  | "minswapV2Adapter";

const VALID_TARGETS: Target[] = [
  "vaultUser", "vaultKeeperHot", "vaultBatcher", "vaultSwapAda",
  "vaultProtocol", "vaultRecall", "vaultLiqwid", "vaultGovPolicy",
  "vaultGovEmergency", "vaultAdminDeploy", "keeperStakeScript",
  "minswapV2Adapter",
];
const ACCOUNTS_TO_SIGN = [0]; // 1-of-n sufficient for CancelAction

interface CliArgs {
  network: Net;
  releaseTag: string;
  target: Target;
}

function parseArgs(): CliArgs {
  const a = process.argv.slice(2);
  let network: Net = "Preprod";
  let releaseTag = "v1-preprod-p2";
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--network") network = a[++i] as Net;
    else if (a[i] === "--releaseTag") releaseTag = a[++i];
  }
  const target = process.env.TARGET as Target | undefined;
  if (!target || !VALID_TARGETS.includes(target)) {
    throw new Error(`TARGET env var must be one of: ${VALID_TARGETS.join(", ")}`);
  }
  return { network, releaseTag, target };
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

async function main() {
  const args = parseArgs();
  const bfUrl = args.network === "Preprod"
    ? "https://cardano-preprod.blockfrost.io/api/v0"
    : "https://cardano-mainnet.blockfrost.io/api/v0";
  const bfKey = args.network === "Preprod"
    ? process.env.BLOCKFROST_API_KEY_PREPROD!
    : process.env.BLOCKFROST_API_KEY!;
  if (!bfKey) throw new Error("Missing Blockfrost key");

  const stateFile = `deploy/state/${args.network.toLowerCase()}-${args.releaseTag}.json`;
  if (!fs.existsSync(stateFile)) throw new Error(`state not found: ${stateFile}`);
  const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));

  if (!state.a2?.[args.target]?.actionId) {
    throw new Error(`no queued action for target ${args.target} — run a2-queue-deregister.ts first`);
  }
  const actionId: string = state.a2[args.target].actionId;
  console.log(`target:     ${args.target}`);
  console.log(`action_id:  ${actionId}`);

  const provider = createBlockfrostProvider(bfUrl, bfKey);
  const lucid = await Lucid(provider as any, args.network);
  const sock = getKeyDaemonSocket();
  const mnemonic = await getMnemonic(sock);
  lucid.selectWallet.fromSeed(mnemonic);
  const wallet = await lucid.wallet().address();
  console.log(`wallet:     ${wallet.slice(0, 30)}…`);

  const govAddr = state.stateUtxos.governance.address;
  const govUtxos = await lucid.utxosAt(govAddr);
  if (govUtxos.length !== 1) throw new Error(`expected 1 gov UTxO, got ${govUtxos.length}`);
  const govIn = govUtxos[0];
  console.log(`gov UTxO:   ${govIn.txHash}#${govIn.outputIndex}`);

  if (!govIn.datum) throw new Error("gov UTxO has no inline datum");
  const govDatum = Data.from(govIn.datum) as any;
  const fields = govDatum.fields as any[];
  const signers = fields[0] as string[];
  const signerJoinedAt = fields[1] as bigint[];
  const signerLastQualified = fields[2] as bigint[];
  const threshold = fields[3] as bigint;
  const queued = fields[4] as any[];
  const compensationPool = fields[5] as bigint;
  const lastDistributeMs = fields[6] as bigint;
  const distributePeriodMs = fields[7] as bigint;
  const nonce = fields[8] as bigint;
  console.log(`gov nonce:  ${nonce}, queued.length: ${queued.length}`);

  const actionIdLower = actionId.toLowerCase();
  const newQueued = queued.filter((q: any) => (q.fields[0] as string).toLowerCase() !== actionIdLower);
  if (newQueued.length === queued.length) {
    // Idempotency check: action not in queue. If state has
    // cancelledAtMs set from a prior run → skip silently. Otherwise action
    // was executed or expired; bail with clear error.
    const prior = state.a2?.[args.target]?.cancelledAtMs;
    if (prior) {
      console.log(`\nℹ️  action ${actionIdLower} already cancelled at ${new Date(prior).toISOString()} — exit idempotent.`);
      return;
    }
    throw new Error(`action_id ${actionIdLower} not in queue and no cancelledAtMs in state — already executed/expired. Nothing to cancel.`);
  }

  // CancelAction redeemer: Constr(1, [action_id])
  const redeemerCancel = Data.to(new Constr(1, [actionIdLower]) as unknown as Data);

  // Validity range — CancelAction has no timelock constraint (just 1h
  // width cap for the refresh_qualification upper). 30min window.
  const slotAlign = (ms: bigint) => (ms / 1000n) * 1000n;
  const lowerMs = slotAlign(BigInt(Date.now()));
  const upperMs = slotAlign(lowerMs + BigInt(30 * 60_000));

  // refresh_qualification: signer_last_qualified_ms[i] = upperMs for
  // signer i in extra_signatories, else unchanged.
  const signerAccountIdx = await deriveSignerAccountIndices(mnemonic, signers);
  const newSignerLastQualified = signers.map((s, i) =>
    ACCOUNTS_TO_SIGN.includes(signerAccountIdx[i]) ? upperMs : signerLastQualified[i],
  );

  // GovDatum Constr(0, [...])
  const newGovDatum = Data.to(new Constr(0, [
    signers,
    signerJoinedAt,
    newSignerLastQualified,
    threshold,
    newQueued,
    compensationPool,
    lastDistributeMs,
    distributePeriodMs,
    nonce + 1n,
  ]) as unknown as Data);

  const mgRef = state.refScripts.multisigGov;
  if (!mgRef) throw new Error("multisigGov ref script not in state");
  const [mgRefUtxo] = await lucid.utxosByOutRef([{ txHash: mgRef.txHash, outputIndex: mgRef.outputIndex }]);
  if (!mgRefUtxo) throw new Error("multisigGov ref UTxO not found on-chain");

  // Build — only signer 0 for 1-of-n.
  const tx = lucid
    .newTx()
    .collectFrom([govIn], redeemerCancel)
    .readFrom([mgRefUtxo])
    .pay.ToAddressWithData(
      govAddr,
      { kind: "inline", value: newGovDatum as unknown as string },
      govIn.assets,
    )
    .validFrom(Number(lowerMs))
    .validTo(Number(upperMs))
    .addSignerKey(signers[0]);

  const completed = await tx.complete();
  const unsignedCbor = completed.toCBOR();
  const signedCbor = await multiSignCbor(unsignedCbor, mnemonic, ACCOUNTS_TO_SIGN);

  const res = await fetch(`${bfUrl}/tx/submit`, {
    method: "POST",
    headers: { "Content-Type": "application/cbor", project_id: bfKey },
    body: Buffer.from(signedCbor, "hex"),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`submit failed: ${body}`);
  const txHash = body.replace(/"/g, "").trim();
  console.log(`✅ Cancel TX submitted: ${txHash}`);

  state.a2[args.target].cancelTx = txHash;
  state.a2[args.target].cancelledAtMs = Date.now();
  fs.writeFileSync(stateFile, JSON.stringify(state, null, 2) + "\n");
}

async function deriveSignerAccountIndices(mnemonic: string, signers: string[]): Promise<number[]> {
  const { mnemonicToEntropy } = await import("bip39");
  const entropy = mnemonicToEntropy(mnemonic);
  const entropyBytes = new Uint8Array(entropy.match(/.{2}/g)!.map((b) => parseInt(b, 16)));
  const rootKey = CML.Bip32PrivateKey.from_bip39_entropy(entropyBytes, new Uint8Array());
  const indices: number[] = [];
  for (const s of signers) {
    let found = -1;
    for (let a = 0; a < 10; a++) {
      const k = rootKey.derive(0x80000000 + 1852).derive(0x80000000 + 1815).derive(0x80000000 + a).derive(0).derive(0);
      if (k.to_raw_key().to_public().hash().to_hex() === s) { found = a; break; }
    }
    indices.push(found);
  }
  return indices;
}

async function multiSignCbor(unsignedCbor: string, mnemonic: string, accountIndices: number[]): Promise<string> {
  const { mnemonicToEntropy } = await import("bip39");
  const entropy = mnemonicToEntropy(mnemonic);
  const entropyBytes = new Uint8Array(entropy.match(/.{2}/g)!.map((b) => parseInt(b, 16)));
  const rootKey = CML.Bip32PrivateKey.from_bip39_entropy(entropyBytes, new Uint8Array());

  const tx = CML.Transaction.from_cbor_hex(unsignedCbor);
  const body = tx.body();
  const bodyHash = CML.hash_transaction(body);
  const witnessSet = CML.TransactionWitnessSet.from_cbor_hex(tx.witness_set().to_cbor_hex());
  const vkeys = witnessSet.vkeywitnesses() ?? CML.VkeywitnessList.new();

  for (const account of accountIndices) {
    const k = rootKey.derive(0x80000000 + 1852).derive(0x80000000 + 1815).derive(0x80000000 + account).derive(0).derive(0);
    const priv = k.to_raw_key();
    const sig = priv.sign(bodyHash.to_raw_bytes());
    vkeys.add(CML.Vkeywitness.new(priv.to_public(), sig));
  }
  witnessSet.set_vkeywitnesses(vkeys);
  const signed = CML.Transaction.new(body, witnessSet, true);
  return signed.to_cbor_hex();
}

main().catch((e) => {
  console.error("[ERROR]", (e as Error).message);
  if ((e as Error).stack) console.error((e as Error).stack);
  process.exit(1);
});
