# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Issue #135 self-mutation sweep — the giant >300 LOC engine-file tier. `PoolCoordinator` (561 LOC) had NO
# convention spec at all before this file, so this is authorship, not a gap-fill: the examples below exist
# to pin the class's own promises before the mutation pass ever ran, then close what it found.
#
# What the class promises (mirrors the file's own header comment):
#
# - `#analyze_files` routes to exactly one of two dispatch paths — the sequential coordinator-side
#   Environment (default), or `#dispatch_pool` (opt-in via `workers:`) — and an empty file list short-circuits
#   before either.
# - `#dispatch_pool` picks among three concrete backends (Ractor pool, fork pool, in-process sequential
#   fallback) based on `record_dependencies:`, `pool_backend` (env override / fork availability), and platform
#   fork support — never silently drops a file.
# - Per-worker reporter drains (`RbsExtended::Reporter`, `BoundaryCrossReporter`, `SourceRbsSynthesisReporter`)
#   replay into the coordinator's OWN accumulators via their dedupe-on-record `#record*` APIs, so pooled and
#   sequential runs leave the same reporter state.
# - The fork-pool child-process contract: a payload written to disk, `Marshal`-loaded back on the parent, a
#   non-zero exit or unreadable payload degrades that child's slice to an in-process re-analysis rather than
#   losing it.
#
# End-to-end pool ⇄ sequential diagnostic-stream EQUIVALENCE (the property that matters most operationally)
# is already exhaustively covered through the public `Runner` API by `runner_fork_pool_spec.rb` and
# `runner_pool_spec.rb` — this file does NOT re-derive that here. Instead it drives `PoolCoordinator` directly
# (it is built for exactly this: every piece of per-run state arrives through an injected reader proc or
# callable), so each routing decision and each collaborator boundary is pinned without paying for a full
# `Environment` build per example.
#
# Fork-pool safety: every example that forks reaps its own child via `Process.waitpid2` (either directly, or
# through `#collect_fork_results`, which the production code already calls unconditionally on every child pid
# before returning) — never a background thread, and never left running past the example. `fork` copies only
# the calling thread, so nothing here arms work off-thread before forking.
RSpec.describe Rigor::Analysis::Runner::PoolCoordinator do
  # Every reader defaults to an inert value; a test overrides only the collaborator its example actually
  # exercises. Mirrors `diagnostic_aggregator_spec.rb`'s `build_aggregator` helper (same subtree, same
  # sweep) — real accumulator instances rather than doubles, so a merge test that reads its target reporter
  # back also proves the reporter's own contract.
  def build_coordinator( # rubocop:disable Metrics/ParameterLists
    configuration: Rigor::Configuration.new(Rigor::Configuration::DEFAULTS),
    cache_store: nil,
    explain: false,
    workers: 0,
    collect_stats: false,
    buffer: nil,
    environment_override: nil,
    rbs_extended_reporter: Rigor::RbsExtended::Reporter.new,
    boundary_cross_reporter: Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new,
    source_rbs_synthesis_reporter: Rigor::Plugin::SourceRbsSynthesisReporter.new,
    snapshots: Rigor::Analysis::Runner::RunSnapshots.new,
    plugin_registry: Rigor::Plugin::Registry::EMPTY,
    dependency_source_index: Rigor::Analysis::DependencySourceInference::Index::EMPTY,
    synthetic_method_index: nil,
    project_patched_methods: nil,
    project_scope_seed: {},
    analyze_file: ->(_path, _environment) { [] },
    record_dependencies: false
  )
    described_class.new(
      configuration: configuration, cache_store: cache_store, explain: explain, workers: workers,
      collect_stats: collect_stats, buffer: buffer, environment_override: environment_override,
      rbs_extended_reporter: rbs_extended_reporter, boundary_cross_reporter: boundary_cross_reporter,
      source_rbs_synthesis_reporter: source_rbs_synthesis_reporter, snapshots: snapshots,
      plugin_registry: -> { plugin_registry }, dependency_source_index: -> { dependency_source_index },
      synthetic_method_index: -> { synthetic_method_index },
      project_patched_methods: -> { project_patched_methods },
      project_scope_seed: -> { project_scope_seed }, analyze_file: analyze_file,
      record_dependencies: record_dependencies
    )
  end

  describe "#pool_mode?" do
    it "is false when workers is nil (the sequential default)" do
      expect(build_coordinator(workers: nil).pool_mode?).to be(false)
    end

    it "is false when workers is zero" do
      expect(build_coordinator(workers: 0).pool_mode?).to be(false)
    end

    it "is false when workers is negative" do
      expect(build_coordinator(workers: -1).pool_mode?).to be(false)
    end

    it "is true when workers is a positive Integer and no buffer is bound" do
      expect(build_coordinator(workers: 2).pool_mode?).to be(true)
    end

    it "is false when a buffer is bound, even with a positive worker count (editor mode overrides pool mode)" do
      buffer = instance_double(Rigor::Analysis::BufferBinding)
      expect(build_coordinator(workers: 4, buffer: buffer).pool_mode?).to be(false)
    end
  end

  describe "#analyze_files" do
    it "returns an empty Array without touching either dispatch path when files is empty" do
      coordinator = build_coordinator(workers: 4)
      allow(coordinator).to receive(:dispatch_pool)
      allow(coordinator).to receive(:analyze_files_sequentially)

      expect(coordinator.analyze_files([])).to eq([])
      expect(coordinator).not_to have_received(:dispatch_pool)
      expect(coordinator).not_to have_received(:analyze_files_sequentially)
    end

    it "routes to the pool dispatcher when pool_mode? is true" do
      coordinator = build_coordinator(workers: 2)
      allow(coordinator).to receive(:dispatch_pool).and_return([:pool_result])

      expect(coordinator.analyze_files(["a.rb"])).to eq([:pool_result])
      expect(coordinator).to have_received(:dispatch_pool).with(["a.rb"])
    end

    it "routes to the sequential path with the caller-supplied environment when pool mode is off" do
      coordinator = build_coordinator(workers: 0)
      environment = instance_double(Rigor::Environment)
      allow(coordinator).to receive(:analyze_files_sequentially).and_return([:seq_result])

      expect(coordinator.analyze_files(["a.rb"], environment: environment)).to eq([:seq_result])
      expect(coordinator).to have_received(:analyze_files_sequentially).with(["a.rb"], environment)
    end

    it "resolves a fresh sequential environment when the caller supplies none" do
      coordinator = build_coordinator(workers: 0)
      resolved = instance_double(Rigor::Environment)
      allow(coordinator).to receive_messages(resolve_sequential_environment: resolved, analyze_files_sequentially: [])

      coordinator.analyze_files(["a.rb"])

      expect(coordinator).to have_received(:resolve_sequential_environment).with(source_files: ["a.rb"])
      expect(coordinator).to have_received(:analyze_files_sequentially).with(["a.rb"], resolved)
    end
  end

  describe "#analyze_files_sequentially" do
    it "flat_maps the injected analyze_file callable over every path, in order, and returns their diagnostics" do
      calls = []
      analyze_file = lambda do |path, environment|
        calls << [path, environment]
        [Rigor::Analysis::Diagnostic.new(path: path, line: 1, column: 1, message: "m", severity: :info, rule: "r")]
      end
      coordinator = build_coordinator(analyze_file: analyze_file)
      environment = instance_double(Rigor::Environment, rbs_loader: nil)

      result = coordinator.analyze_files_sequentially(%w[a.rb b.rb], environment)

      expect(result.map(&:path)).to eq(%w[a.rb b.rb])
      expect(calls).to eq([["a.rb", environment], ["b.rb", environment]])
    end

    it "snapshots class_decl_paths and signature_paths off the environment's loader when collect_stats is true" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(collect_stats: true, snapshots: snapshots)
      loader = instance_double(
        Rigor::Environment::RbsLoader, class_decl_paths: { "Foo" => "foo.rbs" }, signature_paths: ["sig"],
                                       virtual_rbs: [], definition_build_failures: []
      )
      environment = instance_double(Rigor::Environment, rbs_loader: loader)

      coordinator.analyze_files_sequentially(["a.rb"], environment)

      expect(snapshots.class_decl_paths).to eq({ "Foo" => "foo.rbs" })
      expect(snapshots.signature_paths).to eq(["sig"])
    end

    it "leaves the class-universe snapshot at its constructor default when collect_stats is false" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(collect_stats: false, snapshots: snapshots)
      # A loader that WOULD supply different values, so the assertion below fails if collect_stats stops
      # gating the read.
      loader = instance_double(
        Rigor::Environment::RbsLoader, class_decl_paths: { "Foo" => "foo.rbs" }, signature_paths: ["sig"],
                                       virtual_rbs: [], definition_build_failures: []
      )
      environment = instance_double(Rigor::Environment, rbs_loader: loader)

      coordinator.analyze_files_sequentially(["a.rb"], environment)

      expect(snapshots.class_decl_paths).to eq({})
      expect(snapshots.signature_paths).to eq([].freeze)
    end

    # #441 — the environment stays a LOCAL here (it must go GC-eligible when the path returns), so the one
    # thing the run needs from it afterwards is carried out as data: the FIRST virtual buffer carrying an
    # effect annotation, which is what `effect.annotations-unchecked` reports for the rbs-inline lane.
    # Reduced to one entry on purpose — a one-`:info`-per-run pass cannot spend a whole virtual tree.
    it "carries the first effect-annotated virtual buffer out of the sequential path" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(snapshots: snapshots)
      loader = instance_double(
        Rigor::Environment::RbsLoader,
        virtual_rbs: [["virtual:x:plain.rb", "class Plain\nend\n"],
                      ["virtual:x:memo.rb", "class Memo\n  %a{pure}\n  def value: () -> Integer\nend\n"],
                      ["virtual:x:other.rb", "class Other\n  %a{pure}\nend\n"]],
        definition_build_failures: []
      )

      coordinator.analyze_files_sequentially(["a.rb"], instance_double(Rigor::Environment, rbs_loader: loader))

      expect(snapshots.effect_annotation_carrier.map(&:first)).to eq(["virtual:x:memo.rb"])
    end

    # Collection ON is the envelope pass's lane, and it reads the loader directly — so the walk here is
    # skipped rather than duplicated, and a collecting run pays nothing for a diagnostic it cannot emit.
    it "carries nothing when effect collection is on" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(
        configuration: Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("effects" => {})),
        snapshots: snapshots
      )
      loader = instance_double(Rigor::Environment::RbsLoader, definition_build_failures: [])

      coordinator.analyze_files_sequentially(["a.rb"], instance_double(Rigor::Environment, rbs_loader: loader))

      expect(snapshots.effect_annotation_carrier).to eq([])
    end

    # Issue #696 — the timing contract. Definition builds are LAZY (ADR-54 WD1: per class, on first demand),
    # so the class that fails is not known until the per-file loop has run. A snapshot taken beside the
    # signature-state ones, which fire BEFORE `files.flat_map`, would read empty on every run — including
    # every run this diagnostic exists for. The `analyze_file` callable below is what makes the loader answer
    # at all, so an implementation that read the loader too early gets `[]` and this fails.
    it "records definition-build failures only after the per-file loop has run (they are lazy)" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      failure = ["Acme", "RBS::DuplicatedMethodDefinitionError", "::Acme#label has duplicated definitions",
                 ["sig/acme.rbs"]]
      observed = []
      loader = instance_double(Rigor::Environment::RbsLoader, virtual_rbs: [])
      allow(loader).to receive(:definition_build_failures) { observed.dup }
      analyze_file = lambda do |_path, _environment|
        observed << failure
        []
      end
      coordinator = build_coordinator(snapshots: snapshots, analyze_file: analyze_file)

      coordinator.analyze_files_sequentially(["a.rb"], instance_double(Rigor::Environment, rbs_loader: loader))

      expect(snapshots.definition_build_failures).to eq([failure])
    end

    # The must-still-succeed twin: a healthy loader leaves the slot at its inert default, so the diagnostic
    # cannot fire on a project with nothing wrong.
    it "leaves the slot empty when every definition built" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(snapshots: snapshots)
      loader = instance_double(Rigor::Environment::RbsLoader, virtual_rbs: [], definition_build_failures: [])

      coordinator.analyze_files_sequentially(["a.rb"], instance_double(Rigor::Environment, rbs_loader: loader))

      expect(snapshots.definition_build_failures).to eq([])
    end
  end

  # Issue #696 review, F5 — the no-fork fallback is a THIRD analysis path, alongside sequential and the
  # pool, and it analyses on the coordinator's own loader. It already snapshots the two sibling signature
  # conditions; missing this one made a run that degraded to sequential (no `fork` — Windows; and
  # `--incremental` / effects runs without it) report `pool-degraded` and nothing else, where a plain
  # sequential run reported the failure. "Reports less depending on how you ran it", one costume further on.
  describe "#analyze_files_sequentially_fallback" do
    it "snapshots definition-build failures off the coordinator's own loader" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      failure = ["Acme", "RBS::DuplicatedMethodDefinitionError", "::Acme#label", ["sig/acme.rbs"]]
      loader = instance_double(
        Rigor::Environment::RbsLoader, class_decl_paths: {}, signature_paths: [], virtual_rbs: [],
                                       quarantined_signatures: [], env_build_failure: nil,
                                       definition_build_failures: [failure]
      )
      coordinator = build_coordinator(snapshots: snapshots, analyze_file: ->(_path, _env) { [] })
      allow(coordinator).to receive(:build_runner_environment)
        .and_return(instance_double(Rigor::Environment, rbs_loader: loader))

      coordinator.send(:analyze_files_sequentially_fallback, ["a.rb"], reason: "no fork")

      expect(snapshots.definition_build_failures).to eq([failure])
    end

    # The must-still-succeed twin, and the non-vacuity check for the example above: the same path on a
    # healthy loader leaves the slot inert and still degrades loudly.
    it "leaves the slot empty on a healthy loader, and still reports the degrade" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      loader = instance_double(
        Rigor::Environment::RbsLoader, class_decl_paths: {}, signature_paths: [], virtual_rbs: [],
                                       quarantined_signatures: [], env_build_failure: nil,
                                       definition_build_failures: []
      )
      coordinator = build_coordinator(snapshots: snapshots, analyze_file: ->(_path, _env) { [] })
      allow(coordinator).to receive(:build_runner_environment)
        .and_return(instance_double(Rigor::Environment, rbs_loader: loader))

      diagnostics = coordinator.send(:analyze_files_sequentially_fallback, ["a.rb"], reason: "no fork")

      expect(snapshots.definition_build_failures).to eq([])
      expect(diagnostics.map(&:rule)).to eq(["pool-degraded"])
    end
  end

  describe "#snapshot_project_signature_state" do
    it "resets every signature-state snapshot to its inert default when the project declares no signature_paths" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      snapshots.synthesized_namespaces = ["stale"]
      snapshots.quarantined_signatures = ["stale"]
      snapshots.conformance_results = ["stale"]
      snapshots.env_build_failure = [StandardError, 1, []]
      coordinator = build_coordinator(snapshots: snapshots)
      # Never touched: the no-signature_paths branch returns before reading the loader at all.
      environment = instance_double(Rigor::Environment)

      coordinator.snapshot_project_signature_state(environment)

      expect(snapshots.synthesized_namespaces).to eq([])
      expect(snapshots.quarantined_signatures).to eq([])
      expect(snapshots.conformance_results).to eq([])
      expect(snapshots.env_build_failure).to be_nil
    end

    it "reads namespaces, quarantines, the env-build failure, and the conformance scan off the loader " \
       "when the project DOES declare signature_paths" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      configuration = Rigor::Configuration.new("signature_paths" => ["sig"])
      coordinator = build_coordinator(configuration: configuration, snapshots: snapshots)
      loader = instance_double(
        Rigor::Environment::RbsLoader,
        synthesized_namespaces: ["Foo::Bar"],
        quarantined_signatures: ["bad.rbs"],
        env_build_failure: [StandardError, 3, ["buf"]]
      )
      environment = instance_double(Rigor::Environment, rbs_loader: loader)
      allow(Rigor::RbsExtended::ConformanceChecker).to receive(:scan).with(loader).and_return([:conformance_hit])

      coordinator.snapshot_project_signature_state(environment)

      expect(snapshots.synthesized_namespaces).to eq(["Foo::Bar"])
      expect(snapshots.quarantined_signatures).to eq(["bad.rbs"])
      expect(snapshots.env_build_failure).to eq([StandardError, 3, ["buf"]])
      expect(snapshots.conformance_results).to eq([:conformance_hit])
    end
  end

  describe "#resolve_sequential_environment" do
    it "builds a fresh Environment via #build_runner_environment when no override was configured" do
      coordinator = build_coordinator(environment_override: nil)
      built = instance_double(Rigor::Environment)
      allow(coordinator).to receive(:build_runner_environment).with(source_files: ["a.rb"]).and_return(built)

      expect(coordinator.resolve_sequential_environment(source_files: ["a.rb"])).to equal(built)
    end

    it "reattaches THIS run's reporters to a supplied override and returns it unchanged" do
      rbs_reporter = Rigor::RbsExtended::Reporter.new
      boundary_reporter = Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new
      override = instance_double(Rigor::Environment)
      allow(override).to receive(:attach_reporters!)
      coordinator = build_coordinator(
        environment_override: override, rbs_extended_reporter: rbs_reporter,
        boundary_cross_reporter: boundary_reporter
      )

      expect(coordinator.resolve_sequential_environment).to equal(override)
      expect(override).to have_received(:attach_reporters!).with(
        rbs_extended_reporter: rbs_reporter, boundary_cross_reporter: boundary_reporter
      )
    end
  end

  describe "#pool_backend" do
    around do |example|
      original = ENV.fetch("RIGOR_POOL_BACKEND", nil)
      example.run
    ensure
      original.nil? ? ENV.delete("RIGOR_POOL_BACKEND") : (ENV["RIGOR_POOL_BACKEND"] = original)
    end

    it "selects :ractor when RIGOR_POOL_BACKEND=ractor, regardless of fork availability" do
      ENV["RIGOR_POOL_BACKEND"] = "ractor"

      expect(build_coordinator.pool_backend).to eq(:ractor)
    end

    it "selects :fork when fork is available and no backend override is set" do
      ENV.delete("RIGOR_POOL_BACKEND")

      expect(build_coordinator.pool_backend).to eq(:fork)
    end

    it "falls back to :sequential when fork is unavailable (e.g. Windows) and no override is set" do
      ENV.delete("RIGOR_POOL_BACKEND")
      allow(Process).to receive(:respond_to?).and_call_original
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)

      expect(build_coordinator.pool_backend).to eq(:sequential)
    end
  end

  describe "#dispatch_pool" do
    it "routes a recording run to the fork pool when fork is available" do
      coordinator = build_coordinator(record_dependencies: true)
      allow(coordinator).to receive(:analyze_files_in_fork_pool).and_return([:fork_result])

      expect(coordinator.dispatch_pool(["a.rb"])).to eq([:fork_result])
      expect(coordinator).to have_received(:analyze_files_in_fork_pool).with(["a.rb"])
    end

    it "degrades a recording run to sequential when fork is unavailable, " \
       "since only the fork path marshals dependency records back" do
      coordinator = build_coordinator(record_dependencies: true)
      allow(Process).to receive(:respond_to?).and_call_original
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)
      allow(coordinator).to receive(:analyze_files_sequentially_fallback).and_return([:seq_result])

      expect(coordinator.dispatch_pool(["a.rb"])).to eq([:seq_result])
      expect(coordinator).to have_received(:analyze_files_sequentially_fallback).with(
        ["a.rb"], reason: a_string_matching(/incremental parallelism requires fork/)
      )
    end

    it "routes to the Ractor pool when pool_backend resolves to :ractor" do
      coordinator = build_coordinator
      allow(coordinator).to receive_messages(pool_backend: :ractor, analyze_files_in_pool: [:ractor_result])

      expect(coordinator.dispatch_pool(["a.rb"])).to eq([:ractor_result])
      expect(coordinator).to have_received(:analyze_files_in_pool).with(["a.rb"])
    end

    it "routes to the fork pool when pool_backend resolves to :fork" do
      coordinator = build_coordinator
      allow(coordinator).to receive_messages(pool_backend: :fork, analyze_files_in_fork_pool: [:fork_result])

      expect(coordinator.dispatch_pool(["a.rb"])).to eq([:fork_result])
      expect(coordinator).to have_received(:analyze_files_in_fork_pool).with(["a.rb"])
    end

    it "degrades to sequential when pool_backend resolves to :sequential (no fork-capable backend)" do
      coordinator = build_coordinator
      allow(coordinator).to receive_messages(pool_backend: :sequential,
                                             analyze_files_sequentially_fallback: [:seq_result])

      expect(coordinator.dispatch_pool(["a.rb"])).to eq([:seq_result])
      expect(coordinator).to have_received(:analyze_files_sequentially_fallback).with(
        ["a.rb"], reason: a_string_matching(/fork-based parallelism is unavailable/)
      )
    end
  end

  describe "#collected_dependencies" do
    it "starts empty before any pooled recording run" do
      expect(build_coordinator.collected_dependencies).to eq({})
    end
  end

  describe "#merge_worker_reporters" do
    it "replays a worker's unresolved rbs_extended payloads and lossy projections into the run's own reporter" do
      worker_reporter = Rigor::RbsExtended::Reporter.new
      worker_reporter.record_unresolved(payload: "rigor:v1:foo")
      worker_reporter.record_lossy_projection(head: "pick_of")
      coordinator_reporter = Rigor::RbsExtended::Reporter.new
      coordinator = build_coordinator(rbs_extended_reporter: coordinator_reporter)

      coordinator.merge_worker_reporters(
        rbs_extended: { unresolved_payloads: worker_reporter.unresolved_payloads,
                        lossy_projections: worker_reporter.lossy_projections },
        boundary_cross: [], source_rbs_synthesis: []
      )

      expect(coordinator_reporter.unresolved_payloads.map(&:payload)).to eq(["rigor:v1:foo"])
      expect(coordinator_reporter.lossy_projections.map(&:head)).to eq(["pick_of"])
    end

    it "replays a worker's boundary-cross events into the run's own reporter" do
      worker_reporter = Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new
      worker_reporter.record(class_name: "Foo", method_name: :bar, gem_name: "somegem", rbs_display: "() -> void")
      coordinator_reporter = Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new
      coordinator = build_coordinator(boundary_cross_reporter: coordinator_reporter)

      coordinator.merge_worker_reporters(
        rbs_extended: { unresolved_payloads: [], lossy_projections: [] },
        boundary_cross: worker_reporter.entries, source_rbs_synthesis: []
      )

      expect(coordinator_reporter.entries.map(&:class_name)).to eq(["Foo"])
    end

    it "replays a worker's source-rbs-synthesis failures into the run's own reporter" do
      worker_reporter = Rigor::Plugin::SourceRbsSynthesisReporter.new
      worker_reporter.record(plugin_id: "rigor-x", path: "a.rb", message: "boom")
      coordinator_reporter = Rigor::Plugin::SourceRbsSynthesisReporter.new
      coordinator = build_coordinator(source_rbs_synthesis_reporter: coordinator_reporter)

      coordinator.merge_worker_reporters(
        rbs_extended: { unresolved_payloads: [], lossy_projections: [] },
        boundary_cross: [], source_rbs_synthesis: worker_reporter.entries
      )

      expect(coordinator_reporter.entries.map(&:plugin_id)).to eq(["rigor-x"])
    end

    # Mutant: dropping the `Array(...)` around `drained[:source_rbs_synthesis]` turns a missing key into a
    # `NoMethodError` (`nil.each`) instead of treating it as empty. A drain hash that omits the key (any
    # pre-ADR-32-WD6 producer, or simply a drain with nothing to report) must still merge cleanly.
    it "tolerates a drain hash with no source_rbs_synthesis key" do
      coordinator = build_coordinator

      expect do
        coordinator.merge_worker_reporters(
          rbs_extended: { unresolved_payloads: [], lossy_projections: [] }, boundary_cross: []
        )
      end.not_to raise_error
    end
  end

  describe "#fork_worker_payload (private)" do
    it "marshal-loads the child's payload when the process exited successfully and the file exists" do
      coordinator = build_coordinator
      Dir.mktmpdir do |dir|
        out_path = File.join(dir, "payload")
        payload = { results: { "a.rb" => [] }, reporters: {} }
        File.binwrite(out_path, Marshal.dump(payload))
        status = instance_double(Process::Status, success?: true)

        expect(coordinator.send(:fork_worker_payload, status, out_path)).to eq(payload)
      end
    end

    it "returns nil when the child process exited abnormally" do
      coordinator = build_coordinator
      Dir.mktmpdir do |dir|
        out_path = File.join(dir, "payload")
        File.binwrite(out_path, Marshal.dump({ results: {}, reporters: {} }))
        status = instance_double(Process::Status, success?: false)

        expect(coordinator.send(:fork_worker_payload, status, out_path)).to be_nil
      end
    end

    it "returns nil when the child exited successfully but wrote no payload file" do
      coordinator = build_coordinator
      Dir.mktmpdir do |dir|
        status = instance_double(Process::Status, success?: true)

        expect(coordinator.send(:fork_worker_payload, status, File.join(dir, "missing"))).to be_nil
      end
    end

    it "returns nil for a corrupted (unmarshalable) payload file rather than raising" do
      coordinator = build_coordinator
      Dir.mktmpdir do |dir|
        out_path = File.join(dir, "payload")
        File.binwrite(out_path, "not a marshal blob")
        status = instance_double(Process::Status, success?: true)

        expect(coordinator.send(:fork_worker_payload, status, out_path)).to be_nil
      end
    end
  end

  # Real `fork`s, so `Process.waitpid2` (called by `#collect_fork_results` itself, on every child, before it
  # returns) observes real exit statuses — the fastest faithful way to drive this branch without duplicating
  # the whole `analyze_files_in_fork_pool` happy path. Every child mirrors `#run_fork_worker`'s own
  # rescue/`exit!` shape so a write failure can never leave it running past its own body, and no child outlives
  # the example: `collect_fork_results` reaps every pid it is given.
  describe "#collect_fork_results (private)" do
    def spawn_child(out_path:, payload: nil, exit_code: 0)
      fork do
        File.binwrite(out_path, Marshal.dump(payload)) if payload
        exit!(exit_code)
      rescue StandardError
        exit!(1)
      end
    end

    def empty_reporters_payload(results:, dependencies: {})
      { results: results,
        reporters: { rbs_extended: { unresolved_payloads: [], lossy_projections: [] },
                     boundary_cross: [], source_rbs_synthesis: [] },
        dependencies: dependencies }
    end

    it "merges a successful child's results into results_by_path and reports no degraded slice" do
      Dir.mktmpdir do |dir|
        coordinator = build_coordinator
        out_path = File.join(dir, "worker-0")
        pid = spawn_child(out_path: out_path, payload: empty_reporters_payload(results: { "a.rb" => [] }))
        results_by_path = {}

        degraded = coordinator.send(
          :collect_fork_results, [{ pid: pid, slice: ["a.rb"], out_path: out_path }], results_by_path
        )

        expect(degraded).to eq([])
        expect(results_by_path).to eq({ "a.rb" => [] })
      end
    end

    it "reports a crashed child's whole slice as degraded and leaves it out of results_by_path" do
      Dir.mktmpdir do |dir|
        coordinator = build_coordinator
        out_path = File.join(dir, "worker-0")
        pid = spawn_child(out_path: out_path, exit_code: 1)
        results_by_path = {}

        degraded = coordinator.send(
          :collect_fork_results, [{ pid: pid, slice: ["broken.rb"], out_path: out_path }], results_by_path
        )

        expect(degraded).to eq(["broken.rb"])
        expect(results_by_path).to eq({})
      end
    end

    it "folds a recording run's per-child dependency payload into #collected_dependencies" do
      Dir.mktmpdir do |dir|
        coordinator = build_coordinator(record_dependencies: true)
        out_path = File.join(dir, "worker-0")
        payload = empty_reporters_payload(results: { "a.rb" => [] }, dependencies: { "a.rb" => :fake_record })
        pid = spawn_child(out_path: out_path, payload: payload)

        coordinator.send(:collect_fork_results, [{ pid: pid, slice: ["a.rb"], out_path: out_path }], {})

        expect(coordinator.collected_dependencies).to eq({ "a.rb" => :fake_record })
      end
    end

    it "does NOT fold dependencies when record_dependencies is false, even if a child's payload carries some" do
      Dir.mktmpdir do |dir|
        coordinator = build_coordinator(record_dependencies: false)
        out_path = File.join(dir, "worker-0")
        payload = empty_reporters_payload(results: { "a.rb" => [] }, dependencies: { "a.rb" => :fake_record })
        pid = spawn_child(out_path: out_path, payload: payload)

        coordinator.send(:collect_fork_results, [{ pid: pid, slice: ["a.rb"], out_path: out_path }], {})

        expect(coordinator.collected_dependencies).to eq({})
      end
    end
  end

  # Mirrors `runner_fork_pool_spec.rb`'s established "deferred YJIT" pattern (`allocate` + a session double,
  # `exit!` stubbed to keep the worker body in-process — a real fork would run in a child process where a spy
  # on the parent cannot observe the call). Extended here to also cover the rescue branch, since this file's
  # own convention spec is what the self-mutation harness scopes to.
  describe "#run_fork_worker (private)" do
    it "re-arms deferred YJIT, marshals the slice's results/reporters/dependencies, and exit!s 0" do
      coordinator = described_class.allocate
      session = instance_double(
        Rigor::Analysis::WorkerSession, analyze: [], drain_reporters: {}, drain_dependencies: {}
      )
      allow(Rigor::Runtime::Jit).to receive(:rearm_after_fork)
      allow(coordinator).to receive(:exit!)
      Dir.mktmpdir do |dir|
        out_path = File.join(dir, "payload")

        coordinator.send(:run_fork_worker, session, ["a.rb"], out_path)

        expect(Rigor::Runtime::Jit).to have_received(:rearm_after_fork)
        expect(coordinator).to have_received(:exit!).with(0)
        expect(Marshal.load(File.binread(out_path))) # rubocop:disable Security/MarshalLoad
          .to eq(results: { "a.rb" => [] }, reporters: {}, dependencies: {})
      end
    end

    it "exit!s 1 and writes no payload when analysing the slice raises" do
      coordinator = described_class.allocate
      session = instance_double(Rigor::Analysis::WorkerSession)
      allow(session).to receive(:analyze).and_raise(StandardError, "boom")
      allow(Rigor::Runtime::Jit).to receive(:rearm_after_fork)
      allow(coordinator).to receive(:exit!)
      Dir.mktmpdir do |dir|
        out_path = File.join(dir, "payload")

        coordinator.send(:run_fork_worker, session, ["a.rb"], out_path)

        expect(coordinator).to have_received(:exit!).with(1)
        expect(File.exist?(out_path)).to be(false)
      end
    end
  end

  describe "#snapshot_fork_pool_stats (private)" do
    it "snapshots class_decl_paths / signature_paths off the parent session's loader, and leaves quarantined " \
       "signatures + env-build failure at their inert defaults when the project declares no signature_paths" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(snapshots: snapshots)
      loader = instance_double(
        Rigor::Environment::RbsLoader, class_decl_paths: { "Foo" => "foo.rbs" }, signature_paths: ["sig"],
                                       virtual_rbs: []
      )
      session = instance_double(
        Rigor::Analysis::WorkerSession, environment: instance_double(Rigor::Environment, rbs_loader: loader)
      )

      coordinator.send(:snapshot_fork_pool_stats, session)

      expect(snapshots.class_decl_paths).to eq({ "Foo" => "foo.rbs" })
      expect(snapshots.signature_paths).to eq(["sig"])
      expect(snapshots.quarantined_signatures).to eq([])
      expect(snapshots.env_build_failure).to be_nil
    end

    it "reads quarantined signatures and an env-build failure off the loader " \
       "when the project DOES declare signature_paths" do
      configuration = Rigor::Configuration.new("signature_paths" => ["sig"])
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(configuration: configuration, snapshots: snapshots)
      loader = instance_double(
        Rigor::Environment::RbsLoader, class_decl_paths: {}, signature_paths: [], virtual_rbs: [],
                                       quarantined_signatures: ["bad.rbs"], env_build_failure: [StandardError, 2, []],
                                       definition_build_failures: []
      )
      session = instance_double(
        Rigor::Analysis::WorkerSession, environment: instance_double(Rigor::Environment, rbs_loader: loader)
      )

      coordinator.send(:snapshot_fork_pool_stats, session)

      expect(snapshots.quarantined_signatures).to eq(["bad.rbs"])
      expect(snapshots.env_build_failure).to eq([StandardError, 2, []])
    end
  end

  # `analyze_files_in_fork_pool` builds its OWN real {WorkerSession} (unlike the sequential path, it does NOT
  # go through the injected `analyze_file:` callable), so unlike the rest of this file these examples run
  # against a REAL tmp project and let the fork pool run for real, reaping every child it spawns itself (via
  # `#collect_fork_results` → `Process.waitpid2`, exactly as production does).
  #
  # The happy-path pool ⇄ sequential diagnostic EQUIVALENCE contract is already exhaustively proven through
  # the public `Runner` API by `runner_fork_pool_spec.rb` — these examples are NOT re-deriving that. They
  # exist because the self-mutation harness scopes coverage per convention-spec FILE, and this method's own
  # branches (worker-count/slice math, the tmpdir lifecycle, the degrade-and-recover fold) had no direct
  # coverage from THIS file before this sweep.
  describe "#analyze_files_in_fork_pool (real fork pool)" do
    def real_coordinator(dir, workers:, collect_stats: false, record_dependencies: false)
      configuration = Rigor::Configuration.new("paths" => [dir])
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = described_class.new(
        configuration: configuration, cache_store: nil, explain: false, workers: workers,
        collect_stats: collect_stats, buffer: nil, environment_override: nil,
        rbs_extended_reporter: Rigor::RbsExtended::Reporter.new,
        boundary_cross_reporter: Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new,
        source_rbs_synthesis_reporter: Rigor::Plugin::SourceRbsSynthesisReporter.new,
        snapshots: snapshots,
        plugin_registry: -> { Rigor::Plugin::Registry::EMPTY },
        dependency_source_index: -> { Rigor::Analysis::DependencySourceInference::Index::EMPTY },
        synthetic_method_index: -> {}, project_patched_methods: -> {}, project_scope_seed: -> { {} },
        analyze_file: ->(_p, _e) { [] }, record_dependencies: record_dependencies
      )
      [coordinator, snapshots]
    end

    it "analyses every file across N real fork-pool children, with no degraded slice, " \
       "and snapshots the parent's class universe" do
      Dir.mktmpdir do |dir|
        paths = Array.new(2) do |i|
          path = File.join(dir, "file_#{i}.rb")
          File.write(path, "x_#{i} = #{i}\n")
          path
        end
        coordinator, snapshots = real_coordinator(dir, workers: 2, collect_stats: true)

        diagnostics = Dir.chdir(dir) { coordinator.analyze_files_in_fork_pool(paths) }

        expect(diagnostics).to eq([])
        expect(diagnostics.map(&:rule)).not_to include("pool-degraded")
        expect(snapshots.class_decl_paths).to be_a(Hash)
      end
    end

    it "degrades a crashed child's whole slice to an in-process re-analysis, prepends a pool-degraded " \
       "warning, and still folds that slice's dependency records" do
      Dir.mktmpdir do |dir|
        ok_path = File.join(dir, "ok.rb")
        File.write(ok_path, "x = 1\n")
        broken_path = File.join(dir, "broken.rb")
        File.write(broken_path, "x = 1\n")
        coordinator, = real_coordinator(dir, workers: 2, record_dependencies: true)
        # `run_fork_worker` is fail-soft by design (`WorkerSession#analyze` never raises on well-formed
        # input — it's covered directly, rescue branch included, above), so a genuine engine crash isn't
        # reachable here. This drives the DEGRADE branch directly instead: the child that would analyse
        # `broken_path` exits non-zero without writing a payload. `and_wrap_original` still runs inside the
        # forked child (the stub lives on `coordinator`'s singleton class, which `fork` copy-on-write
        # inherits), so the "ok" slice still takes the real `run_fork_worker` path.
        allow(coordinator).to receive(:run_fork_worker).and_wrap_original do |original, session, slice, out_path|
          next exit!(1) if slice == [broken_path]

          original.call(session, slice, out_path)
        end

        diagnostics = Dir.chdir(dir) { coordinator.analyze_files_in_fork_pool([ok_path, broken_path]) }

        degraded = diagnostics.find { |d| d.rule == "pool-degraded" }
        expect(degraded).not_to be_nil
        expect(degraded.message).to include("1 file(s) re-analysed in-process")
        expect(coordinator.collected_dependencies).to have_key(broken_path)
      end
    end
  end

  # DECLINED: `#analyze_files_in_pool` (the ADR-15 Phase 4b Ractor pool body) is deliberately NOT driven
  # directly from this file. It is exercised — including its equivalence, ordering, and no-cache-store
  # degradation contracts — by `spec/rigor/analysis/runner_pool_spec.rb`, which the suite EXCLUDES by default
  # (`spec_helper.rb`'s `RIGOR_INCLUDE_RACTOR_POOL` gate) because spawning real Ractors crashes ~70% of runs
  # under Ruby Bug #22075. Adding a real-Ractor example to THIS file would put that instability back into the
  # default suite the gate exists to protect, for no benefit `runner_pool_spec.rb` doesn't already give under
  # its opt-in gate. The self-mutation sweep's survivors on `#analyze_files_in_pool`'s own lines are accepted
  # as a scope reduction for that reason, not a missed gap — recorded here rather than left implicit.

  describe "#pool_degraded_diagnostic (private)" do
    it "builds a :warning pool-degraded diagnostic naming the degraded file count" do
      diagnostic = build_coordinator.send(:pool_degraded_diagnostic, 3, "fork")

      expect(diagnostic.rule).to eq("pool-degraded")
      expect(diagnostic.severity).to eq(:warning)
      expect(diagnostic.source_family).to eq(:builtin)
      expect(diagnostic.message).to include("3 file(s) re-analysed in-process")
    end
  end

  describe "#build_runner_environment" do
    # rubocop:disable-next RSpec/ExampleLength
    it "threads the configuration, cache_store, injected readers, and source_files into " \
       "Environment.for_project" do
      configuration = Rigor::Configuration.new(
        "libraries" => ["set"], "signature_paths" => ["sig"], "bundler" => { "auto_detect" => true }
      )
      cache_store = instance_double(Rigor::Cache::Store)
      plugin_registry = Rigor::Plugin::Registry::EMPTY
      dependency_source_index = Rigor::Analysis::DependencySourceInference::Index::EMPTY
      rbs_reporter = Rigor::RbsExtended::Reporter.new
      boundary_reporter = Rigor::Analysis::DependencySourceInference::BoundaryCrossReporter.new
      synthesis_reporter = Rigor::Plugin::SourceRbsSynthesisReporter.new
      coordinator = build_coordinator(
        configuration: configuration, cache_store: cache_store, plugin_registry: plugin_registry,
        dependency_source_index: dependency_source_index, rbs_extended_reporter: rbs_reporter,
        boundary_cross_reporter: boundary_reporter, source_rbs_synthesis_reporter: synthesis_reporter,
        synthetic_method_index: :the_synthetic_index, project_patched_methods: :the_patched_methods
      )
      built = instance_double(Rigor::Environment)
      allow(Rigor::Environment).to receive(:for_project).and_return(built)

      result = coordinator.build_runner_environment(source_files: ["a.rb"])

      expect(result).to equal(built)
      expect(Rigor::Environment).to have_received(:for_project).with(
        libraries: ["set"], signature_paths: ["sig"], cache_store: cache_store,
        plugin_registry: plugin_registry, dependency_source_index: dependency_source_index,
        rbs_extended_reporter: rbs_reporter, boundary_cross_reporter: boundary_reporter,
        source_rbs_synthesis_reporter: synthesis_reporter,
        bundler_bundle_path: configuration.bundler_bundle_path, bundler_auto_detect: true,
        bundler_lockfile: configuration.bundler_lockfile,
        rbs_collection_lockfile: configuration.rbs_collection_lockfile,
        rbs_collection_auto_detect: configuration.rbs_collection_auto_detect,
        synthetic_method_index: :the_synthetic_index, project_patched_methods: :the_patched_methods,
        source_files: ["a.rb"]
      )
    end

    it "defaults source_files to an empty Array for callers with no file list yet " \
       "(e.g. a pre-pass-only build path)" do
      coordinator = build_coordinator
      allow(Rigor::Environment).to receive(:for_project)

      coordinator.build_runner_environment

      expect(Rigor::Environment).to have_received(:for_project).with(hash_including(source_files: []))
    end
  end

  describe "#prewarm_rbs_cache_for_pool (private)" do
    it "builds a coordinator-side Environment and prewarms its RBS loader" do
      cache_store = instance_double(Rigor::Cache::Store)
      configuration = Rigor::Configuration.new("libraries" => ["set"])
      coordinator = build_coordinator(configuration: configuration, cache_store: cache_store)
      loader = instance_double(Rigor::Environment::RbsLoader)
      warm_env = instance_double(Rigor::Environment, rbs_loader: loader)
      allow(Rigor::Environment).to receive(:for_project).and_return(warm_env)
      allow(loader).to receive(:prewarm)

      coordinator.send(:prewarm_rbs_cache_for_pool)

      expect(loader).to have_received(:prewarm)
      expect(Rigor::Environment).to have_received(:for_project).with(
        libraries: ["set"], signature_paths: configuration.signature_paths, cache_store: cache_store,
        bundler_bundle_path: configuration.bundler_bundle_path,
        bundler_auto_detect: configuration.bundler_auto_detect,
        bundler_lockfile: configuration.bundler_lockfile,
        rbs_collection_lockfile: configuration.rbs_collection_lockfile,
        rbs_collection_auto_detect: configuration.rbs_collection_auto_detect
      )
    end

    it "tolerates a warm Environment whose rbs_loader is nil, rather than raising" do
      coordinator = build_coordinator
      warm_env = instance_double(Rigor::Environment, rbs_loader: nil)
      allow(Rigor::Environment).to receive(:for_project).and_return(warm_env)

      expect { coordinator.send(:prewarm_rbs_cache_for_pool) }.not_to raise_error
    end
  end

  describe "#analyze_files_sequentially_fallback (private)" do
    it "runs analysis in-process via build_runner_environment and prepends a pool-degraded warning" do
      calls = []
      analyze_file = lambda do |path, environment|
        calls << [path, environment]
        []
      end
      coordinator = build_coordinator(analyze_file: analyze_file)
      built = instance_double(Rigor::Environment, rbs_loader: nil)
      allow(coordinator).to receive(:build_runner_environment).and_return(built)

      diagnostics = coordinator.send(:analyze_files_sequentially_fallback, ["a.rb"], reason: "no cache_store")

      expect(diagnostics.size).to eq(1)
      expect(diagnostics.first.rule).to eq("pool-degraded")
      expect(diagnostics.first.message).to include("no cache_store")
      expect(calls).to eq([["a.rb", built]])
    end

    it "snapshots quarantined signatures and the env-build failure when the project declares signature_paths" do
      configuration = Rigor::Configuration.new("signature_paths" => ["sig"])
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(
        configuration: configuration, snapshots: snapshots, analyze_file: ->(_p, _e) { [] }
      )
      loader = instance_double(
        Rigor::Environment::RbsLoader, class_decl_paths: {}, signature_paths: [], virtual_rbs: [],
                                       quarantined_signatures: ["bad.rbs"], env_build_failure: [StandardError, 1, []],
                                       definition_build_failures: []
      )
      built = instance_double(Rigor::Environment, rbs_loader: loader)
      allow(coordinator).to receive(:build_runner_environment).and_return(built)

      coordinator.send(:analyze_files_sequentially_fallback, ["a.rb"], reason: "x")

      expect(snapshots.quarantined_signatures).to eq(["bad.rbs"])
      expect(snapshots.env_build_failure).to eq([StandardError, 1, []])
    end

    it "leaves quarantined signatures and the env-build failure at their inert defaults " \
       "when the project declares no signature_paths" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(snapshots: snapshots, analyze_file: ->(_p, _e) { [] })
      loader = instance_double(Rigor::Environment::RbsLoader, class_decl_paths: {}, signature_paths: [],
                                                              virtual_rbs: [], definition_build_failures: [])
      built = instance_double(Rigor::Environment, rbs_loader: loader)
      allow(coordinator).to receive(:build_runner_environment).and_return(built)

      coordinator.send(:analyze_files_sequentially_fallback, ["a.rb"], reason: "x")

      expect(snapshots.quarantined_signatures).to eq([])
      expect(snapshots.env_build_failure).to be_nil
    end
  end
end
