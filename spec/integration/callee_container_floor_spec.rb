# frozen_string_literal: true

# Issue #2647 — the callee floor's block channel and Set channel widened a container's literal elements to their
# nominal class beside `Dynamic[top]` (`["r"]` read `Array[Dynamic[top] | String]`), so an element read back out
# failed a literal-typed parameter on correct code: the callee stored a value the call never shows, and Ruby keeps
# every element a valid literal. The elements are now a gradual `Dynamic[String]`, which may forget a fact but never
# claims the class.
require "spec_helper"

RSpec.describe "the callee floor widens a container's literal elements gradually (#2647)", type: :runner do
  let(:signature) do
    { "sink.rbs" => "class Sink\n  def mode: (\"r\" | \"w\") -> void\n  def num: (1 | 2) -> void\n  " \
                    "def key: (:j | :k) -> void\nend\n" }
  end
  let(:defs) do
    <<~RUBY
      class R; def poke(a) = a.size; end
      def via_local(o, a) = o.poke(a)
    RUBY
  end

  def mismatches(source)
    analyze(source, sig: signature).diagnostics.map(&:qualified_rule).grep(/argument-type-mismatch/)
  end

  it "fires for a bad literal (the control that the rule is live)" do
    expect(mismatches("Sink.new.mode(\"x\")\n")).to eq(["call.argument-type-mismatch"])
  end

  it "stays silent for an Array of Strings under a union whose candidate writes in a block (the issue's repro)" do
    source = <<~RUBY
      class W; def poke(a) = 2.times { a << "w" }; end
      #{defs}
      a = ["r"]
      via_local(Object.new, a)
      a.each { |v| Sink.new.mode(v) }
    RUBY
    expect(mismatches(source)).to eq([])
  end

  it "stays silent for an Array of Integers" do
    source = <<~RUBY
      class W; def poke(a) = 2.times { a << 2 }; end
      #{defs}
      a = [1]
      via_local(Object.new, a)
      a.each { |v| Sink.new.num(v) }
    RUBY
    expect(mismatches(source)).to eq([])
  end

  it "stays silent for a Hash key and value written in a block" do
    source = <<~RUBY
      class W; def poke(h) = 2.times { h[:k] = "w" }; end
      #{defs.gsub('a)', 'h)').gsub('a.size', 'h.size')}
      h = { j: "r" }
      via_local(Object.new, h)
      h.each_value { |v| Sink.new.mode(v) }
      h.each_key { |k| Sink.new.key(k) }
    RUBY
    expect(mismatches(source)).to eq([])
  end

  it "stays silent for a Set grown in a block" do
    source = <<~RUBY
      require "set"
      class W; def poke(s) = 2.times { s.add("w") }; end
      #{defs.gsub('a)', 's)').gsub('a.size', 's.size')}
      s = Set["r"]
      via_local(Object.new, s)
      s.each { |v| Sink.new.mode(v) }
    RUBY
    expect(mismatches(source)).to eq([])
  end

  it "stays silent for the Set-only channel under a union" do
    source = <<~RUBY
      require "set"
      class W; def poke(s) = s.add("w"); end
      #{defs.gsub('a)', 's)').gsub('a.size', 's.size')}
      s = Set["r"]
      via_local(Object.new, s)
      s.each { |v| Sink.new.mode(v) }
    RUBY
    expect(mismatches(source)).to eq([])
  end

  it "stays silent for the Set-only channel under a single def read as written" do
    source = <<~RUBY
      require "set"
      def add_w(s) = s.add("w")
      s = Set["r"]
      add_w(s)
      s.each { |v| Sink.new.mode(v) }
    RUBY
    expect(mismatches(source)).to eq([])
  end

  it "stays silent for a single def read as written that stores in a block" do
    source = <<~RUBY
      def add_w(a) = 2.times { a << "w" }
      a = ["r"]
      add_w(a)
      a.each { |v| Sink.new.mode(v) }
    RUBY
    expect(mismatches(source)).to eq([])
  end

  it "keeps a read-only callee's literal elements, so a bad element still reports (same-file control)" do
    source = <<~RUBY
      def look(a) = a.size
      a = ["x"]
      look(a)
      a.each { |v| Sink.new.mode(v) }
    RUBY
    expect(mismatches(source)).to eq(["call.argument-type-mismatch"])
  end
end
