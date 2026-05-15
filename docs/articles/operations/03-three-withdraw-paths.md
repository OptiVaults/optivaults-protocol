# Three Withdraw Paths: Choosing Among Direct / Queue / Emergency

*OptiVaults V1 Operational Mechanics Series — Part 3 of 3*

---

V1 offers three paths for getting USDCx back: **Direct Withdraw**, **Queue Withdraw**, and **Emergency Withdraw**. All three eventually let depositors receive USDCx, but their contract paths, timing, cost, and dependencies differ.

Many vaults offer just one path — typically "batch processing by operator." V1's three paths exist simultaneously for a reason: they correspond to **different "operator availability assumptions,"** letting depositors pick the most appropriate path for the current situation.

This article unpacks the three paths' contract mechanisms, applicable scenarios, and trade-offs.

The whole protocol is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol).

---

## Three Paths Compared

| Property | Direct | Queue | Emergency |
|----------|--------|-------|-----------|
| Corresponding contract | `vault_user.Withdraw` | `order.SubmitWithdraw` + `vault_batcher.BatchProcess` | `emergency-withdraw` CLI |
| Operator dependency | Needs vault state with sufficient buffer | Needs keeper online to run BatchProcess | None |
| Completion time | Immediate (one TX) | Usually < 1 hour (per keeper batch cadence) | Immediate |
| User-paid ADA | About 1-1.5 ADA | About 1 ADA + `max_batcher_tip` | About 1.5-2 ADA |
| Early-withdraw fee | 0.1% (within min_hold window if keeper online) | 0% (queue path not subject to min_hold gate) | 0.1% (if keeper online) / 0% (if keeper inactive ≥ 7d) |
| Applicable scenarios | Small-to-medium amounts, vault has buffer liquidity | Large amounts, vault busy, no rush | Keeper failed or self-exit |

---

## Direct Withdraw — Complete in One TX

The simplest path. Flow:

```
[1] User enters vUSDCx amount on frontend
[2] Frontend constructs TX:
    ├─ Input:  vault UTXO + user's vUSDCx token UTXO
    ├─ Burn:   vusdcx policy burns vUSDCx amount
    └─ Output: vault UTXO (USDCx deducted + idle_buffer updated)
               + user's address (receives USDCx)
[3] Wallet signs → submit → wait for ledger confirm
```

Contract path: `vault_proxy.Spend → vault_user.Withdraw` (via Withdraw-Zero forwarding, [Architecture Series Article 2](../architecture/02-withdraw-zero-forwarding-pattern.md)).

Key constraints:

- **The vault must have sufficient idle_buffer USDCx** for direct settlement. When buffer is insufficient, Direct Withdraw fails (the validator implicitly enforces this between `verify_shares_burned` and `verify_receiver_output`).
- **`min_hold_seconds` cooldown only gates Direct Withdraw**, not Queue Withdraw. If you want to Direct Withdraw within the `min_hold_seconds` window after the latest Compound (launch value 60 seconds, validator hard cap 6 hours), it's blocked; wait out the cooldown, or switch to Queue.

Cost:

- **Network fee**: about 1-1.5 ADA (including Withdraw-Zero forwarding's two validator invocations' ref-script fees).
- **Early-withdraw fee**: when the keeper is online, if still past `min_hold_seconds` but the 7-day inactivity hasn't fired, 0.1% USDCx stays in the vault (pushing other shares' price up).

When to use:

- Position < $500 or within ~5% of current vault TVL.
- Vault holds a 30% idle_buffer as normal state (whitepaper §2.3); most scenarios buffer is sufficient.
- No rush to wait for batcher cadence, want USDCx visible immediately after TX confirms.

---

## Queue Withdraw — Wait for Keeper Batch Settlement

When the vault is busy, your position is large, or you want to avoid vault-state UTXO contention, take Queue Withdraw. Flow:

```
[1] User enters vUSDCx amount on frontend + max_batcher_tip
[2] Frontend constructs TX:
    ├─ Input:  user's vUSDCx token UTXO
    └─ Output: order proxy UTXO (datum records user_addr,
               vusdcx_amount, max_batcher_tip, max_shares_burn)
[3] Wallet signs → submit → vUSDCx now in order proxy
[4] Keeper detects new order UTXO, accumulates to next batch cycle
[5] Keeper constructs BatchProcess TX:
    ├─ Inputs:  vault UTXO + N order UTXOs
    ├─ Burn:    sum of vUSDCx across all orders
    └─ Outputs: vault UTXO + N user addresses (each receiving USDCx)
[6] BatchProcess TX confirms → all orders settled at once
```

Contract path: `order.SubmitWithdraw` (on submission) → `vault_proxy.Spend → vault_batcher.BatchProcess` (on batch settlement).

Key constraints:

- **`max_shares_burn` is a user-set tolerance**. If, at BatchProcess time, share price is lower than expected (vault accrued loss during the period), causing the burn to exceed `max_shares_burn`, the validator rejects that order — it stays in the order proxy, retrievable by user `Cancel` or auto `Expire` to recover vUSDCx.
- **`max_batcher_tip` is user-set**. The keeper, when processing the order, takes at most this tip as batch-processing compensation. Recommend 0.1-0.5 ADA.

Several important properties:

**Queue Withdraw is not subject to `min_hold_seconds` gate**. `min_hold_seconds` only blocks the Direct Withdraw path — meaning depositors can **always** recover funds via the Queue path, even when governance pushes `min_hold_seconds` to the 6-hour cap. This is the concrete guarantee whitepaper §2.4 highlights: "user funds are never locked."

**Order UTXO can be cancelled any time**. Before the keeper performs BatchProcess, the user can take `order.CancelAction` to recover the original vUSDCx. This redeemer is strictly gated by `signed_by_owner` — only the original owner can cancel.

**Auto-Expire after 24 hours**. The order UTXO's datum records `expires_at = submission_time + 24h`. Past expiry, anyone can trigger `order.ExpireOrder`, returning vUSDCx to the original owner (with `valid_refund` enforcing recipient = `ord.owner`). This fail-safe ensures orders don't stick in the proxy when the keeper fully fails.

Cost:

- **Network fee**: about 1 ADA (order submission) + batch processing's amortized fee (about 0.1 ADA per order).
- **`max_batcher_tip`**: user-paid priority-processing tip to the keeper.
- **Early-withdraw fee**: **0% (not charged)** — this is Queue's advantage over Direct.

Timing:

- BatchProcess cadence is typically every 5-15 minutes (depending on vault activity).
- Under normal operation, < 1 hour settlement (whitepaper §2.2 describes as "operational target, not a contract-enforced SLA").
- Peak periods may reach a few hours.

When to use:

- Position $500-$2,500 medium — batch-amortizing BatchProcess fee is cheaper than Direct.
- Vault is in busy state (many deposits / withdraws concurrent), Direct may hit UTXO contention retries.
- No rush, can wait < 1 hour for settlement.

---

## Emergency Withdraw — Self-Service Exit Path

V1's self-service fallback for "keeper failed, can't get USDCx" scenarios. Flow:

```
[1] User downloads emergency-withdraw CLI or opens frontend's emergency mode
[2] Tool reads current vault state (from Blockfrost / Ogmios / Kupo)
[3] Tool constructs TX:
    ├─ Input:  vault UTXO + user's vUSDCx UTXO
    ├─ Burn:   vusdcx amount
    └─ Output: vault UTXO + user address (receives USDCx and possibly
               non-deposit tokens)
[4] Wallet signs → submit → ledger confirms
```

Contract path: same as Direct Withdraw (`vault_proxy.Spend → vault_user.Withdraw`), but emergency-withdraw tool self-constructs the TX, **not depending on V1's frontend / API server**.

Key properties:

- **No operator cooperation required**. Emergency-withdraw reads vault state from Blockfrost / Ogmios / Kupo; the user locally constructs the TX, signs locally, submits locally. The entire path is decoupled from V1's frontend or API.
- **May receive mixed assets**. If the vault currently holds DJED / USDM (e.g., just Recalled from Liqwid, not yet swapped), emergency-withdraw sends every proportional token to the user's address — could be pure USDCx, or USDCx + DJED + USDM mixed.
- **Early-withdraw fee auto-adjusts per 7-day dead-man-switch** ([Part 2](./02-seven-day-keeper-inactivity-dead-man-switch.md)):
  - Keeper still online (last_compound_time + 7d not yet reached): pay 0.1% early-withdraw fee.
  - Keeper inactive ≥ 7 days: 0%, emergency-withdraw becomes economically reasonable.

Cost:

- **Network fee**: about 1.5-2 ADA (including Withdraw-Zero forwarding's two validator invocations' ref-script fees).
- **Possible Liqwid Recall limitation**: emergency-withdraw can settle directly from vault buffer but cannot trigger RecallFromLiqwid (that requires keeper or governance fallback signature). If buffer is insufficient and all funds are in Liqwid, emergency-withdraw can only claim the proportional share within buffer; the remainder waits for governance m-of-n via fallback to Recall the Liqwid position.
- **Possible mixed-asset swap friction**: if you receive DJED / USDM, you swap back to USDCx yourself via Minswap V2, paying batcher fee + slippage.

When to use:

- Keeper fully failed ≥ 7 days, 0% fee path becomes attractive.
- V1 frontend / API server unavailable (e.g., DNS issue, Cloudflare outage), but Cardano ledger still operating.
- Want full operator-decoupling — e.g., suspect V1 frontend is phishing-spoofed, construct TX directly from original source via CLI.

---

## Full Exit Decision Tree

Connect the three paths to "practical exit decisions":

```
I want to exit:

├─ Is the vault operating normally? (keeper online + governance online)
│  │
│  ├─ Yes:
│  │  │
│  │  ├─ Position < $500 + not within min_hold window?
│  │  │  → Direct Withdraw ✓
│  │  │
│  │  ├─ Position $500-$2,500 or vault busy?
│  │  │  → Queue Withdraw ✓ (0% fee, settles within 1h)
│  │  │
│  │  └─ Position very large (≥ 5% vault TVL)?
│  │     → Split into multiple Direct + Queue, avoid single-batch
│  │       pricing impact
│  │
│  ├─ Keeper failed, governance still online:
│  │  ├─ Wait 7 days for dead-man-switch to trigger
│  │  ├─ Or Direct/Queue Withdraw immediately (pay 0.1% fee)
│  │  └─ Governance can take m-of-n RecallFromLiqwid fallback to
│  │     move funds back to buffer
│  │
│  └─ Keeper + governance simultaneously failed:
│     ├─ Wait 7 days for dead-man-switch + emergency-withdraw (0% fee)
│     └─ Wait 90 days for CommunitySunset (any vUSDCx holder can
│        trigger permissionless RecallFromLiqwid)
```

Key takeaway: **depositors always have an exit path**. Worst case (keeper + governance simultaneously fail for 90 days), any vUSDCx holder can trigger CommunitySunset and complete self-service recovery. The middle case (keeper failed, governance online) has 7-day dead-man-switch + governance fallback. The normal case has Direct / Queue optimized paths.

---

## Why Queue Withdraw Doesn't Charge Early-Withdraw Fee

A design asymmetry: Direct charges 0.1% early-withdraw fee within the min_hold_seconds window; Queue doesn't.

Reason:

- **Direct is "cutting the line"** — it directly spends the vault state UTXO, immediately consuming that UTXO's per-period throughput capacity.
- **Queue is "waiting in line"** — the user sends vUSDCx to the order proxy, waiting for the keeper to batch-process it with other orders. From the vault state UTXO's perspective, this is a throughput-friendly design.

The early-withdraw fee is designed to "compensate the vault for operational costs borne by remaining depositors." The Queue path, having already amortized cost via batching, doesn't need the early-withdraw fee — it's "cooperative behavior" toward the vault, not "cutting the line."

Practical implication for depositors: **if not in a rush for USDCx, Queue Withdraw is the more economical choice** — 0% fee is cheaper than the Direct path's 0.1% (within the min_hold window). Medium-amount depositors especially should prefer Queue.

---

## Why Emergency-Withdraw Can't Bypass Vault State Validator

A reader might ask: since emergency-withdraw is "self-service exit" and doesn't depend on operators, can it bypass vault state validator and just take money from the vault?

Answer: **No**. Emergency-withdraw still goes through the `vault_proxy.Spend → vault_user.Withdraw` contract path — the user-locally-constructed TX must also pass all validator checks (`verify_shares_burned`, `verify_receiver_output`, `min_hold_seconds` or 7-day inactivity conditions, `liqwid_positions` invariants, etc.).

Emergency-withdraw's "self-service" property is:

- The tool doesn't depend on V1's frontend / API server.
- The tool doesn't require operator signatures (purely depositor unilateral TX).
- The tool supports depositor local operation (offline TX construction, online submission).

But all contract-layer constraints remain applicable — this is its security property, not a limitation. If contract-layer constraints could be bypassed by the "emergency path," the emergency path becomes an attack surface. V1's design treats emergency as "another legitimate spending path" rather than "special exemption"; all validator-enforced conditions apply equally.

---

## Series Wrap-Up

That covers all three articles:

- **[Part 1](./01-swapada-dual-feed-oracle-loop.md)**: SwapAda — dual-feed oracle on-chain ADA replenishment loop
- **[Part 2](./02-seven-day-keeper-inactivity-dead-man-switch.md)**: 7-day keeper-inactivity dead-man-switch
- **Part 3 (this)**: Three Withdraw paths — Direct / Queue / Emergency

V1's overall operational-layer posture: **what should be contract-enforced is contract-enforced, what should be keeper-autonomous is left to the keeper, what should be a depositor choice is clearly separated**. Each path corresponds to a concrete operational assumption — operator available, operator partially failed, operator fully failed — ensuring depositors always have a path at any time.

OptiVaults V1's full source is open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Internal audit rounds have addressed findings; external audit is targeted at Q2-Q3 2027 (when funding stack materializes).

V1 launches on mainnet with a 100,000 USDCx operational cap; when external audit completes, cap unlocks to Stage 2 / Stage 3. The whole project is positioned as a Cardano DeFi public-goods reference implementation — forks, specializations, and commercial use are welcome, and adversarial review via GitHub Issues or [Discord](https://discord.gg/HY5sy8cz8s) is invited.

---

*OptiVaults V1 is a non-custodial multi-stablecoin auto-yield vault on Cardano, open-source under Apache 2.0 at [github.com/OptiVaults/optivaults-protocol](https://github.com/OptiVaults/optivaults-protocol). Web app at [optivaults.app](https://optivaults.app).*
