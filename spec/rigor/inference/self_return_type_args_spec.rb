# frozen_string_literal: true

require "spec_helper"

# Issue #1092 — an RBS `-> self` return substitutes the receiver's projection WITH its type arguments.
#
# Before the fix `Bases::Self` was built from the class name alone, so `Array[Integer]#tap {}` answered the
# raw `Array` and the next call on it fell to `Dynamic[top]`. A shape carrier substitutes its projected
# nominal (never the shape: ADR-76 WD3 keeps the pure self-returners on ShapeDispatch, and a block can mutate
# the receiver through its yielded alias), with every argument widened deeply; a mutator that can change the
# element types keeps the raw nominal unless the call provably adds nothing outside the arguments.
RSpec.describe "RBS `-> self` keeps the receiver's type arguments", type: :runner do
  def analyzed(source)
    analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source}))
  end

  def dumped_type(expression, prelude = "")
    analyzed("#{prelude}\ndump_type(#{expression})").diagnostics.filter_map do |diagnostic|
      diagnostic.message.delete_prefix("dump_type: ") if diagnostic.message.start_with?("dump_type")
    end.first
  end

  def flow_rules(source)
    analyzed(source).diagnostics.filter_map do |diagnostic|
      diagnostic.rule if diagnostic.rule.to_s.start_with?("flow.")
    end
  end

  def rules(source)
    analyzed(source).diagnostics.map { |diagnostic| diagnostic.rule.to_s }.uniq
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

  describe "a mutator on a generic Nominal receiver" do
    it "keeps the arguments on a method that cannot change the element types" do
      %w[sort! reverse! uniq! shuffle! clear].each do |method_name|
        expect(dumped_type("ints.#{method_name}", ints)).to match(/\AArray\[Integer\]\??\z/)
      end
      expect(dumped_type("ints.delete_if { |i| i > 1 }", ints)).to eq("Array[Integer]")
      expect(dumped_type("h.delete_if { |_k, v| v > 1 }", hash)).to eq("Hash[Symbol, Integer]")
    end

    it "keeps the arguments on an adder whose arguments provably fit" do
      expect(dumped_type("ints << 1", ints)).to eq("Array[Integer]")
      expect(dumped_type("ints.insert(0, 1)", ints)).to eq("Array[Integer]")
      expect(dumped_type("ints.concat([1, 2])", ints)).to eq("Array[Integer]")
      expect(dumped_type("h.merge!(b: 2)", hash)).to eq("Hash[Symbol, Integer]")
    end

    it "degrades an adder whose arguments do not provably fit to the raw nominal" do
      expect(dumped_type('ints.push("s")', ints)).to eq("Array")
      expect(dumped_type('ints.insert(0, "s")', ints)).to eq("Array")
      expect(dumped_type('ints.concat(["s"])', ints)).to eq("Array")
      expect(dumped_type('h.merge!(b: "s")', hash)).to eq("Hash")
      expect(dumped_type('h.merge!(b: 2) { |*| "s" }', hash)).to eq("Hash")
    end

    it "degrades an element-rewriting mutator to the raw nominal" do
      expect(dumped_type("ints.map! { |i| i.to_s }", ints)).to eq("Array")
      expect(dumped_type("ints.replace(%w[a b])", ints)).to eq("Array")
      expect(dumped_type('ints.fill("x")', ints)).to eq("Array")
      expect(dumped_type("h.transform_values!(&:to_s)", hash)).to eq("Hash")
    end

    it "does not report a method missing on the pre-call element type" do
      expect(rules(<<~RUBY)).not_to include("call.undefined-method")
        #{ints}
        list = ints.map! { |i| i.to_s }
        list.each { |s| s.upcase }
        puts ints.push("s").last.upcase
      RUBY
    end
  end

  describe "a shape receiver" do
    it "substitutes the projected nominal, never the tuple" do
      expect(dumped_type("[1, 2].tap {}")).to eq("Array[Integer]")
      expect(dumped_type("[1, 2].each {}")).to eq("Array[Integer]")
      expect(dumped_type("{ a: 1 }.tap {}")).to eq("Hash[Symbol, Integer]")
    end

    it "widens nested shape carriers through the arguments" do
      expect(dumped_type("[[1, 2]].tap {}")).to eq("Array[Array[Integer]]")
      expect(dumped_type("{ a: { b: 1 } }.tap {}")).to eq("Hash[Symbol, Hash[Symbol, Integer]]")
      expect(dumped_type("{ a: [1, 2] }.tap {}")).to eq("Hash[Symbol, Array[Integer]]")
      expect(dumped_type("[{ a: 1 }].tap { |a| a[0][:b] = 2 }.first[:b]")).to eq("Integer")
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

    # The harness does fold a comparison against a literal-pinned value; the declines below are the
    # substitute's doing, not a silent rule.
    it "folds a comparison against a value-pinned local (positive control)" do
      expect(flow_rules(<<~RUBY)).to include("flow.always-truthy-condition")
        x = [:a, :b].sample
        puts "c" if x == :c
      RUBY
    end

    # A block that mutates through the yielded alias is invisible to MutationWidening, so neither the pre-call
    # size nor a literal element set, at any depth, may survive into the call's value.
    it "does not fold a read after a mutation through the yielded alias" do
      expect(dumped_type('[1, 2].tap { |a| a << "s" }.size')).to eq("non-negative-int")
      expect(flow_rules(<<~RUBY)).to be_empty
        list = [:a, :b].tap { |l| l << :c if rand(2).zero? }
        puts "c" if list.last == :c
        opts = { a: 1 }.tap { |o| o[:b] = 2 if rand(2).zero? }
        puts "b" if opts[:b] == 2
        inner = [[1, 2]].tap { |a| a[0] << 3 }
        puts "three" if inner.first.size == 3
        h = { a: { b: 1 } }.tap { |x| x[:a][:c] = 2 }
        puts "c" if h[:a][:c] == 2
        hv = { a: [1, 2] }.tap { |x| x[:a] << 3 }
        puts "v" if hv[:a].size == 3
      RUBY
    end
  end
end
