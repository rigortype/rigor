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

  describe "a nested loop or a symbol proc" do
    it "does not fold through a nested for loop's index" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [[[1]]]
        for r in a; for c in r; c << 2; end; end
        puts(a[0][0].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold through a for loop's index inside a block" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [[[1]]]
        a.each { |r| for c in r; c << 2; end }
        puts(a[0][0].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold the value of a for loop that holds a nested for loop" do
      expect(flow_rules(<<~RUBY)).to eq([])
        r = for x in [[[1]]]; for c in x; c << 2; end; end
        puts(r[0][0].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold through a nested block's parameter" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [[[1]]]
        a.each { |r| r.each { |c| c << 2 } }
        puts(a[0][0].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold through a mutator named by a symbol proc" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [" s "]
        a.each(&:strip!)
        puts(a[0].size == 3 ? :y : :n)
        b = [[1]]
        b.each(&:clear)
        puts(b[0].size == 1 ? :y : :n)
      RUBY
    end

    it "keeps the precise shape for a symbol proc that does not mutate" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        a = [[1]]
        a.each(&:size)
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold through a multi-target index store on an element" do
      expect(flow_rules(<<~RUBY)).to eq([])
        h = [{ a: 1 }]
        h.each { |x| x[:b], _y = 2, 3 }
        puts(h[0].size == 1 ? :y : :n)
      RUBY
    end

    it "keeps the precise shape when a nested for loop only reads" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        a = [[[1]]]
        for r in a; for c in r; c.size; end; end
        puts(a[0][0].size == 1 ? :y : :n)
      RUBY
    end
  end

  # Issue #2287 — the loop's receiver is a call that exposes a variable's own elements, or the body mutates an outer
  # variable's element through an index chain.
  describe "a receiver that exposes a variable's elements" do
    it "does not fold a hash value appended to through `values.each`" do
      expect(flow_rules(<<~RUBY)).to eq([])
        h = { a: [1] }
        h.values.each { |v| v << 2 }
        puts(h[:a].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold a hash value appended to by a for loop over `values`" do
      expect(flow_rules(<<~RUBY)).to eq([])
        h = { a: [1] }
        for v in h.values; v << 2; end
        puts(h[:a].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold an element appended to through a shallow copy" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [[1]]
        a.dup.each { |x| x << 2 }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold an element appended to through `each_with_index.map`" do
      expect(flow_rules(<<~RUBY)).to eq([])
        b = [[1]]
        b.each_with_index.map { |x, i| x << i }
        puts(b[0].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold an element appended to through `each.with_index`" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [[1]]
        a.each.with_index { |x, i| x << i }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold an element appended to through `each.with_index(1).map`" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [[1]]
        a.each.with_index(1).map { |x, i| x << i }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold a Set element a block over a shallow copy adds to" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [Set[1]]
        a.dup.each { |s| s.add(2) }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end

    it "keeps the precise shape when the block over `values` only reads" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        h = { a: [1] }
        h.values.map { |v| v.size }
        puts(h[:a].size == 1 ? :y : :n)
      RUBY
    end

    it "keeps the tuple when the block calls `Hash#merge`, which returns a new hash" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        a = [{ a: 1 }]
        a.dup.each { |x| x.merge(b: 2) }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end
  end

  describe "an outer variable's element mutated through an index chain" do
    it "does not fold an element a block appended to by a computed index" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [[1]]
        [0].each { |i| a[i] << 2 }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end

    it "does not fold an element appended to under `loop`" do
      expect(flow_rules(<<~RUBY)).to eq([])
        a = [[1]]
        loop { a[0] << 2; break }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end

    it "keeps the outer arity, which mutating an element cannot change" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        a = [[1], [3]]
        [0].each { |i| a[i] << 2 }
        puts(a.size == 2 ? :y : :n)
      RUBY
    end

    it "keeps the outer shape when the chain is rooted at a block parameter that shadows it" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        a = [[1]]
        [[[5]]].each { |a| a[0] << 2 }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end

    it "keeps the precise shape when the block only reads the element" do
      expect(flow_rules(<<~RUBY)).to eq(["flow.always-truthy-condition"])
        a = [[1]]
        [0].each { |i| a[i].size }
        puts(a[0].size == 1 ? :y : :n)
      RUBY
    end
  end
end
