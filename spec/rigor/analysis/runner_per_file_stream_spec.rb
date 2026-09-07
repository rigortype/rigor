# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# #788 rounds 7–8 — `Runner#per_file_diagnostics` is what `IncrementalSession` caches per file and serves to
# reused files WITHOUT re-stamping, so it must be (a) the `analyze_files` return severity-resolved exactly as
# the run's own stream is, and (b) sliced to the rows positioned at the run's targets: a pool backend folds
# `.rigor.yml`-positioned prepare / pool-degraded rows into the same return, and a row that is not a target's
# must never enter the per-file cache. The run's own stream keeps the folded row — the slice is the reader's,
# not the run's.
RSpec.describe "Rigor::Analysis::Runner#per_file_diagnostics" do
  it "is the analyze_files return, stamped and sliced to the targets, while the run keeps the folded row" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "s = \"hi\"\ns.no_such_method_at_all\n")
      configuration = Rigor::Configuration.new(
        "paths" => [dir], "severity_overrides" => { "call.undefined-method" => "warning" }
      )
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
      folded = Rigor::Analysis::Diagnostic.new(
        path: ".rigor.yml", line: 1, column: 1, severity: :warning, rule: nil,
        message: "simulated pool-degraded row folded into the per-file return"
      )
      coordinator = runner.instance_variable_get(:@pool_coordinator)
      allow(coordinator).to receive(:analyze_files).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs) + [folded]
      end

      result = guarded_run(runner, [dir])

      per_file = runner.per_file_diagnostics.map { |d| [File.basename(d.path), d.rule, d.severity] }
      expect(per_file).to eq([["a.rb", "call.undefined-method", :warning]])
      expect(runner.per_file_diagnostics).to be_frozen
      expect(result.diagnostics).to include(folded)
    end
  end

  # The reader is assigned on the analysis (miss) path only, so it is reset per run: a second `#run` of the
  # same runner that the ADR-45 result cache serves must not answer with the first run's rows. Unreachable
  # through `IncrementalSession` (its runners record dependencies or narrow, which excludes the result
  # cache), so this pins the reader's own contract rather than a consumer's.
  it "answers [] on a run the result cache serves instead of the previous run's rows" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.rb"), "s = \"hi\"\ns.no_such_method_at_all\n")
      configuration = Rigor::Configuration.new("paths" => [dir])
      store = Rigor::Cache::Store.new(root: File.join(dir, ".rigor", "cache"))
      runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: store)

      first = guarded_run(runner, [dir])
      expect(runner.per_file_diagnostics.map(&:rule)).to eq(["call.undefined-method"])

      second = guarded_run(runner, [dir])
      expect(runner.instance_variable_get(:@run_served_from_cache)).to be(true)
      expect(second.diagnostics.map(&:to_h)).to eq(first.diagnostics.map(&:to_h))
      expect(runner.per_file_diagnostics).to eq([])
    end
  end
end
