# frozen_string_literal: true

require "pastel"

module Clacky
  module UI2
    module Components
      # TodoArea displays active todos above the input area
      class TodoArea
        attr_accessor :height
        attr_reader :todos

        def initialize
          @todos = []
          @pastel = Pastel.new
          @width = TTY::Screen.width
          @height = 0  # Dynamic height based on todos
        end

        # Update todos list
        # @param todos [Array<Hash>] Array of todo items
        def update(todos)
          @todos = todos || []
          # Filter to only show pending todos
          @pending_todos = @todos.select { |t| t[:status] == "pending" }
          # Calculate height: 1 line for header + 1 line per pending todo
          @height = @pending_todos.empty? ? 0 : @pending_todos.size + 1
        end

        # Check if there are todos to display
        def visible?
          @height > 0
        end

        # Render todos area
        # @param start_row [Integer] Screen row to start rendering
        def render(start_row:)
          return unless visible?

          update_width

          # Render header
          move_cursor(start_row, 0)
          clear_line
          header = @pastel.cyan("Tasks:")
          print header

          # Render each pending todo
          @pending_todos.each_with_index do |todo, i|
            move_cursor(start_row + i + 1, 0)
            clear_line

            status_icon = @pastel.yellow("[ ]")
            task_text = truncate_text(todo[:task], @width - 6)
            print "  #{status_icon} #{task_text}"
          end

          flush
        end

        # Clear the area
        def clear
          @todos = []
          @pending_todos = []
          @height = 0
        end

        private

        # Truncate text to fit width
        def truncate_text(text, max_width)
          return "" if text.nil?

          if text.length > max_width
            text[0...(max_width - 3)] + "..."
          else
            text
          end
        end

        # Update width on resize
        def update_width
          @width = TTY::Screen.width
        end

        # Move cursor to position
        def move_cursor(row, col)
          print "\e[#{row + 1};#{col + 1}H"
        end

        # Clear current line
        def clear_line
          print "\e[2K"
        end

        # Flush output
        def flush
          $stdout.flush
        end
      end
    end
  end
end
