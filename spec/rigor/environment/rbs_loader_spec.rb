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

  describe ".vendored_gem_names" do
    it "returns the gem subdirectory names under data/vendored_gem_sigs/" do
      names = described_class.vendored_gem_names
      # The set is the source of truth for RbsCollectionDiscovery's
      # skip list; assert the known native-ext / Rails-ubiquitous
      # gems that drove the collision fix are present.
      expect(names).to include("redis", "nokogiri", "pg", "bcrypt", "cgi")
    end

    it "excludes the non-gem README.md sibling file" do
      expect(described_class.vendored_gem_names).not_to include("README.md")
    end
  end

  describe ".gem_overlay_sig_paths" do
    it "returns the bundled overlay directory for a gem that ships one" do
      paths = described_class.gem_overlay_sig_paths(["activesupport"])
      expect(paths.size).to eq(1)
      expect(paths.first).to be_a(Pathname)
      expect(paths.first.to_s).to end_with("data/gem_overlay/activesupport")
      expect(paths.first.join("core_ext.rbs")).to be_file
    end

    it "ignores gems with no bundled overlay" do
      expect(described_class.gem_overlay_sig_paths(%w[rake no_such_gem])).to be_empty
    end

    it "returns paths only for the gems that have an overlay, in input order" do
      paths = described_class.gem_overlay_sig_paths(%w[rake activesupport])
      expect(paths.map { |p| p.basename.to_s }).to eq(["activesupport"])
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

  describe "class-alias resolution (`class Mutex = Thread::Mutex`)" do
    # An RBS class alias lives only in `class_alias_decls`, so `class_known?`
    # reports it but the definition builder (which only knows `class_decls`)
    # could not enumerate its methods. The loader now normalises the alias to
    # its canonical target before building, so dispatch and the
    # `call.undefined-method` existence check both work on `Mutex`.
    it "reports the alias as known" do
      expect(loader.class_known?("Mutex")).to be(true)
    end

    it "builds the instance definition by resolving the alias target" do
      expect(loader.instance_definition("Mutex")).not_to be_nil
      expect(loader.instance_method_names("Mutex")).to include(:synchronize, :lock, :unlock)
    end

    it "resolves an instance method through the alias" do
      expect(loader.instance_method(class_name: "Mutex", method_name: :synchronize)).not_to be_nil
    end

    it "resolves the singleton (class-side) definition through the alias" do
      expect(loader.singleton_method(class_name: "Mutex", method_name: :new)).not_to be_nil
    end

    it "leaves a non-alias class unchanged" do
      expect(loader.instance_method_names("Integer")).to include(:+, :to_s)
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

  describe "#rbs_module?" do
    it "is true for core modules (Comparable, Enumerable, Kernel)" do
      expect(loader.rbs_module?("Comparable")).to be(true)
      expect(loader.rbs_module?("Enumerable")).to be(true)
      expect(loader.rbs_module?("Kernel")).to be(true)
    end

    it "is false for core classes (Object, Integer, String)" do
      expect(loader.rbs_module?("Object")).to be(false)
      expect(loader.rbs_module?("Integer")).to be(false)
      expect(loader.rbs_module?("String")).to be(false)
    end

    it "is false for unknown names" do
      expect(loader.rbs_module?("ThisModuleDoesNotExist123")).to be(false)
    end

    it "accepts both unprefixed and absolute names" do
      expect(loader.rbs_module?("Kernel")).to be(true)
      expect(loader.rbs_module?("::Kernel")).to be(true)
    end

    it "tolerates malformed names without raising" do
      expect(loader.rbs_module?("not a name")).to be(false)
      expect(loader.rbs_module?("")).to be(false)
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

  describe "core overlay (data/core_overlay/)" do
    # `Numeric#to_f`/`to_i`/`to_r` are not declared on the abstract
    # `Numeric` by upstream `ruby/rbs` (only on the concrete subclasses),
    # but Rigor widens arithmetic chains to `Numeric`, so the overlay
    # reopens the class to supply them. See data/core_overlay/numeric.rbs.
    it "exposes a non-empty overlay sig path set" do
      expect(described_class.core_overlay_sig_paths).not_to be_empty
      expect(described_class.core_overlay_sig_paths).to all(be_a(Pathname))
    end

    it "resolves Numeric#to_f / #to_i / #to_r added by the overlay" do
      %i[to_f to_i to_r].each do |name|
        method = loader.instance_method(class_name: "Numeric", method_name: name)
        expect(method).not_to be_nil, "expected overlay to declare Numeric##{name}"
        expect(method.method_types).not_to be_empty
      end
    end

    it "leaves the upstream Numeric#to_c / #to_int declarations intact" do
      %i[to_c to_int].each do |name|
        expect(loader.instance_method(class_name: "Numeric", method_name: name)).not_to be_nil
      end
    end

    # `Pathname#expand_path` delegates to `File.expand_path` at runtime, which
    # accepts any `to_path`-bearing object as its `dir` base.  The upstream RBS
    # sig only allows `String`, causing false positives when a `Pathname` is
    # passed as the base (the Bundler pattern).  See data/core_overlay/pathname.rbs.
    context "with the pathname stdlib library loaded" do
      # Pathname is a stdlib library (not core), so we need a loader that
      # opts in to it.
      let(:pathname_loader) { described_class.new(libraries: ["pathname"]) }

      it "resolves Pathname#expand_path with the widened overlay signature" do
        method = pathname_loader.instance_method(class_name: "Pathname", method_name: :expand_path)
        expect(method).not_to be_nil, "expected overlay to declare Pathname#expand_path"
        expect(method.method_types).not_to be_empty
        # The overlay widens the optional `dir` parameter to accept Pathname
        # in addition to String; verify at least one overload carries a parameter.
        param_types = method.method_types.flat_map { |mt| mt.type.required_positionals + mt.type.optional_positionals }
        expect(param_types).not_to be_empty
      end

      it "leaves the upstream Pathname#expand_path return type as Pathname" do
        method = pathname_loader.instance_method(class_name: "Pathname", method_name: :expand_path)
        return_types = method.method_types.map { |mt| mt.type.return_type.to_s }
        expect(return_types).to all(eq("::Pathname"))
      end
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

  describe "#class_decl_paths" do
    # Regression: `class_decl_paths` called `entry.primary_decl`
    # unguarded, which only exists on RBS 4.x. Under RBS 3.x (allowed
    # by the gemspec `rbs >= 3.0, < 5.0`, which exposes `entry.primary`
    # instead) `rigor check` crashed with
    # `undefined method 'primary_decl'`. The shared `primary_decl_for`
    # helper normalises both shapes, so this maps every loaded class to
    # the file its first declaration came from across the whole range.
    it "maps core classes to the RBS source file of their first declaration" do
      paths = loader.class_decl_paths
      expect(paths).not_to be_empty
      expect(paths).to be_frozen
      expect(paths["::Integer"]).to be_a(String)
      expect(paths["::Integer"]).to end_with(".rbs")
    end

    it "attributes a project signature_paths class to its own sig file" do
      tmpdir = Dir.mktmpdir("rigor-rbs-loader-decl-paths-spec-")
      File.write(
        File.join(tmpdir, "widget.rbs"),
        "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n"
      )
      project_loader = described_class.new(signature_paths: [tmpdir])
      expect(project_loader.class_decl_paths["::Acme::Widget"])
        .to eq(File.join(tmpdir, "widget.rbs"))
    ensure
      FileUtils.rm_rf(tmpdir) if tmpdir
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
      allow(loader).to receive(:warn) # silence the once-per-loader env-build-failure warning
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

  describe "missing-namespace synthesis (ADR-5 robustness)" do
    # A project sig set that declares qualified names without ever
    # declaring the enclosing namespace is invalid upstream (`rbs
    # validate` rejects it); pre-fix every method on every such class
    # degraded to Dynamic[Top] because `build_instance` raised
    # `NoTypeFoundError`. The loader now synthesizes the missing
    # `module` so the otherwise-inert signatures resolve.
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-namespace-spec-") }

    after { FileUtils.rm_rf(tmpdir) }

    it "resolves an instance method declared under a never-declared namespace" do
      File.write(
        File.join(tmpdir, "qualified.rbs"),
        "class Acme::Widget\n  def size: () -> Integer\nend\n"
      )
      loader = described_class.new(signature_paths: [tmpdir])
      method = loader.instance_method(class_name: "Acme::Widget", method_name: :size)
      expect(method).not_to be_nil
      expect(method.method_types.map(&:to_s)).to eq(["() -> ::Integer"])
    end

    it "reports the synthesized namespace name(s), shallowest-first" do
      File.write(
        File.join(tmpdir, "nested.rbs"),
        "class Acme::Sub::Widget\n  def size: () -> Integer\nend\n"
      )
      loader = described_class.new(signature_paths: [tmpdir])
      expect(loader.synthesized_namespaces).to eq(["Acme", "Acme::Sub"])
    end

    it "is a no-op for a well-formed sig set that declares its namespace" do
      File.write(
        File.join(tmpdir, "wellformed.rbs"),
        "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n"
      )
      loader = described_class.new(signature_paths: [tmpdir])
      expect(loader.synthesized_namespaces).to eq([])
      expect(loader.instance_method(class_name: "Acme::Widget", method_name: :size)).not_to be_nil
    end

    it "recovers the synthesized names from the marshalled env cache" do
      File.write(
        File.join(tmpdir, "qualified.rbs"),
        "class Acme::Widget\n  def size: () -> Integer\nend\n"
      )
      cache_store = Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache"))
      described_class.new(signature_paths: [tmpdir], cache_store: cache_store).send(:env) # populate cache
      fresh = described_class.new(signature_paths: [tmpdir], cache_store: cache_store)
      expect(fresh.synthesized_namespaces).to eq(["Acme"])
    end
  end

  describe "referenced-type stub synthesis (ADR-5 robustness)" do
    # A single reference to a type no loaded signature declares makes
    # RBS's per-class build fail wholesale, so EVERY method on the
    # referencing class degrades to Dynamic[Top]. Stubbing the missing
    # type lets the rest of the class build.
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-stub-spec-") }

    after { FileUtils.rm_rf(tmpdir) }

    it "resolves the unaffected methods of a class that references an undeclared type" do
      File.write(
        File.join(tmpdir, "widget.rbs"),
        <<~RBS
          module Acme
            class Widget
              def size: () -> Integer
              def remote: () -> Net::FakeService
            end
          end
        RBS
      )
      loader = described_class.new(signature_paths: [tmpdir])
      # `size` does not touch the missing type and must resolve...
      expect(loader.instance_method(class_name: "Acme::Widget", method_name: :size)).not_to be_nil
      # ...and the missing referenced type is reported as stubbed.
      expect(loader.synthesized_stub_types).to include("Net::FakeService")
    end

    it "folds namespace + stub names into synthesized_type_names for dispatch" do
      File.write(
        File.join(tmpdir, "widget.rbs"),
        "class Acme::Widget\n  def remote: () -> Net::FakeService\nend\n"
      )
      loader = described_class.new(signature_paths: [tmpdir])
      names = loader.synthesized_type_names
      expect(names).to be_a(Set)
      expect(names).to include("Net::FakeService")
    end

    it "is a no-op for a sig set whose references all resolve" do
      File.write(
        File.join(tmpdir, "widget.rbs"),
        "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n"
      )
      loader = described_class.new(signature_paths: [tmpdir])
      expect(loader.synthesized_stub_types).to eq([])
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
