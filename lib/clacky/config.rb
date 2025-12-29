# frozen_string_literal: true

require "yaml"
require "fileutils"

module Clacky
  class Config
    CONFIG_DIR = File.join(Dir.home, ".clacky")
    CONFIG_FILE = File.join(CONFIG_DIR, "config.yml")

    attr_accessor :api_key, :model

    def initialize(data = {})
      @api_key = data["api_key"]
      @model = data["model"] || "claude-3-5-sonnet-20241022"
    end

    def self.load
      if File.exist?(CONFIG_FILE)
        data = YAML.load_file(CONFIG_FILE) || {}
        new(data)
      else
        new
      end
    end

    def save
      FileUtils.mkdir_p(CONFIG_DIR)
      File.write(CONFIG_FILE, to_yaml)
      FileUtils.chmod(0o600, CONFIG_FILE) # Secure the config file
    end

    def to_yaml
      YAML.dump({
        "api_key" => @api_key,
        "model" => @model
      })
    end
  end
end
