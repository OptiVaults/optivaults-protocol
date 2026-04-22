/**
 * A2 (2026-04-20) — scaffold for the V1 governance-gated stake deregister flow.
 *
 * This file documents the intended flow but is NOT a ready-to-run
 * submitter. Full wiring requires an active m-of-n governance signer
 * setup that the V1 Preprod ceremony does not (yet) configure with real
 * keys — the launch preprod.json uses 2 placeholder PKHs so that no
 * governance action can actually execute against the deployed vault.
 *
 * For A2 on-chain verification to be tractable in a single Preprod
 * session, either:
 *   (a) redeploy governance with 3 real keys the operator controls
 *       (hierarchical-deterministic derivation — 3 paths of the same
 *       mnemonic — or 3 separate wallets); OR
 *   (b) redeploy with `gov_min_threshold = 1` + `gov_min_signers = 3`
 *       temporarily in `lib/vault/constants.ak` (alongside the 1h
 *       `timelock_deregister_stake_ms` override), so that the operator's
 *       single real key satisfies threshold; revert both before mainnet.
 *
 * Either approach is additive to the work this session — the contract
 * layer (5 validators publish + ActDeregisterStake + payload hash +
 * 14d timelock) is already in place and aiken-checked.
 *
 * ── Queue flow (once gov signers are operational) ──
 *   1. Resolve target stake validator's applied Script + script hash.
 *   2. Compute payload_hash = blake2b_256(cbor.serialise(target_hash))
 *      where target_hash is the 28-byte stake validator hash.
 *      Aiken encodes a 28-byte ByteArray as CBOR `0x58 0x1c <28 bytes>`
 *      (major type 2, length 28).
 *   3. Build QueueAction redeemer against MultisigGov:
 *        Constr(0, [
 *          Constr(ACTION_KIND_IDX.ActDeregisterStake, []),  // action_kind
 *          target_hash_bytes,                                // target_script
 *          "",                                               // target_tx_hash (empty)
 *          payload_hash,                                     // 32-byte blake2b
 *          BigInt(timelockMs),                               // 14d prod / 1h preprod
 *          BigInt(ttlMs),                                    // 7d typical
 *        ])
 *   4. Build TX: spend MultisigGov UTxO + new output to MultisigGov
 *      with updated GovDatum (queued list extended + nonce+1 +
 *      signer_last_qualified_ms updated for qualifying signers).
 *   5. Sign with threshold signatures + submit.
 *
 * ── Execute flow (after timelock) ──
 *   1. Identify the queued action's action_id (from GovDatum.queued entry
 *      or recompute: blake2b_256(kind_byte ++ target ++ payload_hash ++
 *                                be8(queued_at_ms) ++ be8(nonce_at_queue))).
 *   2. Build ExecuteAction redeemer: Constr(2, [action_id]).
 *   3. Build TX with:
 *      - Input:  MultisigGov UTxO (spending with ExecuteAction redeemer)
 *      - Output: MultisigGov continuing UTxO with updated GovDatum
 *                (queued entry removed + nonce+1)
 *      - Certificate: Deregister for `Script(target_hash)` stake credential
 *      - validFrom/validTo covering the timelock window [executable_at, expires_at)
 *        + width <= 1h (contract-enforced)
 *   4. Sign with threshold signatures + submit.
 *   5. Cardano ledger invokes target validator's `publish` — our handler
 *      runs is_gov_authorized, matches ActDeregisterStake + target_script
 *      + payload_hash, returns True. Ledger accepts cert + refunds 2 ADA
 *      to TX submitter.
 *
 * ── ActionKind indices (Aiken declaration order in types.ak) ──
 *   0:  ActUpdateStrategy          7:  ActUpdateKeeperAuth
 *   1:  ActUpdateFee               8:  ActTreasurySpend
 *   2:  ActUpdateFeeSplit          9:  ActUpdateTreasuryParams
 *   3:  ActEmergencyWithdraw      10:  ActRotateSigners
 *   4:  ActAdminDeployNonDeposit  11:  ActSlashBond
 *   5:  ActUpdateRegistry         12:  ActUpdateOracleSource
 *   6:  ActFastUpdateMarkets      13:  ActDeregisterStake
 *
 * See spec/governance.md §4.13 + spec/multisig-gov.md §5 for the
 * payload_hash + action_id spec.
 */
console.error(
  "[deregister-stakes] scaffold only — see file header for V1 governance " +
    "setup prerequisite. Full queue/execute submitter lands when opti-gov " +
    "CLI is extended to ActDeregisterStake (paired task).",
);
process.exit(2);
