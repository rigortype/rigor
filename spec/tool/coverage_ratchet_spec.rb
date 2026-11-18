# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../../tool/coverage_ratchet"

# #3315 — `make coverage`'s judge. The scan itself is `rigor coverage --format json` (its call-site fields are pinned in
# spec/rigor/cli/coverage_command_spec.rb); this holds the verdict over a summary: a figure worse than its pin past the
# slack fails, a better one passes with a notice, and a run under another config, without the fields, under the floors
# or past `max_step` cannot pass.
RSpec.describe "tool/coverage_ratchet.rb" do
  let(:pins) do
    {
      "config" => ".rigor.gates.yml",
      "parameter_inference" => false,
      "precision" => { "pin" => 0.6, "slack" => 0.001 },
      "dynamic_call_share" => { "pin" => 0.5, "slack" => 0.001 },
      "floors" => { "expressions" => 350_000, "call_sites" => 90_000 },
      "max_step" => 0.02
    }
  end
  let(:config) { { "path" => ".rigor.gates.yml", "parameter_inference" => false } }

  # 400,000 expressions at 60 % precise; 100,000 call sites at 50 % Dynamic, both on their pins.
  def summary(**overrides)
    {
      "expressions_typed" => 400_000, "precise_count" => 240_000,
      "call_sites" => 100_000, "dynamic_call_count" => 50_000, "parse_errors" => 0
    }.merge(overrides.transform_keys(&:to_s))
  end

  def judge(summary, config: self.config, pins: self.pins)
    ok, lines, = CoverageRatchet.judge(summary: summary, config: config, pins: pins)
    [ok, lines.join("\n")]
  end

  it "passes figures within the slack of their pins, and prints both" do
    ok, text = judge(summary(dynamic_call_count: 50_090, precise_count: 239_700))
    expect(ok).to be(true)
    expect(text).to include("dynamic_call_share: 50.09% (50090 / 100000)", "precision: 59.93%", "ratchet OK")
    expect(text).not_to include("notice")
  end

  it "passes a figure exactly at the edge of its slack, on integer counts that do not divide exactly in binary" do
    # 50,100 / 100,000 - 0.5 is 0.0010000000000000009 in floating point.
    expect(judge(summary(dynamic_call_count: 50_100, precise_count: 239_600)).first).to be(true)
  end

  it "fails a Dynamic call share worse than its pin past the slack, naming the delta command and both ways out" do
    ok, text = judge(summary(dynamic_call_count: 50_200))
    expect(ok).to be(false)
    expect(text).to include(
      "dynamic_call_share is 0.20 points worse than its pin, past the 0.10 points slack",
      "measured against the pin, not against this change's base",
      'git archive "$base" exe lib sig data plugins .rigor.dist.yml .rigor.gates.yml',
      "bundle exec exe/rigor coverage --config .rigor.gates.yml --format json lib > tmp/ratchet-head.json",
      "(1) If the delta is this change's, declare in sig/",
      "(2) Otherwise, or if the loss is deliberate, moving the pin the worse way is a `gate-row` decision",
      "ask the maintainer first",
      "dynamic_call_share.pin: 0.502 # 50200 / 100000"
    )
  end

  it "fails a precision ratio worse than its pin past the slack" do
    expect(judge(summary(precise_count: 239_000))).to match([false, /precision is 0\.25 points worse than its pin/])
  end

  it "passes a figure better than its pin past the slack, with a notice that prints the tighter pin line" do
    ok, text = judge(summary(dynamic_call_count: 49_800, precise_count: 241_000))
    expect(ok).to be(true)
    expect(text).to include(
      "notice: dynamic_call_share is 0.20 points better than its pin",
      "dynamic_call_share.pin: 0.498 # 49800 / 100000",
      "notice: precision is 0.25 points better than its pin",
      "precision.pin: 0.6025 # 241000 / 400000",
      "ratchet OK"
    )
  end

  it "rounds a new pin toward the worse side" do
    # 49,801.5 / 100,000 cannot happen, so use a denominator that leaves a fifth decimal: 0.498015 and 0.602513.
    _, text = judge(summary(call_sites: 200_000, dynamic_call_count: 99_603, expressions_typed: 400_000,
                            precise_count: 241_005))
    expect(text).to include("dynamic_call_share.pin: 0.4981 #", "precision.pin: 0.6025 #")
  end

  it "fails a move past max_step in either direction as an instrument change" do
    expect(judge(summary(dynamic_call_count: 0)))
      .to match([false, /dynamic_call_share moved 50\.00 points from its pin, more than max_step.*Fix the instrument/])
    expect(judge(summary(dynamic_call_count: 53_000))).to match([false, /moved 3\.00 points from its pin/])
  end

  it "fails a scan under either floor" do
    expect(judge(summary(call_sites: 89_999, dynamic_call_count: 45_000)))
      .to match([false, /counted 89999 call sites, under the floor of 90000/])
    expect(judge(summary(expressions_typed: 349_999, precise_count: 210_000)))
      .to match([false, /counted 349999 expressions, under the floor of 350000/])
  end

  it "fails a summary without the call-site fields" do
    ok, text = judge(summary.except("call_sites", "dynamic_call_count"))
    expect(ok).to be(false)
    expect(text).to include("lacks call_sites, dynamic_call_count")
  end

  it "fails a parse error" do
    expect(judge(summary(parse_errors: 1))).to match([false, /1 file\(s\) did not parse/])
  end

  it "fails a run under another config, or with parameter_inference other than pinned" do
    expect(judge(summary, config: { "path" => ".rigor.dist.yml", "parameter_inference" => false }))
      .to match([false, /ran under ".rigor.dist.yml".*pass `--config .rigor.gates.yml`/])
    expect(judge(summary, config: { "path" => ".rigor.gates.yml", "parameter_inference" => true }))
      .to match([false, /parameter_inference is true/])
  end

  it "is configured with every key the judge reads, under the self-check's gates config" do
    committed = YAML.safe_load_file(CoverageRatchet::PINS)
    expect(committed).to include("config" => ".rigor.gates.yml", "parameter_inference" => false)
    expect(committed.dig("precision", "pin")).to be_between(0.5, 0.7)
    expect(committed.dig("dynamic_call_share", "pin")).to be_between(0.3, 0.6)
    expect(committed.keys).to include("floors", "max_step")
  end

  # `run` itself, with the scan stubbed: the exit status, the refusal before the scan, and `--tighten`.
  describe "run" do
    let(:gates_config) { File.join(CoverageRatchet::ROOT, ".rigor.gates.yml") }
    let(:scan_summary) { summary }
    let(:scan_status) { 0 }

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        File.write(File.join(dir, "pins.yml"), File.read(CoverageRatchet::PINS)
          .sub(/^(precision:\n  pin: )\S+.*$/, '\10.6 # x').sub(/^(dynamic_call_share:\n  pin: )\S+.*$/, '\10.5 # y'))
        example.run
      end
    end

    before do
      allow(Rigor::CLI).to receive(:start) do |_argv, out:|
        out.write(JSON.generate({ "summary" => scan_summary }))
        scan_status
      end
    end

    def pins_path = File.join(@dir, "pins.yml")

    def run_ratchet(*argv)
      out = StringIO.new
      status = CoverageRatchet.run(["--pins", pins_path, *argv], out: out)
      [status, out.string]
    end

    it "exits 0 on a passing scan, after running the scan under the given config" do
      status, out = run_ratchet("--config", gates_config, "lib")
      expect(status).to eq(0)
      expect(out).to include("ratchet OK")
      expect(Rigor::CLI).to have_received(:start)
        .with(["coverage", "--config", gates_config, "--format", "json", "lib"], out: anything)
    end

    context "when the scan is worse than a pin" do
      let(:scan_summary) { summary(dynamic_call_count: 50_200) }

      it "exits 1" do
        expect(run_ratchet("--config", gates_config, "lib")).to match([1, /worse than its pin/])
      end
    end

    context "when the scan itself exits non-zero" do
      let(:scan_status) { 1 }

      it "exits 1 even though the figures pass" do
        expect(run_ratchet("--config", gates_config, "lib").first).to eq(1)
      end
    end

    it "refuses a config at another path, even with the key off, before scanning" do
      other = File.join(@dir, "other.yml")
      File.write(other, "parameter_inference: false\n")
      status, out = run_ratchet("--config", other, "lib")
      expect(status).to eq(1)
      expect(out).to include("but the pins are measured under .rigor.gates.yml")
      expect(Rigor::CLI).not_to have_received(:start)
    end

    context "when the scan is better than both pins" do
      let(:scan_summary) { summary(dynamic_call_count: 49_800, precise_count: 241_000) }

      it "exits 0 with the notice and leaves the pins alone without --tighten" do
        before = File.read(pins_path)
        expect(run_ratchet("--config", gates_config, "lib")).to match([0, /notice: dynamic_call_share/])
        expect(File.read(pins_path)).to eq(before)
      end

      it "writes both gains into the pins file with --tighten, and nothing else" do
        before = File.read(pins_path)
        expect(run_ratchet("--config", gates_config, "--tighten", "lib")).to match([0, /tightened precision, dyn/])
        after = File.read(pins_path)
        expect(after).to include("precision:\n  pin: 0.6025 # 241000 / 400000\n",
                                 "dynamic_call_share:\n  pin: 0.498 # 49800 / 100000\n")
        expect(after.lines - before.lines).to eq(["  pin: 0.6025 # 241000 / 400000\n",
                                                  "  pin: 0.498 # 49800 / 100000\n"])
      end
    end

    context "when the scan is worse than a pin" do
      let(:scan_summary) { summary(precise_count: 239_000) }

      it "never loosens a pin with --tighten" do
        before = File.read(pins_path)
        expect(run_ratchet("--config", gates_config, "--tighten", "lib").first).to eq(1)
        expect(File.read(pins_path)).to eq(before)
      end
    end
  end
end
