/**
 * H-RotateSigners Queue + Execute.
 *
 * ActionKind = 11 (ActRotateSigners). Target = multisig_gov (self).
 * Payload = blake2b_256(cbor.serialise((new_signers, new_threshold))).
 *
 * Execute is SPECIAL — uses RotateSignersRedeemer (Constr 3) instead of the
 * standard ExecuteAction (Constr 2). The multisig_gov UTxO spends itself
 * into a new gov UTxO with updated signers + threshold.
 *
 * Contract (multisig_gov.ak:448-552):
 *   - at least `gov.threshold` old signers must sign
 *   - new_signers: 3..20 distinct 28-byte PKHs
 *   - new_threshold: 2..new_signers.length
 *   - signer_joined_at_ms[i] = upperMs for NEW signers, preserved for existing
 *   - signer_last_qualified_ms[i] = 0 for NEW signers, preserved for existing
 *   - compensation_pool + last_distribute + distribute_period unchanged
 *   - nonce += 1
 *   - queued = prev queued - {this action}
 *   - validity window >= executable_at, < expires_at, width ≤ 1h
 *
 * For Preprod E2E we test the simpler rotation: add a 4th signer derived
 * from accountIndex 3 of the same mnemonic, keep threshold=2. Post-rotation
 * the gov state has 4 signers and the session-default ACCOUNTS_TO_SIGN=[0,1]
 * still satisfies the threshold.
 *
 * Usage:
 *   npx tsx deploy/tools/h-rotate-signers.ts --releaseTag <release-tag>
 *     [--newSignersFile /tmp/newsigners.json --newThreshold N]
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import * as fs from "fs";
import { CML, Constr, Data } from "@lucid-evolution/lucid";
import { blake2b } from "@noble/hashes/blake2b";

import {
  initGovCtx,
  queueAction,
  prepareExecute,
  fetchSingleUtxo,
  fetchRefInputs,
  multiSignCbor,
  submitCbor,
  awaitConfirmation,
  parseGovDatum,
  buildGovDatum,
} from "./lib/gov-helpers.js";

const ACTION_KIND_ROTATE_SIGNERS = 11;
const ROTATE_SIGNERS_REDEEMER_TAG = 3;   // RotateSignersRedeemer
const TIMELOCK_MS = 60_000;
const TTL_MS = 86_400_000;

function parseArgs(): { newSignersFile: string | null; newThreshold: bigint | null } {
  const a = process.argv.slice(2);
  let newSignersFile: string | null = null;
  let newThreshold: bigint | null = null;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--newSignersFile") newSignersFile = a[++i];
    else if (a[i] === "--newThreshold") newThreshold = BigInt(a[++i]);
  }
  return { newSignersFile, newThreshold };
}

async function deriveNewAccountPkh(mnemonic: string, accountIndex: number): Promise<string> {
  const { mnemonicToEntropy } = await import("bip39");
  const entropy = mnemonicToEntropy(mnemonic);
  const entropyBytes = new Uint8Array(entropy.match(/.{2}/g)!.map((b) => parseInt(b, 16)));
  const rootKey = CML.Bip32PrivateKey.from_bip39_entropy(entropyBytes, new Uint8Array());
  const k = rootKey
    .derive(0x80000000 + 1852)
    .derive(0x80000000 + 1815)
    .derive(0x80000000 + accountIndex)
    .derive(0)
    .derive(0);
  return k.to_raw_key().to_public().hash().to_hex();
}

/** CBOR major type 0/1 integer. Matches Aiken `cbor.serialise(Int)`. */
function cborSerialiseInt(n: bigint): Buffer {
  if (n < 0n) {
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
 * payload_hash_rotate_signers = blake2b_256(cbor.serialise((newSigners, newThreshold)))
 *
 * Aiken indef-length list encoding (NOT Constr-wrapped). The Aiken byte
 * shape is `9f <list-of-byteArrays> <int> ff` where the inner list is
 * itself `9f <bytes1> <bytes2> ... ff`. Lucid's `Data.to(string[])`
 * produces canonical Plutus Data list bytes for the inner List<ByteArray>.
 */
function payloadHashRotateSigners(newSigners: string[], newThreshold: bigint): string {
  const innerListCbor = Data.to(newSigners as unknown as never);
  const bytes = Buffer.concat([
    Buffer.from([0x9f]),
    Buffer.from(innerListCbor, "hex"),
    cborSerialiseInt(newThreshold),
    Buffer.from([0xff]),
  ]);
  return Buffer.from(blake2b(bytes, { dkLen: 32 })).toString("hex");
}

async function main() {
  const { newSignersFile, newThreshold: overrideThreshold } = parseArgs();
  const ctx = await initGovCtx();
  const { state, lucid, bfUrl, bfKey, mnemonic } = ctx;

  // Fetch current gov state to derive the default rotation (add acct 3)
  const govAddr = state.stateUtxos.governance.address;
  const govInPre = await fetchSingleUtxo(lucid, govAddr);
  const oldGov = parseGovDatum(govInPre.datum!);
  console.log(`current gov: signers.length=${oldGov.signers.length}, threshold=${oldGov.threshold}, nonce=${oldGov.nonce}`);

  let newSigners: string[];
  let newThreshold: bigint;
  if (newSignersFile) {
    const data = JSON.parse(fs.readFileSync(newSignersFile, "utf8"));
    newSigners = data.signers as string[];
    newThreshold = BigInt(overrideThreshold ?? data.threshold);
  } else {
    // Default: add accountIndex 3 (preserving existing 3 accts 0/1/2)
    const acct3Pkh = await deriveNewAccountPkh(mnemonic, 3);
    if (oldGov.signers.includes(acct3Pkh)) {
      throw new Error(`accountIndex 3 PKH ${acct3Pkh} already in signers — provide --newSignersFile`);
    }
    newSigners = [...oldGov.signers, acct3Pkh];
    newThreshold = overrideThreshold ?? oldGov.threshold;
  }
  console.log(`new gov: signers.length=${newSigners.length}, threshold=${newThreshold}`);
  for (const s of newSigners) console.log(`  ${s}`);

  // Validate
  if (newSigners.length < 3 || newSigners.length > 20) throw new Error(`signers count ${newSigners.length} outside [3, 20]`);
  if (newThreshold < 2n || newThreshold > BigInt(newSigners.length)) throw new Error(`threshold ${newThreshold} outside [2, ${newSigners.length}]`);
  if (new Set(newSigners).size !== newSigners.length) throw new Error(`duplicate signer PKH`);

  const targetHash = state.hashes.multisigGovHash;
  const payloadHashHex = payloadHashRotateSigners(newSigners, newThreshold);
  console.log(`payload_hash: ${payloadHashHex}`);

  // ─── Queue ───────────────────────────────────────────────────────────
  const qResult = await queueAction({
    ctx,
    actionKind: ACTION_KIND_ROTATE_SIGNERS,
    targetHash,
    payloadHashHex,
    timelockMs: TIMELOCK_MS,
    ttlMs: TTL_MS,
    label: "RotateSigners",
  });

  // ─── Execute (RotateSignersRedeemer, not ExecuteAction) ──────────────
  console.log(`\n=== Step 2: Execute RotateSigners (Constr ${ROTATE_SIGNERS_REDEEMER_TAG}) ===`);

  // Re-fetch gov UTxO + compute validity range
  const govIn = await fetchSingleUtxo(lucid, govAddr);
  const g = parseGovDatum(govIn.datum!);
  const queuedForExec = g.queued.find((q: any) =>
    (q.fields[0] as string).toLowerCase() === qResult.actionId.toLowerCase()
  );
  if (!queuedForExec) throw new Error(`action not found in queue`);
  const qf = queuedForExec.fields as any[];
  const execExecutableAt = qf[6] as bigint;
  const execExpiresAt = qf[7] as bigint;

  const slotAlign = (ms: bigint) => (ms / 1000n) * 1000n;
  const nowMs = BigInt(Date.now());
  const lowerRaw = nowMs > execExecutableAt + 1000n ? nowMs : execExecutableAt + 1000n;
  const lowerMs = slotAlign(lowerRaw);
  let upperMs = slotAlign(lowerMs + BigInt(15 * 60_000));
  if (upperMs >= execExpiresAt) upperMs = slotAlign(execExpiresAt - 1000n);
  if (upperMs - lowerMs > 3_600_000n) upperMs = lowerMs + 3_600_000n;
  console.log(`  validity: [${lowerMs}, ${upperMs}]`);

  // Build new GovDatum
  const newJoinedAtMs = newSigners.map((s) => {
    const idx = g.signers.indexOf(s);
    return idx >= 0 ? g.signerJoinedAt[idx] : upperMs;
  });
  const newLastQualMs = newSigners.map((s) => {
    const idx = g.signers.indexOf(s);
    return idx >= 0 ? g.signerLastQualified[idx] : 0n;
  });
  const newQueued = g.queued.filter((q: any) => (q.fields[0] as string).toLowerCase() !== qResult.actionId.toLowerCase());

  const newGovDatum = Data.to(buildGovDatum({
    signers: newSigners,
    signerJoinedAt: newJoinedAtMs,
    signerLastQualified: newLastQualMs,
    threshold: newThreshold,
    queued: newQueued,
    compensationPool: g.compensationPool,
    lastDistributeMs: g.lastDistributeMs,
    distributePeriodMs: g.distributePeriodMs,
    nonce: g.nonce + 1n,
  }) as unknown as Data);

  const rotateRedeemer = Data.to(new Constr(ROTATE_SIGNERS_REDEEMER_TAG, [newSigners, newThreshold]) as unknown as Data);

  const refs = await fetchRefInputs(lucid, [
    { txHash: state.refScripts.multisigGov.txHash, outputIndex: state.refScripts.multisigGov.outputIndex },
  ]);

  const execTx = lucid
    .newTx()
    .collectFrom([govIn], rotateRedeemer)
    .readFrom(refs)
    .pay.ToAddressWithData(
      govAddr,
      { kind: "inline", value: newGovDatum as unknown as string },
      govIn.assets,
    )
    .validFrom(Number(lowerMs))
    .validTo(Number(upperMs))
    .addSignerKey(g.signers[0])
    .addSignerKey(g.signers[1]);

  const built = await execTx.complete();
  const eCbor = await multiSignCbor(built.toCBOR(), mnemonic, ctx.signingAccounts);
  const execTxHash = await submitCbor(bfUrl, bfKey, eCbor);
  console.log(`  ✅ Execute TX: ${execTxHash}`);

  await awaitConfirmation(bfUrl, bfKey, execTxHash, "Execute", 180);

  console.log(`\nPASS — H-RotateSigners Queue+Execute`);
  if (qResult.queueTxHash) console.log(`  queue:   ${qResult.queueTxHash}`);
  console.log(`  execute: ${execTxHash}`);
  console.log(`  action_id: ${qResult.actionId}`);
  console.log(`  applied: ${oldGov.signers.length}→${newSigners.length} signers, threshold=${newThreshold}`);
}

main().catch((e) => {
  console.error("[ERROR]", (e as Error).message);
  if ((e as Error).stack) console.error((e as Error).stack);
  process.exit(1);
});
