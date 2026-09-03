# frozen_string_literal: true

require "tmpdir"

require "rigor"
require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/environment"

# Issue #696 — two signature sources declaring the same METHOD make `RBS::DefinitionBuilder` raise
# `DuplicatedMethodDefinitionError` for that class. The class stays KNOWN (`class_known?` reads
# `known_class_names_set`, never a definition build) but loses its method surface, so every call on it — real
# methods and typos alike — reads `Dynamic[top]`. When the collision is on a class others inherit, the whole
# bundled type universe goes with it: the observed shape was thousands of stderr warnings, ZERO diagnostics,
# and exit 0, which every downstream consumer reads as a clean build.
#
# `rbs.coverage.definition-build-failed` is what makes that visible in every channel (`--format json`, SARIF,
# CI annotations, the LSP), and `reject-unparseable-signatures` is what turns it into a build failure for a
# project that opts in. It is the third rung of the ladder its two siblings already sit on, between them by
# consequence: a QUARANTINED file removes what one file declared, this removes what one CLASS declared, an
# ENV-BUILD failure removes everything.
#
# EVERY example here asserts a declared return RESOLVES, or that the diagnostic is PRESENT. A collapsed class
# produces zero diagnostics, so an absence-only assertion passes on exactly the failure this spec exists to
# catch — the trap #665 / #674 / #683 / #686 spent a cycle closing.
RSpec.describe "definition build failed reporting" do
  # Two declarations of `Acme#label` in one signature source. The env RESOLVES fine (this is not
  # `DuplicatedDeclarationError`); the failure happens later, lazily, the first time something demands
  # `Acme`'s definition.
  let(:conflicting_rbs) do
    "class Acme\n  def label: () -> String\nend\n\nclass Acme\n  def label: () -> String\nend\n"
  end
  let(:valid_rbs) { "class Acme\n  def label: () -> String\nend\n" }

  # `label` is declared on both sides, so it resolves whenever the definition builds; `no_such_method` never
  # does. The pair is the point: it separates "the class lost its method surface" from "the rule declined".
  let(:source) { "a = Acme.new\na.label.upcase\na.no_such_method\n" }

  def write_project(rbs:)
    FileUtils.mkdir_p("sig")
    File.write(File.join("sig", "acme.rbs"), rbs)
    File.write("app.rb", source)
  end

  def config(bleeding_edge: nil, signature_paths: %w[sig])
    settings = Rigor::Configuration::DEFAULTS.merge("paths" => %w[app.rb], "signature_paths" => signature_paths)
    settings = settings.merge("bleeding_edge" => bleeding_edge) unless bleeding_edge.nil?
    Rigor::Configuration.new(settings)
  end

  def run(configuration, **runner_kwargs)
    guarded_run(
      Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil, **runner_kwargs), %w[app.rb]
    )
  end

  def build_failed_diagnostics(result)
    result.diagnostics.select { |d| d.rule == "rbs.coverage.definition-build-failed" }
  end

  def rules(result)
    result.diagnostics.map(&:rule)
  end

  around do |example|
    Dir.mktmpdir("rigor-definition-build-failed-integration-") do |dir|
      Dir.chdir(dir) { example.run }
    end
  end

  # The loader's stderr banner is a separate channel (it serves `coverage` / `sig-gen`, which have no
  # diagnostic stream); it is not what these examples are about.
  before { allow_any_instance_of(Rigor::Environment::RbsLoader).to receive(:warn) } # rubocop:disable RSpec/AnyInstance

  it "reports the failed class as a :warning without failing the run" do
    write_project(rbs: conflicting_rbs)
    result = run(config)

    diagnostics = build_failed_diagnostics(result)
    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.severity).to eq(:warning)
    expect(diagnostics.first.path).to eq(".rigor.yml")
    expect(diagnostics.first.message).to include("Acme")
    expect(diagnostics.first.message).to include("sig/acme.rbs")
    # A warning does not fail the build: the collision is typically between the user's `sig/` and Rigor's OWN
    # bundled RBS, so an `:error` default would let a Rigor release turn a green build red with no user change.
    expect(result.success?).to be(true)
  end

  # The half that makes the example above mean something. With the class collapsed, `no_such_method` is NOT
  # reported — that silence is the bug — so a spec that only checked "the warning fired" would still pass on
  # an implementation that left the collapse in place. This pins the collapse itself, and its twin below
  # pins that the same call really does report once the sig set is healthy.
  it "loses the undefined-method report on the collapsed class (the silence the warning is about)" do
    write_project(rbs: conflicting_rbs)

    expect(rules(run(config))).to include("rbs.coverage.definition-build-failed")
    expect(rules(run(config))).not_to include("call.undefined-method")
  end

  it "fires nothing when every definition builds, and the declared method still resolves" do
    write_project(rbs: valid_rbs)
    result = run(config)

    expect(build_failed_diagnostics(result)).to be_empty
    # The POSITIVE control: `Acme` has a method surface, so the declared `label` resolves and only the typo
    # is reported. Byte-for-byte what master reports for this project.
    expect(rules(result)).to eq(["call.undefined-method"])
    expect(result.diagnostics.first.message).to include("no_such_method")
  end

  it "fails the run when the project adopts the reject-unparseable-signatures feature" do
    write_project(rbs: conflicting_rbs)
    result = run(config(bleeding_edge: true))

    diagnostics = build_failed_diagnostics(result)
    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.severity).to eq(:error)
    expect(result.success?).to be(false)
  end

  it "is adoptable by feature id alone" do
    write_project(rbs: conflicting_rbs)
    result = run(config(bleeding_edge: ["reject-unparseable-signatures"]))

    expect(build_failed_diagnostics(result).first.severity).to eq(:error)
  end

  # Issue #696's structural problem 2. Under the pool the PARENT never analyses a file, so its loader never
  # demands a definition and never enters the failing build: a diagnostic wired off the parent's loader would
  # appear here at `workers: 0` and VANISH at `workers: 2` — "reports less depending on how you ran it", the
  # same defect in a new costume. The message has to be identical, not merely present, because a run that
  # names a different set of classes under one flag is the same failure one step quieter.
  it "says exactly the same thing under the fork pool as it does sequentially" do
    write_project(rbs: conflicting_rbs)

    sequential = build_failed_diagnostics(run(config, workers: 0)).map(&:message)
    pooled = build_failed_diagnostics(run(config, workers: 2)).map(&:message)

    expect(sequential.size).to eq(1)
    expect(pooled).to eq(sequential)
  end

  # Issue #696's structural problem 3. The existing whole-run signature snapshot is gated on
  # `project_signature_paths?`, which would suppress the variant where BOTH colliding declarations are
  # bundled — the `bigdecimal` / `BigMath` shape of #299, which a user cannot fix by editing their own `sig/`
  # and which is exactly the case that most needs naming. Here the collision rides `virtual_rbs:` (ADR-32
  # WD4's plugin-synthesised channel), a real signature source that is not `signature_paths:` at all.
  it "reports a collision between bundled sources, with no signature_paths: in the project" do
    File.write("app.rb", source)
    loader = Rigor::Environment::RbsLoader.new(
      libraries: Rigor::Environment::DEFAULT_LIBRARIES, signature_paths: [], cache_store: nil,
      virtual_rbs: [["rigor://spec/acme.rbs", conflicting_rbs]]
    )
    result = run(config(signature_paths: []), environment: Rigor::Environment.new(rbs_loader: loader))

    diagnostics = build_failed_diagnostics(result)
    expect(diagnostics.size).to eq(1)
    expect(diagnostics.first.message).to include("Acme")
  end
end
