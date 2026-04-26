/**
 * Ambient module + global declarations for deploy/ tooling.
 *
 * These tools are designed to run in the operator's environment, where
 * `node_modules` is installed alongside `optivaults-reference`. This
 * `protocol` repo deliberately does NOT carry `package.json` /
 * `node_modules` / `package-lock.json` to stay focused on the protocol
 * layer (smart contracts + spec + docs).
 *
 * The declarations below let the IDE type-check the deploy/ TS sources
 * without complaining about missing module resolution. Operators who
 * want full type-checking + autocomplete should install the real
 * dependencies (see deploy/README.md).
 */

// ─── External npm modules ────────────────────────────────────────────
declare module "@lucid-evolution/lucid";
declare module "@lucid-evolution/utils";
declare module "@noble/hashes/blake2b";
declare module "bip39";
declare module "dotenv";

// ─── Node.js built-ins (loose; install @types/node for full types) ───
declare module "fs";
declare module "path";
declare module "url";
declare module "net";
declare module "node:net";
declare module "child_process";

// ─── Node.js globals ─────────────────────────────────────────────────
declare const process: any;
declare const Buffer: any;
declare const __dirname: string;
declare const __filename: string;
