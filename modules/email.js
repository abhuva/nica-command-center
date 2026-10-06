/**
 * Renders the Email DB tool as an embedded local-server page.
 * @param {{head: HTMLElement, body: HTMLElement}} shell - Module shell returned by homepage renderer.
 * @param {{url?: string}} moduleSettings - Module settings from effective config.
 * @returns {Promise<() => void>} Cleanup callback.
 */
export async function renderEmailModule(shell, moduleSettings) {
  const url = String(moduleSettings?.url || "http://127.0.0.1:4176/email.html").trim();

  const actions = document.createElement("div");
  actions.className = "module-head-actions";

  const openLink = document.createElement("a");
  openLink.className = "module-head-icon-btn";
  openLink.href = url;
  openLink.target = "_blank";
  openLink.rel = "noreferrer";
  openLink.title = "Email DB in neuem Tab oeffnen";
  openLink.setAttribute("aria-label", "Email DB in neuem Tab oeffnen");
  openLink.textContent = "open";
  actions.appendChild(openLink);
  shell.head.appendChild(actions);

  const hint = document.createElement("p");
  hint.className = "module-copy email-hint";
  hint.textContent = "Laedt Email DB vom lokalen Preview-Server. Falls nichts erscheint: Email preview starten.";

  const frame = document.createElement("iframe");
  frame.className = "email-embed-frame";
  frame.src = url;
  frame.title = "Email DB";
  frame.loading = "lazy";
  frame.setAttribute("aria-label", "Email DB");

  shell.body.classList.add("email-module-body");
  shell.body.appendChild(hint);
  shell.body.appendChild(frame);

  return () => {
    shell.body.classList.remove("email-module-body");
    shell.body.innerHTML = "";
    actions.remove();
  };
}
