# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

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

  describe "env build failure short-circuit (O7)" do
    # Open item O7 (real-world Rails survey, 2026-05-15):
    # when a `signature_paths:` entry redeclares a constant or
    # class already shipped by rigor's bundled RBS,
    # `RBS::Environment.from_loader(...).resolve_type_names`
    # raises `RBS::DuplicatedDeclarationError`. Pre-fix, the
    # `||=` memo in `#env` did not capture the failure, so
    # every subsequent `env` access (one per AST node touched
    # during analysis) re-parsed the whole sig set — a ~100x
    # per-file slowdown for projects that wire a conflicting
    # gem-shipped `sig/` into `signature_paths:` (the typical
    # case for prism, which ships its own RBS via the gem
    # AND via the bundled stdlib RBS in Ruby 4.0+).
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-conflict-spec-") }

    after { FileUtils.rm_rf(tmpdir) }

    it "memoises the failure so a duplicated decl rebuilds env only once" do
      File.write(
        File.join(tmpdir, "duplicate_prism_version.rbs"),
        "module Prism\n  VERSION: String\nend\n"
      )
      loader = described_class.new(libraries: ["prism"], signature_paths: [tmpdir])
      allow(described_class).to receive(:build_env_for).and_call_original
      # Touch env many times; the broken state should be memoised
      # so build_env_for runs at most once.
      10.times { loader.send(:env) }
      expect(described_class).to have_received(:build_env_for).at_most(:once)
      expect(loader.send(:env)).to be_nil
    end

    it "emits a single warning identifying the conflicting decl" do
      File.write(
        File.join(tmpdir, "duplicate_prism_version.rbs"),
        "module Prism\n  VERSION: String\nend\n"
      )
      loader = described_class.new(libraries: ["prism"], signature_paths: [tmpdir])
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }
      3.times { loader.send(:env) }
      expect(messages.size).to eq(1)
      expect(messages.first).to include("RBS environment build failed")
      expect(messages.first).to include("DuplicatedDeclarationError")
      expect(messages.first).to include("Prism::VERSION")
    end

    it "returns empty results from each_known_class_name / class_decl_paths when env is nil" do
      File.write(
        File.join(tmpdir, "duplicate_prism_version.rbs"),
        "module Prism\n  VERSION: String\nend\n"
      )
      loader = described_class.new(libraries: ["prism"], signature_paths: [tmpdir])
      allow(loader).to receive(:warn) # silence
      expect(loader.each_known_class_name.to_a).to eq([])
      expect(loader.class_decl_paths).to eq({})
      expect(loader.constant_names).to eq([])
      expect(loader.class_known?("String")).to be(false)
    end
  end

  describe "env via cache_store (v0.0.9 C2)" do
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-env-spec-") }
    let(:cache_store) { Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache")) }

    after { FileUtils.rm_rf(tmpdir) }

    it "uses the cached env so a fresh loader sharing the store never rebuilds" do
      first = described_class.new(cache_store: cache_store)
      first.send(:env) # force build + cache write

      allow(described_class).to receive(:build_env_for).and_call_original
      second = described_class.new(cache_store: cache_store)
      second.send(:env)
      expect(described_class).not_to have_received(:build_env_for)
    end

    it "keeps instance_method lookups working on the cached env" do
      first = described_class.new(cache_store: cache_store)
      first.instance_method(class_name: "Hash", method_name: :fetch)

      second = described_class.new(cache_store: cache_store)
      method_def = second.instance_method(class_name: "Hash", method_name: :fetch)
      expect(method_def).to be_a(RBS::Definition::Method)
    end
  end

  describe "#class_type_param_names via cache_store (v0.0.9 A)" do
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-type-params-spec-") }
    let(:cache_store) { Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache")) }

    after { FileUtils.rm_rf(tmpdir) }

    it "matches the uncached path for generic and non-generic classes" do
      cached = described_class.new(cache_store: cache_store)
      uncached = described_class.new
      %w[Array Hash Integer ::Set].each do |class_name|
        expect(cached.class_type_param_names(class_name)).to eq(uncached.class_type_param_names(class_name))
      end
    end

    it "returns an empty array for unknown class names" do
      cached = described_class.new(cache_store: cache_store)
      expect(cached.class_type_param_names("ThisClassDoesNotExist123")).to eq([])
    end

    it "uses the cached table so a fresh loader sharing the store never builds a definition" do
      first = described_class.new(cache_store: cache_store)
      first.class_type_param_names("Array")

      second = described_class.new(cache_store: cache_store)
      allow(second).to receive(:instance_definition).and_call_original
      second.class_type_param_names("Array")
      second.class_type_param_names("Hash")
      expect(second).not_to have_received(:instance_definition)
    end

    it "returns a fresh Array on each call so callers cannot mutate the cached payload" do
      cached = described_class.new(cache_store: cache_store)
      a = cached.class_type_param_names("Array")
      a << :Mutated
      expect(cached.class_type_param_names("Array")).to eq([:Elem])
    end
  end

  describe "#class_ordering via cache_store (v0.0.9 B)" do
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-ordering-spec-") }
    let(:cache_store) { Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache")) }

    after { FileUtils.rm_rf(tmpdir) }

    it "matches the uncached path for known and unknown class pairs" do
      cached = described_class.new(cache_store: cache_store)
      uncached = described_class.new
      [%w[Integer Numeric], %w[Numeric Integer], %w[Integer String]].each do |lhs, rhs|
        expect(cached.class_ordering(lhs, rhs)).to eq(uncached.class_ordering(lhs, rhs))
      end
    end

    it "uses the cached ancestor table so a fresh loader sharing the store never builds a definition" do
      first = described_class.new(cache_store: cache_store)
      first.class_ordering("Integer", "Numeric")

      second = described_class.new(cache_store: cache_store)
      allow(second).to receive(:instance_definition).and_call_original
      second.class_ordering("Integer", "Numeric")
      second.class_ordering("String", "Object")
      expect(second).not_to have_received(:instance_definition)
    end
  end

  describe "#class_known? via cache_store (v0.0.9 group C)" do
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-class-known-spec-") }
    let(:cache_store) { Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache")) }

    after { FileUtils.rm_rf(tmpdir) }

    it "matches the uncached path for known and unknown names" do
      cached = described_class.new(cache_store: cache_store)
      uncached = described_class.new
      %w[Integer Object Hash ThisClassDoesNotExist123].each do |name|
        expect(cached.class_known?(name)).to eq(uncached.class_known?(name))
      end
    end

    it "uses the cached set so a fresh loader sharing the store never re-walks env decls" do
      first = described_class.new(cache_store: cache_store)
      first.class_known?("Integer")

      second = described_class.new(cache_store: cache_store)
      allow(second).to receive(:each_known_class_name).and_call_original
      second.class_known?("Integer")
      second.class_known?("ThisClassDoesNotExist123")
      expect(second).not_to have_received(:each_known_class_name)
    end
  end

  describe "#constant_type via cache_store (v0.0.9 group A slice 2)" do
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-cache-spec-") }
    let(:cache_store) { Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache")) }

    after { FileUtils.rm_rf(tmpdir) }

    it "returns the same translated type as the uncached path" do
      uncached = described_class.new
      cached = described_class.new(cache_store: cache_store)
      expect(cached.constant_type("Math::PI")).to eq(uncached.constant_type("Math::PI"))
    end

    it "returns nil for unknown constant names under the cached path" do
      cached = described_class.new(cache_store: cache_store)
      expect(cached.constant_type("Math::ThisConstantDoesNotExist123")).to be_nil
    end

    it "uses the on-disk cache so a fresh loader sharing the store never builds env" do
      first = described_class.new(cache_store: cache_store)
      first.constant_type("Math::PI")

      second = described_class.new(cache_store: cache_store)
      allow(second).to receive(:each_constant_decl).and_call_original
      second.constant_type("Math::PI")
      expect(second).not_to have_received(:each_constant_decl)
    end
  end
end
