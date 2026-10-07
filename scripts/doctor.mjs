import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { requireStateRoot, requireVaultRoot, isWriteEnabled } from "../lib/runtime-config.mjs";

const vaultRoot = requireVaultRoot();
const stateRoot = requireStateRoot();
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const checks = [
  ["root dependencies", path.join(repoRoot, "node_modules")],
  ["Calendar dependencies", path.join(repoRoot, "Calendar", "node_modules")]
].map(([name, target]) => ({ name, ok: fs.existsSync(target), target }));

const result = {
  ok: checks.every((check) => check.ok),
  mode: isWriteEnabled() ? "read-write" : "read-only",
  writesEnabled: isWriteEnabled(),
  authority: { vault: vaultRoot, localState: stateRoot, vaultIsAuthoritative: true },
  checks
};

console.log(JSON.stringify(result, null, 2));
if (!result.ok) process.exitCode = 1;
