# frozen_string_literal: true

require "rigor/type"

module Rigor
  module Plugin
    class ActivesupportCoreExt < Rigor::Plugin::Base
      # #2433 — the result type of `Hash#symbolize_keys` / `#to_options`.
      #
      # ActiveSupport implements them as `transform_keys { |key| key.to_sym rescue key }`, so a String or
      # Symbol key becomes a Symbol and a key without `to_sym` (an Integer, a Float) survives unchanged. One
      # RBS return type cannot say that: `Hash[Symbol, V]` reads an Integer key as a Symbol, and
      # `Hash[Symbol | K, V]` makes a String-keyed hash fail a declared `Hash[Symbol, untyped]` parameter.
      # So the RBS rows answer `Hash[untyped, V]` and this module maps each key member where it can.
      #
      # It declines (`nil`, the RBS row answers) for a receiver it cannot read as a `Hash[K, V]`, and it
      # answers `Dynamic[top]` for a key member it cannot decide, so the result is never more precise than
      # what is known.
      module SymbolizeKeys
        HASH = "Hash"
        SYMBOLIZED_CLASSES = %w[String Symbol].freeze

        module_function

        # Answers `Hash[K', V]`, or nil to decline.
        def result(receiver_type, scope)
          key_type, value_type = hash_arguments(receiver_type)
          return nil if key_type.nil?

          Rigor::Type::Combinator.nominal_of(
            HASH, type_args: [map_key(key_type, scope), value_type]
          )
        end

        def hash_arguments(type)
          case type
          when Rigor::Type::Nominal
            type.class_name == HASH && type.type_args.size == 2 ? type.type_args : nil
          when Rigor::Type::Difference
            hash_arguments(type.base)
          when Rigor::Type::HashShape
            shape_arguments(type)
          end
        end

        # A closed, non-empty shape reads as `Hash[<its keys>, <union of its values>]`.
        def shape_arguments(shape)
          return nil if shape.open? || shape.pairs.empty?

          keys = shape.pairs.keys.map { |key| Rigor::Type::Combinator.constant_of(key) }
          [Rigor::Type::Combinator.union(*keys), Rigor::Type::Combinator.union(*shape.pairs.values)]
        end

        def map_key(type, scope)
          members = type.is_a?(Rigor::Type::Union) ? type.members : [type]
          Rigor::Type::Combinator.union(*members.map { |member| map_member(member, scope) })
        end

        def map_member(member, scope)
          case member
          when Rigor::Type::Constant
            if member.value.is_a?(String) || member.value.is_a?(Symbol)
              symbol
            else
              kept_class?(member.value.class.name, scope) ? member : Rigor::Type::Combinator.untyped
            end
          when Rigor::Type::IntegerRange then member
          when Rigor::Type::Nominal then map_nominal(member, scope)
          else Rigor::Type::Combinator.untyped
          end
        end

        def map_nominal(nominal, scope)
          name = nominal.class_name
          return symbol if symbolized_class?(name, scope)

          kept_class?(name, scope) ? nominal : Rigor::Type::Combinator.untyped
        end

        def symbol
          Rigor::Type::Combinator.nominal_of("Symbol")
        end

        # String, Symbol and their subclasses go through `to_sym`.
        def symbolized_class?(name, scope)
          SYMBOLIZED_CLASSES.include?(name) ||
            SYMBOLIZED_CLASSES.any? { |base| %i[equal subclass].include?(ordering(name, base, scope)) }
        end

        # True for a bundled RBS class that is provably unrelated to String and Symbol (so no subclass
        # can be one) and declares no `to_sym`. `Object` is a superclass of String, so it is not kept; a
        # project-declared class is not kept either, since its own `to_sym` may be metaprogrammed.
        def kept_class?(name, scope)
          return false if name.nil? || scope.nil?
          return false unless Rigor::Reflection.rbs_class_known?(name, scope: scope)
          return false if Rigor::Reflection.project_declared_class?(name, scope: scope)
          return false unless SYMBOLIZED_CLASSES.all? { |base| ordering(name, base, scope) == :disjoint }

          Rigor::Reflection.instance_method_definition(name, :to_sym, scope: scope).nil?
        end

        def ordering(name, base, scope)
          Rigor::Reflection.class_ordering(name, base, scope: scope)
        end
      end
    end
  end
end
