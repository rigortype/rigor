# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #1350 — how `OverloadSelector` reads a `Dynamic[T]` argument. The internal spec keeps a `Dynamic` whose
      # static facet is not `top` out of the imprecise arguments because its facet discriminates, but acceptance
      # short-circuits on the wrapper and takes it against any parameter, so the receiver-affinity pre-sort's first arm
      # won: `Money#add(Integer(v))` typed `Money` and `.even?` reported `call.undefined-method`.
      #
      # Selection therefore reads a narrow facet's members ({.select}), leaving out `nil`: a facet's `nil` is usually
      # the join of an overload that returns it for some untyped input (`Integer(v)`'s `exception:` form), and chosen
      # by it `Integer | nil` fell through to the only arm that takes `nil` and `Complex(Integer(v), 1)` turned
      # `Complex?`. One member left stands in for the argument, pass 0 included, and the return stays unwrapped; two
      # are selected one by one, and the distinct picks come back together for the dispatch layer's join, wrapped in
      # `Dynamic` when their returns differ (#521).
      #
      # Only sealed members are read ({.sealed?}): a literal, or a plain instance of a core class no subclass can
      # instantiate. Such a member's runtime value is of exactly its class, so reading it is reading a plain argument
      # of that class, with no hazard a plain argument lacks. Any other member's value may be of a subclass and take an
      # arm the member itself skips: `Numeric` in `2 ** v`'s `Complex | Numeric` skipped a project `(real) -> Float`,
      # whose `real` alias names `Integer`, for a catch-all `(untyped) -> nil`, and `.floor` on the call reported
      # `call.undefined-method`. Scanning the parameters for a subclass of the member caught a plain class name and
      # missed aliases, `instance`, type variables, intersections, singletons and modules, so such a facet keeps the
      # wrapper instead.
      #
      # A wider facet keeps the wrapper and the receiver's arm, as before. It is usually itself a #521 join
      # (`Dynamic[BigDecimal | Complex | Float | Integer | Rational]` from `n * untyped`), and read member by member it
      # joined every arm again: 256 call sites across the survey corpus lost a precise type to `Dynamic`, and a
      # recursion's fuel-exhausted `n * of(n - 1)` stopped reading `Integer`.
      module FacetDistribution
        # The most facet members, `nil` aside, that selection reads one by one.
        MEMBER_LIMIT = 2
        # Member-wise argument lists beyond this keep their wrappers.
        CAP = 8
        # Core classes that undefine their allocator, so no subclass has an instance and a value of one of them is of
        # exactly that class. `NilClass` leaves with the facet's `nil`.
        SEALED_CLASSES = %w[Integer Float Rational Complex Symbol TrueClass FalseClass].freeze

        module_function

        # Whether any argument is a `Dynamic` whose facet selection reads; the cheap guard of the hot path.
        def faceted?(arg_types) = arg_types.any? { |arg| arg.is_a?(Type::Dynamic) && facet_members(arg) }

        # Selects through the block, called as `yield(arg_types, member)`. When every facet selection reads has one
        # member, it yields once with the members standing in. Otherwise, with `member_wise`, it yields once per
        # member-wise list (`member` true, where the block answers only a genuine match); without it (the singular
        # `select`, whose one answer a member order would decide), or when any list matches nothing or there are
        # more than {CAP}, it yields once with the arguments as given.
        def select(arg_types, member_wise:, &)
          choices = arg_types.map { |arg| facet_members(arg) || [arg] }
          return yield(choices.map(&:first), false) if choices.all? { |members| members.size == 1 }
          return yield(arg_types, false) unless member_wise

          picks = picks_by_member(choices, &)
          picks.empty? ? yield(arg_types, false) : picks
        end

        # The distinct overloads the member-wise lists pick; none past {CAP} or when any list picks nothing.
        def picks_by_member(choices)
          return [] if choices.reduce(1) { |count, members| count * members.size } > CAP

          lists = choices.first.product(*choices.drop(1)).map { |combination| yield(combination, true) }
          lists.any?(&:empty?) ? [] : lists.flatten(1).uniq(&:object_id)
        end

        # A `Dynamic` argument's facet members other than `nil`, or nil when selection keeps the wrapper: not a
        # `Dynamic`, the untyped carrier, a facet that is only `nil`, one wider than {MEMBER_LIMIT}, or one with a
        # member that is not sealed, an untyped member included.
        def facet_members(arg)
          return nil unless arg.is_a?(Type::Dynamic) && !arg.static_facet.is_a?(Type::Top)

          facet = arg.static_facet
          members = (facet.is_a?(Type::Union) ? facet.members : [facet]).reject { |member| nil_value?(member) }
          members if members.size.between?(1, MEMBER_LIMIT) && members.all? { |member| sealed?(member) }
        end

        # A member whose runtime value is of exactly its class: a literal, or a plain instance of {SEALED_CLASSES}.
        def sealed?(member)
          case member
          when Type::Constant then true
          when Type::Nominal then member.type_args.empty? && SEALED_CLASSES.include?(member.class_name)
          else false
          end
        end

        def nil_value?(type)
          return type.value.nil? if type.is_a?(Type::Constant)

          type.is_a?(Type::Nominal) && type.class_name == "NilClass"
        end
      end
    end
  end
end
