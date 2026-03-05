// ── Tasks — task/schedule state, rendering, CRUD ──────────────────────────
//
// Responsibilities:
//   - Single source of truth for tasks + schedules data
//   - Render the "Scheduled Tasks" entry in the sidebar
//   - Show/render the task list table in the main panel
//   - CRUD: load, run, editInSession (creates new session), delete
//
// Panel switching is delegated to Router — Tasks only manages data + rendering.
//
// Depends on: WS (ws.js), Sessions (sessions.js), Router (app.js),
//             global $ / escapeHtml helpers
// ─────────────────────────────────────────────────────────────────────────

const Tasks = (() => {
  // ── Private state ──────────────────────────────────────────────────────
  let _tasks     = [];   // [{ name, path, content, schedules: Schedule[] }]
  let _schedules = [];   // [{ name, task, cron, enabled }]

  // ── Private helpers ────────────────────────────────────────────────────

  /** Merge schedule info into task objects. Pure function. */
  function _attachSchedules(tasks, schedules) {
    return tasks.map(t => ({
      ...t,
      schedules: schedules.filter(s => s.task === t.name)
    }));
  }

  /** Render a single task row in the main panel table. */
  function _renderTaskRow(t) {
    const row = document.createElement("div");
    row.className = "task-table-row";
    row.dataset.name = t.name;

    const schedLabel = t.schedules.length > 0
      ? escapeHtml(t.schedules[0].cron)
      : '<span class="sched-manual">Manual</span>';

    const preview = (t.content || "")
      .split("\n")
      .map(l => l.trim())
      .find(l => l.length > 0) || "(empty)";
    const previewText = preview.length > 80
      ? escapeHtml(preview.slice(0, 80)) + "…"
      : escapeHtml(preview);

    row.innerHTML = `
      <div class="task-col task-col-name">
        <span class="task-icon">⏰</span>
        <span class="task-name-text">${escapeHtml(t.name)}</span>
      </div>
      <div class="task-col task-col-schedule">${schedLabel}</div>
      <div class="task-col task-col-content">${previewText}</div>
      <div class="task-col task-col-actions">
        <button class="task-btn task-btn-run"  title="Run now">▶ Run</button>
        <button class="task-btn task-btn-edit" title="Edit task">✎ Edit</button>
        <button class="task-btn task-btn-del"  title="Delete">✕</button>
      </div>`;

    row.querySelector(".task-btn-run").addEventListener("click", e => {
      e.stopPropagation();
      Tasks.run(t.name);
    });
    row.querySelector(".task-btn-edit").addEventListener("click", e => {
      e.stopPropagation();
      Tasks.editInSession(t.name);
    });
    row.querySelector(".task-btn-del").addEventListener("click", e => {
      e.stopPropagation();
      Tasks.delete(t.name);
    });

    return row;
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {

    // ── Data ─────────────────────────────────────────────────────────────

    /** Fetch tasks + schedules from server; re-render sidebar + panel if open. */
    async load() {
      try {
        const [tr, sr] = await Promise.all([
          fetch("/api/tasks"),
          fetch("/api/schedules")
        ]);
        const td = await tr.json();
        const sd = await sr.json();
        _schedules = sd.schedules || [];
        _tasks     = _attachSchedules(td.tasks || [], _schedules);
        Tasks.renderSection();
        if (Router.current === "tasks") Tasks.renderTable();
      } catch (e) {
        console.error("[Tasks] load failed", e);
      }
    },

    // ── Router interface ──────────────────────────────────────────────────

    /** Called by Router when the tasks panel becomes active. */
    onPanelShow() {
      Tasks.renderTable();
      Tasks.renderSection();
      const btn = $("btn-create-task");
      if (btn) btn.onclick = () => Tasks.createInSession();
    },

    // ── Sidebar rendering ─────────────────────────────────────────────────

    renderSection() {
      const section   = $("tasks-section");
      const container = $("task-list-items");
      container.innerHTML = "";
      section.style.display = "";   // always visible

      if (_tasks.length === 0) {
        container.innerHTML =
          '<div class="task-empty-hint">No scheduled tasks.<br>Ask the Agent to create one!</div>';
        return;
      }

      const el = document.createElement("div");
      el.id        = "tasks-sidebar-item";
      el.className = "task-item task-item-summary";
      el.innerHTML = `
        <div class="task-row">
          <span class="task-icon">⏰</span>
          <div class="task-info">
            <span class="task-name">${_tasks.length} task${_tasks.length !== 1 ? "s" : ""}</span>
          </div>
        </div>`;
      el.addEventListener("click", () => {
        if (Router.current === "tasks") {
          Router.navigate("welcome");
        } else {
          Router.navigate("tasks");
        }
      });
      container.appendChild(el);
    },

    // ── Main panel table ──────────────────────────────────────────────────

    /** Render all tasks as rows in the main panel table. */
    renderTable() {
      const table = $("task-list-table");
      table.innerHTML = "";

      if (_tasks.length === 0) {
        table.innerHTML = '<div class="task-table-empty">No scheduled tasks yet. Ask the Agent to create one!</div>';
        return;
      }

      const header = document.createElement("div");
      header.className = "task-table-header";
      header.innerHTML = `
        <div class="task-col task-col-name">Name</div>
        <div class="task-col task-col-schedule">Schedule</div>
        <div class="task-col task-col-content">Task</div>
        <div class="task-col task-col-actions"></div>`;
      table.appendChild(header);

      _tasks.forEach(t => table.appendChild(_renderTaskRow(t)));
    },

    // ── CRUD ─────────────────────────────────────────────────────────────

    async run(name) {
      const res = await fetch("/api/tasks/run", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name })
      });
      const data = await res.json();
      if (!res.ok) { alert("Error: " + (data.error || "unknown")); return; }

      if (data.session) {
        await Tasks.load();
        Sessions.add(data.session);
        Sessions.renderList();
        Sessions.setPendingRunTask(data.session.id);
        Sessions.select(data.session.id);
      }
    },

    /** Create a new task by opening a new session and sending /create-task. */
    async createInSession() {
      const maxN = Sessions.all.reduce((max, s) => {
        const m = s.name.match(/^Session (\d+)$/);
        return m ? Math.max(max, parseInt(m[1], 10)) : max;
      }, 0);
      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: "Session " + (maxN + 1) })
      });
      const data = await res.json();
      if (!res.ok) { alert("Error creating session: " + (data.error || "unknown")); return; }

      const session = data.session;
      if (!session) return;

      Sessions.add(session);
      Sessions.renderList();
      Sessions.select(session.id);

      const msg = "/create-task";
      Sessions.appendMsg("user", escapeHtml(msg));
      WS.send({ type: "message", session_id: session.id, content: msg });
    },

    /** Edit a task by creating a new session and auto-sending the edit command. */
    async editInSession(name) {
      const maxN = Sessions.all.reduce((max, s) => {
        const m = s.name.match(/^Session (\d+)$/);
        return m ? Math.max(max, parseInt(m[1], 10)) : max;
      }, 0);
      const res = await fetch("/api/sessions", {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ name: "Session " + (maxN + 1) })
      });
      const data = await res.json();
      if (!res.ok) { alert("Error creating session: " + (data.error || "unknown")); return; }

      const session = data.session;
      if (!session) return;

      Sessions.add(session);
      Sessions.renderList();
      Sessions.select(session.id);

      const msg = `/create-task I'm editing ${name} task`;
      Sessions.appendMsg("user", escapeHtml(msg));
      WS.send({ type: "message", session_id: session.id, content: msg });
    },

    async delete(name) {
      if (!confirm(`Delete task "${name}"?`)) return;
      const res = await fetch(`/api/tasks/${encodeURIComponent(name)}`, { method: "DELETE" });
      if (!res.ok) { alert("Error deleting task."); return; }

      await Tasks.load();

      // If no tasks remain, leave the tasks panel
      if (_tasks.length === 0 && Router.current === "tasks") {
        Router.navigate("welcome");
      }
    },
  };
})();
