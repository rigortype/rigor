# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::MultiTargetBinder do
  def constant(value)
    Rigor::Type::Combinator.constant_of(value)
  end

  def tuple(*elements)
    Rigor::Type::Combinator.tuple_of(*elements)
  end

  def parse_multi_write(source)
    ast = Prism.parse(source).value
    ast.statements.body.first
  end

  describe ".bind" do
    it "binds two targets element-wise from a Tuple rhs" do
      node = parse_multi_write("a, b = [1, 2]")
      result = described_class.bind(node, tuple(constant(1), constant(2)))
      expect(result).to eq(a: constant(1), b: constant(2))
    end

    it "fills extra fronts with Constant[nil] when the tuple is shorter" do
      node = parse_multi_write("a, b, c = [1, 2]")
      result = described_class.bind(node, tuple(constant(1), constant(2)))
      expect(result).to eq(a: constant(1), b: constant(2), c: constant(nil))
    end

    it "ignores extra elements when the tuple is longer" do
      node = parse_multi_write("a, b = [1, 2, 3]")
      result = described_class.bind(node, tuple(constant(1), constant(2), constant(3)))
      expect(result).to eq(a: constant(1), b: constant(2))
    end

    it "binds the rest target as a Tuple of middle elements" do
      node = parse_multi_write("a, *r, c = [1, 2, 3, 4]")
      result = described_class.bind(
        node,
        tuple(constant(1), constant(2), constant(3), constant(4))
      )
      expect(result[:a]).to eq(constant(1))
      expect(result[:c]).to eq(constant(4))
      expect(result[:r]).to eq(tuple(constant(2), constant(3)))
    end

    it "binds the rest as Tuple[] when the source has no surplus elements" do
      node = parse_multi_write("a, *r, c = [1, 2]")
      result = described_class.bind(node, tuple(constant(1), constant(2)))
      expect(result[:a]).to eq(constant(1))
      expect(result[:c]).to eq(constant(2))
      expect(result[:r]).to eq(tuple)
    end

    it "binds a leading rest" do
      node = parse_multi_write("*r, b = [1, 2, 3]")
      result = described_class.bind(node, tuple(constant(1), constant(2), constant(3)))
      expect(result[:r]).to eq(tuple(constant(1), constant(2)))
      expect(result[:b]).to eq(constant(3))
    end

    it "binds a trailing rest" do
      node = parse_multi_write("a, *r = [1, 2, 3]")
      result = described_class.bind(node, tuple(constant(1), constant(2), constant(3)))
      expect(result[:a]).to eq(constant(1))
      expect(result[:r]).to eq(tuple(constant(2), constant(3)))
    end

    it "skips an anonymous splat (`*`)" do
      node = parse_multi_write("a, *, c = [1, 2, 3, 4]")
      result = described_class.bind(
        node,
        tuple(constant(1), constant(2), constant(3), constant(4))
      )
      expect(result).to eq(a: constant(1), c: constant(4))
    end

    it "recurses into nested MultiTargetNodes" do
      node = parse_multi_write("a, (b, c) = [1, [2, 3]]")
      result = described_class.bind(
        node,
        tuple(constant(1), tuple(constant(2), constant(3)))
      )
      expect(result).to eq(a: constant(1), b: constant(2), c: constant(3))
    end

    # ADR-57 slice 3 — a destructured slot that flow typed as optional (`X | nil`) is softened to its non-nil
    # constituent, because the nil is almost always excluded by a correlated invariant the per-slot flow cannot see (the
    # canonical haml `parse_tag` case).
    it "softens an optional `X | nil` slot to its non-nil constituent" do
      node = parse_multi_write("a, b = pair")
      optional = Rigor::Type::Combinator.union(constant("x"), constant(nil))
      result = described_class.bind(node, tuple(constant(1), optional))
      expect(result[:b]).to eq(constant("x"))
    end

    it "leaves a bare `nil` slot as Constant[nil] (nothing to soften)" do
      node = parse_multi_write("a, b = pair")
      result = described_class.bind(node, tuple(constant(1), constant(nil)))
      expect(result[:b]).to eq(constant(nil))
    end

    it "falls back to Dynamic[Top] for every slot when the rhs may convert through to_ary" do
      node = parse_multi_write("a, b = foo")
      dyn = Rigor::Type::Combinator.untyped
      nominal = Rigor::Type::Combinator.nominal_of("Object")
      result = described_class.bind(node, nominal)
      expect(result).to eq(a: dyn, b: dyn)
    end

    it "skips non-local targets (instance variables, constants, ...)" do
      node = parse_multi_write("@x, b = [1, 2]")
      result = described_class.bind(node, tuple(constant(1), constant(2)))
      expect(result).to eq(b: constant(2))
    end
  end

  # Issue #1093. Every decline below is paired with a neighbour that still decomposes, so a construction
  # error that widens everything to `Dynamic[top]` cannot pass the declines on its own.
  describe ".bind_marked over an Array[T] right-hand side" do
    let(:integer) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:string) { Rigor::Type::Combinator.nominal_of("String") }
    let(:dyn) { Rigor::Type::Combinator.untyped }

    def array_of(element)
      Rigor::Type::Combinator.nominal_of("Array", type_args: [element])
    end

    it "binds each fixed slot to T and a named rest to Array[T], marking only the fixed slots" do
      result = described_class.bind_marked(parse_multi_write("x, *y, z = ints"), array_of(integer))
      expect(result.types).to eq(x: integer, y: array_of(integer), z: integer)
      expect(result.optimistic).to contain_exactly(:x, :z)
    end

    it "binds the rest-free and leading-rest forms consistently" do
      pair = described_class.bind_marked(parse_multi_write("a, b = ints"), array_of(integer))
      expect(pair.types).to eq(a: integer, b: integer)
      expect(pair.optimistic).to contain_exactly(:a, :b)

      leading = described_class.bind_marked(parse_multi_write("*a, b = ints"), array_of(integer))
      expect(leading.types).to eq(a: array_of(integer), b: integer)
      expect(leading.optimistic).to contain_exactly(:b)
    end

    it "decomposes through a Difference base (non-empty-array[T] after an empty? guard)" do
      non_empty = Rigor::Type::Combinator.non_empty_array(integer)
      expect(non_empty).to be_a(Rigor::Type::Difference)
      result = described_class.bind_marked(parse_multi_write("first, *rest = ints"), non_empty)
      expect(result.types).to eq(first: integer, rest: array_of(integer))
    end

    it "recurses into nested targets with T as the new right-hand side, inheriting the mark" do
      element = tuple(integer, string)
      result = described_class.bind_marked(parse_multi_write("(p, q), r = pairs"), array_of(element))
      expect(result.types).to eq(p: integer, q: string, r: element)
      expect(result.optimistic).to contain_exactly(:p, :q, :r)
    end

    it "widens a nested Tuple rest under an inherited mark to an arity-free Array" do
      element = tuple(integer, string)
      result = described_class.bind_marked(parse_multi_write("(p, *q), r = pairs"), array_of(element))
      expect(result.types).to eq(p: integer, q: array_of(string), r: element)
      expect(result.optimistic).to contain_exactly(:p, :r)
    end

    it "keeps a nested Tuple rest precise when nothing above it is optimistic" do
      node = parse_multi_write("(p, *q), r = pair")
      result = described_class.bind_marked(node, tuple(tuple(integer, string), integer))
      expect(result.types).to eq(p: integer, q: tuple(string), r: integer)
      expect(result.optimistic).to be_empty
    end

    it "marks the names under an optimistic parent slot even when the slot itself is a Tuple" do
      node = Prism.parse("foo { |(g, h)| g }").value.statements.body.first.block.parameters.parameters.requireds.first
      result = described_class.bind_marked(node, tuple(integer, string), optimistic: true)
      expect(result.types).to eq(g: integer, h: string)
      expect(result.optimistic).to contain_exactly(:g, :h)
    end

    it "keeps Dynamic[top] per slot for raw Array, Array[untyped] and Dynamic[Array[T]]" do
      node = parse_multi_write("a, *r = xs")
      [
        Rigor::Type::Combinator.nominal_of("Array"),
        array_of(dyn),
        Rigor::Type::Combinator.dynamic(array_of(integer))
      ].each do |carrier|
        result = described_class.bind_marked(node, carrier)
        expect(result.types).to eq(a: dyn, r: dyn), "for #{carrier.describe}"
        expect(result.optimistic).to be_empty
      end
    end

    it "leaves Tuple decomposition unmarked" do
      result = described_class.bind_marked(parse_multi_write("a, b = [1, 2]"), tuple(constant(1), constant(2)))
      expect(result.types).to eq(a: constant(1), b: constant(2))
      expect(result.optimistic).to be_empty
    end

    it "records the mark on the scope through Result#apply_to" do
      result = described_class.bind_marked(parse_multi_write("a, *r = ints"), array_of(integer))
      scope = result.apply_to(Rigor::Scope.empty)
      expect(scope.local(:a)).to eq(integer)
      expect(scope.optimistic_local(:a)).to eq(Rigor::Inference::OptimisticOrigin::IMPLICITLY_RETURNS_NIL)
      expect(scope.optimistic_local(:r)).to be_nil
    end
  end

  # Issue #1094. As above, each decline is paired with a neighbour that still decomposes.
  describe ".bind_marked over a value Ruby wraps as [rhs]" do
    let(:integer) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:dyn) { Rigor::Type::Combinator.untyped }
    let(:scope) { Rigor::Scope.empty }

    it "binds the value to the first slot, nil to the other fixed slots, and [] to the rest, unmarked" do
      result = described_class.bind_marked(parse_multi_write("a, *r, b = 1"), constant(1))
      expect(result.types).to eq(a: constant(1), r: tuple, b: constant(nil))
      expect(result.optimistic).to be_empty
    end

    it "wraps a Hash, a HashShape, nil and a Refined String without an environment" do
      shape = Rigor::Type::Combinator.hash_shape_of(k: constant(1))
      [
        Rigor::Type::Combinator.nominal_of("Hash", type_args: [integer, integer]),
        shape,
        constant(nil),
        Rigor::Type::Combinator.non_empty_string
      ].each do |value|
        result = described_class.bind(parse_multi_write("c, d = v"), value)
        expect(result).to eq({ c: value, d: constant(nil) }), "for #{value.describe}"
      end
    end

    it "wraps an RBS-known class whose ancestry has no to_ary and no method_missing override" do
      time = Rigor::Type::Combinator.nominal_of("Time")
      expect(described_class.bind(parse_multi_write("a, b = t"), time, scope: scope))
        .to eq(a: time, b: constant(nil))
      expect(described_class.bind(parse_multi_write("a, b = t"), time)).to eq(a: dyn, b: dyn)
    end

    it "keeps Dynamic[top] for a Delegator, a module, Object, an unknown class and Dynamic" do
      [
        Rigor::Type::Combinator.nominal_of("SimpleDelegator"),
        Rigor::Type::Combinator.nominal_of("Delegator"),
        Rigor::Type::Combinator.nominal_of("Comparable"),
        Rigor::Type::Combinator.nominal_of("Object"),
        Rigor::Type::Combinator.nominal_of("NoSuchClassAnywhere"),
        Rigor::Type::Combinator.dynamic(integer),
        dyn
      ].each do |value|
        result = described_class.bind_marked(parse_multi_write("a, b = v"), value, scope: scope)
        expect(result.types).to eq({ a: dyn, b: dyn }), "for #{value.describe}"
      end
    end

    # `rbs core` declares `method_missing` / `respond_to_missing?` on `Delegator`, and CRuby's conversion asks
    # them, so `a, b = SimpleDelegator.new([1, 2])` binds `1, 2` at runtime. `Time`, loaded beside it, is the
    # neighbour that proves the environment answers at all.
    it "keeps Dynamic[top] for a class whose RBS ancestry overrides method_missing (SimpleDelegator)" do
      environment = Rigor::Environment.for_project(libraries: ["delegate"], signature_paths: [])
      delegate_scope = Rigor::Scope.empty(environment: environment)
      expect(environment.class_known?("SimpleDelegator")).to be(true)
      delegator = Rigor::Type::Combinator.nominal_of("SimpleDelegator")
      expect(described_class.bind(parse_multi_write("a, b = d"), delegator, scope: delegate_scope))
        .to eq(a: dyn, b: dyn)
      time = Rigor::Type::Combinator.nominal_of("Time")
      expect(described_class.bind(parse_multi_write("a, b = t"), time, scope: delegate_scope))
        .to eq(a: time, b: constant(nil))
    end

    # ADR-17 — a `pre_eval:` file's `def` reaches every analysed file through
    # `Environment#project_patched_methods`, so a hook it adds to the class, an RBS ancestor of it
    # (`Time` includes `Comparable`) or a default owner declines the wrap, core list included.
    it "keeps Dynamic[top] when a pre_eval: file adds a conversion hook the RBS does not declare" do
      entry = lambda do |class_name, method_name|
        Rigor::Inference::ProjectPatchedMethods::Entry.new(
          class_name: class_name, method_name: method_name, kind: :instance,
          source_path: "lib/ext.rb", source_line: 1
        )
      end
      patched_scope = lambda do |*entries|
        registry = Rigor::Inference::ProjectPatchedMethods.new(entries: entries)
        environment = Rigor::Environment.new(rbs_loader: Rigor::Environment::RbsLoader.default,
                                             project_patched_methods: registry)
        Rigor::Scope.empty(environment: environment)
      end
      time = Rigor::Type::Combinator.nominal_of("Time")
      node = parse_multi_write("a, b = t")

      [
        [time, entry.call("Time", :to_ary)],
        [time, entry.call("Comparable", :method_missing)],
        [constant(1), entry.call("Kernel", :respond_to_missing?)]
      ].each do |value, patch|
        expect(described_class.bind(node, value, scope: patched_scope.call(patch)))
          .to eq({ a: dyn, b: dyn }), "for #{patch.class_name}##{patch.method_name}"
      end

      unrelated = patched_scope.call(entry.call("String", :to_url))
      expect(described_class.bind(node, time, scope: unrelated)).to eq(a: time, b: constant(nil))
    end

    it "wraps a nested slot whose value has no to_ary" do
      result = described_class.bind(parse_multi_write("(a, b), c = pair"), tuple(constant(1), constant("s")))
      expect(result).to eq(a: constant(1), b: constant(nil), c: constant("s"))
    end
  end

  describe ".bind_marked over a union right-hand side" do
    let(:integer) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:string) { Rigor::Type::Combinator.nominal_of("String") }
    let(:dyn) { Rigor::Type::Combinator.untyped }

    def union(*members)
      Rigor::Type::Combinator.union(*members)
    end

    def array_of(element)
      Rigor::Type::Combinator.nominal_of("Array", type_args: [element])
    end

    it "distributes over Tuple members, joining each name" do
      rhs = union(tuple(constant(1), constant("s"), constant(:t)), tuple(constant(1.0)))
      result = described_class.bind_marked(parse_multi_write("e, *f = un"), rhs)
      expect(result.types).to eq(
        e: union(constant(1), constant(1.0)),
        f: union(tuple(constant("s"), constant(:t)), tuple)
      )
      expect(result.optimistic).to be_empty
    end

    it "uses the Array[T] rule for an Array member and marks what that member marked" do
      rhs = union(tuple(constant(1), constant("s")), array_of(integer))
      result = described_class.bind_marked(parse_multi_write("a, b, *r = mixed"), rhs)
      expect(result.types).to eq(
        a: union(constant(1), integer),
        b: union(constant("s"), integer),
        r: union(tuple, array_of(integer))
      )
      expect(result.optimistic).to contain_exactly(:a, :b)
    end

    it "binds T per slot for Array[T] | nil (`ints[1..]`), the wrapped nil member softened into the mark" do
      rhs = union(array_of(integer), constant(nil))
      result = described_class.bind_marked(parse_multi_write("a, b = slice"), rhs)
      expect(result.types).to eq(a: integer, b: integer)
      expect(result.optimistic).to contain_exactly(:a, :b)
    end

    # `k, v = hash.find { ... }; v.x if k` — which member arrived is correlated across the slots, so a
    # per-slot `V | nil` would fire on the guarded read. The softened names carry the mark instead.
    it "softens a member's bare nil out of a name another member binds, and marks the name" do
      rhs = union(tuple(integer, string), constant(nil))
      result = described_class.bind_marked(parse_multi_write("k, v = found"), rhs)
      expect(result.types).to eq(k: integer, v: string)
      expect(result.optimistic).to contain_exactly(:k, :v)

      short = union(tuple(constant(:ok), string), tuple(constant(:err)))
      status = described_class.bind_marked(parse_multi_write("s, v = result"), short)
      expect(status.types).to eq(s: union(constant(:ok), constant(:err)), v: string)
      expect(status.optimistic).to contain_exactly(:v)
    end

    it "keeps nil where every member binds nil, and keeps a member's own nil-bearing element" do
      rhs = union(tuple(constant(1), constant(nil)), tuple(constant(2)))
      result = described_class.bind_marked(parse_multi_write("a, b = x"), rhs)
      expect(result.types).to eq(a: union(constant(1), constant(2)), b: constant(nil))
      expect(result.optimistic).to be_empty

      nilable = union(integer, constant(nil))
      arrays = union(array_of(nilable), tuple(string, string))
      kept = described_class.bind_marked(parse_multi_write("a, b = x"), arrays)
      expect(kept.types).to eq(a: union(nilable, string), b: union(nilable, string))
    end

    it "keeps Dynamic[top] for every name when a member cannot be decomposed" do
      rhs = union(tuple(constant(1), constant(2)), Rigor::Type::Combinator.nominal_of("Object"))
      result = described_class.bind_marked(parse_multi_write("a, b = x"), rhs)
      expect(result.types).to eq(a: dyn, b: dyn)
    end

    it "keeps Dynamic[top] only for the nested names a member cannot decompose" do
      object = Rigor::Type::Combinator.nominal_of("Object")
      rhs = union(tuple(tuple(constant(1), constant(2)), constant(3)), tuple(object, constant(4)))
      result = described_class.bind(parse_multi_write("(p, q), r = x"), rhs)
      expect(result).to eq(p: dyn, q: dyn, r: union(constant(3), constant(4)))
    end
  end
end
