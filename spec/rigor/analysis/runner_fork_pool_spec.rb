# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require "rigor/analysis/runner"
require "rigor/configuration"
require "rigor/plugin"

# ADR-15 Amendment (2026-05-20) — fork-pool equivalence.
#
# `workers: N > 0` dispatches per-file analysis across a fork-based worker pool — the active backend (the Ractor pool is
# preserved only behind `RIGOR_POOL_BACKEND=ractor`). Unlike the Ractor pool — which crashes (~70 % of runs, Ruby Bug
# #22075) and otherwise emits 100 % `Ractor::IsolationError` diagnostics — the fork pool runs each worker in a separate
# process, so it is memory-safe and this spec runs in the DEFAULT suite (no `RIGOR_INCLUDE_RACTOR_POOL` gate).
#
# Contract: the fork pool produces the same diagnostic stream as the sequential path AND does real analysis (never an
# `internal analyzer error`).
RSpec.describe "Rigor::Analysis::Runner with fork pool (ADR-15 Amendment)" do
  # Per-file diagnostic comparison key. Severity is stripped — the severity-profile re-stamping is identical on both
  # code paths.
  def diag_keys(diagnostics)
    diagnostics.map do |d|
      [d.path, d.line, d.column, d.rule, d.source_family, d.message]
    end.sort
  end

  def run_check(dir, paths, config: {}, **runner_kwargs)
    configuration = Rigor::Configuration.new({ "paths" => paths }.merge(config))
    Dir.chdir(dir) do
      runner = Rigor::Analysis::Runner.new(configuration: configuration, **runner_kwargs)
      guarded_run(runner).diagnostics
    end
  end

  # Two-file fixture for the cross-file seed regression: `Widget` is RBS-known via `signature_paths:` while
  # `Widget#render` is defined in a different source file than its caller. Returns the definition path, the caller path,
  # and the configuration entries.
  # The receiver is a BUNDLED class reopened by the project, not a project class with a sidecar `sig/`.
  # Issue #735 made that distinction load-bearing: on the project's own sidecar declaration a cross-file
  # `def` is the class's own second file and is suppressed, so the fixture that used one stopped producing
  # the ADR-17 diagnostic this spec observes. Reopening `String` keeps the observable — the RBS is
  # authoritative, the project `def` IS a monkey-patch, and the message still has to carry the def site
  # that only the seeded `discovered_def_sources` table can supply.
  def write_cross_file_fixture(dir)
    defn = File.join(dir, "a_widget.rb")
    File.write(defn, <<~RUBY)
      class String
        def render
          "ok"
        end
      end
    RUBY
    caller_path = File.join(dir, "b_board.rb")
    File.write(caller_path, <<~RUBY)
      class Board
        def show
          "x".render
        end
      end
    RUBY
    [defn, caller_path, {}]
  end

  describe "equivalence with the sequential path" do
    it "returns an empty diagnostic stream when no files are configured" do
      Dir.mktmpdir do |dir|
        expect(run_check(dir, [dir], cache_store: nil, workers: 2)).to be_empty
      end
    end

    it "matches the sequential per-file diagnostics for a single file (workers: 1)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, "x = 1\n")
        sequential = run_check(dir, [path], cache_store: nil)
        pool = run_check(dir, [path], cache_store: nil, workers: 1)
        expect(diag_keys(pool)).to eq(diag_keys(sequential))
      end
    end

    it "matches the sequential per-file diagnostics for many files (workers: 4)" do
      Dir.mktmpdir do |dir|
        paths = Array.new(6) do |i|
          path = File.join(dir, "file_#{i}.rb")
          File.write(path, "x_#{i} = #{i}\n")
          path
        end
        sequential = run_check(dir, paths, cache_store: nil)
        pool = run_check(dir, paths, cache_store: nil, workers: 4)
        expect(diag_keys(pool)).to eq(diag_keys(sequential))
      end
    end

    it "does real RBS-dispatch analysis in workers — no Ractor::IsolationError" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, <<~RUBY)
          "hello".no_such_method
          [1, 2, 3].rotate(1, 2, 3)
        RUBY
        sequential = run_check(dir, [path],
                               cache_store: Rigor::Cache::Store.new(root: File.join(dir, ".rigor-seq")))
        pool = run_check(dir, [path],
                         cache_store: Rigor::Cache::Store.new(root: File.join(dir, ".rigor-pool")), workers: 2)

        expect(pool.map(&:message).grep(/internal analyzer error/)).to be_empty
        expect(diag_keys(pool).select { |k| %w[call.undefined-method call.wrong-arity].include?(k[3]) }).to eq(
          diag_keys(sequential).select { |k| %w[call.undefined-method call.wrong-arity].include?(k[3]) }
        )
      end
    end

    it "runs the pool without a cache_store — fork has no shareability precondition" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "code.rb")
        File.write(path, %("hello".no_such_method\n))
        pool = run_check(dir, [path], cache_store: nil, workers: 2)

        expect(pool.map(&:rule)).not_to include("pool-degraded")
        expect(pool.map(&:message).grep(/internal analyzer error/)).to be_empty
      end
    end

    it "carries the cross-file project pre-pass seed into worker scopes " \
       "(regression: workers emitted call.undefined-method false positives)" do
      Dir.mktmpdir do |dir|
        # Regression for the fork-pool seeding gap observed on rigor's own self-check (`--workers 2` emitted 20
        # cross-file `call.undefined-method` errors the sequential path did not): {WorkerSession#analyze} built its
        # per-file scope from `Scope.empty` without `Runner#seed_project_scope`'s cross-file discovery tables. This
        # fixture makes the seed observable in the diagnostic STREAM: the receiver class is RBS-known via
        # `signature_paths:` while `render` is defined in a different source file, so the ADR-17 diagnostic both paths
        # emit must carry the `project defines ... at a_widget.rb:2` site, which only the seeded
        # `discovered_def_sources` table can supply — an unseeded worker produces a different message and breaks the
        # byte-identical sequential-equivalence contract.
        defn, caller_path, config = write_cross_file_fixture(dir)
        sequential = run_check(dir, [defn, caller_path], config: config, cache_store: nil)
        # workers: 2 puts each file in its own slice, so the worker analysing b_board.rb never parses a_widget.rb itself
        # — it can only resolve `Widget#render` through the seeded pre-pass tables.
        pool = run_check(dir, [defn, caller_path], config: config, cache_store: nil, workers: 2)

        # Guard the fixture itself: the sequential diagnostic must carry the cross-file definition site, or the
        # equivalence assertion below would pass vacuously on two unseeded streams.
        expect(sequential.map(&:message)).to include(a_string_matching(/a_widget\.rb:2/))
        expect(diag_keys(pool)).to eq(diag_keys(sequential))
      end
    end

    it "preserves original path order even when workers complete out of order" do
      Dir.mktmpdir do |dir|
        paths = Array.new(8) do |i|
          path = File.join(dir, "f#{i}.rb")
          File.write(path, %("x".no_such_method_#{i}\n))
          path
        end
        pool = run_check(dir, paths, cache_store: nil, workers: 3)
        expect(pool.map(&:path).uniq).to eq(paths)
      end
    end
  end

  # Issue #798 — `PoolCoordinator#analyze_files_in_fork_pool` never called
  # `#snapshot_project_signature_state`, so the project-signature state (`synthesized-namespace`,
  # `quarantined-signature`, `definition-build-failed`) — which has no per-file producer, only a snapshot
  # read off the run's OWN environment — had no producer at all under `--workers N`. The two slots the fork
  # pool DID cover through a separate stats-only helper (`quarantined-signature`,
  # `environment-build-failed`) were also gated on `@collect_stats`, so a `--workers N --no-stats` run
  # reported LESS than the sequential path over the identical project (observed: `rigor check` reported
  # `quarantined-signature` + `synthesized-namespace`; `--workers=2` reported `quarantined-signature` only;
  # `--workers=2 --no-stats` reported neither).
  describe "project-signature state through the fork pool (issue #798)" do
    # `data-contrast:` is a record key `rbs` rejects, so `broken.rbs` is quarantined; the qualified
    # declaration with no enclosing `module Acme` is the namespace the loader has to synthesize; `DupDemo`
    # is declared twice (once under a `conforms-to` directive so the conformance scan — itself run INSIDE
    # `#snapshot_project_signature_state` — demands its instance definition and so triggers the build
    # failure even though no analysed `.rb` file ever names the class).
    def write_signature_state_fixture(dir)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "a.rb"), "x = 1\n")
      File.write(File.join(dir, "sig", "broken.rbs"), "class Broken\n  def h: () -> { data-contrast: Integer }\nend\n")
      File.write(File.join(dir, "sig", "widget.rbs"), "class Acme::Widget\n  def size: () -> Integer\nend\n")
      File.write(File.join(dir, "sig", "dup.rbs"), <<~RBS)
        interface _Reads
          def read: () -> String
        end

        %a{rigor:v1:conforms-to _Reads}
        class DupDemo
          def read: () -> String
        end
      RBS
      File.write(File.join(dir, "sig", "dup2.rbs"), "class DupDemo\n  def read: () -> String\nend\n")
      { "signature_paths" => [File.join(dir, "sig")] }
    end

    # `[quarantined-signature, synthesized-namespace, definition-build-failed]` counts — mirrors
    # `incremental_session_spec.rb`'s `project_signature_counts` helper for the same fixture shape.
    def signature_state_counts(diagnostics)
      %w[rbs.coverage.quarantined-signature rbs.coverage.synthesized-namespace
         rbs.coverage.definition-build-failed].map { |rule| diagnostics.count { |d| d.qualified_rule == rule } }
    end

    it "reports the same quarantined/synthesized/definition-build rows as the sequential path" do
      Dir.mktmpdir do |dir|
        config = write_signature_state_fixture(dir)
        paths = [File.join(dir, "a.rb")]
        sequential = run_check(dir, paths, config: config, cache_store: nil)
        pool = run_check(dir, paths, config: config, cache_store: nil, workers: 2)

        # Guards the fixture itself: a vacuous 0/0/0 on both sides would pass the equality below for the
        # wrong reason.
        expect(signature_state_counts(sequential)).to eq([1, 1, 1])
        expect(signature_state_counts(pool)).to eq(signature_state_counts(sequential))
      end
    end

    it "reports the same rows under --no-stats (collect_stats: false), on both the sequential and " \
       "pooled paths" do
      Dir.mktmpdir do |dir|
        config = write_signature_state_fixture(dir)
        paths = [File.join(dir, "a.rb")]
        sequential = run_check(dir, paths, config: config, cache_store: nil, collect_stats: false)
        pool = run_check(dir, paths, config: config, cache_store: nil, workers: 2, collect_stats: false)

        expect(signature_state_counts(sequential)).to eq([1, 1, 1])
        expect(signature_state_counts(pool)).to eq([1, 1, 1])
      end
    end
  end

  # Issue #805 — `WorkerSession#drain_reporters` ships the reporter home with `Marshal.dump`, and the
  # `RbsExtended::Reporter`'s unresolved / lossy-projection entries used to carry the `RBS::Location`
  # itself, which is a C-extension object with no `_dump`. Any project whose `sig/` produced even one such
  # event therefore killed every worker at drain time — after its files were analysed — and the run
  # degraded to in-process re-analysis: correct diagnostics, no parallelism, plus a `pool-degraded` warning
  # the project could do nothing about. Observed on `%a{rigor:v1:return: <unknown refinement>}`.
  describe "an unresolvable RBS::Extended payload through the fork pool (issue #805)" do
    # Four callers so more than one worker reads the same annotation: the coordinator's merge has to
    # collapse their copies on the entry's primitives, or `--workers=N` prints N rows where `--workers=0`
    # prints one.
    def write_unresolved_directive_fixture(dir)
      FileUtils.mkdir_p(File.join(dir, "sig"))
      File.write(File.join(dir, "sig", "widget.rbs"), <<~RBS)
        class Widget
          %a{rigor:v1:return: not-a-known-refinement}
          def label: () -> String
        end
      RBS
      paths = Array.new(4) do |i|
        path = File.join(dir, "caller_#{i}.rb")
        File.write(path, "class Caller#{i}\n  def go\n    Widget.new.label\n  end\nend\n")
        path
      end
      [paths, { "signature_paths" => [File.join(dir, "sig")] }]
    end

    def unresolved_rows(diagnostics)
      diagnostics.count { |d| d.rule == "dynamic.rbs-extended.unresolved" }
    end

    it "keeps the pool intact and reports the one row the sequential run reports" do
      Dir.mktmpdir do |dir|
        paths, config = write_unresolved_directive_fixture(dir)
        sequential = run_check(dir, paths, config: config, cache_store: nil)
        pool = run_check(dir, paths, config: config, cache_store: nil, workers: 4)

        # Guards the fixture itself: a payload that RESOLVES would make every assertion below vacuous.
        expect(unresolved_rows(sequential)).to eq(1)
        expect(pool.map(&:rule)).not_to include("pool-degraded")
        expect(unresolved_rows(pool)).to eq(1)
        expect(diag_keys(pool)).to eq(diag_keys(sequential))
      end
    end
  end

  # ADR-46 — the fork pool must MARSHAL each worker's cross-file dependency records back, or a pooled
  # `--incremental` recheck would leave the dependency graph un-refreshed and serve stale diagnostics on the
  # next round. Runs `record_dependencies: true` sequentially and pooled and asserts the recorded edges match.
  describe "dependency recording through the fork pool" do
    def recording_runner(dir, paths, config, **runner_kwargs)
      configuration = Rigor::Configuration.new({ "paths" => paths }.merge(config))
      Dir.chdir(dir) do
        runner = Rigor::Analysis::Runner.new(
          configuration: configuration, record_dependencies: true, **runner_kwargs
        )
        guarded_run(runner)
        runner
      end
    end

    it "captures the same cross-file dependency edges as the sequential path" do
      Dir.mktmpdir do |dir|
        defn, caller_path, config = write_cross_file_fixture(dir)
        paths = [defn, caller_path]
        sequential = recording_runner(dir, paths, config).file_dependencies
        pool = recording_runner(dir, paths, config, workers: 2).file_dependencies

        # The pool run must record — not silently drop — the caller's read of the definition file.
        expect(pool).not_to be_empty
        expect(pool[caller_path]&.sources).to include(defn)
        expect(pool.transform_values(&:sources)).to eq(sequential.transform_values(&:sources))
      end
    end
  end

  # A `fork` copies only the calling thread, so the parent's deferred-YJIT deadline thread (armed by `check` /
  # `coverage`) does NOT survive into a worker. Each worker must therefore re-arm its own deferred YJIT, or a
  # worker forked before the deadline fires would run its whole analysis slice un-JITted no matter how long it
  # runs — exactly the case parallel mode exists for. `rearm_after_fork` owns the remaining-deadline
  # arithmetic; this only asserts the worker calls it. `run_fork_worker` uses no instance state, so it is
  # driven here with `allocate` + a session double (a real fork would run in a child process where a `receive`
  # spy on the parent cannot observe the call).
  describe "deferred YJIT in the fork worker" do
    let(:coordinator) { Rigor::Analysis::Runner::PoolCoordinator.allocate }
    let(:session) do
      instance_double(
        Rigor::Analysis::WorkerSession, analyze: [], drain_reporters: {}, drain_dependencies: {}
      )
    end

    it "re-arms deferred YJIT before analysing its slice" do
      Dir.mktmpdir do |dir|
        out_path = File.join(dir, "payload")
        allow(coordinator).to receive(:exit!) # keep the worker body in-process
        allow(Rigor::Runtime::Jit).to receive(:rearm_after_fork)

        coordinator.send(:run_fork_worker, session, ["a.rb"], out_path)

        expect(Rigor::Runtime::Jit).to have_received(:rearm_after_fork)
      end
    end
  end
end
