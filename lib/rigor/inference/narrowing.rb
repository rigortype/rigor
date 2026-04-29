# frozen_string_literal: true

require "prism"

require_relative "../type"

module Rigor
  module Inference
    # Slice 6 phase 1 minimal narrowing surface.
    #
    # `Rigor::Inference::Narrowing` answers two related questions:
    #
    # 1. Type-level narrowing: given a `Rigor::Type` value, what is its
    #    truthy fragment, its falsey fragment, its nil fragment, and its
    #    non-nil fragment? These primitives understand the value-lattice
    #    algebra (`Constant`, `Nominal`, `Singleton`, `Tuple`, `HashShape`,
    #    `Union`) and stay conservative on `Top` and `Dynamic[T]`, where
    #    the analyzer cannot prove the boundary either way.
    # 2. Predicate-level narrowing: given a Prism predicate node and an
    #    entry scope, what are the truthy-edge scope and the falsey-edge
    #    scope after the predicate has been evaluated? The phase 1
    #    catalogue covers truthiness on `LocalVariableReadNode`, `nil?`
    #    against a local, the unary `!` inverter, parenthesised
    #    predicates, and short-circuiting `&&` / `||` chains.
    #
    # Predicate-level narrowing is consumed by
    # `Rigor::Inference::StatementEvaluator` to refine the `then` and
    # `else` scopes of `IfNode`/`UnlessNode`. Phase 1 narrows local
    # bindings only; class-membership predicates (`is_a?`, `kind_of?`,
    # `instance_of?`), equality narrowing, and ivar/cvar narrowing are
    # deferred to a follow-up.
    #
    # The module is pure: every public function returns fresh values and
    # MUST NOT mutate its inputs. Unrecognised predicate shapes degrade
    # silently to "no narrowing" by returning `nil` from the internal
    # analyser; the public `predicate_scopes` always returns an
    # `[truthy_scope, falsey_scope]` pair (the entry scope twice when no
    # rule matches).
    #
    # See docs/internal-spec/inference-engine.md (Slice 6 — Narrowing)
    # and docs/type-specification/control-flow-analysis.md for the
    # binding contract.
    # rubocop:disable Metrics/ModuleLength
    module Narrowing
      module_function

      # Truthy fragment of `type`: the subset whose inhabitants are truthy
      # in Ruby's sense (anything other than `nil` and `false`).
      #
      # `Top`, `Dynamic[T]`, `Bot`, `Singleton[C]`, `Tuple[*]`, and
      # `HashShape{*}` flow through unchanged: Top/Dynamic stay
      # conservative because the analyzer cannot express the
      # difference type without a richer carrier and Dynamic must
      # preserve its provenance under the value-lattice algebra; the
      # remaining carriers are already truthy by inhabitance.
      def narrow_truthy(type)
        case type
        when Type::Constant
          falsey_value?(type.value) ? Type::Combinator.bot : type
        when Type::Nominal
          falsey_nominal?(type) ? Type::Combinator.bot : type
        when Type::Union
          Type::Combinator.union(*type.members.map { |m| narrow_truthy(m) })
        else
          type
        end
      end

      # Falsey fragment of `type`: the subset whose inhabitants are
      # `nil` or `false`. Carriers that cannot inhabit a falsey value
      # collapse to `Bot`.
      def narrow_falsey(type)
        case type
        when Type::Constant then falsey_value?(type.value) ? type : Type::Combinator.bot
        when Type::Nominal then falsey_nominal?(type) ? type : Type::Combinator.bot
        when Type::Union then Type::Combinator.union(*type.members.map { |m| narrow_falsey(m) })
        else narrow_falsey_other(type)
        end
      end

      # Nil fragment of `type`: the subset whose inhabitants are `nil`.
      # Used by `nil?` predicate narrowing. `Top`/`Dynamic` narrow to
      # the canonical `Constant[nil]` so downstream dispatch resolves
      # through `NilClass`; carriers that never inhabit `nil`
      # (`Singleton`, `Tuple`, `HashShape`) collapse to `Bot`. `Bot`
      # is its own nil fragment.
      def narrow_nil(type)
        case type
        when Type::Constant then type.value.nil? ? type : Type::Combinator.bot
        when Type::Nominal then type.class_name == "NilClass" ? type : Type::Combinator.bot
        when Type::Union then Type::Combinator.union(*type.members.map { |m| narrow_nil(m) })
        else narrow_nil_other(type)
        end
      end

      # Non-nil fragment of `type`: the subset whose inhabitants are
      # not `nil`. Mirror of {.narrow_nil} for the falsey edge of
      # `x.nil?`.
      def narrow_non_nil(type)
        case type
        when Type::Constant
          type.value.nil? ? Type::Combinator.bot : type
        when Type::Nominal
          type.class_name == "NilClass" ? Type::Combinator.bot : type
        when Type::Union
          Type::Combinator.union(*type.members.map { |m| narrow_non_nil(m) })
        else
          # Top, Dynamic, Singleton, Tuple, HashShape, Bot: there is
          # no nil contribution to remove, so the type is its own
          # non-nil fragment.
          type
        end
      end

      # Public predicate analyser. Returns `[truthy_scope, falsey_scope]`,
      # always; when no narrowing rule matches the predicate node both
      # entries are the receiver scope unchanged.
      #
      # @param node [Prism::Node, nil]
      # @param scope [Rigor::Scope]
      # @return [Array(Rigor::Scope, Rigor::Scope)]
      def predicate_scopes(node, scope)
        return [scope, scope] if node.nil?

        result = analyse(node, scope)
        result || [scope, scope]
      end

      # Internal analyser. Returns `[truthy_scope, falsey_scope]` when
      # the predicate shape is recognised, or `nil` to signal "no
      # narrowing" so the public surface can fall back to the entry
      # scope.
      def analyse(node, scope)
        case node
        when Prism::ParenthesesNode
          analyse_parentheses(node, scope)
        when Prism::StatementsNode
          analyse_statements(node, scope)
        when Prism::LocalVariableReadNode
          analyse_local_read(node, scope)
        when Prism::CallNode
          analyse_call(node, scope)
        when Prism::AndNode
          analyse_and(node, scope)
        when Prism::OrNode
          analyse_or(node, scope)
        end
      end

      class << self
        private

        def falsey_value?(value)
          value.nil? || value == false
        end

        def falsey_nominal?(nominal)
          %w[NilClass FalseClass].include?(nominal.class_name)
        end

        # Carriers that the {.narrow_falsey} fast path does not handle
        # by structural inspection. Singleton/Tuple/HashShape inhabit
        # truthy values, so their falsey fragment is empty; everything
        # else (Top, Dynamic, Bot, and any future carrier) stays
        # conservative and is returned unchanged.
        def narrow_falsey_other(type)
          case type
          when Type::Singleton, Type::Tuple, Type::HashShape then Type::Combinator.bot
          else type
          end
        end

        # Carriers that the {.narrow_nil} fast path does not handle by
        # structural inspection. Top/Dynamic narrow to `Constant[nil]`
        # so dispatch resolves through `NilClass`; Bot is its own nil
        # fragment; the remaining carriers (Singleton, Tuple,
        # HashShape, and any future carrier whose inhabitants exclude
        # nil) collapse to `Bot`.
        def narrow_nil_other(type)
          case type
          when Type::Dynamic, Type::Top then Type::Combinator.constant_of(nil)
          when Type::Bot then type
          else Type::Combinator.bot
          end
        end

        def analyse_parentheses(node, scope)
          return nil if node.body.nil?

          analyse(node.body, scope)
        end

        # The truthiness of a `StatementsNode` is determined by its
        # last statement (intermediate statements run for effect and
        # then the predicate's value is the tail's). Earlier
        # statements MAY have scope effects, but Slice 6 phase 1 does
        # NOT thread those through the analyser (the StatementEvaluator
        # has already produced `post_pred` for the call site, and
        # narrowing is layered on that scope).
        def analyse_statements(node, scope)
          return nil if node.body.empty?

          analyse(node.body.last, scope)
        end

        def analyse_local_read(node, scope)
          current = scope.local(node.name)
          return nil if current.nil?

          [
            scope.with_local(node.name, narrow_truthy(current)),
            scope.with_local(node.name, narrow_falsey(current))
          ]
        end

        # Recognised CallNode predicates in phase 1: `recv.nil?` (no
        # args, no block) and the unary `!recv` (which is a CallNode
        # in Prism with `name == :!`). Anything else returns nil so
        # the surrounding analyser falls through.
        def analyse_call(node, scope)
          return nil unless argument_free?(node)
          return nil if node.block
          return nil if node.receiver.nil?

          case node.name
          when :nil? then analyse_nil_predicate(node.receiver, scope)
          when :! then analyse(node.receiver, scope)&.reverse
          end
        end

        def argument_free?(node)
          node.arguments.nil? || node.arguments.arguments.empty?
        end

        def analyse_nil_predicate(receiver, scope)
          return nil unless receiver.is_a?(Prism::LocalVariableReadNode)

          current = scope.local(receiver.name)
          return nil if current.nil?

          [
            scope.with_local(receiver.name, narrow_nil(current)),
            scope.with_local(receiver.name, narrow_non_nil(current))
          ]
        end

        # `a && b` short-circuits: the truthy edge is the truthy edge
        # of `b` evaluated under `a`'s truthy scope; the falsey edge
        # is the union of `a`'s falsey scope (b skipped) and `b`'s
        # falsey scope (b ran but returned falsey). When a sub-edge
        # cannot be narrowed we fall back to the entry scope so the
        # caller still sees consistent keys across the two output
        # scopes.
        def analyse_and(node, scope)
          truthy_a, falsey_a = analyse(node.left, scope) || [scope, scope]
          truthy_b, falsey_b = analyse(node.right, truthy_a) || [truthy_a, truthy_a]
          [truthy_b, falsey_a.join(falsey_b)]
        end

        # `a || b` short-circuits: the truthy edge is the union of
        # `a`'s truthy scope (b skipped) and `b`'s truthy scope (b
        # ran and was truthy); the falsey edge is `b`'s falsey scope
        # evaluated under `a`'s falsey scope.
        def analyse_or(node, scope)
          truthy_a, falsey_a = analyse(node.left, scope) || [scope, scope]
          truthy_b, falsey_b = analyse(node.right, falsey_a) || [falsey_a, falsey_a]
          [truthy_a.join(truthy_b), falsey_b]
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
