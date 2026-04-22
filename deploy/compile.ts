/**
 * V1 compile step.
 *
 * Takes `contracts/plutus.json` (output of `aiken build`) + one of the
 * deploy config files, and produces the full applied-hash set used by the
 * ceremony. The dependency graph is:
 *
 *   NFT mints (no stake hash dependency at this point):
 *     vault_nft(utxo_ref)           → vault_nft_policy
 *     governance_nft(utxo_ref, gov_name) → governance_nft_policy
 *     registry_auth_nft(utxo_ref, asset_name) → registry_auth_policy
 *
 *   keeper_stake_script(gov_nft_policy, gov_nft_name)
 *     → keeper_stake_hash
 *
 *   treasury(deposit_token_policy, deposit_token_name)
 *     → treasury_hash
 *
 *   vault_user(gov_nft_policy, gov_nft_name)
 *     → user_stake_hash
 *     (Phase 77d: keeper_stake_hash dropped — Deposit + Withdraw are
 *      both permissionless, BatchProcess moved to vault_batcher.)
 *   vault_keeper_hot(keeper_stake_hash, treasury_hash, gov_nft_policy, gov_nft_name)
 *     → keeper_hot_stake_hash
 *   vault_batcher(keeper_stake_hash, gov_nft_policy, gov_nft_name)
 *     → batcher_stake_hash
 *   vault_swap_ada(keeper_stake_hash, gov_nft_policy, gov_nft_name)
 *     → swap_ada_stake_hash
 *   vault_protocol(keeper_stake_hash, gov_nft_policy, gov_nft_name)
 *     → protocol_stake_hash
 *   vault_recall(keeper_stake_hash, gov_nft_policy, gov_nft_name)
 *     → recall_stake_hash
 *   vault_liqwid(keeper_stake_hash, gov_nft_policy, gov_nft_name)
 *     → liqwid_stake_hash
 *   vault_gov_policy(gov_nft_policy, gov_nft_name)
 *     → gov_policy_stake_hash
 *   vault_gov_emergency(gov_nft_policy, gov_nft_name)
 *     → gov_emergency_stake_hash
 *   vault_admin_deploy(gov_nft_policy, gov_nft_name)
 *     → admin_deploy_stake_hash
 *
 *   vault_proxy(user, keeper_hot, swap_ada, protocol, recall, liqwid,
 *               gov_policy, gov_emergency, admin_deploy, batcher,
 *               vault_nft_policy)
 *     → vault_hash
 *
 *   order(vault_hash, vault_nft_policy)
 *     → order_script_hash
 *   vusdcx(vault_hash, vault_nft_policy)
 *     → vusdcx_policy
 *
 *   multisig_gov(gov_nft_policy, gov_nft_name, deposit_token_policy,
 *                deposit_token_name, treasury_hash)
 *     → multisig_gov_hash
 *
 *   registry()
 *     → registry_hash
 *
 * This file is pure compile — no network I/O. Runnable offline, idempotent.
 * It is called by deploy.ts before any TX is submitted, but can also be
 * invoked standalone to preview what the hashes WILL be for a given config
 * (useful for ceremony rehearsal + mainnet announce-the-hashes-ahead-of-time).
 *
 * Usage:
 *   npx tsx deploy/compile.ts --network preprod --utxoRefs <out.json>
 *
 * The `--utxoRefs` file contains the 3 UTxO references that will back the
 * 3 ceremony one-shot NFT policies (vault_nft / governance_nft /
 * registry_auth_nft). `gov_signer_nft` is a 4th NFT policy but uses a
 * different parameterisation (one-per-signer, minted on demand) and is not
 * consumed here. These 3 refs must exist in the deploy wallet's UTxO set
 * at mint time and NOT have been spent elsewhere.
 */
import * as fs from "fs";
import * as path from "path";
import {
  applyParamsToScript,
  Data,
  mintingPolicyToId,
  validatorToScriptHash,
  type Script,
} from "@lucid-evolution/lucid";
import { loadConfig, summarizeConfig, type NetworkName } from "./lib/config.js";

interface UtxoRef {
  txHash: string;
  outputIndex: number;
}

interface UtxoRefsInput {
  vaultNft: UtxoRef;
  governanceNft: UtxoRef;
  registryAuthNft: UtxoRef;
}

interface CompiledHashes {
  network: NetworkName;
  compiledAt: string;
  utxoRefs: UtxoRefsInput;

  vaultNftPolicy: string;
  governanceNftPolicy: string;
  registryAuthPolicy: string;

  governanceNftName: string;
  registryAuthName: string;

  keeperStakeHash: string;
  treasuryHash: string;

  // §5.4 P1 (2026-04-21): vault_admin split into
  //   vault_gov_policy + vault_gov_emergency
  // Phase 77 (2026-04-22): vault_core split into vault_user + vault_keeper_hot;
  //   vault_protocol split into vault_protocol + vault_recall (headroom
  //   after SwapAdapter dispatch + Tier 1 oracle wiring).
  // Phase 77b (2026-04-22): SwapAda extracted from vault_keeper_hot into
  //   standalone vault_swap_ada (dual-feed oracle reader + 6-tuple
  //   registry read no longer pressure vault_keeper_hot's bytecode
  //   budget).
  // Phase 77c (2026-04-22): AdminDeployNonDeposit extracted from
  //   vault_gov_emergency into standalone vault_admin_deploy
  //   (SwapAdapter dispatch + destination-whitelist no longer pressure
  //   vault_gov_emergency's bytecode budget).
  // Phase 77d (2026-04-22): BatchProcess extracted from vault_user
  //   into standalone vault_batcher (4 fold loops + OrderDatum/OrderRedeemer
  //   decode + list.unique + R51/R52 anti-leak invariants no longer
  //   pressure vault_user's bytecode budget; vault_user also drops its
  //   keeper_stake_hash compile-time param because Deposit + Withdraw
  //   are both permissionless).
  userStakeHash: string;
  keeperHotStakeHash: string;
  batcherStakeHash: string;
  swapAdaStakeHash: string;
  protocolStakeHash: string;
  recallStakeHash: string;
  liqwidStakeHash: string;
  govPolicyStakeHash: string;
  govEmergencyStakeHash: string;
  adminDeployStakeHash: string;

  vaultProxyHash: string;
  orderScriptHash: string;
  vusdcxPolicy: string;
  multisigGovHash: string;
  registryHash: string;

  // Phase 77 §B@launch=1 SwapAdapter. Parameterized on governance
  // anchors only (A2 publish handler requirement — see
  // minswap_v2_adapter.ak header). Referenced by datumBuilders.ts
  // as `minswapV2AdapterHash` for the Registry swap_adapter_hashes
  // whitelist initial entry.
  minswapV2AdapterHash: string;

  scriptsApplied: Record<string, { compiledCode: string; size: number }>;
}

interface Blueprint {
  validators: {
    title: string;
    compiledCode: string;
    hash?: string;
    parameters?: { title: string; schema: unknown }[];
  }[];
}

function loadBlueprint(): Blueprint {
  const p = path.join(
    __dirname,
    "..",
    "contracts",
    "plutus.json",
  );
  if (!fs.existsSync(p)) {
    throw new Error(
      `${p} not found. Run \`cd contracts && rm -rf build plutus.json && aiken build\` first.`,
    );
  }
  return JSON.parse(fs.readFileSync(p, "utf8")) as Blueprint;
}

/**
 * Look up a validator's `compiledCode` by its title. Aiken emits the
 * same script under multiple titles (e.g., `vault_core.vault_core.withdraw`
 * + `vault_core.vault_core.else`) — they have the same compiledCode, so
 * we pick any. Throws if not found.
 */
function getCompiledCode(bp: Blueprint, titlePrefix: string): string {
  const match = bp.validators.find((v) => v.title.startsWith(titlePrefix + "."));
  if (!match) {
    const available = bp.validators.map((v) => v.title).join(", ");
    throw new Error(
      `Validator title "${titlePrefix}" not found in plutus.json.\nAvailable: ${available}`,
    );
  }
  return match.compiledCode;
}

/**
 * Apply Plutus parameters and return both the applied Script (for the
 * Lucid caller) and its validator script hash (for subsequent param
 * applications). Parameters are passed as Aiken-Data values — callers
 * must construct them per the validator's parameter schema.
 *
 * `scriptType` selects how the hash is computed: "spend" / "withdraw" /
 * "mint" use the same `validatorToScriptHash` under the hood; `mintingPolicyToId`
 * is a synonym exposed by Lucid for minting scripts.
 */
function applyAndHash(
  compiledCode: string,
  params: unknown[],
  type: "PlutusV3",
): { appliedCbor: string; hash: string; size: number } {
  const appliedCbor = applyParamsToScript(compiledCode, params as Data[]);
  const script: Script = { type, script: appliedCbor };
  const hash = validatorToScriptHash(script);
  const size = Math.floor(appliedCbor.length / 2);
  return { appliedCbor, hash, size };
}

/**
 * Compile-time UTXO-reference encoding: Aiken `OutputReference` is
 * `Constr(0, [Constr(0, [transaction_id_bytes]), output_index_int])`.
 *
 * Different Plutus versions represent the TX id wrapper differently —
 * PlutusV3 uses `Constr(0, [hex_bytes])` for TransactionId. Mirror the
 * same structure used at compile time in the Aiken source.
 */
function encodeUtxoRef(ref: UtxoRef): Data {
  const txIdBytes = ref.txHash;
  return new (require("@lucid-evolution/lucid").Constr)(0, [
    txIdBytes,
    BigInt(ref.outputIndex),
  ]) as unknown as Data;
}

function encodeString(hex: string): Data {
  return hex as unknown as Data;
}

export function compile(
  network: NetworkName,
  utxoRefs: UtxoRefsInput,
): CompiledHashes {
  const cfg = loadConfig(network);
  const bp = loadBlueprint();

  console.log(`\n=== V1 compile — ${network} ===`);
  console.log(summarizeConfig(cfg));

  // -- Pass 0: NFT mint policies (parameterised by UTxO ref + name) --
  const vaultNft = applyAndHash(
    getCompiledCode(bp, "vault_nft.vault_nft"),
    [encodeUtxoRef(utxoRefs.vaultNft)],
    "PlutusV3",
  );
  const govNft = applyAndHash(
    getCompiledCode(bp, "governance_nft.governance_nft"),
    [encodeUtxoRef(utxoRefs.governanceNft), encodeString(cfg.governance.governanceNftAssetName)],
    "PlutusV3",
  );
  const regAuthNft = applyAndHash(
    getCompiledCode(bp, "registry_auth_nft.registry_auth_nft"),
    [encodeUtxoRef(utxoRefs.registryAuthNft), encodeString(cfg.governance.registryAuthAssetName)],
    "PlutusV3",
  );

  // -- Pass 1: keeper_stake_script (depends on gov NFT identity) --
  const keeperStakeScript = applyAndHash(
    getCompiledCode(bp, "keeper_stake_script.keeper_stake_script"),
    [encodeString(govNft.hash), encodeString(cfg.governance.governanceNftAssetName)],
    "PlutusV3",
  );

  // -- Pass 1: treasury (depends on deposit-token identity) --
  const treasury = applyAndHash(
    getCompiledCode(bp, "treasury.treasury"),
    [encodeString(cfg.depositToken.policy), encodeString(cfg.depositToken.name)],
    "PlutusV3",
  );

  // -- Pass 2: six staking validators (all depend on gov NFT identity
  // for A2 publish; keeper-authorized ones depend on keeper_stake_hash;
  // vault_keeper_hot also binds treasury for Compound fee split). --
  //
  // §5.4 P1 split (2026-04-22): vault_core → vault_user + vault_keeper_hot.
  // §5.4 Phase 73 split (2026-04-21): vault_admin → vault_gov_policy +
  //   vault_gov_emergency.
  //
  // Each of the six staking validators carries its own `publish` handler
  // (A2 ActDeregisterStake) so the 2 ADA Cardano stake registration
  // deposit for every stake credential is reclaimable via governance
  // deregister at sunset.

  // vault_user: (gov_nft_policy, gov_nft_name)
  //   Phase 77d: keeper_stake_hash dropped — Deposit + Withdraw are
  //   permissionless; BatchProcess moved to vault_batcher.
  const vaultUser = applyAndHash(
    getCompiledCode(bp, "vault_user.vault_user"),
    [
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  // vault_keeper_hot: (keeper_stake_hash, treasury_hash,
  //                    gov_nft_policy, gov_nft_name)
  const vaultKeeperHot = applyAndHash(
    getCompiledCode(bp, "vault_keeper_hot.vault_keeper_hot"),
    [
      encodeString(keeperStakeScript.hash),
      encodeString(treasury.hash),
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  // vault_batcher: (keeper_stake_hash, gov_nft_policy, gov_nft_name)
  //   Phase 77d split from vault_user. Holds BatchProcess only —
  //   the 4 fold loops + OrderDatum/OrderRedeemer decode + list.unique
  //   + R51/R52 anti-leak invariants no longer pressure vault_user's
  //   bytecode budget.
  const vaultBatcher = applyAndHash(
    getCompiledCode(bp, "vault_batcher.vault_batcher"),
    [
      encodeString(keeperStakeScript.hash),
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  // vault_swap_ada: (keeper_stake_hash, gov_nft_policy, gov_nft_name)
  //   Phase 77b split from vault_keeper_hot. Holds SwapAda only —
  //   the §5.4 P5 dual-feed oracle reader + registry 6-tuple read
  //   machinery no longer pressures Compound's host.
  const vaultSwapAda = applyAndHash(
    getCompiledCode(bp, "vault_swap_ada.vault_swap_ada"),
    [
      encodeString(keeperStakeScript.hash),
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  // vault_protocol: (keeper_stake_hash, gov_nft_policy, gov_nft_name)
  //   Phase 77: slimmed to DeployToProtocol only (plus publish/A2);
  //   RecallFromProtocol + MergeUtxo moved to vault_recall.
  const vaultProtocol = applyAndHash(
    getCompiledCode(bp, "vault_protocol.vault_protocol"),
    [
      encodeString(keeperStakeScript.hash),
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  // vault_recall: (keeper_stake_hash, gov_nft_policy, gov_nft_name)
  //   Phase 77 split from vault_protocol for bytecode headroom —
  //   carries RecallFromProtocol + MergeUtxo + A2 publish handler.
  const vaultRecall = applyAndHash(
    getCompiledCode(bp, "vault_recall.vault_recall"),
    [
      encodeString(keeperStakeScript.hash),
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  // vault_liqwid: (keeper_stake_hash, gov_nft_policy, gov_nft_name)
  const vaultLiqwid = applyAndHash(
    getCompiledCode(bp, "vault_liqwid.vault_liqwid"),
    [
      encodeString(keeperStakeScript.hash),
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  // vault_gov_policy: (gov_nft_policy, gov_nft_name)
  //   — UpdateStrategy / UpdateFee / UpdateFeeSplit / UpdateSlippagePolicy
  const vaultGovPolicy = applyAndHash(
    getCompiledCode(bp, "vault_gov_policy.vault_gov_policy"),
    [
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  // vault_gov_emergency: (gov_nft_policy, gov_nft_name)
  //   — EmergencyWithdraw only (AdminDeployNonDeposit moved to
  //     vault_admin_deploy in Phase 77c).
  const vaultGovEmergency = applyAndHash(
    getCompiledCode(bp, "vault_gov_emergency.vault_gov_emergency"),
    [
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  // vault_admin_deploy: (gov_nft_policy, gov_nft_name)
  //   Phase 77c split from vault_gov_emergency. Holds
  //   AdminDeployNonDeposit only — SwapAdapter dispatch +
  //   destination-whitelist check + 6-tuple registry read no longer
  //   pressure EmergencyWithdraw's host.
  const vaultAdminDeploy = applyAndHash(
    getCompiledCode(bp, "vault_admin_deploy.vault_admin_deploy"),
    [
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  // -- Pass 3: vault_proxy depends on ALL ten stake hashes + vault_nft_policy.
  // ProxyRedeemer has 10 routes matching:
  //   UseUser / UseKeeperHot / UseSwapAda / UseProtocol / UseRecall /
  //   UseLiqwid / UseGovPolicy / UseGovEmergency / UseAdminDeploy /
  //   UseBatcher
  //
  // vault_proxy's compile-time parameter order (from vault_proxy.ak,
  // post Phase 77b/77c/77d):
  //   (user_stake_hash, keeper_hot_stake_hash, swap_ada_stake_hash,
  //    protocol_stake_hash, recall_stake_hash, liqwid_stake_hash,
  //    gov_policy_stake_hash, gov_emergency_stake_hash,
  //    admin_deploy_stake_hash, batcher_stake_hash, vault_nft_policy)
  const vaultProxy = applyAndHash(
    getCompiledCode(bp, "vault_proxy.vault_proxy"),
    [
      encodeString(vaultUser.hash),
      encodeString(vaultKeeperHot.hash),
      encodeString(vaultSwapAda.hash),
      encodeString(vaultProtocol.hash),
      encodeString(vaultRecall.hash),
      encodeString(vaultLiqwid.hash),
      encodeString(vaultGovPolicy.hash),
      encodeString(vaultGovEmergency.hash),
      encodeString(vaultAdminDeploy.hash),
      encodeString(vaultBatcher.hash),
      encodeString(vaultNft.hash),
    ],
    "PlutusV3",
  );

  // -- Pass 4: order + vusdcx (depend on vault_proxy hash + vault_nft_policy) --
  const order = applyAndHash(
    getCompiledCode(bp, "order.order"),
    [encodeString(vaultProxy.hash), encodeString(vaultNft.hash)],
    "PlutusV3",
  );
  const vusdcx = applyAndHash(
    getCompiledCode(bp, "vusdcx.vusdcx"),
    [encodeString(vaultProxy.hash), encodeString(vaultNft.hash)],
    "PlutusV3",
  );

  // -- Pass 5: multisig_gov (5 params) --
  const multisigGov = applyAndHash(
    getCompiledCode(bp, "multisig_gov.multisig_gov"),
    [
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
      encodeString(cfg.depositToken.policy),
      encodeString(cfg.depositToken.name),
      encodeString(treasury.hash),
    ],
    "PlutusV3",
  );

  // -- Pass 5: registry (unparameterised) --
  const registryCode = getCompiledCode(bp, "registry.registry");
  const registry = {
    appliedCbor: registryCode,
    hash: validatorToScriptHash({ type: "PlutusV3", script: registryCode }),
    size: Math.floor(registryCode.length / 2),
  };

  // -- Pass 6: minswap_v2_adapter (gov_nft_policy, gov_nft_name) --
  //   Phase 77 SwapAdapter. Parameterized on governance anchors
  //   solely to enable the A2 publish handler (stake-deposit
  //   recovery — see minswap_v2_adapter.ak header). Registry's
  //   swap_adapter_hashes whitelist pins this hash at V1 launch;
  //   governance may add more adapter hashes via UpdateRegistry
  //   (14-day timelock) post-launch.
  const minswapV2Adapter = applyAndHash(
    getCompiledCode(bp, "minswap_v2_adapter.minswap_v2_adapter"),
    [
      encodeString(govNft.hash),
      encodeString(cfg.governance.governanceNftAssetName),
    ],
    "PlutusV3",
  );

  const result: CompiledHashes = {
    network,
    compiledAt: new Date().toISOString(),
    utxoRefs,
    vaultNftPolicy: vaultNft.hash,
    governanceNftPolicy: govNft.hash,
    registryAuthPolicy: regAuthNft.hash,
    governanceNftName: cfg.governance.governanceNftAssetName,
    registryAuthName: cfg.governance.registryAuthAssetName,
    keeperStakeHash: keeperStakeScript.hash,
    treasuryHash: treasury.hash,
    userStakeHash: vaultUser.hash,
    keeperHotStakeHash: vaultKeeperHot.hash,
    batcherStakeHash: vaultBatcher.hash,
    swapAdaStakeHash: vaultSwapAda.hash,
    protocolStakeHash: vaultProtocol.hash,
    recallStakeHash: vaultRecall.hash,
    liqwidStakeHash: vaultLiqwid.hash,
    govPolicyStakeHash: vaultGovPolicy.hash,
    govEmergencyStakeHash: vaultGovEmergency.hash,
    adminDeployStakeHash: vaultAdminDeploy.hash,
    vaultProxyHash: vaultProxy.hash,
    orderScriptHash: order.hash,
    vusdcxPolicy: vusdcx.hash,
    multisigGovHash: multisigGov.hash,
    registryHash: registry.hash,
    minswapV2AdapterHash: minswapV2Adapter.hash,
    scriptsApplied: {
      vaultNft: { compiledCode: vaultNft.appliedCbor, size: vaultNft.size },
      governanceNft: { compiledCode: govNft.appliedCbor, size: govNft.size },
      registryAuthNft: { compiledCode: regAuthNft.appliedCbor, size: regAuthNft.size },
      keeperStakeScript: { compiledCode: keeperStakeScript.appliedCbor, size: keeperStakeScript.size },
      treasury: { compiledCode: treasury.appliedCbor, size: treasury.size },
      vaultUser: { compiledCode: vaultUser.appliedCbor, size: vaultUser.size },
      vaultKeeperHot: { compiledCode: vaultKeeperHot.appliedCbor, size: vaultKeeperHot.size },
      vaultBatcher: { compiledCode: vaultBatcher.appliedCbor, size: vaultBatcher.size },
      vaultSwapAda: { compiledCode: vaultSwapAda.appliedCbor, size: vaultSwapAda.size },
      vaultProtocol: { compiledCode: vaultProtocol.appliedCbor, size: vaultProtocol.size },
      vaultRecall: { compiledCode: vaultRecall.appliedCbor, size: vaultRecall.size },
      vaultLiqwid: { compiledCode: vaultLiqwid.appliedCbor, size: vaultLiqwid.size },
      vaultGovPolicy: { compiledCode: vaultGovPolicy.appliedCbor, size: vaultGovPolicy.size },
      vaultGovEmergency: { compiledCode: vaultGovEmergency.appliedCbor, size: vaultGovEmergency.size },
      vaultAdminDeploy: { compiledCode: vaultAdminDeploy.appliedCbor, size: vaultAdminDeploy.size },
      vaultProxy: { compiledCode: vaultProxy.appliedCbor, size: vaultProxy.size },
      order: { compiledCode: order.appliedCbor, size: order.size },
      vusdcx: { compiledCode: vusdcx.appliedCbor, size: vusdcx.size },
      multisigGov: { compiledCode: multisigGov.appliedCbor, size: multisigGov.size },
      registry: { compiledCode: registry.appliedCbor, size: registry.size },
      minswapV2Adapter: { compiledCode: minswapV2Adapter.appliedCbor, size: minswapV2Adapter.size },
    },
  };

  return result;
}

// ---- CLI entry point ----
if (require.main === module) {
  const args = process.argv.slice(2);
  let network: NetworkName = "Preprod";
  let utxoRefsPath: string | undefined;
  let output: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--network" && i + 1 < args.length) {
      const n = args[++i];
      if (n !== "Preprod" && n !== "Mainnet") {
        throw new Error(`--network must be Preprod or Mainnet (got ${n})`);
      }
      network = n;
    } else if (a === "--utxoRefs" && i + 1 < args.length) {
      utxoRefsPath = args[++i];
    } else if (a === "--output" && i + 1 < args.length) {
      output = args[++i];
    } else if (a === "--help" || a === "-h") {
      console.log(`
Usage: npx tsx deploy/compile.ts [options]

Options:
  --network <Preprod|Mainnet>   Network to compile for (default: Preprod)
  --utxoRefs <path>             JSON file with 3 UTxO refs for NFT mints
                                (required; see example below)
  --output <path>               Where to write compiled-hashes.json
                                (default: deploy/state/<network>-hashes.json)
  -h, --help                    Show this help

utxoRefs JSON format:
  {
    "vaultNft":        { "txHash": "abc…64hex", "outputIndex": 0 },
    "governanceNft":   { "txHash": "def…64hex", "outputIndex": 1 },
    "registryAuthNft": { "txHash": "def…64hex", "outputIndex": 2 }
  }

If you don't yet know which UTxOs you'll use, run the deploy script with
--dry-run — it will query your wallet and pick 3 fresh UTxOs automatically.
`);
      process.exit(0);
    }
  }

  if (!utxoRefsPath) {
    console.error("--utxoRefs is required. Try --help for details.");
    process.exit(1);
  }

  const utxoRefs = JSON.parse(fs.readFileSync(utxoRefsPath, "utf8")) as UtxoRefsInput;
  const compiled = compile(network, utxoRefs);

  const outPath =
    output ??
    path.join(
      __dirname,
      "state",
      `${network.toLowerCase()}-hashes.json`,
    );
  const outDir = path.dirname(outPath);
  if (!fs.existsSync(outDir)) {
    fs.mkdirSync(outDir, { recursive: true });
  }

  // Strip scriptsApplied from the human-visible output — the compiled
  // CBOR is noisy; operators usually just want the hash table.
  const summary = {
    ...compiled,
    scriptsApplied: Object.fromEntries(
      Object.entries(compiled.scriptsApplied).map(([k, v]) => [
        k,
        { size: v.size, cborPreview: v.compiledCode.slice(0, 40) + "…" },
      ]),
    ),
  };
  fs.writeFileSync(outPath, JSON.stringify(summary, null, 2) + "\n");
  fs.writeFileSync(
    outPath.replace(/\.json$/, "-full.json"),
    JSON.stringify(compiled, null, 2) + "\n",
  );

  console.log(`\nWrote summary to ${outPath}`);
  console.log(`Wrote full (with CBOR) to ${outPath.replace(/\.json$/, "-full.json")}`);
  console.log("\n=== Compiled hashes ===");
  for (const k of [
    "vaultNftPolicy",
    "governanceNftPolicy",
    "registryAuthPolicy",
    "keeperStakeHash",
    "treasuryHash",
    "userStakeHash",
    "keeperHotStakeHash",
    "batcherStakeHash",
    "swapAdaStakeHash",
    "protocolStakeHash",
    "recallStakeHash",
    "liqwidStakeHash",
    "govPolicyStakeHash",
    "govEmergencyStakeHash",
    "adminDeployStakeHash",
    "vaultProxyHash",
    "orderScriptHash",
    "vusdcxPolicy",
    "multisigGovHash",
    "registryHash",
    "minswapV2AdapterHash",
  ] as const) {
    console.log(`  ${k.padEnd(28)} ${compiled[k]}`);
  }
  console.log("\n=== Sizes (applied) ===");
  for (const [k, v] of Object.entries(compiled.scriptsApplied)) {
    console.log(`  ${k.padEnd(24)} ${v.size.toString().padStart(6)} B`);
  }
}
