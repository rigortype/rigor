# frozen_string_literal: true

# Gate #2755: the VS Code extension's managed Rigor (ADR-27 WD10) accepts a candidate Ruby only when
# `Gem.ruby_version` satisfies `REQUIRED_RUBY` in `editors/vscode/src/runtime.ts`, a copy of
# `rigortype.gemspec`'s `required_ruby_version`. Nothing else couples the two, so a gemspec bump (to
# Ruby 4.1, say) would leave the extension rejecting a Ruby the gem accepts, or building on one it
# refuses. The gemspec is read with RubyGems' own loader; the TypeScript constant is one array literal
# of string literals, scanned as such.
require "spec_helper"
require "rubygems"

VSCODE_RUBY_REPO_ROOT = File.expand_path("../..", __dir__)
VSCODE_RUBY_RUNTIME_TS = File.join(VSCODE_RUBY_REPO_ROOT, "editors", "vscode", "src", "runtime.ts")

RSpec.describe "VS Code REQUIRED_RUBY sync with rigortype.gemspec (#2755)" do
  def extension_requirements
    literal = File.read(VSCODE_RUBY_RUNTIME_TS)[/^const REQUIRED_RUBY = \[([^\]]*)\];$/, 1]
    raise "no `const REQUIRED_RUBY = [...];` line in #{VSCODE_RUBY_RUNTIME_TS}" unless literal

    literal.scan(/"([^"]*)"/).flatten
  end

  def gemspec_requirements
    spec = Gem::Specification.load(File.join(VSCODE_RUBY_REPO_ROOT, "rigortype.gemspec"))
    spec.required_ruby_version.requirements.map { |op, version| "#{op} #{version}" }
  end

  it "reads a requirement from each side (guards a format change that would yield nothing)" do
    expect(extension_requirements).not_to be_empty
    expect(gemspec_requirements).not_to be_empty
  end

  it "keeps REQUIRED_RUBY equal to the gemspec's required_ruby_version" do
    extension = Gem::Requirement.new(*extension_requirements)
    gemspec = Gem::Requirement.new(*gemspec_requirements)

    expect(extension.requirements.sort).to eq(gemspec.requirements.sort), <<~MESSAGE
      editors/vscode/src/runtime.ts REQUIRED_RUBY is #{extension_requirements.inspect},
      rigortype.gemspec required_ruby_version is #{gemspec_requirements.inspect}.
      Update REQUIRED_RUBY to match the gemspec (and the README's Ruby wording if the range moved).
    MESSAGE
  end
end
