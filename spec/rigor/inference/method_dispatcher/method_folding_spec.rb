# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::MethodDispatcher::MethodFolding do
  let(:scope) { Rigor::Scope.empty(environment: Rigor::Environment.for_project) }

  def parse_expression(source)
    Prism.parse(source).value.statements.body.first
  end

  describe "forward fold — Object#method(:sym)" do
    it "lifts `<const>.method(:sym)` to a BoundMethod carrier" do
      type = scope.type_of(parse_expression('"1".method(:to_i)'))

      expect(type).to be_a(Rigor::Type::BoundMethod)
      expect(type.receiver_type).to eq(Rigor::Type::Combinator.constant_of("1"))
      expect(type.method_name).to eq(:to_i)
    end

    it "accepts a String argument by coercing it to a Symbol (Ruby's documented contract)" do
      type = scope.type_of(parse_expression('"1".method("to_i")'))

      expect(type).to be_a(Rigor::Type::BoundMethod)
      expect(type.method_name).to eq(:to_i)
    end

    it "declines on a non-literal symbol argument" do
      # The receiver `"1"` is precise, but the argument is an
      # unknown identifier the engine cannot fold to a
      # `Constant<Symbol>`; the forward fold declines and the
      # RBS tier answers `Nominal[Method]` instead.
      type = scope.type_of(parse_expression('"1".method(unknown_name)'))

      expect(type).not_to be_a(Rigor::Type::BoundMethod)
    end
  end

  describe "backward fold — Method#call / .() / #[]" do
    it "substitutes the bound dispatch when invoked via `.call`" do
      type = scope.type_of(parse_expression('"1".method(:to_i).call'))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "substitutes the bound dispatch when invoked via `.()` (sugar for `.call`)" do
      type = scope.type_of(parse_expression('"1".method(:to_i).()'))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "substitutes the bound dispatch when invoked via `#[]`" do
      type = scope.type_of(parse_expression('"1".method(:to_i)[]'))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "preserves Tuple per-element precision through map { |m| recv.method(m).call }" do
      type = scope.type_of(parse_expression(
                             '[:to_i, :to_f, :to_sym].map { |m| "1".method(m).call }'
                           ))

      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements).to eq([
                                    Rigor::Type::Combinator.constant_of(1),
                                    Rigor::Type::Combinator.constant_of(1.0),
                                    Rigor::Type::Combinator.constant_of(:"1")
                                  ])
    end
  end

  describe "Method#curry — identity on the carrier (Open Item #5 — Option A)" do
    it "keeps the BoundMethod carrier through `.curry` so a subsequent `.call` still folds" do
      type = scope.type_of(parse_expression('"1".method(:to_i).curry'))

      expect(type).to be_a(Rigor::Type::BoundMethod)
      expect(type.receiver_type).to eq(Rigor::Type::Combinator.constant_of("1"))
      expect(type.method_name).to eq(:to_i)
    end

    it "routes `.curry.call` through the bound dispatch (zero-arg form)" do
      type = scope.type_of(parse_expression('"1".method(:to_i).curry.call'))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(1))
    end

    it "preserves Tuple per-element precision through `.curry.call` over a Symbol Array" do
      # The pre-Option-A behaviour for this expression was
      # `Tuple[Dynamic[Top]×3]` because `Method#curry`
      # collapsed to `Nominal[Proc]` and `Proc#call` then
      # fell through to `Dynamic[Top]`. Option A keeps the
      # `BoundMethod` carrier through `.curry`, so the
      # backward fold's recursive dispatch on the bound
      # `(receiver_type, method_name)` pair runs as if the
      # `.curry` were never written.
      type = scope.type_of(parse_expression(
                             '[:to_i, :to_f, :to_sym].map { |m| "1".method(m).curry.call }'
                           ))

      expect(type).to be_a(Rigor::Type::Tuple)
      expect(type.elements).to eq([
                                    Rigor::Type::Combinator.constant_of(1),
                                    Rigor::Type::Combinator.constant_of(1.0),
                                    Rigor::Type::Combinator.constant_of(:"1")
                                  ])
    end
  end
end
