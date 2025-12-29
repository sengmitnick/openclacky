# frozen_string_literal: true

require "thor"

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
    option :model, type: :string, default: "claude-3-5-sonnet-20241022", desc: "Claude model to use"
    def chat(message = nil)
      config = Config.load

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

      client = Client.new(config.api_key)
      response = client.send_message(message, model: options[:model])

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

      conversation = Conversation.new(config.api_key, model: options[:model])
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
      api_key = prompt.mask("Enter your Claude API key:")

      config = Config.load
      config.api_key = api_key
      config.save

      say "Configuration saved successfully!", :green
    end

    desc "show", "Show current configuration"
    def show
      config = Config.load

      if config.api_key
        masked_key = config.api_key[0..7] + ("*" * 20) + config.api_key[-4..]
        say "API Key: #{masked_key}", :cyan
      else
        say "No API key configured", :yellow
      end
    end
  end

  # Register subcommands after all classes are defined
  CLI.register(ConfigCommand, "config", "config SUBCOMMAND", "Manage configuration")
end
