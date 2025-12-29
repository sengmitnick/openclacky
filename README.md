# Clacky

A command-line interface for interacting with Claude AI. Clacky makes it easy to have conversations with Claude directly from your terminal.

## Features

- 💬 Interactive chat sessions with Claude
- 🚀 Single-message mode for quick queries
- 🔐 Secure API key management
- 📝 Multi-turn conversation support
- 🎨 Colorful terminal output
- ⚡ Powered by Claude 3.5 Sonnet

## Installation

Install the gem by executing:

```bash
gem install clacky
```

Or add it to your Gemfile:

```bash
bundle add clacky
```

For development from source:

```bash
git clone https://github.com/yafeilee/clacky.git
cd clacky
bundle install
bundle exec exe/clacky
```

## Configuration

Before using Clacky, you need to configure your Claude API key:

```bash
clacky config set
```

You'll be prompted to enter your API key. Get your API key from [Claude Console](https://console.anthropic.com/).

To view your current configuration:

```bash
clacky config show
```

## Usage

### Interactive Chat Mode

Start an interactive chat session:

```bash
clacky chat
```

Type your messages and press Enter. Type `exit` or `quit` to end the session.

### Single Message Mode

Send a single message and get a response:

```bash
clacky chat "What is Ruby?"
```

### Specify Model

You can specify which Claude model to use:

```bash
clacky chat --model=claude-3-5-sonnet-20241022 "Hello!"
```

### Available Commands

```bash
clacky chat [MESSAGE]     # Start a chat or send a single message
clacky config set         # Set your API key
clacky config show        # Show current configuration
clacky version            # Show clacky version
clacky help               # Show help information
```

## Examples

```bash
# Quick question
clacky chat "Explain closures in Ruby"

# Start interactive session
clacky chat

# Check version
clacky version
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/clacky. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/[USERNAME]/clacky/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Clacky project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/clacky/blob/main/CODE_OF_CONDUCT.md).
