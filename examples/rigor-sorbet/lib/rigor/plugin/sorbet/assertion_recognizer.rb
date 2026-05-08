# frozen_string_literal: true

require "prism"

require_relative "type_translator"

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Lifts Sorbet's type-assertion calls (`T.let`, `T.cast`,
      # `T.must`, `T.unsafe`) into `FlowContribution` return-type
      # contributions. ADR-11 slice 2.
      #
      # | Sorbet form           | Contribution                            |
      # | --------------------- | --------------------------------------- |
      # | `T.let(expr, T)`      | return type ← translated `T`            |
      # | `T.cast(expr, T)`     | return type ← translated `T`            |
      # | `T.must(expr)`        | return type ← `inferred(expr) - nil`    |
      # | `T.unsafe(x)`         | return type ← `Dynamic[top]`            |
      #
      # The Sorbet runtime's `T.let` / `T.cast` actually return
      # the inner expression unchanged at runtime; their job is
      # purely to *assert* a static type. From Rigor's static
      # perspective the simplest faithful translation is "the
      # call's return type IS the asserted type" — the call
      # site's downstream uses see that type. This matches what
      # `%a{rigor:v1:assert: x is T}` would do for an assignment
      # in the surrounding scope.
      #
      # `T.bind`, `T.assert_type!`, `T.must_because` and
      # `T.reveal_type` are deferred to a follow-up slice
      # (`T.bind` needs a self-targeted post-return fact;
      # `T.reveal_type` is a diagnostic-only path; the others
      # are minor variants).
      module AssertionRecognizer
        # Method names this recogniser claims as Sorbet
        # assertions. The plugin checks call sites against this
        # set before any catalog lookup so a `T.let` call
        # inside an analysed file always resolves through this
        # module.
        SORBET_ASSERTIONS = %i[let cast must unsafe].freeze

        module_function

        # @param call_node [Prism::CallNode]
        # @param scope [Rigor::Scope]
        # @param plugin_id [String] used for the contribution's
        #   `provenance.source_family`.
        # @return [Rigor::FlowContribution, nil]
        def recognize(call_node:, scope:, plugin_id:)
          return nil unless TypeTranslator.sorbet_t_namespaced?(call_node.receiver)
          return nil unless SORBET_ASSERTIONS.include?(call_node.name)

          return_type = return_type_for(call_node, scope)
          return nil if return_type.nil?

          contribution(call_node, return_type, plugin_id)
        end

        def return_type_for(call_node, scope)
          case call_node.name
          when :let, :cast then resolve_typed_assertion(call_node)
          when :must then resolve_must(call_node, scope)
          when :unsafe then Rigor::Type::Combinator.untyped
          end
        end

        # `T.let(expr, T)` and `T.cast(expr, T)` share the same
        # 2-argument shape: `arguments[1]` is the type
        # expression. The first argument is opaque to slice 2 —
        # we don't try to verify it at runtime; that's `srb tc`'s
        # job and is out of scope per ADR-11.
        def resolve_typed_assertion(call_node)
          type_arg = nth_argument(call_node, 1)
          return nil if type_arg.nil?

          TypeTranslator.translate(type_arg)
        end

        # `T.must(expr)` strips `nil` from `expr`'s inferred
        # type. The call's target type is therefore
        # `inferred(expr) - Constant[nil]`. Falls back to the
        # untyped envelope when the inferred shape is itself
        # `Dynamic[top]` or when no scope is available
        # (synthetic / virtual-node call sites).
        def resolve_must(call_node, scope)
          inner = nth_argument(call_node, 0)
          return nil if inner.nil? || scope.nil?

          inner_type = scope.type_of(inner)
          return Rigor::Type::Combinator.untyped if inner_type.nil?

          strip_nil(inner_type)
        rescue StandardError
          # `scope.type_of` may raise on synthetic nodes; degrade
          # to "no contribution" rather than crash the dispatcher.
          nil
        end

        # Removes `nil` (`Constant[nil]`) from `type` using the
        # `Difference` carrier. Idempotent on shapes that don't
        # contain nil — the resulting `Difference[base, removed]`
        # collapses to `base` if `base` already excludes the
        # removed value, but the simple form here is good enough
        # for slice 2; the precise normalisation lands when the
        # Difference carrier gets full algebraic support.
        def strip_nil(type)
          Rigor::Type::Combinator.difference(
            type, Rigor::Type::Combinator.constant_of(nil)
          )
        end

        def nth_argument(call_node, index)
          call_node.arguments&.arguments&.[](index)
        end

        def contribution(call_node, return_type, plugin_id)
          Rigor::FlowContribution.new(
            return_type: return_type,
            provenance: Rigor::FlowContribution::Provenance.new(
              source_family: "plugin.#{plugin_id}",
              plugin_id: plugin_id,
              node: call_node,
              descriptor: nil
            )
          )
        end
      end
    end
  end
end
