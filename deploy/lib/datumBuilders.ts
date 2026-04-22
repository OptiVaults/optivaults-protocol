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
  /// Phase 77d: BatchProcess extracted from vault_user (4 folds +
  /// OrderDatum decode + R51/R52 anti-leak invariants moved to
  /// standalone validator; vault_user becomes purely permissionless
  /// with no keeper_stake_hash param).
  batcherStakeHash: string;
  /// Phase 77b: SwapAda extracted from vault_keeper_hot (dual-feed
  /// oracle + 6-tuple registry read moved to standalone validator).
  swapAdaStakeHash: string;
  protocolStakeHash: string;
  /// Phase 77: vault_recall split from vault_protocol (headroom after
  /// SwapAdapter dispatch + Tier 1 oracle wiring).
  recallStakeHash: string;
  liqwidStakeHash: string;
  govPolicyStakeHash: string;
  govEmergencyStakeHash: string;
  /// Phase 77c: AdminDeployNonDeposit extracted from vault_gov_emergency
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
 * ceremony code MUST mirror this ordering exactly — see
 * `feedback_deploy_datum_sync.md` memory for the V10 registry-deadlock
 * lesson (missing field → reading validator can't deserialize).
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
    [],                                // 5: asset_oracles (§5.4 P3, empty at launch)
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
 * GovDatum — 9 fields. See types.ak:229.
 *
 * The `signer_joined_at_ms` and `signer_last_qualified_ms` parallel lists
 * are pre-seeded with the deploy time for every initial signer, so the
 * compensation-distribution logic has a valid non-zero baseline.
 */
export function buildGovDatum(cfg: DeployConfig, nowMs: number): string {
  const signers = cfg.governance.signers;
  const joinedAt = signers.map(() => BigInt(nowMs));
  const lastQualified = signers.map(() => BigInt(nowMs));
  const data = new Constr(0, [
    signers,                   // 0: signers
    joinedAt,                  // 1: signer_joined_at_ms
    lastQualified,             // 2: signer_last_qualified_ms
    BigInt(cfg.governance.threshold), // 3: threshold
    [],                        // 4: queued
    0n,                        // 5: signer_compensation_pool
    BigInt(nowMs),             // 6: last_distribute_ms
    BigInt(cfg.governance.distributePeriodMs), // 7: distribute_period_ms
    0n,                        // 8: nonce
  ]);
  return Data.to(data as unknown as Data);
}

/**
 * VaultDatum — 28 fields. See types.ak (post-§5.4 P2) + spec/vault-datum.md.
 *
 * At init time all accounting starts at zero; the 9 immutable identity
 * fields are set from the compiled ceremony hashes + policy params.
 * `last_compound_time` is set to the deploy time so the zero-yield
 * cooldown and keeper-inactivity window have a sane baseline.
 *
 * §5.4 P2 (2026-04-21) upgrade — 26 → 28 fields:
 *   - idx 16: `max_slippage_bps` (Tier 1 oracle fair-price bound cap).
 *   - idx 17: `min_swap_peg_bps` (Tier 2 peg-floor bound, window 9300-9950).
 * Pre-P2 deployments wrote only 6 policy fields (10..15) + identity
 * starting at idx 16. Post-P2 deployments write 8 policy fields
 * (10..17) + identity starting at idx 18. `buildRegistryDatum`'s 9-field
 * layout (§5.4 P3 + §B@launch=1) must ship together with this — both
 * are required for any validator call to deserialize cleanly.
 */
export function buildVaultDatum(
  cfg: DeployConfig,
  hashes: CeremonyHashes,
  nowMs: number,
): string {
  const v = cfg.vaultInitialParams;
  const data = new Constr(0, [
    // — Accounting (10) —
    0n,                          // 0: total_deposited
    0n,                          // 1: total_shares
    0n,                          // 2: idle_buffer
    0n,                          // 3: non_deposit_value
    BigInt(nowMs),               // 4: last_compound_time
    BigInt(nowMs),               // 5: last_realloc_time
    BigInt(nowMs),               // 6: last_fee_update_time
    BigInt(nowMs),               // 7: last_ada_swap_time
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

    // — Operational (1) —
    0n,                          // 27: frozen
  ]);
  return Data.to(data as unknown as Data);
}
