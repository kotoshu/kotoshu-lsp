# frozen_string_literal: true

require_relative "lib/kotoshu/lsp/version"

Gem::Specification.new do |spec|
  spec.name = "kotoshu-lsp"
  spec.version = Kotoshu::Lsp::VERSION
  spec.authors = ["Ribose Inc."]
  spec.email = ["open.source@ribose.com"]

  spec.summary = "Language Server Protocol server for the Kotoshu spell checker"
  spec.description = "Wraps the Kotoshu gem with a JSON-RPC LSP server so every " \
                    "LSP-capable editor (VS Code, Neovim, Emacs, JetBrains) gets " \
                    "inline spell-check diagnostics, code actions, and hover."
  spec.homepage = "https://github.com/kotoshu/kotoshu-lsp"
  spec.required_ruby_version = ">= 3.1.0"
  spec.license = "BSD-2-Clause"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/kotoshu/kotoshu-lsp/tree/main"
  spec.metadata["changelog_uri"] = "https://github.com/kotoshu/kotoshu-lsp/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) || f.start_with?(*%w[bin/ spec/ .git .github])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "kotoshu", "~> 0.6"
end
