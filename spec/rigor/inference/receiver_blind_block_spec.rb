# frozen_string_literal: true

require "spec_helper"
require "prism"

# The gate for the in-place forms of the HashShape per-pair fold. The end-to-end repros live beside the fold's
# own examples in `expression_typer_spec.rb` ("HashShape per-pair fold declines"); this file pins each carrier
# arm and each node kind the walk admits or refuses, so deleting one arm fails here.
RSpec.describe Rigor::Inference::ReceiverBlindBlock do
  let(:combinator) { Rigor::Type::Combinator }
  let(:shape) { combinator.hash_shape_of({ x: combinator.constant_of(1) }) }

  describe ".carries_hash_contents?" do
    def carries?(type) = described_class.carries_hash_contents?(type)

    it "answers yes for a HashShape and for a Hash nominal with a typed parameter" do
      expect(carries?(shape)).to be(true)
      symbol_to_integer = [combinator.nominal_of("Symbol"), combinator.nominal_of("Integer")]
      expect(carries?(combinator.nominal_of("Hash", type_args: symbol_to_integer))).to be(true)
      expect(carries?(combinator.nominal_of("Hash", type_args: [combinator.constant_of(:x), combinator.untyped])))
        .to be(true)
    end

    it "answers yes for a shape inside every carrier that holds other types" do
      holders = {
        union: combinator.union(combinator.constant_of(1), shape),
        intersection: Rigor::Type::Intersection.new([combinator.nominal_of("Object"), shape]),
        tuple: combinator.tuple_of(combinator.constant_of(1), shape),
        nominal_argument: combinator.nominal_of("Array", type_args: [shape]),
        refined: Rigor::Type::Refined.new(shape, :non_empty),
        difference: Rigor::Type::Difference.new(shape, combinator.hash_shape_of({})),
        struct_member: Rigor::Type::StructInstance.new({ table: shape }, "S"),
        data_member: Rigor::Type::DataInstance.new({ table: shape }, "D"),
        dynamic_facet: combinator.dynamic(shape),
        bound_method: combinator.bound_method_of(shape, :[]),
        maybe: combinator.maybe_of(shape),
        result: combinator.result_of(combinator.constant_of(1), shape),
        app_argument: Rigor::Type::App.new(:"spec::box", [shape], bound: combinator.untyped),
        app_bound: Rigor::Type::App.new(:"spec::box", [combinator.constant_of(1)], bound: shape)
      }

      expect(holders.reject { |_arm, type| carries?(type) }.keys).to be_empty
    end

    it "answers no for a type that cannot describe a hash's contents" do
      untyped_hash = combinator.nominal_of("Hash", type_args: [combinator.untyped, combinator.untyped])
      types = [
        nil, combinator.constant_of(3), combinator.nominal_of("Integer"), combinator.nominal_of("Hash"),
        untyped_hash, combinator.untyped, combinator.top,
        combinator.tuple_of(combinator.constant_of(1), combinator.constant_of(2)),
        combinator.nominal_of("Array", type_args: [combinator.nominal_of("String")])
      ]

      expect(types.select { |type| carries?(type) }).to be_empty
    end
  end

  describe ".blind?" do
    let(:base_scope) do
      bindings = {
        h: shape, factor: combinator.constant_of(3), reg: combinator.nominal_of("Object"),
        list: combinator.tuple_of(shape)
      }
      scope = bindings.reduce(Rigor::Scope.empty) { |acc, (name, type)| acc.with_local(name, type) }
      scope.with_ivar(:@iv, shape).with_cvar(:@@cv, shape).with_global(:$gv, shape)
    end

    # The block of `h.transform_values! <block>`, parsed with the outer locals in scope so a read of one of
    # them is a captured `LocalVariableReadNode` rather than a method call.
    def block_of(block_source)
      source = "h.transform_values! #{block_source}"
      Prism.parse(source, scopes: [%i[h factor reg list]]).value.statements.body.first.block
    end

    # The same block inside a method body, where `yield` and `super` parse without error.
    def block_in_method(block_source)
      Prism.parse("def m\n  h.transform_values! #{block_source}\nend").value.statements.body.first
           .body.body.first.block
    end

    def blind?(block) = described_class.blind?(block, base_scope)

    it "admits parameters, block-locals, literals, and captured values that carry no hash contents" do
      sources = [
        "{ |e| e * factor }", "{ |h| h + 1 }", "{ it + 1 }", "{ _1 + 1 }", "{ |e| e.to_s.upcase }",
        "{ |e| [e].map { |h| h + 1 }.first }", "{ |e| %i[a b].include?(e) }", "{ |e| (e + factor).succ }",
        "{ |e| defined?(h) ? e : 0 }", "{ |e| factor += e }", "{ |e; t| t = e; t }", "{ |e| e.equal?(reg) ? 1 : e }",
        "{ |e| \"\#{e}\".size }", "{ |e| :\"\#{e}_x\".to_s }", "{ |e| e.is_a?(Foo::Bar) }"
      ]

      expect(sources.reject { |source| blind?(block_of(source)) }).to be_empty
    end

    it "refuses a captured read whose entry type carries hash contents, whatever the variable kind" do
      sources = [
        "{ |e| h[:x] + e }", "{ |e| e.equal?(h) }", "{ |e| e.then { h } }", "{ |e| e.equal?(list) }",
        "{ |e| e.equal?(@iv) }", "{ |e| e.equal?(@@cv) }", "{ |e| e.equal?($gv) }", "{ |e| (h ||= {}); e }",
        "{ |e| @iv ||= e }", "{ |e| @@cv ||= e }", "{ |e| $gv ||= e }", "{ |e, d = h| e }",
        "{ |e| e.then { |h| h } + h[:x] }"
      ]

      expect(sources.select { |source| blind?(block_of(source)) }).to be_empty
    end

    it "refuses a call whose receiver is not built from block parameters and literals" do
      sources = [
        "{ |e| foo(e) }", "{ |e| self.foo(e) }", "{ |e| Foo.bar(e) }", "{ |e| reg.x + e }",
        "{ |e; t| t = e; t.succ }", "{ |e| [factor].first.succ }", "{ |e| reg.x += e }", "{ |e| reg[:x] ||= e }"
      ]

      expect(sources.select { |source| blind?(block_of(source)) }).to be_empty
    end

    it "refuses super, yield, and a nested def" do
      expect(blind?(block_in_method("{ |e| yield e }"))).to be(false)
      expect(blind?(block_in_method("{ |e| super(e) }"))).to be(false)
      expect(blind?(block_of("{ |e| def x = 1; e }"))).to be(false)
    end

    it "refuses a constant it cannot type from the entry scope" do
      # A compound write names its constant with no read node, and `e::T` resolves against a block parameter.
      sources = ["{ |e| F ||= e }", "{ |e| F += e }", "{ |e| F &&= e }", "{ |e| e::T }"]

      expect(sources.select { |source| blind?(block_of(source)) }).to be_empty
    end
  end
end
