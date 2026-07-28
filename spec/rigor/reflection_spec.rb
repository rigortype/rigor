# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Rigor::Reflection do
  describe ".class_known?" do
    it "returns true for a registry-known class" do
      expect(described_class.class_known?("Integer")).to be(true)
    end

    it "returns true for a class discovered in source" do
      index = Rigor::Scope::DiscoveryIndex::EMPTY.with(discovered_classes: { "MyClass" => :class })
      scope = Rigor::Scope.empty.with_discovery(index)
      expect(described_class.class_known?("MyClass", scope: scope)).to be(true)
    end

    it "returns false for an unknown name" do
      # Use a class registry without the RBS loader to avoid the stdlib RBS picking up well-known names that the test
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
      # `Integer < Numeric` in Ruby's class hierarchy, so the ordering is :subclass. Asserting the concrete value rather
      # than the membership keeps the rubocop `RSpec/ExpectActual` cop satisfied.
      result = described_class.class_ordering("Integer", "Numeric")
      expect(result).to eq(:subclass)
    end
  end

  describe ".constant_type_for" do
    it "prefers in-source constants over RBS constants" do
      override = Rigor::Type::Combinator.constant_of(42)
      index = Rigor::Scope::DiscoveryIndex::EMPTY.with(in_source_constants: { "Foo" => override })
      scope = Rigor::Scope.empty.with_discovery(index)
      expect(described_class.constant_type_for("Foo", scope: scope)).to eq(override)
    end

    it "falls back to the Environment's RBS-side constant" do
      # Pick a constant that ships with the bundled RBS so the default Environment can resolve it.
      type = described_class.constant_type_for("ARGV")
      expect(type).not_to be_nil
    end

    it "returns nil for an unknown constant" do
      env = Rigor::Environment.new
      scope = Rigor::Scope.empty(environment: env)
      expect(described_class.constant_type_for("FROBINATOR", scope: scope)).to be_nil
    end
  end

  describe ".resolve_constant_type" do
    it "resolves an in-source value constant to its pinned type" do
      pinned = Rigor::Type::Combinator.constant_of(/\n([ \t]+)\z/)
      index = Rigor::Scope::DiscoveryIndex::EMPTY.with(in_source_constants: { "RE" => pinned })
      scope = Rigor::Scope.empty.with_discovery(index)
      expect(described_class.resolve_constant_type("RE", scope: scope)).to eq(pinned)
    end

    it "resolves a registry class name to a Singleton carrier" do
      type = described_class.resolve_constant_type("String")
      expect(type).to be_a(Rigor::Type::Singleton)
      expect(type.class_name).to eq("String")
    end

    it "walks the enclosing class path (most-qualified candidate wins)" do
      pinned = Rigor::Type::Combinator.constant_of(42)
      index = Rigor::Scope::DiscoveryIndex::EMPTY.with(in_source_constants: { "Foo::RE" => pinned })
      scope = Rigor::Scope.empty
                          .with_self_type(Rigor::Type::Combinator.nominal_of("Foo"))
                          .with_discovery(index)
      expect(described_class.resolve_constant_type("RE", scope: scope)).to eq(pinned)
    end

    it "returns nil for a constant no source knows" do
      env = Rigor::Environment.new
      scope = Rigor::Scope.empty(environment: env)
      expect(described_class.resolve_constant_type("FROBINATOR", scope: scope)).to be_nil
    end

    describe "RBS-backed lookups under cache_store (v0.0.9 group A slice 4)" do
      let(:tmpdir) { Dir.mktmpdir("rigor-reflection-cache-spec-") }
      let(:store) { Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache")) }

      after { FileUtils.rm_rf(tmpdir) }

      it "matches the uncached RBS path through Environment.for_project(cache_store:)" do
        cached_env = Rigor::Environment.for_project(libraries: [], signature_paths: [], cache_store: store)
        cached_scope = Rigor::Scope.empty(environment: cached_env)
        cached = described_class.constant_type_for("ARGV", scope: cached_scope)
        uncached = described_class.constant_type_for("ARGV")
        expect(cached).to eq(uncached)
      end

      it "shares the cache so a second project Environment never rebuilds the constant table" do
        first_env = Rigor::Environment.for_project(libraries: [], signature_paths: [], cache_store: store)
        described_class.constant_type_for("ARGV", scope: Rigor::Scope.empty(environment: first_env))
        first_writes = store.stats.fetch(:writes)
        expect(first_writes).to be >= 1

        second_env = Rigor::Environment.for_project(libraries: [], signature_paths: [], cache_store: store)
        described_class.constant_type_for("ARGV", scope: Rigor::Scope.empty(environment: second_env))
        expect(store.stats.fetch(:writes)).to eq(first_writes)
        expect(store.stats.fetch(:hits)).to be >= 1
      end
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

  describe ".rbs_class_known?" do
    it "returns true for an RBS-known class with an explicit scope" do
      expect(described_class.rbs_class_known?("Integer")).to be(true)
    end

    it "returns false when the loader cannot resolve the name" do
      env = Rigor::Environment.new
      expect(described_class.rbs_class_known?("Frobinator", environment: env)).to be(false)
    end
  end

  describe ".instance_definition" do
    it "returns an RBS::Definition for a known class" do
      result = described_class.instance_definition("Integer")
      expect(result).to be_a(RBS::Definition)
    end

    it "returns nil for an unknown class" do
      env = Rigor::Environment.new
      scope = Rigor::Scope.empty(environment: env)
      expect(described_class.instance_definition("Frobinator", scope: scope)).to be_nil
    end
  end

  describe ".singleton_definition" do
    it "returns an RBS::Definition for a known class" do
      result = described_class.singleton_definition("String")
      expect(result).to be_a(RBS::Definition)
    end

    it "returns nil for an unknown class" do
      env = Rigor::Environment.new
      scope = Rigor::Scope.empty(environment: env)
      expect(described_class.singleton_definition("Frobinator", scope: scope)).to be_nil
    end
  end

  describe ".class_type_param_names" do
    it "returns the type parameter names for a generic class" do
      result = described_class.class_type_param_names("Array")
      expect(result).to eq([:E])
    end

    it "returns an empty array for a non-generic class" do
      result = described_class.class_type_param_names("String")
      expect(result).to eq([])
    end

    it "returns an empty array when the loader is unavailable" do
      env = Rigor::Environment.new
      scope = Rigor::Scope.empty(environment: env)
      expect(described_class.class_type_param_names("Frobinator", scope: scope)).to eq([])
    end
  end

  describe ".discovered_class? / .discovered_method?" do
    let(:scope) do
      index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
        discovered_classes: { "MyClass" => :class },
        discovered_methods: { "MyClass" => { do_thing: :instance } }
      )
      Rigor::Scope.empty.with_discovery(index)
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
