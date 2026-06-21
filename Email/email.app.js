const state = {
  accounts: [],
  rules: [],
  messages: [],
  selectedId: null,
  activeView: "dashboard",
  dashboard: null,
};

const THEME_CACHE_KEY = "email-theme-bootstrap-v1";
const COMPACT_CACHE_KEY = "email-account-compact-v1";
const rootEl = document.documentElement;

const els = {
  status: document.querySelector("#status"),
  dashboardTab: document.querySelector("#dashboardTab"),
  accountTab: document.querySelector("#accountTab"),
  rulesTab: document.querySelector("#rulesTab"),
  dashboardView: document.querySelector("#dashboardView"),
  accountView: document.querySelector("#accountView"),
  rulesView: document.querySelector("#rulesView"),
  fetchNewAllBtn: document.querySelector("#fetchNewAllBtn"),
  countAllBtn: document.querySelector("#countAllBtn"),
  recentLimitInput: document.querySelector("#recentLimitInput"),
  dashboardStatus: document.querySelector("#dashboardStatus"),
  dashboardStats: document.querySelector("#dashboardStats"),
  dashboardAccounts: document.querySelector("#dashboardAccounts"),
  dashboardRecent: document.querySelector("#dashboardRecent"),
  stats: document.querySelector("#stats"),
  accountSelect: document.querySelector("#accountSelect"),
  compactToggle: document.querySelector("#compactToggle"),
  sinceInput: document.querySelector("#sinceInput"),
  beforeInput: document.querySelector("#beforeInput"),
  fetchLimitInput: document.querySelector("#fetchLimitInput"),
  countBtn: document.querySelector("#countBtn"),
  fetchNewBtn: document.querySelector("#fetchNewBtn"),
  fetchBtn: document.querySelector("#fetchBtn"),
  oauthBtn: document.querySelector("#oauthBtn"),
  oauthPanel: document.querySelector("#oauthPanel"),
  serverCount: document.querySelector("#serverCount"),
  refreshBtn: document.querySelector("#refreshBtn"),
  applyRulesBtn: document.querySelector("#applyRulesBtn"),
  exportBtn: document.querySelector("#exportBtn"),
  searchInput: document.querySelector("#searchInput"),
  stateFilter: document.querySelector("#stateFilter"),
  tagFilter: document.querySelector("#tagFilter"),
  messageList: document.querySelector("#messageList"),
  messageDetail: document.querySelector("#messageDetail"),
  messageActions: document.querySelector("#messageActions"),
  tagInput: document.querySelector("#tagInput"),
  tagBtn: document.querySelector("#tagBtn"),
  ruleName: document.querySelector("#ruleName"),
  ruleField: document.querySelector("#ruleField"),
  ruleOperator: document.querySelector("#ruleOperator"),
  rulePattern: document.querySelector("#rulePattern"),
  ruleAction: document.querySelector("#ruleAction"),
  ruleTag: document.querySelector("#ruleTag"),
  saveRuleBtn: document.querySelector("#saveRuleBtn"),
  ruleList: document.querySelector("#ruleList"),
  ruleScope: document.querySelector("#ruleScope"),
  tagSuggestions: document.querySelector("#tagSuggestions"),
  rulesSearch: document.querySelector("#rulesSearch"),
  rulesTagFilter: document.querySelector("#rulesTagFilter"),
  rulesScopeFilter: document.querySelector("#rulesScopeFilter"),
  rulesActionFilter: document.querySelector("#rulesActionFilter"),
  rulesCount: document.querySelector("#rulesCount"),
  rulesTable: document.querySelector("#rulesTable"),
};

const api = async (path, options = {}) => {
  const response = await fetch(path, {
    headers: { "content-type": "application/json" },
    ...options,
  });
  const payload = await response.json();
  if (!response.ok || payload.ok === false) {
    throw new Error(payload.error || response.statusText);
  }
  return payload;
};

const post = (path, payload = {}) => api(path, { method: "POST", body: JSON.stringify(payload) });
const setStatus = (text) => { els.status.textContent = text; };
const fmtNumber = (value) => Number(value || 0).toLocaleString("de-DE");
let progressTimer = null;

const formatProgress = (progress) => {
  if (!progress) return "";
  const message = String(progress.message || "").trim();
  const current = Number(progress.current || 0);
  const total = Number(progress.total || 0);
  const fetched = Number(progress.fetched || 0);
  const suffix = total > 0 ? ` (${fmtNumber(current)}/${fmtNumber(total)}, new ${fmtNumber(fetched)})` : "";
  return `${message}${suffix}`;
};

const startProgressPolling = () => {
  if (progressTimer) window.clearInterval(progressTimer);
  progressTimer = window.setInterval(async () => {
    try {
      const payload = await api("/api/progress");
      const text = formatProgress(payload.progress);
      if (text) setStatus(text);
      if (payload.progress && payload.progress.active === false && payload.progress.phase === "done") {
        window.clearInterval(progressTimer);
        progressTimer = null;
      }
    } catch {
      // Progress polling is best effort; the main request still reports errors.
    }
  }, 700);
};

const stopProgressPolling = () => {
  if (progressTimer) window.clearInterval(progressTimer);
  progressTimer = null;
};

window.addEventListener("unhandledrejection", (event) => {
  setStatus(event.reason?.message || String(event.reason || "Request failed"));
});

const themeVarNames = [
  "--email-bg-a",
  "--email-bg-b",
  "--email-panel",
  "--email-panel-strong",
  "--email-panel-hover",
  "--email-input-bg",
  "--email-text",
  "--email-muted",
  "--email-line",
  "--email-accent",
  "--email-accent-soft",
  "--email-bad",
  "--email-good",
  "--email-warn",
  "--email-shadow",
];

const currentThemeCssVarSnapshot = () => {
  const out = {};
  for (const name of themeVarNames) {
    const value = rootEl.style.getPropertyValue(name);
    if (value && String(value).trim()) out[name] = String(value).trim();
  }
  return out;
};

const persistThemeBootstrapCache = () => {
  try {
    localStorage.setItem(THEME_CACHE_KEY, JSON.stringify({ vars: currentThemeCssVarSnapshot() }));
  } catch {
    // noop
  }
};

const applyMirroredThemeVars = (themeVars) => {
  const accent = String(themeVars?.accent || "").trim();
  const accentHover = String(themeVars?.accentHover || "").trim();
  const bgPrimary = String(themeVars?.bgPrimary || "").trim();
  const bgSecondary = String(themeVars?.bgSecondary || "").trim();
  const bgMod = String(themeVars?.bgMod || "").trim();
  const border = String(themeVars?.border || "").trim();
  const text = String(themeVars?.text || "").trim();
  const textMuted = String(themeVars?.textMuted || "").trim();
  const ok = String(themeVars?.textSuccess || "").trim();
  const danger = String(themeVars?.textError || "").trim();
  if (!bgPrimary || !text || !accent) return false;
  rootEl.style.setProperty("--email-bg-a", bgSecondary || bgPrimary);
  rootEl.style.setProperty("--email-bg-b", bgPrimary);
  rootEl.style.setProperty("--email-panel", bgSecondary || bgPrimary);
  rootEl.style.setProperty("--email-panel-strong", bgPrimary);
  rootEl.style.setProperty("--email-panel-hover", bgMod || bgSecondary || bgPrimary);
  rootEl.style.setProperty("--email-input-bg", bgMod || bgPrimary);
  rootEl.style.setProperty("--email-text", text);
  rootEl.style.setProperty("--email-muted", textMuted || text);
  rootEl.style.setProperty("--email-line", border || "rgba(128, 128, 128, 0.3)");
  rootEl.style.setProperty("--email-accent", accent);
  rootEl.style.setProperty("--email-accent-soft", accentHover || accent);
  rootEl.style.setProperty("--email-bad", danger || "#a42130");
  rootEl.style.setProperty("--email-good", ok || "#1b8e4a");
  rootEl.style.setProperty("--email-warn", accentHover || accent);
  rootEl.style.setProperty("--email-shadow", "0 10px 28px rgba(0, 0, 0, 0.18)");
  return true;
};

const applyEmailTheme = async () => {
  try {
    const payload = await api("/api/obsidian/theme");
    const mirrored = applyMirroredThemeVars(payload?.theme?.vars);
    if (mirrored) persistThemeBootstrapCache();
  } catch (error) {
    console.warn("Could not mirror Obsidian theme for Email:", error.message);
  }
};

const escapeHtml = (value) => String(value ?? "").replace(/[&<>'"]/g, (char) => ({
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  "'": "&#39;",
  "\"": "&quot;",
}[char]));

const shortDate = (value) => {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value).slice(0, 10);
  return date.toISOString().slice(0, 10);
};

const shorten = (value, maxLength) => {
  const text = String(value || "").trim();
  if (text.length <= maxLength) return text;
  return `${text.slice(0, Math.max(0, maxLength - 1))}…`;
};

const applyCompactMode = (enabled) => {
  els.messageList.classList.toggle("compact-list", enabled);
  els.compactToggle.checked = enabled;
  try {
    localStorage.setItem(COMPACT_CACHE_KEY, enabled ? "1" : "0");
  } catch {
    // noop
  }
};

const loadCompactMode = () => {
  let enabled = false;
  try {
    enabled = localStorage.getItem(COMPACT_CACHE_KEY) === "1";
  } catch {
    enabled = false;
  }
  applyCompactMode(enabled);
};

const selectedAccount = () => state.accounts.find((account) => account.id === els.accountSelect.value);

const setActiveView = (view) => {
  state.activeView = view;
  const isDashboard = view === "dashboard";
  const isAccount = view === "account";
  const isRules = view === "rules";
  els.dashboardView.classList.toggle("hidden", !isDashboard);
  els.accountView.classList.toggle("hidden", !isAccount);
  els.rulesView.classList.toggle("hidden", !isRules);
  els.dashboardTab.classList.toggle("active", isDashboard);
  els.accountTab.classList.toggle("active", isAccount);
  els.rulesTab.classList.toggle("active", isRules);
  if (isDashboard) loadDashboard().catch((error) => setStatus(error.message));
  if (isRules) loadRulesView().catch((error) => setStatus(error.message));
};

const renderOAuthControl = () => {
  const account = selectedAccount();
  els.oauthBtn.classList.toggle("hidden", account?.auth_method !== "oauth");
};

const renderAccounts = () => {
  const current = els.accountSelect.value;
  els.accountSelect.innerHTML = state.accounts.map((account) => (
    `<option value="${escapeHtml(account.id)}">${escapeHtml(account.id)} ${account.enabled ? "" : "(off)"}</option>`
  )).join("");
  if (current) els.accountSelect.value = current;
  renderOAuthControl();
};

const renderStats = (stats) => {
  const totals = stats.messages || stats;
  els.stats.textContent = `total ${totals.total || 0} | included ${totals.included || 0} | candidate ${totals.candidate || 0} | excluded ${totals.excluded || 0}`;
};

const renderDashboardStats = (dashboard) => {
  const messages = dashboard?.stats?.messages || {};
  const summary = dashboard?.summary || {};
  const chips = [
    ["accounts", `${fmtNumber(summary.enabledAccounts)}/${fmtNumber(summary.accounts)}`],
    ["local", fmtNumber(summary.localTotal)],
    ["server", fmtNumber(summary.serverTotal)],
    ["candidate", fmtNumber(messages.candidate)],
    ["included", fmtNumber(messages.included)],
    ["excluded", fmtNumber(messages.excluded)],
    ["exported", fmtNumber(summary.exported)],
  ];
  els.dashboardStats.innerHTML = chips.map(([label, value]) => `<div class="stat-chip"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`).join("");
};

const renderDashboardAccounts = (accounts) => {
  if (!accounts?.length) {
    els.dashboardAccounts.innerHTML = `<div class="meta">No accounts configured.</div>`;
    return;
  }
  els.dashboardAccounts.innerHTML = `
    <div class="account-row account-row-head">
      <span>account</span><span>auth</span><span>local</span><span>server</span><span>last sync</span>
    </div>
    ${accounts.map((account) => `
      <div class="account-row ${account.enabled ? "" : "muted-row"}" data-account-open="${escapeHtml(account.id)}">
        <span>${escapeHtml(account.id)}</span>
        <span>${escapeHtml(account.auth_method || "password")}</span>
        <span>${fmtNumber(account.message_count)}</span>
        <span>${fmtNumber(account.server_total)}</span>
        <span>${escapeHtml(shortDate(account.sync_last_at || account.last_sync_at) || "-")}</span>
      </div>
    `).join("")}`;
};

const renderDashboardRecent = (messages) => {
  if (!messages?.length) {
    els.dashboardRecent.innerHTML = `<div class="meta">No local messages yet.</div>`;
    return;
  }
  els.dashboardRecent.innerHTML = messages.map((msg) => `
    <div class="recent-row" data-recent-id="${escapeHtml(msg.id)}">
      <span class="message-date">${escapeHtml(shortDate(msg.sent_at || msg.fetched_at))}</span>
      <span class="message-from">${escapeHtml(msg.account_id)}</span>
      <span class="message-subject">${escapeHtml(msg.subject || "(no subject)")}</span>
      <span class="message-state ${escapeHtml(msg.include_state)}">${escapeHtml(msg.include_state)}</span>
    </div>
  `).join("");
};

const renderDashboard = (dashboard) => {
  state.dashboard = dashboard;
  renderDashboardStats(dashboard);
  renderDashboardAccounts(dashboard.accounts || []);
  renderDashboardRecent(dashboard.recent || []);
};

const loadDashboard = async () => {
  const limit = Number(els.recentLimitInput.value || 30);
  const dashboard = await api(`/api/dashboard?limit=${encodeURIComponent(limit)}`);
  renderDashboard(dashboard);
};

const countRequestPayload = () => ({
  accountId: els.accountSelect.value,
  since: els.sinceInput.value,
  before: els.beforeInput.value,
});

const renderServerCount = (payload) => {
  const boxes = payload.mailboxes || [];
  const detail = boxes.map((box) => (
    `${box.mailbox}: server ${box.total}, filter ${box.matched}, new ${box.newAvailable ?? "-"}, local ${box.localStored ?? box.stored}`
  )).join(" | ");
  els.serverCount.textContent = detail || `server ${payload.total || 0}, filter ${payload.matched || 0}, new ${payload.newAvailable ?? "-"}, local ${payload.localStored ?? payload.stored ?? 0}`;
};

const renderMessages = () => {
  if (!state.messages.length) {
    els.messageList.innerHTML = `<div class="message-row"><span></span><span class="message-subject">No messages</span><span></span></div>`;
    return;
  }
  const compact = els.compactToggle.checked;
  els.messageList.innerHTML = state.messages.map((msg) => {
    const tags = msg.tags ? String(msg.tags).split(",").filter(Boolean).join(" #") : "";
    const sender = msg.sender_email || msg.sender_name || "";
    if (compact) {
      return `
        <div class="message-row compact ${msg.id === state.selectedId ? "active" : ""}" data-id="${escapeHtml(msg.id)}">
          <div class="message-date">${escapeHtml(shortDate(msg.sent_at || msg.fetched_at))}</div>
          <span class="sender-pill" title="${escapeHtml(sender)}">${escapeHtml(shorten(sender, 18))}</span>
          <div class="message-subject" title="${escapeHtml(msg.subject || "(no subject)")}">${escapeHtml(shorten(msg.subject || "(no subject)", 68))}</div>
          <div class="message-state ${escapeHtml(msg.include_state)}">${escapeHtml(msg.include_state)}</div>
        </div>`;
    }
    return `
      <div class="message-row ${msg.id === state.selectedId ? "active" : ""}" data-id="${escapeHtml(msg.id)}">
        <div class="message-date">${escapeHtml(shortDate(msg.sent_at || msg.fetched_at))}</div>
        <div>
          <div class="message-subject">${escapeHtml(msg.subject || "(no subject)")}</div>
          <div class="message-from">${escapeHtml(sender)}</div>
          <div class="message-tags">${tags ? `#${escapeHtml(tags)}` : ""}</div>
        </div>
        <div class="message-state ${escapeHtml(msg.include_state)}">${escapeHtml(msg.include_state)}</div>
      </div>`;
  }).join("");
};

const renderRules = () => {
  els.ruleList.innerHTML = state.rules.length ? state.rules.map((rule) => `
    <div class="rule-card">
      <strong>${escapeHtml(rule.name)}</strong>
      <div class="meta">scope: ${escapeHtml(rule.scope || "global")}${rule.account_id ? ` / ${escapeHtml(rule.account_id)}` : ""}</div>
      <div class="meta">${escapeHtml(rule.field)} ${escapeHtml(rule.operator)} ${escapeHtml(rule.pattern)}</div>
      <div class="meta">${escapeHtml(rule.action)}${rule.tag ? ` #${escapeHtml(rule.tag)}` : ""}</div>
      <button data-rule-delete="${escapeHtml(rule.id)}" type="button">Delete</button>
    </div>
  `).join("") : `<div class="meta">No rules.</div>`;
};

const ruleMatchesFilters = (rule) => {
  const query = els.rulesSearch.value.trim().toLowerCase();
  const tag = els.rulesTagFilter.value.trim().toLowerCase();
  const scope = els.rulesScopeFilter.value;
  const action = els.rulesActionFilter.value;
  const haystack = [
    rule.name,
    rule.scope,
    rule.account_id,
    rule.field,
    rule.operator,
    rule.pattern,
    rule.action,
    rule.tag,
  ].map((value) => String(value || "").toLowerCase()).join(" ");

  if (query && !haystack.includes(query)) return false;
  if (tag && !String(rule.tag || "").toLowerCase().includes(tag)) return false;
  if (scope === "current" && rule.account_id !== els.accountSelect.value) return false;
  if (scope && scope !== "current" && rule.scope !== scope) return false;
  if (action && rule.action !== action) return false;
  return true;
};

const renderRulesTable = () => {
  const rules = state.rules.filter(ruleMatchesFilters);
  els.rulesCount.textContent = `${fmtNumber(rules.length)} / ${fmtNumber(state.rules.length)} rules`;
  if (!rules.length) {
    els.rulesTable.innerHTML = `<div class="meta empty-table">No rules match the current filters.</div>`;
    return;
  }
  els.rulesTable.innerHTML = `
    <div class="rules-row rules-row-head">
      <span>on</span><span>title</span><span>scope</span><span>action</span><span>tag</span><span>match</span><span>updated</span><span></span>
    </div>
    ${rules.map((rule) => `
      <div class="rules-row">
        <span><input data-rule-toggle="${escapeHtml(rule.id)}" type="checkbox" ${rule.enabled ? "checked" : ""} aria-label="Toggle rule"></span>
        <span class="rule-title" title="${escapeHtml(rule.name)}">${escapeHtml(rule.name || `rule ${rule.id}`)}</span>
        <span>${escapeHtml(rule.scope || "global")}${rule.account_id ? ` <em>${escapeHtml(rule.account_id)}</em>` : ""}</span>
        <span class="rule-action ${escapeHtml(rule.action || "")}">${escapeHtml(rule.action || "-")}</span>
        <span>${rule.tag ? `#${escapeHtml(rule.tag)}` : "-"}</span>
        <span title="${escapeHtml(rule.pattern)}">${escapeHtml(rule.field)} ${escapeHtml(rule.operator)} ${escapeHtml(shorten(rule.pattern, 52))}</span>
        <span>${escapeHtml(shortDate(rule.updated_at || rule.created_at) || "-")}</span>
        <span><button data-rule-table-delete="${escapeHtml(rule.id)}" type="button">Delete</button></span>
      </div>
    `).join("")}`;
};

const loadRulesView = async () => {
  await loadState();
  renderRulesTable();
};

const loadTags = async () => {
  const payload = await api("/api/tags");
  els.tagSuggestions.innerHTML = (payload.tags || []).map((tag) => (
    `<option value="${escapeHtml(tag.tag)}">${escapeHtml(tag.count)}</option>`
  )).join("");
};

const loadState = async () => {
  const payload = await api("/api/state");
  state.accounts = payload.accounts || [];
  state.rules = payload.rules || [];
  renderAccounts();
  renderRules();
  if (state.activeView === "rules") renderRulesTable();
  renderStats(payload.stats || {});
  await loadTags();
};

const loadMessages = async () => {
  const params = new URLSearchParams();
  if (els.searchInput.value.trim()) params.set("q", els.searchInput.value.trim());
  if (els.stateFilter.value) params.set("state", els.stateFilter.value);
  if (els.accountSelect.value) params.set("account", els.accountSelect.value);
  if (els.tagFilter.value.trim()) params.set("tag", els.tagFilter.value.trim());
  params.set("limit", "250");
  const payload = await api(`/api/messages?${params.toString()}`);
  state.messages = payload.messages || [];
  renderMessages();
};

const selectMessage = async (id) => {
  state.selectedId = id;
  renderMessages();
  const payload = await api(`/api/messages/${encodeURIComponent(id)}`);
  const msg = payload.message;
  if (msg?.account_id) els.accountSelect.value = msg.account_id;
  els.messageActions.classList.remove("hidden");
  els.messageDetail.classList.remove("empty");
  els.messageDetail.innerHTML = `
    <h2>${escapeHtml(msg.subject || "(no subject)")}</h2>
    <div class="meta">${escapeHtml(msg.sender_name || "")} &lt;${escapeHtml(msg.sender_email || "")}&gt;</div>
    <div class="meta">${escapeHtml(msg.sent_at || "")} | ${escapeHtml(msg.account_id)} / ${escapeHtml(msg.mailbox)}</div>
    <div class="meta">state: ${escapeHtml(msg.include_state)} | tags: ${escapeHtml((msg.tags || []).map((tag) => tag.tag).join(", "))}</div>
    <pre>${escapeHtml(msg.body_markdown || msg.body_text || "")}</pre>`;
};

const createSenderRuleForSelected = async (action) => {
  if (!state.selectedId) return;
  const payload = await api(`/api/messages/${encodeURIComponent(state.selectedId)}`);
  const msg = payload.message;
  const sender = String(msg?.sender_email || "").trim().toLowerCase();
  if (!sender) {
    setStatus("Selected message has no sender email");
    return;
  }
  await post("/api/rules", {
    name: `${action} sender ${sender}`,
    scope: "account",
    accountId: msg.account_id,
    field: "sender_email",
    operator: "equals",
    pattern: sender,
    action,
  });
  const applied = await post("/api/rules/apply");
  setStatus(`${action === "include" ? "Included" : "Excluded"} sender ${sender}; matched ${applied.matches}`);
  await loadState();
  await loadMessages();
  await selectMessage(state.selectedId);
};

const refresh = async () => {
  setStatus("Refreshing...");
  await loadState();
  if (state.activeView === "dashboard") {
    await loadDashboard();
  } else if (state.activeView === "rules") {
    renderRulesTable();
  } else {
    await loadMessages();
  }
  setStatus("Ready");
};

els.refreshBtn.addEventListener("click", () => refresh().catch((error) => setStatus(error.message)));
els.dashboardTab.addEventListener("click", () => setActiveView("dashboard"));
els.accountTab.addEventListener("click", () => setActiveView("account"));
els.rulesTab.addEventListener("click", () => setActiveView("rules"));
els.rulesSearch.addEventListener("input", renderRulesTable);
els.rulesTagFilter.addEventListener("input", renderRulesTable);
els.rulesScopeFilter.addEventListener("change", renderRulesTable);
els.rulesActionFilter.addEventListener("change", renderRulesTable);
els.recentLimitInput.addEventListener("change", () => loadDashboard().catch((error) => setStatus(error.message)));
els.searchInput.addEventListener("input", () => loadMessages().catch((error) => setStatus(error.message)));
els.stateFilter.addEventListener("change", () => loadMessages().catch((error) => setStatus(error.message)));
els.tagFilter.addEventListener("input", () => loadMessages().catch((error) => setStatus(error.message)));
els.accountSelect.addEventListener("change", () => {
  renderOAuthControl();
  els.serverCount.textContent = "";
  loadMessages().catch((error) => setStatus(error.message));
});
els.compactToggle.addEventListener("change", () => {
  applyCompactMode(els.compactToggle.checked);
  renderMessages();
});
els.sinceInput.addEventListener("change", () => { els.serverCount.textContent = ""; });
els.beforeInput.addEventListener("change", () => { els.serverCount.textContent = ""; });

els.dashboardAccounts.addEventListener("click", (event) => {
  const row = event.target.closest("[data-account-open]");
  if (!row) return;
  els.accountSelect.value = row.dataset.accountOpen;
  setActiveView("account");
  loadMessages().catch((error) => setStatus(error.message));
});

els.dashboardRecent.addEventListener("click", (event) => {
  const row = event.target.closest("[data-recent-id]");
  if (!row) return;
  setActiveView("account");
  selectMessage(row.dataset.recentId).catch((error) => setStatus(error.message));
});

els.messageList.addEventListener("click", (event) => {
  const row = event.target.closest("[data-id]");
  if (!row) return;
  selectMessage(row.dataset.id).catch((error) => setStatus(error.message));
});

els.countBtn.addEventListener("click", async () => {
  setStatus("Counting server messages...");
  const payload = await post("/api/count", countRequestPayload());
  renderServerCount(payload);
  setStatus(`Server count: ${payload.matched} matching / ${payload.total} total, ${payload.newAvailable || 0} new`);
  await loadDashboard();
});

els.countAllBtn.addEventListener("click", async () => {
  setStatus("Counting all accounts...");
  startProgressPolling();
  try {
    const payload = await post("/api/count-all", {});
    els.dashboardStatus.textContent = `server ${fmtNumber(payload.total)}, new ${fmtNumber(payload.newAvailable)}, local ${fmtNumber(payload.localStored)}`;
    setStatus(`Counted all accounts: ${payload.newAvailable || 0} new`);
    await loadDashboard();
  } finally {
    stopProgressPolling();
  }
});

els.fetchNewBtn.addEventListener("click", async () => {
  setStatus("Fetching new messages...");
  startProgressPolling();
  try {
    const payload = await post("/api/fetch-new", {
      accountId: els.accountSelect.value,
      since: els.sinceInput.value,
      before: els.beforeInput.value,
      limit: Number(els.fetchLimitInput.value || 500),
    });
    renderServerCount(payload);
    setStatus(`Fetched ${payload.fetched} new messages from ${payload.matched || 0} new candidates`);
    await refresh();
  } finally {
    stopProgressPolling();
  }
});

els.fetchNewAllBtn.addEventListener("click", async () => {
  setStatus("Fetching new mail from all accounts...");
  startProgressPolling();
  try {
    const payload = await post("/api/fetch-new-all", { limit: Number(els.fetchLimitInput.value || 500) });
    els.dashboardStatus.textContent = `fetched ${fmtNumber(payload.fetched)}, candidates ${fmtNumber(payload.matched)}`;
    setStatus(`Fetched ${payload.fetched} new messages across all accounts`);
    await refresh();
  } finally {
    stopProgressPolling();
  }
});

els.fetchBtn.addEventListener("click", async () => {
  setStatus("Fetching all/range...");
  startProgressPolling();
  try {
    const payload = await post("/api/fetch", {
      accountId: els.accountSelect.value,
      since: els.sinceInput.value,
      before: els.beforeInput.value,
      limit: Number(els.fetchLimitInput.value || 500),
    });
    renderServerCount(payload);
    setStatus(`Fetched ${payload.fetched} new messages from ${payload.matched || 0} matching`);
    await refresh();
  } finally {
    stopProgressPolling();
  }
});

els.oauthBtn.addEventListener("click", async () => {
  const accountId = els.accountSelect.value;
  setStatus("Starting OAuth login...");
  const payload = await post("/api/oauth/start", { accountId });
  els.oauthPanel.classList.remove("hidden");
  els.oauthPanel.innerHTML = `
    <div><strong>OAuth Login:</strong> ${escapeHtml(accountId)}</div>
    <div>${escapeHtml(payload.message || "Open the verification URL and enter the code.")}</div>
    <div>URL: <a href="${escapeHtml(payload.verificationUri)}" target="_blank" rel="noreferrer">${escapeHtml(payload.verificationUri)}</a></div>
    ${payload.userCode ? `<div>Code: <strong>${escapeHtml(payload.userCode)}</strong></div>` : ""}
  `;
  setStatus("Waiting for OAuth login...");
  const intervalMs = Math.max(5, Number(payload.interval || 5)) * 1000;
  const deadline = Date.now() + Math.max(60, Number(payload.expiresIn || 900)) * 1000;
  const poll = async () => {
    if (Date.now() > deadline) {
      setStatus("OAuth login expired");
      return;
    }
    const result = await post("/api/oauth/poll", { accountId });
    if (result.pending) {
      window.setTimeout(() => poll().catch((error) => setStatus(error.message)), intervalMs);
      return;
    }
    els.oauthPanel.classList.add("hidden");
    setStatus("OAuth login complete");
  };
  window.setTimeout(() => poll().catch((error) => setStatus(error.message)), intervalMs);
});

els.applyRulesBtn.addEventListener("click", async () => {
  const payload = await post("/api/rules/apply");
  setStatus(`Rules matched ${payload.matches}, changed ${payload.changed}`);
  await refresh();
});

els.exportBtn.addEventListener("click", async () => {
  const payload = await post("/api/export", { state: els.stateFilter.value || "included", accountId: els.accountSelect.value });
  setStatus(`Exported ${payload.exported} markdown files`);
  await refresh();
});

els.saveRuleBtn.addEventListener("click", async () => {
  await post("/api/rules", {
    name: els.ruleName.value,
    scope: els.ruleScope.value,
    accountId: els.ruleScope.value === "account" ? els.accountSelect.value : "",
    field: els.ruleField.value,
    operator: els.ruleOperator.value,
    pattern: els.rulePattern.value,
    action: els.ruleAction.value,
    tag: els.ruleTag.value,
  });
  els.rulePattern.value = "";
  await refresh();
});

els.ruleList.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-rule-delete]");
  if (!button) return;
  await post("/api/rules/delete", { id: button.dataset.ruleDelete });
  await refresh();
});

els.rulesTable.addEventListener("change", async (event) => {
  const checkbox = event.target.closest("[data-rule-toggle]");
  if (!checkbox) return;
  const rule = state.rules.find((item) => String(item.id) === String(checkbox.dataset.ruleToggle));
  if (!rule) return;
  await post("/api/rules", {
    id: rule.id,
    name: rule.name,
    enabled: checkbox.checked,
    scope: rule.scope,
    accountId: rule.account_id || "",
    field: rule.field,
    operator: rule.operator,
    pattern: rule.pattern,
    action: rule.action,
    tag: rule.tag || "",
  });
  await loadRulesView();
});

els.rulesTable.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-rule-table-delete]");
  if (!button) return;
  await post("/api/rules/delete", { id: button.dataset.ruleTableDelete });
  await refresh();
});

els.messageActions.addEventListener("click", async (event) => {
  const senderRuleButton = event.target.closest("[data-sender-rule]");
  if (senderRuleButton) {
    await createSenderRuleForSelected(senderRuleButton.dataset.senderRule);
    return;
  }
  const button = event.target.closest("[data-state]");
  if (!button || !state.selectedId) return;
  await post("/api/messages/tag", { messageId: state.selectedId, state: button.dataset.state });
  await selectMessage(state.selectedId);
  await loadMessages();
});

els.tagBtn.addEventListener("click", async () => {
  if (!state.selectedId || !els.tagInput.value.trim()) return;
  await post("/api/messages/tag", { messageId: state.selectedId, tag: els.tagInput.value.trim() });
  els.tagInput.value = "";
  await selectMessage(state.selectedId);
  await loadMessages();
});

loadCompactMode();
applyEmailTheme().finally(() => refresh().catch((error) => setStatus(error.message)));
