import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const pidPath = path.join(root, "email.preview.pid");

/**
 * Reads the stored preview PID.
 * @returns {number | null} Process id or null.
 */
function readPid() {
  try {
    const raw = fs.readFileSync(pidPath, "utf8").trim();
    const pid = Number.parseInt(raw, 10);
    return Number.isFinite(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

/**
 * Removes the PID file if present.
 * @returns {void}
 */
function clearPid() {
  try {
    fs.unlinkSync(pidPath);
  } catch {
    // Already absent.
  }
}

const pid = readPid();
if (!pid) {
  clearPid();
  console.log("Email preview server is not running.");
  process.exit(0);
}

try {
  process.kill(pid, "SIGTERM");
  clearPid();
  console.log(`Stopped Email preview server (${pid}).`);
} catch (error) {
  clearPid();
  console.log(`Email preview PID was stale (${pid}): ${error.message}`);
}
