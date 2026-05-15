# 7-Day Keeper-Inactivity Dead-Man-Switch: Depositors Don't Have to Trust the Keeper

*OptiVaults V1 Operational Mechanics Series — Part 2 of 3*

---

The keeper is the only role in V1 that "must keep running for the vault to generate yield normally." It executes Compound, rebalances, Minswap V2 swaps, Liqwid Supply / Recall. Without the keeper, the vault no longer accrues yield — but all funds remain in the vault UTXO. It's "passive" rather than "automated."

How should depositors think about the risk that the keeper halts?

Traditional DeFi has two common responses: (a) change keeper to a multi-operator redundancy design where multiple keepers back each other up; (b) rely on multisig governance to intervene when the keeper halts.

V1 takes neither. V1 writes this defense at the contract layer: **after `last_compound_time + 7 days` passes, three things happen automatically** — depositors don't need to trust that the keeper is still alive, don't need to wait for multisig to convene. This article unpacks how the dead-man-switch operates, why 7 days, and most critically: **why it can't be fooled by forged timestamps**.

The whole protocol is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol).

---

## Three Things That Auto-Trigger

When `last_compound_time + 7d < tx.validity_range.upper`, the validator auto-triggers:

**(1) Direct Withdraw's early-withdraw fee auto-waived**.

Under normal operation, Direct Withdraw within the `min_hold_seconds` window incurs 0.1% early-withdraw fee (whitepaper §2.4). After 7 days of keeper inactivity, `vault_user.Withdraw` treats `early_withdraw_fee_bps` as 0, regardless of the value set in datum. This means depositors don't pay for the keeper's failure during a keeper halt.

**(2) Governance m-of-n fallback opens on keeper-authorized redeemers**.

Normally, `vault_liqwid.RecallFromLiqwid` / `vault_recall.RecallFromProtocol` / `vault_admin_deploy.AdminDeployNonDeposit` require keeper signature. After 7 days of keeper inactivity, the `require_keeper_or_governance_fallback` gate inside the validator opens — governance can use m-of-n signatures in place of the keeper to execute the same redeemer.

This makes "keeper runs away + funds stuck in Liqwid" resolvable: m-of-n governance can replace the keeper to Recall all qTokens back to USDCx, letting all depositors Direct Withdraw.

**(3) Emergency-withdraw becomes economically reasonable**.

The `emergency-withdraw` CLI and frontend tool let depositors locally construct TXs for self-exit, **without operator cooperation**. The tool has existed all along, but under normal conditions, taking emergency-withdraw still incurs early_withdraw_fee; after 7-day inactivity, the fee waives automatically, making emergency-withdraw attractive — neither depending on operators nor paying fees.

Add the three together: 7 days after the keeper has completely halted, depositors have three independent exit paths:

```
Path A: Use frontend / wallet to do Direct Withdraw (0% fee)
Path B: Wait for governance m-of-n signature intervention via RecallFromLiqwid
        to convert qTokens back to USDCx
Path C: Self-construct TX via emergency-withdraw CLI (0% fee)
```

None require keeper cooperation. Depositor principal security doesn't rely on "we promise the keeper won't fail" — it relies on the objective comparison of on-chain timestamps.

---

## Why 7 Days

7 days is the trade-off between two considerations:

**Too short → false positive**. The keeper may halt briefly for legitimate reasons: VPS maintenance, transient Cardano mainnet congestion, brief unavailability of Blockfrost / Ogmios, operator on short leave. If dead-man-switch were 1-3 days, these scenarios would be misjudged as "keeper is dead," triggering early-withdraw-fee waiver and giving depositors a misleading signal.

**Too long → insufficient depositor protection**. If dead-man-switch were 30-60 days, depositors would have to wait 1-2 months after an actual keeper runaway to exit without fee. For emergency scenarios (e.g., Liqwid sudden trouble), the window is too long.

7 days lets "reasonable short-term halts" not trigger fallback while letting "genuine keeper failure" enter fallback mode quickly. It also aligns with whitepaper §2.6's Compound schedule — the 1,200+ TVL tier does productive Compound every Saturday, so "last productive Compound > 7 days ago" essentially equals "keeper missed something it should've done."

The 7-day value is deliberately non-adjustable. It's a compile-time constant inside `vault_user.ak` / `vault_keeper_hot.ak`: `keeper_inactivity_window_ms = 7 × 24 × 60 × 60 × 1000`. Governance cannot adjust this value within V1 — changing it requires redeploying the entire V1 (compile-time anchor, see [Security Series Article 4](../security/04-phantom-vault-and-compile-time-anchor.md)).

---

## The Key: `last_compound_time` vs `last_realloc_time`

V1's datum has two time fields with distinct responsibilities:

- **`last_compound_time`**: updated only by "actual yield > 0" productive Compound.
- **`last_realloc_time`**: updated by zero-yield Compound (heartbeat) and by any allocation update (RebalanceBuffer / UpdateStrategy / reconciliation).

**The 7-day dead-man-switch reads only `last_compound_time`**. This design is crucial:

- Zero-yield heartbeat's purpose is to keep off-chain indexer liveness signals fresh, **not to reset the 7-day fallback window**.
- Heartbeat only updates `last_realloc_time`, not affecting `last_compound_time`.
- Under Reference Implementation Mode (Economics Series Part 3), the keeper deliberately runs only heartbeat without Compound — this legitimate operating mode doesn't falsely trigger the 7-day gate (because Compound truly runs once enough yield accrues).

In other words, the dead-man-switch depends entirely on **actual yield activity**, not the keeper's "I'm still alive" ping.

This separation also blocks one detour: "keeper deliberately sends only heartbeats to delay dead-man-switch" — that adversarial scenario **doesn't exist**. Heartbeat doesn't update `last_compound_time`, so the keeper, even if it floods heartbeats, cannot delay the 7-day fallback trigger.

---

## Why Forged Validity Ranges Don't Fool It

The dead-man-switch's judgment logic:

```aiken
fn keeper_is_inactive(datum: VaultDatum, tx: Transaction) -> Bool {
  datum.last_compound_time + 7_days_ms <= tx.validity_range.upper
}
```

This looks like it has a hole: `tx.validity_range.upper` is set by the TX submitter. If the submitter claims `validity_range.upper = now + 100 years`, `keeper_is_inactive` is always true, dead-man-switch always triggers — the keeper is forever "inactive."

V1 plugs this detour. **Every redeemer that writes to a time field enforces `validity_range.upper - validity_range.lower <= 1 hour`**. This width cap lives in helpers used by `vault_user.ak` and `vault_keeper_hot.ak`:

```aiken
fn validate_validity_range_width(tx: Transaction) {
  let lower = tx.validity_range.lower.bound
  let upper = tx.validity_range.upper.bound
  expect upper - lower <= 1 * 60 * 60 * 1000  // 1 hour
}
```

Effects:

- A TX claiming `upper = now + 10y` is rejected at the ledger (width exceeds 1 hour).
- A TX claiming `upper - lower = 1 hour` passes the width check, but `upper` can only be `lower + 1 hour` — cannot be `lower + 100 years`.
- The Cardano ledger also constrains `validity_range.lower` (must be ≤ current slot), so `upper ≤ now + 1 hour`.

Sum total: **keeper-inactivity judgment depends on the actual ledger time, not the TX submitter's claim**. An attacker cannot bypass dead-man-switch by claiming "it's currently year 2030."

---

## Impact on Emergency-Withdraw Self-Service Path

V1 ships an `emergency-withdraw` CLI and frontend tool from day one, letting depositors locally construct TXs. This path requires no operator cooperation — it directly spends the vault UTXO, burns vUSDCx, and recovers USDCx at the current share price.

Under normal operation, emergency-withdraw still incurs early_withdraw_fee (0.1%). Why is there a fee? Because depositors using emergency-withdraw are "skipping the normal keeper processing"; this fee compensates remaining depositors who absorb the potential impact of "non-keeper-optimized swap paths."

After 7-day dead-man-switch triggers, this fee auto-waives to 0. Reasons:

- With keeper halted there's no "normal path"; emergency-withdraw becomes the "only available path."
- Charging fee in this scenario doesn't make sense — they're not choosing to skip the keeper, the keeper is gone.

This 0% fee takes effect automatically at the contract layer; no governance action required, no operator consent required. Depositors simply use the emergency-withdraw tool, paying the minimum TX fee (about 1.5-2 ADA) for exit.

---

## Relationship to Three-Layer Governance Safety

The dead-man-switch and [Security Series Article 1](../security/01-three-layer-governance-safety.md)'s three-layer governance safety are complementary:

| Mechanism | Trigger | Main effect |
|-----------|---------|-------------|
| **7-day dead-man-switch** | `last_compound_time + 7d` | Direct Withdraw 0% fee + governance fallback + emergency-withdraw economically reasonable |
| **Three-layer governance safety Layer 1** (freeze-only) | Governance intervention | Freeze new vault Deploys |
| **Three-layer governance safety Layer 2** (swap-out under freeze) | Governance freeze + keeper online | Swap non-deposit tokens back to USDCx |
| **Three-layer governance safety Layer 3** (CommunitySunset) | `max(last_compound_time, last_realloc_time) + 90d` | Any vUSDCx holder triggers full permissionless recovery |

The 7-day dead-man-switch and Layer 3's 90-day sunset don't conflict — they handle different scenarios:

- The 7-day fallback assumes "keeper failed but governance can still m-of-n sign" — governance intervenes via the fallback path to Recall funds.
- The 90-day sunset assumes "keeper + governance simultaneously failed" — any vUSDCx holder can act as recovery proxy.

Depositor exit paths therefore have layered structure:

```
[Day 1-7] Keeper failed but < 7 days
  → Direct Withdraw still works (with early_withdraw_fee if in min_hold window)
  → Queue Withdraw still fine (but keeper offline may delay)
  → emergency-withdraw available (with fee)

[Day 7+] Keeper failed ≥ 7 days
  → Direct Withdraw 0% fee
  → Governance m-of-n fallback opens (if governance still operating)
  → emergency-withdraw 0% fee

[Day 90+] Keeper + governance simultaneously failed
  → Any vUSDCx holder triggers CommunitySunset
  → Full permissionless recovery path
```

Each layer adds an exit option that "doesn't depend on the previous layer." Even if all operators simultaneously fail for 90 days, depositors can still recover USDCx.

---

## Why This Mechanism Beats Multi-Operator Redundancy Design

Traditional DeFi's response to "keeper SPOF" is multi-operator — e.g., 3 keeper instances run by different operators backing each other up.

Problems with this approach:

**(a) Multiple keepers sharing keeper key**. If three keepers use the same private key, any one stolen means all stolen. If they use different private keys with the contract accepting any signature — the attacker only needs to compromise any one keeper.

**(b) Operator collusion risk**. If multiple operators have economic ties (e.g., same company, same team), multi-operator equates to fake multi-operator.

**(c) Increases contract complexity**. The validator must verify scenarios for multiple keeper signatures, expanding audit surface.

V1's posture: **single keeper + dead-man-switch fallback**. Its advantages:

- **Smaller contract surface**. Keeper authentication logic is simple (single PKH or PKH switchable via `keeper_stake_script`).
- **Depositor protection doesn't depend on multi-operator assumptions**. Even if a single keeper truly fails, dead-man-switch auto-triggers; no need to trust other operators to act in proxy.
- **Multi-operator can be opted into later**. `keeper_stake_script` supports the `PermissionlessWithBond` mode (whitepaper §7.2); at TVL $5-10M, governance can switch to open registration. Dead-man-switch coexists with PermissionlessWithBond — the latter raises keeper online probability, the former remains as the ultimate backstop.

This trade-off reflects V1's overall posture: **first make sure the "worst case" has a structural resolution, then optimize for "the worst case rarely happens."** Dead-man-switch is the concrete embodiment of "worst case has a resolution."

---

## Next Article

Part 3 handles the most common practical issue depositors encounter: **how to take USDCx back from the vault**. V1 provides three withdraw paths — Direct / Queue / Emergency. Their trade-offs, which path to pick in which scenario, costs and timing differences — the next article covers.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/HY5sy8cz8s).*
