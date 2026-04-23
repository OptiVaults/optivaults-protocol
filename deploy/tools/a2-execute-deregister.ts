/**
 * A2 — Execute ActDeregisterStake after timelock.
 *
 * Counterpart to `a2-queue-deregister.ts`. Reads the queued action info
 * from `state.a2.<target>`, waits until `executable_at_ms`, then submits
 * the ExecuteAction TX bundling (a) MultisigGov spend (ExecuteAction
 * redeemer), (b) Cardano Deregister certificate for the target stake
 * credential, (c) continuing MultisigGov output.
 *
 * Usage:
 *   TARGET=vaultAdmin npx tsx deploy/tools/a2-execute-deregister.ts \
 *     --network Preprod --releaseTag v1-a2-preprod
 */
import * as dotenv from "dotenv";
dotenv.config({ path: "keeper/.env" });

import * as fs from "fs";
import * as net from "node:net";
import {
  CML,
  Constr,
  Data,
  Lucid,
  applyParamsToScript,
  paymentCredentialOf,
  validatorToRewardAddress,
} from "@lucid-evolution/lucid";
import type { LucidEvolution, Script, UTxO } from "@lucid-evolution/lucid";
import { createBlockfrostProvider } from "../lib/blockfrostProvider.js";

type Net = "Preprod" | "Mainnet";
type Target =
  | "vaultUser"
  | "vaultKeeperHot"
  | "vaultBatcher"
  | "vaultSwapAda"
  | "vaultProtocol"
  | "vaultRecall"
  | "vaultLiqwid"
  | "vaultGovPolicy"
  | "vaultGovEmergency"
  | "vaultAdminDeploy"
  | "keeperStakeScript"
  | "minswapV2Adapter";

const VALID_TARGETS: Target[] = [
  "vaultUser",
  "vaultKeeperHot",
  "vaultBatcher",
  "vaultSwapAda",
  "vaultProtocol",
  "vaultRecall",
  "vaultLiqwid",
  "vaultGovPolicy",
  "vaultGovEmergency",
  "vaultAdminDeploy",
  "keeperStakeScript",
  "minswapV2Adapter",
];
const ACCOUNTS_TO_SIGN = [0, 1]; // 2 of 3 for threshold=2

interface CliArgs {
  network: Net;
  releaseTag: string;
  target: Target;
}

function parseArgs(): CliArgs {
  const a = process.argv.slice(2);
  let network: Net = "Preprod";
  let releaseTag = "v1-a2-preprod";
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--network") network = a[++i] as Net;
    else if (a[i] === "--releaseTag") releaseTag = a[++i];
  }
  const target = process.env.TARGET as Target | undefined;
  if (!target || !VALID_TARGETS.includes(target)) {
    throw new Error(`TARGET env var must be one of: ${VALID_TARGETS.join(", ")}`);
  }
  return { network, releaseTag, target };
}

async function getMnemonic(sock: string): Promise<string> {
  if (process.env.KEEPER_MNEMONIC) return process.env.KEEPER_MNEMONIC;
  return new Promise((res, rej) => {
    const c = net.createConnection(sock, () => c.write("GET_MNEMONIC"));
    let buf = "";
    c.on("data", (d) => { buf += d.toString(); });
    c.on("end", () => res(buf.startsWith("OK:") ? buf.slice(3).trim() : buf.trim()));
    c.on("error", rej);
    setTimeout(() => rej(new Error("timeout")), 5000);
  });
}

/** Resolve target's applied Script. */
function buildTargetScript(target: Target, state: any, plutus: any): Script {
  const getCode = (title: string) => plutus.validators.find((v: any) => v.title === title)!.compiledCode;
  const keeperStakeHash = state.hashes.keeperStakeHash;
  const treasuryHash = state.hashes.treasuryHash;
  const govPolicy = state.hashes.governanceNftPolicy;
  const govName = state.hashes.governanceNftName;
  switch (target) {
    case "vaultUser":
      // Phase 77d: vault_user dropped keeper_stake_hash param (Deposit +
      // Withdraw are permissionless; BatchProcess moved to vault_batcher).
      return { type: "PlutusV3", script: applyParamsToScript(getCode("vault_user.vault_user.withdraw"), [govPolicy, govName]) };
    case "vaultKeeperHot":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("vault_keeper_hot.vault_keeper_hot.withdraw"), [keeperStakeHash, treasuryHash, govPolicy, govName]) };
    case "vaultBatcher":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("vault_batcher.vault_batcher.withdraw"), [keeperStakeHash, govPolicy, govName]) };
    case "vaultSwapAda":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("vault_swap_ada.vault_swap_ada.withdraw"), [keeperStakeHash, govPolicy, govName]) };
    case "vaultProtocol":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("vault_protocol.vault_protocol.withdraw"), [keeperStakeHash, govPolicy, govName]) };
    case "vaultRecall":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("vault_recall.vault_recall.withdraw"), [keeperStakeHash, govPolicy, govName]) };
    case "vaultLiqwid":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("vault_liqwid.vault_liqwid.withdraw"), [keeperStakeHash, govPolicy, govName]) };
    case "vaultGovPolicy":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("vault_gov_policy.vault_gov_policy.withdraw"), [govPolicy, govName]) };
    case "vaultGovEmergency":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("vault_gov_emergency.vault_gov_emergency.withdraw"), [govPolicy, govName]) };
    case "vaultAdminDeploy":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("vault_admin_deploy.vault_admin_deploy.withdraw"), [govPolicy, govName]) };
    case "keeperStakeScript":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("keeper_stake_script.keeper_stake_script.withdraw"), [govPolicy, govName]) };
    case "minswapV2Adapter":
      return { type: "PlutusV3", script: applyParamsToScript(getCode("minswap_v2_adapter.minswap_v2_adapter.withdraw"), [govPolicy, govName]) };
  }
}

function targetRefScriptLabel(target: Target): string {
  switch (target) {
    case "vaultUser": return "vaultUser";
    case "vaultKeeperHot": return "vaultKeeperHot";
    case "vaultBatcher": return "vaultBatcher";
    case "vaultSwapAda": return "vaultSwapAda";
    case "vaultProtocol": return "vaultProtocol";
    case "vaultRecall": return "vaultRecall";
    case "vaultLiqwid": return "vaultLiqwid";
    case "vaultGovPolicy": return "vaultGovPolicy";
    case "vaultGovEmergency": return "vaultGovEmergency";
    case "vaultAdminDeploy": return "vaultAdminDeploy";
    case "keeperStakeScript": return "keeperStakeScript";
    case "minswapV2Adapter": return "minswapV2Adapter";
  }
}

async function main() {
  const args = parseArgs();
  const bfUrl = args.network === "Preprod"
    ? "https://cardano-preprod.blockfrost.io/api/v0"
    : "https://cardano-mainnet.blockfrost.io/api/v0";
  const bfKey = args.network === "Preprod"
    ? process.env.BLOCKFROST_API_KEY_PREPROD!
    : process.env.BLOCKFROST_API_KEY!;
  if (!bfKey) throw new Error("Missing Blockfrost key");

  const stateFile = `deploy/state/${args.network.toLowerCase()}-${args.releaseTag}.json`;
  const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  const a2 = state.a2?.[args.target];
  if (!a2) throw new Error(`no queued action for target=${args.target} — run a2-queue-deregister.ts first`);
  const { actionId, executableAtMs, expiresAtMs, targetHash } = a2;

  const nowMs = Date.now();
  if (nowMs < executableAtMs) {
    const waitSec = Math.ceil((executableAtMs - nowMs) / 1000);
    throw new Error(`timelock not elapsed: ${waitSec}s (${new Date(executableAtMs).toISOString()}) remaining`);
  }
  if (nowMs > expiresAtMs) throw new Error(`action expired (${new Date(expiresAtMs).toISOString()})`);
  console.log(`executable window: ${new Date(executableAtMs).toISOString()} → ${new Date(expiresAtMs).toISOString()}`);

  const plutus = JSON.parse(fs.readFileSync("contracts/plutus.json", "utf8"));
  const provider = createBlockfrostProvider(bfUrl, bfKey);
  const lucid = await Lucid(provider as any, args.network);
  const sock = process.env.KEY_DAEMON_SOCKET || "/home/chrissoft/claude-code-docker/data/key-daemon-preprod.sock";
  const mnemonic = await getMnemonic(sock);
  lucid.selectWallet.fromSeed(mnemonic);
  const wallet = await lucid.wallet().address();
  console.log(`wallet: ${wallet.slice(0, 30)}…`);

  const govAddr = state.stateUtxos.governance.address;
  const govUtxos = await lucid.utxosAt(govAddr);
  if (govUtxos.length !== 1) throw new Error(`expected 1 gov UTxO, got ${govUtxos.length}`);
  const govIn = govUtxos[0];
  console.log(`gov UTxO: ${govIn.txHash}#${govIn.outputIndex}`);

  // Parse current GovDatum, filter out our action, build new datum
  if (!govIn.datum) throw new Error("gov UTxO has no inline datum");
  const govDatum = Data.from(govIn.datum) as any;
  const fields = govDatum.fields as any[];
  const signers = fields[0] as string[];
  const signerJoinedAt = fields[1] as bigint[];
  const signerLastQualified = fields[2] as bigint[];
  const threshold = fields[3] as bigint;
  const queued = fields[4] as any[];
  const compensationPool = fields[5] as bigint;
  const lastDistributeMs = fields[6] as bigint;
  const distributePeriodMs = fields[7] as bigint;
  const nonce = fields[8] as bigint;
  console.log(`gov nonce: ${nonce}, queued.length: ${queued.length}`);

  const actionIdHex = actionId.toLowerCase();
  const newQueued = queued.filter((q: any) => (q.fields[0] as string).toLowerCase() !== actionIdHex);
  if (newQueued.length === queued.length) {
    // Idempotency (Phase 84 backport from h-emergency-benign): action not in
    // queue. Two possible states:
    //   (a) state.a2.<target>.executedAtMs already set → previously executed
    //       successfully; skip silently (idempotent re-run).
    //   (b) No executedAtMs → either previously cancelled, expired, or state
    //       file diverged from on-chain. Bail with a clear error — the
    //       operator should re-Queue (a2-queue-deregister) to continue.
    const prior = state.a2?.[args.target]?.executedAtMs;
    if (prior) {
      console.log(`\nℹ️  action ${actionIdHex} already executed at ${new Date(prior).toISOString()} — exit idempotent.`);
      return;
    }
    throw new Error(`action_id ${actionIdHex} not found in queue and no executedAtMs in state — already cancelled, expired, or state diverged. Re-run a2-queue-deregister to re-queue.`);
  }

  // ExecuteAction redeemer: Constr(2, [action_id])
  const redeemerExecute = Data.to(new Constr(2, [actionIdHex]) as unknown as Data);

  // Validity range constraints enforced by multisig_gov.ExecuteAction:
  //   lower >= action.executable_at_ms
  //   upper < action.expires_at_ms
  //   upper - lower <= 1 hour (internal-verification width cap)
  // Lower bound: use executable_at_ms + 1s buffer; upper: lower + 30 min.
  // Slot-align both to 1000 ms (Preprod slot length) so Lucid's ms↔slot
  // round-trip is lossless — same fix as the Queue TX learned the hard
  // way (feedback_aiken_lucid_encoding.md #3).
  const slotAlign = (ms: bigint) => (ms / 1000n) * 1000n;
  const rawLower = BigInt(executableAtMs) + 1000n;
  const lowerMs = slotAlign(rawLower);
  const rawUpper = lowerMs + BigInt(30 * 60_000);
  const upperMs = slotAlign(rawUpper);
  if (Number(upperMs) >= expiresAtMs) {
    throw new Error(`upper bound ${upperMs} >= expires_at_ms ${expiresAtMs} — action expired`);
  }

  // Derive which signers we're signing with
  const signerAccountIdx = await deriveSignerAccountIndices(mnemonic, signers);
  const newSignerLastQualified = signers.map((s, i) =>
    ACCOUNTS_TO_SIGN.includes(signerAccountIdx[i]) ? upperMs : signerLastQualified[i],
  );

  const newGovDatum = Data.to(new Constr(0, [
    signers,
    signerJoinedAt,
    newSignerLastQualified,
    threshold,
    newQueued,
    compensationPool,
    lastDistributeMs,
    distributePeriodMs,
    nonce + 1n,
  ]) as unknown as Data);

  // Ref inputs: multisig_gov ref + target validator ref
  const mgRef = state.refScripts.multisigGov;
  const tgtRefLabel = targetRefScriptLabel(args.target);
  const tgtRef = state.refScripts[tgtRefLabel];
  if (!mgRef || !tgtRef) throw new Error("ref scripts missing in state");

  const [mgRefUtxo] = await lucid.utxosByOutRef([{ txHash: mgRef.txHash, outputIndex: mgRef.outputIndex }]);
  const [tgtRefUtxo] = await lucid.utxosByOutRef([{ txHash: tgtRef.txHash, outputIndex: tgtRef.outputIndex }]);
  if (!mgRefUtxo || !tgtRefUtxo) throw new Error("ref script UTxOs not on-chain");

  const targetScript = buildTargetScript(args.target, state, plutus);
  const targetRewardAddr = validatorToRewardAddress(args.network, targetScript);
  console.log(`target reward addr: ${targetRewardAddr.slice(0, 40)}…`);

  // Build TX
  const tx = lucid
    .newTx()
    .collectFrom([govIn], redeemerExecute)
    .readFrom([mgRefUtxo, tgtRefUtxo])
    .deregister.Stake(targetRewardAddr, Data.void())
    .pay.ToAddressWithData(
      govAddr,
      { kind: "inline", value: newGovDatum as unknown as string },
      govIn.assets,
    )
    .validFrom(Number(lowerMs))
    .validTo(Number(upperMs))
    .addSignerKey(signers[0])
    .addSignerKey(signers[1]);

  const completed = await tx.complete();
  const unsignedCbor = completed.toCBOR();

  const signedCbor = await multiSignCbor(unsignedCbor, mnemonic, ACCOUNTS_TO_SIGN);

  const res = await fetch(`${bfUrl}/tx/submit`, {
    method: "POST",
    headers: { "Content-Type": "application/cbor", project_id: bfKey },
    body: Buffer.from(signedCbor, "hex"),
  });
  const body = await res.text();
  if (!res.ok) throw new Error(`submit failed: ${body}`);
  const txHash = body.replace(/"/g, "").trim();
  console.log(`✅ Execute TX submitted: ${txHash}`);
  console.log(`   2 ADA stake deposit refunded for target=${args.target}`);

  state.a2[args.target].executeTx = txHash;
  state.a2[args.target].executedAtMs = nowMs;
  fs.writeFileSync(stateFile, JSON.stringify(state, null, 2) + "\n");
}

async function deriveSignerAccountIndices(mnemonic: string, signers: string[]): Promise<number[]> {
  const { mnemonicToEntropy } = await import("bip39");
  const entropy = mnemonicToEntropy(mnemonic);
  const entropyBytes = new Uint8Array(entropy.match(/.{2}/g)!.map((b) => parseInt(b, 16)));
  const rootKey = CML.Bip32PrivateKey.from_bip39_entropy(entropyBytes, new Uint8Array());
  const indices: number[] = [];
  for (const s of signers) {
    let found = -1;
    for (let a = 0; a < 10; a++) {
      const k = rootKey.derive(0x80000000 + 1852).derive(0x80000000 + 1815).derive(0x80000000 + a).derive(0).derive(0);
      if (k.to_raw_key().to_public().hash().to_hex() === s) { found = a; break; }
    }
    indices.push(found);
  }
  return indices;
}

async function multiSignCbor(unsignedCbor: string, mnemonic: string, accountIndices: number[]): Promise<string> {
  const { mnemonicToEntropy } = await import("bip39");
  const entropy = mnemonicToEntropy(mnemonic);
  const entropyBytes = new Uint8Array(entropy.match(/.{2}/g)!.map((b) => parseInt(b, 16)));
  const rootKey = CML.Bip32PrivateKey.from_bip39_entropy(entropyBytes, new Uint8Array());

  const tx = CML.Transaction.from_cbor_hex(unsignedCbor);
  const body = tx.body();
  const bodyHash = CML.hash_transaction(body);
  const witnessSet = CML.TransactionWitnessSet.from_cbor_hex(tx.witness_set().to_cbor_hex());
  const vkeys = witnessSet.vkeywitnesses() ?? CML.VkeywitnessList.new();

  for (const account of accountIndices) {
    const k = rootKey.derive(0x80000000 + 1852).derive(0x80000000 + 1815).derive(0x80000000 + account).derive(0).derive(0);
    const priv = k.to_raw_key();
    vkeys.add(CML.Vkeywitness.new(priv.to_public(), priv.sign(bodyHash.to_raw_bytes())));
  }
  witnessSet.set_vkeywitnesses(vkeys);

  return CML.Transaction.new(body, witnessSet, true).to_cbor_hex();
}

main().catch((e) => { console.error("[ERROR]", (e as Error).message); if ((e as Error).stack) console.error((e as Error).stack); process.exit(1); });
