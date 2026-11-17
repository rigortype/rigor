# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `ExpressionTyper::Constants` types a constant read (`Foo`, `Foo::Bar`, `::Foo`): the type a guard
# narrowed the spelling to, else the lexical resolution through `Reflection`, else a fail-soft `Dynamic[top]` with the
# fallback recorded. The examples call the entries with a real typer whose tracer collects the fallback events, which
# are the module's three callbacks' visible effect (`fallback_for`, `record_fallback`, `dynamic_top`).
RSpec.describe Rigor::Inference::ExpressionTyper::Constants do
  let(:combinator) { Rigor::Type::Combinator }
  let(:scope) { Rigor::Scope.empty }
  let(:tracer) { Rigor::Inference::FallbackTracer.new }
  let(:typer) { Rigor::Inference::ExpressionTyper.new(scope: scope, tracer: tracer) }

  def node_of(source) = Prism.parse(source).value.statements.body.first

  def read(source, over = scope)
    node = node_of(source)
    entry = node.is_a?(Prism::ConstantReadNode) ? :type_of_constant_read : :type_of_constant_path
    described_class.public_send(entry, node, over, Rigor::Inference::ExpressionTyper.new(scope: over, tracer: tracer))
  end

  describe ".type_of_constant_read and .type_of_constant_path" do
    it "types a known constant as the Singleton of its class, plain, qualified and rooted" do
      expect(read("Integer").describe).to eq("singleton(Integer)")
      expect(read("::Integer").describe).to eq("singleton(Integer)")
      expect(read("Comparable").describe).to eq("singleton(Comparable)")
      expect(tracer.events).to be_empty
    end

    it "types an unknown constant as Dynamic[top] and records one prism fallback for it" do
      expect(read("NoSuchConstant")).to equal(combinator.untyped)
      expect(tracer.events.map { |e| [e.node_class, e.family] }).to eq([[Prism::ConstantReadNode, :prism]])
    end

    it "types an unknown qualified constant as Dynamic[top] and records the fallback on the path node" do
      expect(read("Integer::NoSuch")).to equal(combinator.untyped)
      expect(tracer.events.map { |e| [e.node_class, e.family] }).to eq([[Prism::ConstantPathNode, :prism]])
    end

    it "types a path whose base renders no static name as Dynamic[top] with a fallback" do
      node = Prism.parse("x::Y", scopes: [[:x]]).value.statements.body.first

      type = described_class.type_of_constant_path(node, scope, typer)

      expect(type).to equal(combinator.untyped)
      expect(tracer.events.map(&:node_class)).to eq([Prism::ConstantPathNode])
    end

    it "prefers the type a guard narrowed the spelling to" do
      narrowed = scope.with_constant_narrowing("Integer", combinator.nominal_of("String"), combinator.untyped)
      qualified = scope.with_constant_narrowing("::Comparable", combinator.nominal_of("String"), combinator.untyped)

      expect(read("Integer", narrowed).describe).to eq("String")
      expect(read("::Comparable", qualified).describe).to eq("String")
      expect(read("Float", narrowed).describe).to eq("singleton(Float)")
    end

    it "records no fallback for a narrowed constant that would not resolve" do
      narrowed = scope.with_constant_narrowing("NoSuch", combinator.nominal_of("String"), combinator.untyped)

      expect(read("NoSuch", narrowed).describe).to eq("String")
      expect(tracer.events).to be_empty
    end
  end

  describe ".resolve_constant_name" do
    it "resolves a name to its type, honouring `rooted`, and answers nil for an unknown one" do
      expect(described_class.resolve_constant_name("Integer", scope).describe).to eq("singleton(Integer)")
      expect(described_class.resolve_constant_name("Integer", scope, rooted: true).describe)
        .to eq("singleton(Integer)")
      expect(described_class.resolve_constant_name("NoSuch", scope)).to be_nil
    end
  end
end
