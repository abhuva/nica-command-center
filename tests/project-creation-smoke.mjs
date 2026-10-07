import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "nica-project-creation-"));
const vault = path.join(sandbox, "vault");
const state = path.join(sandbox, "state");
const projectsRoot = path.join(vault, "2. Projektverwaltung");
const templateRoot = path.join(vault, "6. Obsidian", "_template", "project");
const templatePath = path.join(templateRoot, "Projekt.md");

fs.mkdirSync(projectsRoot, { recursive: true });
fs.mkdirSync(templateRoot, { recursive: true });
fs.writeFileSync(templatePath, "---\ncategory: draft\n---\n# <% tp.file.title %>\n", "utf8");

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
 * Sends an HTTP request to the synthetic Homepage server.
 * @param {number} port - Server port.
 * @param {string} method - HTTP method.
 * @param {string} pathname - Request pathname.
 * @param {object|null} [body=null] - Optional JSON body.
 * @param {Record<string, string>} [extraHeaders={}] - Additional request headers.
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
 * Starts an isolated Homepage server and waits for health.
 * @param {{projectEnabled: boolean, obsidianActions?: boolean}} options - Runtime capability options.
 * @returns {Promise<{port: number, child: import("node:child_process").ChildProcess}>} Running server.
 */
async function startServer({ projectEnabled, obsidianActions = false, settingsEnabled = false }) {
  const port = await getFreePort();
  const child = spawn(process.execPath, [path.join(repoRoot, "serve.mjs")], {
    cwd: repoRoot,
    env: {
      ...process.env,
      HOMEPAGE_PORT: String(port),
      NICA_VAULT_ROOT: vault,
      NICA_STATE_ROOT: state,
      NICA_WRITE_ENABLED: "false",
      NICA_PROJECT_CREATE_ENABLED: projectEnabled ? "true" : "false",
      NICA_SETTINGS_MANAGE_ENABLED: settingsEnabled ? "true" : "false",
      NICA_OBSIDIAN_ACTIONS_ENABLED: obsidianActions ? "true" : "false",
      OBSIDIAN_VAULT_NAME: "synthetic-project-vault",
      OBSIDIAN_BIN: process.execPath
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
      // Expected while the server is starting.
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

/** @returns {string[]} Staging folders currently left in the project authority. */
function stagingFolders() {
  return fs.readdirSync(projectsRoot).filter((name) => name.startsWith("_nica-project-staging-"));
}

/** @returns {Promise<void>} Removes the synthetic sandbox after Windows releases child-process directory handles. */
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
  year: 2031,
  society: "NICA",
  fundingCode: "SYNTH",
  title: "Synthetic Project",
  projectType: "funding",
  templatePath: "6. Obsidian/_template/project/Projekt.md",
  openInNewTab: true
};

try {
  const enabled = await startServer({ projectEnabled: true });
  try {
    const health = await request(enabled.port, "GET", "/api/ping");
    assert.equal(health.json?.mode, "limited-write");
    assert.equal(health.json?.writesEnabled, true);
    assert.equal(health.json?.writeCapabilities?.projectCreate, true);
    assert.equal(health.json?.writeCapabilities?.unrestricted, false);
    const session = await request(enabled.port, "GET", "/api/projects/session");
    assert.match(session.json?.actionToken || "", /^[a-f0-9]{64}$/);
    const actionHeaders = { "X-NICA-Action-Token": session.json.actionToken };

    const blockedSettings = await request(enabled.port, "POST", "/api/settings", {});
    assert.equal(blockedSettings.status, 403, "unrelated writes must remain disabled");
    const blockedSearch = await request(enabled.port, "POST", "/api/search/open", {
      provider: "obsidian-search",
      openInNewTab: true
    });
    assert.equal(blockedSearch.status, 403, "Obsidian actions require their explicit capability");

    const invalidSociety = await request(enabled.port, "POST", "/api/projects/plan", {
      ...basePayload,
      society: "OTHER"
    });
    assert.equal(invalidSociety.status, 422);

    const traversal = await request(enabled.port, "POST", "/api/projects/plan", {
      ...basePayload,
      title: "../escape"
    });
    assert.equal(traversal.status, 422);

    const planned = await request(enabled.port, "POST", "/api/projects/plan", basePayload);
    assert.equal(planned.status, 200);
    assert.equal(planned.json?.requiresConfirmation, true);
    assert.match(planned.json?.planId || "", /^[a-f0-9]{64}$/);

    const missingToken = await request(enabled.port, "POST", "/api/projects/create", {
      ...basePayload,
      planId: planned.json.planId
    });
    assert.equal(missingToken.status, 403, "apply requires the ephemeral same-origin token");

    const unconfirmed = await request(enabled.port, "POST", "/api/projects/create", basePayload, actionHeaders);
    assert.equal(unconfirmed.status, 422);
    assert.equal(fs.existsSync(path.join(projectsRoot, planned.json.folderName)), false);
    assert.deepEqual(stagingFolders(), []);

    const changedTemplate = `${fs.readFileSync(templatePath, "utf8")}\nchanged after preview\n`;
    fs.writeFileSync(templatePath, changedTemplate, "utf8");
    const stale = await request(enabled.port, "POST", "/api/projects/create", {
      ...basePayload,
      planId: planned.json.planId
    }, actionHeaders);
    assert.equal(stale.status, 422, "template changes must invalidate the prior plan");
    assert.deepEqual(stagingFolders(), []);

    const refreshed = await request(enabled.port, "POST", "/api/projects/plan", basePayload);
    assert.equal(refreshed.status, 200);
    const created = await request(enabled.port, "POST", "/api/projects/create", {
      ...basePayload,
      planId: refreshed.json.planId
    }, actionHeaders);
    assert.equal(created.status, 200);
    assert.equal(created.json?.created, true);
    assert.equal(created.json?.opened, false);
    const projectFile = path.join(vault, ...created.json.paths.file.split("/"));
    const projectText = fs.readFileSync(projectFile, "utf8");
    assert.match(projectText, /category: 'project-moc'/);
    assert.match(projectText, /antragsteller: 'NICA'/);
    assert.match(projectText, /f\u00f6rderer: 'SYNTH'/);
    assert.deepEqual(stagingFolders(), []);

    const duplicate = await request(enabled.port, "POST", "/api/projects/plan", basePayload);
    assert.equal(duplicate.status, 422);

    const auditPath = path.join(state, "homepage", "audit", "project-creation.jsonl");
    const auditText = fs.readFileSync(auditPath, "utf8");
    assert.match(auditText, /"outcome":"created"/);
    assert.doesNotMatch(auditText, /Synthetic Project/);
    assert.doesNotMatch(auditText, /2\. Projektverwaltung/);
  } finally {
    await stopServer(enabled.child);
  }

  const disabled = await startServer({ projectEnabled: false });
  try {
    const plan = await request(disabled.port, "POST", "/api/projects/plan", {
      ...basePayload,
      title: "Disabled Capability"
    });
    assert.equal(plan.status, 200, "planning remains read-only");
    const apply = await request(disabled.port, "POST", "/api/projects/create", {
      ...basePayload,
      title: "Disabled Capability",
      planId: plan.json.planId
    });
    assert.equal(apply.status, 403);
  } finally {
    await stopServer(disabled.child);
  }

  const settingsServer = await startServer({ projectEnabled: false, settingsEnabled: true });
  try {
    const health = await request(settingsServer.port, "GET", "/api/ping");
    assert.equal(health.json?.mode, "limited-write");
    assert.equal(health.json?.writeCapabilities?.settingsManage, true);
    assert.equal(health.json?.writeCapabilities?.projectCreate, false);
    const saved = await request(settingsServer.port, "POST", "/api/settings", {
      settings: {
        startup: {
          openObsidian: true,
          openHomepage: false,
          openCalendar: false,
          services: {
            calendar: false,
            email: true,
            vaultGraph: false,
            financeNica: true,
            financeTohu: false
          }
        },
        modules: { updo: { enabled: false } }
      }
    });
    assert.equal(saved.status, 200);
    assert.equal(saved.json?.settings?.schemaVersion, 2);
    assert.equal(saved.json?.settings?.startup?.services?.email, true);
    assert.equal(saved.json?.settings?.startup?.services?.calendar, false);
    assert.equal(saved.json?.settings?.modules?.updo?.enabled, false);
    const blockedApply = await request(settingsServer.port, "POST", "/api/projects/create", basePayload);
    assert.equal(blockedApply.status, 403, "settings capability must not enable project creation");
  } finally {
    await stopServer(settingsServer.child);
  }

  const failing = await startServer({ projectEnabled: true, obsidianActions: true });
  try {
    const allowedSearch = await request(failing.port, "POST", "/api/search/open", {
      provider: "obsidian-search",
      openInNewTab: true
    });
    assert.equal(allowedSearch.status, 502, "enabled Obsidian actions must pass the global read-only guard");
    const session = await request(failing.port, "GET", "/api/projects/session");
    const actionHeaders = { "X-NICA-Action-Token": session.json.actionToken };
    const failurePayload = { ...basePayload, title: "Obsidian Failure" };
    const plan = await request(failing.port, "POST", "/api/projects/plan", failurePayload);
    assert.equal(plan.status, 200);
    const apply = await request(failing.port, "POST", "/api/projects/create", {
      ...failurePayload,
      planId: plan.json.planId
    }, actionHeaders);
    assert.equal(apply.status, 422);
    assert.equal(fs.existsSync(path.join(projectsRoot, plan.json.folderName)), false);
    assert.deepEqual(stagingFolders(), [], "failed Obsidian creation must remove its exact staging folder");
  } finally {
    await stopServer(failing.child);
  }

  console.log("Project creation smoke check OK");
} finally {
  await removeSandbox();
}
