/**
 * H-UpdateFeeSplit Queue + Execute.
 *
 * ActionKind = 2. Target = vault_gov_policy (govPolicyStakeHash).
 * Payload = (new_keeper_fee_bps, new_gov_fee_bps).
 *
 * VaultRedeemer.UpdateFeeSplit = Constr(12, [keeper_bps, gov_bps])
 * ProxyRedeemer.UseGovPolicy = Constr(6, [])
 *
 * Hard caps: keeper ≤ 4000 bps (40%), gov ≤ 1000 bps (10%), keeper+gov ≤ 5000 bps (50%).
 *
 * Primary use-case for E2E: set gov_fee_bps > 0 so subsequent Compound runs
 * accumulate into the gov signer_compensation_pool (precondition for later
 * DistributeSignerCompensation tests).
 *
 * Usage:
 *   npx tsx deploy/tools/h-update-fee-split.ts --releaseTag <release-tag> \
 *     --keeperBps 4000 --govBps 500
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

const ACTION_KIND_UPDATE_FEE_SPLIT = 2;
// VaultRedeemer Constr indices below are the on-chain values at this commit;
// verify against `contracts/lib/vault/types.ak::VaultRedeemer` if you fork.
const VAULT_REDEEMER_UPDATE_FEE_SPLIT = 13;
const PROXY_USE_GOV_POLICY = 6;
const TIMELOCK_MS = 21 * 86_400 * 1_000; // 21d production (matches constants.ak)
const TTL_MS = 86_400_000;

function parseSplitArgs(): { keeperBps: bigint; govBps: bigint } {
  const a = process.argv.slice(2);
  let keeperBps: bigint | null = null;
  let govBps: bigint | null = null;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--keeperBps") keeperBps = BigInt(a[++i]);
    else if (a[i] === "--govBps") govBps = BigInt(a[++i]);
  }
  if (keeperBps === null) keeperBps = 4000n;
  if (govBps === null) govBps = 500n;
  if (keeperBps < 0n || keeperBps > 4000n) throw new Error(`keeperBps ${keeperBps} outside [0, 4000]`);
  if (govBps < 0n || govBps > 1000n) throw new Error(`govBps ${govBps} outside [0, 1000]`);
  if (keeperBps + govBps > 5000n) throw new Error(`keeperBps + govBps > 5000`);
  return { keeperBps, govBps };
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
 * payload_hash_update_fee_split = blake2b_256(cbor.serialise((keeperBps, govBps)))
 *
 * Aiken `cbor.serialise((Int, Int))` emits an indefinite-length CBOR list
 * `9f<a><b>ff` (NOT a Constr-wrapped array). The framing matters — using
 * a Constr-wrapped array here produces a payload_hash that the on-chain
 * validator rejects.
 */
function payloadHashUpdateFeeSplit(keeperBps: bigint, govBps: bigint): string {
  const bytes = Buffer.concat([
    Buffer.from([0x9f]),
    cborSerialiseInt(keeperBps),
    cborSerialiseInt(govBps),
    Buffer.from([0xff]),
  ]);
  return Buffer.from(blake2b(bytes, { dkLen: 32 })).toString("hex");
}

async function main() {
  const { keeperBps, govBps } = parseSplitArgs();
  console.log(`H-UpdateFeeSplit: keeperBps=${keeperBps}, govBps=${govBps}`);

  const ctx = await initGovCtx();
  const { state, lucid, network, bfUrl, bfKey, mnemonic } = ctx;

  const targetHash = state.hashes.govPolicyStakeHash;
  if (!targetHash) throw new Error("govPolicyStakeHash not in state");

  const payloadHashHex = payloadHashUpdateFeeSplit(keeperBps, govBps);
  console.log(`payload_hash: ${payloadHashHex}`);

  const qResult = await queueAction({
    ctx,
    actionKind: ACTION_KIND_UPDATE_FEE_SPLIT,
    targetHash,
    payloadHashHex,
    timelockMs: TIMELOCK_MS,
    ttlMs: TTL_MS,
    label: "UpdateFeeSplit",
  });

  console.log(`\n=== Step 2: Execute UpdateFeeSplit ===`);
  const ec = await prepareExecute(ctx, qResult.actionId, qResult);

  const vaultUtxo = await fetchVaultUtxoWithNft(lucid, state);

  const oldVaultDatum = Data.from(vaultUtxo.datum!) as any;
  const oldFields = oldVaultDatum.fields as any[];
  // Index 14: keeper_fee_bps, 15: gov_fee_bps
  const newFields = [...oldFields];
  newFields[14] = keeperBps;
  newFields[15] = govBps;
  const newVaultDatum = Data.to(new Constr(0, newFields as unknown as never[]) as unknown as never);

  const vaultRedeemer = Data.to(new Constr(VAULT_REDEEMER_UPDATE_FEE_SPLIT, [keeperBps, govBps]) as unknown as Data);
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
    .pay.ToAddressWithData(ec.govAddr, { kind: "inline", value: ec.newGovDatumE as unknown as string }, ec.govIn.assets)
    .pay.ToContract(vaultAddr, { kind: "inline", value: newVaultDatum as unknown as string }, vaultUtxo.assets)
    .validFrom(Number(ec.lowerMs))
    .validTo(Number(ec.upperMs))
    .addSignerKey(ec.gov.signers[0])
    .addSignerKey(ec.gov.signers[1]);

  const built = await execTx.complete({ localUPLCEval: false });
  const eCbor = await multiSignCbor(built.toCBOR(), mnemonic, ctx.signingAccounts);
  const execTxHash = await submitCbor(bfUrl, bfKey, eCbor);
  console.log(`  ✅ Execute TX: ${execTxHash}`);

  await awaitConfirmation(bfUrl, bfKey, execTxHash, "Execute", 180);

  console.log(`\nPASS — H-UpdateFeeSplit Queue+Execute`);
  if (qResult.queueTxHash) console.log(`  queue:   ${qResult.queueTxHash}`);
  console.log(`  execute: ${execTxHash}`);
  console.log(`  action_id: ${qResult.actionId}`);
  console.log(`  applied: keeperBps=${keeperBps}, govBps=${govBps}`);
}

main().catch((e) => {
  console.error("[ERROR]", (e as Error).message);
  if ((e as Error).stack) console.error((e as Error).stack);
  process.exit(1);
});
