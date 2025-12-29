# frozen_string_literal: true

require "thor"
require "tty-prompt"
require "tty-spinner"

module Clacky
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    desc "chat [MESSAGE]", "Start a chat with Claude or send a single message"
    long_desc <<-LONGDESC
      Start an interactive chat session with Claude AI.

      If MESSAGE is provided, send it as a single message and exit.
      If no MESSAGE is provided, start an interactive chat session.

      Examples:
        $ clacky chat "What is Ruby?"
        $ clacky chat
    LONGDESC
    option :model, type: :string, desc: "Model to use (default from config)"
    def chat(message = nil)
      config = Clacky::Config.load

      unless config.api_key
        say "Error: API key not found. Please run 'clacky config set' first.", :red
        exit 1
      end

      if message
        # Single message mode
        send_single_message(message, config)
      else
        # Interactive mode
        start_interactive_chat(config)
      end
    end

    desc "version", "Show clacky version"
    def version
      say "Clacky version #{Clacky::VERSION}"
    end

    private

    def send_single_message(message, config)
      spinner = TTY::Spinner.new("[:spinner] Thinking...", format: :dots)
      spinner.auto_spin

      client = Clacky::Client.new(config.api_key, base_url: config.base_url)
      response = client.send_message(message, model: options[:model] || config.model)

      spinner.success("Done!")
      say "\n#{response}", :cyan
    rescue StandardError => e
      spinner.error("Failed!")
      say "Error: #{e.message}", :red
      exit 1
    end

    def start_interactive_chat(config)
      say "Starting interactive chat with Claude...", :green
      say "Type 'exit' or 'quit' to end the session.\n\n", :yellow

      conversation = Clacky::Conversation.new(
        config.api_key,
        model: options[:model] || config.model,
        base_url: config.base_url
      )
      prompt = TTY::Prompt.new

      loop do
        message = prompt.ask("You:", required: false)
        break if message.nil? || %w[exit quit].include?(message.downcase.strip)
        next if message.strip.empty?

        spinner = TTY::Spinner.new("[:spinner] Claude is thinking...", format: :dots)
        spinner.auto_spin

        begin
          response = conversation.send_message(message)
          spinner.success("Claude:")
          say response, :cyan
          say "\n"
        rescue StandardError => e
          spinner.error("Error!")
          say "Error: #{e.message}", :red
        end
      end

      say "\nGoodbye!", :green
    end
  end

  class ConfigCommand < Thor
    desc "set", "Set configuration values"
    def set
      prompt = TTY::Prompt.new

      config = Clacky::Config.load

      # API Key
      api_key = prompt.mask("Enter your Claude API key:")
      config.api_key = api_key

      # Model
      model = prompt.ask("Enter model:", default: config.model)
      config.model = model

      # Base URL
      base_url = prompt.ask("Enter base URL:", default: config.base_url)
      config.base_url = base_url

      config.save

      say "\nConfiguration saved successfully!", :green
      say "API Key: #{api_key[0..7]}#{'*' * 20}#{api_key[-4..]}", :cyan
      say "Model: #{config.model}", :cyan
      say "Base URL: #{config.base_url}", :cyan
    end

    desc "show", "Show current configuration"
    def show
      config = Clacky::Config.load

      if config.api_key
        masked_key = config.api_key[0..7] + ("*" * 20) + config.api_key[-4..]
        say "API Key: #{masked_key}", :cyan
        say "Model: #{config.model}", :cyan
        say "Base URL: #{config.base_url}", :cyan
      else
        say "No configuration found. Run 'clacky config set' to configure.", :yellow
      end
    end
  end

  # Register subcommands after all classes are defined
  CLI.register(ConfigCommand, "config", "config SUBCOMMAND", "Manage configuration")
end
