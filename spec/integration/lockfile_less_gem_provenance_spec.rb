# frozen_string_literal: true

# Issue #530 item 3 — a project with no `Gemfile.lock`.
#
# ADR-82 WD9's constant-ownership index was driven entirely by the LOCKED gem set, so a lockfile-less
# project handed it nothing and every constant reaching into an RBS-less gem kept the generic
# `unsupported_syntax` cause. `coverage --protection` then reported the project's whole gem boundary as
# `engine_gap` — "report this to Rigor" — where the honest answer is `add_rbs`. Measured on slim, whose
# entire Temple boundary lands that way while haml, which has a lockfile, attributes the same gem
# correctly.
#
# The provenance is a side-channel, so the second example pins the half that must NOT move: the run's
# diagnostics are byte-identical with and without the fallback.

require "spec_helper"
require "fileutils"
require "prism"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/environment"
require "rigor/inference/protection_scanner"
require "rigor/scope"

RSpec.describe "gem provenance without a Gemfile.lock (#530)" do
  # A bundle tree with one gem that ships no `sig/`, and deliberately NO `Gemfile.lock` beside it — the
  # shape the fallback exists for. The entry file is real because the index establishes ownership by
  # reading it.
  def write_project
    entry = File.join("vendor", "bundle", "ruby", "4.0.0", "gems", "faraday-2.9.0", "lib", "faraday.rb")
    FileUtils.mkdir_p(File.dirname(entry))
    File.write(entry, "module Faraday\n  class Connection\n  end\nend\n")
    FileUtils.mkdir_p("lib")
    File.write(File.join("lib", "a.rb"), <<~RUBY)
      def run
        Faraday::Connection.new.get("/")
        "text".no_such_method
      end
    RUBY
  end

  def config
    Rigor::Configuration.new(
      Rigor::Configuration::DEFAULTS.merge(
        "paths" => %w[lib], "workers" => 0,
        "bundler" => { "bundle_path" => "vendor/bundle", "auto_detect" => false, "lockfile" => nil }
      )
    )
  end

  def origins
    environment = Rigor::Environment.for_project(
      root: Dir.pwd, bundler_bundle_path: "vendor/bundle", bundler_auto_detect: false
    )
    root = Prism.parse(File.read(File.join("lib", "a.rb"))).value
    scanner = Rigor::Inference::ProtectionScanner.new(scope: Rigor::Scope.empty(environment: environment))
    scanner.scan(root).sites.to_h { |site| [site.method_name, site.dynamic_origin] }
  end

  def diagnostics
    result = guarded_run(Rigor::Analysis::Runner.new(configuration: config), %w[lib])
    result.diagnostics.map { |d| "#{File.basename(d.path)}:#{d.line}:#{d.column} #{d.qualified_rule} #{d.message}" }
  end

  around do |example|
    Dir.mktmpdir("rigor-lockfile-less-") { |dir| Dir.chdir(dir) { example.run } }
  end

  it "attributes a constant reaching into an installed RBS-less gem to that gem" do
    write_project
    expect(origins).to include("new" => :external_gem_without_rbs, "get" => :external_gem_without_rbs)
  end

  it "keeps the generic cause for a constant no installed gem declares" do
    # The must-still-decline arm: the fallback widens WHICH gems can be claimed, never whether an unowned
    # constant is claimed. Without this a change that labelled every unresolved constant would pass above.
    write_project
    File.write(File.join("lib", "a.rb"), "def run\n  Farraday::Connection.new\nend\n")
    expect(origins.fetch("new")).to eq(:unsupported_syntax)
  end

  it "leaves the run's diagnostics byte-identical" do
    # Provenance only: the fallback changes a label on the protection report and nothing a user is told
    # about their code. The `no_such_method` call keeps both sides non-empty, so this is agreement between
    # two real answers rather than two silences.
    write_project
    live = diagnostics
    expect(live).not_to be_empty

    # Emptying the fallback restores the pre-#530 behaviour, and the origin assertion proves the two arms
    # really do differ — without it the comparison below could be between two identical runs.
    allow(Rigor::Environment::InstalledGemSet).to receive(:gems).and_return({})
    expect(origins.fetch("get")).to eq(:unsupported_syntax)
    expect(diagnostics).to eq(live)
  end
end
