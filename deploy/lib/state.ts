/**
 * Deploy ceremony state checkpoint.
 *
 * The ceremony writes state to `deploy/state/<network>-<release_tag>.json`
 * after every successful TX. Reruns resume from the last checkpoint so
 * partial failures do not force restarting from zero.
 *
 * Ceremony steps each have a canonical key. If a step's key is in the
 * saved state, the loader reads its payload and skips re-execution.
 *
 * State file is human-readable JSON — if something goes sideways during
 * a mainnet ceremony, an operator can inspect it directly and decide
 * whether to advance manually or drop state and retry.
 */
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import type { NetworkName } from "./config.js";

// ESM shim for __dirname (tsx/Node.js ESM doesn't expose it).
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export interface MintRecord {
  txHash: string;
  utxoRef: { txHash: string; outputIndex: number };
  policyId: string;
  assetName: string;
}

export interface RefScriptRecord {
  txHash: string;
  outputIndex: number;
  scriptHash: string;
  sizeBytes: number;
  minAda: string;
}

export interface StateUtxoRecord {
  txHash: string;
  outputIndex: number;
  address: string;
}

export interface CeremonyState {
  network: NetworkName;
  releaseTag: string;
  startedAt: string;
  lastUpdatedAt: string;

  // Pass 0: NFT mints (each tied to a specific input UTXO ref)
  mints: {
    vaultNft?: MintRecord;
    governanceNft?: MintRecord;
    registryAuthNft?: MintRecord;
  };

  // Compiled blueprint hashes — populated by compile.ts before any TX.
  // Post Phase 77/77b/77c/77d this covers 17 logic validators + 3 mint-only
  // NFT policies + 1 DEX adapter script — 21 on-chain hashes (vaultNftPolicy
  // counts once, minswapV2AdapterHash counts as the SwapAdapter).
  hashes?: {
    vaultNftPolicy: string;
    governanceNftPolicy: string;
    registryAuthPolicy: string;
    keeperStakeHash: string;
    treasuryHash: string;
    userStakeHash: string;
    keeperHotStakeHash: string;
    /// Phase 77d: BatchProcess extracted from vault_user.
    batcherStakeHash: string;
    /// Phase 77b: SwapAda extracted from vault_keeper_hot.
    swapAdaStakeHash: string;
    protocolStakeHash: string;
    /// Phase 77: vault_recall split from vault_protocol.
    recallStakeHash: string;
    liqwidStakeHash: string;
    govPolicyStakeHash: string;
    govEmergencyStakeHash: string;
    /// Phase 77c: AdminDeployNonDeposit extracted from vault_gov_emergency.
    adminDeployStakeHash: string;
    vaultProxyHash: string;
    orderScriptHash: string;
    vusdcxPolicy: string;
    multisigGovHash: string;
    registryHash: string;
    governanceNftName: string;
    registryAuthName: string;
    /// §B@launch=1: Minswap V2 SwapAdapter hash. V1 launches with this as
    /// the sole entry in `registry.swap_adapter_hashes`.
    minswapV2AdapterHash: string;
  };

  // Pass 1: ref script publications (one entry per validator).
  // Post Phase 77:  +vaultRecall (split from vaultProtocol)
  //                 +minswapV2Adapter (§B@launch=1 SwapAdapter)
  // Post Phase 77b: +vaultSwapAda (SwapAda extracted from vaultKeeperHot)
  // Post Phase 77c: +vaultAdminDeploy (AdminDeployNonDeposit extracted
  //                  from vaultGovEmergency)
  // Post Phase 77d: +vaultBatcher (BatchProcess extracted from vaultUser;
  //                  vaultUser loses its keeper_stake_hash param)
  // → 18 ref scripts total.
  refScripts: {
    vaultProxy?: RefScriptRecord;
    vaultUser?: RefScriptRecord;
    vaultKeeperHot?: RefScriptRecord;
    vaultBatcher?: RefScriptRecord;
    vaultSwapAda?: RefScriptRecord;
    vaultProtocol?: RefScriptRecord;
    vaultRecall?: RefScriptRecord;
    vaultLiqwid?: RefScriptRecord;
    vaultGovPolicy?: RefScriptRecord;
    vaultGovEmergency?: RefScriptRecord;
    vaultAdminDeploy?: RefScriptRecord;
    keeperStakeScript?: RefScriptRecord;
    treasury?: RefScriptRecord;
    multisigGov?: RefScriptRecord;
    registry?: RefScriptRecord;
    order?: RefScriptRecord;
    vusdcx?: RefScriptRecord;
    minswapV2Adapter?: RefScriptRecord;
  };

  // Pass 2: initial state UTXOs
  stateUtxos: {
    registry?: StateUtxoRecord;
    treasury?: StateUtxoRecord;
    keeperAuth?: StateUtxoRecord;
    governance?: StateUtxoRecord;
    vault?: StateUtxoRecord;
  };

  // Stake credential registrations. Post Phase 77 + 77b/77c/77d there are
  // 12 credentials that carry A2 publish handlers and therefore need
  // register.Stake:
  //   vault_user / vault_keeper_hot / vault_batcher / vault_swap_ada /
  //   vault_protocol / vault_recall / vault_liqwid / vault_gov_policy /
  //   vault_gov_emergency / vault_admin_deploy / keeper_stake_script /
  //   minswap_v2_adapter (SwapAdapter).
  // `txHash` is "preexisting" if the stake credential was already
  // registered on-chain when the ceremony reached this step (idempotent
  // re-runs don't waste 2 ADA deposits).
  stakeRegistrations?: {
    [target: string]: {
      target: string;
      rewardAddr: string;
      stakeHash: string;
      txHash: string;
    };
  };
}

function stateDir(): string {
  const d = path.join(__dirname, "..", "state");
  if (!fs.existsSync(d)) {
    fs.mkdirSync(d, { recursive: true });
  }
  return d;
}

function statePath(network: NetworkName, releaseTag: string): string {
  const fname = `${network.toLowerCase()}-${releaseTag}.json`;
  return path.join(stateDir(), fname);
}

export function loadState(
  network: NetworkName,
  releaseTag: string,
): CeremonyState {
  const p = statePath(network, releaseTag);
  if (!fs.existsSync(p)) {
    const fresh: CeremonyState = {
      network,
      releaseTag,
      startedAt: new Date().toISOString(),
      lastUpdatedAt: new Date().toISOString(),
      mints: {},
      refScripts: {},
      stateUtxos: {},
      stakeRegistrations: {},
    };
    return fresh;
  }
  const raw = fs.readFileSync(p, "utf8");
  const parsed = JSON.parse(raw) as CeremonyState;
  if (parsed.network !== network) {
    throw new Error(
      `State file ${p} says network=${parsed.network} but loader was asked for ${network} — refusing to mix networks`,
    );
  }
  return parsed;
}

export function saveState(state: CeremonyState): void {
  state.lastUpdatedAt = new Date().toISOString();
  const p = statePath(state.network, state.releaseTag);
  fs.writeFileSync(p, JSON.stringify(state, null, 2) + "\n");
}

/**
 * Reset state (remove the checkpoint file). Should only be used when
 * the operator has decided that restarting from scratch is safer than
 * resuming — e.g., when an NFT mint failed in a way that makes the
 * previously-picked UTXO ref unusable.
 */
export function resetState(
  network: NetworkName,
  releaseTag: string,
): void {
  const p = statePath(network, releaseTag);
  if (fs.existsSync(p)) {
    const backup = p.replace(/\.json$/, `.reset-${Date.now()}.json`);
    fs.renameSync(p, backup);
    console.log(`State backed up to ${backup} and reset`);
  }
}
