# migration.md — Existing Depositor Migration to V1

V1 is a fresh deployment of the vault stack. Cardano smart contracts are immutable — V1 cannot upgrade an existing vault UTXO in place. Existing depositors on prior internal-verification deployments (informally referred to as "internal-verification-era" in operator docs) must actively migrate their funds.

This document is the canonical user-facing migration reference.

**Layer scoping**: migration is a **protocol-layer** event — depositors withdraw USDCx from the internal-verification-era vault contract and deposit into the V1 vault contract, both on-chain actions using their own wallet. The **operator layer** (which `optivaults.app` URL serves the UI, which keeper processes the TX) is not part of the migration path; depositors can complete the full migration using only `withdraw-cli` + any wallet of their choice + any V1 deposit UI (OptiVaults-operated or a fork). See `whitepaper §3.5` for the full two-layer framing.

---

## 1. Why a Fresh Deploy

V1 introduces several structural changes that cannot be expressed as a datum upgrade:

- **Two new validators** (`keeper_stake_script`, `treasury`) with their own UTXOs and compile-time parameters.
- **Heritage-era datum fields removed** — prior internal-verification versions carried `keeper_pkh` (authorization PKH) and `fee_collector` (USDCx recipient wallet) directly in `VaultDatum`. V1 replaces both:
  - `keeper_pkh` → `keeper_stake_hash` compile-time anchor on `vault_user` / `vault_keeper_hot` / `vault_protocol` / `vault_recall` / `vault_liqwid`; the actual authorized PKH set lives in the stake-script's own datum (governance-mutable via `UpdateKeeperAuth`, rotation without vault redeploy).
  - `fee_collector` → `treasury_hash` compile-time anchor on `vault_keeper_hot` (post-Phase-77 home of Compound; Compound's treasury share routes to the script address, not a wallet PKH).
- **Changed fee split** (100% to one wallet → 3-way split: 40% keeper / 0% gov pool at launch / 60% treasury — keeper share at validator hard cap to support open-source third-party keeper viability) requires the new treasury UTXO and multisig_gov UTXO to exist at Compound time.
- **New compile-time parameters** on nearly every validator — every validator hash changes.

Because validator hashes change, script addresses change, and no existing UTXO can be spent by the new validators. The only safe path is:
1. Deploy the V1 stack at fresh addresses.
2. Notify depositors.
3. Depositors withdraw from the old vault and deposit into V1 at their own pace.

---

## 2. Migration Window

**Phase A — Parallel Operation (target: 30 days)**

Both the old vault and V1 run in parallel. No coercion. Depositors withdraw from old → receive USDCx → deposit into V1 at their discretion.

**Phase B — Old Vault Wind-Down (target: 7 days after Phase A)**

Old vault is frozen (`frozen = 1`) via governance. Deposits disabled. Withdrawals remain open indefinitely — no time pressure.

**Phase C — Old Vault Residual**

Any remaining UTXOs in the old vault continue to accrue passive Liqwid yield until their depositor withdraws. Operator commits to keeper coverage of the old vault for at least 12 months after Phase B.

**V1 protections gained on migration (informational).** Once a depositor migrates from the internal-verification vault into V1, three structural protections that do not exist on the old vault take effect automatically:

1. **Layer 1 — EmergencyWithdraw freeze-only**: V1 governance cannot write loss directly into `total_deposited` via EmergencyWithdraw. All loss accounting flows through physical `vault_liqwid.RecallFromLiqwid` (governance fallback path), so a compromised gov key cannot brick share price by datum mutation alone.
2. **Layer 2 — Frozen-state USDCx swap-out**: under `frozen = 1`, the keeper (or governance, in fallback) can still swap NDV stables (DJED / USDM) back to USDCx via the SwapAdapter whitelist, so depositors can withdraw 1:1 USDCx during emergency rather than receiving mixed-asset payouts.
3. **Layer 3 — CommunitySunset 90-day dead-man-switch**: `vault_user.CommunitySunset` is a permissionless redeemer any vUSDCx holder can trigger if the vault has been inactive for 90 days. It atomically sets `frozen = 1` + opens `RecallFromLiqwid` and `DeployToProtocol` to permissionless callers, allowing any depositor to drive the full Recall → swap → Withdraw chain without operator or governance involvement.

These three layers bound depositor loss under single-signer governance failure and remove the 90-day-after-keeper-failure tail risk that the old internal-verification vault carried. Full design + 6-scenario threat walkthrough: `docs/security-model.md §5.4`.

---

## 3. User Migration Steps

**Step 1:** Visit optivaults.app/withdraw (old-vault endpoint).
**Step 2:** Withdraw full shares. Receive USDCx back to your wallet.
**Step 3:** Visit optivaults.app/deposit (V1 endpoint).
**Step 4:** Deposit USDCx. Receive vUSDCx at the V1 mint ratio (starts at 1:1 for the first V1 depositor, then follows share price).

**No bridge, no claim contract, no admin action required.** Standard withdraw + deposit flow.

**Gas cost:** ~3-5 ADA combined for both TXs.

**Early-withdraw fee:** if your position is under `min_hold_seconds` on the old vault at the time of withdraw, the **0.1% early-withdraw fee** (`early_withdraw_fee_bps = 10`, hard-capped at 100 bps by `vault_gov_policy.ak`'s UpdateFee redeemer via the shared `validate_update_fee` helper) applies. For reference: the old internal-verification vault used `min_hold_seconds = 7 days`; V1 launches with 60 seconds (capped at 6 hours per whitepaper §2.4). Operator subsidizes this fee for the first 100 migrating wallets from the treasury audit reserve — apply via email `optivaults@gmail.com`. (The larger 4.5% figure some users may have seen elsewhere is the **performance fee** on realised yield, not the early-withdraw fee — the two are separate and apply to different flows.)

---

## 4. Share Price Preservation

Share price at V1 deposit time is not directly connected to old-vault share price. You will:
1. Withdraw from old at old share price → receive USDCx.
2. Deposit same USDCx into V1 at V1 share price (starts at 1:1).

If the old vault had accrued positive yield, you keep it in USDCx. If V1 accrues yield after you migrate, your vUSDCx's share price grows.

**Net effect:** no yield lost in migration. Gas is the only cost (subsidized up to 5 ADA per wallet from treasury).

---

## 5. Operator Actions During Migration

**Old vault:**
- Keeper continues Compound + reconciliation cycles on old vault throughout Phase A/B/C.
- Keeper does **not** add new Liqwid positions on old vault after Phase A begins — new yield goes to V1.
- Existing old-vault Liqwid positions are Recall'd on a schedule matching withdrawal demand.

**V1 vault:**
- Fresh deploy with all **17 logic validators + 4 one-shot NFT mint policies + 1 DEX adapter** (see `spec/architecture.md` §4.1 for partitioning rationale).
- Initial treasury balance 0 (grows from Compound fees as V1 accrues yield).
- Governance signers: **1 founder + 2 independent Cardano SPOs, threshold 3 — unanimity required at launch per whitepaper §5.5 / §7.4**.
- Public announcement 14 days before Phase A launch.

---

## 6. Data Continuity

**On-chain state that does NOT carry over:**
- Vault UTXO (new address, new NFT)
- vUSDCx token policy (new policy, new token)
- Order UTXOs (must resubmit on V1)
- Liqwid positions (Recall'd from old + Supply'd from V1 independently)

**User data that carries over (off-chain):**
- Historical transaction audit trail (indexed by wallet address on optivaults.app/history, shows both old + V1)
- APY history charts display continuous data (old + V1 stitched in frontend)

---

## 7. Post-Migration Snapshot

A snapshot of all old-vault positions at Phase B freeze time will be published:
- On-chain as a governance action (IPFS hash committed to a no-op QueueAction)
- Off-chain at optivaults.app/migration/snapshot (JSON + CSV)

This snapshot is the reference document for any migration-fee subsidy claims.

---

## 8. Failure Modes

### 8.1 Depositor doesn't migrate

No action needed. Their old-vault position remains spendable indefinitely. Operator commits to keeper coverage for at least 12 months post Phase B. After 12 months, the operator may propose a governance action to sunset the old vault's keeper — depositors would still be able to withdraw via `emergency-withdraw` self-serve tool (no keeper required).

### 8.2 Old vault keeper goes down during migration window

`keeper_inactive` fallback activates after 7 days (same as V1). Governance can execute Recall/Withdraw paths. User can use `withdraw-cli` self-serve tool bundled with the old-vault interface.

### 8.3 V1 vault has a critical bug discovered during migration

Operator halts V1 deposits via the off-chain TVL-monitor breach threshold (or manual cap-to-zero in the frontend gating layer). Users already migrated can withdraw normally from V1. New migrations pause until V2 is prepared.

### 8.4 USDCx depeg during migration

Both vaults halt deposits per depeg protocol. Withdrawals remain open. Migration pauses, resumes when USDCx is stable.

---

## 9. Timeline (indicative, subject to audit gate)

| Milestone | Date (indicative) | Prerequisites |
|-----------|-------------------|---------------|
| V1 internal audit complete | — | Internal audit rounds on new validators |
| V1 external audit complete | — | External auditor engagement |
| V1 Preprod full E2E | — | All audits pass |
| V1 mainnet deploy ceremony | — | Audits + Preprod E2E |
| Phase A begins (parallel) | Deploy + 1 day | Announcement 14 days prior |
| Phase B freeze old vault | Phase A + 30 days | Governance action queued + executed |
| Phase C long-tail | Phase B + ongoing | Operator 12-month commitment |

Specific dates are announced at least 14 days in advance via Discord + email + on-chain governance disclosure.

---

## 10. FAQ

**Q: Will I lose yield during migration?**
A: No. Old-vault yield accrues until you withdraw. V1 yield accrues from your V1 deposit time. Gas costs (~3-5 ADA) are the only friction, and are subsidized for the first 100 migrators.

**Q: Can I migrate partial shares?**
A: Yes. Old-vault withdraw supports partial amounts. You can split across multiple TXs.

**Q: What happens to my old-vault vUSDCx tokens after I withdraw?**
A: They are burned on withdraw. No further action needed.

**Q: Do I need to claim anything on V1 to receive my migration credit?**
A: No automatic credit. The migration fee subsidy is applied retroactively — email `optivaults@gmail.com` with your wallet address and the treasury audit reserve refunds the early-withdraw fee in USDCx.

**Q: What if I'm outside the 100-wallet subsidy cap?**
A: Standard early-withdraw fee applies. Or wait past `min_hold_seconds` for zero fee.

**Q: Will V1 support my existing vUSDCx?**
A: No. V1 mints a new vUSDCx policy. The two are separate tokens.

**Q: Will the old vault ever be shut down?**
A: Not planned. Operator commits to 12-month keeper coverage post Phase B freeze. After 12 months, depositors retain `emergency-withdraw` self-serve access indefinitely (no keeper required) as long as their UTXO exists.

---

## 11. See Also

- `spec/architecture.md` — V1 validator structure
- `docs/security-model.md` — V1 threat model + trust delegations
- `docs/audit-scope.md` — V1 audit plan and gate to cap removal
- `whitepaper/whitepaper.md` — V1 public whitepaper, §11 migration-stability milestone
