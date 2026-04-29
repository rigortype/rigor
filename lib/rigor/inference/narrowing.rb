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
    # bindings on truthiness and `nil?`; phase 2 sub-phase 1 extends
    # the catalogue with class-membership predicates (`is_a?`,
    # `kind_of?`, `instance_of?`) when the argument is a static
    # constant reference. Equality narrowing, ivar/cvar narrowing,
    # and the formal `Rigor::Analysis::FactStore` are still deferred
    # to phase 2 sub-phase 2+.
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

      # Class-membership fragment of `type`: the subset whose
      # inhabitants are instances of `class_name` (or its subclasses
      # when `exact: false`). `class_name` is the qualified name of
      # the class as it appears in source (`"Integer"`, `"Foo::Bar"`).
      # Slice 6 phase 2 sub-phase 1 narrows the `if x.is_a?(C)`
      # / `if x.kind_of?(C)` / `if x.instance_of?(C)` truthy edge.
      #
      # Nominal narrowing is hierarchy-aware via Ruby's runtime
      # `<=` operator on `Class` objects: when the bound type is a
      # supertype of `class_name` the result narrows DOWN to
      # `Nominal[class_name]` (e.g., `Numeric & Integer = Integer`);
      # when the bound type is already a subtype it is preserved;
      # disjoint hierarchies collapse to `Bot`. Classes the host
      # Ruby cannot resolve (`Object.const_get` fails) fall back to
      # the conservative answer (the type unchanged) so the
      # analyzer never asserts narrowing it cannot prove.
      def narrow_class(type, class_name, exact: false)
        narrow_class_dispatch(type, class_name, exact: exact, polarity: :positive)
      end

      # Mirror of {.narrow_class} for the falsey edge of
      # `is_a?`/`kind_of?`/`instance_of?`. Inhabitants that DO
      # satisfy the predicate are removed; inhabitants that do not
      # are preserved. Conservative on Top/Dynamic/Bot (preserved
      # unchanged) because the analyzer cannot prove the negative
      # without a richer carrier.
      def narrow_not_class(type, class_name, exact: false)
        narrow_class_dispatch(type, class_name, exact: exact, polarity: :negative)
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

      # rubocop:disable Metrics/ClassLength
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

        # Recognised CallNode predicates:
        # - `recv.nil?` (Slice 6 phase 1, no args, no block)
        # - unary `!recv` (`name == :!`, no args, no block)
        # - `recv.is_a?(C)` / `recv.kind_of?(C)` / `recv.instance_of?(C)`
        #   with a single static-constant argument and no block
        #   (Slice 6 phase 2 sub-phase 1).
        # Anything else returns nil so the surrounding analyser falls
        # through to the no-narrowing fallback.
        def analyse_call(node, scope)
          return nil if node.block
          return nil if node.receiver.nil?

          dispatch_call(node, scope, node.name)
        end

        def dispatch_call(node, scope, name)
          case name
          when :nil?, :! then dispatch_unary_predicate(node, scope, name)
          when :is_a?, :kind_of? then analyse_class_predicate(node, scope, exact: false)
          when :instance_of? then analyse_class_predicate(node, scope, exact: true)
          end
        end

        def dispatch_unary_predicate(node, scope, name)
          return nil unless argument_free?(node)

          case name
          when :nil? then analyse_nil_predicate(node.receiver, scope)
          when :! then analyse(node.receiver, scope)&.reverse
          end
        end

        def argument_free?(node)
          node.arguments.nil? || node.arguments.arguments.empty?
        end

        # `recv.is_a?(C)` / `recv.kind_of?(C)` / `recv.instance_of?(C)`
        # narrowing. The receiver MUST be a `LocalVariableReadNode`
        # (so we have a name to rebind), and the argument MUST be a
        # single static constant reference (`Foo` or `Foo::Bar`) we
        # can resolve to a qualified class name. Anything else falls
        # through to "no narrowing".
        def analyse_class_predicate(node, scope, exact:)
          return nil unless node.receiver.is_a?(Prism::LocalVariableReadNode)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          class_name = static_class_name(node.arguments.arguments.first)
          return nil if class_name.nil?

          current = scope.local(node.receiver.name)
          return nil if current.nil?

          [
            scope.with_local(node.receiver.name, narrow_class(current, class_name, exact: exact)),
            scope.with_local(node.receiver.name, narrow_not_class(current, class_name, exact: exact))
          ]
        end

        # Walks a constant-reference subtree (`Prism::ConstantReadNode`,
        # `Prism::ConstantPathNode`) and renders its qualified name.
        # Returns nil for any non-constant argument shape so the
        # caller can fall through.
        def static_class_name(node)
          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            parent = node.parent
            return node.name.to_s if parent.nil?

            parent_name = static_class_name(parent)
            return nil if parent_name.nil?

            "#{parent_name}::#{node.name}"
          end
        end

        # ----- narrow_class / narrow_not_class helpers -----

        # Polarity-aware dispatch table for {.narrow_class} /
        # {.narrow_not_class}. Avoids duplicating the per-carrier
        # case statement and keeps each public surface a thin
        # delegate; the per-carrier helpers know which polarity to
        # apply by looking at `polarity:`.
        def narrow_class_dispatch(type, class_name, exact:, polarity:)
          case type
          when Type::Constant then narrow_constant_class(type, class_name, exact: exact, polarity: polarity)
          when Type::Nominal then narrow_nominal_class(type, class_name, exact: exact, polarity: polarity)
          when Type::Union then narrow_union_class(type, class_name, exact: exact, polarity: polarity)
          when Type::Tuple then narrow_shape_class(type, "Array", class_name, exact: exact, polarity: polarity)
          when Type::HashShape then narrow_shape_class(type, "Hash", class_name, exact: exact, polarity: polarity)
          when Type::Singleton then narrow_singleton_class(type, class_name, exact: exact, polarity: polarity)
          else narrow_other_class(type, class_name, polarity: polarity)
          end
        end

        def narrow_constant_class(constant, class_name, exact:, polarity:)
          if polarity == :positive
            narrow_constant_to_class(constant, class_name, exact: exact)
          else
            narrow_constant_not_class(constant, class_name, exact: exact)
          end
        end

        def narrow_nominal_class(nominal, class_name, exact:, polarity:)
          if polarity == :positive
            narrow_nominal_to_class(nominal, class_name, exact: exact)
          else
            narrow_nominal_not_class(nominal, class_name, exact: exact)
          end
        end

        def narrow_union_class(union, class_name, exact:, polarity:)
          Type::Combinator.union(
            *union.members.map { |m| narrow_class_dispatch(m, class_name, exact: exact, polarity: polarity) }
          )
        end

        def narrow_shape_class(shape, projected_class, class_name, exact:, polarity:)
          if polarity == :positive
            narrow_shape_to_class(shape, projected_class, class_name, exact: exact)
          else
            narrow_shape_not_class(shape, projected_class, class_name, exact: exact)
          end
        end

        def narrow_singleton_class(singleton, class_name, exact:, polarity:)
          if polarity == :positive
            narrow_singleton_to_class(singleton, class_name, exact: exact)
          else
            narrow_singleton_not_class(singleton, class_name, exact: exact)
          end
        end

        def narrow_other_class(type, class_name, polarity:)
          polarity == :positive ? narrow_class_other(type, class_name) : type
        end

        def narrow_constant_to_class(constant, class_name, exact:)
          rigor_class = constant.value.class.name
          subclass_of?(rigor_class, class_name, exact: exact) ? constant : Type::Combinator.bot
        end

        def narrow_constant_not_class(constant, class_name, exact:)
          rigor_class = constant.value.class.name
          subclass_of?(rigor_class, class_name, exact: exact) ? Type::Combinator.bot : constant
        end

        # Narrow a Nominal under `is_a?(class_name)`: when the
        # nominal's class is already a subclass of `class_name`
        # (or matches under `exact: true`) preserve it; when
        # `class_name` is a subclass of the nominal's class
        # (`Nominal[Numeric]` under `is_a?(Integer)`) narrow DOWN
        # to `Nominal[class_name]`; otherwise (disjoint hierarchies
        # under `is_a?`, mismatch under `instance_of?`) collapse to
        # `Bot`. Conservative when the host Ruby cannot resolve
        # either class.
        def narrow_nominal_to_class(nominal, class_name, exact:)
          return nominal if nominal.class_name == class_name
          return Type::Combinator.bot if exact

          case class_ordering(nominal.class_name, class_name)
          when :superclass then Type::Combinator.nominal_of(class_name)
          when :disjoint then Type::Combinator.bot
          else nominal # :subclass preserves the bound; :unknown stays conservative
          end
        end

        def narrow_nominal_not_class(nominal, class_name, exact:)
          return Type::Combinator.bot if nominal.class_name == class_name
          return nominal if exact

          ordering = class_ordering(nominal.class_name, class_name)
          case ordering
          when :subclass then Type::Combinator.bot
          else nominal
          end
        end

        def narrow_shape_to_class(shape, projected_class, class_name, exact:)
          subclass_of?(projected_class, class_name, exact: exact) ? shape : Type::Combinator.bot
        end

        def narrow_shape_not_class(shape, projected_class, class_name, exact:)
          subclass_of?(projected_class, class_name, exact: exact) ? Type::Combinator.bot : shape
        end

        # `Singleton[Foo]` is the *class object* `Foo`, an instance of
        # `Class` (which is a subclass of `Module`). Asking
        # `Foo.is_a?(Class)` returns true; `Foo.is_a?(Foo)` returns
        # false unless `Foo` is `Class` itself. We approximate this
        # by treating singletons uniformly as `Class` instances.
        def narrow_singleton_to_class(singleton, class_name, exact:)
          subclass_of?("Class", class_name, exact: exact) ? singleton : Type::Combinator.bot
        end

        def narrow_singleton_not_class(singleton, class_name, exact:)
          subclass_of?("Class", class_name, exact: exact) ? Type::Combinator.bot : singleton
        end

        # Top/Dynamic narrow to `Nominal[class_name]` so dispatch
        # can resolve through the asked class; Bot stays Bot.
        def narrow_class_other(type, class_name)
          case type
          when Type::Dynamic, Type::Top then Type::Combinator.nominal_of(class_name)
          else type
          end
        end

        # Returns `true` when an instance of `rigor_class_name`
        # satisfies `is_a?(target_class_name)` (or
        # `instance_of?(target_class_name)` when `exact: true`).
        # Falls back to the safe `false` when either name does not
        # resolve to a host-Ruby class.
        def subclass_of?(rigor_class_name, target_class_name, exact:)
          return rigor_class_name == target_class_name if exact

          %i[subclass equal].include?(class_ordering(rigor_class_name, target_class_name))
        end

        # Compares two class names through the host Ruby's class
        # hierarchy. Returns `:equal` when they resolve to the same
        # class, `:subclass` when `lhs <= rhs`, `:superclass` when
        # `rhs <= lhs`, `:disjoint` when neither, and `:unknown` when
        # either name does not resolve.
        def class_ordering(lhs, rhs)
          return :equal if lhs == rhs

          klass_a = safe_const_get(lhs)
          klass_b = safe_const_get(rhs)
          return :unknown if klass_a.nil? || klass_b.nil?

          if klass_a <= klass_b
            klass_a == klass_b ? :equal : :subclass
          elsif klass_b <= klass_a
            :superclass
          else
            :disjoint
          end
        end

        def safe_const_get(name)
          Object.const_get(name)
        rescue NameError, ArgumentError
          nil
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
      # rubocop:enable Metrics/ClassLength
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
