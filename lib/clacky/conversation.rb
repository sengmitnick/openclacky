# frozen_string_literal: true

module Clacky
  class Conversation
    attr_reader :messages

    def initialize(api_key, model:, base_url:, max_tokens:)
      @client = Client.new(api_key, base_url: base_url)
      @model = model
      @max_tokens = max_tokens
      @messages = []
    end

    def send_message(content)
      # Add user message to history
      @messages << {
        role: "user",
        content: content
      }

      # Get response from Claude
      response_text = @client.send_messages(@messages, model: @model, max_tokens: @max_tokens)

      # Add assistant response to history
      @messages << {
        role: "assistant",
        content: response_text
      }

      response_text
    end

    def clear
      @messages = []
    end

    def history
      @messages.dup
    end
  end
end
