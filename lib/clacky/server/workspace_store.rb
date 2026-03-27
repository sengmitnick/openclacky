# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"

module Clacky
  module Server
    # WorkspaceStore manages project and task data for the workspace feature.
    #
    # Projects are stored as a flat JSON file:
    #   ~/clacky_workspace/projects.json
    #
    # Each project:
    #   {
    #     "id":         "uuid",
    #     "name":       "openclacky-code",
    #     "path":       "/Users/xxx/projects/openclacky-code",
    #     "created_at": "ISO8601",
    #     "task_ids":   ["task-uuid", ...]   # newest first
    #   }
    #
    # Tasks are stored separately:
    #   ~/clacky_workspace/tasks.json
    #
    # Each task:
    #   {
    #     "id":            "uuid",
    #     "project_id":    "uuid",
    #     "name":          "Fix login bug",
    #     "type":          "normal | worktree",
    #     "session_id":    "session-uuid",
    #     "branch":        "clacky/fix-login-a3f2",   # worktree only
    #     "worktree_path": "/path/.clacky-worktrees/task-uuid",  # worktree only
    #     "created_at":    "ISO8601",
    #     "status":        "open | closed"   # default: "open"
    #   }
    #
    # Thread safety: all public methods are protected by a Mutex.
    class WorkspaceStore
      PROJECTS_FILE = File.join(Dir.home, "clacky_workspace", "projects.json")
      TASKS_FILE    = File.join(Dir.home, "clacky_workspace", "tasks.json")

      def initialize(projects_file = PROJECTS_FILE, tasks_file = TASKS_FILE)
        @projects_file = projects_file
        @tasks_file    = tasks_file
        @mutex         = Mutex.new
        ensure_data_files
      end

      # ── Projects ────────────────────────────────────────────────────────

      # Return all projects sorted newest-first.
      def list
        @mutex.synchronize { load_projects }
      end

      # Find a project by id. Returns nil if not found.
      def find(id)
        @mutex.synchronize { load_projects.find { |p| p["id"] == id } }
      end

      # Create a new project. Returns the created project hash.
      # Raises ArgumentError if name or path is blank.
      def create(name:, path:)
        raise ArgumentError, "name is required" if name.nil? || name.strip.empty?
        raise ArgumentError, "path is required" if path.nil? || path.strip.empty?

        project = {
          "id"         => SecureRandom.uuid,
          "name"       => name.strip,
          "path"       => path.strip,
          "created_at" => Time.now.iso8601,
          "task_ids"   => []
        }

        @mutex.synchronize do
          projects = load_projects
          projects.unshift(project)
          save_projects(projects)
        end

        project
      end

      # Delete a project by id. Returns true if deleted, false if not found.
      def delete(id)
        @mutex.synchronize do
          projects = load_projects
          original = projects.size
          projects.reject! { |p| p["id"] == id }
          if projects.size < original
            save_projects(projects)
            true
          else
            false
          end
        end
      end

      # ── Tasks ──────────────────────────────────────────────────────────

      # Return all tasks for a project (newest first).
      def list_tasks(project_id)
        @mutex.synchronize do
          project = load_projects.find { |p| p["id"] == project_id }
          return [] unless project

          task_ids = Array(project["task_ids"])
          all_tasks = load_tasks
          task_ids.filter_map { |tid| all_tasks.find { |t| t["id"] == tid } }
        end
      end

      # Find a task by id. Returns nil if not found.
      def find_task(task_id)
        @mutex.synchronize { load_tasks.find { |t| t["id"] == task_id } }
      end

      # Create a new task for a project.
      # type: "normal" or "worktree"
      # Returns the created task hash.
      def create_task(project_id:, name:, type: "normal", session_id: nil,
                      branch: nil, worktree_path: nil)
        raise ArgumentError, "project_id is required" if project_id.nil? || project_id.strip.empty?
        raise ArgumentError, "name is required"       if name.nil? || name.strip.empty?
        raise ArgumentError, "type must be normal or worktree" unless %w[normal worktree].include?(type)

        task = {
          "id"           => SecureRandom.uuid,
          "project_id"   => project_id,
          "name"         => name.strip,
          "type"         => type,
          "status"       => "open",
          "session_id"   => session_id,
          "created_at"   => Time.now.iso8601
        }
        task["branch"]        = branch        if branch
        task["worktree_path"] = worktree_path if worktree_path

        @mutex.synchronize do
          tasks    = load_tasks
          tasks.unshift(task)
          save_tasks(tasks)

          projects = load_projects
          project  = projects.find { |p| p["id"] == project_id }
          if project
            ids = project["task_ids"] ||= []
            ids.unshift(task["id"]) unless ids.include?(task["id"])
            save_projects(projects)
          end
        end

        task
      end

      # Update a task's session_id (called after a session is created/restored).
      def update_task_session(task_id, session_id)
        @mutex.synchronize do
          tasks = load_tasks
          task  = tasks.find { |t| t["id"] == task_id }
          return false unless task

          task["session_id"] = session_id
          save_tasks(tasks)
          true
        end
      end

      # Close a task (status → "closed"). Returns true if updated, false if not found.
      def close_task(task_id)
        update_task_status(task_id, "closed")
      end

      # Reopen a closed task (status → "open"). Returns true if updated, false if not found.
      def reopen_task(task_id)
        update_task_status(task_id, "open")
      end

      # Delete a task. Returns the task hash (with worktree_path) or nil.
      def delete_task(task_id)
        @mutex.synchronize do
          tasks     = load_tasks
          task      = tasks.find { |t| t["id"] == task_id }
          return nil unless task

          tasks.reject! { |t| t["id"] == task_id }
          save_tasks(tasks)

          # Remove from project's task_ids list
          projects = load_projects
          project  = projects.find { |p| p["id"] == task["project_id"] }
          if project
            project["task_ids"] = Array(project["task_ids"]).reject { |tid| tid == task_id }
            save_projects(projects)
          end

          task
        end
      end

      # ── Legacy session compatibility ────────────────────────────────────
      # Projects created before the task system used session_ids + last_session_id.
      # This method migrates them on first access.

      # Return the legacy last_session_id for a project (used for migration only).
      def legacy_session_ids(project_id)
        @mutex.synchronize do
          project = load_projects.find { |p| p["id"] == project_id }
          return [] unless project

          ids  = Array(project["session_ids"])
          last = project["last_session_id"]
          ids.unshift(last) if last && !ids.include?(last)
          ids
        end
      end

      # Migrate legacy session_ids to tasks if task_ids is empty.
      # Each session becomes a "normal" task. Returns count of tasks created.
      def migrate_legacy_sessions(project_id)
        @mutex.synchronize do
          projects = load_projects
          project  = projects.find { |p| p["id"] == project_id }
          return 0 unless project

          # Already migrated or has no legacy data
          return 0 if Array(project["task_ids"]).any?
          return 0 if Array(project["session_ids"]).empty? && project["last_session_id"].nil?

          ids  = Array(project["session_ids"])
          last = project["last_session_id"]
          ids.unshift(last) if last && !ids.include?(last)
          return 0 if ids.empty?

          tasks        = load_tasks
          new_task_ids = []

          ids.each_with_index do |sid, idx|
            task = {
              "id"         => SecureRandom.uuid,
              "project_id" => project_id,
              "name"       => "#{project["name"]} ##{ids.size - idx}",
              "type"       => "normal",
              "session_id" => sid,
              "created_at" => project["created_at"] || Time.now.iso8601
            }
            tasks.unshift(task)
            new_task_ids << task["id"]
          end

          save_tasks(tasks)
          project["task_ids"] = new_task_ids
          save_projects(projects)

          new_task_ids.size
        end
      end

      private

      private def update_task_status(task_id, status)
        @mutex.synchronize do
          tasks = load_tasks
          task  = tasks.find { |t| t["id"] == task_id }
          return false unless task

          task["status"] = status
          save_tasks(tasks)
          true
        end
      end

      private def ensure_data_files
        dir = File.dirname(@projects_file)
        FileUtils.mkdir_p(dir)
        File.write(@projects_file, "[]") unless File.exist?(@projects_file)
        File.write(@tasks_file, "[]")    unless File.exist?(@tasks_file)
      end

      private def load_projects
        raw  = File.read(@projects_file)
        data = JSON.parse(raw)
        data.is_a?(Array) ? data : []
      rescue JSON::ParserError
        []
      end

      private def save_projects(projects)
        File.write(@projects_file, JSON.pretty_generate(projects))
      end

      private def load_tasks
        raw  = File.read(@tasks_file)
        data = JSON.parse(raw)
        data.is_a?(Array) ? data : []
      rescue JSON::ParserError
        []
      end

      private def save_tasks(tasks)
        File.write(@tasks_file, JSON.pretty_generate(tasks))
      end
    end
  end
end
