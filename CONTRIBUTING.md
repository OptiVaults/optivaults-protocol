# Contributing to OptiVaults V1

Thanks for your interest in OptiVaults V1. V1 is published as a **Cardano DeFi public-goods reference implementation** under Apache 2.0 — contributions that strengthen the codebase, its audit story, or its usefulness as a fork-and-specialize baseline are welcome.

This doc covers: how to set up the dev environment, what kinds of contributions we want (and which ones need coordination first), PR expectations, testing + audit posture, and security disclosure.

## Which repo should you contribute to?

OptiVaults V1 is split across two repositories (see `README.md` §"Two-layer architecture"):

- **This repo (`optivaults-protocol`)** — protocol layer: Aiken validators, protocol spec, whitepaper, deploy pipeline. Use this repo for contract changes, spec corrections, whitepaper edits, deploy script improvements.
- **[`optivaults-reference`](https://github.com/OptiVaults/optivaults-reference)** — operator reference implementation: TypeScript keeper, API server, frontend, CLI tools. Use that repo for keeper runtime bugs, frontend UX, API improvements, CLI polish.

When in doubt, open the PR here — maintainers will move it if it's in the wrong repo.

---

## TL;DR — before you open a PR

1. Read `README.md` + `whitepaper/whitepaper.md` (or `whitepaper-zh-TW.md`) for positioning and trust model.
2. `aiken check` in `contracts/` must pass (104 tests / 599 randomized checks / 0 errors).
3. For contract changes, include a regression test in `lib/vault/tests/`.
4. For spec / doc changes, ensure internal cross-references still work (validator names, redeemer tags, field counts).
5. Don't commit secrets, mainnet signer PKHs, or real Blockfrost keys. They belong in operator `.env` (gitignored), never in the repo.
6. **Security-sensitive findings go to `optivaults@gmail.com` (PGP on optivaults.app/security), NOT a public issue.** See §Security disclosure below.

---

## 1. Environment setup

**Prerequisites**:

- Aiken `v1.1.x` (check exact patch version in `contracts/aiken.toml` — the Plutus V3 cost model is sensitive to the patch version; reproducibility matters)
- Node.js 20.x+ with `tsx` for running deploy tooling + E2E scripts
- Blockfrost Preprod project ID (free tier is sufficient for development + testing)
- An unlocked key daemon or a seed-phrase env var for Preprod test transactions (never mainnet seeds in contributor environments)

**Build + test the contracts**:

```bash
cd contracts
rm -rf build plutus.json
aiken build                       # regenerates plutus.json
aiken check                       # runs 104 tests + 599 randomized checks
```

`aiken check` must be clean on the branch before a PR is opened. If you add new tests, put them under `lib/vault/tests/` and ensure they fit the existing naming pattern (`<feature>_test.ak`).

**Run the Preprod deploy ceremony dry-run** (optional, for deploy/* contributors):

```bash
tsx deploy/deploy.ts --network Preprod --releaseTag <your-test-tag> --dryRun
```

Dry-run validates config parsing + compile step without submitting TXs.

---

## 2. Kinds of contributions

### Welcome without prior discussion

- **Bug fixes** in Aiken validators (must include a regression test demonstrating the prior failure + the fix).
- **Test coverage increases** — more property-based tests (`aiken/fuzz`), more edge-case unit tests, more Preprod E2E scenarios in `tests/preprod/`.
- **Documentation clarity** — typo fixes, wording improvements in specs + docs + whitepaper + inline Aiken comments.
- **Deploy tooling polish** — idempotency improvements, better error messages, observability.
- **i18n** — product-overview / whitepaper translations beyond the existing EN + 繁體中文.
- **Off-chain reference tooling** — helper scripts, decode verifiers (like `deploy/tools/verify-minswap-v2-decode.ts`), deploy sanity checks.

### Coordinate first (open an issue or email before PR)

- **New validator additions** or **validator topology changes** (e.g. splitting / merging validators). These affect audit scope, ceremony TX count, deposit capital requirements, and backward compatibility with already-deployed Preprod ceremonies. Discuss rationale before implementation.
- **New governance action kinds** (`ActionKind` enum additions). Every new action adds an audit-surface + a timelock-table entry + a payload-hash helper. Discuss why the new action is necessary vs using an existing one.
- **New SwapAdapter integrations** (e.g. SundaeSwap V3, Splash V2). These follow the `spec/swap-adapter.md §7` lifecycle — start with a spec discussion, then adapter impl + audit, then governance whitelist proposal.
- **Economic parameter changes** (fee caps, buffer targets, oracle disagreement tolerances). Governance chooses actual runtime values via `UpdateStrategy` / `UpdateFee` / `UpdateSlippagePolicy` — if a PR wants to change the constant-enforced CAP, that's a policy change requiring community discussion.
- **Breaking VaultDatum field changes**. The 28-field layout is frozen at V1 launch; any schema change triggers V2 and breaks the sunset / migration path.

### Not accepted

- **Removal of the 4.5% performance-fee hard cap** — `max_performance_fee_bps = 450` in `constants.ak` is a core safety invariant. Fee rate changes within [0, 450] happen via governance `UpdateFee`; pushing the cap higher requires V2.
- **Adding admin-drain redeemers** — any redeemer that could move vault funds to a non-depositor address is out of scope for V1. Emergency paths route through governance + public disclosure.
- **Automated adapter registration** (anyone can deploy an adapter and immediately use it without governance review). V1 requires human governance whitelisting per `spec/swap-adapter.md §10`.
- **Closed-source keeper implementation**. The keeper must remain Apache 2.0 + reproducible — that's what lets depositors self-serve via `emergency-withdraw` when the default keeper stops.

---

## 3. PR expectations

### Commit discipline

- One logical change per commit. Rebase over squash-and-merge.
- Commit messages: imperative + subject ≤ 72 chars, body explains _why_ (see existing `git log`).
- **Do not** include `Co-Authored-By:` trailers unless the user has explicitly asked for them.
- **Do not** include sections like "still pending", "deferred work", "memory update", or speculative future work — a commit describes what IS in the commit, not what isn't.
- Do not include planning/decision documents as part of the commit diff unless the user has explicitly requested them.

### PR description

- Reference the issue or Discord discussion that initiated the work (if any).
- Summarize WHAT changed and WHY.
- For contract changes: list any hash deltas (use `git show HEAD:contracts/plutus.json | jq '.validators[]|{title,hash}'` or equivalent off-chain diff).
- For test additions: note the test count delta (e.g., "104 → 108 tests").
- For spec / doc changes: confirm cross-doc consistency (e.g., validator count, field count, size table).

### Review

- PRs touching Aiken validators get merged only after an internal review round + `aiken check` passing in CI (CI not yet hosted — bring-your-own-CI is acceptable during V1 pre-mainnet; the merge committer runs it locally).
- Doc-only PRs can merge with one reviewer approval (including the author if operator + reviewer are the same identity during V1 early-phase).
- Keeper reference impl PRs (once `keeper/` is started) follow their own review convention TBD.

### Licensing + CLA

- **No CLA.** The project is Apache 2.0 inbound=outbound.
- By opening a PR you certify the Developer Certificate of Origin (DCO) equivalent: the code is yours to submit, it's licensed under Apache 2.0, and you're willing for it to be used in derivatives consistent with the license.

---

## 4. Testing expectations

### Unit tests

Every new validator behaviour or invariant must have at least one unit test. Place under `contracts/lib/vault/tests/<feature>_test.ak`. The test suite is run via `aiken check` — keep the total number of randomized checks reasonable (adding a property test × 100 iterations is fine; don't add × 10,000 without discussion because `aiken check` runtime is operator-facing).

### Property tests

Use `aiken/fuzz v2.2.0` for adversarial coverage. Refer to `property_test.ak` and `r72_test.ak` for existing patterns.

### Preprod E2E tests

When adding a redeemer path or changing redeemer semantics, add a corresponding Preprod E2E script under `tests/preprod/`. See existing `10-deposit-direct.ts` / `11-withdraw-direct-partial.ts` for the canonical shape (ceremony state file loader + Blockfrost provider + key daemon → build TX → submit → assert post-state).

Scripts are numbered by phase: `0X-ceremony-health`, `1X-user-flow`, `2X-compound`, `3X-merge-utxo`, `4X-protocol`, `5X-governance`, `6X-sunset`. Follow the convention when adding new scripts.

### CI / reproducibility

- Aiken version locked in `aiken.toml`. Do not bump without discussion — the Plutus cost model can change across patch versions, altering validator hashes.
- `plutus.json` is gitignored (auto-generated). Do not commit it.
- Deploy ceremony state files under `deploy/state/` are gitignored (operator-specific).

---

## 5. Audit engagement

V1 uses a **coverage-area methodology** (areas A–F, see `docs/audit-scope.md`) for its internal audit history, replacing per-round numbering that earlier versions used. The coverage-area plan is the source of truth for external audit scope.

Known open audit findings to be aware of when contributing:

- **R73 F-1** (MEDIUM, FIXED) — `vault_recall.MergeUtxo` admissibility gap. Closed via `valid_merge_utxo_admissibility` predicate + 6 regression tests (`lib/vault/tests/r73_test.ak`). See [SECURITY.md](SECURITY.md) §"Recently fixed" for the full root-cause + fix write-up. If you touch `vault_recall.ak` or the shared predicate, keep the admissibility guard on any new state-mutation paths.

Findings classified internally as LOW or INFO are tracked internally and don't block contributions unless you're changing the affected validator area; SECURITY.md summarises anything above LOW.

---

## 6. Security disclosure

**Do NOT open a public issue for security-sensitive findings.** Route them privately:

- **Email**: `optivaults@gmail.com`
- **PGP key**: `optivaults.app/security` (encrypt sensitive technical details)

We aim to acknowledge within 72 hours + triage within 7 days. V1 ships with a **Responsible Disclosure Policy + ex gratia recognition** framework (not a structured bug bounty tier) — full terms in `docs/audit-scope.md §6`. A formal bounty program is a post-external-audit + post-TVL-scale consideration.

If you're unsure whether a finding is security-sensitive, err on the side of private disclosure. We'd rather receive a low-severity finding privately and ask you to open a public issue than learn about a CRITICAL via a public bug tracker.

---

## 7. Communication + project coordination

- **Quick questions / implementation discussion**: Discord (invite on optivaults.app).
- **Design proposals / spec changes**: open a GitHub issue on the mirror repo or start a Discord thread.
- **Governance-related policy discussion** (fee rates, strategy allocations, adapter whitelisting): community channels per `spec/governance.md` + on-chain `QueueAction` with 14-21d timelock + public disclosure.

---

## 8. License

By contributing to OptiVaults V1 you agree your contributions are licensed under the **Apache License, Version 2.0** (see `LICENSE` at repo root).

The license choice is deliberate: V1's success metric includes architecture being forked and specialized by other Cardano teams (see whitepaper §1). Restrictive licensing on a pre-audit validation phase would contradict that contribution-oriented posture.
