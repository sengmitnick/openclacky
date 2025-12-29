# frozen_string_literal: true

require "faraday"
require "json"

module Clacky
  class Client
    def initialize(api_key, base_url: "https://api.openai.com")
      @api_key = api_key
      @base_url = base_url
    end

    def send_message(content, model: "gpt-3.5-turbo", max_tokens: 4096)
      response = connection.post("/v1/chat/completions") do |req|
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

    def send_messages(messages, model: "gpt-3.5-turbo", max_tokens: 4096)
      response = connection.post("/v1/chat/completions") do |req|
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
      @connection ||= Faraday.new(url: @base_url) do |conn|
        conn.headers["Content-Type"] = "application/json"
        conn.headers["Authorization"] = "Bearer #{@api_key}"
        conn.adapter Faraday.default_adapter
      end
    end

    def handle_response(response)
      case response.status
      when 200
        data = JSON.parse(response.body)
        data["choices"].first["message"]["content"]
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
