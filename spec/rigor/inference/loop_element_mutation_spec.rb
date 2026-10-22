# frozen_string_literal: true

require "spec_helper"

# Issue #2262 — a loop hands its collection's own elements to its body, so a body that mutates one in place changes a
# shape that the collection's binding (and a `for` loop's value) still carried one level down: `r = for x in [[1]];
# x << 2; end` is `[[1, 2]]` in Ruby, while the value read `Array[[1]]` and `r[0].size == 2` drew a false
# `flow.always-truthy-condition`. Every example is paired with a control whose body does not mutate: it must keep its
# precise shape and its true positive.
RSpec.describe "a loop body that mutates an element in place", type: :runner do
  def flow_rules(source)
    result = analyze(source)
    result.diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.") }
  end

  describe "a for loop" do
    it "does not fold a read of the loop's value after the body appended to an element" do
      expect(flow_rules(<<~RUBY)).to eq([])
        r = for x in [[1]]; x << 2; end
        puts(r[0].size == 2 ? :y : :n)
      RUBY
    end

    it "does not fold a read of the iterated variable after the body appended to an element" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [[1]]
        for x in a; x << 2; end
        puts(a[0].size == 2 ? :y : :n)
      RUBY
    end

    it "does not fold through a mutator reached by an index chain" do
      expect(flow_rules(<<~RUBY)).to eq([])
        r = for x in [[[1]]]; x[0] << 2; end
        puts(r[0][0].size == 2 ? :y : :n)
      RUBY
    end

    it "keeps the precise shape when the body only reads the element" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        r = for x in [[1]]; x.size; end
        puts(r[0].size == 1 ? :y : :n)
      RUBY
    end
  end

  describe "a block call" do
    it "does not fold a read of the receiver after the block appended to an element" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [[1]]
        a.each { |x| x << 2 }
        puts(a[0].size == 2 ? :y : :n)
      RUBY
    end

    it "does not fold a hash element a numbered or `it` parameter stores into" do
      expect(flow_rules(<<~RUBY)).to eq([])
        h = [{ a: 1 }]
        h.each { _1[:b] = 2 }
        puts(h[0].size == 2 ? :y : :n)
      RUBY
    end

    it "keeps the precise shape when the block only reads the element" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        a = [[1]]
        a.each { |x| x.size }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end

    it "keeps the precise shape when the block mutates an unrelated local" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        a = [[1]]
        out = []
        a.each { |x| out << x }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end
  end
end
