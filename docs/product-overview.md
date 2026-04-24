# OptiVaults V1 — Product Overview

**Audience**: depositors evaluating whether V1 fits their needs.
**Not**: a substitute for the [whitepaper](../whitepaper/whitepaper.md), the [security model](security-model.md), or the [economics reference](economics.md). This doc is the short, pragmatic read. When you want the full technical + threat-model answers, read those.

---

## 1. What V1 is, in one paragraph

OptiVaults V1 is a non-custodial smart-contract vault on Cardano. You deposit USDCx; the vault mixes your deposit with everyone else's into a blended position of USDCx, DJED, and USDM (all stablecoins) supplied to Liqwid Finance for lending-market yield. You receive **vUSDCx** share tokens proportional to your deposit. As yield accrues, your vUSDCx becomes worth more USDCx. You can withdraw at any time by burning your vUSDCx. No third party can move your funds; the whole mechanism is smart-contract code you can read + a governance multisig that can only change protocol parameters within validator-enforced hard caps.

**V1 is a Cardano DeFi public-goods reference implementation, not a commercial product** — the 4.5% performance fee covers protocol operations and audit reserve, not revenue to the founder or investors; the Apache 2.0 license allows other teams to fork and specialize. Depositors should enter with a "contributing to a public good + being an early validator" mindset, not as purchasers of a commercial service (full positioning in whitepaper Executive Summary + §12 Disclosure).

**V1 is pre-audit software under a 100K USDCx (≈$100K) total-deposits ceiling.** This is a ceiling, not a target — Phase 1 expected total TVL is actually **$5K-$25K** over the first 6-12 months. Read that as: we want a small number of pragmatic depositors to help us validate the system under real conditions, not a land-rush. External audit is targeted for **Q2-Q3 2027** (reflecting Cardano Project Catalyst Round timing uncertainty — see whitepaper §8.1), after which the cap will be raised.

---

## 1.1 What makes V1 distinct

These are features V1 provides that existing Cardano DeFi alternatives (Direct Liqwid supply / CEX earn products / self-custody USDCx) **do not all provide at once** — not marketing claims; each is directly verifiable against contract source code or on-chain state:

- **One CIP-30 transaction = three-stablecoin diversification + auto-compounding.** The only Cardano product today that packages "45% DJED + 25% USDM + 30% USDCx buffer" into a single deposit TX. Direct Liqwid supply requires 2-4 TXs on entry plus another round-trip per recall.
- **Depositor protections are contract invariants, not operational promises.** The 4.5% fee cap is immutable, no admin-drain redeemer exists, Withdraw has no pause switch — all baked into validator hashes, unchangeable by governance. Verify by reading the validators in `contracts/validators/` (principally `vault_user.ak` + `vault_keeper_hot.ak` for user-facing flows, `vault_gov_policy.ak` for the UpdateFee cap) and running `aiken build` to reproduce the hash against the on-chain deployment.
- **Self-serve recovery without any OptiVaults infrastructure.** `withdraw-cli` + `emergency-withdraw` web tool let you construct and sign a withdraw TX directly against the Cardano chain — no dependency on our API, our keeper, or our servers. V1's 0.1% early-withdraw fee (structural to the buffer design) auto-waives after 7 days of keeper inactivity, so the self-serve path is also fee-free.
- **vUSDCx is a standard Cardano native token** (not bound to the original deposit wallet). Giftable, and eventually usable as collateral or sellable if secondary / lending markets emerge — **a future-value feature**; during pre-audit there is no secondary market yet. Contrast with Liqwid qTokens, which must be redeemed from the original deposit wallet.
- **Apache 2.0 license, fork-welcome.** Any Cardano team can freely fork and specialize V1 into their own variants (different stablecoin baskets, risk postures, regional variants) — this is the intent of V1's non-commercial public-goods positioning, not an unintended consequence.

Other Cardano DeFi products may offer 1-2 of these individually. Only V1 offers **all five simultaneously**. If that's the intersection you're here for, the sections below spell out the contract guarantee and any external-dependency caveat for each one.

---

## 2. What you do, step by step

### 2.1 Deposit

1. Visit **optivaults.app/deposit**.
2. Connect a Cardano wallet (Eternl, Lace, Vespr, Typhon, Yoroi — any CIP-30 wallet should work; those five are tested).
3. Enter the USDCx amount you want to deposit and confirm.
4. Your wallet shows you a transaction to sign. Inspect the transaction details — the OptiVaults API builds the TX on the server side, so you verify before signing, not trust blindly.
5. Sign. TX is submitted to Cardano.
6. Once confirmed (~1 block, ~20-40 seconds typical), **vUSDCx share tokens appear in your wallet**. The number of shares you receive = `deposit × current_share_price_inverse`. The share price starts at 1:1 and increases as the vault earns yield.

You pay: ~0.5 ADA Cardano network fee (roughly $0.25 at recent ADA prices). That's the only cost of depositing. **No deposit fee on our side.**

### 2.2 Withdraw — you have three paths

| Path | When you use it | What happens | Settlement time |
|------|-----------------|--------------|------------------|
| **Direct Withdraw** | Normal case | Single TX — your wallet burns vUSDCx → vault sends USDCx to you | Immediate (next block) |
| **Queue Withdraw** | If vault's buffer is temporarily low | Your order sits in a queue → keeper processes in next batch cycle | Typically < 1 hour |
| **Emergency Withdraw** | If we go offline for > 7 days | You run `withdraw-cli` yourself or use the emergency-withdraw web tool | Immediate, no operator needed |

All three paths are **always available to you on-chain** — none requires governance approval, keeper cooperation-within-hours, or any off-chain signal. The smart contract + Cardano ledger are sufficient; even if our team disappears tomorrow, you can still submit a withdraw TX. **Honest caveat**: "withdraw works" is not the same as "withdraw settles in 1:1 USDCx." Settlement speed + output quality depend on (a) Cardano chain uptime, (b) your wallet having ADA for network fees, (c) Liqwid being available if your share includes a Liqwid position, and (d) USDCx market liquidity at the time. In a multi-protocol crisis (Liqwid bad debt + stablecoin depeg + DEX liquidity dry-up happening simultaneously), your on-chain claim is still enforceable but may settle in whatever assets the vault holds at that moment — not necessarily full-USD-value USDCx. See §6.6 for the correlated-crash scenario.

You pay: ~1-2 ADA network fee depending on path. There is a **0.1% early-withdraw fee** if you withdraw within `min_hold_seconds` (60 seconds at launch, capped at 6 hours) after the most recent Compound. This fee stays inside the vault and accrues to remaining holders as share-price appreciation — so if you hold, you benefit from others' early-withdraw fees. If our keeper is offline for 7+ days, the early-withdraw fee is **automatically waived** by the contract.

### 2.3 That's it

There's no staking, no claiming, no governance voting you need to do. Deposit, hold, withdraw when you want.

---

## 3. Why these protections are contract-enforced (not operational promises)

The five distinct features listed in §1.1 don't rely on "we promise we'll do this." Each one is enforced on-chain by Cardano PlutusV3 validators — anyone can read the source and verify. The 5 items below spell out the **contract-enforced guarantee** alongside **any remaining external dependencies** (honestly qualified).

1. **Withdraw cannot be frozen by anyone.** The Withdraw redeemer succeeds given your signature + vUSDCx burn; governance cannot block it; keeper cannot block it; **there is no "pause withdrawals" admin button** (intentionally not designed). A withdraw TX fails to submit only in three scenarios:
   - **Cardano chain itself is halted** — a chain-wide event affecting every Cardano app, not specific to V1
   - **Vault UTXO is contested by another TX** — fall back to Queue path; settlement within 1 hour
   - **Your wallet is out of ADA for network fees**
2. **Principal cannot be taken by admin.** No admin redeemer exists in the contract that can move `idle_buffer` to a non-depositor address. `EmergencyWithdraw` (governance m-of-n) can mark a loss (proportionally lowering all shareholders' share price) but cannot move funds out of the vault. Validator-layer hard caps (whitepaper §6.3) also preclude governance from setting fees above 4.5% or allocating more than 100% to any market.
3. **4.5% fee cap is immutable.** Hard-capped by `vault_gov_policy.ak`'s UpdateFee redeemer (via the shared `validate_update_fee` helper). Governance cannot raise it under any redeemer.
4. **All governance actions have timelock + 1-of-n cancel.** Every action is publicly visible at QueueAction time, with a minimum 1-hour wait before execution (sensitive actions like fee, signer, or strategy changes carry longer timelocks of 7-21 days). You can observe the queue, compute the payload hash, and — if you disagree — withdraw before execution. Any single signer can 1-of-n cancel to veto the entire action.
5. **You can self-exit if the team stops operating.** `withdraw-cli` is an open-source tool that lets you construct and sign a withdrawal TX without our coordination; tested with every release. If we go silent for 7+ days, the contract auto-waives the early-withdraw fee so self-serve exit is economically rational.

---

## 4. What your money does while you hold

Your USDCx enters the vault, which spreads it across three stablecoins on Liqwid Finance according to a governance-set target allocation (current launch target: **45% DJED, 25% USDM, 30% USDCx buffer**). The vault's keeper periodically:

- **Compounds** yield (roughly once per week at current TVL tier) — takes the interest Liqwid has paid, deducts our 4.5% performance fee, adds the rest back to the vault's total.
- **Rebalances** if the allocation drifts (e.g., after large deposits/withdrawals).
- **Monitors** each stablecoin for depeg events; halts deployment of new capital if a sustained (15 min) > 1% deviation is detected.

**Your share price only goes up over time**, barring one of these events: a stablecoin the vault holds depegs, Liqwid suffers bad debt, or a smart contract bug is exploited (all covered in §6 Risks).

**The 30% USDCx buffer sits idle at the vault address** at launch — it earns 0% yield but lets most withdrawals settle in a single TX without unwinding a Liqwid position. Governance can later reallocate a portion of the buffer into Liqwid's USDCx market if conditions make sense (see whitepaper §2.3 for trigger conditions); any such change goes through a 7-day timelock so you can exit if you disagree.

---

## 5. What you pay, plainly

| Fee | Amount | When you pay |
|-----|--------|--------------|
| Deposit fee | **$0** | Never (we charge nothing on deposit) |
| Management fee (AUM) | **$0** | Never (no annual percentage on your principal) |
| Performance fee | **4.5% of gross yield** | At each Compound (paid out of yield, not principal) |
| Early-withdraw fee | **0.1% of withdraw amount** | Only if you withdraw within `min_hold_seconds` (60 sec at launch) of most recent Compound; fee accrues to remaining holders; **auto-waived after 7 days keeper inactivity** |
| Cardano network fee | **~0.5-2 ADA per TX** | Paid to Cardano miners, not to us |
| SwapAda operational drag | **~0.02% APY at 100K TVL** | Share-price effect, ~10-20 USDCx/year at 100K TVL; this is the cost of replenishing vault operating ADA via oracle-priced swap (whitepaper §4.5 + spec/ada-swap.md) |

**Concrete example**: you deposit $1,000 USDCx. If gross blended yield is 6% and you hold for one year:
- Gross yield earned = $60
- Performance fee = $2.70 (4.5% of $60)
- Net yield = $57.30 (net APY ≈ 5.73%)
- Plus minor SwapAda drag (~$0.20)
- **Your withdrawable balance after a year ≈ $1,057**

Compare this to:
- **Direct Liqwid DJED supply** at ~11.8% APY: you'd get ~$118 (but spend ~4 hours/year doing manual rebalances yourself, and take 100% concentrated DJED exposure).
- **Binance USD earn** at 4-8% APY: you'd get $40-80. Binance is a single-entity counterparty — if Binance fails (see FTX 2022), all funds at Binance are at risk simultaneously. V1 has a different counterparty structure, not zero counterparty risk: exposure is spread across Circle / xReserve bridge / Liqwid / Minswap V2 / Charli3 + Orcfax oracles — so no single-entity bankruptcy can wipe out your position, but V1 adds smart-contract-bug exposure that Binance does not have. Neither is strictly safer; they have different failure modes.
- **Just holding USDCx** in your wallet: you'd get $0 (and still carry the same Circle / xReserve counterparty risk you'd carry in V1).

---

## 6. What can go wrong, honestly

V1 is not principal-protected. These are real risks you accept by depositing. Read the [security-model](security-model.md) for the adversary-class-by-class analysis; the summary below is what each failure looks like from your wallet:

### 6.1 Smart-contract bug

**What it looks like for you**: in the worst case, someone exploits a validator bug and extracts funds from the vault. Your vUSDCx becomes worth proportionally less (or zero if drain is complete).

**Our mitigation**: multi-round internal audit completed before launch; external audit target **Q2-Q3 2027** (reflecting Catalyst Round timing uncertainty — see whitepaper §8.1); 100K USDCx cap limits maximum exposure during pre-audit era; `EmergencyWithdraw` governance path to freeze + recover if a bug is detected but not yet drained.

**Your action**: stay within a deposit size you can afford to lose. At launch, we literally recommend **$200-$2,000 per wallet** during Phase 1 — not because smaller is safer (it is), but because pre-audit risk warrants it.

### 6.2 Stablecoin depeg (DJED, USDM, or USDCx)

**What it looks like for you**: if DJED loses its peg to USD (e.g., falls to $0.85), your share price drops proportionally since the vault is 45% DJED. A 10% DJED depeg ≈ 4.5% share-price drop at current allocation.

**Our mitigation**: per-asset depeg monitoring on Charli3 + Orcfax oracles + Minswap TWAP; sustained (15 min) > 1% deviation triggers keeper halt + operator alert; governance can freeze new deployment via `EmergencyWithdraw`.

**Your action**: if you're uncomfortable with multi-stablecoin exposure, use Direct Liqwid supply to pick a single stablecoin you trust, rather than accepting our basket.

### 6.3 Liqwid protocol failure

**What it looks like for you**: if Liqwid suffers bad debt (under-collateralized loans not covered by their reserve), the qToken-to-underlying rate drops; your share price drops proportionally to the vault's Liqwid exposure (currently 70% of TVL).

**Our mitigation**: per-market position isolation (bad debt in Liqwid DJED does not contaminate Liqwid USDM); keeper can unilaterally disable new supply to a compromised market; governance can `EmergencyWithdraw` to freeze.

**Your action**: V1's Liqwid concentration is real — if Liqwid as a whole fails, V1 has no fallback protocol at launch. This is flagged as V1's single largest on-chain risk source in whitepaper §5.3. If Liqwid protocol risk is a serious concern for you, V1 may not be the right product. **Note that V2's multi-protocol expansion is a design direction, not a committed roadmap** — if Cardano's stablecoin lending landscape does not mature as hoped (e.g., no second qualified lending protocol emerging), V1 **remains a single-protocol Liqwid wrapper indefinitely**.

### 6.4 Keeper outage

**What it looks like for you**: keeper stops running. Compound stops happening. Rebalance stops happening. **Withdraw still works for you** — Direct, Queue, and Emergency paths are all unaffected by keeper state. After 7 days of keeper inactivity, early-withdraw fee is auto-waived so Direct Withdraw is free for you.

**Our mitigation**: keeper code is open-source and on-chain-switchable via `UpdateKeeperAuth`; governance can activate permissionless keeper mode; 7-day grace triggers fee waiver; `emergency-withdraw` tool gives you self-serve exit.

**Your action**: none — V1 is designed so keeper-offline is an inconvenience (no new yield accrues), not a loss event.

### 6.5 Governance action you disagree with

**What it looks like for you**: governance queues a `UpdateStrategy` that shifts the vault to an allocation you're not comfortable with. You have 7 days (timelock on strategy changes) to decide + exit.

**Our mitigation**: every governance action is on-chain + publicly observable at QueueAction time; minimum timelocks (§6.2 whitepaper) give you time to react; any single signer can 1-of-n cancel.

**Your action**: during the timelock window, withdraw if the proposed change is unacceptable to you.

### 6.6 Correlated multi-asset crash

**What it looks like for you**: ADA flash-crashes 30% → DJED depegs (ADA-collateralized) + Minswap DEX liquidity thins for USDM/USDCx exits simultaneously. Share price drops in a cascading way. Reverse swaps (DJED → USDCx) execute at depeg-discount prices before keeper freeze fires.

**Our mitigation**: imperfect. Depeg monitor has a 15-min sustained threshold — a rapid crash can execute multiple swaps at depeg prices before the monitor triggers. We honestly do not have a good answer for sub-15-min crashes; the multi-stablecoin allocation is **dual-issuer diversification within single-ecosystem exposure, NOT independence against ADA crashes**.

**Your action**: understand that V1's multi-stablecoin allocation protects against issuer-specific blowups (one of DJED / USDM / USDCx failing alone) but NOT against ADA-correlated cascades.

---

## 7. Is V1 right for you?

Simple decision tree:

1. **Do you hold USDCx on Cardano, not on a CEX?**
   - No → V1 isn't relevant; consider whether to onramp to USDCx at all (depends on whether you trust Circle + xReserve).
   - Yes → continue.

2. **Are you willing to spend 1 hour per quarter manually managing a Liqwid DJED position?**
   - Yes → **use Direct Liqwid DJED supply instead**. Higher net yield, fewer moving parts, less aggregate attack surface.
   - No → continue.

3. **Would you deposit money at a centralized exchange like Binance for stablecoin earn products?**
   - Yes → Binance Earn 4-8% APY has a different risk structure (single-entity counterparty vs V1's multi-protocol risk + smart-contract-bug exposure). **Neither is strictly safer** — see §5 for the full counterparty comparison (FTX 2022 is the canonical single-entity-failure reference). Consider which failure mode you'd rather bear.
   - No (self-custody principle) → V1 is designed for you. **Continue.**

4. **Is your intended deposit size $100-$10K and you want hands-off exposure?**
   - Yes → V1 may be a reasonable match as a **post-audit target user** (currently targeted **Q2-Q3 2027** after external audit passes and the TVL cap is lifted; see whitepaper §8.1 for funding-stack uncertainty). During the pre-audit period the operator-enforced 100K USDCx TVL cap constrains aggregate deposits, but **the contract is permissionless — there is no invitation gate**. Any depositor who understands and accepts the pre-audit risk profile (undetected CRITICAL bug possible, TVL will not grow quickly, founder bandwidth limited) may decide to enter on their own judgment. Before entering: read whitepaper §5 Risks. There is no "correct" first-deposit size — different Phase 1 depositors have used amounts from $50 to $2K. **If you're unsure, $100-$200 is a reasonable first-deposit range for learning the mechanism**; scale from there once you've completed at least one full deposit + withdraw cycle and confirmed the round-trip works end-to-end. The general principle is that you should be able to afford total loss if a CRITICAL bug surfaces. Pre-audit is not the right phase for depositors seeking yield maximisation or scale entry — that group should wait for post-audit cap lift or choose Direct Liqwid DJED supply directly.
   - No (< $100) → V1 is viable but 0.5 ADA network fee is ~0.25% entry friction at very small size; consider if that is acceptable.
   - No (> $10K) → read whitepaper §4.4 break-even sensitivity table. At higher deposit sizes Direct Liqwid usually wins on pure yield math.

---

## 8. FAQ

**Q: Is this audited?**
A: Internal audit has completed multiple rounds of adversarial validator-code review. External third-party audit is targeted for **Q2-Q3 2027** (reflecting Cardano Project Catalyst Round timing uncertainty — see whitepaper §8.1). V1 operates under a 100K USDCx cap until external audit completes. See whitepaper §5.1 for methodology.

**Q: How do I know you won't steal my money?**
A: You don't have to trust our word — you can read the validator code. Every redeemer enforces on-chain that `idle_buffer` can only be sent to one of three destinations:
- Back to depositors via Withdraw
- DEX order addresses via keeper-signed DeployToProtocol TX (whitelisted)
- Liqwid action validators via SupplyToLiqwid

No redeemer lets us extract funds to an admin wallet. Validator hashes are verifiable — see whitepaper §10 Reproducibility.

**Q: What if Cardano itself goes down?**
A: V1 is entirely on-chain. If Cardano halts, V1 halts too. When Cardano resumes, V1 resumes. Principal is not lost — it is just illiquid during a chain halt.

**Q: Can I lose more than I deposited?**
A: No. Your maximum loss is your vUSDCx value at time of event, which cannot go below zero. V1 has no leverage, no borrowing, no margin liquidation against your position.

**Q: Do I need to pay taxes on yield?**
A: Probably yes in most jurisdictions — yield is generally taxable income or capital gains depending on local law. This is your responsibility; V1 does not issue tax forms. Consult a tax professional in your jurisdiction.

**Q: Can I transfer my vUSDCx to another wallet?**
A: Yes. vUSDCx is a standard Cardano native token. You can send it to any wallet, and the receiving wallet can later redeem it for USDCx. This is also how you could sell your position on a secondary market (though no such market exists at launch).

**Q: What's the minimum deposit?**
A: 10 USDCx (contract-enforced). Anything below is rejected to keep the vault's min-UTXO accounting clean. Practically: because Cardano network fees are ~0.5 ADA (~$0.25) per TX, very small deposits have high percentage entry friction. We recommend **$100+ first deposit** for the math to make sense, though $20+ is technically viable.

**Q: What's the maximum deposit?**
A: No per-wallet cap. The overall vault cap is 100K USDCx during pre-audit; once that's hit, new deposits are rejected at the API layer (the cap is operator-enforced, not contract-enforced — see whitepaper §9.4).

**Q: I see governance has queued an action I don't like. What do I do?**
A: Withdraw during the timelock window (7-21 days depending on action type). You have ample time — this is the point of timelocks.

**Q: Where do I ask questions?**
A: Discord link at optivaults.app. Security issues: `optivaults@gmail.com`.

---

## 9. Summary

OptiVaults V1 is a pre-audit, non-custodial stablecoin vault on Cardano. **Phase 1 (now → external audit completion, currently targeted Q2-Q3 2027)**: operator-enforced 100K USDCx TVL cap, expected TVL range $500-$25K, success measured by Phase-1 criteria (no CRITICAL exploits + working automation + community trust + audit-firm handoff) not by hitting the cap. Phase 1 duration is extended relative to original Q3 2026 audit-target, reflecting Catalyst Round timing uncertainty (whitepaper §8.1). **Phase 2 (post-external-audit, target Q2-Q3 2027 + N months clean operation)**: cap raised or removed per audit findings, target user expands toward $100-$10K hands-off depositors, governance rotation toward Phase 2+ signer slate. V1 is designed for a specific profile in either phase: someone who holds USDCx, won't use a CEX, prefers not to run Liqwid manually, and accepts smart-contract risk in exchange for hands-off blended stablecoin yield. If that sounds like you, start small and read the [whitepaper](../whitepaper/whitepaper.md). If it doesn't, that's fine — we'd rather you find the product that actually fits your needs, whether that's Direct Liqwid, a CEX earn product, or simply continuing to self-custody USDCx.

**Why we built this.** The founder is a Cardano self-custody user: ADA holder + native staker (delegated to a stake pool) since 2025, small-BTC holder since 2025, participated in Midnight's NIGHT redeem, Minswap V2 ADA/NIGHT LP since 2026, and a current USDCx holder (USDCx launched on Cardano via Circle's xReserve in February 2026). V1 started as a concrete personal problem — USDCx was sitting in the founder's wallet and the realistic options were:

- **(a) Send it to a CEX earn product** — rejected on self-custody principle.
- **(b) Supply directly on Liqwid's USDCx market** — ~0.5-2% APY, not worth the effort after inflation.
- **(c) Swap USDCx to DJED and supply on Liqwid for ~11.8% APY** — entry is 2 TXs (swap + Liqwid supply); exit or each partial withdraw is its own 2-TX recall + swap-back round-trip; DJED + USDM + USDCx diversification means parallel management across three positions. Between entry and exit the qToken sits in your wallet with its rate auto-accruing. On a $200 position, the one-off entry + exit round-trip gas is roughly 1-2% of principal; the longer you hold, the more that friction amortises.
- **(d) Just hodl USDCx in the wallet** — 0% yield, same USDCx issuer risk either way.

No "deposit USDCx and let it auto-compound across DJED + USDM with a single-TX exit" option existed. So the founder built one. V1 is "what I was personally looking for but couldn't find."

**Core user protections are contract invariants, not operational promises** — no admin can drain funds, the 4.5% fee cap is immutable, early-withdraw fee is auto-waived after 7 days of keeper inactivity. (Some protections, including successful withdrawal settling in 1:1 USDCx, additionally depend on Cardano + Liqwid + Minswap V2 + USDCx all remaining operational — see whitepaper §1.5.1 for the honest qualification.)

**V1 is a convenience layer, not the one right answer.** V1 does the swap + supply allocation in a single CIP-30 deposit TX and gives you a single-TX exit via vUSDCx burn — in exchange for 4.5% of realised yield. If you prefer to run those steps yourself and keep the full yield, that's a perfectly reasonable choice, especially for longer holding periods where one-time entry + exit gas amortises to a small fraction. If smart-contract risk is outside your comfort zone at any level, continuing to self-custody USDCx in your own wallet is equally reasonable.

**V2 is a direction, not a committed roadmap** — whether V1 evolves into a multi-protocol, multi-strategy asset-allocation layer depends on Cardano DeFi maturing further (a second qualified lending protocol emerging, DEX liquidity deepening, etc.). Until then, evaluate V1 on what it actually offers today: auto-compounding + dual-issuer stablecoin allocation + self-serve exit guarantees + audited-and-capped fee structure. Full origin story plus the why-Cardano and why-now framing is in whitepaper §1.5.

**Operational reality (depositor-relevant, not buried).**

- **V1's success threshold is $500K-$1M TVL, not $20M.** The 4.5% performance fee × that TVL × ~6% blended yield generates ~$135-270/year of keeper-share revenue, enough for the keeper to cover its own infra ops cost. That's the **tier (a)/(b) self-sustain** target. The widely-discussed "$20M TVL" figure is a separate **tier (c) audit-reserve self-funding** target (the protocol covering its own future external audit cycles from the treasury's 80% share), which is a Phase 3+ stretch goal, not a V1 prerequisite. Full three-tier breakdown in whitepaper §4.3.
- **Audit funding stack with explicit Catalyst-pause disclosure.** Primary funding stack is (a) Cardano Project Catalyst grant ($30-50K) — **but Catalyst is currently paused / restructuring with no confirmed Round resumption timeline**; (b) audit-firm public-goods rate (-30-50% off commercial $50-150K range); (c) scope reduction from heritage internal audit (-$15-25K); (d) founder out-of-pocket. **Audit timeline is set to Q2-Q3 2027** explicitly to accommodate Catalyst resumption probability + alternative-grant outreach (Cardano Foundation, Intersect, Aiken Foundation) + founder runway accumulation. If Catalyst does not materialise, founder out-of-pocket cap rises from $20-40K to $50-90K. Whitepaper §8.1 spells out the funding-stack disclosure.
- **The 2 independent SPO governance signers are Cardano community-service roles, not paid positions.** They get a soul-bound recognition NFT and the option to take a 5-10% governance pool share in Phase 2+ (gated on $500K TVL milestone) — both are **upside if V1 succeeds, not primary motivation**. Selection criteria: ≥ 2 years mainnet SPO operating, public on-chain identity, no prior commercial relationship with the founder. Whitepaper §5.5 covers this in full.

**Contacts**:
- Website: [optivaults.app](https://optivaults.app)
- Security disclosures: `optivaults@gmail.com`
- Discord: link at optivaults.app
- Code: `github.com/OptiVaults` (open-source mirror, published at V1 mainnet launch)

---

## 10. Where to go from here

| You want to | Read this |
|-------------|-----------|
| The full technical + threat-model description | [whitepaper/whitepaper.md](../whitepaper/whitepaper.md) |
| How V1 compares economically to alternatives | [economics.md](economics.md) + whitepaper §4 |
| Specific risks and attack surfaces | [security-model.md](security-model.md) + whitepaper §5 |
| How governance works | [../spec/governance.md](../spec/governance.md) + whitepaper §6 |
| How to migrate from the internal-verification deployment | [migration.md](migration.md) |
| What the audit plan looks like | [audit-scope.md](audit-scope.md) + whitepaper §8.1 |
| 繁體中文版 | [product-overview-zh-TW.md](product-overview-zh-TW.md) |
