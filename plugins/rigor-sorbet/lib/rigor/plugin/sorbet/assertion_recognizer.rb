# frozen_string_literal: true

require "prism"

require_relative "type_translator"

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Lifts Sorbet's type-assertion calls (`T.let`, `T.cast`,
      # `T.must`, `T.must_because`, `T.unsafe`, `T.reveal_type`)
      # into `FlowContribution` return-type contributions.
      # ADR-11 slice 2 covered the original four; the
      # `must_because` / `reveal_type` light follow-up extends
      # the same module rather than splitting into a parallel
      # recogniser.
      #
      # | Sorbet form                  | Contribution                            |
      # | ---------------------------- | --------------------------------------- |
      # | `T.let(expr, T)`             | return type ← translated `T`            |
      # | `T.cast(expr, T)`            | return type ← translated `T`            |
      # | `T.must(expr)`               | return type ← `inferred(expr) - nil`    |
      # | `T.must_because(expr, "..")` | return type ← `inferred(expr) - nil`    |
      # | `T.unsafe(x)`                | return type ← `Dynamic[top]`            |
      # | `T.reveal_type(expr)`        | return type ← `inferred(expr)` (passes through) |
      # | `T.assert_type!(expr, T)`    | return type ← translated `T` + static subtype check |
      # | `T.bind(self, T)`            | return type ← `Constant[nil]` + post_return_fact narrowing self to translated `T` |
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
      # `T.must_because` is `T.must` with a second-argument
      # string explanation. The static behaviour is identical to
      # `T.must` — strip `nil` from the inferred type — so the
      # recogniser dispatches through the same path.
      #
      # `T.reveal_type` is "diagnostic-only" in Sorbet: it
      # passes the value through unchanged at runtime AND
      # surfaces the inferred static type as a build-time
      # message. The recogniser contributes the inferred type
      # (so chained call sites still resolve as if the
      # `T.reveal_type` wrapper weren't there); the plugin's
      # `diagnostics_for_file` hook surfaces the
      # `plugin.sorbet.reveal-type` `:info` message for human
      # consumption.
      #
      # `T.bind(self, T)` is recognised as block-scope self
      # narrowing. The recogniser returns a contribution whose
      # `post_return_facts` carries a `Fact(target_kind: :self)`
      # so the engine's `apply_self_post_return_fact` narrows
      # `scope.self_type` for the surrounding scope (in a block
      # body, the rest of the block). The first argument MUST be
      # a literal `Prism::SelfNode` — Sorbet rejects other
      # receivers and the recogniser mirrors that. The runtime
      # call returns nil, so the static return type is
      # `Constant[nil]`.
      module AssertionRecognizer
        # Method names this recogniser claims as Sorbet
        # assertions. The plugin checks call sites against this
        # set before any catalog lookup so a `T.let` call
        # inside an analysed file always resolves through this
        # module.
        SORBET_ASSERTIONS = %i[let cast must must_because unsafe reveal_type assert_type! bind].freeze

        module_function

        # @param call_node [Prism::CallNode]
        # @param scope [Rigor::Scope]
        # @param plugin_id [String] used for the contribution's
        #   `provenance.source_family`.
        # @return [Rigor::FlowContribution, nil]
        def recognize(call_node:, scope:, plugin_id:)
          return nil unless TypeTranslator.sorbet_t_namespaced?(call_node.receiver)
          return nil unless SORBET_ASSERTIONS.include?(call_node.name)

          return recognize_bind(call_node, plugin_id) if call_node.name == :bind

          return_type = return_type_for(call_node, scope)
          return nil if return_type.nil?

          contribution(call_node, return_type, plugin_id)
        end

        def return_type_for(call_node, scope)
          case call_node.name
          when :let, :cast then resolve_typed_assertion(call_node)
          when :must, :must_because then resolve_must(call_node, scope)
          when :unsafe then Rigor::Type::Combinator.untyped
          when :reveal_type then resolve_reveal_type(call_node, scope)
          when :assert_type! then resolve_typed_assertion(call_node)
          end
        end

        # `T.bind(self, T)` recognition. Sorbet rejects any
        # non-`self` receiver argument, and the recogniser
        # mirrors that — calls like `T.bind(other, X)` fall
        # through silently. The contribution carries:
        #
        # - `return_type: Constant[nil]` — Sorbet's runtime
        #   `T.bind` returns nil; chained calls would be a
        #   bug, but the typing stays accurate.
        # - `post_return_facts: [Fact(target_kind: :self,
        #   type: T)]` — the engine's
        #   `apply_self_post_return_fact` narrows
        #   `scope.self_type` for the surrounding scope. In a
        #   block body, that scope is the block's own, so the
        #   narrowing applies to the rest of the block —
        #   matching Sorbet's documented contract.
        def recognize_bind(call_node, plugin_id)
          first_arg = nth_argument(call_node, 0)
          return nil unless first_arg.is_a?(Prism::SelfNode)

          type_arg = nth_argument(call_node, 1)
          return nil if type_arg.nil?

          asserted = TypeTranslator.translate(type_arg)
          return nil if asserted.nil?

          fact = Rigor::FlowContribution::Fact.new(
            target_kind: :self, target_name: :self, type: asserted
          )
          Rigor::FlowContribution.new(
            return_type: Rigor::Type::Combinator.constant_of(nil),
            post_return_facts: [fact],
            provenance: Rigor::FlowContribution::Provenance.new(
              source_family: "plugin.#{plugin_id}",
              plugin_id: plugin_id,
              node: call_node,
              descriptor: nil
            )
          )
        end

        # `T.assert_type!(expr, T)` shares the typed-assertion
        # contribution shape with `T.cast` (return is the
        # asserted type), so the recogniser delegates the
        # return-type half through `resolve_typed_assertion`.
        # The static subtype check that distinguishes
        # `assert_type!` from `cast` lives in the plugin's
        # `diagnostics_for_file` hook (mirroring the
        # absurd-recognizer pattern: record the call here, emit
        # the diagnostic from the per-file walker).
        def assert_type_check(call_node, scope)
          return nil if scope.nil?

          inner = nth_argument(call_node, 0)
          asserted_node = nth_argument(call_node, 1)
          return nil if inner.nil? || asserted_node.nil?

          asserted_type = TypeTranslator.translate(asserted_node)
          return nil if asserted_type.nil?

          inferred = scope.type_of(inner)
          [inferred, asserted_type]
        rescue StandardError
          nil
        end

        # `T.reveal_type(expr)` returns `expr` unchanged at
        # runtime; the Sorbet-side semantics is "make the
        # inferred static type visible to the user." The
        # contribution mirrors `T.must` minus the nil-stripping:
        # the call's return type is the inner expression's
        # inferred type. The companion diagnostic is emitted by
        # the plugin's `diagnostics_for_file` hook through
        # {RevealTypeRecognizer}; the recogniser here is
        # contribution-only.
        def resolve_reveal_type(call_node, scope)
          inner = nth_argument(call_node, 0)
          return Rigor::Type::Combinator.untyped if inner.nil? || scope.nil?

          inner_type = scope.type_of(inner)
          inner_type || Rigor::Type::Combinator.untyped
        rescue StandardError
          # Synthetic / virtual nodes can raise from
          # `scope.type_of`; degrade gracefully so the dispatcher
          # can still proceed with a benign untyped envelope.
          Rigor::Type::Combinator.untyped
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
