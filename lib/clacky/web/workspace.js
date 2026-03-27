// workspace.js — Project & Task management UI
// Migrated from ~/.clacky/skills/workspace/ui/index.js
// All SkillBridge/Router calls replaced with native fetch / hash routing
(() => {
  // ── State ──────────────────────────────────────────────────────────────
  let _projects        = [];
  let _activeProjectId = null;
  let _activeTaskId    = null;
  let _activeSessionId = null;
  let _chatCtx         = null;
  let _sending         = false;
  let _initialized     = false;
  let _newTaskType          = "normal";
  let _activeTaskWorkingDir = null;
  let _editorInfo           = null;

  // ── Helpers ────────────────────────────────────────────────────────────
  function _$(id) { return document.getElementById(id); }
  function _fmtDate(iso) {
    if (!iso) return "";
    try { return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }); }
    catch (_) { return iso; }
  }

  // ── i18n ───────────────────────────────────────────────────────────────
  const _CA_STRINGS = {
    en: {
      title: "Projects", newProject: "New Project", labelName: "Project Name",
      labelPath: "Project Path", placeName: "my-app", placePath: "/Users/you/projects/my-app",
      cancel: "Cancel", create: "Create", creating: "Creating…", loading: "Loading…",
      empty: 'No projects yet. Click "+ New Project" to get started.',
      emptyTasks: "No tasks yet.",
      welcomeTitle: "No tasks yet", welcomeDesc: 'Click "+" in the sidebar to create your first task.',
      errRequired: "Name and path are required.", errTaskRequired: "Task name is required.",
      errOpen: "Failed to open task: ", errDelete: "Failed to delete: ",
      confirmDel: "Delete this project?", confirmDelTask: "Delete this task? (worktree will also be removed)",
      dashboard: "Dashboard", tasks: "Tasks", newTaskTitle: "New Task",
      newNormalTask: "Normal Task", newWorktreeTask: "Workspace (git worktree)",
      taskLabelNormal: "Task Name", taskLabelWorktree: "Workspace Name",
      taskDescLabel: "Description (will be sent as first message)",
      taskDescPlaceholder: "Describe what you want to do…",
      back: "Back", branchLabel: "branch", normalBadge: "T", worktreeBadge: "W",
      openInEditor: "Open in {name}", openInFinder: "Open in Finder",
    },
    zh: {
      title: "项目", newProject: "新建项目", labelName: "项目名称",
      labelPath: "项目路径", placeName: "my-app", placePath: "/Users/you/projects/my-app",
      cancel: "取消", create: "创建", creating: "创建中…", loading: "加载中…",
      empty: "暂无项目，点击「+ 新建项目」开始。", emptyTasks: "暂无任务。",
      welcomeTitle: "还没有任务", welcomeDesc: "点击左侧「+」新建第一个任务。",
      errRequired: "项目名称和路径不能为空。", errTaskRequired: "任务名称不能为空。",
      errOpen: "打开任务失败：", errDelete: "删除失败：",
      confirmDel: "确认删除该项目？", confirmDelTask: "确认删除该任务？（工作区目录也会一并清除）",
      dashboard: "仪表盘", tasks: "任务列表", newTaskTitle: "新建任务",
      newNormalTask: "普通任务", newWorktreeTask: "工作区（git worktree）",
      taskLabelNormal: "任务名称", taskLabelWorktree: "工作区名称",
      taskDescLabel: "任务描述（创建后会作为第一条消息发送）",
      taskDescPlaceholder: "描述你想做什么…",
      back: "返回", branchLabel: "分支", normalBadge: "任", worktreeBadge: "区",
      openInEditor: "在 {name} 中打开", openInFinder: "在 Finder 中打开",
    },
  };

  function _t(key, fallback) {
    const lang = (typeof I18n !== "undefined") ? I18n.lang() : "en";
    const dict = _CA_STRINGS[lang] || _CA_STRINGS["en"];
    return dict[key] !== undefined ? dict[key] : (fallback !== undefined ? fallback : key);
  }

  // ── Hash-based navigation helpers ──────────────────────────────────────
  // Hash format: #workspace | #workspace/{projectId} | #workspace/{projectId}/tasks/{taskId}
  // Use replaceState to update URL without re-triggering Router's hashchange handler
  function _wsNavigate(sub) {
    const hash = sub ? `#workspace/${sub}` : "#workspace";
    const wp = document.getElementById("workspace-panel");
    const panelVisible = wp && wp.style.display !== "none" && wp.style.display !== "";
    if (panelVisible) {
      // Panel already open: just update URL without triggering Router (avoids _hideAll flash)
      if (location.hash !== hash) history.replaceState(null, "", hash);
      // Still need to run workspace routing
      _handleCurrentHash();
    } else {
      // Panel hidden: always go through Router.navigate() so it shows the panel.
      // Can't rely on location.hash= because if hash is already "#workspace",
      // the browser won't fire hashchange (no change → no event).
      if (typeof Router !== "undefined") {
        Router.navigate("workspace", sub ? { sub } : {});
      } else {
        location.hash = hash;
      }
    }
  }

  function _parseWsHash(hash) {
    const cleaned = (hash || "").replace(/^#\/?/, "");
    const m = cleaned.match(/^workspace(?:\/(.+))?$/);
    if (!m) return null;
    return m[1] || null; // null = dashboard, string = sub route
  }

  // ── Global loading overlay ─────────────────────────────────────────────
  function _showGlobalLoading() {
    const el = _$("ca-global-loading");
    if (!el) return;
    el.classList.remove("ca-loading-hidden");
    el.style.display = "flex";
  }
  function _hideGlobalLoading() {
    const el = _$("ca-global-loading");
    if (!el) return;
    el.classList.add("ca-loading-hidden");
    setTimeout(() => { if (el.classList.contains("ca-loading-hidden")) el.style.display = "none"; }, 300);
  }

  // ── Sidebar active state ───────────────────────────────────────────────
  function _clearSidebarActive() {
    document.querySelector(".ca-sidebar-dashboard")?.classList.remove("active");
    document.querySelectorAll(".ca-sidebar-project").forEach(el => el.classList.remove("active"));
  }
  function _highlightDashboard() {
    _clearSidebarActive();
    document.querySelector(".ca-sidebar-dashboard")?.classList.add("active");
  }
  function _highlightProject(projectId) {
    _clearSidebarActive();
    document.querySelector(`.ca-sidebar-project[data-ca-id="${projectId}"]`)?.classList.add("active");
  }

  // ── View switching ─────────────────────────────────────────────────────
  function _showDashboard() {
    const dash = _$("ca-view-dashboard"), proj = _$("ca-view-project");
    if (dash) dash.style.display = "";
    if (proj) proj.style.display = "none";
    _highlightDashboard();
    _activeProjectId = null;
    _activeTaskId    = null;
    _destroyChatCtx();
    _hideGlobalLoading();
  }

  function _showChatView(project) {
    const dash = _$("ca-view-dashboard"), proj = _$("ca-view-project");
    if (dash) dash.style.display = "none";
    if (proj) proj.style.display = "flex";
    _activeProjectId = project.id;
    _highlightProject(project.id);
    const titleEl = _$("ca-project-title");
    if (titleEl) titleEl.textContent = project.name;
    const labelEl = _$("ca-session-sidebar-label");
    if (labelEl) labelEl.textContent = _t("tasks");
  }

  function _showEmptyHint() {
    const hint = _$("ca-empty-task-hint"), msgs = _$("ca-messages");
    const inputArea = _$("ca-input-area"), infoBar = _$("ca-session-info-bar");
    const header = _$("ca-chat-header");
    if (hint) {
      _$("ca-empty-task-title").textContent = _t("welcomeTitle");
      _$("ca-empty-task-desc").textContent  = _t("welcomeDesc");
      hint.style.display = "flex";
    }
    if (msgs)      msgs.style.display      = "none";
    if (inputArea) inputArea.style.display = "none";
    if (infoBar)   infoBar.style.display   = "none";
    if (header)    header.style.display    = "none";
  }

  function _hideEmptyHint() {
    const hint = _$("ca-empty-task-hint"), msgs = _$("ca-messages"), inputArea = _$("ca-input-area");
    if (hint)      hint.style.display      = "none";
    if (msgs)      msgs.style.display      = "";
    if (inputArea) inputArea.style.display = "";
  }

  // ── Chat header helpers ────────────────────────────────────────────────
  function _showChatHeader(taskName, workingDir) {
    const header = _$("ca-chat-header"), title = _$("ca-chat-header-title");
    if (!header) return;
    if (title) title.textContent = taskName || "";
    _activeTaskWorkingDir = workingDir || null;
    header.style.display = "flex";
    _updateEditorButton();
  }

  function _hideChatHeader() {
    const header = _$("ca-chat-header");
    if (header) header.style.display = "none";
    _activeTaskWorkingDir = null;
  }

  async function _loadEditorInfo() {
    if (_editorInfo) return _editorInfo;
    try {
      const res = await fetch("/api/workspace/editor-info");
      if (res.ok) { _editorInfo = (await res.json()).editor; }
    } catch (_) {}
    return _editorInfo;
  }

  async function _updateEditorButton() {
    const btn = _$("ca-btn-open-editor");
    if (!btn) return;
    const info = await _loadEditorInfo();
    if (info && info.icon_url) {
      btn.innerHTML = `<img src="${info.icon_url}" alt="${info.name}" />`;
      btn.title = _t("openInEditor").replace("{name}", info.name);
    } else {
      btn.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="width:16px;height:16px"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>`;
      btn.title = _t("openInFinder");
    }
  }

  // ── ChatContext lifecycle ──────────────────────────────────────────────
  function _destroyChatCtx() {
    if (_chatCtx) { _chatCtx.destroy(); _chatCtx = null; }
    WS.offEvent(_wsStatusHandler);
    _activeSessionId = null;
    _sending = false;
    const btn = _$("ca-btn-interrupt");
    if (btn) btn.style.display = "none";
    const msgs = _$("ca-messages");
    if (msgs) msgs.innerHTML = "";
    _clearInfoBar();
    _hideChatHeader();
  }

  function _mountChatCtx(sessionOrId, task) {
    _destroyChatCtx();
    const msgContainer = _$("ca-messages");
    if (!msgContainer) return;
    const sessionId = typeof sessionOrId === "string" ? sessionOrId : sessionOrId.id;
    _activeSessionId = sessionId;
    WS.send({ type: "subscribe", session_id: sessionId });
    _chatCtx = Sessions.createChatContext(msgContainer, sessionId);
    WS.onEvent(_wsStatusHandler);
    if (typeof sessionOrId === "object" && sessionOrId !== null) {
      _updateInfoBar(sessionOrId);
    }
    if (task) {
      const workingDir = task.working_dir || task.worktree_path || null;
      _showChatHeader(task.name || "", workingDir);
    }
    _SkillAC.loadForSession(sessionId);
    if (_activeProjectId) _TaskSwitcher.load(_activeProjectId, _activeTaskId);
    _$("ca-user-input")?.focus();
  }

  // ── Attachments ────────────────────────────────────────────────────────
  const _pendingImages = [];
  const _pendingFiles  = [];
  const _MAX_IMAGE_SIZE = 5 * 1024 * 1024;
  const _MAX_FILE_SIZE  = 32 * 1024 * 1024;
  const _ACCEPTED_IMAGE_TYPES = ["image/png","image/jpeg","image/gif","image/webp"];

  function _addImageFile(file) {
    if (!_ACCEPTED_IMAGE_TYPES.includes(file.type)) { alert(`Unsupported image type: ${file.type}`); return; }
    if (file.size > _MAX_IMAGE_SIZE) { alert(`Image too large: ${file.name} (max 5 MB)`); return; }
    const reader = new FileReader();
    reader.onload = e => { _pendingImages.push({ dataUrl: e.target.result, name: file.name }); _renderAttachmentPreviews(); };
    reader.readAsDataURL(file);
  }

  function _addGenericFile(file) {
    if (file.size > _MAX_FILE_SIZE) { alert(`File too large: ${file.name} (max 32 MB)`); return; }
    const formData = new FormData();
    formData.append("file", file);
    fetch("/api/upload", { method: "POST", body: formData })
      .then(r => r.json())
      .then(data => {
        if (!data.ok) { alert(`Upload failed: ${data.error}`); return; }
        _pendingFiles.push({ file_id: data.file_id, name: data.name, path: data.path, mime_type: file.type });
        _renderAttachmentPreviews();
      })
      .catch(err => alert(`Upload error: ${err.message}`));
  }

  function _addAttachmentFile(file) {
    if (file.type === "application/pdf") _addGenericFile(file);
    else _addImageFile(file);
  }

  function _renderAttachmentPreviews() {
    const strip = _$("ca-image-preview-strip");
    if (!strip) return;
    strip.innerHTML = "";
    const hasContent = _pendingImages.length > 0 || _pendingFiles.length > 0;
    strip.style.display = hasContent ? "flex" : "none";
    _pendingImages.forEach((img, idx) => {
      const item = document.createElement("div");
      item.className = "ca-img-preview-item";
      item.title = img.name;
      const thumb = document.createElement("img");
      thumb.src = img.dataUrl; thumb.alt = img.name;
      const rm = document.createElement("button");
      rm.className = "ca-img-preview-remove"; rm.textContent = "✕";
      rm.addEventListener("click", () => { _pendingImages.splice(idx, 1); _renderAttachmentPreviews(); });
      item.appendChild(thumb); item.appendChild(rm); strip.appendChild(item);
    });
    _pendingFiles.forEach((pdf, idx) => {
      const item = document.createElement("div");
      item.className = "ca-pdf-preview-item";
      const name = document.createElement("div");
      name.className = "ca-pdf-preview-name"; name.textContent = pdf.name;
      const rm = document.createElement("button");
      rm.className = "ca-pdf-preview-remove"; rm.textContent = "✕";
      rm.addEventListener("click", () => { _pendingFiles.splice(idx, 1); _renderAttachmentPreviews(); });
      item.appendChild(name); item.appendChild(rm); strip.appendChild(item);
    });
  }

  // ── Skill autocomplete ─────────────────────────────────────────────────
  const _SkillAC = (() => {
    let _visible = false, _activeIndex = -1, _items = [], _sessionSkills = [];

    async function _loadForSession(sid) {
      if (!sid) { _sessionSkills = []; return; }
      try { const r = await fetch(`/api/sessions/${sid}/skills`); const d = await r.json(); _sessionSkills = d.skills || []; }
      catch (_) { _sessionSkills = []; }
    }
    function _getSlashQuery(val) {
      if (!val.startsWith("/")) return null;
      return /^\/\S*$/.test(val) ? val.slice(1).toLowerCase() : null;
    }
    function _render(query) {
      const all = _sessionSkills.length > 0 ? _sessionSkills : (typeof Skills !== "undefined" ? Skills.all : []);
      _items = all.filter(s => s.name.toLowerCase().startsWith(query));
      if (_items.length === 0) { _hide(); return; }
      const list = _$("ca-skill-autocomplete-list");
      if (!list) return;
      list.innerHTML = "";
      const hdr = document.createElement("div");
      hdr.className = "ca-skill-ac-header";
      hdr.textContent = (typeof I18n !== "undefined") ? I18n.t("sidebar.skills") : "Skills";
      list.appendChild(hdr);
      _items.forEach((skill, idx) => {
        const item = document.createElement("div");
        item.className = "ca-skill-ac-item"; item.setAttribute("role","option"); item.dataset.idx = idx;
        const nm = document.createElement("div"); nm.className = "ca-skill-ac-name"; nm.textContent = "/" + skill.name;
        const ds = document.createElement("div"); ds.className = "ca-skill-ac-desc";
        ds.textContent = (typeof I18n !== "undefined") ? I18n.t(skill.description, skill.description) : skill.description;
        item.appendChild(nm); item.appendChild(ds);
        item.addEventListener("mousedown", e => { e.preventDefault(); _selectItem(idx); });
        list.appendChild(item);
      });
      _activeIndex = -1; _show();
    }
    function _selectItem(idx) {
      const skill = _items[idx]; if (!skill) return;
      const input = _$("ca-user-input");
      if (input) { input.value = "/" + skill.name + " "; input.focus(); }
      _hide();
    }
    function _show() { const el = _$("ca-skill-autocomplete"); if (el) el.style.display = ""; _visible = true; }
    function _hide() {
      const el = _$("ca-skill-autocomplete"); if (el) el.style.display = "none";
      _visible = false; _activeIndex = -1;
      _$("ca-btn-slash")?.classList.remove("active");
    }
    function _highlightItem(idx) {
      _$("ca-skill-autocomplete-list")?.querySelectorAll(".ca-skill-ac-item")
        .forEach((el, i) => el.classList.toggle("active", i === idx));
    }
    function handleKey(e) {
      if (!_visible) return false;
      if (e.key === "ArrowDown") { e.preventDefault(); _activeIndex = Math.min(_activeIndex+1,_items.length-1); _highlightItem(_activeIndex); return true; }
      if (e.key === "ArrowUp")   { e.preventDefault(); _activeIndex = Math.max(_activeIndex-1,-1); _highlightItem(_activeIndex); return true; }
      if (e.key === "Enter" && _activeIndex >= 0) { e.preventDefault(); _selectItem(_activeIndex); return true; }
      if (e.key === "Escape") { e.preventDefault(); _hide(); return true; }
      return false;
    }
    function toggle() {
      if (_visible) _hide();
      else { const input = _$("ca-user-input"); if (input) { const q = _getSlashQuery(input.value) ?? ""; _render(q); } }
    }
    return {
      loadForSession: _loadForSession, handleKey, hide: _hide, toggle,
      get visible() { return _visible; },
      update(value) { const q = _getSlashQuery(value); if (q !== null) _render(q); else _hide(); }
    };
  })();

  // ── Send / interrupt ───────────────────────────────────────────────────
  function _sendMessage() {
    if (_sending) return;
    const input = _$("ca-user-input");
    if (!input) return;
    const content = input.value.trim();
    if (!content && _pendingImages.length === 0 && _pendingFiles.length === 0) return;
    if (!_activeSessionId) return;
    _sending = true;
    let bubbleHtml = content ? escapeHtml(content) : "";
    if (_pendingImages.length > 0) {
      const thumbs = _pendingImages.map(img => `<img src="${img.dataUrl}" alt="${escapeHtml(img.name)}" class="msg-image-thumb">`).join("");
      bubbleHtml = thumbs + (bubbleHtml ? "<br>" + bubbleHtml : "");
    }
    if (_pendingFiles.length > 0) {
      const badges = _pendingFiles.map(f => `<span class="ca-msg-pdf-badge"><em>${escapeHtml(f.name)}</em></span>`).join(" ");
      bubbleHtml = badges + (bubbleHtml ? "<br>" + bubbleHtml : "");
    }
    if (_chatCtx) _chatCtx.appendMsg("user", bubbleHtml);
    const images = _pendingImages.map(img => img.dataUrl);
    const files  = _pendingFiles.map(f => ({ file_id: f.file_id, name: f.name, mime_type: f.mime_type, path: f.path }));
    _pendingImages.length = 0; _pendingFiles.length = 0;
    _renderAttachmentPreviews();
    WS.send({ type: "message", session_id: _activeSessionId, content, images, files });
    input.value = ""; input.style.height = "auto";
    setTimeout(() => { _sending = false; }, 300);
  }

  // ── Session info bar ───────────────────────────────────────────────────
  let _infoBarState = {};
  function _updateInfoBar(patch) {
    Object.assign(_infoBarState, patch);
    const s = _infoBarState;
    const bar = _$("ca-session-info-bar");
    if (!bar || !s.id) { if (bar) bar.style.display = "none"; return; }
    const sibStatus = _$("ca-sib-status");
    if (sibStatus) { sibStatus.textContent = `● ${s.status || "idle"}`; sibStatus.className = `ca-sib-status-${s.status || "idle"}`; }
    const sibId = _$("ca-sib-id");
    if (sibId) sibId.textContent = s.id ? s.id.slice(0, 8) : "";
    const sibModel = _$("ca-sib-model"), sibModelWrap = _$("ca-sib-model-wrap");
    if (sibModel) sibModel.textContent = s.model || "";
    if (sibModelWrap) sibModelWrap.style.display = s.model ? "" : "none";
    const sibCost = _$("ca-sib-cost");
    if (sibCost) sibCost.textContent = `$${(s.total_cost || 0).toFixed(2)}`;
    const sibTasks = _$("ca-sib-tasks");
    if (sibTasks) sibTasks.textContent = `${s.total_tasks || 0} tasks`;
    const sibDir = _$("ca-sib-dir");
    if (sibDir && s.working_dir) {
      const parts = s.working_dir.replace(/\/$/, "").split("/");
      sibDir.textContent = parts.length > 2 ? "…/" + parts.slice(-2).join("/") : s.working_dir;
      sibDir.title = s.working_dir;
    }
    const sibMode = _$("ca-sib-mode"), sibModeWrap = _$("ca-sib-mode-wrap");
    if (sibMode) sibMode.textContent = s.permission_mode || "";
    if (sibModeWrap) sibModeWrap.style.display = s.permission_mode ? "" : "none";
    bar.style.display = "flex";
  }
  function _clearInfoBar() { _infoBarState = {}; const bar = _$("ca-session-info-bar"); if (bar) bar.style.display = "none"; }

  function _wsStatusHandler(event) {
    const sid = event.session_id || (event.session && event.session.id);
    if (sid !== _activeSessionId) return;
    const btn = _$("ca-btn-interrupt");
    if (event.type === "progress") { if (btn && event.status === "start") btn.style.display = ""; return; }
    if (event.type === "complete") { if (btn) btn.style.display = "none"; return; }
    if (event.type === "session_update") {
      const s = event.session || event;
      const patch = {};
      if (s.status      !== undefined) patch.status      = s.status;
      if (s.cost        !== undefined) patch.total_cost  = s.cost;
      if (s.total_cost  !== undefined) patch.total_cost  = s.total_cost;
      if (s.total_tasks !== undefined) patch.total_tasks = s.total_tasks;
      if (s.model       !== undefined) patch.model       = s.model;
      if (Object.keys(patch).length) _updateInfoBar(patch);
      if (btn && s.status !== undefined) {
        btn.style.display = (s.status === "working" || s.status === "running") ? "" : "none";
      }
    }
  }

  // ── Bind input ─────────────────────────────────────────────────────────
  function _bindInput() {
    const input = _$("ca-user-input"), sendBtn = _$("ca-btn-send");
    const interruptBtn = _$("ca-btn-interrupt"), attachBtn = _$("ca-btn-attach");
    const fileInput = _$("ca-image-file-input"), slashBtn = _$("ca-btn-slash");
    const inputArea = _$("ca-input-area");
    if (!input || !sendBtn || !interruptBtn) return;

    input.addEventListener("input", () => {
      input.style.height = "auto";
      input.style.height = Math.min(input.scrollHeight, 160) + "px";
      _SkillAC.update(input.value);
    });
    input.addEventListener("keydown", e => {
      if (_SkillAC.handleKey(e)) return;
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); _sendMessage(); }
    });
    input.addEventListener("blur", () => setTimeout(() => _SkillAC.hide(), 150));
    input.addEventListener("paste", e => {
      const items = Array.from(e.clipboardData?.items || []);
      const attachItems = items.filter(it => it.kind === "file" && [..._ACCEPTED_IMAGE_TYPES,"application/pdf"].includes(it.type));
      if (attachItems.length === 0) return;
      e.preventDefault();
      attachItems.forEach(it => _addAttachmentFile(it.getAsFile()));
    });
    sendBtn.addEventListener("click", () => _sendMessage());
    interruptBtn.addEventListener("click", () => { if (_activeSessionId) WS.send({ type: "interrupt", session_id: _activeSessionId }); });
    if (attachBtn && fileInput) {
      attachBtn.addEventListener("click", () => fileInput.click());
      fileInput.addEventListener("change", e => { Array.from(e.target.files).forEach(_addAttachmentFile); e.target.value = ""; });
    }
    if (slashBtn) {
      slashBtn.addEventListener("mousedown", e => e.preventDefault());
      slashBtn.addEventListener("click", () => {
        if (input.value === "" || input.value === "/") input.value = "/";
        _SkillAC.toggle();
        if (_SkillAC.visible) slashBtn.classList.add("active");
        input.focus();
      });
    }
    if (inputArea) {
      const ALL = [..._ACCEPTED_IMAGE_TYPES,"application/pdf"];
      inputArea.addEventListener("dragover", e => { e.preventDefault(); inputArea.classList.add("ca-drag-over"); });
      inputArea.addEventListener("dragleave", e => { if (!inputArea.contains(e.relatedTarget)) inputArea.classList.remove("ca-drag-over"); });
      inputArea.addEventListener("drop", e => {
        e.preventDefault(); inputArea.classList.remove("ca-drag-over");
        Array.from(e.dataTransfer.files).filter(f => ALL.includes(f.type)).forEach(_addAttachmentFile);
      });
    }
  }

  // ── API (native fetch, no SkillBridge) ────────────────────────────────
  async function _fetchProjects() {
    const res = await fetch("/api/workspace/projects");
    return (await res.json()).projects || [];
  }
  async function _createProject(name, path) {
    const res = await fetch("/api/workspace/projects", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, path })
    });
    if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.error || `HTTP ${res.status}`); }
    return (await res.json()).project;
  }
  async function _deleteProject(id) {
    const res = await fetch(`/api/workspace/projects/${id}`, { method: "DELETE" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  }
  async function _fetchTasks(projectId) {
    const res = await fetch(`/api/workspace/projects/${projectId}/tasks`);
    return (await res.json()).tasks || [];
  }
  async function _createTask(projectId, name, type) {
    const res = await fetch(`/api/workspace/projects/${projectId}/tasks`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, type })
    });
    if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.error || `HTTP ${res.status}`); }
    return await res.json();
  }
  async function _deleteTask(projectId, taskId) {
    const res = await fetch(`/api/workspace/projects/${projectId}/tasks/${taskId}`, { method: "DELETE" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
  }
  async function _openTaskSession(projectId, taskId) {
    const res = await fetch(`/api/workspace/projects/${projectId}/tasks/${taskId}/session`);
    if (!res.ok) { const d = await res.json().catch(() => ({})); throw new Error(d.error || `HTTP ${res.status}`); }
    return await res.json();
  }

  // ── Task switcher (left sidebar in chat view) ──────────────────────────
  const _TaskSwitcher = (() => {
    let _tasks = [], _projectId = null, _activeId = null;

    async function load(projectId, activeTaskId) {
      _projectId = projectId;
      _activeId  = activeTaskId;
      try { _tasks = await _fetchTasks(projectId); } catch (_) { _tasks = []; }
      _renderList();
    }

    function _renderList() {
      const list = _$("ca-session-list");
      if (!list) return;
      list.innerHTML = "";
      if (_tasks.length === 0) {
        const el = document.createElement("div");
        el.style.cssText = "padding:10px 12px;font-size:0.82rem;color:var(--color-text-secondary)";
        el.textContent = _t("emptyTasks");
        list.appendChild(el);
        return;
      }
      _tasks.forEach(task => {
        const isExpired = task.session?.status === "expired";
        const isActive  = task.id === _activeId;
        const isClosed  = task.status === "closed";
        const item = document.createElement("div");
        item.className = "ca-session-item" +
          (isActive  ? " active"             : "") +
          (isExpired ? " ca-session-expired" : "") +
          (isClosed  ? " ca-session-closed"  : "");

        if (isClosed) {
          const check = document.createElement("span");
          check.className = "ca-task-closed-icon";
          check.innerHTML = `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="width:12px;height:12px"><polyline points="2,8 6,12 14,4"/></svg>`;
          item.appendChild(check);
        } else {
          const badge = document.createElement("span");
          badge.className = "ca-task-item-badge " +
            (task.type === "worktree" ? "ca-task-badge-worktree" : "ca-task-badge-normal");
          badge.textContent = task.type === "worktree" ? _t("worktreeBadge") : _t("normalBadge");
          item.appendChild(badge);
        }

        const name = document.createElement("span");
        name.className = "ca-session-item-name";
        name.textContent = task.name || "Task";

        const cost = document.createElement("span");
        cost.className = "ca-session-item-cost";
        const tc = task.session?.total_cost;
        if (tc && tc > 0) cost.textContent = "$" + tc.toFixed(3);

        item.appendChild(name); item.appendChild(cost);

        if (!isExpired) {
          item.addEventListener("click", () => _switchTo(task));
        } else {
          item.title = "已清理，无法恢复";
          item.style.cursor = "default";
        }
        list.appendChild(item);
      });
    }

    async function _switchTo(task) {
      if (task.id === _activeId) return;
      _activeId = task.id;
      _activeTaskId = task.id;
      _renderList();
      try {
        const data = await _openTaskSession(_projectId, task.id);
        _mountChatCtx(data.session, data.task || task);
      } catch (err) { alert(_t("errOpen") + err.message); }
    }

    function addAndSwitch(task, session) {
      _tasks.unshift(task);
      _activeId     = task.id;
      _activeTaskId = task.id;
      _renderList();
      _hideEmptyHint();
      _mountChatCtx(session, task);
    }

    return { load, addAndSwitch, refresh() { if (_projectId) load(_projectId, _activeId); } };
  })();

  // ── New task dialog ────────────────────────────────────────────────────
  function _bindNewTaskModal() {
    const newBtn    = _$("ca-session-new-btn");
    const overlay   = _$("ca-new-task-modal");
    const nameInput = _$("ca-task-name-input");
    const descInput = _$("ca-task-desc-input");
    const createBtn = _$("ca-task-create-btn");
    const errEl     = _$("ca-task-form-error");
    if (!newBtn || !overlay) return;

    function _openModal() {
      const titleEl = _$("ca-modal-title");
      if (titleEl) titleEl.textContent = _t("newTaskTitle");
      const labelEl = _$("ca-task-name-label");
      if (labelEl) labelEl.textContent = _t("taskLabelNormal");
      overlay.style.display = "flex";
      nameInput?.focus();
    }

    function _closeModal() {
      overlay.style.display = "none";
      if (nameInput) nameInput.value = "";
      if (descInput) descInput.value = "";
      if (errEl) errEl.style.display = "none";
      overlay.querySelectorAll("input[type=radio]").forEach(r => { r.checked = r.value === "normal"; });
    }

    newBtn.addEventListener("click", _openModal);
    _$("ca-task-cancel-btn")?.addEventListener("click", _closeModal);
    _$("ca-task-cancel-btn2")?.addEventListener("click", _closeModal);
    overlay.addEventListener("click", e => { if (e.target === overlay) _closeModal(); });
    document.addEventListener("keydown", e => {
      if (e.key === "Escape" && overlay.style.display !== "none") _closeModal();
    });

    async function _doCreate() {
      const name = nameInput?.value.trim() || "";
      if (!name) {
        if (errEl) { errEl.textContent = _t("errTaskRequired"); errEl.style.display = "block"; }
        nameInput?.focus();
        return;
      }
      const desc = descInput?.value.trim() || "";
      const type = overlay.querySelector("input[name='ca-task-type']:checked")?.value || "normal";
      if (errEl) errEl.style.display = "none";
      createBtn.disabled = true;
      createBtn.textContent = _t("creating");
      try {
        const data = await _createTask(_activeProjectId, name, type);
        _closeModal();
        _TaskSwitcher.addAndSwitch(data.task, data.session);
        // Navigate to the new task via hash
        _wsNavigate(`${_activeProjectId}/tasks/${data.task.id}`);
        if (desc) {
          WS.send({ type: "message", session_id: data.session.id, content: desc });
        }
      } catch (err) {
        if (errEl) { errEl.textContent = err.message; errEl.style.display = "block"; }
      } finally {
        createBtn.disabled = false;
        createBtn.textContent = _t("create");
      }
    }

    createBtn?.addEventListener("click", _doCreate);
    nameInput?.addEventListener("keydown", e => { if (e.key === "Enter") _doCreate(); });
  }

  // ── Project grid ───────────────────────────────────────────────────────
  function renderGrid(projects) {
    const grid = _$("ca-project-grid");
    if (!grid) return;
    if (projects.length === 0) {
      grid.innerHTML = `<div class="ca-empty">${_t("empty")}</div>`;
      return;
    }
    grid.innerHTML = projects.map(p => `
      <div class="ca-project-card" data-ca-id="${p.id}">
        <div class="ca-project-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg></div>
        <div class="ca-project-name">${escapeHtml(p.name)}</div>
        <div class="ca-project-path">${escapeHtml(p.path)}</div>
        <div class="ca-project-date">${_fmtDate(p.created_at)}</div>
        <button class="ca-btn ca-btn-danger ca-project-delete" data-ca-delete="${p.id}">✕</button>
      </div>
    `).join("");

    grid.querySelectorAll(".ca-project-card").forEach(card => {
      card.addEventListener("click", async e => {
        if (e.target.dataset.caDelete) return;
        const project = _projects.find(p => p.id === card.dataset.caId);
        if (project) await _enterProject(project);
      });
    });

    grid.querySelectorAll("[data-ca-delete]").forEach(btn => {
      btn.addEventListener("click", async e => {
        e.stopPropagation();
        const id = btn.dataset.caDelete;
        if (!confirm(_t("confirmDel"))) return;
        try {
          await _deleteProject(id);
          _projects = _projects.filter(p => p.id !== id);
          renderGrid(_projects); renderSidebar(_projects);
        } catch (err) { alert(_t("errDelete") + err.message); }
      });
    });
  }

  // ── New project form ───────────────────────────────────────────────────
  function bindForm() {
    const newBtn = _$("ca-new-project-btn"), form = _$("ca-new-project-form");
    const cancelBtn = _$("ca-cancel-btn"), createBtn = _$("ca-create-btn");
    const nameInput = _$("ca-project-name"), pathInput = _$("ca-project-path");
    const errEl = _$("ca-form-error");
    if (!newBtn || !form) return;

    newBtn.addEventListener("click", () => { form.style.display = "block"; nameInput.focus(); });
    cancelBtn.addEventListener("click", () => {
      form.style.display = "none"; nameInput.value = ""; pathInput.value = ""; errEl.style.display = "none";
    });
    createBtn.addEventListener("click", async () => {
      const name = nameInput.value.trim(), path = pathInput.value.trim();
      errEl.style.display = "none";
      if (!name || !path) { errEl.textContent = _t("errRequired"); errEl.style.display = "block"; return; }
      createBtn.disabled = true; createBtn.textContent = _t("creating");
      try {
        const project = await _createProject(name, path);
        _projects.unshift(project);
        renderGrid(_projects); renderSidebar(_projects);
        form.style.display = "none"; nameInput.value = ""; pathInput.value = "";
        await _enterProject(project);
      } catch (err) { errEl.textContent = err.message; errEl.style.display = "block"; }
      finally { createBtn.disabled = false; createBtn.textContent = _t("create"); }
    });
    pathInput.addEventListener("keydown", e => { if (e.key === "Enter") createBtn.click(); });
  }

  // ── i18n apply ─────────────────────────────────────────────────────────
  function applySidebarI18n() {
    const el = document.getElementById("ca-sidebar-dashboard-label");
    if (el) el.textContent = _t("dashboard");
  }
  function applyPanelI18n() {
    const set = (id, text) => { const el = _$(id); if (el) el.textContent = text; };
    const setAttr = (id, attr, val) => { const el = _$(id); if (el) el.setAttribute(attr, val); };
    set("ca-title-projects", _t("title"));
    const newProjBtn = _$("ca-new-project-btn");
    if (newProjBtn) { const span = newProjBtn.querySelector("span"); if (span) span.textContent = _t("newProject"); }
    set("ca-label-name",    _t("labelName"));
    set("ca-label-path",    _t("labelPath"));
    set("ca-cancel-btn",    _t("cancel"));
    set("ca-create-btn",    _t("create"));
    set("ca-loading",       _t("loading"));
    set("ca-session-sidebar-label", _t("tasks"));
    set("ca-task-cancel-btn",  _t("cancel"));
    set("ca-task-cancel-btn2", _t("cancel"));
    set("ca-task-create-btn",  _t("create"));
    set("ca-task-type-normal-label",   _t("newNormalTask"));
    set("ca-task-type-worktree-label", _t("newWorktreeTask"));
    set("ca-task-desc-label",          _t("taskDescLabel"));
    setAttr("ca-project-name",     "placeholder", _t("placeName"));
    setAttr("ca-project-path",     "placeholder", _t("placePath"));
    setAttr("ca-task-name-input",  "placeholder", _t("taskLabelNormal"));
    setAttr("ca-task-desc-input",  "placeholder", _t("taskDescPlaceholder"));
    setAttr("ca-user-input",       "placeholder", "输入消息…（Enter 发送，Shift+Enter 换行）");
  }
  document.addEventListener("i18n:langchange", () => {
    applySidebarI18n();
    if (_initialized) applyPanelI18n();
  });

  // ── Sidebar ────────────────────────────────────────────────────────────
  function renderSidebar(projects) {
    const list = document.getElementById("ca-project-list");
    if (!list) return;
    list.innerHTML = "";
    projects.forEach(p => {
      const item = document.createElement("div");
      item.className = "task-item task-item-summary ca-sidebar-project";
      item.dataset.caId = p.id;
      item.innerHTML = `
        <div class="task-row">
          <span class="task-icon ca-sidebar-proj-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="width:15px;height:15px;display:block"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg></span>
          <div class="task-info"><span class="task-name">${escapeHtml(p.name)}</span></div>
        </div>`;
      item.addEventListener("click", e => {
        e.stopPropagation();
        _wsNavigate(p.id);
      });
      list.appendChild(item);
    });
    if (_activeProjectId) _highlightProject(_activeProjectId);
    else if ((location.hash || "").replace(/^#\/?/,"").startsWith("workspace")) _highlightDashboard();
  }

  // ── Open-in-editor button ─────────────────────────────────────────────
  function _bindOpenEditorButton() {
    const btn = _$("ca-btn-open-editor");
    if (!btn || btn._caBound) return;
    btn._caBound = true;
    btn.addEventListener("click", async () => {
      if (!_activeTaskWorkingDir) return;
      try {
        const res = await fetch("/api/workspace/open-in-editor", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ path: _activeTaskWorkingDir })
        });
        if (!res.ok) {
          const d = await res.json().catch(() => ({}));
          alert(d.error || "Failed to open editor");
        }
      } catch (err) {
        alert("Failed to open editor: " + err.message);
      }
    });
  }

  function _bindSidebarDashboard() {
    const el = document.querySelector(".ca-sidebar-dashboard");
    if (!el || el._caBound) return;
    el._caBound = true;
    el.addEventListener("click", e => { e.stopPropagation(); _wsNavigate(null); });
  }

  // ── Navigation (hash-based) ────────────────────────────────────────────
  // Hash patterns:
  //   #workspace                         → dashboard
  //   #workspace/{projectId}             → open project (smart-open last task)
  //   #workspace/{projectId}/tasks/{tid} → open specific task

  async function _routeTo(sub) {
    if (!sub) {
      _showDashboard();
      try { _projects = await _fetchProjects(); renderGrid(_projects); renderSidebar(_projects); } catch (_) {}
      return;
    }

    await _ensureProjects();

    const taskMatch = sub.match(/^([^/]+)\/tasks\/([^/]+)$/);
    if (taskMatch) {
      const [, projectId, taskId] = taskMatch;
      const project = _projects.find(p => p.id === projectId);
      if (!project) { _wsNavigate(null); return; }
      try {
        const data = await _openTaskSession(projectId, taskId);
        _activeTaskId = taskId;
        _showChatView(project);
        _mountChatCtx(data.session, data.task);
        _hideGlobalLoading();
      } catch (err) {
        alert(_t("errOpen") + err.message);
        _wsNavigate(null);
      }
      return;
    }

    const projectId = sub;
    const project = _projects.find(p => p.id === projectId);
    if (!project) { _wsNavigate(null); return; }
    await _enterProject(project);
  }

  async function _enterProject(project) {
    try {
      const tasks = await _fetchTasks(project.id);

      if (tasks.length === 0) {
        _showChatView(project);
        _showEmptyHint();
        _TaskSwitcher.load(project.id, null);
        _hideGlobalLoading();
        _wsNavigate(project.id);
        return;
      }

      const first = tasks[0];
      const data  = await _openTaskSession(project.id, first.id);
      _activeTaskId = first.id;
      _showChatView(project);
      _hideEmptyHint();
      _mountChatCtx(data.session, data.task);
      _hideGlobalLoading();
      _wsNavigate(`${project.id}/tasks/${first.id}`);
    } catch (err) {
      alert(_t("errOpen") + err.message);
      _showDashboard();
    }
  }

  async function _ensureProjects() {
    if (_projects.length === 0) {
      try { _projects = await _fetchProjects(); renderGrid(_projects); renderSidebar(_projects); } catch (_) {}
    }
  }

  // ── Hash routing bootstrap ─────────────────────────────────────────────
  // Called externally (by app.js dispatchEvent) or on page load
  function _handleCurrentHash() {
    const hash = (location.hash || "").replace(/^#\/?/, "");
    if (!hash.startsWith("workspace")) return;
    const sub = _parseWsHash(location.hash);
    if (!_initialized) {
      _initialized = true;
      init().then(() => _routeTo(sub));
    } else {
      _routeTo(sub);
    }
  }

  // Listen for real hashchange events (sidebar click → Router sets hash → dispatches event)
  window.addEventListener("hashchange", (e) => {
    const hash = (location.hash || "").replace(/^#\/?/, "");
    if (hash.startsWith("workspace")) {
      _handleCurrentHash();
    } else {
      _clearSidebarActive();
    }
  });

  // ── Init ───────────────────────────────────────────────────────────────
  async function init() {
    applyPanelI18n();
    _bindInput();
    _bindNewTaskModal();
    _bindOpenEditorButton();

    try { _projects = await _fetchProjects(); }
    catch (_) {
      _projects = [];
      const loading = _$("ca-loading");
      if (loading) loading.textContent = "Failed to load projects.";
      _hideGlobalLoading();
      return;
    }

    renderGrid(_projects);
    renderSidebar(_projects);
    bindForm();
    _hideGlobalLoading();
  }

  async function _initSidebar() {
    applySidebarI18n();
    _bindSidebarDashboard();
    try { _projects = await _fetchProjects(); renderSidebar(_projects); } catch (_) {}
  }

  // ── DOM injection ──────────────────────────────────────────────────────
  // Inject sidebar section HTML into #workspace-section placeholder
  function _injectSidebarHTML() {
    const el = document.getElementById("workspace-section");
    if (!el) return;
    el.innerHTML = `
      <div class="sidebar-divider"><span>Workspace</span></div>
      <div class="task-item task-item-summary ca-sidebar-dashboard" data-ca-nav="dashboard">
        <div class="task-row">
          <span class="task-icon ca-sidebar-dash-icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="width:15px;height:15px;display:block"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></svg></span>
          <div class="task-info">
            <span class="task-name" id="ca-sidebar-dashboard-label"></span>
          </div>
        </div>
      </div>
      <div id="ca-project-list"></div>`;
  }

  // Inject main panel HTML into #workspace-panel placeholder
  function _injectPanelHTML() {
    const el = document.getElementById("workspace-panel");
    if (!el) return;
    el.style.cssText = "display:none; flex:1; flex-direction:column; overflow:hidden; position:relative;";
    el.innerHTML = `
      <!-- Global loading overlay -->
      <div id="ca-global-loading" class="ca-global-loading">
        <div class="ca-global-loading-inner">
          <div class="ca-global-loading-spinner"><div class="ca-spinner-ring"></div></div>
          <div class="ca-global-loading-text">Loading\u2026</div>
        </div>
      </div>

      <!-- Dashboard view -->
      <div class="ca-panel" id="ca-view-dashboard">
        <div class="ca-panel-header">
          <h2 class="ca-panel-title">
            <svg class="ca-title-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/><polyline points="6 8 10 12 6 16"/><line x1="13" y1="16" x2="18" y2="16"/></svg>
            <span id="ca-title-projects"></span>
          </h2>
          <button class="ca-btn ca-btn-primary ca-new-proj-btn" id="ca-new-project-btn">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true" style="width:15px;height:15px;flex-shrink:0"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
            <span></span>
          </button>
        </div>
        <div class="ca-new-project-form" id="ca-new-project-form" style="display:none">
          <div class="ca-form-row">
            <label class="ca-form-label" id="ca-label-name"></label>
            <input class="ca-form-input" id="ca-project-name" type="text" autocomplete="off" />
          </div>
          <div class="ca-form-row">
            <label class="ca-form-label" id="ca-label-path"></label>
            <input class="ca-form-input" id="ca-project-path" type="text" autocomplete="off" />
          </div>
          <div class="ca-form-actions">
            <button class="ca-btn ca-btn-ghost" id="ca-cancel-btn"></button>
            <button class="ca-btn ca-btn-primary" id="ca-create-btn"></button>
          </div>
          <div class="ca-form-error" id="ca-form-error" style="display:none"></div>
        </div>
        <div class="ca-project-grid" id="ca-project-grid">
          <div class="ca-loading" id="ca-loading"></div>
        </div>
      </div>

      <!-- Project chat view -->
      <div class="ca-project-view" id="ca-view-project" style="display:none">
        <div class="ca-session-sidebar" id="ca-session-sidebar">
          <div class="ca-session-sidebar-header">
            <span class="ca-session-sidebar-title" id="ca-project-title"></span>
            <button class="ca-btn ca-btn-ghost ca-session-new-btn" id="ca-session-new-btn">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true" style="width:14px;height:14px"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
            </button>
          </div>
          <div class="ca-session-sidebar-label" id="ca-session-sidebar-label"></div>
          <div class="ca-session-list" id="ca-session-list"></div>
        </div>
        <div class="ca-chat-area">
          <div class="ca-chat-header" id="ca-chat-header" style="display:none">
            <span class="ca-chat-header-title" id="ca-chat-header-title"></span>
            <button class="ca-btn ca-btn-icon ca-chat-header-open-btn" id="ca-btn-open-editor"></button>
          </div>
          <div class="ca-empty-task-hint" id="ca-empty-task-hint" style="display:none">
            <div class="ca-empty-task-icon">\u2726</div>
            <div class="ca-empty-task-title" id="ca-empty-task-title"></div>
            <div class="ca-empty-task-desc" id="ca-empty-task-desc"></div>
          </div>
          <div class="ca-messages" id="ca-messages"></div>
          <div id="ca-session-info-bar" style="display:none">
            <span id="ca-sib-status"></span>
            <span class="ca-sib-sep">\u2502</span>
            <span id="ca-sib-id"></span>
            <span id="ca-sib-model-wrap"><span class="ca-sib-sep">\u2502</span><span id="ca-sib-model"></span></span>
            <span class="ca-sib-sep">\u2502</span>
            <span id="ca-sib-cost"></span>
            <span class="ca-sib-detail">
              <span class="ca-sib-sep">\u2502</span><span id="ca-sib-dir"></span>
              <span id="ca-sib-mode-wrap"><span class="ca-sib-sep">\u2502</span><span id="ca-sib-mode"></span></span>
              <span class="ca-sib-sep">\u2502</span><span id="ca-sib-tasks"></span>
            </span>
          </div>
          <div id="ca-input-area" class="ca-input-area">
            <div id="ca-skill-autocomplete" class="ca-skill-autocomplete" style="display:none" role="listbox">
              <div id="ca-skill-autocomplete-list"></div>
            </div>
            <div id="ca-image-preview-strip" class="ca-image-preview-strip" style="display:none"></div>
            <div class="ca-input-bar">
              <div class="ca-input-left">
                <input type="file" id="ca-image-file-input" accept="image/png,image/jpeg,image/gif,image/webp,application/pdf" multiple style="display:none">
                <button id="ca-btn-attach" class="ca-btn ca-btn-icon" title="\u9644\u4ef6">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="width:18px;height:18px"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>
                </button>
                <button id="ca-btn-slash" class="ca-btn ca-btn-icon">/</button>
              </div>
              <textarea id="ca-user-input" class="ca-user-input" rows="1"></textarea>
              <div class="ca-input-actions">
                <button id="ca-btn-send" class="ca-btn ca-btn-primary ca-btn-send">\u53d1\u9001</button>
                <button id="ca-btn-interrupt" class="ca-btn ca-btn-ghost ca-btn-interrupt" style="display:none">
                  <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" style="width:14px;height:14px"><rect x="4" y="4" width="16" height="16" rx="2"/></svg>
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- New task modal -->
      <div class="ca-modal-overlay" id="ca-new-task-modal" style="display:none" role="dialog" aria-modal="true">
        <div class="ca-modal-box">
          <div class="ca-modal-header">
            <span class="ca-modal-title" id="ca-modal-title"></span>
            <button class="ca-modal-close" id="ca-task-cancel-btn" aria-label="Close">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true" style="width:16px;height:16px"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
            </button>
          </div>
          <div class="ca-modal-body">
            <label class="ca-modal-label" id="ca-task-name-label"></label>
            <input class="ca-form-input" id="ca-task-name-input" type="text" autocomplete="off" />
            <label class="ca-modal-label ca-modal-label-sm" id="ca-task-desc-label"></label>
            <textarea class="ca-form-input ca-task-desc-input" id="ca-task-desc-input" rows="3"></textarea>
            <div class="ca-task-type-row">
              <label class="ca-task-type-opt">
                <input type="radio" name="ca-task-type" value="normal" checked>
                <span id="ca-task-type-normal-label"></span>
              </label>
              <label class="ca-task-type-opt">
                <input type="radio" name="ca-task-type" value="worktree">
                <span id="ca-task-type-worktree-label"></span>
              </label>
            </div>
            <div class="ca-form-error" id="ca-task-form-error" style="display:none"></div>
          </div>
          <div class="ca-modal-footer">
            <button class="ca-btn ca-btn-ghost" id="ca-task-cancel-btn2"></button>
            <button class="ca-btn ca-btn-primary" id="ca-task-create-btn"></button>
          </div>
        </div>
      </div>`;
  }

  // ── Self-boot on DOMContentLoaded ──────────────────────────────────────
  function _boot() {
    _injectSidebarHTML();
    _injectPanelHTML();
    _initSidebar();
    // If page loaded directly on a workspace hash, bootstrap
    const hash = (location.hash || "").replace(/^#\/?/, "");
    if (hash.startsWith("workspace")) {
      _handleCurrentHash();
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", _boot);
  } else {
    _boot();
  }
})();
