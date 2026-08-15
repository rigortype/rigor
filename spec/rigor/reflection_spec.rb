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

    # #354 — Ruby's constant lookup is `Module.nesting`, THEN the ancestors of the innermost
    # cresting scope, THEN the top level. The ancestor step was missing, which lost the resolution
    # outright and — worse — handed a shadowed lookup to the top-level fallback.
    describe "ancestor step (#354)" do
      # `class Sub < Base`, with `Base` including `Mixin`. `Base` and `Mixin` are registered as
      # discovered classes because that is what a real run produces — an as-written ancestor name
      # that names no discovered project namespace is dropped by design, so omitting them here
      # would test the drop path instead of the walk.
      def sub_scope(in_source: {})
        discovered = {
          "Sub" => Rigor::Type::Combinator.singleton_of("Sub"),
          "Base" => Rigor::Type::Combinator.singleton_of("Base"),
          "Mixin" => Rigor::Type::Combinator.singleton_of("Mixin")
        }
        index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
          in_source_constants: in_source,
          discovered_classes: discovered,
          discovered_superclasses: { "Sub" => "Base" },
          discovered_includes: { "Base" => ["Mixin"] }
        )
        Rigor::Scope.empty
                    .with_self_type(Rigor::Type::Combinator.nominal_of("Sub"))
                    .with_discovery(index)
      end

      it "resolves a constant owned by the superclass" do
        pinned = Rigor::Type::Combinator.constant_of(42)
        scope = sub_scope(in_source: { "Base::INHERITED" => pinned })
        expect(described_class.resolve_constant_type("INHERITED", scope: scope)).to eq(pinned)
      end

      it "resolves a constant owned by a module the superclass includes" do
        pinned = Rigor::Type::Combinator.constant_of(7)
        scope = sub_scope(in_source: { "Mixin::FROM_MIXIN" => pinned })
        expect(described_class.resolve_constant_type("FROM_MIXIN", scope: scope)).to eq(pinned)
      end

      # The regression this issue is really about: both names exist, and Ruby gives the lookup to
      # the ancestor. Before the fix the bare-name fallback won and the reference typed as the
      # top-level constant — a wrong type on correct code, not merely a missing one.
      it "prefers the ancestor's constant over a shadowing top-level constant" do
        from_ancestor = Rigor::Type::Combinator.constant_of(42)
        from_toplevel = Rigor::Type::Combinator.constant_of("top-level")
        scope = sub_scope(in_source: { "Base::KEY" => from_ancestor, "KEY" => from_toplevel })
        expect(described_class.resolve_constant_type("KEY", scope: scope)).to eq(from_ancestor)
      end

      # The control that keeps the two preceding examples honest: with no ancestor owning the name,
      # the top-level fallback must still answer exactly as it did before.
      it "still falls back to the top level when no ancestor owns the name" do
        pinned = Rigor::Type::Combinator.constant_of("top-level")
        scope = sub_scope(in_source: { "ONLY_TOPLEVEL" => pinned })
        expect(described_class.resolve_constant_type("ONLY_TOPLEVEL", scope: scope)).to eq(pinned)
      end

      it "terminates on a superclass cycle" do
        index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
          in_source_constants: {},
          discovered_superclasses: { "A" => "B", "B" => "A" },
          discovered_classes: { "A" => Rigor::Type::Combinator.singleton_of("A"),
                                "B" => Rigor::Type::Combinator.singleton_of("B") }
        )
        scope = Rigor::Scope.empty
                            .with_self_type(Rigor::Type::Combinator.nominal_of("A"))
                            .with_discovery(index)
        expect(described_class.resolve_constant_type("NOPE", scope: scope)).to be_nil
      end

      # An RBS-known ancestor contributes no name to the walk: `superclass_of` carries the
      # as-written name and it resolves to no discovered project class, so it is dropped. Recorded
      # so the boundary is deliberate rather than accidental.
      it "drops an ancestor that names no discovered project class" do
        pinned = Rigor::Type::Combinator.constant_of(1)
        index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
          in_source_constants: { "ActiveRecord::Base::TABLE" => pinned },
          discovered_superclasses: { "Model" => "ActiveRecord::Base" }
        )
        scope = Rigor::Scope.empty
                            .with_self_type(Rigor::Type::Combinator.nominal_of("Model"))
                            .with_discovery(index)
        expect(described_class.resolve_constant_type("TABLE", scope: scope)).to be_nil
      end
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
      expect(result).to eq([RbsCoreTypeParams.array_element])
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

    it "reports a both-sides method under either kind (#239)" do
      # One name may be defined on both sides of a class, and the table holds one value per name — so the writers
      # record METHOD_KIND_BOTH instead of letting the second definition erase the first's kind.
      index = Rigor::Scope::DiscoveryIndex::EMPTY.with(
        discovered_methods: { "MyClass" => { helper: Rigor::Scope::DiscoveryIndex::METHOD_KIND_BOTH } }
      )
      both = Rigor::Scope.empty.with_discovery(index)

      expect(described_class.discovered_method?("MyClass", :helper, kind: :instance, scope: both)).to be(true)
      expect(described_class.discovered_method?("MyClass", :helper, kind: :singleton, scope: both)).to be(true)
      expect(described_class.discovered_method?("MyClass", :other, kind: :singleton, scope: both)).to be(false)
    end
  end
end
