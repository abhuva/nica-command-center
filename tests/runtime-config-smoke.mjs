import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  isWriteEnabled,
  requireComponentStateDir,
  requireVaultRoot,
  requireWriteEnabled
} from "../lib/runtime-config.mjs";

const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "nica-runtime-config-"));
const vault = path.join(sandbox, "vault");
const state = path.join(sandbox, "state");
fs.mkdirSync(vault);

try {
  delete process.env.NICA_VAULT_ROOT;
  assert.throws(() => requireVaultRoot(), /is required/);
  process.env.NICA_VAULT_ROOT = "relative-vault";
  assert.throws(() => requireVaultRoot(), /absolute path/);

  process.env.NICA_VAULT_ROOT = vault;
  const nestedState = path.join(vault, "state");
  process.env.NICA_STATE_ROOT = nestedState;
  assert.throws(() => requireComponentStateDir("calendar"), /separate directory trees/);
  assert.equal(fs.existsSync(nestedState), false, "invalid nested state root must not be created");

  process.env.NICA_STATE_ROOT = state;
  assert.equal(requireVaultRoot(), fs.realpathSync(vault));
  assert.equal(requireComponentStateDir("calendar"), fs.realpathSync(path.join(state, "calendar")));

  delete process.env.NICA_WRITE_ENABLED;
  assert.equal(isWriteEnabled(), false);
  assert.throws(() => requireWriteEnabled("test operation"), /disabled/);
  process.env.NICA_WRITE_ENABLED = "true";
  assert.equal(isWriteEnabled(), true);
  requireWriteEnabled("test operation");
  console.log("Runtime configuration smoke check OK");
} finally {
  fs.rmSync(sandbox, { recursive: true, force: true });
}
