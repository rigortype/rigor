# frozen_string_literal: true

require "prism"
require "rigor/plugin"

module Rigor
  module Plugin
    # rigor-mangrove — precision plugin for the [Mangrove](https://github.com/kazzix14/mangrove) functional
    # toolkit (Result / Option carriers).
    #
    # ## Why this plugin exists (and what it deliberately is NOT)
    #
    # Mangrove is a Sorbet-first library: every carrier method is annotated with an inline `sig { ... }`, and
    # the Enum DSL's dynamic variants are materialised by a bundled Tapioca DSL compiler. So the *type source*
    # for Mangrove is already covered by `rigor-sorbet` (sig ingestion + RBI walking) — this plugin is NOT a
    # parallel type source. See `docs/notes/20260530-mangrove-library-survey.md`.
    #
    # What sig-ingestion (Sorbet-level precision) structurally cannot do is **instantiate the carrier's generic
    # type-member at the unwrap call site**. Mangrove's `Result` interface declares:
    #
    #     sig { abstract.returns(OkType) }
    #     def unwrap!; end
    #
    # `OkType` is a `type_member(:out)`. When the receiver's static type is
    # `Mangrove::Result[String, StandardError]`, `unwrap!` *should* yield `String` — but resolving the abstract
    # `OkType` to the receiver's first type argument is generic instantiation, which neither `rigor-sorbet` (it
    # contributes the cataloged sig's return type verbatim) nor a bare-`def unwrap!: () -> untyped` RBS stub
    # performs. The call degrades to `Dynamic[top]`.
    #
    # This plugin closes exactly that gap. At every recognised unwrap-family call on a known Mangrove carrier,
    # it reads the receiver's `Rigor::Type::Nominal#type_args` and contributes the first argument (the
    # `OkType` / `InnerType`) as the call's return type. The receiver type is already known, so this only ever
    # *sharpens* an existing `Dynamic[top]` into a concrete type — it never invents a receiver type and never
    # emits a diagnostic of its own, so it cannot frighten working code (Rigor's false-positive discipline).
    #
    # ## Scope (slice 1)
    #
    # - Result unwrap family → `OkType` (`type_args[0]`): `unwrap!`, `unwrap_in`, `expect!`, `expect_with!`,
    #   `unwrap_or_raise!`, `unwrap_or_raise_with!`, `unwrap_or_raise_inner!`.
    # - Option unwrap family → `InnerType` (`type_args[0]`): `unwrap`, `unwrap!`, `unwrap_or`, `expect!`,
    #   `expect_with!`.
    #
    # The contribution fires only when the receiver resolves to a carrier Nominal carrying a non-empty
    # `type_args` — i.e. when the Result/Option came from a method whose declared return type is an applied
    # generic (`-> Result[String, E]`), the realistic Mangrove shape. The bare-constructor shape
    # (`Result::Ok.new("x")`) currently yields a raw Nominal with no `type_args` (the engine does not infer
    # generics from constructor arguments), so the plugin no-ops there rather than guessing — a conservative
    # floor, not a regression.
    #
    # ## Out of scope (tracked elsewhere)
    #
    # - `is_a?(Result::Ok)` / `Some` / `None` exhaustive narrowing — core control-flow analysis over a sealed
    #   hierarchy, not a plugin surface.
    # - The `variants do variant Const, Type end` Enum DSL is handled via ADR-36 `nested_class_templates:` in
    #   this plugin's manifest (Slice A — see `nested_class_templates:` block below).
    class Mangrove < Rigor::Plugin::Base
      manifest(
        id: "mangrove",
        version: "0.2.0",
        description: "Instantiates Mangrove Result/Option carrier generics at unwrap call sites, " \
                     "sharpening `unwrap!` / `unwrap_in` / `unwrap_or` from `untyped` to the carried type; " \
                     "synthesises `Enum` variant subclasses from the `variants do … end` DSL (ADR-36).",
        # ADR-36 nested-class emission — Mangrove's `Enum`:
        #
        #   class Shape
        #     extend Mangrove::Enum
        #     variants do
        #       variant Circle, Float
        #     end
        #   end
        #
        # mints `Shape::Circle < Shape` with `#inner : Float`. The substrate resolves the variant constant +
        # its `#inner` reader statically so `Shape::Circle.new(1.0).inner` types as `Float` without running
        # Mangrove's `const_missing`.
        nested_class_templates: [
          Rigor::Plugin::Macro::NestedClassTemplate.new(
            receiver_constraint: "Mangrove::Enum",
            block_method: :variants,
            variant_method: :variant,
            symbol_arg_position: 0,
            inner_arg_position: 1,
            inner_reader: :inner
          )
        ]
      )

      # Carrier class names whose FIRST type argument is the value the unwrap family yields (`OkType` for
      # Result, `InnerType` for Option). Matched with and without a leading `::` because `scope.type_of`
      # reports the lexical form while user code may root the constant.
      RESULT_CARRIERS = [
        "Mangrove::Result",
        "Mangrove::Result::Ok",
        "Mangrove::Result::Err"
      ].freeze

      OPTION_CARRIERS = [
        "Mangrove::Option",
        "Mangrove::Option::Some",
        "Mangrove::Option::None"
      ].freeze

      # Methods on the Result carriers that return `OkType` (`type_args[0]`). All of these are documented as
      # yielding the success value, raising / short-circuiting on `Err`.
      RESULT_UNWRAP_METHODS = %i[
        unwrap! unwrap_in expect! expect_with!
        unwrap_or_raise! unwrap_or_raise_with! unwrap_or_raise_inner!
      ].freeze

      # Methods on the Option carriers that return `InnerType` (`type_args[0]`).
      OPTION_UNWRAP_METHODS = %i[unwrap unwrap! unwrap_or expect! expect_with!].freeze

      # ADR-37 slice 2 — a pure return-type contributor. The engine gates on the receiver being a known
      # carrier class (so the block only runs on Result/Option receivers); the block then confirms the call
      # is an unwrap method on an instantiated carrier and yields the carried `type_args[0]`.
      dynamic_return receivers: (RESULT_CARRIERS + OPTION_CARRIERS) do |call_node, scope|
        receiver = call_node.receiver
        next nil if receiver.nil?

        receiver_type = receiver_type_of(receiver, scope)
        next nil unless receiver_type.is_a?(Rigor::Type::Nominal)

        carried_type(receiver_type, call_node.name)
      end

      private

      # @return [Rigor::Type, nil] the receiver's inferred type, or nil when the engine raises on a synthetic
      #   / unrecognised node (mirrors rigor-sorbet's defensive degrade).
      def receiver_type_of(receiver, scope)
        scope.type_of(receiver)
      rescue StandardError
        nil
      end

      # The value the unwrap family yields for this receiver, or nil when the call is not an unwrap on a
      # known carrier, or the carrier is raw (no `type_args` to instantiate).
      def carried_type(receiver_type, method_name)
        class_name = normalize(receiver_type.class_name)
        type_args = receiver_type.type_args
        return nil if type_args.empty?

        if RESULT_CARRIERS.include?(class_name)
          return type_args.first if RESULT_UNWRAP_METHODS.include?(method_name)
        elsif OPTION_CARRIERS.include?(class_name)
          return type_args.first if OPTION_UNWRAP_METHODS.include?(method_name)
        end

        nil
      end

      def normalize(class_name)
        class_name.start_with?("::") ? class_name.delete_prefix("::") : class_name
      end
    end

    Rigor::Plugin.register(Mangrove)
  end
end
