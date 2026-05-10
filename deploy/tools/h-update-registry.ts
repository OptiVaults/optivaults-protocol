/**
 * H-UpdateRegistry Queue + Execute.
 *
 * ActionKind = 6. Target = registry script (state.hashes.registryHash).
 * Payload = blake2b_256(cbor.serialise(new RegistryDatum)).
 *
 * RegistryRedeemer.UpdateRegistry = Constr(0, [])   (tag index 0 of RegistryRedeemer).
 * No proxy route (registry is its own spend UTxO, not vault-proxied).
 * No vault continuing output — only the registry UTxO moves.
 *
 * Contract-enforced constraints (registry.ak:65-224):
 *   - governance_policy / governance_name / keeper_pkh IMMUTABLE
 *   - protocol_hashes MUST be non-empty (≤ 20, no duplicates)
 *   - stable_tokens ≤ 50
 *   - liqwid_markets ≤ 20; existing entries' qtoken+underlying immutable;
 *     append-only-by-length; no qtoken collision
 *   - asset_oracles ≤ 20; each structurally well-formed
 *   - swap_adapter_hashes ≤ 10, 28-byte hashes, unique
 *   - Auth NFT + all other tokens preserved (no new token policies)
 *   - 1-hour cooldown on last_update_time
 *   - new_reg.last_update_time == TX validity lower_bound (slot-aligned ms)
 *   - 1-hour validity-range width cap
 *
 * The last_update_time == validity.lower constraint means the tool MUST
 * commit at Queue time to a specific future lower-bound that the Execute
 * TX will use. We pick `targetLowerMs = nowMs + timelockMs + 5min` (ample
 * safety buffer for Blockfrost indexing lag).
 *
 * Usage (E2E helper: add one stable token + seed protocol hash):
 *   npx tsx deploy/tools/h-update-registry.ts --releaseTag <release-tag> \
 *     --addStableToken <policy>.<name>            (can repeat)
 *     --seedProtocolHash <hex28>                   (first run must provide; later opt)
 *     --addLiqwidMarket <inline-json|path>         (can repeat — appends to liqwid_markets)
 *     --addSwapAdapterHash <hex28>                 (can repeat — appends to swap_adapter_hashes)
 *     --addAssetOracle <inline-json|path>          (can repeat — appends to asset_oracles)
 *     --fromMockOracleState <path>                 (reads mock-oracle-preprod.json and auto-injects
 *                                                   ALL `assetEntries` as asset_oracles entries)
 *     --fromMockState <dir>                        (reads mock-liqwid-preprod.json + mock-adapter-preprod.json
 *                                                   from <dir> and auto-injects market + adapter hash + 2 protocol hashes)
 *
 * `--addLiqwidMarket` JSON shape (matching LiqwidMarketEntry in types.ak):
 *   { "action_addr_hash": "<28-hex>",
 *     "qtoken_policy":   "<28-hex>",
 *     "qtoken_name":     "<hex>",
 *     "underlying_policy":"<28-hex>",
 *     "underlying_name": "<hex>",
 *     "active":          true }
 *
 * `--addAssetOracle` JSON shape (matching AssetOracleEntry in types.ak):
 *   { "asset_policy":         "<28-hex or empty for ADA>",
 *     "asset_name":           "<hex or empty for ADA>",
 *     "feeds":                [{ "feed_script_hash":"<28-hex>",
 *                                "feed_auth_policy":"<28-hex or empty>",
 *                                "feed_auth_name":  "<hex or empty>" }, ...],
 *     "max_disagreement_bps": 200,        // (0, 1000] cap
 *     "max_staleness_ms":     600000,     // (0, 3_600_000] cap
 *     "min_feeds":            2 }         // ≥1, ≤feeds.length
 */
import * as dotenv from "dotenv";
import * as fs from "node:fs";
import * as path from "node:path";
dotenv.config({ path: "keeper/.env" });

/**
 * After a successful Execute, the registry UTXO is moved from the old
 * outRef to a new (TX, idx). Tests that read `state.stateUtxos.registry`
 * via `lucid.utxosByOutRef([...])` will fail with "registry state UTXO
 * not found — config drift?" until the state file is updated. This
 * helper writes the new outRef into the JSON in-place so the next test
 * run picks it up automatically.
 */
function flushRegistryStateUtxoUpdate(
  stateFile: string,
  newRegistryOutRef: { txHash: string; outputIndex: number; address: string },
): void {
  const d = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  const old = d.stateUtxos?.registry;
  if (!old) {
    console.log(`  [state-sync] state file has no stateUtxos.registry — skipping flush`);
    return;
  }
  d.stateUtxos.registry = newRegistryOutRef;
  d.lastUpdatedAt = new Date().toISOString();
  fs.writeFileSync(stateFile, JSON.stringify(d, null, 2));
  console.log(`  [state-sync] wrote new registry outRef to ${stateFile} (was ${old.txHash.slice(0,16)}…#${old.outputIndex} → now ${newRegistryOutRef.txHash.slice(0,16)}…#${newRegistryOutRef.outputIndex})`);
}

import { Constr, Data } from "@lucid-evolution/lucid";
import { blake2b } from "@noble/hashes/blake2b";

import {
  initGovCtx,
  queueAction,
  prepareExecute,
  fetchSingleUtxo,
  fetchRefInputs,
  multiSignCbor,
  submitCbor,
  awaitConfirmation,
  stripLucidDatumFields,
} from "./lib/gov-helpers.js";

const ACTION_KIND_UPDATE_REGISTRY = 6;
const REGISTRY_REDEEMER_UPDATE = 0;   // UpdateRegistry
const TIMELOCK_MS = 60_000;
const TTL_MS = 86_400_000;

interface StableTokenEntryJson {
  policy: string;
  name: string;
}

interface LiqwidMarketJson {
  action_addr_hash: string;
  qtoken_policy: string;
  qtoken_name: string;
  underlying_policy: string;
  underlying_name: string;
  active: boolean;
}

interface AssetOracleFeedJson {
  feed_script_hash: string;
  feed_auth_policy: string; // can be ""
  feed_auth_name: string;   // can be ""
}

interface AssetOracleEntryJson {
  asset_policy: string;     // can be "" for ADA
  asset_name: string;       // can be "" for ADA
  feeds: AssetOracleFeedJson[];
  max_disagreement_bps: number;
  max_staleness_ms: number;
  min_feeds: number;
}

function isHex28(h: string): boolean {
  return /^[0-9a-f]{56}$/i.test(h);
}

function isHex28OrEmpty(h: string): boolean {
  return h === "" || /^[0-9a-f]{56}$/i.test(h);
}

function isHexEvenOrEmpty(h: string): boolean {
  return h === "" || /^[0-9a-f]+$/i.test(h);
}

function loadMockStateBundle(dir: string): {
  liqwidMarket: LiqwidMarketJson;
  swapAdapterHash: string;
  protocolHashes: string[];
} {
  const liqwidPath = path.join(dir, "mock-liqwid-preprod.json");
  const adapterPath = path.join(dir, "mock-adapter-preprod.json");
  if (!fs.existsSync(liqwidPath)) throw new Error(`mock-liqwid-preprod.json not found in ${dir}`);
  if (!fs.existsSync(adapterPath)) throw new Error(`mock-adapter-preprod.json not found in ${dir}`);
  const liq = JSON.parse(fs.readFileSync(liqwidPath, "utf8"));
  const ada = JSON.parse(fs.readFileSync(adapterPath, "utf8"));
  const hint = (liq.registryUpdateHint || [])[0];
  if (!hint) throw new Error(`mock-liqwid-preprod.json missing registryUpdateHint[0]`);
  const liqwidMarket: LiqwidMarketJson = {
    action_addr_hash: hint.action_addr_hash,
    qtoken_policy: hint.qtoken_policy,
    qtoken_name: hint.qtoken_name_hex,
    underlying_policy: hint.underlying_policy,
    underlying_name: hint.underlying_name_hex,
    active: !!hint.active,
  };
  const swapAdapterHash = (ada.registryUpdateHint?.swap_adapter_hashes_add) || ada.adapterValidatorHash;
  if (!isHex28(swapAdapterHash)) throw new Error(`mock adapter hash invalid: ${swapAdapterHash}`);
  const protocolHashes: string[] = [];
  if (liq.registryProtocolHashHint && isHex28(liq.registryProtocolHashHint)) {
    protocolHashes.push(liq.registryProtocolHashHint.toLowerCase());
  }
  if (ada.registryUpdateHint?.protocol_hashes_add && isHex28(ada.registryUpdateHint.protocol_hashes_add)) {
    protocolHashes.push((ada.registryUpdateHint.protocol_hashes_add as string).toLowerCase());
  }
  return { liqwidMarket, swapAdapterHash: swapAdapterHash.toLowerCase(), protocolHashes };
}

/**
 * Parse `--addAssetOracle <v>` where v is either:
 *   - inline JSON of AssetOracleEntryJson shape, OR
 *   - path to a JSON file containing same shape
 *
 * Performs client-side cap pre-checks (the on-chain
 * `valid_asset_oracle_entry` re-checks; this catches obvious mistakes
 * pre-submit + before the 1h cooldown wait).
 */
function parseAssetOracleArg(v: string): AssetOracleEntryJson {
  let raw: any;
  if (v.startsWith("{")) {
    raw = JSON.parse(v);
  } else if (fs.existsSync(v)) {
    raw = JSON.parse(fs.readFileSync(v, "utf8"));
  } else {
    throw new Error(`--addAssetOracle ${v} must be inline JSON or path to JSON file`);
  }
  for (const k of ["asset_policy", "asset_name"]) {
    if (typeof raw[k] !== "string") throw new Error(`--addAssetOracle missing string field ${k}`);
  }
  if (!Array.isArray(raw.feeds)) throw new Error(`--addAssetOracle feeds must be array`);
  if (raw.feeds.length === 0) throw new Error(`--addAssetOracle feeds must be non-empty`);
  for (const [i, f] of raw.feeds.entries()) {
    if (typeof f.feed_script_hash !== "string" || !isHex28(f.feed_script_hash)) {
      throw new Error(`--addAssetOracle feeds[${i}].feed_script_hash must be 28-byte hex`);
    }
    if (typeof f.feed_auth_policy !== "string" || !isHex28OrEmpty(f.feed_auth_policy)) {
      throw new Error(`--addAssetOracle feeds[${i}].feed_auth_policy must be 28-byte hex or empty`);
    }
    if (typeof f.feed_auth_name !== "string" || !isHexEvenOrEmpty(f.feed_auth_name)) {
      throw new Error(`--addAssetOracle feeds[${i}].feed_auth_name must be hex or empty`);
    }
  }
  if (!isHex28OrEmpty(raw.asset_policy)) {
    throw new Error(`--addAssetOracle asset_policy must be 28-byte hex or empty (ADA)`);
  }
  if (!isHexEvenOrEmpty(raw.asset_name)) {
    throw new Error(`--addAssetOracle asset_name must be hex or empty (ADA)`);
  }
  if (typeof raw.max_disagreement_bps !== "number" || raw.max_disagreement_bps <= 0 || raw.max_disagreement_bps > 1_000) {
    throw new Error(`--addAssetOracle max_disagreement_bps out of (0, 1000] cap`);
  }
  if (typeof raw.max_staleness_ms !== "number" || raw.max_staleness_ms <= 0 || raw.max_staleness_ms > 3_600_000) {
    throw new Error(`--addAssetOracle max_staleness_ms out of (0, 3_600_000] cap`);
  }
  if (typeof raw.min_feeds !== "number" || raw.min_feeds < 1 || raw.min_feeds > raw.feeds.length) {
    throw new Error(`--addAssetOracle min_feeds must be in [1, feeds.length=${raw.feeds.length}]`);
  }
  return {
    asset_policy: raw.asset_policy.toLowerCase(),
    asset_name: raw.asset_name.toLowerCase(),
    feeds: raw.feeds.map((f: any) => ({
      feed_script_hash: f.feed_script_hash.toLowerCase(),
      feed_auth_policy: f.feed_auth_policy.toLowerCase(),
      feed_auth_name: f.feed_auth_name.toLowerCase(),
    })),
    max_disagreement_bps: raw.max_disagreement_bps,
    max_staleness_ms: raw.max_staleness_ms,
    min_feeds: raw.min_feeds,
  };
}

/**
 * Read mock-oracle-preprod.json and extract every `assetEntries[i].registryUpdateHint`
 * shape into a list of AssetOracleEntryJson, ready for append to the registry's
 * `asset_oracles` list. Lets the operator fire `--fromMockOracleState <path>`
 * once instead of repeating `--addAssetOracle` per asset.
 */
function loadMockOracleStateBundle(p: string): AssetOracleEntryJson[] {
  if (!fs.existsSync(p)) throw new Error(`mock-oracle state file not found at ${p}`);
  const raw = JSON.parse(fs.readFileSync(p, "utf8"));
  if (!Array.isArray(raw.assetEntries)) throw new Error(`${p} missing assetEntries array`);
  if (raw.assetEntries.length === 0) {
    throw new Error(`${p}::assetEntries is empty — run mock-oracle-init.ts first`);
  }
  return raw.assetEntries.map((e: any) => parseAssetOracleArg(JSON.stringify(e.registryUpdateHint)));
}

function parseLiqwidMarketArg(v: string): LiqwidMarketJson {
  // Accept either inline JSON or a path to a JSON file with the 6 fields.
  let raw: any;
  if (v.startsWith("{")) {
    raw = JSON.parse(v);
  } else if (fs.existsSync(v)) {
    raw = JSON.parse(fs.readFileSync(v, "utf8"));
  } else {
    throw new Error(`--addLiqwidMarket ${v} must be inline JSON or path to JSON file`);
  }
  for (const k of ["action_addr_hash", "qtoken_policy", "qtoken_name", "underlying_policy", "underlying_name"]) {
    if (typeof raw[k] !== "string") throw new Error(`--addLiqwidMarket missing string field ${k}`);
  }
  if (typeof raw.active !== "boolean") throw new Error(`--addLiqwidMarket active must be boolean`);
  if (!isHex28(raw.action_addr_hash)) throw new Error(`action_addr_hash must be 28-byte hex`);
  if (!isHex28(raw.qtoken_policy)) throw new Error(`qtoken_policy must be 28-byte hex`);
  if (!isHex28(raw.underlying_policy) && raw.underlying_policy !== "") throw new Error(`underlying_policy must be 28-byte hex or empty`);
  return {
    action_addr_hash: raw.action_addr_hash.toLowerCase(),
    qtoken_policy: raw.qtoken_policy.toLowerCase(),
    qtoken_name: raw.qtoken_name.toLowerCase(),
    underlying_policy: raw.underlying_policy.toLowerCase(),
    underlying_name: raw.underlying_name.toLowerCase(),
    active: raw.active,
  };
}

function parseRegArgs(): {
  addStableTokens: StableTokenEntryJson[];
  seedProtocolHashes: string[];
  addLiqwidMarkets: LiqwidMarketJson[];
  addSwapAdapterHashes: string[];
  addAssetOracles: AssetOracleEntryJson[];
  /** Optional override of the computed targetLowerMs. Use to reuse a
   * previously-Queued action whose payload_hash was bound to a specific
   * last_update_time (e.g. the Execute leg failed mid-flight). */
  forcedTargetLowerMs?: bigint;
} {
  const a = process.argv.slice(2);
  const addStableTokens: StableTokenEntryJson[] = [];
  const seedProtocolHashes: string[] = [];
  const addLiqwidMarkets: LiqwidMarketJson[] = [];
  const addSwapAdapterHashes: string[] = [];
  const addAssetOracles: AssetOracleEntryJson[] = [];
  let forcedTargetLowerMs: bigint | undefined;
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--addStableToken") {
      const v = a[++i];
      const dot = v.indexOf(".");
      if (dot < 0) throw new Error(`--addStableToken ${v} must be policy.name`);
      addStableTokens.push({ policy: v.slice(0, dot), name: v.slice(dot + 1) });
    } else if (a[i] === "--seedProtocolHash") {
      const h = a[++i];
      if (!isHex28(h)) throw new Error(`--seedProtocolHash ${h} must be 28-byte hex`);
      seedProtocolHashes.push(h.toLowerCase());
    } else if (a[i] === "--addLiqwidMarket") {
      addLiqwidMarkets.push(parseLiqwidMarketArg(a[++i]));
    } else if (a[i] === "--addSwapAdapterHash") {
      const h = a[++i];
      if (!isHex28(h)) throw new Error(`--addSwapAdapterHash ${h} must be 28-byte hex`);
      addSwapAdapterHashes.push(h.toLowerCase());
    } else if (a[i] === "--addAssetOracle") {
      addAssetOracles.push(parseAssetOracleArg(a[++i]));
    } else if (a[i] === "--fromMockOracleState") {
      const p = a[++i];
      for (const e of loadMockOracleStateBundle(p)) addAssetOracles.push(e);
    } else if (a[i] === "--fromMockState") {
      const dir = a[++i];
      const bundle = loadMockStateBundle(dir);
      addLiqwidMarkets.push(bundle.liqwidMarket);
      addSwapAdapterHashes.push(bundle.swapAdapterHash);
      for (const h of bundle.protocolHashes) seedProtocolHashes.push(h);
    } else if (a[i] === "--targetLowerMs") {
      const v = a[++i];
      if (!/^[0-9]+$/.test(v)) throw new Error(`--targetLowerMs ${v} must be a positive integer (ms)`);
      forcedTargetLowerMs = BigInt(v);
    }
  }
  return { addStableTokens, seedProtocolHashes, addLiqwidMarkets, addSwapAdapterHashes, addAssetOracles, forcedTargetLowerMs };
}

/**
 * Rebuild RegistryDatum as a Constr matching types.ak 9-field layout.
 *
 * LiqwidMarketEntry is encoded as Constr(0, [
 *   action_addr_hash,         // ByteArray
 *   qtoken_policy,            // ByteArray
 *   qtoken_name,              // ByteArray
 *   underlying_policy,        // ByteArray
 *   underlying_name,          // ByteArray
 *   active,                   // Bool — Constr(1,[]) for True, Constr(0,[]) for False
 * ])
 */
function buildLiqwidMarketEntry(m: LiqwidMarketJson): Constr<Data> {
  return new Constr(0, [
    m.action_addr_hash,
    m.qtoken_policy,
    m.qtoken_name,
    m.underlying_policy,
    m.underlying_name,
    new Constr(m.active ? 1 : 0, []) as unknown as Data,
  ]);
}

/**
 * Build an AssetOracleFeed Constr matching types.ak:
 *   AssetOracleFeed = Constr(0, [
 *     feed_script_hash:  ByteArray,
 *     feed_auth_policy:  ByteArray,
 *     feed_auth_name:    ByteArray,
 *   ])
 */
function buildAssetOracleFeed(f: AssetOracleFeedJson): Constr<Data> {
  return new Constr(0, [f.feed_script_hash, f.feed_auth_policy, f.feed_auth_name]);
}

/**
 * Build an AssetOracleEntry Constr matching types.ak:
 *   AssetOracleEntry = Constr(0, [
 *     asset_policy:          ByteArray,
 *     asset_name:            ByteArray,
 *     feeds:                 List<AssetOracleFeed>,
 *     max_disagreement_bps:  Int,
 *     max_staleness_ms:      Int,
 *     min_feeds:             Int,
 *   ])
 *
 * Field order: registry.ak::valid_asset_oracle_entry decodes via
 * `e.feeds`, `e.min_feeds`, `e.max_disagreement_bps`, `e.max_staleness_ms`
 * — Aiken accessor order doesn't constrain Constr layout. Layout follows
 * types.ak declaration order (asset_policy / asset_name / feeds /
 * max_disagreement_bps / max_staleness_ms / min_feeds).
 */
function buildAssetOracleEntry(e: AssetOracleEntryJson): Constr<Data> {
  return new Constr(0, [
    e.asset_policy,
    e.asset_name,
    e.feeds.map((f) => buildAssetOracleFeed(f)) as unknown as Data,
    BigInt(e.max_disagreement_bps),
    BigInt(e.max_staleness_ms),
    BigInt(e.min_feeds),
  ]);
}

function buildRegistryDatum(
  oldFields: any[],
  newProtocolHashes: string[],
  newStableTokens: StableTokenEntryJson[],
  newLiqwidMarketsRaw: any[],
  newSwapAdapterHashes: string[],
  newAssetOraclesRaw: any[],
  lastUpdateMs: bigint,
): string {
  const stableList = newStableTokens.map((st) =>
    new Constr(0, [st.policy, st.name]),
  );
  const data = new Constr(0, [
    oldFields[0],                  // 0: governance_policy (immutable)
    oldFields[1],                  // 1: governance_name   (immutable)
    newProtocolHashes,             // 2: protocol_hashes
    stableList,                    // 3: stable_tokens
    newLiqwidMarketsRaw,           // 4: liqwid_markets (append-only via UpdateRegistry)
    newAssetOraclesRaw,            // 5: asset_oracles (append-only with dedup by asset)
    newSwapAdapterHashes,          // 6: swap_adapter_hashes
    lastUpdateMs,                  // 7: last_update_time (binds to validity.lower)
    oldFields[8],                  // 8: keeper_pkh (immutable)
  ]);
  return Data.to(data as unknown as Data);
}

function payloadHashUpdateRegistry(registryDatumCbor: string): string {
  return Buffer.from(blake2b(Buffer.from(registryDatumCbor, "hex"), { dkLen: 32 })).toString("hex");
}

async function main() {
  const { addStableTokens, seedProtocolHashes, addLiqwidMarkets, addSwapAdapterHashes, addAssetOracles, forcedTargetLowerMs } = parseRegArgs();
  console.log(`H-UpdateRegistry: addStableTokens=${addStableTokens.length}, seedProtocolHashes=${seedProtocolHashes.length}, addLiqwidMarkets=${addLiqwidMarkets.length}, addSwapAdapterHashes=${addSwapAdapterHashes.length}, addAssetOracles=${addAssetOracles.length}` + (forcedTargetLowerMs !== undefined ? `, forcedTargetLowerMs=${forcedTargetLowerMs}` : ""));

  const ctx = await initGovCtx();
  const { state, lucid, bfUrl, bfKey, mnemonic } = ctx;

  const targetHash = state.hashes.registryHash;
  if (!targetHash) throw new Error("registryHash not in state");
  console.log(`target (registry): ${targetHash}`);

  // Fetch current registry UTxO + datum.
  //
  // Registry validator is unparameterized → same script address is reused
  // across all ceremonies (p2/p5/p6/p7-trace/p8-trace/p9-trace/p10-clean
  // etc.). Filter by the ceremony-specific registry auth NFT to disambiguate.
  const registryAddr = state.stateUtxos.registry.address;
  const authPolicy = state.mints.registryAuthNft?.policyId;
  const authName = state.mints.registryAuthNft?.assetName;
  if (!authPolicy || !authName) throw new Error("state.mints.registryAuthNft missing policyId/assetName");
  const authUnit = `${authPolicy}${authName}`;
  const regCandidates = await lucid.utxosAt(registryAddr);
  const regMatches = regCandidates.filter((u) => (u.assets as any)[authUnit] === 1n);
  if (regMatches.length !== 1) {
    throw new Error(`expected exactly 1 UTxO at registry holding auth NFT ${authUnit.slice(0,32)}…, got ${regMatches.length} (out of ${regCandidates.length} total at addr)`);
  }
  const regIn = regMatches[0];
  const oldReg = Data.from(regIn.datum!) as any;
  const oldFields = oldReg.fields as any[];
  console.log(`  current registry: protocol_hashes=${(oldFields[2] as string[]).length}, stable_tokens=${(oldFields[3] as any[]).length}, liqwid_markets=${(oldFields[4] as any[]).length}, asset_oracles=${(oldFields[5] as any[]).length}, swap_adapter_hashes=${(oldFields[6] as string[]).length}, last_update_time=${oldFields[7]}`);

  // Enforce contract-level 1-hour cooldown off-chain early exit
  const oldLastUpdateMs = BigInt(oldFields[7] as bigint);
  const earliestAllowedLowerMs = oldLastUpdateMs + 3_600_000n;
  const nowMs = BigInt(Date.now());
  if (nowMs < earliestAllowedLowerMs) {
    const waitMs = Number(earliestAllowedLowerMs - nowMs);
    console.log(`  registry 1h cooldown not yet satisfied (${waitMs}ms remaining); will wait after Queue confirms`);
  }

  // Merge new + existing protocol_hashes (dedup, contract enforces uniqueness + cap 20)
  const oldProtoHashes = oldFields[2] as string[];
  const newProtocolHashes: string[] = [
    ...oldProtoHashes,
    ...seedProtocolHashes.filter((h) => !oldProtoHashes.includes(h)),
  ];
  if (newProtocolHashes.length === 0) {
    throw new Error(`registry protocol_hashes must be non-empty; pass --seedProtocolHash on first run`);
  }
  if (newProtocolHashes.length > 20) {
    throw new Error(`protocol_hashes count ${newProtocolHashes.length} exceeds cap 20`);
  }

  // Merge stable_tokens (contract cap 50, no dup check on-chain but dedup off-chain to be safe)
  const existingStables = oldFields[3] as any[];
  const existingStableKeys = new Set(existingStables.map((s: any) => `${s.fields[0]}.${s.fields[1]}`));
  const newStableEntries: StableTokenEntryJson[] = [
    ...existingStables.map((s: any) => ({ policy: s.fields[0] as string, name: s.fields[1] as string })),
    ...addStableTokens.filter((s) => !existingStableKeys.has(`${s.policy}.${s.name}`)),
  ];

  // Merge liqwid_markets (contract: cap 20, append-only-by-length, no qtoken_policy+name collision)
  const existingMarkets = oldFields[4] as any[];
  const existingMarketKeys = new Set(
    existingMarkets.map((m: any) => `${m.fields[1]}.${m.fields[2]}`), // qtoken_policy.qtoken_name
  );
  const liqwidToAppend = addLiqwidMarkets.filter(
    (m) => !existingMarketKeys.has(`${m.qtoken_policy}.${m.qtoken_name}`),
  );
  const newLiqwidMarketsRaw: any[] = [
    ...existingMarkets,
    ...liqwidToAppend.map((m) => buildLiqwidMarketEntry(m)),
  ];
  if (newLiqwidMarketsRaw.length > 20) {
    throw new Error(`liqwid_markets count ${newLiqwidMarketsRaw.length} exceeds cap 20`);
  }

  // Merge swap_adapter_hashes (contract: cap 10, unique 28-byte hashes)
  const oldAdapterHashes = oldFields[6] as string[];
  const newSwapAdapterHashes: string[] = [
    ...oldAdapterHashes,
    ...addSwapAdapterHashes.filter((h) => !oldAdapterHashes.includes(h)),
  ];
  if (newSwapAdapterHashes.length > 10) {
    throw new Error(`swap_adapter_hashes count ${newSwapAdapterHashes.length} exceeds cap 10`);
  }

  // Merge asset_oracles (contract: cap 20, structurally well-formed per
  // dedup by (asset_policy, asset_name) — registry's own
  // valid_asset_oracle_entry checks structural sanity but does not enforce
  // uniqueness on (asset_policy, asset_name); we dedup off-chain to avoid
  // committing duplicate entries that would silently conflict on the
  // first-match-wins lookup in lib/vault/oracle.ak::find_asset_oracle).
  const existingOracles = oldFields[5] as any[];
  const existingOracleKeys = new Set(
    existingOracles.map((o: any) => `${o.fields[0]}.${o.fields[1]}`),
  );
  const oraclesToAppend = addAssetOracles.filter(
    (e) => !existingOracleKeys.has(`${e.asset_policy}.${e.asset_name}`),
  );
  // Detect intra-batch dup: caller passes the same (policy, name) twice.
  {
    const seen = new Set<string>();
    for (const e of oraclesToAppend) {
      const k = `${e.asset_policy}.${e.asset_name}`;
      if (seen.has(k)) {
        throw new Error(
          `--addAssetOracle batch contains duplicate (asset_policy, asset_name) pair ${k} — split into separate UpdateRegistry calls`,
        );
      }
      seen.add(k);
    }
  }
  const newAssetOraclesRaw: any[] = [
    ...existingOracles,
    ...oraclesToAppend.map((e) => buildAssetOracleEntry(e)),
  ];
  if (newAssetOraclesRaw.length > 20) {
    throw new Error(`asset_oracles count ${newAssetOraclesRaw.length} exceeds cap 20`);
  }

  // Pick a target last_update_time: nowMs + timelockMs + 5min safety buffer.
  // If registry cooldown hasn't elapsed yet, push further.
  // If caller passed --targetLowerMs, reuse exactly (recovery from a prior
  // failed Execute leg whose Queue is still in the m-of-n queue).
  //
  // slotAlignUp ceils to the next slot boundary
  // (NOT truncates). Aiken's `now >= reg.last_update_time + one_hour_ms`
  // requires `targetLowerMs >= earliestAllowedLowerMs`. Floor-align would
  // truncate sub-slot precision (e.g. last_update_time = 1777294547426ms
  // → earliestAllowed = 1777298147426ms; floor → 1777298147000ms which is
  // 426ms SHORT of the cooldown). p10-clean's last_update_time happened
  // to be slot-aligned by luck; p11-trace exposed the bug.
  const slotAlignUp = (ms: bigint) => ((ms + 999n) / 1000n) * 1000n;
  const candidate = nowMs + BigInt(TIMELOCK_MS) + BigInt(5 * 60_000);
  const targetLowerMs = forcedTargetLowerMs !== undefined
    ? slotAlignUp(forcedTargetLowerMs)
    : slotAlignUp(candidate < earliestAllowedLowerMs ? earliestAllowedLowerMs : candidate);
  console.log(`  targetLowerMs (=new last_update_time): ${targetLowerMs} (${new Date(Number(targetLowerMs)).toISOString()})${forcedTargetLowerMs !== undefined ? " [FORCED via --targetLowerMs]" : ""}`);

  // Build the new RegistryDatum with the committed last_update_time
  const newRegistryDatumCbor = buildRegistryDatum(
    oldFields,
    newProtocolHashes,
    newStableEntries,
    newLiqwidMarketsRaw,
    newSwapAdapterHashes,
    newAssetOraclesRaw,
    targetLowerMs,
  );
  const payloadHashHex = payloadHashUpdateRegistry(newRegistryDatumCbor);
  console.log(`  payload_hash: ${payloadHashHex}`);

  // ─── Queue ───────────────────────────────────────────────────────────
  const qResult = await queueAction({
    ctx,
    actionKind: ACTION_KIND_UPDATE_REGISTRY,
    targetHash,
    payloadHashHex,
    timelockMs: TIMELOCK_MS,
    ttlMs: TTL_MS,
    label: "UpdateRegistry",
  });

  // ─── Execute ─────────────────────────────────────────────────────────
  console.log(`\n=== Step 2: Execute UpdateRegistry ===`);
  const ec = await prepareExecute(ctx, qResult.actionId, qResult, targetLowerMs);
  if (ec.lowerMs !== targetLowerMs) {
    throw new Error(`validity lower mismatch: committed ${targetLowerMs}, got ${ec.lowerMs}`);
  }

  // Registry redeemer = UpdateRegistry (Constr 0)
  const registryRedeemer = Data.to(new Constr(REGISTRY_REDEEMER_UPDATE, []) as unknown as Data);

  const refs = await fetchRefInputs(lucid, [
    { txHash: state.refScripts.multisigGov.txHash, outputIndex: state.refScripts.multisigGov.outputIndex },
    { txHash: state.refScripts.registry.txHash, outputIndex: state.refScripts.registry.outputIndex },
  ]);

  const execTx = lucid
    .newTx()
    .collectFrom([stripLucidDatumFields(ec.govIn)], ec.redeemerExec)
    .collectFrom([stripLucidDatumFields(regIn)], registryRedeemer)
    .readFrom(refs)
    .pay.ToAddressWithData(
      ec.govAddr,
      { kind: "inline", value: ec.newGovDatumE as unknown as string },
      ec.govIn.assets,
    )
    .pay.ToAddressWithData(
      registryAddr,
      { kind: "inline", value: newRegistryDatumCbor as unknown as string },
      regIn.assets,
    )
    .validFrom(Number(ec.lowerMs))
    .validTo(Number(ec.upperMs))
    .addSignerKey(ec.gov.signers[0])
    .addSignerKey(ec.gov.signers[1]);

  // localUPLCEval:false
  // routes Plutus script eval through the active provider (Blockfrost
  // /utils/txs/evaluate or Ogmios evaluateTransaction). Mandatory because
  // mainnet has no Ogmios infrastructure — production code must work via
  // Blockfrost only. Lucid local UPLC eval has a generic-crash bug.
  const built = await execTx.complete({ localUPLCEval: false });
  const eCbor = await multiSignCbor(built.toCBOR(), mnemonic, ctx.signingAccounts);
  const execTxHash = await submitCbor(bfUrl, bfKey, eCbor);
  console.log(`  ✅ Execute TX: ${execTxHash}`);

  await awaitConfirmation(bfUrl, bfKey, execTxHash, "Execute", 180);

  // After confirmation, registry UTXO has moved. Update state file so
  // downstream tests don't hit "registry state UTXO not found — config drift?"
  // Output index is 1 in the Execute TX above (gov continuing = idx 0,
  // registry continuing = idx 1).
  flushRegistryStateUtxoUpdate(ctx.stateFile, {
    txHash: execTxHash,
    outputIndex: 1,
    address: registryAddr,
  });

  console.log(`\nPASS — H-UpdateRegistry Queue+Execute`);
  if (qResult.queueTxHash) console.log(`  queue:   ${qResult.queueTxHash}`);
  console.log(`  execute: ${execTxHash}`);
  console.log(`  action_id: ${qResult.actionId}`);
  console.log(
    `  applied: protocol_hashes ${(oldFields[2] as string[]).length}→${newProtocolHashes.length} | ` +
    `stable_tokens ${(oldFields[3] as any[]).length}→${newStableEntries.length} | ` +
    `liqwid_markets ${(oldFields[4] as any[]).length}→${newLiqwidMarketsRaw.length} | ` +
    `swap_adapter_hashes ${(oldFields[6] as string[]).length}→${newSwapAdapterHashes.length} | ` +
    `asset_oracles ${(oldFields[5] as any[]).length}→${newAssetOraclesRaw.length}`,
  );
}

main().catch((e) => {
  console.error("[ERROR]", (e as Error).message);
  if ((e as Error).stack) console.error((e as Error).stack);
  process.exit(1);
});
