/// V1 protocol-wide constants. Anchored at deploy time; many are also
/// surfaced as compile-time parameters on individual validators (see each
/// validator file's parameter list). Per-V1 specs:
///   spec/vault-datum.md, spec/governance.md, spec/treasury.md,
///   spec/keeper-auth.md, spec/order-batch.md, spec/ada-swap.md.

// ─────────────────────────────────────────────────────────────────────
// Token names
// ─────────────────────────────────────────────────────────────────────

/// Vault Identity NFT asset name (hex of "OptiVault")
pub const vault_nft_token_name: ByteArray = #"4f7074695661756c74"

/// vUSDCx share token asset name (hex of "vUSDCx")
pub const vusdcx_token_name: ByteArray = #"765553444378"

// ─────────────────────────────────────────────────────────────────────
// Share-mint accounting
// ─────────────────────────────────────────────────────────────────────

/// First-deposit share multiplier (ERC-4626 inflation-attack guard)
pub const initial_share_multiplier: Int = 1_000_000

/// Minimum direct deposit (10 USDCx; 6 decimals)
pub const min_deposit: Int = 10_000_000

/// Minimum compounding yield (1 USDCx); below this, productive Compound
/// is rejected so a 0-yield pseudo-Compound cannot reset cooldowns.
pub const min_compound_yield: Int = 1_000_000

// ─────────────────────────────────────────────────────────────────────
// Fee caps (validator-enforced; governance cannot exceed)
// ─────────────────────────────────────────────────────────────────────

/// Performance fee cap: 4.5% (450 bps).
pub const max_performance_fee_bps: Int = 450

/// Early-withdraw fee cap: 1% (100 bps).
pub const max_early_withdraw_fee_bps: Int = 100

/// Min hold cap: 6 hours (21_600 seconds). Tightened from an earlier
/// 24h cap after whitepaper review — on the weekly Compound cycle a
/// 24h cap would have blocked Direct Withdraw for up to 14% of the
/// time (worst case), well above DeFi stablecoin-product norms. 6h
/// reduces the worst-case block window to ~3.6% of the weekly cycle
/// (2.5% of a 7-day week), keeps defense-in-depth against Compound-
/// extraction attacks, and leaves the Queue Withdraw path entirely
/// unaffected (it never observes min_hold_seconds).
pub const max_min_hold_seconds: Int = 21_600

/// Keeper share cap: 40% (4_000 bps). Raised from 25% pre-V1-launch to
/// align with the public-goods reference-implementation positioning —
/// makes Phase 2+ ($500K-$1M TVL) third-party keeper viability reachable
/// (breakeven drops from ~$1.5M to ~$1M at 6% APY) while keeping treasury
/// majority at 50% floor. Total performance fee envelope still 4.5% (450
/// bps) — only the within-fee allocation shifts.
pub const max_keeper_fee_bps: Int = 4_000

/// Gov pool cap: 10% (1_000 bps).
pub const max_gov_fee_bps: Int = 1_000

/// Combined keeper + gov pool cap: 50% (5_000 bps); treasury floor 50%.
/// Raised from 30% alongside the keeper cap bump above. Treasury 50% floor
/// preserved by `treasury_audit_floor_bps = 2000` (audit reserve stays at
/// 20% of treasury minimum) — at the new floor 50% × 20% = 10% of fee
/// reaches audit reserve at minimum, vs the current 14% (70% × 20%). The
/// treasury sub-allocation default is rebalanced in deploy config to keep
/// effective audit accumulation at 24% of fee (60% × 40% audit_bps).
pub const max_keeper_plus_gov_bps: Int = 5_000

/// On-chain slippage cap ceiling (§5.4 Phase 2). Governance may set
/// `max_slippage_bps` anywhere in `[0, max_slippage_bps_cap]`. 500 bps = 5%
/// is the validator-enforced maximum — above this, Tier 1 oracle-based
/// fair-price enforcement would no longer be meaningful protection. Used
/// by `UpdateSlippagePolicy` and by `DeployToProtocol` Tier 1 check.
pub const max_slippage_bps_cap: Int = 500

/// Peg-floor minimum (93% = 9_300 bps). A governance-set `min_swap_peg_bps`
/// below this would accept catastrophic peg breakage — e.g. at 90% an
/// attacker-controlled keeper could lose ~10% of every swap and still pass
/// the Tier 2 bound. The 9_300 floor is the "how far from 1:1 is this still
/// a stablecoin swap" lower boundary.
pub const min_swap_peg_bps_floor: Int = 9_300

/// Peg-floor maximum (99.5% = 9_950 bps). Above this, normal Minswap V2
/// swaps that already tolerate ~0.3% pool-depth slippage at V1 scale would
/// be rejected by Tier 2, causing liveness issues. 9_950 is the "strict
/// enough to block attacks, loose enough to not reject legitimate swaps"
/// upper boundary.
pub const min_swap_peg_bps_ceiling: Int = 9_950

// ─────────────────────────────────────────────────────────────────────
// Validity-range width cap (internal-verification family)
// ─────────────────────────────────────────────────────────────────────

/// Every redeemer that writes a time-anchored datum field caps its TX
/// validity window at 1 hour to bound timestamp-manipulation surface.
pub const max_validity_range_ms: Int = 3_600_000

// ─────────────────────────────────────────────────────────────────────
// Timelock build flag — single source of truth for Preprod vs Mainnet
// ─────────────────────────────────────────────────────────────────────

/// Gate for ALL governance timelocks, registry cooldowns, and the
/// Heartbeat distribute-period. Set to `True` for Preprod E2E ceremonies
/// (60s turnaround on every governance action). Set to `False` and
/// rebuild for mainnet — restores production values (7d / 14d / 21d /
/// 90d) without per-constant editing.
///
/// Replaces 14+ individual `pub const timelock_*_ms = if ... else ...`
/// overrides — those had a partial-patch failure mode where editing
/// one of several related constants while missing siblings would
/// silently break a Preprod E2E test. A single Bool gate makes that
/// class of bug structurally impossible.
///
/// Affected constants (all defined below):
/// - timelock_update_strategy_ms       7d
/// - timelock_update_fee_ms            14d
/// - timelock_update_fee_split_ms      21d
/// - timelock_admin_deploy_ms          7d
/// - timelock_update_registry_ms       14d
/// - timelock_update_keeper_auth_ms    14d
/// - timelock_treasury_spend_ms        7d
/// - timelock_update_treasury_params_ms 14d
/// - timelock_rotate_signers_ms        14d
/// - timelock_slash_bond_ms            14d
/// - timelock_deregister_stake_ms      14d
/// - timelock_update_slippage_policy_ms 48h
/// - admin_deploy_registry_cooldown_ms 21d
/// - distribute_period_ms              90d
///
/// NOT gated (already short or always-zero by design):
/// - timelock_emergency_ms             0    (immediate; gated via §3 hard-gate)
/// - timelock_fast_update_markets_ms   1h   (named "fast" — already short)
/// - keeper_inactive_ms                7d   (security feature; tests use BACKDATE_COMPOUND_DAYS)
/// - one_hour_ms                       1h   (rate-limit on Compound/RebalanceBuffer/etc.)
///
/// MAINNET BUILD CHECKLIST: `preprod_fast_timelocks = False` + `aiken build`
/// + verify `cat ./plutus.json | grep timelock` shows production values
/// + run `deploy/scripts/verify-mainnet-build.sh` to assert no Preprod
/// 60s literal sneaked through to the active branch.
pub const preprod_fast_timelocks: Bool = False

// ─────────────────────────────────────────────────────────────────────
// Cooldowns (milliseconds)
// ─────────────────────────────────────────────────────────────────────

/// 1 hour — Compound + RebalanceBuffer + RotateSigners + UpdateRegistry
/// fast-path + SwapAda
pub const one_hour_ms: Int = 3_600_000

/// 7 days — keeper inactivity fallback window for keeper-authorized
/// redeemers (governance can step in after this elapses).
pub const keeper_inactive_ms: Int = 7 * 86_400 * 1_000

/// 7 days — UpdateFee minimum cooldown
pub const fee_update_cooldown_ms: Int = 7 * 86_400 * 1_000

/// 21 days — AdminDeployNonDeposit registry-stability cooldown
/// Conditional via `preprod_fast_timelocks` flag (see top of file).
pub const admin_deploy_registry_cooldown_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 21 * 86_400 * 1_000 }

/// Sanity baseline: timestamps before 2023-11-15 UTC are treated as
/// uninitialised (mainly defends against an uninitialised
/// last_compound_time leading to a false keeper-inactivity fallback at
/// epoch 0).
pub const min_valid_timestamp_ms: Int = 1_700_000_000_000

// ─────────────────────────────────────────────────────────────────────
// Vault ADA bounds
// ─────────────────────────────────────────────────────────────────────

/// Per-TX cap on lovelace decrease via DeployToProtocol
pub const max_deploy_ada: Int = 5_000_000

/// Floor below which DeployToProtocol is rejected (vault min-UTXO + headroom)
pub const min_vault_ada: Int = 10_000_000

/// SwapAda trigger: vault lovelace must be < this to invoke
pub const ada_swap_threshold: Int = 15_000_000

/// SwapAda minimum amount (10 ADA)
pub const ada_swap_min: Int = 10_000_000

/// SwapAda maximum amount (50 ADA)
pub const ada_swap_max: Int = 50_000_000

/// (2026-05-30): absolute sanity band on the oracle ADA price
/// (USDCx-per-ADA × 10_000). A degenerate-value circuit breaker that
/// backstops `read_fair_price` (whose dual-feed disagreement guard — now
/// distinct-feed — is the primary defense). Deliberately
/// VERY wide ($0.01–$100/ADA) so it never binds a real price; it only
/// rejects an obviously-broken feed (0 / overflow / mis-decoded). Bounds
/// the protocol's serviceable ADA-price range — acceptable since SwapAda
/// is a minor 50-ADA-capped, keeper-only, oracle-gated path.
pub const ada_swap_price_floor_bps: Int = 100

/// upper sanity bound — $100/ADA × 10_000.
pub const ada_swap_price_ceiling_bps: Int = 1_000_000

// ─────────────────────────────────────────────────────────────────────
// Allocation + position bounds
// ─────────────────────────────────────────────────────────────────────

pub const max_allocations: Int = 10
pub const max_liqwid_positions: Int = 5

// ─────────────────────────────────────────────────────────────────────
// Order pattern
// ─────────────────────────────────────────────────────────────────────

pub const min_order_amount: Int = 10_000_000
pub const default_order_expiry_ms: Int = 86_400_000

// ─────────────────────────────────────────────────────────────────────
// Governance / multisig
// ─────────────────────────────────────────────────────────────────────

/// Minimum signer count enforced on every signer-mutating redeemer
pub const gov_min_signers: Int = 3
pub const gov_max_signers: Int = 20

/// Minimum threshold across all configurations
pub const gov_min_threshold: Int = 2

/// Maximum simultaneous queued actions (DoS cap)
pub const gov_max_queued: Int = 30

/// Minimum TTL on any queued action (1 day)
pub const gov_min_ttl_ms: Int = 86_400_000

/// Maximum TTL on any queued action (30 days)
pub const gov_max_ttl_ms: Int = 30 * 86_400_000

/// Per-action timelock floors (per spec/governance.md §3).
/// All values gated through `preprod_fast_timelocks` Bool flag — see top
/// of file. Flip the flag for mainnet builds to restore production values
/// in one place. emergency (0d) + fast_update_markets (1h) remain
/// runnable in a single Preprod session and are NOT gated by the flag
/// (already short by design).
pub const timelock_update_strategy_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 7 * 86_400 * 1_000 }
pub const timelock_update_fee_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 14 * 86_400 * 1_000 }
pub const timelock_update_fee_split_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 21 * 86_400 * 1_000 }
pub const timelock_emergency_ms: Int = 0
pub const timelock_admin_deploy_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 7 * 86_400 * 1_000 }
pub const timelock_update_registry_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 14 * 86_400 * 1_000 }
pub const timelock_fast_update_markets_ms: Int = 3_600_000
pub const timelock_update_keeper_auth_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 14 * 86_400 * 1_000 }
pub const timelock_treasury_spend_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 7 * 86_400 * 1_000 }
pub const timelock_update_treasury_params_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 14 * 86_400 * 1_000 }
pub const timelock_rotate_signers_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 14 * 86_400 * 1_000 }

/// SlashBond (Phase 3+ only; per spec/keeper-auth.md §3.6)
pub const timelock_slash_bond_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 14 * 86_400 * 1_000 }

/// ActDeregisterStake (A2, 2026-04-20): governance-gated stake credential
/// deregister path enabling recovery of 2 ADA per staking validator deposit.
/// PRODUCTION = 14 days (matches `timelock_update_keeper_auth_ms`).
pub const timelock_deregister_stake_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 14 * 86_400 * 1_000 }

/// UpdateSlippagePolicy (§5.4 Phase 2, 2026-04-21): governance-gated
/// adjustment of `max_slippage_bps` + `min_swap_peg_bps`. 48 hours chosen
/// as balance between (a) depeg-response agility — during a stablecoin
/// stress event governance may need to tighten the peg floor faster than
/// the 14-day UpdateFee cadence allows — and (b) observation-window
/// preservation — depositors still have a full business day plus weekend
/// to exit if they disagree with the policy change. 1-of-n cancel still
/// applies throughout the 48h window.
pub const timelock_update_slippage_policy_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 48 * 60 * 60 * 1_000 }

/// Heartbeat / quarterly-distribution cadence (90 days)
/// Affects multisig_gov.Heartbeat `cooldown_ok = lo - prev_qual >=
/// distribute_period_ms` gate (line 594). NOT the GovDatum field
/// `gov.distribute_period_ms` (which only governs DistributeSignerCompensation
/// cadence at line 732 — that's a separate runtime field, not this constant).
pub const distribute_period_ms: Int =
  if preprod_fast_timelocks { 60_000 } else { 90 * 86_400 * 1_000 }

/// Zero-yield Compound minimum on-chain cooldown (10 min).
/// Keeper off-chain policy targets every 5 days per whitepaper §2.5;
/// this is the floor the contract enforces.
pub const zero_yield_cooldown_ms: Int = 600_000

// ─────────────────────────────────────────────────────────────────────
// Treasury
// ─────────────────────────────────────────────────────────────────────

/// 24-hour cooldown between Spend actions per category
pub const treasury_spend_cooldown_ms: Int = 86_400_000

/// 180-day cooldown between UpdateParams actions
pub const treasury_param_cooldown_ms: Int = 180 * 86_400_000

/// Audit-reserve floor as a fraction of treasury inflow ratio (20% = 2000 bps)
pub const treasury_audit_floor_bps: Int = 2000

/// 30-day window for monthly cap accounting
pub const treasury_monthly_window_ms: Int = 30 * 86_400_000

/// Recent-spend log cap (last 50 entries kept on-chain)
pub const treasury_log_cap: Int = 50

// ─────────────────────────────────────────────────────────────────────
// Keeper-auth
// ─────────────────────────────────────────────────────────────────────

/// Minimum bond size when permissionless mode is active (50 ADA)
pub const min_keeper_bond: Int = 50_000_000

/// Bond withdrawal cooldown (30 days)
pub const bond_withdrawal_cooldown_ms: Int = 30 * 86_400 * 1_000

/// Default rotation period (7 days)
pub const rotation_period_ms_default: Int = 7 * 86_400 * 1_000

/// Default failover window (30 minutes)
pub const failover_window_ms_default: Int = 30 * 60 * 1_000

/// Max authorized keeper count cap
pub const max_authorized_keepers: Int = 20

/// Anti-spam cooldown floor (1 minute)
pub const keeper_cooldown_ms_min: Int = 60_000

/// Anti-spam cooldown ceiling (24 hours)
pub const keeper_cooldown_ms_max: Int = 86_400_000

/// 24-hour cooldown between governance UpdateAuthDatum actions
pub const keeper_auth_update_cooldown_ms: Int = 86_400_000
