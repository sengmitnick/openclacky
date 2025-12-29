# frozen_string_literal: true

module Clacky
  class Conversation
    attr_reader :messages

    def initialize(api_key, model: "claude-3-5-sonnet-20241022")
      @client = Client.new(api_key)
      @model = model
      @messages = []
    end

    def send_message(content)
      # Add user message to history
      @messages << {
        role: "user",
        content: content
      }

      # Get response from Claude
      response_text = @client.send_messages(@messages, model: @model)

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
