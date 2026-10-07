const state = {
  accounts: [],
  rules: [],
  messages: [],
  selectedId: null,
  activeView: "dashboard",
  dashboard: null,
  ruleSort: { key: "", dir: "" },
  runtimeMode: "unknown",
  writesEnabled: false,
  writeCapabilities: {},
  exportPlanToken: "",
};

const THEME_CACHE_KEY = "email-theme-bootstrap-v1";
const COMPACT_CACHE_KEY = "email-account-compact-v1";
const rootEl = document.documentElement;

const els = {
  runtimeBadge: document.querySelector("#runtimeBadge"),
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
  dashboardAccountsTab: document.querySelector("#dashboardAccountsTab"),
  dashboardMailTab: document.querySelector("#dashboardMailTab"),
  dashboardAccountsPanel: document.querySelector("#dashboardAccountsPanel"),
  dashboardMailPanel: document.querySelector("#dashboardMailPanel"),
  dashboardMessageActions: document.querySelector("#dashboardMessageActions"),
  dashboardMessageDetail: document.querySelector("#dashboardMessageDetail"),
  dashboardTagInput: document.querySelector("#dashboardTagInput"),
  dashboardTagBtn: document.querySelector("#dashboardTagBtn"),
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
  exportPanel: document.querySelector("#exportPanel"),
  exportSummary: document.querySelector("#exportSummary"),
  exportApplyBtn: document.querySelector("#exportApplyBtn"),
  exportCancelBtn: document.querySelector("#exportCancelBtn"),
  searchInput: document.querySelector("#searchInput"),
  stateFilter: document.querySelector("#stateFilter"),
  tagFilter: document.querySelector("#tagFilter"),
  groupFilter: document.querySelector("#groupFilter"),
  groupSort: document.querySelector("#groupSort"),
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

const CAPABILITY_CONTROL_SELECTORS = {
  mailCount: "#countAllBtn, #countBtn",
  mailFetch: "#fetchNewAllBtn, #fetchNewBtn, #fetchBtn",
  messageTag: "#dashboardTagBtn, #tagBtn, [data-state]",
  oauthManage: "#oauthBtn",
  rulesApply: "#applyRulesBtn",
  rulesManage: [
    "#saveRuleBtn",
    "#ruleName",
    "#ruleScope",
    "#ruleField",
    "#ruleOperator",
    "#rulePattern",
    "#ruleAction",
    "#ruleTag",
    "[data-rule-delete]",
    "[data-rule-table-delete]",
    "[data-rule-toggle]",
    "[data-rule-edit]",
  ].join(","),
  vaultExport: "#exportBtn",
};
const ROUTE_CAPABILITIES = {
  "/api/count": "mailCount",
  "/api/count-all": "mailCount",
  "/api/fetch": "mailFetch",
  "/api/fetch-new": "mailFetch",
  "/api/fetch-new-all": "mailFetch",
  "/api/export": "vaultExport",
  "/api/export/plan": "vaultExport",
  "/api/export/apply": "vaultExport",
  "/api/rules": "rulesManage",
  "/api/rules/delete": "rulesManage",
  "/api/rules/apply": "rulesApply",
  "/api/messages/tag": "messageTag",
  "/api/oauth/start": "oauthManage",
  "/api/oauth/poll": "oauthManage",
};

const capabilityEnabled = (name) => state.writeCapabilities.unrestricted === true || state.writeCapabilities[name] === true;

const setRuntimeControlState = (control, enabled, label) => {
  if (!enabled && !control.disabled) {
    control.dataset.runtimeDisabled = "true";
    control.disabled = true;
    control.title = `Disabled: ${label} capability is not enabled`;
  } else if (enabled && control.dataset.runtimeDisabled === "true") {
    control.disabled = false;
    delete control.dataset.runtimeDisabled;
    control.removeAttribute("title");
  }
};

const applyRuntimeMode = () => {
  const readOnly = !state.writesEnabled;
  document.body.dataset.writesEnabled = String(state.writesEnabled);
  if (els.runtimeBadge) {
    els.runtimeBadge.textContent = readOnly
      ? "Migration candidate · read-only"
      : state.runtimeMode === "limited-write"
        ? "Migration candidate · limited write"
        : "Migration candidate";
  }
  Object.entries(CAPABILITY_CONTROL_SELECTORS).forEach(([capability, selector]) => {
    document.querySelectorAll(selector).forEach((control) => {
      setRuntimeControlState(control, capabilityEnabled(capability), capability);
    });
  });
  document.querySelectorAll("[data-sender-rule]").forEach((control) => {
    setRuntimeControlState(control, capabilityEnabled("rulesManage") && capabilityEnabled("rulesApply"), "rulesManage + rulesApply");
  });
  if (!capabilityEnabled("vaultExport")) clearExportPlan();
};

const runtimeReadyStatus = () => {
  if (state.runtimeMode === "limited-write") {
    if (capabilityEnabled("vaultExport")) {
      return "Ready · bounded Email export";
    }
    if (capabilityEnabled("oauthManage")) {
      return "Ready · bounded Email OAuth";
    }
    const classificationEnabled = capabilityEnabled("messageTag")
      && capabilityEnabled("rulesApply")
      && capabilityEnabled("rulesManage");
    return classificationEnabled
      ? "Ready · bounded Email classification"
      : "Ready · bounded Email fetch";
  }
  return state.writesEnabled ? "Ready" : "Ready · read-only shadow";
};

const post = (path, payload = {}) => {
  const capability = ROUTE_CAPABILITIES[path];
  if (!capability || !capabilityEnabled(capability)) {
    return Promise.reject(new Error(`Action disabled: ${capability || "unknown"} capability is not enabled`));
  }
  return api(path, { method: "POST", body: JSON.stringify(payload) });
};
const setStatus = (text) => { els.status.textContent = text; };
const fmtNumber = (value) => Number(value || 0).toLocaleString("de-DE");
let progressTimer = null;
let exportPlanRequestVersion = 0;

const clearExportPlan = () => {
  exportPlanRequestVersion += 1;
  state.exportPlanToken = "";
  els.exportSummary.textContent = "";
  els.exportApplyBtn.disabled = true;
  els.exportPanel.classList.add("hidden");
};

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
  applyRuntimeMode();
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
      <span>account</span><span>auth</span><span>local</span><span title="included">inc</span><span title="excluded">ex</span><span title="candidate">can</span><span>server</span><span>last sync</span>
    </div>
    ${accounts.map((account) => `
      <div class="account-row ${account.enabled ? "" : "muted-row"}" data-account-open="${escapeHtml(account.id)}">
        <span>${escapeHtml(account.id)}</span>
        <span>${escapeHtml(account.auth_method || "password")}</span>
        <span>${fmtNumber(account.message_count)}</span>
        <span title="included">${fmtNumber(account.included_count)}</span>
        <span title="excluded">${fmtNumber(account.excluded_count)}</span>
        <span title="candidate">${fmtNumber(account.candidate_count)}</span>
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
      <span class="recent-tags" title="${escapeHtml(messageTags(msg).join(", "))}">${escapeHtml(messageTags(msg).map((tag) => `#${tag}`).join(" "))}</span>
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

const setDashboardAccountPanel = (panel) => {
  const showMail = panel === "mail";
  els.dashboardAccountsPanel.classList.toggle("hidden", showMail);
  els.dashboardMailPanel.classList.toggle("hidden", !showMail);
  els.dashboardAccountsTab.classList.toggle("active", !showMail);
  els.dashboardMailTab.classList.toggle("active", showMail);
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

const messageSender = (msg) => msg.sender_email || msg.sender_name || "";

const messageTags = (msg) => String(msg.tags || "").split(",").map((tag) => tag.trim()).filter(Boolean);

const renderMessageRow = (msg, compact) => {
  const tags = messageTags(msg).join(" #");
  const sender = messageSender(msg);
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
};

const messageGroupLabel = (msg, groupBy) => {
  if (groupBy === "sender") return messageSender(msg) || "(unknown sender)";
  if (groupBy === "state") return msg.include_state || "(no state)";
  if (groupBy === "mailbox") return msg.mailbox || "(no mailbox)";
  if (groupBy === "date") return shortDate(msg.sent_at || msg.fetched_at) || "(no date)";
  if (groupBy === "tag") return messageTags(msg)[0] || "(untagged)";
  return "";
};

const groupedMessages = (messages, groupBy) => {
  const groups = new Map();
  for (const msg of messages) {
    const label = messageGroupLabel(msg, groupBy);
    if (!groups.has(label)) groups.set(label, []);
    groups.get(label).push(msg);
  }
  const entries = [...groups.entries()];
  if (els.groupSort.value === "size") {
    return entries.sort(([leftLabel, leftMessages], [rightLabel, rightMessages]) => (
      rightMessages.length - leftMessages.length || leftLabel.localeCompare(rightLabel, undefined, { sensitivity: "base" })
    ));
  }
  return entries.sort(([leftLabel], [rightLabel]) => leftLabel.localeCompare(rightLabel, undefined, { sensitivity: "base" }));
};

const renderMessages = () => {
  if (!state.messages.length) {
    els.messageList.innerHTML = `<div class="message-row"><span></span><span class="message-subject">No messages</span><span></span></div>`;
    return;
  }
  const compact = els.compactToggle.checked;
  const groupBy = els.groupFilter.value;
  if (!groupBy) {
    els.messageList.innerHTML = state.messages.map((msg) => renderMessageRow(msg, compact)).join("");
    return;
  }
  els.messageList.innerHTML = groupedMessages(state.messages, groupBy).map(([label, messages]) => `
    <section class="message-group">
      <div class="message-group-head">
        <span title="${escapeHtml(label)}">${escapeHtml(shorten(label, 64))}</span>
        <strong>${fmtNumber(messages.length)}</strong>
      </div>
      ${messages.map((msg) => renderMessageRow(msg, compact)).join("")}
    </section>
  `).join("");
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
  applyRuntimeMode();
};

const accountOptionHtml = (selectedId) => state.accounts.map((account) => (
  `<option value="${escapeHtml(account.id)}" ${account.id === selectedId ? "selected" : ""}>${escapeHtml(account.id)}</option>`
)).join("");

const rulePayload = (rule, patch = {}) => {
  const scope = patch.scope ?? rule.scope ?? "global";
  const accountId = scope === "account" ? (patch.accountId ?? rule.account_id ?? els.accountSelect.value ?? state.accounts[0]?.id ?? "") : "";
  return {
    id: rule.id,
    name: patch.name ?? rule.name,
    enabled: patch.enabled ?? Boolean(rule.enabled),
    scope,
    accountId,
    field: patch.field ?? rule.field,
    operator: patch.operator ?? rule.operator,
    pattern: patch.pattern ?? rule.pattern,
    action: patch.action ?? rule.action,
    tag: patch.tag ?? rule.tag ?? "",
  };
};

const saveRulePatch = async (ruleId, patch) => {
  const rule = state.rules.find((item) => String(item.id) === String(ruleId));
  if (!rule) return;
  await post("/api/rules", rulePayload(rule, patch));
  await loadRulesView();
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

const ruleSortValue = (rule, key) => {
  if (key === "enabled") return Number(rule.enabled || 0);
  if (key === "hit_count") return Number(rule.hit_count || 0);
  if (key === "name") return String(rule.name || "").toLowerCase();
  if (key === "scope") return `${String(rule.scope || "global").toLowerCase()} ${String(rule.account_id || "").toLowerCase()}`;
  if (key === "action") return String(rule.action || "").toLowerCase();
  if (key === "tag") return String(rule.tag || "").toLowerCase();
  if (key === "match") return `${String(rule.field || "").toLowerCase()} ${String(rule.operator || "").toLowerCase()} ${String(rule.pattern || "").toLowerCase()}`;
  if (key === "updated_at") return String(rule.updated_at || rule.created_at || "");
  return "";
};

const sortRules = (rules) => {
  if (!state.ruleSort.key || !state.ruleSort.dir) return rules;
  const direction = state.ruleSort.dir === "asc" ? 1 : -1;
  return [...rules].sort((left, right) => {
    const leftValue = ruleSortValue(left, state.ruleSort.key);
    const rightValue = ruleSortValue(right, state.ruleSort.key);
    if (typeof leftValue === "number" || typeof rightValue === "number") {
      return (Number(leftValue) - Number(rightValue)) * direction;
    }
    return String(leftValue).localeCompare(String(rightValue), undefined, { numeric: true, sensitivity: "base" }) * direction;
  });
};

const sortLabel = (key, label) => {
  const active = state.ruleSort.key === key;
  const marker = active ? (state.ruleSort.dir === "asc" ? " ↑" : " ↓") : "";
  return `<button class="rule-sort-btn ${active ? "active" : ""}" data-rule-sort="${escapeHtml(key)}" type="button">${escapeHtml(label)}${marker}</button>`;
};

const renderRulesTable = () => {
  const rules = sortRules(state.rules.filter(ruleMatchesFilters));
  els.rulesCount.textContent = `${fmtNumber(rules.length)} / ${fmtNumber(state.rules.length)} rules`;
  if (!rules.length) {
    els.rulesTable.innerHTML = `<div class="meta empty-table">No rules match the current filters.</div>`;
    applyRuntimeMode();
    return;
  }
  els.rulesTable.innerHTML = `
    <div class="rules-row rules-row-head">
      <span>${sortLabel("enabled", "on")}</span>
      <span title="matched mails">${sortLabel("hit_count", "hits")}</span>
      <span>${sortLabel("name", "title")}</span>
      <span>${sortLabel("scope", "scope")}</span>
      <span>${sortLabel("action", "action")}</span>
      <span>${sortLabel("tag", "tag")}</span>
      <span>${sortLabel("match", "match")}</span>
      <span>${sortLabel("updated_at", "updated")}</span>
      <span></span>
    </div>
    ${rules.map((rule) => `
      <div class="rules-row">
        <span><input data-rule-toggle="${escapeHtml(rule.id)}" type="checkbox" ${rule.enabled ? "checked" : ""} aria-label="Toggle rule"></span>
        <span class="rule-hit-count" title="${escapeHtml(fmtNumber(rule.hit_count))} matched mails">${fmtNumber(rule.hit_count)}</span>
        <span><input class="rule-cell-input rule-title-input" data-rule-edit="${escapeHtml(rule.id)}" data-rule-field="name" type="text" value="${escapeHtml(rule.name || `rule ${rule.id}`)}" title="${escapeHtml(rule.name || "")}"></span>
        <span class="rule-scope-cell">
          <select data-rule-edit="${escapeHtml(rule.id)}" data-rule-field="scope">
            <option value="global" ${(rule.scope || "global") === "global" ? "selected" : ""}>global</option>
            <option value="account" ${rule.scope === "account" ? "selected" : ""}>local</option>
          </select>
          <select data-rule-edit="${escapeHtml(rule.id)}" data-rule-field="accountId" ${rule.scope === "account" ? "" : "disabled"}>
            ${accountOptionHtml(rule.account_id)}
          </select>
        </span>
        <span>
          <select class="rule-action ${escapeHtml(rule.action || "")}" data-rule-edit="${escapeHtml(rule.id)}" data-rule-field="action">
            <option value="include" ${rule.action === "include" ? "selected" : ""}>include</option>
            <option value="exclude" ${rule.action === "exclude" ? "selected" : ""}>exclude</option>
            <option value="tag" ${rule.action === "tag" ? "selected" : ""}>tag</option>
          </select>
        </span>
        <span><input class="rule-cell-input" data-rule-edit="${escapeHtml(rule.id)}" data-rule-field="tag" type="text" value="${escapeHtml(rule.tag || "")}" placeholder="-" list="tagSuggestions"></span>
        <span class="rule-match-cell" title="${escapeHtml(rule.pattern)}">
          <select data-rule-edit="${escapeHtml(rule.id)}" data-rule-field="field">
            <option value="sender_email" ${rule.field === "sender_email" ? "selected" : ""}>sender email</option>
            <option value="sender_domain" ${rule.field === "sender_domain" ? "selected" : ""}>sender domain</option>
            <option value="subject" ${rule.field === "subject" ? "selected" : ""}>subject</option>
            <option value="body" ${rule.field === "body" ? "selected" : ""}>body</option>
            <option value="account_id" ${rule.field === "account_id" ? "selected" : ""}>account</option>
          </select>
          <select data-rule-edit="${escapeHtml(rule.id)}" data-rule-field="operator">
            <option value="contains" ${rule.operator === "contains" ? "selected" : ""}>contains</option>
            <option value="equals" ${rule.operator === "equals" ? "selected" : ""}>equals</option>
            <option value="regex" ${rule.operator === "regex" ? "selected" : ""}>regex</option>
          </select>
          <input class="rule-cell-input" data-rule-edit="${escapeHtml(rule.id)}" data-rule-field="pattern" type="text" value="${escapeHtml(rule.pattern || "")}">
        </span>
        <span>${escapeHtml(shortDate(rule.updated_at || rule.created_at) || "-")}</span>
        <span><button data-rule-table-delete="${escapeHtml(rule.id)}" type="button">Delete</button></span>
      </div>
    `).join("")}`;
  applyRuntimeMode();
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

const renderMessageDetail = (msg, actionsEl, detailEl) => {
  actionsEl.classList.remove("hidden");
  detailEl.classList.remove("empty");
  detailEl.innerHTML = `
    <h2>${escapeHtml(msg.subject || "(no subject)")}</h2>
    <div class="meta">${escapeHtml(msg.sender_name || "")} &lt;${escapeHtml(msg.sender_email || "")}&gt;</div>
    <div class="meta">${escapeHtml(msg.sent_at || "")} | ${escapeHtml(msg.account_id)} / ${escapeHtml(msg.mailbox)}</div>
    <div class="meta">state: ${escapeHtml(msg.include_state)} | tags: ${escapeHtml((msg.tags || []).map((tag) => tag.tag).join(", "))}</div>
    <pre>${escapeHtml(msg.body_markdown || msg.body_text || "")}</pre>`;
  applyRuntimeMode();
};

const selectMessage = async (id, target = "account") => {
  state.selectedId = id;
  if (target === "account") renderMessages();
  const payload = await api(`/api/messages/${encodeURIComponent(id)}`);
  const msg = payload.message;
  if (target === "dashboard") {
    setDashboardAccountPanel("mail");
    renderMessageDetail(msg, els.dashboardMessageActions, els.dashboardMessageDetail);
    return;
  }
  if (msg?.account_id) els.accountSelect.value = msg.account_id;
  renderMessageDetail(msg, els.messageActions, els.messageDetail);
};

const createSenderRuleForSelected = async (action, target = "account") => {
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
  if (target === "dashboard") {
    await loadDashboard();
  } else {
    await loadMessages();
  }
  await selectMessage(state.selectedId, target);
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
  applyRuntimeMode();
  setStatus(runtimeReadyStatus());
};

const loadRuntimeMode = async () => {
  const runtime = await api("/api/ping");
  state.runtimeMode = String(runtime.mode || "unknown");
  state.writesEnabled = runtime.writesEnabled === true;
  state.writeCapabilities = runtime.writeCapabilities || (state.writesEnabled ? { unrestricted: true } : {});
  applyRuntimeMode();
};

els.refreshBtn.addEventListener("click", () => refresh().catch((error) => setStatus(error.message)));
els.dashboardTab.addEventListener("click", () => setActiveView("dashboard"));
els.accountTab.addEventListener("click", () => setActiveView("account"));
els.rulesTab.addEventListener("click", () => setActiveView("rules"));
els.dashboardAccountsTab.addEventListener("click", () => setDashboardAccountPanel("accounts"));
els.dashboardMailTab.addEventListener("click", () => setDashboardAccountPanel("mail"));
els.rulesSearch.addEventListener("input", renderRulesTable);
els.rulesTagFilter.addEventListener("input", renderRulesTable);
els.rulesScopeFilter.addEventListener("change", renderRulesTable);
els.rulesActionFilter.addEventListener("change", renderRulesTable);
els.recentLimitInput.addEventListener("change", () => loadDashboard().catch((error) => setStatus(error.message)));
els.searchInput.addEventListener("input", () => loadMessages().catch((error) => setStatus(error.message)));
els.stateFilter.addEventListener("change", () => {
  clearExportPlan();
  loadMessages().catch((error) => setStatus(error.message));
});
els.tagFilter.addEventListener("input", () => loadMessages().catch((error) => setStatus(error.message)));
els.groupFilter.addEventListener("change", renderMessages);
els.groupSort.addEventListener("change", renderMessages);
els.accountSelect.addEventListener("change", () => {
  clearExportPlan();
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
  clearExportPlan();
  els.accountSelect.value = row.dataset.accountOpen;
  setActiveView("account");
  loadMessages().catch((error) => setStatus(error.message));
});

els.dashboardRecent.addEventListener("click", (event) => {
  const row = event.target.closest("[data-recent-id]");
  if (!row) return;
  selectMessage(row.dataset.recentId, "dashboard").catch((error) => setStatus(error.message));
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
  clearExportPlan();
  const requestVersion = exportPlanRequestVersion;
  setStatus("Planning vault export...");
  const payload = await post("/api/export/plan", {
    state: els.stateFilter.value || "included",
    accountId: els.accountSelect.value,
  });
  if (requestVersion !== exportPlanRequestVersion) return;
  els.exportSummary.textContent = `Export preview: ${fmtNumber(payload.total)} total · ${fmtNumber(payload.create)} new · ${fmtNumber(payload.unchanged)} unchanged · ${fmtNumber(payload.legacyExisting)} existing archive · ${fmtNumber(payload.conflicts)} conflicts`;
  els.exportPanel.classList.remove("hidden");
  state.exportPlanToken = payload.planToken || "";
  els.exportApplyBtn.disabled = !payload.canApply;
  if (payload.conflicts) {
    setStatus("Export blocked by existing files with different content");
  } else if (!payload.total) {
    setStatus("Nothing matches this export selection");
  } else {
    setStatus("Export preview ready · review and apply separately");
  }
});

els.exportApplyBtn.addEventListener("click", async () => {
  const planToken = state.exportPlanToken;
  if (!planToken) {
    setStatus("Export preview is missing; preview again");
    return;
  }
  state.exportPlanToken = "";
  els.exportApplyBtn.disabled = true;
  setStatus("Applying vault export...");
  let payload;
  try {
    payload = await post("/api/export/apply", { planToken });
  } catch (error) {
    clearExportPlan();
    setStatus(error instanceof Error ? error.message : String(error));
    return;
  }
  clearExportPlan();
  await refresh();
  setStatus(`Exported ${payload.exported} markdown files · ${payload.created} new · ${payload.unchanged} unchanged · ${payload.legacyExisting} existing archive`);
});

els.exportCancelBtn.addEventListener("click", () => {
  clearExportPlan();
  setStatus(runtimeReadyStatus());
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
  if (checkbox) {
    await saveRulePatch(checkbox.dataset.ruleToggle, { enabled: checkbox.checked });
    return;
  }
  const field = event.target.closest("[data-rule-edit]");
  if (!field) return;
  if (field.tagName === "INPUT") return;
  await saveRulePatch(field.dataset.ruleEdit, { [field.dataset.ruleField]: field.value });
});

els.rulesTable.addEventListener("click", async (event) => {
  const sortButton = event.target.closest("[data-rule-sort]");
  if (sortButton) {
    const key = sortButton.dataset.ruleSort;
    if (state.ruleSort.key !== key) {
      state.ruleSort = { key, dir: "asc" };
    } else if (state.ruleSort.dir === "asc") {
      state.ruleSort = { key, dir: "desc" };
    } else {
      state.ruleSort = { key: "", dir: "" };
    }
    renderRulesTable();
    return;
  }
  const button = event.target.closest("[data-rule-table-delete]");
  if (!button) return;
  await post("/api/rules/delete", { id: button.dataset.ruleTableDelete });
  await refresh();
});

els.rulesTable.addEventListener("focusout", async (event) => {
  const field = event.target.closest("input[data-rule-edit]");
  if (!field) return;
  await saveRulePatch(field.dataset.ruleEdit, { [field.dataset.ruleField]: field.value });
});

els.rulesTable.addEventListener("keydown", (event) => {
  if (event.key !== "Enter") return;
  const field = event.target.closest("input[data-rule-edit]");
  if (!field) return;
  field.blur();
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

els.dashboardMessageActions.addEventListener("click", async (event) => {
  const senderRuleButton = event.target.closest("[data-sender-rule]");
  if (senderRuleButton) {
    await createSenderRuleForSelected(senderRuleButton.dataset.senderRule, "dashboard");
    return;
  }
  const button = event.target.closest("[data-state]");
  if (!button || !state.selectedId) return;
  await post("/api/messages/tag", { messageId: state.selectedId, state: button.dataset.state });
  await loadDashboard();
  await selectMessage(state.selectedId, "dashboard");
});

els.tagBtn.addEventListener("click", async () => {
  if (!state.selectedId || !els.tagInput.value.trim()) return;
  await post("/api/messages/tag", { messageId: state.selectedId, tag: els.tagInput.value.trim() });
  els.tagInput.value = "";
  await selectMessage(state.selectedId);
  await loadMessages();
});

els.dashboardTagBtn.addEventListener("click", async () => {
  if (!state.selectedId || !els.dashboardTagInput.value.trim()) return;
  await post("/api/messages/tag", { messageId: state.selectedId, tag: els.dashboardTagInput.value.trim() });
  els.dashboardTagInput.value = "";
  await loadDashboard();
  await selectMessage(state.selectedId, "dashboard");
});

loadCompactMode();
applyEmailTheme().finally(() => {
  loadRuntimeMode()
    .then(refresh)
    .catch((error) => setStatus(error.message));
});
