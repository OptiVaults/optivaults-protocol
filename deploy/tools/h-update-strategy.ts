/**
 * H-UpdateStrategy Queue + Execute.
 *
 * ActionKind = 0. Target = vault_gov_policy (govPolicyStakeHash).
 * Payload = (new_allocations, new_buffer_target_bps).
 *
 * VaultRedeemer.UpdateStrategy = Constr(10, [new_allocations, new_buffer_target_bps])
 * ProxyRedeemer.UseGovPolicy = Constr(6, [])
 *
 * For initial Preprod E2E against v1-preprod-p4, changes buffer_target_bps
 * from the deploy default 3500 → 2500, keeps allocations=[] (no Liqwid
 * markets registered yet at this stage of the session).
 *
 * Usage:
 *   npx tsx deploy/tools/h-update-strategy.ts --releaseTag <release-tag> \
 *     --bufferTargetBps 2500
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import { Constr, Data } from "@lucid-evolution/lucid";
import { blake2b } from "@noble/hashes/blake2b";

import {
  initGovCtx,
  queueAction,
  prepareExecute,
  fetchVaultUtxoWithNft,
  stakingRewardAddress,
  fetchRefInputs,
  multiSignCbor,
  submitCbor,
  awaitConfirmation,
  stripLucidDatumFields,
} from "./lib/gov-helpers.js";

const ACTION_KIND_UPDATE_STRATEGY = 0;
// VaultRedeemer Constr indices below are the on-chain values at this commit;
// verify against `contracts/lib/vault/types.ak::VaultRedeemer` if you fork.
const VAULT_REDEEMER_UPDATE_STRATEGY = 11;
const PROXY_USE_GOV_POLICY = 6;
const TIMELOCK_MS = 7 * 86_400 * 1_000; // 7d production (matches constants.ak)
const TTL_MS = 86_400_000;

function parseStratArgs(): { bufferTargetBps: bigint; allocations: any[] } {
  const a = process.argv.slice(2);
  let bufferTargetBps: bigint | null = null;
  // Allocations: default empty. If we want to test non-empty allocations
  // later we'd accept a JSON list via --allocationsFile. For now,
  // buffer-only flows cover the primary UpdateStrategy path.
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--bufferTargetBps") bufferTargetBps = BigInt(a[++i]);
  }
  if (bufferTargetBps === null) bufferTargetBps = 2500n;
  if (bufferTargetBps < 500n || bufferTargetBps > 5000n) {
    throw new Error(`bufferTargetBps ${bufferTargetBps} outside [500, 5000]`);
  }
  return { bufferTargetBps, allocations: [] };
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
 * payload_hash_update_strategy = blake2b_256(cbor.serialise((allocations, bufferTargetBps)))
 *
 * Aiken indef-length list encoding (NOT Constr-wrapped). Outer tuple
 * `9f <allocations-list-cbor> <bufferTargetBps-int> ff`. Each Allocation
 * inside `allocations` is a Constr (already produced by Lucid's Data.to).
 */
function payloadHashUpdateStrategy(allocations: any[], bufferTargetBps: bigint): string {
  const innerListCbor = Data.to(allocations as unknown as never);
  const bytes = Buffer.concat([
    Buffer.from([0x9f]),
    Buffer.from(innerListCbor, "hex"),
    cborSerialiseInt(bufferTargetBps),
    Buffer.from([0xff]),
  ]);
  return Buffer.from(blake2b(bytes, { dkLen: 32 })).toString("hex");
}

async function main() {
  const { bufferTargetBps, allocations } = parseStratArgs();
  console.log(`H-UpdateStrategy: bufferTargetBps=${bufferTargetBps}, allocations.length=${allocations.length}`);

  const ctx = await initGovCtx();
  const { state, lucid, network, bfUrl, bfKey, mnemonic } = ctx;
  console.log(`wallet: ${ctx.wallet.slice(0, 30)}…`);

  const targetHash = state.hashes.govPolicyStakeHash;
  if (!targetHash) throw new Error("govPolicyStakeHash not in state");
  console.log(`target (vault_gov_policy): ${targetHash}`);

  const payloadHashHex = payloadHashUpdateStrategy(allocations, bufferTargetBps);
  console.log(`payload_hash: ${payloadHashHex}`);

  // ─── Queue (idempotent) ──────────────────────────────────────────────
  const qResult = await queueAction({
    ctx,
    actionKind: ACTION_KIND_UPDATE_STRATEGY,
    targetHash,
    payloadHashHex,
    timelockMs: TIMELOCK_MS,
    ttlMs: TTL_MS,
    label: "UpdateStrategy",
  });

  // ─── Execute ─────────────────────────────────────────────────────────
  console.log(`\n=== Step 2: Execute UpdateStrategy ===`);
  const ec = await prepareExecute(ctx, qResult.actionId, qResult);

  const vaultUtxo = await fetchVaultUtxoWithNft(lucid, state);
  console.log(`  vault UTxO: ${vaultUtxo.txHash.slice(0, 16)}…#${vaultUtxo.outputIndex}`);

  const oldVaultDatum = Data.from(vaultUtxo.datum!) as any;
  const oldFields = oldVaultDatum.fields as any[];
  // Update indices: 8 (strategy_allocations), 13 (buffer_target_bps)
  const newFields = [...oldFields];
  newFields[8] = allocations;
  newFields[13] = bufferTargetBps;
  const newVaultDatum = Data.to(new Constr(0, newFields as unknown as never[]) as unknown as never);

  const vaultRedeemer = Data.to(
    new Constr(VAULT_REDEEMER_UPDATE_STRATEGY, [allocations, bufferTargetBps]) as unknown as Data,
  );
  const proxyRedeemer = Data.to(new Constr(PROXY_USE_GOV_POLICY, []) as unknown as Data);

  const refs = await fetchRefInputs(lucid, [
    { txHash: state.refScripts.multisigGov.txHash, outputIndex: state.refScripts.multisigGov.outputIndex },
    { txHash: state.refScripts.vaultProxy.txHash, outputIndex: state.refScripts.vaultProxy.outputIndex },
    { txHash: state.refScripts.vaultGovPolicy.txHash, outputIndex: state.refScripts.vaultGovPolicy.outputIndex },
  ]);

  const govPolicyRewardAddr = stakingRewardAddress(targetHash, network);
  const vaultAddr = state.stateUtxos.vault.address;

  const execTx = lucid
    .newTx()
    .collectFrom([stripLucidDatumFields(ec.govIn)], ec.redeemerExec)
    .collectFrom([stripLucidDatumFields(vaultUtxo)], proxyRedeemer)
    .withdraw(govPolicyRewardAddr, 0n, vaultRedeemer)
    .readFrom(refs)
    .pay.ToAddressWithData(
      ec.govAddr,
      { kind: "inline", value: ec.newGovDatumE as unknown as string },
      ec.govIn.assets,
    )
    .pay.ToContract(
      vaultAddr,
      { kind: "inline", value: newVaultDatum as unknown as string },
      vaultUtxo.assets,
    )
    .validFrom(Number(ec.lowerMs))
    .validTo(Number(ec.upperMs))
    .addSignerKey(ec.gov.signers[0])
    .addSignerKey(ec.gov.signers[1]);

  const built = await execTx.complete({ localUPLCEval: false });
  const eCbor = await multiSignCbor(built.toCBOR(), mnemonic, ctx.signingAccounts);
  const execTxHash = await submitCbor(bfUrl, bfKey, eCbor);
  console.log(`  ✅ Execute TX: ${execTxHash}`);

  await awaitConfirmation(bfUrl, bfKey, execTxHash, "Execute", 180);

  console.log(`\nPASS — H-UpdateStrategy Queue+Execute`);
  if (qResult.queueTxHash) console.log(`  queue:   ${qResult.queueTxHash}`);
  console.log(`  execute: ${execTxHash}`);
  console.log(`  action_id: ${qResult.actionId}`);
  console.log(`  applied: bufferTargetBps=${bufferTargetBps}, allocations=[]`);
}

main().catch((e) => {
  console.error("[ERROR]", (e as Error).message);
  if ((e as Error).stack) console.error((e as Error).stack);
  process.exit(1);
});
