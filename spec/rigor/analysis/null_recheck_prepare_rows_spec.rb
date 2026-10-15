# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/plugin/base"

# Issue #1541 — a plugin's `#prepare` owes every run its rows: the `runtime-error` row when it raises (at
# `.rigor.yml`), and the run-scoped `#disclose_once` / `#emit_once` registrations it makes. A pooled run's
# `#prepare` happens inside its workers, so a nothing-changed `--incremental --workers N` recheck, which
# analyses an empty closure and dispatches none, used to drop all of them — turning a red project green on
# its second run.
RSpec.describe Rigor::Analysis::IncrementalSession, "null recheck keeps the plugin `#prepare` rows" do # rubocop:disable RSpec/DescribeMethod,RSpec/SpecFilePathFormat
  unless defined?(Rigor::Plugin::NullRecheckPrepareRaises)
    Rigor::Plugin.const_set(
      :NullRecheckPrepareRaises,
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "null-recheck-prepare-raises", version: "0.1.0")

        def prepare(_services)
          disclose_once(:note, message: "prepare-time disclosure")
          emit_once(:batch, [Rigor::Analysis::Diagnostic.new(
            path: "a.rb", line: 1, column: 1, message: "prepare-time batch row",
            severity: :warning, rule: "batch", source_family: :plugin_loader
          )])
          raise StandardError, "prepare boom"
        end
      end
    )
    # A refused read in `#prepare` is recorded on the plugin instance and surfaces as an info row. Since
    # #1900 a pooled run shows it too, and a pooled null recheck, which runs `#prepare` on a throwaway
    # registry, must show the same row.
    Rigor::Plugin.const_set(
      :NullRecheckPrepareRefused,
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "null-recheck-prepare-refused", version: "0.1.0")

        def prepare(_services)
          io_boundary.read_file("/etc/hosts")
        rescue Rigor::Plugin::AccessDeniedError
          nil
        end
      end
    )
  end

  def requirer_for(plugin_class)
    lambda do |_name|
      Rigor::Plugin.register(plugin_class)
      true
    end
  end

  def project(dir)
    File.write(File.join(dir, "a.rb"), "Rigor.dump_type(1)\n")
    File.write(File.join(dir, "b.rb"), "y = 2\n")
  end

  def configuration(dir, plugin_id)
    Rigor::Configuration.new("paths" => [dir], "plugins" => [plugin_id],
                             "pre_eval" => [File.join(dir, "missing_pre_eval.rb")])
  end

  def full_run(dir, workers, plugin_id: raising_id, plugin_class: Rigor::Plugin::NullRecheckPrepareRaises)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir, plugin_id), cache_store: nil,
      plugin_requirer: requirer_for(plugin_class), workers: workers
    )
    guarded_run(runner, allow_plugin_crash: true)
  end

  def raising_id = "rigor-null-recheck-prepare-raises"

  def session(dir, workers, plugin_id: raising_id, plugin_class: Rigor::Plugin::NullRecheckPrepareRaises)
    described_class.new(configuration: configuration(dir, plugin_id), paths: [dir],
                        plugin_requirer: requirer_for(plugin_class), workers: workers)
  end

  def prepare_rows(diagnostics)
    diagnostics.select { |d| d.rule == "runtime-error" && d.message.include?("raised during prepare") }
  end

  def hashes(diagnostics) = diagnostics.map(&:to_h)

  [0, 2].each do |workers|
    context "with workers: #{workers}" do
      before { skip "fork is unavailable on this platform" if workers.positive? && !Process.respond_to?(:fork) }

      it "serves the full run's diagnostics, in its order, on a null recheck" do
        Dir.mktmpdir do |dir|
          project(dir)
          expected = full_run(dir, workers).diagnostics
          rules = expected.map(&:rule)
          expect(prepare_rows(expected).size).to eq(1)
          expect(rules).to include("pre-eval.file-not-found", "batch")
          expect(expected.map(&:message)).to include("prepare-time disclosure")

          subject_session = session(dir, workers)
          guarded_baseline(subject_session, allow_plugin_crash: true)
          recheck = guarded_recheck(subject_session, allow_plugin_crash: true)

          expect(recheck.affected).to be_empty
          expect(hashes(recheck.diagnostics)).to eq(hashes(expected))
        end
      end

      it "keeps every row on a warm `run_incremental` null run" do
        Dir.mktmpdir do |dir|
          project(dir)
          expected = full_run(dir, workers).diagnostics
          snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))

          runs = Array.new(2) do
            guarded_run_incremental(session(dir, workers), snapshot: snapshot, fingerprint: "fp-1541",
                                                           allow_plugin_crash: true)
          end

          expect(runs.last.last).to be(true)
          runs.map(&:first).each { |diagnostics| expect(hashes(diagnostics)).to eq(hashes(expected)) }
        end
      end

      it "keeps the prepare row for a project with no Ruby files" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "notes.txt"), "no ruby here\n")
          expected = full_run(dir, workers).diagnostics

          expect(prepare_rows(expected).size).to eq(1)
        end
      end
    end
  end

  context "with a `#prepare` whose read the trust policy refuses" do
    before { skip "fork is unavailable on this platform" unless Process.respond_to?(:fork) }

    it "serves a pooled null recheck byte for byte what the pooled cold run printed" do
      Dir.mktmpdir do |dir|
        project(dir)
        refused = { plugin_id: "rigor-null-recheck-prepare-refused",
                    plugin_class: Rigor::Plugin::NullRecheckPrepareRefused }
        # Positive control: the refusal is real, so the pooled comparison below cannot pass vacuously.
        expect(full_run(dir, 0, **refused).diagnostics.map(&:rule)).to include("plugin_trust.read-refused")
        expected = full_run(dir, 2, **refused).diagnostics

        subject_session = session(dir, 2, **refused)
        guarded_baseline(subject_session, allow_plugin_crash: true)
        recheck = guarded_recheck(subject_session, allow_plugin_crash: true)

        expect(hashes(recheck.diagnostics)).to eq(hashes(expected))
        expect(recheck.diagnostics.map(&:rule)).to include("plugin_trust.read-refused")
      end
    end
  end
end
