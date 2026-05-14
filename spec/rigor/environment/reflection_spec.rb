# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Environment::Reflection do
  let(:reflection) { Rigor::Environment.for_project.reflection }

  describe "construction" do
    it "is built lazily and memoised by the loader" do
      env = Rigor::Environment.for_project
      first = env.reflection
      second = env.reflection
      expect(first).to equal(second)
    end

    it "is frozen at construction" do
      expect(reflection).to be_frozen
      expect(reflection.known_class_names).to be_frozen
      expect(reflection.instance_definitions).to be_frozen
      expect(reflection.singleton_definitions).to be_frozen
      expect(reflection.type_param_names).to be_frozen
      expect(reflection.constant_types).to be_frozen
      expect(reflection.ancestor_names).to be_frozen
    end
  end

  describe "#class_known?" do
    it "answers core RBS classes" do
      expect(reflection.class_known?("Integer")).to be(true)
      expect(reflection.class_known?("String")).to be(true)
      expect(reflection.class_known?("Array")).to be(true)
    end

    it "tolerates rooted (`::`-prefixed) and unrooted forms" do
      expect(reflection.class_known?("Integer")).to be(true)
      expect(reflection.class_known?("::Integer")).to be(true)
    end

    it "returns false for unknown classes" do
      expect(reflection.class_known?("DefinitelyNotARealClass")).to be(false)
    end
  end

  describe "#instance_definition" do
    it "returns the RBS::Definition for a known class" do
      expect(reflection.instance_definition("Integer")).to be_a(RBS::Definition)
    end

    it "returns nil for unknown classes" do
      expect(reflection.instance_definition("Nope")).to be_nil
    end

    it "tolerates rooted and unrooted forms" do
      a = reflection.instance_definition("Integer")
      b = reflection.instance_definition("::Integer")
      expect(a).to equal(b)
    end
  end

  describe "#singleton_definition" do
    it "returns the singleton-side RBS::Definition" do
      expect(reflection.singleton_definition("Class")).to be_a(RBS::Definition)
    end
  end

  describe "#class_ordering" do
    it "returns :equal for the same class" do
      expect(reflection.class_ordering("Integer", "Integer")).to eq(:equal)
    end

    it "returns :subclass when lhs descends from rhs" do
      expect(reflection.class_ordering("Integer", "Numeric")).to eq(:subclass)
      expect(reflection.class_ordering("Integer", "Comparable")).to eq(:subclass)
    end

    it "returns :superclass when lhs is an ancestor of rhs" do
      expect(reflection.class_ordering("Numeric", "Integer")).to eq(:superclass)
    end

    it "returns :disjoint when neither subclasses the other" do
      expect(reflection.class_ordering("Integer", "String")).to eq(:disjoint)
    end

    it "returns :unknown for unknown classes" do
      expect(reflection.class_ordering("Nope", "Integer")).to eq(:unknown)
    end
  end

  describe "#class_type_param_names" do
    it "returns the declared type parameters of a generic class" do
      expect(reflection.class_type_param_names("Array")).to eq([:Elem])
      expect(reflection.class_type_param_names("Hash")).to eq(%i[K V])
    end

    it "returns [] for non-generic classes" do
      expect(reflection.class_type_param_names("Integer")).to eq([])
    end
  end

  describe "#constant_type" do
    it "returns the translated type for known constants" do
      pi = reflection.constant_type("Math::PI")
      expect(pi).not_to be_nil
    end

    it "returns nil for unknown constants" do
      expect(reflection.constant_type("Unknown::Constant")).to be_nil
    end
  end

  describe "#each_known_class_name" do
    it "yields every known class name" do
      names = []
      reflection.each_known_class_name { |n| names << n }
      expect(names).to include("::Integer", "::String", "::Array")
    end

    it "returns an Enumerator without a block" do
      expect(reflection.each_known_class_name).to be_an(Enumerator)
    end
  end
end
