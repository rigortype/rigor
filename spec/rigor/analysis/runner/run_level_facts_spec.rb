# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-116 WD3 (#1195) — every declared run-level fact, across every path that can produce it. Each path used to
# copy the slots by hand, and the copies drifted (#1201: the sequential fallback once took three of the five
# signature-state slots). The paths now read the declarations in {Rigor::Analysis::Runner::RunLevelFacts}, so
# this spec runs the five of them over one fake environment that answers EVERY declared fact with a non-empty
# value, and asserts each fact reaches the same run-level rows on all five:
#
# - sequential (`--workers 0`);
# - the fork pool, whose coordinator harvests off the pre-fork session and whose children drain the rest;
# - the Ractor pool. Its workers build their environment through `Environment.for_project`, which this spec
#   stubs; a stub is an unshareable closure, so every worker dies at construction and the run takes the
#   backend's degrade path (the shape every Ractor run had under rbs 4.x, #414). The coordinator still
#   harvests off its cache-prewarm environment and drains the degrade environment;
# - the degraded fallback (the Ractor backend with no cache store);
# - the empty closure (a narrowed run with nothing to analyse), which analyses no file, so it is held to the
#   fact rows and not to the reporter streams per-file analysis records.
#
# A fact added to the registry without a value here fails the `fetch` below rather than passing vacuously.
RunLevelFactsSpecLoader = Struct.new(:answers) do
  def prewarm = nil
  def deferred_signature_paths = [Pathname("/plugins/rigor-x/sig")]
  def virtual_rbs = answers.fetch(:virtual_rbs)

  %i[signature_standdowns vendored_standdowns synthesized_namespaces quarantined_signatures env_build_failure
     definition_build_failures class_decl_paths signature_paths].each do |name|
    define_method(name) { answers.fetch(name) }
  end
end

# Like the real `Environment#hkt_registry`, the demand is what records a declined HKT directive (#785) on the
# reporter the environment was built with — so a worker drain that snapshots its reporters BEFORE demanding the
# registry loses the row on the pool paths.
RunLevelFactsSpecEnvironment = Struct.new(:rbs_loader, :hkt_scan_failure, :reporter) do
  def hkt_registry
    reporter&.record_hkt_error(message: "uri= is required", path: "sig/a.rbs", line: 3, column: 1)
    nil
  end
end

RSpec.describe Rigor::Analysis::Runner::RunLevelFacts do
  let(:facts) { described_class.facts }

  let(:annotated) { "class Memo\n  %a{pure}\n  def value: () -> Integer\nend\n" }

  let(:conformance) do
    Rigor::RbsExtended::ConformanceChecker::Unsatisfied.new(
      class_name: "Memo", interface_name: "_Comparable", missing_methods: [:<=>], location: nil
    )
  end

  let(:fact_values) do
    {
      signature_standdowns: [["/plugins/rigor-x/sig/memo.rbs", "::Memo", 0, 1, nil]],
      vendored_standdowns: [["prime", [["Integer#prime?", nil, "member"]], false]],
      synthesized_namespaces: ["Acme"],
      quarantined_signatures: [["sig/broken.rbs", 2]],
      env_build_failure: ["RBS::DuplicatedDeclarationError", "dup", ["sig/a.rbs"]],
      conformance_results: [conformance],
      effect_annotation_carrier: [["virtual:synth:memo.rb", annotated]],
      definition_build_failures: [["Acme", "RBS::DuplicatedMethodDefinitionError", "::Acme#label", ["sig/acme.rbs"]]],
      hkt_scan_failure: ["NameError", "simulated scan bug", nil, :scan],
      class_decl_paths: { "Acme" => "sig/acme.rbs" },
      signature_paths: ["sig"]
    }
  end

  let(:environment) do
    loader = RunLevelFactsSpecLoader.new(
      fact_values.except(:effect_annotation_carrier, :hkt_scan_failure, :conformance_results)
                 .merge(virtual_rbs: [["virtual:synth:plain.rb", "class Plain\nend\n"],
                                      ["virtual:synth:memo.rb", annotated]])
    )
    RunLevelFactsSpecEnvironment.new(loader, fact_values.fetch(:hkt_scan_failure))
  end

  let(:registry) do
    instance_double(Rigor::Plugin::Registry, signature_paths: ["/plugins/rigor-x/sig"], blueprints: [],
                                             source_rbs_synthesizers: [], plugins: [], empty?: true)
  end

  # One entry per reporter stream but the hkt-directive one, recorded by every per-file analysis whichever
  # process runs it. The hkt-directive entry comes only from the run's own HKT demand (the fake environment).
  def record_streams(rbs_extended, boundary_cross, source_rbs_synthesis)
    rbs_extended.record_unresolved(payload: "rigor:v1:nope", path: "sig/a.rbs", line: 1, column: 1)
    rbs_extended.record_lossy_projection(head: "pick_of", path: "sig/a.rbs", line: 2, column: 1)
    rbs_extended.record_deprecated_form(payload: "int<5, 10>", replacement: "Integer[5..10]",
                                        path: "sig/a.rbs", line: 4, column: 1)
    boundary_cross.record(class_name: "Acme", method_name: :label, gem_name: "acme", rbs_display: "() -> String")
    source_rbs_synthesis.record(plugin_id: "synth", path: "memo.rb", message: "dropped", kind: :not_honoured)
  end

  # Runs one path and returns `{snapshots:, rows:}`: the store, and each row builder's output.
  def run_path(path, files, project_files) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    reporters = {
      rbs_extended: Rigor::RbsExtended::Reporter.new,
      boundary_cross: Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new,
      source_rbs_synthesis: Rigor::Plugin::SourceRbsSynthesisReporter.new
    }
    snapshots = Rigor::Analysis::Runner::RunSnapshots.new
    environment.reporter = reporters[:rbs_extended]
    configuration = Rigor::Configuration.new("signature_paths" => ["sig"])
    cache_store = path == :ractor ? Rigor::Cache::Store.new(root: File.join(Dir.pwd, ".rigor-cache")) : nil
    coordinator = Rigor::Analysis::Runner::PoolCoordinator.new(
      configuration: configuration, cache_store: cache_store, explain: false,
      workers: %i[fork ractor fallback].include?(path) ? 2 : 0, collect_stats: true, buffer: nil,
      environment_override: nil, rbs_extended_reporter: reporters[:rbs_extended],
      boundary_cross_reporter: reporters[:boundary_cross],
      source_rbs_synthesis_reporter: reporters[:source_rbs_synthesis], snapshots: snapshots,
      plugin_registry: -> { registry },
      dependency_source_index: -> { Rigor::Analysis::DependencySourceInference::Index::EMPTY },
      synthetic_method_index: -> {}, project_patched_methods: -> {},
      analyze_file: lambda do |_path, _environment|
        record_streams(reporters[:rbs_extended], reporters[:boundary_cross], reporters[:source_rbs_synthesis])
        []
      end
    )
    coordinator.analyze_files(files, environment: path == :sequential ? environment : nil,
                                     project_files: project_files)
    aggregator = Rigor::Analysis::Runner::DiagnosticAggregator.new(
      configuration: configuration, rbs_extended_reporter: reporters[:rbs_extended],
      boundary_cross_reporter: reporters[:boundary_cross],
      source_rbs_synthesis_reporter: reporters[:source_rbs_synthesis],
      plugin_registry: -> { registry }, dependency_source_index: -> {}, pool_mode: -> { false },
      cached_plugin_prepare_diagnostics: -> { [] }, pre_eval_diagnostics_from_scanner: -> { [] },
      snapshots: snapshots, pooled_run_disclosures: -> { coordinator.collected_run_disclosures }
    )
    rows = described_class.row_builders.to_h { |builder| [builder, aggregator.public_send(builder).map(&:to_h)] }
    { snapshots: snapshots, rows: rows }
  end

  def with_backend(backend)
    original = ENV.fetch("RIGOR_POOL_BACKEND", nil)
    backend ? ENV["RIGOR_POOL_BACKEND"] = backend : ENV.delete("RIGOR_POOL_BACKEND")
    yield
  ensure
    original.nil? ? ENV.delete("RIGOR_POOL_BACKEND") : (ENV["RIGOR_POOL_BACKEND"] = original)
  end

  def stub_pool_environment
    allow(Rigor::Environment).to receive(:for_project).and_return(environment)
    allow(Rigor::RbsExtended::ConformanceChecker).to receive(:scan)
      .and_return(fact_values.fetch(:conformance_results))
    allow(Rigor::Analysis::WorkerSession).to receive(:new).and_wrap_original do |original, **options|
      session = original.call(**options)
      environment.reporter = session.rbs_extended_reporter
      allow(session).to receive(:analyze) do
        record_streams(*%i[@rbs_extended_reporter @boundary_cross_reporter @source_rbs_synthesis_reporter]
                         .map { |ivar| session.instance_variable_get(ivar) })
        []
      end
      session
    end
  end

  it "reports every declared fact's rows identically on the sequential, fork, Ractor, fallback and " \
     "empty-closure paths" do # rubocop:disable RSpec/ExampleLength
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        files = %w[a.rb b.rb c.rb].each { |name| File.write(name, "x = 1\n") }
        stub_pool_environment

        runs = {
          sequential: with_backend(nil) { run_path(:sequential, files, files) },
          fork: with_backend("fork") { run_path(:fork, files, files) },
          ractor: with_backend("ractor") { run_path(:ractor, files, files) },
          fallback: with_backend("ractor") { run_path(:fallback, files, files) },
          empty_closure: with_backend(nil) { run_path(:empty_closure, [], files) }
        }

        facts.each do |fact|
          expected = fact_values.fetch(fact.name)
          runs.each do |path, run|
            next if fact.source == :stats && path == :empty_closure

            expect([path, fact.name, run[:snapshots][fact.name]]).to eq([path, fact.name, expected])
            next unless fact.row

            expect([path, fact.name, run[:rows].fetch(fact.row)])
              .to eq([path, fact.name, runs[:sequential][:rows].fetch(fact.row)])
          end
          expect(runs[:sequential][:rows].fetch(fact.row)).not_to be_empty if fact.row
        end

        stream_rows = described_class.row_builders - facts.filter_map(&:row) -
                      %i[plugin_run_disclosure_diagnostics plugin_trust_refusal_diagnostics]
        stream_rows.each do |builder|
          expect(runs[:sequential][:rows].fetch(builder)).not_to be_empty
          runs.except(:empty_closure).each do |path, run|
            expect([path, builder, run[:rows].fetch(builder)])
              .to eq([path, builder, runs[:sequential][:rows].fetch(builder)])
          end
        end
      end
    end
  end

  # #2405 — the example above reaches the Ractor degrade only when the workers die; whether they die BEFORE
  # the coordinator dispatches is a race, and `Ractor#send` to a worker that already died raises
  # `Ractor::ClosedError`. Every worker is held until it has died here, so the dead-before-send ordering
  # happens on every run, for the first, middle and last send and for the closing `nil` of every worker.
  it "degrades to the sequential rows when every Ractor worker died before dispatch" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        files = %w[a.rb b.rb c.rb].each { |name| File.write(name, "x = 1\n") }
        stub_pool_environment
        dead_before_dispatch = []
        allow(Ractor).to receive(:new).and_wrap_original do |original, *args, &block|
          worker = original.call(*args, &block)
          begin
            worker.join
          rescue Ractor::Error
            nil
          end
          dead_before_dispatch << worker
          worker
        end

        sequential = with_backend(nil) { run_path(:sequential, files, files) }
        ractor = with_backend("ractor") { run_path(:ractor, files, files) }

        expect(dead_before_dispatch.size).to eq(2)
        dead_before_dispatch.each { |worker| expect { worker.send(:probe) }.to raise_error(Ractor::ClosedError) }
        expect(ractor[:rows]).to eq(sequential[:rows])
        facts.each { |fact| expect(ractor[:snapshots][fact.name]).to eq(fact_values.fetch(fact.name)) }
      end
    end
  end

  describe ".row_builders" do
    it "orders the rows by declared position, the rbs.coverage ladder widest consequence first" do
      expect(described_class.row_builders).to eq(
        %i[rbs_quarantined_signature_diagnostics rbs_environment_build_failed_diagnostics
           rbs_definition_build_failed_diagnostics rbs_hkt_scan_failed_diagnostics
           rbs_synthesized_namespace_diagnostics rbs_plugin_signature_stood_down_diagnostics
           rbs_vendored_signature_stood_down_diagnostics conforms_to_diagnostics
           unresolved_payload_diagnostics lossy_projection_diagnostics hkt_directive_diagnostics
           deprecated_form_diagnostics boundary_cross_diagnostics source_rbs_synthesis_diagnostics
           plugin_run_disclosure_diagnostics plugin_trust_refusal_diagnostics]
      )
    end
  end

  describe ".harvest" do
    # The quarantine derivation reads the BUILT env, so the env-forcing reads come first, and the
    # conformance scan — which demands definitions the `:analysis` drain then reads — comes last.
    it "collects the :environment facts in declaration order" do
      read = []
      context = described_class::Context.new(project_signature_paths: true, plugin_signature_paths: true,
                                             record_effects: false)
      facts.select { |fact| fact.source == :environment }.each do |fact|
        allow(described_class::Collect).to receive(fact.name) { read << fact.name }
      end

      described_class.harvest(:environment, context) { nil }

      expect(read).to eq(%i[signature_standdowns vendored_standdowns synthesized_namespaces
                            quarantined_signatures env_build_failure conformance_results
                            effect_annotation_carrier])
    end
  end

  describe ".drain" do
    it "drains only the non-demanding facts when asked not to demand, so no HKT build is forced" do
      demanded = false
      environment = instance_double(Rigor::Environment, rbs_loader: nil)
      allow(environment).to receive(:hkt_registry) { demanded = true }

      expect(described_class.drain(environment, demanding: false)).to eq(definition_build_failures: [])
      expect(demanded).to be(false)
    end
  end

  describe Rigor::Analysis::Runner::RunSnapshots do
    it "folds a value in by its fact's merge rule" do
      snapshots = described_class.new
      first = ["NameError", "first", nil, :scan]

      snapshots.absorb(hkt_scan_failure: first, quarantined_signatures: [["a.rbs", 1]])
      snapshots.absorb(hkt_scan_failure: ["NameError", "second", nil, :scan], quarantined_signatures: [])

      expect(snapshots.hkt_scan_failure).to eq(first)
      expect(snapshots.quarantined_signatures).to eq([])
    end

    it "rejects a key no fact declares" do
      expect { described_class.new.absorb(undeclared: 1) }.to raise_error(KeyError)
    end
  end

  describe Rigor::Cache::IncrementalSnapshot::RunLevelRows do
    it "carries exactly the facts declared replayable" do
      expect(described_class.members).to eq(%i[definition_build_failures hkt_scan_failure])
    end
  end
end
