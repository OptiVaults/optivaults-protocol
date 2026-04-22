# OptiVaults V1 — Order Queue & Batch Processing

**Scope**: the `order` validator, OrderDatum, and BatchProcess redeemer on `vault_batcher` (the standalone keeper-authorized staking validator that owns the 4 fold loops + OrderDatum/OrderRedeemer decode + list.unique + R51/R52 anti-leak invariants) — how deposits and withdrawals are queued and processed in batches.

---

## 1. Why a batch queue exists

Cardano's eUTXO model means the vault UTXO can only be consumed by one transaction per block. If two users try to deposit simultaneously and both directly consume the vault UTXO, one transaction will fail. The batch queue decouples user action (creating an Order UTXO at the `order` script address) from vault state mutation (keeper consumes N orders at once in a single BatchProcess transaction).

Properties the batch queue provides:

- **Concurrency**: arbitrary number of users can submit orders in parallel
- **Fee amortization**: one vault-UTXO-mutation per batch amortizes vault-touching gas across N orders
- **Flash-loan resistance**: the 24h order expiry combined with batch-processing latency prevents atomic deposit-withdraw attacks
- **Keeper independence for refund**: orders that are never processed are refundable by anyone after 24h (see `Expire` redeemer)
- **Explicit pricing rule**: all orders in a batch are priced against the pre-batch snapshot, avoiding ordering-dependent outcomes

---

## 2. OrderDatum

```aiken
type OrderAction {
  DepositOrder { min_shares: Int }       // User minimum vUSDCx to accept
  WithdrawOrder { min_receive: Int, receiver: Address }  // User minimum USDCx + payout address
}

type OrderDatum {
  owner: VerificationKeyHash,    // Signer allowed to Cancel; recipient of Expire refunds
  action: OrderAction,
  expires_at: Int,               // POSIX ms; 24 hours from creation
  max_batcher_tip: Int,          // Lovelace; upper bound on keeper tip per order
}
```

Order UTXO contents:

- For `DepositOrder`: the user's USDCx deposit + a small ADA deposit (covers min-UTXO + `max_batcher_tip` + refund margin, ~2.5 ADA typical)
- For `WithdrawOrder`: the user's vUSDCx shares + the same small ADA deposit

The `max_batcher_tip` is user-specified at order creation. Users submitting low-priority orders may set tip low (or zero) and risk keeper skipping the order; users wanting rapid processing set tip higher. Keepers choose which orders to process based on tip economics.

---

## 3. Order lifecycle

```
 User creates Order UTXO
       │
       ▼
 Order sits at `order` script address with expires_at = creation_time + 24h
       │
       ├──── Keeper processes ────────▶ Process redeemer (batch)
       │
       ├──── Owner cancels ──────────▶ Cancel redeemer
       │
       └──── Expiry passes ──────────▶ Expire redeemer (anyone-can-trigger)
```

Only one of Process / Cancel / Expire can consume a given Order UTXO. Subsequent attempts fail because the UTXO is already spent.

---

## 4. Redeemers

### 4.1 `Process` — keeper processes order in a batch

Triggered when the keeper includes the Order UTXO in a BatchProcess transaction on the vault side.

```aiken
Process {
  vault_ref_input_idx: Int,       // Index of vault reference input (for reading pre-batch snapshot)
  payout_output_index: Int,       // For Withdraw: index of output paying user
  tip_output_idx: Option<Int>,    // Index of output paying keeper tip; None = keeper declines tip
}
```

**Order-side validation**:
- `tx.validity_range.upper < ord.expires_at` (order not yet expired)
- Vault input must be present in the transaction (keeper is consuming vault UTXO + this order UTXO simultaneously)
- Vault input must be at the `order_script_hash`-bound vault address (i.e., the "correct" vault, verified via Vault NFT)
- Keeper authorization check (via `keeper_stake_script` withdrawal entry)
- For DepositOrder: user's USDCx amount must flow into the vault's output; keeper mints and routes vUSDCx to `owner`'s address at `payout_output_index`; mint ratio computed per `vault_batcher` BatchProcess invariant
- For WithdrawOrder: user's vUSDCx is burned; user's requested `min_receive` USDCx must flow to `WithdrawOrder.receiver` at `payout_output_index`
- `min_shares` / `min_receive` slippage floors enforced (order fails if vault's pricing yields less than the user-specified minimum)
- Tip extraction (if `tip_output_idx = Some(idx)`):
  - Output at `idx` receives ≥ 0 lovelace and ≤ `max_batcher_tip` lovelace
  - Tip paid from the Order UTXO's own ADA balance (not from user's USDCx deposit)
  - Recipient address not constrained by contract (keeper freely chooses their own wallet)
- Refund: any ADA remaining in the Order UTXO (i.e., deposit minus min-UTXO minus tip) returns to `owner`'s address

### 4.2 `Cancel` — owner cancels pending order

```aiken
Cancel
```

**Validation**:
- `tx.extra_signatories` contains `ord.owner`
- Full Order UTXO value (USDCx / vUSDCx + all ADA) refunded to owner's address
- No vault involvement

Cancel is always available regardless of `expires_at` — owner retains full control over their order until processed.

### 4.3 `Expire` — anyone-can-trigger refund after expiry

```aiken
Expire
```

**Validation**:
- `tx.validity_range.lower >= ord.expires_at`
- Full Order UTXO value refunded to `ord.owner`'s address
- No vault involvement
- **No signer requirement** — anyone can submit this transaction. The full order value goes to the owner, not to whoever triggers Expire, so there's no incentive for Expire to be weaponized (the submitter pays the transaction fee; they receive nothing in return).

Expire is the "keeper downtime" failsafe: even if the keeper is completely offline, pending orders are refundable to users after 24 hours through any other Cardano user submitting the Expire transaction. This means a user's principal is **never trapped** in an unprocessed order — the worst case is "wait 24 hours for auto-refund".

---

## 5. BatchProcess redeemer (vault-side)

The vault-side counterpart to `order.Process`. Triggered on `vault_batcher` (post-Phase-77d standalone home of BatchProcess) as a staking-validator redeemer when the keeper includes a batch of orders in a transaction.

```aiken
BatchProcess {
  order_inputs: List<OrderInput>,   // Per-order metadata: input index, payout index, tip index, action
  mint_total: Int,                  // Total vUSDCx to mint (sum across deposit orders)
  burn_total: Int,                  // Total vUSDCx to burn (sum across withdraw orders)
  new_idle_buffer: Int,             // Computed post-batch idle_buffer
}
```

**Validation highlights** (full detail in implementation):

1. All `order_inputs` reference UTXOs at the `order` script address; each has a matching `Process` redeemer in the transaction
2. `mint_total == Σ deposit_order_shares` (computed from each deposit's amount × pre-batch share price)
3. `burn_total == Σ withdraw_order_shares`
4. `new_total_deposited = old_total_deposited + Σ deposit_amounts − Σ withdraw_amounts`
5. `new_total_shares = old_total_shares + mint_total − burn_total`
6. `new_idle_buffer = old_idle_buffer + Σ deposit_amounts − Σ withdraw_amounts`
7. Mint invariant: `tx.mint[vusdcx] == mint_total − burn_total` (net mint = mint − burn; can be positive or negative)
8. **Pre-batch snapshot pricing**: every order's fair share / fair withdrawal is computed against `old_total_deposited / old_total_shares`, not a running accumulator
9. **Payout index uniqueness**: each `payout_output_index` in the batch is distinct (prevents keeper from pointing two orders to the same output, double-counting)
10. **No vUSDCx leak**: minted vUSDCx can only flow to deposit-order owners or be burned against withdraw orders; no net vUSDCx to keeper's address or any third-party output
11. **Not frozen**: `old.frozen == 0`
12. **Keeper authorization**: `keeper_stake_script` zero-withdraw present

---

## 6. Pre-batch snapshot pricing — detailed explanation

All orders in a single batch are priced against the **pre-batch exchange rate snapshot**. That is:

```
share_price_in_batch = old_total_deposited / old_total_shares
```

This rate is computed once at the start of the batch, and all orders use it. A deposit of X USDCx always mints `X / share_price_in_batch` vUSDCx regardless of what other orders do within the same batch.

**Why this rule** (vs running-accumulator):

The vault enforces a per-batch aggregate invariant: `Σ minted_shares_per_deposit_order + Σ burned_shares_per_withdraw_order == mint_total - burn_total`. For this sum to be exactly enforceable with integer arithmetic, all orders need to use the same share price. A running accumulator (where order N uses the state after orders 1..N-1 are applied) breaks this invariant in edge cases and reintroduces an ordering-dependent fee extraction vector that was closed by an internal-verification finding.

**Consequence**: if a user submits a Withdraw order while a large Deposit order is in the same batch, the user's Withdraw is priced against the **pre-batch** state. Conversely, if Deposit is submitted alongside a large Withdraw in the same batch, the Deposit is priced against pre-batch. Either way, the user gets an unambiguous pricing rule they can verify after-the-fact; there is no keeper ordering-manipulation advantage.

**Bound on pricing drift**: at mature TVL, `max_single_order / total_deposited` is in the basis-point range and pre-batch-vs-post-batch pricing drift is negligible. At the pre-audit 100K TVL cap, a $5K order in a batch against a $100K vault yields a ~5% drift window. Users submitting large single orders at low TVL should prefer Direct Deposit or Direct Withdraw to avoid this drift.

---

## 7. Keeper economics of tips

The `max_batcher_tip` field creates a market for keeper processing priority. Keepers observe the order queue and choose which orders to process based on:

- Their own tip-collection strategy (claim full `max_batcher_tip`, claim less to win against other keepers, decline to claim and service public-good mode)
- Gas cost of including the order (each order adds transaction size and computation cost)
- Deadline proximity (orders near their 24h expiry get processed; otherwise they're refunded via Expire)

**Minimum viable tip** (frontend-enforced, not contract-enforced): the frontend rejects orders with `max_batcher_tip < 100_000` lovelace (0.1 ADA) to prevent spam. Users submitting directly via Cardano CLI can bypass this, but such orders are unlikely to be picked up by any keeper — the economic incentive is absent.

**Tip range at V1 launch**:
- Low-priority orders: 100,000–200,000 lovelace (0.1–0.2 ADA)
- Standard orders: 500,000 lovelace (0.5 ADA)
- High-priority: 1,000,000+ lovelace (1+ ADA)

Users should calibrate against observed keeper behavior post-launch.

---

## 8. Honest acknowledgement of ordering drift at low TVL

Because V1 launches with a 100K TVL cap, any single user submitting an order near 5% of that cap (i.e., $5K) will experience notable pre-batch-vs-post-batch drift if their order is in a batch with other large orders. Small orders (<$500) don't experience meaningful drift. Practical implication:

- **Users submitting small orders (<$500)**: Queue Deposit/Withdraw works perfectly; drift is sub-bp
- **Users submitting medium orders ($500–$2500)**: Queue is still reasonable; drift is single-digit bp
- **Users submitting large orders ($2500+)**: **Prefer Direct Deposit / Direct Withdraw** to avoid the drift window. Direct operations don't batch, so they always price against live vault state.

The frontend will surface this recommendation in the Deposit/Withdraw UX when order amounts approach 5% of current TVL.

---

## 9. Depositor-facing guarantees

Reading this specification, a user can rely on the following properties being contract-enforced:

1. **Principal safety during queue**: your deposit USDCx (or your vUSDCx for withdraw) sits in an Order UTXO at the `order` script address; only you (via Cancel) or the keeper (via Process) or — after 24 hours — anyone (via Expire) can move it. Nobody else.
2. **Cancellation rights**: you can Cancel at any time before Process, full refund guaranteed.
3. **24-hour recovery guarantee**: if the keeper never processes your order, after 24 hours it auto-refunds via Expire; you are never trapped.
4. **Slippage protection**: `DepositOrder.min_shares` and `WithdrawOrder.min_receive` set minimum acceptance thresholds; if the batch price would give you less than you specified, the order fails (does not execute).
5. **No hidden fees in batching**: the `max_batcher_tip` you specify is the only non-refundable ADA cost; no USDCx protocol fee applies to batched operations.
6. **Payout address guaranteed**: WithdrawOrder specifies `receiver: Address`; the contract verifies USDCx flows to exactly that address.
7. **Keeper cannot skim**: the batch's mint / burn / payout logic is entirely validator-enforced; no keeper-visible mechanism exists to siphon value from the batch to the keeper's own wallet beyond the user-authorized `max_batcher_tip`.

---

## 10. Reference to companion documents

- `spec/architecture.md` §5 — how Order / BatchProcess fits into the 12 transaction patterns
- `spec/vault-datum.md` §4 — BatchProcess column in the state-transition matrix
- `spec/keeper-auth.md` — keeper authorization mechanism used by BatchProcess
- `docs/economics.md` §1 — fee structure for Queue Deposit / Queue Withdraw vs Direct
