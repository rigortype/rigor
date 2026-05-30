# frozen_string_literal: true

# Integration spec for `plugins/rigor-mangrove/`. Slice 1:
# instantiates the Mangrove Result/Option carrier generic at the
# unwrap call site, contributing `type_args[0]` (the OkType /
# InnerType) as the unwrap call's return type.
#
# The carriers are declared as applied generics in RBS but their
# unwrap methods return `untyped` — mirroring a generic-unaware
# sig source. Without the plugin every unwrap is `untyped` and a
# typo'd chained call goes unnoticed; with the plugin the unwrap
# resolves to the carried type and the typo surfaces as
# `call.undefined-method`.

require "spec_helper"

MANGROVE_PLUGIN_LIB = File.expand_path("../../../plugins/rigor-mangrove/lib", __dir__)
$LOAD_PATH.unshift(MANGROVE_PLUGIN_LIB) unless $LOAD_PATH.include?(MANGROVE_PLUGIN_LIB)
require "rigor-mangrove"

# Carriers as applied generics; a `Session` producer whose
# declared return types make the receiver carry `type_args`.
MANGROVE_RBS = <<~RBS
  module Mangrove
    module Result
      class Ok[OkType, ErrType]
        def initialize: (OkType inner) -> void
        def unwrap!: () -> untyped
        def unwrap_in: (untyped ctx) -> untyped
        def expect!: (String message) -> untyped
      end
    end

    module Option
      class Some[InnerType]
        def initialize: (InnerType inner) -> void
        def unwrap: () -> untyped
        def unwrap_or: (InnerType default) -> untyped
      end
    end
  end

  class Session
    def token: () -> Mangrove::Result::Ok[String, StandardError]
    def cached_user: () -> Mangrove::Option::Some[String]
  end
RBS

ENUM_SOURCE = <<~RUBY
  module Mangrove
    module Enum; end
  end

  class Shape
    extend Mangrove::Enum
    variants do
      variant Circle, Float
      variant Label, String
    end
  end
RUBY

RSpec.describe "plugins/rigor-mangrove" do
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::Mangrove }

  def undefined_methods(result)
    result.diagnostics.select { |d| d.rule == "call.undefined-method" }
  end

  describe "Result unwrap family → OkType" do
    it "resolves `unwrap!` to the OkType so a valid chained call stays clean" do
      source = <<~RUBY
        def demo
          Session.new.token.unwrap!.upcase
        end
      RUBY

      result = run_plugin(source: source, files: { "sig/mangrove.rbs" => MANGROVE_RBS }, signature_paths: ["sig"])
      expect(undefined_methods(result)).to be_empty
    end

    it "resolves `unwrap!` to String so a typo'd chained call is caught" do
      source = <<~RUBY
        def demo
          Session.new.token.unwrap!.uppercaze
        end
      RUBY

      result = run_plugin(source: source, files: { "sig/mangrove.rbs" => MANGROVE_RBS }, signature_paths: ["sig"])
      offenders = undefined_methods(result)
      expect(offenders.map(&:message)).to include(a_string_matching(/uppercaze.*for String/))
    end

    it "resolves the early-return `unwrap_in(ctx)` to the OkType" do
      source = <<~RUBY
        def demo(ctx)
          Session.new.token.unwrap_in(ctx).lenght
        end
      RUBY

      result = run_plugin(source: source, files: { "sig/mangrove.rbs" => MANGROVE_RBS }, signature_paths: ["sig"])
      expect(undefined_methods(result).map(&:message)).to include(a_string_matching(/lenght.*for String/))
    end
  end

  describe "Option unwrap family → InnerType" do
    it "resolves `unwrap_or(default)` to the InnerType" do
      source = <<~RUBY
        def demo
          Session.new.cached_user.unwrap_or("guest").revrse
        end
      RUBY

      result = run_plugin(source: source, files: { "sig/mangrove.rbs" => MANGROVE_RBS }, signature_paths: ["sig"])
      expect(undefined_methods(result).map(&:message)).to include(a_string_matching(/revrse.*for String/))
    end
  end

  describe "conservative floor — never invents precision" do
    it "no-ops on a raw carrier with no type_args (constructor shape)" do
      # `Result::Ok.new("x")` yields a raw Nominal (the engine
      # does not infer generics from constructor args), so the
      # plugin contributes nothing and the typo'd chain stays
      # `untyped` — no false positive.
      source = <<~RUBY
        def demo
          Mangrove::Result::Ok.new("x").unwrap!.uppercaze
        end
      RUBY

      result = run_plugin(source: source, files: { "sig/mangrove.rbs" => MANGROVE_RBS }, signature_paths: ["sig"])
      expect(undefined_methods(result)).to be_empty
    end

    it "emits no diagnostics of its own" do
      source = <<~RUBY
        def demo
          Session.new.token.unwrap!.upcase
        end
      RUBY

      result = run_plugin(source: source, files: { "sig/mangrove.rbs" => MANGROVE_RBS }, signature_paths: ["sig"])
      expect(plugin_diagnostics(result)).to be_empty
    end
  end

  # ADR-36 nested-class emission — the `variants do … end` Enum DSL
  # mints a nested subclass per variant with a typed `#inner` reader.
  describe "Enum variant synthesis (ADR-36)" do
    it "resolves the variant constant + `.new` + a payload-typed `#inner`" do
      source = <<~RUBY
        #{ENUM_SOURCE}
        def demo
          Shape::Circle.new(1.5).inner.floor
        end
      RUBY

      result = run_plugin(source: source)
      # `#inner` resolves to Float, `Float#floor` is valid → no undefined-method.
      expect(undefined_methods(result)).to be_empty
    end

    it "catches a typo on the variant payload (inner resolved to Float)" do
      source = <<~RUBY
        #{ENUM_SOURCE}
        def demo
          Shape::Circle.new(1.5).inner.no_such_float_method
        end
      RUBY

      result = run_plugin(source: source)
      expect(undefined_methods(result).map(&:message))
        .to include(a_string_matching(/no_such_float_method.*for Float/))
    end

    it "types each variant's `#inner` to its own declared payload" do
      source = <<~RUBY
        #{ENUM_SOURCE}
        def demo
          Shape::Label.new("hi").inner.no_such_string_method
        end
      RUBY

      result = run_plugin(source: source)
      expect(undefined_methods(result).map(&:message))
        .to include(a_string_matching(/no_such_string_method.*for String/))
    end
  end
end
