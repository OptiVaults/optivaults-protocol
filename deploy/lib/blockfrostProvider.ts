/**
 * Blockfrost provider wrapper with:
 * 1. Binary CBOR evaluation endpoint (avoids Ogmios tag 258 rejection)
 * 2. Dual-key rotation on 402/429 errors
 * 3. Retry with delay on HTML/rate-limit responses
 * 4. Protocol parameters caching (1 request per session)
 * 5. Null Conway-era field handling (drep_deposit, gov_action_deposit)
 * 6. Ogmios fallback for protocol params when Blockfrost exhausted
 */
import { Blockfrost } from "@lucid-evolution/lucid";
import { scriptFromNative, applyDoubleCborEncoding } from "@lucid-evolution/utils";

/** Convert Ogmios costModels (plutus:v1 arrays) → Blockfrost format (PlutusV1 objects) */
function convertOgmosCostModels(cm: any): any {
  if (!cm) return undefined;
  const result: any = {};
  const mapping: Record<string, string> = { "plutus:v1": "PlutusV1", "plutus:v2": "PlutusV2", "plutus:v3": "PlutusV3" };
  for (const [ogKey, bfKey] of Object.entries(mapping)) {
    const arr = cm[ogKey];
    if (Array.isArray(arr)) {
      const obj: Record<string, number> = {};
      for (let i = 0; i < arr.length; i++) obj[String(i)] = arr[i];
      result[bfKey] = obj;
    }
  }
  return Object.keys(result).length > 0 ? result : undefined;
}

export function createBlockfrostProvider(url: string, primaryKey: string, backupKey?: string, ogmiosUrl?: string) {
  const keys = [primaryKey, backupKey].filter(Boolean) as string[];
  let currentKeyIdx = 0;
  let bf: any = new Blockfrost(url, keys[currentKeyIdx]);

  // ── Protocol params cache (saves ~8 requests per reinitLucid) ──
  let cachedProtocolParams: any = null;

  function currentKey() { return keys[currentKeyIdx]; }

  function rotateKey() {
    if (keys.length > 1) {
      currentKeyIdx = (currentKeyIdx + 1) % keys.length;
      // Mutate the existing bf object in place — reassigning would not update
      // the caller's reference (used by Lucid).
      bf.projectId = keys[currentKeyIdx];
    }
  }

  function isRateLimitError(msg: string): boolean {
    return msg.includes("402") || msg.includes("429") || msg.includes("403")
      || msg.includes("Over Limit") || msg.includes("over limit")
      || msg.includes("non-JSON") || msg.includes("<html")
      || msg.includes("Unexpected token '<'") || msg.includes("Unexpected token");
  }

  function patchEval() {
    bf.evaluateTx = async (tx: string, _additionalUTxOs?: any) => {
      // Strip CBOR tag 258 (d90102) before set/array/map markers — Lucid
      // Evolution emits these around input/output sets, but Blockfrost's
      // Ogmios evaluator returns empty `ScriptFailures: {}` when it sees them.
      // Pattern: `d90102` followed by array (8x, 9x) OR map (ax, bx) major
      // type byte. Matches the same transform used by the reference keeper.
      const stripped = tx.replace(/d90102([89ab][0-9a-f])/g, "$1");
      const cborBytes = Buffer.from(stripped, "hex");

      const doEval = async () => {
        const res = await fetch(`${url}/utils/txs/evaluate`, {
          method: "POST",
          headers: { "Content-Type": "application/cbor", project_id: currentKey() },
          body: cborBytes,
          signal: AbortSignal.timeout(30000),
        });

        const text = await res.text();
        if (text.trimStart().startsWith("<")) {
          throw new Error(`Blockfrost eval returned non-JSON (HTML): ${text.slice(0, 100)}`);
        }

        let data: any;
        try { data = JSON.parse(text); } catch { throw new Error(`Blockfrost eval returned non-JSON: ${text.slice(0, 200)}`); }

        if (data.status_code && data.status_code >= 400) {
          throw new Error(`Blockfrost eval error ${data.status_code}: ${data.message || JSON.stringify(data).slice(0, 300)}`);
        }
        if (data.fault) {
          throw new Error(`Ogmios eval fault: ${JSON.stringify(data.fault).slice(0, 500)}`);
        }

        const evalResult = data?.result?.EvaluationResult;
        if (!evalResult) {
          if (data?.result?.EvaluationFailure) {
            throw new Error(`EvaluateTransaction fails: ${JSON.stringify(data.result.EvaluationFailure).slice(0, 1000)}`);
          }
          throw new Error(`Unexpected eval response: ${JSON.stringify(data).slice(0, 500)}`);
        }

        const tagMap: Record<string, string> = {
          "spending": "spend", "minting": "mint", "withdrawal": "withdraw",
          "publishing": "publish", "voting": "vote", "proposing": "propose",
        };
        const redeemers: any[] = [];
        for (const [pointer, budget] of Object.entries(evalResult)) {
          const [rawTag, idx] = pointer.split(":");
          const tag = tagMap[rawTag] || rawTag;
          const b = budget as any;
          redeemers.push({ redeemer_tag: tag, redeemer_index: Number(idx), ex_units: { mem: b.memory, steps: b.steps } });
        }
        return redeemers;
      };

      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          return await doEval();
        } catch (err: any) {
          const msg = String(err?.message || err);
          if (isRateLimitError(msg) && attempt < 2) {
            rotateKey();
            await new Promise(r => setTimeout(r, 2000 * (attempt + 1)));
            continue;
          }
          throw err;
        }
      }
    };
  }

  function patchProtocolParams() {
    bf.getProtocolParameters = async () => {
      // Return cached params if available (saves 1 Blockfrost request per Lucid init)
      if (cachedProtocolParams) return cachedProtocolParams;

      const doFetch = async () => {
        const res = await fetch(`${url}/epochs/latest/parameters`, {
          headers: { project_id: currentKey() },
          signal: AbortSignal.timeout(15000),
        });
        const text = await res.text();
        if (text.trimStart().startsWith("<")) {
          throw new Error(`Blockfrost params returned HTML: ${text.slice(0, 100)}`);
        }
        let result: any;
        try { result = JSON.parse(text); } catch { throw new Error(`Blockfrost params non-JSON: ${text.slice(0, 200)}`); }
        if (result.status_code && result.status_code >= 400) {
          throw new Error(`Blockfrost params error ${result.status_code}: ${result.message}`);
        }
        return result;
      };

      let result: any;
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          result = await doFetch();
          break;
        } catch (err: any) {
          const errMsg = String(err?.message || err);
          if (isRateLimitError(errMsg) && attempt < 2) {
            rotateKey();
            await new Promise(r => setTimeout(r, 2000 * (attempt + 1)));
            continue;
          }
          // Fallback to Ogmios for protocol params if Blockfrost exhausted
          const ogmiosEndpoint = ogmiosUrl || process.env.OGMIOS_URL;
          if (ogmiosEndpoint && isRateLimitError(errMsg)) {
            try {
              const ogmiosRes = await fetch(ogmiosEndpoint, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ jsonrpc: "2.0", method: "queryLedgerState/protocolParameters", id: null }),
                signal: AbortSignal.timeout(10000),
              });
              const ogmiosData = await ogmiosRes.json() as any;
              const pp = ogmiosData?.result;
              if (pp) {
                result = {
                  min_fee_a: pp.minFeeCoefficient,
                  min_fee_b: pp.minFeeConstant?.ada?.lovelace ?? pp.minFeeConstant,
                  max_tx_size: pp.maxTransactionSize?.bytes ?? pp.maxTransactionSize,
                  max_val_size: pp.maxValueSize?.bytes ?? pp.maxValueSize,
                  key_deposit: pp.stakeCredentialDeposit?.ada?.lovelace ?? pp.stakeCredentialDeposit,
                  pool_deposit: pp.stakePoolDeposit?.ada?.lovelace ?? pp.stakePoolDeposit,
                  drep_deposit: pp.delegateRepresentativeDeposit?.ada?.lovelace ?? pp.delegateRepresentativeDeposit ?? "500000000",
                  gov_action_deposit: pp.governanceActionDeposit?.ada?.lovelace ?? pp.governanceActionDeposit ?? "100000000000",
                  price_mem: pp.scriptExecutionPrices?.memory ? (() => { const [n, d] = pp.scriptExecutionPrices.memory.split("/"); return Number(n) / Number(d); })() : 0.0577,
                  price_step: pp.scriptExecutionPrices?.cpu ? (() => { const [n, d] = pp.scriptExecutionPrices.cpu.split("/"); return Number(n) / Number(d); })() : 0.0000721,
                  max_tx_ex_mem: pp.maxExecutionUnitsPerTransaction?.memory ?? "14000000",
                  max_tx_ex_steps: pp.maxExecutionUnitsPerTransaction?.cpu ?? "10000000000",
                  coins_per_utxo_size: pp.minUtxoDepositCoefficient ?? "4310",
                  collateral_percent: pp.collateralPercentage ?? 150,
                  max_collateral_inputs: pp.maxCollateralInputs ?? 3,
                  min_fee_ref_script_cost_per_byte: pp.minFeeReferenceScripts?.base ?? "15",
                  cost_models: convertOgmosCostModels(pp.plutusCostModels),
                };
                break;
              }
            } catch { /* Ogmios also failed */ }
          }
          throw err;
        }
      }

      // Build Lucid-compatible params with null safety
      cachedProtocolParams = {
        minFeeA: parseInt(result.min_fee_a),
        minFeeB: parseInt(result.min_fee_b),
        maxTxSize: parseInt(result.max_tx_size),
        maxValSize: parseInt(result.max_val_size),
        keyDeposit: BigInt(result.key_deposit ?? "2000000"),
        poolDeposit: BigInt(result.pool_deposit ?? "500000000"),
        drepDeposit: BigInt(result.drep_deposit ?? "500000000"),
        govActionDeposit: BigInt(result.gov_action_deposit ?? "100000000000"),
        priceMem: parseFloat(result.price_mem),
        priceStep: parseFloat(result.price_step),
        maxTxExMem: BigInt(result.max_tx_ex_mem ?? "14000000"),
        maxTxExSteps: BigInt(result.max_tx_ex_steps ?? "10000000000"),
        coinsPerUtxoByte: BigInt(result.coins_per_utxo_size ?? "4310"),
        collateralPercentage: parseInt(result.collateral_percent ?? "150"),
        maxCollateralInputs: parseInt(result.max_collateral_inputs ?? "3"),
        minFeeRefScriptCostPerByte: parseInt(result.min_fee_ref_script_cost_per_byte ?? "15"),
        costModels: result.cost_models,
      };
      return cachedProtocolParams;
    };
  }

  /**
   * Patch getUtxos with per-page retry + key rotation.
   * Lucid's built-in Blockfrost provider throws "Could not fetch UTxOs" on any
   * page failure, which is brittle for wallets with many UTXOs (>100) or
   * transient Blockfrost errors. This wrapper retries each page up to 3 times
   * with key rotation.
   */
  function patchGetUtxos() {
    const wrapWithRetry = (fnName: string) => {
      const original = bf[fnName]?.bind(bf);
      if (!original) return;
      bf[fnName] = async (...args: any[]) => {
        for (let attempt = 0; attempt < 5; attempt++) {
          try {
            return await original(...args);
          } catch (err: any) {
            const msg = String(err?.message || err);
            // Lucid's generic "Could not fetch" hides the real error (often 402/429)
            // — always rotate key on this error since the primary is likely exhausted.
            const shouldRetry = attempt < 4 && (
              isRateLimitError(msg) ||
              msg.includes("Could not fetch UTxOs") ||
              msg.includes("Could not fetch")
            );
            if (shouldRetry) {
              rotateKey();
              await new Promise(r => setTimeout(r, 2000 * (attempt + 1)));
              continue;
            }
            throw err;
          }
        }
        throw new Error(`${fnName}: max retries exhausted`);
      };
    };
    wrapWithRetry("getUtxos");
    wrapWithRetry("getUtxosWithUnit");
    wrapWithRetry("getUtxoByUnit");
    wrapWithRetry("getUtxosByOutRef");

    // Post-retry filter: strip ref script UTXOs from results when
    // SKIP_SCRIPT_REF_RESOLVE=1 to avoid Blockfrost /scripts/<hash>/cbor
    // failures for wallets that hold large ref script UTXOs (e.g. the
    // keeper wallet after deploying 6 validators to its own address).
    if (process.env.SKIP_SCRIPT_REF_RESOLVE === "1") {
      const origGetUtxos = bf.getUtxos?.bind(bf);
      if (origGetUtxos) {
        bf.getUtxos = async (...args: any[]) => {
          const utxos = await origGetUtxos(...args);
          return utxos.filter((u: any) => !u.scriptRef);
        };
      }
    }
  }

  /**
   * Patch `blockfrostUtxosToUtxos` to cache reference-script fetches.
   *
   * Root cause of the Blockfrost `scripts` endpoint abuse (observed
   * 50K+ calls/day — 98% of total quota): Lucid Evolution's stock
   * implementation calls `/scripts/<hash>` and `/scripts/<hash>/cbor`
   * (and `/scripts/<hash>/json` for native scripts) for EVERY UTXO
   * with a `reference_script_hash` on EVERY `getUtxos*` call. There
   * is no deduplication across a single call batch and no session
   * cache, so hot-path keeper flows that re-query the same addresses
   * burn the daily Blockfrost quota in hours.
   *
   * Scripts are content-addressed (the hash is the script), so a
   * session-wide cache is always correct. This patch:
   *   1. Deduplicates script fetches within a single getUtxos call —
   *      multiple UTXOs referencing the same script only fetch once.
   *   2. Persists across calls via an instance-level Map so repeat
   *      queries for the same vault / ref-script address are free.
   *
   * Result: the `/scripts/*` call count drops from O(utxos_with_refs
   * × getUtxos_calls) to O(unique_script_hashes_ever_seen), typically
   * a 10-100x reduction for a keeper running against a handful of
   * deployed ref scripts.
   */
  const scriptCache = new Map<string, any>();

  function patchScriptCache() {
    const originalMethod = bf.blockfrostUtxosToUtxos?.bind(bf);
    if (!originalMethod) return;

    async function resolveScriptRef(refHash: string): Promise<any> {
      const cached = scriptCache.get(refHash);
      if (cached !== undefined) return cached;
      const headers = { project_id: currentKey(), lucid: "lucid" };
      const { type } = await fetch(`${url}/scripts/${refHash}`, { headers }).then((res) => res.json());
      const { cbor: script } = await fetch(`${url}/scripts/${refHash}/cbor`, { headers }).then((res) => res.json());
      let resolved: any;
      switch (type) {
        case "timelock": {
          const { json: native } = await fetch(`${url}/scripts/${refHash}/json`, { headers }).then((res) => res.json());
          resolved = scriptFromNative(native);
          break;
        }
        case "plutusV1":
          resolved = { type: "PlutusV1", script: applyDoubleCborEncoding(script) };
          break;
        case "plutusV2":
          resolved = { type: "PlutusV2", script: applyDoubleCborEncoding(script) };
          break;
        case "plutusV3":
          resolved = { type: "PlutusV3", script: applyDoubleCborEncoding(script) };
          break;
        default:
          resolved = undefined;
      }
      scriptCache.set(refHash, resolved);
      return resolved;
    }

    bf.blockfrostUtxosToUtxos = async function (result: any[]) {
      const batchSize = 10;
      const utxos: any[] = [];
      for (let i = 0; i < result.length; i += batchSize) {
        const batch = result.slice(i, i + batchSize);
        const mapped = await Promise.all(
          batch.map(async (r: any) => ({
            txHash: r.tx_hash,
            outputIndex: r.output_index,
            assets: Object.fromEntries(
              r.amount.map(({ unit, quantity }: any) => [unit, BigInt(quantity)]),
            ),
            address: r.address,
            datumHash: !r.inline_datum && r.data_hash || undefined,
            datum: r.inline_datum || undefined,
            scriptRef: r.reference_script_hash
              ? (process.env.SKIP_SCRIPT_REF_RESOLVE === "1" ? { type: "PlutusV3" as const, script: "skip" } : await resolveScriptRef(r.reference_script_hash))
              : undefined,
          })),
        );
        utxos.push(...mapped);
      }
      return utxos;
    };
  }

  function patchAll() {
    patchEval();
    patchProtocolParams();
    patchGetUtxos();
    patchScriptCache();
  }

  patchAll();
  return bf;
}
