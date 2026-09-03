# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/configuration"

# An unparseable `.rbs` under `signature_paths:` is QUARANTINED so the rest of the RBS env survives (the
# env-build resilience fix). The failure mode that leaves behind is silence: the types the skipped file declared
# are gone, so the run gets QUIETER — which reads as a clean run. The `rbs.coverage.quarantined-signature`
# diagnostic is what makes that visible in every channel (`--format json`, SARIF, CI annotations, the LSP), and
# the `reject-unparseable-signatures` bleeding-edge feature is what turns it into a build failure for a project
# that opts in (ADR-50 WD3 — a new required discipline ships off-by-default, then defaults on at a major).
RSpec.describe "quarantined signature reporting" do
  # The exact shape a sig-gen bug once emitted into a real project: a bare non-identifier record key
  # (`data-contrast:`), which `rbs` rejects with `unexpected record key token`.
  let(:broken_rbs) { "module Acme\n  class Broken\n    def h: () -> { data-contrast: Integer }\n  end\nend\n" }
  let(:valid_rbs) { "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n" }

  def write_project(rbs:)
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "acme.rbs"), rbs)
    File.write("app.rb", "x = 1\n")
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

  def quarantine_diagnostics(result)
    result.diagnostics.select { |d| d.rule == "rbs.coverage.quarantined-signature" }
  end

  around do |example|
    Dir.mktmpdir("rigor-quarantine-integration-") do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  # The loader's stderr banner is a separate channel (it serves `coverage` / `sig-gen`, which have no diagnostic
  # stream); it is not what these examples are about.
  before { allow_any_instance_of(Rigor::Environment::RbsLoader).to receive(:warn) } # rubocop:disable RSpec/AnyInstance

  it "reports a quarantined signature as a :warning without failing the run" do
    write_project(rbs: broken_rbs)
    result = run(config)

    diagnostics = quarantine_diagnostics(result)
    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.severity).to eq(:warning)
    expect(diagnostics.first.path).to eq(".rigor.yml")
    expect(diagnostics.first.message).to include("sig/acme.rbs")
    # A warning does not fail the build: an existing green project must not turn red just by upgrading Rigor.
    expect(result.success?).to be(true)
  end

  it "fires nothing when every signature parses" do
    write_project(rbs: valid_rbs)
    expect(quarantine_diagnostics(run(config))).to be_empty
  end

  it "fails the run when the project adopts the reject-unparseable-signatures feature" do
    write_project(rbs: broken_rbs)
    result = run(config(bleeding_edge: true))

    diagnostics = quarantine_diagnostics(result)
    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.severity).to eq(:error)
    expect(result.success?).to be(false)
  end

  it "is adoptable by feature id alone" do
    write_project(rbs: broken_rbs)
    result = run(config(bleeding_edge: ["reject-unparseable-signatures"]))
    expect(quarantine_diagnostics(result).first.severity).to eq(:error)
  end
end
