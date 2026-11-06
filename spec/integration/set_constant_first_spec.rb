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
    expect(dumped(%(dump_type(Set[1, "a"].first)\ndump_type(Set.new(["r"]).first)))).to eq(["1", %("r")])
  end

  it "answers nil for the empty Set" do
    expect(dumped("dump_type(Set[].first)")).to eq(["nil"])
  end

  it "keeps the nil arm after the set is emptied through a mutator, an alias or a callee" do
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
    out = dumped(source)
    expect(out.size).to eq(4)
    expect(out).to all(satisfy { |t| t.end_with?("?") || t.include?("nil") })
  end

  it "leaves first(n) to RBS" do
    expect(dumped(%(dump_type(Set["r"].first(1))))).to eq(["Array[Dynamic[top]]"])
  end
end
