# frozen_string_literal: true

# The sampling reducer of the ADR-50 WD4 perf gate (`tool/bench.rb`, issue #987).
#
# The gate compares `peak_rss_kb` against a committed baseline inside a +10% band while the host spread of that
# measurement is ±7%, so a single sample can flip the verdict either way. The fix takes the LOWER of N reps on the
# two noisy axes and leaves the deterministic ones alone — and that rule is the part worth pinning, because it is
# invisible in a real run: a benchmark whose reduction silently became "last rep wins" still prints plausible
# numbers and still passes.
#
# Since #1507 the gate also measures a frozen corpus, the release tag `bench/baseline.json` names, rather than this
# checkout's growing `lib`. Every way of losing that corpus has to stop the run: a gate that quietly measured another
# tree, or a partial run, prints plausible numbers and passes.
#
# Unit test only. Requiring the script defines {Bench} without benchmarking anything (the `$PROGRAM_NAME` guard at
# the bottom of the script), so no examples here run the analyzer.
require "json"
require "spec_helper"
require "tmpdir"

require_relative "../../tool/bench"

RSpec.describe "tool/bench.rb sampling and corpus (ADR-50 WD4, #987, #1507)" do
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

      expect { Bench.measure_in_fresh_process("lib", "/corpus") }.to raise_error(SystemExit)
        .and output(/no sample to reduce/).to_stderr
    end

    # A child killed by a signal has a nil exit status, which is why the message reports the whole status object.
    it "aborts when a rep's child was killed rather than exited" do
      allow(Bench).to receive(:popen_rep).and_return(["", status_double(nil)])

      expect { Bench.measure_in_fresh_process("lib", "/corpus") }.to raise_error(SystemExit)
        .and output(/failed/).to_stderr
    end

    it "aborts when a rep's output is not JSON" do
      allow(Bench).to receive(:popen_rep).and_return(["Segmentation fault\n", status_double(true)])

      expect { Bench.measure_in_fresh_process("lib", "/corpus") }.to raise_error(SystemExit)
        .and output(/unparseable output/).to_stderr
    end

    it "returns the parsed metrics of a clean rep" do
      allow(Bench).to receive(:popen_rep)
        .and_return([JSON.generate(sample(wall: 1.0, allocations: 2, rss: nil)), status_double(true)])

      expect(Bench.measure_in_fresh_process("lib", "/corpus")).to include("wall_s" => 1.0, "allocations" => 2)
    end

    # The child can only analyse the corpus if it is told where the corpus is.
    it "hands the corpus directory to the child" do
      allow(Bench).to receive(:popen_rep)
        .and_return([JSON.generate(sample(wall: 1.0, allocations: 2, rss: nil)), status_double(true)])

      Bench.measure_in_fresh_process("lib", "/corpus")

      expect(Bench).to have_received(:popen_rep).with(array_including("--measure", "lib", "--corpus-dir", "/corpus"))
    end
  end

  # A `rigor check` that stopped early (a usage error is 64, an internal error 70) or printed something other than
  # its JSON report measured less than the corpus, and its smaller numbers would pass the gate.
  describe ".assert_completed" do
    it "accepts a clean run and a run with findings" do
      expect(Bench.assert_completed(0, 0, "")).to be_nil
      expect(Bench.assert_completed(1, 3, "")).to be_nil
    end

    it "aborts on any other exit status" do
      expect { Bench.assert_completed(64, 0, "unknown option") }.to raise_error(SystemExit)
        .and output(/exited 64 .*unknown option/m).to_stderr
      expect { Bench.assert_completed(70, 1, "") }.to raise_error(SystemExit).and output(/exited 70/).to_stderr
    end

    it "aborts on unparseable output even when the exit status is clean" do
      expect { Bench.assert_completed(0, nil, "") }.to raise_error(SystemExit).and output(/unparseable/).to_stderr
    end
  end

  # The engine is stubbed at {EngineAllocAB.run_check}, so these examples observe where and how the child runs the
  # check without analysing anything.
  describe ".measure" do
    def stub_check(status, json)
      allow(EngineAllocAB).to receive(:run_check) do |_target, out, _err|
        yield Dir.pwd if block_given?
        out.write(json)
        status
      end
    end

    # Config discovery is cwd-based, so a check run from anywhere else analyses some other tree.
    it "runs the check inside the corpus" do
      Dir.mktmpdir do |dir|
        corpus = File.realpath(dir)
        cwd = nil
        stub_check(1, JSON.generate("diagnostics" => [{}, {}])) { |pwd| cwd = pwd }

        expect(Bench.measure("lib", corpus)).to include("diagnostics" => 2)
        expect(cwd).to eq(corpus)
        expect(Dir.pwd).not_to eq(corpus)
      end
    end

    it "aborts when the check did not complete" do
      Dir.mktmpdir do |dir|
        stub_check(64, "")

        expect { Bench.measure("lib", dir) }.to raise_error(SystemExit).and output(/exited 64/).to_stderr
      end
    end
  end

  describe "the corpus" do
    def write(dir, name, content)
      File.join(dir, name).tap { |path| File.write(path, content) }
    end

    it "is the revision the baseline names" do
      expect(Bench.corpus_revision({ "calibrated" => true, "corpus" => "v0.4.0" }, "baseline.json")).to eq("v0.4.0")
    end

    it "is named by the committed baseline, as a release tag" do
      path = File.expand_path("../../bench/baseline.json", __dir__)

      expect(Bench.corpus_revision(Bench.load_baseline(path), path)).to match(/\Av\d+\.\d+\.\d+\z/)
    end

    # No fallback to this checkout's tree: that is the growing corpus the gate moved away from.
    it "aborts when the baseline names none" do
      expect { Bench.corpus_revision({ "calibrated" => true }, "baseline.json") }.to raise_error(SystemExit)
        .and output(/names no corpus revision/).to_stderr
      expect { Bench.corpus_revision({ "corpus" => " " }, "baseline.json") }.to raise_error(SystemExit)
        .and output(/names no corpus revision/).to_stderr
    end

    it "aborts when the baseline cannot be read, rather than passing as uncalibrated" do
      Dir.mktmpdir do |dir|
        expect { Bench.load_baseline(File.join(dir, "missing.json")) }.to raise_error(SystemExit)
          .and output(/cannot read the perf baseline/).to_stderr
        expect { Bench.load_baseline(write(dir, "broken.json", "{")) }.to raise_error(SystemExit)
          .and output(/cannot read the perf baseline/).to_stderr
      end
    end

    it "resolves a revision in this clone to its commit" do
      expect(Bench.resolve_corpus("HEAD")).to match(/\A\h{40}\z/)
    end

    # The realistic case is a tag a shallow CI checkout never fetched.
    it "aborts on a revision this clone does not have, and says how to fetch it" do
      expect { Bench.resolve_corpus("v0.0.0-no-such-release") }.to raise_error(SystemExit)
        .and output(/"v0.0.0-no-such-release" is not a commit in this clone.*fetch-depth: 0/).to_stderr
    end

    it "does not unpack anything for a revision it cannot resolve" do
      allow(EngineAllocAB).to receive(:materialise)

      expect { Bench.with_corpus("v0.0.0-no-such-release") { nil } }.to raise_error(SystemExit).and output.to_stderr
      expect(EngineAllocAB).not_to have_received(:materialise)
    end

    # The temporary directory is reached through a symlink, as macOS's `/tmp` is, so the example can tell a
    # realpath'd corpus from the spelling `Dir.mktmpdir` returned.
    it "unpacks the resolved commit into a realpath'd directory for the duration of the block" do
      allow(EngineAllocAB).to receive(:materialise)
      head = Bench.resolve_corpus("HEAD")
      seen = nil
      resolved = nil

      Dir.mktmpdir do |outer|
        FileUtils.mkdir_p(File.join(outer, "real"))
        File.symlink(File.join(outer, "real"), File.join(outer, "link"))
        allow(Dir).to receive(:tmpdir).and_return(File.join(outer, "link"))

        expect do
          Bench.with_corpus("HEAD") do |dir|
            seen = dir
            resolved = File.join(File.realpath(File.dirname(dir)), "corpus")
          end
        end.to output(/Corpus: HEAD/).to_stderr
        expect(seen).to start_with(File.join(File.realpath(outer), "real", ""))
      end
      expect(EngineAllocAB).to have_received(:materialise).with(head, seen)
      expect(seen).to eq(resolved)
      expect(File.exist?(File.dirname(seen))).to be(false)
    end

    # The zero-work guard: a target the corpus lacks would finish fast and read as a large improvement.
    it "refuses a target with no Ruby files before spawning a rep" do
      allow(Bench).to receive(:measure_in_fresh_process)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "empty"))

        expect { Bench.run_reps("lib", 1, dir) }.to raise_error(SystemExit)
          .and output(/no Ruby files under lib/).to_stderr
        expect { Bench.run_reps("empty", 1, dir) }.to raise_error(SystemExit).and output(/no Ruby files/).to_stderr
      end
      expect(Bench).not_to have_received(:measure_in_fresh_process)
    end

    it "measures a target that has Ruby files" do
      allow(Bench).to receive(:measure_in_fresh_process).and_return(sample(wall: 1.0, allocations: 2, rss: nil))
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "a"))
        write(File.join(dir, "lib", "a"), "b.rb", "")

        expect { Bench.run_reps("lib", 2, dir) }.to output(/1 Ruby files in the corpus/).to_stderr
        expect(Bench).to have_received(:measure_in_fresh_process).with("lib", dir).twice
      end
    end

    # Recalibrating commits this file, so the corpus has to travel with the numbers measured on it.
    it "is named in the suggested baseline" do
      Dir.mktmpdir do |dir|
        options = { baseline: write(dir, "baseline.json", "{}"), thresholds: File.join(dir, "none.yml"),
                    write: nil, reps: 2 }
        results = { "lib" => sample(wall: 1.0, allocations: 2, rss: nil) }

        expect { Bench.gate(results, { "calibrated" => false }, "v0.4.0", options) }
          .to raise_error(SystemExit).and output(/corpus v0.4.0/).to_stdout
        expect(JSON.parse(File.read(File.join(dir, "baseline.updated.json"))))
          .to include("corpus" => "v0.4.0", "targets" => results)
      end
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

    # A child without a corpus would analyse whatever tree it started in: this checkout's.
    it "rejects --measure without --corpus-dir" do
      expect { Bench.parse_options(["--measure", "lib"]) }.to raise_error(ArgumentError, /--corpus-dir/)
      expect(Bench.parse_options(["--measure", "lib", "--corpus-dir", "/c"])[:corpus_dir]).to eq("/c")
    end
  end
end
