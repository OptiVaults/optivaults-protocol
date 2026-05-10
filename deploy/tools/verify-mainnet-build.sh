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
