/**
 * H-UpdateFee Queue + Execute.
 *
 * ActionKind = 1. Target = vault_gov_policy (govPolicyStakeHash).
 * Payload = (new_performance_fee_bps, new_early_withdraw_fee_bps, new_min_hold_seconds).
 *
 * VaultRedeemer.UpdateFee = Constr(11, [perf, early, minhold])
 * ProxyRedeemer.UseGovPolicy = Constr(6, [])
 *
 * Primary use-case for E2E: set early_withdraw_fee_bps=0 so B3 full-drain
 * can run without the defer-yield fee gate.
 *
 * Usage:
 *   npx tsx deploy/tools/h-update-fee.ts --releaseTag <release-tag> \
 *     --perfBps 450 --earlyBps 0 --minHold 60
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

const ACTION_KIND_UPDATE_FEE = 1;
// VaultRedeemer Constr indices below are the on-chain values at this commit;
// verify against `contracts/lib/vault/types.ak::VaultRedeemer` if you fork.
const VAULT_REDEEMER_UPDATE_FEE = 12;
const PROXY_USE_GOV_POLICY = 6;
const TIMELOCK_MS = 14 * 86_400 * 1_000; // 14d production (matches constants.ak)
const TTL_MS = 86_400_000;  // 1 day

function parseFeeArgs(): { perfBps: bigint; earlyBps: bigint; minHold: bigint } {
  const a = process.argv.slice(2);
  let perfBps: bigint | null = null;
  let earlyBps: bigint | null = null;
  let minHold: bigint | null = null;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--perfBps") perfBps = BigInt(a[++i]);
    else if (a[i] === "--earlyBps") earlyBps = BigInt(a[++i]);
    else if (a[i] === "--minHold") minHold = BigInt(a[++i]);
  }
  if (perfBps === null) perfBps = 450n;
  if (earlyBps === null) earlyBps = 0n;
  if (minHold === null) minHold = 60n;
  if (perfBps < 0n || perfBps > 450n) throw new Error(`perfBps ${perfBps} outside [0, 450]`);
  if (earlyBps < 0n || earlyBps > 100n) throw new Error(`earlyBps ${earlyBps} outside [0, 100]`);
  if (minHold < 0n || minHold > 21_600n) throw new Error(`minHold ${minHold} outside [0, 21600]`);
  return { perfBps, earlyBps, minHold };
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
 * payload_hash_update_fee = blake2b_256(cbor.serialise((perfBps, earlyBps, minHold)))
 * Aiken indef-length list encoding for 3-tuple. See gov-helpers.ts.
 */
function payloadHashUpdateFee(perfBps: bigint, earlyBps: bigint, minHold: bigint): string {
  const bytes = Buffer.concat([
    Buffer.from([0x9f]),
    cborSerialiseInt(perfBps),
    cborSerialiseInt(earlyBps),
    cborSerialiseInt(minHold),
    Buffer.from([0xff]),
  ]);
  return Buffer.from(blake2b(bytes, { dkLen: 32 })).toString("hex");
}

async function main() {
  const { perfBps, earlyBps, minHold } = parseFeeArgs();
  console.log(`H-UpdateFee: perfBps=${perfBps}, earlyBps=${earlyBps}, minHold=${minHold}s`);

  const ctx = await initGovCtx();
  const { state, lucid, network, bfUrl, bfKey, mnemonic } = ctx;
  console.log(`wallet: ${ctx.wallet.slice(0, 30)}…`);

  const targetHash = state.hashes.govPolicyStakeHash;
  if (!targetHash) throw new Error("govPolicyStakeHash not in state");
  console.log(`target (vault_gov_policy): ${targetHash}`);

  const payloadHashHex = payloadHashUpdateFee(perfBps, earlyBps, minHold);
  console.log(`payload_hash: ${payloadHashHex}`);

  // ─── Queue phase (idempotent) ────────────────────────────────────────
  const qResult = await queueAction({
    ctx,
    actionKind: ACTION_KIND_UPDATE_FEE,
    targetHash,
    payloadHashHex,
    timelockMs: TIMELOCK_MS,
    ttlMs: TTL_MS,
    label: "UpdateFee",
  });

  // ─── Execute phase ───────────────────────────────────────────────────
  console.log(`\n=== Step 2: Execute UpdateFee ===`);
  const ec = await prepareExecute(ctx, qResult.actionId, qResult);

  // Fetch vault with NFT
  const vaultUtxo = await fetchVaultUtxoWithNft(lucid, state);
  console.log(`  vault UTxO: ${vaultUtxo.txHash.slice(0, 16)}…#${vaultUtxo.outputIndex}`);

  // Parse current VaultDatum (28 fields) + build new with updated fee fields
  const oldVaultDatum = Data.from(vaultUtxo.datum!) as any;
  const oldFields = oldVaultDatum.fields as any[];
  // VaultDatum field indices (28 fields total; see types.ak):
  //   6:  last_fee_update_time (bumped every UpdateFee)
  //   10: performance_fee_bps
  //   11: early_withdraw_fee_bps
  //   12: min_hold_seconds
  const newFields = [...oldFields];
  newFields[10] = perfBps;
  newFields[11] = earlyBps;
  newFields[12] = minHold;
  newFields[6] = ec.upperMs;
  const newVaultDatum = Data.to(new Constr(0, newFields as unknown as never[]) as unknown as never);

  // Redeemers
  const vaultRedeemer = Data.to(new Constr(VAULT_REDEEMER_UPDATE_FEE, [perfBps, earlyBps, minHold]) as unknown as Data);
  const proxyRedeemer = Data.to(new Constr(PROXY_USE_GOV_POLICY, []) as unknown as Data);

  // Ref inputs
  const refs = await fetchRefInputs(lucid, [
    { txHash: state.refScripts.multisigGov.txHash, outputIndex: state.refScripts.multisigGov.outputIndex },
    { txHash: state.refScripts.vaultProxy.txHash, outputIndex: state.refScripts.vaultProxy.outputIndex },
    { txHash: state.refScripts.vaultGovPolicy.txHash, outputIndex: state.refScripts.vaultGovPolicy.outputIndex },
  ]);

  // gov_policy staking validator reward address (Withdraw-Zero)
  const govPolicyRewardAddr = stakingRewardAddress(targetHash, network);
  console.log(`  vault_gov_policy reward addr: ${govPolicyRewardAddr.slice(0, 40)}…`);

  const vaultAddr = state.stateUtxos.vault.address;
  // stripLucidDatumFields prevents Lucid from incorrectly attaching the
  // input's inline datum to witness_set (Conway rejects with
  // NotAllowedSupplementalDatums). Both gov + vault UTxOs carry inline
  // datums; without stripping, Lucid duplicates them in supplemental data.
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

  // localUPLCEval:false routes through provider eval (Ogmios/Blockfrost)
  // for structured error messages — Lucid's local UPLC eval reports
  // generic "validator crashed" without surfacing which expect failed.
  const built = await execTx.complete({ localUPLCEval: false });
  const eCbor = await multiSignCbor(built.toCBOR(), mnemonic, ctx.signingAccounts);
  const execTxHash = await submitCbor(bfUrl, bfKey, eCbor);
  console.log(`  ✅ Execute TX: ${execTxHash}`);

  await awaitConfirmation(bfUrl, bfKey, execTxHash, "Execute", 180);

  console.log(`\nPASS — H-UpdateFee Queue+Execute`);
  if (qResult.queueTxHash) console.log(`  queue:   ${qResult.queueTxHash}`);
  console.log(`  execute: ${execTxHash}`);
  console.log(`  action_id: ${qResult.actionId}`);
  console.log(`  applied: perfBps=${perfBps}, earlyBps=${earlyBps}, minHold=${minHold}`);
}

main().catch((e) => {
  console.error("[ERROR]", (e as Error).message);
  if ((e as Error).stack) console.error((e as Error).stack);
  process.exit(1);
});
