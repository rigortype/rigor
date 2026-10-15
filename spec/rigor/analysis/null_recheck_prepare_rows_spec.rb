# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rigor/plugin/base"

# Issue #1541 — a plugin whose `#prepare` raises owes every run one `runtime-error` row positioned at
# `.rigor.yml`. A nothing-changed `--incremental` recheck analyses an empty closure, never dispatches the
# pool, and (in pool mode) the coordinator skips `#prepare` — so the row used to appear nowhere and a red
# project turned green on its second run.
RSpec.describe Rigor::Analysis::IncrementalSession, "null recheck keeps the plugin `#prepare` row" do # rubocop:disable RSpec/DescribeMethod,RSpec/SpecFilePathFormat
  unless defined?(Rigor::Plugin::NullRecheckPrepareRaises)
    Rigor::Plugin.const_set(
      :NullRecheckPrepareRaises,
      Class.new(Rigor::Plugin::Base) do
        manifest(id: "null-recheck-prepare-raises", version: "0.1.0")

        def prepare(_services)
          raise StandardError, "prepare boom"
        end
      end
    )
  end

  let(:requirer) do
    lambda do |_name|
      Rigor::Plugin.register(Rigor::Plugin::NullRecheckPrepareRaises)
      true
    end
  end

  def project(dir)
    File.write(File.join(dir, "a.rb"), "x = 1\n")
    File.write(File.join(dir, "b.rb"), "y = 2\n")
  end

  def configuration(dir)
    Rigor::Configuration.new("paths" => [dir], "plugins" => ["rigor-null-recheck-prepare-raises"])
  end

  def full_run(dir, workers)
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration(dir), cache_store: nil, plugin_requirer: requirer, workers: workers
    )
    guarded_run(runner, allow_plugin_crash: true)
  end

  def prepare_rows(diagnostics)
    diagnostics.select { |d| d.rule == "runtime-error" && d.message.include?("raised during prepare") }
  end

  def session(dir, workers)
    described_class.new(configuration: configuration(dir), paths: [dir], plugin_requirer: requirer, workers: workers)
  end

  [0, 2].each do |workers|
    context "with workers: #{workers}" do
      before { skip "fork is unavailable on this platform" if workers.positive? && !Process.respond_to?(:fork) }

      it "serves the full run's diagnostics, in its order, on a null recheck" do
        Dir.mktmpdir do |dir|
          project(dir)
          expected = full_run(dir, workers)
          expect(prepare_rows(expected.diagnostics).size).to eq(1)

          subject_session = session(dir, workers)
          guarded_baseline(subject_session, allow_plugin_crash: true)
          recheck = guarded_recheck(subject_session, allow_plugin_crash: true)

          expect(recheck.affected).to be_empty
          expect(recheck.diagnostics.map(&:to_h)).to eq(expected.diagnostics.map(&:to_h))
        end
      end

      it "keeps the row on a warm `run_incremental` null run" do
        Dir.mktmpdir do |dir|
          project(dir)
          expected = full_run(dir, workers)
          snapshot = Rigor::Cache::IncrementalSnapshot.new(root: File.join(dir, ".cache"))

          runs = Array.new(2) do
            guarded_run_incremental(session(dir, workers), snapshot: snapshot, fingerprint: "fp-1541",
                                                           allow_plugin_crash: true)
          end

          expect(runs.last.last).to be(true)
          runs.map(&:first).each do |diagnostics|
            expect(diagnostics.map(&:to_h)).to eq(expected.diagnostics.map(&:to_h))
          end
        end
      end
    end
  end
end
