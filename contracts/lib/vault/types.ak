/// V1 type definitions — VaultDatum, redeemers, supporting types.
///
/// Cross-references:
///   - spec/vault-datum.md  (29 fields, 9 immutable)
///   - spec/order-batch.md  (OrderDatum + OrderRedeemer)
///   - spec/governance.md   (GovDatum + GovRedeemer + ActionKind)
///   - spec/treasury.md     (TreasuryDatum + TreasuryRedeemer)
///   - spec/keeper-auth.md  (KeeperAuthDatum + KeeperAuthRedeemer)
///   - spec/ada-swap.md     (SwapAda redeemer)

use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address}

// ─────────────────────────────────────────────────────────────────────
// Vault datum — single canonical UTXO at vault_proxy address
// ─────────────────────────────────────────────────────────────────────

pub type ProtocolId {
  Liqwid
  MinswapLP
  SundaeSwapLP
}

pub type Allocation {
  protocol: ProtocolId,
  amount: Int,
  expected_apy_bps: Int,
}

pub type LiqwidPosition {
  market_id: Int,
  qtokens_held: Int,
  supplied_value: Int,
}

/// 29 fields — see spec/vault-datum.md §1.
///
/// Mutability classes:
///   - Accounting state (10): mutated by user/keeper redeemers
///   - Policy parameters (8): mutable by governance redeemers within caps
///   - Identity (9): immutable after deploy (`vault_version` + 8 anchors)
///   - Operational flags (2): `frozen`, `community_sunset_triggered`
///
/// V1 §5.4 Phase 2 (2026-04-21): added `max_slippage_bps` +
/// `min_swap_peg_bps` to the Policy group (6 → 8 fields) for on-chain
/// slippage enforcement. See spec/governance.md §4.X `UpdateSlippagePolicy`
/// + whitepaper §5.4 for the Tier 1 oracle + Tier 2 peg-floor mechanism.
pub type VaultDatum {
  // — Accounting (10) —
  total_deposited: Int,
  total_shares: Int,
  idle_buffer: Int,
  non_deposit_value: Int,
  last_compound_time: Int,
  last_realloc_time: Int,
  last_fee_update_time: Int,
  last_ada_swap_time: Int,
  strategy_allocations: List<Allocation>,
  liqwid_positions: List<LiqwidPosition>,

  // — Policy (8) —
  performance_fee_bps: Int,
  early_withdraw_fee_bps: Int,
  min_hold_seconds: Int,
  buffer_target_bps: Int,
  keeper_fee_bps: Int,
  gov_fee_bps: Int,
  /// §5.4 Phase 2: Tier 1 oracle-based fair-price bound. Enforced in
  /// `DeployToProtocol` when the deploy asset is covered by
  /// `registry.asset_oracles` (Phase 3). Cap = `max_slippage_bps_cap` (5%).
  max_slippage_bps: Int,
  /// §5.4 Phase 2: Tier 2 peg-floor bound. Enforced in `DeployToProtocol`
  /// via decoded Minswap V2 route datum: `min_receive × 10_000 >=
  /// deploy_amount × min_swap_peg_bps`. Bound to
  /// `[min_swap_peg_bps_floor, min_swap_peg_bps_ceiling]` (9_300..9_950).
  min_swap_peg_bps: Int,

  // — Identity, immutable (9) —
  vault_version: Int,
  governance_policy: ByteArray,
  governance_name: ByteArray,
  deposit_token_policy: ByteArray,
  deposit_token_name: ByteArray,
  vusdcx_policy: ByteArray,
  order_script_hash: ByteArray,
  registry_hash: ByteArray,
  registry_auth_policy: ByteArray,

  // — Operational (2) —
  frozen: Int,
  /// Phase 1 governance safety — Layer 3 (2026-04-25): Dead-man-switch flag.
  /// Set 0 → 1 by `CommunitySunset` redeemer (vault_user.ak) when the vault
  /// has been operationally inactive for ≥ 90 days
  /// (`max(last_compound_time, last_realloc_time) + 90d <= now`). Once set
  /// it is preserved by every other redeemer (one-way irreversible flag).
  ///
  /// Effect: enables permissionless invocation of recovery-path redeemers
  /// for any vUSDCx holder:
  ///   - `vault_recall.RecallFromLiqwid` skips the keeper-active +
  ///     7d-keeper-inactive gate
  ///   - `vault_protocol.DeployToProtocol` Layer 2 path skips the keeper
  ///     signature requirement (swap NDV → USDCx for user withdraw)
  ///
  /// Lets the depositor base recover their full proportional USDCx share
  /// even when the founder + governance are completely failed.
  community_sunset_triggered: Int,
}

/// Vault redeemers (vault_core / vault_protocol / vault_liqwid all forward
/// from vault_proxy via Withdraw-Zero; the redeemer is decoded inside the
/// staking validator — see spec/architecture.md §4 for which redeemer
/// belongs to which validator).
pub type VaultRedeemer {
  // ── User-facing (vault_user) ──
  Deposit { amount: Int }
  Withdraw { shares: Int, receiver: ByteArray, receiver_output_idx: Int }
  BatchProcess {
    total_deposit: Int,
    total_withdraw: Int,
    total_mint: Int,
    total_burn: Int,
  }
  /// Phase 1 governance safety — Layer 3 (2026-04-25): Dead-man-switch.
  /// Permissionless redeemer callable by any vUSDCx holder when the vault
  /// has been inactive for ≥ 90 days (no Compound or zero-yield heartbeat).
  /// Sets `frozen=1` and `community_sunset_triggered=1`, opening
  /// permissionless paths in `vault_recall.RecallFromLiqwid` +
  /// `vault_protocol.DeployToProtocol` Layer 2 so depositors can recover
  /// their full proportional USDCx share without any keeper or
  /// governance intervention. See spec/governance.md §X CommunitySunset.
  CommunitySunset

  // ── Keeper hot-path (vault_keeper_hot) ──
  Compound {
    harvested_amount: Int,
    new_allocations: List<Allocation>,
    fee_output_idx: Int,
    keeper_output_idx: Int,
  }
  RebalanceBuffer
  /// V1 closed-loop ADA replenishment — keeper contributes ADA, vault
  /// returns USDCx at oracle-priced rate. See spec/ada-swap.md.
  SwapAda {
    amount_ada: Int,
    keeper_output_idx: Int,
  }

  // ── Keeper-facing (vault_protocol) ──
  DeployToProtocol {
    deploy_amount: Int,
    new_allocations: List<Allocation>,
    deploy_token_policy: ByteArray,
    deploy_token_name: ByteArray,
    dest_output_idx: Int,
  }
  RecallFromProtocol {
    recall_amount: Int,
    new_allocations: List<Allocation>,
    recall_token_policy: ByteArray,
    recall_token_name: ByteArray,
  }
  MergeUtxo { buffer_increase: Int, non_deposit_increase: Int }
  AdminDeployNonDeposit {
    deploy_amount: Int,
    new_allocations: List<Allocation>,
    deploy_token_policy: ByteArray,
    deploy_token_name: ByteArray,
    dest_output_idx: Int,
  }

  // ── Governance-facing (vault_protocol) ──
  UpdateStrategy { new_allocations: List<Allocation>, new_buffer_target_bps: Int }
  UpdateFee {
    new_performance_fee_bps: Int,
    new_early_withdraw_fee_bps: Int,
    new_min_hold_seconds: Int,
  }
  /// 3-way fee split adjustment — 21-day timelock. See spec/governance.md §4.3.
  UpdateFeeSplit {
    new_keeper_fee_bps: Int,
    new_gov_fee_bps: Int,
  }
  /// §5.4 Phase 2: on-chain slippage policy adjustment — 48-hour timelock.
  /// Sets `max_slippage_bps` (Tier 1 oracle fair-price bound) +
  /// `min_swap_peg_bps` (Tier 2 peg-floor bound). Validator-enforced caps:
  /// max_slippage ∈ [0, max_slippage_bps_cap], peg ∈
  /// [min_swap_peg_bps_floor, min_swap_peg_bps_ceiling]. See whitepaper
  /// §5.4 + spec/governance.md UpdateSlippagePolicy.
  UpdateSlippagePolicy {
    new_max_slippage_bps: Int,
    new_min_swap_peg_bps: Int,
  }
  EmergencyWithdraw { loss_amount: Int, freeze_flag: Int }

  // ── Keeper-facing (vault_liqwid) ──
  SupplyToLiqwid { market_id: Int, supply_amount: Int, dest_output_idx: Int }
  RecallFromLiqwid { market_id: Int }
}

/// vUSDCx minting policy redeemer — defers to vault_core (Deposit /
/// Withdraw / BatchProcess). The minting policy itself only checks that
/// the vault UTXO is consumed in the same TX.
pub type MintRedeemer {
  MintShares
  BurnShares
}

// ─────────────────────────────────────────────────────────────────────
// Order pattern — see spec/order-batch.md
// ─────────────────────────────────────────────────────────────────────

pub type OrderType {
  DepositOrder
  WithdrawOrder
}

pub type OrderDatum {
  owner: VerificationKeyHash,
  order_type: OrderType,
  amount: Int,
  /// Slippage protection: deposit-order min_shares OR withdraw-order min_receive
  min_receive: Int,
  /// For WithdrawOrder: the address receiving USDCx; for DepositOrder this
  /// is the owner's payment address (where vUSDCx is delivered).
  receiver: Address,
  created_at: Int,
  expires_at: Int,
  /// Lovelace ceiling on keeper tip per order
  max_batcher_tip: Int,
}

pub type OrderRedeemer {
  Process {
    payout_output_index: Int,
    tip_output_idx: Int,
  }
  Cancel
  Expire
}

// ─────────────────────────────────────────────────────────────────────
// Governance — see spec/governance.md + spec/multisig-gov.md
// ─────────────────────────────────────────────────────────────────────

pub type ActionKind {
  ActUpdateStrategy
  ActUpdateFee
  ActUpdateFeeSplit
  /// §5.4 Phase 2 (2026-04-21): on-chain slippage policy adjustment.
  /// 48h timelock (balance between depeg-response agility + depositor
  /// exit window); 1-of-n cancel preserved. Handled by vault_gov_policy.
  ActUpdateSlippagePolicy
  ActEmergencyWithdraw
  ActAdminDeployNonDeposit
  ActUpdateRegistry
  ActFastUpdateMarkets
  ActUpdateKeeperAuth
  ActTreasurySpend
  ActUpdateTreasuryParams
  ActRotateSigners
  /// Phase 3+ only (active_bonds non-empty). Governance-driven bond
  /// slashing via keeper_stake_script.SlashBond. See spec/keeper-auth.md §3.6.
  ActSlashBond
  /// A2 (2026-04-20, extended Phase 77/77b/77c/77d): Governance-gated stake
  /// credential deregistration. Enables recovery of the 2 ADA Cardano
  /// stake-registration deposit per staking validator. Post-Phase-77d
  /// coverage (12 credentials):
  ///   - vault_user + vault_keeper_hot (replaced vault_core via Phase 77
  ///     authorization-boundary split; the prior 16 KB V3 ceiling that
  ///     blocked vault_core's `publish` handler is resolved by the split).
  ///   - vault_batcher (Phase 77d extraction from vault_user: BatchProcess
  ///     + its 4 fold loops + OrderDatum/OrderRedeemer decode + R51/R52
  ///     anti-leak invariants).
  ///   - vault_swap_ada (Phase 77b extraction from vault_keeper_hot:
  ///     SwapAda + dual-feed oracle reader + 6-tuple registry read).
  ///   - vault_protocol + vault_recall (split Phase 77 for bytecode
  ///     headroom after §5.4 P3-P5 adapter dispatch + oracle wiring).
  ///   - vault_liqwid / vault_gov_policy / vault_gov_emergency.
  ///   - vault_admin_deploy (Phase 77c extraction from vault_gov_emergency:
  ///     AdminDeployNonDeposit + SwapAdapter dispatch + destination-whitelist).
  ///   - keeper_stake_script.
  ///   - minswap_v2_adapter (SwapAdapter A2 coverage; adapter is
  ///     parameterized on governance anchors solely to enable this path).
  /// Runs through the standard `is_gov_authorized` m-of-n gate with a
  /// 14-day timelock. See deploy/state/recovery-verification.md §2.
  ActDeregisterStake
}

pub type QueuedAction {
  action_id: ByteArray,
  action_kind: ActionKind,
  target_script: ByteArray,
  target_tx_hash: ByteArray,
  payload_hash: ByteArray,
  queued_at_ms: Int,
  executable_at_ms: Int,
  expires_at_ms: Int,
}

pub type GovDatum {
  signers: List<VerificationKeyHash>,
  signer_joined_at_ms: List<Int>,
  signer_last_qualified_ms: List<Int>,
  threshold: Int,
  queued: List<QueuedAction>,
  signer_compensation_pool: Int,
  last_distribute_ms: Int,
  distribute_period_ms: Int,
  nonce: Int,
}

pub type GovRedeemer {
  QueueAction {
    action_kind: ActionKind,
    target_script: ByteArray,
    target_tx_hash: ByteArray,
    payload_hash: ByteArray,
    timelock_ms: Int,
    ttl_ms: Int,
  }
  CancelAction { action_id: ByteArray }
  ExecuteAction { action_id: ByteArray }
  RotateSignersRedeemer {
    new_signers: List<VerificationKeyHash>,
    new_threshold: Int,
  }
  Heartbeat { signer: VerificationKeyHash }
  DistributeSignerCompensation {
    triggering_signer: VerificationKeyHash,
    forfeit_output_idx: Int,
  }
  /// Compound-time top-up: vault_keeper_hot.Compound (post-Phase-77) spends
  /// + reproduces the MultisigGov UTXO, and this redeemer's validator
  /// auto-derives the `delta` from the continuing-output USDCx increment
  /// (V1 internal audit fix). No signer required — authorization is the
  /// paired vault_keeper_hot.Compound spend which physically transfers
  /// the gov-share USDCx into this UTXO.
  ReceiveCompoundShare
}

// ─────────────────────────────────────────────────────────────────────
// Treasury — see spec/treasury.md
// ─────────────────────────────────────────────────────────────────────

pub type SpendCategory {
  AuditReserve
  Operations
  RD
  Buffer
}

pub type TreasurySpendRecord {
  tx_hash: ByteArray,
  category: SpendCategory,
  amount: Int,
  recipient: Address,
  timestamp: Int,
}

pub type TreasuryDatum {
  audit_reserve_balance: Int,
  operations_balance: Int,
  rd_balance: Int,
  buffer_balance: Int,

  audit_bps: Int,
  ops_bps: Int,
  rd_bps: Int,
  buffer_bps: Int,

  last_spend_time_audit: Int,
  last_spend_time_ops: Int,
  last_spend_time_rd: Int,
  last_spend_time_buffer: Int,
  last_param_update_time: Int,

  monthly_cap_audit: Int,
  monthly_cap_ops: Int,
  monthly_cap_rd: Int,
  monthly_cap_buffer: Int,

  recent_spend_log: List<TreasurySpendRecord>,

  governance_policy: ByteArray,
  governance_name: ByteArray,
  min_audit_reserve: Int,
}

pub type TreasuryRedeemer {
  /// Passive accounting transition driven by Compound's fee output.
  /// Validates that the treasury's continuing datum splits the inflow by
  /// the current ratios.
  Receive { incoming_amount: Int }
  /// Governance-gated outflow.
  Spend {
    category: SpendCategory,
    amount: Int,
    recipient_idx: Int,
    audit_invoice_ref: ByteArray,
  }
  /// Forfeit-to-audit-reserve flow from MultisigGov DistributeSignerCompensation.
  ReceiveGovForfeit { forfeit_amount: Int }
  /// Governance-gated parameter update (180-day cooldown).
  UpdateParams {
    new_audit_bps: Int,
    new_ops_bps: Int,
    new_rd_bps: Int,
    new_buffer_bps: Int,
    new_monthly_cap_audit: Int,
    new_monthly_cap_ops: Int,
    new_monthly_cap_rd: Int,
    new_monthly_cap_buffer: Int,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Keeper authorization — see spec/keeper-auth.md
// ─────────────────────────────────────────────────────────────────────

pub type RegistrationMode {
  GovernanceOnly
  Mixed
  PermissionlessWithBond
}

pub type KeeperBond {
  bond_owner: VerificationKeyHash,
  bond_amount: Int,
  posted_at: Int,
  withdrawal_requested_at: Option<Int>,
}

pub type KeeperAuthDatum {
  registration_mode: RegistrationMode,
  authorized_pkhs: List<VerificationKeyHash>,
  active_bonds: List<KeeperBond>,
  bond_amount_required: Int,
  last_config_update_time: Int,
  cooldown_ms: Int,
  max_authorized_count: Int,

  rotation_epoch_start_ms: Int,
  rotation_period_ms: Int,
  failover_window_ms: Int,
  last_successful_tx_at: Int,
  nonce: Int,

  governance_policy: ByteArray,
  governance_name: ByteArray,
}

pub type KeeperAuthRedeemer {
  WithdrawAsAuthorized { keeper_pkh: VerificationKeyHash }
  PostBond { bond_owner: VerificationKeyHash }
  RequestBondWithdrawal { bond_owner: VerificationKeyHash }
  WithdrawBond { bond_owner: VerificationKeyHash }
  UpdateAuthDatum { new_datum: KeeperAuthDatum }
  /// Phase 3+ — never reachable at V1 launch (active_bonds always empty).
  SlashBond {
    bond_owner: VerificationKeyHash,
    evidence_ref: ByteArray,
    slash_amount: Int,
  }
}

// ─────────────────────────────────────────────────────────────────────
// Registry — see spec/architecture.md §3.6
// ─────────────────────────────────────────────────────────────────────

pub type StableTokenEntry {
  policy: ByteArray,
  name: ByteArray,
}

pub type LiqwidMarketEntry {
  action_addr_hash: ByteArray,
  qtoken_policy: ByteArray,
  qtoken_name: ByteArray,
  underlying_policy: ByteArray,
  underlying_name: ByteArray,
  active: Bool,
}

/// §5.4 P3 — dual-feed oracle entry for one asset.
///
/// V1 integrates Charli3 + Orcfax fair-price feeds for Tier 1 slippage
/// checks on DEX routes (DeployToProtocol peg-floor enforcement) + SwapAda
/// oracle bounds. Each asset gets an entry pinning its oracle sources +
/// freshness + cross-feed disagreement bounds. Populated via governance
/// `UpdateRegistry` (14d timelock).
///
/// Feed datum format (canonical V1 PriceSample):
///   InlineDatum(PriceSample { price_bps: Int, timestamp_ms: Int })
/// Where price_bps = (asset_price_usdcx × 10_000) e.g. $1.00 DJED = 10_000.
/// timestamp_ms is the ledger time at which the off-chain oracle operator
/// published the sample. Off-chain operator is responsible for aggregating
/// Charli3/Orcfax native feeds into this canonical format. Future V1.x /
/// V2 may parse Charli3/Orcfax native datum formats directly.
pub type AssetOracleFeed {
  /// Script hash of the reference-UTXO address hosting this feed.
  feed_script_hash: ByteArray,
  /// NFT policy that pins the canonical feed UTXO (one-shot style —
  /// stops attackers from creating decoy UTXOs at the same address).
  /// Set to #"" to skip NFT pin (not recommended for production).
  feed_auth_policy: ByteArray,
  /// NFT name under `feed_auth_policy` (same behavior re: #"" skip).
  feed_auth_name: ByteArray,
}

pub type AssetOracleEntry {
  /// Asset this oracle pair prices — (policy, name).
  /// ADA uses (#"", #"") per Cardano lovelace convention.
  asset_policy: ByteArray,
  asset_name: ByteArray,
  /// List of redundant feeds (typically 2 — one Charli3, one Orcfax).
  /// Caller's read_fair_price requires min_feeds count present.
  feeds: List<AssetOracleFeed>,
  /// Max cross-feed price disagreement in bps (e.g. 200 = 2%).
  /// If feeds diverge beyond this, read_fair_price fails.
  max_disagreement_bps: Int,
  /// Max age of any single feed sample vs tx.validity_range.lower_bound
  /// in milliseconds. Stale feeds fail read_fair_price.
  max_staleness_ms: Int,
  /// Minimum number of healthy feeds required to return a price.
  /// Typically set to list.length(feeds) for "all feeds must agree".
  min_feeds: Int,
}

/// Canonical V1 oracle price sample datum (InlineDatum on feed UTXO).
pub type PriceSample {
  /// Price in asset/USDCx × 10_000. 10_000 == $1.00.
  price_bps: Int,
  /// Ledger ms timestamp when the oracle operator published this sample.
  timestamp_ms: Int,
}

pub type RegistryDatum {
  governance_policy: ByteArray,
  governance_name: ByteArray,
  protocol_hashes: List<ByteArray>,
  stable_tokens: List<StableTokenEntry>,
  liqwid_markets: List<LiqwidMarketEntry>,
  /// §5.4 P3 — dual-feed oracle registry. Governance-managed via
  /// UpdateRegistry (14d timelock). Empty list at V1 launch; populated
  /// per-asset as Charli3+Orcfax feeds come online.
  asset_oracles: List<AssetOracleEntry>,
  /// §B@launch=1 (2026-04-22) — whitelisted SwapAdapter script hashes.
  /// Each entry is a 28-byte Plutus V3 staking validator hash of an
  /// audited DEX adapter (see `lib/vault/swap_adapter.ak`). vault_
  /// protocol.DeployToProtocol + vault_admin_deploy.AdminDeployNonDeposit
  /// (post-Phase-77c extraction from vault_gov_emergency) only permit
  /// DEX routing through adapters whose hash appears here. Updated via
  /// governance UpdateRegistry (14d timelock + 1-of-n cancel) — enables
  /// post-launch addition of new DEX adapters without V1 vault redeploy
  /// / depositor migration. V1 launches with exactly one entry:
  /// `minswap_v2_adapter` hash.
  swap_adapter_hashes: List<ByteArray>,
  last_update_time: Int,
  /// Keeper PKH allowed to KeeperToggleMarket (immutable once set;
  /// per internal verification, must be changed only by full redeploy).
  keeper_pkh: ByteArray,
}

/// Registry redeemers carry no payload — the new RegistryDatum is read
/// from the continuing output's InlineDatum, and the validator enforces
/// the diff (old vs new) per redeemer's allowed-mutation set.
pub type RegistryRedeemer {
  /// Governance-gated whitelist update (14-day governance timelock +
  /// 1-hour on-chain cooldown; protocol_hashes / stable_tokens /
  /// liqwid_markets all updatable; keeper_pkh + governance_* immutable).
  UpdateRegistry
  /// Keeper unilateral pause (no cooldown, active: True→False only,
  /// at least one toggle must occur per internal verification).
  KeeperToggleMarket
  /// Governance fast path for Liqwid migrations (1-hour governance
  /// timelock + 1-hour on-chain cooldown; per-market action_addr_hash +
  /// active flag updatable; everything else immutable).
  FastUpdateMarkets
}
