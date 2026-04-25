# security-model.md — V1 Threat Model

V1's security story rests on three layers: (1) compile-time trust anchors that are baked into validator hashes at deploy, (2) redeemer-level invariants verified on every transaction, and (3) explicit operator obligations that bound the trust delegated to off-chain actors. This document enumerates adversaries, the attack surface each can reach, the on-chain defenses, and the residual risks we disclose to depositors.

---

## 1. Adversary Classes

| Class | Capabilities | In-Scope |
|-------|--------------|----------|
| **External user** | Submit arbitrary TXs, deposit/withdraw, mint scam tokens, send donations | Yes |
| **Compromised keeper** | Sign TXs as `keeper_pkh`, access to keeper's hot key, sees real-time vault state | Yes |
| **Malicious governance quorum** | m-of-n signers collude, can queue and execute any governance action | Yes (residual) |
| **Rogue single signer** | 1-of-n compromised, can 1-of-n cancel any queued action | Yes (protective, not offensive) |
| **Liqwid protocol failure** | Bad debt, rate oracle manipulation, pool migration with attacker action_addr | Partial (escape hatches documented) |
| **Minswap V2 batcher failure** | Batcher offline, stuck orders, invalid fills | Yes (expire + cancel paths) |
| **USDCx issuer failure** | Circle revokes or changes USDCx; xReserve bridge compromise; underlying USDC backing failure | Out of scope (see §6.1) |
| **Cardano ledger failure** | Re-org, node consensus split, Plutus bug | Out of scope |
| **Discord/Telegram channel injection** | Attacker messages via channel, tries to social-engineer operator | Yes (explicit refusal policy) |

---

## 2. Six On-Chain Identities (Human Controllers)

V1 separates authority across six distinct key-controlled identities. No single human controls more than one, by policy.

**Layer-scoping note**: all six identities below are **operational roles for running a vault instance**. They describe the OptiVaults-operated instance (or any vault fork). The protocol-layer code itself ([`optivaults-protocol`](https://github.com/OptiVaults/optivaults-protocol)) has no controllers — anyone may read it, fork it, or deploy their own instance with their own identity set. The table below is about the **operator instance** running at `optivaults.app`; a fork operator assembles their own identity set, which is entirely independent of OptiVaults's.

| # | Identity | Layer | Role | On-Chain Artifact | Rotation Path |
|---|----------|-------|------|-------------------|---------------|
| 1 | **Keeper** | Operator | Compound, rebalance, batch, swap, Liqwid supply/recall | Authorized via `keeper_stake_script` zero-withdraw pattern — `keeper_stake_hash` is a compile-time param of `vault_user` / `vault_keeper_hot` / `vault_protocol` / `vault_recall` / `vault_liqwid`; the actual authorized PKH set lives in the stake-script's own datum (governance-mutable) | `UpdateKeeperAuth` via governance (14-day timelock) updates the stake-script datum |
| 2 | **Governance Signer A** | Instance governance | 1-of-3 quorum member | pubkey in `GovDatum.signers` | `RotateSigners` 14d timelock |
| 3 | **Governance Signer B** | Instance governance | 1-of-3 quorum member | pubkey in `GovDatum.signers` | `RotateSigners` 14d timelock |
| 4 | **Governance Signer C** | Instance governance | 1-of-3 quorum member | pubkey in `GovDatum.signers` | `RotateSigners` 14d timelock |
| 5 | **Ref-script deployer** | Operator | Deploys validator reference scripts, holds deployer wallet UTXOs | Deploy wallet pubkey (off-chain identity, anchored via TX history) | Retirement after V1 deploy completes (ref scripts are immutable) |
| 6 | **Founder subsidy wallet** | Operator | Holds personal runway funding the vault until break-even | Personal Cardano wallet | Retirement or public hand-off per §9.2 of whitepaper |

**"Instance governance" vs "Operator"** — governance signers (identities 2-4) control on-chain protocol-policy mutations (fee rate, strategy, keeper authorization); they are governance **for this specific vault instance**. A fork operator would have their own governance signer set, separate from OptiVaults's, with potentially different signer counts, rotation policies, and humans. The protocol-layer code doesn't care who the signers are — it just checks that the required threshold signs any governance action.

**Launch reality:** at V1 launch, identities 1 + 5 + 6 are the same founder. Identities 2/3/4 are founder + 2 trusted collaborators. The 6-identity map is the **target state** for the OptiVaults instance — §8.6 of the whitepaper discloses the current concentration and the path to separation.

---

## 3. Attack Surface Catalog

### 3.1 Phantom Vault Injection (internal-verification-era CRITICAL, closed)

**Attack:** Attacker deploys their own `vault_nft` validator, mints `(attacker_policy, "OptiVault")`, crafts a fake VaultDatum claiming `vault_nft_policy = attacker_policy`, sends UTXO to the real proxy address. All NFT checks in the legacy validators were self-referential (read policy from datum, verify policy in UTXO) → fake UTXO passed all checks → first-deposit multiplier minted 10^13 real vUSDCx from fake datum → burned back to real vault for full drain.

**V1 defense:** Vault NFT policy is a **compile-time parameter** on `vault_proxy`, `vusdcx`, and `order`. Every NFT check anchors to the compile-time value, which cannot be forged without breaking the validator hash. Fake datum UTXOs at the real proxy address are ignored because their `vault_nft_policy` claim is irrelevant — the validators don't read it.

**Status:** structurally impossible in V1.

### 3.2 Governance Empty-Hash Trust Delegation

**Background:** `QueueAction` accepts `target_tx_hash == #""` (empty). When target is empty, `ExecuteAction` does **not** enforce `tx.id == target_tx_hash`. This is deliberate — most governance actions cannot predict their future TX hash at queue time (the hash depends on execute-time fee-paying inputs which are unknown in advance). Full pattern documented in `spec/governance.md §5`.

**What empty-hash does NOT change:** `ExecuteAction` **always** requires `signers_present >= gov.threshold` (`multisig_gov.ak:378`). The empty-hash path bypasses ONLY the `tx.id` binding — the payload_hash binding (blake2b_256 of the redeemer parameters) is still enforced, so the target validator's post-execute state is fully fixed at queue time.

Common mischaracterization to flag: **"any 1-of-n signer can execute arbitrary admin after 14 days" is incorrect**. The validator has no 1-of-n execute path. The attack surface is m-of-n collusion, not 1-of-n delegation.

**Historically closed variant (internal-verification-era):** a grief path involving `timelock = 0` plus 1-signer `CancelAction` was closed during internal review. Current `QueueAction` enforces `timelock_ms >= min_timelock_ms(action_kind)` (§3 of governance.md), so every queued action sits at ≥ its documented minimum (7-21 days for substantive actions, 0-1h for `EmergencyWithdraw` / `FastUpdateMarkets`).

**V1 residual risk (accurately stated):**

- **`m` colluding signers** queue an action (14-30 days in advance depending on action kind).
- After timelock, the same `m` signers execute. Payload_hash binding means the post-execute on-chain state is exactly what they queued — no swap-in of a different redeemer. What empty-hash frees up is the execute TX's *shape* (fee inputs, non-essential outputs) but not the payload's intent.
- **On-chain defense — 1-of-n CancelAction**: any single signer not in the colluding set can cancel at any time during the timelock window (`multisig_gov.ak::CancelAction`, `sig_ok >= 1`).
- **Off-chain defense — operator charter**:
  - Broadcast every non-trivial queue within 1 hour of signing (public Discord + on-chain CBOR decode).
  - ≥1 honest signer actively monitoring every queue.
  - Recruit signers such that ≥2 are non-colluding (V1 launch: 1 founder + 2 independent Cardano SPOs).

**V1 launch note (3-of-3 unanimity):** at launch `threshold == n == 3`, so "m colluding" means all 3 signers. 1-of-n cancel = any 1 of 3 can veto. Structurally stronger than typical threshold setups because the queue itself requires unanimity. The concern only tightens once Phase 2+ introduces `threshold < n` (5 signers / threshold 4), where 4 colluders + 1 silent honest signer could push a malicious action through if the off-chain monitoring obligation fails.

### 3.3 vUSDCx Inflation via Mint-Ratio Skim (internal-verification-era, closed)

**Attack:** Keeper aggregates multiple orders into one BatchProcess, computes `expected_mint` using pre-batch snapshot, but mints `expected_mint + 1` (rounding "surplus") → 1 unit of vUSDCx dilutes every holder by ~1/total_shares per batch.

**V1 defense:** `vault_batcher.ak:valid_mint_ratio` enforces `total_mint == Σ per_order_fair_shares` (exact equality, no tolerance). Rounding surplus is not mintable — it appears as a share-price uptick for existing holders.

**Status:** closed.

### 3.4 Keeper Wallet Hijack (in-scope, bounded — operator-layer scope)

**Layer scope**: keeper wallet compromise is an **operator-layer** threat. It affects operational availability of the OptiVaults-operated instance (or any fork) but does not propagate to the protocol layer — a fork running the same Aiken contracts with an independent keeper wallet is unaffected by OptiVaults's keeper compromise. The on-chain invariants below bound keeper-compromise damage regardless of which instance's keeper is compromised.

**Scenario:** Keeper's hot key is compromised. Attacker can:
- Sign Compound, RebalanceBuffer, MergeUtxo, BatchProcess, SupplyToLiqwid, RecallFromLiqwid, DeployToProtocol, VaultSwap, AdminDeployNonDeposit (gov-path only), KeeperToggleMarket.
- Sign VaultSwap to send vault funds to a Minswap V2 order with an attacker-controlled owner → at fill time, funds go to attacker wallet.

**V1 bounded damage:**
- `verify_destination_whitelisted` — DeployToProtocol target addresses must have stake credential in `registry.protocol_hashes`. A rogue receiver address would need to have its stake credential pre-whitelisted.
- `no_vusdcx_leak` (internal verification) — BatchProcess cannot route minted vUSDCx to non-order-owner addresses.
- `verify_other_tokens_preserved` (internal verification) — non-deposit tokens cannot be drained via Compound/Rebalance.
- `slippage_ok` on orders (internal verification) — keeper cannot execute fills with price deviation beyond user's `min_shares` or `max_shares_burn`.
- `buffer_target_bps >= 500` on UpdateStrategy — but keeper has no UpdateStrategy access, gov-only.

**Remaining risk:** keeper could do `VaultSwap` against Minswap V2 with attacker-controlled swap target that is within `protocol_hashes` whitelist. Defense: `protocol_hashes` whitelist is tight (Minswap V2 order script + stake, Liqwid action addresses). Expanding it requires `UpdateRegistry` with 14-day timelock.

**Keeper-commission slashing:** V1 defers formal slashing. At V1 launch, keeper compromise is bounded by the above contract checks + the economic reality that a compromised keeper gains at most the performance-fee stream (4.5% of yield × 20% keeper share ≈ 0.9% of gross yield, ~$45/year at 100K TVL). Rational-attacker profit ceiling is below the cost of compromise for anyone outside the founder's threat model.

### 3.5 Treasury Drain via Compromised Governance

**Scenario:** m signers collude, queue a `TreasurySpend` action for the full buffer category balance.

**V1 defenses:**
- 7-day timelock → any depositor has 7 days to withdraw.
- `audit_reserve_ratio >= 2000` floor → audit category cannot be drained below 20% of treasury, even by governance.
- 1-of-n cancel → any remaining honest signer can veto.
- TX audit trail — destination address is public on-chain.

**Residual risk:** genuine m-of-n collusion is the explicit trust assumption of MultisigGov. Mitigation: public signer identities, 1-hour broadcast obligation, community monitoring, 7-day window for mass withdrawal.

### 3.6 Liqwid Bad Debt

**Scenario:** Liqwid market suffers protocol-level loss (oracle manipulation, liquidation failure, bad debt accumulation) → vault's qTokens become worth less than `supplied_value`.

**V1 behavior:**
- `RecallFromLiqwid` (keeper path): requires `underlying_received >= supplied_value`. If Liqwid returns less, TX fails. Keeper cannot automate the loss.
- `EmergencyWithdraw` (governance path): accepts `loss_amount >= 0`, explicitly writing the loss to `non_deposit_value`. Requires m-of-n signatures + 0-day timelock (emergency).
- Depositors see the loss proportionally via share-price decrease at next Compound.

**Escape hatches:**
- `KeeperToggleMarket` — keeper can disable a market unilaterally (1-way, `active: true → false`).
- `EmergencyWithdraw` — governance absorbs loss and re-opens normal flow.

### 3.7 USDCx Depeg

**Scenario:** USDCx trades at $0.50 on DEX while Circle's xReserve accounting is still 1:1 → arbitrage opportunity for attacker to deposit 2 USDCx (market price $1) and claim shares worth 1 real USD of underlying.

**V1 defense:** V1 has **no on-chain USDCx price oracle**. This is intentional — adding a price feed would introduce oracle manipulation attack surface.

**Off-chain defense:** `tvlCapMonitor` + depeg monitoring via **Cardano-native oracle feeds** (Charli3 + Orcfax + Minswap V2 TWAP as an on-chain triangulation source), 15-min sustained deviation threshold, 2/day trigger rate-limit. No cross-chain oracle bridges are used (consistent with whitepaper §2.3 "no cross-chain bridges"). Prior internal-verification-phase deployments polled CoinGecko + DeFi Llama off-chain feeds — those were convenient for testing but are web2 price APIs, not on-chain oracles. V1 moves to on-chain Cardano oracles for the launch configuration. On sustained depeg, keeper triggers `KeeperToggleMarket` (no timelock) + governance queues `EmergencyWithdraw` (timelock per `governance.md` §4.6).

**Operator obligation:** suspend new deposits within 1 hour of sustained depeg signal. Withdraws remain open (client-side whitelist never blocks withdraw — see whitepaper §9.2). Disclosed in whitepaper §6.5.

### 3.8 First-Depositor Share Dilution (internal-verification-era, closed)

**Attack:** Vault at `total_deposited = 1, total_shares = 10^15`. First new depositor deposits 10 USDCx → receives `10 * 10^15 / 1 = 10^16` shares, but existing holder's `1 * 10^15 / (10^15 + 10^16)` = ~9% of their prior value, effectively re-minting the multiplier.

**V1 defense:** `valid_deposited > 0` and `valid_shares > 0` floors enforced on every redeemer. A zombie state with `total_deposited = 0, total_shares > 0` cannot exist — EmergencyWithdraw must leave ≥ 1 unit of both or use a different redeemer.

**Status:** closed.

### 3.9 Donation Poisoning

**Attack:** Attacker sends UTXO with arbitrary tokens to the proxy address, hoping to bloat vault or force min-ADA inflation.

**V1 defense:**
- MergeUtxo whitelist: only `{ADA, deposit_token, registry.stable_tokens}` can be merged. Other tokens are rejected — keeper cannot merge the donation.
- If the donation UTXO cannot be merged, it sits at the proxy address unconsumed. Attacker has voluntarily burned their tokens.
- `AdminDeployNonDeposit` (gov-path) can retrieve legitimate stuck tokens.

**Status:** closed.

### 3.10 Order UTXO Phantom Datum (internal-verification-era, closed)

**Attack:** Attacker places a UTXO at the proxy address with a forged VaultDatum (not referenced by `find_vault_datum_ref`'s NFT check in the pre-fix internal-verification codebase). Order's Expire redeemer reads this fake datum, enabling permissionless drain of order UTXOs under attacker's control.

**V1 defense:** `find_vault_datum_ref` enforces `datum.vault_nft_policy != #""` and `quantity_of(value, vault_nft_policy, name) == 1`. Fake UTXOs without the real Vault NFT are ignored. Expire fallback refunds the full order value to the owner.

**Status:** closed.

---

## 4. Trust Delegations (Explicit)

V1 explicitly delegates trust to these parties. Depositors must evaluate each delegation before depositing.

| Trust Target | Scope of Delegation | Bound |
|--------------|--------------------|-----|
| **Keeper operator** | Swap routing, compound timing, allocation within strategy | Slippage tolerance + `protocol_hashes` whitelist + strategy caps |
| **Governance signers** | Fee changes, strategy changes, emergency actions | Timelock + 1-of-n cancel + hard caps on fees |
| **Liqwid protocol** | Safe custody of USDCx/DJED/USDM while supplied | Liqwid's own audit + escape hatches (KeeperToggleMarket, EmergencyWithdraw) |
| **Minswap V2 batcher** | Execute DEX orders at fair price | User-set `min_shares` + slippage checks + Cancel/Expire fallback |
| **USDCx issuer (Circle via xReserve)** | Maintain 1:1 USDC backing via xReserve + USDC's own USD reserves | Circle Deloitte monthly attestation + depeg monitoring + operator halt procedure |
| **Blockfrost / Ogmios indexing** | Provide accurate UTXO state for keeper + API | Multi-source redundancy + on-chain validation as source of truth |

---

## 5. Defense-in-Depth Layers

### 5.1 Compile-time anchors (cannot be changed without full redeploy)

Validator hashes + fundamental identity. Changing any forces a new deployment (new addresses, migration).

- `vault_nft_policy` — Vault NFT identity (baked into `vault_proxy` / `vusdcx` / `order`)
- `governance_policy` + `governance_name` — MultisigGov NFT identity (baked into `multisig_gov` / `keeper_stake_script`)
- `core_stake_hash`, `protocol_stake_hash`, `liqwid_stake_hash`, `admin_stake_hash` — Staking validator hashes (baked into `vault_proxy`)
- `keeper_stake_hash` — keeper_stake_script hash (baked into `vault_user` / `vault_keeper_hot` / `vault_protocol` / `vault_recall` / `vault_liqwid`)
- `treasury_hash` — Treasury script hash (baked into `vault_keeper_hot` for Compound fee routing, post-Phase-77 — Compound migrated there from vault_core during the authorization-boundary split + `multisig_gov` for DistributeSignerCompensation forfeit routing)
- `deposit_token_policy` + `deposit_token_name` — USDCx policy/name (baked into `treasury` + `multisig_gov`)
- `vusdcx_policy` — vUSDCx share token policy (deployed as a minting policy parameterized by `vault_hash` + `vault_nft_policy`)
- `registry_hash`, `order_script_hash`, `vault_hash` — cross-validator dependency anchors

Note on keeper identity: V1 does NOT anchor a specific `keeper_pkh` at compile time. The authorized keeper set is **governance-mutable** via `UpdateKeeperAuth` (14-day timelock) which modifies the `keeper_stake_script`'s internal datum. The compile-time anchor is the stake-script *hash*, not the PKH — allowing rotation without redeploy.

### 5.2 Runtime invariants (enforced on every TX)

- Token preservation (multiple internal-verification rounds)
- Accounting non-negativity (`idle_buffer >= 0`, `non_deposit_value >= 0`, `total_deposited > 0` post-operation)
- Fee caps (`performance_fee_bps <= 450`, `early_withdraw_fee_bps <= 100`)
- Time-field width caps (`upper - now <= 1h` on every time-writing redeemer, internal verification)
- Allocation invariant (`alloc_sum + idle_buffer <= total_deposited + NDV + Σ liqwid_principal`)
- Share-price monotonicity (Deposit/Compound/Withdraw preserve or grow share price, internal-verification deferred-yield rule)

### 5.3 Economic / social layer

- 100K USDCx pre-audit TVL cap (operator-enforced via `tvlCapMonitor`)
- Public disclosure of governance signer identities
- 1-hour broadcast obligation for governance queues
- Orderly wind-down protocol (whitepaper §9.2)
- Third-party audit gate before cap removal

---

## 6. Out-of-Scope

### 6.1 USDCx issuer failure
V1 assumes USDCx is a live, well-backed stablecoin. Failures in the trust chain — Circle's corporate integrity, xReserve bridge security, USDC's USD reserve backing — are outside V1's threat model. Depositors should evaluate USDCx's own risk profile separately, including Circle's compliance posture, xReserve smart contract audits, and USDC's Deloitte attestations.

### 6.2 Cardano ledger failure
Consensus splits, Plutus compiler bugs, stake pool attacks, and chain re-orgs are outside V1's threat model. V1 inherits Cardano's security assumptions.

### 6.3 Physical wallet compromise of depositor
If a user's wallet is compromised, their shares can be withdrawn. V1 does not provide additional protection — this is the user's own key management.

### 6.4 Legal / regulatory
V1 makes no representation about regulatory compliance. Users are responsible for their own jurisdictional obligations.

---

## 7. Residual Risk Summary

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Governance m-of-n collusion | Low | High | Public identities, 14d timelock, 1-of-n cancel, orderly wind-down |
| Keeper compromise + whitelist abuse | Low | Medium | Tight `protocol_hashes`, governance-only strategy changes, slippage caps |
| Liqwid bad debt | Medium | Medium | EmergencyWithdraw escape hatch, KeeperToggleMarket 1-way pause |
| USDCx depeg | Medium | High | Off-chain monitoring, operator halt procedure |
| Minswap batcher outage | Medium | Low | Order Expire fallback refunds to user |
| Founder wallet compromise | Low | Medium | Gov rotation + treasury separation mitigate concentration risk |
| Plutus bug in V1 validators | Low | High | Internal audit (≥1 external round pre-launch), Responsible Disclosure Policy + ex gratia recognition framework (`docs/audit-scope.md §6`), EmergencyWithdraw |
| Regulatory action (SEC / MiCA / FinCEN / OFAC / local) | Low-Medium | High (operator legal exposure) / Low (depositor principal — withdraw always open) | Public-goods positioning (non-commercial, non-solicitation, geographic framework) per whitepaper §12; operator may geoblock jurisdictions based on legal opinion |

---

## 8. Audit Posture

V1 enters public launch with:
- **Multi-round internal verification** carried forward into V1 via unchanged validator patterns that remain.
- **0 CRIT/HIGH/MEDIUM** in internal-verification phase.
- **V1-specific scope additions** (treasury, keeper_stake_script, V1 governance redeemers) require additional internal rounds + at least one external audit before the TVL cap is lifted.

See `docs/audit-scope.md` for the V1 audit plan.

---

## 8.5 Regulatory Posture

V1 is positioned as a non-commercial Cardano DeFi public-goods reference implementation — not an investment product, not a fund, not a managed service. Full regulatory posture disclosed in whitepaper §12 (non-investment / non-solicitation / geographical framework / code-is-law / depositor due-diligence). The V1 bootstrap strategy explicitly does not pursue VC funding, token issuance, or SAFE / SAFT commitments.

Residual regulatory risk is non-zero and scales with TVL:

- **Phase 1 (100K cap, TVL $5K-$25K expected)**: <5% enforcement risk — monetary size below typical enforcement thresholds
- **Phase 2 (post-audit, cap lift to 1M, TVL $100K-$500K)**: 10-20% rising visibility — geographic posture + legal review recommended prior to cap lift execution
- **Phase 3+ (TVL $1M+)**: 30-50% substantial risk — legal entity + compliance policy recommended prior to entering this tier

Audit firms evaluating V1 operational risk should note this posture as separate from smart-contract risk surface.

---

## 9. Disclosure Policy

Any suspected vulnerability should be reported privately to `optivaults@gmail.com` with PGP encryption (key at optivaults.app/security). Response SLA: 24 hours acknowledgment, 72 hours triage, bounty payable from treasury audit reserve category per severity tier. Public disclosure follows a 90-day coordinated window unless actively exploited.
