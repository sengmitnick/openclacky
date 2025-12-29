# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  class Client
    API_URL = "https://api.anthropic.com/v1/messages"
    API_VERSION = "2023-06-01"

    def initialize(api_key)
      @api_key = api_key
    end

    def send_message(content, model: "claude-3-5-sonnet-20241022", max_tokens: 4096)
      response = connection.post(API_URL) do |req|
        req.body = {
          model: model,
          max_tokens: max_tokens,
          messages: [
            {
              role: "user",
              content: content
            }
          ]
        }.to_json
      end

      handle_response(response)
    end

    def send_messages(messages, model: "claude-3-5-sonnet-20241022", max_tokens: 4096)
      response = connection.post(API_URL) do |req|
        req.body = {
          model: model,
          max_tokens: max_tokens,
          messages: messages
        }.to_json
      end

      handle_response(response)
    end

    private

    def connection
      @connection ||= Faraday.new do |conn|
        conn.headers["Content-Type"] = "application/json"
        conn.headers["x-api-key"] = @api_key
        conn.headers["anthropic-version"] = API_VERSION
        conn.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      case response.status
      when 200
        data = JSON.parse(response.body)
        data["content"].first["text"]
      when 401
        raise Error, "Invalid API key"
      when 429
        raise Error, "Rate limit exceeded"
      when 500..599
        raise Error, "Server error: #{response.status}"
      else
        raise Error, "Unexpected error: #{response.status} - #{response.body}"
      end
    end
  end
end
