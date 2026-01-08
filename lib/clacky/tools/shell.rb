# frozen_string_literal: true

require_relative "base"

module Clacky
  module Tools
    class Shell < Base
      self.tool_name = "shell"
      self.tool_description = "Execute shell commands in the terminal"
      self.tool_category = "system"
      self.tool_parameters = {
        type: "object",
        properties: {
          command: {
            type: "string",
            description: "Shell command to execute"
          }
        },
        required: ["command"]
      }

      TIMEOUT = 30 # seconds

      def execute(command:)
        require "open3"
        require "timeout"

        begin
          stdout, stderr, status = Timeout.timeout(TIMEOUT) do
            Open3.capture3(command)
          end

          {
            command: command,
            stdout: stdout,
            stderr: stderr,
            exit_code: status.exitstatus,
            success: status.success?
          }
        rescue Timeout::Error
          {
            command: command,
            stdout: "",
            stderr: "Command timed out after #{TIMEOUT} seconds",
            exit_code: -1,
            success: false
          }
        rescue StandardError => e
          {
            command: command,
            stdout: "",
            stderr: "Error executing command: #{e.message}",
            exit_code: -1,
            success: false
          }
        end
      end

      def format_call(args)
        cmd = args[:command] || args['command'] || ''
        cmd_parts = cmd.split
        cmd_short = cmd_parts.first(3).join(' ')
        cmd_short += '...' if cmd_parts.size > 3
        "Shell(#{cmd_short})"
      end

      def format_result(result)
        exit_code = result[:exit_code] || result['exit_code'] || 0
        stdout = result[:stdout] || result['stdout'] || ""
        stderr = result[:stderr] || result['stderr'] || ""

        if exit_code == 0
          lines = stdout.lines.size
          "✓ Completed#{lines > 0 ? " (#{lines} lines)" : ''}"
        else
          error_msg = stderr.lines.first&.strip || "Failed"
          "✗ Exit #{exit_code}: #{error_msg[0..50]}"
        end
      end
    end
  end
end
