# frozen_string_literal: true

# The statistics of the engine wall A/B (`tool/engine_wall_ab.rb`, issue #1507).
#
# Wall is the noisy axis, so what the tool must not get wrong is the arithmetic that decides whether a difference
# is evidence: the run order that keeps host drift off one arm, the median, and whether the two arms' ranges
# separate beyond chance. Unit test only; requiring the script runs no engine.
require "spec_helper"

require_relative "../../tool/engine_wall_ab"

RSpec.describe "tool/engine_wall_ab.rb (#1507)" do
  def runs(*walls, yjit: false)
    walls.map { |wall| { "wall_s" => wall, "cpu_s" => wall, "gc_ms" => 10, "allocations" => 1, "yjit" => yjit } }
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

  describe ".separation_null_probability" do
    it "is the chance that one distribution's samples land with their ranges apart, 2 / C(n + m, n)" do
      expect(EngineWallAB.separation_null_probability(2, 2)).to be_within(1e-9).of(1 / 3.0)
      expect(EngineWallAB.separation_null_probability(4, 4)).to be_within(1e-9).of(2 / 70.0)
      expect(EngineWallAB.separation_null_probability(5, 5)).to be_within(1e-9).of(2 / 252.0)
    end
  end

  describe ".stats" do
    it "calls apart ranges separated when that is unlikely by chance" do
      wall = EngineWallAB.stats(base: runs(10.0, 11.0, 10.5, 10.8, 10.2),
                                head: runs(9.0, 9.5, 9.2, 9.4, 9.1))["wall_s"]
      expect(wall).to include("median_pct" => -12.38, "apart" => true, "separated" => true)
      expect(wall["base"]).to eq("median" => 10.5, "min" => 10.0, "max" => 11.0)
    end

    it "does not call apart ranges separated at two runs, where they part a third of the time by chance" do
      wall = EngineWallAB.stats(base: runs(10.0, 11.0), head: runs(9.0, 9.5))["wall_s"]
      expect(wall).to include("apart" => true, "separated" => false)
    end

    it "divides the 5% bar by the number of rows, so four runs are not enough for three rows" do
      wall = EngineWallAB.stats(base: runs(10.0, 11.0, 10.5, 10.8), head: runs(9.0, 9.5, 9.2, 9.4))["wall_s"]
      expect(wall).to include("apart" => true, "null_probability" => 0.0286, "separated" => false)
    end

    it "does not count touching ranges as apart" do
      wall = EngineWallAB.stats(base: runs(10.0, 11.0, 10.5, 10.8, 10.2),
                                head: runs(9.0, 9.5, 9.2, 9.4, 10.0))["wall_s"]
      expect(wall).to include("apart" => false, "separated" => false)
    end

    it "does not call overlapping ranges separated, whatever the medians say" do
      wall = EngineWallAB.stats(base: runs(10.0, 12.0, 10.5, 10.6), head: runs(9.0, 10.2, 11.0, 9.1))["wall_s"]
      expect(wall["separated"]).to be(false)
    end

    it "leaves out a metric no run recorded" do
      expect(EngineWallAB.stats(base: runs(1.0, 2.0), head: runs(1.0, 2.0))).not_to have_key("instructions")
    end
  end

  describe ".runs_needed" do
    it "is five runs per arm for three or four rows" do
      expect([EngineWallAB.runs_needed(3), EngineWallAB.runs_needed(4)]).to eq([5, 5])
    end
  end

  describe ".consistency_notes" do
    it "warns when the arms ended in different YJIT states" do
      notes = EngineWallAB.consistency_notes(base: runs(1.0, 1.0, yjit: false), head: runs(1.0, 1.0, yjit: true))
      expect(notes.join("\n")).to include("YJIT ended in different states")
    end

    it "warns when a mode that fixes YJIT did not get the state it asked for" do
      notes = EngineWallAB.consistency_notes({ base: runs(1.0, yjit: false), head: runs(1.0, yjit: false) }, "on")
      expect(notes.join("\n")).to include("`--yjit on` was requested, but some runs ended with YJIT off")
    end

    it "does not warn when every run ended in the same state" do
      notes = EngineWallAB.consistency_notes(base: runs(1.0, 1.0, yjit: true), head: runs(1.0, 1.0, yjit: true))
      expect(notes.join("\n")).not_to include("YJIT ended in different states")
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
