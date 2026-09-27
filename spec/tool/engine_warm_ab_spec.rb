# frozen_string_literal: true

# The warm-journey harness (`tool/engine_warm_ab.rb`, issue #1507). What it must not get wrong without anyone
# noticing: the probe edit (a `method` edit that lands outside the class changes a different table, and one that
# fails to change the file measures a null build), and the warm-equals-cold comparison, which must tell different
# findings from the same findings in another order. Unit test only; requiring the script runs no engine.
require "json"
require "spec_helper"

require_relative "../../tool/engine_warm_ab"

RSpec.describe "tool/engine_warm_ab.rb (#1507)" do
  describe ".edited" do
    let(:source) { "class A\n  def x; end\nend\n" }

    it "inserts a probe method before the file's last top-level end" do
      expect(EngineWarmAB.edited(source, "method", 2))
        .to eq("class A\n  def x; end\n  def __rigor_warm_probe_2; end\nend\n")
    end

    it "appends a comment line for a bytes-only edit" do
      expect(EngineWarmAB.edited(source, "comment", 1)).to eq("#{source}# rigor-warm-probe 1\n")
    end

    it "changes the file on every repetition, so no timed edit run is a null build" do
      expect(EngineWarmAB.edited(source, "method", 1)).not_to eq(EngineWarmAB.edited(source, "method", 2))
    end
  end

  describe ".set_digest" do
    def output(*rules)
      JSON.generate("success" => false, "diagnostics" => rules.map { |rule| { "rule" => rule } })
    end

    it "agrees for the same diagnostics in another order" do
      expect(EngineWarmAB.set_digest(output("a", "b"))).to eq(EngineWarmAB.set_digest(output("b", "a")))
    end

    it "disagrees for different diagnostics, including a repeated one" do
      expect(EngineWarmAB.set_digest(output("a", "b"))).not_to eq(EngineWarmAB.set_digest(output("a", "c")))
      expect(EngineWarmAB.set_digest(output("a", "a"))).not_to eq(EngineWarmAB.set_digest(output("a")))
    end
  end
end
