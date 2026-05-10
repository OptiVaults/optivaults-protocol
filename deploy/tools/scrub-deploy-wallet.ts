#!/usr/bin/env tsx
/**
 * Scrub the deploy wallet by freeing up ADA from stale ref-script UTxOs.
 *
 * After many V1 ceremony test runs the deploy wallet accumulates ref-script
 * UTxOs at its own address (when REF_SCRIPT_ADDR is unset or set to the
 * wallet itself). These UTxOs hold ADA but the picker excludes them
 * because they have script_ref attached (would clutter change). Result:
 * even though the wallet shows 11K+ ADA on chain, only a handful of clean
 * pure-ADA UTxOs are usable for ref-script TXs.
 *
 * This script consolidates N stale ref-script UTxOs into one fat pure-ADA
 * UTxO. The original ref-scripts are dropped from the new outputs (their
 * bytes are effectively burned, which is fine because these are leftovers
 * from prior test runs that the active ceremony does not depend on).
 *
 * Usage:
 *   set -a && source keeper/.env && set +a
 *   npx tsx deploy/tools/scrub-deploy-wallet.ts
 *
 * Environment:
 *   BLOCKFROST_API_KEY_PREPROD    Required for UTxO query + TX submit.
 *   SCRUB_BATCH_SIZE              Optional. Default 15 ref-script UTxOs per TX.
 *                                 Conway has a hard cap of ~200 KB total
 *                                 ref-script bytes consumed per TX; 30 inputs
 *                                 of avg ~12 KB each = 352 KB > 200 KB cap.
 *                                 15 × 12 KB = 180 KB stays under the cap.
 *   SCRUB_INITIAL_FEE_ADA         Optional. Default 25 ADA initial estimate.
 *                                 Conway minFeeRefScriptCoinsPerByte tiers
 *                                 ramp at higher consumption: ~22 ADA real
 *                                 fee observed at 200 KB. Starting at 25 ADA
 *                                 lets first attempt land; retry adjusts down
 *                                 if overestimated.
 *   SCRUB_DRY_RUN                 Optional. Set to "1" to print the plan
 *                                 without submitting.
 */
import {
  Lucid,
  CML,
  paymentCredentialOf,
} from "@lucid-evolution/lucid";
import * as net from "node:net";
import * as fs from "node:fs";
import * as path from "node:path";

import { getKeyDaemonSocket } from "../lib/keyDaemon.js";
const BLOCKFROST_URL = "https://cardano-preprod.blockfrost.io/api/v0";

/**
 * Walk the deploy state directory and collect every TX hash that an active
 * (non-archived) ceremony depends on. Includes ref-script TX hashes, mint
 * TX hashes, and state-UTxO TX hashes. The scrub picker MUST exclude these
 * so we don't destroy ref scripts that an active ceremony is mid-flight on.
 */
function collectActiveTxHashes(stateDir: string): Set<string> {
  const hashes = new Set<string>();
  if (!fs.existsSync(stateDir)) return hashes;
  for (const file of fs.readdirSync(stateDir)) {
    // Skip the `archive/` subdir — those ceremonies are sunset.
    if (!file.endsWith(".json")) continue;
    const fp = path.join(stateDir, file);
    let parsed: any;
    try {
      parsed = JSON.parse(fs.readFileSync(fp, "utf-8"));
    } catch {
      continue;
    }
    const refScripts = parsed.refScripts ?? {};
    for (const v of Object.values(refScripts) as any[]) {
      if (v && typeof v.txHash === "string") hashes.add(v.txHash);
    }
    const mints = parsed.mints ?? {};
    for (const v of Object.values(mints) as any[]) {
      if (v && typeof v.txHash === "string") hashes.add(v.txHash);
      // Also add the utxoRef.txHash that minted-against (one-shot anchor).
      if (v && v.utxoRef && typeof v.utxoRef.txHash === "string") hashes.add(v.utxoRef.txHash);
    }
    const stateUtxos = parsed.stateUtxos ?? {};
    for (const v of Object.values(stateUtxos) as any[]) {
      if (v && typeof v.txHash === "string") hashes.add(v.txHash);
    }
  }
  return hashes;
}

function getBlockfrostKey(): string {
  const k =
    process.env.BLOCKFROST_API_KEY_PREPROD ??
    process.env.BLOCKFROST_API_KEY ??
    "";
  if (!k) throw new Error("BLOCKFROST_API_KEY_PREPROD env var required");
  return k;
}

async function fetchMnemonicFromKeyDaemon(sockPath: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const c = net.createConnection(sockPath, () => c.write("GET_MNEMONIC"));
    let buf = "";
    c.on("data", (d) => (buf += d.toString()));
    c.on("end", () =>
      resolve(buf.startsWith("OK:") ? buf.slice(3).trim() : buf.trim()),
    );
    c.on("error", reject);
    setTimeout(
      () => reject(new Error(`key daemon timeout after 5s (${sockPath})`)),
      5000,
    );
  });
}

interface BlockfrostUtxo {
  txHash: string;
  outputIndex: number;
  lovelace: bigint;
  hasRefScript: boolean;
  hasTokens: boolean;
  rawAmount: Array<{ unit: string; quantity: string }>;
}

async function fetchAllUtxos(
  addr: string,
  bfKey: string,
): Promise<BlockfrostUtxo[]> {
  const out: BlockfrostUtxo[] = [];
  let page = 1;
  while (true) {
    const res = await fetch(
      `${BLOCKFROST_URL}/addresses/${addr}/utxos?count=100&page=${page}`,
      { headers: { project_id: bfKey }, signal: AbortSignal.timeout(20000) },
    );
    if (res.status === 404) break;
    if (!res.ok)
      throw new Error(
        `Blockfrost /utxos page ${page} failed: ${res.status} ${await res.text()}`,
      );
    const batch = (await res.json()) as any[];
    if (!Array.isArray(batch) || batch.length === 0) break;
    for (const u of batch) {
      const lov = BigInt(
        u.amount.find((a: any) => a.unit === "lovelace")?.quantity ?? "0",
      );
      const hasTokens = u.amount.some((a: any) => a.unit !== "lovelace");
      out.push({
        txHash: u.tx_hash,
        outputIndex: Number(u.output_index),
        lovelace: lov,
        hasRefScript: !!u.reference_script_hash,
        hasTokens,
        rawAmount: u.amount,
      });
    }
    if (batch.length < 100) break;
    page += 1;
    if (page > 50) throw new Error("Blockfrost pagination > 50 pages");
  }
  return out;
}

async function getCurrentSlot(bfKey: string): Promise<number> {
  const res = await fetch(`${BLOCKFROST_URL}/blocks/latest`, {
    headers: { project_id: bfKey },
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) throw new Error(`/blocks/latest failed: ${res.status}`);
  const j = (await res.json()) as any;
  if (!j.slot) throw new Error("no slot in /blocks/latest");
  return j.slot as number;
}

async function submitViaBf(
  cborHex: string,
  bfKey: string,
): Promise<string> {
  const res = await fetch(`${BLOCKFROST_URL}/tx/submit`, {
    method: "POST",
    headers: {
      "Content-Type": "application/cbor",
      project_id: bfKey,
    },
    body: Buffer.from(cborHex, "hex"),
    signal: AbortSignal.timeout(30000),
  });
  const body = await res.text();
  if (res.ok) return body.replace(/"/g, "").trim();
  throw new Error(body);
}

async function awaitTxConfirmed(
  txHash: string,
  bfKey: string,
  timeoutMs: number = 120_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const res = await fetch(`${BLOCKFROST_URL}/txs/${txHash}`, {
      headers: { project_id: bfKey },
      signal: AbortSignal.timeout(15000),
    });
    if (res.status === 200) return;
    await new Promise((r) => setTimeout(r, 5000));
  }
  throw new Error(`TX ${txHash} not confirmed within ${timeoutMs}ms`);
}

async function main() {
  const dryRun = process.env.SCRUB_DRY_RUN === "1";
  const batchSize = parseInt(process.env.SCRUB_BATCH_SIZE ?? "15", 10);
  const initialFeeAda = parseInt(process.env.SCRUB_INITIAL_FEE_ADA ?? "25", 10);
  const bfKey = getBlockfrostKey();

  console.log(`[scrub] Initializing Lucid (Preprod) ...`);
  // Minimal Blockfrost provider — we only need it for Lucid wallet signing.
  const { Blockfrost } = await import("@lucid-evolution/lucid");
  const provider = new Blockfrost(BLOCKFROST_URL, bfKey);
  const lucid = await Lucid(provider as any, "Preprod");

  console.log(`[scrub] Fetching mnemonic from key daemon ...`);
  const mnemonic = await fetchMnemonicFromKeyDaemon(getKeyDaemonSocket());
  lucid.selectWallet.fromSeed(mnemonic);
  const walletAddr = await lucid.wallet().address();
  const walletPkh = paymentCredentialOf(walletAddr).hash;
  console.log(`[scrub] Wallet address: ${walletAddr}`);

  console.log(`[scrub] Fetching wallet UTxOs from Blockfrost ...`);
  const utxos = await fetchAllUtxos(walletAddr, bfKey);
  console.log(`[scrub] Total UTxOs: ${utxos.length}`);

  // Collect TX hashes from every active (non-archived) ceremony state file
  // so we don't destroy a ref-script that a live ceremony is mid-flight on.
  // State files live at <repo>/deploy/state/*.json relative to cwd.
  const stateDir = path.resolve(process.cwd(), "deploy/state");
  const protectedTxHashes = collectActiveTxHashes(stateDir);
  console.log(
    `[scrub] Protected TX hashes (active ceremonies): ${protectedTxHashes.size}`,
  );

  // Categorize. Ref-script UTxOs whose tx_hash is in any active state file
  // are EXCLUDED from the scrub pool.
  const refScriptOnly = utxos.filter(
    (u) =>
      u.hasRefScript &&
      !u.hasTokens &&
      u.lovelace >= 2_000_000n &&
      !protectedTxHashes.has(u.txHash),
  );
  const refScriptProtected = utxos.filter(
    (u) =>
      u.hasRefScript && protectedTxHashes.has(u.txHash),
  );
  console.log(
    `[scrub] Protected ref-script UTxOs (kept untouched): ${refScriptProtected.length}`,
  );
  const cleanPureAda = utxos.filter(
    (u) => !u.hasRefScript && !u.hasTokens && u.lovelace >= 2_000_000n,
  );
  const tokenCarrying = utxos.filter(
    (u) => !u.hasRefScript && u.hasTokens && u.lovelace >= 2_000_000n,
  );

  const sumLov = (xs: BlockfrostUtxo[]) =>
    xs.reduce((s, u) => s + u.lovelace, 0n);

  console.log(
    `[scrub] Categories:\n` +
      `  ref-script-only: ${refScriptOnly.length} UTxOs (${Number(sumLov(refScriptOnly)) / 1e6} ADA)\n` +
      `  clean pure-ADA:  ${cleanPureAda.length} UTxOs (${Number(sumLov(cleanPureAda)) / 1e6} ADA)\n` +
      `  token-carrying:  ${tokenCarrying.length} UTxOs (${Number(sumLov(tokenCarrying)) / 1e6} ADA)`,
  );

  if (refScriptOnly.length === 0) {
    console.log(`[scrub] No stale ref-script UTxOs to scrub. Exiting.`);
    return;
  }

  // Sort ref-script UTxOs by ADA (desc) and pick the largest batchSize
  const picked = [...refScriptOnly]
    .sort((a, b) => Number(b.lovelace - a.lovelace))
    .slice(0, batchSize);
  const totalIn = sumLov(picked);
  console.log(
    `[scrub] Will fold ${picked.length} ref-script UTxOs ` +
      `(${Number(totalIn) / 1e6} ADA total) into ONE pure-ADA output back to wallet.`,
  );

  if (dryRun) {
    console.log(`[scrub] DRY RUN: not submitting.`);
    console.log(`  Picked UTxOs:`);
    for (const u of picked.slice(0, 10)) {
      console.log(
        `    ${u.txHash}#${u.outputIndex}: ${Number(u.lovelace) / 1e6} ADA`,
      );
    }
    if (picked.length > 10) console.log(`    ... and ${picked.length - 10} more`);
    return;
  }

  // Build CML TX directly to avoid Lucid auto-coin-selection (which would
  // try to preserve ref scripts in change outputs, defeating the purpose).
  const currentSlot = await getCurrentSlot(bfKey);
  const addrCml = CML.Address.from_bech32(walletAddr);

  const inputs = CML.TransactionInputList.new();
  // Sort canonically (txHash asc, then outputIndex asc) — required for
  // Lucid to match input order during signing.
  const sortedPicked = [...picked].sort(
    (a, b) =>
      a.txHash.localeCompare(b.txHash) || a.outputIndex - b.outputIndex,
  );
  for (const u of sortedPicked) {
    inputs.add(
      CML.TransactionInput.new(
        CML.TransactionHash.from_hex(u.txHash),
        BigInt(u.outputIndex),
      ),
    );
  }

  const reqSigners = CML.Ed25519KeyHashList.new();
  reqSigners.add(CML.Ed25519KeyHash.from_hex(walletPkh));

  // Conway minFeeRefScriptCoinsPerByte tiers: ref-script bytes consumed
  // in inputs are taxed on a tiered curve that grows steeply past 100 KB.
  // Empirically: 30 inputs / 352 KB → required fee
  // 21.9 ADA. With batchSize=15 we expect ~175 KB consumed, fee ~6-10 ADA,
  // but Conway can surprise; start at SCRUB_INITIAL_FEE_ADA so the first
  // submit usually lands. The retry loop adjusts down via FeeTooSmall
  // feedback (which always reports the exact required fee).
  let estFee = BigInt(initialFeeAda) * 1_000_000n;

  function buildBody(fee: bigint): CML.TransactionBody {
    const outs = CML.TransactionOutputList.new();
    const changeAmt = totalIn - fee;
    outs.add(
      CML.TransactionOutput.new(
        addrCml,
        CML.Value.new(changeAmt, CML.MultiAsset.new()),
      ),
    );
    const body = CML.TransactionBody.new(inputs, outs, fee);
    body.set_validity_interval_start(BigInt(currentSlot - 120));
    body.set_ttl(BigInt(currentSlot + 1800));
    body.set_required_signers(reqSigners);
    return body;
  }

  // Iterate fee adjustments
  for (let attempt = 0; attempt < 8; attempt++) {
    const body = buildBody(estFee);
    const ws = CML.TransactionWitnessSet.new();
    const draft = CML.Transaction.new(body, ws, true);
    const witnessSet = await lucid
      .wallet()
      .signTx(CML.Transaction.from_cbor_hex(draft.to_cbor_hex()));
    const signed = CML.Transaction.new(body, witnessSet, true);
    try {
      const txHash = await submitViaBf(signed.to_cbor_hex(), bfKey);
      console.log(`[scrub] TX ${txHash} submitted (fee ${Number(estFee) / 1e6} ADA, change ${Number(totalIn - estFee) / 1e6} ADA), awaiting confirmation ...`);
      await awaitTxConfirmed(txHash, bfKey, 180_000);
      console.log(`[scrub] CONFIRMED. New pure-ADA UTxO of ${Number(totalIn - estFee) / 1e6} ADA at deploy wallet.`);
      console.log(`[scrub] Wait 30s for indexer to expose, then resume ceremony.`);
      await new Promise((r) => setTimeout(r, 30_000));
      return;
    } catch (err: any) {
      const msg = err.message ?? String(err);
      // ConwayTxRefScriptsSizeTooBig is a HARD ledger cap, NOT recoverable
      // by fee retry. Abort with operator hint to lower SCRUB_BATCH_SIZE.
      const sizeMatch = msg.match(
        /ConwayTxRefScriptsSizeTooBig\D+(\d+)\D+(\d+)/i,
      );
      if (sizeMatch) {
        const used = BigInt(sizeMatch[1]);
        const cap = BigInt(sizeMatch[2]);
        throw new Error(
          `[scrub] ConwayTxRefScriptsSizeTooBig: TX would consume ${used} ` +
            `bytes of ref-scripts in inputs but ledger cap is ${cap}. ` +
            `Lower SCRUB_BATCH_SIZE (current ${batchSize}) and retry. ` +
            `Suggested next: ${Math.max(5, Math.floor(batchSize * Number(cap) / Number(used)))}.`,
        );
      }
      // FeeTooSmallUTxO Conway format: `(FeeTooSmallUTxO (Coin <provided>) (Coin <required>))`.
      // Required is the LAST integer in the substring. Older fee error
      // formats also handled.
      let requiredFee: bigint | null = null;
      const ftsuBlock = msg.match(/FeeTooSmallUTxO[\s\S]{0,500}?(?:\)\s*\)|$)/i);
      if (ftsuBlock) {
        const nums = ftsuBlock[0].match(/\d+/g);
        if (nums && nums.length >= 2) {
          requiredFee = BigInt(nums[nums.length - 1]);
        }
      }
      if (requiredFee === null) {
        const m =
          msg.match(/NotEnoughFundsForFee[^(]*\(Coin (\d+)\)/i) ||
          msg.match(/"minimumRequiredFee"[^}]*"lovelace":(\d+)/);
        if (m) requiredFee = BigInt(m[1]);
      }
      if (requiredFee !== null) {
        estFee = requiredFee + 100_000n;
        console.log(
          `[scrub] retry: fee bumped to ${Number(estFee) / 1e6} ADA ` +
            `(required ${Number(requiredFee) / 1e6} + 0.1 margin)`,
        );
        continue;
      }
      throw new Error(`scrub TX submit failed: ${msg.slice(0, 1500)}`);
    }
  }
  throw new Error("scrub TX failed after 8 fee-adjustment attempts");
}

main().catch((e) => {
  console.error("[scrub] FATAL:", e);
  process.exit(1);
});
