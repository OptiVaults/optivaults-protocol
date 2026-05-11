/**
 * Shared helpers for governance Queue + Execute tools
 * (h-update-strategy.ts, h-update-fee.ts, ... h-emergency-benign.ts).
 *
 * Extracted from the first implementation in h-emergency-benign.ts so that
 * 10 per-action tools can share the ~250 LOC of common scaffolding:
 *   - CBOR encoding of canonical Aiken ints (for action_id preimage)
 *   - blake2b-256 hashing
 *   - CIP-1852 signer-account discovery from mnemonic
 *   - multisig CBOR assembly (append vkey witnesses)
 *   - GovDatum parse / build (9 fields)
 *   - state-file loading + ceremony-anchored UTxO lookups
 *
 * Each action-specific tool supplies:
 *   - actionKind (integer index 0-13 per ActionKind enum)
 *   - target_hash (script hash the action writes to)
 *   - payloadHashHex (per-action, see contracts/lib/vault/helpers.ak)
 *   - Queue / Execute TX builders (Lucid) — the non-shared parts
 */
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
import { createBlockfrostProvider } from "../../lib/blockfrostProvider.js";
import { getKeyDaemonSocket } from "../../lib/keyDaemon.js";

export interface GovCtx {
  network: "Preprod" | "Mainnet";
  releaseTag: string;
  bfUrl: string;
  bfKey: string;
  stateFile: string;
  state: any;
  lucid: LucidEvolution;
  mnemonic: string;
  wallet: string;
  /** 2 default signer account indices for Queue+Execute m-of-n */
  signingAccounts: number[];
}

export function parseCommonArgs(defaults: { releaseTag?: string } = {}): {
  network: "Preprod" | "Mainnet";
  releaseTag: string;
  dryRun: boolean;
} {
  const a = process.argv.slice(2);
  let network: "Preprod" | "Mainnet" = "Preprod";
  let releaseTag = defaults.releaseTag ?? "v1-preprod-p4";
  let dryRun = false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--network") network = a[++i] as "Preprod" | "Mainnet";
    else if (a[i] === "--releaseTag") releaseTag = a[++i];
    else if (a[i] === "--dryRun") dryRun = true;
  }
  return { network, releaseTag, dryRun };
}

async function getMnemonic(sock: string): Promise<string> {
  if (process.env.KEEPER_MNEMONIC) return process.env.KEEPER_MNEMONIC;
  return new Promise((res, rej) => {
    const c = net.createConnection(sock, () => c.write("GET_MNEMONIC"));
    let buf = "";
    c.on("data", (d) => { buf += d.toString(); });
    c.on("end", () => res(buf.startsWith("OK:") ? buf.slice(3).trim() : buf.trim()));
    c.on("error", rej);
    setTimeout(() => rej(new Error("key daemon timeout")), 5000);
  });
}

export async function initGovCtx(): Promise<GovCtx> {
  const { network, releaseTag } = parseCommonArgs();
  const bfUrl = network === "Preprod"
    ? "https://cardano-preprod.blockfrost.io/api/v0"
    : "https://cardano-mainnet.blockfrost.io/api/v0";
  const bfKey = network === "Preprod"
    ? (process.env.BLOCKFROST_API_KEY_PREPROD || "")
    : (process.env.BLOCKFROST_API_KEY || "");
  if (!bfKey) throw new Error(`Missing Blockfrost key for ${network}`);

  const stateFile = `deploy/state/${network.toLowerCase()}-${releaseTag}.json`;
  if (!fs.existsSync(stateFile)) throw new Error(`state not found: ${stateFile}`);
  const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));

  const provider = createBlockfrostProvider(bfUrl, bfKey);
  const lucid = await Lucid(provider as any, network);
  const mnemonic = await getMnemonic(getKeyDaemonSocket());
  lucid.selectWallet.fromSeed(mnemonic);
  const wallet = await lucid.wallet().address();

  return { network, releaseTag, bfUrl, bfKey, stateFile, state, lucid, mnemonic, wallet, signingAccounts: [0, 1] };
}

export function blake2b256Hex(bytes: Buffer): string {
  return Buffer.from(blake2b(bytes, { dkLen: 32 })).toString("hex");
}

/**
 * Strip Lucid Evolution v0.4.x InlineDatum fields before `collectFrom`.
 *
 * Lucid CompleteTxBuilder picks the
 * `plutus_script` branch (attaches datum to witness_set) when both
 * `utxo.datum` and `utxo.datumHash` are populated. Blockfrost/Kupo
 * populate BOTH for inline-datum UTxOs, so the resulting TX has
 * supplemental datums the ledger rejects with
 * `NotAllowedSupplementalDatums`. Strip both fields (and `scriptRef` to
 * avoid the ref-script auto-coin-selection trap) so Lucid
 * routes through `plutus_script_inline_datum` — the validator reads the
 * on-chain inline datum directly.
 *
 * Same helper as `tests/preprod/tools/deploy-helpers.ts::stripLucidDatumFields`;
 * mirrored here so gov-helpers doesn't depend on the test tree.
 */
export function stripLucidDatumFields<T extends { datum?: any; datumHash?: any; scriptRef?: any }>(u: T): T {
  return { ...u, datum: undefined, datumHash: undefined, scriptRef: undefined };
}

/**
 * Canonical CBOR integer (major type 0 / 1) matching Aiken's
 * `cbor.serialise(Int)` byte output. Used to build the action_id preimage.
 */
export function cborSerialiseInt(n: bigint): Buffer {
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
 * Action kind byte tag per `action_kind_byte` in multisig_gov.ak.
 * Note: declaration variant index does NOT equal byte tag for
 * ActUpdateStrategy / UpdateFee / UpdateFeeSplit / UpdateSlippagePolicy /
 * DeregisterStake. Byte tags are 1-indexed AND were shuffled when
 * UpdateSlippagePolicy was added post-launch (assigned 0x0f to preserve
 * existing tags) — keep this table in lock-step with the contract.
 */
export const ACTION_KIND_BYTE: Record<number, number> = {
  0: 0x01,  // ActUpdateStrategy
  1: 0x02,  // ActUpdateFee
  2: 0x03,  // ActUpdateFeeSplit
  3: 0x0f,  // ActUpdateSlippagePolicy (§5.4 P2, added post-launch)
  4: 0x04,  // ActEmergencyWithdraw
  5: 0x05,  // ActAdminDeployNonDeposit
  6: 0x06,  // ActUpdateRegistry
  7: 0x07,  // ActFastUpdateMarkets
  8: 0x08,  // ActUpdateKeeperAuth
  9: 0x09,  // ActTreasurySpend
  10: 0x0a, // ActUpdateTreasuryParams
  11: 0x0b, // ActRotateSigners
  12: 0x0c, // ActSlashBond
  13: 0x0e, // ActDeregisterStake (skips 0x0d by design)
};

/**
 * action_id = blake2b_256(kind_byte || target_script || payload_hash ||
 *                         cbor(queued_at_ms) || cbor(nonce))
 *
 * NOTE: `target_tx_hash` is in the on-chain QueuedAction record but is
 * NOT part of the action_id preimage (see multisig_gov.ak::compute_action_id).
 */
export function computeActionId(
  actionKind: number,
  targetHash: string,
  payloadHashHex: string,
  upperMs: bigint,
  nonce: bigint,
): string {
  const byteTag = ACTION_KIND_BYTE[actionKind];
  if (byteTag === undefined) throw new Error(`Unknown action kind variant ${actionKind}`);
  const bytes = Buffer.concat([
    Buffer.from([byteTag]),
    Buffer.from(targetHash, "hex"),
    Buffer.from(payloadHashHex, "hex"),
    cborSerialiseInt(upperMs),
    cborSerialiseInt(nonce),
  ]);
  return blake2b256Hex(bytes);
}

export async function deriveSignerAccountIndices(
  mnemonic: string,
  signers: string[],
): Promise<number[]> {
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

export async function multiSignCbor(
  unsignedCbor: string,
  mnemonic: string,
  accountIndices: number[],
): Promise<string> {
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

export async function submitCbor(
  bfUrl: string,
  bfKey: string,
  cborHex: string,
): Promise<string> {
  const res = await fetch(`${bfUrl}/tx/submit`, {
    method: "POST",
    headers: { "Content-Type": "application/cbor", project_id: bfKey },
    body: Buffer.from(cborHex, "hex"),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`submit failed: ${body}`);
  return body.replace(/"/g, "").trim();
}

export async function awaitConfirmation(
  bfUrl: string,
  bfKey: string,
  txHash: string,
  label = "TX",
  maxWaitSeconds = 300,
): Promise<void> {
  const t0 = Date.now();
  for (let i = 0; i < maxWaitSeconds / 10; i++) {
    await new Promise((r) => setTimeout(r, 10_000));
    const r = await fetch(`${bfUrl}/txs/${txHash}`, { headers: { project_id: bfKey } });
    if (r.ok) {
      console.log(`  ✅ ${label} confirmed after ${Math.round((Date.now() - t0) / 1000)}s`);
      return;
    }
  }
  throw new Error(`${label} didn't confirm within ${maxWaitSeconds}s`);
}

// ─────────────────────────────────────────────────────────────────────
// GovDatum parse + build (9 fields)
// ─────────────────────────────────────────────────────────────────────

export interface GovDatumParsed {
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

export function parseGovDatum(datumCbor: string): GovDatumParsed {
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

export function buildGovDatum(g: GovDatumParsed): Constr<unknown> {
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

export async function fetchSingleUtxo(lucid: LucidEvolution, addr: string): Promise<UTxO> {
  const utxos = await lucid.utxosAt(addr);
  if (utxos.length !== 1) throw new Error(`expected 1 UTxO at ${addr.slice(0,40)}…, got ${utxos.length}`);
  return utxos[0];
}

/**
 * Fetch the gov UTxO with stability polling — return only after 2
 * consecutive polls return the same outRef + datum nonce. Hardens
 * queueAction's idempotency check against the Blockfrost
 * address-utxos indexer-lag bug class.
 *
 * Bug class: operator retries an h-* governance tool after a
 * Blockfrost /txs/<hash> 404 polling timeout. On retry, queueAction's
 * idempotency check runs against a STALE gov UTxO returned by
 * Blockfrost (known 30-90s address-utxos indexer lag), misses the
 * just-landed first-attempt action, and builds a duplicate Queue TX
 * with a different action_id. Result: two stuck queued actions
 * needing manual cleanup.
 *
 * awaitGovActionInQueue already documents the same lag pattern for
 * the post-queue path; this helper closes the equivalent gap on the
 * pre-queue idempotency check.
 *
 * Default 30s max wait, 5s poll interval = 6 attempts max. Returns
 * after 2 consecutive identical observations (typical 10s overhead).
 * If gov state doesn't stabilise, warns and returns the last seen
 * UTxO so callers degrade to old behaviour rather than hang.
 */
export async function fetchStableGovUtxo(
  lucid: LucidEvolution,
  addr: string,
  maxWaitMs = 30_000,
  pollIntervalMs = 5_000,
): Promise<UTxO> {
  const t0 = Date.now();
  let prevTxHash: string | null = null;
  let prevOutIdx: number | null = null;
  let prevNonce: bigint | null = null;
  let last: UTxO | null = null;
  while (Date.now() - t0 < maxWaitMs) {
    const utxo = await fetchSingleUtxo(lucid, addr);
    last = utxo;
    const g = parseGovDatum(utxo.datum!);
    if (
      prevTxHash === utxo.txHash &&
      prevOutIdx === utxo.outputIndex &&
      prevNonce === g.nonce
    ) {
      return utxo;
    }
    prevTxHash = utxo.txHash;
    prevOutIdx = utxo.outputIndex;
    prevNonce = g.nonce;
    await new Promise((r) => setTimeout(r, pollIntervalMs));
  }
  console.warn(
    `[fetchStableGovUtxo] gov UTxO did not stabilise within ${maxWaitMs}ms — ` +
    `proceeding with last observed (txHash=${last?.txHash.slice(0, 16) ?? "??"}…). ` +
    `Risk: queueAction idempotency check may miss a recently-landed action.`,
  );
  return last ?? (await fetchSingleUtxo(lucid, addr));
}

/**
 * Re-fetch the gov UTxO with polling until a specific action_id appears
 * in the queued list. Mitigates Blockfrost address-utxos indexer lag —
 * Blockfrost commonly returns the pre-Queue gov UTxO for 30-90s after
 * `lucid.awaitTx()` resolves. Without polling, prepareExecute reads
 * stale gov state and throws "action not found in queue".
 *
 * Polls every 5s up to `timeoutMs` (default 120s). Returns the gov UTxO,
 * parsed datum, and matched queued entry in a single decode pass to
 * avoid redundant `find` in callers.
 */
export async function awaitGovActionInQueue(
  lucid: LucidEvolution,
  govAddr: string,
  actionId: string,
  timeoutMs: number = 120_000,
): Promise<{ govIn: UTxO; g: GovDatumParsed; queuedForExec: { fields: any[] } }> {
  const POLL_INTERVAL_MS = 5_000;
  const targetActionId = actionId.toLowerCase();
  const deadline = Date.now() + timeoutMs;
  let lastQueuedLen = -1;
  let lastNonce = -1n;
  while (true) {
    const govIn = await fetchSingleUtxo(lucid, govAddr);
    const g = parseGovDatum(govIn.datum!);
    const queuedForExec = g.queued.find((q: any) =>
      ((q.fields[0] as string).toLowerCase() === targetActionId)
    );
    if (queuedForExec) return { govIn, g, queuedForExec };
    if (g.queued.length !== lastQueuedLen || g.nonce !== lastNonce) {
      console.log(`  gov polling: nonce=${g.nonce} queued.length=${g.queued.length} (waiting for action ${actionId.slice(0, 16)}…)`);
      lastQueuedLen = g.queued.length;
      lastNonce = g.nonce;
    }
    if (Date.now() >= deadline) {
      throw new Error(
        `awaitGovActionInQueue: action ${actionId.slice(0, 16)}… not found in gov queue within ${timeoutMs}ms ` +
        `(last seen queued.length=${g.queued.length}, nonce=${g.nonce}) — Blockfrost indexer stalled?`,
      );
    }
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
}

/**
 * Fetch the vault UTxO (the one with Vault NFT). Useful for actions that
 * read the vault as a Withdraw-Zero continuing output.
 */
export async function fetchVaultUtxoWithNft(
  lucid: LucidEvolution,
  state: any,
): Promise<UTxO> {
  const vaultNftUnit = state.mints.vaultNft.policyId + state.mints.vaultNft.assetName;
  const vaultAddr = state.stateUtxos.vault.address;
  const all = await lucid.utxosAt(vaultAddr);
  const u = all.find((x) => (x.assets[vaultNftUnit] || 0n) === 1n);
  if (!u) throw new Error(`vault UTxO with NFT not found at ${vaultAddr.slice(0, 40)}…`);
  return u;
}

// ─────────────────────────────────────────────────────────────────────
// Queue + Execute common phases
// ─────────────────────────────────────────────────────────────────────

export interface QueueArgs {
  ctx: GovCtx;
  actionKind: number;
  targetHash: string;
  payloadHashHex: string;
  /** Action-level timelock (milliseconds from queue time to executable_at_ms). */
  timelockMs: number;
  /** Action TTL (milliseconds from queue time to expires_at_ms). */
  ttlMs: number;
  /** Short label for log lines. */
  label: string;
  /** Queue TX validity window (defaults to 90s width). */
  queueWindowMs?: number;
  /**
   * If true, skip the post-Queue sleep until `executable_at_ms + 120s`.
   * Useful for callers that don't follow up with Execute (e.g.
   * h-numeric-verify-all.ts which Queues + asserts delta + Cancels).
   * Default false (preserves existing Queue+Execute callers' semantics).
   */
  skipExecutableWait?: boolean;
}

export interface QueueResult {
  actionId: string;
  queueTxHash: string | null;
  executableAtMs: bigint;
  expiresAtMs: bigint;
  /** Latest observed gov datum AFTER queuing. */
  gov: GovDatumParsed;
}

/**
 * Queue a governance action idempotently. If a matching action (same
 * action_kind + payload_hash) is already queued, skip the Queue TX and
 * return the existing action's metadata.
 */
export async function queueAction(args: QueueArgs): Promise<QueueResult> {
  const { ctx, actionKind, targetHash, payloadHashHex, timelockMs, ttlMs, label } = args;
  const queueWindowMs = args.queueWindowMs ?? 90_000;
  const skipExecutableWait = args.skipExecutableWait ?? false;
  const { lucid, state, mnemonic } = ctx;

  const govAddr = state.stateUtxos.governance.address;
  // Stability poll instead of single fetch — closes the
  // Blockfrost address-utxos indexer-lag bug where the idempotency
  // check below ran against a stale gov UTxO and missed a
  // just-landed action. See fetchStableGovUtxo docstring.
  let govIn = await fetchStableGovUtxo(lucid, govAddr);
  let g = parseGovDatum(govIn.datum!);
  console.log(`gov: nonce=${g.nonce}, queued.length=${g.queued.length}`);

  // Idempotency: look for existing queued action with matching kind + payload
  const existing = g.queued.find((q: any) => {
    const qf = q.fields as any[];
    return (qf[1] as Constr<any>).index === actionKind && (qf[4] as string).toLowerCase() === payloadHashHex.toLowerCase();
  });
  if (existing) {
    const ef = existing.fields as any[];
    const actionId = ef[0] as string;
    const executableAtMs = ef[6] as bigint;
    const expiresAtMs = ef[7] as bigint;
    console.log(`ℹ️  matching ${label} already queued — skipping Queue phase`);
    console.log(`  action_id:        ${actionId}`);
    console.log(`  executable_at_ms: ${executableAtMs} (${new Date(Number(executableAtMs)).toISOString()})`);
    if (!skipExecutableWait) {
      const waitMs = Number(executableAtMs - BigInt(Date.now()) + 2000n);
      if (waitMs > 0) {
        console.log(`  sleeping ${waitMs}ms until executable_at + 2s buffer...`);
        await new Promise((r) => setTimeout(r, waitMs));
      }
    }
    return { actionId, queueTxHash: null, executableAtMs, expiresAtMs, gov: g };
  }

  console.log(`\n=== Step 1: Queue ${label} ===`);
  const upperMsQueue = BigInt(Math.floor((Date.now() + queueWindowMs) / 1000) * 1000);
  const lowerMsQueue = upperMsQueue - BigInt(Math.min(55 * 60_000, queueWindowMs * 30));
  const actionId = computeActionId(actionKind, targetHash, payloadHashHex, upperMsQueue, g.nonce);
  console.log(`  computed action_id: ${actionId}`);

  const sigIdx = await deriveSignerAccountIndices(mnemonic, g.signers);
  const newSignerLastQ = g.signers.map((_, i) =>
    ctx.signingAccounts.includes(sigIdx[i]) ? upperMsQueue : g.signerLastQualified[i],
  );

  const executableAtMs = upperMsQueue + BigInt(timelockMs);
  const expiresAtMs = executableAtMs + BigInt(ttlMs);

  const newQueued = new Constr(0, [
    actionId,
    new Constr(actionKind, []),
    targetHash,
    "",
    payloadHashHex,
    upperMsQueue,
    executableAtMs,
    expiresAtMs,
  ]);
  const newGovDatumQ = Data.to(buildGovDatum({
    ...g,
    signerLastQualified: newSignerLastQ,
    queued: [newQueued, ...g.queued],
    nonce: g.nonce + 1n,
  }) as unknown as Data);

  const redeemerQueue = Data.to(new Constr(0, [
    new Constr(actionKind, []),
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
    .collectFrom([stripLucidDatumFields(govIn)], redeemerQueue)
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

  // localUPLCEval:false
  // routes Plutus script eval through the active provider (Blockfrost
  // /utils/txs/evaluate or Ogmios evaluateTransaction). Mandatory because
  // (a) Lucid local UPLC eval has a generic-crash bug that masks real
  // failures as "Spend[N] the validator crashed", and (b) mainnet has no
  // Ogmios infrastructure — production code must work via Blockfrost only.
  // Provider-eval works identically whether DATASOURCE=BLOCKFROST or KUPMIOS.
  const qc = await queueTx.complete({ localUPLCEval: false });
  const qCbor = await multiSignCbor(qc.toCBOR(), mnemonic, ctx.signingAccounts);
  const queueTxHash = await submitCbor(ctx.bfUrl, ctx.bfKey, qCbor);
  console.log(`  ✅ Queue TX: ${queueTxHash}`);

  await awaitConfirmation(ctx.bfUrl, ctx.bfKey, queueTxHash, "Queue");
  await new Promise((r) => setTimeout(r, 5_000));

  // Wait until executable_at_ms + 120s buffer. The 120s absorbs Preprod
  // chain-tip lag (validating relay's slot ~30-90s behind real wall clock).
  // Without this margin, Execute submit hits OutsideValidityIntervalUTxO
  // because TX validity_range.lower = executable_at + 1s but the chain's
  // current slot is still < executable_at when we submit.
  // Callers that don't follow up with Execute (e.g. Queue+Cancel verifiers)
  // can pass `skipExecutableWait: true` to skip this sleep.
  if (!skipExecutableWait) {
    const waitMs = Number(executableAtMs - BigInt(Date.now()) + 120_000n);
    if (waitMs > 0) {
      console.log(`  sleeping ${waitMs}ms until executable_at + 120s...`);
      await new Promise((r) => setTimeout(r, waitMs));
    }
  }

  // Re-fetch gov to get post-Queue state for the Execute caller
  govIn = await fetchSingleUtxo(lucid, govAddr);
  g = parseGovDatum(govIn.datum!);

  return { actionId, queueTxHash, executableAtMs, expiresAtMs, gov: g };
}

/**
 * Build an Execute TX body that refreshes the GovDatum (nonce++, remove
 * the action from queued, bump signerLastQualified for participating
 * signers). The caller fills in the action-specific side (vault spend,
 * stake withdraw, etc.) and submits the TX.
 */
export interface ExecuteContext {
  ctx: GovCtx;
  actionId: string;
  /** Validity range (ms since epoch), both slot-aligned to 1000ms. */
  lowerMs: bigint;
  upperMs: bigint;
  gov: GovDatumParsed;
  govIn: UTxO;
  govAddr: string;
  /** Built MultisigGov ExecuteAction redeemer (Constr(2, [action_id])) */
  redeemerExec: string;
  /** Built post-Execute GovDatum CBOR */
  newGovDatumE: string;
}

export async function prepareExecute(
  ctx: GovCtx,
  actionId: string,
  qResult: QueueResult,
  /** Optional override for the TX validity lower bound (ms since epoch).
   * Callers that need last_update_time = lower_bound (e.g. UpdateRegistry)
   * pass this to pin the lower bound explicitly. Slot-aligned inside. */
  overrideLowerMs?: bigint,
): Promise<ExecuteContext> {
  const { lucid, state, mnemonic } = ctx;
  const govAddr = state.stateUtxos.governance.address;

  // Re-fetch gov UTxO with polling — Blockfrost address-utxos indexer
  // commonly lags awaitTx by 30-90s, so the post-Queue gov state may
  // not be visible immediately after `await lucid.awaitTx(queueTxHash)`.
  // awaitGovActionInQueue polls every 5s up to 120s for the action_id
  // to appear in the queued list (returns govIn + g + queuedForExec in
  // one decode pass).
  const { govIn, g, queuedForExec } = await awaitGovActionInQueue(lucid, govAddr, actionId);
  console.log(`  gov (post-Queue): nonce=${g.nonce}, queued.length=${g.queued.length}`);

  const qf = queuedForExec.fields as any[];
  const execExecutableAt = qf[6] as bigint;
  const execExpiresAt = qf[7] as bigint;

  // Validity range: max(now-margin, execExecutableAt + 1s) ≤ lower ≤ upper
  // < expires, width ≤ 1h. The 120-second past margin absorbs Preprod
  // chain-tip lag (relays validating TXs at slots 30-120s behind real time).
  // Without it, TX builds with lower=now and submit hits
  // OutsideValidityIntervalUTxO when the validating relay's slot is < lower.
  // 300s timeout (bumped from 120s after observing 271s wall-clock on
  // wall-clock-vs-relay lag (chain slot 271s behind real time when submit
  // fired post-cooldown sleep). Preprod relays normally 30-90s behind
  // UpdateRegistry Execute under load).
  // not unprecedented under load. 300s margin keeps the submit succeed
  // rate ~100% across observed lag distribution; cost is +180s wait per
  // Execute. Conservative > flaky.
  const PREPROD_LAG_MARGIN_MS = 300_000n;
  const slotAlign = (ms: bigint) => (ms / 1000n) * 1000n;
  const nowMs = BigInt(Date.now());
  const nowWithLag = nowMs - PREPROD_LAG_MARGIN_MS;
  const lowerRaw = overrideLowerMs !== undefined
    ? overrideLowerMs
    : (nowWithLag > execExecutableAt + 1000n ? nowWithLag : execExecutableAt + 1000n);
  const lowerMs = slotAlign(lowerRaw);
  // If caller overrides the lower bound, wait until lowerMs + lag margin.
  // The lag margin (= 120s, same value as the past-margin in the non-override
  // branch) absorbs Preprod chain-tip lag — relays commonly validate TXs
  // 30-90s behind wall-clock, so submitting at lowerMs + 2s real time
  // hits OutsideValidityIntervalUTxO when the relay's slot < lowerMs.
  // `+ 2000n` was too tight for UpdateRegistry's
  // override path; observed 28-slot relay lag → submit reject.
  const overrideTarget = overrideLowerMs !== undefined ? lowerMs + PREPROD_LAG_MARGIN_MS : 0n;
  if (overrideLowerMs !== undefined && overrideTarget > BigInt(Date.now())) {
    const waitMs = Number(overrideTarget - BigInt(Date.now()));
    if (waitMs > 0) {
      console.log(`  sleeping ${waitMs}ms until override lower bound ${lowerMs} + ${Number(PREPROD_LAG_MARGIN_MS)/1000}s lag margin...`);
      await new Promise((r) => setTimeout(r, waitMs));
    }
  }
  let upperMs = slotAlign(lowerMs + BigInt(30 * 60_000));
  if (upperMs >= execExpiresAt) {
    upperMs = slotAlign(execExpiresAt - 1000n);
    if (upperMs - lowerMs < 60_000n) throw new Error("action expired — not enough window left");
  }
  // Cap width at 1h (contract's max_validity_range_ms = 3_600_000).
  if (upperMs - lowerMs > 3_600_000n) upperMs = lowerMs + 3_600_000n;
  console.log(`  validity range: [${lowerMs}, ${upperMs}]`);

  const sigIdx = await deriveSignerAccountIndices(mnemonic, g.signers);
  const newSignerLastE = g.signers.map((_, i) =>
    ctx.signingAccounts.includes(sigIdx[i]) ? upperMs : g.signerLastQualified[i],
  );
  const newQueuedE = g.queued.filter((q: any) => (q.fields[0] as string).toLowerCase() !== actionId.toLowerCase());

  const newGovDatumE = Data.to(buildGovDatum({
    ...g,
    signerLastQualified: newSignerLastE,
    queued: newQueuedE,
    nonce: g.nonce + 1n,
  }) as unknown as Data);

  const redeemerExec = Data.to(new Constr(2, [actionId]) as unknown as Data);

  return { ctx, actionId, lowerMs, upperMs, gov: g, govIn, govAddr, redeemerExec, newGovDatumE };
}

/**
 * Compute the reward address for a staking validator, given its script hash.
 * vault_gov_policy, vault_gov_emergency, vault_admin_deploy, etc. all expose
 * their state-mutation redeemer via the Withdraw-Zero Forwarding Pattern —
 * spending only the vault UTXO via the proxy is not enough; the staking
 * validator's 0-ADA withdrawal must also be authorised.
 */
export function stakingRewardAddress(scriptHashHex: string, network: "Preprod" | "Mainnet"): string {
  const scriptHash = CML.ScriptHash.from_hex(scriptHashHex);
  const cred = CML.Credential.new_script(scriptHash);
  const net = network === "Preprod" ? 0 : 1;
  const rewardAddr = CML.RewardAddress.new(net, cred);
  return rewardAddr.to_address().to_bech32(undefined);
}

/**
 * Fetch multiple ref-script UTxOs in one Blockfrost call.
 */
export async function fetchRefInputs(
  lucid: LucidEvolution,
  refScripts: { txHash: string; outputIndex: number }[],
): Promise<UTxO[]> {
  const utxos = await lucid.utxosByOutRef(refScripts);
  if (utxos.length !== refScripts.length) {
    throw new Error(`expected ${refScripts.length} ref UTxOs, got ${utxos.length}`);
  }
  return utxos;
}
