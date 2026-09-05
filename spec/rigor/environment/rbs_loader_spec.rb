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
      # The set is the source of truth for RbsCollectionDiscovery's skip list; assert the known native-ext /
      # Rails-ubiquitous gems that drove the collision fix are present.
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

  # Issue #632/#660 — `CheckRules#gem_overlay_loaded?` calls this instead of reaching for
  # `GEM_OVERLAY_SIGS_ROOT` directly: that constant is defined inside this class's `class << self` block, so
  # it is reachable from methods in the SAME block but not as `RbsLoader::GEM_OVERLAY_SIGS_ROOT` from outside
  # (a `NameError` a plain constant reference doesn't catch — this method is the public seam instead).
  describe ".under_gem_overlay_root?" do
    it "is true for a path this method's own gem_overlay_sig_paths would return" do
      path = described_class.gem_overlay_sig_paths(["activesupport"]).first
      expect(described_class.under_gem_overlay_root?(path)).to be(true)
    end

    it "is true for a String path under the root, not only a Pathname" do
      dir = described_class.gem_overlay_sig_paths(["activesupport"]).first
      expect(described_class.under_gem_overlay_root?("#{dir}/core_ext.rbs")).to be(true)
    end

    it "is false for a path outside the gem-overlay root" do
      expect(described_class.under_gem_overlay_root?("/some/project/sig")).to be(false)
    end

    it "is false for a differently-named sibling directory that merely shares the prefix" do
      root = described_class.gem_overlay_sig_paths(["activesupport"]).first.dirname
      expect(described_class.under_gem_overlay_root?("#{root}_other/activesupport")).to be(false)
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
    # An RBS class alias lives only in `class_alias_decls`, so `class_known?` reports it but the definition builder
    # (which only knows `class_decls`) could not enumerate its methods. The loader now normalises the alias to its
    # canonical target before building, so dispatch and the `call.undefined-method` existence check both work on
    # `Mutex`.
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
    # `Numeric#to_f`/`to_i`/`to_r` are not declared on the abstract `Numeric` by upstream `ruby/rbs` (only on the
    # concrete subclasses), but Rigor widens arithmetic chains to `Numeric`, so the overlay reopens the class to supply
    # them. See data/core_overlay/numeric.rbs.
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

    # `Pathname#expand_path` delegates to `File.expand_path` at runtime, which accepts any `to_path`-bearing object as
    # its `dir` base. The upstream RBS sig only allows `String`, causing false positives when a `Pathname` is passed as
    # the base (the Bundler pattern). See data/core_overlay/pathname.rbs.
    context "with the pathname stdlib library loaded" do
      # Pathname is a stdlib library (not core), so we need a loader that opts in to it.
      let(:pathname_loader) { described_class.new(libraries: ["pathname"]) }

      it "resolves Pathname#expand_path with the widened overlay signature" do
        method = pathname_loader.instance_method(class_name: "Pathname", method_name: :expand_path)
        expect(method).not_to be_nil, "expected overlay to declare Pathname#expand_path"
        expect(method.method_types).not_to be_empty
        # The overlay widens the optional `dir` parameter to accept Pathname in addition to String; verify at least one
        # overload carries a parameter.
        param_types = method.method_types.flat_map { |mt| mt.type.required_positionals + mt.type.optional_positionals }
        expect(param_types).not_to be_empty
      end

      it "leaves the upstream Pathname#expand_path return type as Pathname" do
        method = pathname_loader.instance_method(class_name: "Pathname", method_name: :expand_path)
        return_types = method.method_types.map { |mt| mt.type.return_type.to_s }
        expect(return_types).to all(eq("::Pathname"))
      end
    end

    # `Psych.parse` (= `YAML.parse`) and the two-arg `CSV::MalformedCSVError.new(message, line)` are real
    # stdlib API the pinned `rbs` gem omits; the overlay restores them so GitLab's `YAML.parse(...)` and
    # `raise CSV::MalformedCSVError.new(msg, line)` don't false-fire undefined-method / wrong-arity. See
    # data/core_overlay/psych.rbs + csv.rbs.
    context "with the psych / csv stdlib libraries loaded" do
      let(:stdlib_loader) { described_class.new(libraries: %w[psych csv]) }

      it "resolves the singleton `Psych.parse` added by the overlay" do
        method = stdlib_loader.singleton_definition("Psych")&.methods&.[](:parse)
        expect(method).not_to be_nil, "expected overlay to declare Psych.parse"
        expect(method.method_types).not_to be_empty
      end

      it "resolves the two-arg `CSV::MalformedCSVError#initialize` added by the overlay" do
        method = stdlib_loader.instance_method(class_name: "CSV::MalformedCSVError", method_name: :initialize)
        expect(method).not_to be_nil, "expected overlay to declare CSV::MalformedCSVError#initialize"
        # A `(String, ?Integer)` overload — at least one positional beyond the inherited single-arg form.
        positionals = method.method_types.flat_map { |mt| mt.type.required_positionals + mt.type.optional_positionals }
        expect(positionals.size).to be >= 2
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
      # Module#instance_methods is a singleton-side method on every class type; it MUST NOT be exposed on the instance
      # side.
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

  describe "definition build failure warning (#295)" do
    # A `signature_paths:` file that PARSES cleanly — so `#env` builds successfully and `class_known?`
    # comes back true — but whose class declares the same method twice without an overload marker. RBS
    # only detects that when `RBS::DefinitionBuilder` actually builds the definition, which (unlike the
    # env-build failures exercised above) happens LAZILY: per class, on the first caller that asks. This is
    # exactly the shape the loader's memoised-nil rescue used to swallow in silence — the class stayed
    # "known", so every subsequent call to it, real methods and typos alike, degraded to `Dynamic[top]`
    # unwitnessed.
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-definition-build-spec-") }

    after { FileUtils.rm_rf(tmpdir) }

    def write_duplicate_method_rbs(tmpdir)
      File.write(
        File.join(tmpdir, "widget.rbs"),
        "class Widget\n  def bar: () -> void\n  def bar: () -> String\nend\n"
      )
    end

    it "warns once, naming the class and the colliding declaration file" do
      write_duplicate_method_rbs(tmpdir)
      loader = described_class.new(signature_paths: [tmpdir])
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }

      expect(loader.instance_definition("Widget")).to be_nil
      expect(messages.size).to eq(1)
      expect(messages.first).to include("RBS definition build failed")
      expect(messages.first).to include("Widget")
      expect(messages.first).to include("DuplicatedMethodDefinitionError")
      expect(messages.first).to include(File.join(tmpdir, "widget.rbs"))
    end

    it "does not double-warn when both the instance and singleton sides fail for the same class" do
      write_duplicate_method_rbs(tmpdir)
      loader = described_class.new(signature_paths: [tmpdir])
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }

      loader.instance_definition("Widget")
      loader.singleton_definition("Widget")
      loader.instance_definition("Widget") # per-process memo cache hit — must not re-warn

      expect(messages.size).to eq(1)
    end

    it "keeps the class known and fails soft: dispatch degrades without a crash or new diagnostic" do
      write_duplicate_method_rbs(tmpdir)
      loader = described_class.new(signature_paths: [tmpdir])
      allow(loader).to receive(:warn)

      expect(loader.class_known?("Widget")).to be(true)
      expect(loader.instance_definition("Widget")).to be_nil
      expect(loader.instance_method(class_name: "Widget", method_name: :bar)).to be_nil
    end

    it "does not warn for a class whose definition builds cleanly" do
      File.write(File.join(tmpdir, "widget.rbs"), "class Widget\n  def bar: () -> void\nend\n")
      loader = described_class.new(signature_paths: [tmpdir])
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }

      expect(loader.instance_definition("Widget")).not_to be_nil
      expect(messages).to be_empty
    end

    it "warns identically on a cache-hit run (definition builds stay per-process since ADR-54)" do
      write_duplicate_method_rbs(tmpdir)
      cache_store = Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache"))

      warm = described_class.new(signature_paths: [tmpdir], cache_store: cache_store)
      allow(warm).to receive(:warn) # populate the env cache; not what this example asserts
      warm.send(:env)

      loader = described_class.new(signature_paths: [tmpdir], cache_store: cache_store)
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }

      expect(loader.instance_definition("Widget")).to be_nil
      expect(messages.size).to eq(1)
      expect(messages.first).to include("RBS definition build failed")
    end

    # Issue #696 — the stderr banner above is not a diagnostic, so it never reached `--format json`, SARIF,
    # CI annotations, the LSP, or the exit code. `#definition_build_failures` is the recorded half the
    # analysis layer turns into `rbs.coverage.definition-build-failed`.
    it "records the failed class, the error class, the message and the colliding file for the diagnostic" do
      write_duplicate_method_rbs(tmpdir)
      loader = described_class.new(signature_paths: [tmpdir])
      allow(loader).to receive(:warn)

      expect(loader.instance_definition("Widget")).to be_nil

      class_name, error_class, member, buffers = loader.definition_build_failures.first
      expect(loader.definition_build_failures.size).to eq(1)
      expect(class_name).to eq("Widget")
      expect(error_class).to eq("RBS::DuplicatedMethodDefinitionError")
      # The MEMBER, off the error object rather than parsed out of its message: the message is built from
      # `RBS::Location`s, which the ADR-54 env cache dumps to a `<cached>` sentinel, so a warm run would
      # otherwise report different text than a cold one (issue #696 review, F4).
      expect(member).to eq("::Widget#bar")
      expect(buffers).to eq([File.join(tmpdir, "widget.rbs")])
    end

    # F4 — a cache hit must report the SAME thing a cold run does, member and file alike.
    #
    # `#qualified_method_name` is a `TypeName` + Symbol, so the member always round-tripped. The FILE did
    # not: the ADR-54 marshal patch reconstructed every `RBS::Location` behind a `<cached>` sentinel, so a
    # warm run named no file and a cold run named one — the same project saying different things by cache
    # state. The patch now keeps `buffer.name`, so both name the file.
    #
    # `eq`, not `not_to include`: the weaker form passes on `[]`, which is exactly the residual it was
    # supposed to document (issue #696 review, second pass, nit 2).
    it "reports the same member AND the same file on a cache-hit run as on a cold one" do
      write_duplicate_method_rbs(tmpdir)
      cache_store = Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache"))
      warm = described_class.new(signature_paths: [tmpdir], cache_store: cache_store)
      allow(warm).to receive(:warn)
      warm.send(:env)

      loader = described_class.new(signature_paths: [tmpdir], cache_store: cache_store)
      allow(loader).to receive(:warn)
      loader.instance_definition("Widget")

      _, _, member, buffers = loader.definition_build_failures.first
      expect(member).to eq("::Widget#bar")
      expect(buffers).to eq([File.join(tmpdir, "widget.rbs")])
    end

    # F4, the other half — the sentinel itself, driven straight through the buffer extractor. A warm
    # cross-process run reported `Conflicting signature file(s): <cached>`, naming a sentinel as if it were
    # a path the user could open. It is dropped, so the clause is simply absent rather than wrong.
    it "never reports the marshal sentinel as a conflicting signature file" do
      loader = described_class.new
      buffer = Struct.new(:name).new(described_class::CACHED_LOCATION_BUFFER_NAME)
      member = Struct.new(:location).new(Struct.new(:buffer).new(buffer))
      # `Struct.new(:members)` would override `Struct#members`; a bare object carrying the accessor is what
      # the real `RBS::DuplicatedMethodDefinitionError` looks like to this method anyway.
      error = Object.new
      error.define_singleton_method(:members) { [member] }

      expect(loader.send(:definition_build_conflict_buffers, error)).to eq([])
    end

    # `::Widget` (the eager table walk's `RBS::TypeName#to_s` spelling) and `Widget` (a dispatch site's) are
    # the same class, and a diagnostic that named both would be lying about the count.
    it "records one entry per class however the caller spelled the name" do
      write_duplicate_method_rbs(tmpdir)
      loader = described_class.new(signature_paths: [tmpdir])
      allow(loader).to receive(:warn)

      loader.instance_definition("Widget")
      loader.singleton_definition("::Widget")

      expect(loader.definition_build_failures.map(&:first)).to eq(["Widget"])
    end

    # The must-still-succeed twin of the two above: a healthy sig set records nothing, so the diagnostic
    # cannot fire on a project with nothing wrong.
    it "records nothing for a class whose definition builds cleanly" do
      File.write(File.join(tmpdir, "widget.rbs"), "class Widget\n  def bar: () -> void\nend\n")
      loader = described_class.new(signature_paths: [tmpdir])

      expect(loader.instance_definition("Widget")).not_to be_nil
      expect(loader.definition_build_failures).to be_empty
    end

    # Issue #696 review, F1 — the regression gate for the BLOCKER. The whole-universe walk behind
    # `#prewarm` / `#reflection` is a cache-warming implementation detail, so what it discovers must not
    # reach the diagnostic: otherwise the reported class list depends on whether a pool warmed a cache, and
    # the same project reports differently under `--workers=N` than under `--workers=0` — the "reports less
    # depending on how you ran it" defect the diagnostic exists to end. The stderr banner stays armed there,
    # unchanged.
    #
    # The first cut of this fix suppressed recording in `instance_definitions_table` /
    # `singleton_definitions_table`, which record nothing either way. The producers that were actually
    # recording are `RbsClassTypeParamNames` and `RbsClassAncestorTable`, which walk `each_known_class_name`
    # through the PUBLIC `#instance_definition` — and only on a COLD store, since a warm one serves the
    # table from disk and never walks. That is why this example needs a real store and a cold one: with a
    # nil store `#prewarm` returns immediately and executes none of this.
    #
    # On a fresh checkout with default workers (i.e. CI) the un-suppressed walk made one `class Object`
    # duplicate report 1,336 classes where every other configuration reported 3.
    it "does not record from a cold-store pre-warm, only from what the analysis demanded" do
      write_duplicate_method_rbs(tmpdir)
      cache_store = Rigor::Cache::Store.new(root: File.join(tmpdir, ".rigor", "cache"))
      loader = described_class.new(signature_paths: [tmpdir], cache_store: cache_store)
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }

      loader.prewarm

      expect(loader.definition_build_failures).to be_empty
      # Non-vacuity: the walk really did reach the failing build — it just must not feed the diagnostic.
      expect(messages.grep(/RBS definition build failed/)).not_to be_empty
      # And the memoised nil must not swallow the real demand that follows. Recording from the rescue
      # cannot satisfy this: after the walk, the rescue never runs again for this class.
      expect(loader.instance_definition("Widget")).to be_nil
      expect(loader.definition_build_failures.map(&:first)).to eq(["Widget"])
    end

    # Issue #696 review, second pass — the BLOCKER. `RbsHierarchy` used to fetch `RbsClassAncestorTable`
    # directly, bypassing the loader's marked accessor, and branched on `cache_store`: a whole-universe
    # table build with a store, a single-class demand without one. Same project, same question, three
    # answers — 504 classes on a cold store, 0 on a warm one, 2 with no store. Reached from
    # `Environment#class_ordering` whenever two RBS-declared classes are compared (`raise SomeGemError`,
    # `rescue`, `is_a?`), and on the DEFAULT `--workers=0` path nothing pre-warms the store first, so the
    # cold answer was the one written into the run-result cache and replayed.
    #
    # Ordering two classes is not the analysis asking whether either one's methods resolve, so neither side
    # feeds the diagnostic now.
    it "reports nothing from a class-ordering query, in any cache state" do
      write_duplicate_method_rbs(tmpdir)
      root = File.join(tmpdir, ".rigor", "cache")
      cold = described_class.new(signature_paths: [tmpdir], cache_store: Rigor::Cache::Store.new(root: root))
      warm = described_class.new(signature_paths: [tmpdir], cache_store: Rigor::Cache::Store.new(root: root))
      none = described_class.new(signature_paths: [tmpdir], cache_store: nil)
      [cold, warm, none].each { |loader| allow(loader).to receive(:warn) }

      orderings = [cold, warm, none].map { |loader| loader.class_ordering("Widget", "Object") }
      failures = [cold, warm, none].map(&:definition_build_failures)

      expect(failures).to eq([[], [], []])
      # Non-vacuity and the must-still-succeed half: the query really was answered, identically in all
      # three states. A hierarchy that silently returned `:unknown` everywhere would satisfy the line above.
      expect(orderings.uniq.size).to eq(1)
      expect(orderings.first).to eq(:unknown) # `Widget` is the class whose build fails here
    end

    # The ordering ANSWERS are what the branch removal must not move, so they are pinned on a healthy sig
    # set where the relationships are real.
    it "answers class_ordering identically in every cache state on a healthy sig set" do
      File.write(File.join(tmpdir, "widget.rbs"), "class Widget\n  def bar: () -> void\nend\n")
      root = File.join(tmpdir, ".rigor", "cache")
      loaders = [described_class.new(signature_paths: [tmpdir], cache_store: Rigor::Cache::Store.new(root: root)),
                 described_class.new(signature_paths: [tmpdir], cache_store: Rigor::Cache::Store.new(root: root)),
                 described_class.new(signature_paths: [tmpdir], cache_store: nil)]
      pairs = [%w[String Object], %w[Object String], %w[String Integer], %w[StandardError Exception]]

      answers = loaders.map { |loader| pairs.map { |l, r| loader.class_ordering(l, r) } }

      expect(answers.uniq.size).to eq(1)
      expect(answers.first).to eq(%i[subclass superclass disjoint subclass])
    end

    it "does not record from the eager definitions table either" do
      write_duplicate_method_rbs(tmpdir)
      loader = described_class.new(signature_paths: [tmpdir])
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }

      loader.send(:instance_definitions_table)

      expect(loader.definition_build_failures).to be_empty
      expect(messages.grep(/RBS definition build failed/)).not_to be_empty
      loader.instance_definition("Widget")
      expect(loader.definition_build_failures.map(&:first)).to eq(["Widget"])
    end
  end

  describe "#class_type_param_names (Slice 4 phase 2d)" do
    it "returns Array's single element type parameter" do
      expect(loader.class_type_param_names("Array")).to eq([RbsCoreTypeParams.array_element])
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
    # Regression: `class_decl_paths` called `entry.primary_decl` unguarded, which only exists on RBS 4.x. Under RBS 3.x
    # (allowed by the gemspec `rbs >= 3.0, < 5.0`, which exposes `entry.primary` instead) `rigor check` crashed with
    # `undefined method 'primary_decl'`. The shared `primary_decl_for` helper normalises both shapes, so this maps every
    # loaded class to the file its first declaration came from across the whole range.
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
    # Open item O7 (real-world Rails survey, 2026-05-15): when env build raised,
    # pre-fix the `||=` memo in `#env` did not capture the failure, so every
    # subsequent `env` access re-parsed the whole sig set (~100x per-file).
    # Project-vs-bundled `DuplicatedDeclarationError`s are quarantined per-file
    # since #777; this describe keeps the *unrecoverable* failure memoisation
    # contract by stubbing `build_env_for` to raise.
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-conflict-spec-") }

    after { FileUtils.rm_rf(tmpdir) }

    def force_unrecoverable_build!(loader)
      error = Class.new(RBS::BaseError) do
        def message = "forced unrecoverable build failure"
      end.new
      allow(loader).to receive(:warn)
      allow(described_class).to receive(:build_env_for).and_raise(error)
      error
    end

    it "memoises an unrecoverable failure so env rebuilds only once" do
      loader = described_class.new(signature_paths: [tmpdir])
      force_unrecoverable_build!(loader)
      10.times { loader.send(:env) }
      expect(described_class).to have_received(:build_env_for).at_most(:once)
      expect(loader.send(:env)).to be_nil
    end

    it "emits a single warning for an unrecoverable env-build failure" do
      loader = described_class.new(signature_paths: [tmpdir])
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }
      error = Class.new(RBS::BaseError) do
        def message = "forced unrecoverable build failure"
      end.new
      allow(described_class).to receive(:build_env_for).and_raise(error)
      3.times { loader.send(:env) }
      expect(messages.size).to eq(1)
      expect(messages.first).to include("RBS environment build failed")
    end

    it "returns empty results from each_known_class_name / class_decl_paths when env is nil" do
      loader = described_class.new(signature_paths: [tmpdir])
      force_unrecoverable_build!(loader)
      expect(loader.each_known_class_name.to_a).to eq([])
      expect(loader.class_decl_paths).to eq({})
      expect(loader.constant_names).to eq([])
      expect(loader.class_known?("String")).to be(false)
    end
  end

  describe "project signature collision quarantine (issue #777)" do
    # A `signature_paths:` file that parses but kind-collides with bundled RBS
    # (`class Base64` vs bundled `module Base64`) used to raise
    # `RBS::DuplicatedDeclarationError` and collapse the WHOLE env to nil —
    # Greeter, core, and every other signature vanished, so dependent
    # diagnostics (e.g. a `lenght` typo) silently disappeared and the run
    # looked clean. Quarantine the conflicting project file only.
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-collision-spec-") }

    after { FileUtils.rm_rf(tmpdir) }

    before do
      skip "requires the sources-based RBS::Environment (rbs 4.x)" unless RBS::Environment.new.respond_to?(:sources)
    end

    def build_loader
      loader = described_class.new(
        libraries: Rigor::Environment::DEFAULT_LIBRARIES,
        signature_paths: [tmpdir]
      )
      allow(loader).to receive(:warn)
      loader
    end

    it "keeps the env usable when a project class collides with a bundled module" do
      File.write(File.join(tmpdir, "base64.rbs"),
                 "class Base64\n  def self.encode64: (String) -> String\nend\n")
      File.write(File.join(tmpdir, "greeter.rbs"),
                 "class Greeter\n  def greet: () -> String\nend\n")
      loader = build_loader
      env = loader.send(:env)
      expect(env).not_to be_nil
      expect(loader.env_build_failure).to be_nil
      expect(loader.class_known?("Greeter")).to be(true)
      expect(loader.class_known?("String")).to be(true)
      expect(loader.class_known?("Base64")).to be(true) # bundled module remains
      quarantined_paths = loader.quarantined_signatures.map(&:first)
      expect(quarantined_paths).to include(File.join(tmpdir, "base64.rbs"))
      expect(quarantined_paths).not_to include(File.join(tmpdir, "greeter.rbs"))
    end

    it "does not quarantine a same-kind reopen of the bundled module" do
      File.write(File.join(tmpdir, "base64.rbs"),
                 "module Base64\n  def self.encode64: (String) -> String\nend\n")
      File.write(File.join(tmpdir, "greeter.rbs"),
                 "class Greeter\n  def greet: () -> String\nend\n")
      loader = build_loader
      expect(loader.send(:env)).not_to be_nil
      expect(loader.quarantined_signatures).to be_empty
      expect(loader.class_known?("Greeter")).to be(true)
    end

    it "warns once naming the collision-quarantined file" do
      File.write(File.join(tmpdir, "base64.rbs"),
                 "class Base64\n  def self.encode64: (String) -> String\nend\n")
      File.write(File.join(tmpdir, "greeter.rbs"),
                 "class Greeter\n  def greet: () -> String\nend\n")
      loader = described_class.new(
        libraries: Rigor::Environment::DEFAULT_LIBRARIES,
        signature_paths: [tmpdir]
      )
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }
      3.times { loader.send(:env) }
      expect(messages.size).to eq(1)
      expect(messages.first).to include("QUARANTINED")
      expect(messages.first).to include(File.join(tmpdir, "base64.rbs"))
      expect(messages.first).to match(/duplicated|bundled RBS/i)
    end

    it "does not treat a path-mismatched copy of an already-loaded signature as collision-quarantined" do
      # Mirrors the suite's RbsEnvMemo: byte-identical sig content under a fresh Dir.mktmpdir with
      # relative `signature_paths:` reuses the env whose buffers still name the FIRST path. Path-only
      # membership would false-positive every memo hit as "duplicated against bundled RBS" (CI spam).
      content = "class Sink\n  def take_int: (Integer value) -> void\nend\n"
      File.write(File.join(tmpdir, "sink.rbs"), content)
      env = build_loader.send(:env)
      expect(env).not_to be_nil

      other = Dir.mktmpdir("rigor-rbs-loader-collision-other-")
      begin
        File.write(File.join(other, "sink.rbs"), content)
        reported = described_class.collision_quarantined_project_signatures(env, [other])
        expect(reported).to be_empty
      ensure
        FileUtils.rm_rf(other)
      end
    end
  end

  describe "unparseable project signature quarantine (env-build resilience)" do
    # A single unparseable user `.rbs` used to collapse the WHOLE env (`from_loader` parses all-or-nothing),
    # degrading every type-of query to Dynamic[top] — the "sig looks harmful" failure of the 2026-07-06 mastodon
    # coverage note. The loader now loads project sigs per-file and quarantines the broken one so the rest survives.
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-quarantine-spec-") }

    after { FileUtils.rm_rf(tmpdir) }

    it "keeps the valid sigs when a sibling file does not parse" do
      File.write(File.join(tmpdir, "good.rbs"),
                 "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n")
      # A bare non-identifier record key — the exact mastodon `application_helper.rbs` failure
      # (`unexpected record key token, token=`data``) a sig-gen bug emitted for `data-contrast:`.
      File.write(File.join(tmpdir, "bad.rbs"),
                 "module Acme\n  class Broken\n    def h: () -> { data-contrast: Integer }\n  end\nend\n")
      loader = described_class.new(signature_paths: [tmpdir])
      allow(loader).to receive(:warn) # silence the quarantine notice for this assertion
      expect(loader.send(:env)).not_to be_nil
      expect(loader.class_decl_paths["::Acme::Widget"]).to eq(File.join(tmpdir, "good.rbs"))
      expect(loader.class_known?("Acme::Broken")).to be(false)
    end

    it "warns once, naming the quarantined file and its parse error" do
      File.write(File.join(tmpdir, "good.rbs"),
                 "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n")
      File.write(File.join(tmpdir, "bad.rbs"),
                 "module Acme\n  class Broken\n    def h: () -> { data-contrast: Integer }\n  end\nend\n")
      loader = described_class.new(signature_paths: [tmpdir])
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }
      3.times { loader.send(:env) }
      expect(messages.size).to eq(1)
      expect(messages.first).to include("QUARANTINED")
      expect(messages.first).to include("record key")
      expect(messages.first).to include(File.join(tmpdir, "bad.rbs"))
    end

    it "does not warn when every project sig parses" do
      File.write(File.join(tmpdir, "good.rbs"),
                 "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n")
      loader = described_class.new(signature_paths: [tmpdir])
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }
      loader.send(:env)
      expect(messages).to be_empty
    end
  end

  describe "invalid-UTF-8 project signature quarantine (pre-parser guard)" do
    # rbs 4.1 turned an invalid UTF-8 byte into a clean `ParsingError` (ruby/rbs#2983), but on the older
    # releases the gemspec supports the C lexer could infinite-loop or abort on it (ruby/rbs#2973) — a hang
    # the quarantine's rescue can never catch. Rigor therefore rejects the content BEFORE the parser on every
    # rbs version; these specs pin the guard by asserting Rigor's own note, which no rbs-emitted message
    # contains.
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-encoding-spec-") }

    after { FileUtils.rm_rf(tmpdir) }

    before do
      File.write(File.join(tmpdir, "good.rbs"),
                 "module Acme\n  class Widget\n    def size: () -> Integer\n  end\nend\n")
      # `\xE9` is a bare Latin-1 é — an invalid byte in UTF-8. The declarations around it are well-formed, so
      # only the encoding (not the grammar) makes the file unusable.
      File.binwrite(File.join(tmpdir, "bad_encoding.rbs"),
                    "module Acme\n  class Broken\n    def size: () -> Integer\n  end\nend\n# caf\xE9\n")
    end

    it "keeps the valid sigs and skips the invalid-encoding file before it reaches the parser" do
      loader = described_class.new(signature_paths: [tmpdir])
      allow(loader).to receive(:warn)
      expect(loader.send(:env)).not_to be_nil
      expect(loader.class_decl_paths["::Acme::Widget"]).to eq(File.join(tmpdir, "good.rbs"))
      expect(loader.class_known?("Acme::Broken")).to be(false)
    end

    it "warns once, naming the file and Rigor's pre-parser note" do
      loader = described_class.new(signature_paths: [tmpdir])
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }
      3.times { loader.send(:env) }
      expect(messages.size).to eq(1)
      expect(messages.first).to include("QUARANTINED")
      expect(messages.first).to include(File.join(tmpdir, "bad_encoding.rbs"))
      expect(messages.first).to include("skipped before reaching the RBS parser")
    end

    it "skips an invalid-encoding virtual RBS contribution without pulling the env down" do
      bad_virtual = ["virtual:test:/app/lib/bad.rb", "module VirtualBad\nend\n# caf\xE9\n".b.force_encoding(Encoding::UTF_8)]
      clean_virtual = ["virtual:test:/app/lib/ok.rb", "module VirtualOk\nend\n"]
      loader = described_class.new(signature_paths: [tmpdir], virtual_rbs: [bad_virtual, clean_virtual])
      allow(loader).to receive(:warn)
      expect(loader.send(:env)).not_to be_nil
      expect(loader.class_known?("VirtualOk")).to be(true)
      expect(loader.class_known?("VirtualBad")).to be(false)
    end
  end

  describe "missing-namespace synthesis (ADR-5 robustness)" do
    # A project sig set that declares qualified names without ever declaring the enclosing namespace is invalid upstream
    # (`rbs validate` rejects it); pre-fix every method on every such class degraded to Dynamic[Top] because
    # `build_instance` raised `NoTypeFoundError`. The loader now synthesizes the missing `module` so the otherwise-inert
    # signatures resolve.
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
    # A single reference to a type no loaded signature declares makes RBS's per-class build fail wholesale, so EVERY
    # method on the referencing class degrades to Dynamic[Top]. Stubbing the missing type lets the rest of the class
    # build.
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

    it "does not collapse the env when a class references its own nested type (2026-07-04 redmine)" do
      # The stub sweep must stub only the missing leaf (`GitAdapter::Revision`), never re-declare the already-declared
      # `GitAdapter` as a `module` — that class-vs-module kind mismatch made `resolve_type_names` raise
      # DuplicatedDeclarationError and nulled the WHOLE env (every type-of query → Dynamic[Top]). The exact shape `rigor
      # sig-gen` emitted for a subclass whose sig dropped the superclass.
      File.write(
        File.join(tmpdir, "adapter.rbs"),
        <<~RBS
          module Scm
            class GitAdapter
              def lastrev: () -> (Scm::GitAdapter::Revision | nil)
            end
          end
        RBS
      )
      loader = described_class.new(signature_paths: [tmpdir])

      # The env builds (non-nil), so the declared method resolves...
      expect(loader.send(:env)).not_to be_nil
      expect(loader.instance_method(class_name: "Scm::GitAdapter", method_name: :lastrev)).not_to be_nil
      # ...and the missing nested leaf is the only thing stubbed.
      expect(loader.synthesized_stub_types).to include("Scm::GitAdapter::Revision")
    end

    it "stubs a dangling type-alias reference as a `type` alias, not a class (#237)" do
      # `type` and `interface` names are unparseable as `class <name>`, so the pre-#237 shape emitted a buffer
      # RBS rejected — and because the batch shared one buffer, the fail-soft rescue discarded EVERY stub in
      # it. herb ships 48 signature files whose 74 missing names are all dangling aliases, so the pass was a
      # complete no-op there.
      File.write(
        File.join(tmpdir, "widget.rbs"),
        "class Acme::Widget\n  def serialize: () -> serialized_widget\nend\n"
      )
      loader = described_class.new(signature_paths: [tmpdir])

      expect(loader.instance_method(class_name: "Acme::Widget", method_name: :serialize)).not_to be_nil
      alias_names = loader.send(:env).type_alias_decls.keys.map { |name| name.to_s.sub(/\A::/, "") }
      expect(alias_names).to include("serialized_widget")
    end

    it "stubs a dangling interface reference as an `interface`" do
      File.write(
        File.join(tmpdir, "widget.rbs"),
        "class Acme::Widget\n  def sink: () -> _Writable\nend\n"
      )
      loader = described_class.new(signature_paths: [tmpdir])

      expect(loader.instance_method(class_name: "Acme::Widget", method_name: :sink)).not_to be_nil
      interface_names = loader.send(:env).interface_decls.keys.map { |name| name.to_s.sub(/\A::/, "") }
      expect(interface_names).to include("_Writable")
    end

    it "lists every method name declared by a real (non-stubbed) interface" do
      File.write(
        File.join(tmpdir, "readable.rbs"),
        "interface _Readable\n  def read: () -> String\n  def close: () -> void\nend\n"
      )
      loader = described_class.new(signature_paths: [tmpdir])

      expect(loader.interface_method_names("_Readable")).to contain_exactly(:read, :close)
    end

    it "returns nil for an interface name that does not resolve" do
      loader = described_class.new(signature_paths: [tmpdir])

      expect(loader.interface_method_names("_NoSuchInterface")).to be_nil
    end

    it "lands class, namespace, interface and alias stubs from one batch" do
      # All four kinds in a single missing set — the shape that used to take the whole batch down with it,
      # since one buffer carried every declaration.
      File.write(
        File.join(tmpdir, "widget.rbs"),
        <<~RBS
          class Acme::Widget
            def remote: () -> Net::FakeService
            def sink: () -> _Writable
            def serialize: () -> serialized_widget
          end
        RBS
      )
      loader = described_class.new(signature_paths: [tmpdir])
      env = loader.send(:env)

      expect(loader.synthesized_stub_types).to include("Net", "Net::FakeService")
      expect(env.interface_decls.keys.map(&:to_s)).to include("::_Writable")
      expect(env.type_alias_decls.keys.map(&:to_s)).to include("::serialized_widget")
      # Every method still resolves: the class built.
      %i[remote sink serialize].each do |method_name|
        expect(loader.instance_method(class_name: "Acme::Widget", method_name: method_name)).not_to be_nil
      end
    end

    it "keeps the rest of a batch when one declaration fails validation" do
      # The per-declaration check is what bounds a bad declaration to itself. Every kind this synthesis emits
      # parses today (qualified `type` / `interface` included), so the rejection is injected rather than
      # spelled in RBS — the guard exists for a kind we get wrong, or an rbs grammar shift inside the
      # supported `>= 3.0, < 5.0` range.
      # Two classes, one missing name each, so both names reach the SAME batch (RBS surfaces only the first
      # missing reference per class, so two references on one class would arrive in separate passes).
      File.write(
        File.join(tmpdir, "widget.rbs"),
        <<~RBS
          class Acme::Widget
            def sink: () -> _Writable
          end

          class Acme::Gadget
            def remote: () -> Net::FakeService
          end
        RBS
      )
      allow(described_class).to receive(:parseable_rbs?).and_wrap_original do |original, source|
        source.start_with?("interface") ? false : original.call(source)
      end
      loader = described_class.new(signature_paths: [tmpdir])

      expect(loader.synthesized_stub_types).to include("Net::FakeService")
      expect(loader.send(:env).interface_decls.keys.map(&:to_s)).not_to include("::_Writable")
    end

    it "stops the fixpoint on a pass that appends nothing instead of burning MAX_STUB_PASSES" do
      # With nothing landing, detection re-reports the identical set forever. Before #237 the iteration cap was
      # the only stop, so the full detection sweep ran five times over (measured on herb, where every one of
      # the 74 missing names was discarded).
      File.write(
        File.join(tmpdir, "widget.rbs"),
        "class Acme::Widget\n  def remote: () -> Net::FakeService\nend\n"
      )
      allow(described_class).to receive(:parseable_rbs?).and_return(false)
      passes = 0
      allow(described_class).to receive(:unresolved_referenced_types).and_wrap_original do |original, *args|
        passes += 1
        original.call(*args)
      end
      loader = described_class.new(signature_paths: [tmpdir])
      loader.send(:env)

      expect(passes).to eq(1)
      expect(loader.synthesized_stub_types).to eq([])
    end

    it "still iterates when a stub exposes a deeper missing reference" do
      # The progress guard must not cost the case MAX_STUB_PASSES exists for: RBS surfaces only the first
      # missing reference per class per build, so a class with two of them needs a second pass.
      File.write(
        File.join(tmpdir, "widget.rbs"),
        <<~RBS
          class Acme::Widget
            def one: () -> Net::FakeService
            def two: () -> Net::OtherService
          end
        RBS
      )
      passes = 0
      allow(described_class).to receive(:unresolved_referenced_types).and_wrap_original do |original, *args|
        passes += 1
        original.call(*args)
      end
      loader = described_class.new(signature_paths: [tmpdir])

      expect(loader.synthesized_stub_types).to include("Net::FakeService", "Net::OtherService")
      expect(passes).to be > 1
    end

    it "does not re-stub a leaf whose namespace prefix is already a declared class" do
      # `append_stub_declarations` mirrors `collect_missing_namespaces`'s `declared.include?` guard: an enclosing prefix
      # already present in the env is never re-emitted.
      File.write(
        File.join(tmpdir, "adapter.rbs"),
        <<~RBS
          class Outer::Base
            def x: () -> Outer::Base::Nested
          end
        RBS
      )
      loader = described_class.new(signature_paths: [tmpdir])

      expect(loader.send(:env)).not_to be_nil
      expect(loader.synthesized_stub_types).to include("Outer::Base::Nested")
      expect(loader.synthesized_stub_types).not_to include("Outer::Base")
    end
  end

  describe "referenced-type detection agrees with the builder sweep (#207)" do
    # #207 replaced the detection half of the stub pass: it built every project class with a throwaway
    # `RBS::DefinitionBuilder` (7.84M allocations, a third of a cold `check lib`) and read the missing name out
    # of `NoTypeFoundError`. The sweep survives HERE, as the oracle the static walk must keep agreeing with —
    # `docs/notes/20260730-stub-pass1-static-detection-evaluation.md` is the corpus-scale version of this test.
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-detect-spec-") }

    after { FileUtils.rm_rf(tmpdir) }

    def builder_sweep(env, project_files)
      builder = RBS::DefinitionBuilder.new(env: env)
      missing = []
      env.class_decls.each do |type_name, entry|
        next unless described_class.send(:project_entry?, entry, project_files)

        %i[build_instance build_singleton].each do |build|
          builder.public_send(build, type_name)
        rescue RBS::NoTypeFoundError => e
          name = e.message[/Could not find (\S+)/, 1]
          missing << name.sub(/\A::/, "") if name
        rescue RBS::BaseError
          nil # other build failures are not this pass's to repair
        end
      end
      missing.uniq
    end

    # Both detectors, run against the FIRST pass's env (later passes see the stubs already appended). Each
    # fixture class carries exactly one missing name, so the builder's one-error-per-class limit cannot hide a
    # difference.
    def detect_both(source)
      File.write(File.join(tmpdir, "shapes.rbs"), source)
      captured = nil
      allow(described_class).to receive(:unresolved_referenced_types).and_wrap_original do |original, *args|
        env, project_files = args
        result = original.call(*args)
        captured ||= { builder: builder_sweep(env, project_files).sort, static: result.sort }
        result
      end
      described_class.new(signature_paths: [tmpdir]).send(:env)
      captured
    end

    # Fixture sources live outside the examples so each one reads as a table of positions rather than a wall
    # of heredoc.
    def validated_positions
      <<~RBS
        class ShapeReturn
          def x: () -> RigorGoneReturn
        end

        class ShapeParam
          def x: (RigorGoneParam a) -> void
        end

        class ShapeNested
          def x: () -> RigorGoneNested::Deep
        end

        class ShapeGenericArg
          def x: () -> Array[RigorGoneGenericArg]
        end

        class ShapeAttr
          attr_reader v: RigorGoneAttr
        end

        class ShapeBlockParam
          def x: () { (RigorGoneBlockParam) -> void } -> void
        end

        class ShapeInterface
          def x: () -> _RigorGoneInterface
        end

        class ShapeAlias
          def x: () -> rigor_gone_alias
        end

        class ShapeSuperArgs < Array[RigorGoneSuperArg]
        end

        class ShapeMixinArgs
          include Enumerable[RigorGoneMixinArg]
        end

        module ShapeSelfTypeArgs : Enumerable[RigorGoneSelfTypeArg]
        end
      RBS
    end

    # `validate_type_params` skips `initialize` and is never called for the singleton side, instance-variable
    # types are imported without validation, a missing super-class / mixin NAME raises a different error this
    # pass has never stubbed, and the methods a class imports from an interface are not variance-walked.
    # Reporting these anyway cost allocations on the corpus and changed no diagnostic, so the walk stops
    # exactly where the builder stopped.
    def unvalidated_positions
      <<~RBS
        class ShapeInitializeOnly
          def initialize: (RigorGoneInitialize a) -> void
        end

        class ShapeSingletonOnly
          def self.x: () -> RigorGoneSingleton
        end

        class ShapeIvarOnly
          @v: RigorGoneIvar
        end

        class ShapeSuperName < RigorGoneSuperName
        end

        class ShapeMixinName
          include RigorGoneMixinName
        end

        class ShapeAliasBody
          type body = RigorGoneAliasBody
          def x: () -> body
        end

        interface _RigorProbe
          def x: () -> RigorGoneFromInterface
        end

        class ShapeIncludesInterface
          include _RigorProbe
        end
      RBS
    end

    it "reports the same names for every position the builder validates" do
      result = detect_both(validated_positions)

      expect(result[:static]).to eq(result[:builder])
      expect(result[:static]).to include(
        "RigorGoneReturn", "RigorGoneParam", "RigorGoneNested::Deep", "RigorGoneGenericArg", "RigorGoneAttr",
        "RigorGoneBlockParam", "_RigorGoneInterface", "rigor_gone_alias", "RigorGoneSuperArg",
        "RigorGoneMixinArg", "RigorGoneSelfTypeArg"
      )
    end

    it "reports nothing for the positions the builder does not validate" do
      result = detect_both(unvalidated_positions)

      expect(result[:static]).to eq(result[:builder])
      expect(result[:static]).to be_empty
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
      expect(cached.class_type_param_names("Array")).to eq([RbsCoreTypeParams.array_element])
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

  describe "virtual RBS collision quarantine (inline-synthesized vs sig/)" do
    # A project that ships BOTH hand-written `sig/` and rbs-inline comments on the same code declares the
    # same constants twice — the expected state mid-migration, not an authoring error (measured on herb).
    # `RBS::Environment#add_source` appends the source before inserting decls, so without the transactional
    # rescue in `.add_virtual_rbs` the mid-insert `DuplicatedDeclarationError` left a poisoned source behind
    # and `resolve_type_names` re-raised it outside every rescue: the WHOLE env collapsed to nil. These
    # specs pin the fix: the explicit `.rbs` wins, only the colliding virtual contribution is dropped, and
    # the drop is loud. The `sources`-based mechanics are the rbs 4.x shape.
    let(:tmpdir) { Dir.mktmpdir("rigor-rbs-loader-virtual-collision-spec-") }
    let(:colliding_virtual) do
      ["virtual:rbs-inline:/app/lib/m.rb", "module M\n  FOO: ::Integer\n  def self.only_inline: () -> ::Integer\nend\n"]
    end
    let(:clean_virtual) { ["virtual:rbs-inline:/app/lib/n.rb", "module N\n  BAR: ::Integer\nend\n"] }

    after { FileUtils.rm_rf(tmpdir) }

    before do
      skip "requires the sources-based RBS::Environment (rbs 4.x)" unless RBS::Environment.new.respond_to?(:sources)
      File.write(File.join(tmpdir, "m.rbs"), "module M\n  FOO: ::String\nend\n")
    end

    def build_loader(virtual_rbs)
      loader = described_class.new(signature_paths: [tmpdir], virtual_rbs: virtual_rbs)
      allow(loader).to receive(:warn)
      loader
    end

    it "keeps the env alive and drops only the colliding virtual contribution" do
      loader = build_loader([colliding_virtual, clean_virtual])
      env = loader.send(:env)
      expect(env).not_to be_nil
      expect(env.class_decls.keys.map(&:to_s)).to include("::Integer", "::M", "::N")
      buffer_names = env.buffers.map(&:name)
      expect(buffer_names).not_to include(colliding_virtual.first)
      expect(buffer_names).to include(clean_virtual.first)
    end

    it "lets the explicit sig declaration win for the colliding constant" do
      loader = build_loader([colliding_virtual])
      env = loader.send(:env)
      entry = env.constant_decls.find { |name, _| name.to_s == "::M::FOO" }&.last
      expect(entry).not_to be_nil
      expect(entry.decl.type.to_s).to eq("::String")
    end

    it "reports the dropped file via virtual_rbs_collision_quarantined, not the clean one" do
      loader = build_loader([colliding_virtual, clean_virtual])
      loader.send(:env)
      expect(loader.virtual_rbs_collision_quarantined).to eq([colliding_virtual.first])
    end

    it "does not report a parse-failed virtual entry as a collision" do
      loader = build_loader([["virtual:rbs-inline:/app/lib/broken.rb", "module {{{ not rbs"]])
      expect(loader.send(:env)).not_to be_nil
      expect(loader.virtual_rbs_collision_quarantined).to be_empty
    end

    it "warns once, naming the dropped source file" do
      loader = described_class.new(signature_paths: [tmpdir], virtual_rbs: [colliding_virtual, clean_virtual])
      messages = []
      allow(loader).to receive(:warn) { |msg| messages << msg }
      3.times { loader.send(:env) }
      collision_warnings = messages.select { |m| m.include?("dropped inline-RBS") }
      expect(collision_warnings.size).to eq(1)
      expect(collision_warnings.first).to include(colliding_virtual.first)
      expect(collision_warnings.first).not_to include(clean_virtual.first)
    end
  end
end
