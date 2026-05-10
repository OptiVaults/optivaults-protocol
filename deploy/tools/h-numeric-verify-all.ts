/**
 * Phase A — numeric timelock verification across all governance action kinds.
 *
 * Per `deploy/runbooks/v1-mainnet-ceremony.md §2.5 A`. Iterates each
 * ActionKind, submits a Queue TX with `timelock_ms` set to the production
 * constant value, decodes the resulting on-chain queued action's
 * `queued_at_ms` + `executable_at_ms`, asserts
 *   `executable_at_ms - queued_at_ms == production_timelock_ms`
 * (verifying both that the validator accepted the production timelock AND
 * that off-chain encoding committed exactly the expected value), then
 * cancels with 1-of-n to free the slot for the next kind.
 *
 * Skips Execute entirely — production timelocks are 7-21d, ceremony B
 * (datum-backdate) handles the Execute path for high-frequency kinds.
 *
 * Requires a fresh ceremony with constants.ak at production values.
 *
 * Usage:
 *   npx tsx deploy/tools/h-numeric-verify-all.ts --releaseTag <release-tag>
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import { Constr, Data } from "@lucid-evolution/lucid";
import { blake2b } from "@noble/hashes/blake2b";
import {
  initGovCtx,
  queueAction,
  fetchSingleUtxo,
  parseGovDatum,
  buildGovDatum,
  multiSignCbor,
  submitCbor,
  awaitConfirmation,
  stripLucidDatumFields,
  cborSerialiseInt,
  deriveSignerAccountIndices,
  type GovCtx,
} from "./lib/gov-helpers.js";

// ─────────────────────────────────────────────────────────────────────
// Production timelock constants (mirror of contracts/lib/vault/constants.ak)
// ─────────────────────────────────────────────────────────────────────
const MS_PER_HOUR = 3_600_000n;
const MS_PER_DAY = 86_400_000n;

// Aiken ActionKind Constr indices (declaration order in lib/vault/types.ak).
// IMPORTANT: ActUpdateSlippagePolicy sits at Constr 3 (between UpdateFeeSplit
// and EmergencyWithdraw) — not at the end as one might assume from its
// chronological introduction. Mismatch caught against h-update-slippage-policy.ts
// + smoke-test tools at integration time.
const KIND_UPDATE_STRATEGY = 0;
const KIND_UPDATE_FEE = 1;
const KIND_UPDATE_FEE_SPLIT = 2;
const KIND_UPDATE_SLIPPAGE_POLICY = 3;
const KIND_EMERGENCY_WITHDRAW = 4;
const KIND_ADMIN_DEPLOY_NON_DEPOSIT = 5;
const KIND_UPDATE_REGISTRY = 6;
const KIND_FAST_UPDATE_MARKETS = 7;
const KIND_UPDATE_KEEPER_AUTH = 8;
const KIND_TREASURY_SPEND = 9;
const KIND_UPDATE_TREASURY_PARAMS = 10;
const KIND_ROTATE_SIGNERS = 11;
const KIND_SLASH_BOND = 12;
const KIND_DEREGISTER_STAKE = 13;

interface KindSpec {
  kind: number;
  name: string;
  expectedMs: bigint;
  /** Target script (which validator handles this action). Lookup key in state.hashes. */
  targetField: string;
  /** Build a benign payload + return blake2b256 hex. */
  payloadHashFn: () => string;
}

/** CBOR indef-length list `9f <items> ff` — matches Aiken `cbor.serialise((tuple))`. */
function cborTuple(items: Buffer[]): Buffer {
  return Buffer.concat([Buffer.from([0x9f]), ...items, Buffer.from([0xff])]);
}

function cborByteString(bytes: Buffer | string): Buffer {
  const b = typeof bytes === "string" ? Buffer.from(bytes, "hex") : bytes;
  if (b.length < 24) return Buffer.concat([Buffer.from([0x40 + b.length]), b]);
  if (b.length < 256) return Buffer.concat([Buffer.from([0x58, b.length]), b]);
  if (b.length < 65536) {
    const hdr = Buffer.alloc(3);
    hdr[0] = 0x59;
    hdr.writeUInt16BE(b.length, 1);
    return Buffer.concat([hdr, b]);
  }
  throw new Error("byte string too large");
}

function blake2b256Hex(b: Buffer): string {
  return Buffer.from(blake2b(b, { dkLen: 32 })).toString("hex");
}

const PLACEHOLDER_28 = Buffer.alloc(28);
const PLACEHOLDER_32 = Buffer.alloc(32);

/**
 * Benign payload-hash builders, one per ActionKind. Mirrors the Aiken
 * helpers in lib/vault/helpers.ak. Content is intentionally placeholder —
 * Cancel runs before Execute so payload validity is irrelevant; only the
 * 32-byte length matters. Determinism + uniqueness across kinds matters for
 * queueAction's idempotency check.
 */
const KIND_SPECS: KindSpec[] = [
  {
    kind: KIND_UPDATE_STRATEGY,
    name: "UpdateStrategy",
    expectedMs: 7n * MS_PER_DAY,
    targetField: "govPolicyStakeHash",
    // payload: (buffer_target_bps, allocations[]) — we use 3500 + empty list
    payloadHashFn: () => {
      // (3500, [])  ≡  9f <19 0DAC> 9fff ff
      const inner = cborTuple([cborSerialiseInt(3500n), Buffer.from([0x9f, 0xff])]);
      return blake2b256Hex(inner);
    },
  },
  {
    kind: KIND_UPDATE_FEE,
    name: "UpdateFee",
    expectedMs: 14n * MS_PER_DAY,
    targetField: "govPolicyStakeHash",
    payloadHashFn: () =>
      blake2b256Hex(
        cborTuple([cborSerialiseInt(450n), cborSerialiseInt(10n), cborSerialiseInt(60n)]),
      ),
  },
  {
    kind: KIND_UPDATE_FEE_SPLIT,
    name: "UpdateFeeSplit",
    expectedMs: 21n * MS_PER_DAY,
    targetField: "govPolicyStakeHash",
    payloadHashFn: () =>
      blake2b256Hex(cborTuple([cborSerialiseInt(4000n), cborSerialiseInt(0n)])),
  },
  {
    kind: KIND_EMERGENCY_WITHDRAW,
    name: "EmergencyWithdraw",
    expectedMs: 0n,
    targetField: "govEmergencyStakeHash",
    payloadHashFn: () =>
      blake2b256Hex(cborTuple([cborSerialiseInt(0n), cborSerialiseInt(0n)])),
  },
  {
    kind: KIND_ADMIN_DEPLOY_NON_DEPOSIT,
    name: "AdminDeployNonDeposit",
    expectedMs: 7n * MS_PER_DAY,
    targetField: "adminDeployStakeHash",
    // payload: (asset_policy: 28 bytes, asset_name, amount)
    payloadHashFn: () =>
      blake2b256Hex(
        cborTuple([
          cborByteString(PLACEHOLDER_28),
          cborByteString(Buffer.alloc(0)),
          cborSerialiseInt(1_000_000n),
        ]),
      ),
  },
  {
    kind: KIND_UPDATE_REGISTRY,
    name: "UpdateRegistry",
    expectedMs: 14n * MS_PER_DAY,
    targetField: "registryHash",
    // payload = blake2b_256(cbor.serialise(new_registry_datum)) — full
    // RegistryDatum hash. We use a fixed 32-byte placeholder hash directly
    // (validator only checks length == 32).
    payloadHashFn: () => Buffer.alloc(32, 0x11).toString("hex"),
  },
  {
    kind: KIND_FAST_UPDATE_MARKETS,
    name: "FastUpdateMarkets",
    expectedMs: 1n * MS_PER_HOUR,
    targetField: "registryHash",
    // payload: (market_idx, new_action_addr_hash)
    payloadHashFn: () =>
      blake2b256Hex(
        cborTuple([cborSerialiseInt(0n), cborByteString(PLACEHOLDER_28)]),
      ),
  },
  {
    kind: KIND_UPDATE_KEEPER_AUTH,
    name: "UpdateKeeperAuth",
    expectedMs: 14n * MS_PER_DAY,
    targetField: "keeperStakeHash",
    payloadHashFn: () => Buffer.alloc(32, 0x22).toString("hex"),
  },
  {
    kind: KIND_TREASURY_SPEND,
    name: "TreasurySpend",
    expectedMs: 7n * MS_PER_DAY,
    targetField: "treasuryHash",
    // payload: (category_tag, amount, recipient, audit_invoice_ref)
    payloadHashFn: () =>
      blake2b256Hex(
        cborTuple([
          cborByteString(Buffer.from([0x01])), // category_tag = 0x01 (Audit)
          cborSerialiseInt(1_000_000n),
          cborByteString(PLACEHOLDER_28), // recipient placeholder (Address Data)
          cborByteString(Buffer.alloc(0)), // empty invoice ref
        ]),
      ),
  },
  {
    kind: KIND_UPDATE_TREASURY_PARAMS,
    name: "UpdateTreasuryParams",
    expectedMs: 14n * MS_PER_DAY,
    targetField: "treasuryHash",
    // payload: 8 ints (audit/ops/rd/buffer_bps + cap_*)
    payloadHashFn: () =>
      blake2b256Hex(
        cborTuple([
          cborSerialiseInt(4000n),
          cborSerialiseInt(2500n),
          cborSerialiseInt(2500n),
          cborSerialiseInt(1000n),
          cborSerialiseInt(0n),
          cborSerialiseInt(0n),
          cborSerialiseInt(0n),
          cborSerialiseInt(0n),
        ]),
      ),
  },
  {
    kind: KIND_ROTATE_SIGNERS,
    name: "RotateSigners",
    expectedMs: 14n * MS_PER_DAY,
    targetField: "multisigGovHash",
    payloadHashFn: () => Buffer.alloc(32, 0x33).toString("hex"),
  },
  {
    kind: KIND_SLASH_BOND,
    name: "SlashBond",
    expectedMs: 14n * MS_PER_DAY,
    targetField: "keeperStakeHash",
    // payload: (bond_owner, evidence_ref, slash_amount)
    payloadHashFn: () =>
      blake2b256Hex(
        cborTuple([
          cborByteString(PLACEHOLDER_28),
          cborByteString(Buffer.alloc(0)),
          cborSerialiseInt(1n),
        ]),
      ),
  },
  {
    kind: KIND_DEREGISTER_STAKE,
    name: "DeregisterStake",
    expectedMs: 14n * MS_PER_DAY,
    targetField: "userStakeHash", // any valid 28-byte hash
    // payload: target_hash (single 28-byte field)
    payloadHashFn: () => blake2b256Hex(cborByteString(PLACEHOLDER_28)),
  },
  {
    kind: KIND_UPDATE_SLIPPAGE_POLICY,
    name: "UpdateSlippagePolicy",
    expectedMs: 48n * MS_PER_HOUR,
    targetField: "govPolicyStakeHash",
    payloadHashFn: () =>
      blake2b256Hex(cborTuple([cborSerialiseInt(500n), cborSerialiseInt(9300n)])),
  },
];

const TTL_MS = 86_400_000; // 1d (gov_min_ttl_ms)

interface VerifyResult {
  name: string;
  kind: number;
  expectedMs: bigint;
  actualDeltaMs: bigint | null;
  pass: boolean;
  queueTxHash: string | null;
  cancelTxHash: string | null;
  error?: string;
}

async function cancelAction(
  ctx: GovCtx,
  actionId: string,
): Promise<string> {
  const { lucid, state, mnemonic } = ctx;
  const govAddr = state.stateUtxos.governance.address;
  const govIn = await fetchSingleUtxo(lucid, govAddr);
  const g = parseGovDatum(govIn.datum!);
  const actionIdLower = actionId.toLowerCase();
  const newQueued = g.queued.filter(
    (q: any) => (q.fields[0] as string).toLowerCase() !== actionIdLower,
  );
  if (newQueued.length === g.queued.length) {
    throw new Error(`action ${actionIdLower} not in queue (already cancelled or executed)`);
  }

  // Preprod relay's currentSlot lags real wall-clock by 30-120s. validFrom
  // = Date.now() lands ahead of the chain's slot view → ledger rejects with
  // OutsideValidityIntervalUTxO. Subtract 180s past margin before slot
  // alignment to absorb the lag.
  const slotAlign = (ms: bigint) => (ms / 1000n) * 1000n;
  const lowerMs = slotAlign(BigInt(Date.now()) - 180_000n);
  const upperMs = slotAlign(lowerMs + BigInt(30 * 60_000));

  const ACCOUNTS_TO_SIGN = [0]; // 1-of-n sufficient
  const sigIdx = await deriveSignerAccountIndices(mnemonic, g.signers);
  const newSignerLastQ = g.signers.map((_, i) =>
    ACCOUNTS_TO_SIGN.includes(sigIdx[i]) ? upperMs : g.signerLastQualified[i],
  );

  const newGovDatum = Data.to(
    buildGovDatum({
      ...g,
      signerLastQualified: newSignerLastQ,
      queued: newQueued,
      nonce: g.nonce + 1n,
    }) as unknown as Data,
  );

  const redeemerCancel = Data.to(new Constr(1, [actionIdLower]) as unknown as Data);
  const mgRef = state.refScripts.multisigGov;
  const [mgRefUtxo] = await lucid.utxosByOutRef([
    { txHash: mgRef.txHash, outputIndex: mgRef.outputIndex },
  ]);

  const tx = lucid
    .newTx()
    .collectFrom([stripLucidDatumFields(govIn)], redeemerCancel)
    .readFrom([mgRefUtxo])
    .pay.ToAddressWithData(govAddr, { kind: "inline", value: newGovDatum as unknown as string }, govIn.assets)
    .validFrom(Number(lowerMs))
    .validTo(Number(upperMs))
    .addSignerKey(g.signers[0]);

  const built = await tx.complete({ localUPLCEval: false });
  const signedCbor = await multiSignCbor(built.toCBOR(), mnemonic, ACCOUNTS_TO_SIGN);
  const txHash = await submitCbor(ctx.bfUrl, ctx.bfKey, signedCbor);
  await awaitConfirmation(ctx.bfUrl, ctx.bfKey, txHash, "Cancel", 180);
  return txHash;
}

async function verifyOne(ctx: GovCtx, spec: KindSpec): Promise<VerifyResult> {
  const targetHash = (ctx.state.hashes as any)[spec.targetField];
  if (!targetHash) {
    return {
      name: spec.name,
      kind: spec.kind,
      expectedMs: spec.expectedMs,
      actualDeltaMs: null,
      pass: false,
      queueTxHash: null,
      cancelTxHash: null,
      error: `state.hashes.${spec.targetField} not found`,
    };
  }
  const payloadHash = spec.payloadHashFn();
  console.log(`\n──── ${spec.name} (kind=${spec.kind}, expected timelock=${spec.expectedMs}ms) ────`);

  let queueTxHash: string | null = null;
  let cancelTxHash: string | null = null;
  try {
    const qr = await queueAction({
      ctx,
      actionKind: spec.kind,
      targetHash,
      payloadHashHex: payloadHash,
      timelockMs: Number(spec.expectedMs),
      ttlMs: TTL_MS,
      label: spec.name,
      // Phase A only verifies queued_at_ms / executable_at_ms delta — no
      // Execute, so no need to sleep until executable_at.
      skipExecutableWait: true,
    });
    queueTxHash = qr.queueTxHash;

    // Read back the queued action from on-chain GovDatum and assert
    // executable_at_ms - queued_at_ms == expected timelock.
    const govIn = await fetchSingleUtxo(ctx.lucid, ctx.state.stateUtxos.governance.address);
    const g = parseGovDatum(govIn.datum!);
    const queued = g.queued.find(
      (q: any) => (q.fields[0] as string).toLowerCase() === qr.actionId.toLowerCase(),
    );
    if (!queued) {
      throw new Error(`action ${qr.actionId} not found in gov queue after Queue confirm`);
    }
    const queuedAtMs = (queued.fields[5] as bigint);
    const executableAtMs = (queued.fields[6] as bigint);
    const actualDeltaMs = executableAtMs - queuedAtMs;
    const pass = actualDeltaMs === spec.expectedMs;
    console.log(
      `  queued_at_ms=${queuedAtMs}  executable_at_ms=${executableAtMs}  delta=${actualDeltaMs}ms  ${pass ? "✅ PASS" : "❌ FAIL"}`,
    );

    // Cancel to free slot for next kind.
    cancelTxHash = await cancelAction(ctx, qr.actionId);
    console.log(`  cancel TX: ${cancelTxHash}`);

    return {
      name: spec.name,
      kind: spec.kind,
      expectedMs: spec.expectedMs,
      actualDeltaMs,
      pass,
      queueTxHash,
      cancelTxHash,
    };
  } catch (e) {
    return {
      name: spec.name,
      kind: spec.kind,
      expectedMs: spec.expectedMs,
      actualDeltaMs: null,
      pass: false,
      queueTxHash,
      cancelTxHash,
      error: (e as Error).message,
    };
  }
}

async function main() {
  console.log("=== Phase A — Numeric timelock verification (14 ActionKinds) ===\n");
  const ctx = await initGovCtx();

  // Optional kind filter via --only-kind comma list (e.g. --only-kind UpdateStrategy,UpdateFee)
  const args = process.argv.slice(2);
  let onlyKinds: string[] | null = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--only-kind") {
      onlyKinds = (args[++i] || "").split(",").map((s) => s.trim()).filter(Boolean);
    }
  }
  const specs = onlyKinds ? KIND_SPECS.filter((s) => onlyKinds!.includes(s.name)) : KIND_SPECS;
  if (specs.length === 0) {
    console.error("No matching kinds; use names from KIND_SPECS or omit --only-kind for all.");
    process.exit(1);
  }
  console.log(`Running ${specs.length}/${KIND_SPECS.length} kind(s)\n`);

  const results: VerifyResult[] = [];
  for (const spec of specs) {
    const r = await verifyOne(ctx, spec);
    results.push(r);
  }

  console.log("\n\n══════════════ SUMMARY ══════════════");
  console.log(
    "Kind".padEnd(28) + "Expected (ms)".padStart(16) + "Actual delta (ms)".padStart(20) + "  Result",
  );
  console.log("─".repeat(70));
  let passCount = 0;
  for (const r of results) {
    const expected = r.expectedMs.toString();
    const actual = r.actualDeltaMs == null ? "—" : r.actualDeltaMs.toString();
    const result = r.pass ? "✅ PASS" : "❌ FAIL" + (r.error ? `: ${r.error}` : "");
    console.log(
      r.name.padEnd(28) + expected.padStart(16) + actual.padStart(20) + "  " + result,
    );
    if (r.pass) passCount++;
  }
  console.log("─".repeat(70));
  console.log(`${passCount}/${results.length} passed`);
  if (passCount < results.length) {
    process.exit(1);
  }
}

main().catch((e) => {
  console.error("[FATAL]", (e as Error).message);
  if ((e as Error).stack) console.error((e as Error).stack);
  process.exit(1);
});
