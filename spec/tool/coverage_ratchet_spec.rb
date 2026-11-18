# frozen_string_literal: true

require "spec_helper"
require "yaml"
require_relative "../../tool/coverage_ratchet"

# #3315 — `make coverage`'s judge. The scan itself is `rigor coverage --format json` (its call-site fields are pinned in
# spec/rigor/cli/coverage_command_spec.rb); this holds the verdict over a summary: both figures are two-sided ratchets,
# and a run under another config, without the fields, or under the floors cannot pass.
RSpec.describe "tool/coverage_ratchet.rb" do
  let(:pins) do
    {
      "config" => ".rigor.gates.yml",
      "parameter_inference" => false,
      "precision" => { "pin" => 0.6, "slack" => 0.0015 },
      "dynamic_call_share" => { "pin" => 0.5, "slack" => 0.0015 },
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
    ok, lines = CoverageRatchet.judge(summary: summary, config: config, pins: pins)
    [ok, lines.join("\n")]
  end

  it "passes figures within the slack of their pins, and prints both" do
    ok, text = judge(summary(dynamic_call_count: 50_140, precise_count: 239_500))
    expect(ok).to be(true)
    expect(text).to include("dynamic_call_share: 50.14% (50140 / 100000)", "precision: 59.88%", "ratchet OK")
  end

  it "fails a Dynamic call share that rose past the slack, and says to declare or re-pin with a reason" do
    ok, text = judge(summary(dynamic_call_count: 50_200))
    expect(ok).to be(false)
    expect(text).to match(%r{dynamic_call_share worsened by 0\.20 points.*Declare in sig/.*give the reason})
  end

  it "fails a Dynamic call share that fell past the slack, and says to lock the gain in" do
    ok, text = judge(summary(dynamic_call_count: 49_800))
    expect(ok).to be(false)
    expect(text).to include("dynamic_call_share improved by 0.20 points",
                            "set `dynamic_call_share.pin` in tool/coverage_ratchet.yml to 0.498 # 49800 / 100000")
  end

  it "fails a precision ratio that fell past the slack, and one that rose past it" do
    expect(judge(summary(precise_count: 239_000))).to match([false, /precision worsened by 0\.25 points/])
    expect(judge(summary(precise_count: 241_000))).to match([false, /precision improved by 0\.25 points.*0\.6025/])
  end

  it "fails a tally forced to zero as an instrument change, not as a gain" do
    ok, text = judge(summary(dynamic_call_count: 0))
    expect(ok).to be(false)
    expect(text).to match(/dynamic_call_share moved 50\.00 points in one run, more than max_step.*Fix the instrument/)
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
end
