# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/configuration"

# A `signature_paths:` `.rbs` that parses fine but redeclares a constant/class Rigor's bundled RBS already ships
# raises `RBS::DuplicatedDeclarationError` at resolve, which collapses the WHOLE RBS environment to nil — every
# type-of query then reads `Dynamic[top]` and most rules stop firing, so the run comes back EMPTY, which reads as
# clean. The `rbs.coverage.environment-build-failed` diagnostic is what makes that visible in every channel
# (`--format json`, SARIF, CI annotations, the LSP), naming the conflicting files; the
# `reject-unparseable-signatures` bleeding-edge feature turns it into a build failure for a project that opts in.
# It is the twin of `rbs.coverage.quarantined-signature`, one tier louder in consequence.
RSpec.describe "environment build failed reporting" do
  # `RUBY_VERSION: Integer` redeclares a constant core RBS already ships (`core/constants.rbs`), so the env
  # collapses on resolve with `RBS::DuplicatedDeclarationError`.
  let(:conflicting_rbs) { "RUBY_VERSION: Integer\n" }
  let(:valid_rbs) { "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n" }

  def write_project(rbs:)
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "conflict.rbs"), rbs)
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

  def env_failed_diagnostics(result)
    result.diagnostics.select { |d| d.rule == "rbs.coverage.environment-build-failed" }
  end

  around do |example|
    Dir.mktmpdir("rigor-env-build-failed-integration-") do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  # The loader's stderr banner is a separate channel (it serves `coverage` / `sig-gen`, which have no diagnostic
  # stream); it is not what these examples are about.
  before { allow_any_instance_of(Rigor::Environment::RbsLoader).to receive(:warn) } # rubocop:disable RSpec/AnyInstance

  it "reports a total env-build failure as a :warning without failing the run" do
    write_project(rbs: conflicting_rbs)
    result = run(config)

    diagnostics = env_failed_diagnostics(result)
    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.severity).to eq(:warning)
    expect(diagnostics.first.path).to eq(".rigor.yml")
    # Names the user's conflicting signature file, and the conflict itself.
    expect(diagnostics.first.message).to include("sig/conflict.rbs")
    expect(diagnostics.first.message).to include("RUBY_VERSION")
    # A warning does not fail the build: an existing green project must not turn red just by upgrading Rigor —
    # the conflict is typically against Rigor's OWN bundled RBS.
    expect(result.success?).to be(true)
  end

  it "fires nothing when the RBS environment builds" do
    write_project(rbs: valid_rbs)
    expect(env_failed_diagnostics(run(config))).to be_empty
  end

  it "fails the run when the project adopts the reject-unparseable-signatures feature" do
    write_project(rbs: conflicting_rbs)
    result = run(config(bleeding_edge: true))

    diagnostics = env_failed_diagnostics(result)
    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.severity).to eq(:error)
    expect(result.success?).to be(false)
  end

  it "is adoptable by feature id alone" do
    write_project(rbs: conflicting_rbs)
    result = run(config(bleeding_edge: ["reject-unparseable-signatures"]))
    expect(env_failed_diagnostics(result).first.severity).to eq(:error)
  end
end
