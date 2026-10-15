# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/plugin/base"

# Issue #1900 — a plugin's trust-policy refusals ({Rigor::Plugin::IoBoundary}) surface as one
# `plugin_trust.read-refused` row per plugin, and that row has to be the same whatever `--workers` says.
# A pooled run makes its reads on the pre-fork parent session (`#prepare`) and in each worker (per-file
# analysis), none of which is the coordinator-side registry the row used to be read from, so `--workers 2`
# printed nothing where `--workers 0` printed the row. The pool's sequential fallback ran no `#prepare` at
# all.
RSpec.describe "Trust-policy refusal rows under the worker pool (#1900)" do
  unless defined?(Rigor::Plugin::PooledTrustRefusalProbe)
    Rigor::Plugin.const_set(
      :PooledTrustRefusalProbe,
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "pooled-trust-refusal-probe", version: "0.1.0")

        # What the probe reads, set per example. Read in whichever process runs the plugin; a fork child
        # inherits it.
        class << self
          attr_accessor :settings
        end

        # `#init` runs on every registry a run materialises — the coordinator's, the pool's parent session's,
        # each worker's, a null recheck's throwaway — not only on the one that analyses.
        def init(_services)
          read_refused(self.class.settings[:init_read]) if self.class.settings[:init_read]
        end

        def prepare(_services)
          self.class.settings[:prepare_calls] += 1
          read_refused(self.class.settings[:prepare_read]) if self.class.settings[:prepare_read]
          raise StandardError, "prepare boom" if self.class.settings[:prepare_raises]
        end

        # One refused read per file, each naming its own file, so the reported first path also pins the
        # order the counts were merged in.
        # `crash_on` kills a fork child (never the parent, which re-analyses the dead child's slice) when it
        # reaches that file, before the file's read.
        def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
          settings = self.class.settings
          exit!(1) if File.basename(path) == settings[:crash_on] && Process.pid != settings[:parent_pid]
          read_refused("/rigor-refused-#{File.basename(path)}") if settings[:file_reads]
          []
        end

        private

        def read_refused(path)
          io_boundary.read_file(path)
        rescue Rigor::Plugin::AccessDeniedError
          nil
        end
      end
    )
  end

  before do
    Rigor::Plugin.unregister!
    probe.settings = { init_read: nil, prepare_read: nil, file_reads: false, prepare_raises: false,
                       prepare_calls: 0, crash_on: nil, parent_pid: Process.pid }
  end

  after { Rigor::Plugin.unregister! }

  def probe = Rigor::Plugin::PooledTrustRefusalProbe

  def requirer
    lambda do |_name|
      Rigor::Plugin.register(probe)
      true
    end
  end

  def project(dir)
    %w[a b c].each { |name| File.write(File.join(dir, "#{name}.rb"), "#{name} = 1\n") }
  end

  def configuration(dir)
    Rigor::Configuration.new("paths" => [dir], "plugins" => ["rigor-pooled-trust-refusal-probe"])
  end

  def run(dir, workers)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir), cache_store: nil, plugin_requirer: requirer, workers: workers
    )
    guarded_run(runner, allow_plugin_crash: true).diagnostics
  end

  def refusal_rows(diagnostics)
    diagnostics.select { |d| d.rule == "plugin_trust.read-refused" }.map(&:to_h)
  end

  def first_refused_path(row)
    row["message"][/first refused path: "([^"]+)"/, 1]
  end

  def read_count(row)
    Integer(row["message"][/had (\d+) read\(s\)/, 1])
  end

  context "with the fork pool" do
    before { skip "fork is unavailable on this platform" unless Process.respond_to?(:fork) }

    {
      "a refusal in `#prepare` only" => [{ prepare_read: "/etc/hosts" }, 1, "/etc/hosts"],
      "refusals in per-file analysis only" => [{ file_reads: true }, 3, "/rigor-refused-a.rb"],
      "refusals in both" => [{ prepare_read: "/etc/hosts", file_reads: true }, 4, "/etc/hosts"],
      # The coordinator-side registry reports `#init`'s reads; the workers' drains start after `#init`, so
      # the reads are neither lost nor counted twice, and the coordinator's path is named first.
      "a refusal in `#init` only" => [{ init_read: "/etc/shells" }, 1, "/etc/shells"],
      "refusals in `#init`, `#prepare` and per-file analysis" =>
        [{ init_read: "/etc/shells", prepare_read: "/etc/hosts", file_reads: true }, 5, "/etc/shells"]
    }.each do |label, (settings, count, first_path)|
      it "reports #{label} exactly as --workers 0 does, counting every refused attempt once" do
        probe.settings.merge!(settings)
        Dir.mktmpdir do |dir|
          project(dir)
          sequential = refusal_rows(run(dir, 0))
          pooled = refusal_rows(run(dir, 2))

          expect(sequential.size).to eq(1)
          expect(read_count(sequential.first)).to eq(count)
          expect(first_refused_path(sequential.first)).to eq(first_path)
          expect(pooled).to eq(sequential)
        end
      end
    end

    # The child holding [a.rb, b.rb] dies on a.rb; the parent re-analyses that slice after the surviving
    # child (c.rb) has reported. The refusals are merged in file order regardless.
    it "names the sequential run's first path when a worker's slice is re-analysed in process" do
      probe.settings.merge!(file_reads: true, crash_on: "a.rb")
      Dir.mktmpdir do |dir|
        project(dir)
        sequential = run(dir, 0)
        pooled = run(dir, 2)

        expect(pooled.map(&:rule)).to include("pool-degraded")
        expect(first_refused_path(refusal_rows(sequential).first)).to eq("/rigor-refused-a.rb")
        expect(refusal_rows(pooled)).to eq(refusal_rows(sequential))
      end
    end

    it "adds no row for a plugin that has no refusals" do
      Dir.mktmpdir do |dir|
        project(dir)
        expect(refusal_rows(run(dir, 0))).to be_empty
        expect(refusal_rows(run(dir, 2))).to be_empty
      end
    end

    it "keeps a raising `#prepare`'s error row and the refusal it made first" do
      probe.settings.merge!(prepare_read: "/etc/hosts", prepare_raises: true)
      Dir.mktmpdir do |dir|
        project(dir)
        sequential = run(dir, 0)
        pooled = run(dir, 2)

        prepare_errors = ->(rows) { rows.select { |d| d.message.include?("raised during prepare") }.map(&:to_h) }
        expect(prepare_errors.call(sequential).size).to eq(1)
        expect(prepare_errors.call(pooled)).to eq(prepare_errors.call(sequential))
        expect(refusal_rows(pooled)).to eq(refusal_rows(sequential))
        expect(read_count(refusal_rows(pooled).first)).to eq(1)
      end
    end

    # A nothing-changed recheck through the session API analyses no file, so only the run's `#init` and
    # `#prepare` reads are made again: both on the coordinator registry sequentially; pooled, `#init` there
    # and `#prepare` on a throwaway registry (#1541) whose own `#init` is not counted. Both report those two
    # refusals; the cold run's per-file refusals are not replayed in either mode.
    it "reports the same row on an incremental null recheck" do
      probe.settings.merge!(init_read: "/etc/shells", prepare_read: "/etc/hosts", file_reads: true)
      Dir.mktmpdir do |dir|
        project(dir)
        rechecks = [0, 2].map do |workers|
          session = Rigor::Analysis::IncrementalSession.new(
            configuration: configuration(dir), paths: [dir], plugin_requirer: requirer, workers: workers
          )
          guarded_baseline(session, allow_plugin_crash: true)
          recheck = guarded_recheck(session, allow_plugin_crash: true)
          expect(recheck.affected).to be_empty
          refusal_rows(recheck.diagnostics)
        end

        expect(rechecks.first.size).to eq(1)
        expect(read_count(rechecks.first.first)).to eq(2)
        expect(rechecks.last).to eq(rechecks.first)
      end
    end
  end

  # The pool's no-worker fallback, reached here the way the CLI reaches it on any platform: the Ractor
  # backend refuses to run without a cache store and degrades before spawning anything.
  context "with the sequential fallback" do
    around do |example|
      original = ENV.fetch("RIGOR_POOL_BACKEND", nil)
      ENV["RIGOR_POOL_BACKEND"] = "ractor"
      example.run
    ensure
      original.nil? ? ENV.delete("RIGOR_POOL_BACKEND") : (ENV["RIGOR_POOL_BACKEND"] = original)
    end

    def without_degrade_row(diagnostics)
      diagnostics.reject { |d| d.rule == "pool-degraded" }.map(&:to_h).sort_by(&:to_s)
    end

    it "runs `#prepare` exactly once and reports what --workers 0 reports" do
      probe.settings.merge!(prepare_read: "/etc/hosts", file_reads: true)
      Dir.mktmpdir do |dir|
        project(dir)
        sequential = run(dir, 0)
        probe.settings[:prepare_calls] = 0
        fallback = run(dir, 2)

        expect(fallback.map(&:rule)).to include("pool-degraded")
        expect(probe.settings[:prepare_calls]).to eq(1)
        expect(read_count(refusal_rows(fallback).first)).to eq(4)
        expect(without_degrade_row(fallback)).to eq(without_degrade_row(sequential))
      end
    end

    it "keeps a raising `#prepare`'s error row" do
      probe.settings.merge!(prepare_raises: true)
      Dir.mktmpdir do |dir|
        project(dir)
        sequential = run(dir, 0)
        fallback = run(dir, 2)

        expect(sequential.map(&:message).grep(/raised during prepare/).size).to eq(1)
        expect(without_degrade_row(fallback)).to eq(without_degrade_row(sequential))
      end
    end
  end
end
