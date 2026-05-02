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

      # Integer-comparison fragment of `type` against an Integer
      # literal `bound`. Narrows the receiver of `x < n`, `x <= n`,
      # `x > n`, `x >= n` (and the reversed forms) to the subset of
      # the existing domain that satisfies the comparison. Hooks in:
      # - `Constant<Integer>` is preserved when it satisfies the
      #   comparison, otherwise collapsed to `Bot`.
      # - `IntegerRange[a..b]` becomes the intersection with the
      #   half-line implied by the comparison; an empty intersection
      #   collapses to `Bot`, a single-point intersection collapses
      #   to `Constant<Integer>`.
      # - `Nominal[Integer]` becomes the half-line itself (e.g.
      #   `x > 0` on `Nominal[Integer]` is `positive_int`).
      # - `Union` narrows each member independently.
      # - Other carriers (Float, String, Top, Dynamic) flow through
      #   unchanged: the analyzer does not have a Float-range carrier
      #   today, and no other carrier participates in numeric ordering.
      def narrow_integer_comparison(type, comparator, bound)
        return type unless bound.is_a?(Integer) && %i[< <= > >=].include?(comparator)

        narrow_integer_comparison_dispatch(type, comparator, bound)
      end

      # Equality fragment of `type` against an Integer `value`.
      # `Constant<Integer>` is preserved when it equals `value`,
      # otherwise collapses to `Bot`. `IntegerRange` covers? `value`
      # narrows to `Constant[value]`; an out-of-range comparison
      # collapses to `Bot`. `Nominal[Integer]` narrows to
      # `Constant[value]`. `Union` narrows each member.
      def narrow_integer_equal(type, value)
        return type unless value.is_a?(Integer)

        narrow_integer_equal_dispatch(type, value)
      end

      # Complement of {.narrow_integer_equal}. Removes a single
      # integer value from the domain when one endpoint of an
      # `IntegerRange` is exactly that value (so the result stays a
      # contiguous range). Domains where the value sits strictly
      # between the endpoints stay unchanged: punching a hole would
      # require a two-piece carrier the lattice does not yet model.
      def narrow_integer_not_equal(type, value)
        return type unless value.is_a?(Integer)

        case type
        when Type::Constant
          type.value == value ? Type::Combinator.bot : type
        when Type::IntegerRange
          narrow_integer_range_not_equal(type, value)
        when Type::Union
          Type::Combinator.union(*type.members.map { |m| narrow_integer_not_equal(m, value) })
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
          predicate_result = analyse_rbs_extended_predicate(node, scope)
          assert_result = analyse_rbs_extended_assert_if(node, scope)
          merge_extended_results(predicate_result, assert_result, scope)
        end

        # Combines two `[truthy_scope, falsey_scope]` pair
        # results from sibling RBS::Extended analysers
        # (`predicate-if-*` and `assert-if-*`). When only one
        # side fires, return it directly; when both fire the
        # right side's per-local deltas are applied on top of
        # the left side's edges so the rules compose.
        def merge_extended_results(left, right, base_scope)
          return left if right.nil?
          return right if left.nil?

          [
            merge_scope_pair(left[0], right[0], base_scope),
            merge_scope_pair(left[1], right[1], base_scope)
          ]
        end

        def merge_scope_pair(left_scope, right_scope, base_scope)
          right_scope.locals.reduce(left_scope) do |acc, (name, type)|
            base_type = base_scope.local(name)
            type.equal?(base_type) ? acc : acc.with_local(name, type)
          end
        end

        ZERO_CLASS_PREDICATES = %i[positive? negative? zero? nonzero?].freeze
        COMPARISON_OPERATORS = %i[< <= > >=].freeze
        private_constant :ZERO_CLASS_PREDICATES, :COMPARISON_OPERATORS

        def dispatch_call(node, scope, name)
          return dispatch_call_simple(node, scope, name) if simple_dispatch_name?(name)

          dispatch_call_numeric(node, scope, name)
        end

        def simple_dispatch_name?(name)
          %i[nil? ! is_a? kind_of? instance_of? == != ===].include?(name)
        end

        def dispatch_call_simple(node, scope, name)
          case name
          when :nil?, :! then dispatch_unary_predicate(node, scope, name)
          when :is_a?, :kind_of? then analyse_class_predicate(node, scope, exact: false)
          when :instance_of? then analyse_class_predicate(node, scope, exact: true)
          when :==, :!= then analyse_equality_predicate(node, scope, equality: name)
          when :=== then analyse_case_equality_predicate(node, scope)
          end
        end

        def dispatch_call_numeric(node, scope, name)
          if COMPARISON_OPERATORS.include?(name)
            analyse_comparison_predicate(node, scope, comparator: name)
          elsif ZERO_CLASS_PREDICATES.include?(name)
            analyse_zero_class_predicate(node, scope, predicate: name)
          elsif name == :between?
            analyse_between_predicate(node, scope)
          end
        end

        # `:positive?` / `:negative?` / `:zero?` / `:nonzero?` are
        # zero-arg predicates on `Numeric`. We model them as
        # comparisons against the literal 0 so the existing range
        # narrowing handles them uniformly.
        ZERO_CLASS_PREDICATE_RULES = {
          positive?: { truthy: [:>, 0],  falsey: [:<=, 0] },
          negative?: { truthy: [:<, 0],  falsey: [:>=, 0] },
          zero?: { truthy: [:eq, 0], falsey: [:ne, 0] },
          nonzero?: { truthy: [:ne, 0], falsey: [:eq, 0] }
        }.freeze
        private_constant :ZERO_CLASS_PREDICATE_RULES

        def analyse_zero_class_predicate(node, scope, predicate:)
          return nil unless argument_free?(node)
          return nil unless node.receiver.is_a?(Prism::LocalVariableReadNode)

          local_name = node.receiver.name
          current = scope.local(local_name)
          return nil if current.nil?

          rules = ZERO_CLASS_PREDICATE_RULES[predicate]
          truthy = apply_zero_rule(current, rules[:truthy])
          falsey = apply_zero_rule(current, rules[:falsey])
          [scope.with_local(local_name, truthy), scope.with_local(local_name, falsey)]
        end

        def apply_zero_rule(type, rule)
          case rule[0]
          when :eq then narrow_integer_equal(type, rule[1])
          when :ne then narrow_integer_not_equal(type, rule[1])
          else
            narrow_integer_comparison(type, rule[0], rule[1])
          end
        end

        # `x.between?(a, b)` truthy edge narrows to
        # `narrow_integer_comparison(>=, a)` ∩
        # `narrow_integer_comparison(<=, b)`. The falsey edge is left
        # unchanged because the complement is a two-piece domain
        # (`x < a || x > b`) that the lattice cannot express
        # precisely. `a` and `b` MUST both be integer literals.
        def analyse_between_predicate(node, scope)
          return nil unless node.receiver.is_a?(Prism::LocalVariableReadNode)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 2

          low, high = node.arguments.arguments
          return nil unless low.is_a?(Prism::IntegerNode) && high.is_a?(Prism::IntegerNode)

          local_name = node.receiver.name
          current = scope.local(local_name)
          return nil if current.nil?

          truthy = narrow_integer_comparison(
            narrow_integer_comparison(current, :>=, low.value),
            :<=, high.value
          )
          [scope.with_local(local_name, truthy), scope]
        end

        # Helper for {.narrow_integer_not_equal}. Only adjusts when the
        # value sits exactly on one endpoint, so the result stays
        # contiguous; otherwise the input range is preserved.
        def narrow_integer_range_not_equal(range, value)
          return range if range.lower > value || range.upper < value
          return Type::Combinator.bot if single_point_range_equal?(range, value)
          return build_narrowing_integer_range(value + 1, range.upper) if range.lower == value
          return build_narrowing_integer_range(range.lower, value - 1) if range.upper == value

          range
        end

        def single_point_range_equal?(range, value)
          range.finite? && range.min == value && range.max == value
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

        # Comparison predicate analyser. Recognised shapes:
        #   x  <  Int        x  <=  Int        x  >  Int        x  >=  Int
        #   Int <  x         Int <=  x         Int >  x         Int >=  x
        # The reversed (literal-on-left) form is normalised by
        # transposing the operator so the receiver-local always
        # appears on the left of the rule.
        INVERT_COMPARISON_OP = { :< => :>=, :<= => :>, :> => :<=, :>= => :< }.freeze
        REVERSE_COMPARISON_OP = { :< => :>, :<= => :>=, :> => :<, :>= => :<= }.freeze
        private_constant :INVERT_COMPARISON_OP, :REVERSE_COMPARISON_OP

        def analyse_comparison_predicate(node, scope, comparator:)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          match = comparison_local_literal(node.receiver, node.arguments.arguments.first, comparator)
          return nil if match.nil?

          local_name, normalised_op, bound = match
          current = scope.local(local_name)
          return nil if current.nil?

          truthy = narrow_integer_comparison(current, normalised_op, bound)
          falsey = narrow_integer_comparison(current, INVERT_COMPARISON_OP[normalised_op], bound)
          [scope.with_local(local_name, truthy), scope.with_local(local_name, falsey)]
        end

        def comparison_local_literal(left, right, comparator)
          if left.is_a?(Prism::LocalVariableReadNode) && right.is_a?(Prism::IntegerNode)
            return [left.name, comparator, right.value]
          end
          return nil unless right.is_a?(Prism::LocalVariableReadNode) && left.is_a?(Prism::IntegerNode)

          [right.name, REVERSE_COMPARISON_OP[comparator], left.value]
        end

        def narrow_integer_equal_dispatch(type, value)
          case type
          when Type::Constant then narrow_integer_equal_constant(type, value)
          when Type::IntegerRange then narrow_integer_equal_range(type, value)
          when Type::Nominal then narrow_integer_equal_nominal(type, value)
          when Type::Union
            Type::Combinator.union(*type.members.map { |m| narrow_integer_equal(m, value) })
          else type
          end
        end

        def narrow_integer_equal_constant(constant, value)
          constant.value == value ? constant : Type::Combinator.bot
        end

        def narrow_integer_equal_range(range, value)
          range.covers?(value) ? Type::Combinator.constant_of(value) : Type::Combinator.bot
        end

        def narrow_integer_equal_nominal(nominal, value)
          return nominal unless nominal.class_name == "Integer" && nominal.type_args.empty?

          Type::Combinator.constant_of(value)
        end

        def narrow_integer_comparison_dispatch(type, comparator, bound)
          case type
          when Type::Constant
            integer_constant_satisfies?(type.value, comparator, bound) ? type : Type::Combinator.bot
          when Type::IntegerRange
            intersect_integer_range(type, comparator, bound)
          when Type::Nominal
            narrow_integer_comparison_nominal(type, comparator, bound)
          when Type::Union
            Type::Combinator.union(
              *type.members.map { |m| narrow_integer_comparison(m, comparator, bound) }
            )
          else
            type
          end
        end

        def narrow_integer_comparison_nominal(nominal, comparator, bound)
          return nominal unless nominal.class_name == "Integer" && nominal.type_args.empty?

          intersect_integer_range(Type::Combinator.universal_int, comparator, bound)
        end

        def integer_constant_satisfies?(value, comparator, bound)
          return false unless value.is_a?(Integer)

          case comparator
          when :<  then value < bound
          when :<= then value <= bound
          when :>  then value > bound
          when :>= then value >= bound
          end
        end

        def intersect_integer_range(range, comparator, bound)
          new_lower, new_upper = comparison_endpoints(range, comparator, bound)
          return Type::Combinator.bot if new_lower > new_upper

          build_narrowing_integer_range(new_lower, new_upper)
        end

        def comparison_endpoints(range, comparator, bound)
          case comparator
          when :<  then [range.lower, [range.upper, bound - 1].min]
          when :<= then [range.lower, [range.upper, bound].min]
          when :>  then [[range.lower, bound + 1].max, range.upper]
          when :>= then [[range.lower, bound].max, range.upper]
          end
        end

        def build_narrowing_integer_range(lower, upper)
          min = lower == -Float::INFINITY ? Type::IntegerRange::NEG_INFINITY : Integer(lower)
          max = upper == Float::INFINITY ? Type::IntegerRange::POS_INFINITY : Integer(upper)
          if min.is_a?(Integer) && max.is_a?(Integer) && min == max
            Type::Combinator.constant_of(min)
          else
            Type::Combinator.integer_range(min, max)
          end
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

        # v0.0.2 — `assert-if-true` / `assert-if-false`. Reads
        # the conditional assertion effects off the called
        # method and narrows the matching argument on the
        # corresponding edge. The unconditional `assert`
        # variant is NOT applied here; `StatementEvaluator`
        # applies it directly to the post-call scope.
        def analyse_rbs_extended_assert_if(node, scope)
          method_def = resolve_rbs_extended_method(node, scope)
          return nil if method_def.nil?

          effects = RbsExtended.read_assert_effects(method_def).reject(&:always?)
          return nil if effects.empty?

          truthy_scope = scope
          falsey_scope = scope
          effects.each do |effect|
            truthy_scope, falsey_scope =
              apply_assert_if_effect(effect, node, scope, truthy_scope, falsey_scope, method_def)
          end
          [truthy_scope, falsey_scope]
        end

        # rubocop:disable Metrics/ParameterLists
        def apply_assert_if_effect(effect, call_node, entry_scope, truthy_scope, falsey_scope, method_def)
          target_node = effect_target_node(effect, call_node, method_def)
          return [truthy_scope, falsey_scope] unless target_node.is_a?(Prism::LocalVariableReadNode)

          local_name = target_node.name
          current = entry_scope.local(local_name)
          return [truthy_scope, falsey_scope] if current.nil?

          narrowed = narrow_for_effect(current, effect, entry_scope.environment)
          if effect.if_truthy_return?
            [truthy_scope.with_local(local_name, narrowed), falsey_scope]
          else
            [truthy_scope, falsey_scope.with_local(local_name, narrowed)]
          end
        end
        # rubocop:enable Metrics/ParameterLists

        # v0.0.2 #3 — resolves an effect's target node. For
        # `target: <param>` we look up the matching positional
        # argument; for `target: self` we use the call's
        # receiver. In both cases the caller still requires a
        # `Prism::LocalVariableReadNode` for narrowing to
        # actually fire (the engine's narrowing surface only
        # rebinds locals).
        def effect_target_node(effect, call_node, method_def)
          if effect.target_kind == :self
            call_node.receiver
          else
            lookup_positional_arg(call_node, method_def, effect.target_name)
          end
        end

        # v0.0.2 — selects `narrow_class` (positive) or
        # `narrow_not_class` (negative `~T` form) based on
        # the effect's `negative?` flag. Shared between
        # predicate-if-* and assert-if-* application paths.
        def narrow_for_effect(current, effect, environment)
          return effect.refinement_type if effect.respond_to?(:refinement?) && effect.refinement?

          if effect.negative?
            narrow_not_class(current, effect.class_name, exact: false, environment: environment)
          else
            narrow_class(current, effect.class_name, exact: false, environment: environment)
          end
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
          target_node = effect_target_node(effect, call_node, method_def)
          return [truthy_scope, falsey_scope] unless target_node.is_a?(Prism::LocalVariableReadNode)

          local_name = target_node.name
          current = entry_scope.local(local_name)
          return [truthy_scope, falsey_scope] if current.nil?

          narrowed = narrow_for_effect(current, effect, entry_scope.environment)
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
            applied = apply_case_when_condition(scope, current, condition, falsey_type)
            if applied
              truthy_members << applied[:truthy]
              falsey_type = applied[:falsey]
              fully_narrowable &&= applied[:fully_narrowable]
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

        # Per-condition rule. Returns `nil` when the condition shape
        # is not recognised (caller marks `fully_narrowable = false`),
        # or `{truthy:, falsey:, fully_narrowable:}` when it is.
        def apply_case_when_condition(scope, current, condition, falsey_acc)
          int_range = case_equality_integer_range(condition)
          return integer_range_when_result(current, int_range, falsey_acc) if int_range && integer_rooted_type?(current)

          int_literal = case_equality_integer_literal(condition)
          if int_literal && integer_rooted_type?(current)
            return integer_literal_when_result(current, int_literal, falsey_acc)
          end

          target = static_class_name(condition) || case_equality_target_class(condition)
          return class_when_result(scope, current, target, falsey_acc) if target

          nil
        end

        def case_equality_integer_literal(condition)
          condition = unwrap_parens(condition)
          condition.is_a?(Prism::IntegerNode) ? condition.value : nil
        end

        def integer_literal_when_result(current, value, falsey_acc)
          # `case n when k` is `k === n` which for Integer is value
          # equality. The truthy edge collapses the local to
          # `Constant[k]`; the falsey edge tightens via
          # `narrow_integer_not_equal` (only effective when k sits
          # at one endpoint of the current range).
          {
            truthy: narrow_integer_equal(current, value),
            falsey: narrow_integer_not_equal(falsey_acc, value),
            fully_narrowable: true
          }
        end

        def integer_range_when_result(current, range_pair, falsey_acc)
          low, high = range_pair
          truthy = narrow_integer_comparison(
            narrow_integer_comparison(current, :>=, low),
            :<=, high
          )
          # The falsey edge of `n in [a, b]` is two-piece; we cannot
          # express the complement precisely with a single carrier,
          # so keep the accumulator unchanged. `fully_narrowable: false`
          # forces the else-branch to see `current` (the unmodified
          # entry type), which mirrors `between?` falsey behaviour.
          { truthy: truthy, falsey: falsey_acc, fully_narrowable: false }
        end

        def class_when_result(scope, current, target, falsey_acc)
          {
            truthy: narrow_class(current, target, exact: false, environment: scope.environment),
            falsey: narrow_not_class(falsey_acc, target, exact: false, environment: scope.environment),
            fully_narrowable: true
          }
        end

        # Returns `[low, high]` for a `Prism::RangeNode` whose
        # endpoints are both `Prism::IntegerNode` literals, with
        # `..`/`...` exclusivity respected. Open-ended ranges use
        # the symbolic infinities so the existing comparison
        # narrowing tier handles them. Returns `nil` for any other
        # shape (Float endpoints, String endpoints, dynamic
        # expressions).
        def case_equality_integer_range(condition)
          condition = unwrap_parens(condition)
          return nil unless condition.is_a?(Prism::RangeNode)

          low = integer_range_endpoint(condition.left, default: Type::IntegerRange::NEG_INFINITY)
          high = integer_range_endpoint(condition.right, default: Type::IntegerRange::POS_INFINITY)
          return nil if low.nil? || high.nil?

          high -= 1 if condition.exclude_end? && high.is_a?(Integer)
          [low, high]
        end

        def integer_range_endpoint(node, default:)
          return default if node.nil?
          return node.value if node.is_a?(Prism::IntegerNode)

          nil
        end

        def integer_rooted_type?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer)
          when Type::IntegerRange then true
          when Type::Nominal then type.class_name == "Integer" && type.type_args.empty?
          when Type::Union then type.members.all? { |m| integer_rooted_type?(m) }
          else false
          end
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
