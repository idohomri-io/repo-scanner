const headerSubtitle = document.getElementById("header-subtitle");
const overviewCards = document.getElementById("overview-cards");
const statusBannerWrap = document.getElementById("status-banner-wrap");
const repoHealthBody = document.getElementById("repo-health-body");
const affectedPackagesBody = document.getElementById("affected-packages-body");
const findingsTableWrap = document.getElementById("findings-table-wrap");
const appMain = document.getElementById("app-main");

const searchInput = document.getElementById("search-input");
const severityFilter = document.getElementById("severity-filter");
const packageFilter = document.getElementById("package-filter");
const scannerFilter = document.getElementById("scanner-filter");
const themeToggle = document.getElementById("theme-toggle");
const scanNowButton = document.getElementById("scan-now");
const scanNowLabel = document.getElementById("scan-now-label");

const drawer = document.getElementById("finding-drawer");
const drawerBackdrop = document.getElementById("drawer-backdrop");
const drawerSeverity = document.getElementById("drawer-severity");
const drawerPackage = document.getElementById("drawer-package");
const drawerBody = document.getElementById("drawer-body");
const drawerClose = document.getElementById("drawer-close");

const runLogModal = document.getElementById("run-log-modal");
const runLogTitle = document.getElementById("run-log-title");
const runLogBody = document.getElementById("run-log-body");
const runLogClose = document.getElementById("run-log-close");

const SEVERITY_ORDER = ["critical", "high", "moderate", "low", "unknown"];
const SEVERITY_LABEL = { critical: "Critical", high: "High", moderate: "Moderate", low: "Low", unknown: "Unknown" };

let allFindings = [];
let overviewData = null;
let scanPollTimer = null;

function initTheme() {
  const stored = localStorage.getItem("theme");
  const theme = stored || (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  document.documentElement.setAttribute("data-theme", theme);
  themeToggle.setAttribute("aria-pressed", String(theme === "dark"));
}

function toggleTheme() {
  const current = document.documentElement.getAttribute("data-theme");
  const next = current === "dark" ? "light" : "dark";
  document.documentElement.setAttribute("data-theme", next);
  localStorage.setItem("theme", next);
  themeToggle.setAttribute("aria-pressed", String(next === "dark"));
}

// Strips the leading ", " artifact present in some fixed_version/recommendation
// strings from the scanner adapter. Display-only — the underlying data on disk
// is untouched.
function cleanText(str) {
  if (!str) return str;
  return str.replace(/,\s+(?=\S)/g, "");
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str ?? "";
  return div.innerHTML;
}

// ── Data loading ──────────────────────────────────────────

async function loadOverview() {
  try {
    const res = await fetch("/api/overview");
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    overviewData = await res.json();
  } catch (err) {
    renderErrorPanel();
    return;
  }

  if (!overviewData.repos || overviewData.repos.length === 0) {
    renderNoRepos();
    return;
  }

  allFindings = overviewData.repos.flatMap((r) => r.findings || []);

  renderSubtitle();
  renderOverviewCards();
  renderStatusBanner();
  renderRepoHealth();
  renderAffectedPackages();
  populateFilterOptions();
  renderFindingsTable();
}

function renderErrorPanel() {
  appMain.innerHTML = `
    <div class="error-panel">
      <div class="error-title">Unable to load inspection data</div>
      <div>The dashboard could not display the vulnerability records. Try reloading the page.</div>
    </div>`;
}

function renderNoRepos() {
  overviewCards.innerHTML = "";
  statusBannerWrap.innerHTML = "";
  repoHealthBody.innerHTML = `
    <div class="empty-state">
      <div class="empty-title">No repositories found</div>
      <div>No vulnerability records are currently available to display.</div>
    </div>`;
  affectedPackagesBody.innerHTML = "";
  findingsTableWrap.innerHTML = "";
}

// ── Subtitle (last inspection + webhook flag) ────────────

function formatLastInspection(isoTimestamp, dateStr) {
  if (!isoTimestamp) return dateStr;

  const date = new Date(isoTimestamp);
  if (Number.isNaN(date.getTime())) return dateStr;

  return date.toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function renderSubtitle() {
  const stats = overviewData.stats;
  const parts = ["Dependency vulnerability overview"];
  if (stats.last_scan_date) {
    parts.push(`Last inspection ${formatLastInspection(stats.last_scan_at, stats.last_scan_date)}`);
  }

  let webhookHtml = "";
  if (stats.webhook.status === "down") {
    webhookHtml = ' · <span class="webhook-flag down">● Webhook delivery failing</span>';
  } else if (stats.webhook.status === "online") {
    webhookHtml = ' · <span class="webhook-flag online">● Webhook delivery OK</span>';
  }

  headerSubtitle.innerHTML = escapeHtml(parts.join(" · ")) + webhookHtml;
}

// ── Overview cards ────────────────────────────────────────

function renderOverviewCards() {
  const stats = overviewData.stats;
  const totalFindings = allFindings.length;
  const affectedRepos = overviewData.repos.filter((r) => r.status !== "clean").length;
  const highCount = allFindings.filter((f) => f.severity === "critical" || f.severity === "high").length;
  const scanners = [...new Set(allFindings.map((f) => f.scanner).filter(Boolean))];
  const scannerLabel = scanners.length === 0 ? "—" : scanners.length === 1 ? scanners[0] : `${scanners.length} scanners`;

  overviewCards.innerHTML = `
    <div class="metric-card">
      <div class="metric-label">Total findings</div>
      <div class="metric-value">${totalFindings}</div>
    </div>
    <div class="metric-card">
      <div class="metric-label">Affected repositories</div>
      <div class="metric-value">${affectedRepos}</div>
      <div class="metric-sub">of ${stats.total_repos} tracked</div>
    </div>
    <div class="metric-card">
      <div class="metric-label">High severity</div>
      <div class="metric-value">${highCount}</div>
    </div>
    <div class="metric-card">
      <div class="metric-label">Scanner</div>
      <div class="metric-value" style="font-size:1.1rem;">${escapeHtml(scannerLabel)}</div>
    </div>
  `;
}

// ── Status banner ─────────────────────────────────────────

function renderStatusBanner() {
  const total = allFindings.length;

  if (total === 0) {
    statusBannerWrap.innerHTML = `
      <div class="status-banner" style="--banner-color: var(--sev-clean);">
        <div class="banner-title">No vulnerabilities found</div>
        <div class="banner-detail">All ${overviewData.stats.total_repos} tracked repositories are clean.</div>
      </div>`;
    return;
  }

  const counts = severityTally(allFindings);
  const worstSeverity = SEVERITY_ORDER.find((s) => counts[s] > 0);
  const colorVar = `var(--sev-${worstSeverity === "critical" || worstSeverity === "high" ? worstSeverity : worstSeverity})`;

  const affected = overviewData.repos.filter((r) => r.status !== "clean");
  const subject =
    affected.length === 1
      ? affected[0].repo
      : `${affected.length} repositories`;

  const breakdown = SEVERITY_ORDER.filter((s) => counts[s] > 0)
    .map((s) => `${counts[s]} ${s}`)
    .join(" · ");

  const titleText =
    worstSeverity === "critical" || worstSeverity === "high"
      ? "High severity finding detected"
      : "Dependency findings detected";

  statusBannerWrap.innerHTML = `
    <div class="status-banner" style="--banner-color: ${colorVar};">
      <div class="banner-title">${escapeHtml(titleText)}</div>
      <div class="banner-detail">${escapeHtml(subject)} ${affected.length === 1 ? "has" : "have"} ${total} dependency finding${total === 1 ? "" : "s"}. ${escapeHtml(breakdown)}</div>
    </div>`;
}

function severityTally(findings) {
  const tally = { critical: 0, high: 0, moderate: 0, low: 0, unknown: 0 };
  for (const f of findings) {
    const sev = tally.hasOwnProperty(f.severity) ? f.severity : "unknown";
    tally[sev] += 1;
  }
  return tally;
}

// ── Repository health ─────────────────────────────────────

function formatManifests(manifests) {
  if (!manifests || manifests.length === 0) return null;
  return manifests.join(", ").replace(/,(?!\s)/g, ", ");
}

function renderRepoHealth() {
  repoHealthBody.innerHTML = overviewData.repos
    .map((repo) => {
      const findings = repo.findings || [];
      const counts = severityTally(findings);
      const ecosystem = findings[0]?.ecosystem;
      const scanner = findings[0]?.scanner;
      const manifestsLabel = formatManifests(repo.manifests);
      const metaParts = [ecosystem, manifestsLabel, scanner].filter(Boolean);

      let statusHtml;
      if (repo.status === "failed") {
        statusHtml = `<span class="status-text" style="color: var(--text-muted);">Scan failed</span>`;
      } else if (repo.status === "unknown") {
        statusHtml = `<span class="status-text" style="color: var(--text-muted);">Not yet inspected</span>`;
      } else if (findings.length === 0) {
        statusHtml = `<span class="status-text no-findings">No findings</span>`;
      } else {
        statusHtml = `<span class="status-text needs-attention">Needs attention</span>`;
      }

      const countsHtml = findings.length
        ? `<div class="severity-counts">${SEVERITY_ORDER.filter((s) => counts[s] > 0)
            .map((s) => `<span class="count-pill nonzero">${counts[s]} ${SEVERITY_LABEL[s]}</span>`)
            .join("")}</div>`
        : "";

      const errorHtml = repo.error
        ? `<div class="muted" style="font-size:0.72rem;margin-top:0.2rem;">${escapeHtml(repo.error)}</div>`
        : "";

      return `
        <div class="repo-row">
          <div class="repo-row-main">
            <div class="repo-name">${escapeHtml(repo.repo)}</div>
            ${metaParts.length ? `<div class="repo-meta">${escapeHtml(metaParts.join(" · "))}</div>` : ""}
            ${errorHtml}
          </div>
          <div class="repo-row-status">
            ${countsHtml}
            ${statusHtml}
            <button class="view-history" type="button" data-repo="${escapeHtml(repo.repo)}">View history</button>
          </div>
        </div>`;
    })
    .join("");

  repoHealthBody.querySelectorAll(".view-history").forEach((btn) => {
    btn.addEventListener("click", () => openRunLog(btn.dataset.repo));
  });
}

// ── Affected packages ──────────────────────────────────────

function renderAffectedPackages() {
  const counts = {};
  for (const f of allFindings) {
    counts[f.package] = (counts[f.package] || 0) + 1;
  }
  const rows = Object.entries(counts).sort((a, b) => b[1] - a[1]);

  if (rows.length === 0) {
    affectedPackagesBody.innerHTML = `<div class="empty-state-row">No affected packages.</div>`;
    return;
  }

  const max = rows[0][1];
  affectedPackagesBody.innerHTML = rows
    .map(
      ([pkg, count]) => `
        <div class="package-row">
          <span class="package-name">${escapeHtml(pkg)}</span>
          <span class="package-bar-track"><span class="package-bar-fill" style="width:${(count / max) * 100}%"></span></span>
          <span class="package-count">${count}</span>
        </div>`
    )
    .join("");
}

// ── Filters ─────────────────────────────────────────────────

function populateFilterOptions() {
  const packages = [...new Set(allFindings.map((f) => f.package))].sort();
  const scanners = [...new Set(allFindings.map((f) => f.scanner).filter(Boolean))].sort();

  packageFilter.innerHTML =
    '<option value="">All packages</option>' +
    packages.map((p) => `<option value="${escapeHtml(p)}">${escapeHtml(p)}</option>`).join("");

  scannerFilter.innerHTML =
    '<option value="">All scanners</option>' +
    scanners.map((s) => `<option value="${escapeHtml(s)}">${escapeHtml(s)}</option>`).join("");
}

function filteredFindings() {
  const term = searchInput.value.trim().toLowerCase();
  const severity = severityFilter.value;
  const pkg = packageFilter.value;
  const scanner = scannerFilter.value;

  return allFindings.filter((f) => {
    if (severity && f.severity !== severity) return false;
    if (pkg && f.package !== pkg) return false;
    if (scanner && f.scanner !== scanner) return false;
    if (term) {
      const haystack = [f.repo, f.package, f.summary, f.vulnerability_id, ...(f.aliases || [])]
        .join(" ")
        .toLowerCase();
      if (!haystack.includes(term)) return false;
    }
    return true;
  });
}

// ── Findings table ─────────────────────────────────────────

function renderFindingsTable() {
  const rows = filteredFindings();

  if (rows.length === 0) {
    findingsTableWrap.innerHTML = `
      <div class="empty-state">
        <div class="empty-title">No matching findings</div>
        <div>Try searching by package, CVE, advisory ID, or repository name.</div>
      </div>`;
    return;
  }

  const bodyRows = rows
    .map((f, i) => {
      const fixed = cleanText(f.fixed_version) || "not listed";
      const cve = (f.aliases || []).join(", ") || "—";
      return `
        <tr class="finding-row" data-index="${i}" tabindex="0">
          <td data-label="Severity"><span class="severity-badge ${f.severity}">${SEVERITY_LABEL[f.severity] || f.severity}</span></td>
          <td class="cell-repo" data-label="Repo">${escapeHtml(f.repo)}</td>
          <td class="cell-package" data-label="Package">${escapeHtml(f.package)}</td>
          <td class="cell-summary" data-label="Vulnerability">${escapeHtml(f.summary)}</td>
          <td class="cell-version" data-label="Installed">${escapeHtml(f.installed_version)}</td>
          <td class="cell-version" data-label="Fixed">${escapeHtml(fixed)}</td>
          <td class="cell-advisory" data-label="Advisory">${escapeHtml(f.vulnerability_id)}</td>
          <td class="cell-advisory col-tablet-hide" data-label="CVE">${escapeHtml(cve)}</td>
          <td class="cell-manifest col-tablet-hide" data-label="Manifest">${escapeHtml(f.manifest)}</td>
          <td class="cell-scanner col-tablet-hide" data-label="Scanner">${escapeHtml(f.scanner)}</td>
        </tr>`;
    })
    .join("");

  findingsTableWrap.innerHTML = `
    <table class="findings-table">
      <thead>
        <tr>
          <th>Severity</th>
          <th>Repo</th>
          <th>Package</th>
          <th>Vulnerability</th>
          <th>Installed</th>
          <th>Fixed</th>
          <th>Advisory</th>
          <th class="col-tablet-hide">CVE</th>
          <th class="col-tablet-hide">Manifest</th>
          <th class="col-tablet-hide">Scanner</th>
        </tr>
      </thead>
      <tbody>${bodyRows}</tbody>
    </table>`;

  findingsTableWrap.querySelectorAll(".finding-row").forEach((row) => {
    const finding = rows[Number(row.dataset.index)];
    row.addEventListener("click", () => openDrawer(finding));
    row.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        openDrawer(finding);
      }
    });
  });
}

function applyFilters() {
  if (overviewData) renderFindingsTable();
}

// ── Drawer ──────────────────────────────────────────────────

function openDrawer(finding) {
  drawerSeverity.className = `severity-badge ${finding.severity}`;
  drawerSeverity.textContent = SEVERITY_LABEL[finding.severity] || finding.severity;
  drawerPackage.textContent = finding.package;

  const fixed = cleanText(finding.fixed_version) || "not listed";
  const recommendation = cleanText(finding.recommendation);
  const cve = (finding.aliases || []).join(", ") || "—";
  const cvss = (finding.cvss || []).map((c) => c.score).join(", ") || "—";

  drawerBody.innerHTML = `
    <div class="drawer-field">
      <div class="field-label">Repository</div>
      <div class="field-value">${escapeHtml(finding.repo)}</div>
    </div>
    <div class="drawer-field">
      <div class="field-label">Advisory</div>
      <div class="field-value mono"><a class="drawer-link" href="${finding.url}" target="_blank" rel="noopener">${escapeHtml(finding.vulnerability_id)}</a></div>
    </div>
    <div class="drawer-field">
      <div class="field-label">CVE</div>
      <div class="field-value mono">${escapeHtml(cve)}</div>
    </div>
    <div class="drawer-field">
      <div class="field-label">Installed version</div>
      <div class="field-value mono">${escapeHtml(finding.installed_version)}</div>
    </div>
    <div class="drawer-field">
      <div class="field-label">Fixed version</div>
      <div class="field-value mono">${escapeHtml(fixed)}</div>
    </div>
    <div class="drawer-field">
      <div class="field-label">Manifest</div>
      <div class="field-value mono">${escapeHtml(finding.manifest)}</div>
    </div>
    <div class="drawer-field">
      <div class="field-label">Scanner</div>
      <div class="field-value mono">${escapeHtml(finding.scanner)}</div>
    </div>
    <div class="drawer-field">
      <div class="field-label">CVSS</div>
      <div class="field-value mono">${escapeHtml(cvss)}</div>
    </div>
    <div class="drawer-field">
      <div class="field-label">Summary</div>
      <div class="field-value">${escapeHtml(finding.summary)}</div>
    </div>
    <div class="drawer-field">
      <div class="field-label">Details</div>
      <div class="field-value" style="white-space:pre-wrap;">${escapeHtml(finding.details || "—")}</div>
    </div>
    <div class="drawer-field">
      <div class="field-label">Recommendation</div>
      <div class="field-value">${escapeHtml(recommendation)}</div>
      <a class="drawer-link" href="${finding.url}" target="_blank" rel="noopener">Open OSV advisory &rarr;</a>
    </div>
  `;

  drawer.classList.add("is-open");
  drawer.setAttribute("aria-hidden", "false");
  drawerBackdrop.hidden = false;
}

function closeDrawer() {
  drawer.classList.remove("is-open");
  drawer.setAttribute("aria-hidden", "true");
  drawerBackdrop.hidden = true;
}

// ── Run history modal (kept from prior pass, restyled) ─────

async function openRunLog(repo) {
  runLogTitle.textContent = repo;
  runLogBody.innerHTML = '<p class="muted">Loading run history&hellip;</p>';
  runLogModal.showModal();

  const res = await fetch(`/api/runs?repo=${encodeURIComponent(repo)}&limit=10`);
  const data = await res.json();

  if (!data.runs || data.runs.length === 0) {
    runLogBody.innerHTML = '<p class="muted">No run history recorded yet.</p>';
    return;
  }

  runLogBody.innerHTML = data.runs
    .map((run) => {
      const counts = SEVERITY_ORDER.map((k) => `${k[0].toUpperCase()}${run.summary[k] ?? 0}`).join(" ");
      const statusLabel = run.status === "clean" ? "No findings" : run.status === "failed" ? "Scan failed" : run.status === "vulnerable" ? "Needs attention" : "Unknown";
      const errorHtml = run.error ? `<div class="run-error">${escapeHtml(run.error)}</div>` : "";
      return `
        <div class="run-row">
          <span class="run-date">${run.date}</span>
          <span class="muted">${statusLabel}</span>
          <span class="run-counts">${counts}${errorHtml}</span>
        </div>`;
    })
    .join("");
}

// ── Scan now ────────────────────────────────────────────────

function setScanningUI(isScanning) {
  scanNowButton.classList.toggle("is-scanning", isScanning);
  scanNowButton.disabled = isScanning;
  scanNowLabel.textContent = isScanning ? "Scanning…" : "Scan now";
}

function stopScanPolling() {
  if (scanPollTimer) {
    clearInterval(scanPollTimer);
    scanPollTimer = null;
  }
}

function startScanPolling() {
  stopScanPolling();
  scanPollTimer = setInterval(async () => {
    try {
      const res = await fetch("/api/scan/status");
      const data = await res.json();
      if (!data.running) {
        stopScanPolling();
        setScanningUI(false);
        loadOverview();
      }
    } catch (err) {
      stopScanPolling();
      setScanningUI(false);
    }
  }, 3000);
}

async function checkScanStatusOnLoad() {
  try {
    const res = await fetch("/api/scan/status");
    const data = await res.json();
    if (data.running) {
      setScanningUI(true);
      startScanPolling();
    }
  } catch (err) {
    // Status endpoint unavailable (e.g. flock missing outside Docker) — leave button enabled.
  }
}

async function triggerScan() {
  setScanningUI(true);
  try {
    const res = await fetch("/api/scan", { method: "POST" });
    if (res.status === 409 || res.status === 202) {
      startScanPolling();
    } else {
      setScanningUI(false);
    }
  } catch (err) {
    setScanningUI(false);
  }
}

// ── Wiring ───────────────────────────────────────────────────

scanNowButton.addEventListener("click", triggerScan);
themeToggle.addEventListener("click", toggleTheme);
searchInput.addEventListener("input", applyFilters);
severityFilter.addEventListener("change", applyFilters);
packageFilter.addEventListener("change", applyFilters);
scannerFilter.addEventListener("change", applyFilters);

drawerClose.addEventListener("click", closeDrawer);
drawerBackdrop.addEventListener("click", closeDrawer);
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && drawer.classList.contains("is-open")) closeDrawer();
});

runLogClose.addEventListener("click", () => runLogModal.close());
runLogModal.addEventListener("click", (e) => {
  if (e.target === runLogModal) runLogModal.close();
});

initTheme();
loadOverview();
checkScanStatusOnLoad();
