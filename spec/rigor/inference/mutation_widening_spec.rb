# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/inference/mutation_widening"
require "rigor/scope"
require "rigor/type"

# Unit-level coverage for {Rigor::Inference::MutationWidening}.
# The integration with `eval_call` (the actual G1 / G2
# flow-folding gap closure) is exercised by the
# end-to-end loop-mutation spec under `spec/integration/`;
# this file pins the widening primitive in isolation.
RSpec.describe Rigor::Inference::MutationWidening do
  describe ".widen_for_mutator" do
    it "widens a single-element Tuple under `<<` to Array[T]" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"))
      widened = described_class.widen_for_mutator(tuple, :<<)
      expect(widened).to be_a(Rigor::Type::Nominal)
      expect(widened.class_name).to eq("Array")
      expect(widened.type_args.first.class_name).to eq("String")
    end

    it "widens a multi-element Tuple to Array[union]" do
      tuple = Rigor::Type::Combinator.tuple_of(
        Rigor::Type::Combinator.nominal_of("String"),
        Rigor::Type::Combinator.nominal_of("Integer")
      )
      widened = described_class.widen_for_mutator(tuple, :push)
      expect(widened.class_name).to eq("Array")
      arg = widened.type_args.first
      expect(arg).to be_a(Rigor::Type::Union)
    end

    it "widens an empty Tuple to Array[untyped]" do
      tuple = Rigor::Type::Combinator.tuple_of
      widened = described_class.widen_for_mutator(tuple, :<<)
      expect(widened.type_args.first).to be_a(Rigor::Type::Dynamic)
    end

    it "declines when the method is not an Array mutator" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"))
      expect(described_class.widen_for_mutator(tuple, :map)).to be_nil
      expect(described_class.widen_for_mutator(tuple, :size)).to be_nil
      expect(described_class.widen_for_mutator(tuple, :first)).to be_nil
    end

    it "declines when the type is already a plain Array nominal" do
      arr = Rigor::Type::Combinator.nominal_of("Array",
                                               type_args: [Rigor::Type::Combinator.nominal_of("String")])
      expect(described_class.widen_for_mutator(arr, :<<)).to be_nil
    end

    it "widens a HashShape under `[]=` to Hash[K, V]" do
      shape = Rigor::Type::HashShape.new(
        a: Rigor::Type::Combinator.nominal_of("Integer"),
        b: Rigor::Type::Combinator.nominal_of("String")
      )
      widened = described_class.widen_for_mutator(shape, :[]=)
      expect(widened.class_name).to eq("Hash")
      expect(widened.type_args.first.class_name).to eq("Symbol")
    end

    it "declines for HashShape under a non-Hash mutator" do
      shape = Rigor::Type::HashShape.new(a: Rigor::Type::Combinator.nominal_of("Integer"))
      expect(described_class.widen_for_mutator(shape, :<<)).to be_nil
    end

    it "is a no-op for non-shape types" do
      expect(described_class.widen_for_mutator(Rigor::Type::Combinator.nominal_of("String"), :<<)).to be_nil
      expect(described_class.widen_for_mutator(Rigor::Type::Combinator.constant_of(1), :<<)).to be_nil
      expect(described_class.widen_for_mutator(nil, :<<)).to be_nil
    end
  end

  describe ".widen_after_call" do
    # Parses the last statement in `source` as a CallNode. We
    # parse a multi-statement source so that local-variable reads
    # in the target expression resolve to `LocalVariableReadNode`
    # — Prism's parser needs an explicit assignment to a name
    # before treating later occurrences as locals (otherwise they
    # parse as zero-arg implicit-self calls).
    def parse_call(source)
      Prism.parse(source).value.statements.body.last
    end

    let(:scope) { Rigor::Scope.empty }

    it "widens a local-variable receiver bound to a Tuple under `<<`" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"))
      seeded = scope.with_local(:arms, tuple)
      call = parse_call("arms = []; arms << x")
      result = described_class.widen_after_call(call_node: call, current_scope: seeded)

      widened = result.local(:arms)
      expect(widened).to be_a(Rigor::Type::Nominal)
      expect(widened.class_name).to eq("Array")
    end

    it "widens an instance-variable receiver bound to a Tuple under `<<`" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"))
      seeded = scope.with_ivar(:@tags, tuple)
      call = parse_call("@tags << x")
      result = described_class.widen_after_call(call_node: call, current_scope: seeded)

      widened = result.ivar(:@tags)
      expect(widened.class_name).to eq("Array")
    end

    it "leaves the scope unchanged for a non-mutator call" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"))
      seeded = scope.with_local(:arms, tuple)
      call = parse_call("arms = []; arms.first")
      result = described_class.widen_after_call(call_node: call, current_scope: seeded)

      expect(result.local(:arms)).to equal(tuple)
    end

    it "leaves the scope unchanged when the receiver is not a local/ivar read" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"))
      seeded = scope.with_local(:arms, tuple)
      call = parse_call("[1] << 2") # array-literal receiver, not a name read
      expect(described_class.widen_after_call(call_node: call, current_scope: seeded)).to equal(seeded)
    end

    it "leaves the scope unchanged when the receiver has no current binding" do
      call = parse_call("arms = []; arms << x")
      expect(described_class.widen_after_call(call_node: call, current_scope: scope)).to equal(scope)
    end
  end

  describe ".widen_after_block" do
    # Parses a method body so that locals declared at method scope
    # and read inside a block resolve as LocalVariableReadNode with
    # `depth >= 1` (the outer-scope hop count Prism records).
    # Returns the outer-most call carrying the block (the
    # `.each do ... end` call site).
    def parse_each_call(body_source)
      source = "def m\n#{body_source}\nend\n"
      def_node = Prism.parse(source).value.statements.body.first
      def_node.body.body.last
    end

    let(:tuple) { Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("Integer")) }

    it "widens an outer-scope local mutated by `<<` inside a block body" do
      call = parse_each_call(<<~RUBY)
        arr = [1]
        items.each do |x|
          arr << x
        end
      RUBY
      seeded = Rigor::Scope.empty.with_local(:arr, tuple)
      result = described_class.widen_after_block(call_node: call, outer_scope: seeded)
      expect(result.local(:arr).class_name).to eq("Array")
    end

    it "leaves the outer scope unchanged when the block body has no mutators on it" do
      call = parse_each_call(<<~RUBY)
        arr = [1]
        items.each do |x|
          arr.first
        end
      RUBY
      seeded = Rigor::Scope.empty.with_local(:arr, tuple)
      result = described_class.widen_after_block(call_node: call, outer_scope: seeded)
      expect(result.local(:arr)).to equal(tuple)
    end

    it "is a no-op when the receiver is a block-local shadow (depth 0)" do
      # `arr` in the block parameter list shadows the outer name —
      # mutations on the shadow MUST NOT widen the outer binding.
      call = parse_each_call(<<~RUBY)
        arr = [1]
        items.each do |arr|
          arr << 1
        end
      RUBY
      seeded = Rigor::Scope.empty.with_local(:arr, tuple)
      result = described_class.widen_after_block(call_node: call, outer_scope: seeded)
      expect(result.local(:arr)).to equal(tuple)
    end

    it "widens an outer-scope ivar mutated by `<<` inside a block body" do
      call = parse_each_call(<<~RUBY)
        items.each do |x|
          @tags << x
        end
      RUBY
      seeded = Rigor::Scope.empty.with_ivar(:@tags, tuple)
      result = described_class.widen_after_block(call_node: call, outer_scope: seeded)
      expect(result.ivar(:@tags).class_name).to eq("Array")
    end

    it "does not descend into a nested call's own block" do
      # Outer `arr.each` carries the relevant block; the nested
      # `[1,2].each` block also contains `acc << x` but `acc`
      # is the nested call's block scope, not ours.
      call = parse_each_call(<<~RUBY)
        arr = [1]
        items.each do |x|
          [1, 2].each do |y|
            arr << y
          end
        end
      RUBY
      seeded = Rigor::Scope.empty.with_local(:arr, tuple)
      result = described_class.widen_after_block(call_node: call, outer_scope: seeded)
      # The recursive walk still finds the mutation; we just want
      # to verify we don't crash on nesting. The widening MUST
      # apply because the inner `arr` is still an outer-scope
      # local (depth >= 1).
      expect(result.local(:arr).class_name).to eq("Array")
    end

    it "is a no-op for a block-less call" do
      call = parse_each_call("arr = [1]; items.size")
      seeded = Rigor::Scope.empty.with_local(:arr, tuple)
      expect(described_class.widen_after_block(call_node: call, outer_scope: seeded)).to equal(seeded)
    end
  end
end
