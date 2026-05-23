/**
 * Pure datum builders for V1 state UTXOs.
 *
 * Each function returns a Lucid `Data` value whose on-chain bytes match
 * the corresponding Aiken type in `contracts/lib/vault/types.ak`.
 * Constructor indices follow Aiken's declaration order (starts at 0).
 *
 * Keeping these in their own module gives us:
 *   1. Isolation for testing (no Lucid/network/wallet dependency).
 *   2. A single place to update when a datum schema changes.
 *   3. Grep-friendly field ordering that mirrors types.ak line by line.
 */
import { Constr, Data } from "@lucid-evolution/lucid";
import type { DeployConfig } from "./config.js";

/** Common compiled-hashes bundle shared by all builders. */
export interface CeremonyHashes {
  vaultNftPolicy: string;
  governanceNftPolicy: string;
  registryAuthPolicy: string;
  governanceNftName: string;
  registryAuthName: string;
  keeperStakeHash: string;
  treasuryHash: string;
  userStakeHash: string;
  keeperHotStakeHash: string;
  /// BatchProcess extraction: BatchProcess extracted from vault_user (4 folds +
  /// OrderDatum decode + vUSDCx no-leak + payout-output uniqueness invariants moved to
  /// standalone validator; vault_user becomes purely permissionless
  /// with no keeper_stake_hash param).
  batcherStakeHash: string;
  /// SwapAda extraction: SwapAda extracted from vault_keeper_hot (dual-feed
  /// oracle + 6-tuple registry read moved to standalone validator).
  swapAdaStakeHash: string;
  protocolStakeHash: string;
  /// vault_recall was split from vault_protocol during the authorization-boundary refactor (headroom after
  /// SwapAdapter dispatch + Tier 1 oracle wiring).
  recallStakeHash: string;
  liqwidStakeHash: string;
  govPolicyStakeHash: string;
  govEmergencyStakeHash: string;
  /// AdminDeployNonDeposit extraction: AdminDeployNonDeposit extracted from vault_gov_emergency
  /// (SwapAdapter dispatch + destination-whitelist moved to standalone
  /// validator).
  adminDeployStakeHash: string;
  vaultProxyHash: string;
  orderScriptHash: string;
  vusdcxPolicy: string;
  multisigGovHash: string;
  registryHash: string;
  /// §B@launch=1 SwapAdapter hash — V1 launch value = minswap_v2_adapter.
  minswapV2AdapterHash: string;
}

/**
 * RegistryDatum — 9 fields, most whitelists empty at launch.
 * See types.ak `pub type RegistryDatum` + spec/architecture.md §3.6.
 *
 * §5.4 P3 (2026-04-22): `asset_oracles` added at index 5. Empty list
 * at launch — governance populates via UpdateRegistry (14d timelock)
 * per-asset as Charli3+Orcfax dual-feed coverage comes online.
 *
 * §B@launch=1 (2026-04-22): `swap_adapter_hashes` added at index 6 —
 * whitelist of authorized SwapAdapter script hashes (see
 * lib/vault/swap_adapter.ak). V1 launches with exactly one entry:
 * the `minswap_v2_adapter` hash. Governance can add new adapters via
 * UpdateRegistry (14d timelock + 1-of-n cancel) without V1 vault
 * redeploy.
 *
 * last_update_time now at index 7; keeper_pkh at index 8. Governance
 * ceremony code MUST mirror this ordering exactly — a missing field
 * leaves the reading validator unable to deserialize the datum, which
 * has historically locked the Registry UTXO before mainnet redeploy.
 */
export function buildRegistryDatum(
  cfg: DeployConfig,
  hashes: CeremonyHashes,
  nowMs: number,
): string {
  const initialAdapters =
    cfg.registryInitialParams.swapAdapterHashes ?? [
      // §B@launch=1: at V1 launch the only authorised adapter is
      // minswap_v2_adapter. Caller can override via config.
      hashes.minswapV2AdapterHash,
    ];

  // §5.4 P3 (Preprod E2E only) — optional pre-load of `asset_oracles` at
  // ceremony deploy time. Mainnet MUST omit this so V1 launches with
  // `[]` and oracles come online via governance UpdateRegistry only.
  // The Preprod path is necessary because the production action timelock
  // (14d) blocks runtime UpdateRegistry tests within a single E2E session.
  const cfgAssetOracles = cfg.registryInitialParams.assetOracles ?? [];
  if (cfg.network === "Mainnet" && cfgAssetOracles.length > 0) {
    throw new Error(
      "[buildRegistryDatum] cfg.registryInitialParams.assetOracles is non-empty " +
      "but network=Mainnet — V1 mainnet MUST launch with `asset_oracles = []` " +
      "and add oracle entries via governance UpdateRegistry only. Refusing.",
    );
  }
  const initialAssetOracles = cfgAssetOracles.map((e) => {
    // Client-side cap pre-check (the registry validator re-checks).
    if (e.maxDisagreementBps <= 0 || e.maxDisagreementBps > 1_000) {
      throw new Error(
        `[buildRegistryDatum] asset_oracle ${e.assetPolicy}.${e.assetName} ` +
        `maxDisagreementBps=${e.maxDisagreementBps} out of (0, 1000] cap`,
      );
    }
    if (e.maxStalenessMs <= 0 || e.maxStalenessMs > 3_600_000) {
      throw new Error(
        `[buildRegistryDatum] asset_oracle ${e.assetPolicy}.${e.assetName} ` +
        `maxStalenessMs=${e.maxStalenessMs} out of (0, 3_600_000] cap`,
      );
    }
    if (e.minFeeds < 1 || e.minFeeds > e.feeds.length) {
      throw new Error(
        `[buildRegistryDatum] asset_oracle ${e.assetPolicy}.${e.assetName} ` +
        `minFeeds=${e.minFeeds} out of [1, feeds.length=${e.feeds.length}]`,
      );
    }
    return new Constr(0, [
      e.assetPolicy,
      e.assetName,
      e.feeds.map(
        (f) => new Constr(0, [f.feedScriptHash, f.feedAuthPolicy, f.feedAuthName]),
      ),
      BigInt(e.maxDisagreementBps),
      BigInt(e.maxStalenessMs),
      BigInt(e.minFeeds),
    ]);
  });

  const data = new Constr(0, [
    hashes.governanceNftPolicy,        // 0: governance_policy
    hashes.governanceNftName,          // 1: governance_name
    cfg.registryInitialParams.protocolHashes, // 2: protocol_hashes (empty at launch)
    cfg.registryInitialParams.stableTokens.map( // 3: stable_tokens
      (s) => new Constr(0, [s.policy, s.name]),
    ),
    cfg.registryInitialParams.liqwidMarkets.map( // 4: liqwid_markets
      (m) =>
        new Constr(0, [
          m.actionAddrHash,
          m.qtokenPolicy,
          m.qtokenName,
          m.underlyingPolicy,
          m.underlyingName,
          m.active ? new Constr(1, []) : new Constr(0, []),
        ]),
    ),
    initialAssetOracles,               // 5: asset_oracles (§5.4 P3, empty at launch on mainnet)
    initialAdapters,                   // 6: swap_adapter_hashes (§B@launch=1)
    BigInt(nowMs),                     // 7: last_update_time
    cfg.registryInitialParams.keeperPkh, // 8: keeper_pkh
  ]);
  return Data.to(data as unknown as Data);
}

/**
 * TreasuryDatum — 21 fields (indices 0-20). All four balances +
 * last_spend_time_* + log start at 0; min_audit_reserve floor matches
 * config (default 0 at launch). See types.ak `pub type TreasuryDatum`.
 */
export function buildTreasuryDatum(
  cfg: DeployConfig,
  hashes: CeremonyHashes,
): string {
  const t = cfg.treasuryInitialParams;
  const data = new Constr(0, [
    0n,                       // 0: audit_reserve_balance
    0n,                       // 1: operations_balance
    0n,                       // 2: rd_balance
    0n,                       // 3: buffer_balance
    BigInt(t.auditBps),       // 4: audit_bps
    BigInt(t.opsBps),         // 5: ops_bps
    BigInt(t.rdBps),          // 6: rd_bps
    BigInt(t.bufferBps),      // 7: buffer_bps
    0n,                       // 8: last_spend_time_audit
    0n,                       // 9: last_spend_time_ops
    0n,                       // 10: last_spend_time_rd
    0n,                       // 11: last_spend_time_buffer
    0n,                       // 12: last_param_update_time
    BigInt(t.monthlyCapAudit),// 13: monthly_cap_audit
    BigInt(t.monthlyCapOps),  // 14: monthly_cap_ops
    BigInt(t.monthlyCapRd),   // 15: monthly_cap_rd
    BigInt(t.monthlyCapBuffer),// 16: monthly_cap_buffer
    [],                       // 17: recent_spend_log (empty)
    hashes.governanceNftPolicy, // 18: governance_policy
    hashes.governanceNftName,   // 19: governance_name
    BigInt(t.minAuditReserve),  // 20: min_audit_reserve
  ]);
  return Data.to(data as unknown as Data);
}

/**
 * KeeperAuthDatum — 14 fields. See types.ak:361.
 * RegistrationMode indices per Aiken declaration order:
 *   GovernanceOnly = 0, Mixed = 1, PermissionlessWithBond = 2.
 */
export function buildKeeperAuthDatum(
  cfg: DeployConfig,
  hashes: CeremonyHashes,
  nowMs: number,
): string {
  const k = cfg.keeperAuthInitialParams;
  const modeIdx =
    k.registrationMode === "GovernanceOnly" ? 0
      : k.registrationMode === "Mixed" ? 1
      : 2;
  const data = new Constr(0, [
    new Constr(modeIdx, []),    // 0: registration_mode
    k.authorizedPkhs,           // 1: authorized_pkhs
    [],                         // 2: active_bonds
    BigInt(k.bondAmountRequired), // 3: bond_amount_required
    BigInt(nowMs),              // 4: last_config_update_time
    BigInt(k.cooldownMs),       // 5: cooldown_ms
    BigInt(k.maxAuthorizedCount),// 6: max_authorized_count
    BigInt(nowMs),              // 7: rotation_epoch_start_ms
    BigInt(k.rotationPeriodMs), // 8: rotation_period_ms
    BigInt(k.failoverWindowMs), // 9: failover_window_ms
    0n,                         // 10: last_successful_tx_at
    0n,                         // 11: nonce
    hashes.governanceNftPolicy, // 12: governance_policy
    hashes.governanceNftName,   // 13: governance_name
  ]);
  return Data.to(data as unknown as Data);
}

/**
 * QueuedAction — 8 fields. See types.ak::QueuedAction (used by GovDatum).
 *
 * Constr fields:
 *   0: action_id (32-byte hex)
 *   1: action_kind (Constr<ActionKind>)
 *   2: target_script (28-byte hex)
 *   3: target_tx_hash (empty or 32-byte hex)
 *   4: payload_hash (32-byte hex)
 *   5: queued_at_ms (Int)
 *   6: executable_at_ms (Int)
 *   7: expires_at_ms (Int)
 */
export interface PrequeuedAction {
  /** Already-computed action_id (hex32). Use computeActionIdHex below. */
  actionId: string;
  /** Aiken ActionKind Constr index (0..13). */
  actionKindIdx: number;
  /** 28-byte target script hash hex. */
  targetScript: string;
  /** Pre-image queued_at_ms (POSIX ms). Validator stores this for action_id check downstream. */
  queuedAtMs: bigint;
  /** Pre-image executable_at_ms = queued_at_ms + production_timelock_ms. */
  executableAtMs: bigint;
  /** Pre-image expires_at_ms = executable_at_ms + ttl_ms. */
  expiresAtMs: bigint;
  /** payload_hash (hex32). */
  payloadHash: string;
}

function buildQueuedActionConstr(q: PrequeuedAction): Constr<unknown> {
  return new Constr(0, [
    q.actionId,
    new Constr(q.actionKindIdx, []),
    q.targetScript,
    "", // target_tx_hash empty
    q.payloadHash,
    q.queuedAtMs,
    q.executableAtMs,
    q.expiresAtMs,
  ]);
}

/**
 * GovDatum — 9 fields. See types.ak:229.
 *
 * The `signer_joined_at_ms` and `signer_last_qualified_ms` parallel lists
 * are pre-seeded with the deploy time for every initial signer, so the
 * compensation-distribution logic has a valid non-zero baseline.
 *
 * `prequeue` (Preprod-only convenience): list of QueuedAction records to
 * write directly into GovDatum.queued at deploy time. Bypasses normal
 * QueueAction validator path — only valid because GovInit creates the gov
 * UTxO from scratch (no validator runs at mint+send). Used by Phase B
 * datum-backdate ceremonies to enable Queue→Execute end-to-end on Preprod
 * with production timelock values: pre-queued actions have backdated
 * queued_at_ms so executable_at_ms is reachable immediately after deploy.
 *
 * `nonce` is auto-set to `prequeue.length` so the next live QueueAction
 * computes its action_id with a nonce that doesn't collide with any
 * pre-queued action_id (each pre-queued action used a distinct nonce
 * value 0..N-1 when its action_id was computed).
 *
 * Mainnet refuses any prequeue (programmatic guard in phases.ts).
 */
export function buildGovDatum(
  cfg: DeployConfig,
  nowMs: number,
  prequeue: PrequeuedAction[] = [],
): string {
  const signers = cfg.governance.signers;
  const joinedAt = signers.map(() => BigInt(nowMs));
  const lastQualified = signers.map(() => BigInt(nowMs));
  // Aiken's `list.push` prepends → newest-queued at front. Pre-queued
  // actions don't have a meaningful order, but we mirror the validator's
  // shape (newest first by queued_at descending).
  const queuedSorted = [...prequeue].sort((a, b) => Number(b.queuedAtMs - a.queuedAtMs));
  const queuedConstrs = queuedSorted.map(buildQueuedActionConstr);
  const data = new Constr(0, [
    signers,                   // 0: signers
    joinedAt,                  // 1: signer_joined_at_ms
    lastQualified,             // 2: signer_last_qualified_ms
    BigInt(cfg.governance.threshold), // 3: threshold
    queuedConstrs,             // 4: queued
    0n,                        // 5: signer_compensation_pool
    BigInt(nowMs),             // 6: last_distribute_ms
    BigInt(cfg.governance.distributePeriodMs), // 7: distribute_period_ms
    BigInt(prequeue.length),   // 8: nonce (= number of pre-queued actions)
  ]);
  return Data.to(data as unknown as Data);
}

/**
 * VaultDatum — 29 fields. See types.ak (post-Layer-3) + spec/vault-datum.md.
 *
 * At init time all accounting starts at zero; the 9 immutable identity
 * fields are set from the compiled ceremony hashes + policy params.
 * `last_compound_time` is set to the deploy time so the zero-yield
 * cooldown and keeper-inactivity window have a sane baseline.
 *
 * §5.4 P2 (2026-04-21) — 26 → 28 fields:
 *   - idx 16: `max_slippage_bps`, idx 17: `min_swap_peg_bps`.
 *
 * Phase 1 governance safety Layer 3 (2026-04-25) — 28 → 29 fields:
 *   - idx 28: `community_sunset_triggered` (Preprod L3 dead-man-switch).
 *   Always 0 at init; flipped to 1 only by `vault_user.CommunitySunset`
 *   after ≥ 90 days of operational inactivity.
 *
 * `buildRegistryDatum`'s 9-field layout (§5.4 P3 + §B@launch=1) must
 * ship together with this — both are required for any validator call
 * to deserialize cleanly.
 */
export function buildVaultDatum(
  cfg: DeployConfig,
  hashes: CeremonyHashes,
  nowMs: number,
  /**
   * Optional backdate offsets in MILLISECONDS — Preprod-ONLY E2E
   * convenience. Set when a fresh ceremony needs to land in a state
   * where time-gated redeemers can fire immediately, instead of waiting
   * the real cooldown window.
   *
   * MAINNET CALLERS MUST PASS `{}` (or omit). The contract has no
   * gate that would catch backdated mainnet deployments — the only
   * defense is operator discipline. The mainnet ceremony script in
   * `deploy/scripts/init-vault-state-mainnet.ts` should refuse this
   * argument outright.
   *
   * Fields (all default 0 = no backdate):
   *   - `feeMs` — subtracted from `last_fee_update_time` (idx 6). Used
   *     to bypass the 7d `fee_update_cooldown_ms` for Phase H-UpdateFee
   *     E2E.
   *   - `compoundMs` — subtracted from BOTH `last_compound_time` (idx 4)
   *     AND `last_realloc_time` (idx 5). Used for Phase L3 CommunitySunset
   *     E2E (90-day threshold). See `tests/preprod/TIME-MACHINE.md`.
   *   - `adaSwapMs` — subtracted from `last_ada_swap_time` (idx 7). Used
   *     to bypass the SwapAda 1h cooldown.
   *
   * Backdating `compoundMs > 91 * 86_400_000` makes the vault appear
   * to have had no keeper activity for 91+ days, which (a) lets any
   * vUSDCx holder fire `CommunitySunset` immediately, and (b) lets
   * any wallet bypass the keeper signature in
   * `vault_recall.RecallFromLiqwid` + `vault_user.Withdraw` early-fee
   * waiver. Use only on Preprod.
   */
  backdate: BackdateOptions = {},
): string {
  const v = cfg.vaultInitialParams;
  const compoundBaseMs = nowMs - (backdate.compoundMs ?? 0);
  const data = new Constr(0, [
    // — Accounting (10) —
    0n,                          // 0: total_deposited
    0n,                          // 1: total_shares
    0n,                          // 2: idle_buffer
    0n,                          // 3: non_deposit_value
    BigInt(compoundBaseMs),      // 4: last_compound_time (Preprod-backdate-aware)
    BigInt(compoundBaseMs),      // 5: last_realloc_time (kept synced with #4)
    BigInt(nowMs - (backdate.feeMs ?? 0)),     // 6: last_fee_update_time
    BigInt(nowMs - (backdate.adaSwapMs ?? 0)), // 7: last_ada_swap_time
    [],                          // 8: strategy_allocations
    [],                          // 9: liqwid_positions

    // — Policy (8) —
    BigInt(v.performanceFeeBps),    // 10: performance_fee_bps
    BigInt(v.earlyWithdrawFeeBps),  // 11: early_withdraw_fee_bps
    BigInt(v.minHoldSeconds),       // 12: min_hold_seconds
    BigInt(v.bufferTargetBps),      // 13: buffer_target_bps
    BigInt(v.keeperFeeBps),         // 14: keeper_fee_bps
    BigInt(v.govFeeBps),            // 15: gov_fee_bps
    BigInt(v.maxSlippageBps),       // 16: max_slippage_bps (§5.4 P2)
    BigInt(v.minSwapPegBps),        // 17: min_swap_peg_bps (§5.4 P2)

    // — Identity, immutable (9) —
    BigInt(v.vaultVersion),      // 18: vault_version
    hashes.governanceNftPolicy,  // 19: governance_policy
    hashes.governanceNftName,    // 20: governance_name
    cfg.depositToken.policy,     // 21: deposit_token_policy
    cfg.depositToken.name,       // 22: deposit_token_name
    hashes.vusdcxPolicy,         // 23: vusdcx_policy
    hashes.orderScriptHash,      // 24: order_script_hash
    hashes.registryHash,         // 25: registry_hash
    hashes.registryAuthPolicy,   // 26: registry_auth_policy

    // — Operational (2) —
    0n,                          // 27: frozen
    0n,                          // 28: community_sunset_triggered (Layer 3)
  ]);
  return Data.to(data as unknown as Data);
}

/**
 * Backdate options for `buildVaultDatum`. Preprod-only convenience —
 * each field subtracts its value (in milliseconds) from the
 * corresponding `nowMs`-derived datum field at vault init.
 *
 * Mainnet ceremony scripts should construct without this object so
 * defaults of 0 apply throughout.
 */
export interface BackdateOptions {
  /** Subtracted from `last_fee_update_time` (idx 6). */
  feeMs?: number;
  /** Subtracted from BOTH `last_compound_time` (idx 4) and
   *  `last_realloc_time` (idx 5). */
  compoundMs?: number;
  /** Subtracted from `last_ada_swap_time` (idx 7). */
  adaSwapMs?: number;
}
