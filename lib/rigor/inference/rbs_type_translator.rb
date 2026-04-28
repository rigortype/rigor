# frozen_string_literal: true

require "rbs"

require_relative "../type"

module Rigor
  module Inference
    # Translates `RBS::Types::*` instances into `Rigor::Type` values.
    #
    # Slice 4 phase 2d adds two pieces of generic plumbing:
    # - `RBS::Types::ClassInstance` arguments are translated recursively
    #   so `Array[Integer]` becomes `Nominal["Array", [Nominal["Integer"]]]`
    #   (and `Hash[Symbol, Integer]` becomes `Nominal["Hash", [...]]`).
    # - `RBS::Types::Variable` consults a caller-supplied substitution
    #   map (`type_vars:`) keyed by the variable's RBS name. When the
    #   variable is bound, the bound `Rigor::Type` is returned unchanged;
    #   when it is not bound, the variable degrades to `Dynamic[Top]` so
    #   uninstantiated generics keep their fail-soft behavior.
    #
    # Slice 5 phase 1 maps tuples and records to their dedicated shape
    # carriers:
    # - `RBS::Types::Tuple` becomes `Rigor::Type::Tuple[...]` so the
    #   arity and per-position element types survive the boundary.
    # - `RBS::Types::Record` becomes `Rigor::Type::HashShape{...}`,
    #   carrying the (Symbol -> Type) map intact.
    # Element and value types are translated recursively under the
    # caller's `self_type` / `instance_type` / `type_vars` context.
    #
    # Interface and intersection types still degrade to `Dynamic[Top]`;
    # they are bound to acceptance and dispatch rules that Slice 5+
    # will replace.
    #
    # The optional `self_type:` and `instance_type:` arguments are the
    # Rigor counterparts of RBS's `self` and `instance` tokens:
    # - `self_type` substitutes for `Bases::Self`. Inside an instance
    #   method body it is `Nominal[C]`; inside a singleton method body
    #   it is `Singleton[C]`.
    # - `instance_type` substitutes for `Bases::Instance` and is always
    #   `Nominal[C]` regardless of which method body we are in.
    # When either argument is omitted, the corresponding token degrades
    # to Dynamic[Top].
    # rubocop:disable Metrics/ModuleLength
    module RbsTypeTranslator
      # Hash-based dispatch keeps `translate` linear and dodges the
      # bookkeeping costs of a 20-arm `case` (RuboCop AbcSize/CCN/Length
      # all spike on that shape). Anonymous RBS-type subclasses are not
      # expected; the table only maps the concrete leaf classes shipped
      # by the `rbs` gem.
      TRANSLATORS = {
        RBS::Types::Bases::Top => :translate_top,
        RBS::Types::Bases::Bottom => :translate_bot,
        RBS::Types::Bases::Any => :translate_untyped,
        RBS::Types::Bases::Nil => :translate_nil,
        RBS::Types::Bases::Bool => :translate_bool,
        RBS::Types::Bases::Self => :translate_self,
        RBS::Types::Bases::Instance => :translate_instance,
        RBS::Types::Bases::Class => :translate_untyped,
        RBS::Types::Bases::Void => :translate_untyped,
        RBS::Types::Optional => :translate_optional,
        RBS::Types::Union => :translate_union,
        RBS::Types::Literal => :translate_literal,
        RBS::Types::ClassInstance => :translate_class_instance,
        RBS::Types::Tuple => :translate_tuple,
        RBS::Types::Record => :translate_record,
        RBS::Types::Proc => :translate_proc_nominal,
        RBS::Types::ClassSingleton => :translate_class_singleton,
        RBS::Types::Alias => :translate_untyped,
        RBS::Types::Intersection => :translate_untyped,
        RBS::Types::Variable => :translate_variable,
        RBS::Types::Interface => :translate_untyped
      }.freeze
      private_constant :TRANSLATORS

      EMPTY_TYPE_VARS = {}.freeze
      private_constant :EMPTY_TYPE_VARS

      class << self
        # @param rbs_type [RBS::Types::Bases::Base, RBS::Types::ClassInstance, ...]
        # @param self_type [Rigor::Type, nil] substitute for `Bases::Self`.
        # @param instance_type [Rigor::Type, nil] substitute for
        #   `Bases::Instance`. Defaults to `nil`, which degrades to
        #   Dynamic[Top].
        # @param type_vars [Hash{Symbol => Rigor::Type}] substitution map
        #   for `Bases::Variable`. Keys are the RBS variable names (e.g.,
        #   `:Elem`); values are Rigor types that replace the variable.
        #   Variables that are not bound in the map degrade to Dynamic[Top].
        # @return [Rigor::Type]
        def translate(rbs_type, self_type: nil, instance_type: nil, type_vars: EMPTY_TYPE_VARS)
          handler = TRANSLATORS[rbs_type.class]
          return send(handler, rbs_type, self_type, instance_type, type_vars) if handler

          Type::Combinator.untyped
        end

        private

        def translate_top(_rbs_type, _self_type, _instance_type, _type_vars)
          Type::Combinator.top
        end

        def translate_bot(_rbs_type, _self_type, _instance_type, _type_vars)
          Type::Combinator.bot
        end

        def translate_untyped(_rbs_type, _self_type, _instance_type, _type_vars)
          Type::Combinator.untyped
        end

        def translate_nil(_rbs_type, _self_type, _instance_type, _type_vars)
          Type::Combinator.constant_of(nil)
        end

        # `bool` in RBS denotes `true | false`. We fold it to that union
        # eagerly so downstream comparisons (e.g., `result == Constant[true]`)
        # remain structural. Memoized at the module level because the
        # union is value-equal across calls.
        def translate_bool(_rbs_type, _self_type, _instance_type, _type_vars)
          BOOL_UNION
        end

        BOOL_UNION = Type::Combinator.union(
          Type::Combinator.constant_of(true),
          Type::Combinator.constant_of(false)
        ).freeze
        private_constant :BOOL_UNION

        def translate_self(_rbs_type, self_type, _instance_type, _type_vars)
          self_type || Type::Combinator.untyped
        end

        def translate_instance(_rbs_type, _self_type, instance_type, _type_vars)
          instance_type || Type::Combinator.untyped
        end

        def translate_optional(rbs_type, self_type, instance_type, type_vars)
          inner = translate(rbs_type.type, self_type: self_type, instance_type: instance_type, type_vars: type_vars)
          Type::Combinator.union(inner, Type::Combinator.constant_of(nil))
        end

        def translate_union(rbs_type, self_type, instance_type, type_vars)
          members = rbs_type.types.map do |t|
            translate(t, self_type: self_type, instance_type: instance_type, type_vars: type_vars)
          end
          Type::Combinator.union(*members)
        end

        def translate_literal(rbs_type, _self_type, _instance_type, _type_vars)
          Type::Combinator.constant_of(rbs_type.literal)
        end

        # Slice 4 phase 2d translates the type arguments recursively so
        # `Array[Integer]` round-trips into `Nominal["Array", [Nominal["Integer"]]]`.
        # Variables inside the args participate in substitution through
        # the same `type_vars:` map.
        def translate_class_instance(rbs_type, self_type, instance_type, type_vars)
          name = rbs_type.name.relative!.to_s
          translated_args = rbs_type.args.map do |arg|
            translate(arg, self_type: self_type, instance_type: instance_type, type_vars: type_vars)
          end
          Type::Combinator.nominal_of(name, type_args: translated_args)
        end

        # Slice 5 phase 1: preserve tuple precision through the
        # boundary. Each positional element type is translated
        # recursively under the caller's substitution context, and the
        # resulting list is wrapped in a `Rigor::Type::Tuple`.
        def translate_tuple(rbs_type, self_type, instance_type, type_vars)
          elements = rbs_type.types.map do |t|
            translate(t, self_type: self_type, instance_type: instance_type, type_vars: type_vars)
          end
          Type::Combinator.tuple_of(*elements)
        end

        # Slice 5 phase 1: preserve hash-record precision through the
        # boundary. RBS records use Symbol keys; the translator keeps
        # them as Symbol keys on the resulting HashShape so erasure can
        # round-trip back to `{ a: T }` syntax.
        def translate_record(rbs_type, self_type, instance_type, type_vars)
          pairs = rbs_type.fields.each_with_object({}) do |(key, value), acc|
            acc[key] = translate(value, self_type: self_type, instance_type: instance_type, type_vars: type_vars)
          end
          Type::Combinator.hash_shape_of(pairs)
        end

        def translate_proc_nominal(_rbs_type, _self_type, _instance_type, _type_vars)
          Type::Combinator.nominal_of(Proc)
        end

        # `singleton(Foo)` is the type of the constant `Foo` itself
        # (the class object). With the dedicated Singleton type added in
        # Slice 4 phase 2b, we map directly to `Singleton[Foo]`.
        def translate_class_singleton(rbs_type, _self_type, _instance_type, _type_vars)
          name = rbs_type.name.relative!.to_s
          Type::Combinator.singleton_of(name)
        end

        # Slice 4 phase 2d. Looks up the variable's RBS name in the
        # substitution map; bound variables are replaced inline, free
        # variables degrade to Dynamic[Top]. We use `fetch` with a
        # default rather than `[]` so a deliberate `nil` binding (a
        # caller mistake) is never silently consumed.
        def translate_variable(rbs_type, _self_type, _instance_type, type_vars)
          type_vars.fetch(rbs_type.name) { Type::Combinator.untyped }
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
