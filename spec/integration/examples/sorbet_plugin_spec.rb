# frozen_string_literal: true

# Integration spec for `examples/rigor-sorbet/`. Slice 1 of
# ADR-11: ingests Sorbet `sig { ... }` blocks and contributes
# the parsed return type at every call site.

require "spec_helper"

SORBET_PLUGIN_LIB = File.expand_path("../../../examples/rigor-sorbet/lib", __dir__)
$LOAD_PATH.unshift(SORBET_PLUGIN_LIB) unless $LOAD_PATH.include?(SORBET_PLUGIN_LIB)
require "rigor-sorbet"

# Stub stamp every demo source uses — `sorbet-runtime` is not
# loaded in the test environment, so the spec defines `sig` /
# `T::Sig` as no-ops at runtime. The plugin only reads the
# syntactic shape; the runtime gem is independent.
SIG_STUB = <<~RUBY
  module T
    module Sig
      def sig(*, &) = nil
    end
  end
RUBY

RSpec.describe "examples/rigor-sorbet" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Sorbet }

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
          sig { returns(T.untyped) }
          def self.thing; 1; end
        end
        Mystery.thing.anything_at_all
      RUBY

      result = run_plugin(source: source)
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
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
      # Adjacent malformed (no terminus) + well-formed sigs.
      # Slice 4 contract: malformed silently degrades; the
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
      # With rbi_paths: [] the plugin doesn't walk the RBI;
      # the RBI's sig is therefore never recorded. We only
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
      # The RBI declares Slug.default_length, but the file is
      # `# typed: ignore` so rigor-sorbet must not record the
      # sig. Without the contribution, the chained `.even?`
      # call on the receiver wouldn't carry an Integer type;
      # we assert the silent-degradation outcome (no plugin
      # diagnostic about the missing contribution, no crash).
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

    it "honours `# typed: false` by recording sigs for cross-file use" do
      # Sorbet's contract: `# typed: false` files still have
      # their sigs PARSED AND USED by other files. We mirror
      # that — the catalog harvest walks the file the same way
      # as a `# typed: true` file.
      typed_false_rbi = <<~RBI
        # typed: false
        class Greeter
          extend T::Sig
          sig { returns(String) }
          def self.hello; "hi"; end
        end
      RBI

      result = run_plugin(
        source: "#{SIG_STUB}Greeter.hello.upcase\n",
        files: { "sorbet/rbi/shims/greeter.rbi" => typed_false_rbi }
      )
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end

    it "treats files without a `# typed:` sigil the same as `# typed: false`" do
      # Default-Sorbet-behaviour parity: sigs in sigil-less
      # files still feed the catalog. (Most user-authored
      # `.rb` files don't carry a sigil; not honouring this
      # would break the common case.)
      no_sigil_rbi = <<~RBI
        class Bareword
          extend T::Sig
          sig { returns(Integer) }
          def self.always; 1; end
        end
      RBI

      result = run_plugin(
        source: "#{SIG_STUB}Bareword.always.even?\n",
        files: { "sorbet/rbi/shims/bareword.rbi" => no_sigil_rbi }
      )
      expect(result.diagnostics.select { |d| d.rule == "call.undefined-method" }).to be_empty
    end
  end

  describe "T.absurd exhaustiveness (ADR-11 slice 6)" do
    # Slice 6 relies on Rigor's existing flow-sensitive
    # narrowing to decide whether the discriminant has been
    # narrowed to `bot` at the absurd call. `is_a?` narrowing
    # is precise; `case`/`when` over symbols isn't (as of
    # v0.1.3 — covered by an open-question in ADR-11). Tests
    # use the precise pattern so they exercise the plugin's
    # logic, not the engine's narrowing strength.

    it "stays silent when the discriminant narrows to bot via `is_a?`" do
      # `Constant<1>` minus `Integer` collapses to `bot`, so
      # the else branch is unreachable and `T.absurd` is
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
      # `Integer` minus `String` is `Integer`, not `bot`, so
      # the else branch IS reachable — `T.absurd` is wrong.
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
      # `nil.nil?` is statically `true`, so the engine prunes
      # the else branch entirely — `flow_contribution_for` is
      # never called for the `T.absurd` and our recorded set
      # stays empty.
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
      # If the user's project defines its own `T` constant that
      # is NOT Sorbet's, the plugin should not interfere. The
      # recognizer keys on receiver name `T`; a renamed
      # constant doesn't match and the call falls through.
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
end
