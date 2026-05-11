#!/usr/bin/env bash
# verify-mainnet-build.sh — preview mainnet contract hashes by temporarily
# swapping Preprod-override timelocks to production values, rebuilding,
# capturing hashes + diffs, and restoring constants.ak.
#
# This is a DRY-RUN verifier: makes NO permanent changes to source files.
# Run before any mainnet ceremony to confirm the mainnet artefact set
# compiles cleanly + matches expected hash deltas.
#
# Usage:
#   ./deploy/tools/verify-mainnet-build.sh
#
# Output written to deploy/state/mainnet-hash-preview.txt

set -euo pipefail
cd "$(dirname "$0")/../.."

CONST=contracts/lib/vault/constants.ak
BACKUP="$CONST.preprod-backup"
OUT=deploy/state/mainnet-hash-preview.txt

if [ ! -f "$CONST" ]; then
  echo "FATAL: $CONST not found (run from repo root or its deploy/tools/ subdir)" >&2
  exit 1
fi

mkdir -p deploy/state

# Pre-flight: audit off-chain h-* tool TIMELOCK_MS constants. The
# on-chain `preprod_fast_timelocks` flag governs validator-side timelock
# enforcement, but each h-* tool ALSO hardcodes its own TIMELOCK_MS at
# Queue commit time. A 60_000 left in any tool means a mainnet operator
# would commit a Queue with a 60-second timelock that the validator
# rejects — the failed Execute wastes the queue fee. Caught here at
# code-review time instead.
echo "[audit] h-* tool TIMELOCK_MS (must not be 60_000 for mainnet release)..."
TOOL_AUDIT_FAIL=0
while IFS= read -r line; do
  if echo "$line" | grep -q "= 60_000"; then
    echo "  FATAL: $line"
    TOOL_AUDIT_FAIL=1
  else
    echo "  OK:    $line"
  fi
done < <(grep -nE "const TIMELOCK_MS = " deploy/tools/h-*.ts)
if [ "$TOOL_AUDIT_FAIL" = "1" ]; then
  echo ""
  echo "FATAL: One or more h-* tools still have TIMELOCK_MS = 60_000."
  echo "Restore each to its production value per constants.ak::timelock_*_ms:"
  echo "  h-update-registry.ts       → 14 * 86_400 * 1_000 (14d)"
  echo "  h-update-fee-split.ts      → 21 * 86_400 * 1_000 (21d)"
  echo "  h-update-slippage-policy.ts→ 48 * 60 * 60 * 1_000 (48h)"
  echo "  h-rotate-signers.ts        → 14 * 86_400 * 1_000 (14d)"
  exit 1
fi
echo ""

trap 'if [ -f "$BACKUP" ]; then mv "$BACKUP" "$CONST"; echo "[restored] $CONST"; fi' EXIT INT TERM

cp "$CONST" "$BACKUP"
echo "[snapshot] backed up $CONST → $BACKUP"

# Single Bool flag flip drives all gated timelocks at once.
# `preprod_fast_timelocks = True` (Preprod E2E) → 60s on every gated timelock.
# `preprod_fast_timelocks = False` (mainnet build) → production values
# (7d / 14d / 21d / 48h) for: timelock_update_strategy_ms, timelock_update_fee_ms,
# timelock_update_fee_split_ms, timelock_admin_deploy_ms, timelock_update_registry_ms,
# timelock_update_keeper_auth_ms, timelock_treasury_spend_ms,
# timelock_update_treasury_params_ms, timelock_rotate_signers_ms, timelock_slash_bond_ms,
# timelock_update_slippage_policy_ms, timelock_deregister_stake_ms,
# admin_deploy_registry_cooldown_ms, distribute_period_ms.
python3 <<'PYEOF'
import re
fp = "contracts/lib/vault/constants.ak"
src = open(fp).read()
pat = r"(pub const preprod_fast_timelocks: Bool = )(True|False)"
m = re.search(pat, src)
if not m:
    raise SystemExit("FATAL: `preprod_fast_timelocks` flag not found in constants.ak — unexpected layout?")
if m.group(2) == "False":
    raise SystemExit("FATAL: flag already False — was constants.ak left in mainnet state? Restore Preprod build first.")
src = re.sub(pat, r"\g<1>False", src)
open(fp, "w").write(src)
print("[flip] preprod_fast_timelocks: True → False (mainnet build)")
PYEOF

echo ""
echo "[build] aiken build with mainnet timelocks..."
cd contracts
rm -rf build plutus.json
aiken build 2>&1 | tail -3
cd ..

echo ""
echo "[hashes] computing validator hashes..."
node -e "
const j = require('./contracts/plutus.json');
const seen = new Set();
const rows = [];
for (const v of j.validators) {
  if (!v.compiledCode) continue;
  const title = v.title.replace(/\..*/, '');
  if (seen.has(title)) continue;
  seen.add(title);
  rows.push({ title, hash: v.hash, size: v.compiledCode.length / 2 });
}
rows.sort((a, b) => b.size - a.size);
console.log('Validator                  Hash (28-byte)                                              Size (B)');
console.log('--------------------------------------------------------------------------------------------------');
for (const r of rows) console.log(\`\${r.title.padEnd(26)} \${r.hash}  \${String(r.size).padStart(8)}\`);
console.log('');
console.log('Over 16,384 B ceiling:', rows.filter(r => r.size > 16384).length);
" | tee "$OUT"

echo ""
echo "[done] hash preview written to $OUT"
echo "[note] constants.ak will be restored to Preprod values on script exit"
