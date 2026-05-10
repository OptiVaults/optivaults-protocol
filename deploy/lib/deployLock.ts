/**
 * Deploy ceremony process lock.
 *
 * Prevents two `deploy.ts` invocations from racing on the same
 * `(network, releaseTag)` pair. Without this lock, concurrent runs
 * race on:
 *   - PHASE 0 NFT bootstrap UTxO selection (each picks the same UTxO,
 *     mint TXs collide, only first lands → orphan ref-script ADA)
 *   - PHASE 3 ref-script publication (both submit ref-script TXs in
 *     parallel; state file overwrites lose the loser's txHash)
 *   - PHASE 4 stake registration / state UTxO init (multi-asset
 *     change UTxOs corrupt and block downstream coin selection)
 *
 * Lock file: `deploy/state/.deploy.lock.<network>-<releaseTag>.json`
 *   Content: `{ pid, hostname, startedAt, releaseTag, network }`
 *
 * Acquisition strategy:
 *   1. Try `O_EXCL` create (atomic file existence guard).
 *   2. If file exists, parse it + check whether the recorded PID is
 *      still alive on this host (`process.kill(pid, 0)` no-op).
 *   3. If alive on this host: refuse (another instance running).
 *   4. If dead OR on a different host (cross-host race not handled —
 *      operator must coordinate manually): force-clear + re-acquire,
 *      logging a warning so the operator sees the stale-lock recovery.
 *
 * Release: unlink on every exit path — `process.on('exit')` for
 * normal termination, `SIGINT` / `SIGTERM` for ctrl-C / kill, plus
 * an explicit call from the deploy.ts main() success / catch paths.
 *
 * Mainnet implication: this is the same defence that prevents an
 * operator from accidentally launching a second mainnet ceremony
 * while the first is still running (e.g. tab-switched terminal,
 * forgotten background job, retry-on-spurious-error). On Preprod the
 * cost is wasted ADA on orphan refs; on mainnet the same race could
 * leak operator-controlled funds or burn deploy capital that
 * subsequent recovery cannot recover within the timelock window.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const STATE_DIR = path.resolve(__dirname, "..", "state");

interface LockBody {
  pid: number;
  hostname: string;
  startedAt: string;
  releaseTag: string;
  network: string;
  argv: string[];
}

function lockPath(network: string, releaseTag: string): string {
  return path.join(STATE_DIR, `.deploy.lock.${network.toLowerCase()}-${releaseTag}.json`);
}

function isPidAlive(pid: number): boolean {
  try {
    // Sending signal 0 doesn't actually deliver a signal — it just
    // returns true if the process exists, false if not.
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

let registeredHandlers = false;
let acquiredPath: string | null = null;

function registerExitHandlers(): void {
  if (registeredHandlers) return;
  registeredHandlers = true;
  const release = () => {
    if (acquiredPath && fs.existsSync(acquiredPath)) {
      try { fs.unlinkSync(acquiredPath); } catch { /* ignore */ }
    }
  };
  process.on("exit", release);
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) {
    process.on(sig, () => {
      release();
      process.exit(130);
    });
  }
}

/**
 * Acquire the deploy lock for `(network, releaseTag)`. Throws if a
 * live instance already holds it; auto-recovers from a stale lock
 * left by a crashed prior run.
 */
export function acquireLock(network: string, releaseTag: string): void {
  if (!fs.existsSync(STATE_DIR)) {
    fs.mkdirSync(STATE_DIR, { recursive: true });
  }
  const lp = lockPath(network, releaseTag);
  const body: LockBody = {
    pid: process.pid,
    hostname: os.hostname(),
    startedAt: new Date().toISOString(),
    releaseTag,
    network,
    argv: process.argv.slice(2),
  };
  const payload = JSON.stringify(body, null, 2);

  // Fast path: file does not exist yet — atomic O_EXCL create.
  try {
    const fd = fs.openSync(lp, "wx");
    fs.writeSync(fd, payload);
    fs.closeSync(fd);
    acquiredPath = lp;
    registerExitHandlers();
    return;
  } catch (e: any) {
    if (e?.code !== "EEXIST") throw e;
  }

  // Lock file exists — parse it + decide whether to break it.
  let existing: LockBody | null = null;
  try {
    existing = JSON.parse(fs.readFileSync(lp, "utf8"));
  } catch {
    // Corrupt lockfile — overwrite.
  }

  if (existing) {
    const sameHost = existing.hostname === os.hostname();
    if (sameHost && isPidAlive(existing.pid)) {
      throw new Error(
        `Another deploy.ts is running (pid ${existing.pid}, started ${existing.startedAt}). ` +
        `Lockfile: ${lp}. ` +
        `If you are sure no other deploy is in flight (e.g. terminal closed), run: ` +
        `rm "${lp}" && retry.`,
      );
    }
    // Stale (dead PID OR different host — different host means another
    // operator is responsible; we log + auto-recover but mainnet operators
    // should coordinate via Discord before getting here).
    process.stderr.write(
      `[deployLock] stale lock for pid ${existing.pid} on ${existing.hostname} ` +
      `(started ${existing.startedAt}) — recovering.\n`,
    );
  }

  // Force write (lock is stale or corrupt).
  fs.writeFileSync(lp, payload);
  acquiredPath = lp;
  registerExitHandlers();
}

/**
 * Explicit release. Idempotent. Safe to call from main() success
 * branch even though exit handlers will also run.
 */
export function releaseLock(): void {
  if (!acquiredPath) return;
  if (fs.existsSync(acquiredPath)) {
    try { fs.unlinkSync(acquiredPath); } catch { /* ignore */ }
  }
  acquiredPath = null;
}
