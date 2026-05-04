# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Reflection do
  describe ".class_known?" do
    it "returns true for a registry-known class" do
      expect(described_class.class_known?("Integer")).to be(true)
    end

    it "returns true for a class discovered in source" do
      scope = Rigor::Scope.empty.with_discovered_classes("MyClass" => :class)
      expect(described_class.class_known?("MyClass", scope: scope)).to be(true)
    end

    it "returns false for an unknown name" do
      # Use a class registry without the RBS loader to avoid the
      # stdlib RBS picking up well-known names that the test
      # author did not intend.
      env = Rigor::Environment.new
      scope = Rigor::Scope.empty(environment: env)
      expect(described_class.class_known?("Frobinator", scope: scope)).to be(false)
    end
  end

  describe ".nominal_for_name" do
    it "returns a Nominal carrier for a registered class" do
      type = described_class.nominal_for_name("Integer")
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end
  end

  describe ".singleton_for_name" do
    it "returns a Singleton carrier for a registered class" do
      type = described_class.singleton_for_name("String")
      expect(type).to be_a(Rigor::Type::Singleton)
      expect(type.class_name).to eq("String")
    end
  end

  describe ".class_ordering" do
    it "delegates to Environment#class_ordering and returns the trinary ordering" do
      # `Integer < Numeric` in Ruby's class hierarchy, so the
      # ordering is :subclass. Asserting the concrete value
      # rather than the membership keeps the rubocop
      # `RSpec/ExpectActual` cop satisfied.
      result = described_class.class_ordering("Integer", "Numeric")
      expect(result).to eq(:subclass)
    end
  end

  describe ".constant_type_for" do
    it "prefers in-source constants over RBS constants" do
      override = Rigor::Type::Combinator.constant_of(42)
      scope = Rigor::Scope.empty.with_in_source_constants("Foo" => override)
      expect(described_class.constant_type_for("Foo", scope: scope)).to eq(override)
    end

    it "falls back to the Environment's RBS-side constant" do
      # Pick a constant that ships with the bundled RBS so the
      # default Environment can resolve it.
      type = described_class.constant_type_for("ARGV")
      expect(type).not_to be_nil
    end

    it "returns nil for an unknown constant" do
      env = Rigor::Environment.new
      scope = Rigor::Scope.empty(environment: env)
      expect(described_class.constant_type_for("FROBINATOR", scope: scope)).to be_nil
    end
  end

  describe ".instance_method_definition" do
    it "resolves an RBS-declared instance method to a Definition::Method" do
      result = described_class.instance_method_definition("Integer", :+)
      expect(result).to be_a(RBS::Definition::Method)
    end

    it "returns nil for an unknown method" do
      result = described_class.instance_method_definition("Integer", :frobinator)
      expect(result).to be_nil
    end

    it "returns nil when the environment has no RBS loader" do
      env = Rigor::Environment.new
      scope = Rigor::Scope.empty(environment: env)
      expect(described_class.instance_method_definition("Integer", :+, scope: scope)).to be_nil
    end
  end

  describe ".singleton_method_definition" do
    it "resolves an RBS-declared singleton method to a Definition::Method" do
      result = described_class.singleton_method_definition("Hash", :new)
      expect(result).to be_a(RBS::Definition::Method)
    end
  end

  describe ".discovered_class? / .discovered_method?" do
    let(:scope) do
      Rigor::Scope.empty.with_discovered_classes("MyClass" => :class).with_discovered_methods(
        "MyClass" => { do_thing: :instance }
      )
    end

    it "reports discovered class presence" do
      expect(described_class.discovered_class?("MyClass", scope: scope)).to be(true)
      expect(described_class.discovered_class?("Other", scope: scope)).to be(false)
    end

    it "reports discovered method presence by kind" do
      expect(described_class.discovered_method?("MyClass", :do_thing, scope: scope)).to be(true)
      expect(described_class.discovered_method?("MyClass", :unknown_method, scope: scope)).to be(false)
    end
  end
end
