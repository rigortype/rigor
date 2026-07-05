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
      Rigor::Analysis::Runner.new(configuration: configuration, **runner_kwargs).run.diagnostics
    end
  end

  # Two-file fixture for the cross-file seed regression: `Widget` is RBS-known via `signature_paths:` while
  # `Widget#render` is defined in a different source file than its caller. Returns the definition path, the caller path,
  # and the configuration entries.
  def write_cross_file_fixture(dir)
    FileUtils.mkdir_p(File.join(dir, "sig"))
    File.write(File.join(dir, "sig", "widget.rbs"), "class Widget\nend\n")
    defn = File.join(dir, "a_widget.rb")
    File.write(defn, <<~RUBY)
      class Widget
        def render
          "ok"
        end
      end
    RUBY
    caller_path = File.join(dir, "b_board.rb")
    File.write(caller_path, <<~RUBY)
      class Board
        def show
          Widget.new.render
        end
      end
    RUBY
    [defn, caller_path, { "signature_paths" => [File.join(dir, "sig")] }]
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
end
