# frozen_string_literal: true

# Integration spec for `plugins/rigor-sorbet/`. Slice 1 of ADR-11: ingests Sorbet `sig { ... }` blocks and
# contributes the parsed return type at every call site.

require "spec_helper"

SORBET_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-sorbet/lib", __dir__)
$LOAD_PATH.unshift(SORBET_PLUGIN_LIB) unless $LOAD_PATH.include?(SORBET_PLUGIN_LIB)
require "rigor-sorbet"

# Stub stamp every demo source uses — `sorbet-runtime` is not loaded in the test environment, so the spec
# defines `sig` / `T::Sig` as no-ops at runtime. The plugin only reads the syntactic shape; the runtime gem is
# independent.
SIG_STUB = <<~RUBY
  module T
    module Sig
      def sig(*, &) = nil
    end
  end
RUBY

RSpec.describe "plugins/rigor-sorbet" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Sorbet }

  # Opt into the shared per-process `Cache::Store`. This file has 48 `run_plugin` examples and the warm-cache
  # savings dominate the cache I/O overhead: spec wall time drops 13.1 s → 3.9 s isolated (≈3× faster). Other
  # plugin specs with fewer examples (typically 4–11) see net-neutral or net-negative parallel-mode behaviour
  # from the shared cache because the cache I/O overhead exceeds the per-call env build savings; the
  # shared-cache default in `plugin_helpers` stays opt-in for that reason.
  let(:default_run_plugin_cache_store) { :shared }

  describe "method signature contributions (slice 1)" do
    it "narrows a chained call's receiver to the sig'd return type" do
      source = <<~RUBY
        #{SIG_STUB}
        class Slug
          extend T::Sig
          sig { returns(Integer) }
          def self.default_length; 32; end
        end
        # `.default_length.even?` resolves only when the catalog
        # contributes `Integer` for the singleton call.
        Slug.default_length.even?
      RUBY

      result = run_plugin(source: source)
      undefined_method = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(undefined_method).to be_empty
    end

    it "contributes the return type for instance-side calls when the receiver is Nominal" do
      source = <<~RUBY
        #{SIG_STUB}
        class Slug
          extend T::Sig
          sig { params(name: String).returns(String) }
          def normalise(name); name; end
        end
        slug = Slug.new
        slug.normalise("Alice").upcase
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "leaves an unrecognised method without a sig untyped, raising no plugin diagnostic" do
      source = <<~RUBY
        #{SIG_STUB}
        class Slug
          extend T::Sig
          sig { returns(Integer) }
          def self.default_length; 32; end
          def self.no_sig_method; "hi"; end
        end
        Slug.no_sig_method
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags).to be_empty
    end
  end

  describe "parse-error diagnostics" do
    it "warns when a sig has no `.returns(...)` or `.void` terminus" do
      source = <<~RUBY
        #{SIG_STUB}
        class Adder
          extend T::Sig
          sig { params(a: Integer, b: Integer) }
          def add(a, b); a + b; end
        end
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags.size).to eq(1)
      expect(diags.first.rule).to eq("parse-error")
      expect(diags.first.severity).to eq(:warning)
      expect(diags.first.message).to include("returns")
    end

    it "warns when a sig is not immediately followed by a method definition" do
      source = <<~RUBY
        #{SIG_STUB}
        class Stranded
          extend T::Sig
          sig { returns(Integer) }
          puts "stranded"
          def call; 1; end
        end
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags.size).to eq(1)
      expect(diags.first.message).to include("immediately followed by")
    end

    it "warns when two sigs are stacked back-to-back" do
      source = <<~RUBY
        #{SIG_STUB}
        class Doubled
          extend T::Sig
          sig { returns(String) }
          sig { returns(Integer) }
          def call; 1; end
        end
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags.size).to eq(1)
      expect(diags.first.message).to include("Two `sig` blocks")
    end
  end

  # A `sig { returns(T) }` above an `attr_reader` / `attr_writer` / `attr_accessor` types the generated
  # accessor — a first-class Sorbet idiom (dependabot-core uses it pervasively). It must NOT warn as a dangling
  # sig, and SHOULD contribute the accessor's type at call sites.
  describe "attribute-accessor sigs" do
    it "does not warn when a sig precedes an attr_reader" do
      source = <<~RUBY
        #{SIG_STUB}
        class User
          extend T::Sig
          sig { returns(String) }
          attr_reader :name
        end
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags.select { |d| d.rule == "parse-error" }).to be_empty
    end

    it "contributes the reader's return type so a typo'd chain is caught" do
      source = <<~RUBY
        # typed: true
        #{SIG_STUB}
        class User
          extend T::Sig
          sig { returns(String) }
          attr_reader :name
        end
        User.new.name.no_such_string_method
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(a_string_matching(/no_such_string_method.*for String/))
    end

    it "types both the reader and writer for attr_accessor" do
      source = <<~RUBY
        # typed: true
        #{SIG_STUB}
        class User
          extend T::Sig
          sig { returns(Integer) }
          attr_accessor :age
        end
        User.new.age.no_such_int_method
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(a_string_matching(/no_such_int_method.*for Integer/))
    end

    it "types every name in a multi-name attr_reader" do
      source = <<~RUBY
        # typed: true
        #{SIG_STUB}
        class Point
          extend T::Sig
          sig { returns(Integer) }
          attr_reader :x, :y
        end
        Point.new.y.no_such_int_method
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(a_string_matching(/no_such_int_method.*for Integer/))
    end
  end

  # A `sig { ... }` above a visibility-wrapped def — `private def foo`, `private_class_method def self.bar`,
  # `module_function def baz` — is a common Ruby/Sorbet idiom (dependabot-core uses `private_class_method def
  # self.x`). It must NOT warn as a dangling sig, and SHOULD type the wrapped method.
  describe "visibility-wrapped def sigs" do
    %w[private public protected private_class_method public_class_method module_function].each do |macro|
      it "does not warn for `#{macro} def`" do
        receiver = macro.include?("class_method") ? "self." : ""
        source = <<~RUBY
          #{SIG_STUB}
          class Worker
            extend T::Sig
            sig { returns(Integer) }
            #{macro} def #{receiver}run; 1; end
          end
        RUBY

        diags = plugin_diagnostics(run_plugin(source: source))
        expect(diags.select { |d| d.rule == "parse-error" }).to be_empty
      end
    end

    it "contributes the wrapped def's return type at the call site" do
      source = <<~RUBY
        # typed: true
        #{SIG_STUB}
        class Registry
          extend T::Sig
          sig { returns(String) }
          public_class_method def self.host; compute_host; end
        end
        Registry.host.no_such_string_method
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(a_string_matching(/no_such_string_method.*for String/))
    end
  end

  describe "type vocabulary translation" do
    it "translates `T.nilable(X)` to a Union with nil so a guarded call type-checks" do
      source = <<~RUBY
        #{SIG_STUB}
        class Box
          extend T::Sig
          sig { returns(T.nilable(Integer)) }
          def self.maybe; nil; end
        end
        # Without the guard, the receiver would be nilable.
        v = Box.maybe
        if v
          v.even?
        end
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "translates `T.untyped` to Dynamic so call-site method-existence is silenced" do
      source = <<~RUBY
        #{SIG_STUB}
        class Mystery
          extend T::Sig
          sig { params(x: T.untyped).returns(T.untyped) }
          def self.thing(x); x; end
        end
        Mystery.thing(some_value).anything_at_all
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    # An enforced `sig { returns(T.untyped) }` is the author's explicit opt-out of return typing. The plugin's
    # `dynamic_return` tier sits ahead of the engine's body-inference tiers in `MethodDispatcher`, so the
    # contributed `Dynamic[top]` wins even when the body would fold to a precise value (`def thing; 1; end` →
    # `Constant[1]`) — per the false-positive discipline, the opt-out outranks the foldable body's precision.
    # The sigil gate still applies: in a sigil-less / `# typed: false` file Sorbet itself ignores the sig, so
    # the engine's fold stands there (see the contrast example).
    describe "`T.untyped` opt-out over a foldable body" do
      it "suppresses engine body-folding for an instance method (explicit receiver)" do
        source = <<~RUBY
          # typed: true
          #{SIG_STUB}
          class Mystery
            extend T::Sig
            sig { returns(T.untyped) }
            def thing; 1; end
          end
          Mystery.new.thing.anything_at_all
        RUBY

        result = run_plugin(source: source)
        expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
      end

      it "suppresses engine body-folding for a singleton method (explicit receiver)" do
        source = <<~RUBY
          # typed: true
          #{SIG_STUB}
          class Mystery
            extend T::Sig
            sig { returns(T.untyped) }
            def self.thing; 1; end
          end
          Mystery.thing.anything_at_all
        RUBY

        result = run_plugin(source: source)
        expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
      end

      it "suppresses engine body-folding for an implicit-self call in an instance method" do
        source = <<~RUBY
          # typed: true
          #{SIG_STUB}
          class Mystery
            extend T::Sig
            sig { returns(T.untyped) }
            def thing; 1; end
            def use
              thing.anything_at_all
            end
          end
          Mystery.new.use
        RUBY

        result = run_plugin(source: source)
        expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
      end

      it "suppresses engine body-folding for an implicit-self call in a singleton method" do
        source = <<~RUBY
          # typed: true
          #{SIG_STUB}
          class Mystery
            extend T::Sig
            sig { returns(T.untyped) }
            def self.thing; 1; end
            def self.use
              thing.anything_at_all
            end
          end
          Mystery.use
        RUBY

        result = run_plugin(source: source)
        expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
      end

      it "lets the engine's fold stand in a sigil-less file (Sorbet would not enforce the sig)" do
        source = <<~RUBY
          #{SIG_STUB}
          class Mystery
            extend T::Sig
            sig { returns(T.untyped) }
            def thing; 1; end
          end
          Mystery.new.thing.anything_at_all
        RUBY

        result = run_plugin(source: source)
        offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
        expect(offenders.map(&:message)).to include(a_string_matching(/anything_at_all/))
      end
    end
  end

  describe "modifier recognition" do
    it "accepts `abstract` / `override` / `overridable` / `final` modifiers without error" do
      source = <<~RUBY
        #{SIG_STUB}
        class Animal
          extend T::Sig
          sig { abstract.returns(String) }
          def name; raise "abstract"; end
          sig(:final) { returns(Integer) }
          def self.legs; 4; end
        end
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags).to be_empty
    end
  end

  describe "widened type vocabulary (ADR-11 slice 3)" do
    it "translates `T::Array[E]` to a generic `Nominal[Array]`" do
      source = <<~RUBY
        #{SIG_STUB}
        class List
          extend T::Sig
          sig { returns(T::Array[Integer]) }
          def self.numbers; [1, 2, 3]; end
        end
        # Calling `.first` on the contributed Array[Integer]
        # would resolve through Rigor's array-shape dispatch.
        # Asserting only that the Sorbet sig parsed without
        # producing a plugin-side error keeps the spec robust
        # against engine-side changes to `Array#first`'s exact
        # carrier shape.
        List.numbers.first
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags).to be_empty
    end

    it "translates `T::Hash[K, V]` to a generic `Nominal[Hash]`" do
      source = <<~RUBY
        #{SIG_STUB}
        class Index
          extend T::Sig
          sig { returns(T::Hash[Symbol, Integer]) }
          def self.counts; {a: 1, b: 2}; end
        end
        Index.counts.size
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    # The fix that unblocks rigor-mangrove on the real Sorbet-sig chain: a non-`T::`-namespaced generic
    # application in sig position now maps to `Nominal[name, type_args]` instead of degrading to `untyped`, so
    # the receiver's generic arguments survive to the call site. Verified directly against the translator — the
    # end-to-end chain (sig → translation → rigor-mangrove unwrap) is exercised by the survey fixture in
    # `docs/notes/20260530-mangrove-library-survey.md`.
    describe "user-defined generic application (non-`T::`)" do
      def translate_sig_type(expr)
        node = Prism.parse(expr).value.statements.body.first
        Rigor::Plugin::Sorbet::TypeTranslator.translate(node)
      end

      it "maps `Foo::Bar[A, B]` to a `Nominal` carrying type_args" do
        type = translate_sig_type("Mangrove::Result::Ok[String, StandardError]")
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Mangrove::Result::Ok")
        expect(type.type_args.map(&:class_name)).to eq(%w[String StandardError])
      end

      it "maps a top-level `Box[Integer]` too" do
        type = translate_sig_type("Box[Integer]")
        expect(type).to be_a(Rigor::Type::Nominal)
        expect(type.class_name).to eq("Box")
        expect(type.type_args.map(&:class_name)).to eq(%w[Integer])
      end

      it "translates nested `T::Array[...]` arguments recursively" do
        type = translate_sig_type("Box[T::Array[String]]")
        expect(type.class_name).to eq("Box")
        inner = type.type_args.first
        expect(inner.class_name).to eq("Array")
        expect(inner.type_args.map(&:class_name)).to eq(%w[String])
      end

      it "still degrades a `[]` call on a non-constant receiver" do
        expect(translate_sig_type("foo[bar]")).not_to be_a(Rigor::Type::Nominal)
      end
    end

    it "translates `T.class_of(C)` to a `Singleton[C]`" do
      source = <<~RUBY
        #{SIG_STUB}
        class Animal
          extend T::Sig
          sig { returns(T.class_of(Animal)) }
          def self.factory; self; end
        end
        # Calling `.new` on the contributed Singleton[Animal]
        # resolves through Rigor's normal class-method dispatch.
        Animal.factory.new
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "translates a tuple literal `[A, B]` in sig position to `Tuple`" do
      source = <<~RUBY
        #{SIG_STUB}
        class Pair
          extend T::Sig
          sig { returns([Integer, String]) }
          def self.first_pair; [1, "two"]; end
        end
        # Tuple shape preserves per-position types; .first
        # picks element 0 (Integer).
        Pair.first_pair.first
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags).to be_empty
    end

    it "translates a hash-shape literal `{a: A, b: B}` in sig position to `HashShape`" do
      source = <<~RUBY
        #{SIG_STUB}
        class Record
          extend T::Sig
          sig { returns({name: String, age: Integer}) }
          def self.template; {name: "Alice", age: 30}; end
        end
        Record.template.size
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags).to be_empty
    end

    # The positive half of the example above, added by #673. `translate_shape` collected an ARRAY of pairs
    # and handed it to `hash_shape_of`, which validates its argument is a Hash and raises `ArgumentError`
    # — so this module's documented "never nil; unrecognised forms degrade" contract was really "this one
    # form raises", and every sig-declared shape was lost. Asserted on the translator directly because the
    # run-level example above cannot see it: a shape that never arrives produces no diagnostics at all,
    # and Rigor's own inference of the literal body answers the same type either way.
    it "builds the HashShape rather than raising on the array of pairs it collects" do
      node = Prism.parse("{name: String, age: Integer}").value.statements.body.first
      translated = Rigor::Plugin::Sorbet::TypeTranslator.translate(node)

      expect(translated).to be_a(Rigor::Type::HashShape)
      expect(translated.describe(:short)).to eq("{ name: String, age: Integer }")
    end

    it "leaves unsupported `T.proc` / `T.attached_class` constructs as Dynamic[top] without crashing" do
      source = <<~RUBY
        #{SIG_STUB}
        class Maker
          extend T::Sig
          sig { returns(T.proc.params(x: Integer).returns(String)) }
          def self.fn; ->(x) { x.to_s }; end
          sig { returns(T.attached_class) }
          def self.make; new; end
        end
        # The two unsupported constructs degrade silently;
        # neither crashes the plugin nor emits a plugin
        # diagnostic.
        Maker.fn
        Maker.make
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags).to be_empty
    end
  end

  # Issue #1097 — the annotation DSL EXPRESSIONS themselves type: `sig` resolves through
  # `extend T::Sig` (manifest `rbs_complete_extends:`), the sig block's self binds to
  # `T::Private::Methods::DeclBuilder` (`block_as_methods:`), the `T::X[...]` constructors and
  # `T.*` functions answer through the bundled `sig/sorbet.rbs`, and the `T::Struct`/`T::Enum`
  # families carry their macros through the `rbs_complete_ancestors` superclass bridge.
  describe "annotation DSL surface (issue #1097)" do
    it "resolves `sig` through `extend T::Sig` so a chained call reports NilClass" do
      source = <<~RUBY
        class Worker
          extend T::Sig
          result = sig { returns(Integer) }
          result.upcase
          def run; 1; end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      # `sig` typed to nil (declare_sig's real return) — `result.upcase` proves the call site is
      # not `Dynamic[top]`, which would silence the check entirely.
      expect(offenders.map(&:message)).to include(a_string_matching(/upcase.*for nil/))
    end

    it "does not bind DeclBuilder when the class overrides `sig` with `def self.sig`" do
      # A class's own singleton method precedes every `extend` in the singleton ancestry, so
      # F's `sig` runs and `class_exec`s the block on F — DeclBuilder is not the block's self.
      source = <<~RUBY
        class F
          extend T::Sig
          def self.sig(&blk)
            class_exec(&blk)
          end
          sig { params(x: Integer).bogus_terminus }
          def m(x); end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).not_to include(
        a_string_matching(/DeclBuilder/)
      )
    end

    it "still binds DeclBuilder for a sig call deferred inside a method body when T::Sig owns it" do
      source = <<~RUBY
        class F
          extend T::Sig
          def self.m
            sig { params(x: Integer).bogus_terminus }
          end
          def self.target = m
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(a_string_matching(/bogus_terminus.*DeclBuilder/))
    end

    it "does not bind DeclBuilder for a deferred sig call when `def self.sig` follows `m`" do
      # `sig` inside `def self.m` runs when `m` is called — after the class body finished installing
      # `F.sig` — so the later `def self.sig` owns the call even though it lexically follows `m`.
      source = <<~RUBY
        class F
          extend T::Sig
          def self.m
            sig { params(x: Integer).bogus_terminus }
          end
          def self.sig(&blk)
            class_exec(&blk)
          end
          def self.target = m
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).not_to include(
        a_string_matching(/DeclBuilder/)
      )
    end

    it "still binds DeclBuilder when `def self.sig` follows the call on the SAME line" do
      # Statement order within a line is execution order — `sig {}; def self.sig` resolves through
      # `T::Sig` at runtime. Ordering by def-site line alone would treat the def as shadowing.
      source = <<~RUBY
        class F
          extend T::Sig
          sig { params(x: Integer).bogus_terminus }; def self.sig(&blk) = class_exec(&blk)
          def m(x); end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(
        a_string_matching(/bogus_terminus.*DeclBuilder/)
      )
    end

    it "still binds DeclBuilder when `def self.sig` is defined AFTER the sig call" do
      # `def` takes effect at execution: a `sig { ... }` call that precedes the later override
      # still resolves through `extend T::Sig` at runtime, so the block binding must not be
      # suppressed by a def the discovery table already knows about.
      source = <<~RUBY
        class F
          extend T::Sig
          sig { params(x: Integer).bogus_terminus }
          def m(x); end
          def self.sig(&blk)
            class_exec(&blk)
          end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(
        a_string_matching(/bogus_terminus.*DeclBuilder/)
      )
    end

    it "still resolves `sig` when the class is also declared in project RBS" do
      # `class F` in `sig/` makes F RBS-known, but its RBS need not repeat the source
      # `extend T::Sig` — the bridge still honours the source edge.
      source = <<~RUBY
        class F
          extend T::Sig
          sig { params(x: Integer).bogus_terminus }
          def m(x); end
        end
      RUBY
      sig = "class F\n  def unrelated: () -> void\nend\n"

      result = run_plugin(source: source, files: { "sig/f.rbs" => sig },
                          signature_paths: ["sig"])
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(
        a_string_matching(/bogus_terminus.*DeclBuilder/)
      )
    end

    it "binds the sig block's self to DeclBuilder so unknown builder verbs still warn" do
      source = <<~RUBY
        class Worker
          extend T::Sig
          sig { params(x: Integer).bogus_terminus }
          def run(x); x; end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(
        a_string_matching(/bogus_terminus.*DeclBuilder/)
      )
    end

    it "types `params`/`returns`/`void`/`checked`/`override`/`abstract` builder chains" do
      source = <<~RUBY
        class Worker
          extend T::Sig
          sig { abstract.params(x: Integer).returns(String) }
          def run(x); x.to_s; end
          sig { override.void.checked(:never) }
          def stop; nil; end
          sig { overridable.returns(Integer) }
          def retries; 0; end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders).to be_empty
    end

    it "resolves `T::Sig::WithoutRuntime.sig` as a module-singleton call" do
      source = <<~RUBY
        class Worker
          T::Sig::WithoutRuntime.sig { params(x: Integer).bogus_terminus }
          def run(x); x; end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(
        a_string_matching(/bogus_terminus.*DeclBuilder/)
      )
    end

    it "types the `T::Array[...]` / `T::Hash[...]` constructors" do
      source = <<~RUBY
        T::Array[Integer].bogus_constructor_call
        T::Hash[Symbol, Integer].bogus_constructor_call
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(a_string_matching(/bogus_constructor_call.*TypedArray/))
      expect(offenders.map(&:message)).to include(a_string_matching(/bogus_constructor_call.*TypedHash/))
    end

    it "resolves `T::Helpers` / `T::Generic` macros through `extend`" do
      source = <<~RUBY
        class Base
          extend T::Helpers
          extend T::Generic
          abstract!
          interface!
          Elem = type_member
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders).to be_empty
    end

    it "resolves `prop` / `const` on a `T::Struct` subclass" do
      source = <<~RUBY
        class Doc < T::Struct
          prop :name, String
          const :ttl, Integer
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders).to be_empty
    end

    it "binds the sig block to DeclBuilder on a `T::ImmutableStruct` subclass (RBS-side extend edge)" do
      # `T::ImmutableStruct` is the only `T::Struct`-family class that `extend`s `T::Sig` at
      # runtime (`struct.rb`) — the match comes from that bundled-RBS edge, surfaced via
      # `singleton_extended_modules`.
      source = <<~RUBY
        class Doc < T::ImmutableStruct
          sig { params(x: Integer).bogus_terminus }
          def run(x); x; end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(
        a_string_matching(/bogus_terminus.*DeclBuilder/)
      )
    end

    it "does not bind `sig` on a plain `T::Struct` subclass (runtime has no extend T::Sig)" do
      # `T::InexactStruct`/`T::Struct` carry no `extend T::Sig` — `sig` inside the body raises at
      # runtime, so the block must NOT bind DeclBuilder (an invented edge would silently resolve
      # a call that cannot run).
      source = <<~RUBY
        class Doc < T::Struct
          sig { params(x: Integer).bogus_terminus }
          def run(x); x; end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).not_to include(
        a_string_matching(/DeclBuilder/)
      )
    end

    it "continues past an allow-listed extend module that lacks the method" do
      # `extend T::Helpers` then `extend T::Generic`: `type_member` lives on T::Generic. The
      # bridge must search every extended module (not stop at the first allow-listed one), so the
      # call resolves to `T::Types::TypeMember` and `bogus` reports against it.
      source = <<~RUBY
        class Node
          extend T::Helpers
          extend T::Generic
          type_member.bogus
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(
        a_string_matching(/bogus.*TypeMember/)
      )
    end

    it "does not bind DeclBuilder when a nearer extended module defines `sig`" do
      # `extend T::Sig; extend CustomSig` — the later extend is nearer, so `CustomSig#sig`
      # answers the call at runtime and picks the block's self. Narrowing to DeclBuilder would
      # misread a perfectly ordinary custom DSL method.
      source = <<~RUBY
        module CustomSig
          def sig(&blk)
            nil
          end
        end
        class F
          extend T::Sig
          extend CustomSig
          sig { params(x: Integer).bogus_terminus }
          def m(x); end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).not_to include(
        a_string_matching(/DeclBuilder/)
      )
    end

    it "still binds DeclBuilder when a nearer extended module does not define `sig`" do
      source = <<~RUBY
        module Plain
          def helper
            :ok
          end
        end
        class F
          extend T::Sig
          extend Plain
          sig { params(x: Integer).bogus_terminus }
          def m(x); end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(
        a_string_matching(/bogus_terminus.*DeclBuilder/)
      )
    end

    it "does not fall through to the global `T::Sig` when a project module owns the extend edge" do
      # `Outer::T::Sig` is a project-defined module — `extend T::Sig` inside `Outer` binds it at
      # runtime, so `sig` must NOT resolve through the plugin's global `T::Sig` declaration.
      source = <<~RUBY
        module Outer
          module T
            module Sig
            end
          end
          class F
            extend T::Sig
            sig { bogus_terminus }
          end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).not_to include(
        a_string_matching(/DeclBuilder/)
      )
    end

    it "keeps a zero-arg `prop` silent on a `T::Struct` subclass (signature-reading rules stay off)" do
      # The superclass bridge is a signature LOOKUP only — the subclass stays outside RBS, so
      # `call.wrong-arity` does not fire on its calls (the ADR-43 contract; see plugin.md). This
      # example pins that deliberately-lenient reading for the Struct family.
      source = <<~RUBY
        class Doc < T::Struct
          prop
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select do |d|
        %w[call.undefined-method call.wrong-arity].include?(d.rule)
      end
      expect(offenders).to be_empty
    end

    it "resolves `enums` and the `new` calls inside its block on a `T::Enum` subclass" do
      source = <<~RUBY
        class Suit < T::Enum
          enums do
            Spades = new(true)
            Hearts = new(false)
          end
        end
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders).to be_empty
    end

    it "accepts both `T.type_alias` forms — positional type and block" do
      # Runtime signature is `type_alias(type=nil, &blk)` — the positional form is the legacy
      # migration path and must not report `call.wrong-arity`.
      source = <<~RUBY
        A = T.type_alias(String)
        B = T.type_alias { Integer }
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select do |d|
        %w[call.wrong-arity call.undefined-method].include?(d.rule)
      end
      expect(offenders).to be_empty
    end

    it "adopts the asserted type for `T.let` / `T.cast` (recognizer path stays authoritative)" do
      source = <<~RUBY
        # typed: true
        x = T.let("hi", String)
        x.no_such_string_method
        y = T.cast(1, Integer)
        y.no_such_int_method
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders.map(&:message)).to include(a_string_matching(/no_such_string_method.*for String/))
      expect(offenders.map(&:message)).to include(a_string_matching(/no_such_int_method.*for Integer/))
    end

    it "keeps an undeclared `T.*` call opaque instead of firing undefined-method" do
      source = <<~RUBY
        T.this_does_not_exist(1)
      RUBY

      result = run_plugin(source: source)
      offenders = result.diagnostics.select { |d| d.rule == "call.undefined-method" }
      expect(offenders).to be_empty
    end
  end

  describe "mixin chain resolution (ADR-11 slice 8)" do
    # Tapioca's standard DSL RBI shape. Slice 8 lifts sigs declared on a `Generated*` module up to the host
    # class via the recorded `include` / `extend` chain.

    let(:tapioca_include_rbi) do
      <<~RBI
        # typed: true
        class Post
          include GeneratedAttributeMethods
          module GeneratedAttributeMethods
            extend T::Sig
            sig { returns(String) }
            def body; end
          end
        end
      RBI
    end

    let(:tapioca_extend_rbi) do
      <<~RBI
        # typed: true
        class Post
          extend GeneratedClassMethods
          module GeneratedClassMethods
            extend T::Sig
            sig { params(id: Integer).returns(String) }
            def find(id); end
          end
        end
      RBI
    end

    let(:transitive_rbi) do
      <<~RBI
        # typed: true
        class Post
          include AttributeMixin
        end
        module AttributeMixin
          include InnerMixin
        end
        module InnerMixin
          extend T::Sig
          sig { returns(String) }
          def body; end
        end
      RBI
    end

    it "resolves `post.body` through the `include`d Generated module's sig" do
      result = run_plugin(
        source: "#{SIG_STUB}post = Post.new; post.body.upcase\n",
        files: {
          "app/models/post.rb" => "class Post; end\n",
          "sorbet/rbi/dsl/post.rbi" => tapioca_include_rbi
        },
        paths: ["demo.rb", "app/models/post.rb"]
      )
      # Plugin contributed `String` for `post.body`, so the chained `.upcase` resolves through String's RBS.
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "resolves `Post.find` through the `extend`ed Generated module's sig" do
      result = run_plugin(
        source: "#{SIG_STUB}Post.find(1).upcase\n",
        files: {
          "app/models/post.rb" => "class Post; end\n",
          "sorbet/rbi/dsl/post.rbi" => tapioca_extend_rbi
        },
        paths: ["demo.rb", "app/models/post.rb"]
      )
      # `extend M` lifts M's instance methods to singleton methods on the extending class. `Post.find` resolves
      # via `GeneratedClassMethods#find`, returning `String`.
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "walks transitive `include` chains across modules" do
      result = run_plugin(
        source: "#{SIG_STUB}post = Post.new; post.body.upcase\n",
        files: {
          "app/models/post.rb" => "class Post; end\n",
          "sorbet/rbi/dsl/post.rbi" => transitive_rbi
        },
        paths: ["demo.rb", "app/models/post.rb"]
      )
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "leaves `post.bogus` untouched when no module in the chain declares it" do
      result = run_plugin(
        source: "#{SIG_STUB}post = Post.new; post.bogus\n",
        files: {
          "app/models/post.rb" => "class Post; end\n",
          "sorbet/rbi/dsl/post.rbi" => tapioca_include_rbi
        },
        paths: ["demo.rb", "app/models/post.rb"]
      )
      # `bogus` isn't in any chained module — the plugin contributes nothing and no spurious sig lands on the
      # method. (`call.undefined-method` is silenced separately by Post being a non-RBS-known class.)
      expect(plugin_diagnostics(result)).to be_empty
    end
  end

  describe "RBI tree walking (ADR-11 slice 4)" do
    let(:gem_rbi) do
      <<~RBI
        # typed: true
        module Gem
          class Connection
            extend T::Sig
            sig { returns(Gem::Connection) }
            def self.open; new; end
            sig { returns(String) }
            def handshake; "ok"; end
          end
        end
      RBI
    end

    let(:mixed_rbi) do
      # Adjacent malformed (no terminus) + well-formed sigs. Slice 4 contract: malformed silently degrades; the
      # well-formed sig in the same file is still recorded.
      <<~RBI
        # typed: true
        module Gem
          class Mixed
            extend T::Sig
            sig { params(x: Integer) }
            def malformed(x); x; end
            sig { returns(String) }
            def well_formed; "ok"; end
          end
        end
      RBI
    end

    it "loads sigs from `sorbet/rbi/**/*.rbi` and contributes them at call sites" do
      result = run_plugin(
        source: "#{SIG_STUB}Gem::Connection.open.handshake\n",
        files: { "sorbet/rbi/gems/gem.rbi" => gem_rbi }
      )
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "tolerates malformed sigs in RBI files alongside well-formed ones in the same file" do
      result = run_plugin(
        source: "#{SIG_STUB}Gem::Mixed.new.well_formed.upcase\n",
        files: { "sorbet/rbi/shims/mixed.rbi" => mixed_rbi }
      )
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "respects an empty `rbi_paths` to opt out of RBI loading entirely" do
      # With rbi_paths: [] the plugin doesn't walk the RBI; the RBI's sig is therefore never recorded. We only
      # assert that the opt-out doesn't crash the plugin.
      result = run_plugin(
        source: "#{SIG_STUB}Gem::Connection.open\n",
        files: { "sorbet/rbi/gems/gem.rbi" => gem_rbi },
        plugin_entry: { "gem" => "rigor-sorbet", "config" => { "rbi_paths" => [] } }
      )
      expect(plugin_diagnostics(result)).to be_empty
    end
  end

  describe "sigil honoring (ADR-11 slice 5)" do
    it "skips a file marked `# typed: ignore` during catalog harvest" do
      # The RBI declares Slug.default_length, but the file is `# typed: ignore` so rigor-sorbet must not record
      # the sig. Without the contribution, the chained `.even?` call on the receiver wouldn't carry an Integer
      # type; we assert the silent-degradation outcome (no plugin diagnostic about the missing contribution,
      # no crash).
      ignored_rbi = <<~RBI
        # typed: ignore
        class Slug
          extend T::Sig
          sig { returns(Integer) }
          def self.default_length; 32; end
        end
      RBI

      result = run_plugin(
        source: SIG_STUB,
        files: { "sorbet/rbi/shims/slug.rbi" => ignored_rbi }
      )
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "skips `# typed: false` sigs when enforce_sigil is on (default)" do
      # Sorbet itself doesn't enforce types at `# typed: false` — sigs are parsed but not used to surface
      # errors. Rigor mirrors that under the default `enforce_sigil: true`: the file's catalog entry is not
      # recorded, so the chained `.bit_length` call falls back to RBS / nominal dispatch as if the sig wasn't there.
      typed_false_rbi = <<~RBI
        # typed: false
        class Greeter
          extend T::Sig
          sig { returns(Integer) }
          def self.count; 1; end
        end
      RBI

      # Without the sig contribution, `Greeter.count.bit_length` has no inferred Integer return at the chained
      # call — we ASSERT no plugin recognised the sig (the diagnostic-trace check stays empty), not that the
      # downstream call resolves.
      result = run_plugin(
        source: "#{SIG_STUB}Greeter.count\n",
        files: { "sorbet/rbi/shims/greeter.rbi" => typed_false_rbi }
      )
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "skips sigil-less files under enforce_sigil (defaults to :false)" do
      no_sigil_rbi = <<~RBI
        class Bareword
          extend T::Sig
          sig { returns(Integer) }
          def self.always; 1; end
        end
      RBI

      result = run_plugin(
        source: "#{SIG_STUB}Bareword.always\n",
        files: { "sorbet/rbi/shims/bareword.rbi" => no_sigil_rbi }
      )
      expect(plugin_diagnostics(result)).to be_empty
    end

    it "records sigs from `# typed: true`+ files under enforce_sigil (default)" do
      typed_true_rbi = <<~RBI
        # typed: true
        class Strict
          extend T::Sig
          sig { returns(Integer) }
          def self.value; 7; end
        end
      RBI

      result = run_plugin(
        source: "#{SIG_STUB}Strict.value.even?\n",
        files: { "sorbet/rbi/shims/strict.rbi" => typed_true_rbi }
      )
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "restores pre-gate behaviour when enforce_sigil: false (records every sig)" do
      typed_false_rbi = <<~RBI
        # typed: false
        class Lenient
          extend T::Sig
          sig { returns(Integer) }
          def self.value; 7; end
        end
      RBI

      # Override default `enforce_sigil: true` via the plugin entry's config block. Now the `# typed: false`
      # file's sig DOES contribute, so the chained `.even?` resolves.
      result = run_plugin(
        source: "#{SIG_STUB}Lenient.value.even?\n",
        files: { "sorbet/rbi/shims/lenient.rbi" => typed_false_rbi },
        plugin_entry: { "gem" => "rigor-sorbet", "config" => { "enforce_sigil" => false } }
      )
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end
  end

  describe "per-call-site assertion gating (ADR-11 deferred follow-up)" do
    # Sorbet itself only enforces type errors at `# typed: true` and above. The harvest-time `enforce_sigil`
    # gate already mirrors that for cataloged sigs; this gate extends the same discipline to caller-side
    # assertion recognisers (`T.let` / `T.cast` / `T.must` / `T.bind` / `T.assert_type!` / `T.reveal_type` /
    # `T.unsafe`).
    #
    # Behaviour observability: the suppressed `T.reveal_type` never records a `record_reveal_type_call`, so
    # `diagnostics_for_file` emits no `reveal-type` :info diagnostic. We use that as the smoke signal: the
    # diagnostic IS / IS-NOT present.

    it "fires assertion recognisers at `# typed: true` files (default enforce_sigil)" do
      source = <<~RUBY
        # typed: true
        #{SIG_STUB}
        n = T.let(3, Integer)
        T.reveal_type(n)
      RUBY

      diag = run_plugin(source: source).diagnostics.find { |d| d.rule == "reveal-type" }
      expect(diag).not_to be_nil
    end

    it "suppresses assertion recognisers at `# typed: false` files (default enforce_sigil)" do
      source = <<~RUBY
        # typed: false
        #{SIG_STUB}
        n = T.let(3, Integer)
        T.reveal_type(n)
      RUBY

      diag = run_plugin(source: source).diagnostics.find { |d| d.rule == "reveal-type" }
      expect(diag).to be_nil
    end

    it "suppresses assertion recognisers in sigil-less files (treated as `:false`)" do
      source = <<~RUBY
        #{SIG_STUB}
        n = T.let(3, Integer)
        T.reveal_type(n)
      RUBY

      diag = run_plugin(source: source).diagnostics.find { |d| d.rule == "reveal-type" }
      expect(diag).to be_nil
    end

    it "fires assertion recognisers regardless of sigil when enforce_sigil: false" do
      source = <<~RUBY
        # typed: false
        #{SIG_STUB}
        n = T.let(3, Integer)
        T.reveal_type(n)
      RUBY

      diag = run_plugin(
        source: source,
        plugin_entry: { "gem" => "rigor-sorbet", "config" => { "enforce_sigil" => false } }
      ).diagnostics.find { |d| d.rule == "reveal-type" }
      expect(diag).not_to be_nil
    end
  end

  describe "T.absurd exhaustiveness (ADR-11 slice 6)" do
    # Slice 6 relies on Rigor's existing flow-sensitive narrowing to decide whether the discriminant has been
    # narrowed to `bot` at the absurd call. `is_a?` narrowing is precise; `case`/`when` over symbols isn't (as
    # of v0.1.3 — covered by an open-question in ADR-11). Tests use the precise pattern so they exercise the
    # plugin's logic, not the engine's narrowing strength.

    it "stays silent when the discriminant narrows to bot via `is_a?`" do
      # `Constant<1>` minus `Integer` collapses to `bot`, so the else branch is unreachable and `T.absurd` is
      # correct.
      source = <<~RUBY
        #{SIG_STUB}
        val = 1
        if val.is_a?(Integer)
          puts(val)
        else
          T.absurd(val)
        end
      RUBY
      reachable = plugin_diagnostics(run_plugin(source: source)).select { |d| d.rule == "absurd-reachable" }
      expect(reachable).to be_empty
    end

    it "emits `absurd-reachable` when the discriminant remains reachable" do
      # `Integer` minus `String` is `Integer`, not `bot`, so the else branch IS reachable — `T.absurd` is wrong.
      source = <<~RUBY
        #{SIG_STUB}
        val = T.let(1, Integer)
        if val.is_a?(String)
          puts(val)
        else
          T.absurd(val)
        end
      RUBY
      reachable = plugin_diagnostics(run_plugin(source: source)).select { |d| d.rule == "absurd-reachable" }
      expect(reachable.size).to eq(1)
      expect(reachable.first.message).to include("did not narrow")
    end

    it "stays silent when the engine determines the entire else branch is dead before typing" do
      # `nil.nil?` is statically `true`, so the engine prunes the else branch entirely — the dynamic_return
      # hook is never called for the `T.absurd` and our recorded set stays empty.
      source = <<~RUBY
        #{SIG_STUB}
        val = nil
        if val.nil?
          puts("nil")
        else
          T.absurd(val)
        end
      RUBY
      reachable = plugin_diagnostics(run_plugin(source: source)).select { |d| d.rule == "absurd-reachable" }
      expect(reachable).to be_empty
    end
  end

  describe "type assertion recognition (ADR-11 slice 2)" do
    it "narrows `T.let(expr, T)` to the asserted type" do
      source = <<~RUBY
        #{SIG_STUB}
        # The literal `0` would normally infer to `Constant<0>`,
        # but `T.let(0, Integer)` widens to `Integer` so the
        # variable can hold any Integer in subsequent loops /
        # branches without "type changed" errors.
        x = T.let(0, Integer)
        x.even?
        x.bit_length
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "narrows `T.cast(expr, T)` the same way as T.let for static analysis" do
      source = <<~RUBY
        #{SIG_STUB}
        # Receiver type is opaque (`Object`); the cast asserts
        # `String` and lets the chained `.upcase` resolve.
        any_value = Object.new
        T.cast(any_value, String).upcase
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "narrows `T.must(expr)` to the inner type minus nil" do
      source = <<~RUBY
        #{SIG_STUB}
        # `T.let(nil, T.nilable(Integer))` is `Integer | nil`;
        # `T.must` strips the nil so `.even?` resolves on
        # `Integer` without a possibly-nil-receiver complaint.
        maybe = T.let(nil, T.nilable(Integer))
        T.must(maybe).even?
      RUBY

      result = run_plugin(source: source)
      undefined_or_nil = result.diagnostics.select do |d|
        %w[call.undefined-method call.possible-nil-receiver].include?(d.rule)
      end
      expect(undefined_or_nil).to be_empty
    end

    it "treats `T.unsafe(expr)` as `Dynamic[top]` so any chained call is silenced" do
      source = <<~RUBY
        #{SIG_STUB}
        class Mystery
          extend T::Sig
          sig { returns(Integer) }
          def self.from_int; 1; end
        end
        # T.unsafe forces the result back to untyped, which
        # silences `call.undefined-method` for any subsequent
        # call against unknown methods on the value.
        T.unsafe(Mystery.from_int).never_defined_anywhere
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "leaves a non-Sorbet `T.let`-shaped call alone (different receiver)" do
      # If the user's project defines its own `T` constant that is NOT Sorbet's, the plugin should not
      # interfere. The recognizer keys on receiver name `T`; a renamed constant doesn't match and the call
      # falls through.
      source = <<~RUBY
        #{SIG_STUB}
        module NotSorbet
          def self.let(expr, type) = expr
        end
        NotSorbet.let("hello", String)
      RUBY

      diags = plugin_diagnostics(run_plugin(source: source))
      expect(diags).to be_empty
    end
  end

  describe "T.must_because + T.reveal_type (ADR-11 light follow-up)" do
    it "narrows `T.must_because(expr, \"reason\")` identically to T.must" do
      source = <<~RUBY
        #{SIG_STUB}
        # Same shape as the slice-2 T.must test, just with the
        # second-argument string explanation Sorbet supports.
        maybe = T.let(nil, T.nilable(Integer))
        T.must_because(maybe, "outer caller guarantees non-nil").even?
      RUBY

      result = run_plugin(source: source)
      undefined_or_nil = result.diagnostics.select do |d|
        %w[call.undefined-method call.possible-nil-receiver].include?(d.rule)
      end
      expect(undefined_or_nil).to be_empty
    end

    it "passes `T.reveal_type(expr)` through unchanged for chained call resolution" do
      source = <<~RUBY
        #{SIG_STUB}
        # T.reveal_type returns expr unchanged at runtime; the
        # static contribution preserves the inferred type so the
        # `.even?` chained call still resolves on Integer.
        n = T.let(3, Integer)
        T.reveal_type(n).even?
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "emits a `plugin.sorbet.reveal-type` :info diagnostic naming the inferred type" do
      # Per-call-site assertion gating (ADR-11 deferred follow-up): the `T.reveal_type` recogniser only fires
      # at files Sorbet itself would enforce. The sigil is required so the gate stays open.
      source = <<~RUBY
        # typed: true
        #{SIG_STUB}
        n = T.let(3, Integer)
        T.reveal_type(n)
      RUBY

      diag = run_plugin(source: source).diagnostics.find { |d| d.rule == "reveal-type" }

      expect(diag).not_to be_nil
      expect(diag.severity).to eq(:info)
      expect(diag.message).to include("T.reveal_type")
      expect(diag.message).to include("Integer")
    end
  end

  describe "T.assert_type! (T.bind / T.assert_type! priority slice 1)" do
    it "narrows the call's return to the asserted type (T.cast-compatible)" do
      source = <<~RUBY
        #{SIG_STUB}
        # T.assert_type! returns the asserted type so chained
        # calls resolve through it (same return-type contract
        # as T.cast).
        any_value = Object.new
        T.assert_type!(any_value, String).upcase
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "emits `plugin.sorbet.assert-type-mismatch` when the inferred type is provably incompatible" do
      # Per-call-site assertion gating (ADR-11 deferred follow-up): the `T.assert_type!` mismatch check only
      # fires at files Sorbet itself would enforce.
      source = <<~RUBY
        # typed: true
        #{SIG_STUB}
        # `s` is provably `Constant<"hello">`; asserting Integer
        # is definitely incompatible — the gradual-acceptance
        # check returns :no, so the plugin records a mismatch.
        s = "hello"
        T.assert_type!(s, Integer)
      RUBY

      diag = run_plugin(source: source).diagnostics.find { |d| d.rule == "assert-type-mismatch" }

      expect(diag).not_to be_nil
      expect(diag.severity).to eq(:error)
      expect(diag.message).to include("Integer")
    end

    it "stays silent when the inferred type is Dynamic (gradual consistency)" do
      source = <<~RUBY
        #{SIG_STUB}
        # T.unsafe widens the value back to Dynamic[top]; under
        # gradual consistency, the assertion is silenced.
        opaque = T.unsafe(Object.new)
        T.assert_type!(opaque, Integer)
      RUBY

      diags = run_plugin(source: source).diagnostics.select { |d| d.rule == "assert-type-mismatch" }
      expect(diags).to be_empty
    end

    it "stays silent when the inferred type is :maybe-compatible (trust the user)" do
      source = <<~RUBY
        #{SIG_STUB}
        # `n` is Integer (literal-folded). Asserting Integer is
        # definitely compatible (:yes) — no diagnostic.
        n = T.let(3, Integer)
        T.assert_type!(n, Integer)
      RUBY

      diags = run_plugin(source: source).diagnostics.select { |d| d.rule == "assert-type-mismatch" }
      expect(diags).to be_empty
    end
  end

  describe "T.bind (T.bind / T.assert_type! priority slice 3)" do
    it "narrows self in a block via post_return_facts(target_kind: :self)" do
      # Without T.bind, an implicit-self call to `upcase` at top level would emit `call.undefined-method`
      # (default self is Object). After `T.bind(self, String)`, the engine narrows self to String, and
      # `upcase` resolves on the narrowed self via the standard String method dispatch.
      source = <<~RUBY
        #{SIG_STUB}
        T.bind(self, String)
        upcase
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "rejects non-self first argument silently (matches Sorbet's contract)" do
      source = <<~RUBY
        #{SIG_STUB}
        # `T.bind(other, String)` is invalid Sorbet syntax —
        # bind is self-only. The recogniser declines, the call
        # falls through to RBS (no sig), and Rigor stays silent.
        other = Object.new
        T.bind(other, String)
      RUBY

      diags = run_plugin(source: source).diagnostics.select do |d|
        d.source_family == "plugin.sorbet"
      end
      expect(diags).to be_empty
    end
  end
end
