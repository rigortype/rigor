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
      expect(coordinator).to have_received(:dispatch_pool).with(["a.rb"], source_files: ["a.rb"])
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
      environment = instance_double(Rigor::Environment, rbs_loader: nil, hkt_registry: nil, hkt_scan_failure: nil)

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
      environment = instance_double(Rigor::Environment, rbs_loader: loader, hkt_registry: nil, hkt_scan_failure: nil)

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
      environment = instance_double(Rigor::Environment, rbs_loader: loader, hkt_registry: nil, hkt_scan_failure: nil)

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

      coordinator.analyze_files_sequentially(
        ["a.rb"], instance_double(Rigor::Environment, rbs_loader: loader, hkt_registry: nil, hkt_scan_failure: nil)
      )

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

      coordinator.analyze_files_sequentially(
        ["a.rb"], instance_double(Rigor::Environment, rbs_loader: loader, hkt_registry: nil, hkt_scan_failure: nil)
      )

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

      coordinator.analyze_files_sequentially(
        ["a.rb"], instance_double(Rigor::Environment, rbs_loader: loader, hkt_registry: nil, hkt_scan_failure: nil)
      )

      expect(snapshots.definition_build_failures).to eq([failure])
    end

    # Issue #784 — the seam in `Environment#hkt_registry` is demand-driven, and a subset run (a
    # `--verify-incremental` partition, an incremental closure) can contain no file that demands it. The
    # RUN must demand it once itself, or the row silently depends on which files happened to be analysed.
    # The `analyze_file` callable here never touches the environment, so only the coordinator's own demand
    # can populate the slot; an implementation that merely reads it after the loop gets nil and fails.
    it "demands the HKT registry itself after the loop, so the row does not depend on the files (#784)" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      tuple = ["NameError", "simulated scan bug", "lib/rigor/inference/hkt_registry.rb:1:in 'scan'"]
      demanded = false
      environment = instance_double(Rigor::Environment, rbs_loader: nil)
      allow(environment).to receive(:hkt_registry) { demanded = true }
      allow(environment).to receive(:hkt_scan_failure) { demanded ? tuple : nil }
      coordinator = build_coordinator(snapshots: snapshots)

      coordinator.analyze_files_sequentially(["a.rb"], environment)

      expect(environment).to have_received(:hkt_registry).once
      expect(snapshots.hkt_scan_failure).to eq(tuple)
    end

    # Issue #784 — an EMPTY analyze set (an incremental recheck whose closure is empty) returns before the
    # per-file loop, but still owes the run its row: `IncrementalSession` caches only what per-file analysis
    # produced (`Runner#per_file_diagnostics`), so every run-level row is regenerated by every run. Only an
    # environment that already exists is consulted — the override, or the one the caller resolved.
    it "records the row from an already-resolved environment even when the analyze set is empty (#784)" do
      tuple = ["NameError", "simulated scan bug", nil]
      environment = instance_double(Rigor::Environment, rbs_loader: nil, hkt_registry: nil, hkt_scan_failure: tuple)

      via_override = Rigor::Analysis::Runner::RunSnapshots.new
      build_coordinator(snapshots: via_override, environment_override: environment).analyze_files([])
      expect(via_override.hkt_scan_failure).to eq(tuple)

      via_argument = Rigor::Analysis::Runner::RunSnapshots.new
      build_coordinator(snapshots: via_argument).analyze_files([], environment: environment)
      expect(via_argument.hkt_scan_failure).to eq(tuple)
    end

    # The shipping `--incremental` shape: `CheckCommand#run_incremental_check` builds its session with no
    # environment, so a warm recheck whose closure is empty reaches this branch with nothing in hand. The
    # project HAS files, so the coordinator resolves an environment for the purpose — over the project's
    # own file list, so it carries the same plugin-synthesized RBS a full run would (an env built over `[]`
    # scans a different universe) — and records the outcome. Without this the warm run went 0 diagnostics
    # / exit 0 on a broken-scan project where the cold run was red.
    it "resolves an environment over the project's files for an empty run with none in hand (#784)" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      tuple = ["NameError", "simulated scan bug", nil]
      resolved = instance_double(Rigor::Environment, rbs_loader: nil, hkt_registry: nil, hkt_scan_failure: tuple)
      allow(Rigor::Environment).to receive(:for_project).and_return(resolved)

      result = build_coordinator(snapshots: snapshots).analyze_files([], project_files: ["a.rb", "b.rb"])

      expect(result).to eq([])
      expect(Rigor::Environment).to have_received(:for_project).with(hash_including(source_files: ["a.rb",
                                                                                                   "b.rb"])).once
      expect(resolved).to have_received(:hkt_registry).once
      expect(snapshots.hkt_scan_failure).to eq(tuple)
    end

    # #788 round 6 — the residual pass reads the effect-annotation carrier the coordinator snapshots off
    # the environment; only the non-empty path used to fill it. Now that run-level rows are never served
    # from the per-file cache, an empty-closure recheck must fill it from the environment it resolves, or
    # an inline-only `effect.annotations-unchecked` goes 1 → 0 on every warm nothing-changed run.
    it "snapshots the effect-annotation carrier from the environment an empty run resolves (#788)" do
      annotated = ["lib/demo.rb", "class Memo\n  %a{pure}\n  def value: () -> Integer\nend\n"]
      loader = instance_double(Rigor::Environment::RbsLoader, definition_build_failures: [],
                                                              virtual_rbs: [["lib/plain.rb", "class P\nend\n"],
                                                                            annotated])
      resolved = instance_double(Rigor::Environment, hkt_registry: nil, hkt_scan_failure: nil, rbs_loader: loader)
      allow(Rigor::Environment).to receive(:for_project).and_return(resolved)
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new

      build_coordinator(snapshots: snapshots).analyze_files([], project_files: ["a.rb"])

      expect(snapshots.effect_annotation_carrier).to eq([annotated])
    end

    # Round 9 (user's reviewer, P1) — the same branch owes the run its project-signature state: with the
    # per-file cache holding only per-file rows, `synthesized-namespace`, `quarantined-signature`,
    # `environment-build-failed` and the conformance rows have no other producer on a warm recheck that
    # changed nothing, and an `:error`-level quarantine row went 1 → 0 on the second `--incremental` run.
    # The conformance scan demands the definition of every `conforms-to` class, so the definition-build
    # failures are read AFTER it (the sequential path's order): the loader here reports one only once the
    # scan has run.
    it "snapshots the project-signature state from the environment an empty run resolves (#788)" do
      failures = []
      loader = instance_double(Rigor::Environment::RbsLoader, virtual_rbs: [], synthesized_namespaces: [:ns],
                                                              quarantined_signatures: [:quarantined],
                                                              env_build_failure: :build_failure)
      allow(loader).to receive(:definition_build_failures) { failures }
      resolved = instance_double(Rigor::Environment, hkt_registry: nil, hkt_scan_failure: nil, rbs_loader: loader)
      allow(Rigor::Environment).to receive(:for_project).and_return(resolved)
      allow(Rigor::RbsExtended::ConformanceChecker).to receive(:scan).with(loader) do
        failures << ["DupDemo", :duplicated_member]
        [:conformance]
      end
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("signature_paths" => ["sig"]))

      build_coordinator(configuration: configuration, snapshots: snapshots).analyze_files([], project_files: ["a.rb"])

      expect([snapshots.synthesized_namespaces, snapshots.quarantined_signatures, snapshots.env_build_failure,
              snapshots.conformance_results]).to eq([[:ns], [:quarantined], :build_failure, [:conformance]])
      expect(snapshots.definition_build_failures).to eq([["DupDemo", :duplicated_member]])
    end

    it "snapshots empty project-signature state on an empty run over a project with no files" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS.merge("signature_paths" => ["sig"]))
      allow(Rigor::Environment).to receive(:for_project)

      build_coordinator(configuration: configuration, snapshots: snapshots).analyze_files([], project_files: [])

      expect(Rigor::Environment).not_to have_received(:for_project)
      expect([snapshots.synthesized_namespaces, snapshots.quarantined_signatures, snapshots.env_build_failure,
              snapshots.conformance_results]).to eq([[], [], nil, []])
    end

    # Issue #793 — a NON-empty narrowed run must build its environment over the whole project too, or the
    # plugin-synthesized RBS of every excluded file is missing and the run scans a different type universe
    # than the full run it is compared against. `files` is what is analysed; `source_files:` is what the
    # environment is built over.
    it "builds a narrowed run's environment over the whole project, not the analyze set (#793)" do
      resolved = instance_double(Rigor::Environment, rbs_loader: nil, hkt_registry: nil, hkt_scan_failure: nil)
      allow(Rigor::Environment).to receive(:for_project).and_return(resolved)
      analyzed = []
      coordinator = build_coordinator(analyze_file: lambda { |path, _env|
        analyzed << path
        []
      })

      coordinator.analyze_files(["a.rb"], project_files: ["a.rb", "b.rb"])

      expect(analyzed).to eq(["a.rb"])
      expect(Rigor::Environment).to have_received(:for_project).with(hash_including(source_files: ["a.rb",
                                                                                                   "b.rb"])).once
    end

    # The must-still-succeed twin: a project with NO files — even when `analyze_only` narrowed it to
    # `Set[]`, which a recheck over an empty project does — has nobody who could have demanded a registry,
    # and the coordinator must not build an environment just to ask. An empty project pays no env build
    # today, and that stays true on every path.
    it "never builds an environment when the project has no files (#784)" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      allow(Rigor::Environment).to receive(:for_project).and_call_original

      result = build_coordinator(snapshots: snapshots).analyze_files([], project_files: [])

      expect(result).to eq([])
      expect(snapshots.hkt_scan_failure).to be_nil
      expect(Rigor::Environment).not_to have_received(:for_project)
    end

    # The must-still-succeed twin: a healthy loader leaves the slot at its inert default, so the diagnostic
    # cannot fire on a project with nothing wrong.
    it "leaves the slot empty when every definition built" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(snapshots: snapshots)
      loader = instance_double(Rigor::Environment::RbsLoader, virtual_rbs: [], definition_build_failures: [])

      coordinator.analyze_files_sequentially(
        ["a.rb"], instance_double(Rigor::Environment, rbs_loader: loader, hkt_registry: nil, hkt_scan_failure: nil)
      )

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
        .and_return(instance_double(Rigor::Environment, rbs_loader: loader, hkt_registry: nil, hkt_scan_failure: nil))

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
        .and_return(instance_double(Rigor::Environment, rbs_loader: loader, hkt_registry: nil, hkt_scan_failure: nil))

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
      snapshots.signature_standdowns = ["stale"]
      snapshots.conformance_results = ["stale"]
      snapshots.env_build_failure = [StandardError, 1, []]
      coordinator = build_coordinator(snapshots: snapshots)
      # Never touched: the no-signature_paths branch returns before reading the loader at all, and the
      # #610 stand-down slot asks the (empty) plugin registry, never the environment.
      environment = instance_double(Rigor::Environment)

      coordinator.snapshot_project_signature_state(environment)

      expect(snapshots.synthesized_namespaces).to eq([])
      expect(snapshots.quarantined_signatures).to eq([])
      expect(snapshots.signature_standdowns).to eq([])
      expect(snapshots.conformance_results).to eq([])
      expect(snapshots.env_build_failure).to be_nil
    end

    # Issue #610 — the stand-down slot is gated on a loaded plugin contributing signatures, not on the
    # project's own `signature_paths:`: the source a plugin's `sig/` stands down against is typically an
    # `rbs collection install` the configuration never lists.
    it "reads the plugin-signature stand-downs off the loader when a plugin contributes signatures, " \
       "even with no project signature_paths" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      standdown = ["/plugins/rigor-activerecord/sig/active_record/relation.rbs", "::ActiveRecord::Relation", 0, 1, nil]
      registry = instance_double(Rigor::Plugin::Registry, signature_paths: ["/plugins/rigor-activerecord/sig"])
      loader = instance_double(
        Rigor::Environment::RbsLoader,
        deferred_signature_paths: [Pathname("/plugins/rigor-activerecord/sig")], signature_standdowns: [standdown]
      )
      coordinator = build_coordinator(snapshots: snapshots, plugin_registry: registry)
      environment = instance_double(Rigor::Environment, rbs_loader: loader)

      coordinator.snapshot_project_signature_state(environment)

      expect(snapshots.signature_standdowns).to eq([standdown])
      expect(snapshots.quarantined_signatures).to eq([])
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
      expect(coordinator).to have_received(:analyze_files_in_fork_pool).with(["a.rb"], source_files: ["a.rb"])
    end

    it "degrades a recording run to sequential when fork is unavailable, " \
       "since only the fork path marshals dependency records back" do
      coordinator = build_coordinator(record_dependencies: true)
      allow(Process).to receive(:respond_to?).and_call_original
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)
      allow(coordinator).to receive(:analyze_files_sequentially_fallback).and_return([:seq_result])

      expect(coordinator.dispatch_pool(["a.rb"])).to eq([:seq_result])
      expect(coordinator).to have_received(:analyze_files_sequentially_fallback).with(
        ["a.rb"], reason: a_string_matching(/incremental parallelism requires fork/), source_files: ["a.rb"]
      )
    end

    it "routes to the Ractor pool when pool_backend resolves to :ractor" do
      coordinator = build_coordinator
      allow(coordinator).to receive_messages(pool_backend: :ractor, analyze_files_in_pool: [:ractor_result])

      expect(coordinator.dispatch_pool(["a.rb"])).to eq([:ractor_result])
      expect(coordinator).to have_received(:analyze_files_in_pool).with(["a.rb"], source_files: ["a.rb"])
    end

    it "routes to the fork pool when pool_backend resolves to :fork" do
      coordinator = build_coordinator
      allow(coordinator).to receive_messages(pool_backend: :fork, analyze_files_in_fork_pool: [:fork_result])

      expect(coordinator.dispatch_pool(["a.rb"])).to eq([:fork_result])
      expect(coordinator).to have_received(:analyze_files_in_fork_pool).with(["a.rb"], source_files: ["a.rb"])
    end

    it "degrades to sequential when pool_backend resolves to :sequential (no fork-capable backend)" do
      coordinator = build_coordinator
      allow(coordinator).to receive_messages(pool_backend: :sequential,
                                             analyze_files_sequentially_fallback: [:seq_result])

      expect(coordinator.dispatch_pool(["a.rb"])).to eq([:seq_result])
      expect(coordinator).to have_received(:analyze_files_sequentially_fallback).with(
        ["a.rb"], reason: a_string_matching(/fork-based parallelism is unavailable/), source_files: ["a.rb"]
      )
    end
  end

  describe "#analyze_files_in_pool without a cache store" do
    # #788 round 5 — the one fallback exit that lives INSIDE the Ractor backend (not in `dispatch_pool`)
    # was missed when `source_files:` was threaded everywhere else, so a narrowed Ractor-backend run with
    # no store built its fallback environment over the narrowed set again (#793).
    it "threads source_files to the sequential fallback it degrades to" do
      coordinator = build_coordinator(workers: 2, cache_store: nil)
      allow(coordinator).to receive(:analyze_files_sequentially_fallback).and_return([:seq_result])

      expect(coordinator.analyze_files_in_pool(["a.rb"], source_files: ["a.rb", "b.rb"])).to eq([:seq_result])
      expect(coordinator).to have_received(:analyze_files_sequentially_fallback).with(
        ["a.rb"], reason: a_string_matching(/requires a cache_store/), source_files: ["a.rb", "b.rb"]
      )
    end
  end

  # Round 9 (user's reviewer, P2) — a Ractor worker that died never sends `:done`, so nothing drains its
  # HKT outcome, and the in-process re-analysis of its files runs on a LOCAL environment with no session to
  # drain. The helper must finalize that environment itself — the definition-build failures the re-analysis
  # demanded, and the HKT outcome demanded once more by the run — or a rescued scan failure vanishes with
  # the worker. Tested on the helper: the Ractor backend cannot run under the current rbs.
  describe "#reanalyze_degraded_in_process (private)" do
    it "finalizes the degraded in-process environment (definition failures + HKT outcome)" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      tuple = ["NameError", "simulated scan bug", nil]
      loader = instance_double(Rigor::Environment::RbsLoader, definition_build_failures: [])
      local = instance_double(Rigor::Environment, hkt_registry: nil, hkt_scan_failure: tuple, rbs_loader: loader)
      analyzed = []
      coordinator = build_coordinator(snapshots: snapshots, analyze_file: lambda { |path, env|
        analyzed << [path, env]
        [:"row_#{path}"]
      })
      allow(coordinator).to receive(:build_runner_environment).with(source_files: ["a.rb", "b.rb"]).and_return(local)
      results = {}

      coordinator.send(:reanalyze_degraded_in_process, ["b.rb"], results, source_files: ["a.rb", "b.rb"])

      expect(analyzed).to eq([["b.rb", local]])
      expect(results).to eq({ "b.rb" => [:"row_b.rb"] })
      expect(local).to have_received(:hkt_registry).once
      expect(loader).to have_received(:definition_build_failures)
      expect(snapshots.hkt_scan_failure).to eq(tuple)
    end

    it "builds nothing when no worker's files were left unreported" do
      coordinator = build_coordinator
      allow(coordinator).to receive(:build_runner_environment)

      coordinator.send(:reanalyze_degraded_in_process, [], {}, source_files: ["a.rb"])

      expect(coordinator).not_to have_received(:build_runner_environment)
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

    # Issue #785 — every worker scans the same RBS env, so N workers hand over N copies of one declined
    # directive. The reporter's own `(message, path, line, column)` dedup is what makes `--workers=N` print
    # the single row `--workers=0` prints; carrying an `RBS::Location` instead would defeat it, since two
    # workers hold separate `RBS::Buffer` objects.
    it "replays a worker's hkt-directive failures and collapses two workers' copies into one row" do
      coordinator_reporter = Rigor::RbsExtended::Reporter.new
      coordinator = build_coordinator(rbs_extended_reporter: coordinator_reporter)
      worker_reporter = Rigor::RbsExtended::Reporter.new
      worker_reporter.record_hkt_error(message: "uri= is required", path: "sig/a.rbs", line: 2, column: 1)

      2.times do
        coordinator.merge_worker_reporters(
          rbs_extended: { unresolved_payloads: [], lossy_projections: [],
                          hkt_directive_errors: worker_reporter.hkt_directive_errors },
          boundary_cross: [], source_rbs_synthesis: []
        )
      end

      expect(coordinator_reporter.hkt_directive_errors.map(&:message)).to eq(["uri= is required"])
      expect(coordinator_reporter.hkt_directive_errors.first.path).to eq("sig/a.rbs")
    end

    it "tolerates a drain shape that carries no hkt-directive key" do
      coordinator_reporter = Rigor::RbsExtended::Reporter.new
      coordinator = build_coordinator(rbs_extended_reporter: coordinator_reporter)

      expect do
        coordinator.merge_worker_reporters(
          rbs_extended: { unresolved_payloads: [], lossy_projections: [] },
          boundary_cross: [], source_rbs_synthesis: []
        )
      end.not_to raise_error
      expect(coordinator_reporter).to be_empty
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

    # Issue #824 — the drain used to replay every entry as WD6's default `:failed`, so under `--workers N`
    # a WD12 "parsed but not honoured" row came back as `source-rbs-synthesis-failed`: a different rule id,
    # and a message telling the user the file contributed nothing when all but one annotation bound.
    it "preserves an entry's kind, so a WD12 row does not replay as a synthesis failure" do
      worker_reporter = Rigor::Plugin::SourceRbsSynthesisReporter.new
      worker_reporter.record(plugin_id: "rbs-inline", path: "a.rb", message: "dropped", kind: :not_honoured)
      coordinator_reporter = Rigor::Plugin::SourceRbsSynthesisReporter.new
      coordinator = build_coordinator(source_rbs_synthesis_reporter: coordinator_reporter)

      coordinator.merge_worker_reporters(
        rbs_extended: { unresolved_payloads: [], lossy_projections: [] },
        boundary_cross: [], source_rbs_synthesis: worker_reporter.entries
      )

      expect(coordinator_reporter.entries.map(&:kind)).to eq([:not_honoured])
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

    # Issue #784 — first-wins, unlike `definition_build_failures`'s accumulate-and-dedup above: the scan is
    # ONE build over the SAME `signature_paths:` overlay every worker was handed, so every worker that
    # demands it observes the identical tuple, and `||=` records it once rather than accumulating a list
    # of duplicates.
    it "records the first worker's hkt_scan_failure tuple, and a later drain does not overwrite it" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(snapshots: snapshots)
      first = ["NameError", "simulated scan bug", "lib/rigor/inference/hkt_registry.rb:1"]
      second = ["NameError", "a different message entirely", "lib/rigor/inference/hkt_registry.rb:1"]

      coordinator.merge_worker_reporters(
        rbs_extended: { unresolved_payloads: [], lossy_projections: [] }, boundary_cross: [],
        hkt_scan_failure: first
      )
      coordinator.merge_worker_reporters(
        rbs_extended: { unresolved_payloads: [], lossy_projections: [] }, boundary_cross: [],
        hkt_scan_failure: second
      )

      expect(snapshots.hkt_scan_failure).to eq(first)
    end

    # The must-still-succeed twin, and the non-vacuity check for the example above: a drain hash that omits
    # the key (any pre-#784 producer, or simply nothing to report) must merge cleanly and leave the slot at
    # its inert default, exactly as `definition_build_failures` does.
    it "tolerates a drain hash with no hkt_scan_failure key, leaving the slot nil" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(snapshots: snapshots)

      expect do
        coordinator.merge_worker_reporters(
          rbs_extended: { unresolved_payloads: [], lossy_projections: [] }, boundary_cross: []
        )
      end.not_to raise_error
      expect(snapshots.hkt_scan_failure).to be_nil
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

  # Issue #798 — narrowed to `RunStats` telemetry only. `quarantined_signatures` / `env_build_failure` used
  # to be written HERE, gated on `@collect_stats`, which is what made a `--workers N --no-stats` run silent
  # about a broken `signature_paths:` file the sequential path reports — those diagnostic-bearing slots now
  # belong entirely to `#snapshot_project_signature_state`, called unconditionally in
  # `#analyze_files_in_fork_pool` regardless of whether stats collection is on.
  describe "#snapshot_fork_pool_stats (private)" do
    it "snapshots class_decl_paths / signature_paths off the parent session's loader" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      coordinator = build_coordinator(snapshots: snapshots)
      loader = instance_double(
        Rigor::Environment::RbsLoader, class_decl_paths: { "Foo" => "foo.rbs" }, signature_paths: ["sig"]
      )
      session = instance_double(
        Rigor::Analysis::WorkerSession, environment: instance_double(Rigor::Environment, rbs_loader: loader)
      )

      coordinator.send(:snapshot_fork_pool_stats, session)

      expect(snapshots.class_decl_paths).to eq({ "Foo" => "foo.rbs" })
      expect(snapshots.signature_paths).to eq(["sig"])
    end

    it "does not touch the project-signature-state slots at all" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      snapshots.quarantined_signatures = ["stays"]
      snapshots.env_build_failure = [StandardError, 9, []]
      coordinator = build_coordinator(snapshots: snapshots)
      loader = instance_double(Rigor::Environment::RbsLoader, class_decl_paths: {}, signature_paths: [])
      session = instance_double(
        Rigor::Analysis::WorkerSession, environment: instance_double(Rigor::Environment, rbs_loader: loader)
      )

      coordinator.send(:snapshot_fork_pool_stats, session)

      expect(snapshots.quarantined_signatures).to eq(["stays"])
      expect(snapshots.env_build_failure).to eq([StandardError, 9, []])
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
    def real_coordinator(dir, workers:, collect_stats: false, record_dependencies: false, signature_paths: nil)
      config = { "paths" => [dir] }
      config["signature_paths"] = signature_paths if signature_paths
      configuration = Rigor::Configuration.new(config)
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

    # Issue #798 — `analyze_files_in_fork_pool` never called `#snapshot_project_signature_state` at all, so
    # `quarantined-signature` / `synthesized-namespace` had no producer under `--workers N`, and the two
    # slots `#snapshot_fork_pool_stats` DID cover (`quarantined_signatures`, `env_build_failure`) were gated
    # on `@collect_stats` — a `--workers N --no-stats` run said strictly LESS than the sequential path over
    # the same project. `collect_stats: false` here is the regression case: these rows must survive it.
    it "reports quarantined/synthesized project-signature state through a real fork pool even with " \
       "collect_stats: false" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "sig"))
        File.write(File.join(dir, "sig", "broken.rbs"),
                   "class Broken\n  def h: () -> { data-contrast: Integer }\nend\n")
        File.write(File.join(dir, "sig", "widget.rbs"), "class Acme::Widget\n  def size: () -> Integer\nend\n")
        path = File.join(dir, "a.rb")
        File.write(path, "x = 1\n")
        coordinator, snapshots = real_coordinator(
          dir, workers: 2, collect_stats: false, signature_paths: [File.join(dir, "sig")]
        )

        Dir.chdir(dir) { coordinator.analyze_files_in_fork_pool([path]) }

        expect(snapshots.quarantined_signatures.map(&:first)).to eq([File.join(dir, "sig", "broken.rbs")])
        expect(snapshots.synthesized_namespaces).not_to be_empty
        # `collect_stats: false` must skip ONLY the RunStats-only slots, not the diagnostic-bearing ones.
        expect(snapshots.class_decl_paths).to eq({})
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

      coordinator.send(:prewarm_rbs_cache_for_pool, source_files: ["a.rb", "b.rb"])

      expect(loader).to have_received(:prewarm)
      # An EXACT keyword list on purpose: it pins that the run's three reporter accumulators are not handed
      # to this build (the example two below says why they must not be).
      expect(Rigor::Environment).to have_received(:for_project).with(
        libraries: ["set"], signature_paths: configuration.signature_paths, cache_store: cache_store,
        plugin_registry: Rigor::Plugin::Registry::EMPTY,
        bundler_bundle_path: configuration.bundler_bundle_path,
        bundler_auto_detect: configuration.bundler_auto_detect,
        bundler_lockfile: configuration.bundler_lockfile,
        rbs_collection_lockfile: configuration.rbs_collection_lockfile,
        rbs_collection_auto_detect: configuration.rbs_collection_auto_detect,
        source_files: ["a.rb", "b.rb"]
      )
    end

    it "tolerates a warm Environment whose rbs_loader is nil, rather than raising" do
      coordinator = build_coordinator
      warm_env = instance_double(Rigor::Environment, rbs_loader: nil)
      allow(Rigor::Environment).to receive(:for_project).and_return(warm_env)

      expect { coordinator.send(:prewarm_rbs_cache_for_pool, source_files: []) }.not_to raise_error
    end

    # Issue #798 — the Ractor pool's coordinator body used to discard this environment right after
    # warming the cache, which is also why it never snapshotted the project-signature state: unlike the
    # fork pool's copy-on-write children, a Ractor worker builds its own isolated Environment and shares
    # no memory with the coordinator's, so a warm_env nobody kept was a warm_env nobody could read from.
    it "returns the built environment rather than discarding it" do
      coordinator = build_coordinator
      loader = instance_double(Rigor::Environment::RbsLoader)
      warm_env = instance_double(Rigor::Environment, rbs_loader: loader)
      allow(Rigor::Environment).to receive(:for_project).and_return(warm_env)
      allow(loader).to receive(:prewarm)

      expect(coordinator.send(:prewarm_rbs_cache_for_pool, source_files: [])).to equal(warm_env)
    end

    # The environment is built the way each Ractor worker builds its own — with the loaded plugin registry
    # over the WHOLE project (#793) — and WITHOUT the run's reporter accumulators. Both halves are what
    # makes the carrier snapshot in `#analyze_files_in_pool` mean something: `Environment.for_project`
    # collects plugin-synthesized virtual RBS only when handed both a registry and a file list (it used to
    # get neither, so the loader's `virtual_rbs` read empty on every project), and an environment BUILD
    # writes synthesizer failures to the `source_rbs_synthesis` reporter, which every worker's drain
    # already replays into the coordinator's accumulator without dedup — a reporter here would count each
    # entry twice.
    it "builds over the whole project with the plugin registry and withholds the run's reporters" do
      registry = instance_double(Rigor::Plugin::Registry)
      coordinator = build_coordinator(plugin_registry: registry)
      loader = instance_double(Rigor::Environment::RbsLoader, prewarm: nil)
      warm_env = instance_double(Rigor::Environment, rbs_loader: loader)
      allow(Rigor::Environment).to receive(:for_project).and_return(warm_env)

      coordinator.send(:prewarm_rbs_cache_for_pool, source_files: ["lib/a.rb", "lib/b.rb"])

      expect(Rigor::Environment).to have_received(:for_project).with(
        hash_including(plugin_registry: registry, source_files: ["lib/a.rb", "lib/b.rb"])
      )
      expect(Rigor::Environment).to have_received(:for_project).with(
        hash_excluding(:rbs_extended_reporter, :boundary_cross_reporter, :source_rbs_synthesis_reporter)
      )
    end

    # `Environment.for_project` un-stubbed, so this pins the chain the carrier depends on rather than a
    # keyword list: a plugin-synthesized buffer is on the built environment's loader, where
    # `#snapshot_effect_annotation_carrier` reads it. No RBS environment is demanded (the loader is lazy
    # and `cache_store: nil` makes `#prewarm` a no-op), and the paths deliberately do not exist, so the
    # synthesizer is invoked directly rather than through the cache-store memo.
    it "carries the plugin-synthesized virtual RBS the rbs-inline lane is read from" do
      annotated = "class Memo\n  %a{pure}\n  def value: () -> Integer\nend\n"
      plugin_class = Class.new(Rigor::Plugin::Base) do
        manifest(id: "synth", version: "0.0.1",
                 source_rbs_synthesizer: ->(path) { annotated if path.end_with?("memo.rb") })
      end
      services = Rigor::Plugin::Services.new(
        reflection: Rigor::Reflection, type: Rigor::Type::Combinator, configuration: Rigor::Configuration.new
      )
      registry = Rigor::Plugin::Registry.new(plugins: [plugin_class.new(services: services)])
      coordinator = build_coordinator(plugin_registry: registry)

      warm_env = coordinator.send(:prewarm_rbs_cache_for_pool, source_files: ["plain.rb", "memo.rb"])

      expect(warm_env.rbs_loader.virtual_rbs).to eq([["virtual:synth:memo.rb", annotated]])
      expect(Rigor::Effects::SignatureSources.annotated_carrier(warm_env.rbs_loader.virtual_rbs))
        .to eq([["virtual:synth:memo.rb", annotated]])
    end
  end

  # Issue #798 — the SAME gap `analyze_files_in_fork_pool` had: nothing called
  # `#snapshot_project_signature_state` on this backend at all, so `synthesized-namespace` /
  # `quarantined-signature` / the conformance results had no producer under a Ractor-pool run, healthy or
  # not. `workers: 0` reaches every line up to (and stops at) the pool array — `Array.new(0) { ... }` never
  # invokes its block, so no real Ractor is ever spawned — which is how this exercises the coordinator's OWN
  # new pre-dispatch snapshot without tripping the file's own DECLINED note below (never driving the pool
  # backend's worker-spawning body for real).
  describe "#analyze_files_in_pool project-signature state (issue #798)" do
    it "snapshots the project-signature state and its definition-build failures off the cache-prewarm " \
       "environment before any worker is dispatched" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      cache_store = instance_double(Rigor::Cache::Store, root: "/tmp/rigor-798-cache-root-stub")
      coordinator = build_coordinator(workers: 0, cache_store: cache_store, snapshots: snapshots)
      failure = ["Acme", "RBS::DuplicatedMethodDefinitionError", "::Acme#label", ["sig/acme.rbs"]]
      loader = instance_double(Rigor::Environment::RbsLoader, definition_build_failures: [failure], virtual_rbs: [])
      warm_env = instance_double(Rigor::Environment, rbs_loader: loader)
      allow(coordinator).to receive(:prewarm_rbs_cache_for_pool).and_return(warm_env)
      allow(coordinator).to receive(:snapshot_project_signature_state)

      result = coordinator.analyze_files_in_pool([], source_files: [])

      expect(result).to eq([])
      expect(coordinator).to have_received(:snapshot_project_signature_state).with(warm_env)
      expect(snapshots.definition_build_failures).to eq([failure])
    end
  end

  # The inline stratum of `effect.annotations-unchecked` had the same shape of gap on this backend as #798:
  # every other analysis path snapshots the effect-annotation carrier, and this one never did, so an effect
  # annotation living only in an rbs-inline comment had no producer under `RIGOR_POOL_BACKEND=ractor` — on
  # a healthy run, with no worker lost. Same harness as the #798 example above: `workers: 0` reaches the
  # coordinator's own pre-dispatch reads and spawns no Ractor. The prewarm is handed the WHOLE project
  # (`source_files:`), never the analyze set — the buffer that carries the annotation may belong to a file
  # this run does not analyse.
  describe "#analyze_files_in_pool effect-annotation carrier" do
    it "carries the first effect-annotated virtual buffer off the cache-prewarm environment, built over " \
       "the whole project, before any worker is dispatched" do
      snapshots = Rigor::Analysis::Runner::RunSnapshots.new
      cache_store = instance_double(Rigor::Cache::Store, root: "/tmp/rigor-ractor-carrier-cache-root-stub")
      coordinator = build_coordinator(workers: 0, cache_store: cache_store, snapshots: snapshots)
      loader = instance_double(
        Rigor::Environment::RbsLoader,
        virtual_rbs: [["virtual:x:plain.rb", "class Plain\nend\n"],
                      ["virtual:x:memo.rb", "class Memo\n  %a{pure}\n  def value: () -> Integer\nend\n"]],
        definition_build_failures: []
      )
      warm_env = instance_double(Rigor::Environment, rbs_loader: loader)
      allow(coordinator).to receive(:prewarm_rbs_cache_for_pool).and_return(warm_env)
      allow(coordinator).to receive(:snapshot_project_signature_state)

      coordinator.analyze_files_in_pool([], source_files: ["plain.rb", "memo.rb"])

      expect(coordinator).to have_received(:prewarm_rbs_cache_for_pool).with(source_files: ["plain.rb", "memo.rb"])
      expect(snapshots.effect_annotation_carrier.map(&:first)).to eq(["virtual:x:memo.rb"])
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
      built = instance_double(Rigor::Environment, rbs_loader: nil, hkt_registry: nil, hkt_scan_failure: nil)
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
      built = instance_double(Rigor::Environment, rbs_loader: loader, hkt_registry: nil, hkt_scan_failure: nil)
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
      built = instance_double(Rigor::Environment, rbs_loader: loader, hkt_registry: nil, hkt_scan_failure: nil)
      allow(coordinator).to receive(:build_runner_environment).and_return(built)

      coordinator.send(:analyze_files_sequentially_fallback, ["a.rb"], reason: "x")

      expect(snapshots.quarantined_signatures).to eq([])
      expect(snapshots.env_build_failure).to be_nil
    end
  end
end
