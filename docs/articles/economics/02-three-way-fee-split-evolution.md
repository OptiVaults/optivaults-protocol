# 3-Way Fee Split: keeper / gov pool / treasury Evolution

*OptiVaults V1 Economic Model Series — Part 2 of 4*

---

[Part 1](./01-performance-fee-precise-semantics.md) covered how the 4.5% performance fee is computed and how the validator locks the 4.5% cap structurally. This article handles the next-layer question: **once the 4.5% is collected, how is it distributed?**

V1 splits the performance fee into three streams: **keeper (the operator running the keeper bot) / gov pool (compensation pool for governance signers) / treasury (the protocol's own treasury)**. At launch, the split is 40 / 0 / 60. In future phases, depending on TVL and signer composition, it evolves to 40 / 5 / 55 → 40 / 10 / 50.

Each ratio isn't arbitrary — it corresponds to V1's specific trade-off between "protocol self-sufficiency" and "economic viability for operators." This article unpacks those trade-offs and explains why some caps are governance-adjustable while others are validator-coded.

The whole protocol is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol).

---

## Three Streams, Three Independent Spend Paths

First, the on-chain mechanism. Each Compound triggering fee computation forces the validator to split the fee into three outputs based on `keeper_fee_bps` and `gov_fee_bps`:

```
Compound TX outputs:
  ├─ Keeper share   = fee_amount × keeper_fee_bps / 10000
  │                   → sent directly to signing keeper's address (USDCx)
  ├─ Gov pool share = fee_amount × gov_fee_bps / 10000
  │                   → accrued in MultisigGov UTXO's
  │                     signer_compensation_pool field (USDCx)
  └─ Treasury share = fee_amount × (10000 − keeper_fee_bps − gov_fee_bps) / 10000
                      → flows to treasury contract address (USDCx)
```

Each destination has independent:

- **On-chain address** — keeper's personal address, MultisigGov UTXO, treasury contract address.
- **Redeemer authorization path** — keeper's share lands directly in their wallet; gov pool is distributed via `DistributeSignerCompensation` (quarterly settlement); treasury is spent via `TreasurySpend` (governance 7-day timelock).
- **Timelock settings** — `keeper_fee_bps` / `gov_fee_bps` adjustments go through `UpdateFeeSplit`, with timelock **21 days** (the longest of all V1 governance actions — reason discussed below).

This three-stream structure is V1's on-chain separation-of-powers in concrete form — three pockets, three sets of rules, three layers of timelock.

---

## Launch Allocation: 40 / 0 / 60

V1's launch allocation:

| Recipient | Ratio | Meaning |
|-----------|-------|---------|
| Keeper | 40% | Collected by the founder-operated keeper instance |
| Gov pool | 0% (disabled) | Off during Phase 1 launch |
| Treasury | 60% | Flows to 4-category budget (audit reserve / ops / R&D / buffer) |

Key points:

**The keeper's 40% looks high, but it is actually a net cost centre.** At 100K TVL, 6% gross yield × 4.5% × 40% ≈ $108/yr — under the Phase 1 baseline configuration, far short of covering an independent operator's infrastructure and monitoring costs (typically $400–$1,000/yr). The 40% keeper cap is deliberately set high so that future open keeper registration (whitepaper §7.2 PermissionlessWithBond) can bring a non-founder keeper's breakeven TVL down to roughly $1M — a 25% cap would put it near $1.5M; 40% drops it to about $1M. This is V1's structural runway for actually opening up keeper registration in Phase 3+.

**The gov pool starts at 0%.** In Phase 1, governance is a 3-of-3 multisig (or falls back to a single signer when SPO recruitment is delayed); governance activity is sparse, so the gov pool has no economic necessity at this stage. Setting `gov_fee_bps = 0` effectively disables the gov pool — no USDCx accrues in the MultisigGov UTXO — while the governance timelock and cancel mechanisms keep operating normally.

**The treasury's 60% belongs to the protocol itself.** This 60% goes to the treasury contract address and is spent via the `TreasurySpend` governance action. The treasury then distributes accrued funds across four categories (audit reserve 40% / ops 25% / R&D 25% / buffer 10%), and every payout goes through a 7-day timelock. The treasury is nobody's pocket — it is a contract-controlled fund pool, and every expenditure is observable on cardanoscan.

---

## Evolution: Phase 2 Becomes 40 / 5 / 55

When TVL crosses $500K and Phase 2 (whitepaper §6.1's defined phase) begins, the allocation evolves to:

| Recipient | Ratio | Change |
|-----------|-------|--------|
| Keeper | 40% | unchanged |
| Gov pool | 5% | **enabled** (from 0 to 5%) |
| Treasury | 55% | from 60% to 55% (yielding 5% to gov pool) |

Phase 2 enables the gov pool once TVL crosses $500K and external (community-selected) signers are added. `UpdateFeeSplit` is a governance action with a 21-day timelock; enabling the gov pool requires unanimous signer consent to change `gov_fee_bps` from 0 to 500.

Why is gov pool only enabled in Phase 2? Because in Phase 1:

- Governance activity is sparse (occasional `UpdateStrategy`, possibly emergency responses), insufficient to justify routine compensation.
- Under the founder-only-signer fallback scenario, gov pool is equivalent to "founder paying founder" — meaningless.

After Phase 2, the signer set expands to five (including at least one community-selected signer); governance workload rises with TVL, and the structural dissent-veto mechanism starts to see real use. Enabling a 5% gov pool at that point gives non-founder signers small but non-zero compensation, which keeps the "Cardano community service" role sustainable.

The quarterly distribution mechanism (`DistributeSignerCompensation`) has an important "forfeit clause": if a signer fails to maintain liveness via `Heartbeat` during a given quarter, their share of that period's pool is forfeit — other qualified signers split it proportionally. This rule is enforced at the validator level in `multisig_gov.ak`, requiring no offline judgment of who's qualified.

---

## End-State: Phase 3 Becomes 40 / 10 / 50

When TVL crosses $2M and Phase 3 begins:

| Recipient | Ratio | Change |
|-----------|-------|--------|
| Keeper | 40% | unchanged |
| Gov pool | 10% | from 5% to 10% |
| Treasury | 50% | from 55% to 50% — **hits validator hard floor** |

Phase 3's key property is **treasury hitting its 50% hard floor**. V1's `validate_update_fee_split` enforces:

```
expect keeper_fee_bps <= 4000          // 40% cap
expect gov_fee_bps <= 1000              // 10% cap
expect keeper_fee_bps + gov_fee_bps <= 5000  // treasury floor 50%
```

That is, **treasury's 50% is validator-locked; governance, no matter how it adjusts keeper / gov pool ratios, cannot drop treasury below 50%**. Reasons for this floor:

- **Audit-reserve accrual rate not diluted by governance**. Within treasury's internal allocation, audit reserve takes 40%, so "total fee into audit reserve" = 50% × 40% = 20%. This intake ratio is enforced by `treasury.ak` at `UpdateParams` time as ≥ 20% (whitepaper §4.2 audit reserve floor). Treasury 50% × audit-bucket 40% double-floor protection ensures future V1.x / V2 audit commission funding cannot be sabotaged by short-term governance decisions.
- **Protocol's own R&D / ops budget structurally preserved**. Treasury 25% R&D + 25% ops + 10% buffer = 50%; the triggered floor ensures protocol has non-zero self-operational capacity under any fee-split configuration.

---

## Cap Structure: 4 Hard Limits

Putting all validator-enforced fee-split constraints in one table:

| Condition | Value | Guarded by | Meaning |
|-----------|-------|-----------|---------|
| `keeper_fee_bps` | ≤ 4000 (40%) | `vault_gov_policy.UpdateFeeSplit` | Keeper at most 40% |
| `gov_fee_bps` | ≤ 1000 (10%) | `vault_gov_policy.UpdateFeeSplit` | Gov pool at most 10% |
| `keeper_fee_bps + gov_fee_bps` | ≤ 5000 (50%) | `vault_gov_policy.UpdateFeeSplit` | Treasury at least 50% |
| Audit-bucket internal intake | ≥ 2000 (20%) | `treasury.UpdateParams` | Audit-reserve accrual rate ≥ 20% |

The fourth condition "audit-bucket intake ≥ 20%" is treasury's internal allocation floor, on a different layer from fee split:

- Fee split guards "how much of total fee treasury receives."
- Treasury params guard "of treasury's total intake, how much enters audit reserve."

Multiplying the two: `50% × 20% = 10%` is the structural floor "at least 10% of total fee accrues to audit reserve." Whatever governance does on fee split or treasury params, future audit commission accrual rate cannot drop below this line.

---

## Why `UpdateFeeSplit` Timelock Is 21 Days (Longest of All V1 Actions)

V1 governance actions sorted by timelock:

| Action | Timelock |
|--------|----------|
| `EmergencyWithdraw` | 0 days (freeze-only, still requires 3-of-3 signature) |
| `FastUpdateMarkets` | 1 hour |
| `UpdateSlippagePolicy` | 48 hours |
| `UpdateStrategy` / `TreasurySpend` / `AdminDeployNonDeposit` | 7 days |
| `UpdateFee` / `UpdateRegistry` / `UpdateKeeperAuth` / `RotateSigners` / others | 14 days |
| **`UpdateFeeSplit`** | **21 days** |

`UpdateFeeSplit` has the longest timelock of all V1 actions — longer than fee changes, registry adjustments, signer rotation. The reason:

**Governance is adjusting its own compensation here**. When a governance action directly impacts signer personal income (gov pool) or keeper income (keeper share), depositors most need time to observe and exit. The 21-day window lets any depositor:

- Observe the specific payload of the queued action (new ratios, signer reasoning).
- Evaluate the long-term implications for their position.
- If they decide to exit, comfortably take Direct Withdraw or Queue Withdraw.

21 days is on the longer side, but in the specific scenario of "governance adjusting its own compensation," prioritizing depositor protection is reasonable. Other actions (e.g., `UpdateStrategy` adjusting allocation) have gradual impact; 7 days is sufficient response time. Fee split's impact is direct cash flow; the 21-day window is more appropriate.

`UpdateFeeSplit` shares the 1-of-n cancel of other governance actions — any signer can veto within the 21 days. Multiple protections make it hard for depositors to suffer real damage from "governance quietly changing the split."

---

## On-Chain Independence vs Launch-Time Human-Controller Overlap

V1 designs fee split as three on-chain-independent destinations — that's structural preparation; but at launch, **human controllers overlap significantly**, requiring honest disclosure:

- **Keeper** is operated by the founder → founder.
- **Gov pool** is 0% in Phase 1; if enabled, 3-of-3 governance (including founder's signature) → includes founder.
- **Treasury** payouts require 3-of-3 governance agreement → includes founder.

The three streams' on-chain independence is real — three addresses, three redeemers, three timelock sets. But the signer set overlaps in Phase 1, so **the structure is in place while decentralization is not yet complete**.

This is precisely why V1 places "Six-identity separation" (whitepaper §6.1) on the roadmap. Phase 2 introduces community-selected signers; Phase 3 adds more independent signers; the human-controller overlap gradually decreases — the goal in Phase 4 is to evaluate DAO migration.

V1's launch posture is "on the way to decentralization, structure in place, honest about current state," not "we're decentralized now." This distinction matters to depositors.

---

## Contrast: How Traditional DeFi Vaults Handle Fee Split

Many DeFi vaults have fees collected directly by a multisig, with allocation rules described in a readme or blog, not in the contract. That means:

- Fees enter a single wallet; subsequent allocation depends on multisig offline coordination.
- No audit reserve hard floor, no treasury minimum, no keeper / governance split.
- Depositors must trust "multisig will allocate per readme" — a social commitment, not ledger-verifiable.

V1's difference is putting allocation rules into the validator: each Compound TX automatically splits three streams, each stream has an independent address, each cap is validator-enforced. Anyone can observe any Compound TX on cardanoscan:

```
Inputs:
  └─ Vault UTXO (containing fee-corresponding USDCx)
Outputs:
  ├─ Keeper address: <USDCx amount A>
  ├─ MultisigGov UTXO: <USDCx amount B in signer_compensation_pool>
  └─ Treasury address: <USDCx amount C>

Verify:
  A / (A+B+C) == keeper_fee_bps / 10000
  B / (A+B+C) == gov_fee_bps / 10000
  C / (A+B+C) == (10000 - keeper_fee_bps - gov_fee_bps) / 10000
```

If the keeper-constructed TX doesn't satisfy this ratio, the validator rejects; the ledger doesn't accept it. This verification can be redone by anyone — no trust in founder or multisig needed.

---

## Next Article

Part 3 handles a structural challenge in V1's economic model: **under the 100K TVL cap, ~$270/yr in protocol income is insufficient to cover operational costs**. Traditional DeFi responds by "growing rapidly to self-sustaining scale" — but V1's posture is "sustainable operation at low TVL." Part 3 covers Reference Implementation Mode: low-TVL public-goods operation mode, scaling operational cadence down to match real revenue base, so V1 doesn't need growth pressure to survive at $500-$25K TVL.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/HY5sy8cz8s).*
