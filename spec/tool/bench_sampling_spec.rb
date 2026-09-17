# frozen_string_literal: true

# The sampling reducer of the ADR-50 WD4 perf gate (`tool/bench.rb`, issue #987).
#
# The gate compares `peak_rss_kb` against a committed baseline inside a +10% band while the host spread of that
# measurement is ±7%, so a single sample can flip the verdict either way. The fix takes the LOWER of N reps on the
# two noisy axes and leaves the deterministic ones alone — and that rule is the part worth pinning, because it is
# invisible in a real run: a benchmark whose reduction silently became "last rep wins" still prints plausible
# numbers and still passes.
#
# Unit test only. Requiring the script defines {Bench} without benchmarking anything (the `$PROGRAM_NAME` guard at
# the bottom of the script), so no examples here run the analyzer.
require "json"
require "spec_helper"

require_relative "../../tool/bench"

RSpec.describe "tool/bench.rb sampling (ADR-50 WD4, #987)" do
  def sample(wall:, allocations:, rss:, diagnostics: 1)
    { "wall_s" => wall, "allocations" => allocations, "peak_rss_kb" => rss, "diagnostics" => diagnostics }
  end

  describe ".reduce_samples" do
    it "takes the lower wall_s and peak_rss_kb across the reps" do
      reduced = Bench.reduce_samples(
        [sample(wall: 26.4, allocations: 23_670_693, rss: 501_000),
         sample(wall: 25.1, allocations: 23_670_701, rss: 462_000)]
      )

      expect(reduced["wall_s"]).to eq(25.1)
      expect(reduced["peak_rss_kb"]).to eq(462_000)
    end

    it "keeps allocations and diagnostics single-sample (the first rep), not reduced" do
      reduced = Bench.reduce_samples(
        [sample(wall: 26.4, allocations: 23_670_693, rss: 501_000, diagnostics: 1),
         sample(wall: 25.1, allocations: 23_000_000, rss: 462_000, diagnostics: 0)]
      )

      expect(reduced["allocations"]).to eq(23_670_693)
      expect(reduced["diagnostics"]).to eq(1)
    end

    it "reduces the noisy axes and only those" do
      expect(Bench::LOWER_OF_REPS).to contain_exactly("wall_s", "peak_rss_kb")
      expect(Bench::SINGLE_SAMPLE).to contain_exactly("allocations", "diagnostics")
    end

    it "preserves the one-rep metric shape, so nothing downstream sees that sampling happened" do
      one = sample(wall: 25.5, allocations: 23_670_693, rss: 483_252)

      expect(Bench.reduce_samples([one, sample(wall: 26.0, allocations: 1, rss: 490_000)]).keys).to eq(one.keys)
    end

    it "is the identity on a single rep" do
      one = sample(wall: 25.5, allocations: 23_670_693, rss: 483_252)

      expect(Bench.reduce_samples([one])).to eq(one)
    end

    # macOS and any other host without /proc/self/status reports RSS as nil in every rep; the gate skips a nil
    # metric, and `min` over an empty list must not turn that skip into a crash or a zero.
    it "keeps a metric that is nil in every rep nil" do
      reduced = Bench.reduce_samples(
        [sample(wall: 26.4, allocations: 1, rss: nil), sample(wall: 25.1, allocations: 1, rss: nil)]
      )

      expect(reduced["peak_rss_kb"]).to be_nil
    end

    it "reduces over the reps that have a value when only some are nil" do
      reduced = Bench.reduce_samples(
        [sample(wall: 26.4, allocations: 1, rss: nil), sample(wall: 25.1, allocations: 1, rss: 462_000)]
      )

      expect(reduced["peak_rss_kb"]).to eq(462_000)
    end

    it "refuses an empty rep list rather than inventing a sample" do
      expect { Bench.reduce_samples([]) }.to raise_error(ArgumentError)
    end
  end

  # The gate must stop rather than quietly reduce fewer reps than it claims. Both failure paths abort, and both are
  # unreachable from a real run without breaking a child on purpose — so they are stubbed at {Bench.popen_rep},
  # which exists to make exactly this testable.
  describe ".measure_in_fresh_process failure paths" do
    def status_double(success)
      instance_double(Process::Status, success?: success)
    end

    it "aborts when a rep's child exits non-zero" do
      allow(Bench).to receive(:popen_rep).and_return(["", status_double(false)])

      expect { Bench.measure_in_fresh_process("lib") }.to raise_error(SystemExit)
        .and output(/no sample to reduce/).to_stderr
    end

    # A child killed by a signal has a nil exit status, which is why the message reports the whole status object.
    it "aborts when a rep's child was killed rather than exited" do
      allow(Bench).to receive(:popen_rep).and_return(["", status_double(nil)])

      expect { Bench.measure_in_fresh_process("lib") }.to raise_error(SystemExit)
        .and output(/failed/).to_stderr
    end

    it "aborts when a rep's output is not JSON" do
      allow(Bench).to receive(:popen_rep).and_return(["Segmentation fault\n", status_double(true)])

      expect { Bench.measure_in_fresh_process("lib") }.to raise_error(SystemExit)
        .and output(/unparseable output/).to_stderr
    end

    it "returns the parsed metrics of a clean rep" do
      allow(Bench).to receive(:popen_rep)
        .and_return([JSON.generate(sample(wall: 1.0, allocations: 2, rss: nil)), status_double(true)])

      expect(Bench.measure_in_fresh_process("lib")).to include("wall_s" => 1.0, "allocations" => 2)
    end
  end

  describe "defaults" do
    it "reps twice by default" do
      expect(Bench::DEFAULT_REPS).to eq(2)
    end

    it "accepts --reps N" do
      expect(Bench.parse_options(["--reps", "3", "--target", "lib"])[:reps]).to eq(3)
    end

    it "defaults --reps to DEFAULT_REPS" do
      expect(Bench.parse_options([])[:reps]).to eq(Bench::DEFAULT_REPS)
    end

    # Zero reps would reduce an empty list; the option parser refuses it, and `main` turns that into an abort.
    it "rejects --reps below 1" do
      expect { Bench.parse_options(["--reps", "0"]) }.to raise_error(ArgumentError, /--reps/)
    end
  end
end
