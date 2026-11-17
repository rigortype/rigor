# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — the receiver predicates several rules share. Plain data: types built with
# `Type::Combinator`, an empty scope over the bundled RBS, no runner.
RSpec.describe Rigor::Analysis::CheckRules::ReceiverPredicates do
  let(:combinator) { Rigor::Type::Combinator }
  let(:scope) { Rigor::Scope.empty }

  describe ".concrete_class_name" do
    it "names the class a nominal, a singleton and a literal dispatch on" do
      expect(described_class.concrete_class_name(combinator.nominal_of("Foo"))).to eq("Foo")
      expect(described_class.concrete_class_name(combinator.constant_of(1))).to eq("Integer")
      expect(described_class.concrete_class_name(combinator.constant_of("a"))).to eq("String")
    end

    it "resolves the shape carriers to their runtime class" do
      expect(described_class.concrete_class_name(combinator.tuple_of(combinator.constant_of(1)))).to eq("Array")
    end

    it "returns nil for a union, which names no single class" do
      union = combinator.union(combinator.constant_of(1), combinator.constant_of("a"))

      expect(described_class.concrete_class_name(union)).to be_nil
    end
  end

  describe ".strip_root" do
    it "drops a leading `::` and nothing else" do
      expect(described_class.strip_root("::Foo::Bar")).to eq("Foo::Bar")
      expect(described_class.strip_root("Foo::Bar")).to eq("Foo::Bar")
    end
  end

  describe ".nil_member?" do
    it "is true for the nil literal and the NilClass nominal only" do
      expect(described_class.nil_member?(combinator.constant_of(nil))).to be(true)
      expect(described_class.nil_member?(combinator.nominal_of("NilClass"))).to be(true)
      expect(described_class.nil_member?(combinator.nominal_of("String"))).to be(false)
    end
  end

  describe ".unbounded_receiver_surface?" do
    it "is false for a closed core class and true for a core-overlay open receiver" do
      expect(described_class.unbounded_receiver_surface?("String", scope)).to be(false)
      expect(described_class.unbounded_receiver_surface?("OpenStruct", scope)).to be(true)
    end
  end

  describe ".lookup_method" do
    let(:string) { combinator.nominal_of("String") }

    it "finds a method the receiver's class declares" do
      expect(described_class.lookup_method(string, "String", :upcase, scope)).to be_a(RBS::Definition::Method)
    end

    it "returns nil for a name the class does not declare" do
      expect(described_class.lookup_method(string, "String", :no_such_method, scope)).to be_nil
    end
  end

  describe ".method_present_anywhere?" do
    it "answers whether the member's class declares the method" do
      string = combinator.nominal_of("String")

      expect(described_class.method_present_anywhere?(string, :upcase, scope)).to be(true)
      expect(described_class.method_present_anywhere?(string, :no_such_method, scope)).to be(false)
    end
  end
end
