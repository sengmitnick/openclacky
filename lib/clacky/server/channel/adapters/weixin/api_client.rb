# frozen_string_literal: true

require "net/http"
require "json"
require "openssl"
require "securerandom"
require "base64"

module Clacky
  module Channel
    module Adapters
      module Weixin
        # HTTP API client for Weixin iLink bot protocol.
        #
        # All requests POST JSON to <base_url>/<endpoint>.
        # Required headers per request:
        #   Content-Type:      application/json
        #   AuthorizationType: ilink_bot_token
        #   Authorization:     Bearer <token>
        #   X-WECHAT-UIN:      base64(random uint32 as decimal string)
        class ApiClient
          DEFAULT_BASE_URL     = "https://ilinkai.weixin.qq.com"
          API_PATH_PREFIX      = "ilink/bot"
          CHANNEL_VERSION      = "1.0.2"
          LONG_POLL_TIMEOUT_S  = 40   # slightly above the server's 35s
          API_TIMEOUT_S        = 15

          # Raised for non-zero API return codes or HTTP errors.
          class ApiError < StandardError
            attr_reader :code
            def initialize(code, msg) = (@code = code; super("WeixinApiError(#{code}): #{msg.to_s.slice(0, 200)}"))
          end

          # Raised on network/read timeouts.
          class TimeoutError < StandardError; end

          # Server errcode for expired sessions.
          SESSION_EXPIRED_ERRCODE = -14

          def initialize(base_url:, token:)
            @base_url = base_url.to_s.chomp("/")
            @token    = token.to_s
          end

          # Long-poll for new messages.
          # @param get_updates_buf [String] cursor from last response ("" for first call)
          # @return [Hash] { ret:, msgs: [], get_updates_buf:, longpolling_timeout_ms: }
          def get_updates(get_updates_buf:)
            post("getupdates", { get_updates_buf: get_updates_buf }, timeout: LONG_POLL_TIMEOUT_S)
          end

          # Send a plain text message.
          # context_token is required by the Weixin protocol for conversation association.
          def send_text(to_user_id:, text:, context_token:)
            body = {
              msg: {
                from_user_id: "",
                to_user_id:   to_user_id,
                client_id:    "clacky-#{SecureRandom.hex(8)}",
                message_type: 2,   # BOT
                message_state: 2,  # FINISH
                item_list:     [{ type: 1, text_item: { text: text } }],
                context_token: context_token
              }
            }
            post("sendmessage", body)
          end

          private

          def post(endpoint, body_hash, timeout: API_TIMEOUT_S)
            uri  = URI("#{@base_url}/#{API_PATH_PREFIX}/#{endpoint}")
            # All POST bodies must include base_info per iLink protocol spec.
            body = JSON.generate(body_hash.merge(base_info: { channel_version: CHANNEL_VERSION }))

            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl      = uri.scheme == "https"
            http.verify_mode  = OpenSSL::SSL::VERIFY_PEER
            http.read_timeout = timeout
            http.open_timeout = 10

            req = Net::HTTP::Post.new(uri.path)
            req["Content-Type"]      = "application/json"
            req["AuthorizationType"] = "ilink_bot_token"
            req["Content-Length"]    = body.bytesize.to_s
            req["X-WECHAT-UIN"]      = random_wechat_uin
            req["Authorization"]     = "Bearer #{@token}" unless @token.empty?
            req.body = body

            Clacky::Logger.debug("[WeixinApiClient] POST #{endpoint}")

            res = http.request(req)
            raise ApiError.new(res.code.to_i, res.body), "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

            data = JSON.parse(res.body)
            ret  = data["ret"] || data["errcode"]
            raise ApiError.new(ret, data["errmsg"]) if ret && ret != 0

            data
          rescue Net::ReadTimeout, Net::OpenTimeout
            raise TimeoutError, "#{endpoint} timed out"
          rescue JSON::ParserError => e
            raise ApiError.new(0, "Invalid JSON: #{e.message}")
          end

          # X-WECHAT-UIN: random uint32 → decimal string → base64
          def random_wechat_uin
            uint32 = SecureRandom.random_bytes(4).unpack1("N")
            Base64.strict_encode64(uint32.to_s)
          end
        end
      end
    end
  end
end
