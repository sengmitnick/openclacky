# frozen_string_literal: true

require_relative "base_component"

module Clacky
  module UI2
    module Components
      # CommonComponent renders common UI elements (progress, success, error, warning)
      class CommonComponent < BaseComponent
        # Render thinking indicator
        # @return [String] Thinking indicator
        def render_thinking
          symbol = format_symbol(:thinking)
          text = format_text("Thinking...", :thinking)
          "#{symbol} #{text}"
        end

        # Render progress indicator
        # @param message [String] Progress message
        # @return [String] Progress indicator
        def render_progress(message)
          symbol = format_symbol(:thinking)
          text = format_text(message, :thinking)
          "#{symbol} #{text}"
        end

        # Render success message
        # @param message [String] Success message
        # @return [String] Success message
        def render_success(message)
          symbol = format_symbol(:success)
          text = format_text(message, :success)
          "#{symbol} #{text}"
        end

        # Render error message
        # @param message [String] Error message
        # @return [String] Error message
        def render_error(message)
          symbol = format_symbol(:error)
          text = format_text(message, :error)
          "#{symbol} #{text}"
        end

        # Render warning message
        # @param message [String] Warning message
        # @return [String] Warning message
        def render_warning(message)
          symbol = format_symbol(:warning)
          text = format_text(message, :warning)
          "#{symbol} #{text}"
        end

        # Render task completion summary
        # @param iterations [Integer] Number of iterations
        # @param cost [Float] Cost in USD
        # @param duration [Float] Duration in seconds
        # @param cache_tokens [Integer] Cache read tokens
        # @return [String] Formatted completion summary
        def render_task_complete(iterations:, cost:, duration: nil, cache_tokens: nil)
          parts = []
          parts << "Iterations: #{iterations}"
          parts << "Cost: $#{cost.round(4)}"
          parts << "Duration: #{duration.round(1)}s" if duration
          parts << "Cache: #{cache_tokens} tokens" if cache_tokens && cache_tokens > 0

          lines = []
          lines << ""
          lines << @pastel.dim("─" * 60)
          lines << render_success(parts.join(" │ "))
          lines.join("\n")
        end
      end
    end
  end
end
