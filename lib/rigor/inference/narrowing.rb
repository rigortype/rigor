# frozen_string_literal: true

require "prism"

require_relative "../reflection"
require_relative "../source/constant_path"
require_relative "../type"
require_relative "../environment"
require_relative "../rbs_extended"
require_relative "../analysis/fact_store"
require_relative "../builtins/regex_refinement"

module Rigor
  module Inference
    # Control-flow predicate narrowing and type-lattice narrowing primitives.
    #
    # `Rigor::Inference::Narrowing` answers two related questions:
    #
    # 1. Type-level narrowing: given a `Rigor::Type` value, what is its truthy fragment, its
    #    falsey fragment, its nil fragment, and its non-nil fragment? These primitives
    #    understand the value-lattice algebra (`Constant`, `Nominal`, `Singleton`, `Tuple`,
    #    `HashShape`, `Union`) and stay conservative on `Top` and `Dynamic[T]`.
    # 2. Predicate-level narrowing: given a Prism predicate node and an entry scope, what are the
    #    truthy-edge scope and the falsey-edge scope? The catalogue covers truthiness, `nil?`,
    #    `!`, `&&`/`||`, class-membership (`is_a?`, `kind_of?`, `instance_of?`), trusted
    #    equality/inequality against static literals, `case`/`when`, regex match globals, string
    #    predicates (`start_with?` etc.), key-presence, array emptiness, numeric comparison, and
    #    `respond_to?`.
    #
    # Consumed by `Rigor::Inference::StatementEvaluator` to refine `then`/`else` scopes of
    # `IfNode`/`UnlessNode` and `case`/`when` branches.
    #
    # The module is pure: every public function returns fresh values and MUST NOT mutate its
    # inputs. Unrecognised predicate shapes degrade silently to "no narrowing" by returning
    # `nil` from the internal analyser; the public `predicate_scopes` always returns an
    # `[truthy_scope, falsey_scope]` pair (the entry scope twice when no rule matches).
    #
    # See docs/internal-spec/inference-engine.md (Narrowing) and
    # docs/type-specification/control-flow-analysis.md for the binding contract.
    # rubocop:disable-next Metrics/ModuleLength
    module Narrowing
      TRUSTED_EQUALITY_LITERAL_CLASSES = [String, Symbol, Integer, TrueClass, FalseClass, NilClass].freeze
      SINGLETON_LITERAL_CLASSES = [TrueClass, FalseClass, NilClass].freeze
      ClassNarrowingContext = Data.define(:exact, :polarity, :environment)
      # A recognised `=~` regex pattern operand: the pattern `source` string and whether it was
      # compiled in extended (`//x`) mode. Extraction from a literal `RegularExpressionNode` and from
      # a value-pinned `Constant[Regexp]` share this carrier so the participation walk and the
      # extended-mode bail read one shape.
      RegexMatchPattern = Data.define(:source, :extended)
      private_constant :TRUSTED_EQUALITY_LITERAL_CLASSES, :SINGLETON_LITERAL_CLASSES, :ClassNarrowingContext,
                       :RegexMatchPattern

      module_function

      # Truthy fragment of `type`: the subset whose inhabitants are truthy in Ruby's sense
      # (anything other than `nil` and `false`).
      #
      # `Top`, `Dynamic[T]`, `Bot`, `Singleton[C]`, `Tuple[*]`, and `HashShape{*}` flow through
      # unchanged: Top/Dynamic stay conservative because the analyzer cannot express the
      # difference type without a richer carrier and Dynamic must preserve its provenance under
      # the value-lattice algebra; the remaining carriers are already truthy by inhabitance.
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

      # Falsey fragment of `type`: the subset whose inhabitants are `nil` or `false`. Carriers
      # that cannot inhabit a falsey value collapse to `Bot`.
      def narrow_falsey(type)
        case type
        when Type::Constant then falsey_value?(type.value) ? type : Type::Combinator.bot
        when Type::Nominal then falsey_nominal?(type) ? type : Type::Combinator.bot
        when Type::Union then Type::Combinator.union(*type.members.map { |m| narrow_falsey(m) })
        else narrow_falsey_other(type)
        end
      end

      # Nil fragment of `type`: the subset whose inhabitants are `nil`. Used by `nil?` predicate
      # narrowing. `Top`/`Dynamic` narrow to the canonical `Constant[nil]` so downstream
      # dispatch resolves through `NilClass`; carriers that never inhabit `nil` (`Singleton`,
      # `Tuple`, `HashShape`) collapse to `Bot`. `Bot` is its own nil fragment.
      def narrow_nil(type)
        case type
        when Type::Constant then type.value.nil? ? type : Type::Combinator.bot
        when Type::Nominal then type.class_name == "NilClass" ? type : Type::Combinator.bot
        when Type::Union then Type::Combinator.union(*type.members.map { |m| narrow_nil(m) })
        else narrow_nil_other(type)
        end
      end

      # Non-nil fragment of `type`: the subset whose inhabitants are not `nil`. Mirror of
      # {.narrow_nil} for the falsey edge of `x.nil?`.
      def narrow_non_nil(type)
        case type
        when Type::Constant
          type.value.nil? ? Type::Combinator.bot : type
        when Type::Nominal
          type.class_name == "NilClass" ? Type::Combinator.bot : type
        when Type::Union
          Type::Combinator.union(*type.members.map { |m| narrow_non_nil(m) })
        else
          # Top, Dynamic, Singleton, Tuple, HashShape, Bot: there is no nil contribution to
          # remove, so the type is its own non-nil fragment.
          type
        end
      end

      # Three-valued truthiness certainty of a predicate's type, derived from the truthy /
      # falsey fragments above: `:truthy` when no inhabitant is falsey (the falsey fragment is
      # `Bot`), `:falsey` when no inhabitant is truthy, nil when both fragments are inhabited —
      # or when the type itself is nil / `Bot` (dead code is not a certainty claim). This is the
      # single owner of the judgment both branch-elision consumers read
      # (`ExpressionTyper#elide_or_union` on the value side, `StatementEvaluator#live_branch_for_if`
      # on the scope side), so the type a dead branch is elided from and the scope that stops
      # flowing through it can never disagree.
      def predicate_certainty(type)
        return nil if type.nil? || type.is_a?(Type::Bot)

        truthy_bot = narrow_truthy(type).is_a?(Type::Bot)
        falsey_bot = narrow_falsey(type).is_a?(Type::Bot)

        return :falsey if truthy_bot && !falsey_bot
        return :truthy if !truthy_bot && falsey_bot

        nil
      end

      # Three-valued certainty of `C === subject` for a class / module `when` pattern, derived
      # from {.narrow_class} / {.narrow_not_class}: `:no` when no inhabitant of the subject
      # matches, `:yes` when every inhabitant matches, `:maybe` otherwise. The value-side
      # counterpart of the scope narrowing {.case_when_scopes} performs for the same condition
      # shape, kept here so the branch a `case` expression's type drops and the clause whose
      # body scope goes dead derive from one judgment.
      def class_pattern_certainty(subject_type, class_name, environment:)
        truthy_bot = narrow_class(subject_type, class_name, environment: environment).is_a?(Type::Bot)
        falsey_bot = narrow_not_class(subject_type, class_name, environment: environment).is_a?(Type::Bot)

        return :no if truthy_bot && !falsey_bot
        return :yes if !truthy_bot && falsey_bot

        :maybe
      end

      # Classes whose `===` is plain value equality, so a literal `when` pattern against a
      # pinned `Constant` subject is exact in both directions. Anything else keeps custom-`===`
      # semantics and stays `:maybe` in {.value_pattern_certainty}.
      VALUE_EQUALITY_CLASSES = [Integer, Float, Rational, Complex, String, Symbol,
                                TrueClass, FalseClass, NilClass].freeze

      # Three-valued certainty of `<literal> === subject` for a value-equality literal pattern:
      # exact (`:yes` / `:no`) only when the subject is itself a pinned `Constant` of a
      # value-equality class; `:maybe` otherwise (the runtime value isn't pinned, or `===` may
      # be user-defined).
      def value_pattern_certainty(subject_type, pattern_value)
        return :maybe unless subject_type.is_a?(Type::Constant)
        return :maybe unless VALUE_EQUALITY_CLASSES.any? { |klass| subject_type.value.is_a?(klass) }

        pattern_value == subject_type.value ? :yes : :no
      end

      # Equality fragment of `type` against a trusted literal.
      #
      # String/Symbol/Integer equality narrows only when the current domain is already a
      # finite union of trusted literals. Nil and booleans are singleton values, so they can be
      # extracted from a mixed union such as `Integer | nil` without manufacturing a new
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

      # Complement of {.narrow_equal}. Negative facts are domain-relative: they remove a literal
      # from an already-known domain but do not create an unbounded difference type when the
      # domain is broad or dynamic.
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

      # Integer-comparison fragment of `type` against an Integer literal `bound`. Narrows the
      # receiver of `x < n`, `x <= n`, `x > n`, `x >= n` (and the reversed forms) to the subset
      # of the existing domain that satisfies the comparison. Hooks in:
      # - `Constant<Integer>` is preserved when it satisfies the comparison, otherwise collapsed
      #   to `Bot`.
      # - `IntegerRange[a..b]` becomes the intersection with the half-line implied by the
      #   comparison; an empty intersection collapses to `Bot`, a single-point intersection
      #   collapses to `Constant<Integer>`.
      # - `Nominal[Integer]` becomes the half-line itself (e.g. `x > 0` on `Nominal[Integer]` is
      #   `positive_int`).
      # - `Union` narrows each member independently.
      # - Other carriers (Float, String, Top, Dynamic) flow through unchanged: the analyzer does
      #   not have a Float-range carrier today, and no other carrier participates in numeric
      #   ordering.
      def narrow_integer_comparison(type, comparator, bound)
        return type unless bound.is_a?(Integer) && %i[< <= > >=].include?(comparator)

        narrow_integer_comparison_dispatch(type, comparator, bound)
      end

      # Equality fragment of `type` against an Integer `value`. `Constant<Integer>` is preserved
      # when it equals `value`, otherwise collapses to `Bot`. `IntegerRange` covers? `value`
      # narrows to `Constant[value]`; an out-of-range comparison collapses to `Bot`.
      # `Nominal[Integer]` narrows to `Constant[value]`. `Union` narrows each member.
      def narrow_integer_equal(type, value)
        return type unless value.is_a?(Integer)

        narrow_integer_equal_dispatch(type, value)
      end

      # Complement of {.narrow_integer_equal}. Removes a single integer value from the domain
      # when one endpoint of an `IntegerRange` is exactly that value (so the result stays a
      # contiguous range). Domains where the value sits strictly between the endpoints stay
      # unchanged: punching a hole would require a two-piece carrier the lattice does not yet
      # model.
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

      # Class-membership fragment of `type`: the subset whose inhabitants are instances of
      # `class_name` (or its subclasses when `exact: false`). `class_name` is the qualified name
      # of the class as it appears in source (`"Integer"`, `"Foo::Bar"`). Slice 6 phase 2
      # sub-phase 1 narrows the `if x.is_a?(C)` / `if x.kind_of?(C)` / `if x.instance_of?(C)`
      # truthy edge.
      #
      # Nominal narrowing is hierarchy-aware through the analyzer environment: when the bound
      # type is a supertype of `class_name` the result narrows DOWN to `Nominal[class_name]`
      # (e.g., `Numeric & Integer = Integer`); when the bound type is already a subtype it is
      # preserved; disjoint hierarchies collapse to `Bot`. Classes the environment cannot
      # resolve fall back to the conservative answer (the type unchanged) so the analyzer never
      # asserts narrowing it cannot prove.
      def narrow_class(type, class_name, exact: false, environment: Environment.default)
        context = ClassNarrowingContext.new(exact: exact, polarity: :positive, environment: environment)
        narrow_class_dispatch(type, class_name, context)
      end

      # Mirror of {.narrow_class} for the falsey edge of `is_a?`/`kind_of?`/`instance_of?`.
      # Inhabitants that DO satisfy the predicate are removed; inhabitants that do not are
      # preserved. Conservative on Top/Dynamic/Bot (preserved unchanged) because the analyzer
      # cannot prove the negative without a richer carrier.
      def narrow_not_class(type, class_name, exact: false, environment: Environment.default)
        context = ClassNarrowingContext.new(exact: exact, polarity: :negative, environment: environment)
        narrow_class_dispatch(type, class_name, context)
      end

      # Negation pair for `assert_value is ~refinement` / `predicate-if-* … is ~refinement`
      # directives. Computes the complement of `refinement` within the current local's domain
      # `current_type`.
      #
      # Carrier-by-carrier rules:
      #
      # - `Difference[base, Constant[v]]`. Complement of `base \ {v}` within `current_type`.
      #   Walk the current type's union members, keep each part disjoint from `base`, and add
      #   the removed-value Constant once when any current member covers it. `assert s is
      #   ~non-empty-string` over `s: String | nil` narrows to `Constant[""] | NilClass`.
      # - `IntegerRange[a, b]` (v0.0.5+ slice). Complement is the two open halves `int<min,
      #   a-1>` and `int<b+1, max>`, each intersected with the integer-domain parts of
      #   `current_type`. Non-integer parts (nil, String, …) of a Union receiver survive
      #   unchanged. `assert n is ~int<5, 10>` over `n: Integer | nil` narrows to `int<min, 4> |
      #   int<11, max> | NilClass`.
      # - `Type::Intersection[M1, M2, …]` (v0.0.5+ slice). De Morgan: `D \ (M1 ∩ M2) = (D \ M1)
      #   ∪ (D \ M2)`. Each member's complement is computed independently within
      #   `current_type` and the results are unioned. Members the algebra cannot complement
      #   (Refined, non-Constant Difference, …) contribute `current_type` itself, so the union
      #   widens the answer to `current_type` — sound but imprecise.
      # - `Refined[base, predicate]`. Predicate complements are not reducible to a finite
      #   carrier without a richer shape (e.g. `~lowercase-string` is "uppercase OR
      #   mixed-case"); `current_type` is returned unchanged.
      def narrow_not_refinement(current_type, refinement_type)
        case refinement_type
        when Type::Difference
          return current_type unless refinement_type.removed.is_a?(Type::Constant)

          complement_difference(current_type, refinement_type)
        when Type::IntegerRange
          complement_integer_range(current_type, refinement_type)
        when Type::Intersection
          complement_intersection(current_type, refinement_type)
        when Type::Refined
          complement_refined(current_type, refinement_type)
        else
          current_type
        end
      end

      # ADR-7 § "Slice 4-A" — public Fact-shaped narrowing entry. Distinguishes a
      # `Nominal[<class>]`-typed Fact (uses `narrow_class` / `narrow_not_class` for
      # hierarchy-aware narrowing) from a refinement-shaped Fact (refined types, IntegerRange,
      # Difference, …). The implementation lives next to its sibling helpers `narrow_class` and
      # `narrow_not_refinement`; consumers outside `Narrowing` (today:
      # `StatementEvaluator`'s post-return assertion path) reach for it via
      # `Rigor::Inference::Narrowing.narrow_for_fact`.
      def narrow_for_fact(current, fact, environment)
        if fact.type.is_a?(Type::Nominal) && fact.type.type_args.empty?
          class_name = fact.type.class_name
          return narrow_not_class(current, class_name, exact: false, environment: environment) if fact.negative?

          return narrow_class(current, class_name, exact: false, environment: environment)
        end

        return narrow_not_refinement(current, fact.type) if fact.negative?

        fact.type
      end

      # Public predicate analyser. Returns `[truthy_scope, falsey_scope]`, always; when no
      # narrowing rule matches the predicate node both entries are the receiver scope unchanged.
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
      # Given the subject of a `case` (the expression after the `case` keyword) and an array of
      # `when`-clause condition nodes (`when_clause.conditions`), returns a pair of scopes:
      #
      # - `body_scope`: the scope under which the body of the `when` clause MUST be evaluated.
      #   The subject local is narrowed by the union of every condition's truthy edge so the
      #   body sees the most specific type compatible with "any of the conditions matched".
      # - `falsey_scope`: the scope under which the next branch (the next `when` or the `else`)
      #   MUST be evaluated. The subject is narrowed by the conjunction of every condition's
      #   falsey edge.
      #
      # The narrowing is best-effort: if the subject is not a `Prism::LocalVariableReadNode` or
      # none of the condition shapes are recognised, both returned scopes equal the input
      # scope. The catalogue mirrors {.case_equality_target_class}: static class/module
      # constants narrow as `is_a?`; integer/float-endpoint ranges narrow to `Numeric`;
      # string-endpoint ranges and regexp literals narrow to `String`.
      #
      # @param subject [Prism::Node, nil] the `case` subject.
      # @param conditions [Array<Prism::Node>] the `when`
      #   clause's `conditions` array.
      # @param scope [Rigor::Scope]
      # @return [Array(Rigor::Scope, Rigor::Scope)]
      def case_when_scopes(subject, conditions, scope)
        # C1 — `case x when /re/` runs `/re/ === x`, which sets the regex match-data globals
        # exactly as a successful `=~` does. Narrow `$~`/`$&`/`$1..$N` on the clause body (the
        # match edge); the falsey scope keeps the entry globals because a later clause may match
        # a different regex. Applied even when the subject is not a narrowable local read.
        body_scope = apply_when_regex_globals(conditions, scope)

        return [body_scope, scope] unless subject.is_a?(Prism::LocalVariableReadNode)

        local_name = subject.name
        current = scope.local(local_name)
        return [body_scope, scope] if current.nil?

        truthy, = accumulate_case_when_scopes(body_scope, local_name, current, conditions)
        _, falsey = accumulate_case_when_scopes(scope, local_name, current, conditions)
        [truthy, falsey]
      end

      # When the clause has exactly one `RegularExpressionNode` literal condition, narrow the
      # match-data globals on the body edge (same rule as `analyse_regex_match_predicate`'s
      # truthy edge). With multiple regex conditions (`when /a/, /b/`) the body is reachable
      # through any of them, so only `$~`/`$&` are safely non-nil; numbered groups whose
      # presence differs per alternative stay `String | nil`. With no regex condition the entry
      # scope passes through unchanged.
      def apply_when_regex_globals(conditions, scope)
        regexes = conditions.grep(Prism::RegularExpressionNode)
        return scope if regexes.empty?

        unconditional =
          if regexes.size == 1
            unconditional_capture_groups(regexes.first.unescaped)
          else
            Set.new
          end
        truthy, = regex_match_predicate_scopes(scope, unconditional)
        truthy
      end

      # Internal analyser. Returns `[truthy_scope, falsey_scope]` when the predicate shape is
      # recognised, or `nil` to signal "no narrowing" so the public surface can fall back to the
      # entry scope.
      def analyse(node, scope)
        case node
        when Prism::ParenthesesNode
          analyse_parentheses(node, scope)
        when Prism::StatementsNode
          analyse_statements(node, scope)
        when Prism::LocalVariableReadNode
          analyse_local_read(node, scope)
        when Prism::LocalVariableWriteNode
          analyse_local_write(node, scope)
        when Prism::InstanceVariableReadNode, Prism::InstanceVariableWriteNode
          analyse_ivar(node, scope)
        when Prism::ClassVariableWriteNode
          analyse_cvar_write(node, scope)
        when Prism::GlobalVariableWriteNode
          analyse_global_write(node, scope)
        when Prism::CallNode
          analyse_call(node, scope)
        when Prism::AndNode
          analyse_and(node, scope)
        when Prism::OrNode
          analyse_or(node, scope)
        when Prism::MatchWriteNode
          analyse_match_write(node, scope)
        end
      end

      # rubocop:disable-next Metrics/ClassLength
      class << self
        private

        # Complement of `Difference[base, Constant[v]]` within `current_type`. Walks the
        # current type's union members, keeps each member disjoint from `base` (those values
        # were never in the refinement to begin with), and adds the removed-value `Constant[v]`
        # exactly once when any current member covers it. Members that are fully contained in
        # the refinement (i.e. inside `base` and NOT equal to the removed value) are dropped —
        # they are exactly the values the negation excludes.
        def complement_difference(current_type, difference)
          base = difference.base
          removed = difference.removed
          parts = current_type.is_a?(Type::Union) ? current_type.members : [current_type]

          survivors = []
          add_removed = false
          parts.each do |part|
            if base_disjoint?(base, part)
              survivors << part
            elsif part_covers_constant?(part, removed)
              add_removed = true
            end
          end
          survivors << removed if add_removed

          return current_type if survivors.empty?

          Type::Combinator.union(*survivors)
        end

        def base_disjoint?(base, part)
          base.accepts(part, mode: :gradual).no?
        end

        def part_covers_constant?(part, constant)
          result = part.accepts(constant, mode: :gradual)
          result.yes? || result.maybe?
        end

        # Complement of an `IntegerRange[a, b]` within `current_type`. Splits the range
        # complement into the two open halves `int<min, a-1>` and `int<b+1, max>` (skipping a
        # half when its bound is infinity), then intersects each half with the integer-domain
        # parts of `current_type`. Non-integer parts of a Union receiver (nil, String, …)
        # survive unchanged.
        def complement_integer_range(current_type, range)
          halves = integer_range_complement_halves(range)
          parts = current_type.is_a?(Type::Union) ? current_type.members : [current_type]

          survivors = []
          parts.each do |part|
            if integer_member?(part)
              halves.each do |half|
                meet = intersect_integer_part(part, half)
                survivors << meet unless meet.nil? || meet.is_a?(Type::Bot)
              end
            else
              survivors << part
            end
          end

          return current_type if survivors.empty?

          Type::Combinator.union(*survivors)
        end

        # Returns the two open halves of an IntegerRange's complement: the left half `int<-∞,
        # a-1>` (when `a` is finite) and the right half `int<b+1, ∞>` (when `b` is finite).
        # Universal ranges (both bounds infinite) yield an empty array — the complement is
        # empty.
        def integer_range_complement_halves(range)
          halves = []
          left_max = range.min
          right_min = range.max

          if left_max.is_a?(Integer)
            halves << Type::Combinator.integer_range(Type::IntegerRange::NEG_INFINITY, left_max - 1)
          end
          if right_min.is_a?(Integer)
            halves << Type::Combinator.integer_range(right_min + 1, Type::IntegerRange::POS_INFINITY)
          end
          halves
        end

        def integer_member?(part)
          case part
          when Type::Constant then part.value.is_a?(Integer)
          when Type::IntegerRange then true
          when Type::Nominal then part.class_name == "Integer"
          else false
          end
        end

        # Intersect an integer-domain part with a complement half-range. For a
        # Nominal[Integer] receiver the meet is the half itself; for an existing IntegerRange
        # the meet narrows both bounds; for a Constant[Integer] the meet is the constant when
        # the half covers it, otherwise nil.
        def intersect_integer_part(part, half)
          case part
          when Type::Nominal
            half
          when Type::IntegerRange
            integer_range_meet(part, half)
          when Type::Constant
            half.covers?(part.value) ? part : nil
          end
        end

        def integer_range_meet(left, right)
          low = numeric_to_bound([integer_bound_value(left.min), integer_bound_value(right.min)].max)
          high = numeric_to_bound([integer_bound_value(left.max), integer_bound_value(right.max)].min)
          return nil if integer_range_disjoint?(low, high)

          Type::Combinator.integer_range(low, high)
        end

        def integer_bound_value(bound)
          return -Float::INFINITY if bound == Type::IntegerRange::NEG_INFINITY
          return Float::INFINITY if bound == Type::IntegerRange::POS_INFINITY

          bound
        end

        def numeric_to_bound(value)
          return Type::IntegerRange::NEG_INFINITY if value == -Float::INFINITY
          return Type::IntegerRange::POS_INFINITY if value == Float::INFINITY

          value.to_i
        end

        def integer_range_disjoint?(low, high)
          return false if low == Type::IntegerRange::NEG_INFINITY
          return false if high == Type::IntegerRange::POS_INFINITY

          low > high
        end

        # De Morgan: `D \ (M1 ∩ M2 ∩ …) = (D \ M1) ∪ (D \ M2) ∪ …`. Each member's complement is
        # computed independently within `current_type` and the results are unioned. Members the
        # algebra cannot complement contribute `current_type` itself, so the union widens to
        # `current_type` overall — sound but imprecise.
        def complement_intersection(current_type, intersection)
          per_member = intersection.members.map do |member|
            Narrowing.narrow_not_refinement(current_type, member)
          end
          Type::Combinator.union(*per_member)
        end

        # v0.0.7 — complement of a `Refined[base, predicate]` refinement within `current_type`.
        # Walks the current type's union members; parts that are disjoint from the refinement's
        # base survive unchanged; parts equal to the refinement itself drop entirely (they were
        # exactly the negated subset); parts that overlap the base contribute `Difference[part,
        # refined]` so downstream narrowing knows the refinement subset is excluded.
        #
        # v0.0.9 — when the predicate has a registered complement (see
        # {Type::Refined::COMPLEMENT_PAIRS}) and the part is exactly the refinement's base, the
        # narrowing returns `Refined[base, complement_predicate]` instead of
        # `Difference[base, refined]`. This is the `~T` symmetry the spec promises:
        # `~lowercase-string` narrows `String` to `non-lowercase-string` rather than
        # `Difference[String, lowercase-string]`.
        #
        # Predicates without a registered complement still fall back to the imprecise but sound
        # `Difference[part, refined]` carrier so behaviour is unchanged for untouched call
        # sites.
        def complement_refined(current_type, refined)
          complement = registered_complement_for(refined)
          parts = current_type.is_a?(Type::Union) ? current_type.members : [current_type]
          survivors = parts.filter_map { |part| complement_refined_part(part, refined, complement) }
          return current_type if survivors.empty?

          Type::Combinator.union(*survivors)
        end

        def complement_refined_part(part, refined, complement)
          return nil if part == refined
          return part if base_disjoint?(refined.base, part)
          return complement if complement && part == refined.base

          Type::Combinator.difference(part, refined)
        end

        def registered_complement_for(refined)
          complement_id = refined.complement_predicate_id
          return nil if complement_id.nil?

          Type::Combinator.refined(refined.base, complement_id)
        end

        def falsey_value?(value)
          value.nil? || value == false
        end

        def falsey_nominal?(nominal)
          %w[NilClass FalseClass].include?(nominal.class_name)
        end

        # Carriers that the {.narrow_falsey} fast path does not handle by structural
        # inspection. Singleton/Tuple/HashShape inhabit truthy values, so their falsey fragment
        # is empty; everything else (Top, Dynamic, Bot, and any future carrier) stays
        # conservative and is returned unchanged.
        def narrow_falsey_other(type)
          case type
          when Type::Singleton, Type::Tuple, Type::HashShape then Type::Combinator.bot
          else type
          end
        end

        # Carriers that the {.narrow_nil} fast path does not handle by structural inspection.
        # Top/Dynamic narrow to `Constant[nil]` so dispatch resolves through `NilClass`; Bot is
        # its own nil fragment; the remaining carriers (Singleton, Tuple, HashShape, and any
        # future carrier whose inhabitants exclude nil) collapse to `Bot`.
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

        # The truthiness of a `StatementsNode` is determined by its last statement
        # (intermediate statements run for effect and then the predicate's value is the
        # tail's). Earlier statements MAY have scope effects, but Slice 6 phase 1 does NOT
        # thread those through the analyser (the StatementEvaluator has already produced
        # `post_pred` for the call site, and narrowing is layered on that scope).
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

        # Assignment-in-condition: `if name = expr` and the more frequent `if cond && (name =
        # expr)` / `if cond && name = expr` Redmine-style guard. By the time narrowing runs,
        # `StatementEvaluator#eval_local_write` has already bound the assigned local in `scope`
        # to the rvalue type. The write's own truthiness IS the assigned value's truthiness, so
        # the truthy edge narrows the local by `narrow_truthy(current)` and the falsey edge by
        # `narrow_falsey(current)`. Mirrors `analyse_local_read` because the only meaningful
        # difference between "predicate is `var`" and "predicate is `var = expr`" is which scope
        # holds the just-bound value; the narrowing contract on the surrounding `if` is the
        # same.
        def analyse_local_write(node, scope)
          current = scope.local(node.name)
          return nil if current.nil?

          [
            scope.with_local(node.name, narrow_truthy(current)),
            scope.with_local(node.name, narrow_falsey(current))
          ]
        end

        # Truthy guard on an instance variable. Covers both the bare read — `if @ivar`, the
        # left arm of `@ivar && @ivar.foo`, the receiver of `unless @ivar.nil?` once `!`
        # reverses it — and the assignment-in-condition write `if @ivar = expr`. Mirrors
        # `analyse_local_read` / `analyse_local_write`: the truthy edge narrows the ivar by
        # `narrow_truthy` (dropping `nil` / `false`), the falsey edge by `narrow_falsey`. The
        # narrowing is scoped to the guarded branch only, so it is purely additive — it never
        # widens or re-narrows the ivar binding seen elsewhere.
        def analyse_ivar(node, scope)
          current = scope.ivar(node.name)
          return nil if current.nil?

          [
            scope.with_ivar(node.name, narrow_truthy(current)),
            scope.with_ivar(node.name, narrow_falsey(current))
          ]
        end

        def analyse_cvar_write(node, scope)
          current = scope.cvar(node.name)
          return nil if current.nil?

          [
            scope.with_cvar(node.name, narrow_truthy(current)),
            scope.with_cvar(node.name, narrow_falsey(current))
          ]
        end

        def analyse_global_write(node, scope)
          current = scope.global(node.name)
          return nil if current.nil?

          [
            scope.with_global(node.name, narrow_truthy(current)),
            scope.with_global(node.name, narrow_falsey(current))
          ]
        end

        # `if /(?<x>...)/ =~ str` — Prism wraps the `=~` call in a `MatchWriteNode` listing the
        # named-capture targets. The parent `eval_match_write` has already bound each target to
        # `String | nil`; in the truthy branch (the regex matched) every named capture is
        # guaranteed `String`, and in the falsey branch (no match) every capture is `nil`.
        # Subtract the dead half on each edge so callers like `year.upcase` inside the truthy
        # branch no longer fire `possible-nil-receiver`.
        #
        # v0.1.1 Track 1 slice 1 — when the regex source is a statically known
        # `RegularExpressionNode` and a named capture's body matches one of the curated shapes
        # in {Rigor::Builtins::RegexRefinement::RULES}, the truthy branch narrows further than
        # `String` to the matching imported refinement (e.g. `decimal-int-string` for `\d+`).
        # Bodies outside the table fall back to the v0.1.0 baseline (plain `String`).
        def analyse_match_write(node, scope)
          string_t = Type::Combinator.nominal_of("String")
          nil_t = Type::Combinator.constant_of(nil)
          refinements = match_write_capture_refinements(node)
          truthy = scope
          falsey = scope
          node.targets.each do |target|
            next unless target.is_a?(Prism::LocalVariableTargetNode)

            truthy = truthy.with_local(target.name, refinements[target.name] || string_t)
            falsey = falsey.with_local(target.name, nil_t)
          end
          [truthy, falsey]
        end

        # Extracts `{ capture_name => Refinement }` for every named capture group in the
        # `MatchWriteNode`'s wrapped `=~` call whose body the recogniser table accepts. Bodies
        # that contain nested groups, anchors, alternation, or anything else outside the curated
        # forms drop out and the caller falls back to plain `String`.
        NAMED_CAPTURE_BODY_RE = /\(\?<([A-Za-z_][A-Za-z0-9_]*)>([^()|]*)\)/
        private_constant :NAMED_CAPTURE_BODY_RE

        def match_write_capture_refinements(node)
          regex = node.call.is_a?(Prism::CallNode) ? node.call.receiver : nil
          return {} unless regex.is_a?(Prism::RegularExpressionNode)

          refinements = {}
          regex.unescaped.scan(NAMED_CAPTURE_BODY_RE) do |name, body|
            type = ::Rigor::Builtins::RegexRefinement.for_capture_body(body)
            refinements[name.to_sym] = type if type
          end
          refinements
        end

        # Recognised CallNode predicates:
        # - `recv.nil?` (Slice 6 phase 1, no args, no block)
        # - unary `!recv` (`name == :!`, no args, no block)
        # - `recv.is_a?(C)` / `recv.kind_of?(C)` / `recv.instance_of?(C)` with a single
        #   static-constant argument and no block (Slice 6 phase 2 sub-phase 1).
        # - `local == literal` / `literal == local` and the `!=` mirror for trusted static
        #   literals (Slice 6 phase 2 sub-phase 2).
        # Anything else returns nil so the surrounding analyser falls through to the
        # no-narrowing fallback.
        def analyse_call(node, scope)
          return nil if node.block

          unless node.receiver.nil?
            shape_result = dispatch_call(node, scope, node.name)
            return apply_safe_nav_non_nil(node, scope, shape_result) if shape_result

            # v0.1.1 Track 1 slice 4 — String predicate flow facts.
            string_predicate_result = analyse_string_predicate(node, scope)
            return apply_safe_nav_non_nil(node, scope, string_predicate_result) if string_predicate_result

            # A predicate whose RBS says it always returns `false` for one union arm cannot have
            # been called on that arm when it answered truthily. `NilClass#present?: () -> false`
            # (ActiveSupport) is the motivating case: `if login.present?` must narrow `String | nil`
            # to `String`, and nothing else in the catalogue does it — `present?` is a gem method the
            # engine must not hardcode, and `rigor:v1:predicate-if-true` facts never reach a union
            # receiver.
            polarity_result = analyse_union_predicate_polarity(node, scope)
            return polarity_result if polarity_result

            # A safe-navigation call (`v&.foo`) whose result is truthy proves the receiver was
            # non-nil — `&.` returns `nil` when the receiver is nil, so a truthy outcome can
            # only come from a non-nil receiver. Narrow the receiver on the truthy edge even
            # when the call itself carries no other flow fact, so `v&.start_with?('[') &&
            # v.end_with?(']')` sees `v` non-nil in the `&&` right operand. The falsey edge is
            # the conservative no-op (falsey could mean nil receiver OR a falsey method result).
            safe_nav_result = analyse_safe_nav_receiver(node, scope)
            return safe_nav_result if safe_nav_result

            # Issue #606 slice 1 — the same proof one call further out, where the `&.` result is
            # fed to a suffix (`custom&.value.present?`, `backup&.user.nil?`) or compared against
            # a non-nil operand. Sits after every pre-existing NARROWING path so those keep first claim
            # on the node (the RBS-extended contribution hook still runs later and can be pre-empted —
            # no live collision today since arg-free chains carry no argument facts):
            # each of them returns nil for these shapes today (the predicate analysers require a
            # local-read receiver, which a chain is not), so this only ever runs on nodes that
            # were otherwise about to narrow nothing.
            chain_result =
              if %i[== !=].include?(node.name)
                analyse_safe_nav_chain_equality(node, scope)
              else
                analyse_safe_nav_chain(node, scope)
              end
            return chain_result if chain_result

            # Issue #606 slice 2 — membership. Runs after `analyse_string_predicate`, which owns
            # the `str.include?(literal)` shape; this one wants the mirror image (a collection
            # receiver, a bound argument), so the two never contend for the same node.
            if node.name == :include?
              membership_result = analyse_membership_predicate(node, scope)
              return membership_result if membership_result
            end
          end

          # Slice 7 phase 15 — RBS::Extended predicate effects. When the method's RBS signature
          # carries `rigor:v1:predicate-if-true` / `predicate-if-false` annotations, apply them
          # to narrow the corresponding local-variable arguments on each edge. v0.1.1 Track 1
          # slice 3 — implicit-self calls (`recv == nil`, e.g. `admin?` inside an instance
          # method body) flow through here too so `self`-targeted facts can edit
          # `scope.self_type`.
          analyse_rbs_extended_contribution(node, scope)
        end

        # v0.1.1 Track 1 slice 4 — `String#start_with?` / `#end_with?` / `#include?` against a
        # `Constant<String>` needle attaches a relational `FactStore::Fact` to the local on
        # each edge. The receiver's type does NOT change — Rigor has no "starts-with-X" carrier
        # today — so the fact carries the predicate semantics for any downstream consumer that
        # wants to read it (e.g. a plugin's `prepare(services)` hook in v0.1.x). Truthy edge:
        # positive polarity. Falsey edge: negative polarity. Mirrors the equality-predicate fact
        # pattern already used by `analyse_equality_predicate`.
        STRING_PREDICATE_NAMES = %i[start_with? end_with? include?].freeze
        private_constant :STRING_PREDICATE_NAMES

        def analyse_string_predicate(node, scope)
          return nil unless string_predicate_call?(node)

          needle = string_predicate_needle(node, scope)
          return nil if needle.nil?

          local_name = node.receiver.name
          return nil if scope.local(local_name).nil?

          [
            scope.with_fact(string_predicate_fact(local_name, node.name, needle, polarity: :positive)),
            scope.with_fact(string_predicate_fact(local_name, node.name, needle, polarity: :negative))
          ]
        end

        def string_predicate_call?(node)
          STRING_PREDICATE_NAMES.include?(node.name) &&
            node.receiver.is_a?(Prism::LocalVariableReadNode) &&
            !node.arguments.nil? &&
            node.arguments.arguments.size == 1
        end

        def string_predicate_needle(node, scope)
          needle_type = static_literal_type(node.arguments.arguments.first, scope)
          return nil unless needle_type.is_a?(Type::Constant) && needle_type.value.is_a?(String)

          needle_type.value
        end

        def string_predicate_fact(name, predicate, needle, polarity:)
          Analysis::FactStore::Fact.new(
            bucket: :relational,
            target: Analysis::FactStore::Target.local(name),
            predicate: predicate,
            payload: needle,
            polarity: polarity,
            stability: :local_binding
          )
        end

        ZERO_CLASS_PREDICATES = %i[positive? negative? zero? nonzero?].freeze
        COMPARISON_OPERATORS = %i[< <= > >=].freeze
        private_constant :ZERO_CLASS_PREDICATES, :COMPARISON_OPERATORS

        def dispatch_call(node, scope, name)
          return dispatch_call_simple(node, scope, name) if simple_dispatch_name?(name)

          dispatch_call_numeric(node, scope, name)
        end

        def simple_dispatch_name?(name)
          %i[nil? ! is_a? kind_of? instance_of? == != === =~ match? key? has_key? empty? any?
             none? respond_to?].include?(name)
        end

        def dispatch_call_simple(node, scope, name)
          case name
          when :nil?, :! then dispatch_unary_predicate(node, scope, name)
          when :is_a?, :kind_of? then analyse_class_predicate(node, scope, exact: false)
          when :instance_of? then analyse_class_predicate(node, scope, exact: true)
          when :==, :!= then analyse_equality_predicate(node, scope, equality: name)
          when :=== then analyse_case_equality_predicate(node, scope)
          when :=~ then analyse_regex_match_predicate(node, scope)
          when :match? then analyse_whole_regex_match_predicate(node, scope)
          when :key?, :has_key? then analyse_key_presence_predicate(node, scope)
          when :empty?, :any?, :none? then analyse_array_emptiness_predicate(node, scope, name)
          when :respond_to? then analyse_respond_to_predicate(node, scope)
          end
        end

        # T3 (template-corpora survey) — `recv.respond_to?(sym)` truthy edge narrows `recv`
        # non-nil. `nil.respond_to?(m)` is `false` for every method `m` that `NilClass` does not
        # define, so a truthy `respond_to?` proves the receiver was not `nil` UNLESS the queried
        # symbol is one of `NilClass`'s own methods (`:to_s`, `:inspect`, `:nil?`, …) — `nil`
        # DOES respond to those, so the truthy edge admits a nil receiver and we narrow nothing.
        #
        # Conservative floor: narrow only on a literal `Symbol`/`String` argument resolved
        # against the RBS environment; a non-literal symbol, a missing argument, or a symbol
        # that IS in `NilClass`'s method set declines. The falsey edge is always the no-op
        # ("does not respond" proves little about the receiver's type). Narrowing-only: it
        # removes the `nil` constituent and never promotes a non-nil type.
        def analyse_respond_to_predicate(node, scope)
          return nil if node.block
          return nil if node.arguments.nil? || node.arguments.arguments.size != 1

          sym = static_hash_key(node.arguments.arguments.first)
          return nil if sym.nil?
          return nil if nilclass_method?(sym, scope)

          reader, writer = emptiness_receiver_accessors(node.receiver)
          return nil if reader.nil?

          current = scope.public_send(reader, node.receiver.name)
          return nil if current.nil?

          non_nil = narrow_non_nil(current)
          return nil if non_nil.equal?(current)

          [scope.public_send(writer, node.receiver.name, non_nil), scope]
        end

        # True when `nil` responds to `sym` — i.e. `NilClass` (own, inherited
        # Kernel/BasicObject) defines an instance method named `sym`. Resolved against the RBS
        # environment; when the lookup is unavailable the answer is conservatively `true`
        # (decline to narrow) so an unknown environment never manufactures a false non-nil
        # narrowing.
        def nilclass_method?(sym, scope)
          name = sym.respond_to?(:to_sym) ? sym.to_sym : sym
          return true unless name.is_a?(Symbol)

          !Rigor::Reflection.instance_method_definition(
            "NilClass", name, environment: scope.environment
          ).nil?
        rescue StandardError
          true
        end

        # ADR-47 §4-4 (Elixir `tuple_size`/non-empty analogue) — a bare `arr.empty?` /
        # `arr.any?` / `arr.none?` (no block, no args) narrows an Array-typed receiver to
        # `non-empty-array[T]` on the edge that implies "at least one element":
        #
        #   - `empty?` → false edge   (the array is NOT empty)
        #   - `any?`   → true  edge   (a truthy element exists ⇒ non-empty)
        #   - `none?`  → false edge   (a truthy element exists ⇒ non-empty)
        #
        # The opposite edge is the conservative no-op (`any?`/`none?` falseness does not imply
        # emptiness — the array may hold only falsey elements; `empty?` truth could narrow to an
        # empty array but that carrier move is deferred). Only `Nominal[Array, [T]]` receivers
        # narrow — `Tuple` is already known-length, `Dynamic` is left alone (gradual
        # guarantee), and a non-Array receiver (`String#empty?`, `Range#any?`, …) bails so the
        # existing string / predicate paths still run.
        def analyse_array_emptiness_predicate(node, scope, name)
          return nil if node.block
          return nil unless node.arguments.nil? || node.arguments.arguments.empty?

          reader, writer = emptiness_receiver_accessors(node.receiver)
          return nil if reader.nil?

          current = scope.public_send(reader, node.receiver.name)
          return nil if current.nil?

          non_empty = narrow_to_non_empty_array(current)
          return nil if non_empty.equal?(current) # receiver is not an Array shape → opaque

          non_empty_scope = scope.public_send(writer, node.receiver.name, non_empty)
          name == :any? ? [non_empty_scope, scope] : [scope, non_empty_scope]
        end

        def emptiness_receiver_accessors(receiver)
          case receiver
          when Prism::LocalVariableReadNode then %i[local with_local]
          when Prism::InstanceVariableReadNode then %i[ivar with_ivar]
          else [nil, nil]
          end
        end

        # Refines `Array[T]` (and every Array member of a Union) to `non-empty-array[T]`;
        # returns the input unchanged when nothing applies, so the caller can detect "no
        # narrowing".
        def narrow_to_non_empty_array(type)
          case type
          when Type::Nominal
            return type unless type.class_name == "Array"

            Type::Combinator.non_empty_array(type.type_args.first || Type::Combinator.top)
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_to_non_empty_array(member) })
          else
            type
          end
        end

        # ADR-47 §4-3 (Elixir `is_map_key/2` analogue) — `h.key?(:foo)` narrows the receiver on
        # the truthy edge: a `HashShape` whose `:foo` is an OPTIONAL key has it promoted to
        # REQUIRED, so a subsequent `h[:foo]` reads the declared value type instead of `value |
        # nil` (the optionality nil is gone). Sound because key presence removes only the
        # optionality-injected nil, never the value's own intrinsic nil (`h = {foo: nil}` keeps
        # `h[:foo]` nil-typed). The falsey edge is left unchanged — "key absent" is the
        # conservative no-op. Only literal `Symbol`/`String` arguments and
        # `LocalVariableReadNode`/`InstanceVariableReadNode` receivers narrow; everything else
        # (Dynamic, `Nominal[Hash]`, method-chain receivers, dynamic keys) bails to no
        # narrowing.
        def analyse_key_presence_predicate(node, scope)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          key = static_hash_key(node.arguments.arguments.first)
          return nil if key.nil?

          case node.receiver
          when Prism::LocalVariableReadNode
            key_presence_scopes(node.receiver.name, key, scope, reader: :local, writer: :with_local)
          when Prism::InstanceVariableReadNode
            key_presence_scopes(node.receiver.name, key, scope, reader: :ivar, writer: :with_ivar)
          end
        end

        def key_presence_scopes(name, key, scope, reader:, writer:)
          current = scope.public_send(reader, name)
          return nil if current.nil?

          truthy = narrow_hash_key_present(current, key)
          # §4-3 false edge — `h.key?(:foo)` being false proves `:foo` is absent, so on that
          # edge `h[:foo]` reads `nil`. Remove the (optional) key from the shape; a required
          # key makes the false edge dead and an unknown key is already nil, both no-ops.
          falsey = narrow_hash_key_absent(current, key)
          return nil if truthy.equal?(current) && falsey.equal?(current) # predicate is opaque

          truthy_scope = truthy.equal?(current) ? scope : scope.public_send(writer, name, truthy)
          falsey_scope = falsey.equal?(current) ? scope : scope.public_send(writer, name, falsey)
          [truthy_scope, falsey_scope]
        end

        def static_hash_key(node)
          case node
          when Prism::SymbolNode then node.unescaped.to_sym
          when Prism::StringNode then node.unescaped
          end
        end

        # Promotes `key` from optional to required across a HashShape (or every HashShape
        # member of a Union). Returns the input unchanged when nothing applies, so the caller
        # can detect "no narrowing".
        def narrow_hash_key_present(type, key)
          case type
          when Type::HashShape
            promote_hash_key(type, key)
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_hash_key_present(member, key) })
          else
            type
          end
        end

        def promote_hash_key(shape, key)
          return shape unless shape.pairs.key?(key) # unknown key → no value type to assert
          return shape unless shape.optional_key?(key) # already required → nothing to promote

          Type::HashShape.new(
            shape.pairs,
            required_keys: shape.required_keys + [key],
            optional_keys: shape.optional_keys - [key],
            read_only_keys: shape.read_only_keys,
            extra_keys: shape.extra_keys
          )
        end

        # §4-3 false edge — drops `key` from a HashShape (or every HashShape member of a Union)
        # so the proven-absent key reads `nil`. Returns the input unchanged when nothing
        # applies (caller detects "no narrowing"). Only an *optional* present key is removed: a
        # required key makes `key?` always true (the false edge is dead, leave the shape opaque)
        # and a key absent from `pairs` already reads `nil` on a closed shape. On an open shape an
        # undeclared key keeps reading `untyped` on this edge — sound but imprecise, since the shape
        # carries no per-key exclusion to record what the guard just proved absent.
        def narrow_hash_key_absent(type, key)
          case type
          when Type::HashShape
            remove_hash_key(type, key)
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| narrow_hash_key_absent(member, key) })
          else
            type
          end
        end

        def remove_hash_key(shape, key)
          return shape unless shape.pairs.key?(key)
          return shape unless shape.optional_key?(key)

          Type::HashShape.new(
            shape.pairs.except(key),
            required_keys: shape.required_keys,
            optional_keys: shape.optional_keys - [key],
            read_only_keys: shape.read_only_keys - [key],
            extra_keys: shape.extra_keys
          )
        end

        # Survey item (b): `/regex/ =~ str` and `str =~ /regex/` bind the regex match-data
        # globals on each edge.
        #
        # - Truthy edge (`=~` returned an Integer position — the match succeeded): `$~` to
        #   `Nominal[MatchData]`; `$&` and `$1..$N` (where N is the number of capture groups in
        #   the regex source) to `Nominal[String]`. This is the same optimistic-narrowing shape
        #   the existing `analyse_match_write` uses for named captures inside `if /(?<x>...)/
        #   =~ str` — optional groups in the regex source (`(\d+)?`) would bind `$N` to `nil`
        #   at runtime, but the floor here matches the common idiom (required captures) and
        #   lets `unless /(\d+)/ =~ s; raise; end; $1.to_i` resolve cleanly.
        # - Falsey edge (`=~` returned nil — no match): `$~` and every numbered / back-reference
        #   global bound to `Constant<nil>`.
        #
        # Returns nil (no narrowing) when the receiver / argument pair does not resolve to exactly one
        # regex pattern we can count (see {#regex_match_pattern}).
        def analyse_regex_match_predicate(node, scope)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          arg = node.arguments.arguments.first
          pattern = regex_match_pattern(node.receiver, arg, scope)
          return nil if pattern.nil?
          # Extended mode (`//x`) lets the pattern carry free whitespace and `#` comments, and a
          # comment may contain a literal `(` — which the light char-scan walker would miscount as a
          # capturing group, shifting `$N` indices and narrowing the wrong global. That is a
          # false-negative-class misnarrowing, so bail rather than risk it. The literal path shares
          # this bail: `RegularExpressionNode` carries the same latent miscount.
          return nil if pattern.extended

          unconditional = unconditional_capture_groups(pattern.source)
          truthy, falsey = regex_match_predicate_scopes(scope, unconditional)
          # #164 — layer whole-receiver refinement onto the truthy edge without disturbing the
          # match-global logic above. A successful `str =~ /\A\d+\z/` proves the WHOLE string
          # matched, so the string operand narrows to the imported refinement the anchored pattern
          # names. The falsey edge is untouched: a failed match proves nothing about the shape.
          truthy = apply_whole_receiver_refinement(truthy, node.receiver, arg, pattern.source, scope)
          [truthy, falsey]
        end

        # `str.match?(/\A\d+\z/)` — `String#match?` is a pure boolean predicate whose truthy edge
        # proves a property of the ENTIRE receiver. When the argument is a fully `\A…\z`-anchored
        # single-char-class pattern recognised by {RegexRefinement.for_whole_pattern}, narrow the
        # receiver local to the matching imported refinement on the truthy edge; the falsey edge
        # passes through unchanged (failing one pattern proves nothing about the string's shape).
        # A non-literal / unanchored / `\Z` / line-anchored / `//x` pattern falls through to no
        # narrowing.
        def analyse_whole_regex_match_predicate(node, scope)
          return nil unless node.receiver.is_a?(Prism::LocalVariableReadNode)
          return nil if node.arguments.nil? || node.arguments.arguments.size != 1

          pattern = regex_operand_pattern(node.arguments.arguments.first, scope)
          return nil unless pattern.is_a?(RegexMatchPattern)
          return nil if pattern.extended

          refinement = ::Rigor::Builtins::RegexRefinement.for_whole_pattern(pattern.source)
          return nil if refinement.nil?

          local_name = node.receiver.name
          return nil if scope.local(local_name).nil?

          [scope.with_local(local_name, refinement), scope]
        end

        # Narrows the string operand of a `=~` predicate to a whole-receiver refinement when the
        # regex source is a recognised `\A…\z`-anchored pattern. Returns the (possibly unchanged)
        # truthy scope; the falsey edge is never touched by this layer.
        def apply_whole_receiver_refinement(truthy, receiver, arg, source, scope)
          refinement = ::Rigor::Builtins::RegexRefinement.for_whole_pattern(source)
          return truthy if refinement.nil?

          # `regex_match_pattern` already resolved the regex operand from a literal or a
          # `Constant[Regexp]` constant read — never a bare local — so the string subject is
          # unambiguously the local-read operand, if either operand is one.
          subject = [receiver, arg].find { |operand| operand.is_a?(Prism::LocalVariableReadNode) }
          return truthy if subject.nil? || scope.local(subject.name).nil?

          truthy.with_local(subject.name, refinement)
        end

        # Recognises the regex pattern operand of a `=~` predicate. An operand resolves to a regex when
        # it is either a syntactic `RegularExpressionNode` literal OR a constant read whose type is a
        # value-pinned `Constant[Regexp]` (`RE = /.../` and `RE = Regexp.new(...)` both fold to the
        # carrier in the whole-program constant pre-pass). Returns a single {RegexMatchPattern}, or nil
        # (no narrowing) when NEITHER operand resolves to a regex, when BOTH do (`/a/ =~ /b/` — no
        # string subject to bind), or when a constant operand is ambiguous — typed as a `Union` from a
        # twice-assigned constant, where no single source can be pinned.
        def regex_match_pattern(left, right, scope)
          left_pattern = regex_operand_pattern(left, scope)
          right_pattern = regex_operand_pattern(right, scope)
          return nil if left_pattern == :ambiguous || right_pattern == :ambiguous

          patterns = [left_pattern, right_pattern].grep(RegexMatchPattern)
          patterns.size == 1 ? patterns.first : nil
        end

        # Classifies one `=~` operand: a {RegexMatchPattern} when it resolves to a regex (literal or
        # `Constant[Regexp]`), `:ambiguous` when a constant operand types as a `Union` (a twice-assigned
        # constant), or nil when the operand is not a regex at all.
        def regex_operand_pattern(node, scope)
          case node
          when Prism::RegularExpressionNode
            RegexMatchPattern.new(source: node.unescaped, extended: node.extended?)
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            regex_operand_from_constant(node, scope)
          end
        end

        # Resolves a constant-reference operand to a regex pattern via the shared lexical-constant
        # resolution (`Reflection.resolve_constant_type`). `Regexp#options` gives the real
        # extended-mode flag; `Regexp#source` the pattern. Returns `:ambiguous` for a `Union`-typed
        # constant so the caller bails, and nil when the constant does not resolve to a `Constant[Regexp]`.
        def regex_operand_from_constant(node, scope)
          name = Source::ConstantPath.qualified_name_or_nil(node)
          return nil if name.nil?

          type = Reflection.resolve_constant_type(name, scope: scope,
                                                        rooted: Source::ConstantPath.rooted?(node))
          return :ambiguous if type.is_a?(Type::Union)
          return nil unless type.is_a?(Type::Constant)

          value = type.value
          return nil unless value.is_a?(Regexp)

          RegexMatchPattern.new(source: value.source, extended: value.options.anybits?(Regexp::EXTENDED))
        end

        # Curated set of match globals bound non-nil on every successful `=~` regardless of grouping:
        # `$~` (the MatchData), `$&` (whole match), `` $` `` (pre-match), `$'` (post-match). Numbered
        # references (`$1..$N`) and `$+` (the last matched group) are handled separately because they
        # depend on the regex source — `$+` is gated on the same participation set as `$N` (#177).
        REGEX_MATCH_GLOBALS = %i[$~ $& $` $'].freeze
        private_constant :REGEX_MATCH_GLOBALS

        # `unconditional` is the Set of 1-based numbered-capture indices whose group is
        # guaranteed to participate in any successful match (no optional quantifier on the
        # group or an ancestor, no alternation in the pattern). Those `$N` are bound to
        # `String`; every other numbered group present in the pattern stays `String | nil` on
        # both edges (a truthy match leaves an optional group nil at runtime), so we do not
        # narrow it on the truthy edge.
        def regex_match_predicate_scopes(scope, unconditional)
          string_t = Type::Combinator.nominal_of("String")
          match_data_t = Type::Combinator.nominal_of("MatchData")
          nil_t = Type::Combinator.constant_of(nil)

          truthy = scope
          falsey = scope
          truthy = truthy.with_global(:$~, match_data_t)
          falsey = falsey.with_global(:$~, nil_t)
          REGEX_MATCH_GLOBALS.each do |name|
            next if name == :$~

            truthy = truthy.with_global(name, string_t)
            falsey = falsey.with_global(name, nil_t)
          end
          unconditional.each do |index|
            name = :"$#{index}"
            truthy = truthy.with_global(name, string_t)
            falsey = falsey.with_global(name, nil_t)
          end
          # `$+` is the LAST matched group, so it is nil on a successful match whose groups are all
          # optional (`"b" =~ /(a)?b/` matches yet leaves `$+` nil) or absent (no capture group). It
          # narrows to `String` only when some group is guaranteed to participate — the same
          # participation gate `$N` uses (#177). With no unconditional group it is left unbound on both
          # edges (fall through to the RBS `String?` default), exactly as an optional `$N` is.
          unless unconditional.empty?
            truthy = truthy.with_global(:$+, string_t)
            falsey = falsey.with_global(:$+, nil_t)
          end
          [truthy, falsey]
        end

        # Returns the Set of 1-based numbered-capture indices that are UNCONDITIONAL in
        # `source`: present on every successful match because no optional quantifier (`?`,
        # `*`, `{0,…}`) applies to the group or any ancestor group, and the pattern contains no
        # alternation (`|`). Optional and alternation-reachable groups are excluded — at
        # runtime `$N` is `nil` for them even when the overall match succeeds, so narrowing
        # them to non-nil `String` would be unsound. The walker is intentionally light (char
        # scan, not a regex-AST parse): backslash escapes are skipped; `(?:…)`, lookahead
        # `(?=…)`/`(?!…)`, and lookbehind `(?<=…)`/`(?<!…)` do not capture; named groups
        # `(?<name>…)` do. Conservatism is one-directional — when in doubt a group is treated
        # as conditional (dropped from the Set), never the reverse.
        def unconditional_capture_groups(source)
          # `unconditional` collects every capturing index; a group is later removed (with its
          # whole subtree) when it is optionally quantified, nested under an optional ancestor,
          # or sits in an alternation branch. `stack` holds one frame per open group (plus a
          # virtual root frame for the top level) as `[group_index_or_nil, descendant_indices,
          # alternated?]`. A `|` marks the CURRENT group's frame alternated — its branches are
          # mutually exclusive, so its descendant captures may be absent on a successful match;
          # the group itself still participates. Closing a frame rolls its subtree up to the
          # parent so an optional / alternated ancestor disqualifies it.
          state = { unconditional: Set.new, stack: [[nil, [], false]], group_index: 0 }
          pos = 0
          length = source.length
          while pos < length
            chr = source[pos]
            if chr == "\\"
              pos += 2
              next
            end
            if chr == "["
              pos = skip_char_class(source, pos) + 1
              next
            end
            scan_group_char(source, pos, chr, state)
            pos += 1
          end
          # Drain the virtual root: a top-level `|` disqualifies all.
          finalize_frame(state, state[:stack].pop, optional: false)
          state[:unconditional]
        end

        # Updates the walk `state` at a group-relevant char during
        # {#unconditional_capture_groups}: `(` pushes a frame, `)` pops and resolves it, `|`
        # flags the current frame as alternated.
        def scan_group_char(source, pos, chr, state)
          case chr
          when "("
            idx = nil
            if capturing_group?(source, pos)
              idx = (state[:group_index] += 1)
              state[:unconditional] << idx
            end
            state[:stack].push([idx, [], false])
          when ")"
            finalize_frame(state, state[:stack].pop, optional: next_quantifier_optional?(source, pos + 1))
          when "|"
            state[:stack].last[2] = true
          end
        end

        # Resolves a closed (or virtual-root) group frame: its subtree is its own index plus
        # every descendant index. The subtree is disqualified when the group is optionally
        # quantified or its branches are alternated (only the descendants in that case — but a
        # self subtree always keeps its own index unless optional).
        def finalize_frame(state, frame, optional:)
          idx, descendants, alternated = frame
          subtree = descendants.dup
          subtree << idx if idx
          state[:unconditional].subtract(subtree) if optional
          # Alternation disqualifies the branch contents (descendants),
          # never the enclosing group itself.
          state[:unconditional].subtract(descendants) if alternated
          state[:stack].last && state[:stack].last[1].concat(subtree)
        end

        # True when the group whose closing paren is at `source[pos]` is followed by a
        # quantifier that permits zero repetitions (`?`, `*`, `{0…}`). `+` and `{1,…}` do NOT
        # make a group optional. A lazy/possessive suffix (`*?`, `*+`) is still zero-permitting
        # on the base quantifier.
        def next_quantifier_optional?(source, pos)
          case source[pos]
          when "?", "*" then true
          when "{" then source[pos + 1] == "0"
          else false
          end
        end

        def capturing_group?(source, pos)
          return true unless source[pos + 1] == "?"

          # `(?<name>…)` captures; `(?<=…)`/`(?<!…)` (lookbehind) and
          # `(?:…)`/`(?=…)`/`(?!…)` do not.
          source[pos + 2] == "<" && source[pos + 3] != "=" && source[pos + 3] != "!"
        end

        def skip_char_class(source, start)
          pos = start + 1
          pos += 1 if source[pos] == "^"
          pos += 1 if source[pos] == "]" # literal ] as first member
          while pos < source.length
            return pos if source[pos] == "]"

            pos += source[pos] == "\\" ? 2 : 1
          end
          pos
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

        # `:positive?` / `:negative?` / `:zero?` / `:nonzero?` are zero-arg predicates on
        # `Numeric`. We model them as comparisons against the literal 0 so the existing range
        # narrowing handles them uniformly.
        ZERO_CLASS_PREDICATE_RULES = Ractor.make_shareable({
                                                             positive?: { truthy: [:>, 0], falsey: [:<=, 0] },
                                                             negative?: { truthy: [:<, 0], falsey: [:>=, 0] },
                                                             zero?: { truthy: [:eq, 0], falsey: [:ne, 0] },
                                                             nonzero?: { truthy: [:ne, 0], falsey: [:eq, 0] }
                                                           })
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

        # `x.between?(a, b)` truthy edge narrows to `narrow_integer_comparison(>=, a)` ∩
        # `narrow_integer_comparison(<=, b)`. The falsey edge is left unchanged because the
        # complement is a two-piece domain (`x < a || x > b`) that the lattice cannot express
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

        # Helper for {.narrow_integer_not_equal}. Only adjusts when the value sits exactly on
        # one endpoint, so the result stays contiguous; otherwise the input range is preserved.
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
        # The reversed (literal-on-left) form is normalised by transposing the operator so the
        # receiver-local always appears on the left of the rule.
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

        # `recv.is_a?(C)` / `recv.kind_of?(C)` / `recv.instance_of?(C)` narrowing. The receiver
        # MUST be a `LocalVariableReadNode` (so we have a name to rebind), and the argument
        # MUST be a single static constant reference (`Foo` or `Foo::Bar`) we can resolve to a
        # qualified class name. Anything else falls through to "no narrowing".
        def analyse_class_predicate(node, scope, exact:)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          argument = node.arguments.arguments.first
          bare_name = static_class_name(argument)
          return nil if bare_name.nil?

          # Resolve `bare_name` through the lexical-scope chain so a name shadowed by the
          # current class / enclosing module wins over the top-level constant. Mirrors Ruby's
          # `Module.nesting`-driven constant lookup. The canonical motivating case: inside
          # `Rigor::Type::Singleton#==`, `is_a?(Singleton)` should resolve to
          # `Rigor::Type::Singleton`, not the top-level stdlib `Singleton` mixin (which would
          # surface as a spurious `undefined-method` on subsequent `other.class_name` calls).
          #
          # A leading `::` opts out of that walk (#614): `static_class_name` de-roots the
          # argument, so without the marker the guard answered the shadow while the READ
          # `::Foo.new` answered the top-level class — the guard and the value it guards
          # disagreeing about the same spelling. When no top-level class owns the name we
          # DECLINE (nil) rather than pass the unknown name down: keeping the pre-state is the
          # conservative answer, and narrowing to the shadow is the one answer that is wrong.
          class_name = rooted_class_predicate_name(argument, bare_name, scope)
          return nil if class_name.nil?

          case node.receiver
          when Prism::LocalVariableReadNode
            analyse_class_predicate_on_local(node, scope, class_name, exact)
          when Prism::CallNode
            analyse_class_predicate_on_chain(node, scope, class_name, exact)
          end
        end

        # The class name a `is_a?` / `kind_of?` / `instance_of?` argument denotes: the top-level
        # `bare_name` when the reference is written `::Foo` (nil when nothing declares it there),
        # the lexical resolution otherwise.
        def rooted_class_predicate_name(argument, bare_name, scope)
          return resolve_class_name_lexically(bare_name, scope) unless Source::ConstantPath.rooted?(argument)

          class_known_to_scope?(scope, bare_name) ? bare_name : nil
        end

        def analyse_class_predicate_on_local(node, scope, class_name, exact)
          current = scope.local(node.receiver.name)
          return nil if current.nil?

          class_predicate_scopes(scope, node.receiver.name, current, class_name, exact: exact)
        end

        # Stable single-hop method-chain narrowing (ROADMAP § Future cycles — "Method-call
        # receiver narrowing across stable receivers"). When the predicate's receiver is
        # `<local/ivar>.<method>` with no args and no block, record the truthy / falsey
        # narrowing in `Scope#method_chain_narrowings` keyed on the chain address. The
        # dominated body's identical chain reads then observe the narrowed type through
        # `ExpressionTyper#call_type_for`'s lookup.
        #
        # Heuristic-by-design (ROADMAP § "Soundness gap"): a second call to `x.last` could in
        # principle return a different value than the first. The chain is dropped on (1)
        # receiver variable rebind (handled inside `Scope#with_local` / `#with_ivar`), and (2)
        # any intervening call against the same root receiver (handled by
        # `StatementEvaluator#eval_call`'s invalidation step). The Law of Demeter justifies the
        # single-hop restriction: a single-hop chain is the idiomatic Ruby shape where
        # re-evaluation soundness is the strongest.
        def analyse_class_predicate_on_chain(node, scope, class_name, exact)
          address = stable_chain_address(node.receiver)
          return nil if address.nil?

          current = scope.type_of(node.receiver)
          return nil if current.nil?

          truthy_type = narrow_class(current, class_name, exact: exact, environment: scope.environment)
          falsey_type = narrow_not_class(current, class_name, exact: exact, environment: scope.environment)

          [
            scope.with_method_chain_narrowing(*address, truthy_type),
            scope.with_method_chain_narrowing(*address, falsey_type)
          ]
        end

        # Returns `[receiver_kind, receiver_name, method_name]` iff `chain_call` is a stable
        # single-hop chain whose root is a local / ivar read and whose own call shape has no
        # positional arguments and no block. Other shapes (multi-hop, args, block,
        # method-defined-on-arbitrary-receiver) lose stability for one of the reasons
        # enumerated in the slice's design notes.
        def stable_chain_address(chain_call)
          return nil unless chain_call.is_a?(Prism::CallNode)
          return nil unless chain_call.block.nil?

          args = chain_call.arguments
          return nil unless args.nil? || args.arguments.empty?

          case chain_call.receiver
          when Prism::LocalVariableReadNode
            [:local, chain_call.receiver.name, chain_call.name]
          when Prism::InstanceVariableReadNode
            [:ivar, chain_call.receiver.name, chain_call.name]
          end
        end

        # Walks the lexical-nesting chain derived from `scope.self_type` and returns the first
        # `<prefix>::<bare_name>` (or bare `<bare_name>` at the top level) that the environment
        # recognises. Falls back to `bare_name` itself when nothing in the chain resolves; the
        # downstream `narrow_class` then yields the conservative answer for unknown receivers.
        #
        # A MULTI-SEGMENT spelling is relative too and gets the same walk (#635). `Type::Nominal`
        # written inside `module Rigor` is not "already qualified": Ruby anchors the path's FIRST
        # segment through `Module.nesting`, so the constant it names is `Rigor::Type::Nominal`.
        # Treating any `::` as absolute left every such guard narrowing to a name no environment
        # knows, and each subsequent reader call on the narrowed receiver degraded to
        # `Dynamic[top]` — ~300 sites in Rigor's own `lib/` alone. Trying the whole path under
        # each prefix is the same rule the single-segment case already applies, and it adopts a
        # candidate only when the scope actually knows it, so a genuinely absolute spelling still
        # falls through to `bare_name` unchanged.
        #
        # NOT `Module.nesting`, though — an APPROXIMATION of it, and the gap is #652's. The chain
        # comes from `lexical_nesting_for`, which peels `scope.self_type.class_name`; that string
        # is identical for `class Admin::UsersController` and for `module Admin; class
        # UsersController`, so the derivation cannot tell a COMPACT definition from a nested one
        # and hands back `["Admin::UsersController", "Admin"]` for both. Ruby's nesting in the
        # compact form is `[Admin::UsersController]` alone, so a bare `User` there means `::User`
        # while this walk answers `Admin::User`. The defect is in the derivation, not in any one
        # guard shape: fixing `lexical_nesting_for` (and `Reflection.enclosing_class_path`, which
        # peels the same way) closes it for `is_a?`, `case`/`when` and `===` at once. Until then
        # `case`/`when` and `===` share the divergence that `is_a?` already had.
        def resolve_class_name_lexically(bare_name, scope)
          chain = lexical_nesting_for(scope)
          chain.each do |prefix|
            candidate = "#{prefix}::#{bare_name}"
            return candidate if class_known_to_scope?(scope, candidate)
          end
          bare_name
        end

        # Combines the environment's RBS-known set with the scope's in-source
        # `discovered_classes` table so a lexical-nesting candidate matches a class the project
        # declares but has no RBS for.
        def class_known_to_scope?(scope, candidate)
          return true if scope.environment.class_known?(candidate)

          scope.discovered_classes.key?(candidate)
        end

        # Approximates `Module.nesting` from the inferable `self_type`. Today's implementation
        # handles the common case: when the surrounding method is a regular instance method
        # (`self_type = Nominal[T]`) or a class-body / singleton (`self_type = Singleton[T]`),
        # the chain is `T`'s namespace path — `Foo::Bar::Baz` → `["Foo::Bar::Baz", "Foo::Bar",
        # "Foo"]`. Returns an empty array when `self_type` is unknown.
        def lexical_nesting_for(scope)
          self_type = scope.self_type
          base = case self_type
                 when Type::Nominal, Type::Singleton then self_type.class_name
                 end
          return [] if base.nil? || base.empty?

          parts = base.split("::")
          parts.each_index.map { |i| parts[0..-(i + 1)].join("::") }
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

        # Slice 7 phase 4 — `===`-narrowing. The case-equality predicate `<receiver> === local`
        # is the operator that backs Ruby's `case`/`when` dispatch. Three receiver shapes
        # produce sound narrowing rules:
        #
        # - **Class / Module receiver**: `Foo === x` is isomorphic to `x.is_a?(Foo)` (the
        #   default behaviour of `Module#===`). Reuse `class_predicate_scopes` so the truthy
        #   edge narrows down to `Foo` and the falsey edge subtracts `Foo` from a union.
        # - **Range literal receiver** (`(1..10) === x`): the default `Range#===` includes `x`
        #   iff the endpoints compare it. We conservatively narrow `x` to `Numeric` for
        #   integer-endpoint ranges and to `String` for string-endpoint ranges; other endpoint
        #   types fall through.
        # - **Regexp literal receiver** (`/foo/ === x`): the match operator coerces `x` to a
        #   String, so the truthy edge narrows `x` to `String`. The falsey edge keeps the entry
        #   type unchanged because `Regexp#===` returns false for non-Strings AND for Strings
        #   that simply do not match.
        #
        # Anything else — non-local LHS argument, dynamic receiver, custom `===` method — falls
        # through to the no-narrowing branch (nil), preserving the entry scope on both edges.
        def analyse_case_equality_predicate(node, scope)
          return nil if node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          arg = node.arguments.arguments.first
          case arg
          when Prism::LocalVariableReadNode
            current = scope.local(arg.name)
            return nil if current.nil?

            analyse_case_equality_receiver(node.receiver, scope, arg.name, current)
          when Prism::CallNode
            analyse_case_equality_on_chain(node.receiver, arg, scope)
          end
        end

        # `Class === <local/ivar>.<method>` — the case-equality counterpart of
        # {.analyse_class_predicate_on_chain}. The `open3` idiom `if Hash === cmd.last` narrows
        # `cmd.last` to the class inside the branch, recorded as a single-hop method-chain
        # narrowing keyed on the chain address (same stability rules as `is_a?` on a chain).
        # Only static class/module receivers narrow here — the Range / Regexp literal receivers
        # (`(1..10) === x.foo`) are not a common method-chain shape and stay deferred.
        def analyse_case_equality_on_chain(receiver, chain_arg, scope)
          class_name = lexical_class_name(receiver, scope)
          return nil if class_name.nil?

          address = stable_chain_address(chain_arg)
          return nil if address.nil?

          current = scope.type_of(chain_arg)
          return nil if current.nil?

          truthy_type = narrow_class(current, class_name, exact: false, environment: scope.environment)
          falsey_type = narrow_not_class(current, class_name, exact: false, environment: scope.environment)
          [
            scope.with_method_chain_narrowing(*address, truthy_type),
            scope.with_method_chain_narrowing(*address, falsey_type)
          ]
        end

        def analyse_case_equality_receiver(receiver, scope, local_name, current)
          if (class_name = lexical_class_name(receiver, scope))
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

        # Maps a case-equality literal receiver to the class whose membership is implied by the
        # truthy edge. `Prism::ParenthesesNode` wrappers are transparently unwrapped (`(1..10)
        # === x` is parsed with the range inside parentheses).  Range literals: integer
        # endpoints → `Numeric`; string endpoints → `String`. Regexp literals → `String`. Other
        # shapes return nil so the caller falls through.
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

        # Slice 4b-1 (ADR-7 § "Slice 4-A/4-B") — single-point RBS::Extended contribution
        # analyser. Replaces the earlier sibling pair (`analyse_rbs_extended_predicate` +
        # `analyse_rbs_extended_assert_if`) with one path that routes through
        # `RbsExtended.read_flow_contribution` and `Rigor::FlowContribution::Merger.merge`. The
        # bundle's `truthy_facts` slot already includes both the `predicate-if-true` and
        # `assert-if-true` Facts (slice 4a routing closed the v0.0.9 imperfection); the
        # `falsey_facts` slot mirrors that. The merger composes any future plugin contribution
        # at the same site alongside the RBS::Extended bundle without changing this analyser.
        #
        # Conservative envelope (carried over from the previous implementation):
        # - Receiver type must be `Type::Nominal`, `Type::Singleton`, or `Type::Constant`.
        # - The method must be present in the loader.
        # - For each fact, the corresponding positional argument (matched by parameter name in
        #   the selected overload) MUST be a `Prism::LocalVariableReadNode` for narrowing to
        #   apply.
        # - When the target is `self`, narrowing applies to the receiver — but the engine does
        #   not yet narrow `self` itself, so `self`-targeted facts are accepted by the merger
        #   but currently produce no scope edits.
        def analyse_rbs_extended_contribution(node, scope)
          method_def = resolve_rbs_extended_method(node, scope)
          return nil if method_def.nil?

          contribution = RbsExtended.read_flow_contribution(method_def, environment: scope.environment)
          return nil if contribution.nil?

          result = Rigor::FlowContribution::Merger.merge([contribution])
          truthy_facts = result.truthy_facts
          falsey_facts = result.falsey_facts
          return nil if truthy_facts.empty? && falsey_facts.empty?

          apply_facts_to_scope_pair(node, scope, truthy_facts, falsey_facts, method_def)
        end

        def apply_facts_to_scope_pair(call_node, entry_scope, truthy_facts, falsey_facts, method_def)
          truthy_scope = entry_scope
          falsey_scope = entry_scope
          truthy_facts.each do |fact|
            truthy_scope = apply_fact_to_scope(fact, call_node, entry_scope, truthy_scope, method_def)
          end
          falsey_facts.each do |fact|
            falsey_scope = apply_fact_to_scope(fact, call_node, entry_scope, falsey_scope, method_def)
          end
          [truthy_scope, falsey_scope]
        end

        def apply_fact_to_scope(fact, call_node, entry_scope, target_scope, method_def)
          target_node = fact_target_node(fact, call_node, method_def)
          return apply_self_fact(fact, target_node, entry_scope, target_scope) if fact.target_kind == :self
          return target_scope unless target_node.is_a?(Prism::LocalVariableReadNode)

          local_name = target_node.name
          current = entry_scope.local(local_name)
          return target_scope if current.nil?

          narrowed = narrow_for_fact(current, fact, entry_scope.environment)
          target_scope.with_local(local_name, narrowed)
        end

        # v0.1.1 Track 1 slice 3 — `target_kind == :self` facts (`predicate-if-true self is T`,
        # `predicate-if-false self is T`) narrow whichever scope binding is bound to the call's
        # receiver. Four receiver shapes participate:
        #
        #   `recv.method?` where recv is...
        #   - `LocalVariableReadNode`            -> narrow that local
        #   - `InstanceVariableReadNode`         -> narrow that ivar
        #   - `Prism::SelfNode` (explicit self)  -> narrow `self_type`
        #   - nil (implicit self call inside a method body)
        #                                        -> narrow `self_type`
        #
        # Other receiver shapes (method chains, expressions) have no scope binding to narrow
        # against and fall through.
        def apply_self_fact(fact, receiver_node, entry_scope, target_scope)
          case receiver_node
          when nil, Prism::SelfNode
            current = entry_scope.self_type
            return target_scope if current.nil?

            narrowed = narrow_for_fact(current, fact, entry_scope.environment)
            target_scope.with_self_type(narrowed)
          when Prism::LocalVariableReadNode
            current = entry_scope.local(receiver_node.name)
            return target_scope if current.nil?

            narrowed = narrow_for_fact(current, fact, entry_scope.environment)
            target_scope.with_local(receiver_node.name, narrowed)
          when Prism::InstanceVariableReadNode
            current = entry_scope.ivar(receiver_node.name)
            return target_scope if current.nil?

            narrowed = narrow_for_fact(current, fact, entry_scope.environment)
            target_scope.with_ivar(receiver_node.name, narrowed)
          else
            target_scope
          end
        end

        # Resolves a Fact's target node. Mirrors the earlier `effect_target_node` helper but
        # reads from the canonical Fact carrier; `:self` routes to the call receiver, otherwise
        # we look up the matching positional argument by parameter name.
        def fact_target_node(fact, call_node, method_def)
          if fact.target_kind == :self
            call_node.receiver
          else
            lookup_positional_arg(call_node, method_def, fact.target_name)
          end
        end

        def resolve_rbs_extended_method(node, scope)
          receiver_type = receiver_type_for_resolve(node, scope)
          return nil if receiver_type.nil?

          class_name = rbs_extended_class_name(receiver_type)
          return nil if class_name.nil?
          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)

          if receiver_type.is_a?(Type::Singleton)
            Rigor::Reflection.singleton_method_definition(class_name, node.name, scope: scope)
          else
            Rigor::Reflection.instance_method_definition(class_name, node.name, scope: scope)
          end
        rescue StandardError
          nil
        end

        # Implicit self call (`admin?` with no receiver inside an instance method body) — read
        # the method definition from `scope.self_type` per v0.1.1 Track 1 slice 3.
        def receiver_type_for_resolve(node, scope)
          node.receiver.nil? ? scope.self_type : scope.type_of(node.receiver)
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

        # Maps the effect's target parameter name to the call site argument by inspecting the
        # selected overload's required-positional parameter list. Returns the Prism arg node at
        # that position, or nil when the overload shape does not allow a precise match.
        def lookup_positional_arg(call_node, method_def, target_name)
          arguments = call_node.arguments&.arguments || []
          method_def.method_types.each do |mt|
            params = mt.type.required_positionals + mt.type.optional_positionals
            index = params.find_index { |param| param.name == target_name }
            return arguments[index] if index && arguments[index]
          end
          nil
        end

        # Slice 7 phase 5 — case/when accumulator. Walks each `when` condition, computes the
        # narrowed type for the subject as if `condition === subject`, and accumulates them.
        # The body's narrowed type is the union across all conditions; the falsey type is the
        # running result after subtracting every condition's class. Conditions whose shape we
        # cannot statically classify are treated as "no narrowing": the body falls back to the
        # union of what we did learn (or the entry type when nothing learned), and the falsey
        # edge is the entry type (because we cannot prove the unknown condition didn't match).
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

        # Per-condition rule. Returns `nil` when the condition shape is not recognised (caller
        # marks `fully_narrowable = false`), or `{truthy:, falsey:, fully_narrowable:}` when it
        # is.
        def apply_case_when_condition(scope, current, condition, falsey_acc)
          int_range = case_equality_integer_range(condition)
          return integer_range_when_result(current, int_range, falsey_acc) if int_range && integer_rooted_type?(current)

          int_literal = case_equality_integer_literal(condition)
          if int_literal && integer_rooted_type?(current)
            return integer_literal_when_result(current, int_literal, falsey_acc)
          end

          target = lexical_class_name(condition, scope) || case_equality_target_class(condition)
          return class_when_result(scope, current, target, falsey_acc) if target

          nil
        end

        def case_equality_integer_literal(condition)
          condition = unwrap_parens(condition)
          condition.is_a?(Prism::IntegerNode) ? condition.value : nil
        end

        def integer_literal_when_result(current, value, falsey_acc)
          # `case n when k` is `k === n` which for Integer is value equality. The truthy edge
          # collapses the local to `Constant[k]`; the falsey edge tightens via
          # `narrow_integer_not_equal` (only effective when k sits at one endpoint of the
          # current range).
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
          # The falsey edge of `n in [a, b]` is two-piece; we cannot express the complement
          # precisely with a single carrier, so keep the accumulator unchanged.
          # `fully_narrowable: false` forces the else-branch to see `current` (the unmodified
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

        # Returns `[low, high]` for a `Prism::RangeNode` whose endpoints are both
        # `Prism::IntegerNode` literals, with `..`/`...` exclusivity respected. Open-ended
        # ranges use the symbolic infinities so the existing comparison narrowing tier handles
        # them. Returns `nil` for any other shape (Float endpoints, String endpoints, dynamic
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

        # Walks a constant-reference subtree (`Prism::ConstantReadNode`, `Prism::ConstantPathNode`)
        # and renders its qualified name. Returns nil for any non-constant argument shape so the
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

        # The class a constant reference denotes at THIS point in the source (#635). `case t when
        # Type::Union` inside `module Rigor` names `Rigor::Type::Union`, and narrowing to the
        # source spelling instead left the guarded receiver an unknown nominal whose every reader
        # dispatched to `Dynamic[top]`. The resolution APPROXIMATES Ruby's — see
        # {#resolve_class_name_lexically} for where the derived nesting chain diverges (#652).
        #
        # Shared by the case-equality shapes (`Class === x`, `case/when`) so one spelling narrows
        # to one name whichever guard it is written in; `is_a?` / `kind_of?` / `instance_of?` go
        # through {#rooted_class_predicate_name}, which layers #614's extra decline on top of the
        # same walk. A rooted `::Foo` names the top level and never a lexically nearer shadow, so
        # it keeps the un-walked spelling. nil for any non-constant shape, as before.
        def lexical_class_name(node, scope)
          bare_name = static_class_name(node)
          return nil if bare_name.nil?
          return bare_name if Source::ConstantPath.rooted?(node)

          resolve_class_name_lexically(bare_name, scope)
        end

        # ----- narrow_class / narrow_not_class helpers -----

        # Polarity-aware dispatch table for {.narrow_class} / {.narrow_not_class}. Avoids
        # duplicating the per-carrier case statement and keeps each public surface a thin
        # delegate; the per-carrier helpers know which polarity to apply by looking at
        # `polarity:`.
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

        # Narrow a Nominal under `is_a?(class_name)`: when the nominal's class is already a
        # subclass of `class_name` (or matches under `exact: true`) preserve it; when
        # `class_name` is a subclass of the nominal's class (`Nominal[Numeric]` under
        # `is_a?(Integer)`) narrow DOWN to `Nominal[class_name]`; otherwise (disjoint
        # hierarchies under `is_a?`, mismatch under `instance_of?`) collapse to `Bot`.
        # Conservative when the analyzer environment cannot resolve either class.
        def narrow_nominal_to_class(nominal, class_name, context)
          return nominal if nominal.class_name == class_name
          return Type::Combinator.bot if context.exact

          case class_ordering(nominal.class_name, class_name, context)
          when :superclass then Type::Combinator.nominal_of(class_name)
          when :disjoint then Type::Combinator.bot
          when :subclass then nominal
          else
            # :unknown — the guard proved membership in a class the environment cannot order against the
            # bound (an RBS-less gem class, typically). Keeping the old bound licenses `undefined-method`
            # on the guard-proven branch (concurrent-ruby's `done.is_a?(Concurrent::Maybe)` kept `Array`
            # and fired on `.value`); the honest join is Dynamic — the guard destroyed the old knowledge.
            Type::Combinator.untyped
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

        # `Singleton[Foo]` is the *class object* `Foo`, an instance of `Class` (which is a
        # subclass of `Module`). Asking `Foo.is_a?(Class)` returns true; `Foo.is_a?(Foo)`
        # returns false unless `Foo` is `Class` itself. We approximate this by treating
        # singletons uniformly as `Class` instances.
        def narrow_singleton_to_class(singleton, class_name, context)
          subclass_of?("Class", class_name, context) ? singleton : Type::Combinator.bot
        end

        def narrow_singleton_not_class(singleton, class_name, context)
          subclass_of?("Class", class_name, context) ? Type::Combinator.bot : singleton
        end

        # Top/Dynamic narrow to `Nominal[class_name]` so dispatch can resolve through the asked
        # class; Bot stays Bot.
        def narrow_class_other(type, class_name)
          case type
          when Type::Dynamic, Type::Top then Type::Combinator.nominal_of(class_name)
          else type
          end
        end

        # Returns `true` when an instance of `rigor_class_name` satisfies
        # `is_a?(target_class_name)` (or `instance_of?(target_class_name)` when `exact: true`).
        # Falls back to the safe `false` when either name does not resolve through the analyzer
        # environment.
        def subclass_of?(rigor_class_name, target_class_name, context)
          return rigor_class_name == target_class_name if context.exact

          %i[subclass equal].include?(
            class_ordering(rigor_class_name, target_class_name, context)
          )
        end

        # Compares two class names through the analyzer environment. Returns `:equal` when they
        # resolve to the same class, `:subclass` when `lhs <= rhs`, `:superclass` when `rhs <=
        # lhs`, `:disjoint` when neither, and `:unknown` when either name does not resolve.
        def class_ordering(lhs, rhs, context)
          return :equal if lhs == rhs

          context.environment.class_ordering(lhs, rhs)
        end

        def analyse_nil_predicate(receiver, scope)
          case receiver
          when Prism::LocalVariableReadNode
            current = scope.local(receiver.name)
            return nil if current.nil?

            [
              scope.with_local(receiver.name, narrow_nil(current)),
              scope.with_local(receiver.name, narrow_non_nil(current))
            ]
          when Prism::InstanceVariableReadNode
            current = scope.ivar(receiver.name)
            return nil if current.nil?

            [
              scope.with_ivar(receiver.name, narrow_nil(current)),
              scope.with_ivar(receiver.name, narrow_non_nil(current))
            ]
          end
        end

        # The three value-pinned classes a union arm can name whose instances are the single
        # value itself. Their finality is what makes the polarity rule below sound: no subclass
        # can override the predicate, because there is no subclass.
        POLARITY_ARM_CLASSES = { nil => "NilClass", true => "TrueClass", false => "FalseClass" }.freeze
        private_constant :POLARITY_ARM_CLASSES

        # Drops union arms a zero-argument predicate's own signature rules out on each edge.
        #
        # `if x.present?` with `x: String | nil` must see `String` in the body. Rigor could not:
        # `present?` is an ActiveSupport method (so the engine must not join the hardcoded
        # `nil?` / `empty?` catalogue with it), and `resolve_rbs_extended_method` hands a union
        # receiver no `rigor:v1:predicate-if-true` facts, so annotating the RBS would not help
        # either. But the answer is already written down: the bundled ActiveSupport signature
        # declares `NilClass#present?: () -> false`, and a method that always returns `false` for
        # `nil` cannot have answered truthily on a `nil` receiver.
        #
        # Soundness rests on the arm being a value-pinned `nil` / `true` / `false`. For an
        # ordinary `Nominal[Foo]` arm the static type admits Foo's subclasses, any of which may
        # override the predicate and return the other polarity; the three classes here have no
        # subclasses, so the declared return is the runtime return.
        #
        # Safe navigation is excluded: `x&.blank?` yields `nil` (falsey) for a nil receiver
        # rather than `NilClass#blank?`'s declared `true`, so the falsey edge would wrongly drop
        # the nil arm. `analyse_safe_nav_receiver` below handles that shape's truthy edge.
        #
        # Returns `[truthy_scope, falsey_scope]`, or nil when no arm is ruled out, when an edge
        # would be emptied, or when the receiver has no scope binding to narrow.
        def analyse_union_predicate_polarity(node, scope)
          return nil if node.safe_navigation? || !argument_free?(node)
          return nil unless node.name.end_with?("?")

          receiver_type = receiver_binding_type(node.receiver, scope)
          return nil unless receiver_type.is_a?(Type::Union)

          truthy, falsey = partition_arms_by_polarity(receiver_type.members, node.name, scope)
          return nil if truthy.size == receiver_type.members.size && falsey.size == receiver_type.members.size
          return nil if truthy.empty? || falsey.empty?

          [
            narrow_receiver_binding(node.receiver, scope, Type::Combinator.union(*truthy)),
            narrow_receiver_binding(node.receiver, scope, Type::Combinator.union(*falsey))
          ]
        end

        # Splits `members` into the arms that survive the truthy edge and those that survive the
        # falsey edge. An arm whose polarity is unknown survives both.
        def partition_arms_by_polarity(members, method_name, scope)
          truthy = []
          falsey = []
          members.each do |arm|
            case arm_predicate_polarity(arm, method_name, scope)
            when :always_false then falsey << arm
            when :always_true then truthy << arm
            else
              truthy << arm
              falsey << arm
            end
          end
          [truthy, falsey]
        end

        # `:always_false` / `:always_true` when every RBS overload of `method_name` on the arm's
        # class returns that literal; nil for any other arm, signature, or lookup failure.
        def arm_predicate_polarity(arm, method_name, scope)
          returns = arm_predicate_return_types(arm, method_name, scope)
          return nil if returns.nil? || returns.empty?
          return :always_false if returns.all? { |type| literal_boolean?(type, false) }
          return :always_true if returns.all? { |type| literal_boolean?(type, true) }

          nil
        end

        # Declared return type of every RBS overload of `method_name` on the arm's class, or nil
        # when the arm is not one of the three value-pinned classes or the lookup fails.
        def arm_predicate_return_types(arm, method_name, scope)
          return nil unless arm.is_a?(Type::Constant)

          class_name = POLARITY_ARM_CLASSES[arm.value]
          return nil if class_name.nil?

          definition = Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope)
          definition&.method_types&.map { |method_type| method_type.type.return_type }
        rescue StandardError
          nil
        end

        def literal_boolean?(rbs_type, value)
          rbs_type.is_a?(RBS::Types::Literal) && rbs_type.literal == value
        end

        # The four receiver shapes with a scope binding the edges can rebind, mirroring
        # `apply_self_fact`. A method chain or arbitrary expression has none, so it reads nil and
        # the caller declines.
        def receiver_binding_type(receiver, scope)
          case receiver
          when Prism::LocalVariableReadNode then scope.local(receiver.name)
          when Prism::InstanceVariableReadNode then scope.ivar(receiver.name)
          when Prism::SelfNode then scope.self_type
          end
        end

        def narrow_receiver_binding(receiver, scope, narrowed)
          case receiver
          when Prism::LocalVariableReadNode then scope.with_local(receiver.name, narrowed)
          when Prism::InstanceVariableReadNode then scope.with_ivar(receiver.name, narrowed)
          when Prism::SelfNode then scope.with_self_type(narrowed)
          end
        end

        # Narrows a safe-navigation call's receiver (`v&.foo`) to its non-nil fragment on the
        # truthy edge, returning `[truthy, falsey]` or nil when nothing applies (not safe-nav,
        # opaque receiver, or already non-nil). Used standalone for a bare `v&.foo` truthy edge
        # and as a post-pass over the existing predicate edges.
        def analyse_safe_nav_receiver(node, scope)
          return nil unless node.safe_navigation?

          receiver = node.receiver
          reader, writer =
            case receiver
            when Prism::LocalVariableReadNode then %i[local with_local]
            when Prism::InstanceVariableReadNode then %i[ivar with_ivar]
            else return nil
            end

          current = scope.public_send(reader, receiver.name)
          return nil if current.nil?

          non_nil = narrow_non_nil(current)
          return nil if non_nil.equal?(current)

          [scope.public_send(writer, receiver.name, non_nil), scope]
        end

        # Issue #606 slice 1 — the SAFE-NAV CHAIN forms. {.analyse_safe_nav_receiver} above proves
        # the receiver non-nil when the `&.` call is itself the predicate (`if v&.foo`). It cannot
        # see the far more common shape where the `&.` result is fed to one more call:
        #
        #   if custom&.value.present?          # mastodon extended_description.rb / privacy_policy.rb
        #   return true if backup&.user.nil?   # mastodon backup_worker.rb  (the FALL-THROUGH proves it)
        #
        # Both were measured firing `call.possible-nil-receiver` on correct code (#574's matrix).
        #
        # ## Why a truthy chain proves the root non-nil, and when it does not
        #
        # If the root IS nil, `root&.y` is nil and every suffix runs ON nil. Reaching the guarded
        # branch then requires each of them to have returned — and the outermost to have returned
        # TRUTHY. Two things can stop that, and only these two are sound to rely on:
        #
        # 1. `NilClass` does not define the method. The call raises, so control never reaches the
        #    branch at all, and narrowing the branch body is vacuously correct.
        # 2. The method is defined on `NilClass` and documented falsey there — {NIL_FALSEY_SUFFIXES}.
        #    ActiveSupport's `nil.present?` is `false`, so a truthy answer excludes the nil root.
        #
        # Anything else must decline, and the temptation to wave this through is exactly where the
        # bug would be: most of what `NilClass` DOES define returns something truthy. `nil.to_s` is
        # `""`, `nil.to_a` is `[]`, `nil.to_i` is `0`, `nil.inspect` is `"nil"` — all truthy — and
        # `nil.nil?` and `nil.blank?` are literally `true`. Narrowing on `x&.y.nil?`'s TRUTHY edge
        # would invert the guard's meaning. `nil?` therefore gets the opposite edge instead: a
        # FALSEY `x&.y.nil?` says `x&.y` is not nil, which no nil root can produce.
        #
        # Scoped to chains that actually contain `&.`. The same raise-based argument would license
        # narrowing a plain `x.y.present?` chain, but there `x.y` is itself the latent nil bug this
        # rule exists to report, and suppressing it is the opposite of the intent.
        NIL_FALSEY_SUFFIXES = %i[present?].freeze
        private_constant :NIL_FALSEY_SUFFIXES

        def analyse_safe_nav_chain(node, scope)
          chain = safe_nav_chain(node)
          return nil if chain.nil?

          receiver, suffixes = chain
          edge = safe_nav_chain_edge(suffixes, scope)
          return nil if edge.nil?

          narrowed = safe_nav_chain_narrowed_scope(receiver, scope)
          return nil if narrowed.nil?

          edge == :truthy ? [narrowed, scope] : [scope, narrowed]
        end

        # Walks a call chain down to its `&.` link, collecting the suffix method names applied
        # above it (outermost first). Declines unless the chain bottoms out in a `&.` call on a
        # direct local / ivar read — those are the two bindings a scope can rewrite — and unless
        # every suffix is a bare reader or predicate, since an argument or a block could make the
        # answer depend on something other than the receiver.
        #
        # `allow_bare:` false keeps the zero-suffix case (`if v&.foo`) with
        # {.analyse_safe_nav_receiver}, which already owns it; the equality form passes true
        # because there the `&.` call IS the comparison's receiver.
        def safe_nav_chain(node, allow_bare: false)
          suffixes = []
          current = node
          while current.is_a?(Prism::CallNode) && !current.safe_navigation?
            return nil unless argument_free?(current) && current.block.nil?

            suffixes << current.name
            current = current.receiver
          end
          return nil unless current.is_a?(Prism::CallNode) && current.safe_navigation?
          return nil if suffixes.empty? && !allow_bare

          receiver = current.receiver
          return nil unless receiver.is_a?(Prism::LocalVariableReadNode) ||
                            receiver.is_a?(Prism::InstanceVariableReadNode)

          [receiver, suffixes]
        end

        # Which edge — if either — a chain's outcome narrows on. The inner suffixes (everything
        # below the outermost) only ever have to NOT return, so they are held to the raise test
        # alone; the outermost decides the edge per the table in {NIL_FALSEY_SUFFIXES}'s comment.
        def safe_nav_chain_edge(suffixes, scope)
          outermost, *inner = suffixes
          return nil unless inner.all? { |name| !nilclass_method?(name, scope) }
          return :falsey if outermost == :nil?
          return :truthy if NIL_FALSEY_SUFFIXES.include?(outermost)
          return :truthy unless nilclass_method?(outermost, scope)

          nil
        end

        def safe_nav_chain_narrowed_scope(receiver, scope)
          reader, writer =
            case receiver
            when Prism::LocalVariableReadNode then %i[local with_local]
            when Prism::InstanceVariableReadNode then %i[ivar with_ivar]
            else return nil
            end

          current = scope.public_send(reader, receiver.name)
          return nil if current.nil?

          non_nil = narrow_non_nil(current)
          return nil if non_nil.equal?(current)

          scope.public_send(writer, receiver.name, non_nil)
        end

        # Issue #606 slice 1, second form — a safe-nav chain COMPARED to a value that cannot be
        # nil: `next unless status&.account_id == @account.id`. A nil root makes the left side nil,
        # and `nil == <non-nil>` is false, so a true comparison excludes it.
        #
        # The whole form turns on proving the OTHER operand non-nil, and `x&.y == nil` is the
        # counter-example that must never narrow — there a nil root makes the comparison TRUE.
        # {.provably_non_nil_type?} is deliberately a whitelist rather than "not obviously nil":
        # an operand typed `Dynamic` may well be nil at runtime, so it declines. That costs the
        # third corpus site (`@account.id` types opaque there), which is the honest price of not
        # guessing.
        #
        # `!=` takes the opposite edge, for the same reason `nil?` did above: a nil root makes
        # `nil != <non-nil>` true, so it is the FALSEY edge that proves the root non-nil.
        def analyse_safe_nav_chain_equality(node, scope)
          return nil if node.arguments.nil? || node.arguments.arguments.size != 1

          chain = safe_nav_chain(node.receiver, allow_bare: true)
          return nil if chain.nil?

          receiver, suffixes = chain
          return nil unless suffixes.all? { |name| !nilclass_method?(name, scope) }
          return nil unless provably_non_nil_type?(scope.type_of(node.arguments.arguments.first))

          narrowed = safe_nav_chain_narrowed_scope(receiver, scope)
          return nil if narrowed.nil?

          node.name == :== ? [narrowed, scope] : [scope, narrowed]
        end

        # Whitelist: true only for types every inhabitant of which is non-nil. `Dynamic` / `Top`
        # answer FALSE — an untyped operand is exactly the case where nil cannot be excluded —
        # and so does `Bot`, which has no inhabitants to reason about.
        def provably_non_nil_type?(type)
          case type
          when Type::Constant then !type.value.nil?
          when Type::Nominal then type.class_name != "NilClass"
          when Type::Singleton, Type::Tuple, Type::HashShape then true
          when Type::Union then type.members.all? { |member| provably_non_nil_type?(member) }
          end
        end

        # Issue #606 slice 2 — MEMBERSHIP. `collection.include?(x)` answering true proves `x` is one
        # of the collection's elements, so if none of those can be nil, neither can `x`:
        #
        #   unless Redmine::Reaction::REACTABLE_TYPES.include?(object_type)   # redmine reactions_controller.rb
        #     render_403
        #     return
        #   end
        #   @object = object_type.constantize.find(...)                       # ← fired before this
        #
        # The proof lives entirely in the collection, which is why {.nil_free_collection?} answers
        # only for shapes whose element types are actually known — a literal / `Tuple`, or an
        # `Array` / `Set` carrying an element type. An untyped collection declines: `Dynamic` may
        # hold nil, and "we do not know" must not read as "no nil here".
        #
        # Only the truthy edge narrows. A false `include?` says nothing about `x` — a nil `x` is
        # simply not in the list, which is exactly what false means.
        MEMBERSHIP_COLLECTION_CLASSES = %w[Array Set].freeze
        private_constant :MEMBERSHIP_COLLECTION_CLASSES

        def analyse_membership_predicate(node, scope)
          return nil if node.receiver.nil? || node.arguments.nil?
          return nil unless node.arguments.arguments.size == 1

          argument = node.arguments.arguments.first
          reader, writer =
            case argument
            when Prism::LocalVariableReadNode then %i[local with_local]
            when Prism::InstanceVariableReadNode then %i[ivar with_ivar]
            else return nil
            end
          return nil unless nil_free_collection?(scope.type_of(node.receiver))

          current = scope.public_send(reader, argument.name)
          return nil if current.nil?

          non_nil = narrow_non_nil(current)
          return nil if non_nil.equal?(current)

          [scope.public_send(writer, argument.name, non_nil), scope]
        end

        # True only when every inhabitant the collection can yield is non-nil. Restricted to
        # sequence shapes on purpose: `Hash#include?` asks about KEYS and `Range#include?` about
        # bounds, so neither element story is the one this rule reasons about.
        def nil_free_collection?(type)
          case type
          when Type::Tuple
            !type.elements.empty? && type.elements.all? { |element| provably_non_nil_type?(element) }
          when Type::Constant
            type.value.is_a?(Array) && !type.value.empty? && type.value.none?(&:nil?)
          when Type::Nominal
            MEMBERSHIP_COLLECTION_CLASSES.include?(type.class_name) &&
              type.type_args.size == 1 &&
              provably_non_nil_type?(type.type_args.first)
          end
        end

        # Layers the safe-nav non-nil truthy narrowing over the edges an existing predicate path
        # already produced, so a safe-nav string predicate (`v&.start_with?(x)`) keeps its
        # relational fact AND proves `v` non-nil on the truthy edge. Re-runs the predicate's
        # narrowing under the non-nil truthy scope so the fact is attached to the narrowed
        # binding. No-op for non-safe-nav calls.
        def apply_safe_nav_non_nil(node, scope, edges)
          return edges unless node.safe_navigation? && edges

          truthy, falsey = edges
          safe = analyse_safe_nav_receiver(node, scope)
          return edges unless safe

          receiver = node.receiver
          reader = receiver.is_a?(Prism::InstanceVariableReadNode) ? :ivar : :local
          non_nil = safe.first.public_send(reader, receiver.name)
          writer = receiver.is_a?(Prism::InstanceVariableReadNode) ? :with_ivar : :with_local
          [truthy.public_send(writer, receiver.name, non_nil), falsey]
        end

        # `a && b` short-circuits: the truthy edge is the truthy edge of `b` evaluated under
        # `a`'s truthy scope; the falsey edge is the union of `a`'s falsey scope (b skipped) and
        # `b`'s falsey scope (b ran but returned falsey). When a sub-edge cannot be narrowed we
        # fall back to the entry scope so the caller still sees consistent keys across the two
        # output scopes.
        def analyse_and(node, scope)
          truthy_a, falsey_a = analyse(node.left, scope) || [scope, scope]
          truthy_b, falsey_b = analyse(node.right, truthy_a) || [truthy_a, truthy_a]
          [truthy_b, falsey_a.join(falsey_b)]
        end

        # `a || b` short-circuits: the truthy edge is the union of `a`'s truthy scope (b
        # skipped) and `b`'s truthy scope (b ran and was truthy); the falsey edge is `b`'s
        # falsey scope evaluated under `a`'s falsey scope.
        def analyse_or(node, scope)
          truthy_a, falsey_a = analyse(node.left, scope) || [scope, scope]
          truthy_b, falsey_b = analyse(node.right, falsey_a) || [falsey_a, falsey_a]
          [truthy_a.join(truthy_b), falsey_b]
        end
      end
    end
  end
end
