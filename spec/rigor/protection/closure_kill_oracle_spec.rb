# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "rigor/configuration"
require "rigor/language_server/project_context"
require "rigor/protection/closure_kill_oracle"
require "rigor/protection/dependency_closure"
require "rigor/protection/kill_signature"
require "rigor/protection/mutator"

# Ground truth for the closure oracle's cross-check (issue #254): a real analysis of the WHOLE project with the
# mutant on disk, in a throwaway copy of the tree. Independent of everything the closure oracle does — no buffer
# binding, no discovery seed, no prebuilt scan, and no closure — so an agreement between the two is evidence
# about the closure rather than about shared machinery.
class BruteForceMutationOracle
  def initialize(paths:, configuration:, environment:)
    @paths = paths
    @configuration = configuration
    @environment = environment
    @root = Dir.mktmpdir("rigor-brute-force")
    paths.each do |path|
      FileUtils.mkdir_p(File.join(@root, File.dirname(path)))
      FileUtils.cp(path, File.join(@root, path))
    end
    @baseline = signatures
  end

  # The throwaway tree is a whole copy of the fixture project and lives as long as the example that built the
  # oracle, so the example releases it explicitly — there is no block to close (issue #330).
  def discard!
    FileUtils.rm_rf(@root)
  end

  def killed?(mutant_source, path)
    copy = File.join(@root, path)
    original = File.read(copy)
    File.write(copy, mutant_source)
    signatures.any? { |signature| !@baseline.include?(signature) }
  ensure
    File.write(copy, original)
  end

  private

  def signatures
    diagnostics = Dir.chdir(@root) do
      runner = Rigor::Analysis::Runner.new(
        configuration: @configuration, environment: @environment, cache_store: nil, collect_stats: false
      )
      # A plain class, not an example group, so the `GuardedAnalysis` mixin is out of reach here.
      InternalAnalyzerErrorGuard.check!(runner.run(@paths), context: "BruteForceMutationOracle").diagnostics
    end
    Rigor::Protection::KillSignature.signatures_of(diagnostics)
  end
end

# Issue #254 — the ADR-69 Seam 1 oracle that judges a mutant by the whole dependent closure. Drives the real
# analyzer (one shared environment + project scan), so a cross-file kill it claims is one `rigor check` would
# really report.
#
# The fixture is deliberately two files whose kill depends on knowledge that ONLY spans them: mutating the
# argument inside `Account.label` changes what `label` RETURNS, and the only diagnostic that produces lands in
# `service.rb`, on the `upcase` call. The shipped single-file oracle scores exactly this catch as a miss.
RSpec.describe Rigor::Protection::ClosureKillOracle do
  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  def account_source
    <<~RUBY
      class Account
        def self.label
          Account.wrap("account")
        end

        def self.wrap(value)
          value
        end
      end
    RUBY
  end

  def write_fixture
    FileUtils.mkdir_p("lib")
    File.write("lib/account.rb", account_source)
    File.write("lib/service.rb", "def lookup\n  Account.label.upcase\nend\n")
    %w[lib/account.rb lib/service.rb]
  end

  # The mutant the whole file is about: the argument that decides `Account.label`'s return type.
  def mutant_source
    account_source.sub('Account.wrap("account")', "Account.wrap(nil)")
  end

  let(:configuration) { Rigor::Configuration.load(nil) }
  let(:context) { Rigor::LanguageServer::ProjectContext.new(configuration: configuration) }

  # `discovery_seed:` is what `discovery-seeded-mutation-sites` supplies. nil (the default here) is the
  # closure feature adopted ALONE: the mutated file's verdict is then the shipped single-file oracle's,
  # unchanged, and the closure is the only thing this class adds.
  #
  # Issue #572 — this spec used to register every oracle it built in a `built_oracles` side table and release
  # each one in an `after` hook, because the oracle's mutant `Tempfile` was reclaimed only by its finalizer
  # and the issue-#330 residue check runs while the process is still alive. The oracle now unlinks the file
  # inside the method that writes it, so there is nothing left for a call site to forget; the "leaves no
  # mutant file behind" example below is what holds that.
  def oracle_for(paths, dependents:, seeded: false)
    described_class.new(
      configuration: configuration, environment: context.environment, project_scan: context.project_scan,
      paths: paths, dependents: dependents,
      seed_bundles: Rigor::Protection::DiscoverySeed.bundles(paths: paths),
      discovery_seed: seeded ? discovery_seed_for(paths) : nil
    )
  end

  def discovery_seed_for(paths)
    Rigor::Protection::DiscoverySeed.build(
      paths: paths, environment: context.environment, target_ruby: configuration.target_ruby
    )
  end

  def recorded_dependents(paths)
    Rigor::Protection::DependencyClosure.build(
      paths: paths, configuration: configuration, environment: context.environment,
      cache_store: context.cache_store
    )
  end

  it "kills a mutant whose only diagnostic lands in a dependent file" do
    paths = write_fixture
    dependents = recorded_dependents(paths)
    # Non-vacuity: the closure must actually contain the caller, or the kill below would prove nothing.
    expect(dependents.fetch("lib/account.rb")).to eq(["lib/service.rb"])

    oracle = oracle_for(paths, dependents: dependents)
    baseline = oracle.baseline(source: account_source, path: "lib/account.rb")

    # The clean closure is diagnostic-free, so any new report is the mutant's. The two halves stay separate:
    # a diagnostic the dependents' baseline carries must never mask a kill in the mutated file itself.
    expect(baseline.own).to be_empty
    expect(baseline.dependents).to be_empty
    expect(oracle.killed?(mutant_source: mutant_source, path: "lib/account.rb", baseline: baseline)).to be(true)
  end

  # Issue #572 — the mutant file's lifetime must be the call that writes it, not the GC's schedule. The oracle
  # used to keep one `Tempfile` per process, which `Tempfile` reclaims only from its finalizer, so whether the
  # file was still on disk when the suite's issue-#330 residue check ran was a timing coin flip: it came up
  # tails on a CI shard (`spec suite leaked 1 temp entry … rigor-mutant-….rb`) and failed a run whose own
  # rerun of the identical head passed.
  #
  # The first two expectations are the non-vacuity half — an oracle that never bound a mutant file would
  # satisfy "reclaims every mutant file" for free.
  it "leaves no mutant file behind once the kill run returns" do
    paths = write_fixture
    bound = []
    allow(Rigor::Analysis::BufferBinding).to receive(:new).and_wrap_original do |original, **kwargs|
      bound << kwargs[:physical_path]
      original.call(**kwargs)
    end

    oracle = oracle_for(paths, dependents: recorded_dependents(paths))
    baseline = oracle.baseline(source: account_source, path: "lib/account.rb")
    killed = oracle.killed?(mutant_source: mutant_source, path: "lib/account.rb", baseline: baseline)

    mutant_files = bound.grep(/rigor-mutant-/)
    expect(killed).to be(true)
    expect(mutant_files).not_to be_empty
    # `select`, not a boolean: a failure names the file that survived, which is what the CI report needed.
    expect(mutant_files.select { |file| File.exist?(file) }).to eq([])
    expect(Dir.glob(File.join(Dir.tmpdir, "rigor-mutant-*"))).to eq([])
  end

  # The same mutant, same oracle, with the closure narrowed to the mutated file — what the shipped single-file
  # {Rigor::Protection::DiagnosticOracle} sees. It survives, which is the complaint #254 exists to answer: the
  # catch is real, the measurement just was not looking where it landed.
  it "scores the same mutant a survivor when the dependent is not in the closure" do
    paths = write_fixture
    oracle = oracle_for(paths, dependents: { "lib/account.rb" => [], "lib/service.rb" => [] })
    baseline = oracle.baseline(source: account_source, path: "lib/account.rb")

    expect(oracle.killed?(mutant_source: mutant_source, path: "lib/account.rb", baseline: baseline)).to be(false)
  end

  # The acceptance criterion the issue calls the trap: the mutated file is treated as changed everywhere the run
  # reads it, even though its bytes on disk never move. If the substitution reached only the analysis, the
  # dependent would resolve the `def` still on disk, no diagnostic could ever appear outside the mutated file,
  # and the result would be a plausible-looking zero.
  it "never writes the mutant to the measured file, yet the dependent sees it" do
    paths = write_fixture
    before_content = File.read("lib/account.rb")
    before_mtime = File.stat("lib/account.rb").mtime

    oracle = oracle_for(paths, dependents: recorded_dependents(paths))
    baseline = oracle.baseline(source: account_source, path: "lib/account.rb")
    killed = oracle.killed?(mutant_source: mutant_source, path: "lib/account.rb", baseline: baseline)

    expect(killed).to be(true)
    expect(File.read("lib/account.rb")).to eq(before_content)
    expect(File.stat("lib/account.rb").mtime).to eq(before_mtime)
  end

  # The change-detection half in isolation: the per-mutant seed rebuild digests the mutated path THROUGH the
  # binding, so its cached bundle is invalidated and re-walked from the mutant's bytes. The `def` every dependent
  # resolves is therefore the mutated one while the file on disk is untouched.
  it "re-walks the mutated file's discovery bundle from the buffer, not from disk" do
    paths = write_fixture
    bundles = Rigor::Protection::DiscoverySeed.bundles(paths: paths)
    # `Tempfile.create` with a block, not `Tempfile.new`: the latter reclaims only on finalization, so
    # whether the file is still in the private root when `after(:suite)`'s issue #330 residue check runs
    # is a GC-timing coin flip. It came up tails on CI (`leaked 1 temp entry … mutant*.rb`) while every
    # local run and the preceding PRs passed.
    Tempfile.create(["mutant", ".rb"]) do |tmp|
      tmp.write(mutant_source)
      tmp.flush
      buffer = Rigor::Analysis::BufferBinding.new(logical_path: "lib/account.rb", physical_path: tmp.path)

      tables = Rigor::Protection::DiscoverySeed.tables_for_buffer(paths: paths, bundles: bundles, buffer: buffer)

      label = tables.fetch(:discovered_singleton_def_nodes).fetch("Account").fetch(:label)
      expect(label.location.slice).to include("Account.wrap(nil)")
      expect(File.read("lib/account.rb")).to include('Account.wrap("account")')
    end
  end

  # The acceptance criterion that proves the CLOSURE is the right set: for every mutation of every measured file,
  # the closure oracle's verdict must equal what a whole-project re-analysis says — no kill missed (a dependent
  # left out of the closure) and none invented (a diagnostic a real project run would not produce).
  #
  # Both features are adopted here, deliberately. A whole-project re-analysis differs from the shipped
  # single-file oracle on TWO axes: what it knows (the discovery seed — #253/#260) and where a diagnostic may
  # land (the closure — this issue). Comparing an unseeded closure oracle against it measures both at once and
  # reports the knowledge gap as a closure defect: without the seed, renaming `upcase` in the *caller* is a
  # kill the whole-project oracle sees and no per-file oracle can. Seeded, the knowledge axis is equalised and
  # the comparison is about the closure alone.
  it "agrees with a brute-force whole-project oracle on every mutant" do
    write_fixture
    File.write("lib/registry.rb", "class Registry\n  def self.for(name)\n    name.to_s\n  end\nend\n")
    File.write("lib/report.rb", "def render\n  Registry.for(\"x\").size\nend\n")
    paths = %w[lib/account.rb lib/registry.rb lib/report.rb lib/service.rb]

    oracle = oracle_for(paths, dependents: recorded_dependents(paths), seeded: true)
    reference = BruteForceMutationOracle.new(
      paths: paths, configuration: configuration, environment: context.environment
    )

    verdicts = paths.flat_map { |path| verdicts_for(path, oracle, reference) }

    expect(verdicts).not_to be_empty
    expect(verdicts.count { |_, closure, _| closure }).to be >= 1 # non-vacuity: something really is killed
    expect(verdicts.reject { |_, closure, whole| closure == whole }).to eq([])
  ensure
    reference&.discard!
  end

  # One file's `[label, closure verdict, whole-project verdict]` triples. The label carries enough to name a
  # disagreement in the failure output without re-running anything.
  def verdicts_for(path, oracle, reference)
    source = File.read(path)
    baseline = oracle.baseline(source: source, path: path)
    Rigor::Protection::Mutator.new(source).mutations.filter_map do |mutation|
      mutant = mutation.apply(source)
      next unless Prism.parse(mutant).success?

      [[path, mutation.line, mutation.operator, mutation.replacement],
       oracle.killed?(mutant_source: mutant, path: path, baseline: baseline),
       reference.killed?(mutant, path)]
    end
  end
end
