# frozen_string_literal: true

# The verdict of the per-PR engine allocation A/B (`tool/engine_alloc_ab.rb`, issue #1507).
#
# The job is advisory, so the only thing it can get wrong silently is the verdict: a comparison that reads the band
# backwards, or reports an improvement as a regression, still prints a plausible table. Unit test only; requiring
# the script defines {EngineAllocAB} without running an engine (the `$PROGRAM_NAME` guard at its bottom).
require "spec_helper"
require "tmpdir"

require_relative "../../tool/engine_alloc_ab"

RSpec.describe "tool/engine_alloc_ab.rb (#1507)" do
  def run(allocations, digest = "same")
    { "allocations" => allocations, "wall_s" => 1.0, "diagnostics" => 1, "output_digest" => digest }
  end

  describe ".compare" do
    it "flags a head that allocates more than the band over the base" do
      verdict = EngineAllocAB.compare(run(1_000_000), run(1_011_000), 1.0)
      expect(verdict).to include("delta" => 11_000, "pct" => 1.1, "regressed" => true, "same_output" => true)
    end

    it "does not flag a rise inside the band, nor any improvement" do
      expect(EngineAllocAB.compare(run(1_000_000), run(1_009_000), 1.0)["regressed"]).to be(false)
      expect(EngineAllocAB.compare(run(1_000_000), run(900_000), 1.0)["regressed"]).to be(false)
    end

    it "decides the band on the percentage as printed" do
      verdict = EngineAllocAB.compare(run(1_000_000), run(1_010_040), 1.0)
      expect(verdict).to include("pct" => 1.0, "regressed" => false)
    end

    it "reports when the two engines' outputs differ" do
      expect(EngineAllocAB.compare(run(10, "a"), run(10, "b"), 1.0)["same_output"]).to be(false)
    end
  end

  describe ".summary" do
    let(:revs) { { base: "abc", head: "def", corpus: "abc", target: "lib" } }

    it "states the signed delta and marks a regression" do
      text = EngineAllocAB.summary(revs, run(42_000_000), run(42_600_000),
                                   EngineAllocAB.compare(run(42_000_000), run(42_600_000), 1.0), 1.0)
      expect(text).to include("| head | `def` | 42,600,000 |", "**Δ +600,000 (+1.43%)**", "**Above the band.**")
    end

    it "states an improvement without the regression mark" do
      text = EngineAllocAB.summary(revs, run(42_000_000), run(40_000_000),
                                   EngineAllocAB.compare(run(42_000_000), run(40_000_000), 1.0), 1.0)
      expect(text).to include("**Δ −2,000,000 (−4.76%)**")
      expect(text).not_to include("Above the band")
    end
  end

  describe ".warn_pct" do
    it "reads pr_allocations_pct from the thresholds file" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "thresholds.yml")
        File.write(path, "allocations_pct: 5\npr_allocations_pct: 2.5\n")
        expect(EngineAllocAB.warn_pct(path)).to eq(2.5)
      end
    end

    it "parses the committed thresholds" do
      path = File.expand_path("../../bench/thresholds.yml", __dir__)
      expect(EngineAllocAB.warn_pct(path)).to be_a(Float)
    end

    it "falls back to the default band when the key is absent" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "thresholds.yml")
        File.write(path, "allocations_pct: 5\n")
        expect(EngineAllocAB.warn_pct(path)).to eq(EngineAllocAB::DEFAULT_WARN_PCT)
      end
    end
  end

  describe ".report" do
    let(:revs) { { base: "abc", head: "def", corpus: "abc", target: "lib" } }

    def reported(head_allocations, actions:)
      Dir.mktmpdir do |dir|
        summary = File.join(dir, "summary.md")
        File.write(summary, "earlier\n")
        out = with_env("GITHUB_ACTIONS" => actions) do
          capture_stdout { EngineAllocAB.report(revs, run(1_000_000), run(head_allocations), 1.0, summary) }
        end
        [out, File.read(summary)]
      end
    end

    def with_env(pairs)
      saved = pairs.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      pairs.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| ENV[key] = value }
    end

    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end

    it "appends the table to the summary and warns on CI when the head is above the band" do
      out, summary = reported(1_020_000, actions: "true")
      expect(summary).to start_with("earlier\n### Engine allocations")
      expect(out).to include("::warning title=Engine allocations::The PR's engine allocates +2.00% (+20,000)")
    end

    it "does not warn inside the band, nor off CI" do
      expect(reported(1_005_000, actions: "true").first).not_to include("::warning")
      expect(reported(1_020_000, actions: nil).first).not_to include("::warning")
    end
  end
end
