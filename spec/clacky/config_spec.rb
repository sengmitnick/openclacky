# frozen_string_literal: true

RSpec.describe Clacky::Config do
  let(:config_dir) { File.join(Dir.home, ".clacky") }
  let(:config_file) { File.join(config_dir, "config.yml") }

  before do
    # Clean up any existing config
    FileUtils.rm_f(config_file) if File.exist?(config_file)
  end

  after do
    # Clean up after tests
    FileUtils.rm_f(config_file) if File.exist?(config_file)
  end

  describe ".load" do
    context "when config file doesn't exist" do
      it "returns a new config with default values" do
        config = described_class.load
        expect(config.api_key).to be_nil
        expect(config.model).to eq("gpt-3.5-turbo")
        expect(config.base_url).to eq("https://api.openai.com")
      end
    end

    context "when config file exists" do
      it "loads configuration from file" do
        config = described_class.new("api_key" => "test-key", "model" => "gpt-4", "base_url" => "https://api.test.com")
        config.save

        loaded_config = described_class.load
        expect(loaded_config.api_key).to eq("test-key")
        expect(loaded_config.model).to eq("gpt-4")
        expect(loaded_config.base_url).to eq("https://api.test.com")
      end
    end
  end

  describe "#save" do
    it "saves configuration to file" do
      config = described_class.new("api_key" => "my-api-key")
      config.save

      expect(File).to exist(config_file)
      saved_data = YAML.load_file(config_file)
      expect(saved_data["api_key"]).to eq("my-api-key")
    end

    it "creates config directory if it doesn't exist" do
      FileUtils.rm_rf(config_dir) if Dir.exist?(config_dir)

      config = described_class.new("api_key" => "test-key")
      config.save

      expect(Dir).to exist(config_dir)
    end

    it "sets secure file permissions" do
      config = described_class.new("api_key" => "secure-key")
      config.save

      file_stat = File.stat(config_file)
      permissions = file_stat.mode.to_s(8)[-3..]
      expect(permissions).to eq("600")
    end
  end

  describe "#to_yaml" do
    it "converts config to YAML format" do
      config = described_class.new("api_key" => "test-key", "model" => "gpt-4", "base_url" => "https://api.test.com")
      yaml = config.to_yaml

      expect(yaml).to include("api_key: test-key")
      expect(yaml).to include("model: gpt-4")
      expect(yaml).to include("base_url: https://api.test.com")
    end
  end
end
