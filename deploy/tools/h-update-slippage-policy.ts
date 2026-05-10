/**
 * H-UpdateSlippagePolicy Queue + Execute (§5.4 governance-gated swap policy).
 *
 * ActionKind = 3. Target = vault_gov_policy (govPolicyStakeHash).
 * Payload = (new_max_slippage_bps, new_min_swap_peg_bps).
 *
 * VaultRedeemer.UpdateSlippagePolicy = Constr(13, [max_slip, min_peg])
 * ProxyRedeemer.UseGovPolicy = Constr(6, [])
 *
 * Validator-enforced caps:
 *   - max_slippage_bps ∈ [0, 500]  (5% ceiling)
 *   - min_swap_peg_bps ∈ [9300, 9950]  (93%–99.5% window)
 *
 * Preprod timelock override = 60s (production = 48h).
 *
 * Usage:
 *   npx tsx deploy/tools/h-update-slippage-policy.ts --releaseTag <release-tag> \
 *     --maxSlippageBps 150 --minSwapPegBps 9800
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
} from "./lib/gov-helpers.js";

const ACTION_KIND_UPDATE_SLIPPAGE = 3;
// VaultRedeemer Constr indices below are the on-chain values at this commit;
// verify against `contracts/lib/vault/types.ak::VaultRedeemer` if you fork.
const VAULT_REDEEMER_UPDATE_SLIPPAGE = 14;
const PROXY_USE_GOV_POLICY = 6;
const TIMELOCK_MS = 60_000;
const TTL_MS = 86_400_000;

function parseSlipArgs(): { maxSlippageBps: bigint; minSwapPegBps: bigint } {
  const a = process.argv.slice(2);
  let maxSlippageBps: bigint | null = null;
  let minSwapPegBps: bigint | null = null;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--maxSlippageBps") maxSlippageBps = BigInt(a[++i]);
    else if (a[i] === "--minSwapPegBps") minSwapPegBps = BigInt(a[++i]);
  }
  if (maxSlippageBps === null) maxSlippageBps = 150n;
  if (minSwapPegBps === null) minSwapPegBps = 9800n;
  if (maxSlippageBps < 0n || maxSlippageBps > 500n)
    throw new Error(`maxSlippageBps ${maxSlippageBps} outside [0, 500]`);
  if (minSwapPegBps < 9300n || minSwapPegBps > 9950n)
    throw new Error(`minSwapPegBps ${minSwapPegBps} outside [9300, 9950]`);
  return { maxSlippageBps, minSwapPegBps };
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
 * payload_hash_update_slippage = blake2b_256(cbor.serialise((maxSlipBps, minPegBps)))
 * Aiken indef-length list encoding (NOT Constr-wrapped). See gov-helpers.ts.
 */
function payloadHashUpdateSlippage(maxSlipBps: bigint, minPegBps: bigint): string {
  const bytes = Buffer.concat([
    Buffer.from([0x9f]),
    cborSerialiseInt(maxSlipBps),
    cborSerialiseInt(minPegBps),
    Buffer.from([0xff]),
  ]);
  return Buffer.from(blake2b(bytes, { dkLen: 32 })).toString("hex");
}

async function main() {
  const { maxSlippageBps, minSwapPegBps } = parseSlipArgs();
  console.log(`H-UpdateSlippagePolicy: maxSlippageBps=${maxSlippageBps}, minSwapPegBps=${minSwapPegBps}`);

  const ctx = await initGovCtx();
  const { state, lucid, network, bfUrl, bfKey, mnemonic } = ctx;

  const targetHash = state.hashes.govPolicyStakeHash;
  if (!targetHash) throw new Error("govPolicyStakeHash not in state");

  const payloadHashHex = payloadHashUpdateSlippage(maxSlippageBps, minSwapPegBps);
  console.log(`payload_hash: ${payloadHashHex}`);

  const qResult = await queueAction({
    ctx,
    actionKind: ACTION_KIND_UPDATE_SLIPPAGE,
    targetHash,
    payloadHashHex,
    timelockMs: TIMELOCK_MS,
    ttlMs: TTL_MS,
    label: "UpdateSlippagePolicy",
  });

  console.log(`\n=== Step 2: Execute UpdateSlippagePolicy ===`);
  const ec = await prepareExecute(ctx, qResult.actionId, qResult);

  const vaultUtxo = await fetchVaultUtxoWithNft(lucid, state);
  const oldVaultDatum = Data.from(vaultUtxo.datum!) as any;
  const oldFields = oldVaultDatum.fields as any[];
  // Index 16: max_slippage_bps, 17: min_swap_peg_bps
  const newFields = [...oldFields];
  newFields[16] = maxSlippageBps;
  newFields[17] = minSwapPegBps;
  const newVaultDatum = Data.to(new Constr(0, newFields as unknown as never[]) as unknown as never);

  const vaultRedeemer = Data.to(new Constr(VAULT_REDEEMER_UPDATE_SLIPPAGE, [maxSlippageBps, minSwapPegBps]) as unknown as Data);
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
    .collectFrom([ec.govIn], ec.redeemerExec)
    .collectFrom([vaultUtxo], proxyRedeemer)
    .withdraw(govPolicyRewardAddr, 0n, vaultRedeemer)
    .readFrom(refs)
    .pay.ToAddressWithData(ec.govAddr, { kind: "inline", value: ec.newGovDatumE as unknown as string }, ec.govIn.assets)
    .pay.ToContract(vaultAddr, { kind: "inline", value: newVaultDatum as unknown as string }, vaultUtxo.assets)
    .validFrom(Number(ec.lowerMs))
    .validTo(Number(ec.upperMs))
    .addSignerKey(ec.gov.signers[0])
    .addSignerKey(ec.gov.signers[1]);

  const built = await execTx.complete();
  const eCbor = await multiSignCbor(built.toCBOR(), mnemonic, ctx.signingAccounts);
  const execTxHash = await submitCbor(bfUrl, bfKey, eCbor);
  console.log(`  ✅ Execute TX: ${execTxHash}`);

  await awaitConfirmation(bfUrl, bfKey, execTxHash, "Execute", 180);

  console.log(`\nPASS — H-UpdateSlippagePolicy Queue+Execute`);
  if (qResult.queueTxHash) console.log(`  queue:   ${qResult.queueTxHash}`);
  console.log(`  execute: ${execTxHash}`);
  console.log(`  action_id: ${qResult.actionId}`);
}

main().catch((e) => {
  console.error("[ERROR]", (e as Error).message);
  if ((e as Error).stack) console.error((e as Error).stack);
  process.exit(1);
});
