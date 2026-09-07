# frozen_string_literal: true

# Issue #784 — a shared, memoised sub-build that raises during per-file analysis is caught by every
# file's `analyze_body` rescue and turned into the SAME `internal analyzer error` row. The run then
# looks almost clean (N identical rows, non-zero exit, nothing saying the analyzer never ran). The
# aggregator folds those N rows into one sample plus one `analyzer.internal-error` run-level summary.
#
# This file drives `Rigor::Analysis::Runner#run` directly and reads the raw `Result`, because its
# subject IS the crash envelope: routing through `guarded_run` / `RunnerHelpers#analyze` would raise
# `InternalAnalyzerErrorGuard::AnalyzerCrashed` before the collapse could be inspected. The single run
# site is registered in `spec/docs/spec_analyzer_guard_spec.rb`'s allowlist.
require "spec_helper"
require "rigor/analysis/runner"

RSpec.describe "a shared analyzer sub-build that raises on every file (issue #784)" do
  it "collapses the N identical internal-error rows into one sample plus one run-level summary" do
    allow(Rigor::Analysis::CheckRules).to receive(:diagnose)
      .and_raise(RuntimeError, "shared sub-build is broken")

    Dir.mktmpdir do |dir|
      %w[a b c].each { |n| File.write(File.join(dir, "#{n}.rb"), "x = 1\n") }
      configuration = Rigor::Configuration.new("paths" => [dir])

      result = Dir.chdir(dir) do
        Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil).run
      end

      crash_rows = result.diagnostics.select do |d|
        Rigor::Analysis::CrashSignature.reason(d) == :check_rule
      end
      summary = crash_rows.find { |d| d.rule == "analyzer.internal-error" }

      # One retained per-file sample + one run-level summary, not one row per file.
      expect(crash_rows.size).to eq(2)
      expect(summary).not_to be_nil
      expect(summary.path).to eq(".rigor.yml")
      expect(summary.severity).to eq(:error)
      expect(summary.message).to include("shared sub-build is broken")
      expect(summary.message).to include("of 3 file(s)")
      expect(result).not_to be_success
    end
  end
end
