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

    it "puts the probe inside the innermost class of a namespaced file, not the outer module" do
      namespaced = "module X\n  class Y\n    def a; end\n  end\nend\n"
      expect(EngineWarmAB.edited(namespaced, "method", 1))
        .to eq("module X\n  class Y\n    def a; end\n    def __rigor_warm_probe_1; end\n  end\nend\n")
    end

    it "puts it in the innermost module of a file with no class, past the namespace wrapper" do
      commands = "module X\n  module Commands\n    define_command(:c) {}\n  end\nend\n"
      expect(EngineWarmAB.edited(commands, "method", 1)).to eq(
        "module X\n  module Commands\n    define_command(:c) {}\n    def __rigor_warm_probe_1; end\n  end\nend\n"
      )
    end

    it "chooses the main class over a nested one and over a trailing one-line class" do
      source = "class Account\n  class Field\n    def a; end\n  end\n  def b; end\nend\n" \
               "class Error < StandardError; end\n"
      expect(EngineWarmAB.edited(source, "method", 1)).to eq(
        "class Account\n  class Field\n    def a; end\n  end\n  def b; end\n  def __rigor_warm_probe_1; end\nend\n" \
        "class Error < StandardError; end\n"
      )
    end

    it "ignores a class spelled inside a heredoc" do
      source = "class A\n  X = <<~RUBY\n    class Fake\n    end\n  RUBY\nend\n"
      expect(EngineWarmAB.edited(source, "method", 1))
        .to eq("class A\n  X = <<~RUBY\n    class Fake\n    end\n  RUBY\n  def __rigor_warm_probe_1; end\nend\n")
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

  describe ".parse_marker" do
    it "reads the child's exit marker, defaulting to no foreign load" do
      expect(EngineWarmAB.parse_marker("engine=0 yjit=1 foreign="))
        .to include("engine" => "0", "yjit" => "1", "foreign" => "")
      expect(EngineWarmAB.parse_marker("")).to include("foreign" => "")
    end
  end

  describe ".report" do
    it "writes a partial A/B report when one engine has no samples for a row" do
      journey = EngineWarmAB::Journey.new({ "base" => {}, "head" => {} }, {}, "/nonexistent")
      journey.samples[%w[default null]]["base"] << 0.4
      options = { project: "p", paths: [], leaf: "l.rb", hub: "h.rb", edit: "method", reps: 5,
                  base: "b", head: "h" }
      expect { EngineWarmAB.report(options, %w[base head], journey) }.to output(/default \| null/).to_stdout
    end
  end
end
