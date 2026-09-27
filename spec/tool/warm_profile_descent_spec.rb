# frozen_string_literal: true

# The breakdown of the warm-journey profiler (`tool/warm_profile_descent.rb`, issue #1507). The profiler preload
# requires it inside the profiled process, so this spec is its only check: what it must not get wrong is which
# chain it reports as shared and where it says the time fans out.
require "spec_helper"

require_relative "../../tool/warm_profile_descent"

RSpec.describe WarmProfileDescent do
  it "follows the chain every sample shares, then reports where the samples fan out" do
    result = described_class.call(
      { %w[main cli analyze a] => 55, %w[main cli analyze b] => 30, %w[main cli boot] => 15 }
    )
    expect(result["chain"]).to eq([["main", 100], ["cli", 100]])
    expect(result["phases"]).to eq([["analyze", 85], ["boot", 15]])
  end

  it "opens a phase that holds 90% of all samples instead of hiding it" do
    result = described_class.call({ %w[main analyze a] => 55, %w[main analyze b] => 40, %w[main boot] => 5 })
    expect(result["chain"].map(&:first)).to eq(%w[main analyze])
    expect(result["phases"]).to eq([["a", 55], ["b", 40]])
  end

  it "counts a recursive label once per level it appears at" do
    result = described_class.call({ %w[main f f g x] => 60, %w[main f f h] => 30, %w[main f k] => 10 })
    expect(result["chain"]).to eq([["main", 100], ["f", 100], ["f", 90]])
    expect(result["phases"]).to eq([["g", 60], ["h", 30]])
    expect(result["inner"]).to eq(["g", [["x", 60]]])
  end

  it "reports samples that end at the fan-out level as self time" do
    result = described_class.call({ %w[main] => 20, %w[main a] => 40, %w[main b] => 40 })
    expect(result["phases"]).to eq([["a", 40], ["b", 40], ["(self)", 20]])
    expect(result["inner"].first).to eq("a")
  end
end
