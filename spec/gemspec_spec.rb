# frozen_string_literal: true

# The plan-118 failure mode, lsp edition: the runtime floor sat at
# ~> 0.6 while kotoshu moved to 1.0 - lsp 0.1.1 resolved the pre-1.0
# engine. A shipped constraint nobody reads must be guarded by a spec
# that reads it.
RSpec.describe "kotoshu-lsp gemspec" do
  let(:spec) do
    Gem::Specification.load(File.expand_path("../kotoshu-lsp.gemspec", __dir__))
  end

  it "floors kotoshu on the engine line it actually rides" do
    dependency = spec.dependencies.find { |d| d.name == "kotoshu" }

    expect(dependency).not_to be_nil
    expect(dependency.requirement).to be_satisfied_by(Gem::Version.new(Kotoshu::VERSION))
  end
end
