# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Environment::RbsLoader do
  let(:loader) { described_class.default }

  describe ".default" do
    it "memoizes a single shared instance" do
      expect(described_class.default).to equal(described_class.default)
    end

    it "returns a frozen loader" do
      expect(described_class.default).to be_frozen
    end

    it "loads core only (no opt-in libraries or signature paths)" do
      expect(described_class.default.libraries).to be_empty
      expect(described_class.default.signature_paths).to be_empty
    end
  end

  describe "with stdlib library opt-in" do
    let(:custom_loader) { described_class.new(libraries: ["pathname"]) }

    it "loads the requested stdlib classes" do
      expect(custom_loader.class_known?("Pathname")).to be(true)
    end

    it "tolerates unknown library names by failing soft" do
      bad_loader = described_class.new(libraries: ["this_library_does_not_exist_xyz"])
      expect(bad_loader.class_known?("Integer")).to be(true)
    end
  end

  describe "with project signature paths" do
    let(:project_loader) do
      described_class.new(
        signature_paths: [Pathname(__dir__).join("../../../sig").expand_path]
      )
    end

    it "loads classes declared in the project's sig/ tree" do
      expect(project_loader.class_known?("Rigor::Configuration")).to be(true)
      expect(project_loader.class_known?("Rigor::Analysis::Diagnostic")).to be(true)
    end

    it "silently ignores non-existent signature directories" do
      empty_loader = described_class.new(signature_paths: ["/path/that/definitely/does/not/exist"])
      expect(empty_loader.class_known?("Integer")).to be(true)
      expect(empty_loader.class_known?("Rigor::Configuration")).to be(false)
    end
  end

  describe "#class_known?" do
    it "is true for core classes (Integer, String, Array)" do
      expect(loader.class_known?("Integer")).to be(true)
      expect(loader.class_known?("String")).to be(true)
      expect(loader.class_known?("Array")).to be(true)
    end

    it "accepts both unprefixed and absolute names" do
      expect(loader.class_known?("Integer")).to be(true)
      expect(loader.class_known?("::Integer")).to be(true)
    end

    it "is true for nested core classes" do
      expect(loader.class_known?("Encoding::Converter")).to be(true)
    end

    it "is true for core modules (Comparable, Math)" do
      expect(loader.class_known?("Comparable")).to be(true)
      expect(loader.class_known?("Math")).to be(true)
    end

    it "is false for unknown names" do
      expect(loader.class_known?("ThisClassDoesNotExist123")).to be(false)
    end

    it "tolerates malformed names without raising" do
      expect(loader.class_known?("not a name")).to be(false)
      expect(loader.class_known?("")).to be(false)
    end
  end

  describe "#instance_method" do
    it "returns the method definition for a known instance method" do
      method = loader.instance_method(class_name: "Integer", method_name: :succ)
      expect(method).to be_a(RBS::Definition::Method)
      expect(method.method_types).not_to be_empty
    end

    it "resolves inherited methods (Integer < Numeric < Comparable < Object)" do
      method = loader.instance_method(class_name: "Integer", method_name: :tap)
      expect(method).not_to be_nil
    end

    it "returns nil for unknown methods" do
      method = loader.instance_method(class_name: "Integer", method_name: :totally_does_not_exist)
      expect(method).to be_nil
    end

    it "returns nil for unknown classes" do
      method = loader.instance_method(class_name: "ThisClassDoesNotExist123", method_name: :succ)
      expect(method).to be_nil
    end
  end

  describe "#instance_definition" do
    it "memoizes per-class definitions" do
      first = loader.instance_definition("Integer")
      second = loader.instance_definition("Integer")
      expect(first).to equal(second)
    end

    it "returns nil for unknown classes" do
      expect(loader.instance_definition("ThisClassDoesNotExist123")).to be_nil
    end
  end

  describe "#singleton_method (Slice 4 phase 2b)" do
    it "returns class methods declared on the class itself (Integer.sqrt)" do
      method = loader.singleton_method(class_name: "Integer", method_name: :sqrt)
      expect(method).to be_a(RBS::Definition::Method)
      expect(method.method_types).not_to be_empty
    end

    it "returns inherited class methods (Foo.new from Class#new)" do
      method = loader.singleton_method(class_name: "Integer", method_name: :new)
      expect(method).not_to be_nil
    end

    it "returns inherited class methods from Module (Foo.name)" do
      method = loader.singleton_method(class_name: "Integer", method_name: :name)
      expect(method).not_to be_nil
    end

    it "is namespace-disjoint from #instance_method" do
      # Module#instance_methods is a singleton-side method on every
      # class type; it MUST NOT be exposed on the instance side.
      expect(loader.instance_method(class_name: "Integer", method_name: :instance_methods)).to be_nil
      expect(loader.singleton_method(class_name: "Integer", method_name: :instance_methods)).not_to be_nil
    end

    it "returns nil for unknown methods" do
      expect(loader.singleton_method(class_name: "Integer", method_name: :totally_does_not_exist)).to be_nil
    end

    it "returns nil for unknown classes" do
      expect(loader.singleton_method(class_name: "ThisClassDoesNotExist123", method_name: :new)).to be_nil
    end
  end

  describe "#singleton_definition (Slice 4 phase 2b)" do
    it "memoizes per-class definitions" do
      first = loader.singleton_definition("Integer")
      second = loader.singleton_definition("Integer")
      expect(first).to equal(second)
    end

    it "is distinct from instance_definition for the same class" do
      inst = loader.instance_definition("Integer")
      sing = loader.singleton_definition("Integer")
      expect(inst).not_to equal(sing)
    end

    it "returns nil for unknown classes" do
      expect(loader.singleton_definition("ThisClassDoesNotExist123")).to be_nil
    end
  end

  describe "#class_type_param_names (Slice 4 phase 2d)" do
    it "returns Array's [:Elem]" do
      expect(loader.class_type_param_names("Array")).to eq([:Elem])
    end

    it "returns Hash's [:K, :V]" do
      expect(loader.class_type_param_names("Hash")).to eq(%i[K V])
    end

    it "returns an empty array for non-generic classes" do
      expect(loader.class_type_param_names("Integer")).to eq([])
      expect(loader.class_type_param_names("String")).to eq([])
    end

    it "returns an empty array for unknown classes (fail-soft)" do
      expect(loader.class_type_param_names("ThisClassDoesNotExist123")).to eq([])
    end
  end

  describe "#class_ordering" do
    it "compares core inheritance through RBS ancestors" do
      expect(loader.class_ordering("Integer", "Numeric")).to eq(:subclass)
      expect(loader.class_ordering("Numeric", "Integer")).to eq(:superclass)
      expect(loader.class_ordering("Integer", "String")).to eq(:disjoint)
    end

    it "returns unknown when either class is absent" do
      expect(loader.class_ordering("Integer", "ThisClassDoesNotExist123")).to eq(:unknown)
    end
  end
end
