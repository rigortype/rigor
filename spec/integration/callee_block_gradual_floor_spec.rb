# frozen_string_literal: true

# Issue #2638 — the block channel of the callee floor (`def poke(s) = 2.times { s << "x" }`) floored a String to the
# nominal `String` whatever the owner was. Under an over-approximating floor (a union resolution, several callees, a
# hop to one) the callee is not known to write the argument, and the nominal `String` failed a literal-typed parameter
# the unmutated local satisfied. `FLOOR_ALL` and `FLOOR_EVERY` never reach the block channel alone: the direct-write
# channel floors the String gradually first. Such a floor is gradual
# (`Dynamic[String]`), as the direct-write channel's is; a single def read as written keeps the nominal floor.
require "spec_helper"

RSpec.describe "the block channel floors a String gradually under an over-approximation (#2638)", type: :runner do
  let(:signature) do
    { "sink.rbs" => "class Sink\n  def mode: (\"r\" | \"w\") -> void\n  def int: (Integer) -> void\nend\n" }
  end
  let(:block_writer) { "2.times { s << \"x\" }" }

  def found(source)
    rules = analyze(source, sig: signature).diagnostics.map(&:qualified_rule)
    rules.grep(/argument-type-mismatch|undefined-method/)
  end

  it "fires for a bad literal (the control that the rule is live)" do
    expect(found("Sink.new.mode(\"x\")\n")).to eq(["call.argument-type-mismatch"])
  end

  it "stays silent for a local-receiver union whose candidate writes in a block" do
    source = <<~RUBY
      class W; def poke(s) = #{block_writer}; end
      class R; def poke(s) = s.size; end
      def via_local(o, s) = o.poke(s)
      m = "r"
      via_local(Object.new, m)
      Sink.new.mode(m)
    RUBY
    expect(found(source)).to eq([])
  end

  it "keeps the nominal floor for a single def read as written that writes in a block" do
    source = <<~RUBY
      def poke(s) = #{block_writer}
      m = "r"
      poke(m)
      Sink.new.int(m)
      m.no_such_method
    RUBY
    expect(found(source)).to eq(%w[call.argument-type-mismatch call.undefined-method])
  end

  it "keeps the nominal floor inside a class too" do
    source = <<~RUBY
      def poke(s) = #{block_writer}
      class Caller
        def run
          m = "r"
          poke(m)
          Sink.new.int(m)
        end
      end
    RUBY
    expect(found(source)).to eq(["call.argument-type-mismatch"])
  end

  it "stays silent for a call with several callees, one of which writes in a block" do
    source = <<~RUBY
      class W; def poke(s) = #{block_writer}; end
      class R; def poke(s) = s.size; end
      m = "r"
      [W.new, R.new].sample.poke(m)
      Sink.new.mode(m)
    RUBY
    expect(found(source)).to eq([])
  end

  it "stays silent when a hop reaches a union whose candidate writes in a block" do
    source = <<~RUBY
      class W; def poke(s) = #{block_writer}; end
      class R; def poke(s) = s.size; end
      def via_local(o, s) = o.poke(s)
      def app(o, s) = via_local(o, s)
      m = "r"
      app(Object.new, m)
      Sink.new.mode(m)
    RUBY
    expect(found(source)).to eq([])
  end
end
