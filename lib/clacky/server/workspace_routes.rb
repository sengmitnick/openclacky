# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "shellwords"
require "uri"
require "json"
require_relative "workspace_store"

module Clacky
  module Server
    # WorkspaceRoutes handles all /api/workspace/* API endpoints.
    #
    # Usage: mixed into HttpServer — call WorkspaceRoutes.dispatch(method, path, req, res, server)
    # where server is the HttpServer instance (provides json_response, parse_json_body,
    # build_session, build_session_from_data, @registry, @session_manager).
    module WorkspaceRoutes
      # Returns true if this module handles the given method+path.
      def self.handles?(method, path)
        return true if path.start_with?("/api/workspace/")
        path == "/api/workspace" && method == "GET"
      end

      # Main dispatch entry point. Called from HttpServer#dispatch.
      def self.dispatch(method, path, req, res, server)
        store = workspace_store

        case [method, path]
        when ["GET",  "/api/workspace/projects"]
          handle_list_projects(res, store, server)
        when ["POST", "/api/workspace/projects"]
          handle_create_project(req, res, store, server)
        when ["GET",  "/api/workspace/editor-info"]
          handle_editor_info(res, server)
        when ["POST", "/api/workspace/open-in-editor"]
          handle_open_in_editor(req, res, server)
        else
          # Pattern-matched routes
          if method == "DELETE" && (m = path.match(%r{^/api/workspace/projects/([^/]+)$}))
            handle_delete_project(URI.decode_www_form_component(m[1]), res, store, server)

          elsif method == "GET" && (m = path.match(%r{^/api/workspace/projects/([^/]+)/tasks$}))
            handle_list_tasks(URI.decode_www_form_component(m[1]), res, store, server)

          elsif method == "POST" && (m = path.match(%r{^/api/workspace/projects/([^/]+)/tasks$}))
            handle_create_task(URI.decode_www_form_component(m[1]), req, res, store, server)

          elsif method == "DELETE" && (m = path.match(%r{^/api/workspace/projects/([^/]+)/tasks/([^/]+)$}))
            handle_delete_task(URI.decode_www_form_component(m[1]),
                               URI.decode_www_form_component(m[2]), res, store, server)

          elsif method == "PATCH" && (m = path.match(%r{^/api/workspace/projects/([^/]+)/tasks/([^/]+)/close$}))
            handle_close_task(URI.decode_www_form_component(m[1]),
                              URI.decode_www_form_component(m[2]), res, store, server)

          elsif method == "PATCH" && (m = path.match(%r{^/api/workspace/projects/([^/]+)/tasks/([^/]+)/reopen$}))
            handle_reopen_task(URI.decode_www_form_component(m[1]),
                               URI.decode_www_form_component(m[2]), res, store, server)

          elsif method == "GET" && (m = path.match(%r{^/api/workspace/projects/([^/]+)/tasks/([^/]+)/session$}))
            handle_task_session(URI.decode_www_form_component(m[1]),
                                URI.decode_www_form_component(m[2]), res, store, server)

          elsif method == "GET" && (m = path.match(%r{^/api/workspace/editor-icon/([^/]+)$}))
            handle_editor_icon(m[1], res, server)

          else
            server.send(:not_found, res)
          end
        end
      end

      # ── Lazy singleton store ──────────────────────────────────────────

      def self.workspace_store
        @_store_mu ||= Mutex.new
        @_store_mu.synchronize do
          @_store ||= Clacky::Server::WorkspaceStore.new
        end
      end

      # ── Helper: slugify a task name into a git branch segment ─────────
      # "Fix login bug" → "clacky/fix-login-bug-a3f2"
      def self.branch_slug(name)
        slug = name.downcase
                   .gsub(/[^a-z0-9\s-]/, "")
                   .strip
                   .gsub(/\s+/, "-")
                   .gsub(/-{2,}/, "-")[0..39]
        suffix = SecureRandom.hex(2) # 4 hex chars
        "clacky/#{slug}-#{suffix}"
      end

      # ── Helper: worktree base dir for a project ───────────────────────
      # Places worktrees at ~/clacky_workspace/worktrees/{project_id}/{task_id}/
      def self.worktree_path(project, task_id)
        File.join(Dir.home, "clacky_workspace", "worktrees", project["id"], task_id)
      end

      # ── Helper: restore or create a session for a task ────────────────
      # Returns [session_id, is_new]
      # Uses registry.ensure for lazy restore (same path as WS "subscribe") so we
      # don't duplicate that logic here.
      def self.resolve_task_session(task, project, server)
        working_dir = task["type"] == "worktree" ? task["worktree_path"] : project["path"]
        session_id  = task["session_id"]
        registry    = server.instance_variable_get(:@registry)

        # If task already has a session_id, let registry.ensure handle it:
        # it's either already live in memory (fast path) or gets lazy-restored
        # from disk — exactly the same flow as a WS "subscribe" message.
        if session_id && registry.ensure(session_id)
          return [session_id, false]
        end

        # No session yet (or stale id that no longer exists on disk): create fresh.
        FileUtils.mkdir_p(working_dir)
        new_id = server.send(:build_session, name: task["name"], working_dir: working_dir, profile: "coding")
        [new_id, true]
      end

      # ── GET /api/workspace/projects ───────────────────────────────────
      def self.handle_list_projects(res, store, server)
        projects = store.list
        server.send(:json_response, res, 200, { projects: projects })
      end

      # ── POST /api/workspace/projects ──────────────────────────────────
      def self.handle_create_project(req, res, store, server)
        body = server.send(:parse_json_body, req)
        name = body["name"].to_s.strip
        path = body["path"].to_s.strip

        return server.send(:json_response, res, 400, { error: "name is required" }) if name.empty?
        return server.send(:json_response, res, 400, { error: "path is required" }) if path.empty?
        return server.send(:json_response, res, 422, { error: "Path does not exist: #{path}" }) unless Dir.exist?(path)

        project = store.create(name: name, path: path)
        server.send(:json_response, res, 201, { project: project })
      end

      # ── DELETE /api/workspace/projects/:id ────────────────────────────
      def self.handle_delete_project(project_id, res, store, server)
        deleted = store.delete(project_id)
        if deleted
          server.send(:json_response, res, 200, { ok: true })
        else
          server.send(:json_response, res, 404, { error: "Project not found" })
        end
      end

      # ── GET /api/workspace/projects/:id/tasks ─────────────────────────
      def self.handle_list_tasks(project_id, res, store, server)
        project = store.find(project_id)
        return server.send(:json_response, res, 404, { error: "Project not found" }) unless project

        # One-time migration: convert legacy session_ids → normal tasks
        store.migrate_legacy_sessions(project_id)

        tasks           = store.list_tasks(project_id)
        snapshots_base  = File.join(Dir.home, ".clacky", "snapshots")
        registry        = server.instance_variable_get(:@registry)
        session_mgr     = server.instance_variable_get(:@session_manager)

        # Enrich each task with live session summary
        enriched = tasks.map do |task|
          sid          = task["session_id"]
          session_info = nil

          if sid
            # Try live registry first
            s = registry.session_summary(sid)
            if s
              session_info = { status: s[:status], total_cost: s[:total_cost], name: s[:name] }
            else
              # Try disk snapshot
              data = session_mgr.load(sid)
              if data
                session_info = {
                  status:     "idle",
                  total_cost: data.dig(:stats, :total_cost) || 0,
                  name:       data[:name]
                }
              else
                # Check snapshot dir (expired)
                snapshot_dir = File.join(snapshots_base, sid)
                session_info = { status: "expired", total_cost: 0 } if Dir.exist?(snapshot_dir)
              end
            end
          end

          task.merge("session" => session_info)
        end

        server.send(:json_response, res, 200, { tasks: enriched })
      end

      # ── POST /api/workspace/projects/:id/tasks ────────────────────────
      def self.handle_create_task(project_id, req, res, store, server)
        body = server.send(:parse_json_body, req)
        name = body["name"].to_s.strip
        type = body["type"].to_s.strip
        type = "normal" unless %w[normal worktree].include?(type)

        return server.send(:json_response, res, 400, { error: "name is required" }) if name.empty?

        project = store.find(project_id)
        return server.send(:json_response, res, 404, { error: "Project not found" }) unless project

        project_path = project["path"]
        return server.send(:json_response, res, 422, { error: "Project path does not exist: #{project_path}" }) unless Dir.exist?(project_path)

        branch        = nil
        wt_path       = nil

        if type == "worktree"
          git_dir = File.join(project_path, ".git")
          unless Dir.exist?(git_dir) || File.exist?(git_dir)
            return server.send(:json_response, res, 422, { error: "Project is not a git repository (no .git found)" })
          end

          branch       = branch_slug(name)
          task_id_temp = SecureRandom.uuid
          wt_path      = worktree_path(project, task_id_temp)

          FileUtils.mkdir_p(File.dirname(wt_path))
          out = `cd #{Shellwords.escape(project_path)} && git worktree add #{Shellwords.escape(wt_path)} -b #{Shellwords.escape(branch)} 2>&1`
          unless $?.success?
            return server.send(:json_response, res, 422, { error: "Failed to create git worktree: #{out.strip}" })
          end
        end

        task = store.create_task(
          project_id:   project_id,
          name:         name,
          type:         type,
          branch:       branch,
          worktree_path: wt_path
        )

        # Build a session immediately so the frontend can mount it right away
        working_dir = type == "worktree" ? wt_path : project_path
        FileUtils.mkdir_p(working_dir)
        session_id = server.send(:build_session, name: name, working_dir: working_dir, profile: "coding")
        store.update_task_session(task["id"], session_id)
        task["session_id"] = session_id

        registry = server.instance_variable_get(:@registry)
        session  = registry.session_summary(session_id)

        server.send(:json_response, res, 201, { task: task, session: session })
      end

      # ── DELETE /api/workspace/projects/:id/tasks/:tid ─────────────────
      def self.handle_delete_task(project_id, task_id, res, store, server)
        task = store.find_task(task_id)
        return server.send(:json_response, res, 404, { error: "Task not found" }) unless task
        return server.send(:json_response, res, 403, { error: "Task does not belong to this project" }) if task["project_id"] != project_id

        # Clean up worktree if applicable
        if task["type"] == "worktree" && task["worktree_path"]
          project = store.find(project_id)
          if project && Dir.exist?(project["path"])
            `cd #{Shellwords.escape(project["path"])} && git worktree remove #{Shellwords.escape(task["worktree_path"])} --force 2>&1`
          end
          FileUtils.rm_rf(task["worktree_path"]) if Dir.exist?(task["worktree_path"])
        end

        store.delete_task(task_id)
        server.send(:json_response, res, 200, { ok: true })
      end

      # ── PATCH /api/workspace/projects/:id/tasks/:tid/close ────────────
      def self.handle_close_task(project_id, task_id, res, store, server)
        task = store.find_task(task_id)
        return server.send(:json_response, res, 404, { error: "Task not found" }) unless task
        return server.send(:json_response, res, 403, { error: "Task does not belong to this project" }) if task["project_id"] != project_id
        return server.send(:json_response, res, 422, { error: "Task is already closed" }) if task["status"] == "closed"

        # For worktree tasks: remove the worktree directory (branch kept for reopen)
        if task["type"] == "worktree" && task["worktree_path"] && Dir.exist?(task["worktree_path"].to_s)
          project = store.find(project_id)
          if project && Dir.exist?(project["path"].to_s)
            `cd #{Shellwords.escape(project["path"])} && git worktree remove #{Shellwords.escape(task["worktree_path"])} --force 2>&1`
          end
          FileUtils.rm_rf(task["worktree_path"])
        end

        store.close_task(task_id)
        server.send(:json_response, res, 200, { ok: true, task_id: task_id, status: "closed" })
      end

      # ── PATCH /api/workspace/projects/:id/tasks/:tid/reopen ───────────
      def self.handle_reopen_task(project_id, task_id, res, store, server)
        task    = store.find_task(task_id)
        project = store.find(project_id)
        return server.send(:json_response, res, 404, { error: "Task not found" }) unless task
        return server.send(:json_response, res, 404, { error: "Project not found" }) unless project
        return server.send(:json_response, res, 403, { error: "Task does not belong to this project" }) if task["project_id"] != project_id
        return server.send(:json_response, res, 422, { error: "Task is already open" }) if task["status"] != "closed"

        # For worktree tasks: recreate worktree from existing branch
        if task["type"] == "worktree" && task["branch"] && task["worktree_path"]
          wt_path = task["worktree_path"]
          unless Dir.exist?(wt_path)
            FileUtils.mkdir_p(File.dirname(wt_path))
            out = `cd #{Shellwords.escape(project["path"])} && git worktree add #{Shellwords.escape(wt_path)} #{Shellwords.escape(task["branch"])} 2>&1`
            unless $?.success?
              return server.send(:json_response, res, 422, { error: "Failed to recreate git worktree: #{out.strip}" })
            end
          end
        end

        store.reopen_task(task_id)
        server.send(:json_response, res, 200, { ok: true, task_id: task_id, status: "open" })
      end

      # ── GET /api/workspace/projects/:id/tasks/:tid/session ────────────
      def self.handle_task_session(project_id, task_id, res, store, server)
        project = store.find(project_id)
        return server.send(:json_response, res, 404, { error: "Project not found" }) unless project

        task = store.find_task(task_id)
        return server.send(:json_response, res, 404, { error: "Task not found" }) unless task

        working_dir = task["type"] == "worktree" ? task["worktree_path"] : project["path"]
        return server.send(:json_response, res, 422, { error: "Working directory does not exist: #{working_dir}" }) unless Dir.exist?(working_dir.to_s)

        task = task.merge("working_dir" => working_dir)
        session_id, is_new = resolve_task_session(task, project, server)
        store.update_task_session(task_id, session_id)

        registry = server.instance_variable_get(:@registry)
        session  = registry.session_summary(session_id)
        server.send(:json_response, res, 200, { session: session, task: task, is_new: is_new })
      end

      # ── GET /api/workspace/editor-info ────────────────────────────────
      def self.handle_editor_info(res, server)
        cursor_path = "/Applications/Cursor.app"
        vscode_path = "/Applications/Visual Studio Code.app"

        editor = if Dir.exist?(cursor_path)
          { id: "cursor", name: "Cursor", command: "cursor", icon_url: "/api/workspace/editor-icon/cursor" }
        elsif Dir.exist?(vscode_path)
          { id: "vscode", name: "VS Code", command: "code", icon_url: "/api/workspace/editor-icon/vscode" }
        else
          { id: "finder", name: "Finder", command: nil, icon_url: nil }
        end

        server.send(:json_response, res, 200, { editor: editor })
      end

      # ── GET /api/workspace/editor-icon/:id ────────────────────────────
      def self.handle_editor_icon(editor_id, res, server)
        icon_path = case editor_id
        when "cursor" then "/Applications/Cursor.app/Contents/Resources/Cursor.icns"
        when "vscode" then "/Applications/Visual Studio Code.app/Contents/Resources/Code.icns"
        end

        if icon_path && File.exist?(icon_path)
          tmp_png = "/tmp/clacky_editor_icon_#{editor_id}.png"
          unless File.exist?(tmp_png)
            `sips -s format png #{Shellwords.escape(icon_path)} --out #{Shellwords.escape(tmp_png)} 2>/dev/null`
          end
          if File.exist?(tmp_png)
            res.status = 200
            res["Content-Type"]  = "image/png"
            res["Cache-Control"] = "public, max-age=86400"
            res.body = File.binread(tmp_png)
            return
          end
        end

        server.send(:json_response, res, 404, { error: "Icon not found" })
      end

      # ── POST /api/workspace/open-in-editor ────────────────────────────
      def self.handle_open_in_editor(req, res, server)
        body = server.send(:parse_json_body, req)
        path = body["path"].to_s.strip

        return server.send(:json_response, res, 400, { error: "path is required" }) if path.empty?
        return server.send(:json_response, res, 422, { error: "Path does not exist: #{path}" }) unless Dir.exist?(path) || File.exist?(path)

        if Dir.exist?("/Applications/Cursor.app")
          spawn("open", "-a", "Cursor", path)
        elsif Dir.exist?("/Applications/Visual Studio Code.app")
          spawn("open", "-a", "Visual Studio Code", path)
        else
          spawn("open", path)
        end

        server.send(:json_response, res, 200, { ok: true })
      end
    end
  end
end
