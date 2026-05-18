# Three-Layer Governance Safety: Preserving Depositor Recovery Under Single-Signer Governance

*OptiVaults V1 Security Design Series — Part 1 of 4*

---

The most uncomfortable reality at V1 launch is this: the target is to recruit two independent Cardano SPOs as governance signers before mainnet ceremony, forming a 3-of-3 unanimous multisig; but under Phase 1 small-TVL conditions (the $500–$25K range described in whitepaper §8.2), SPO recruitment may be deferred or kept in a standby form, and the founder effectively operates governance as a single signer.

"Single-signer governance with a fragile key" sounds like a red flag depositors should walk away from.

V1's response is **not** to promise "nothing will go wrong." It is to design the contracts so that even if the founder's key is stolen, even if the founder stops paying the operating subsidy, even if the founder becomes incapacitated for 90+ days, depositors still have a path to recover USDCx. That guarantee doesn't rely on promises — it lives in the validator code, and anyone can verify it directly against the deployed script hashes.

This part of the series unpacks how that guarantee holds together: three layers of structural protection, each addressing a specific threat — a compromised governance key trying to inflict loss, a compromised keeper trying to disrupt recovery, and the case where governance and keeper both go dark.

The whole protocol is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Every validator cited here is browsable there.

---

## Why Three Layers

First, what we're defending against.

Traditional DeFi vault designs typically take one of two approaches on governance: (a) no emergency path at all — when something goes wrong, the community has to coordinate manually; or (b) an emergency path that grants the multisig broad authority, including directly modifying datum, reducing `total_deposited`, removing position records.

Neither fits V1's launch posture. (a) is brittle — having no freeze mechanism when Liqwid runs into trouble is a real risk. (b) is too broad — if the emergency path can directly modify ledger fields, then "governance key compromise → attacker rewrites the vault to zero" becomes a viable scenario, leaving depositors with only reputational evidence and no on-chain remedy.

V1 splits the emergency path into three layers. Each layer handles a specific threat, and **no layer grants governance more power than that specific threat requires**:

| Layer | Triggered by | Can do | Cannot do |
|-------|--------------|--------|-----------|
| Layer 1 | Governance multisig | Toggle `frozen` flag | Modify `total_deposited`, `liqwid_positions`, `idle_buffer` |
| Layer 2 | Keeper (still callable under freeze) | Swap non-deposit tokens back to USDCx via whitelisted SwapAdapter | Route output to any address other than the vault |
| Layer 3 | Any vUSDCx holder (permissionless) | Unlock permissionless recovery paths | Modify any immutable datum field |

Stacked together, the coverage looks like this: **even if governance fails, even if the keeper fails, even if both fail simultaneously, depositors always have an exit path**.

---

## Layer 1 — `EmergencyWithdraw` Restricted to Freeze-Only

The first threat is "governance key compromised, attacker tries to use the emergency path to inflict loss."

Many vault designs make the emergency path "if the multisig signs, you can modify the datum however you want." V1 doesn't. `vault_gov_emergency.EmergencyWithdraw` is structurally restricted to freeze-only at the validator level:

- **Cannot reduce `total_deposited`.** Any transaction that writes a smaller value to this field is rejected at the validator level.
- **Cannot remove or modify any entry in `liqwid_positions`.** A Liqwid position's `supplied_value` and `qtokens_held` can only be written by `vault_liqwid.SupplyToLiqwid` / `RecallFromLiqwid` — the latter writes loss only when an actual physical Recall of underlying USDCx falls short (`supplied_value − underlying_received`).
- **Cannot accept a non-zero `loss_amount`.** Loss accounting cannot be unilaterally declared by governance signatures.

The **only thing it can do** is toggle the `frozen` flag between 0 and 1 — combined with a 14-day timelock plus 1-of-n cancel, this lets governance freeze the vault when it detects Liqwid anomalies or stablecoin depeg signals, halting new Deploys and position changes while the community plans recovery.

The `EmergencyWithdraw` timelock is 0 days (described in whitepaper §6.2) for response speed — when a persistent depeg signal needs an immediate freeze, governance can queue and execute in the same signing session. "0 days" means **minimum wait time is zero**, not that consensus is bypassed: each invocation still requires a full 3-of-3 signature (when SPOs are in place), still subject to 1-of-n cancel, still bound by payload-hash binding.

**Security property of this layer**: a compromised governance key can at most put the vault into a frozen state. It **cannot** orphan qToken positions, fabricate loss to depress the share price, or erase any depositor's principal record. Any action that could plausibly reduce NAV must go through `vault_liqwid`'s concrete token-movement paths, where the amount written is determined by actual Recall / Swap events on the ledger. The datum cannot be unilaterally crashed by governance.

---

## Layer 2 — `DeployToProtocol` Open for Swap-Out Under Freeze

Layer 1 closes the destructive path but introduces a new problem: **once the vault is frozen, it may still hold a large amount of DJED / USDM (recalled from Liqwid but not yet swapped back to USDCx). If freeze entirely blocks DeployToProtocol, those non-deposit tokens get stuck in the vault — depositors using Direct Withdraw would receive DJED instead of USDCx and would have to handle the swap themselves.**

For small depositors this is a terrible experience — freeze should protect them, not transfer the burden of DEX swap onto their shoulders.

Layer 2 handles this with a precise exception: when `frozen == 1` AND the redeemer's `deploy_token != deposit_token`, the keeper can still execute swap-out via a whitelisted SwapAdapter (Minswap V2).

The key property is that this exception **only opens swap-out, nothing else**:

- **The SwapAdapter validator enforces that the destination must be the vault's own address.** Even if the keeper's key is also compromised, the attacker cannot redirect the swap output to a wallet they control. The worst case is slippage forced within the Tier 2 peg-floor boundary (`min_receive × 10_000 ≥ deploy_amount × min_swap_peg_bps`), and the resulting USDCx still lands in the vault for depositor withdrawal.
- **New deposits / position expansion remain blocked by freeze.** Layer 2 does not allow USDCx → DJED swaps (because when `deploy_token == deposit_token`, the path goes through the normal route, which freeze blocks). It only opens the reverse direction.
- **Registry whitelist remains in force.** The SwapAdapter hash must be in `swap_adapter_hashes`, managed by 14-day timelock governance. A compromised keeper cannot inject arbitrary adapters.

Without Layer 2, freezing immediately strands the non-deposit-token portion until a 21-day `AdminDeployNonDeposit` governance fallback. Layer 2 shortens that 21-day window to "if the keeper is online, swap-out works immediately, so depositors doing Direct Withdraw receive USDCx."

---

## Layer 3 — CommunitySunset Auto-Stop

The first two layers assume "either the keeper or governance is still running." What if both are gone?

Layer 3 handles this worst case: when the vault has had no operations for 90 consecutive days (`max(last_compound_time, last_realloc_time) + 90d ≤ now`), any vUSDCx holder can invoke `vault_user.CommunitySunset` — a permissionless redeemer. Once triggered:

- `community_sunset_triggered` flag is set to 1 (one-way, irreversible).
- `frozen` is set to 1 (blocks new Deploy).
- **`vault_liqwid.RecallFromLiqwid` accepts any signer** (no keeper or governance signature needed).
- **`vault_protocol.DeployToProtocol` Layer 2 swap-out path also accepts any signer** (same).

Any vUSDCx holder can drive the full recovery chain — Recall → Swap → Withdraw — without keeper or governance involvement. The 90-day threshold corresponds to roughly 18 missed zero-yield heartbeats (one every 5 days), equivalent to a fully-dead keeper.

The sunset path **only opens recovery, it cannot mutate datum**. It cannot modify `total_deposited`, `total_shares`, `idle_buffer`, `liqwid_positions`, or any immutable field. The validator's preservation clauses ensure that during sunset, the SwapAdapter's destination, peg-floor, and slippage limits remain in force — an attacker cannot exploit the open recovery path to drain value, even post-sunset.

### Why `max(both)` Rather Than Just `last_compound_time`

Layer 3 triggers on `max(last_compound_time, last_realloc_time)`, which superficially gives the keeper room to "send only heartbeats, never productive Compound" and delay sunset indefinitely. This is deliberate — it preserves two legitimate operating scenarios:

- **Reference Implementation Mode** (whitepaper §2.6.1): during low-TVL periods, running heartbeats only is a legitimate operating mode. If we only looked at `last_compound_time`, Layer 3 would trigger prematurely in this mode.
- **Migration / V2 deployment scenarios**: governance may legitimately pause productive Compound during a migration window while maintaining vault state liveness through `RebalanceBuffer` or `UpdateStrategy` — both of which update `last_realloc_time`.

The adversarial case of "keeper sends only heartbeats to delay sunset" does exist, but is covered by other protections: whitepaper §5.4's 7-day keeper-inactivity gate **reads only `last_compound_time`**, regardless of heartbeats. If productive Compound stops for over 7 days, the gate activates: Direct Withdraw's early-withdraw fee is auto-waived, the m-of-n governance fallback path opens on keeper-authorized redeemers, and emergency-withdraw becomes economically reasonable. Layer 3 is therefore the **last** line of recovery, not the primary protection. Layer 1 + Layer 2 + 7-day gate + self-serve withdraw infrastructure already cover the keeper-sabotage scenario long before an attacker can stretch to Layer 3.

---

## Combined Coverage of the Three Layers

Stack the three layers and V1's response maps onto four concrete scenarios:

**Scenario A — Founder is honest but only holds one key**: the system operates normally as 1-of-1 multisig with timelock + cancel as safety primitives. Layers 1/2/3 are never triggered.

**Scenario B — Founder's key is stolen**: the attacker gains nothing of value. Layer 1 closes the brick path (cannot crash the vault), Layer 2 keeps recovery flow open (swap-out still works under freeze), and whitepaper §6.3's hard caps close fee abuse (`performance_fee_bps` can never be pushed above 4.5%). Even if the attacker queues a malicious action, the 14-day timelock and 1-of-n cancel realistically block it — if SPOs are in place by then, any independent SPO can cancel.

**Scenario C — Founder stops paying operational subsidy but hasn't formally initiated sunset** (the scenario described in whitepaper §9.2 (c)): keeper goes offline → §5.4's 7-day gate activates automatically (Direct Withdraw's early-fee is waived) → by day 90, Layer 3 can be triggered by any vUSDCx holder.

**Scenario D — Founder is incapacitated for 90+ consecutive days**: depositors directly invoke Layer 3 community sunset, recovering USDCx without any operator cooperation.

---

## What This Recovery Range Does **Not** Cover

Honest disclosure of boundaries matters. Layer 3's recovery range does **not** cover:

- **ADA locked in deployment ref-scripts** (V1 launch ceremony locks roughly 962 ADA across 20 ref-script UTXOs).
- **Stake credential registration deposits** (14 staking validators × 2 ADA = 28 ADA) — these are handled by the `ActDeregisterStake` governance action, which requires the founder's wallet signature.

These two portions bind the founder's deployment wallet and the A2 governance path as residual costs of single-signer governance — roughly 990 ADA in total. Depositors' USDCx principal does not fall in this residual range; it is always recoverable through Layer 1/2/3 + Direct Withdraw.

---

## Why This Design Makes Single-Signer Governance an Acceptable Fallback

Connect the four scenarios together: V1's depositor protection **does not rely on** "the governance key not being stolen," "the founder not becoming incapacitated," or "the keeper still being online." Each assumption has a corresponding recovery path as substitute.

This is the structural answer to "why is single-signer governance acceptable as a Phase 1 fallback": not because we believe the founder won't run into trouble, but because **the contract is designed so the consequences of the founder running into trouble are bounded**.

This isn't to say 3-of-3 with two independent SPOs is irrelevant. SPO recruitment remains the preferred path — it adds credibility and structural dissent veto, narrowing the "governance collusion" window from "14-day timelock + public observation" to "requires three independent identities cooperating." But it is not a launch blocker, because the contract-level protections already cap the depositor's worst case at "USDCx principal recoverable, only the convenience of V1 is lost" — that's an acceptable floor.

---

## Next Article

Part 2 handles the second concern: **how do you confirm these protections actually exist?** Unit tests can lie — change one line of validator logic and one line of test fixture, and the red light turns green. What V1 adds is adversarial chain replay: construct attack transactions, send them to a Preprod ceremony build of the live contract, and record the contract's rejection (or worse, acceptance) as on-chain evidence. Part 2 covers the methodology and the verified defense-layer taxonomy.

Part 3 handles V1's exposure to multi-stablecoin depeg risk — what can be defended against, what cannot. Part 4 dives into the phantom-vault attack vector, complementing the Architecture series' Article 4 on the compile-time NFT anchor.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/HY5sy8cz8s).*
