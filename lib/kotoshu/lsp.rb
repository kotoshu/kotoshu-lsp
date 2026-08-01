# frozen_string_literal: true

require_relative "lsp/version"
require_relative "lsp/server"

module Kotoshu
  module Lsp
    def self.run(input: $stdin, output: $stdout, logger: nil)
      server = Server.new(input: input, output: output, logger: logger)
      server.run
    end
  end
end
