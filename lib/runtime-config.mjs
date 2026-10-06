import fs from "node:fs";
import path from "node:path";

/**
 * Reads and validates an absolute directory path from the environment.
 * @param {string} name Environment variable name.
 * @param {{create?: boolean}} [options] Validation options.
 * @returns {string} Canonical absolute directory path.
 */
export function requireDirectory(name, { create = false } = {}) {
  const raw = String(process.env[name] || "").trim();
  if (!raw) throw new Error(`${name} is required`);
  if (!path.isAbsolute(raw)) throw new Error(`${name} must be an absolute path`);
  const resolved = path.resolve(raw);
  if (create) fs.mkdirSync(resolved, { recursive: true });
  if (!fs.existsSync(resolved) || !fs.statSync(resolved).isDirectory()) {
    throw new Error(`${name} must identify an existing directory`);
  }
  return fs.realpathSync(resolved);
}

/** @returns {string} Explicit, canonical vault root. */
export function requireVaultRoot() {
  return requireDirectory("NICA_VAULT_ROOT");
}

/**
 * Returns whether neither path contains the other.
 * @param {string} first First absolute path.
 * @param {string} second Second absolute path.
 * @returns {boolean} True when the directory trees are separate.
 */
function areSeparateTrees(first, second) {
  const secondFromFirst = path.relative(first, second);
  const firstFromSecond = path.relative(second, first);
  return (
    secondFromFirst !== "" &&
    firstFromSecond !== "" &&
    (secondFromFirst.startsWith("..") || path.isAbsolute(secondFromFirst)) &&
    (firstFromSecond.startsWith("..") || path.isAbsolute(firstFromSecond))
  );
}

/**
 * Validates and creates the local state root without first writing inside the vault.
 * @returns {string} Canonical state root.
 */
export function requireStateRoot() {
  const vaultRoot = requireVaultRoot();
  const raw = String(process.env.NICA_STATE_ROOT || "").trim();
  if (!raw) throw new Error("NICA_STATE_ROOT is required");
  if (!path.isAbsolute(raw)) throw new Error("NICA_STATE_ROOT must be an absolute path");
  const unresolvedStateRoot = path.resolve(raw);
  if (!areSeparateTrees(vaultRoot, unresolvedStateRoot)) {
    throw new Error("NICA_STATE_ROOT and NICA_VAULT_ROOT must be separate directory trees");
  }
  const stateRoot = requireDirectory("NICA_STATE_ROOT", { create: true });
  if (!areSeparateTrees(vaultRoot, stateRoot)) {
    throw new Error("NICA_STATE_ROOT and NICA_VAULT_ROOT must be separate directory trees");
  }
  return stateRoot;
}

/**
 * Returns an isolated, created state directory for one component.
 * @param {string} component Safe component directory name.
 * @returns {string} Canonical component state directory.
 */
export function requireComponentStateDir(component) {
  if (!/^[a-z0-9-]+$/.test(component)) throw new Error("Invalid state component name");
  const stateRoot = requireStateRoot();
  const componentDir = path.join(stateRoot, component);
  if (fs.existsSync(componentDir) && fs.lstatSync(componentDir).isSymbolicLink()) {
    throw new Error(`State component directory must not be a symbolic link: ${component}`);
  }
  fs.mkdirSync(componentDir, { recursive: true });
  const realComponentDir = fs.realpathSync(componentDir);
  const relativeToState = path.relative(stateRoot, realComponentDir);
  if (relativeToState.startsWith("..") || path.isAbsolute(relativeToState)) {
    throw new Error(`State component directory escaped NICA_STATE_ROOT: ${component}`);
  }
  return realComponentDir;
}

/** @returns {boolean} Whether consequential operations are explicitly enabled. */
export function isWriteEnabled() {
  return String(process.env.NICA_WRITE_ENABLED || "").trim().toLowerCase() === "true";
}

/**
 * Rejects an operation when the candidate is in its default read-only mode.
 * @param {string} operation Human-readable operation name.
 * @returns {void}
 */
export function requireWriteEnabled(operation) {
  if (!isWriteEnabled()) {
    const error = new Error(`${operation} is disabled while NICA_WRITE_ENABLED is not true`);
    error.code = "NICA_READ_ONLY";
    throw error;
  }
}

/**
 * Builds non-sensitive runtime diagnostics.
 * @param {string} component Component name.
 * @param {string} vaultRoot Canonical vault root.
 * @param {string} stateDir Canonical component state directory.
 * @returns {object} Health metadata.
 */
export function runtimeHealth(component, vaultRoot, stateDir) {
  return {
    component,
    mode: isWriteEnabled() ? "read-write" : "read-only",
    writesEnabled: isWriteEnabled(),
    authority: {
      vault: vaultRoot,
      localState: stateDir,
      vaultIsAuthoritative: true
    }
  };
}
