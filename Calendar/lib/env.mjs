import fs from "node:fs";

import path from "node:path";

/**
 * Load Dot Env File.
 * @param {*}
 * @returns {boolean} Whether the file existed and was loaded.
 */
export function loadDotEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return false;
  const raw = fs.readFileSync(filePath, "utf8");
  const lines = raw.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = String(line || "").trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const match = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!match) continue;
    const key = match[1];
    let value = match[2] || "";
    const isDoubleQuoted = value.startsWith('"') && value.endsWith('"');
    const isSingleQuoted = value.startsWith("'") && value.endsWith("'");
    if (!isDoubleQuoted && !isSingleQuoted) {
      const hashIndex = value.indexOf("#");
      if (hashIndex >= 0) value = value.slice(0, hashIndex);
      value = value.trim();
    } else {
      value = value.slice(1, -1);
    }
    if (process.env[key] == null) {
      process.env[key] = value;
    }
  }
  return true;
}

/**
 * Checks whether a path is inside a directory tree.
 * @param {string} root Directory root.
 * @param {string} target Candidate path.
 * @returns {boolean} Whether target is the root or one of its descendants.
 */
function isWithin(root, target) {
  const relative = path.relative(path.resolve(root), path.resolve(target));
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

/**
 * Loads Calendar configuration without mixing an explicit external secret file
 * with a repository-local `.env.local` file.
 * @param {string} calendarDir Absolute Calendar source directory.
 * @returns {{source: "external"|"local"|"defaults", externalFile: string}}
 * Configuration source metadata without secret values.
 */
export function loadCalendarEnvironment(calendarDir) {
  loadDotEnvFile(path.resolve(calendarDir, ".env"));

  const externalFile = String(process.env.NICA_CALENDAR_ENV_FILE || "").trim();
  if (externalFile) {
    if (!path.isAbsolute(externalFile)) {
      throw new Error("NICA_CALENDAR_ENV_FILE must be an absolute path");
    }
    const resolved = path.resolve(externalFile);
    if (!fs.existsSync(resolved) || !fs.statSync(resolved).isFile()) {
      throw new Error("NICA_CALENDAR_ENV_FILE must identify an existing file");
    }
    if (isWithin(calendarDir, resolved)) {
      throw new Error("NICA_CALENDAR_ENV_FILE must be outside the Calendar source directory");
    }
    const vaultRoot = String(process.env.NICA_VAULT_ROOT || "").trim();
    if (vaultRoot && path.isAbsolute(vaultRoot) && isWithin(vaultRoot, resolved)) {
      throw new Error("NICA_CALENDAR_ENV_FILE must be outside the vault");
    }
    loadDotEnvFile(resolved);
    return { source: "external", externalFile: resolved };
  }

  const localFile = path.resolve(calendarDir, ".env.local");
  if (loadDotEnvFile(localFile)) {
    return { source: "local", externalFile: "" };
  }
  return { source: "defaults", externalFile: "" };
}


