/**
 * H-Emergency Queue + Execute — benign ActEmergencyWithdraw(0, 0).
 *
 * ActEmergencyWithdraw has timelock_emergency_ms=0, so Queue and Execute
 * can both land in the same session. With `(loss_amount=0, freeze_flag=0)`
 * the on-chain state is effectively unchanged — but the full control
 * flow is exercised:
 *   - MultisigGov.QueueAction (2-of-3 sigs, action_id computed)
 *   - MultisigGov.ExecuteAction (2-of-3 sigs, action removed from queue)
 *   - vault_proxy.UseGovEmergency route (withdrawal_count == 1)
 *   - vault_gov_emergency.EmergencyWithdraw (is_gov_authorized +
 *     payload_hash check + valid_frozen + valid_deposited +
 *     valid_multi_inputs + no_mint + no_order_inputs)
 *
 * Idempotency: if a matching ActEmergencyWithdraw(0,0) is already
 * queued (e.g. previous run's Queue succeeded but Execute crashed),
 * Queue is skipped and the tool waits until the existing action's
 * executable_at_ms before submitting Execute.
 *
 * Usage:
 *   npx tsx deploy/tools/h-emergency-benign.ts --releaseTag v1-preprod-p2
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
import { blake2b } from "@noble/hashes/blake2b";
import { createBlockfrostProvider } from "../lib/blockfrostProvider.js";
import { getKeyDaemonSocket } from "../lib/keyDaemon.js";

const ACCOUNTS_TO_SIGN = [0, 1];
const ACTION_KIND_EMERGENCY = 4;

interface CliArgs {
  network: "Preprod" | "Mainnet";
  releaseTag: string;
}

function parseArgs(): CliArgs {
  const a = process.argv.slice(2);
  let network: CliArgs["network"] = "Preprod";
  let releaseTag = "v1-preprod-p2";
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--network") network = a[++i] as CliArgs["network"];
    else if (a[i] === "--releaseTag") releaseTag = a[++i];
  }
  return { network, releaseTag };
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
 * payload_hash_emergency_withdraw(loss, freeze) = blake2b_256(cbor.serialise((loss, freeze)))
 *
 * Aiken `cbor.serialise((Int, Int))` emits an indefinite-length CBOR list
 * at the Plutus Data level — NOT a Constr-wrapped array. Canonical bytes:
 * `9f <cbor(loss)> <cbor(freeze)> ff`. Each tuple element is encoded
 * canonically (cborSerialiseInt for Int). The naive `Data.to(Constr(0,
 * [a,b]))` encoding (`d8799f<a><b>ff`) is wrong and produces a different
 * hash than Aiken's on-chain recompute, surfacing as a generic
 * governance-authorization rejection at Execute time.
 */
function payloadHashEmergencyWithdraw(loss: bigint, freeze: bigint): string {
  const bytes = Buffer.concat([
    Buffer.from([0x9f]),
    cborSerialiseInt(loss),
    cborSerialiseInt(freeze),
    Buffer.from([0xff]),
  ]);
  return blake2b256Hex(bytes);
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

  const provider = createBlockfrostProvider(bfUrl, bfKey);
  const lucid = await Lucid(provider as any, args.network);
  const sock = getKeyDaemonSocket();
  const mnemonic = await getMnemonic(sock);
  lucid.selectWallet.fromSeed(mnemonic);
  const wallet = await lucid.wallet().address();
  console.log(`wallet: ${wallet.slice(0, 30)}…`);

  const targetHash = state.hashes.govEmergencyStakeHash;
  if (!targetHash) throw new Error("govEmergencyStakeHash not in state");
  console.log(`target (vault_gov_emergency): ${targetHash}`);

  const lossAmount = 0n;
  const freezeFlag = 0n;
  const payloadHashHex = payloadHashEmergencyWithdraw(lossAmount, freezeFlag);
  console.log(`payload_hash (0, 0): ${payloadHashHex}`);

  const govAddr = state.stateUtxos.governance.address;
  let govIn = await fetchSingleUtxo(lucid, govAddr);
  let g = parseGovDatum(govIn.datum!);
  console.log(`gov: nonce=${g.nonce}, queued.length=${g.queued.length}`);

  // Try to reuse existing queued action
  let actionId: string;
  let queueTxHash: string | null = null;
  const existing = g.queued.find((q: any) => {
    const qf = q.fields as any[];
    return (qf[1] as Constr<any>).index === ACTION_KIND_EMERGENCY && (qf[4] as string) === payloadHashHex;
  });

  if (existing) {
    const ef = existing.fields as any[];
    actionId = ef[0] as string;
    const executableAt = ef[6] as bigint;
    const expiresAt = ef[7] as bigint;
    console.log(`\nℹ️  matching action already queued — skipping Queue phase`);
    console.log(`  action_id:        ${actionId}`);
    console.log(`  executable_at_ms: ${executableAt} (${new Date(Number(executableAt)).toISOString()})`);
    console.log(`  expires_at_ms:    ${expiresAt}`);

    const waitMs = Number(executableAt - BigInt(Date.now()) + 2000n);
    if (waitMs > 0) {
      console.log(`  sleeping ${waitMs}ms until executable_at_ms + 2s buffer...`);
      await new Promise((r) => setTimeout(r, waitMs));
    }
  } else {
    console.log("\n=== Phase 1: Queue ActEmergencyWithdraw(0, 0) ===");
    const timelockMs = 0;
    const ttlMs = 86_400_000;

    // Short queue window so executable_at_ms is close to wall-clock
    const upperMsQueue = BigInt(Math.floor((Date.now() + 90_000) / 1000) * 1000);
    const lowerMsQueue = upperMsQueue - BigInt(55 * 60_000);
    const actionIdBytes = Buffer.concat([
      Buffer.from("04", "hex"),
      Buffer.from(targetHash, "hex"),
      Buffer.from(payloadHashHex, "hex"),
      cborSerialiseInt(upperMsQueue),
      cborSerialiseInt(g.nonce),
    ]);
    actionId = blake2b256Hex(actionIdBytes);
    console.log(`  computed action_id: ${actionId}`);

    const sigIdx = await deriveSignerAccountIndices(mnemonic, g.signers);
    const newSignerLastQ = g.signers.map((_, i) =>
      ACCOUNTS_TO_SIGN.includes(sigIdx[i]) ? upperMsQueue : g.signerLastQualified[i],
    );

    const newQueued = new Constr(0, [
      actionId,
      new Constr(ACTION_KIND_EMERGENCY, []),
      targetHash,
      "",
      payloadHashHex,
      upperMsQueue,
      upperMsQueue + BigInt(timelockMs),
      upperMsQueue + BigInt(timelockMs) + BigInt(ttlMs),
    ]);
    const newGovDatumQ = Data.to(buildGovDatum({
      ...g,
      signerLastQualified: newSignerLastQ,
      queued: [newQueued, ...g.queued],
      nonce: g.nonce + 1n,
    }) as unknown as Data);

    const redeemerQueue = Data.to(new Constr(0, [
      new Constr(ACTION_KIND_EMERGENCY, []),
      targetHash,
      "",
      payloadHashHex,
      BigInt(timelockMs),
      BigInt(ttlMs),
    ]) as unknown as Data);

    const mgRef = state.refScripts.multisigGov;
    const [mgRefUtxo] = await lucid.utxosByOutRef([{ txHash: mgRef.txHash, outputIndex: mgRef.outputIndex }]);

    const queueTx = lucid
      .newTx()
      .collectFrom([govIn], redeemerQueue)
      .readFrom([mgRefUtxo])
      .pay.ToAddressWithData(
        govAddr,
        { kind: "inline", value: newGovDatumQ as unknown as string },
        govIn.assets,
      )
      .validFrom(Number(lowerMsQueue))
      .validTo(Number(upperMsQueue))
      .addSignerKey(g.signers[0])
      .addSignerKey(g.signers[1]);

    const qc = await queueTx.complete();
    const qCbor = await multiSignCbor(qc.toCBOR(), mnemonic, ACCOUNTS_TO_SIGN);
    const qRes = await fetch(`${bfUrl}/tx/submit`, {
      method: "POST",
      headers: { "Content-Type": "application/cbor", project_id: bfKey },
      body: Buffer.from(qCbor, "hex"),
    });
    const qBody = await qRes.text();
    if (!qRes.ok) throw new Error(`Queue submit failed: ${qBody}`);
    queueTxHash = qBody.replace(/"/g, "").trim();
    console.log(`  ✅ Queue TX: ${queueTxHash}`);

    // Wait for indexing
    console.log(`  waiting for Blockfrost indexing...`);
    const t0 = Date.now();
    let confirmed = false;
    for (let i = 0; i < 30; i++) {
      await new Promise((r) => setTimeout(r, 10_000));
      const r = await fetch(`${bfUrl}/txs/${queueTxHash}`, { headers: { project_id: bfKey } });
      if (r.ok) { confirmed = true; console.log(`  ✅ confirmed after ${Math.round((Date.now()-t0)/1000)}s`); break; }
    }
    if (!confirmed) throw new Error(`Queue TX didn't confirm within 5min`);
    await new Promise((r) => setTimeout(r, 5_000));

    // Ensure wall-clock >= executable_at_ms (= upperMsQueue since timelock=0)
    // + 300s lag buffer so Preprod relay's slot catches up to lower bound.
    // A shorter 2s buffer hits OutsideValidityIntervalUTxO when chain lag
    // exceeds a few seconds (Preprod relay propagation is non-deterministic
    // in the 30-120s range, with occasional spikes that exceed shorter
    // buffers).
    const waitMs = Number(upperMsQueue - BigInt(Date.now()) + 300_000n);
    if (waitMs > 0) {
      console.log(`  sleeping ${waitMs}ms until executable_at_ms + 300s lag buffer...`);
      await new Promise((r) => setTimeout(r, waitMs));
    }
  }

  // ====== Execute Phase ======
  console.log("\n=== Phase 2: Execute ActEmergencyWithdraw(0, 0) ===");
  // Re-fetch gov UTxO (now at queued state)
  govIn = await fetchSingleUtxo(lucid, govAddr);
  g = parseGovDatum(govIn.datum!);
  console.log(`  gov: nonce=${g.nonce}, queued.length=${g.queued.length}`);

  // Find queued action + extract its executable/expires
  const queuedForExec = g.queued.find((q: any) =>
    ((q.fields[0] as string).toLowerCase() === actionId.toLowerCase())
  );
  if (!queuedForExec) throw new Error(`action ${actionId} not found in queue`);
  const qf = queuedForExec.fields as any[];
  const execExecutableAt = qf[6] as bigint;
  const execExpiresAt = qf[7] as bigint;

  // Fetch vault UTxO with NFT
  const vaultNftUnit = state.mints.vaultNft.policyId + state.mints.vaultNft.assetName;
  const vaultAddr = state.stateUtxos.vault.address;
  const allVaultUtxos = await lucid.utxosAt(vaultAddr);
  const vaultUtxo = allVaultUtxos.find((u) => (u.assets[vaultNftUnit] || 0n) === 1n);
  if (!vaultUtxo) throw new Error(`vault UTxO with NFT not found`);
  console.log(`  vault UTxO: ${vaultUtxo.txHash.slice(0, 16)}…#${vaultUtxo.outputIndex}`);

  // Validity range: max(Date.now() - 180s past margin, execExecutableAt + 1s)
  //                  ≤ lower ≤ upper < execExpiresAt, width ≤ 1h.
  // Past margin absorbs Preprod relay's 30-120s slot lag — without it,
  // submit hits OutsideValidityIntervalUTxO because chain's currentSlot
  // is still < lower when Blockfrost forwards the TX.
  const slotAlign = (ms: bigint) => (ms / 1000n) * 1000n;
  const nowPastMargin = BigInt(Date.now()) - 180_000n;
  const lowerRaw = nowPastMargin > execExecutableAt + 1000n ? nowPastMargin : execExecutableAt + 1000n;
  const lowerMsExec = slotAlign(lowerRaw);
  let upperMsExec = slotAlign(lowerMsExec + BigInt(30 * 60_000));
  if (upperMsExec >= execExpiresAt) {
    upperMsExec = slotAlign(execExpiresAt - 1000n);
    if (upperMsExec - lowerMsExec < 60_000n) throw new Error("action expired — not enough window left");
  }
  console.log(`  validity range: [${lowerMsExec}, ${upperMsExec}]`);

  // Derive signer account indices
  const sigIdx = await deriveSignerAccountIndices(mnemonic, g.signers);
  const newSignerLastE = g.signers.map((_, i) =>
    ACCOUNTS_TO_SIGN.includes(sigIdx[i]) ? upperMsExec : g.signerLastQualified[i],
  );

  // Filter out the action
  const newQueuedE = g.queued.filter((q: any) => (q.fields[0] as string).toLowerCase() !== actionId.toLowerCase());

  const newGovDatumE = Data.to(buildGovDatum({
    ...g,
    signerLastQualified: newSignerLastE,
    queued: newQueuedE,
    nonce: g.nonce + 1n,
  }) as unknown as Data);

  // Redeemers
  const redeemerExec = Data.to(new Constr(2, [actionId]) as unknown as Data);
  // EmergencyWithdraw is at VaultRedeemer Constr index 15. Off-chain
  // redeemer index numbering must mirror Aiken declaration order in
  // `lib/vault/types.ak::VaultRedeemer`; insertions to that enum shift
  // every later variant by +1 and any TS callsite hand-building
  // `Constr(N, [...])` for a vault redeemer must update in lockstep.
  const emergencyRedeemer = Data.to(new Constr(15, [lossAmount, freezeFlag]) as unknown as Data);
  const proxyRedeemer = Data.to(new Constr(7, []) as unknown as Data); // UseGovEmergency

  // Ref inputs
  const mgRef = state.refScripts.multisigGov;
  const proxyRef = state.refScripts.vaultProxy;
  const govEmergRef = state.refScripts.vaultGovEmergency;
  const refs = await lucid.utxosByOutRef([
    { txHash: mgRef.txHash, outputIndex: mgRef.outputIndex },
    { txHash: proxyRef.txHash, outputIndex: proxyRef.outputIndex },
    { txHash: govEmergRef.txHash, outputIndex: govEmergRef.outputIndex },
  ]);
  if (refs.length !== 3) throw new Error(`expected 3 ref UTxOs, got ${refs.length}`);

  // vault_gov_emergency reward addr from script hash
  const govEmergScriptHash = CML.ScriptHash.from_hex(targetHash);
  const govEmergCred = CML.Credential.new_script(govEmergScriptHash);
  const rewardAddrObj = CML.RewardAddress.new(
    args.network === "Preprod" ? 0 : 1,
    govEmergCred,
  );
  const govEmergRewardAddr = rewardAddrObj.to_address().to_bech32(undefined);
  console.log(`  vault_gov_emergency reward addr: ${govEmergRewardAddr.slice(0, 40)}…`);

  const execTx = lucid
    .newTx()
    .collectFrom([govIn], redeemerExec)
    .collectFrom([vaultUtxo], proxyRedeemer)
    .withdraw(govEmergRewardAddr, 0n, emergencyRedeemer)
    .readFrom(refs)
    .pay.ToAddressWithData(
      govAddr,
      { kind: "inline", value: newGovDatumE as unknown as string },
      govIn.assets,
    )
    .pay.ToContract(
      vaultAddr,
      { kind: "inline", value: (Data.to(Data.from(vaultUtxo.datum!) as unknown as never)) },
      vaultUtxo.assets,
    )
    .validFrom(Number(lowerMsExec))
    .validTo(Number(upperMsExec))
    .addSignerKey(g.signers[0])
    .addSignerKey(g.signers[1]);

  const ec = await execTx.complete();
  const eCbor = await multiSignCbor(ec.toCBOR(), mnemonic, ACCOUNTS_TO_SIGN);
  const eRes = await fetch(`${bfUrl}/tx/submit`, {
    method: "POST",
    headers: { "Content-Type": "application/cbor", project_id: bfKey },
    body: Buffer.from(eCbor, "hex"),
  });
  const eBody = await eRes.text();
  if (!eRes.ok) throw new Error(`Execute submit failed: ${eBody}`);
  const execTxHash = eBody.replace(/"/g, "").trim();
  console.log(`  ✅ Execute TX: ${execTxHash}`);

  console.log(`\nPASS — H-Emergency Queue+Execute cycle`);
  if (queueTxHash) console.log(`  queue:   ${queueTxHash}`);
  console.log(`  execute: ${execTxHash}`);
  console.log(`  action_id: ${actionId}`);
}

// ─────────────────────────────────────────────────────────────────────
interface GovDatumParsed {
  signers: string[];
  signerJoinedAt: bigint[];
  signerLastQualified: bigint[];
  threshold: bigint;
  queued: any[];
  compensationPool: bigint;
  lastDistributeMs: bigint;
  distributePeriodMs: bigint;
  nonce: bigint;
}
function parseGovDatum(datumCbor: string): GovDatumParsed {
  const d = Data.from(datumCbor) as any;
  const f = d.fields as any[];
  return {
    signers: f[0] as string[],
    signerJoinedAt: f[1] as bigint[],
    signerLastQualified: f[2] as bigint[],
    threshold: f[3] as bigint,
    queued: f[4] as any[],
    compensationPool: f[5] as bigint,
    lastDistributeMs: f[6] as bigint,
    distributePeriodMs: f[7] as bigint,
    nonce: f[8] as bigint,
  };
}
function buildGovDatum(g: GovDatumParsed): Constr<unknown> {
  return new Constr(0, [
    g.signers,
    g.signerJoinedAt,
    g.signerLastQualified,
    g.threshold,
    g.queued,
    g.compensationPool,
    g.lastDistributeMs,
    g.distributePeriodMs,
    g.nonce,
  ]) as Constr<unknown>;
}
async function fetchSingleUtxo(lucid: LucidEvolution, addr: string): Promise<UTxO> {
  const utxos = await lucid.utxosAt(addr);
  if (utxos.length !== 1) throw new Error(`expected 1 UTxO at ${addr.slice(0,40)}…, got ${utxos.length}`);
  return utxos[0];
}

main().catch((e) => {
  console.error("[ERROR]", (e as Error).message);
  if ((e as Error).stack) console.error((e as Error).stack);
  process.exit(1);
});
