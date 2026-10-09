import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "nica-homepage-dashboard-"));
const vault = path.join(sandbox, "vault");
const state = path.join(sandbox, "state");
const homepageConfig = path.join(state, "homepage", "config");
const projectsFile = path.join(vault, "6. Obsidian", "Live", "Projekte.md");
const contactsFile = path.join(vault, "6. Obsidian", "Bases", "Kontakte.base");

fs.mkdirSync(path.dirname(projectsFile), { recursive: true });
fs.mkdirSync(path.dirname(contactsFile), { recursive: true });
fs.mkdirSync(path.join(vault, ".obsidian"), { recursive: true });
fs.mkdirSync(homepageConfig, { recursive: true });
fs.writeFileSync(projectsFile, "# Synthetic projects\n", "utf8");
fs.writeFileSync(contactsFile, "filters: []\n", "utf8");
fs.writeFileSync(path.join(vault, ".obsidian", "bookmarks.json"), '{"items":[]}\n', "utf8");
fs.writeFileSync(
  path.join(homepageConfig, "settings.local.json"),
  `${JSON.stringify(
    {
      schemaVersion: 2,
      startup: {
        services: {
          calendar: true,
          email: false,
          websiteConsole: true,
          projects: true,
          contacts: false,
          vaultGraph: false,
          financeNica: true,
          financeTohu: false
        }
      },
      modules: {
        dashboard: { enabled: true, title: "Home" },
        bookmarks: { enabled: false },
        clock: { enabled: false },
        newProject: { enabled: false },
        beantime: { enabled: false },
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
 * Sends one request to the synthetic Homepage server.
 * @param {number} port - Homepage port.
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
          ? {
              "Content-Type": "application/json",
              "Content-Length": Buffer.byteLength(encoded),
              Origin: `http://127.0.0.1:${port}`
            }
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

/** @returns {Promise<void>} Removes the synthetic sandbox after child-process handles close. */
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

const port = await getFreePort();
const child = spawn(process.execPath, [path.join(repoRoot, "serve.mjs")], {
  cwd: repoRoot,
  env: {
    ...process.env,
    HOMEPAGE_PORT: String(port),
    NICA_VAULT_ROOT: vault,
    NICA_STATE_ROOT: state,
    NICA_WRITE_ENABLED: "false",
    NICA_PROJECT_CREATE_ENABLED: "false",
    NICA_SETTINGS_MANAGE_ENABLED: "false",
    NICA_OBSIDIAN_ACTIONS_ENABLED: "true",
    OBSIDIAN_VAULT_NAME: "synthetic-dashboard-vault",
    OBSIDIAN_BIN: process.execPath,
    DASHBOARD_CALENDAR_PORT: "53101",
    DASHBOARD_EMAIL_PORT: "53102",
    DASHBOARD_WEBSITE_CONSOLE_PORT: "53105",
    DASHBOARD_FINANCE_NICA_PORT: "53103",
    DASHBOARD_FINANCE_TOHU_PORT: "53104"
  },
  stdio: ["ignore", "pipe", "pipe"]
});

let lastError = "";
child.stderr.on("data", (chunk) => {
  lastError += String(chunk);
});

try {
  let ready = false;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    if (child.exitCode !== null) throw new Error(`Synthetic Homepage exited early: ${lastError}`);
    try {
      const health = await request(port, "GET", "/api/ping");
      if (health.status === 200 && health.json?.ok) {
        ready = true;
        break;
      }
    } catch {
      // Expected while the server starts.
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.equal(ready, true, `Synthetic Homepage did not become ready: ${lastError}`);

  const settings = await request(port, "GET", "/api/settings");
  assert.equal(settings.status, 200);
  assert.equal(settings.json?.settings?.modules?.dashboard?.enabled, true);
  assert.equal(settings.json?.settings?.startup?.services?.projects, true);
  assert.equal(settings.json?.settings?.startup?.services?.contacts, false);
  assert.equal(settings.json?.settings?.startup?.services?.researchAgent, false);
  assert.equal(settings.json?.settings?.modules?.dashboard?.services?.researchAgent, true);

  const dashboard = await request(port, "GET", "/api/dashboard");
  assert.equal(dashboard.status, 200);
  assert.deepEqual(
    dashboard.json?.items?.map((item) => item.id),
    ["calendar", "website", "research", "projects", "finance-nica"]
  );
  assert.equal(dashboard.text.includes("53101"), false, "Dashboard payload must not expose runtime URLs");
  assert.equal(dashboard.text.includes("53105"), false, "Website console port must remain server-side");
  assert.equal(dashboard.text.includes("8767"), false, "Research service port must remain server-side");
  assert.equal(dashboard.text.includes("Projekte.md"), false, "Dashboard payload must not expose vault paths");
  assert.equal(dashboard.json?.items?.find((item) => item.id === "research")?.action, "start-or-open");

  const unknown = await request(port, "POST", "/api/dashboard/open", { id: "unknown" });
  assert.equal(unknown.status, 404);
  const disabled = await request(port, "POST", "/api/dashboard/open", { id: "email" });
  assert.equal(disabled.status, 403);
  const enabledWeb = await request(port, "POST", "/api/dashboard/open", { id: "calendar" });
  assert.equal(enabledWeb.status, 502, "Enabled web entry must reach the bounded Obsidian action");
  const enabledFile = await request(port, "POST", "/api/dashboard/open", { id: "projects" });
  assert.equal(enabledFile.status, 502, "Enabled file entry must reach the bounded Obsidian action");
  const researchStart = await request(port, "POST", "/api/dashboard/start", { id: "research" });
  assert.equal(researchStart.status, 403, "Research start must require its explicit local capability");

  console.log("Homepage shared-dashboard smoke check OK");
  if (String(process.env.NICA_DASHBOARD_BROWSER_PREVIEW || "").toLowerCase() === "true") {
    console.log(`Homepage dashboard browser preview: http://127.0.0.1:${port}/home.html`);
    await new Promise((resolve) => {
      process.once("SIGINT", resolve);
      process.once("SIGTERM", resolve);
    });
  }
} finally {
  await stopServer(child);
  await removeSandbox();
}
