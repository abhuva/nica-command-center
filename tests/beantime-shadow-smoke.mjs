import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "nica-beantime-shadow-"));
const vault = path.join(sandbox, "vault");
const state = path.join(sandbox, "state");
const componentState = path.join(state, "homepage");
const configDir = path.join(componentState, "config");
const ledger = path.join(componentState, "beantime", "zeit.beancount");
const timerState = path.join(componentState, "beantime", "state.json");

fs.mkdirSync(path.join(vault, ".obsidian"), { recursive: true });
fs.mkdirSync(configDir, { recursive: true });
fs.writeFileSync(path.join(vault, ".obsidian", "bookmarks.json"), '{"items":[]}\n', "utf8");
fs.writeFileSync(
  path.join(configDir, "settings.local.json"),
  `${JSON.stringify(
    {
      schemaVersion: 1,
      ui: { title: "Synthetic Beantime" },
      modules: {
        bookmarks: { enabled: false },
        clock: { enabled: false },
        newProject: { enabled: false },
        beantime: {
          enabled: true,
          title: "Synthetic Beantime",
          file: "beantime/zeit.beancount",
          personAccount: "Zeit:Example",
          stateFile: "beantime/state.json",
          bookableAccountPrefix: "Projekte:"
        },
        vaultGraph: { enabled: false },
        email: { enabled: false },
        updo: { enabled: false }
      }
    },
    null,
    2
  )}\n`,
  "utf8"
);

/** @returns {Promise<number>} Unoccupied loopback TCP port. */
async function getFreePort() {
  const socket = net.createServer();
  await new Promise((resolve, reject) => {
    socket.once("error", reject);
    socket.listen(0, "127.0.0.1", resolve);
  });
  const address = socket.address();
  const port = typeof address === "object" && address ? address.port : 0;
  await new Promise((resolve) => socket.close(resolve));
  return port;
}

/**
 * Sends an HTTP request to the synthetic Homepage server.
 * @param {number} port - Server port.
 * @param {string} method - HTTP method.
 * @param {string} pathname - Request pathname.
 * @param {object|null} [body=null] - Optional JSON body.
 * @returns {Promise<{status: number, text: string, json: object|null}>} Response payload.
 */
async function request(port, method, pathname, body = null) {
  const encoded = body === null ? "" : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: "127.0.0.1",
        port,
        method,
        path: pathname,
        headers: encoded
          ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(encoded) }
          : {}
      },
      (res) => {
        let text = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => {
          text += chunk;
        });
        res.on("end", () => {
          let json = null;
          try {
            json = JSON.parse(text);
          } catch {
            json = null;
          }
          resolve({ status: res.statusCode || 0, text, json });
        });
      }
    );
    req.once("error", reject);
    if (encoded) req.write(encoded);
    req.end();
  });
}

/**
 * Starts an isolated Homepage server and waits for health.
 * @param {string} capabilities - Comma-separated Beantime capabilities.
 * @param {string} [vaultLedgerPath=""] - Optional vault-relative ledger path.
 * @returns {Promise<{port: number, child: import("node:child_process").ChildProcess}>} Running server.
 */
async function startServer(capabilities, vaultLedgerPath = "") {
  const port = await getFreePort();
  const favaPort = await getFreePort();
  const child = spawn(process.execPath, [path.join(repoRoot, "serve.mjs")], {
    cwd: repoRoot,
    env: {
      ...process.env,
      HOMEPAGE_HOST: "127.0.0.1",
      HOMEPAGE_PORT: String(port),
      BEANTIME_FAVA_PORT: String(favaPort),
      NICA_VAULT_ROOT: vault,
      NICA_STATE_ROOT: state,
      NICA_WRITE_ENABLED: "false",
      NICA_PROJECT_CREATE_ENABLED: "false",
      NICA_OBSIDIAN_ACTIONS_ENABLED: "false",
      NICA_BEANTIME_CAPABILITIES: capabilities,
      NICA_BEANTIME_LEDGER_PATH: vaultLedgerPath,
      OBSIDIAN_VAULT_NAME: "synthetic-beantime-vault"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  let lastError = "";
  child.stderr.on("data", (chunk) => {
    lastError += String(chunk);
  });
  for (let attempt = 0; attempt < 80; attempt += 1) {
    if (child.exitCode !== null) throw new Error(`Synthetic Homepage exited early: ${lastError}`);
    try {
      const health = await request(port, "GET", "/api/ping");
      if (health.status === 200 && health.json?.ok) return { port, child };
    } catch {
      // Expected while the server starts.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  child.kill();
  throw new Error(`Synthetic Homepage did not become ready: ${lastError}`);
}

/** @param {import("node:child_process").ChildProcess} child - Server process. */
async function stopServer(child) {
  if (child.exitCode !== null) return;
  child.kill();
  await new Promise((resolve) => {
    const timeout = setTimeout(() => {
      if (child.exitCode === null) child.kill("SIGKILL");
    }, 3000);
    child.once("exit", () => {
      clearTimeout(timeout);
      resolve();
    });
  });
}

/**
 * Verifies invalid startup configuration fails before listening.
 * @param {Record<string, string>} overrides - Environment overrides under test.
 * @param {RegExp} expectedError - Expected stderr diagnostic.
 * @returns {Promise<void>} Resolves after the expected startup failure.
 */
async function assertStartupFails(overrides, expectedError) {
  const port = await getFreePort();
  const child = spawn(process.execPath, [path.join(repoRoot, "serve.mjs")], {
    cwd: repoRoot,
    env: {
      ...process.env,
      HOMEPAGE_PORT: String(port),
      NICA_VAULT_ROOT: vault,
      NICA_STATE_ROOT: state,
      NICA_WRITE_ENABLED: "false",
      NICA_BEANTIME_CAPABILITIES: "beantime.read",
      NICA_BEANTIME_LEDGER_PATH: "",
      ...overrides
    },
    stdio: ["ignore", "ignore", "pipe"]
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += String(chunk);
  });
  const exitCode = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error("Server did not reject invalid Beantime startup configuration"));
    }, 3000);
    child.once("exit", (code) => {
      clearTimeout(timeout);
      resolve(code);
    });
  });
  assert.notEqual(exitCode, 0);
  assert.match(stderr, expectedError);
}

/** @returns {Promise<void>} Removes the synthetic sandbox after handles are released. */
async function removeSandbox() {
  let lastError = null;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      fs.rmSync(sandbox, { recursive: true, force: true });
      return;
    } catch (error) {
      lastError = error;
      if (!(error?.code === "EPERM" || error?.code === "EBUSY")) throw error;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
  throw lastError;
}

const timerPayload = {
  account: "Projekte:Synthetic",
  personAccount: "Zeit:Example",
  summary: "Synthetic verification"
};

try {
  await assertStartupFails(
    { NICA_BEANTIME_CAPABILITIES: "beantime.read,beantime.unknown" },
    /Unknown NICA_BEANTIME_CAPABILITIES value/
  );
  const outsideLedgerDir = path.join(sandbox, "outside-ledger");
  const linkedLedgerDir = path.join(vault, "linked-ledger");
  fs.mkdirSync(outsideLedgerDir, { recursive: true });
  fs.writeFileSync(path.join(outsideLedgerDir, "zeit.beancount"), "synthetic\n", "utf8");
  fs.symlinkSync(outsideLedgerDir, linkedLedgerDir, process.platform === "win32" ? "junction" : "dir");
  await assertStartupFails(
    { NICA_BEANTIME_LEDGER_PATH: "../outside-ledger/zeit.beancount" },
    /must stay inside NICA_VAULT_ROOT/
  );
  await assertStartupFails(
    { NICA_BEANTIME_LEDGER_PATH: "linked-ledger/zeit.beancount" },
    /resolves outside NICA_VAULT_ROOT/
  );

  const disabled = await startServer("");
  try {
    const health = await request(disabled.port, "GET", "/api/ping");
    assert.equal(health.json?.mode, "read-only");
    assert.equal(health.json?.writeCapabilities?.beantimeRead, false);
    assert.equal((await request(disabled.port, "GET", "/api/beantime/meta")).status, 403);
    assert.equal((await request(disabled.port, "POST", "/api/beantime/start", timerPayload)).status, 403);
    assert.equal((await request(disabled.port, "POST", "/api/beantime/stop", {})).status, 403);
    assert.equal((await request(disabled.port, "POST", "/api/beantime/show", {})).status, 403);
    assert.equal(fs.existsSync(ledger), false, "disabled routes must not create the ledger");
  } finally {
    await stopServer(disabled.child);
  }

  const readOnly = await startServer("beantime.read");
  try {
    const missing = await request(readOnly.port, "GET", "/api/beantime/meta");
    assert.equal(missing.status, 500);
    assert.equal(fs.existsSync(ledger), false, "metadata reads must not provision a ledger");

    fs.mkdirSync(path.dirname(ledger), { recursive: true });
    const initialLedger = [
      'option "title" "Synthetic Beantime"',
      'option "operating_currency" "HR"',
      'option "name_assets" "Zeit"',
      'option "name_expenses" "Projekte"',
      "",
      "2031-01-01 commodity HR",
      "2031-01-01 open Zeit:Example",
      "2031-01-01 open Projekte:Synthetic",
      ""
    ].join("\n");
    fs.writeFileSync(ledger, initialLedger, "utf8");
    const meta = await request(readOnly.port, "GET", "/api/beantime/meta");
    assert.equal(meta.status, 200);
    assert.deepEqual(meta.json?.accounts, ["Projekte:Synthetic"]);
    assert.deepEqual(meta.json?.personAccounts, ["Zeit:Example"]);
    assert.deepEqual(meta.json?.capabilities, { timer: false, append: false, fava: false });
    assert.equal(fs.readFileSync(ledger, "utf8"), initialLedger, "metadata reads must not alter the ledger");
  } finally {
    await stopServer(readOnly.child);
  }

  const timerOnly = await startServer("beantime.read,beantime.timer");
  try {
    const health = await request(timerOnly.port, "GET", "/api/ping");
    assert.equal(health.json?.mode, "limited-write");
    assert.equal(health.json?.writeCapabilities?.beantimeTimer, true);
    assert.equal(health.json?.writeCapabilities?.beantimeAppend, false);
    assert.equal((await request(timerOnly.port, "POST", "/api/beantime/start", timerPayload)).status, 200);
    assert.equal(fs.existsSync(timerState), true);
    assert.equal((await request(timerOnly.port, "POST", "/api/beantime/stop", {})).status, 403);
    assert.equal(fs.existsSync(timerState), true, "denied stop must preserve running state");
  } finally {
    await stopServer(timerOnly.child);
  }
  fs.rmSync(timerState, { force: true });

  const bounded = await startServer("beantime.read,beantime.timer,beantime.append");
  try {
    const before = fs.readFileSync(ledger, "utf8");
    const invalid = await request(bounded.port, "POST", "/api/beantime/start", {
      ...timerPayload,
      account: "Projekte:Missing"
    });
    assert.equal(invalid.status, 422);
    assert.equal(fs.existsSync(timerState), false);

    assert.equal((await request(bounded.port, "POST", "/api/beantime/start", timerPayload)).status, 200);
    const stopped = await request(bounded.port, "POST", "/api/beantime/stop", {});
    assert.equal(stopped.status, 200);
    assert.equal(stopped.json?.file, "beantime/zeit.beancount");
    assert.equal(fs.existsSync(timerState), false);
    const after = fs.readFileSync(ledger, "utf8");
    assert.ok(after.length > before.length);
    assert.match(after, /Synthetic verification/);
    assert.equal((await request(bounded.port, "POST", "/api/beantime/show", {})).status, 403);
    assert.equal((await request(bounded.port, "POST", "/api/settings", {})).status, 403);
  } finally {
    await stopServer(bounded.child);
  }

  const vaultLedger = path.join(vault, "Tools", "data", "beantime", "zeit.beancount");
  fs.mkdirSync(path.dirname(vaultLedger), { recursive: true });
  fs.copyFileSync(ledger, vaultLedger);
  const localLedgerBefore = fs.readFileSync(ledger, "utf8");
  const vaultBacked = await startServer(
    "beantime.read,beantime.timer,beantime.append",
    "Tools/data/beantime/zeit.beancount"
  );
  try {
    const health = await request(vaultBacked.port, "GET", "/api/ping");
    assert.equal(health.json?.beantimeLedgerAuthority, "vault");
    const meta = await request(vaultBacked.port, "GET", "/api/beantime/meta");
    assert.equal(meta.status, 200);
    assert.equal(meta.json?.file, "Tools/data/beantime/zeit.beancount");
    assert.equal(meta.json?.ledgerAuthority, "vault");

    assert.equal((await request(vaultBacked.port, "POST", "/api/beantime/start", timerPayload)).status, 200);
    assert.equal(fs.existsSync(timerState), true, "running timer state must remain local");
    assert.equal((await request(vaultBacked.port, "POST", "/api/beantime/stop", {})).status, 200);
    assert.equal(fs.existsSync(timerState), false);
    assert.match(fs.readFileSync(vaultLedger, "utf8"), /Synthetic verification/);
    assert.equal(
      fs.readFileSync(ledger, "utf8"),
      localLedgerBefore,
      "vault-backed writes must not modify the local-state ledger"
    );
  } finally {
    await stopServer(vaultBacked.child);
  }

  console.log("Beantime shadow smoke check OK");
} finally {
  await removeSandbox();
}
