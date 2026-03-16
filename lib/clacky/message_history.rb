# frozen_string_literal: true

module Clacky
  # MessageHistory wraps the conversation message list and exposes
  # business-meaningful operations instead of raw array manipulation.
  #
  # Internal fields (task_id, created_at, system_injected, etc.) are kept
  # in the internal store but stripped when calling #to_api.
  class MessageHistory
    # Fields that are internal to the agent and must not be sent to the API.
    INTERNAL_FIELDS = %i[
      task_id created_at system_injected session_context memory_update
      subagent_instructions subagent_result token_usage reasoning_content
      compressed_summary chunk_path truncated
    ].freeze

    def initialize(messages = [])
      @messages = messages.dup
    end

    # ─────────────────────────────────────────────
    # Write operations
    # ─────────────────────────────────────────────

    # Append a single message hash to the history.
    def append(message)
      @messages << message
      self
    end

    # Replace (or insert at head) the system prompt message.
    # Used by session_serializer#refresh_system_prompt.
    def replace_system_prompt(content, **extra)
      msg = { role: "system", content: content }.merge(extra)
      idx = @messages.index { |m| m[:role] == "system" }
      if idx
        @messages[idx] = msg
      else
        @messages.unshift(msg)
      end
      self
    end

    # Replace the entire message list (used by compression rebuild).
    def replace_all(new_messages)
      @messages = new_messages.dup
      self
    end

    # Remove and return the last message.
    def pop_last
      @messages.pop
    end

    # Remove messages from the end while the block is truthy.
    def pop_while(&block)
      @messages.pop while !@messages.empty? && block.call(@messages.last)
      self
    end

    # Remove all messages matching the block in-place
    # (e.g. cleanup_memory_messages uses reject! { m[:memory_update] }).
    def delete_where(&block)
      @messages.reject!(&block)
      self
    end

    # Mutate the last message matching the predicate lambda in-place.
    # Used by execute_skill_with_subagent to update instruction messages.
    def mutate_last_matching(predicate, &block)
      msg = @messages.reverse.find { |m| predicate.call(m) }
      block.call(msg) if msg
      self
    end

    # Remove all messages from index onward (used by restore_session on error).
    def truncate_from(index)
      @messages = @messages[0...index]
      self
    end

    # ─────────────────────────────────────────────
    # Business queries
    # ─────────────────────────────────────────────

    # True when the last assistant message has tool_calls but no
    # tool_result has been appended yet (would cause a 400 from the API).
    def pending_tool_calls?
      return false if @messages.empty?

      last = @messages.last
      return false unless last[:role] == "assistant" && last[:tool_calls]&.any?

      # Check that there is no tool result message after this assistant message
      last_assistant_idx = @messages.rindex { |m| m == last }
      @messages[(last_assistant_idx + 1)..].none? { |m| m[:role] == "tool" || m[:tool_results] }
    end

    # Return the session_date value from the most recent session_context message.
    # Used by inject_session_context_if_needed to avoid re-injecting on the same date.
    def last_session_context_date
      msg = @messages.reverse.find { |m| m[:session_context] }
      msg&.dig(:session_date)
    end

    # Return only real (non-system-injected) user messages.
    def real_user_messages
      @messages.select { |m| m[:role] == "user" && !m[:system_injected] }
    end

    # Return the index of the last real (non-system-injected) user message.
    # Used by restore_session to trim back to a clean state on error.
    def last_real_user_index
      @messages.rindex { |m| m[:role] == "user" && !m[:system_injected] }
    end

    # Return the message with :subagent_instructions set.
    def subagent_instruction_message
      @messages.find { |m| m[:subagent_instructions] }
    end

    # Return all messages where task_id <= given id (Time Machine support).
    def for_task(task_id)
      @messages.select { |m| !m[:task_id] || m[:task_id] <= task_id }
    end

    # Count how many of the last N messages have :truncated set.
    # Used by think() to guard against infinite truncation retry loops.
    def recent_truncation_count(n)
      @messages.last(n).count { |m| m[:truncated] }
    end

    # ─────────────────────────────────────────────
    # Size helpers
    # ─────────────────────────────────────────────

    def size
      @messages.size
    end

    def empty?
      @messages.empty?
    end

    # ─────────────────────────────────────────────
    # Output
    # ─────────────────────────────────────────────

    # Return a clean copy of messages suitable for sending to the LLM API:
    # - strips internal-only fields
    # - removes trailing assistant+tool_calls with no subsequent tool_result
    def to_api
      result = @messages.dup

      # Strip trailing orphaned assistant+tool_calls (no tool_result follows)
      while (last = result.last) &&
            last[:role] == "assistant" &&
            last[:tool_calls]&.any?
        last_idx = result.rindex { |m| m == last }
        has_tool_result = result[(last_idx + 1)..].any? { |m| m[:role] == "tool" || m[:tool_results] }
        break if has_tool_result

        result.pop
      end

      result.map { |m| strip_internal_fields(m) }
    end

    # Return a shallow copy of the full internal message list.
    # For serialization, compression, and cloning.
    def to_a
      @messages.dup
    end

    private def strip_internal_fields(message)
      message.reject { |k, _| INTERNAL_FIELDS.include?(k) }
    end
  end
end
