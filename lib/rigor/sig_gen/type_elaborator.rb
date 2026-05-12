# frozen_string_literal: true

require_relative "../reflection"
require_relative "../type"

module Rigor
  module SigGen
    # ADR-14 follow-up to the dogfood findings: when the
    # inference engine produces a `Type::Nominal` for a class
    # that requires type parameters (`Array`, `Hash`, `Set`,
    # `Range`, `Enumerable`, `Enumerator`, ...) with an empty
    # `type_args` array, the carrier is structurally valid but
    # `erase_to_rbs` renders just `Array` / `Hash` / etc. While
    # RBS itself accepts the bare form, downstream consumers
    # (Steep, IDE plugins, gem-published `sig/` trees) expect
    # the elaborated `Array[untyped]` / `Hash[untyped, untyped]`
    # spelling.
    #
    # This module walks a `Rigor::Type` tree and rebuilds every
    # raw `Nominal[C]` for a generic `C` into `Nominal[C, [Dynamic, ...]]`
    # where the arity comes from
    # `Reflection.class_type_param_names`. The transformation is
    # purely cosmetic — the resulting carrier is structurally
    # distinct from the raw form, but `accepts(other) == accepts(other)`
    # holds because the gradual mode treats `Dynamic[top]`
    # arguments as covering anything.
    #
    # The module is sig-gen-local; the broader question of
    # whether the inference engine itself should always
    # construct generics with explicit type_args is queued as
    # an ADR-14 follow-up.
    module TypeElaborator
      # @param type [Rigor::Type]
      # @param environment [Rigor::Environment]
      # @return [Rigor::Type] same shape with bare generic
      #   nominals filled in.
      def self.elaborate(type, environment:)
        arity_cache = {}
        walk(type, environment, arity_cache)
      end

      def self.walk(type, environment, arity_cache)
        case type
        when Type::Nominal then elaborate_nominal(type, environment, arity_cache)
        when Type::Union   then elaborate_union(type, environment, arity_cache)
        when Type::Tuple   then elaborate_tuple(type, environment, arity_cache)
        when Type::HashShape then elaborate_hash_shape(type, environment, arity_cache)
        else type
        end
      end

      def self.elaborate_nominal(type, environment, arity_cache)
        elaborated_args = type.type_args.map { |arg| walk(arg, environment, arity_cache) }
        return Type::Combinator.nominal_of(type.class_name, type_args: elaborated_args) if elaborated_args.any?

        arity = generic_arity_for(type.class_name, environment, arity_cache)
        return type if arity.zero?

        filled = Array.new(arity) { Type::Combinator.untyped }
        Type::Combinator.nominal_of(type.class_name, type_args: filled)
      end

      def self.elaborate_union(type, environment, arity_cache)
        Type::Combinator.union(*type.members.map { |m| walk(m, environment, arity_cache) })
      end

      def self.elaborate_tuple(type, environment, arity_cache)
        elements = type.elements.map { |e| walk(e, environment, arity_cache) }
        Type::Tuple.new(elements)
      end

      def self.elaborate_hash_shape(type, _environment, _arity_cache)
        # HashShape's element types are read-only on the carrier;
        # rebuilding them would need going through the per-pair
        # required/optional/read-only machinery. Sig-gen only
        # routes top-level returns through here for now —
        # nested HashShape elaboration ships as a follow-up if
        # the need surfaces.
        type
      end

      def self.generic_arity_for(class_name, environment, cache)
        return cache[class_name] if cache.key?(class_name)

        names = Reflection.class_type_param_names(class_name, environment: environment)
        cache[class_name] = names.size
      rescue StandardError
        cache[class_name] = 0
      end
    end
  end
end
