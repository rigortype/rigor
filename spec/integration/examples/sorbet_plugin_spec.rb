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
end
