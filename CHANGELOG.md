# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-12-27

### Added
- Initial release of Clacky
- Interactive chat mode for conversations with Claude
- Single message mode for quick queries
- Configuration management for API keys
- Support for Claude 3.5 Sonnet model
- Colorful terminal output with TTY components
- Secure API key storage in `~/.clacky/config.yml`
- Multi-turn conversation support with context preservation
- Command-line interface powered by Thor
- Comprehensive test suite with RSpec

### Features
- `clacky chat [MESSAGE]` - Start interactive chat or send single message
- `clacky config set` - Configure API key
- `clacky config show` - Display current configuration
- `clacky version` - Show version information
- Model selection via `--model` option

[Unreleased]: https://github.com/yafeilee/clacky/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yafeilee/clacky/releases/tag/v0.1.0
