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
 * Get current slot from Blockfrost /blocks/latest.
 */
async function getCurrentSlot(blockfrostUrl: string, blockfrostKey: string): Promise<number> {
  const res = await fetch(`${blockfrostUrl}/blocks/latest`, {
    headers: { project_id: blockfrostKey },
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) throw new Error(`Blockfrost /blocks/latest failed: ${res.status}`);
  const data = await res.json() as any;
  const slot = data.slot as number;
  if (!slot) throw new Error("Cannot get current slot from Blockfrost");
  return slot;
}

/**
 * Submit TX via Blockfrost /tx/submit.
 * Returns TX hash on success, throws on error.
 */
async function submitViaBf(
  signedCbor: string,
  blockfrostUrl: string,
  blockfrostKey: string,
): Promise<string> {
  const cborBytes = Buffer.from(signedCbor, "hex");
  const res = await fetch(`${blockfrostUrl}/tx/submit`, {
    method: "POST",
    headers: {
      "Content-Type": "application/cbor",
      project_id: blockfrostKey,
    },
    body: cborBytes,
    signal: AbortSignal.timeout(30000),
  });
  const body = await res.text();
  if (res.ok) {
    // Blockfrost returns the TX hash as a JSON string (with quotes)
    return body.replace(/"/g, "").trim();
  }
  // Return raw error for caller to parse
  throw new Error(body);
}

export async function deployRefScripts(
  lucid: LucidEvolution,
  scripts: Script[],
  outputLovelaces: bigint[],
  blockfrostUrl: string,
  blockfrostKey: string,
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

  // R64 F-2 FIX: accept mixed-asset UTXOs and bundle tokens into change.
  //
  // Pre-R64 this helper required `Object.keys(u.assets).length === 1`
  // (pure ADA), which falsely rejected the operator's wallet mid-deploy
  // after Pass 0 / Gov Step 1 had produced change UTXOs carrying
  // vaultNftUnit / govNftUnit / TestUSDC alongside lovelace. Operators
  // had to manually consolidate UTXOs before each deploy, and the error
  // message ("insufficient clean lovelace UTXOs") was misleading because
  // `getBalance()` reported ample funds.
  //
  // Post-R64: accept any non-scriptRef UTXO with >= 2 ADA, aggregate
  // non-lovelace tokens, and bundle them into the change output via
  // CML MultiAsset. Scripts are still locked pure-ADA at the script
  // address (ref script outputs unchanged), only the change output is
  // enriched.
  const allUtxos = prefetchedUtxos || await lucid.wallet().getUtxos();
  // R64 F-2 follow-up: prefer pure-ADA UTXOs so large ref-script TXs (e.g.
  // vault_protocol at ~15.6 KB) don't bloat past 16,384 B max tx size via
  // mixed-asset change bundling. Token-carrying UTXOs are still accepted as
  // fallback when pure-ADA alone cannot cover targetBalance.
  const usableUtxos = allUtxos
    .filter(u => !u.scriptRef && (u.assets.lovelace as bigint) >= 2_000_000n)
    .sort((a, b) => {
      const aTokens = Object.keys(a.assets).length > 1 ? 1 : 0;
      const bTokens = Object.keys(b.assets).length > 1 ? 1 : 0;
      if (aTokens !== bTokens) return aTokens - bTokens; // pure-ADA (0) first
      return Number((b.assets.lovelace as bigint) - (a.assets.lovelace as bigint));
    });

  const totalOutputLovelace = outputLovelaces.reduce((a, b) => a + b, 0n);
  const targetBalance = totalOutputLovelace + 3_000_000n; // +3 ADA for fee + change minUTXO

  const picked: UTxO[] = [];
  let acc = 0n;
  const changeTokens: Record<string, bigint> = {}; // unit -> qty aggregated from picked inputs
  for (const u of usableUtxos) {
    picked.push(u);
    acc += u.assets.lovelace as bigint;
    for (const [unit, qty] of Object.entries(u.assets)) {
      if (unit === "lovelace" || qty === 0n) continue;
      changeTokens[unit] = (changeTokens[unit] || 0n) + (qty as bigint);
    }
    if (acc >= targetBalance) break;
  }
  if (acc < targetBalance) {
    throw new Error(
      `insufficient UTXOs: need ${Number(targetBalance)/1e6} ADA, have ${Number(acc)/1e6} ADA. ` +
      `Check wallet balance and faucet if on Preprod.`
    );
  }

  /** Build CML MultiAsset from aggregated token map (R64 F-2). */
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
  // R64 F-2: bundle aggregated input tokens into change so mixed-asset
  // inputs don't leak value (they would otherwise be burned).
  const placeholderChange = acc - totalOutputLovelace - 2_000_000n;
  outputs.add(CML.TransactionOutput.new(addrCml, CML.Value.new(placeholderChange, buildChangeMultiAsset())));

  const reqSigners = CML.Ed25519KeyHashList.new();
  reqSigners.add(CML.Ed25519KeyHash.from_hex(walletPkh));

  function buildBody(fee: bigint, changeAmt: bigint): CML.TransactionBody {
    const outs = CML.TransactionOutputList.new();
    // Re-add script outputs from originals
    for (let i = 0; i < scripts.length; i++) {
      outs.add(outputs.get(i));
    }
    // R64 F-2: preserve input tokens in change output
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
    if (changeAmt < 1_000_000n) throw new Error(`change too small: ${changeAmt}`);
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
      throw new Error(`submit failed: ${errStr.slice(0, 400)}`);
    }
  }
  throw new Error("failed after 3 fee-adjustment attempts");
}
