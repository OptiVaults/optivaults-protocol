/**
 * V1 deploy config loader.
 *
 * Reads config/<network>.json, validates required fields, and exports
 * a typed DeployConfig used by compile.ts and deploy.ts.
 *
 * Mainnet and Preprod share the same schema — only values differ.
 * This keeps the deploy pipeline parameterised rather than forked.
 */
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

// ESM shim: `__dirname` doesn't exist under tsx/Node.js ESM; derive it from
// `import.meta.url`.
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export type NetworkName = "Preprod" | "Mainnet";

export interface DeployConfig {
  network: NetworkName;
  blockfrost: {
    url: string;
    /** Inline Blockfrost project id. Takes precedence over projectIdEnv. */
    projectId?: string;
    /** Env var name to read project id from (preferred — keeps secrets out of config). */
    projectIdEnv?: string;
    projectIdBackup?: string;
    projectIdBackupEnv?: string;
  };
  wallet: {
    /** Inline BIP39 mnemonic (dev/test only). Prefer keyDaemonSocket for real deploys. */
    seedPhrase?: string;
    /** Env var name containing BIP39 mnemonic (dev/test). */
    seedPhraseEnv?: string;
    /**
     * Path to a Unix socket that serves the mnemonic via `GET_MNEMONIC`
     * query (see scripts/admin/preprod-consolidate-utxos.ts for the protocol).
     * Preferred for any real Preprod / Mainnet deploy.
     */
    keyDaemonSocket?: string;
  };
  depositToken: {
    policy: string;
    name: string;
    decimals: number;
  };
  governance: {
    signers: string[];
    threshold: number;
    distributePeriodMs: number;
    governanceNftAssetName: string;
    registryAuthAssetName: string;
  };
  vaultInitialParams: {
    performanceFeeBps: number;
    earlyWithdrawFeeBps: number;
    minHoldSeconds: number;
    bufferTargetBps: number;
    keeperFeeBps: number;
    govFeeBps: number;
    /**
     * §5.4 P2 Tier 1 oracle fair-price slippage bound. Hard cap 500 bps
     * (5%). Active only when RegistryDatum.asset_oracles has an entry
     * for the swap's output asset; V1 launches with empty asset_oracles
     * so this is initially inactive until governance populates feeds.
     */
    maxSlippageBps: number;
    /**
     * §5.4 P2 Tier 2 peg-floor. Always active. Rejects any DEX swap
     * whose `min_receive` falls below `deploy_amount × min_swap_peg_bps
     * / 10_000`. Validator-enforced range [9300, 9950] bps (93-99.5%).
     * V1 launch recommendation: 9900 (99%).
     */
    minSwapPegBps: number;
    vaultVersion: number;
    seedLovelace: number;
  };
  treasuryInitialParams: {
    auditBps: number;
    opsBps: number;
    rdBps: number;
    bufferBps: number;
    monthlyCapAudit: number;
    monthlyCapOps: number;
    monthlyCapRd: number;
    monthlyCapBuffer: number;
    minAuditReserve: number;
  };
  keeperAuthInitialParams: {
    registrationMode: "GovernanceOnly" | "Mixed" | "PermissionlessWithBond";
    authorizedPkhs: string[];
    bondAmountRequired: number;
    cooldownMs: number;
    maxAuthorizedCount: number;
    rotationPeriodMs: number;
    failoverWindowMs: number;
  };
  registryInitialParams: {
    protocolHashes: string[];
    stableTokens: { policy: string; name: string }[];
    liqwidMarkets: LiqwidMarketEntry[];
    keeperPkh: string;
    /**
     * §B@launch=1 (2026-04-22) — optional override for the initial
     * `swap_adapter_hashes` whitelist. If omitted, buildRegistryDatum
     * defaults to `[minswap_v2_adapter_hash]` (the only adapter at V1
     * launch). Governance can add new adapters post-launch via
     * `UpdateRegistry` (14d timelock + 1-of-n cancel).
     */
    swapAdapterHashes?: string[];
  };
  ceremonyOptions: {
    refScriptMinAdaMultiplier: number;
    mintDeadlineSlotOffsetMs: number;
    awaitConfirmSeconds: number;
  };
}

export interface LiqwidMarketEntry {
  actionAddrHash: string;
  qtokenPolicy: string;
  qtokenName: string;
  underlyingPolicy: string;
  underlyingName: string;
  active: boolean;
}

const PLACEHOLDER_PATTERNS = [
  /REPLACE_WITH_/i,
  /YOUR_KEY_HERE/i,
  /NEVER_COMMIT_THIS_FILE/i,
  /TBD/,
  /MAINNET_SIGNER_/,
  /MAINNET_SEED_PHRASE/,
  /MAINNET_FOUNDER_KEEPER/,
  /PREPROD_SIGNER_/i,
  /PREPROD_KEEPER_PKH/i,
  /word1 word2/,
];

function isPlaceholder(s: string): boolean {
  return PLACEHOLDER_PATTERNS.some((p) => p.test(s));
}

function expectHex(name: string, s: string, bytes?: number): void {
  if (!/^[0-9a-f]*$/i.test(s)) {
    throw new Error(
      `config.${name}: expected hex string, got ${JSON.stringify(s)}`,
    );
  }
  if (bytes !== undefined && s.length !== bytes * 2) {
    throw new Error(
      `config.${name}: expected ${bytes}-byte hex (${bytes * 2} chars), got ${s.length} chars`,
    );
  }
}

function expectPositive(name: string, v: number): void {
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0) {
    throw new Error(`config.${name}: expected non-negative number, got ${v}`);
  }
}

/**
 * Load and validate config/<network>.json.
 *
 * Validation catches the common mistakes:
 *   - Unreplaced placeholder strings
 *   - Non-hex policy / PKH fields
 *   - Wrong byte count on fields that have a canonical size (28-byte hash)
 *   - Threshold outside [2, signer_count]
 *   - Fee bps above the validator hard caps (4.5% / 25% / 10% / 6h)
 *   - Treasury inflow bps not summing to 10000
 */
export function loadConfig(
  network: NetworkName,
  configDir?: string,
): DeployConfig {
  const dir = configDir ?? path.join(__dirname, "..", "config");
  const filename = `${network.toLowerCase()}.json`;
  const filePath = path.join(dir, filename);
  if (!fs.existsSync(filePath)) {
    throw new Error(
      `Config not found: ${filePath}. Copy ${filename.replace(".json", ".example.json")} to ${filename} and fill in the values.`,
    );
  }
  const raw = fs.readFileSync(filePath, "utf8");
  let cfg: DeployConfig;
  try {
    cfg = JSON.parse(raw) as DeployConfig;
  } catch (e) {
    throw new Error(`Config ${filePath} is not valid JSON: ${(e as Error).message}`);
  }

  // --- network identity ---
  if (cfg.network !== network) {
    throw new Error(
      `Config file says network=${cfg.network} but loader was asked for ${network}`,
    );
  }

  // --- Blockfrost ---
  const bf = cfg.blockfrost;
  const projectId = bf.projectId ?? (bf.projectIdEnv ? process.env[bf.projectIdEnv] : undefined);
  if (!projectId) {
    throw new Error(
      `config.blockfrost: set either projectId (inline) or projectIdEnv (env var name). Got neither.`,
    );
  }
  if (isPlaceholder(projectId)) {
    throw new Error("config.blockfrost.projectId resolves to a placeholder");
  }
  const expectedPrefix = network === "Preprod" ? "preprod" : "mainnet";
  if (!projectId.startsWith(expectedPrefix)) {
    throw new Error(
      `config.blockfrost projectId must start with "${expectedPrefix}" — caught wrong-network key`,
    );
  }
  // Normalise onto cfg.blockfrost.projectId so downstream code has a single field.
  bf.projectId = projectId;
  if (bf.projectIdBackup && isPlaceholder(bf.projectIdBackup)) {
    throw new Error(
      "config.blockfrost.projectIdBackup is a placeholder — either remove it or fill it in",
    );
  }
  if (!bf.projectIdBackup && bf.projectIdBackupEnv) {
    bf.projectIdBackup = process.env[bf.projectIdBackupEnv];
  }

  // --- wallet ---
  const w = cfg.wallet;
  const hasKeyDaemon = !!w.keyDaemonSocket && !isPlaceholder(w.keyDaemonSocket);
  const hasSeedEnv = !!w.seedPhraseEnv && !!process.env[w.seedPhraseEnv];
  const hasSeedInline = !!w.seedPhrase && !isPlaceholder(w.seedPhrase);
  if (!hasKeyDaemon && !hasSeedEnv && !hasSeedInline) {
    throw new Error(
      `config.wallet: must set one of keyDaemonSocket (preferred), seedPhraseEnv (env var), or seedPhrase (inline).`,
    );
  }
  if (hasSeedInline) {
    const words = w.seedPhrase!.trim().split(/\s+/);
    if (words.length !== 12 && words.length !== 15 && words.length !== 24) {
      throw new Error(
        `config.wallet.seedPhrase: BIP39 must be 12, 15, or 24 words (got ${words.length})`,
      );
    }
  }
  if (hasKeyDaemon) {
    // Defer existence check to runtime — loader is a pure parse step and
    // the socket may live on a different machine in prod. A Lucid init
    // with the wrong path will fail loudly at connect time.
  }

  // --- deposit token ---
  if (isPlaceholder(cfg.depositToken.policy)) {
    throw new Error("config.depositToken.policy is still a placeholder");
  }
  expectHex("depositToken.policy", cfg.depositToken.policy, 28);
  expectHex("depositToken.name", cfg.depositToken.name);
  expectPositive("depositToken.decimals", cfg.depositToken.decimals);

  // --- governance ---
  if (cfg.governance.signers.length < 3 || cfg.governance.signers.length > 20) {
    throw new Error(
      `config.governance.signers: must be 3–20 signers (got ${cfg.governance.signers.length}) — per validator floor`,
    );
  }
  cfg.governance.signers.forEach((s, i) => {
    if (isPlaceholder(s)) {
      throw new Error(`config.governance.signers[${i}] is still a placeholder`);
    }
    expectHex(`governance.signers[${i}]`, s, 28);
  });
  if (new Set(cfg.governance.signers).size !== cfg.governance.signers.length) {
    throw new Error("config.governance.signers: duplicate PKH detected");
  }
  if (
    cfg.governance.threshold < 2 ||
    cfg.governance.threshold > cfg.governance.signers.length
  ) {
    throw new Error(
      `config.governance.threshold=${cfg.governance.threshold} outside [2, ${cfg.governance.signers.length}]. V1 launch uses 3-of-3 unanimity.`,
    );
  }
  expectHex(
    "governance.governanceNftAssetName",
    cfg.governance.governanceNftAssetName,
  );
  expectHex(
    "governance.registryAuthAssetName",
    cfg.governance.registryAuthAssetName,
  );

  // --- vault params (enforce hard caps from constants.ak) ---
  if (cfg.vaultInitialParams.performanceFeeBps > 450) {
    throw new Error(
      `performanceFeeBps ${cfg.vaultInitialParams.performanceFeeBps} > 450 (4.5% hard cap)`,
    );
  }
  if (cfg.vaultInitialParams.earlyWithdrawFeeBps > 100) {
    throw new Error(
      `earlyWithdrawFeeBps ${cfg.vaultInitialParams.earlyWithdrawFeeBps} > 100 (1% hard cap)`,
    );
  }
  if (cfg.vaultInitialParams.minHoldSeconds > 21600) {
    throw new Error(
      `minHoldSeconds ${cfg.vaultInitialParams.minHoldSeconds} > 21600 (6h hard cap, per V1 internal audit tightening)`,
    );
  }
  if (cfg.vaultInitialParams.keeperFeeBps > 2500) {
    throw new Error(
      `keeperFeeBps ${cfg.vaultInitialParams.keeperFeeBps} > 2500 (25% hard cap)`,
    );
  }
  if (cfg.vaultInitialParams.govFeeBps > 1000) {
    throw new Error(
      `govFeeBps ${cfg.vaultInitialParams.govFeeBps} > 1000 (10% hard cap)`,
    );
  }
  if (
    cfg.vaultInitialParams.keeperFeeBps + cfg.vaultInitialParams.govFeeBps > 3000
  ) {
    throw new Error(
      `keeperFeeBps + govFeeBps > 3000 (treasury floor 70% hard cap)`,
    );
  }
  if (cfg.vaultInitialParams.seedLovelace < 10000000) {
    throw new Error(
      `seedLovelace ${cfg.vaultInitialParams.seedLovelace} < min_vault_ada (10 ADA = 10_000_000 lovelace)`,
    );
  }
  // §5.4 P2 slippage policy caps (constants.ak::max_slippage_bps_cap,
  // min_swap_peg_bps_floor, min_swap_peg_bps_ceiling). The validator
  // enforces these on UpdateSlippagePolicy; initial deploy values MUST
  // sit inside the allowed window too — mismatched state would brick
  // the vault until governance pushes a correction through 48h timelock.
  if (
    cfg.vaultInitialParams.maxSlippageBps < 0 ||
    cfg.vaultInitialParams.maxSlippageBps > 500
  ) {
    throw new Error(
      `maxSlippageBps ${cfg.vaultInitialParams.maxSlippageBps} outside [0, 500] (5% hard cap per constants.ak::max_slippage_bps_cap)`,
    );
  }
  if (
    cfg.vaultInitialParams.minSwapPegBps < 9300 ||
    cfg.vaultInitialParams.minSwapPegBps > 9950
  ) {
    throw new Error(
      `minSwapPegBps ${cfg.vaultInitialParams.minSwapPegBps} outside [9300, 9950] (93-99.5% validator range per constants.ak::min_swap_peg_bps_{floor,ceiling})`,
    );
  }

  // --- treasury ratios ---
  const t = cfg.treasuryInitialParams;
  if (t.auditBps + t.opsBps + t.rdBps + t.bufferBps !== 10000) {
    throw new Error(
      `treasury inflow bps do not sum to 10000: ${t.auditBps}+${t.opsBps}+${t.rdBps}+${t.bufferBps}=${t.auditBps + t.opsBps + t.rdBps + t.bufferBps}`,
    );
  }
  if (t.auditBps < 2000) {
    throw new Error(
      `treasury auditBps ${t.auditBps} < 2000 (20% audit-reserve floor per treasury_audit_floor_bps)`,
    );
  }

  // --- keeper auth ---
  cfg.keeperAuthInitialParams.authorizedPkhs.forEach((p, i) => {
    if (isPlaceholder(p)) {
      throw new Error(
        `config.keeperAuthInitialParams.authorizedPkhs[${i}] is a placeholder`,
      );
    }
    expectHex(`keeperAuthInitialParams.authorizedPkhs[${i}]`, p, 28);
  });
  if (cfg.keeperAuthInitialParams.bondAmountRequired < 50000000) {
    throw new Error(
      `bondAmountRequired ${cfg.keeperAuthInitialParams.bondAmountRequired} < min_keeper_bond (50 ADA)`,
    );
  }

  // --- registry keeper PKH ---
  if (isPlaceholder(cfg.registryInitialParams.keeperPkh)) {
    throw new Error("config.registryInitialParams.keeperPkh is a placeholder");
  }
  expectHex("registryInitialParams.keeperPkh", cfg.registryInitialParams.keeperPkh, 28);

  return cfg;
}

/**
 * Deep summary of a config — used by `compile.ts` to emit a stable
 * human-readable header for the hashes output.
 */
export function summarizeConfig(cfg: DeployConfig): string {
  return [
    `Network: ${cfg.network}`,
    `Deposit token: ${cfg.depositToken.policy}.${cfg.depositToken.name}`,
    `Gov signers: ${cfg.governance.signers.length}, threshold ${cfg.governance.threshold} (${cfg.governance.threshold === cfg.governance.signers.length ? "unanimity" : "< n"})`,
    `Treasury ratios: audit=${cfg.treasuryInitialParams.auditBps}/ops=${cfg.treasuryInitialParams.opsBps}/rd=${cfg.treasuryInitialParams.rdBps}/buffer=${cfg.treasuryInitialParams.bufferBps} bps`,
    `Keeper mode: ${cfg.keeperAuthInitialParams.registrationMode}, authorized PKHs=${cfg.keeperAuthInitialParams.authorizedPkhs.length}`,
    `Vault init params: perf=${cfg.vaultInitialParams.performanceFeeBps}bps, early=${cfg.vaultInitialParams.earlyWithdrawFeeBps}bps, minhold=${cfg.vaultInitialParams.minHoldSeconds}s, buffer=${cfg.vaultInitialParams.bufferTargetBps}bps, keeper=${cfg.vaultInitialParams.keeperFeeBps}bps, gov=${cfg.vaultInitialParams.govFeeBps}bps, max_slippage=${cfg.vaultInitialParams.maxSlippageBps}bps, min_swap_peg=${cfg.vaultInitialParams.minSwapPegBps}bps`,
  ].join("\n");
}
