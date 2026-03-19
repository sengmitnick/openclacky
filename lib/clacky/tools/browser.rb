# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "shellwords"
require_relative "base"

module Clacky
  module Tools
    # Browser tool — controls the user's real Chromium-based browser (Chrome 146+)
    # via the Chrome DevTools MCP server (chrome-devtools-mcp).
    #
    # Architecture: profile="user" uses the existing-session driver (Chrome MCP).
    #   npx -y chrome-devtools-mcp@latest --autoConnect --experimentalStructuredContent
    #       --experimental-page-id-routing [--userDataDir <path>]
    #
    # Communication: MCP stdio JSON-RPC 2.0 — the tool spawns a short-lived MCP
    # process per tool invocation (stateless) or reuses a persistent session.
    #
    # No agent-browser, no DevToolsActivePort, no CDP port management.
    class Browser < Base
      self.tool_name = "browser"
      self.tool_description = <<~DESC
        Control the browser for automation tasks (login, form submission, UI interaction, scraping).
        For simple page fetch or search, prefer web_fetch or web_search instead.

        PROFILES — choose the right browser context:
        - profile="user"    → your real browser (Chrome/Edge/Brave) with existing logins & cookies. Requires Chrome 146+.
        - profile="sandbox" → isolated sandboxed browser (default, no cookies).

        ACTIONS OVERVIEW:
        - snapshot   → get accessibility tree with element refs. ALWAYS run before interacting.
        - act        → interact with page: click, type, fill, press, hover, scroll, drag, select, wait, evaluate
        - open       → open URL in a new tab
        - navigate   → navigate current tab to URL
        - tabs       → list open tabs
        - focus      → switch to a tab by targetId
        - close      → close current tab
        - screenshot → capture screenshot. Ask user first (high token cost).
        - status     → check if browser is running

        SNAPSHOT WORKFLOW — always snapshot first:
        - action="snapshot"                            → full accessibility tree
        - action="snapshot", interactive=true          → interactive elements only (recommended)
        - action="snapshot", interactive=true, compact=true → compact interactive

        ACT KINDS: click, type, fill, press, hover, drag, select, scroll, wait, evaluate
        - click:   ref="e1"
        - fill:    ref="e1", text="value"
        - press:   key="Enter"
        - scroll:  direction="down", amount=300
        - wait:    ms=2000 OR selector=".spinner"
        - evaluate: js="document.title"

        TARGETING TABS — pass target_id from snapshot/tabs to subsequent acts.
      DESC
      self.tool_category = "web"
      self.tool_parameters = {
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: %w[snapshot act open navigate tabs focus close screenshot status],
            description: "Action to perform."
          },
          profile: {
            type: "string",
            enum: %w[sandbox user],
            description: "Browser profile. 'user' = real browser (Chrome 146+). 'sandbox' = isolated (default)."
          },
          interactive: {
            type: "boolean",
            description: "snapshot: only include interactive elements."
          },
          compact: {
            type: "boolean",
            description: "snapshot: remove empty structural elements."
          },
          depth: {
            type: "integer",
            description: "snapshot: max tree depth."
          },
          selector: {
            type: "string",
            description: "snapshot scope / act CSS selector."
          },
          kind: {
            type: "string",
            enum: %w[click dblclick type fill press hover drag select scroll wait evaluate],
            description: "act: interaction kind."
          },
          ref: {
            type: "string",
            description: "act: element ref from snapshot (e.g. 'e1')."
          },
          text: { type: "string", description: "act type/fill: text to enter." },
          key:  { type: "string", description: "act press: key (e.g. 'Enter')." },
          direction: {
            type: "string",
            enum: %w[up down left right],
            description: "act scroll: direction."
          },
          amount:     { type: "integer", description: "act scroll: pixels." },
          ms:         { type: "integer", description: "act wait: milliseconds." },
          load_state: {
            type: "string",
            enum: %w[load domcontentloaded networkidle],
            description: "act wait: page load state."
          },
          js:         { type: "string", description: "act evaluate: JS expression." },
          target_ref: { type: "string", description: "act drag: destination ref." },
          values: {
            type: "array",
            items: { type: "string" },
            description: "act select: option values."
          },
          double_click: { type: "boolean", description: "act click: double-click." },
          url:       { type: "string",  description: "open/navigate: URL." },
          target_id: { type: "string",  description: "tab targetId from open/tabs." },
          format: {
            type: "string",
            enum: %w[png jpeg],
            description: "screenshot: format (default jpeg)."
          },
          quality:   { type: "integer", description: "screenshot: JPEG quality 0-100." },
          full_page: { type: "boolean", description: "screenshot: full scrollable page." }
        },
        required: ["action"]
      }

      # Chrome MCP command constants
      CHROME_MCP_COMMAND = "npx"
      CHROME_MCP_ARGS = %w[
        -y
        chrome-devtools-mcp@latest
        --autoConnect
        --experimentalStructuredContent
        --experimental-page-id-routing
      ].freeze

      # Minimum Chrome major version for Chrome MCP support
      MIN_CHROME_MAJOR = 146

      # MCP tool call timeout (seconds)
      MCP_TIMEOUT = 30

      MAX_SNAPSHOT_CHARS   = 4000
      MAX_LLM_OUTPUT_CHARS = 6000

      def execute(action:, profile: nil, working_dir: nil, **opts)
        use_user = profile.to_s == "user"

        if use_user
          execute_user_browser(action, opts)
        else
          execute_sandbox(action, opts)
        end
      rescue StandardError => e
        { error: "Browser error: #{e.message}" }
      end

      def format_call(args)
        action  = args[:action]  || args["action"]  || "browser"
        profile = args[:profile] || args["profile"]
        suffix  = profile ? "(#{action}, profile=#{profile})" : "(#{action})"
        "browser#{suffix}"
      end

      def format_result(result)
        return "[Error] #{result[:error].to_s[0..80]}" if result[:error]
        return "[OK] #{result[:output].to_s.lines.size} lines" if result[:output]
        "[OK] Done"
      end

      def format_result_for_llm(result)
        return result if result[:error]

        action = result[:action].to_s
        output = result[:output].to_s

        output = compress_snapshot(output) if action == "snapshot"
        max_chars = action == "snapshot" ? MAX_SNAPSHOT_CHARS : MAX_LLM_OUTPUT_CHARS

        truncated = truncate_output(output, max_chars)

        {
          action:  action,
          success: result[:success],
          stdout:  truncated,
          profile: result[:profile]
        }.compact
      end

      private

      # -----------------------------------------------------------------------
      # User browser (Chrome MCP / existing-session driver)
      # -----------------------------------------------------------------------

      private def execute_user_browser(action, opts)
        unless chrome_mcp_available?
          return {
            error: "chrome-devtools-mcp requires Node.js and npx. " \
                   "Install Node.js 18+ and ensure 'npx' is in PATH."
          }
        end

        case action.to_s
        when "tabs"
          result = mcp_call("list_pages")
          pages  = extract_pages(result)
          { action: "tabs", success: true, profile: "user", output: format_tabs(pages), tabs: pages }
        when "snapshot"
          do_user_snapshot(opts)
        when "open"
          url = require_url(opts)
          return url if url.is_a?(Hash)
          result = mcp_call("new_page", { url: url })
          pages  = extract_pages(result)
          page   = pages.last || {}
          { action: "open", success: true, profile: "user",
            targetId: page[:id]&.to_s, url: url, output: "Opened: #{url}" }
        when "navigate"
          url       = require_url(opts)
          return url if url.is_a?(Hash)
          target_id = resolve_target_id(opts)
          return target_id if target_id.is_a?(Hash)
          mcp_call("navigate_page", { pageId: target_id.to_i, type: "url", url: url })
          { action: "navigate", success: true, profile: "user",
            targetId: target_id.to_s, url: url, output: "Navigated to: #{url}" }
        when "focus"
          target_id = resolve_target_id(opts)
          return target_id if target_id.is_a?(Hash)
          mcp_call("select_page", { pageId: target_id.to_i, bringToFront: true })
          { action: "focus", success: true, profile: "user", output: "Focused tab #{target_id}" }
        when "close"
          target_id = resolve_target_id(opts)
          return target_id if target_id.is_a?(Hash)
          mcp_call("close_page", { pageId: target_id.to_i })
          { action: "close", success: true, profile: "user", output: "Closed tab #{target_id}" }
        when "act"
          do_user_act(opts)
        when "screenshot"
          do_user_screenshot(opts)
        when "status"
          result = mcp_call("list_pages")
          pages  = extract_pages(result)
          { action: "status", success: true, profile: "user",
            output: "Browser running. #{pages.size} tab(s) open.", tabs: pages }
        else
          { error: "Action '#{action}' is not supported for profile=user." }
        end
      end

      private def do_user_snapshot(opts)
        target_id = resolve_target_id(opts)
        return target_id if target_id.is_a?(Hash)

        raw = mcp_call("take_snapshot", { pageId: target_id.to_i })
        snapshot_node = extract_snapshot(raw)

        interactive = opts[:interactive] || opts["interactive"]
        compact_opt = opts[:compact]     || opts["compact"]
        max_depth   = opts[:depth]       || opts["depth"]

        text = build_ai_snapshot(snapshot_node,
                                 interactive: interactive,
                                 compact: compact_opt,
                                 max_depth: max_depth)

        { action: "snapshot", success: true, profile: "user",
          targetId: target_id.to_s, output: text }
      end

      private def do_user_act(opts)
        kind      = (opts[:kind] || opts["kind"] || "click").to_s
        target_id = resolve_target_id(opts)
        return target_id if target_id.is_a?(Hash)

        page_id = target_id.to_i
        ref     = opts[:ref] || opts["ref"]

        case kind
        when "click", "dblclick"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          args = { pageId: page_id, uid: uid }
          args[:dblClick] = true if kind == "dblclick" || opts[:double_click] || opts["double_click"]
          mcp_call("click", args)
        when "fill"
          uid   = require_ref(ref)
          return uid if uid.is_a?(Hash)
          value = opts[:text] || opts["text"] || ""
          mcp_call("fill", { pageId: page_id, uid: uid, value: value })
        when "type"
          uid   = require_ref(ref)
          return uid if uid.is_a?(Hash)
          value = opts[:text] || opts["text"] || ""
          mcp_call("fill", { pageId: page_id, uid: uid, value: value })
        when "press"
          key = opts[:key] || opts["key"] || "Enter"
          mcp_call("press_key", { pageId: page_id, key: key })
        when "hover"
          uid = require_ref(ref)
          return uid if uid.is_a?(Hash)
          mcp_call("hover", { pageId: page_id, uid: uid })
        when "drag"
          uid        = require_ref(ref)
          return uid if uid.is_a?(Hash)
          target_uid = opts[:target_ref] || opts["target_ref"] || ""
          mcp_call("drag", { pageId: page_id, from_uid: uid, to_uid: target_uid })
        when "select"
          uid    = require_ref(ref)
          return uid if uid.is_a?(Hash)
          values = Array(opts[:values] || opts["values"] || [])
          mcp_call("fill", { pageId: page_id, uid: uid, value: values.first.to_s })
        when "scroll"
          direction = opts[:direction] || opts["direction"] || "down"
          amount    = opts[:amount]    || opts["amount"]    || 300
          js = "window.scrollBy(#{direction == 'right' || direction == 'left' ?
                                   (direction == 'left' ? -amount.to_i : amount.to_i) : 0
                                 }, #{direction == 'up' ? -amount.to_i :
                                      direction == 'down' ? amount.to_i : 0})"
          mcp_call("evaluate_script", { pageId: page_id, function: "() => { #{js} }" })
        when "wait"
          ms         = opts[:ms]         || opts["ms"]
          load_state = opts[:load_state] || opts["load_state"]
          sel        = opts[:selector]   || opts["selector"]
          if ms
            sleep(ms.to_i / 1000.0)
            { action: "act", success: true, profile: "user", output: "Waited #{ms}ms" }
            return { action: "act", success: true, profile: "user", output: "Waited #{ms}ms" }
          elsif sel
            mcp_call("wait_for", { pageId: page_id, text: [sel] })
          else
            sleep(1)
          end
        when "evaluate"
          js     = opts[:js] || opts["js"] || ""
          result = mcp_call("evaluate_script", {
            pageId: page_id,
            function: "() => { return (#{js}) }"
          })
          value = extract_message(result)
          return { action: "act", success: true, profile: "user",
                   output: value.to_s }
        else
          return { error: "Unknown act kind: #{kind}" }
        end

        { action: "act", success: true, profile: "user", output: "#{kind} completed." }
      end

      private def do_user_screenshot(opts)
        target_id = resolve_target_id(opts)
        return target_id if target_id.is_a?(Hash)

        format    = opts[:format]    || opts["format"]    || "jpeg"
        full_page = opts[:full_page] || opts["full_page"] || false

        tmp_file = File.join(Dir.tmpdir, "clacky_screenshot_#{Time.now.to_i}.#{format}")
        mcp_call("take_screenshot", {
          pageId:   target_id.to_i,
          filePath: tmp_file,
          format:   format,
          fullPage: full_page
        })

        { action: "screenshot", success: true, profile: "user",
          path: tmp_file, output: "Screenshot saved: #{tmp_file}" }
      end

      # -----------------------------------------------------------------------
      # Sandbox browser (agent-browser fallback — not Chrome MCP)
      # -----------------------------------------------------------------------

      private def execute_sandbox(action, opts)
        {
          error: "Sandbox profile is not yet supported in this version. " \
                 "Use profile=\"user\" with Chrome 146+."
        }
      end

      # -----------------------------------------------------------------------
      # Chrome MCP — process management & JSON-RPC over stdio
      # -----------------------------------------------------------------------

      # Returns true if npx is available on PATH
      private def chrome_mcp_available?
        result = system("which npx > /dev/null 2>&1")
        result
      end

      # Calls a Chrome MCP tool and returns the parsed response.
      # Spawns a short-lived npx process each time (stateless mode).
      private def mcp_call(tool_name, arguments = {})
        cmd_args = CHROME_MCP_ARGS.dup

        # Build MCP JSON-RPC messages
        init_msg  = mcp_json_rpc("initialize", {
          protocolVersion: "2024-11-05",
          capabilities:    {},
          clientInfo:      { name: "clacky", version: "1.0" }
        }, id: 1)

        call_msg = mcp_json_rpc("tools/call", {
          name:      tool_name,
          arguments: arguments
        }, id: 2)

        # Combine as newline-delimited JSON (MCP stdio framing)
        input = [init_msg, call_msg].join("\n") + "\n"

        stdout_str, stderr_str, status = Open3.capture3(
          CHROME_MCP_COMMAND, *cmd_args,
          stdin_data: input,
          timeout:    MCP_TIMEOUT
        )

        unless status.success? || !stdout_str.empty?
          raise "Chrome MCP process failed (exit #{status.exitstatus}): #{stderr_str.to_s[0..200]}"
        end

        parse_mcp_response(stdout_str, request_id: 2)
      end

      # Build a JSON-RPC 2.0 message string
      private def mcp_json_rpc(method, params, id:)
        JSON.generate({ jsonrpc: "2.0", id: id, method: method, params: params })
      end

      # Parse MCP stdio output — find the response for our call (id=2)
      private def parse_mcp_response(raw_output, request_id:)
        # MCP sends newline-delimited JSON frames
        raw_output.each_line do |line|
          line = line.strip
          next if line.empty?
          begin
            msg = JSON.parse(line)
            next unless msg.is_a?(Hash)
            next unless msg["id"] == request_id
            if msg["error"]
              raise "Chrome MCP error: #{msg['error']['message'] || msg['error']}"
            end
            return msg["result"] || {}
          rescue JSON::ParserError
            next
          end
        end
        # Return empty result if no matching response found
        {}
      end

      # -----------------------------------------------------------------------
      # MCP response extractors
      # -----------------------------------------------------------------------

      private def extract_pages(result)
        return [] unless result.is_a?(Hash)

        # Try structuredContent.pages first
        structured = result["structuredContent"]
        if structured.is_a?(Hash) && structured["pages"].is_a?(Array)
          return structured["pages"].map do |p|
            { id: p["id"], url: p["url"], selected: p["selected"] == true }
          end
        end

        # Fall back to text content parsing
        text = extract_text_content(result)
        parse_pages_from_text(text)
      end

      private def extract_snapshot(result)
        return {} unless result.is_a?(Hash)

        structured = result["structuredContent"]
        if structured.is_a?(Hash) && structured["snapshot"].is_a?(Hash)
          return structured["snapshot"]
        end

        # Try content array
        text = extract_text_content(result)
        begin
          JSON.parse(text)
        rescue StandardError
          {}
        end
      end

      private def extract_message(result)
        return "" unless result.is_a?(Hash)

        structured = result["structuredContent"]
        if structured.is_a?(Hash)
          return structured["message"].to_s if structured["message"]
        end

        extract_text_content(result)
      end

      private def extract_text_content(result)
        return "" unless result.is_a?(Hash)

        content = result["content"]
        return "" unless content.is_a?(Array)

        content.filter_map do |entry|
          entry["text"] if entry.is_a?(Hash) && entry["text"].is_a?(String)
        end.join("\n")
      end

      private def parse_pages_from_text(text)
        text.each_line.filter_map do |line|
          m = line.match(/^\s*(\d+):\s+(.+?)(?:\s+\[(selected)\])?\s*$/i)
          next unless m
          { id: m[1].to_i, url: m[2].strip, selected: !m[3].nil? }
        end
      end

      private def format_tabs(pages)
        return "No open tabs." if pages.empty?
        pages.map { |p| "#{p[:id]}: #{p[:url]}#{p[:selected] ? ' [selected]' : ''}" }.join("\n")
      end

      # -----------------------------------------------------------------------
      # Snapshot rendering (ChromeMcpSnapshotNode → AI text format)
      # -----------------------------------------------------------------------

      INTERACTIVE_ROLES = %w[
        button link textbox checkbox radio select combobox
        menuitem option tab switch searchbox spinbutton
        slider menuitemcheckbox menuitemradio
      ].freeze

      STRUCTURAL_ROLES = %w[
        generic none presentation group region section
      ].freeze

      CONTENT_ROLES = %w[
        heading paragraph text statictext image img
        listitem term definition
      ].freeze

      private def build_ai_snapshot(node, interactive: false, compact: false, max_depth: nil)
        return "" unless node.is_a?(Hash) && !node.empty?

        lines = []
        refs  = {}
        visit_node(node, 0, lines, refs,
                   interactive: interactive,
                   compact: compact,
                   max_depth: max_depth)
        lines.join("\n")
      end

      private def visit_node(node, depth, lines, refs, interactive:, compact:, max_depth:)
        return if max_depth && depth > max_depth

        role = node["role"].to_s.downcase.strip
        role = "generic" if role.empty?
        name = node["name"].to_s.strip
        uid  = node["id"].to_s.strip
        val  = node["value"]
        desc = node["description"].to_s.strip

        # Decide whether to render this node (but always recurse into children)
        render = true
        render = false if interactive && !INTERACTIVE_ROLES.include?(role)
        render = false if compact && STRUCTURAL_ROLES.include?(role) && name.empty?

        if render
          line = "#{" " * (depth * 2)}- #{role}"
          line += " \"#{escape_quoted(name)}\"" unless name.empty?

          # Assign ref if interactive or named content role
          if uid && !uid.empty? && (INTERACTIVE_ROLES.include?(role) ||
                                     (CONTENT_ROLES.include?(role) && !name.empty?))
            refs[uid] = { role: role, name: name }
            line += " [ref=#{uid}]"
          end

          line += " value=\"#{escape_quoted(val.to_s)}\"" unless val.nil? || val.to_s.empty?
          line += " description=\"#{escape_quoted(desc)}\"" unless desc.empty?

          lines << line
        end

        # Always recurse into children regardless of whether this node was rendered
        child_depth = render ? depth + 1 : depth
        Array(node["children"]).each do |child|
          visit_node(child, child_depth, lines, refs,
                     interactive: interactive,
                     compact: compact,
                     max_depth: max_depth)
        end
      end

      private def escape_quoted(str)
        str.to_s.gsub("\\", "\\\\").gsub('"', '\\"')
      end

      # -----------------------------------------------------------------------
      # Parameter helpers
      # -----------------------------------------------------------------------

      private def require_url(opts)
        url = opts[:url] || opts["url"] || ""
        return { error: "url is required for this action" } if url.empty?
        url
      end

      private def require_ref(ref)
        return { error: "ref is required for this act kind (snapshot first to get refs)" } if ref.nil? || ref.to_s.empty?
        ref.to_s
      end

      private def resolve_target_id(opts)
        tid = opts[:target_id] || opts["target_id"]
        if tid && !tid.to_s.empty?
          return tid.to_s
        end
        # Auto-select the first available page
        result = mcp_call("list_pages")
        pages  = extract_pages(result)
        page   = pages.find { |p| p[:selected] } || pages.first
        return { error: "No open tabs found. Use action=open first." } unless page
        page[:id].to_s
      end

      # -----------------------------------------------------------------------
      # Output helpers
      # -----------------------------------------------------------------------

      private def compress_snapshot(output)
        return output if output.empty?

        lines    = output.lines
        orig     = lines.size
        filtered = lines.reject do |line|
          s = line.strip
          s.start_with?("- /url:", "/url:", "- /placeholder:", "/placeholder:") ||
            s == "- img" || s.match?(/\A-\s+img\s*\z/)
        end

        removed = orig - filtered.size
        if removed > 0
          filtered << "\n[snapshot compressed: #{removed} lines removed]\n"
        end
        filtered.join
      end

      private def truncate_output(output, max_chars)
        return output if output.length <= max_chars

        lines     = output.lines
        available = max_chars - 150
        first_part = []
        acc = 0
        lines.each do |line|
          break if acc + line.length > available
          first_part << line
          acc += line.length
        end
        notice = "\n... [truncated: #{first_part.size}/#{lines.size} lines shown] ..."
        first_part.join + notice
      end
    end
  end
end
