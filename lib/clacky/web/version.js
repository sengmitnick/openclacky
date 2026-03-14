// ── Version — version check and upgrade manager ───────────────────────────
//
// Responsibilities:
//   - Check current / latest version from GET /api/version on page load
//   - Show version badge in sidebar footer
//   - Show update dot when a newer version is available
//   - Handle upgrade modal: confirm → progress log → reconnect after restart
// ─────────────────────────────────────────────────────────────────────────

const Version = (() => {
  // ── State ──────────────────────────────────────────────────────────────
  let _current       = null;
  let _latest        = null;
  let _needsUpdate   = false;
  let _upgrading     = false;   // prevent duplicate upgrade triggers
  let _reconnectTimer = null;

  // ── DOM refs (resolved after DOMContentLoaded) ─────────────────────────
  const $ = id => document.getElementById(id);

  // ── Version check ──────────────────────────────────────────────────────

  /** Fetch /api/version and update the badge. Called once on boot. */
  async function checkVersion() {
    try {
      const res  = await fetch("/api/version");
      if (!res.ok) return;
      const data = await res.json();
      _current     = data.current;
      _latest      = data.latest;
      _needsUpdate = !!data.needs_update;
      _renderBadge();
    } catch (e) {
      console.warn("[Version] check failed:", e);
    }
  }

  /** Render the version badge and update dot in sidebar-footer. */
  function _renderBadge() {
    const badge = $("version-badge");
    const text  = $("version-text");
    const dot   = $("version-update-dot");
    if (!badge || !text || !dot) return;

    text.textContent = `v${_current}`;

    if (_needsUpdate) {
      dot.style.display = "inline-block";
      badge.classList.add("has-update");
      badge.title = `Update available: v${_latest}`;
    } else {
      dot.style.display = "none";
      badge.classList.remove("has-update");
      badge.title = `v${_current} (up to date)`;
    }

    badge.style.display = "flex";
  }

  // ── Upgrade modal ──────────────────────────────────────────────────────

  function openUpgradeModal() {
    if (_upgrading) return;

    // Populate version info line
    const infoEl = $("upgrade-version-info");
    if (infoEl) {
      infoEl.textContent = _needsUpdate
        ? `Current: v${_current}  →  Latest: v${_latest}`
        : `You are on v${_current} (latest)`;
    }

    // Reset to confirm state
    _showState("confirm");
    $("upgrade-modal-close").style.display = "none";
    $("upgrade-modal-overlay").style.display = "flex";
  }

  function closeUpgradeModal() {
    if (_upgrading) return;
    $("upgrade-modal-overlay").style.display = "none";
  }

  /** Switch between confirm / progress / reconnect panes. */
  function _showState(state) {
    ["confirm", "progress", "reconnect"].forEach(s => {
      const el = $(`upgrade-state-${s}`);
      if (el) el.style.display = s === state ? "" : "none";
    });
  }

  /** Start upgrade: POST /api/version/upgrade, then show log pane. */
  async function startUpgrade() {
    if (_upgrading) return;
    _upgrading = true;

    // Switch to progress pane
    _showState("progress");
    const logEl = $("upgrade-log");
    if (logEl) logEl.textContent = "";

    try {
      await fetch("/api/version/upgrade", { method: "POST" });
      // Actual progress arrives via WebSocket upgrade_log / upgrade_complete events
    } catch (e) {
      _appendLog(`\n✗ Failed to start upgrade: ${e.message}\n`);
      _upgrading = false;
      $("upgrade-modal-close").style.display = "";
    }
  }

  /** Append a line to the upgrade log textarea. */
  function _appendLog(line) {
    const logEl = $("upgrade-log");
    if (!logEl) return;
    logEl.textContent += line;
    logEl.scrollTop = logEl.scrollHeight;
  }

  /** Called when upgrade_complete event is received via WebSocket. */
  function _onUpgradeComplete(success) {
    if (success) {
      _showState("reconnect");
      _waitForReconnect();
    } else {
      _upgrading = false;
      $("upgrade-modal-close").style.display = "";
    }
  }

  /**
   * Poll /api/version every 2 seconds until the server responds.
   * Once reconnected, reload the page to load the new gem version.
   */
  function _waitForReconnect() {
    if (_reconnectTimer) clearInterval(_reconnectTimer);

    // Wait a moment before starting to poll (server is restarting)
    setTimeout(() => {
      _reconnectTimer = setInterval(async () => {
        try {
          const res = await fetch("/api/version", { cache: "no-store" });
          if (res.ok) {
            clearInterval(_reconnectTimer);
            _reconnectTimer = null;
            // Server is back — reload the page
            window.location.reload();
          }
        } catch (_) {
          // Server not yet up, keep polling
        }
      }, 2000);
    }, 3000);
  }

  // ── WebSocket event handler ────────────────────────────────────────────

  function _handleWsEvent(event) {
    if (event.type === "upgrade_log") {
      _appendLog(event.line);
    } else if (event.type === "upgrade_complete") {
      _onUpgradeComplete(event.success);
    }
  }

  // ── Init ───────────────────────────────────────────────────────────────

  function init() {
    // Wire up badge click → open modal
    const badge = $("version-badge");
    if (badge) {
      badge.addEventListener("click", () => {
        if (_current) openUpgradeModal();
      });
    }

    // Wire up upgrade modal buttons
    const btnStart  = $("upgrade-btn-start");
    const btnCancel = $("upgrade-btn-cancel");
    const btnClose  = $("upgrade-modal-close");

    if (btnStart)  btnStart.addEventListener("click",  startUpgrade);
    if (btnCancel) btnCancel.addEventListener("click", closeUpgradeModal);
    if (btnClose)  btnClose.addEventListener("click",  closeUpgradeModal);

    // Close on overlay backdrop click (only in confirm state)
    const overlay = $("upgrade-modal-overlay");
    if (overlay) {
      overlay.addEventListener("click", e => {
        if (e.target === overlay) closeUpgradeModal();
      });
    }

    // Listen for upgrade events from WebSocket
    if (typeof WS !== "undefined") {
      WS.onEvent(_handleWsEvent);
    }

    // Kick off version check
    checkVersion();
  }

  // Run after DOM is ready
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {
    checkVersion,
    openUpgradeModal,
  };
})();
