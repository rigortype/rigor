# frozen_string_literal: true

require "rbs"

require_relative "../type"

module Rigor
  module Inference
    # Translates `RBS::Types::*` instances into `Rigor::Type` values.
    #
    # The translator is intentionally conservative for Slice 4: generics
    # are erased, type variables degrade to Dynamic[Top], and
    # interface/intersection types are not modelled. The mapping is
    # documented in docs/internal-spec/inference-engine.md so callers
    # can rely on the boundaries even before the deeper generics work
    # in Slice 5+.
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
        RBS::Types::Tuple => :translate_array_nominal,
        RBS::Types::Record => :translate_hash_nominal,
        RBS::Types::Proc => :translate_proc_nominal,
        RBS::Types::ClassSingleton => :translate_class_singleton,
        RBS::Types::Alias => :translate_untyped,
        RBS::Types::Intersection => :translate_untyped,
        RBS::Types::Variable => :translate_untyped,
        RBS::Types::Interface => :translate_untyped
      }.freeze
      private_constant :TRANSLATORS

      class << self
        # @param rbs_type [RBS::Types::Bases::Base, RBS::Types::ClassInstance, ...]
        # @param self_type [Rigor::Type, nil] substitute for `Bases::Self`.
        # @param instance_type [Rigor::Type, nil] substitute for
        #   `Bases::Instance`. Defaults to `nil`, which degrades to
        #   Dynamic[Top].
        # @return [Rigor::Type]
        def translate(rbs_type, self_type: nil, instance_type: nil)
          handler = TRANSLATORS[rbs_type.class]
          return send(handler, rbs_type, self_type, instance_type) if handler

          Type::Combinator.untyped
        end

        private

        def translate_top(_rbs_type, _self_type, _instance_type)
          Type::Combinator.top
        end

        def translate_bot(_rbs_type, _self_type, _instance_type)
          Type::Combinator.bot
        end

        def translate_untyped(_rbs_type, _self_type, _instance_type)
          Type::Combinator.untyped
        end

        def translate_nil(_rbs_type, _self_type, _instance_type)
          Type::Combinator.constant_of(nil)
        end

        # `bool` in RBS denotes `true | false`. We fold it to that union
        # eagerly so downstream comparisons (e.g., `result == Constant[true]`)
        # remain structural. Memoized at the module level because the
        # union is value-equal across calls.
        def translate_bool(_rbs_type, _self_type, _instance_type)
          BOOL_UNION
        end

        BOOL_UNION = Type::Combinator.union(
          Type::Combinator.constant_of(true),
          Type::Combinator.constant_of(false)
        ).freeze
        private_constant :BOOL_UNION

        def translate_self(_rbs_type, self_type, _instance_type)
          self_type || Type::Combinator.untyped
        end

        def translate_instance(_rbs_type, _self_type, instance_type)
          instance_type || Type::Combinator.untyped
        end

        def translate_optional(rbs_type, self_type, instance_type)
          inner = translate(rbs_type.type, self_type: self_type, instance_type: instance_type)
          Type::Combinator.union(inner, Type::Combinator.constant_of(nil))
        end

        def translate_union(rbs_type, self_type, instance_type)
          members = rbs_type.types.map do |t|
            translate(t, self_type: self_type, instance_type: instance_type)
          end
          Type::Combinator.union(*members)
        end

        def translate_literal(rbs_type, _self_type, _instance_type)
          Type::Combinator.constant_of(rbs_type.literal)
        end

        def translate_class_instance(rbs_type, _self_type, _instance_type)
          name = rbs_type.name.relative!.to_s
          # Slice 4 phase 1 drops the type arguments; we do not model
          # generic Nominals yet (e.g., `Array[Integer]` becomes
          # `Array`). Slice 5 will plumb args through the type model.
          Type::Combinator.nominal_of(name)
        end

        def translate_array_nominal(_rbs_type, _self_type, _instance_type)
          # Slice 4 phase 1 erases tuple shape to `Array`. Tuple
          # precision lands in Slice 5 alongside the dedicated
          # Tuple/HashShape carriers from ADR-3.
          Type::Combinator.nominal_of(Array)
        end

        def translate_hash_nominal(_rbs_type, _self_type, _instance_type)
          Type::Combinator.nominal_of(Hash)
        end

        def translate_proc_nominal(_rbs_type, _self_type, _instance_type)
          Type::Combinator.nominal_of(Proc)
        end

        # `singleton(Foo)` is the type of the constant `Foo` itself
        # (the class object). With the dedicated Singleton type added in
        # Slice 4 phase 2b, we map directly to `Singleton[Foo]`.
        def translate_class_singleton(rbs_type, _self_type, _instance_type)
          name = rbs_type.name.relative!.to_s
          Type::Combinator.singleton_of(name)
        end
      end
    end
  end
end
