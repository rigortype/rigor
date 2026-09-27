# frozen_string_literal: true

# The statistics of the engine wall A/B (`tool/engine_wall_ab.rb`, issue #1507).
#
# Wall is the noisy axis, so what the tool must not get wrong is the arithmetic that decides whether a difference
# is evidence: the run order that keeps host drift off one arm, the median, and whether the two arms' ranges
# separate. Unit test only; requiring the script runs no engine.
require "spec_helper"

require_relative "../../tool/engine_wall_ab"

RSpec.describe "tool/engine_wall_ab.rb (#1507)" do
  def runs(*walls)
    walls.map { |wall| { "wall_s" => wall, "cpu_s" => wall, "gc_ms" => 10, "allocations" => 1 } }
  end

  describe ".schedule" do
    it "alternates the arms in ABBA order so a host drift charges both alike" do
      expect(EngineWallAB.schedule(3)).to eq(%i[base head head base base head])
    end
  end

  describe ".median" do
    it "takes the middle value, or the mean of the middle two" do
      expect(EngineWallAB.median([3, 1, 2])).to eq(2)
      expect(EngineWallAB.median([4, 1, 3, 2])).to eq(2.5)
    end
  end

  describe ".stats" do
    it "reports the change in the median and that separated ranges separate" do
      wall = EngineWallAB.stats(base: runs(10.0, 11.0, 10.5), head: runs(9.0, 9.5, 9.2))["wall_s"]
      expect(wall).to include("median_pct" => -12.38, "separated" => true)
      expect(wall["base"]).to eq("median" => 10.5, "min" => 10.0, "max" => 11.0)
    end

    it "does not call overlapping ranges separated, whatever the medians say" do
      wall = EngineWallAB.stats(base: runs(10.0, 12.0, 10.5), head: runs(9.0, 10.2, 11.0))["wall_s"]
      expect(wall["separated"]).to be(false)
    end

    it "leaves out a metric no run recorded" do
      expect(EngineWallAB.stats(base: runs(1.0, 2.0), head: runs(1.0, 2.0))).not_to have_key("instructions")
    end
  end

  describe ".parse_perf" do
    it "reads the user-space instruction count from perf stat's CSV output" do
      text = "# started on Sun Sep 27\n\n123456789,,instructions:u,1000000,100.00,,\n"
      expect(EngineWallAB.parse_perf(text)).to eq(123_456_789)
    end

    it "answers nil where the host does not support the counter" do
      expect(EngineWallAB.parse_perf("<not supported>,,instructions:u,0,100.00,,\n")).to be_nil
    end
  end
end
