/**
 * Phase B (datum-backdate) pre-queue helpers — Preprod only.
 *
 * Allows the deploy ceremony to write QueuedAction records directly into
 * GovDatum at GovInit time, with backdated `queued_at_ms` so the
 * production timelock has effectively elapsed by deploy completion. This
 * lets Preprod E2E exercise the Execute path of high-frequency governance
 * redeemers (UpdateFee / UpdateStrategy / UpdateFeeSplit / UpdateRegistry)
 * within a single session, without waiting 7-21d for real timelock to
 * expire.
 *
 * Mirrors Aiken's `compute_action_id` formula (multisig_gov.ak:88-104) +
 * the per-redeemer `payload_hash_*` helpers in lib/vault/helpers.ak. The
 * payload-hash helpers must produce byte-identical hashes to the on-chain
 * Aiken side or the Execute will fail validation (action_id mismatch
 * between pre-queued record and what gov state-machine recomputes via
 * `is_gov_authorized`).
 *
 * NOT for mainnet — guard via `cfg.network === "Preprod"`.
 */

import { Constr, Data } from "@lucid-evolution/lucid";
import { blake2b } from "@noble/hashes/blake2b";
import type { PrequeuedAction } from "./datumBuilders.js";

/**
 * Aiken `cbor.serialise(Int)` canonical encoding (CBOR major type 0/1).
 * Mirrors gov-helpers.cborSerialiseInt + h-emergency-benign.cborSerialiseInt.
 */
export function cborSerialiseInt(n: bigint): Buffer {
  if (n < 0n) {
    const abs = -1n - n;
    if (abs < 24n) return Buffer.from([0x20 | Number(abs)]);
    if (abs < 256n) return Buffer.from([0x38, Number(abs)]);
    if (abs < 65536n) {
      const b = Buffer.alloc(3); b[0] = 0x39; b.writeUInt16BE(Number(abs), 1); return b;
    }
    if (abs < 4294967296n) {
      const b = Buffer.alloc(5); b[0] = 0x3a; b.writeUInt32BE(Number(abs), 1); return b;
    }
    const b = Buffer.alloc(9); b[0] = 0x3b; b.writeBigUInt64BE(abs, 1); return b;
  }
  if (n < 24n) return Buffer.from([Number(n)]);
  if (n < 256n) return Buffer.from([0x18, Number(n)]);
  if (n < 65536n) {
    const b = Buffer.alloc(3); b[0] = 0x19; b.writeUInt16BE(Number(n), 1); return b;
  }
  if (n < 4294967296n) {
    const b = Buffer.alloc(5); b[0] = 0x1a; b.writeUInt32BE(Number(n), 1); return b;
  }
  const b = Buffer.alloc(9); b[0] = 0x1b; b.writeBigUInt64BE(n, 1); return b;
}

const blake2b256Hex = (b: Buffer): string =>
  Buffer.from(blake2b(b, { dkLen: 32 })).toString("hex");

/** Aiken indef-length CBOR list `9f <items> ff` — for tuple cbor.serialise. */
function cborTuple(items: Buffer[]): Buffer {
  return Buffer.concat([Buffer.from([0x9f]), ...items, Buffer.from([0xff])]);
}

/**
 * ActionKind Constr index → kind byte tag.
 * Matches multisig_gov.ak::action_kind_byte switch.
 */
export const ACTION_KIND_BYTE: Record<number, number> = {
  0: 0x01,  // ActUpdateStrategy
  1: 0x02,  // ActUpdateFee
  2: 0x03,  // ActUpdateFeeSplit
  3: 0x0f,  // ActUpdateSlippagePolicy
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
 * action_id = blake2b_256(
 *   kind_byte || target_script || payload_hash ||
 *   cbor(queued_at_ms) || cbor(nonce)
 * )
 * Mirrors multisig_gov.ak::compute_action_id.
 */
export function computeActionIdHex(
  actionKindIdx: number,
  targetScriptHex: string,
  payloadHashHex: string,
  queuedAtMs: bigint,
  nonce: bigint,
): string {
  const byteTag = ACTION_KIND_BYTE[actionKindIdx];
  if (byteTag === undefined) {
    throw new Error(`Unknown action kind variant ${actionKindIdx}`);
  }
  const bytes = Buffer.concat([
    Buffer.from([byteTag]),
    Buffer.from(targetScriptHex, "hex"),
    Buffer.from(payloadHashHex, "hex"),
    cborSerialiseInt(queuedAtMs),
    cborSerialiseInt(nonce),
  ]);
  return blake2b256Hex(bytes);
}

// ─────────────────────────────────────────────────────────────────────
// Per-redeemer payload-hash helpers (Aiken `payload_hash_*` mirror)
// ─────────────────────────────────────────────────────────────────────

export function payloadHashUpdateFee(
  perfBps: bigint,
  earlyBps: bigint,
  minHold: bigint,
): string {
  return blake2b256Hex(cborTuple([
    cborSerialiseInt(perfBps),
    cborSerialiseInt(earlyBps),
    cborSerialiseInt(minHold),
  ]));
}

export function payloadHashUpdateFeeSplit(
  keeperBps: bigint,
  govBps: bigint,
): string {
  return blake2b256Hex(cborTuple([
    cborSerialiseInt(keeperBps),
    cborSerialiseInt(govBps),
  ]));
}

/**
 * UpdateStrategy payload: `cbor.serialise((new_allocations, new_buffer_target_bps))`
 * (allocations FIRST, buffer SECOND — matches lib/vault/helpers.ak:707-712).
 *
 * Verified via Aiken `cbor_test.ak`: `cbor.serialise(([], 2500))` =
 * `9F801909C4FF` — Aiken uses INDEF for the outer tuple but CANONICAL
 * (`80`) for the empty inner List, matching Lucid's `Data.to([])`. This
 * matters because h-update-strategy.ts uses `Data.to([])` and the
 * validator uses Aiken's `cbor.serialise` — they DO agree on the empty
 * list encoding (canonical `80`), even though tuple wrappers are indef.
 */
export function payloadHashUpdateStrategy(
  allocations: { tokenPolicy: string; tokenName: string; protocol: number; amount: bigint }[],
  bufferTargetBps: bigint,
): string {
  const innerListCbor =
    allocations.length === 0
      ? Buffer.from("80", "hex") // canonical CBOR empty array — matches Aiken + Lucid
      : Buffer.from(
          Data.to(
            allocations.map(
              (a) =>
                new Constr(0, [a.tokenPolicy, a.tokenName, BigInt(a.protocol), a.amount]),
            ) as unknown as never,
          ),
          "hex",
        );
  return blake2b256Hex(
    cborTuple([innerListCbor, cborSerialiseInt(bufferTargetBps)]),
  );
}

/** Aiken list `[a, b, c]` → indef-length CBOR list `9f <a> <b> <c> ff`. */
function serialiseList(items: Buffer[]): Buffer {
  return Buffer.concat([Buffer.from([0x9f]), ...items, Buffer.from([0xff])]);
}

/** UpdateRegistry payload: blake2b_256(cbor.serialise(new_registry_datum)).
 *  For pre-queue we use a placeholder hash; the Execute would need the
 *  actual new_registry CBOR. Caller responsibility to ensure consistency.
 *  This helper just hashes the supplied 32-byte placeholder. */
export function payloadHashUpdateRegistryFromHash(placeholderHash32Hex: string): string {
  if (!/^[0-9a-f]{64}$/i.test(placeholderHash32Hex)) {
    throw new Error("payloadHashUpdateRegistryFromHash expects 32-byte hex");
  }
  return placeholderHash32Hex.toLowerCase();
}

/**
 * DeregisterStake payload: `blake2b_256(cbor.serialise(target_hash))`.
 * target_hash is the 28-byte staking validator script hash. CBOR
 * serialisation: `0x58 0x1c <28 bytes>` (major-type-2 bytestring, length=28).
 * Mirrors a2-queue-deregister.ts:133-136.
 */
export function payloadHashDeregisterStake(targetHashHex: string): string {
  const raw = Buffer.from(targetHashHex, "hex");
  if (raw.length !== 28) {
    throw new Error(`target hash must be 28 bytes, got ${raw.length}`);
  }
  return blake2b256Hex(Buffer.concat([Buffer.from([0x58, 0x1c]), raw]));
}

// ─────────────────────────────────────────────────────────────────────
// Pre-queue builder (env-driven from phases.ts)
// ─────────────────────────────────────────────────────────────────────

export interface PrequeueEnv {
  /** Days to backdate `queued_at_ms` for UpdateFee. 0 = no pre-queue. */
  feeDays?: number;
  /** Days to backdate UpdateStrategy queued_at_ms. */
  strategyDays?: number;
  /** Days to backdate UpdateFeeSplit queued_at_ms. */
  feeSplitDays?: number;
  /** Days to backdate UpdateRegistry queued_at_ms. */
  registryDays?: number;
  /** Days to backdate DeregisterStake queued_at_ms (target = vaultUser). */
  deregisterDays?: number;
}

export interface PrequeueTargets {
  govPolicyStakeHash: string;
  registryHash: string;
  /** vaultUser stake hash — chosen as the pre-queue test target for
   *  DeregisterStake. Other 11 credentials follow same flow. */
  userStakeHash?: string;
}

const ONE_DAY_MS = 86_400_000n;
// Pre-queued actions need a TTL long enough for Execute to fire after
// deploy completes (validity range check `now < expires_at_ms`). 1d is
// too tight — `expires_at = nowMs - 1d + 14d + 1d = nowMs` so any
// post-deploy wait makes the action immediately expired. 7d gives a
// comfortable post-deploy execution window. gov_max_ttl_ms = 30d cap.
const TTL_MS = 7n * 86_400_000n;
// Production timelock constants (mirror constants.ak post-revert)
const PROD_TIMELOCK = {
  updateStrategy: 7n * ONE_DAY_MS,
  updateFee: 14n * ONE_DAY_MS,
  updateFeeSplit: 21n * ONE_DAY_MS,
  updateRegistry: 14n * ONE_DAY_MS,
  deregisterStake: 14n * ONE_DAY_MS,
};

/**
 * Compute pre-queued actions from env-driven backdate days.
 *
 * Each pre-queued action has:
 *   queued_at_ms = nowMs - days * ONE_DAY_MS  (slot-aligned)
 *   executable_at_ms = queued_at_ms + production_timelock_ms
 *   expires_at_ms = executable_at_ms + ttl_ms
 *
 * Caller (phases.ts) chooses days such that executable_at_ms <= now
 * (Execute fires immediately) and expires_at_ms > now + reasonable buffer
 * for the Execute TX submit to land within window.
 *
 * Default benign payloads (no-op datum):
 *   UpdateFee:        (perfBps=450, earlyBps=10, minHold=60)
 *   UpdateStrategy:   (bufferTargetBps=3000, allocations=[])
 *   UpdateFeeSplit:   (keeperBps=4000, govBps=0)
 *   UpdateRegistry:   placeholder 32-byte hash (Execute won't actually
 *                     fire because new_reg datum hash won't match — used
 *                     only for action_id positional verification, not
 *                     full Execute round-trip)
 */
export function buildPrequeueActions(
  env: PrequeueEnv,
  targets: PrequeueTargets,
  nowMs: number,
): PrequeuedAction[] {
  const slotAlign = (ms: bigint) => (ms / 1000n) * 1000n;
  const actions: PrequeuedAction[] = [];

  // Each pre-queued action uses a distinct nonce (0, 1, 2, 3) for
  // action_id determinism. After all are pre-queued, GovDatum.nonce
  // = actions.length (= next nonce for live QueueAction).
  let nextNonce = 0n;

  if (env.feeDays && env.feeDays > 0) {
    const queuedAtMs = slotAlign(BigInt(nowMs) - BigInt(env.feeDays) * ONE_DAY_MS);
    const executableAtMs = queuedAtMs + PROD_TIMELOCK.updateFee;
    const expiresAtMs = executableAtMs + TTL_MS;
    // Match h-update-fee.ts CLI defaults: perfBps=450, earlyBps=0, minHold=60.
    const payloadHash = payloadHashUpdateFee(450n, 0n, 60n);
    const actionId = computeActionIdHex(
      1, // KIND_UPDATE_FEE
      targets.govPolicyStakeHash,
      payloadHash,
      queuedAtMs,
      nextNonce,
    );
    actions.push({
      actionId,
      actionKindIdx: 1,
      targetScript: targets.govPolicyStakeHash,
      queuedAtMs,
      executableAtMs,
      expiresAtMs,
      payloadHash,
    });
    nextNonce++;
  }

  if (env.strategyDays && env.strategyDays > 0) {
    const queuedAtMs = slotAlign(BigInt(nowMs) - BigInt(env.strategyDays) * ONE_DAY_MS);
    const executableAtMs = queuedAtMs + PROD_TIMELOCK.updateStrategy;
    const expiresAtMs = executableAtMs + TTL_MS;
    // Matches h-update-strategy.ts default: bufferTargetBps=2500, empty allocations.
    const payloadHash = payloadHashUpdateStrategy([], 2500n);
    const actionId = computeActionIdHex(
      0, // KIND_UPDATE_STRATEGY
      targets.govPolicyStakeHash,
      payloadHash,
      queuedAtMs,
      nextNonce,
    );
    actions.push({
      actionId,
      actionKindIdx: 0,
      targetScript: targets.govPolicyStakeHash,
      queuedAtMs,
      executableAtMs,
      expiresAtMs,
      payloadHash,
    });
    nextNonce++;
  }

  if (env.feeSplitDays && env.feeSplitDays > 0) {
    const queuedAtMs = slotAlign(BigInt(nowMs) - BigInt(env.feeSplitDays) * ONE_DAY_MS);
    const executableAtMs = queuedAtMs + PROD_TIMELOCK.updateFeeSplit;
    const expiresAtMs = executableAtMs + TTL_MS;
    // Match h-update-fee-split.ts CLI defaults: keeperBps=4000, govBps=500.
    const payloadHash = payloadHashUpdateFeeSplit(4000n, 500n);
    const actionId = computeActionIdHex(
      2, // KIND_UPDATE_FEE_SPLIT
      targets.govPolicyStakeHash,
      payloadHash,
      queuedAtMs,
      nextNonce,
    );
    actions.push({
      actionId,
      actionKindIdx: 2,
      targetScript: targets.govPolicyStakeHash,
      queuedAtMs,
      executableAtMs,
      expiresAtMs,
      payloadHash,
    });
    nextNonce++;
  }

  if (env.registryDays && env.registryDays > 0) {
    const queuedAtMs = slotAlign(BigInt(nowMs) - BigInt(env.registryDays) * ONE_DAY_MS);
    const executableAtMs = queuedAtMs + PROD_TIMELOCK.updateRegistry;
    const expiresAtMs = executableAtMs + TTL_MS;
    // Placeholder payload hash — UpdateRegistry payload is the FULL new
    // RegistryDatum hash, which depends on what tool computes when
    // running. For pre-queue we use a known fixed value the tool can
    // match by reading the pre-queue from state file.
    const payloadHash = "1".repeat(64);
    const actionId = computeActionIdHex(
      6, // KIND_UPDATE_REGISTRY
      targets.registryHash,
      payloadHash,
      queuedAtMs,
      nextNonce,
    );
    actions.push({
      actionId,
      actionKindIdx: 6,
      targetScript: targets.registryHash,
      queuedAtMs,
      executableAtMs,
      expiresAtMs,
      payloadHash,
    });
    nextNonce++;
  }

  if (env.deregisterDays && env.deregisterDays > 0) {
    if (!targets.userStakeHash) {
      throw new Error("buildPrequeueActions: deregisterDays requires targets.userStakeHash");
    }
    const queuedAtMs = slotAlign(BigInt(nowMs) - BigInt(env.deregisterDays) * ONE_DAY_MS);
    const executableAtMs = queuedAtMs + PROD_TIMELOCK.deregisterStake;
    const expiresAtMs = executableAtMs + TTL_MS;
    const payloadHash = payloadHashDeregisterStake(targets.userStakeHash);
    const actionId = computeActionIdHex(
      13, // KIND_DEREGISTER_STAKE
      targets.userStakeHash,
      payloadHash,
      queuedAtMs,
      nextNonce,
    );
    actions.push({
      actionId,
      actionKindIdx: 13,
      targetScript: targets.userStakeHash,
      queuedAtMs,
      executableAtMs,
      expiresAtMs,
      payloadHash,
    });
    nextNonce++;
  }

  return actions;
}
