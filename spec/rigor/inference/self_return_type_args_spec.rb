# frozen_string_literal: true

require "spec_helper"

# Issue #1092 — an RBS `-> self` return substitutes the receiver's projection WITH its type arguments.
#
# Before the fix `Bases::Self` was built from the class name alone, so `Array[Integer]#tap {}` answered the
# raw `Array` and the next call on it fell to `Dynamic[top]`. A shape carrier substitutes its projected
# nominal (never the shape: ADR-76 WD3 keeps the pure self-returners on ShapeDispatch, and a block can mutate
# the receiver through its yielded alias), with value-pinned arguments widened to their nominal base; a
# mutator on a shape carrier keeps the raw nominal.
RSpec.describe "RBS `-> self` keeps the receiver's type arguments", type: :runner do
  def dumped_types(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end
  end

  def dumped_type(expression, prelude = "")
    dumped_types("#{prelude}\ndump_type(#{expression})").first
  end

  def flow_rules(source)
    result = analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
    result.diagnostics.filter_map { |diagnostic| diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.") }
  end

  let(:ints) { "ints = (1..rand(9)).to_a" }
  let(:hash) { "h = [[:a, 1]].to_h { |k, v| [k, v * rand(2)] }" }

  describe "a generic Nominal receiver" do
    %w[ints.itself ints.tap{} ints.freeze ints.dup ints.each{} ints.push(1)].each do |call|
      it "types `#{call}` as Array[Integer]" do
        expect(dumped_type(call, ints)).to eq("Array[Integer]")
        expect(dumped_type("#{call}.first", ints)).to eq("Integer")
      end
    end

    it "keeps a Hash receiver's arguments" do
      expect(dumped_type("h", hash)).to eq("Hash[Symbol, Integer]")
      expect(dumped_type("h.tap {}", hash)).to eq("Hash[Symbol, Integer]")
      expect(dumped_type("h.each {}", hash)).to eq("Hash[Symbol, Integer]")
    end

    it "unions a block `break` value with the argument-bearing self" do
      expect(dumped_type('ints.tap { break "s" if rand(2).zero? }', ints)).to eq('"s" | Array[Integer]')
    end

    it "leaves a non-generic receiver as it was" do
      expect(dumped_type('"a".dup.tap {}')).to eq("String")
    end
  end

  describe "a shape receiver" do
    it "substitutes the projected nominal, never the tuple" do
      expect(dumped_type("[1, 2].tap {}")).to eq("Array[Integer]")
      expect(dumped_type("[1, 2].each {}")).to eq("Array[Integer]")
      expect(dumped_type("{ a: 1 }.tap {}")).to eq("Hash[Symbol, Integer]")
    end

    it "keeps the pure self-returners on the shape (ADR-76 WD3)" do
      %w[freeze dup clone itself].each do |method_name|
        expect(dumped_type("[1, 2].#{method_name}")).to eq("[1, 2]")
      end
      expect(dumped_type("{ a: 1 }.freeze")).to eq("{ a: 1 }")
    end

    it "keeps the raw nominal for a mutator" do
      expect(dumped_type("[1, 2].push(3)")).to eq("Array")
      expect(dumped_type("[1, 2] << 3")).to eq("Array")
      expect(dumped_type("[1, 2].concat([3])")).to eq("Array")
      expect(dumped_type("{ a: 1 }.merge!(b: 2)")).to eq("Hash")
    end

    # A block that mutates through the yielded alias is invisible to MutationWidening, so neither the pre-call
    # size nor a literal element set may survive into the call's value.
    it "does not fold a read after a mutation through the yielded alias" do
      expect(dumped_type('[1, 2].tap { |a| a << "s" }.size')).not_to eq("2")
      expect(flow_rules(<<~RUBY)).to be_empty
        list = [:a, :b].tap { |l| l << :c if rand(2).zero? }
        puts "c" if list.last == :c
        opts = { a: 1 }.tap { |o| o[:b] = 2 if rand(2).zero? }
        puts "b" if opts[:b] == 2
      RUBY
    end
  end
end
