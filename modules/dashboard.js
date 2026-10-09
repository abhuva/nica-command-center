/**
 * Renders the shared service dashboard and its bounded open actions.
 * @param {{body: HTMLElement}} shell - Module shell returned by the homepage renderer.
 * @returns {Promise<() => void>} Cleanup callback.
 */
export async function renderDashboardModule(shell) {
  const status = document.createElement("div");
  status.className = "status dashboard-status";
  status.setAttribute("aria-live", "polite");

  const grid = document.createElement("div");
  grid.className = "dashboard-grid";

  shell.body.classList.add("dashboard-module-body");
  shell.body.appendChild(status);
  shell.body.appendChild(grid);

  /**
   * Updates dashboard feedback without exposing target paths or URLs.
   * @param {string} text - User-facing status text.
   * @param {"ok"|"err"|""} [state] - Optional status state.
   * @returns {void}
   */
  function setStatus(text, state = "") {
    status.textContent = text || "";
    status.classList.remove("ok", "err");
    if (state === "ok") status.classList.add("ok");
    if (state === "err") status.classList.add("err");
  }

  /**
   * Requests one allow-listed dashboard action from the local Homepage service.
   * @param {object} item - Dashboard entry returned by `/api/dashboard`.
   * @param {HTMLButtonElement} button - Trigger button to temporarily disable.
   * @returns {Promise<void>}
   */
  async function openItem(item, button) {
    const managed = item.action === "start-or-open";
    setStatus(managed ? `Starte oder oeffne ${item.title} ...` : `Oeffne ${item.title} ...`);
    button.disabled = true;
    try {
      const response = await fetch(managed ? "/api/dashboard/start" : "/api/dashboard/open", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: item.id })
      });
      if (!response.ok) {
        const text = await response.text();
        throw new Error(text || "Dashboard-Ziel konnte nicht geoeffnet werden");
      }
      setStatus(managed ? `${item.title} ist bereit und wurde geoeffnet.` : `${item.title} geoeffnet.`, "ok");
    } catch (error) {
      setStatus(`Konnte ${item.title} nicht oeffnen: ${error.message || error}`, "err");
    } finally {
      button.disabled = false;
    }
  }

  /**
   * Replaces the grid with the current shared, enabled service entries.
   * @param {Array<object>} items - Normalized dashboard entries.
   * @returns {void}
   */
  function renderItems(items) {
    grid.innerHTML = "";
    if (!items.length) {
      const empty = document.createElement("div");
      empty.className = "empty dashboard-empty";
      empty.textContent = "Keine gemeinsamen Dienste aktiviert.";
      grid.appendChild(empty);
      return;
    }

    for (const item of items) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "dashboard-entry";
      button.dataset.dashboardId = String(item.id || "");

      const icon = document.createElement("span");
      icon.className = "dashboard-entry-icon";
      icon.setAttribute("aria-hidden", "true");
      icon.textContent = String(item.icon || "\ud83e\udde9");

      const copy = document.createElement("span");
      copy.className = "dashboard-entry-copy";
      const title = document.createElement("span");
      title.className = "dashboard-entry-title";
      title.textContent = String(item.title || item.id || "Dienst");
      const description = document.createElement("span");
      description.className = "dashboard-entry-description";
      description.textContent = String(item.description || "");
      copy.appendChild(title);
      copy.appendChild(description);

      const arrow = document.createElement("span");
      arrow.className = "dashboard-entry-arrow";
      arrow.setAttribute("aria-hidden", "true");
      arrow.textContent = item.action === "start-or-open" ? "Start" : "\u2197";

      button.appendChild(icon);
      button.appendChild(copy);
      button.appendChild(arrow);
      button.addEventListener("click", () => {
        void openItem(item, button);
      });
      grid.appendChild(button);
    }
  }

  setStatus("Lade gemeinsame Dienste...");
  try {
    const response = await fetch("/api/dashboard", { cache: "no-store" });
    if (!response.ok) {
      const text = await response.text();
      throw new Error(text || "Dashboard konnte nicht geladen werden");
    }
    const payload = await response.json();
    renderItems(Array.isArray(payload?.items) ? payload.items : []);
    setStatus("");
  } catch (error) {
    renderItems([]);
    setStatus(`Dashboard-Fehler: ${error.message || error}`, "err");
  }

  return () => {
    shell.body.classList.remove("dashboard-module-body");
    shell.body.innerHTML = "";
  };
}
