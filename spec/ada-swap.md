# OptiVaults V1 — Vault ADA Replenishment (`SwapAda`)

**Scope**: the `SwapAda` redeemer that lets a keeper atomically contribute ADA to the vault in exchange for USDCx at oracle-priced rate, replenishing vault operating ADA consumed by Minswap V2 swap batcher fees.

---

## 1. Problem this redeemer solves

V1's `DeployToProtocol` and related swap-producing redeemers consume ~4 ADA from the vault per Minswap V2 order. Fills typically return ~2 ADA (after batcher fee), producing a net ~2 ADA loss per swap cycle that the vault pays to Minswap's batcher infrastructure.

At 100K TVL with ~20 swaps per year, expected annual vault ADA consumption is ~40 ADA. Without a replenishment mechanism, vault ADA monotonically depletes toward `min_vault_ada` (10 ADA floor), at which point `DeployToProtocol` becomes rejected and the strategy can no longer rebalance.

The internal-verification-era mainnet required operators to manually send NoDatum ADA UTXOs to the vault address and fold them in via `MergeUtxo`. This works but is an off-chain operational step that:
- Requires dedicated keeper time + ADA
- Creates asymmetric burden across multi-keeper rotation (which keeper happens to top up?)
- Has no on-chain compensation for the keeper's ADA outlay

`SwapAda` makes this an atomic on-chain barter: keeper gives ADA to vault, vault gives equivalent USDCx back at oracle-priced fair rate. Keeper is economically neutral (value swapped 1-for-1 at market rate); vault's USDCx depletes slowly over time, and that slow depletion IS the protocol's way of charging depositors for the Minswap batcher fees (via share-price haircut). Closed loop.

---

## 2. Redeemer

```aiken
type VaultCoreRedeemer {
  // ... existing redeemers (Deposit, Withdraw, Compound, etc.)
  SwapAda { amount_ada: Int }
}
```

Single integer argument: the lovelace amount of ADA the keeper contributes to the vault.

---

## 3. Validation

The `SwapAda` redeemer lives on `vault_swap_ada` — a standalone staking validator extracted from `vault_keeper_hot` to hoist the dual-feed oracle reader + 6-tuple registry read out of Compound's host. It is reached via Withdraw-Zero forwarding from `vault_proxy` with the `UseSwapAda` route. The redeemer enforces the following invariants. Key V1 note: **keeper authorization goes through the stake-script zero-withdraw pattern**, not a `keeper_pkh` datum field (which does not exist in V1 VaultDatum). The keeper PKH for output routing is derived from `tx.extra_signatories` at runtime, matched against the `keeper_output_idx` output address.

```aiken
SwapAda { amount_ada, keeper_output_idx } -> {
  // Identify own input + continuing output
  expect vault_input_count == 1
  expect old_datum.frozen == 0                          // V1 internal-audit finding: freeze blocks SwapAda

  let own_lovelace = lovelace_of(own_input.output.value)
  let (cont_output, new_datum) =
    get_continuing_datum(tx.outputs, proxy_hash, own_input.output)
  let out_lovelace = lovelace_of(cont_output.value)

  // 1. Keeper authorization — V1 stake-script zero-withdraw, NOT
  //    require_keeper(keeper_pkh). vault_core is compile-time anchored
  //    to keeper_stake_script_hash; any wallet authorized by the stake
  //    script can invoke.
  let keeper_authorized = require_keeper_stake_script(tx, keeper_stake_hash)

  // 2. Trigger precondition: vault ADA below threshold
  let ada_below_threshold = own_lovelace < ada_swap_threshold   // 15 ADA

  // 3. Amount bounds
  let amount_in_range = and {
    amount_ada >= ada_swap_min,      // ≥ 10 ADA
    amount_ada <= ada_swap_max,      // ≤ 50 ADA
  }

  // 4. Physical ADA transfer
  let ada_added = out_lovelace == own_lovelace + amount_ada

  // 5. Fair USDCx output (via oracle-read rate)
  //    ada_price_bps = USDCx per 1 ADA × 10^4; e.g. 5_000 ⇔ 1 ADA = 0.5 USDCx.
  //    Full dual-feed enforcement runs through `oracle.read_fair_price`
  //    (§5.4 P5) which returns the midpoint of Charli3+Orcfax samples.
  //    Divisor MUST be 10_000 (= 10^4), matching the bps scaling of the
  //    price input. Dimensional analysis: amount_ada (lovelace = ADA×10^6)
  //    × ada_price_bps (×10^4) / 10^4 = microUSDCx (USDCx×10^6, since both
  //    have 6 decimals). Synchronised with oracle.check_tier1_bound which
  //    uses the same /10_000 divisor on the same read_fair_price return.
  let ada_price_bps = read_ada_price_oracle(tx)
  let usdcx_out_expected = amount_ada * ada_price_bps / 10_000

  let own_usdcx = quantity_of(
    own_input.output.value,
    old_datum.deposit_token_policy, old_datum.deposit_token_name,
  )
  let out_usdcx = quantity_of(
    cont_output.value,
    old_datum.deposit_token_policy, old_datum.deposit_token_name,
  )
  let usdcx_deducted = own_usdcx == out_usdcx + usdcx_out_expected

  // 6. Keeper receives USDCx — output at keeper_output_idx must pay to
  //    a VerificationKey wallet whose PKH appears in tx.extra_signatories
  //    (the signing keeper). This derives keeper identity at runtime from
  //    the TX, not from a datum field.
  let valid_keeper_output =
    expect Some(kout) = list.at(tx.outputs, keeper_output_idx)
    when kout.address.payment_credential is {
      VerificationKey(pkh) ->
        and {
          list.has(tx.extra_signatories, pkh),
          quantity_of(kout.value,
            old_datum.deposit_token_policy, old_datum.deposit_token_name,
          ) >= usdcx_out_expected,
        }
      _ -> False
    }

  // 7. Cooldown + 1h validity-range width cap (internal verification)
  let valid_cooldown = when (
      tx.validity_range.lower_bound.bound_type,
      tx.validity_range.upper_bound.bound_type,
    ) is {
      (Finite(now), Finite(upper)) -> and {
        now >= old_datum.last_ada_swap_time + ada_swap_cooldown_ms,
        upper - now <= max_validity_range_ms,
        new_datum.last_ada_swap_time >= now,
        new_datum.last_ada_swap_time <= upper,
      }
      _ -> False
    }

  // 8. Datum: only last_ada_swap_time + idle_buffer change; everything else preserved
  let valid_datum_other = and {
      new_datum.total_deposited == old_datum.total_deposited,
      new_datum.total_shares == old_datum.total_shares,
      new_datum.idle_buffer == old_datum.idle_buffer - usdcx_out_expected,
      new_datum.non_deposit_value == old_datum.non_deposit_value,
      new_datum.last_compound_time == old_datum.last_compound_time,
      new_datum.last_realloc_time == old_datum.last_realloc_time,
      new_datum.last_fee_update_time == old_datum.last_fee_update_time,
      new_datum.strategy_allocations == old_datum.strategy_allocations,
      new_datum.liqwid_positions == old_datum.liqwid_positions,
      new_datum.frozen == old_datum.frozen,
      check_immutable_fields(old_datum, new_datum),
      check_policy_fields_unchanged(old_datum, new_datum),
      new_datum.idle_buffer >= 0,
    }

  // 9. Token preservation (internal-verification dual-layer)
  let valid_other_tokens_preserved = verify_other_tokens_preserved(
    own_input.output, cont_output,
    old_datum.deposit_token_policy, old_datum.deposit_token_name,
    #"", #"",
  )

  // 10. No mint / no order inputs (prevents mixing with BatchProcess)
  let no_mint = get_mint_quantity(tx, old_datum.vusdcx_policy) == 0
  let no_order_inputs = val_has_no_order_inputs(
    tx.inputs, old_datum.order_script_hash,
  )

  and {
    keeper_authorized,
    amount_in_range,
    ada_below_threshold,
    ada_added,
    usdcx_deducted,
    valid_keeper_output,
    valid_cooldown,
    valid_datum_other,
    valid_other_tokens_preserved,
    no_mint,
    no_order_inputs,
  }
}
```

---

## 4. Compile-time parameters

Consolidated into `vault_swap_ada`'s compile-time parameter set (the home of SwapAda):

| Parameter | V1 launch value | Semantics |
|-----------|-----------------|-----------|
| `ada_swap_threshold` | 15_000_000 (15 ADA) | Trigger condition: vault ADA must be BELOW this to invoke |
| `ada_swap_min` | 10_000_000 (10 ADA) | Minimum ADA per SwapAda (prevents dust spam) |
| `ada_swap_max` | 50_000_000 (50 ADA) | Maximum ADA per SwapAda (caps oracle-staleness exploitation) |
| `ada_swap_cooldown_ms` | 3_600_000 (1 hour) | Minimum wait between SwapAda TXs (anti-spam + oracle-staleness bound) |
| `ada_price_oracle_source` | Charli3/Orcfax policy + asset_name, or Minswap V2 ADA/USDCx pool script hash | Reference-input identity for price reading |

Changing any of these requires a full V1 redeploy (new validator hashes, new vault address). This is intentional — these bounds determine the trust model around SwapAda and should not be governance-adjustable in V1.

---

## 5. Oracle source

**§5.4 P5 — shared dual-feed reader via `contracts/lib/vault/oracle.ak`.** SwapAda reads the ADA/USDCx price through the same `read_fair_price` helper used for P4 Tier 1 peg-floor checks on `DeployToProtocol`. The oracle config comes from the registry's `asset_oracles` list — an `AssetOracleEntry` pinned to the ADA convention `(asset_policy = #"", asset_name = #"")`. Governance populates the ADA entry via `UpdateRegistry` (14-day timelock); V1 launches with `asset_oracles = []`, which means SwapAda is **inactive until governance enables it** — during the bootstrap window, vault ADA top-up goes via `MergeUtxo` donations (operator path).

### 5.1 Registry entry layout

The ADA entry in `RegistryDatum.asset_oracles` pins:

- **Asset identity**: `(asset_policy = #"", asset_name = #"")` — the Cardano lovelace convention.
- **Feeds list** (typically 2 entries): each `AssetOracleFeed` identifies a reference-UTXO location by `(feed_script_hash, feed_auth_policy, feed_auth_name)`. The auth NFT prevents decoy UTXOs at the same script address. V1 launch convention is one Charli3 feed + one Orcfax feed, aggregated off-chain by the oracle operator into the canonical `PriceSample` format (see 5.2 below).
- **`max_disagreement_bps`**: cross-feed spread cap. Recommended 200 (2%) — matches the legacy MVP's `diff_pct <= 2` behaviour.
- **`max_staleness_ms`**: per-feed age cap vs `tx.validity_range.lower_bound`. The on-chain ceiling is **1 hour**, enforced by `contracts/lib/vault/validation.ak::valid_asset_oracle_entry`. Launch-recommended value is **600_000 (10 minutes) per entry**, governance-tunable within the ceiling via `UpdateRegistry`. Tighter than the legacy MVP's 40-minute cap because dual-feed aggregation already compensates for single-feed lag.
- **`min_feeds`**: required healthy feed count. Set to 2 (all feeds must agree).

### 5.2 PriceSample datum format

Each feed UTXO carries an `InlineDatum` of the canonical V1 shape:

```aiken
PriceSample {
  price_bps: Int,       // USDCx per ADA × 10_000 (10_000 = $1.00)
  timestamp_ms: Int,    // ledger ms when the oracle operator published the sample
}
```

The off-chain oracle operator is responsible for reading Charli3 + Orcfax native feeds, applying the operator's aggregation policy (typically midpoint or median), and publishing one `PriceSample` UTXO per feed slot. The operator identity + publishing policy is an external trust boundary documented in `../docs/security-model.md`. Future V1.x / V2 may swap in per-protocol native parsers (Charli3 `OracleDatum` + Orcfax `FactStatement`) to remove the operator-aggregation layer.

### 5.3 Consensus rule (enforced in `vault_swap_ada`)

```aiken
expect Some(ada_entry) = find_asset_oracle(asset_oracles, #"", #"")
expect Some(ada_price_bps) = read_fair_price(tx, ada_entry)
let usdcx_out_expected = amount_ada * ada_price_bps / 10_000
```

`read_fair_price` is defined in `contracts/lib/vault/oracle.ak` and enforces:

1. At least `entry.min_feeds` healthy samples (feed UTXO present + auth NFT present + `price_bps > 0`).
2. Each sample's `timestamp_ms` is fresher than `tx.validity_range.lower_bound - entry.max_staleness_ms`. Stale samples drop out of the aggregate.
3. Cross-feed spread (`(max − min) × 10_000 / min`) is at most `entry.max_disagreement_bps`.
4. The returned fair price is the midpoint of the healthy samples — equivalent to the median for 2-feed entries.

Any failure (missing entry, too-few healthy feeds, stale, disagreement, degenerate price) returns `None`, and the `expect Some(...)` forms in `SwapAda` then force a TX revert.

Combined with the 1-hour cooldown on SwapAda and the launch-recommended 10-minute per-feed staleness (rooted in the on-chain 1-hour ceiling), an attacker attempting single-oracle manipulation would need both feeds to independently lie in concert — the dual-feed consensus raises the bar from "one oracle compromised" to "two independent oracles compromised within the configured staleness window".

---

## 6. Economic model

### 6.1 Annual vault ADA flow at 100K TVL

Assuming ~20 swap cycles / year, each net −2 ADA from vault → Minswap:

| Event | Frequency | ADA change |
|-------|-----------|-----------|
| DeployToProtocol (VaultSwap) | ~20 / year | −4 × 20 = −80 ADA (out to Minswap order) |
| Minswap fill | ~20 / year | +2 × 20 = +40 ADA (returned to vault) |
| **Net vault ADA consumption** | — | **−40 ADA / year** |
| SwapAda (replenishment) | ~2 / year (each +20 ADA) | +40 ADA |
| **Net vault ADA** | — | **≈ 0** (closed loop) |

Vault ADA oscillates in the range 13–35 ADA (sometimes touches the 15 ADA threshold downward, then SwapAda restores to ~35).

### 6.2 Who pays the cost

| Actor | Net ADA flow | Net USDCx flow | Economic position |
|-------|--------------|-----------------|-------------------|
| Depositors | 0 (no direct ADA exposure) | −20 USDCx / year via share-price haircut | Ultimate cost bearer (≈ 0.02% APY haircut at 100K TVL) |
| Keeper | ±0 net (SwapAda is fair barter) | +20 USDCx / year from SwapAda (offset by ADA given) | Economically neutral |
| Minswap V2 batcher | +40 ADA / year | 0 | Receives batcher fees as usual |

Depositors pay ~20 USDCx / year (0.02% of TVL) for the protocol's right to use Minswap V2. This is surfaced as a micro share-price drag, not as an explicit fee.

### 6.3 Keeper rotation fairness (Phase 2+)

With multi-keeper rotation, whoever signs the SwapAda TX in a given cycle does the ADA↔USDCx barter. Over many cycles, SwapAda is roughly evenly distributed across active keepers proportional to their rotation weeks. Each keeper's barters are individually fair (oracle-priced), so no structural unfairness.

This is a strict improvement over the internal-verification-era manual top-up pattern where the founder-keeper bore all replenishment costs.

---

## 7. Failure modes + mitigations

| Failure | Mitigation |
|---------|-----------|
| Oracle feeds diverge by >2% (manipulation / outage) | TX rejected; keeper waits or uses external Minswap V2 to manually USDCx→ADA at their own cost |
| Both oracles stale >40 min | TX rejected; same as above |
| Keeper wallet insufficient ADA for SwapAda (20-50 ADA) | Keeper operational responsibility; documented in `docs/integration-playbook.md` — keeper should maintain 100+ ADA reserve |
| Malicious keeper triggers SwapAda when vault ADA is NOT below threshold | Contract check rejects (`ada_below_threshold = false`) |
| Malicious keeper spams SwapAda to arbitrage stale oracle (at max 50 ADA × 2% tolerance = 1 USDCx/attempt × 24 attempts/day max) | Cooldown 1h + bounded spread + max 50 ADA cap limits daily loss to ≈24 USDCx (0.024% of 100K TVL in worst case) |
| Oracle source compromised across both Charli3 + Orcfax simultaneously | Governance can queue `UpdateOracleSource` action via 14-day timelock to switch feeds; meanwhile `EmergencyWithdraw` pauses the vault (frozen=1) blocking SwapAda invocations |

---

## 8. Why not allow reverse direction (USDCx → ADA withdraw)

A `WithdrawAda` redeemer (keeper gives USDCx, receives ADA) was considered and deferred from V1:

- **Rarely useful in practice**: vault ADA naturally oscillates 13–35 ADA, rarely exceeding a hypothetical `> 50` upper trigger. Keeper has limited opportunities to invoke.
- **Attack surface doubled**: Keeper-profit oracle-staleness exploits work in both directions; closing reverse direction halves the attack surface.
- **Keeper has alternative path**: keeper's USDCx fee income can be converted to ADA externally via Minswap V2 on keeper's own schedule (≈2 ADA Minswap fee per quarterly conversion = 8 ADA/year total, economically negligible at 100K TVL).

V1.x candidate feature if operational experience demonstrates a clear need.

---

## 9. Related specs

- `spec/vault-datum.md` §2.1 — adds `last_ada_swap_time` field to the accounting-state group
- `spec/architecture.md` §7.5 — overview of ADA lifecycle + reference to this spec
- `whitepaper/whitepaper.md` §4.5 + §5.4 — depositor-facing disclosure of the closed-loop model
- `docs/security-model.md` §3.x — oracle failure threat model
