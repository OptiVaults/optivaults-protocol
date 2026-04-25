/**
 * verify-minswap-v2-decode.ts — byte-for-byte verifier for the pre-R74
 * Minswap V2 adapter's datum decoder.
 *
 * ⚠️ SUPERSEDED BY R74 F-1 FIX (2026-04-24).
 *
 * The adapter used to claim `lp_asset` is a 2-asset pair and derive the
 * target asset from it. This was wrong — Minswap V2's `lp_asset` is a
 * single LP-token identifier, not a pair. The R74 fix replaces target
 * derivation with `hop_chain` commitment + on-chain LP-name re-hash via
 * `compute_lp_asset_name` (see `contracts/validators/minswap_v2_adapter.ak`
 * and the project SECURITY.md "Known open findings" section).
 *
 * This file is retained for historical reference of the pre-R74 assumption.
 * It will FAIL on every real Minswap V2 order because the pair-extraction
 * assumption is false on-chain — that failure is itself evidence the R74
 * fix is needed.
 *
 * The current replacement — which verifies the NEW adapter logic against
 * real mainnet datums — is:
 *
 *     v1/tests/preprod/60-minswap-decoder-verify.ts
 *
 * Run that instead.
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

interface CliArgs {
  network: "Preprod" | "Mainnet";
  txHash: string;
  outputIndex: number;
  expectedMinReceive?: bigint;
  expectedTargetPolicy?: string;
  expectedTargetName?: string;
}

function parseArgs(): CliArgs {
  const a = process.argv.slice(2);
  let network: CliArgs["network"] = "Preprod";
  let txHash: string | undefined;
  let outputIndex = 0;
  let expectedMinReceive: bigint | undefined;
  let expectedTargetPolicy: string | undefined;
  let expectedTargetName: string | undefined;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--network") network = a[++i] as CliArgs["network"];
    else if (a[i] === "--txHash") txHash = a[++i];
    else if (a[i] === "--outputIndex") outputIndex = parseInt(a[++i], 10);
    else if (a[i] === "--expectedMinReceive") expectedMinReceive = BigInt(a[++i]);
    else if (a[i] === "--expectedTargetPolicy") expectedTargetPolicy = a[++i];
    else if (a[i] === "--expectedTargetName") expectedTargetName = a[++i];
  }
  if (!txHash) {
    console.error("Usage: --network <Preprod|Mainnet> --txHash <hex> [--outputIndex N]");
    console.error("       [--expectedMinReceive N] [--expectedTargetPolicy hex] [--expectedTargetName hex]");
    process.exit(1);
  }
  return { network, txHash, outputIndex, expectedMinReceive, expectedTargetPolicy, expectedTargetName };
}

// ─────────────────────────────────────────────────────────────────────
// Minimal Plutus Data CBOR decoder.
// We decode only the structural forms used by Minswap V2 order datums:
//   Constr(tag, fields)  — CBOR tag 121..127 (small) or 102 (large),
//                           payload is an indefinite or definite array
//                           of Plutus Data.
//   ByteString           — CBOR major type 2.
//   Int                  — CBOR major type 0 or 1 (optionally tagged 2/3
//                           for bigints, but stablecoin + min_receive
//                           values fit in 64 bits).
//   List<Data>           — CBOR major type 4.
//   Map<Data, Data>      — not expected inside Minswap V2 OrderDatum.
// ─────────────────────────────────────────────────────────────────────

type PlutusData =
  | { type: "constr"; tag: number; fields: PlutusData[] }
  | { type: "bytes"; hex: string }
  | { type: "int"; value: bigint }
  | { type: "list"; items: PlutusData[] }
  | { type: "map"; entries: Array<{ key: PlutusData; value: PlutusData }> };

class CborDecoder {
  private pos = 0;
  constructor(private readonly buf: Buffer) {}

  private readHead(): { major: number; info: number; value: bigint } {
    const byte = this.buf[this.pos++];
    const major = byte >> 5;
    const info = byte & 0x1f;
    let value: bigint = BigInt(info);
    if (info === 24) {
      value = BigInt(this.buf[this.pos++]);
    } else if (info === 25) {
      value = BigInt(this.buf.readUInt16BE(this.pos));
      this.pos += 2;
    } else if (info === 26) {
      value = BigInt(this.buf.readUInt32BE(this.pos));
      this.pos += 4;
    } else if (info === 27) {
      value = this.buf.readBigUInt64BE(this.pos);
      this.pos += 8;
    }
    return { major, info, value };
  }

  private readBytes(length: number): Buffer {
    const out = this.buf.subarray(this.pos, this.pos + length);
    this.pos += length;
    return out;
  }

  private decodeArrayItems(count: bigint | "indefinite"): PlutusData[] {
    const items: PlutusData[] = [];
    if (count === "indefinite") {
      while (this.buf[this.pos] !== 0xff) items.push(this.decode());
      this.pos++; // consume break
    } else {
      for (let i = 0n; i < count; i++) items.push(this.decode());
    }
    return items;
  }

  decode(): PlutusData {
    const h = this.readHead();
    switch (h.major) {
      case 0: // unsigned int
        return { type: "int", value: h.value };
      case 1: // negative int
        return { type: "int", value: -1n - h.value };
      case 2: { // bytes
        let length: bigint | "indefinite" = h.value;
        if (h.info === 31) {
          // indefinite-length byte chunks
          const chunks: Buffer[] = [];
          while (this.buf[this.pos] !== 0xff) {
            const inner = this.readHead();
            chunks.push(this.readBytes(Number(inner.value)));
          }
          this.pos++;
          return { type: "bytes", hex: Buffer.concat(chunks).toString("hex") };
        }
        return { type: "bytes", hex: this.readBytes(Number(length)).toString("hex") };
      }
      case 4: { // array
        const count = h.info === 31 ? ("indefinite" as const) : h.value;
        const items = this.decodeArrayItems(count);
        return { type: "list", items };
      }
      case 5: { // map
        const count = h.info === 31 ? ("indefinite" as const) : h.value;
        const entries: Array<{ key: PlutusData; value: PlutusData }> = [];
        if (count === "indefinite") {
          while (this.buf[this.pos] !== 0xff) {
            const k = this.decode();
            const v = this.decode();
            entries.push({ key: k, value: v });
          }
          this.pos++;
        } else {
          for (let i = 0n; i < count; i++) {
            entries.push({ key: this.decode(), value: this.decode() });
          }
        }
        return { type: "map", entries };
      }
      case 6: { // tagged
        const tag = Number(h.value);
        if (tag >= 121 && tag <= 127) {
          // Plutus compact Constr (tags 121..127 = constructor 0..6)
          const arrHead = this.readHead();
          const items = this.decodeArrayItems(arrHead.info === 31 ? "indefinite" : arrHead.value);
          return { type: "constr", tag: tag - 121, fields: items };
        }
        if (tag >= 1280 && tag <= 1400) {
          // Plutus compact Constr second range (tags 1280..1400 = constructor 7..127)
          const arrHead = this.readHead();
          const items = this.decodeArrayItems(arrHead.info === 31 ? "indefinite" : arrHead.value);
          return { type: "constr", tag: tag - 1280 + 7, fields: items };
        }
        if (tag === 102) {
          // Plutus general Constr: payload is [uint, array]
          const arrHead = this.readHead();
          if (arrHead.major !== 4) throw new Error(`tag 102 expected array, got major=${arrHead.major}`);
          const tagHead = this.readHead();
          if (tagHead.major !== 0) throw new Error(`tag 102 first element must be uint`);
          const constrTag = Number(tagHead.value);
          const innerHead = this.readHead();
          const items = this.decodeArrayItems(innerHead.info === 31 ? "indefinite" : innerHead.value);
          return { type: "constr", tag: constrTag, fields: items };
        }
        // Other tags (2/3 bigint, 24 encoded CBOR) — not expected here
        throw new Error(`unsupported CBOR tag: ${tag}`);
      }
      case 7: {
        if (h.info === 20) return { type: "constr", tag: 0, fields: [] };  // false (Aiken Bool)
        if (h.info === 21) return { type: "constr", tag: 1, fields: [] };  // true (Aiken Bool)
        throw new Error(`unsupported CBOR simple/float major=7 info=${h.info}`);
      }
      default:
        throw new Error(`unsupported CBOR major type: ${h.major}`);
    }
  }
}

function parsePlutusData(cborHex: string): PlutusData {
  const buf = Buffer.from(cborHex, "hex");
  const d = new CborDecoder(buf);
  return d.decode();
}

// ─────────────────────────────────────────────────────────────────────
// Minswap V2 order datum decoder — mirrors
// validators/minswap_v2_adapter.ak::extract_minswap_v2_order.
// ─────────────────────────────────────────────────────────────────────

interface Decoded {
  minReceive: bigint;
  targetPolicy: string;
  targetName: string;
  stepVariant: "SwapExactIn" | "SwapMultiRouting";
  aToB: boolean;
}

function expectConstr(d: PlutusData, tag?: number): { tag: number; fields: PlutusData[] } {
  if (d.type !== "constr") throw new Error(`expected Constr, got ${d.type}`);
  if (tag !== undefined && d.tag !== tag) throw new Error(`expected Constr(${tag}), got Constr(${d.tag})`);
  return { tag: d.tag, fields: d.fields };
}
function expectBytes(d: PlutusData): string {
  if (d.type !== "bytes") throw new Error(`expected bytes, got ${d.type}`);
  return d.hex;
}
function expectInt(d: PlutusData): bigint {
  if (d.type !== "int") throw new Error(`expected int, got ${d.type}`);
  return d.value;
}

function extractTargetFromLp(lp: PlutusData, aToB: boolean): { policy: string; name: string } {
  const lpConstr = expectConstr(lp, 0);
  const fields = lpConstr.fields;
  if (fields.length === 4) {
    // Variant A: flat (policy_a, name_a, policy_b, name_b)
    const policy = aToB ? expectBytes(fields[2]) : expectBytes(fields[0]);
    const name = aToB ? expectBytes(fields[3]) : expectBytes(fields[1]);
    return { policy, name };
  } else if (fields.length === 2) {
    // Variant B: nested pair of Assets
    const targetPair = aToB ? fields[1] : fields[0];
    const assetConstr = expectConstr(targetPair, 0);
    if (assetConstr.fields.length !== 2) throw new Error(`Variant B asset inner must have 2 fields`);
    return { policy: expectBytes(assetConstr.fields[0]), name: expectBytes(assetConstr.fields[1]) };
  } else {
    throw new Error(`lp_asset unexpected field count: ${fields.length}`);
  }
}

function decodeStep(step: PlutusData, lpAsset: PlutusData): Decoded {
  const stepConstr = expectConstr(step);
  const f = stepConstr.fields;

  if (stepConstr.tag === 0) {
    // SwapExactIn: [a_to_b_bool, swap_amount, minimum_receive, killable_bool]
    if (f.length !== 4) throw new Error(`SwapExactIn expected 4 fields, got ${f.length}`);
    const aToBConstr = expectConstr(f[0]);
    const aToB = aToBConstr.tag === 1;
    const minRecv = expectInt(f[2]);
    const target = extractTargetFromLp(lpAsset, aToB);
    return {
      minReceive: minRecv,
      targetPolicy: target.policy,
      targetName: target.name,
      stepVariant: "SwapExactIn",
      aToB,
    };
  }

  if (stepConstr.tag === 9) {
    // SwapMultiRouting: [swap_routing (list of SwapRoute), swap_amount, minimum_receive]
    if (f.length !== 3) throw new Error(`SwapMultiRouting expected 3 fields, got ${f.length}`);
    if (f[0].type !== "list") throw new Error(`swap_routing must be list`);
    const routes = f[0].items;
    if (routes.length === 0) throw new Error(`swap_routing empty`);
    const lastRoute = routes[routes.length - 1];
    const lastConstr = expectConstr(lastRoute, 0);
    if (lastConstr.fields.length !== 2) throw new Error(`SwapRoute must have 2 fields`);
    const aToBConstr = expectConstr(lastConstr.fields[1]);
    const aToB = aToBConstr.tag === 1;
    const minRecv = expectInt(f[2]);
    const target = extractTargetFromLp(lastConstr.fields[0], aToB);
    return {
      minReceive: minRecv,
      targetPolicy: target.policy,
      targetName: target.name,
      stepVariant: "SwapMultiRouting",
      aToB,
    };
  }

  throw new Error(`unsupported step tag: ${stepConstr.tag} (not a swap — rejected by adapter)`);
}

function decodeMinswapV2Order(datumHex: string): Decoded {
  const data = parsePlutusData(datumHex);
  const outer = expectConstr(data, 0);
  // OrderDatum layout:
  //   0: canceller  1: refund_addr  2: refund_datum
  //   3: success_addr  4: success_datum
  //   5: lp_asset
  //   6: step
  //   7: max_batcher_fee  8: expire_opt
  if (outer.fields.length !== 9) {
    throw new Error(`OrderDatum expected 9 fields, got ${outer.fields.length}`);
  }
  return decodeStep(outer.fields[6], outer.fields[5]);
}

// ─────────────────────────────────────────────────────────────────────
// Main — fetch TX, extract output datum, decode, compare
// ─────────────────────────────────────────────────────────────────────

async function fetchOutputDatumCbor(
  network: CliArgs["network"],
  txHash: string,
  outputIndex: number,
): Promise<string> {
  const bfUrl = network === "Preprod"
    ? "https://cardano-preprod.blockfrost.io/api/v0"
    : "https://cardano-mainnet.blockfrost.io/api/v0";
  const bfKey = network === "Preprod"
    ? process.env.BLOCKFROST_API_KEY_PREPROD
    : process.env.BLOCKFROST_API_KEY;
  if (!bfKey) throw new Error(`Missing Blockfrost key for ${network}`);

  const utxosRes = await fetch(`${bfUrl}/txs/${txHash}/utxos`, {
    headers: { project_id: bfKey },
  });
  if (!utxosRes.ok) {
    throw new Error(`Blockfrost ${utxosRes.status}: ${await utxosRes.text()}`);
  }
  const utxos: any = await utxosRes.json();
  const out = utxos.outputs?.[outputIndex];
  if (!out) throw new Error(`output index ${outputIndex} not found in TX`);
  if (out.inline_datum) return out.inline_datum;

  // Fallback: datum_hash → fetch raw datum
  if (!out.data_hash) {
    throw new Error(`output has no inline_datum and no data_hash`);
  }
  const datumRes = await fetch(`${bfUrl}/scripts/datum/${out.data_hash}/cbor`, {
    headers: { project_id: bfKey },
  });
  if (!datumRes.ok) {
    throw new Error(`Blockfrost datum ${datumRes.status}: ${await datumRes.text()}`);
  }
  const datumBody: any = await datumRes.json();
  return datumBody.cbor;
}

async function main() {
  const args = parseArgs();
  console.log(`Network:      ${args.network}`);
  console.log(`TX hash:      ${args.txHash}`);
  console.log(`Output idx:   ${args.outputIndex}`);

  const cborHex = await fetchOutputDatumCbor(args.network, args.txHash, args.outputIndex);
  console.log(`Datum CBOR:   ${cborHex.slice(0, 80)}${cborHex.length > 80 ? "..." : ""}`);
  console.log(`Datum bytes:  ${cborHex.length / 2}`);

  const decoded = decodeMinswapV2Order(cborHex);
  console.log(`\n── Decoded ──`);
  console.log(`step_variant:        ${decoded.stepVariant}`);
  console.log(`a_to_b_direction:    ${decoded.aToB}`);
  console.log(`min_receive:         ${decoded.minReceive}`);
  console.log(`target_asset_policy: ${decoded.targetPolicy || "(empty = ADA)"}`);
  console.log(`target_asset_name:   ${decoded.targetName || "(empty = ADA)"}`);

  let ok = true;
  if (args.expectedMinReceive !== undefined) {
    const match = decoded.minReceive === args.expectedMinReceive;
    console.log(`\nexpected min_receive:  ${args.expectedMinReceive} — ${match ? "✅ MATCH" : "❌ MISMATCH"}`);
    ok = ok && match;
  }
  if (args.expectedTargetPolicy !== undefined) {
    const match = decoded.targetPolicy.toLowerCase() === args.expectedTargetPolicy.toLowerCase();
    console.log(`expected target_policy: ${args.expectedTargetPolicy} — ${match ? "✅ MATCH" : "❌ MISMATCH"}`);
    ok = ok && match;
  }
  if (args.expectedTargetName !== undefined) {
    const match = decoded.targetName.toLowerCase() === args.expectedTargetName.toLowerCase();
    console.log(`expected target_name:   ${args.expectedTargetName} — ${match ? "✅ MATCH" : "❌ MISMATCH"}`);
    ok = ok && match;
  }

  if (!ok) {
    console.log(`\n❌ Some expected values did not match the decoded datum.`);
    process.exit(1);
  }
  console.log(`\n✅ Decoded successfully${args.expectedMinReceive !== undefined ? " + expected values match" : ""}.`);
}

main().catch((e) => {
  console.error(`[ERROR] ${(e as Error).message}`);
  if ((e as Error).stack) console.error((e as Error).stack);
  process.exit(1);
});
