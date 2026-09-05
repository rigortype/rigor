# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/configuration"

# Issue #777: a `signature_paths:` `.rbs` that parses fine but redeclares a constant/class Rigor's
# bundled RBS already ships used to raise `RBS::DuplicatedDeclarationError` and collapse the WHOLE
# RBS environment to nil. The conflicting file is now QUARANTINED (same channel as unparseable
# signatures), so Greeter/core stay available and dependent diagnostics still fire. The
# `rbs.coverage.environment-build-failed` diagnostic remains for *unrecoverable* build failures
# (stubbed below); recoverable collisions surface as `rbs.coverage.quarantined-signature`.
RSpec.describe "environment build failed / conflict quarantine reporting" do
  let(:conflicting_rbs) { "RUBY_VERSION: Integer\n" }
  let(:valid_rbs) { "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n" }
  let(:class_vs_module_rbs) { "class Base64\n  def self.encode64: (String) -> String\nend\n" }

  def write_project(rbs:, app: "x = 1\n")
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "conflict.rbs"), rbs)
    File.write("app.rb", app)
  end

  def config(bleeding_edge: nil)
    settings = Rigor::Configuration::DEFAULTS.merge(
      "paths" => %w[app.rb], "signature_paths" => %w[sig]
    )
    settings = settings.merge("bleeding_edge" => bleeding_edge) unless bleeding_edge.nil?
    Rigor::Configuration.new(settings)
  end

  def run(configuration)
    guarded_run(Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil), %w[app.rb])
  end

  def env_failed_diagnostics(result)
    result.diagnostics.select { |d| d.rule == "rbs.coverage.environment-build-failed" }
  end

  def quarantine_diagnostics(result)
    result.diagnostics.select { |d| d.rule == "rbs.coverage.quarantined-signature" }
  end

  around do |example|
    Dir.mktmpdir("rigor-env-build-failed-integration-") do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  before { allow_any_instance_of(Rigor::Environment::RbsLoader).to receive(:warn) } # rubocop:disable RSpec/AnyInstance

  it "quarantines a constant collision and keeps the run's other diagnostics available" do
    write_project(rbs: conflicting_rbs)
    result = run(config)

    expect(env_failed_diagnostics(result)).to be_empty
    diagnostics = quarantine_diagnostics(result)
    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.severity).to eq(:warning)
    expect(diagnostics.first.message).to include("sig/conflict.rbs")
    expect(result.success?).to be(true)
  end

  it "quarantines class-vs-module Base64 and still reports a dependent undefined-method" do
    skip "requires sources-based RBS::Environment (rbs 4.x)" unless RBS::Environment.new.respond_to?(:sources)

    FileUtils.mkdir_p("sig")
    File.write("sig/base64.rbs", class_vs_module_rbs)
    File.write("sig/greeter.rbs", "class Greeter\n  def greet: () -> String\nend\n")
    File.write("app.rb", "greeter = Greeter.new\nputs greeter.greet.lenght\n")
    result = run(config)

    expect(env_failed_diagnostics(result)).to be_empty
    expect(quarantine_diagnostics(result).map(&:message).join).to include("sig/base64.rbs")
    undefined = result.diagnostics.select { |d| d.rule.to_s.include?("undefined") || d.message.include?("lenght") }
    expect(undefined).not_to be_empty, "expected lenght typo diagnostic, got: #{result.diagnostics.map { |d| [d.rule, d.message] }}"
  end

  it "fires nothing when the RBS environment builds cleanly" do
    write_project(rbs: valid_rbs)
    expect(quarantine_diagnostics(run(config))).to be_empty
    expect(env_failed_diagnostics(run(config))).to be_empty
  end

  it "reports an unrecoverable env-build failure as a :warning without failing the run" do
    write_project(rbs: valid_rbs)
    allow(Rigor::Environment::RbsLoader).to receive(:build_env_for).and_raise(
      Class.new(RBS::BaseError) { def message = "forced unrecoverable build failure" }.new
    )
    result = run(config)

    diagnostics = env_failed_diagnostics(result)
    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.severity).to eq(:warning)
    expect(diagnostics.first.path).to eq(".rigor.yml")
    expect(result.success?).to be(true)
  end

  it "fails the run when reject-unparseable-signatures promotes a collision quarantine" do
    write_project(rbs: conflicting_rbs)
    result = run(config(bleeding_edge: true))

    diagnostics = quarantine_diagnostics(result)
    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.severity).to eq(:error)
    expect(result.success?).to be(false)
  end

  it "is adoptable by feature id alone for collision quarantine" do
    write_project(rbs: conflicting_rbs)
    result = run(config(bleeding_edge: ["reject-unparseable-signatures"]))
    expect(quarantine_diagnostics(result).first.severity).to eq(:error)
  end
end
