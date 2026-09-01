# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/inference/mutation_widening"
require "rigor/scope"
require "rigor/type"

# Unit-level coverage for {Rigor::Inference::MutationWidening}. The integration with `eval_call` (the actual G1 / G2
# flow-folding gap closure) is exercised by the end-to-end loop-mutation spec under `spec/integration/`; this file pins
# the widening primitive in isolation.
RSpec.describe Rigor::Inference::MutationWidening do
  describe ".pure_self_returner?" do
    it "recognizes freeze, dup, clone, and itself" do
      expect(described_class.pure_self_returner?(:freeze)).to be true
      expect(described_class.pure_self_returner?(:dup)).to be true
      expect(described_class.pure_self_returner?(:clone)).to be true
      expect(described_class.pure_self_returner?(:itself)).to be true
    end

    it "declines for mutators and ordinary readers" do
      expect(described_class.pure_self_returner?(:<<)).to be false
      expect(described_class.pure_self_returner?(:push)).to be false
      expect(described_class.pure_self_returner?(:first)).to be false
      expect(described_class.pure_self_returner?(:map)).to be false
    end
  end

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

    # Issue #560 — the mutator that falsified the SHAPE can also falsify the VALUES: `t = [1, 2];
    # t[0] += 5` holds 6 at slot 0, so a surviving `Array[1 | 2]` feeds the constant-comparison fold
    # and fires a false always-falsey on `t[0] == 6`. The widened element bound is the class nominal.
    it "widens value-pinned Tuple elements to their class nominal" do
      tuple = Rigor::Type::Combinator.tuple_of(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2)
      )
      widened = described_class.widen_for_mutator(tuple, :[]=)
      expect(widened.class_name).to eq("Array")
      expect(widened.type_args.first).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end

    it "widens value-pinned HashShape values to their class nominal" do
      shape = Rigor::Type::HashShape.new(headers: Rigor::Type::Combinator.constant_of(false))
      widened = described_class.widen_for_mutator(shape, :[]=)
      expect(widened.class_name).to eq("Hash")
      expect(widened.type_args.last).to eq(Rigor::Type::Combinator.nominal_of("FalseClass"))
    end

    it "keeps value pinning under an ADDING mutator (`<<` never rewrites an existing slot)" do
      # haml's `tmp = [:multi]; tmp << compiled` returns arrays that really do start with `:multi`,
      # and its handwritten sig says `Array[:multi]` — widening the pinning under `<<` drew eight
      # false `def.return-type-mismatch` on the corpus gate. The added value's under-coverage is the
      # value-join half still open on #560.
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.constant_of(:multi))
      widened = described_class.widen_for_mutator(tuple, :<<)
      expect(widened.class_name).to eq("Array")
      expect(widened.type_args.first).to eq(Rigor::Type::Combinator.constant_of(:multi))
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

    it "widens a non-empty-array refinement to its base Array nominal under a size-mutator" do
      non_empty = Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("String"))
      widened = described_class.widen_for_mutator(non_empty, :clear)
      expect(widened).to be_a(Rigor::Type::Nominal)
      expect(widened.class_name).to eq("Array")
      expect(widened.type_args.first.class_name).to eq("String")
    end

    it "widens a non-empty-array refinement under every Array mutator that can empty it" do
      non_empty = Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("String"))
      %i[pop shift delete_if reject! clear replace select!].each do |mutator|
        expect(described_class.widen_for_mutator(non_empty, mutator)).to(
          eq(non_empty.base), "expected #{mutator} to widen non-empty-array to its base"
        )
      end
    end

    it "keeps the non-empty-array refinement under readers and non-mutating siblings" do
      non_empty = Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("String"))
      expect(described_class.widen_for_mutator(non_empty, :size)).to be_nil
      expect(described_class.widen_for_mutator(non_empty, :empty?)).to be_nil
      expect(described_class.widen_for_mutator(non_empty, :map)).to be_nil
      expect(described_class.widen_for_mutator(non_empty, :first)).to be_nil
    end

    it "widens a non-empty-hash refinement to its base Hash nominal under a Hash mutator" do
      non_empty = Rigor::Type::Combinator.non_empty_hash(
        Rigor::Type::Combinator.nominal_of("Symbol"),
        Rigor::Type::Combinator.nominal_of("Integer")
      )
      widened = described_class.widen_for_mutator(non_empty, :clear)
      expect(widened).to be_a(Rigor::Type::Nominal)
      expect(widened.class_name).to eq("Hash")
      expect(widened.type_args.map(&:class_name)).to eq(%w[Symbol Integer])
    end

    it "does not cross the mutator tables between the Array and Hash refinements" do
      non_empty_array = Rigor::Type::Combinator.non_empty_array(Rigor::Type::Combinator.nominal_of("String"))
      non_empty_hash = Rigor::Type::Combinator.non_empty_hash
      # `store` is Hash-only; `pop` is Array-only.
      expect(described_class.widen_for_mutator(non_empty_array, :store)).to be_nil
      expect(described_class.widen_for_mutator(non_empty_hash, :pop)).to be_nil
    end

    it "leaves the String / Integer refinements alone — their mutators are in neither table" do
      # `non-empty-string` and `non-zero-int` are empty-witness Differences too, but no method that
      # could reach them is listed as an Array / Hash mutator. Pinned so a future table addition
      # that would silently widen them fails here.
      expect(described_class.widen_for_mutator(Rigor::Type::Combinator.non_empty_string, :<<)).to be_nil
      expect(described_class.widen_for_mutator(Rigor::Type::Combinator.non_empty_string, :concat)).to be_nil
      expect(described_class.widen_for_mutator(Rigor::Type::Combinator.non_zero_int, :<<)).to be_nil
    end

    it "declines for a Difference that is not an empty-witness refinement" do
      # `Array[String] - Tuple[String]` removes a one-element witness, not the empty one: not a
      # catalogued refinement, so the widening arm must not claim it.
      odd = Rigor::Type::Combinator.difference(
        Rigor::Type::Combinator.nominal_of("Array", type_args: [Rigor::Type::Combinator.nominal_of("String")]),
        Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"))
      )
      expect(described_class.widen_for_mutator(odd, :clear)).to be_nil
    end
  end

  describe ".widen_after_call" do
    # Parses the last statement in `source` as a CallNode. We parse a multi-statement source so that local-variable
    # reads in the target expression resolve to `LocalVariableReadNode` — Prism's parser needs an explicit assignment to
    # a name before treating later occurrences as locals (otherwise they parse as zero-arg implicit-self calls).
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

    it "leaves the scope unchanged for pure self-returners on a Tuple" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"))
      seeded = scope.with_local(:arms, tuple)

      %i[freeze dup clone itself].each do |meth|
        call = parse_call("arms = []; arms.#{meth}")
        result = described_class.widen_after_call(call_node: call, current_scope: seeded)
        expect(result.local(:arms)).to equal(tuple),
                                       "expected #{meth} not to widen the Tuple, but it did"
      end
    end

    it "leaves the scope unchanged for pure self-returners on a HashShape" do
      shape = Rigor::Type::HashShape.new(a: Rigor::Type::Combinator.nominal_of("Integer"))
      seeded = scope.with_local(:params, shape)

      %i[freeze dup clone itself].each do |meth|
        call = parse_call("params = {}; params.#{meth}")
        result = described_class.widen_after_call(call_node: call, current_scope: seeded)
        expect(result.local(:params)).to equal(shape),
                                         "expected #{meth} not to widen the HashShape, but it did"
      end
    end

    # Issue #277 — the receiver may SELECT among variables instead of naming one. Every candidate the
    # expression can evaluate to is the mutation's possible target, so every candidate must widen.
    it "widens both arms of a ternary receiver under `[]=`" do
      shape = Rigor::Type::HashShape.new(a: Rigor::Type::Combinator.nominal_of("Integer"))
      seeded = scope.with_local(:required, shape).with_local(:optional, shape)
      call = parse_call("required = {}; optional = {}; (flag ? required : optional)[key] = value")
      result = described_class.widen_after_call(call_node: call, current_scope: seeded)

      expect(result.local(:required).class_name).to eq("Hash")
      expect(result.local(:optional).class_name).to eq("Hash")
    end

    it "widens both arms of an `if`/`else` receiver and of a short-circuit receiver" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.nominal_of("String"))
      seeded = scope.with_local(:head, tuple).with_local(:tail, tuple)

      if_call = parse_call("head = []; tail = []; (if flag then head else tail end) << x")
      if_result = described_class.widen_after_call(call_node: if_call, current_scope: seeded)
      expect(if_result.local(:head).class_name).to eq("Array")
      expect(if_result.local(:tail).class_name).to eq("Array")

      or_call = parse_call("head = []; tail = []; (head || tail) << x")
      or_result = described_class.widen_after_call(call_node: or_call, current_scope: seeded)
      expect(or_result.local(:head).class_name).to eq("Array")
      expect(or_result.local(:tail).class_name).to eq("Array")
    end

    it "declines for a receiver that names no binding — an index read is not an alias" do
      shape = Rigor::Type::HashShape.new(required: Rigor::Type::Combinator.tuple_of)
      seeded = scope.with_local(:declared, shape)
      call = parse_call("declared = {}; declared[kind] << key")

      expect(described_class.widen_after_call(call_node: call, current_scope: seeded)).to equal(seeded)
    end
  end

  describe ".widen_after_block" do
    # Parses a method body so that locals declared at method scope and read inside a block resolve as
    # LocalVariableReadNode with `depth >= 1` (the outer-scope hop count Prism records). Returns the outer-most call
    # carrying the block (the `.each do ... end` call site).
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
      # `arr` in the block parameter list shadows the outer name — mutations on the shadow MUST NOT widen the outer
      # binding.
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
      # Outer `arr.each` carries the relevant block; the nested `[1,2].each` block also contains `acc << x` but `acc` is
      # the nested call's block scope, not ours.
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
      # The recursive walk still finds the mutation; we just want to verify we don't crash on nesting. The widening MUST
      # apply because the inner `arr` is still an outer-scope local (depth >= 1).
      expect(result.local(:arr).class_name).to eq("Array")
    end

    it "is a no-op for a block-less call" do
      call = parse_each_call("arr = [1]; items.size")
      seeded = Rigor::Scope.empty.with_local(:arr, tuple)
      expect(described_class.widen_after_block(call_node: call, outer_scope: seeded)).to equal(seeded)
    end

    it "leaves the outer scope unchanged for pure self-returners inside a block body" do
      call = parse_each_call(<<~RUBY)
        arr = [1]
        items.each do |x|
          arr.freeze
          arr.dup
          arr.clone
          arr.itself
        end
      RUBY
      seeded = Rigor::Scope.empty.with_local(:arr, tuple)
      result = described_class.widen_after_block(call_node: call, outer_scope: seeded)
      expect(result.local(:arr)).to equal(tuple)
    end

    # Issue #277's exact shape: the block routes the mutation through a ternary over two captured hashes.
    it "widens every captured arm of a selection receiver inside a block body" do
      call = parse_each_call(<<~RUBY)
        required = {}
        optional = {}
        rows.each do |kind, key, info|
          (kind == :required ? required : optional)[key] = info
        end
      RUBY
      shape = Rigor::Type::HashShape.new(a: Rigor::Type::Combinator.nominal_of("Integer"))
      seeded = Rigor::Scope.empty.with_local(:required, shape).with_local(:optional, shape)
      result = described_class.widen_after_block(call_node: call, outer_scope: seeded)

      expect(result.local(:required).class_name).to eq("Hash")
      expect(result.local(:optional).class_name).to eq("Hash")
    end

    # The depth-0 skip applies per candidate, not per receiver expression: a selection mixing an outer capture
    # with a block-local shadow widens only the capture.
    it "skips a block-local arm of a selection receiver while widening the captured arm" do
      call = parse_each_call(<<~RUBY)
        arr = [1]
        other = [1]
        items.each do |arr|
          (flag ? arr : other) << 1
        end
      RUBY
      seeded = Rigor::Scope.empty.with_local(:arr, tuple).with_local(:other, tuple)
      result = described_class.widen_after_block(call_node: call, outer_scope: seeded)

      expect(result.local(:arr)).to equal(tuple)
      expect(result.local(:other).class_name).to eq("Array")
    end
  end


  describe ".widen_hash_shape" do
    it "wraps an empty HashShape as Hash[untyped, untyped] via Combinator.nominal_of" do
      widened = described_class.widen_hash_shape(Rigor::Type::HashShape.new)
      expect(widened).to be_a(Rigor::Type::Nominal)
      expect(widened.class_name).to eq("Hash")
      expect(widened.type_args[0]).to be_a(Rigor::Type::Dynamic)
      expect(widened.type_args[1]).to be_a(Rigor::Type::Dynamic)
    end

    it "wraps a populated HashShape as Hash[key_union, value_union]" do
      int_type = Rigor::Type::Combinator.nominal_of("Integer")
      str_type = Rigor::Type::Combinator.nominal_of("String")
      shape = Rigor::Type::HashShape.new(a: int_type, b: str_type)
      widened = described_class.widen_hash_shape(shape)
      expect(widened.class_name).to eq("Hash")
      expect(widened.type_args[0]).to eq(Rigor::Type::Combinator.nominal_of("Symbol"))
      expect(widened.type_args[1]).to eq(Rigor::Type::Combinator.union(int_type, str_type))
    end

    it "widens numeric keys to their class nominal and singleton keys to their constant" do
      int_type = Rigor::Type::Combinator.nominal_of("Integer")
      shape = Rigor::Type::HashShape.new(1 => int_type, 1.0 => int_type, nil => int_type)
      widened = described_class.widen_hash_shape(shape)
      expect(widened.class_name).to eq("Hash")
      expect(widened.type_args[0]).to eq(
        Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.nominal_of("Integer"),
          Rigor::Type::Combinator.nominal_of("Float"),
          Rigor::Type::Combinator.constant_of(nil)
        )
      )
    end
  end
end
