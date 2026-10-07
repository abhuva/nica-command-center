import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "nica-calendar-vault-create-"));
const vault = path.join(sandbox, "vault");
const state = path.join(sandbox, "state");
const inbox = path.join(vault, "6. Obsidian", "Inbox");
const bookmarksDir = path.join(vault, ".obsidian");
const outsideInbox = path.join(sandbox, "outside-inbox");
const linkedInbox = path.join(vault, "linked-inbox");

fs.mkdirSync(inbox, { recursive: true });
fs.mkdirSync(bookmarksDir, { recursive: true });
fs.mkdirSync(outsideInbox, { recursive: true });
fs.symlinkSync(outsideInbox, linkedInbox, process.platform === "win32" ? "junction" : "dir");
fs.writeFileSync(path.join(bookmarksDir, "bookmarks.json"), '{"items":[]}', "utf8");

/** @returns {Promise<number>} Unoccupied loopback TCP port. */
async function getFreePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

/**
 * Sends an HTTP request to the synthetic Calendar server.
 * @param {number} port - Server port.
 * @param {string} method - HTTP method.
 * @param {string} pathname - Request pathname.
 * @param {object|null} [body=null] - Optional JSON body.
 * @param {Record<string, string>} [extraHeaders={}] - Additional headers.
 * @returns {Promise<{status: number, text: string, json: object|null}>} Response payload.
 */
async function request(port, method, pathname, body = null, extraHeaders = {}) {
  const encoded = body === null ? "" : JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: "127.0.0.1",
        port,
        method,
        path: pathname,
        headers: {
          ...(encoded ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(encoded) } : {}),
          ...extraHeaders
        }
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
 * Starts an isolated Calendar server and waits for health.
 * @param {boolean} vaultCreateEnabled - Whether the narrow creation capability is enabled.
 * @param {string} [inboxPath="6. Obsidian/Inbox"] - Vault-relative Calendar inbox.
 * @returns {Promise<{port: number, child: import("node:child_process").ChildProcess}>} Running server.
 */
async function startServer(vaultCreateEnabled, inboxPath = "6. Obsidian/Inbox") {
  const port = await getFreePort();
  const child = spawn(process.execPath, [path.join(repoRoot, "Calendar", "serve.mjs")], {
    cwd: path.join(repoRoot, "Calendar"),
    env: {
      ...process.env,
      CALENDAR_PORT: String(port),
      NICA_VAULT_ROOT: vault,
      NICA_STATE_ROOT: state,
      NICA_WRITE_ENABLED: "false",
      NICA_CALENDAR_VAULT_CREATE_ENABLED: vaultCreateEnabled ? "true" : "false",
      NICA_OBSIDIAN_ACTIONS_ENABLED: "false",
      NICA_CALENDAR_ENV_FILE: "",
      OBSIDIAN_VAULT_NAME: "synthetic-calendar-vault",
      CALENDAR_INBOX_PATH: inboxPath,
      ALLOW_MARKDOWN_FALLBACK: "true"
    },
    stdio: ["ignore", "pipe", "pipe"]
  });

  let lastError = "";
  child.stderr.on("data", (chunk) => {
    lastError += String(chunk);
  });
  for (let attempt = 0; attempt < 80; attempt += 1) {
    if (child.exitCode !== null) throw new Error(`Synthetic Calendar exited early: ${lastError}`);
    try {
      const health = await request(port, "GET", "/api/ping");
      if (health.status === 200 && health.json?.ok) return { port, child };
    } catch {
      // Expected while the server starts.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  child.kill();
  throw new Error(`Synthetic Calendar did not become ready: ${lastError}`);
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

/** @returns {string[]} Calendar staging files currently left in the synthetic inbox. */
function stagingFiles() {
  return fs.readdirSync(inbox).filter((name) => name.startsWith("_nica-calendar-staging-"));
}

/** @returns {Promise<void>} Removes the synthetic sandbox after process handles are released. */
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

const basePayload = {
  title: "Synthetic Calendar Event",
  start: "2031-05-04",
  end: "2031-05-05",
  allDay: true
};

try {
  const enabled = await startServer(true);
  try {
    const health = await request(enabled.port, "GET", "/api/ping");
    assert.equal(health.json?.mode, "limited-write");
    assert.equal(health.json?.writesEnabled, true);
    assert.equal(health.json?.writeCapabilities?.vaultEventCreate, true);
    assert.equal(health.json?.writeCapabilities?.unrestricted, false);

    const session = await request(enabled.port, "GET", "/api/session");
    assert.match(session.json?.token || "", /^[a-f0-9]{48}$/);
    const actionHeaders = { "X-Calendar-Token": session.json.token };

    const missingToken = await request(enabled.port, "POST", "/api/events/create/plan", basePayload);
    assert.equal(missingToken.status, 403);

    const invalidTitle = await request(
      enabled.port,
      "POST",
      "/api/events/create/plan",
      { ...basePayload, title: "bad\ntitle" },
      actionHeaders
    );
    assert.equal(invalidTitle.status, 400);

    const invalidRange = await request(
      enabled.port,
      "POST",
      "/api/events/create/plan",
      { ...basePayload, start: "2031-05-06", end: "2031-05-05" },
      actionHeaders
    );
    assert.equal(invalidRange.status, 400);

    const planned = await request(enabled.port, "POST", "/api/events/create/plan", basePayload, actionHeaders);
    assert.equal(planned.status, 200);
    assert.equal(planned.json?.sourcePath, "6. Obsidian/Inbox/Synthetic Calendar Event.md");
    assert.match(planned.json?.planId || "", /^[a-f0-9]{64}$/);
    const eventFile = path.join(vault, ...planned.json.sourcePath.split("/"));
    assert.equal(fs.existsSync(eventFile), false, "planning must not create a note");

    const unconfirmed = await request(enabled.port, "POST", "/api/events/create", basePayload, actionHeaders);
    assert.equal(unconfirmed.status, 409);
    assert.equal(fs.existsSync(eventFile), false);

    const changed = await request(
      enabled.port,
      "POST",
      "/api/events/create",
      { ...basePayload, title: "Changed Synthetic Event", planId: planned.json.planId },
      actionHeaders
    );
    assert.equal(changed.status, 409);
    assert.equal(fs.existsSync(path.join(inbox, "Changed Synthetic Event.md")), false);

    const created = await request(
      enabled.port,
      "POST",
      "/api/events/create",
      { ...basePayload, planId: planned.json.planId },
      actionHeaders
    );
    assert.equal(created.status, 200);
    assert.equal(created.json?.sourcePath, planned.json.sourcePath);
    assert.equal(fs.existsSync(eventFile), true);
    const eventText = fs.readFileSync(eventFile, "utf8");
    assert.match(eventText, /^title: "Synthetic Calendar Event"$/m);
    assert.match(eventText, /^startDate: 2031-05-04$/m);
    assert.match(eventText, /^endDate: 2031-05-05$/m);
    assert.match(eventText, /^  - event$/m);
    assert.deepEqual(stagingFiles(), []);

    const stale = await request(
      enabled.port,
      "POST",
      "/api/events/create",
      { ...basePayload, planId: planned.json.planId },
      actionHeaders
    );
    assert.equal(stale.status, 409);
    assert.equal(fs.existsSync(path.join(inbox, "Synthetic Calendar Event (2).md")), false);

    const blockedRoutes = [
      "/api/events/update-dates",
      "/api/events/open-note",
      "/api/events/open-map",
      "/api/events/rebuild",
      "/api/events/publish-public",
      "/api/google-oauth/disconnect",
      "/api/google-calendar/events/create",
      "/api/nextcloud-calendar/events/create"
    ];
    for (const pathname of blockedRoutes) {
      const blocked = await request(enabled.port, "POST", pathname, {}, actionHeaders);
      assert.equal(blocked.status, 403, `${pathname} must remain disabled`);
    }
    const oauthStart = await request(enabled.port, "GET", "/api/google-oauth/start");
    assert.equal(oauthStart.status, 403);

    const auditPath = path.join(state, "calendar", "audit", "vault-event-creation.jsonl");
    const audit = fs.readFileSync(auditPath, "utf8");
    assert.match(audit, /"outcome":"created"/);
    assert.doesNotMatch(audit, /Synthetic Calendar Event/);
    assert.doesNotMatch(audit, /6\. Obsidian/);
  } finally {
    await stopServer(enabled.child);
  }

  const disabled = await startServer(false);
  try {
    const health = await request(disabled.port, "GET", "/api/ping");
    assert.equal(health.json?.mode, "read-only");
    assert.equal(health.json?.writeCapabilities?.vaultEventCreate, false);
    const session = await request(disabled.port, "GET", "/api/session");
    const headers = { "X-Calendar-Token": session.json.token };
    const plan = await request(disabled.port, "POST", "/api/events/create/plan", basePayload, headers);
    assert.equal(plan.status, 403);
    const apply = await request(disabled.port, "POST", "/api/events/create", basePayload, headers);
    assert.equal(apply.status, 403);
  } finally {
    await stopServer(disabled.child);
  }

  const escaped = await startServer(true, "linked-inbox");
  try {
    const session = await request(escaped.port, "GET", "/api/session");
    const headers = { "X-Calendar-Token": session.json.token };
    const plan = await request(escaped.port, "POST", "/api/events/create/plan", basePayload, headers);
    assert.equal(plan.status, 400);
    assert.equal(plan.json?.code, "NICA_CALENDAR_PLAN_INVALID");
    assert.match(plan.json?.message || "", /resolves outside vault/);
    assert.deepEqual(fs.readdirSync(outsideInbox), []);
  } finally {
    await stopServer(escaped.child);
  }

  console.log("Calendar vault-event creation smoke check OK");
} finally {
  await removeSandbox();
}
