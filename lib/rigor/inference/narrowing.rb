# frozen_string_literal: true

require "prism"

require_relative "../type"
require_relative "../environment"
require_relative "../rbs_extended"
require_relative "../analysis/fact_store"

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
    # bindings on truthiness and `nil?`; phase 2 extends the catalogue
    # with class-membership predicates (`is_a?`, `kind_of?`,
    # `instance_of?`) and trusted equality/inequality checks against
    # static literals.
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
      TRUSTED_EQUALITY_LITERAL_CLASSES = [String, Symbol, Integer, TrueClass, FalseClass, NilClass].freeze
      SINGLETON_LITERAL_CLASSES = [TrueClass, FalseClass, NilClass].freeze
      ClassNarrowingContext = Data.define(:exact, :polarity, :environment)
      private_constant :TRUSTED_EQUALITY_LITERAL_CLASSES, :SINGLETON_LITERAL_CLASSES, :ClassNarrowingContext

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

      # Equality fragment of `type` against a trusted literal.
      #
      # String/Symbol/Integer equality narrows only when the current
      # domain is already a finite union of trusted literals. Nil and
      # booleans are singleton values, so they can be extracted from a
      # mixed union such as `Integer | nil` without manufacturing a new
      # positive domain from the comparison alone.
      def narrow_equal(type, literal)
        return type unless trusted_equality_literal?(literal)

        if singleton_literal?(literal)
          narrow_singleton_equal(type, literal)
        elsif finite_trusted_literal_domain?(type)
          narrow_finite_equal(type, literal)
        else
          type
        end
      end

      # Complement of {.narrow_equal}. Negative facts are domain-relative:
      # they remove a literal from an already-known domain but do not create
      # an unbounded difference type when the domain is broad or dynamic.
      def narrow_not_equal(type, literal)
        return type unless trusted_equality_literal?(literal)

        if singleton_literal?(literal)
          narrow_singleton_not_equal(type, literal)
        elsif finite_trusted_literal_domain?(type)
          narrow_finite_not_equal(type, literal)
        else
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
      # Nominal narrowing is hierarchy-aware through the analyzer
      # environment: when the bound type is a supertype of
      # `class_name` the result narrows DOWN to `Nominal[class_name]`
      # (e.g., `Numeric & Integer = Integer`); when the bound type is
      # already a subtype it is preserved; disjoint hierarchies
      # collapse to `Bot`. Classes the environment cannot resolve
      # fall back to the conservative answer (the type unchanged) so
      # the analyzer never asserts narrowing it cannot prove.
      def narrow_class(type, class_name, exact: false, environment: Environment.default)
        context = ClassNarrowingContext.new(exact: exact, polarity: :positive, environment: environment)
        narrow_class_dispatch(type, class_name, context)
      end

      # Mirror of {.narrow_class} for the falsey edge of
      # `is_a?`/`kind_of?`/`instance_of?`. Inhabitants that DO
      # satisfy the predicate are removed; inhabitants that do not
      # are preserved. Conservative on Top/Dynamic/Bot (preserved
      # unchanged) because the analyzer cannot prove the negative
      # without a richer carrier.
      def narrow_not_class(type, class_name, exact: false, environment: Environment.default)
        context = ClassNarrowingContext.new(exact: exact, polarity: :negative, environment: environment)
        narrow_class_dispatch(type, class_name, context)
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

      # Slice 7 phase 5 — `case`/`when` narrowing.
      #
      # Given the subject of a `case` (the expression after the
      # `case` keyword) and an array of `when`-clause condition
      # nodes (`when_clause.conditions`), returns a pair of
      # scopes:
      #
      # - `body_scope`: the scope under which the body of the
      #   `when` clause MUST be evaluated. The subject local is
      #   narrowed by the union of every condition's truthy
      #   edge so the body sees the most specific type
      #   compatible with "any of the conditions matched".
      # - `falsey_scope`: the scope under which the next branch
      #   (the next `when` or the `else`) MUST be evaluated.
      #   The subject is narrowed by the conjunction of every
      #   condition's falsey edge.
      #
      # The narrowing is best-effort: if the subject is not a
      # `Prism::LocalVariableReadNode` or none of the condition
      # shapes are recognised, both returned scopes equal the
      # input scope. The catalogue mirrors
      # {.case_equality_target_class}: static class/module
      # constants narrow as `is_a?`; integer/float-endpoint
      # ranges narrow to `Numeric`; string-endpoint ranges and
      # regexp literals narrow to `String`.
      #
      # @param subject [Prism::Node, nil] the `case` subject.
      # @param conditions [Array<Prism::Node>] the `when`
      #   clause's `conditions` array.
      # @param scope [Rigor::Scope]
      # @return [Array(Rigor::Scope, Rigor::Scope)]
      def case_when_scopes(subject, conditions, scope)
        return [scope, scope] unless subject.is_a?(Prism::LocalVariableReadNode)

        local_name = subject.name
        current = scope.local(local_name)
        return [scope, scope] if current.nil?

        accumulate_case_when_scopes(scope, local_name, current, conditions)
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

        def trusted_equality_literal?(literal)
          literal.is_a?(Type::Constant) &&
            TRUSTED_EQUALITY_LITERAL_CLASSES.include?(literal.value.class)
        end

        def singleton_literal?(literal)
          SINGLETON_LITERAL_CLASSES.include?(literal.value.class)
        end

        def finite_trusted_literal_domain?(type)
          case type
          when Type::Bot then true
          when Type::Constant then trusted_equality_literal?(type)
          when Type::Union then type.members.all? { |member| finite_trusted_literal_domain?(member) }
          else false
          end
        end

        def narrow_finite_equal(type, literal)
          case type
          when Type::Bot then type
          when Type::Constant then type == literal ? type : Type::Combinator.bot
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_finite_equal(member, literal) })
          else Type::Combinator.bot
          end
        end

        def narrow_finite_not_equal(type, literal)
          case type
          when Type::Constant then type == literal ? Type::Combinator.bot : type
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_finite_not_equal(member, literal) })
          else type
          end
        end

        def narrow_singleton_equal(type, literal)
          case type
          when Type::Constant then type == literal ? type : Type::Combinator.bot
          when Type::Nominal then singleton_nominal_matches?(type, literal) ? type : Type::Combinator.bot
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_singleton_equal(member, literal) })
          else narrow_singleton_equal_other(type)
          end
        end

        def narrow_singleton_equal_other(type)
          case type
          when Type::Singleton, Type::Tuple, Type::HashShape then Type::Combinator.bot
          else type
          end
        end

        def narrow_singleton_not_equal(type, literal)
          case type
          when Type::Constant then type == literal ? Type::Combinator.bot : type
          when Type::Nominal then singleton_nominal_matches?(type, literal) ? Type::Combinator.bot : type
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_singleton_not_equal(member, literal) })
          else type
          end
        end

        def singleton_nominal_matches?(nominal, literal)
          case literal.value
          when nil then nominal.class_name == "NilClass"
          when true then nominal.class_name == "TrueClass"
          when false then nominal.class_name == "FalseClass"
          else false
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
        # - `local == literal` / `literal == local` and the `!=` mirror
        #   for trusted static literals (Slice 6 phase 2 sub-phase 2).
        # Anything else returns nil so the surrounding analyser falls
        # through to the no-narrowing fallback.
        def analyse_call(node, scope)
          return nil if node.block
          return nil if node.receiver.nil?

          shape_result = dispatch_call(node, scope, node.name)
          return shape_result if shape_result

          # Slice 7 phase 15 — RBS::Extended predicate
          # effects. When the method's RBS signature carries
          # `rigor:v1:predicate-if-true` / `predicate-if-false`
          # annotations, apply them to narrow the corresponding
          # local-variable arguments on each edge.
          analyse_rbs_extended_predicate(node, scope)
        end

        def dispatch_call(node, scope, name)
          case name
          when :nil?, :! then dispatch_unary_predicate(node, scope, name)
          when :is_a?, :kind_of? then analyse_class_predicate(node, scope, exact: false)
          when :instance_of? then analyse_class_predicate(node, scope, exact: true)
          when :==, :!= then analyse_equality_predicate(node, scope, equality: name)
          when :=== then analyse_case_equality_predicate(node, scope)
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

        def analyse_equality_predicate(node, scope, equality:)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          match = equality_local_literal(node.receiver, node.arguments.arguments.first, scope)
          return nil if match.nil?

          name, literal = match
          current = scope.local(name)
          return nil if current.nil?

          positive = equality_scope(scope, name, current, literal, predicate: :==)
          negative = equality_scope(scope, name, current, literal, predicate: :!=)
          equality == :== ? [positive, negative] : [negative, positive]
        end

        def equality_local_literal(left, right, scope)
          if left.is_a?(Prism::LocalVariableReadNode)
            literal = static_literal_type(right, scope)
            return [left.name, literal] if trusted_equality_literal?(literal)
          end

          return nil unless right.is_a?(Prism::LocalVariableReadNode)

          literal = static_literal_type(left, scope)
          return [right.name, literal] if trusted_equality_literal?(literal)

          nil
        end

        def static_literal_type(node, scope)
          case node
          when Prism::IntegerNode,
               Prism::StringNode,
               Prism::SymbolNode,
               Prism::TrueNode,
               Prism::FalseNode,
               Prism::NilNode
            scope.type_of(node)
          end
        end

        def equality_scope(scope, name, current, literal, predicate:)
          narrowed =
            if predicate == :==
              narrow_equal(current, literal)
            else
              narrow_not_equal(current, literal)
            end

          scope
            .with_local(name, narrowed)
            .with_fact(equality_fact(name, current, narrowed, literal, predicate: predicate))
        end

        def equality_fact(name, original, narrowed, literal, predicate:)
          Analysis::FactStore::Fact.new(
            bucket: equality_fact_bucket(original, narrowed),
            target: Analysis::FactStore::Target.local(name),
            predicate: predicate,
            payload: literal,
            polarity: predicate == :== ? :positive : :negative,
            stability: :local_binding
          )
        end

        def equality_fact_bucket(original, narrowed)
          narrowed == original ? :relational : :local_binding
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

          class_predicate_scopes(scope, node.receiver.name, current, class_name, exact: exact)
        end

        def class_predicate_scopes(scope, name, current, class_name, exact:)
          [
            scope.with_local(
              name,
              narrow_class(current, class_name, exact: exact, environment: scope.environment)
            ),
            scope.with_local(
              name,
              narrow_not_class(current, class_name, exact: exact, environment: scope.environment)
            )
          ]
        end

        # Slice 7 phase 4 — `===`-narrowing. The case-equality
        # predicate `<receiver> === local` is the operator that
        # backs Ruby's `case`/`when` dispatch. Three receiver
        # shapes produce sound narrowing rules:
        #
        # - **Class / Module receiver**: `Foo === x` is
        #   isomorphic to `x.is_a?(Foo)` (the default behaviour
        #   of `Module#===`). Reuse `class_predicate_scopes` so
        #   the truthy edge narrows down to `Foo` and the falsey
        #   edge subtracts `Foo` from a union.
        # - **Range literal receiver** (`(1..10) === x`): the
        #   default `Range#===` includes `x` iff the endpoints
        #   compare it. We conservatively narrow `x` to
        #   `Numeric` for integer-endpoint ranges and to
        #   `String` for string-endpoint ranges; other endpoint
        #   types fall through.
        # - **Regexp literal receiver** (`/foo/ === x`): the
        #   match operator coerces `x` to a String, so the
        #   truthy edge narrows `x` to `String`. The falsey
        #   edge keeps the entry type unchanged because
        #   `Regexp#===` returns false for non-Strings AND for
        #   Strings that simply do not match.
        #
        # Anything else — non-local LHS argument, dynamic
        # receiver, custom `===` method — falls through to
        # the no-narrowing branch (nil), preserving the
        # entry scope on both edges.
        def analyse_case_equality_predicate(node, scope)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          local_arg = node.arguments.arguments.first
          return nil unless local_arg.is_a?(Prism::LocalVariableReadNode)

          current = scope.local(local_arg.name)
          return nil if current.nil?

          analyse_case_equality_receiver(node.receiver, scope, local_arg.name, current)
        end

        def analyse_case_equality_receiver(receiver, scope, local_name, current)
          if (class_name = static_class_name(receiver))
            return class_predicate_scopes(scope, local_name, current, class_name, exact: false)
          end

          target_class = case_equality_target_class(receiver)
          return nil if target_class.nil?

          narrowed = narrow_class(current, target_class, exact: false, environment: scope.environment)
          [
            scope.with_local(local_name, narrowed),
            scope.with_local(local_name, current)
          ]
        end

        # Maps a case-equality literal receiver to the class
        # whose membership is implied by the truthy edge.
        # `Prism::ParenthesesNode` wrappers are transparently
        # unwrapped (`(1..10) === x` is parsed with the range
        # inside parentheses).  Range literals: integer
        # endpoints → `Numeric`; string endpoints → `String`.
        # Regexp literals → `String`. Other shapes return nil
        # so the caller falls through.
        def case_equality_target_class(receiver)
          receiver = unwrap_parens(receiver)
          case receiver
          when Prism::RangeNode then range_target_class(receiver)
          when Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode then "String"
          end
        end

        def unwrap_parens(node)
          while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) &&
                node.body.body.size == 1
            node = node.body.body.first
          end
          node
        end

        # Slice 7 phase 15 — RBS::Extended predicate-effect
        # analyser. Resolves the called method through the
        # RBS environment, reads any `rigor:v1:predicate-if-*`
        # annotations, and applies them to the call's
        # local-variable arguments.
        #
        # Conservative envelope:
        # - Receiver type must be `Type::Nominal`,
        #   `Type::Singleton`, or `Type::Constant`.
        # - The method must be present in the loader.
        # - For each predicate effect, the corresponding
        #   positional argument (matched by parameter name in
        #   the selected overload) MUST be a
        #   `Prism::LocalVariableReadNode` for narrowing to
        #   apply.
        # - When the target is `self`, narrowing applies to
        #   the receiver — but the engine does not yet narrow
        #   `self` itself (Slice A-engine self-typing is
        #   read-only), so `self`-targeted effects are
        #   accepted by the parser but currently produce no
        #   scope edits.
        def analyse_rbs_extended_predicate(node, scope)
          method_def = resolve_rbs_extended_method(node, scope)
          return nil if method_def.nil?

          effects = RbsExtended.read_predicate_effects(method_def)
          return nil if effects.empty?

          truthy_scope = scope
          falsey_scope = scope
          effects.each do |effect|
            truthy_scope, falsey_scope =
              apply_predicate_effect(effect, node, scope, truthy_scope, falsey_scope, method_def)
          end
          [truthy_scope, falsey_scope]
        end

        def resolve_rbs_extended_method(node, scope)
          loader = scope.environment.rbs_loader
          return nil if loader.nil?

          receiver_type = scope.type_of(node.receiver)
          class_name = rbs_extended_class_name(receiver_type)
          return nil if class_name.nil?
          return nil unless loader.class_known?(class_name)

          if receiver_type.is_a?(Type::Singleton)
            loader.singleton_method(class_name: class_name, method_name: node.name)
          else
            loader.instance_method(class_name: class_name, method_name: node.name)
          end
        rescue StandardError
          nil
        end

        def rbs_extended_class_name(receiver_type)
          case receiver_type
          when Type::Nominal, Type::Singleton then receiver_type.class_name
          when Type::Constant then rbs_extended_constant_class(receiver_type.value)
          end
        end

        CONSTANT_CLASSES = {
          Integer => "Integer", Float => "Float", String => "String",
          Symbol => "Symbol",
          TrueClass => "TrueClass", FalseClass => "FalseClass",
          NilClass => "NilClass"
        }.freeze
        private_constant :CONSTANT_CLASSES

        def rbs_extended_constant_class(value)
          CONSTANT_CLASSES.each { |klass, name| return name if value.is_a?(klass) }
          nil
        end

        # rubocop:disable Metrics/ParameterLists
        def apply_predicate_effect(effect, call_node, entry_scope, truthy_scope, falsey_scope, method_def)
          arg_node = lookup_positional_arg(call_node, method_def, effect.target_name)
          return [truthy_scope, falsey_scope] if effect.target_kind != :parameter
          return [truthy_scope, falsey_scope] unless arg_node.is_a?(Prism::LocalVariableReadNode)

          local_name = arg_node.name
          current = entry_scope.local(local_name)
          return [truthy_scope, falsey_scope] if current.nil?

          narrowed = narrow_class(current, effect.class_name, exact: false, environment: entry_scope.environment)
          if effect.truthy_only?
            [truthy_scope.with_local(local_name, narrowed), falsey_scope]
          else
            [truthy_scope, falsey_scope.with_local(local_name, narrowed)]
          end
        end
        # rubocop:enable Metrics/ParameterLists

        # Maps the effect's target parameter name to the call
        # site argument by inspecting the selected overload's
        # required-positional parameter list. Returns the Prism
        # arg node at that position, or nil when the overload
        # shape does not allow a precise match.
        def lookup_positional_arg(call_node, method_def, target_name)
          arguments = call_node.arguments&.arguments || []
          method_def.method_types.each do |mt|
            params = mt.type.required_positionals + mt.type.optional_positionals
            index = params.find_index { |param| param.name == target_name }
            return arguments[index] if index && arguments[index]
          end
          nil
        end

        # Slice 7 phase 5 — case/when accumulator. Walks each
        # `when` condition, computes the narrowed type for the
        # subject as if `condition === subject`, and accumulates
        # them. The body's narrowed type is the union across
        # all conditions; the falsey type is the running result
        # after subtracting every condition's class. Conditions
        # whose shape we cannot statically classify are treated
        # as "no narrowing": the body falls back to the union of
        # what we did learn (or the entry type when nothing
        # learned), and the falsey edge is the entry type
        # (because we cannot prove the unknown condition didn't
        # match).
        def accumulate_case_when_scopes(scope, local_name, current, conditions)
          truthy_members = []
          falsey_type = current
          fully_narrowable = true

          conditions.each do |condition|
            target = static_class_name(condition) || case_equality_target_class(condition)
            if target
              truthy_members << narrow_class(current, target, exact: false, environment: scope.environment)
              falsey_type = narrow_not_class(falsey_type, target, exact: false, environment: scope.environment)
            else
              fully_narrowable = false
            end
          end

          truthy = truthy_members.empty? ? current : Type::Combinator.union(*truthy_members)
          [
            scope.with_local(local_name, truthy),
            scope.with_local(local_name, fully_narrowable ? falsey_type : current)
          ]
        end

        def range_target_class(range_node)
          left = range_node.left
          right = range_node.right
          return "Numeric" if integer_endpoint?(left) || integer_endpoint?(right)

          "String" if string_endpoint?(left) || string_endpoint?(right)
        end

        def integer_endpoint?(node)
          node.is_a?(Prism::IntegerNode) || node.is_a?(Prism::FloatNode)
        end

        def string_endpoint?(node)
          node.is_a?(Prism::StringNode)
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
        def narrow_class_dispatch(type, class_name, context)
          case type
          when Type::Constant then narrow_constant_class(type, class_name, context)
          when Type::Nominal then narrow_nominal_class(type, class_name, context)
          when Type::Union then narrow_union_class(type, class_name, context)
          when Type::Tuple then narrow_shape_class(type, "Array", class_name, context)
          when Type::HashShape then narrow_shape_class(type, "Hash", class_name, context)
          when Type::Singleton then narrow_singleton_class(type, class_name, context)
          else narrow_other_class(type, class_name, context)
          end
        end

        def narrow_constant_class(constant, class_name, context)
          if context.polarity == :positive
            narrow_constant_to_class(constant, class_name, context)
          else
            narrow_constant_not_class(constant, class_name, context)
          end
        end

        def narrow_nominal_class(nominal, class_name, context)
          if context.polarity == :positive
            narrow_nominal_to_class(nominal, class_name, context)
          else
            narrow_nominal_not_class(nominal, class_name, context)
          end
        end

        def narrow_union_class(union, class_name, context)
          Type::Combinator.union(
            *union.members.map { |member| narrow_class_dispatch(member, class_name, context) }
          )
        end

        def narrow_shape_class(shape, projected_class, class_name, context)
          if context.polarity == :positive
            narrow_shape_to_class(shape, projected_class, class_name, context)
          else
            narrow_shape_not_class(shape, projected_class, class_name, context)
          end
        end

        def narrow_singleton_class(singleton, class_name, context)
          if context.polarity == :positive
            narrow_singleton_to_class(singleton, class_name, context)
          else
            narrow_singleton_not_class(singleton, class_name, context)
          end
        end

        def narrow_other_class(type, class_name, context)
          context.polarity == :positive ? narrow_class_other(type, class_name) : type
        end

        def narrow_constant_to_class(constant, class_name, context)
          rigor_class = constant.value.class.name
          subclass_of?(rigor_class, class_name, context) ? constant : Type::Combinator.bot
        end

        def narrow_constant_not_class(constant, class_name, context)
          rigor_class = constant.value.class.name
          subclass_of?(rigor_class, class_name, context) ? Type::Combinator.bot : constant
        end

        # Narrow a Nominal under `is_a?(class_name)`: when the
        # nominal's class is already a subclass of `class_name`
        # (or matches under `exact: true`) preserve it; when
        # `class_name` is a subclass of the nominal's class
        # (`Nominal[Numeric]` under `is_a?(Integer)`) narrow DOWN
        # to `Nominal[class_name]`; otherwise (disjoint hierarchies
        # under `is_a?`, mismatch under `instance_of?`) collapse to
        # `Bot`. Conservative when the analyzer environment cannot
        # resolve either class.
        def narrow_nominal_to_class(nominal, class_name, context)
          return nominal if nominal.class_name == class_name
          return Type::Combinator.bot if context.exact

          case class_ordering(nominal.class_name, class_name, context)
          when :superclass then Type::Combinator.nominal_of(class_name)
          when :disjoint then Type::Combinator.bot
          else nominal # :subclass preserves the bound; :unknown stays conservative
          end
        end

        def narrow_nominal_not_class(nominal, class_name, context)
          return Type::Combinator.bot if nominal.class_name == class_name
          return nominal if context.exact

          ordering = class_ordering(nominal.class_name, class_name, context)
          case ordering
          when :subclass then Type::Combinator.bot
          else nominal
          end
        end

        def narrow_shape_to_class(shape, projected_class, class_name, context)
          subclass_of?(projected_class, class_name, context) ? shape : Type::Combinator.bot
        end

        def narrow_shape_not_class(shape, projected_class, class_name, context)
          subclass_of?(projected_class, class_name, context) ? Type::Combinator.bot : shape
        end

        # `Singleton[Foo]` is the *class object* `Foo`, an instance of
        # `Class` (which is a subclass of `Module`). Asking
        # `Foo.is_a?(Class)` returns true; `Foo.is_a?(Foo)` returns
        # false unless `Foo` is `Class` itself. We approximate this
        # by treating singletons uniformly as `Class` instances.
        def narrow_singleton_to_class(singleton, class_name, context)
          subclass_of?("Class", class_name, context) ? singleton : Type::Combinator.bot
        end

        def narrow_singleton_not_class(singleton, class_name, context)
          subclass_of?("Class", class_name, context) ? Type::Combinator.bot : singleton
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
        # resolve through the analyzer environment.
        def subclass_of?(rigor_class_name, target_class_name, context)
          return rigor_class_name == target_class_name if context.exact

          %i[subclass equal].include?(
            class_ordering(rigor_class_name, target_class_name, context)
          )
        end

        # Compares two class names through the analyzer environment.
        # Returns `:equal` when they resolve to the same class,
        # `:subclass` when `lhs <= rhs`, `:superclass` when
        # `rhs <= lhs`, `:disjoint` when neither, and `:unknown` when
        # either name does not resolve.
        def class_ordering(lhs, rhs, context)
          return :equal if lhs == rhs

          context.environment.class_ordering(lhs, rhs)
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
