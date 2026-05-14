# Why OptiVaults V1 Has 17 Validators: Four Orthogonal Cuts

*OptiVaults V1 Contract Architecture Series — Part 3 of 4*

---

[Part 2](./02-withdraw-zero-forwarding-pattern.md) introduced the Withdraw-Zero Forwarding Pattern: moving vault business logic out of spending validators and into multiple staking validators. What it didn't answer is *how many* validators V1 splits into and along which lines. That's the question this part answers.

OptiVaults V1 splits vault logic into **17 logic validators + 4 NFT mint policies + 1 DEX adapter = 22 compiled artefacts**. That's a relatively aggressive split for a Cardano vault — many existing designs ship with 5–8 validators. So why so many for V1?

**Because the split follows four orthogonal cuts**, each driven by a specific design constraint. This part explains them one by one.

---

## Cut 1: Authorization Boundary

Different redeemers require different authorization principals. Putting them in a single validator means "in order to validate a deposit, the validator has to load keeper-auth logic into memory in the spending path too."

Along the authorization boundary, V1 splits into:

| Validator | Authorization model | Redeemers |
|---|---|---|
| `vault_user` | Permissionless (any CIP-30 wallet) | Deposit / Withdraw / CommunitySunset |
| `vault_keeper_hot` | Keeper authorization (via `keeper_stake_script` zero-withdraw) | Compound / RebalanceBuffer |
| `vault_batcher` | Keeper authorization | BatchProcess |
| `vault_swap_ada` | Keeper authorization | SwapAda (separated for the reason in Cut 3) |
| `vault_gov_policy` | Governance multisig (via spending MultisigGov UTXO) | UpdateStrategy / UpdateFee / UpdateFeeSplit / UpdateSlippagePolicy |
| `vault_gov_emergency` | Governance multisig | EmergencyWithdraw |
| `vault_admin_deploy` | Governance multisig | AdminDeployNonDeposit |

Keeping `vault_user` purely permissionless is a critical property: deposit and withdraw — the two highest-frequency user operations — don't pay ref-script fee for keeper-auth or governance-multisig logic. BatchProcess is also user-facing, but it requires keeper authorization (the keeper batches several queued orders into the vault), so it's split into `vault_batcher`. That lets `vault_user` shed its keeper-auth compile-time parameter entirely and crystallize as a "permissionless three-redeemer" structure.

---

## Cut 2: Governance Response Latency

Governance actions vary widely in timelock — from emergency's 0 days to UpdateFeeSplit's 21 days. Splitting them apart isolates logic with different response cadences:

| Validator | Timelock | Redeemer |
|---|---|---|
| `vault_gov_emergency` | **0 days** | EmergencyWithdraw (emergency vault freeze) |
| `vault_gov_policy` UpdateSlippagePolicy | 48 hours | Slippage policy |
| `vault_gov_policy` UpdateStrategy | 7 days | Strategy allocation |
| `vault_gov_policy` UpdateFee | 14 days | Performance fee rate |
| `vault_gov_policy` UpdateFeeSplit | **21 days** (longest) | Three-way fee split |
| `vault_admin_deploy` | 7d keeper-inactive + 21d registry-stable | Non-deposit token recovery |

**Why isolate EmergencyWithdraw?** Because it's the special path with 0-day timelock — every other governance action waits out a timelock; only this one can take effect immediately (used to freeze the vault under attack). Keeping that fast-response path in its own validator means **future SwapAdapter additions or other governance logic won't expand the emergency path's attack surface** — `vault_gov_emergency` is permanently "the smallest set of logic that can act in zero time."

UpdateFeeSplit's 21-day timelock (the longest of all V1 governance actions) also has a concrete rationale: this is the action where governance adjusts its own compensation (governance signers themselves may receive a share). Maximum timelock here gives depositors the longest possible observation window to exit before changes take effect.

---

## Cut 3: Bytecode Cost Center

Some redeemers carry expensive helpers. Splitting them out keeps the rest of the system from paying for what it doesn't use:

**`vault_swap_ada` separated from `vault_keeper_hot`**: the SwapAda redeemer reads a dual-feed oracle (Charli3 + Orcfax median aggregation, with cross-feed disagreement / staleness / min_feeds checks) plus a 6-tuple registry read. That bytecode is roughly 4–5 KB and **is only used by SwapAda**.

If it stayed with Compound / RebalanceBuffer, every Compound execution would have to load those 4–5 KB. After the split, `vault_keeper_hot` shrinks to ~10.5 KB and `vault_swap_ada` is its own 12.2 KB; Compound TXs no longer touch SwapAda logic at all.

**`vault_admin_deploy` separated from `vault_gov_emergency`**: AdminDeployNonDeposit covers SwapAdapter dispatch + destination-whitelist checks + 6-tuple registry read — the heaviest of the governance paths. Splitting it out reduces `vault_gov_emergency` to ~12.6 KB and keeps EmergencyWithdraw inside a tight validator.

**`vault_batcher` separated from `vault_user`**: BatchProcess has four independent fold loops (validating per-order owner / sums / vUSDCx non-leakage / payout uniqueness) plus an anti-leak invariant — bytecode totals 11.5 KB. Splitting it out frees `vault_user` from its keeper-auth compile-time parameter; deposit and withdraw no longer carry keeper-authorization logic.

---

## Cut 4: Pure Size Limit

The last cut is the least elegant — "doesn't fit."

After V1 introduced oracle / asset_oracles / Minswap V2 SwapAdapter dispatch, the original `vault_protocol` (covering DeployToProtocol + Recall + MergeUtxo) ballooned to 16.5 KB — **116 bytes over the 16 KB ceiling**.

Those features couldn't be cut, so a split was forced. Cut along the natural DeployToProtocol / Recall boundary:

- **`vault_protocol`**: DeployToProtocol (via SwapAdapter dispatch into Minswap V2). 13.1 KB / ~3.3 KB headroom.
- **`vault_recall`**: RecallFromProtocol, MergeUtxo. 13.3 KB / ~3.0 KB headroom.

Combined size is 26.4 KB versus 16.5 KB pre-split — a 10 KB increase, mostly from helpers that get duplicated on both sides (`get_continuing_datum`, `read_registry_datum`, etc.). But every TX uses only one side, so per-TX ref-script fee doesn't worsen.

---

## The Final Shape: 17 Logic Validators

The combined result of all four cuts:

| Validator | Role | Size |
|---|---|---|
| `vault_proxy` | Withdraw-Zero router | ~4.9 KB |
| `vault_user` | Deposit / Withdraw / CommunitySunset | ~12.5 KB |
| `vault_keeper_hot` | Compound / RebalanceBuffer | ~10.5 KB |
| `vault_batcher` | BatchProcess | 11.5 KB |
| `vault_swap_ada` | SwapAda (dual-feed oracle) | 12.2 KB |
| `vault_protocol` | DeployToProtocol (SwapAdapter dispatch) | 13.1 KB |
| `vault_recall` | RecallFromProtocol / MergeUtxo | 13.3 KB |
| `vault_liqwid` | SupplyToLiqwid / RecallFromLiqwid | 13.4 KB (tightest) |
| `vault_gov_policy` | UpdateStrategy / Fee / FeeSplit / Slippage | 12.6 KB |
| `vault_gov_emergency` | EmergencyWithdraw | ~12.6 KB |
| `vault_admin_deploy` | AdminDeployNonDeposit | 13.2 KB |
| `keeper_stake_script` | Keeper authorization rules | 8.8 KB |
| `treasury` | Treasury fee buckets and outflow gating | 9.9 KB |
| `multisig_gov` | m-of-n governance state machine | 8.3 KB |
| `registry` | Protocol whitelist + asset_oracles + swap_adapter_hashes | 8.5 KB |
| `order` | Order Process / Cancel / Expire | 3.8 KB |
| `vusdcx` | Share token minting policy | 1.3 KB |

Plus 4 NFT mint policies (`vault_nft` / `governance_nft` / `registry_auth_nft` / `gov_signer_nft`) + 1 DEX adapter (`minswap_v2_adapter`) = 22 compiled artefacts.

The tightest is `vault_liqwid` with ~3 KB of headroom. All 22 artefacts comfortably fit under the 16 KB ceiling.

---

## The Cost of Splitting

To be complete, here's the cost side of the trade:

**(a) More ceremony deployment TXs**: V1's ceremony requires 38 TXs (3 NFT mints + 18 ref script deployments + 12 stake credential registrations + 5 state UTXO inits), with about 944 ADA committed to ref-script lockup and registration deposits (ref scripts are reclaimable at sunset via `reclaim-refs.ts`). A single-validator vault would need only 5–10 ceremony TXs.

**(b) Larger audit surface**: each staking validator is its own audit target. Internal review accumulated multiple rounds with findings addressed; some of those findings (for example, `vault_keeper_hot`'s Compound path didn't originally verify that the gov input's spending redeemer was `ReceiveCompoundShare`, which could have let `gov_share` be miscredited under a different governance action) were missed precisely because validators are split apart and cross-validator binding becomes less visible.

**(c) Deployment ordering is more fragile**: with 18 ref scripts and a dependency chain (vault_proxy's compile-time parameters require all 10 stake hashes to be decided first), the ceremony is sensitive to TX ordering and wallet UTXO contention. V1's `deploy.ts` includes a checkpoint mechanism with auto-resume — essentially mandatory at this split scale.

But the upside of splitting — breaking past 16 KB, paying ref-script fee only for what each TX actually uses, and natural authorization isolation — outweighs these costs significantly for user experience and security model. So V1 chose this direction.

---

## Summary

V1's 17 logic validators aren't carved arbitrarily. Along **authorization boundary**, **governance response latency**, **bytecode cost center**, and **pure size limit** — four orthogonal cuts — every split corresponds to a concrete design constraint.

The cost is more ceremony complexity, larger audit surface, and more fragile deployment ordering; the upside is breaking past 16 KB, ref-script fee proportional to actual usage, and authorization separation that falls out for free.

The final part covers the last piece: **how vault state is stored, how the 29-field VaultDatum splits into mutable vs immutable, and how the compile-time Vault NFT anchor blocks phantom-vault attacks** — V1's response to [Part 1](./01-eutxo-vault-design-constraints.md)'s Constraint 4 ("UTXOs have no native identity").

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app). Community on [Discord](https://discord.gg/HY5sy8cz8s).*
