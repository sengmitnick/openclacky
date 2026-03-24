# frozen_string_literal: true

require "yaml"
require "fileutils"

module Clacky
  # ClaudeCode environment variable compatibility layer
  # Provides configuration detection from ClaudeCode's environment variables
  module ClaudeCodeEnv
    # Environment variable names used by ClaudeCode
    ENV_API_KEY = "ANTHROPIC_API_KEY"
    ENV_AUTH_TOKEN = "ANTHROPIC_AUTH_TOKEN"
    ENV_BASE_URL = "ANTHROPIC_BASE_URL"

    # Default Anthropic API endpoint
    DEFAULT_BASE_URL = "https://api.anthropic.com"

    class << self
      # Check if any ClaudeCode authentication is configured
      def configured?
        !api_key.nil? && !api_key.empty?
      end

      # Get API key - prefer ANTHROPIC_API_KEY, fallback to ANTHROPIC_AUTH_TOKEN
      def api_key
        if ENV[ENV_API_KEY] && !ENV[ENV_API_KEY].empty?
          ENV[ENV_API_KEY]
        elsif ENV[ENV_AUTH_TOKEN] && !ENV[ENV_AUTH_TOKEN].empty?
          ENV[ENV_AUTH_TOKEN]
        end
      end

      # Get base URL from environment, or return default Anthropic API URL
      def base_url
        ENV[ENV_BASE_URL] && !ENV[ENV_BASE_URL].empty? ? ENV[ENV_BASE_URL] : DEFAULT_BASE_URL
      end

      # Get configuration as a hash (includes configured values)
      # Returns api_key and base_url (always available as there's a default)
      def to_h
        {
          "api_key" => api_key,
          "base_url" => base_url
        }.compact
      end
    end
  end

  # Clacky environment variable layer
  # Provides configuration from CLACKY_XXX environment variables
  module ClackyEnv
    # Environment variable names for default model
    ENV_API_KEY = "CLACKY_API_KEY"
    ENV_BASE_URL = "CLACKY_BASE_URL"
    ENV_MODEL = "CLACKY_MODEL"
    ENV_ANTHROPIC_FORMAT = "CLACKY_ANTHROPIC_FORMAT"

    # Environment variable names for lite model
    ENV_LITE_API_KEY = "CLACKY_LITE_API_KEY"
    ENV_LITE_BASE_URL = "CLACKY_LITE_BASE_URL"
    ENV_LITE_MODEL = "CLACKY_LITE_MODEL"
    ENV_LITE_ANTHROPIC_FORMAT = "CLACKY_LITE_ANTHROPIC_FORMAT"

    # Default model name (only for model, not base_url)
    DEFAULT_MODEL = "claude-sonnet-4-5"

    class << self
      # Check if default model is configured via environment variables
      def default_configured?
        !default_api_key.nil? && !default_api_key.empty?
      end

      # Check if lite model is configured via environment variables
      def lite_configured?
        !lite_api_key.nil? && !lite_api_key.empty?
      end

      # Get default model API key
      def default_api_key
        ENV[ENV_API_KEY] if ENV[ENV_API_KEY] && !ENV[ENV_API_KEY].empty?
      end

      # Get default model base URL (no default, must be explicitly set)
      def default_base_url
        ENV[ENV_BASE_URL] if ENV[ENV_BASE_URL] && !ENV[ENV_BASE_URL].empty?
      end

      # Get default model name
      def default_model
        ENV[ENV_MODEL] && !ENV[ENV_MODEL].empty? ? ENV[ENV_MODEL] : DEFAULT_MODEL
      end

      # Get default model anthropic_format flag
      def default_anthropic_format
        return true if ENV[ENV_ANTHROPIC_FORMAT].nil? || ENV[ENV_ANTHROPIC_FORMAT].empty?
        ENV[ENV_ANTHROPIC_FORMAT].downcase == "true"
      end

      # Get default model configuration as a hash
      def default_model_config
        {
          "type" => "default",
          "api_key" => default_api_key,
          "base_url" => default_base_url,
          "model" => default_model,
          "anthropic_format" => default_anthropic_format
        }.compact
      end

      # Get lite model API key
      def lite_api_key
        ENV[ENV_LITE_API_KEY] if ENV[ENV_LITE_API_KEY] && !ENV[ENV_LITE_API_KEY].empty?
      end

      # Get lite model base URL (no default, must be explicitly set)
      def lite_base_url
        ENV[ENV_LITE_BASE_URL] if ENV[ENV_LITE_BASE_URL] && !ENV[ENV_LITE_BASE_URL].empty?
      end

      # Get lite model name
      def lite_model
        ENV[ENV_LITE_MODEL] && !ENV[ENV_LITE_MODEL].empty? ? ENV[ENV_LITE_MODEL] : "claude-haiku-4"
      end

      # Get lite model anthropic_format flag
      def lite_anthropic_format
        return true if ENV[ENV_LITE_ANTHROPIC_FORMAT].nil? || ENV[ENV_LITE_ANTHROPIC_FORMAT].empty?
        ENV[ENV_LITE_ANTHROPIC_FORMAT].downcase == "true"
      end

      # Get lite model configuration as a hash
      def lite_model_config
        {
          "type" => "lite",
          "api_key" => lite_api_key,
          "base_url" => lite_base_url,
          "model" => lite_model,
          "anthropic_format" => lite_anthropic_format
        }.compact
      end
    end
  end

  class AgentConfig
    CONFIG_DIR = File.join(Dir.home, ".clacky")
    CONFIG_FILE = File.join(CONFIG_DIR, "config.yml")

    # Default model for ClaudeCode environment
    CLAUDE_DEFAULT_MODEL = "claude-sonnet-4-5"

    PERMISSION_MODES = [:auto_approve, :confirm_safes, :confirm_all].freeze

    attr_accessor :permission_mode, :max_tokens, :verbose,
                  :enable_compression, :enable_prompt_caching,
                  :models, :current_model_index

    def initialize(options = {})
      @permission_mode = validate_permission_mode(options[:permission_mode])
      @max_tokens = options[:max_tokens] || 8192
      @verbose = options[:verbose] || false
      @enable_compression = options[:enable_compression].nil? ? true : options[:enable_compression]
      # Enable prompt caching by default for cost savings
      @enable_prompt_caching = options[:enable_prompt_caching].nil? ? true : options[:enable_prompt_caching]

      # Models configuration
      @models = options[:models] || []
      @current_model_index = options[:current_model_index] || 0
    end

    # Load configuration from file
    def self.load(config_file = CONFIG_FILE)
      # Load from config file first
      if File.exist?(config_file)
        data = YAML.load_file(config_file)
      else
        data = nil
      end

      # Migrate old flat-array or legacy Hash formats to providers: format.
      # Old format = Array at top level, or Hash without "providers" key.
      # Backs up the original file before overwriting so the user can recover it.
      if data && !(data.is_a?(Hash) && data["providers"])
        migrate_config_format(config_file, data)
        # Reload after migration
        data = File.exist?(config_file) ? YAML.load_file(config_file) : data
      end

      # Parse models from config
      models = parse_models(data)

      # Priority: config file > CLACKY_XXX env vars > ClaudeCode env vars
      if models.empty?
        # Try CLACKY_XXX environment variables first
        if ClackyEnv.default_configured?
          models << ClackyEnv.default_model_config
        # ClaudeCode (Anthropic) environment variable support is disabled
        # elsif ClaudeCodeEnv.configured?
        #   models << {
        #     "type" => "default",
        #     "api_key" => ClaudeCodeEnv.api_key,
        #     "base_url" => ClaudeCodeEnv.base_url,
        #     "model" => CLAUDE_DEFAULT_MODEL,
        #     "anthropic_format" => true
        #   }
        end

        # Add CLACKY_LITE_XXX if configured (only when loading from env)
        if ClackyEnv.lite_configured?
          models << ClackyEnv.lite_model_config
        end
      else
        # Config file exists, but check if we need to add env-based models
        # Only add if no model with that type exists
        has_default = models.any? { |m| m["type"] == "default" }
        has_lite = models.any? { |m| m["type"] == "lite" }

        # Add CLACKY default if not in config and env is set
        if !has_default && ClackyEnv.default_configured?
          models << ClackyEnv.default_model_config
        end

        # Add CLACKY lite if not in config and env is set
        if !has_lite && ClackyEnv.lite_configured?
          models << ClackyEnv.lite_model_config
        end

        # Ensure at least one model has type: default
        # If no model has type: default, assign it to the first model
        unless models.any? { |m| m["type"] == "default" }
          models.first["type"] = "default" if models.any?
        end
      end

      new(models: models)
    end

    # Save configuration to file
    # Deep copy — models array contains mutable Hashes, so a shallow dup would
    # let the copy share the same Hash objects with the original, causing
    # Settings changes to silently mutate already-running session configs.
    # JSON round-trip is the cleanest approach since @models is pure JSON-able data.
    def deep_copy
      copy = dup
      copy.instance_variable_set(:@models, JSON.parse(JSON.generate(@models)))
      copy
    end

    def save(config_file = CONFIG_FILE)
      config_dir = File.dirname(config_file)
      FileUtils.mkdir_p(config_dir)
      File.write(config_file, to_yaml)
      FileUtils.chmod(0o600, config_file)
    end

    # Convert to YAML format.
    # If models carry "provider" metadata (loaded from providers: format), serialize back
    # into the provider→model two-layer structure.  Otherwise fall back to the flat array.
    def to_yaml
      if @models.any? { |m| m["provider"] }
        YAML.dump(to_providers_hash)
      else
        YAML.dump(@models)
      end
    end

    # Build the providers: Hash structure from flat @models array.
    # Groups models by (provider name + api_key + base_url + anthropic_format).
    private def to_providers_hash
      providers = []
      grouped = {}
      group_order = []

      @models.each do |m|
        key = [m["provider"] || "", m["api_key"] || "", m["base_url"] || "", m["anthropic_format"]]
        unless grouped.key?(key)
          grouped[key] = []
          group_order << key
        end
        grouped[key] << m
      end

      group_order.each do |key|
        provider_name, api_key, base_url, anthropic_format = key
        model_entries = grouped[key].map do |m|
          entry = { "id" => m["model"] }
          entry["alias"] = m["alias"] if m["alias"]
          entry["type"]  = m["type"]  if m["type"]
          entry
        end
        p = {
          "name"             => provider_name,
          "api_key"          => api_key,
          "base_url"         => base_url,
          "anthropic_format" => anthropic_format,
          "models"           => model_entries
        }
        p.delete("name") if provider_name.empty?
        providers << p
      end

      { "providers" => providers }
    end

    # Check if any model is configured
    def models_configured?
      !@models.empty? && !current_model.nil?
    end

    # Get current model configuration
    def current_model
      return nil if @models.empty?
      @models[@current_model_index]
    end

    # Get model by index
    def get_model(index)
      @models[index]
    end

    # Switch to model by index
    # Updates the type: default to the selected model
    # Returns true if switched, false if index out of range
    def switch_model(index)
      return false if index < 0 || index >= @models.length
      
      # Remove type: default from all models
      @models.each { |m| m.delete("type") if m["type"] == "default" }
      
      # Set type: default on the selected model
      @models[index]["type"] = "default"
      
      # Update current_model_index for backward compatibility
      @current_model_index = index
      
      true
    end

    # List all model names
    def model_names
      @models.map { |m| m["model"] }
    end

    # Get API key for current model
    def api_key
      current_model&.dig("api_key")
    end

    # Set API key for current model
    def api_key=(value)
      return unless current_model
      current_model["api_key"] = value
    end

    # Get base URL for current model
    def base_url
      current_model&.dig("base_url")
    end

    # Set base URL for current model
    def base_url=(value)
      return unless current_model
      current_model["base_url"] = value
    end

    # Get model name for current model
    def model_name
      current_model&.dig("model")
    end

    # Set model name for current model
    def model_name=(value)
      return unless current_model
      current_model["model"] = value
    end

    # Check if should use Anthropic format for current model
    def anthropic_format?
      current_model&.dig("anthropic_format") || false
    end

    # Check if current model uses AWS Bedrock API key (ABSK prefix)
    def bedrock?
      Clacky::MessageFormat::Bedrock.bedrock_api_key?(api_key.to_s)
    end

    # Add a new model configuration
    def add_model(model:, api_key:, base_url:, anthropic_format: false, type: nil)
      @models << {
        "api_key" => api_key,
        "base_url" => base_url,
        "model" => model,
        "anthropic_format" => anthropic_format,
        "type" => type
      }.compact
    end

    # Find model by type (default or lite)
    # Returns the model hash or nil if not found
    def find_model_by_type(type)
      @models.find { |m| m["type"] == type }
    end

    # Get the default model (type: default)
    # Falls back to current_model for backward compatibility
    def default_model
      find_model_by_type("default") || current_model
    end

    # Get the lite model (type: lite)
    # Returns nil if no lite model configured
    def lite_model
      find_model_by_type("lite")
    end

    # Get current model configuration
    # Looks for type: default first, falls back to current_model_index
    def current_model
      return nil if @models.empty?
      default_model = find_model_by_type("default")
      return default_model if default_model
      
      # Fallback to index-based for backward compatibility
      @models[@current_model_index]
    end

    # Set a model's type (default or lite)
    # Ensures only one model has each type
    # @param index [Integer] the model index
    # @param type [String, nil] "default", "lite", or nil to remove type
    # Returns true if successful
    def set_model_type(index, type)
      return false if index < 0 || index >= @models.length
      return false unless ["default", "lite", nil].include?(type)

      if type
        # Remove type from any other model that has it
        @models.each do |m|
          m.delete("type") if m["type"] == type
        end
        
        # Set type on target model
        @models[index]["type"] = type
      else
        # Remove type from target model
        @models[index].delete("type")
      end

      true
    end

    # Handle /model slash command — parse arg and switch model or list models.
    # Returns a human-readable response string suitable for any channel.
    #
    # Usage:
    #   /model           → list all models with current marker
    #   /model <index>   → switch by 1-based index (e.g. /model 2)
    #   /model <alias>   → switch by alias (e.g. /model sonnet)
    #   /model <id>      → switch by partial model id match (e.g. /model gpt-4o)
    #
    # Returns [response_text, switched_index_or_nil]
    # switched_index_or_nil is the 0-based index of the newly active model, or nil if not switched.
    def handle_model_command(arg = nil)
      if arg.nil? || arg.strip.empty?
        return [list_models_text, nil]
      end

      arg = arg.strip

      # Try 1-based numeric index first
      if arg =~ /\A\d+\z/
        idx = arg.to_i - 1
        if idx < 0 || idx >= @models.length
          return ["Model ##{arg} not found. Use /model to list available models.", nil]
        end
        if switch_model(idx)
          m = @models[idx]
          name = model_display_name(m)
          return ["✅ Switched to **#{name}**", idx]
        end
      end

      # Try alias or partial model id match (case-insensitive)
      matched_idx = @models.each_with_index.find do |m, _i|
        alias_match = m["alias"] && m["alias"].downcase == arg.downcase
        id_match    = m["model"] && m["model"].downcase.include?(arg.downcase)
        alias_match || id_match
      end&.last

      if matched_idx
        if switch_model(matched_idx)
          m = @models[matched_idx]
          name = model_display_name(m)
          return ["✅ Switched to **#{name}**", matched_idx]
        end
      end

      ["Model '#{arg}' not found. Use /model to list available models.", nil]
    end

    # Remove a model by index
    # Returns true if removed, false if index out of range or it's the last model
    def remove_model(index)
      # Don't allow removing the last model
      return false if @models.length <= 1
      return false if index < 0 || index >= @models.length
      
      @models.delete_at(index)
      
      # Adjust current_model_index if necessary
      if @current_model_index >= @models.length
        @current_model_index = @models.length - 1
      end
      
      true
    end

    # Format list of all models as human-readable text
    private def list_models_text
      if @models.empty?
        return "No models configured. Use `clacky config set` to add models."
      end

      lines = ["Available models:"]
      @models.each_with_index do |m, i|
        active  = (m["type"] == "default") ? " ◀ current" : ""
        alias_s = m["alias"] ? " (#{m["alias"]})" : ""
        lines << "  #{i + 1}. #{m["model"]}#{alias_s}#{active}"
      end
      lines << "\nUsage: /model <number|alias|model_id>"
      lines.join("\n")
    end

    # Short display name for a model entry
    private def model_display_name(m)
      m["alias"] || m["model"] || "(unknown)"
    end

    private def validate_permission_mode(mode)
      mode ||= :confirm_safes
      mode = mode.to_sym

      unless PERMISSION_MODES.include?(mode)
        raise ArgumentError, "Invalid permission mode: #{mode}. Must be one of #{PERMISSION_MODES.join(', ')}"
      end

      mode
    end

    # Migrate old config format to new providers: format.
    # Creates a backup at config_file + ".bak.<timestamp>" before writing.
    # Only runs once — subsequent loads will see the providers: key and skip this.
    private_class_method def self.migrate_config_format(config_file, data)
      return unless File.exist?(config_file)

      # Parse models from the old data using the legacy parsers below
      flat_models = parse_models_legacy(data)
      return if flat_models.empty?

      # Build providers: structure by grouping on api_key + base_url
      providers = []
      grouped = {}
      group_order = []

      flat_models.each do |m|
        key = [m["api_key"].to_s, m["base_url"].to_s, m["anthropic_format"]]
        unless grouped.key?(key)
          grouped[key] = []
          group_order << key
        end
        grouped[key] << m
      end

      group_order.each_with_index do |key, idx|
        api_key, base_url, anthropic_format = key
        model_entries = grouped[key].map do |m|
          entry = { "id" => (m["model"] || m["name"]).to_s }
          entry["alias"] = m["alias"] if m["alias"]
          entry["type"]  = m["type"]  if m["type"]
          entry
        end
        providers << {
          "name"             => "provider_#{idx + 1}",
          "api_key"          => api_key,
          "base_url"         => base_url,
          "anthropic_format" => anthropic_format || false,
          "models"           => model_entries
        }
      end

      new_data = { "providers" => providers }

      # Backup old file
      timestamp = Time.now.strftime("%Y%m%d%H%M%S")
      backup_path = "#{config_file}.bak.#{timestamp}"
      FileUtils.cp(config_file, backup_path)
      Clacky::Logger.info("[AgentConfig] Migrated config to providers: format. Backup: #{backup_path}")

      # Write new format
      File.write(config_file, YAML.dump(new_data))
      FileUtils.chmod(0o600, config_file)
    rescue => e
      Clacky::Logger.warn("[AgentConfig] Config migration failed: #{e.message}. Continuing with old format.")
    end

    # Legacy parser used ONLY during migration — parses old flat/hash formats into a flat array.
    private_class_method def self.parse_models_legacy(data)
      models = []
      return models if data.nil?

      if data.is_a?(Array)
        models = data.map do |m|
          m = m.dup
          if m["name"] && !m["model"]
            m["model"] = m["name"]
            m.delete("name")
          end
          m
        end
      elsif data.is_a?(Hash) && data["models"]
        if data["models"].is_a?(Array)
          models = data["models"].map do |m|
            m = m.dup
            if m["name"] && !m["model"]
              m["model"] = m["name"]
              m.delete("name")
            end
            m
          end
        end
      elsif data.is_a?(Hash) && data["api_key"]
        models << {
          "api_key"          => data["api_key"],
          "base_url"         => data["base_url"],
          "model"            => data["model"] || CLAUDE_DEFAULT_MODEL,
          "anthropic_format" => data["anthropic_format"] || false
        }
      end

      models
    end

    # Parse models from config data.
    # Supports three formats (newest first):
    #   1. providers: format  — Hash with "providers" key (NEW)
    #   2. Top-level array    — Array of flat model entries  (current)
    #   3. Hash with "models" — Old nested format  (legacy)
    #   4. Single-model Hash  — Very old format  (legacy)
    private_class_method def self.parse_models(data)
      models = []

      # Handle nil or empty data
      return models if data.nil?

      # --- NEW: providers: format ---
      if data.is_a?(Hash) && data["providers"]
        data["providers"].each do |provider|
          provider_name     = provider["name"].to_s
          api_key           = provider["api_key"].to_s
          base_url          = provider["base_url"].to_s
          anthropic_format  = provider["anthropic_format"] || false

          (provider["models"] || []).each do |m|
            entry = {
              "model"           => m["id"].to_s,
              "api_key"         => api_key,
              "base_url"        => base_url,
              "anthropic_format"=> anthropic_format,
              "provider"        => provider_name
            }
            entry["alias"] = m["alias"]   if m["alias"]
            entry["type"]  = m["type"]    if m["type"]
            models << entry
          end
        end
        return models
      end

      if data.is_a?(Array)
        # New format: top-level array of model configurations
        models = data.map do |m|
          # Convert old name-based format to new model-based format if needed
          if m["name"] && !m["model"]
            m["model"] = m["name"]
            m.delete("name")
          end
          m
        end
      elsif data.is_a?(Hash) && data["models"]
        # Old format with "models:" key
        if data["models"].is_a?(Array)
          # Array under models key
          models = data["models"].map do |m|
            # Convert old name-based format to new model-based format
            if m["name"] && !m["model"]
              m["model"] = m["name"]
              m.delete("name")
            end
            m
          end
        elsif data["models"].is_a?(Hash)
          # Hash format with tier names as keys (very old format)
          data["models"].each do |tier_name, config|
            if config.is_a?(Hash)
              model_config = {
                "api_key" => config["api_key"],
                "base_url" => config["base_url"],
                "model" => config["model_name"] || config["model"] || tier_name,
                "anthropic_format" => config["anthropic_format"] || false
              }
              models << model_config
            elsif config.is_a?(String)
              # Old-style tier with just model name
              model_config = {
                "api_key" => data["api_key"],
                "base_url" => data["base_url"],
                "model" => config,
                "anthropic_format" => data["anthropic_format"] || false
              }
              models << model_config
            end
          end
        end
      elsif data.is_a?(Hash) && data["api_key"]
        # Very old format: single model with global config
        models << {
          "api_key" => data["api_key"],
          "base_url" => data["base_url"],
          "model" => data["model"] || CLAUDE_DEFAULT_MODEL,
          "anthropic_format" => data["anthropic_format"] || false
        }
      end

      models
    end
  end
end
