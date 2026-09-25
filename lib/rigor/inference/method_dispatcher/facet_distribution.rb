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
      # A wider facet keeps the wrapper and the receiver's arm, as before. It is usually itself a #521 join
      # (`Dynamic[BigDecimal | Complex | Float | Integer | Rational]` from `n * untyped`), and read member by member it
      # joined every arm again: 256 call sites across the survey corpus lost a precise type to `Dynamic`, and a
      # recursion's fuel-exhausted `n * of(n - 1)` stopped reading `Integer`.
      module FacetDistribution
        # The most facet members, `nil` aside, that selection reads one by one.
        MEMBER_LIMIT = 2
        # Member-wise argument lists beyond this keep their wrappers.
        CAP = 8

        module_function

        # Whether any argument is a `Dynamic` whose facet selection reads; the cheap guard of the hot path.
        def faceted?(arg_types) = arg_types.any? { |arg| arg.is_a?(Type::Dynamic) && facet_members(arg) }

        # Selects through the block, called as `yield(arg_types, member)`. When every narrow-faceted argument has one
        # member, it yields once with the members standing in. Otherwise, with `member_wise`, it yields once per
        # member-wise list (`member` true, where the block answers only a genuine match); without it (the singular
        # `select`, whose one answer a member order would decide), or when any list matches nothing or there are
        # more than {CAP}, it yields once with the arguments as given. A list that matches nothing proves only that
        # no overload names that member: a supertype member (`Numeric` in `2 ** n`'s `Complex | Numeric`) still
        # reaches an arm at runtime, and dropping it read `1 + 2 ** n` as a precise `Complex`.
        def select(arg_types, definition, member_wise:, environment:, &)
          choices = arg_types.map { |arg| facet_members(arg) || [arg] }
          return yield(arg_types, false) if supertype_member?(choices, arg_types, definition.method_types, environment)
          return yield(choices.map(&:first), false) if choices.all? { |members| members.size == 1 }
          return yield(arg_types, false) unless member_wise

          picks = picks_by_member(choices, &)
          picks.empty? ? yield(arg_types, false) : picks
        end

        # Whether a facet member is a proper superclass of a class some overload's parameter names (`Numeric` against
        # `Integer#<=>`'s `(Integer)`): the member's runtime value may be of that subclass and take that arm, yet the
        # member itself skips it for a catch-all (`(untyped) -> Integer?`), whose return then read as precise. Both
        # halves of "no overload takes it" and "an overload takes it" are unproven for such a member, so the wrapper
        # stays. A literal has no subclass to hide.
        def supertype_member?(choices, arg_types, overloads, environment)
          members = choices.each_with_index.flat_map { |ms, i| facet_members(arg_types[i]) ? ms : [] }
          members = members.grep(Type::Nominal)
          return false if members.empty?
          return true if environment.nil?

          names = overloads.flat_map { |method_type| param_class_names(method_type) }.uniq
          members.any? do |member|
            names.any? { |name| environment.class_ordering(name, member.class_name) == :subclass }
          end
        end

        # The class names an overload's positional parameters spell, rest included, through `?` and `|`.
        def param_class_names(method_type)
          fun = method_type.type
          return [] unless fun.respond_to?(:required_positionals)

          params = fun.required_positionals + fun.optional_positionals + fun.trailing_positionals
          params += [fun.rest_positionals] if fun.rest_positionals
          params.flat_map { |param| class_names_in(param.type) }
        end

        def class_names_in(rbs_type)
          case rbs_type
          when RBS::Types::ClassInstance then [rbs_type.name.to_s.delete_prefix("::")]
          when RBS::Types::Optional then class_names_in(rbs_type.type)
          when RBS::Types::Union then rbs_type.types.flat_map { |member| class_names_in(member) }
          else []
          end
        end

        # The distinct overloads the member-wise lists pick; none past {CAP} or when any list picks nothing.
        def picks_by_member(choices)
          return [] if choices.reduce(1) { |count, members| count * members.size } > CAP

          lists = choices.first.product(*choices.drop(1)).map { |combination| yield(combination, true) }
          lists.any?(&:empty?) ? [] : lists.flatten(1).uniq(&:object_id)
        end

        # A `Dynamic` argument's facet members other than `nil`, or nil when selection keeps the wrapper: not a
        # `Dynamic`, the untyped carrier, a facet that is only `nil`, one with an untyped member, or one wider than
        # {MEMBER_LIMIT}.
        def facet_members(arg)
          return nil unless arg.is_a?(Type::Dynamic) && !arg.static_facet.is_a?(Type::Top)

          facet = arg.static_facet
          members = (facet.is_a?(Type::Union) ? facet.members : [facet]).reject { |member| nil_value?(member) }
          return nil if members.any? { |member| member.is_a?(Type::Dynamic) || member.is_a?(Type::Top) }

          members if members.size.between?(1, MEMBER_LIMIT)
        end

        def nil_value?(type)
          return type.value.nil? if type.is_a?(Type::Constant)

          type.is_a?(Type::Nominal) && type.class_name == "NilClass"
        end
      end
    end
  end
end
