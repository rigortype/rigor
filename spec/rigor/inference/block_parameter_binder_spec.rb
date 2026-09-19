# frozen_string_literal: true

require "prism"

RSpec.describe Rigor::Inference::BlockParameterBinder do
  def parse_block(source)
    program = Prism.parse(source).value
    call = program.statements.body.first
    call.block
  end

  def integer_nominal
    Rigor::Type::Combinator.nominal_of("Integer")
  end

  def string_nominal
    Rigor::Type::Combinator.nominal_of("String")
  end

  def untyped
    Rigor::Type::Combinator.untyped
  end

  describe "#bind" do
    it "returns an empty hash when the block has no parameters" do
      block = parse_block("foo { 1 }")
      bindings = described_class.new(expected_param_types: []).bind(block)
      expect(bindings).to eq({})
    end

    it "binds a single required positional to the matching expected type" do
      block = parse_block("foo { |x| x }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings).to eq(x: integer_nominal)
    end

    it "binds multiple required positionals in order" do
      block = parse_block("foo { |a, b| a }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal, string_nominal]
      ).bind(block)
      expect(bindings).to eq(a: integer_nominal, b: string_nominal)
    end

    it "defaults a required positional to Dynamic[Top] when the array is shorter" do
      block = parse_block("foo { |a, b| a }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings[:a]).to eq(integer_nominal)
      expect(bindings[:b]).to eq(untyped)
    end

    it "defaults every parameter to Dynamic[Top] when no expected types are given" do
      block = parse_block("foo { |a, b| a }")
      bindings = described_class.new.bind(block)
      expect(bindings).to eq(a: untyped, b: untyped)
    end

    it "binds optional positionals" do
      block = parse_block("foo { |a, b = 1| a }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal, string_nominal]
      ).bind(block)
      expect(bindings).to eq(a: integer_nominal, b: string_nominal)
    end

    it "binds a trailing required positional after a rest (the `|a, *b, c|` shape)" do
      # Regression: `bind_trailing_positionals` previously called an undefined `required_name` helper, so a `post`
      # parameter raised NoMethodError. It now routes through `bind_required_param`.
      block = parse_block("foo { |a, *b, c| c }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings[:a]).to eq(integer_nominal)
      expect(bindings).to have_key(:c)
    end

    it "binds the rest parameter as Array[Dynamic[Top]] regardless of expected types" do
      block = parse_block("foo { |a, *rest| a }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal]
      ).bind(block)
      expect(bindings[:a]).to eq(integer_nominal)
      array_type = Rigor::Type::Combinator.nominal_of("Array", type_args: [untyped])
      expect(bindings[:rest]).to eq(array_type)
    end

    it "binds keyword parameters as Dynamic[Top] (no RBS introspection in sub-phase 1)" do
      block = parse_block("foo { |a, k:, m: 0| a }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings[:a]).to eq(integer_nominal)
      expect(bindings[:k]).to eq(untyped)
      expect(bindings[:m]).to eq(untyped)
    end

    it "binds the keyword-rest parameter as Hash[Symbol, Dynamic[Top]]" do
      block = parse_block("foo { |**opts| 1 }")
      bindings = described_class.new.bind(block)
      symbol_nominal = Rigor::Type::Combinator.nominal_of("Symbol")
      expected = Rigor::Type::Combinator.nominal_of(
        "Hash",
        type_args: [symbol_nominal, untyped]
      )
      expect(bindings[:opts]).to eq(expected)
    end

    it "binds the explicit block parameter as Nominal[Proc]" do
      block = parse_block("foo { |a, &blk| a }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings[:blk]).to eq(Rigor::Type::Combinator.nominal_of(Proc))
    end

    it "binds MultiTargetNode block parameters with a non-Tuple slot to Dynamic[Top]" do
      # When the slot expected type is not a Tuple, MultiTargetBinder falls back to Dynamic[Top] for every inner local.
      # The outer `c` still binds to its slot type.
      block = parse_block("foo { |(a, b), c| c }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal, string_nominal]
      ).bind(block)
      dyn = Rigor::Type::Combinator.untyped
      expect(bindings).to eq(a: dyn, b: dyn, c: string_nominal)
    end

    it "binds trailing positionals" do
      block = parse_block("foo { |a, b, c| a }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal, string_nominal, integer_nominal]
      ).bind(block)
      expect(bindings).to eq(a: integer_nominal, b: string_nominal, c: integer_nominal)
    end

    it "binds numbered-block parameters from NumberedParametersNode" do
      # `_1` is implicit; it is bound from the per-position
      # expected_param_types array, just like an explicit `|x|`.
      block = parse_block("foo { _1.succ }")
      expect(block.parameters).to be_a(Prism::NumberedParametersNode)
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings).to eq(_1: integer_nominal)
    end

    it "binds multiple numbered-block parameters up to the body's maximum" do
      block = parse_block("foo { _1 + _2 }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal, integer_nominal]
      ).bind(block)
      expect(bindings).to eq(_1: integer_nominal, _2: integer_nominal)
    end

    it "defaults missing numbered slots to Dynamic[Top]" do
      block = parse_block("foo { _1 + _2 }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings[:_1]).to eq(integer_nominal)
      expect(bindings[:_2]).to eq(Rigor::Type::Combinator.untyped)
    end

    it "binds the `it` implicit parameter from ItParametersNode" do
      block = parse_block("foo { it.succ }")
      expect(block.parameters).to be_a(Prism::ItParametersNode)
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings).to eq(it: integer_nominal)
    end

    it "defaults `it` to Dynamic[Top] when expected_param_types is empty" do
      block = parse_block("foo { it.succ }")
      bindings = described_class.new(expected_param_types: []).bind(block)
      expect(bindings).to eq(it: untyped)
    end

    it "destructures MultiTargetNode block parameters element-wise from a Tuple" do
      block = parse_block("foo { |(a, b), c| a }")
      tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
      bindings = described_class.new(
        expected_param_types: [tuple, integer_nominal]
      ).bind(block)
      expect(bindings).to eq(a: integer_nominal, b: string_nominal, c: integer_nominal)
    end

    it "falls back to Dynamic[Top] for MultiTargetNode slots when the slot is not a Tuple" do
      block = parse_block("foo { |(a, b)| a }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      dyn = Rigor::Type::Combinator.untyped
      expect(bindings).to eq(a: dyn, b: dyn)
    end

    describe "block auto-splat (single Tuple yield -> multi-param destructure)" do
      it "splats Tuple[K, V] across |k, v| (Hash#each shape)" do
        block = parse_block("hash.each { |k, v| k }")
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        bindings = described_class.new(expected_param_types: [tuple]).bind(block)
        expect(bindings).to eq(k: integer_nominal, v: string_nominal)
      end

      it "leaves |pair| (single-param block) as Tuple[K, V] — no splat" do
        block = parse_block("hash.each { |pair| pair }")
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        bindings = described_class.new(expected_param_types: [tuple]).bind(block)
        expect(bindings).to eq(pair: tuple)
      end

      it "pads with Dynamic[Top] when the block has more params than the Tuple elements" do
        block = parse_block("hash.each { |k, v, extra| extra }")
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        bindings = described_class.new(expected_param_types: [tuple]).bind(block)
        expect(bindings).to eq(k: integer_nominal, v: string_nominal, extra: untyped)
      end

      it "does NOT splat when the receiver yields multiple args (each_with_index shape)" do
        # `each_with_index` yields `(element, index)` as two args.
        # Block `|p, i|` is a direct positional bind — no auto-splat
        # of the first element, even though it is a Tuple.
        block = parse_block("hash.each_with_index { |p, i| p }")
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        non_neg = Rigor::Type::Combinator.non_negative_int
        bindings = described_class.new(expected_param_types: [tuple, non_neg]).bind(block)
        expect(bindings).to eq(p: tuple, i: non_neg)
      end

      it "leaves a non-Array single expected element unchanged" do
        block = parse_block("foo { |a, b| a }")
        bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
        expect(bindings).to eq(a: integer_nominal, b: untyped)
      end

      it "splats a Tuple across |k, *rest| and the trailing-comma |k,| form" do
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        with_rest = described_class.new(expected_param_types: [tuple]).bind(parse_block("h.each { |k, *r| k }"))
        expect(with_rest[:k]).to eq(integer_nominal)
        trailing = described_class.new(expected_param_types: [tuple]).bind(parse_block("h.each { |k,| k }"))
        expect(trailing).to eq(k: integer_nominal)
      end

      it "does not splat into a lone |*rest|" do
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        bindings = described_class.new(expected_param_types: [tuple]).bind(parse_block("h.each { |*r| r }"))
        expect(bindings).to eq(r: Rigor::Type::Combinator.nominal_of("Array", type_args: [untyped]))
      end
    end

    # Issue #1093 — a single yielded `Array[T]` (`each_slice`, `each_cons`, `Array[Array[T]]#each`).
    describe "block auto-splat of a single Array[T] yield" do
      def array_of(element)
        Rigor::Type::Combinator.nominal_of("Array", type_args: [element])
      end

      it "binds T to each positional slot and marks them optimistic" do
        binder = described_class.new(expected_param_types: [array_of(integer_nominal)])
        expect(binder.bind(parse_block("ints.each_slice(2) { |g, h| g }")))
          .to eq(g: integer_nominal, h: integer_nominal)
        expect(binder.optimistic).to contain_exactly(:g, :h)
      end

      it "binds Array[T] to a named rest, unmarked, and splats the trailing-comma form" do
        binder = described_class.new(expected_param_types: [array_of(integer_nominal)])
        expect(binder.bind(parse_block("ints.each_slice(2) { |g, *r| g }")))
          .to eq(g: integer_nominal, r: array_of(integer_nominal))
        expect(binder.optimistic).to contain_exactly(:g)

        trailing = described_class.new(expected_param_types: [array_of(integer_nominal)])
        expect(trailing.bind(parse_block("ints.each_slice(2) { |g,| g }"))).to eq(g: integer_nominal)
      end

      it "keeps Dynamic[Top] for an optional positional, whose short-array value is its default" do
        binder = described_class.new(expected_param_types: [array_of(integer_nominal)])
        expect(binder.bind(parse_block("ints.each_slice(2) { |g, h = 5| g }"))).to eq(g: integer_nominal, h: untyped)
        expect(binder.optimistic).to contain_exactly(:g)
      end

      it "leaves a single-parameter block holding the whole Array[T]" do
        binder = described_class.new(expected_param_types: [array_of(integer_nominal)])
        expect(binder.bind(parse_block("ints.each_slice(2) { |g| g }"))).to eq(g: array_of(integer_nominal))
        expect(binder.optimistic).to be_empty
      end

      it "does not splat Dynamic[Array[T]] or Array[untyped]" do
        [Rigor::Type::Combinator.dynamic(array_of(integer_nominal)), array_of(untyped)].each do |carrier|
          bindings = described_class.new(expected_param_types: [carrier]).bind(parse_block("xs.each { |g, h| g }"))
          expect(bindings).to eq(g: carrier, h: untyped)
        end
      end

      it "destructures |(g, h)| over an Array[T] element and marks the inner names" do
        binder = described_class.new(expected_param_types: [array_of(integer_nominal)])
        expect(binder.bind(parse_block("nested.each { |(g, h)| g }"))).to eq(g: integer_nominal, h: integer_nominal)
        expect(binder.optimistic).to contain_exactly(:g, :h)
      end

      it "records the marks on the scope through #bind_onto" do
        binder = described_class.new(expected_param_types: [array_of(integer_nominal)])
        scope = binder.bind_onto(parse_block("ints.each_slice(2) { |g, *r| g }"), Rigor::Scope.empty)
        expect(scope.local(:g)).to eq(integer_nominal)
        expect(scope.optimistic_local(:g)).to eq(Rigor::Inference::OptimisticOrigin::IMPLICITLY_RETURNS_NIL)
        expect(scope.optimistic_local(:r)).to be_nil
      end
    end
  end
end
