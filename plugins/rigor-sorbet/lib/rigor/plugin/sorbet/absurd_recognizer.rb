# frozen_string_literal: true

require "prism"

require_relative "type_translator"

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Slice 6 of ADR-11 — recognises `T.absurd(x)` calls and
      # composes them with the engine's flow-sensitive
      # narrowing. `T.absurd` asserts that a code branch is
      # statically unreachable; it's the standard Sorbet idiom
      # for case/when exhaustiveness:
      #
      #   case x
      #   when A then ...
      #   when B then ...
      #   else
      #     T.absurd(x)
      #   end
      #
      # If every case has been handled, `x` at the `else` branch
      # has been narrowed to `T.noreturn` (Rigor's `Type::Bot`)
      # and the assertion holds. If the user forgot a case, `x`
      # narrows to whatever's left and the assertion is wrong —
      # we surface that mistake as `plugin.sorbet.absurd-reachable`.
      #
      # ## Two-phase mechanism
      #
      # The recogniser is invoked from `flow_contribution_for`
      # where the per-node `scope:` carries the proper narrowing
      # context. It returns:
      #
      # - A `FlowContribution` with `return_type: bot` and
      #   `exceptional: :raises` regardless of reachability
      #   (faithful to `T.absurd`'s runtime behaviour: it always
      #   raises). This lets the engine's existing flow analysis
      #   treat code after `T.absurd` as unreachable, matching
      #   what users of Sorbet expect.
      # - When the branch is REACHABLE (the discriminant's type
      #   isn't `bot`), the recogniser also records the call
      #   node in a per-plugin set. The plugin's
      #   `diagnostics_for_file` later walks the AST for
      #   `T.absurd` calls and emits a
      #   `plugin.sorbet.absurd-reachable` warning at every
      #   call_node whose object identity matches the recorded
      #   set. We rely on the runner only parsing each file
      #   once per run, so the same Prism node object is seen
      #   in both `flow_contribution_for` and
      #   `diagnostics_for_file`.
      module AbsurdRecognizer
        # @param call_node [Prism::CallNode]
        # @return [Boolean] true when `call_node` is `T.absurd(x)`.
        def self.absurd_call?(call_node)
          return false unless call_node.is_a?(Prism::CallNode)
          return false unless call_node.name == :absurd
          return false unless TypeTranslator.sorbet_t_namespaced?(call_node.receiver)

          # Slice 6 only handles single-argument `T.absurd(x)`;
          # no-arg / multi-arg shapes are syntax errors at
          # Sorbet's level too.
          arguments = call_node.arguments&.arguments
          arguments&.size == 1
        end

        # @param call_node [Prism::CallNode]
        # @param scope [Rigor::Scope, nil]
        # @return [Boolean] true when the discriminant has been
        #   narrowed to `bot` (the branch is unreachable, so
        #   `T.absurd` is correct). The caller suppresses the
        #   `absurd-reachable` diagnostic in this case.
        def self.exhaustive?(call_node, scope)
          return false if scope.nil?

          arg = call_node.arguments.arguments.first
          arg_type = scope.type_of(arg)
          arg_type.equal?(Rigor::Type::Bot.instance) || arg_type.is_a?(Rigor::Type::Bot)
        rescue StandardError
          # On synthetic / unrecognised nodes the typer may
          # raise; treat as "can't prove unreachable" so the
          # diagnostic fires conservatively.
          false
        end

        # The contribution every `T.absurd` call gets,
        # regardless of static reachability — `T.absurd` raises
        # at runtime, so its return type is `bot` and the call
        # is exceptional. This lets the engine's flow analysis
        # treat code after the call as unreachable (no
        # `flow.unreachable-branch` from us; that's an engine
        # rule that consults the same effect lattice).
        def self.contribution(call_node, plugin_id)
          Rigor::FlowContribution.new(
            return_type: Rigor::Type::Combinator.bot,
            exceptional: :raises,
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
