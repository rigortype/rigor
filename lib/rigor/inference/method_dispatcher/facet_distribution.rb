# frozen_string_literal: true

require_relative "../../type"
require_relative "../../rbs_extended"

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
      # Only sealed members are read ({.sealed?}): a literal, or a plain `Integer`, `Float`, `Rational`, `Complex` or
      # `Symbol`, core classes whose `new` and `allocate` are undefined. Such a member's runtime value is of exactly its
      # class, where any other member's may be of a subclass and take an arm the member itself skips: `Numeric` in
      # `2 ** v`'s `Complex | Numeric` skipped a project `(real) -> Float`, whose `real` alias names `Integer`, for a
      # catch-all `(untyped) -> nil`, and `.floor` on the call reported `call.undefined-method`. Scanning the parameters
      # for a subclass of the member caught a plain class name and missed aliases, `instance`, type variables,
      # intersections, singletons and modules.
      #
      # Even a sealed member is read only where acceptance can rule it out ({.provable?}). Acceptance reads class
      # relations from the analyzer's own process, so it answers `no` for `Integer` against a `(Printable)` that project
      # RBS or source includes into `Integer` (#1352). A plain argument shares that, but the wrapper hid it from a
      # `Dynamic` one: with `(Printable) -> String | (Integer) -> Integer`, reading the member typed
      # `fmt(Integer(v)).upcase` as `Integer` and fired `call.undefined-method` where master read `String`. So every
      # overload's positional parameters must be spelled as a class RBS declares, `untyped`, `top` or `nil`, through `?`
      # and `|`, which leaves acceptance only a sealed class's fixed ancestry to read. A literal or `bool` parameter
      # asks for a value, which a class member cannot prove it holds: `Symbol` skipped `(:json) -> String` for
      # `(untyped) -> nil`, and a `TrueClass` member was refused by `bool` itself. Anything else, a module, a stubbed
      # name, an alias, an interface, a type variable, `instance`, `self`, an intersection, a singleton or an untyped
      # `(?)`, keeps the wrapper too. The list names what is provable rather than what is not, so a form it has not met
      # falls back to master's reading.
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
        # Core classes whose `new` and `allocate` are undefined, so plain Ruby cannot make an instance of a subclass
        # (`Integer`, `Float` and `Symbol` have no allocator at all; a `Rational` or `Complex` subclass instance takes
        # `Marshal.load` or a rebound `Class#allocate`). `NilClass` leaves with the facet's `nil`, and `true` and
        # `false` are read only as literals.
        SEALED_CLASSES = %w[Integer Float Rational Complex Symbol].freeze

        module_function

        # Whether any argument is a `Dynamic` whose facet selection reads; the cheap guard of the hot path.
        def faceted?(arg_types) = arg_types.any? { |arg| arg.is_a?(Type::Dynamic) && facet_members(arg) }

        # Selects through the block, called as `yield(arg_types, member)`. It yields once per member-wise list, one
        # member standing in for each faceted argument, with `member` true so the block answers only a genuine match.
        # It yields once with the arguments as given instead when the overloads are not {.provable?}, when an argument
        # has two members and the caller is the singular `select` (`member_wise` false, whose one answer a member order
        # would decide), when there are more than {CAP} lists, or when any list matches nothing.
        def select(arg_types, definition, member_wise:, environment:, &)
          choices = arg_types.map { |arg| facet_members(arg) || [arg] }
          return yield(arg_types, false) unless member_wise || choices.all? { |members| members.size == 1 }
          return yield(arg_types, false) unless provable?(definition, environment)

          picks = picks_by_member(choices, &)
          picks.empty? ? yield(arg_types, false) : picks
        end

        # The distinct overloads the member-wise lists pick; none past {CAP} or when any list picks nothing.
        def picks_by_member(choices)
          return [] if choices.reduce(1) { |count, members| count * members.size } > CAP

          lists = choices.first.product(*choices.drop(1)).map { |combination| yield(combination, true) }
          lists.any?(&:empty?) ? [] : lists.flatten(1).uniq(&:object_id)
        end

        # Whether every overload's positional parameters, rest and trailing included, are in a provable form
        # ({.provable_param?}), where acceptance's answer for a sealed member rests only on the member class's fixed
        # ancestry; a `rigor:v1:param:` override proves nothing either.
        def provable?(definition, environment)
          loader = environment&.rbs_loader
          return false if loader.nil?
          return false unless RbsExtended.param_type_override_map(definition, environment: environment).empty?

          definition.method_types.all? do |method_type|
            fun = method_type.type
            next false unless fun.respond_to?(:required_positionals)

            params = fun.required_positionals + fun.optional_positionals + fun.trailing_positionals
            params += [fun.rest_positionals] if fun.rest_positionals
            params.all? { |param| provable_param?(param.type, loader) }
          end
        end

        def provable_param?(rbs_type, loader)
          case rbs_type
          when RBS::Types::ClassInstance then declared_class?(rbs_type.name.to_s.delete_prefix("::"), loader)
          when RBS::Types::Optional then provable_param?(rbs_type.type, loader)
          when RBS::Types::Union then rbs_type.types.all? { |member| provable_param?(member, loader) }
          when RBS::Types::Bases::Any, RBS::Types::Bases::Top, RBS::Types::Bases::Nil then true
          else false
          end
        end

        # A class RBS declares, not a module and not a name Rigor stubbed because no RBS declares it: a class cannot be
        # included, and a sealed member's class has a fixed ancestry, so acceptance's answer against it holds.
        def declared_class?(name, loader)
          loader.class_known?(name) && !loader.rbs_module?(name) && !loader.synthesized_type_names.include?(name)
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

        # A member whose runtime value is of exactly its class: a `Constant`, which is a value of that exact class, or a
        # plain instance of {SEALED_CLASSES}.
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
