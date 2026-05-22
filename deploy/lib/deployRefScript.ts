/**
 * Deploy a Plutus V3 reference script via manual CML TX building.
 *
 * Lucid Evolution 0.4.29's .complete() under-estimates Conway-era fees when an
 * output contains a large script_ref (it appears to omit the per-byte
 * `minFeeRefScriptCostPerByte` component), so .submit() fails with "Insufficient fee"
 * for scripts >10KB. This helper builds and submits the TX directly via CML + Blockfrost.
 */
import { CML, applyDoubleCborEncoding, paymentCredentialOf } from "@lucid-evolution/lucid";
import type { LucidEvolution, Script, UTxO } from "@lucid-evolution/lucid";

export interface DeployResult {
  txHash: string;
  outputIndex: number;
}

/**
 * Normalize a `string | string[]` BF key input into a non-empty array.
 * Filters out empty strings to allow callers to pass `[primary, backup]`
 * where backup is optional.
 */
function normalizeKeys(keys: string | string[]): string[] {
  const arr = Array.isArray(keys) ? keys : [keys];
  const filtered = arr.filter((k) => k && k.length > 0);
  if (filtered.length === 0) {
    throw new Error("[deployRefScript] no Blockfrost keys provided");
  }
  return filtered;
}

/**
 * Wrap a single-key Blockfrost call with rotation-on-quota-error
 * fallback. Accepts an array of keys and tries each one until either
 * the call succeeds OR a non-quota error fires (e.g. 4xx other than
 * 402/429, network error, payload error). Quota errors (402, 429,
 * "over limit", "rate limit") rotate to the next key; non-quota errors
 * propagate immediately so real bugs aren't masked.
 *
 * Without this, a primary-key 402 mid-ceremony crashed the deploy and
 * left partial state with no clean resume path.
 */
async function withKeyRotation<T>(
  keys: string[],
  callerLabel: string,
  fn: (key: string) => Promise<T>,
): Promise<T> {
  let lastErr: Error | null = null;
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    try {
      return await fn(k);
    } catch (e: any) {
      lastErr = e instanceof Error ? e : new Error(String(e));
      const msg = lastErr.message || "";
      const isQuotaError =
        msg.includes("402") ||
        msg.includes("429") ||
        msg.toLowerCase().includes("over limit") ||
        msg.toLowerCase().includes("rate limit");
      if (!isQuotaError) {
        // Non-quota error — don't try other keys, surface immediately
        throw lastErr;
      }
      // Quota error: log + try next key
      const remaining = keys.length - i - 1;
      console.log(
        `[deployRefScript] ${callerLabel} key #${i + 1}/${keys.length} (${k.slice(0, 12)}…) quota-exhausted; ${
          remaining > 0 ? `rotating to backup` : `all keys exhausted`
        }`,
      );
    }
  }
  throw lastErr ?? new Error(`[deployRefScript] ${callerLabel}: all ${keys.length} keys exhausted`);
}

/**
 * Get current slot from Blockfrost /blocks/latest.
 *
 * Accepts string OR array of keys; rotates on 402/429 to backup keys
 * (this rotation fix). Original single-key signature still works because
 * `string` is normalized to `[string]` internally.
 */
async function getCurrentSlot(
  blockfrostUrl: string,
  blockfrostKeys: string | string[],
): Promise<number> {
  const keys = normalizeKeys(blockfrostKeys);
  return withKeyRotation(keys, "getCurrentSlot", async (key) => {
    const res = await fetch(`${blockfrostUrl}/blocks/latest`, {
      headers: { project_id: key },
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) throw new Error(`Blockfrost /blocks/latest failed: ${res.status}`);
    const data = await res.json() as any;
    const slot = data.slot as number;
    if (!slot) throw new Error("Cannot get current slot from Blockfrost");
    return slot;
  });
}

/**
 * Submit TX via Blockfrost /tx/submit.
 * Returns TX hash on success, throws on error.
 *
 * Accepts string OR array of keys; rotates on 402/429 (this rotation fix).
 * Other 4xx (e.g. duplicate input, validity-range, FeeTooSmall) propagate
 * immediately — no point retrying with a different key.
 */
async function submitViaBf(
  signedCbor: string,
  blockfrostUrl: string,
  blockfrostKeys: string | string[],
): Promise<string> {
  const keys = normalizeKeys(blockfrostKeys);
  const cborBytes = Buffer.from(signedCbor, "hex");
  return withKeyRotation(keys, "submitViaBf", async (key) => {
    const res = await fetch(`${blockfrostUrl}/tx/submit`, {
      method: "POST",
      headers: {
        "Content-Type": "application/cbor",
        project_id: key,
      },
      body: cborBytes,
      signal: AbortSignal.timeout(30000),
    });
    const body = await res.text();
    if (res.ok) {
      // Blockfrost returns the TX hash as a JSON string (with quotes)
      return body.replace(/"/g, "").trim();
    }
    // 402/429 → withKeyRotation rotates; everything else surfaces.
    if (res.status === 402 || res.status === 429) {
      throw new Error(`Blockfrost /tx/submit failed: ${res.status} ${body}`);
    }
    throw new Error(body);
  });
}

/**
 * Fetch ALL UTxOs at an address via Blockfrost, fully paginated.
 *
 * Lucid Evolution's `lucid.wallet().getUtxos()` is internally paginated
 * but in practice returns truncated results for wallets with hundreds of
 * UTxOs (observed: a wallet with 566 pure-ADA UTxOs returned only ~5 to
 * Lucid). This helper bypasses Lucid's wallet UTxO query and goes
 * straight to Blockfrost, returning every UTxO at the address as a
 * Lucid-compatible `UTxO` shape (with `assets` as Record<unit, bigint>).
 *
 * `scriptRef` is left as `undefined` because our deploy wallet does not
 * own ref-script UTxOs (those live at REF_SCRIPT_ADDR, a separate
 * address). If a future caller needs scriptRef-aware UTxO selection at
 * the wallet, fetch /scripts/{hash}/cbor per ref'd UTxO.
 */
async function fetchAllUtxosFromBlockfrost(
  addr: string,
  blockfrostUrl: string,
  blockfrostKeys: string | string[],
): Promise<UTxO[]> {
  const keys = normalizeKeys(blockfrostKeys);
  const out: UTxO[] = [];
  let page = 1;
  while (true) {
    const batch = await withKeyRotation(
      keys,
      `fetchAllUtxosFromBlockfrost page=${page}`,
      async (key) => {
        const res = await fetch(
          `${blockfrostUrl}/addresses/${addr}/utxos?count=100&page=${page}`,
          {
            headers: { project_id: key },
            signal: AbortSignal.timeout(20000),
          },
        );
        if (res.status === 404) return null; // no UTxOs at all
        if (res.status === 402 || res.status === 429) {
          throw new Error(`Blockfrost /utxos page ${page} failed: ${res.status}`);
        }
        if (!res.ok) throw new Error(`Blockfrost /utxos page ${page} failed: ${res.status}`);
        return await res.json() as any[];
      },
    );
    if (batch === null) break;
    if (!Array.isArray(batch) || batch.length === 0) break;
    for (const u of batch) {
      const assets: Record<string, bigint> = {};
      for (const a of u.amount as Array<{ unit: string; quantity: string }>) {
        assets[a.unit] = BigInt(a.quantity);
      }
      out.push({
        txHash: u.tx_hash,
        outputIndex: Number(u.output_index),
        address: addr,
        assets,
        datum: u.inline_datum ?? null,
        datumHash: u.data_hash ?? null,
        scriptRef: u.reference_script_hash
          ? // Mark presence; full script body omitted (deploy wallet shouldn't hold ref-script UTxOs).
            ({ type: "PlutusV3", script: "" } as any)
          : null,
      } as UTxO);
    }
    if (batch.length < 100) break;
    page += 1;
    if (page > 50) throw new Error("Blockfrost /utxos pagination exceeded 50 pages — wallet has > 5,000 UTxOs?");
  }
  return out;
}

/**
 * Wait for a TX to appear in Blockfrost (indexer-confirmed).
 * Returns when /txs/{hash} returns 200, or throws on timeout.
 */
async function awaitTxConfirmed(
  txHash: string,
  blockfrostUrl: string,
  blockfrostKey: string | string[],
  timeoutMs: number = 90_000,
): Promise<void> {
  const keys = normalizeKeys(blockfrostKey);
  const deadline = Date.now() + timeoutMs;
  let keyIdx = 0;
  while (Date.now() < deadline) {
    const k = keys[keyIdx];
    try {
      const res = await fetch(`${blockfrostUrl}/txs/${txHash}`, {
        headers: { project_id: k },
        signal: AbortSignal.timeout(15000),
      });
      if (res.ok) return;
      if (res.status === 402 || res.status === 429) {
        // Quota error — try next key on next loop iteration
        keyIdx = (keyIdx + 1) % keys.length;
        await new Promise((r) => setTimeout(r, 5000));
        continue;
      }
      if (res.status !== 404) {
        const body = await res.text();
        throw new Error(`Blockfrost /txs/${txHash} ${res.status}: ${body.slice(0, 300)}`);
      }
    } catch (e: any) {
      const msg = e?.message || String(e);
      if (msg.includes("402") || msg.includes("429") || msg.toLowerCase().includes("over limit")) {
        keyIdx = (keyIdx + 1) % keys.length;
      } else {
        throw e;
      }
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
  throw new Error(`TX ${txHash} not confirmed after ${timeoutMs}ms`);
}

/**
 * Auto-consolidation TX (Phase B fix, 2026-04-25): when the deploy wallet's
 * pure-ADA UTXO pool is exhausted mid-ceremony (after Phase 0 NFT mints + N
 * ref-script publishes consume the pure-ADA stash), the next ref-script TX
 * would have to grab a token-carrying input. The token bundle then leaks
 * into the change output, and combined with a 12+ KB ref-script body the
 * TX exceeds Cardano's 16,384-byte max-tx-size. (Observed in practice
 * at vault_batcher publish: TX size 17,190 B.)
 *
 * Fix: before each ref-script TX, if the wallet's pure-ADA UTxOs cannot
 * cover targetBalance, submit a consolidation TX first that gathers ALL
 * token-carrying UTxOs into a single token-tank output (tokens + 3 ADA
 * min-UTXO) and returns the rest as ADA-only change. After confirmation,
 * the ref-script picker has a fat pure-ADA UTxO available and can build
 * the ref-script TX without token-bundling. Cost: ~0.3 ADA per
 * consolidation, only when needed.
 *
 * Returns the consolidation TX hash if a consolidation was performed,
 * or null if the wallet already had enough pure-ADA.
 */
async function consolidateTokensIfNeeded(
  lucid: LucidEvolution,
  walletAddr: string,
  walletPkh: string,
  addrCml: any,
  targetBalance: bigint,
  blockfrostUrl: string,
  blockfrostKey: string | string[],
  currentSlot: number,
  prefetchedAllUtxos?: UTxO[],
): Promise<string | null> {
  // Use Blockfrost-direct UTxO list when available — Lucid's getUtxos() is
  // unreliable on heavily-used wallets.
  const allUtxos = prefetchedAllUtxos
    ?? await fetchAllUtxosFromBlockfrost(walletAddr, blockfrostUrl, blockfrostKey);
  const pureAda = allUtxos.filter(u =>
    !u.scriptRef &&
    Object.keys(u.assets).length === 1 &&
    (u.assets.lovelace as bigint) >= 2_000_000n,
  );
  const tokenCarrying = allUtxos.filter(u =>
    !u.scriptRef &&
    Object.keys(u.assets).length > 1 &&
    (u.assets.lovelace as bigint) >= 2_000_000n,
  );
  const pureAdaSum = pureAda.reduce(
    (sum, u) => sum + (u.assets.lovelace as bigint),
    0n,
  );
  if (pureAdaSum >= targetBalance || tokenCarrying.length === 0) {
    return null; // no consolidation needed
  }

  // pure-ADA pool drained to 0 case. The consolidator
  // re-folds N existing 30-ADA tanks into N new 30-ADA tanks; the lovelace
  // conserved exactly equals 30N. Without an additional pure-ADA input to
  // cover the ~600K-1.2M lovelace TX fee, the change output goes negative
  // (observed e.g. -6924138 lovelace at the vaultAdminDeploy ref publish)
  // We can't auto-recover here because (a) inline scrub of stale ref-scripts
  // is risky in the middle of a ceremony (might destroy active refs from
  // CONCURRENT releaseTags), and (b) Lucid coin selection on heavily-used
  // wallets is unreliable. Throw an actionable error directing operator to
  // run `scrub-deploy-wallet.ts` then resume deploy.ts (idempotent skip via
  // state checkpoints).
  if (pureAda.length === 0) {
    const tokenLovelace = tokenCarrying.reduce(
      (sum, u) => sum + (u.assets.lovelace as bigint),
      0n,
    );
    throw new Error(
      `[deployRefScript] consolidation BLOCKED: wallet has 0 pure-ADA UTxOs ` +
      `(token-tank pool ${Number(tokenLovelace)/1e6} ADA insufficient to cover ~0.6-1.2 ADA TX fee). ` +
      `Run \`cd v1 && npx tsx deploy/tools/scrub-deploy-wallet.ts\` to fold ~15 stale ` +
      `ref-script UTxOs into a fresh ~250 ADA pure-ADA UTxO, then re-launch ` +
      `\`npx tsx deploy/deploy.ts --network Preprod --releaseTag <tag>\` ` +
      `(idempotent: skips already-checkpointed PHASE 0/1/2 + 3 already-published refs + 4a/4b items).`,
    );
  }

  console.log(
    `[deployRefScript] consolidating: pure-ADA pool ${Number(pureAdaSum)/1e6} ADA < target ${Number(targetBalance)/1e6} ADA, ` +
    `${tokenCarrying.length} token-carrying UTxOs to fold into token-tank`,
  );

  // Aggregate every token from every token-carrying UTxO into a single map.
  const aggTokens: Record<string, bigint> = {};
  let aggLovelace = 0n;
  for (const u of tokenCarrying) {
    aggLovelace += u.assets.lovelace as bigint;
    for (const [unit, qty] of Object.entries(u.assets)) {
      if (unit === "lovelace" || qty === 0n) continue;
      aggTokens[unit] = (aggTokens[unit] || 0n) + (qty as bigint);
    }
  }

  // Group tokens by policyId. Cardano protocol enforces maxValueSize ~5KB
  // per output — a wallet polluted by many prior ceremonies can hit 7KB+
  // total bundle, requiring multiple token-tank outputs to bucketize.
  const policyEntries: Array<[string, Map<string, bigint>]> = [];
  {
    const policyMap = new Map<string, Map<string, bigint>>();
    for (const [unit, qty] of Object.entries(aggTokens)) {
      if (qty === 0n) continue;
      const policyId = unit.slice(0, 56);
      const assetName = unit.slice(56);
      if (!policyMap.has(policyId)) policyMap.set(policyId, new Map());
      policyMap.get(policyId)!.set(assetName, qty);
    }
    for (const e of policyMap.entries()) policyEntries.push(e);
  }

  // Bucket policies. Each bucket caps at ~10 policies — empirically yields
  // value-bytes well under the 5KB protocol cap even with multi-asset
  // policies. (Conservative; could tighten if a future deploy hits the
  // limit again.)
  const POLICIES_PER_BUCKET = 10;
  const buckets: Array<Array<[string, Map<string, bigint>]>> = [];
  for (let i = 0; i < policyEntries.length; i += POLICIES_PER_BUCKET) {
    buckets.push(policyEntries.slice(i, i + POLICIES_PER_BUCKET));
  }
  if (buckets.length === 0) buckets.push([]); // no tokens edge case

  function buildBucketMultiAsset(bucket: Array<[string, Map<string, bigint>]>): any {
    const ma = CML.MultiAsset.new();
    for (const [policyId, assetEntries] of bucket) {
      const inner = CML.MapAssetNameToCoin.new();
      for (const [assetName, qty] of assetEntries) {
        inner.insert(CML.AssetName.from_hex(assetName || ""), qty);
      }
      ma.insert_assets(CML.ScriptHash.from_hex(policyId), inner);
    }
    return ma;
  }

  // Build inputs (sorted). Include token-carrying UTxOs PLUS at least one
  // pure-ADA UTxO so that fees + min-ADA change have a lovelace source
  // beyond the token-tank inputs themselves. Without this, re-folding 14
  // existing tanks (each 30 ADA = 420 ADA) into 14 new tanks (each 30 ADA
  // = 420 ADA) leaves no ADA for the ~600K fee → change output goes
  // negative → throw on line ~430. Pull the largest pure-ADA UTxO available
  // (greedy — fewer inputs = smaller TX size = lower fee).
  const pureAdaSorted = [...pureAda].sort(
    (a, b) => Number((b.assets.lovelace as bigint) - (a.assets.lovelace as bigint)),
  );
  const pureAdaToInclude: UTxO[] = pureAdaSorted.length > 0 ? [pureAdaSorted[0]] : [];

  const allInputs = [...tokenCarrying, ...pureAdaToInclude];
  const sorted = allInputs.sort(
    (a, b) =>
      a.txHash.localeCompare(b.txHash) || a.outputIndex - b.outputIndex,
  );
  const inputs = CML.TransactionInputList.new();
  for (const u of sorted) {
    inputs.add(
      CML.TransactionInput.new(
        CML.TransactionHash.from_hex(u.txHash),
        BigInt(u.outputIndex),
      ),
    );
  }
  // aggLovelace was calculated only from tokenCarrying; bump it with the
  // pure-ADA inputs we just pulled in.
  for (const u of pureAdaToInclude) {
    aggLovelace += u.assets.lovelace as bigint;
  }

  const reqSigners = CML.Ed25519KeyHashList.new();
  reqSigners.add(CML.Ed25519KeyHash.from_hex(walletPkh));

  // Per-bucket token-tank lovelace. 30 ADA covers Conway min-UTXO for
  // up to ~10 policies / ~30 assets per output. (Math:
  // ~150 + (10×28 + 30×12 + 30×8) × 4310 ≈ 4M lovelace floor; 30 ADA gives
  // 7× safety margin.)
  const tankAdaPerBucket = 30_000_000n;
  const totalTankAda = tankAdaPerBucket * BigInt(buckets.length);

  console.log(
    `[deployRefScript] consolidating into ${buckets.length} token-tank output(s) ` +
    `(${policyEntries.length} policies / ${Object.keys(aggTokens).length} assets, ` +
    `${Number(tankAdaPerBucket)/1e6} ADA each)`,
  );

  function buildBody(fee: bigint, changeAmt: bigint): CML.TransactionBody {
    const outs = CML.TransactionOutputList.new();
    // Outputs 0..N-1: token-tank buckets
    for (const bucket of buckets) {
      outs.add(
        CML.TransactionOutput.new(
          addrCml,
          CML.Value.new(tankAdaPerBucket, buildBucketMultiAsset(bucket)),
        ),
      );
    }
    // Output N: ADA-only change
    outs.add(
      CML.TransactionOutput.new(
        addrCml,
        CML.Value.new(changeAmt, CML.MultiAsset.new()),
      ),
    );
    const body = CML.TransactionBody.new(inputs, outs, fee);
    body.set_validity_interval_start(BigInt(currentSlot - 120));
    body.set_ttl(BigInt(currentSlot + 900));
    body.set_required_signers(reqSigners);
    return body;
  }

  // Estimate fee
  const draftBody = buildBody(500_000n, aggLovelace - totalTankAda - 500_000n);
  const ws = CML.TransactionWitnessSet.new();
  const draftTx = CML.Transaction.new(draftBody, ws, true);
  const draftSize = BigInt(draftTx.to_cbor_hex().length / 2);
  const sizeFee = 44n * (draftSize + 120n) + 155381n;
  let estFee = sizeFee + 50_000n;

  for (let attempt = 0; attempt < 3; attempt++) {
    const changeAmt = aggLovelace - totalTankAda - estFee;
    if (changeAmt < 2_000_000n) {
      throw new Error(
        `consolidation TX change too small: ${changeAmt} (token-tanks require more lovelace from inputs; need to also pull pure-ADA UTxOs into the consolidation)`,
      );
    }
    const body = buildBody(estFee, changeAmt);
    const unsigned = CML.Transaction.new(body, ws, true);
    const witnessSet = await lucid
      .wallet()
      .signTx(CML.Transaction.from_cbor_hex(unsigned.to_cbor_hex()));
    const signed = CML.Transaction.new(body, witnessSet, true);
    try {
      const txHash = await submitViaBf(
        signed.to_cbor_hex(),
        blockfrostUrl,
        blockfrostKey,
      );
      console.log(`[deployRefScript] consolidation TX ${txHash} submitted, awaiting confirmation`);
      await awaitTxConfirmed(txHash, blockfrostUrl, blockfrostKey, 120_000);
      // Extra 30s for Blockfrost indexer to expose the new UTxOs to wallet.getUtxos()
      await new Promise((r) => setTimeout(r, 30_000));
      console.log(`[deployRefScript] consolidation confirmed; pure-ADA pool refreshed`);
      return txHash;
    } catch (err: any) {
      const errStr = err.message || String(err);
      const feeMatch =
        errStr.match(/NotEnoughFundsForFee[^(]*\(Coin (\d+)\)/i) ||
        errStr.match(/"minimumRequiredFee"[^}]*"lovelace":(\d+)/);
      if (feeMatch) {
        estFee = BigInt(feeMatch[1]) + 10_000n;
        continue;
      }
      throw new Error(`consolidation TX submit failed: ${errStr.slice(0, 1500)}`);
    }
  }
  throw new Error("consolidation TX failed after 3 fee-adjustment attempts");
}

export async function deployRefScripts(
  lucid: LucidEvolution,
  scripts: Script[],
  outputLovelaces: bigint[],
  blockfrostUrl: string,
  /**
   * accept `string` (single key, original) OR `string[]`
   * (primary + backups). Internal getCurrentSlot/submitViaBf/utxos
   * helpers rotate on 402/429 quota errors.
   */
  blockfrostKey: string | string[],
  prefetchedUtxos?: UTxO[],
): Promise<DeployResult[]> {
  if (scripts.length !== outputLovelaces.length) {
    throw new Error("scripts and outputLovelaces length mismatch");
  }
  const walletAddr = await lucid.wallet().address();
  const walletPkh = paymentCredentialOf(walletAddr).hash;
  const addrCml = CML.Address.from_bech32(walletAddr);

  // REF_SCRIPT_ADDR: optional separate address for ref script outputs.
  // When set, ref scripts are stored at this address (e.g. a dedicated
  // ref-deployer wallet) while change returns to the signing wallet.
  // This prevents keeper daily operations from accidentally spending
  // ref script UTXOs. When unset, defaults to walletAddr (original behavior).
  const refScriptAddr = process.env.REF_SCRIPT_ADDR || walletAddr;
  const refAddrCml = CML.Address.from_bech32(refScriptAddr);
  if (refScriptAddr !== walletAddr) {
    console.log(`[deployRefScript] Ref script outputs → ${refScriptAddr.slice(0, 40)}...`);
    console.log(`[deployRefScript] Change outputs → ${walletAddr.slice(0, 40)}...`);
  }

  // Get current slot from Blockfrost
  const currentSlot = await getCurrentSlot(blockfrostUrl, blockfrostKey);

  const totalOutputLovelace = outputLovelaces.reduce((a, b) => a + b, 0n);
  // Reserve 20 ADA buffer on top of the script outputs so the picker
  // always has fee + change min-UTXO headroom.
  const targetBalance = totalOutputLovelace + 20_000_000n;

  // Fetch full UTxO list directly from Blockfrost — Lucid's
  // wallet().getUtxos() truncates results on wallets with hundreds of
  // UTxOs (observed: 566-UTxO wallet returned only ~5 to Lucid).
  const blockfrostAllUtxos = prefetchedUtxos
    ?? await fetchAllUtxosFromBlockfrost(walletAddr, blockfrostUrl, blockfrostKey);

  // Phase B fix (2026-04-25): when the wallet's pure-ADA UTxO pool is
  // exhausted, run a consolidation TX FIRST to fold every token-carrying
  // UTxO into a single token-tank, releasing the rest as a fat pure-ADA
  // change. This avoids the 16,384 B max-tx-size violation we'd hit if
  // ref-script TXs had to take token-carrying inputs (12 KB script body +
  // bundled token change = ~17 KB > 16,384). After consolidation the
  // ref-script picker uses pure-ADA inputs only.
  if (!prefetchedUtxos) {
    await consolidateTokensIfNeeded(
      lucid,
      walletAddr,
      walletPkh,
      addrCml,
      targetBalance,
      blockfrostUrl,
      blockfrostKey,
      currentSlot,
      blockfrostAllUtxos,
    );
  }

  // Re-fetch UTxOs (post-consolidation if it ran). Always go via
  // Blockfrost direct query so we see everything.
  const allUtxos = prefetchedUtxos
    ?? await fetchAllUtxosFromBlockfrost(walletAddr, blockfrostUrl, blockfrostKey);

  // Pick pure-ADA UTxOs only — ref-script TXs (especially 12+ KB scripts)
  // cannot afford to bundle tokens into change. If we hit "insufficient
  // pure-ADA" here we throw with operator instructions; consolidation
  // already ran above, so this path indicates the wallet is genuinely
  // out of ADA, not just out of pure-ADA UTxOs.
  const pureAdaUsable = allUtxos
    .filter(u =>
      !u.scriptRef &&
      Object.keys(u.assets).length === 1 &&
      (u.assets.lovelace as bigint) >= 2_000_000n,
    )
    .sort((a, b) =>
      Number((b.assets.lovelace as bigint) - (a.assets.lovelace as bigint)),
    );

  const picked: UTxO[] = [];
  let acc = 0n;
  for (const u of pureAdaUsable) {
    picked.push(u);
    acc += u.assets.lovelace as bigint;
    if (acc >= targetBalance) break;
  }

  // Token bundle in change is now empty (pure-ADA inputs only).
  const changeTokens: Record<string, bigint> = {};

  if (acc < targetBalance) {
    // Fallback: try token-carrying UTxOs (preserves mixed-asset bundling robustness for
    // small-script ceremonies where Phase B consolidation overhead is
    // unjustified — e.g. dev/test deployments). Bundles tokens back into
    // change, which may bust max-tx-size if scripts are large; the throw
    // path below catches that case explicitly.
    const tokenUsable = allUtxos
      .filter(u =>
        !u.scriptRef &&
        Object.keys(u.assets).length > 1 &&
        (u.assets.lovelace as bigint) >= 2_000_000n,
      )
      .sort((a, b) =>
        Number((b.assets.lovelace as bigint) - (a.assets.lovelace as bigint)),
      );
    for (const u of tokenUsable) {
      picked.push(u);
      acc += u.assets.lovelace as bigint;
      for (const [unit, qty] of Object.entries(u.assets)) {
        if (unit === "lovelace" || qty === 0n) continue;
        changeTokens[unit] = (changeTokens[unit] || 0n) + (qty as bigint);
      }
      if (acc >= targetBalance) break;
    }
  }

  if (acc < targetBalance) {
    throw new Error(
      `insufficient UTXOs: need ${Number(targetBalance)/1e6} ADA, have ${Number(acc)/1e6} ADA. ` +
      `Check wallet balance and faucet if on Preprod.`,
    );
  }

  /** Build CML MultiAsset from aggregated token map (mixed-asset bundling). */
  function buildChangeMultiAsset(): any {
    const multiAsset = CML.MultiAsset.new();
    const policyMap = new Map<string, Map<string, bigint>>();
    for (const [unit, qty] of Object.entries(changeTokens)) {
      if (qty === 0n) continue;
      const policyId = unit.slice(0, 56);
      const assetName = unit.slice(56);
      if (!policyMap.has(policyId)) policyMap.set(policyId, new Map());
      policyMap.get(policyId)!.set(assetName, qty);
    }
    for (const [policyId, assetEntries] of policyMap) {
      const policyAssets = CML.MapAssetNameToCoin.new();
      for (const [assetName, qty] of assetEntries) {
        policyAssets.insert(CML.AssetName.from_hex(assetName || ""), qty);
      }
      multiAsset.insert_assets(CML.ScriptHash.from_hex(policyId), policyAssets);
    }
    return multiAsset;
  }

  // Build inputs (sorted)
  const sorted = [...picked].sort((a, b) => a.txHash.localeCompare(b.txHash) || a.outputIndex - b.outputIndex);
  const inputs = CML.TransactionInputList.new();
  for (const u of sorted) {
    inputs.add(CML.TransactionInput.new(CML.TransactionHash.from_hex(u.txHash), BigInt(u.outputIndex)));
  }

  // Build outputs: one script_ref output per script, plus one change output
  const outputs = CML.TransactionOutputList.new();
  const scriptOutputIndexes: number[] = [];
  for (let i = 0; i < scripts.length; i++) {
    const s = scripts[i];
    if (s.type !== "PlutusV3") throw new Error(`only PlutusV3 supported, got ${s.type}`);
    const wrapped = applyDoubleCborEncoding(s.script);
    const out = CML.TransactionOutputBuilder.new()
      .with_address(refAddrCml)
      .with_data(CML.DatumOption.new_datum(CML.PlutusData.new_bytes(new Uint8Array())))
      .with_reference_script(CML.Script.new_plutus_v3(CML.PlutusV3Script.from_cbor_hex(wrapped)))
      .next()
      .with_value(CML.Value.new(outputLovelaces[i], CML.MultiAsset.new()))
      .build()
      .output();
    scriptOutputIndexes.push(i);
    outputs.add(out);
  }

  // Placeholder change output (for sizing)
  // Mixed-asset bundling: bundle aggregated input tokens into change so mixed-asset
  // inputs don't leak value (they would otherwise be burned).
  // Reserve 15 ADA in placeholder change so the draft TX size estimate
  // accounts for a token-bundled change output (matches the run-time
  // change min-UTXO under Conway minUtxoValue rules with ~200 tokens).
  const placeholderChange = acc - totalOutputLovelace - 15_000_000n;
  outputs.add(CML.TransactionOutput.new(addrCml, CML.Value.new(placeholderChange, buildChangeMultiAsset())));

  const reqSigners = CML.Ed25519KeyHashList.new();
  reqSigners.add(CML.Ed25519KeyHash.from_hex(walletPkh));

  function buildBody(fee: bigint, changeAmt: bigint): CML.TransactionBody {
    const outs = CML.TransactionOutputList.new();
    // Re-add script outputs from originals
    for (let i = 0; i < scripts.length; i++) {
      outs.add(outputs.get(i));
    }
    // Mixed-asset bundling: preserve input tokens in change output
    outs.add(CML.TransactionOutput.new(addrCml, CML.Value.new(changeAmt, buildChangeMultiAsset())));
    const body = CML.TransactionBody.new(inputs, outs, fee);
    body.set_validity_interval_start(BigInt(currentSlot - 120));
    body.set_ttl(BigInt(currentSlot + 900));
    body.set_required_signers(reqSigners);
    return body;
  }

  // First pass: estimate fee using draft body
  const draftBody = buildBody(500_000n, placeholderChange);
  const ws = CML.TransactionWitnessSet.new();
  const draftTx = CML.Transaction.new(draftBody, ws, true);
  const draftSize = BigInt(draftTx.to_cbor_hex().length / 2);

  // Conway fee: a*size + b + refScriptFee (tiered, multiplier ~15)
  const totalScriptBytes = scripts.reduce((sum, s) => sum + BigInt(applyDoubleCborEncoding(s.script).length / 2), 0n);
  const sizeFee = 44n * (draftSize + 120n) + 155381n;
  const refScriptFee = 30n * totalScriptBytes; // empirical upper bound
  let estFee = sizeFee + refScriptFee + 100_000n; // safety margin

  // Build TX with estimated fee, then submit — retry on fee mismatch
  for (let attempt = 0; attempt < 3; attempt++) {
    const changeAmt = acc - totalOutputLovelace - estFee;
    // Require >= 10 ADA change to cover the worst-case token-bundle
    // min-UTXO. Lower thresholds work when the wallet has pure-ADA
    // UTxOs but fail on the V1-preprod-p5 wallet shape where every
    // input UTxO carries tokens that cascade into change.
    if (changeAmt < 10_000_000n) throw new Error(`change too small: ${changeAmt} (need >=10 ADA for token bundle min-UTXO)`);
    const body = buildBody(estFee, changeAmt);
    const unsigned = CML.Transaction.new(body, ws, true);
    const unsignedCbor = unsigned.to_cbor_hex();

    const witnessSet = await lucid.wallet().signTx(CML.Transaction.from_cbor_hex(unsignedCbor));
    const signed = CML.Transaction.new(body, witnessSet, true);
    const signedCbor = signed.to_cbor_hex();

    try {
      const txHash = await submitViaBf(signedCbor, blockfrostUrl, blockfrostKey);
      return scriptOutputIndexes.map(i => ({ txHash, outputIndex: i }));
    } catch (err: any) {
      const errStr = err.message || String(err);
      // Parse Blockfrost fee error: "ConwayNotEnoughFundsForFee (Coin REQUIRED) (Coin PROVIDED)"
      const feeMatch = errStr.match(/NotEnoughFundsForFee[^(]*\(Coin (\d+)\)/i)
        || errStr.match(/"minimumRequiredFee"[^}]*"lovelace":(\d+)/);
      if (feeMatch) {
        const requiredFee = BigInt(feeMatch[1]);
        estFee = requiredFee + 10_000n; // tiny margin
        continue;
      }
      throw new Error(`submit failed: ${errStr.slice(0, 2000)}`);
    }
  }
  throw new Error("failed after 3 fee-adjustment attempts");
}
