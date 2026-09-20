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

    it "binds MultiTargetNode block parameters with a slot that may convert to Dynamic[Top]" do
      # When the slot's value may answer `to_ary` (here `Object`, which an Array is), MultiTargetBinder falls back
      # to Dynamic[Top] for every inner local. The outer `c` still binds to its slot type.
      block = parse_block("foo { |(a, b), c| c }")
      bindings = described_class.new(
        expected_param_types: [Rigor::Type::Combinator.nominal_of("Object"), string_nominal]
      ).bind(block)
      dyn = Rigor::Type::Combinator.untyped
      expect(bindings).to eq(a: dyn, b: dyn, c: string_nominal)
    end

    it "wraps a MultiTargetNode slot whose value has no to_ary as [value] (issue #1094)" do
      # `[[1, "s"]].each { |(a, b), c| }` hands `(a, b)` the Integer 1, which Ruby destructures as `[1]`.
      block = parse_block("foo { |(a, b), c| c }")
      bindings = described_class.new(expected_param_types: [integer_nominal, string_nominal]).bind(block)
      expect(bindings).to eq(a: integer_nominal, b: Rigor::Type::Combinator.constant_of(nil), c: string_nominal)
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

    it "falls back to Dynamic[Top] for MultiTargetNode slots when the slot is not decomposable" do
      block = parse_block("foo { |(a, b)| a }")
      bindings = described_class.new(expected_param_types: [untyped]).bind(block)
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

      it "reads a trailing positional after a rest from the Tuple's tail (|*r, v|)" do
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        bindings = described_class.new(expected_param_types: [tuple]).bind(parse_block("h.each { |*r, v| v }"))
        expect(bindings[:v]).to eq(string_nominal)
      end

      it "splits |a, *r, b| over a Tuple into head, middle and tail" do
        float = Rigor::Type::Combinator.nominal_of("Float")
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal, float)
        bindings = described_class.new(expected_param_types: [tuple]).bind(parse_block("xs.each { |a, *r, b| b }"))
        expect(bindings.slice(:a, :b)).to eq(a: integer_nominal, b: float)
      end

      it "binds a trailing positional past a short Tuple to Dynamic[Top]" do
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal)
        bindings = described_class.new(expected_param_types: [tuple]).bind(parse_block("xs.each { |a, *r, b| b }"))
        expect(bindings.slice(:a, :b)).to eq(a: integer_nominal, b: untyped)
      end

      it "starts every #bind from the declared types, so a reused binder does not splat twice" do
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        binder = described_class.new(expected_param_types: [tuple])
        binder.bind(parse_block("h.each { |k, v| k }"))
        expect(binder.bind(parse_block("h.each { |pair| pair }"))).to eq(pair: tuple)

        array = Rigor::Type::Combinator.nominal_of("Array", type_args: [integer_nominal])
        reused = described_class.new(expected_param_types: [array])
        reused.bind(parse_block("xs.each { |g, *r| g }"))
        expect(reused.bind(parse_block("xs.each { |*r| r }")))
          .to eq(r: Rigor::Type::Combinator.nominal_of("Array", type_args: [untyped]))
        expect(reused.optimistic).to be_empty
      end

      it "does not splat into |a = 1, *r|, which CRuby leaves unsplatted" do
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        array = Rigor::Type::Combinator.nominal_of("Array", type_args: [integer_nominal])
        [tuple, array].each do |carrier|
          binder = described_class.new(expected_param_types: [carrier])
          bindings = binder.bind(parse_block("xs.each { |a = 1, *r| a }"))
          expect(bindings[:a]).to eq(carrier), "for #{carrier.describe}"
          expect(binder.optimistic).to be_empty
        end
      end

      it "splats |a = 1, b = 2|, which has more than one optional" do
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        bindings = described_class.new(expected_param_types: [tuple]).bind(parse_block("xs.each { |a = 1, b = 2| a }"))
        expect(bindings).to eq(a: integer_nominal, b: string_nominal)
      end

      it "does not splat into |a, &b|" do
        tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
        bindings = described_class.new(expected_param_types: [tuple]).bind(parse_block("xs.each { |a, &b| a }"))
        expect(bindings[:a]).to eq(tuple)
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

      it "binds Dynamic[Top] per slot for Dynamic[Array[T]] or Array[untyped], which it cannot decompose" do
        [Rigor::Type::Combinator.dynamic(array_of(integer_nominal)), array_of(untyped)].each do |carrier|
          binder = described_class.new(expected_param_types: [carrier])
          expect(binder.bind(parse_block("xs.each { |g, h| g }"))).to eq(g: untyped, h: untyped)
          expect(binder.optimistic).to be_empty
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

    # Issue #1094 — a union of splattable carriers splats member by member. Each join is paired with a decline
    # that keeps the pre-#1094 answer, so a construction error that stops splatting cannot pass both.
    describe "block auto-splat of a union yield" do
      def array_of(element)
        Rigor::Type::Combinator.nominal_of("Array", type_args: [element])
      end

      def union(*members)
        Rigor::Type::Combinator.union(*members)
      end

      def tuple(*elements)
        Rigor::Type::Combinator.tuple_of(*elements)
      end

      it "joins each position across Tuple members, a slot past a short member staying Dynamic[Top]" do
        yielded = union(tuple(string_nominal, integer_nominal), tuple(integer_nominal))
        binder = described_class.new(expected_param_types: [yielded])
        expect(binder.bind(parse_block("xs.each { |a, b| a }")))
          .to eq(a: union(string_nominal, integer_nominal), b: untyped)
        expect(binder.optimistic).to be_empty
      end

      it "marks a position any Array[T] member marked, and joins the rest only when every member supplies one" do
        yielded = union(array_of(integer_nominal), tuple(string_nominal, string_nominal))
        binder = described_class.new(expected_param_types: [yielded])
        expect(binder.bind(parse_block("xs.each { |a, b| a }")))
          .to eq(a: union(integer_nominal, string_nominal), b: union(integer_nominal, string_nominal))
        expect(binder.optimistic).to contain_exactly(:a, :b)

        with_rest = described_class.new(expected_param_types: [yielded]).bind(parse_block("xs.each { |a, *r| a }"))
        expect(with_rest[:r]).to eq(array_of(untyped))

        arrays = union(array_of(integer_nominal), array_of(string_nominal))
        all_arrays = described_class.new(expected_param_types: [arrays]).bind(parse_block("xs.each { |a, *r| a }"))
        expect(all_arrays[:r]).to eq(union(array_of(integer_nominal), array_of(string_nominal)))
      end

      it "softens a member's bare nil out of a position another member fills, marking the position" do
        nil_type = Rigor::Type::Combinator.constant_of(nil)
        yielded = union(tuple(integer_nominal, string_nominal), tuple(nil_type, nil_type))
        binder = described_class.new(expected_param_types: [yielded])
        expect(binder.bind(parse_block("xs.each { |a, b| a }"))).to eq(a: integer_nominal, b: string_nominal)
        expect(binder.optimistic).to contain_exactly(:a, :b)
      end

      it "does not splat, nor wrap, a carrier with no array member" do
        yielded = union(string_nominal, Rigor::Type::Combinator.constant_of(nil))
        bindings = described_class.new(expected_param_types: [yielded]).bind(parse_block("xs.each { |a, b| a }"))
        expect(bindings).to eq(a: yielded, b: untyped)

        lone = described_class.new(expected_param_types: [string_nominal])
        expect(lone.bind(parse_block("xs.each { |a, b| a }"))).to eq(a: string_nominal, b: untyped)
      end
    end

    # Issue #1116 — the parameter list decides the splat, so a carrier the binder cannot decompose must not
    # leave the whole value on the first parameter. Each fallback is paired with the precise carrier it must
    # not disturb, so a change that widened everything to Dynamic[Top] could not pass both.
    describe "block auto-splat of a carrier it cannot decompose" do
      def array_of(element)
        Rigor::Type::Combinator.nominal_of("Array", type_args: [element])
      end

      def union(*members)
        Rigor::Type::Combinator.union(*members)
      end

      def tuple(*elements)
        Rigor::Type::Combinator.tuple_of(*elements)
      end

      def nil_type
        Rigor::Type::Combinator.constant_of(nil)
      end

      def array_nominal
        Rigor::Type::Combinator.nominal_of("Array")
      end

      # `[1, 2].tap { |a, b| }` — #1092 widens the `-> self` yield of a literal-tuple receiver to the raw
      # `Array`, which has no element type to hand the slots.
      it "binds Dynamic[Top] per slot for a raw Array, where the Tuple it widened from stays precise" do
        binder = described_class.new(expected_param_types: [array_nominal])
        expect(binder.bind(parse_block("[1, 2].tap { |a, b| a }"))).to eq(a: untyped, b: untyped)
        expect(binder.optimistic).to be_empty

        precise = described_class.new(expected_param_types: [tuple(integer_nominal, string_nominal)])
        expect(precise.bind(parse_block("xs.each { |a, b| a }"))).to eq(a: integer_nominal, b: string_nominal)
      end

      it "leaves a single-parameter block holding the whole raw Array" do
        binder = described_class.new(expected_param_types: [array_nominal])
        expect(binder.bind(parse_block("[1, 2].tap { |a| a }"))).to eq(a: array_nominal)
        expect(binder.bind(parse_block("[1, 2].tap { it }"))).to eq(it: array_nominal)
      end

      it "binds the default Array[Dynamic[Top]] to a named rest under a raw Array" do
        binder = described_class.new(expected_param_types: [array_nominal])
        expect(binder.bind(parse_block("[1, 2].tap { |a, *r| a }"))).to eq(a: untyped, r: array_of(untyped))
        expect(binder.bind(parse_block("[1, 2].tap { |*r, z| z }"))).to eq(r: array_of(untyped), z: untyped)
      end

      # `[[1, "a"], nil].each { |a, b| }` — CRuby hands the `nil` iteration `a = nil, b = nil`, because `nil`
      # has no `to_ary`, so the member contributes `nil` to every slot and #1094's softening takes it out.
      it "gives a nil member nil per slot, softened out of a position another member fills" do
        yielded = union(tuple(integer_nominal, string_nominal), nil_type)
        binder = described_class.new(expected_param_types: [yielded])
        expect(binder.bind(parse_block("xs.each { |a, b| a }"))).to eq(a: integer_nominal, b: string_nominal)
        expect(binder.optimistic).to contain_exactly(:a, :b)

        over_array = described_class.new(expected_param_types: [union(array_of(integer_nominal), nil_type)])
        expect(over_array.bind(parse_block("xs.each { |a, b| a }"))).to eq(a: integer_nominal, b: integer_nominal)
        expect(over_array.optimistic).to contain_exactly(:a, :b)
      end

      it "floors every slot when an opaque or non-array member joins a precise one" do
        [array_nominal, string_nominal].each do |other|
          yielded = union(tuple(integer_nominal, string_nominal), other)
          bindings = described_class.new(expected_param_types: [yielded]).bind(parse_block("xs.each { |a, b| a }"))
          expect(bindings).to eq(a: untyped, b: untyped)
        end
      end

      # `str.scan(/(\w+)=(\w+)/) { |name, body| }` — joining the whole match's `String` against a capture's
      # `String?` would hand `name` a `String?` and fire `call.possible-nil-receiver` on `name.to_sym`,
      # which the two groups' correlated invariant makes a false positive (ADR-5).
      it "floors a String | Array[String?] yield rather than joining the capture's nil into it" do
        yielded = union(string_nominal, array_of(union(string_nominal, nil_type)))
        bindings = described_class.new(expected_param_types: [yielded]).bind(parse_block("s.scan(re) { |a, b| a }"))
        expect(bindings).to eq(a: untyped, b: untyped)
      end

      it "reads the numbered-parameter twin of the raw-Array case the same way" do
        binder = described_class.new(expected_param_types: [array_nominal])
        expect(binder.bind(parse_block("[1, 2].tap { _1; _2 }"))).to eq(_1: untyped, _2: untyped)
        expect(binder.bind(parse_block("[1, 2].tap { _1 }"))).to eq(_1: array_nominal)
      end
    end

    # Issue #1108 — a numbered-parameter block reads as the explicit list of `maximum` required positionals,
    # so it auto-splats (and marks) exactly as that list does. Each case is checked against its explicit twin.
    describe "numbered-parameter auto-splat" do
      def array_of(element)
        Rigor::Type::Combinator.nominal_of("Array", type_args: [element])
      end

      def pair
        Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
      end

      def bind_both(expected, numbered_source, explicit_source)
        [numbered_source, explicit_source].map do |source|
          binder = described_class.new(expected_param_types: expected)
          [binder.bind(parse_block(source)).values, binder.optimistic.size]
        end
      end

      it "splats a Tuple across _1, _2 as |k, v| does (Hash#each shape)" do
        numbered, explicit = bind_both([pair], "h.each { _1; _2 }", "h.each { |k, v| k }")
        expect(numbered).to eq(explicit)
        expect(numbered).to eq([[integer_nominal, string_nominal], 0])
      end

      it "splats an Array[T] across _1, _2 as |g, h| does, marking both optimistic" do
        binder = described_class.new(expected_param_types: [array_of(integer_nominal)])
        expect(binder.bind(parse_block("ints.each_slice(2) { _1 + _2 }")))
          .to eq(_1: integer_nominal, _2: integer_nominal)
        expect(binder.optimistic).to contain_exactly(:_1, :_2)

        numbered, explicit = bind_both([array_of(integer_nominal)], "xs.each { _1 + _2 }", "xs.each { |g, h| g }")
        expect(numbered).to eq(explicit)
      end

      it "splats when only _2 is referenced, _1 still bound" do
        bindings = described_class.new(expected_param_types: [pair]).bind(parse_block("h.each { _2 }"))
        expect(bindings).to eq(_1: integer_nominal, _2: string_nominal)
      end

      it "leaves a slot past the Tuple at Dynamic[Top], as |a, b, c| does" do
        numbered, explicit = bind_both([pair], "h.each { _3 }", "h.each { |a, b, c| a }")
        expect(numbered).to eq(explicit)
        expect(numbered.first.last).to eq(untyped)
      end

      it "does not splat a block that references only _1, nor an `it` block, as |a| does not" do
        [pair, array_of(integer_nominal)].each do |carrier|
          ["h.each { _1 }", "h.each { it }", "h.each { |a| a }"].each do |source|
            binder = described_class.new(expected_param_types: [carrier])
            expect(binder.bind(parse_block(source)).values).to eq([carrier]), "#{source} over #{carrier.describe}"
            expect(binder.optimistic).to be_empty
          end
        end
      end

      it "does not splat a two-value yield (each_with_index)" do
        yielded = [pair, integer_nominal]
        numbered, explicit = bind_both(yielded, "xs.each_with_index { _1; _2 }", "xs.each_with_index { |a, b| a }")
        expect(numbered).to eq(explicit)
        expect(numbered).to eq([[pair, integer_nominal], 0])
      end

      it "joins a union yield per position as |a, b| does" do
        yielded = Rigor::Type::Combinator.union(pair, array_of(string_nominal))
        numbered, explicit = bind_both([yielded], "xs.each { _1; _2 }", "xs.each { |a, b| a }")
        expect(numbered).to eq(explicit)
      end

      it "records the marks on the scope through #bind_onto" do
        binder = described_class.new(expected_param_types: [array_of(integer_nominal)])
        scope = binder.bind_onto(parse_block("ints.each_slice(2) { _1 + _2 }"), Rigor::Scope.empty)
        expect(scope.local(:_2)).to eq(integer_nominal)
        expect(scope.optimistic_local(:_2)).to eq(Rigor::Inference::OptimisticOrigin::IMPLICITLY_RETURNS_NIL)
      end
    end
  end
end
