# frozen_string_literal: true

# Issue #2657 — `Set#first` with no argument on a constant-folded Set answers its first member (the set's insertion
# order), `nil` only for the empty set. RBS alone answered `E?` with `E` unbound, so `Set["r"].first` read
# `Dynamic[top]?` and failed a `("r" | "w")` parameter. Every mutator widens the carrier, so the answer holds only
# while the set is as built.
require "spec_helper"

RSpec.describe "Set#first on a constant-folded Set", type: :runner do
  def dumped(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  it "answers the member of a one-member Set, with no nil arm" do
    expect(dumped(%(s = Set["r"]\ndump_type(s.first)))).to eq([%("r")])
  end

  it "answers the first member of a mixed Set, and for Set.new over a literal Array" do
    source = %(a = Set[1, "a"]\ndump_type(a.first)\nb = Set.new(["r"])\ndump_type(b.first))
    expect(dumped(source)).to eq(["1", %("r")])
  end

  it "answers nil for the empty Set" do
    expect(dumped("e = Set[]\ndump_type(e.first)")).to eq(["nil"])
  end

  it "keeps the nil arm after the set is emptied through a modelled mutator, an alias or a callee" do
    source = <<~RUBY
      s = Set["r"]
      s.clear
      dump_type(s.first)
      a = Set["r"]
      b = a
      b.clear
      dump_type(a.first)
      def drain(x) = x.clear
      c = Set["r"]
      drain(c)
      dump_type(c.first)
      d = Set["r"]
      d.delete("r")
      dump_type(d.first)
    RUBY
    expect(dumped(source)).to eq(["String?", "Dynamic[top] | String | nil", "Dynamic[top]?", "String?"])
  end

  # Each of these empties the set without a modelled mutator at the call, so the fold must decline and leave the RBS
  # answer rather than claim a member Ruby no longer returns.
  {
    "a lambda called later" => "f = -> { s.clear }\nf.call",
    "a container element" => "[s].each(&:clear)",
    "a Method object" => "s.method(:clear).call",
    "instance_eval" => "s.instance_eval { clear }",
    "a proc called later" => ["pr = proc { s.clear }\npr.call", "Dynamic[top] | String | nil"],
    # Issue #3057 — the same reflective frame access through a `send`-family dispatch on a literal
    # frame-call name (Symbol or String), `local_variable_get`-style names, or a `TOPLEVEL_BINDING` reference.
    "send(:eval)" => "send(:eval, \"s.clear\")",
    "__send__(:eval)" => "__send__(:eval, \"s.clear\")",
    "public_send(:binding)" => "public_send(:binding)",
    "send(:instance_eval)" => "send(:instance_eval, \"s.clear\")",
    "send(\"eval\")" => "send(\"eval\", \"s.clear\")",
    "__send__(\"binding\")" => "__send__(\"binding\")"
  }.each do |label, (emptier, answer)|
    it "declines when the local escapes through #{label}" do
      expect(dumped(%(s = Set["r"]\n#{emptier}\ndump_type(s.first)))).to eq([answer || "Dynamic[top]?"])
    end
  end

  # The helper empties the top-level `s` through the binding it is handed, so Ruby's `s.first` is nil. It goes
  # through `method(:local_variable_get)` to stand in for a helper in another file: the scan also covers a nested
  # `def`, so a direct `local_variable_get` there would escape `s` without the reference under test.
  ["TOPLEVEL_BINDING", "::TOPLEVEL_BINDING", "Object::TOPLEVEL_BINDING"].each do |reference|
    it "declines when the local escapes through #{reference} handed to a helper" do
      source = <<~RUBY
        module Helper
          def self.h(b) = b.method(:local_variable_get).call(:s).clear
        end
        s = Set["r"]
        Helper.h(#{reference})
        dump_type(s.first)
      RUBY
      expect(dumped(source)).to eq(["Dynamic[top]?"])
    end
  end

  it "still folds first after a block-only send(:instance_eval) that leaves the set alone" do
    expect(dumped(%(s = Set["r"]\nsend(:instance_eval) { 1 }\ndump_type(s.first)))).to eq([%("r")])
  end

  it "declines when local_variable_get reaches the local through another binding" do
    expect(dumped(<<~RUBY)).to eq(["Dynamic[top]?"])
      def reach(b)
        s = Set["r"]
        b.local_variable_get(:s)
        dump_type(s.first)
      end
    RUBY
  end

  it "still folds first after a send naming no frame call" do
    expect(dumped(%(s = Set["r"]\nsend(:foo)\ndump_type(s.first)))).to eq([%("r")])
  end

  it "declines for a global mutated inside a def, and for a receiver that is not a local" do
    source = <<~RUBY
      $g = Set[1, 2]
      def gdrain = $g.clear
      gdrain
      dump_type($g.first)
      dump_type(Set["r"].first)
    RUBY
    expect(dumped(source)).to eq(["Dynamic[top]?", "Dynamic[top]?"])
  end

  it "reports nothing for a truthiness test on first after an escaping clear" do
    source = <<~RUBY
      s = Set["r"]
      cleanup = -> { s.clear }
      cleanup.call
      v = s.first
      puts(v ? v : "none")
    RUBY
    expect(analyze(source).diagnostics.map(&:qualified_rule)).to eq([])
  end

  it "leaves first(n) to RBS" do
    expect(dumped(%(s = Set["r"]; dump_type(s.first(1))))).to eq(["Array[Dynamic[top]]"])
  end
end
