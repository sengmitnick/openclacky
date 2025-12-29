# frozen_string_literal: true

require_relative "clacky/version"
require_relative "clacky/config"
require_relative "clacky/client"
require_relative "clacky/conversation"
require_relative "clacky/cli"

module Clacky
  class Error < StandardError; end
end
