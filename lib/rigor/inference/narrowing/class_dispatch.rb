# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module Narrowing
      # ADR-116 C1 — `narrow_class_dispatch`: the per-carrier narrowing for `Narrowing.narrow_class` and
      # `Narrowing.narrow_not_class`. {.narrow_class_dispatch} takes the type, the class name and a
      # `Narrowing::ClassNarrowingContext` (read through its `exact`, `polarity`, `environment` and `scope`
      # accessors only, so this file does not name the carrier) and answers the narrowed type.
      #
      # Plain functions on `Rigor::Type` values. Calls nothing in `Narrowing`; the two public narrowing entries
      # are its only callers.
      module ClassDispatch
        module_function

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

        # Issue #657 — `Bot` is the assertion "this can never match", and only a KNOWN-disjoint ordering
        # supports it (the reason {#declines_bot?} exists, and the repro it was written against):
        #
        #   module Taggable; def tag = "t"; end
        #   class Integer; include Taggable; end
        #   x = 1
        #   case x
        #   when Taggable then x.tag      # reported unreachable; `1.is_a?(Taggable)` is true
        #   end
        #
        # The ordering is `:unknown` because an in-source `include` into a CORE class never reaches the
        # environment's class ordering — the include is discovered in project source, `Integer`'s ancestry
        # comes from RBS, and the two are not joined (the precision half, left in #657).
        #
        # `:unknown` joins to Dynamic, the same answer {#narrow_nominal_to_class} gives and for the same
        # reason: keeping the old bound licenses `call.undefined-method` on the guard-proven branch. Keeping
        # the literal was tried first and did exactly that — `s = "str"` under `when Unrelated` stayed
        # `Constant["str"]` and reported `undefined method 'other'`, trading one false positive for
        # another. The value is lost only on the guarded arm, which is where the guard just told us the
        # environment's picture was incomplete.
        def narrow_constant_to_class(constant, class_name, context)
          rigor_class = constant.value.class.name
          return constant if subclass_of?(rigor_class, class_name, context)
          return Type::Combinator.untyped if declines_bot?(rigor_class, class_name, context)

          Type::Combinator.bot
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
        #
        # A disjoint `Bot` narrows the edge but is not always a verdict that the code is dead: see
        # {.disjoint_nominal_guard?} (issue #1429).
        def narrow_nominal_to_class(nominal, class_name, context)
          return nominal if nominal.class_name == class_name
          return exact_nominal_to_class(nominal, class_name, context) if context.exact

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

        # `instance_of?(class_name)` compares the exact class, so its truthy edge holds `class_name` itself. Issue
        # #1429: when `class_name` is a class below the nominal's (`Numeric` under `instance_of?(Integer)`), that is
        # the edge's type; the edge was `Bot` before, for every class but the nominal's own. A module is never an
        # object's class, and any other ordering leaves no class the object can have, so those stay `Bot`.
        def exact_nominal_to_class(nominal, class_name, context)
          return Type::Combinator.bot if context.environment.rbs_module?(class_name)
          return Type::Combinator.bot unless class_ordering(nominal.class_name, class_name, context) == :superclass

          Type::Combinator.nominal_of(class_name)
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

        # A shape projects to `Array` / `Hash`, and reopening either of those to include a project module
        # leaves the ordering `:unknown` for the same reason #657's `Integer` does — so `[1, 2]` under `when
        # Taggable` reached the same unsupported `Bot`. The carrier differs; the missing evidence does not.
        def narrow_shape_to_class(shape, projected_class, class_name, context)
          return shape if subclass_of?(projected_class, class_name, context)
          return Type::Combinator.untyped if declines_bot?(projected_class, class_name, context)

          Type::Combinator.bot
        end

        def narrow_shape_not_class(shape, projected_class, class_name, context)
          subclass_of?(projected_class, class_name, context) ? Type::Combinator.bot : shape
        end

        # `Singleton[Foo]` is the *class object* `Foo`, an instance of `Class` (which is a
        # subclass of `Module`). Asking `Foo.is_a?(Class)` returns true; `Foo.is_a?(Foo)`
        # returns false unless `Foo` is `Class` itself. We approximate this by treating
        # singletons uniformly as `Class` instances.
        #
        # The approximation answers through `Class`, so a target `Class` cannot be ordered against — a
        # project module, typically — lands on the same `:unknown` #657 collapsed to `Bot`, and `case Widget
        # when Meta` was reported unreachable where `Widget` had `extend Meta`.
        #
        # Issue #898 — that decline is silent about a target the environment DOES order against `Class`, and
        # `extend Comparable` is one: both names are in RBS, neither includes the other, so the ordering says
        # `:disjoint` and the collapse fired on an arm MRI takes (`Widget.is_a?(Comparable)` is true — the
        # `extend` put `Comparable` in `Widget`'s SINGLETON ancestry, which asking about `Class` cannot see).
        # {#singleton_extend_declines_bot?} supplies the missing half from the project's own `extend` record.
        def narrow_singleton_to_class(singleton, class_name, context)
          return singleton if subclass_of?("Class", class_name, context)
          return Type::Combinator.untyped if declines_bot?("Class", class_name, context)
          return Type::Combinator.untyped if singleton_extend_declines_bot?(singleton, class_name, context)

          Type::Combinator.bot
        end

        # Whether the class object's own `extend` record forbids the `Bot` the `Class` approximation would
        # otherwise authorise (#898). An extended `M` puts every ancestor of `M` in the singleton's
        # ancestry, so the question per extended module is `M <= target`: `:equal` (`extend Comparable`
        # under `when Comparable`) and `:subclass` support the arm, and `:unknown` (`extend Meta` under
        # `when Comparable`, `Meta` being project source the environment never joined to RBS) cannot rule
        # it out. `:superclass` and `:disjoint` support NOTHING and must keep the collapse — `Integer`
        # under `when Integer` orders `:superclass` against an extended `Comparable`, and reading that as
        # support would retract `case Widget when Integer` from every class that extends a core module.
        #
        # The answer is `Dynamic[top]`, never the preserved `Singleton[C]`, and the negative edge
        # ({#narrow_singleton_not_class}) is untouched — so this record is read ONLY to withhold a claim,
        # never to make one. That asymmetry is deliberate, and it is what keeps the fix honest against an
        # extend record that is structurally incomplete: `Widget.extend(m)` at a call site and an `extend`
        # written in a file outside the analysed set are both invisible to the walk behind
        # {Scope#singleton_extends_of}, and the declaration-side record joined to it below is no more
        # complete — RBS says nothing about a class it does not declare. A shape that turned this table
        # into a positive `:subclass` verdict would have to be right about ABSENCE too, and it cannot be. Preserving
        # `Singleton[C]` would also hand the arm a receiver whose singleton method table has no `clamp` on
        # it, trading the unreachable-clause false positive for an undefined-method one — the same trap
        # #657 recorded on the `Constant` carrier.
        #
        # Issue #915 — two sources, read as one. The source record above sees only what Ruby source spells;
        # a project that declares `extend M` in its own `sig/` puts the same module in the same singleton
        # ancestry, and the environment's declaration-side answer
        # ({Environment#singleton_extended_modules}) is consulted alongside it. Neither is asked to be
        # complete; each can only add a module that IS there, which is all the one-directional read needs.
        def singleton_extend_declines_bot?(singleton, class_name, context)
          return false if context.exact

          extended = singleton_ancestor_modules(singleton, context)
          return false if extended.empty?

          extended.any? do |module_name|
            %i[equal subclass unknown].include?(class_ordering(module_name, class_name, context))
          end
        end

        def singleton_ancestor_modules(singleton, context)
          scope = context.scope
          from_source = scope.nil? ? [] : scope.singleton_extends_of(singleton.class_name)
          from_rbs = context.environment&.singleton_extended_modules(singleton.class_name) || []
          return from_source if from_rbs.empty?
          return from_rbs if from_source.empty?

          from_source | from_rbs
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

        # Whether the positive edge must decline the `Bot` that `subclass_of?` returning false would
        # otherwise authorise (#657). `subclass_of?` folds `:disjoint` and `:unknown` into one `false`, and
        # only the first is evidence that the guard can never match; the second is the environment saying it
        # cannot tell, which any file reopening either side can make true.
        #
        # This only ever ADDS a decline: every caller keeps its own `subclass_of?` test first, so the
        # preserving edge is untouched, and a `:disjoint`, `:equal`, `:subclass` or `:superclass` verdict
        # never reaches here. There is no ordering it turns INTO a match — the honest answer for
        # "cannot tell" is Dynamic, never the asked class.
        #
        # `instance_of?` is exempt because it compares the exact class: a module is never an object's class,
        # so that edge's `Bot` rests on the guard's own semantics rather than on the ordering.
        def declines_bot?(rigor_class_name, target_class_name, context)
          !context.exact && class_ordering(rigor_class_name, target_class_name, context) == :unknown
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

        private_class_method :narrow_constant_class, :narrow_nominal_class, :narrow_union_class, :narrow_shape_class,
                             :narrow_singleton_class, :narrow_other_class, :narrow_constant_to_class,
                             :narrow_constant_not_class, :narrow_nominal_to_class, :exact_nominal_to_class,
                             :narrow_nominal_not_class, :narrow_shape_to_class, :narrow_shape_not_class,
                             :narrow_singleton_to_class, :singleton_extend_declines_bot?, :singleton_ancestor_modules,
                             :narrow_singleton_not_class, :narrow_class_other, :declines_bot?, :subclass_of?,
                             :class_ordering
      end
    end
  end
end
