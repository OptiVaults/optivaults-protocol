/**
 * A2 — Queue ActDeregisterStake for a V1 staking validator.
 *
 * Builds + submits a QueueAction(ActDeregisterStake) TX against the
 * MultisigGov UTxO created by the V1 deploy ceremony. Signs with 2 of
 * 3 governance keys derived from the operator's single Preprod mnemonic
 * (CIP-1852 accountIndex 0/1).
 *
 * After this runs, wait `timelock_deregister_stake_ms` (1h in Preprod
 * override; 14d in production), then call `a2-execute-deregister.ts`.
 *
 * Usage:
 *   TARGET=vaultAdmin npx tsx v1/deploy/tools/a2-queue-deregister.ts \
 *     --network Preprod --releaseTag v1-a2-preprod
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
  applyParamsToScript,
  paymentCredentialOf,
  validatorToAddress,
} from "@lucid-evolution/lucid";
import type { LucidEvolution, Script, UTxO } from "@lucid-evolution/lucid";
import { blake2b } from "@noble/hashes/blake2b";
import { createBlockfrostProvider } from "../../../scripts/utils/blockfrostProvider.js";

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
  "minswapV2Adapter",
];

/** Aiken ActionKind Constr indices (declaration order in types.ak) */
const ACTION_KIND_DEREGISTER = 13;

const ACCOUNTS_TO_SIGN = [0, 1]; // 2 of 3 for threshold=2

interface CliArgs {
  network: Net;
  releaseTag: string;
  target: Target;
}

function parseArgs(): CliArgs {
  const a = process.argv.slice(2);
  let network: Net = "Preprod";
  let releaseTag = "v1-a2-preprod";
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

function blake2b256Hex(bytes: Buffer): string {
  return Buffer.from(blake2b(bytes, { dkLen: 32 })).toString("hex");
}

/**
 * Serialise a non-negative bigint to CBOR (matches Aiken's `cbor.serialise(Int)`).
 * Major type 0 (unsigned integer). For negative ints would use major type 1.
 */
function cborSerialiseInt(n: bigint): Buffer {
  if (n < 0n) {
    // Major type 1 for negative integers — not currently needed for our
    // timestamps + nonce but implemented defensively.
    const abs = -1n - n;
    if (abs < 24n) return Buffer.from([0x20 | Number(abs)]);
    if (abs < 256n) return Buffer.from([0x38, Number(abs)]);
    if (abs < 65536n) { const b = Buffer.alloc(3); b[0] = 0x39; b.writeUInt16BE(Number(abs), 1); return b; }
    if (abs < 4294967296n) { const b = Buffer.alloc(5); b[0] = 0x3a; b.writeUInt32BE(Number(abs), 1); return b; }
    const b = Buffer.alloc(9); b[0] = 0x3b; b.writeBigUInt64BE(abs, 1); return b;
  }
  if (n < 24n) return Buffer.from([Number(n)]);
  if (n < 256n) return Buffer.from([0x18, Number(n)]);
  if (n < 65536n) { const b = Buffer.alloc(3); b[0] = 0x19; b.writeUInt16BE(Number(n), 1); return b; }
  if (n < 4294967296n) { const b = Buffer.alloc(5); b[0] = 0x1a; b.writeUInt32BE(Number(n), 1); return b; }
  const b = Buffer.alloc(9); b[0] = 0x1b; b.writeBigUInt64BE(n, 1); return b;
}

/**
 * payload_hash_deregister_stake = blake2b_256(cbor.serialise(target_hash)).
 * 28-byte ByteArray encodes as CBOR `0x58 0x1c <28 bytes>`.
 */
function payloadHashDeregisterStake(targetHashHex: string): string {
  const raw = Buffer.from(targetHashHex, "hex");
  if (raw.length !== 28) throw new Error(`target hash must be 28 bytes, got ${raw.length}`);
  return blake2b256Hex(Buffer.concat([Buffer.from([0x58, 0x1c]), raw]));
}

function targetStakeHash(target: Target, hashes: any): string {
  switch (target) {
    case "vaultUser": return hashes.userStakeHash;
    case "vaultKeeperHot": return hashes.keeperHotStakeHash;
    case "vaultBatcher": return hashes.batcherStakeHash;
    case "vaultSwapAda": return hashes.swapAdaStakeHash;
    case "vaultProtocol": return hashes.protocolStakeHash;
    case "vaultRecall": return hashes.recallStakeHash;
    case "vaultLiqwid": return hashes.liqwidStakeHash;
    case "vaultGovPolicy": return hashes.govPolicyStakeHash;
    case "vaultGovEmergency": return hashes.govEmergencyStakeHash;
    case "vaultAdminDeploy": return hashes.adminDeployStakeHash;
    case "keeperStakeScript": return hashes.keeperStakeHash;
    case "minswapV2Adapter": return hashes.minswapV2AdapterHash;
  }
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

  const stateFile = `v1/deploy/state/${args.network.toLowerCase()}-${args.releaseTag}.json`;
  if (!fs.existsSync(stateFile)) throw new Error(`state not found: ${stateFile}`);
  const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  if (!state.stateUtxos?.governance) throw new Error("gov state UTxO not in state — ceremony PHASE 4b incomplete");

  const provider = createBlockfrostProvider(bfUrl, bfKey);
  const lucid = await Lucid(provider as any, args.network);
  const sock = process.env.KEY_DAEMON_SOCKET || "/home/chrissoft/claude-code-docker/data/key-daemon-preprod.sock";
  const mnemonic = await getMnemonic(sock);
  lucid.selectWallet.fromSeed(mnemonic);
  const wallet = await lucid.wallet().address();
  console.log(`wallet (payment): ${wallet.slice(0, 30)}…`);

  // Resolve target
  const tgtHash = targetStakeHash(args.target, state.hashes);
  const payloadHashHex = payloadHashDeregisterStake(tgtHash);
  console.log(`target (${args.target}):  ${tgtHash}`);
  console.log(`payload_hash:              ${payloadHashHex}`);

  // QueueAction redeemer: Constr(0, [action_kind, target_script, target_tx_hash, payload_hash, timelock_ms, ttl_ms])
  const timelockMs = 60 * 60 * 1_000;         // 1h (Preprod override matches constants)
  const ttlMs = 86_400_000;                    // 1d (spec minimum)
  const redeemerQueue = Data.to(new Constr(0, [
    new Constr(ACTION_KIND_DEREGISTER, []),    // action_kind = ActDeregisterStake
    tgtHash,                                    // target_script
    "",                                         // target_tx_hash (empty)
    payloadHashHex,                             // payload_hash
    BigInt(timelockMs),
    BigInt(ttlMs),
  ]) as unknown as Data);

  // Load gov UTxO
  const govAddr = state.stateUtxos.governance.address;
  const govUtxos = await lucid.utxosAt(govAddr);
  if (govUtxos.length !== 1) throw new Error(`expected 1 gov UTxO at ${govAddr}, got ${govUtxos.length}`);
  const govIn = govUtxos[0];
  console.log(`gov UTxO: ${govIn.txHash}#${govIn.outputIndex}`);
  console.log(`  value:  ${JSON.stringify(govIn.assets, (_k, v) => typeof v === "bigint" ? v.toString() : v)}`);

  // Decode current GovDatum to derive updated datum
  if (!govIn.datum) throw new Error("gov UTxO has no inline datum");
  const govDatum = Data.from(govIn.datum);
  const govDatumFields = (govDatum as any).fields as any[];
  const signers = govDatumFields[0] as string[];
  const signerJoinedAt = govDatumFields[1] as bigint[];
  const signerLastQualified = govDatumFields[2] as bigint[];
  const threshold = govDatumFields[3] as bigint;
  const queued = govDatumFields[4] as any[];
  const compensationPool = govDatumFields[5] as bigint;
  const lastDistributeMs = govDatumFields[6] as bigint;
  const distributePeriodMs = govDatumFields[7] as bigint;
  const nonce = govDatumFields[8] as bigint;
  console.log(`gov signers: ${signers.length}, threshold: ${threshold}, nonce: ${nonce}, queued: ${queued.length}`);

  // Compute action_id = blake2b_256(kind_byte || target || payload_hash ||
  //                                  cbor(queued_at_ms) || cbor(nonce))
  // queued_at_ms must equal the TX validity upper bound as seen by the
  // validator (Aiken: `expect Finite(upper) = tx.validity_range.upper_bound`).
  // Preprod slot length = 1000 ms; align to a whole-second boundary so Lucid's
  // ms→slot→ms conversion is lossless.
  const nowMs = Date.now();
  const rawUpperMs = nowMs + 10 * 60_000;
  const upperMs = BigInt(Math.floor(rawUpperMs / 1000) * 1000);
  const kindByte = Buffer.from("0e", "hex"); // ActDeregisterStake = 0x0e
  const actionIdBytes = Buffer.concat([
    kindByte,
    Buffer.from(tgtHash, "hex"),
    Buffer.from(payloadHashHex, "hex"),
    cborSerialiseInt(upperMs),
    cborSerialiseInt(nonce),
  ]);
  const actionId = blake2b256Hex(actionIdBytes);
  console.log(`computed action_id: ${actionId}`);

  // Compute refresh_qualification output — signer_last_qualified_ms[i] becomes
  // upperMs if signer i is in tx.extra_signatories (our 2 signer wallets), else unchanged.
  // For our 2-of-3 setup signing with accounts 0 + 1: signers[0] and signers[1] are in extra_signatories.
  // signers[2] is not.
  const signerAccountIdx = await deriveSignerAccountIndices(mnemonic, signers);
  const newSignerLastQualified = signers.map((s, i) => {
    if (ACCOUNTS_TO_SIGN.includes(signerAccountIdx[i])) return upperMs;
    return signerLastQualified[i];
  });

  // QueuedAction = Constr(0, [action_id, action_kind, target_script, target_tx_hash, payload_hash, queued_at_ms, executable_at_ms, expires_at_ms])
  const newQueuedAction = new Constr(0, [
    actionId,
    new Constr(ACTION_KIND_DEREGISTER, []),
    tgtHash,
    "",
    payloadHashHex,
    upperMs,
    upperMs + BigInt(timelockMs),
    upperMs + BigInt(timelockMs) + BigInt(ttlMs),
  ]);

  // New GovDatum — list.push in Aiken *prepends* (not appends), so the
  // new QueuedAction goes at the FRONT of the existing queue.
  const newGovDatum = Data.to(new Constr(0, [
    signers,
    signerJoinedAt,
    newSignerLastQualified,
    threshold,
    [newQueuedAction, ...queued],
    compensationPool,
    lastDistributeMs,
    distributePeriodMs,
    nonce + 1n,
  ]) as unknown as Data);

  // DEBUG: compare full bytes of original datum and our new datum
  console.log(`\n--- old datum ---\n${govIn.datum}`);
  console.log(`\n--- new datum ---\n${newGovDatum}`);

  // Ref input: multisig_gov ref script
  const mgRefState = state.refScripts.multisigGov;
  if (!mgRefState) throw new Error("multisig_gov ref script not in state");
  const [mgRefUtxo] = await lucid.utxosByOutRef([{ txHash: mgRefState.txHash, outputIndex: mgRefState.outputIndex }]);
  if (!mgRefUtxo) throw new Error("multisig_gov ref script not found on-chain");

  // Validity range: now ± 5min, upperBound = upperMs
  const lowerMs = upperMs - BigInt(50 * 60_000); // 50 min before upper → just under 1h cap
  const lower = Number(lowerMs);
  const upper = Number(upperMs);

  // Build TX
  const tx = lucid
    .newTx()
    .collectFrom([govIn], redeemerQueue)
    .readFrom([mgRefUtxo])
    .pay.ToAddressWithData(
      govAddr,
      { kind: "inline", value: newGovDatum as unknown as string },
      govIn.assets,
    )
    .validFrom(lower)
    .validTo(upper)
    .addSignerKey(signers[0])
    .addSignerKey(signers[1]);

  const completed = await tx.complete();
  const unsignedCbor = completed.toCBOR();

  // Multi-key sign: derive account 0 + account 1 paymentKeys, sign body, append witnesses
  const signedCbor = await multiSignCbor(unsignedCbor, mnemonic, ACCOUNTS_TO_SIGN);

  // Submit via Blockfrost
  const res = await fetch(`${bfUrl}/tx/submit`, {
    method: "POST",
    headers: { "Content-Type": "application/cbor", project_id: bfKey },
    body: Buffer.from(signedCbor, "hex"),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`submit failed: ${body}`);
  const txHash = body.replace(/"/g, "").trim();
  console.log(`✅ Queue TX submitted: ${txHash}`);

  // Persist queue info for the execute step
  state.a2 = state.a2 || {};
  state.a2[args.target] = {
    queuedTx: txHash,
    actionId,
    queuedAtMs: Number(upperMs),
    executableAtMs: Number(upperMs + BigInt(timelockMs)),
    expiresAtMs: Number(upperMs + BigInt(timelockMs) + BigInt(ttlMs)),
    targetHash: tgtHash,
    payloadHash: payloadHashHex,
  };
  fs.writeFileSync(stateFile, JSON.stringify(state, null, 2) + "\n");
  console.log(`action_id:        ${actionId}`);
  console.log(`executable_at_ms: ${state.a2[args.target].executableAtMs} (${new Date(state.a2[args.target].executableAtMs).toISOString()})`);
  console.log(`expires_at_ms:    ${state.a2[args.target].expiresAtMs}`);
}

/** Derive account indices for each signer PKH. Scans accounts 0..10 to find a match for each signer. */
async function deriveSignerAccountIndices(mnemonic: string, signers: string[]): Promise<number[]> {
  const { mnemonicToEntropy } = await import("bip39");
  const entropy = mnemonicToEntropy(mnemonic);
  const entropyBytes = new Uint8Array(entropy.match(/.{2}/g)!.map((b) => parseInt(b, 16)));
  const rootKey = CML.Bip32PrivateKey.from_bip39_entropy(entropyBytes, new Uint8Array());

  const indices: number[] = [];
  for (const signer of signers) {
    let found = -1;
    for (let account = 0; account < 10; account++) {
      const key = rootKey
        .derive(0x80000000 + 1852)
        .derive(0x80000000 + 1815)
        .derive(0x80000000 + account)
        .derive(0)
        .derive(0);
      const pkh = key.to_raw_key().to_public().hash().to_hex();
      if (pkh === signer) { found = account; break; }
    }
    indices.push(found);
  }
  return indices;
}

/** Sign a TX body with multiple account indices + attach vkey witnesses. */
async function multiSignCbor(unsignedCbor: string, mnemonic: string, accountIndices: number[]): Promise<string> {
  const { mnemonicToEntropy } = await import("bip39");
  const entropy = mnemonicToEntropy(mnemonic);
  const entropyBytes = new Uint8Array(entropy.match(/.{2}/g)!.map((b) => parseInt(b, 16)));
  const rootKey = CML.Bip32PrivateKey.from_bip39_entropy(entropyBytes, new Uint8Array());

  const tx = CML.Transaction.from_cbor_hex(unsignedCbor);
  const body = tx.body();
  const bodyHash = CML.hash_transaction(body);

  // Start with existing witness set (preserves Lucid-added redeemers + script inlines)
  const witnessSet = CML.TransactionWitnessSet.from_cbor_hex(tx.witness_set().to_cbor_hex());
  const vkeys = witnessSet.vkeywitnesses() ?? CML.VkeywitnessList.new();

  for (const account of accountIndices) {
    const paymentKey = rootKey
      .derive(0x80000000 + 1852)
      .derive(0x80000000 + 1815)
      .derive(0x80000000 + account)
      .derive(0)
      .derive(0);
    const priv = paymentKey.to_raw_key();
    const sig = priv.sign(bodyHash.to_raw_bytes());
    vkeys.add(CML.Vkeywitness.new(priv.to_public(), sig));
  }
  witnessSet.set_vkeywitnesses(vkeys);

  const signedTx = CML.Transaction.new(body, witnessSet, true);
  return signedTx.to_cbor_hex();
}

main().catch((e) => { console.error("[ERROR]", (e as Error).message); if ((e as Error).stack) console.error((e as Error).stack); process.exit(1); });
