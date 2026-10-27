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
      # It declines (`nil`, the RBS row answers) for a receiver member that is neither a `Hash[K, V]` nor `nil`,
      # and it answers `Dynamic[top]` for a key member it cannot decide, so the result is never more precise than
      # what is known.
      module SymbolizeKeys
        HASH = "Hash"
        SYMBOLIZED_CLASSES = %w[String Symbol].freeze

        module_function

        # Answers `Hash[K', V]` (or the union of such, with `nil` kept for a `&.` receiver), or nil to decline.
        def result(receiver_type, scope)
          members = receiver_type.is_a?(Rigor::Type::Union) ? receiver_type.members : [receiver_type]
          answers = members.map { |member| member_answer(member, scope) }
          return nil if answers.any?(:decline) || answers.all?(:nil)

          nil_type = Rigor::Type::Combinator.constant_of(nil)
          Rigor::Type::Combinator.union(*answers.map { |answer| answer == :nil ? nil_type : answer })
        end

        def member_answer(member, scope)
          return :nil if nil_member?(member)

          key_type, value_type = hash_arguments(member)
          return :decline if key_type.nil?

          Rigor::Type::Combinator.nominal_of(HASH, type_args: [map_key(key_type, scope), value_type])
        end

        def nil_member?(type)
          (type.is_a?(Rigor::Type::Constant) && type.value.nil?) ||
            (type.is_a?(Rigor::Type::Nominal) && type.class_name == "NilClass")
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
            return symbol if member.value.is_a?(String) || member.value.is_a?(Symbol)

            kept_class?(member.value.class.name, scope) ? member : Rigor::Type::Combinator.untyped
          when Rigor::Type::IntegerRange then kept_class?("Integer", scope) ? member : Rigor::Type::Combinator.untyped
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

        # The core value classes that cannot meaningfully be subclassed, each with the chain a `to_sym` could
        # be defined on. Any other class, a project subclass or a delegator included, may answer `to_sym`.
        KEPT_CLASS_CHAINS = {
          "Integer" => %w[Integer Numeric Comparable Object Kernel BasicObject],
          "Float" => %w[Float Numeric Comparable Object Kernel BasicObject],
          "Rational" => %w[Rational Numeric Comparable Object Kernel BasicObject],
          "Complex" => %w[Complex Numeric Comparable Object Kernel BasicObject],
          "NilClass" => %w[NilClass Object Kernel BasicObject],
          "TrueClass" => %w[TrueClass Object Kernel BasicObject],
          "FalseClass" => %w[FalseClass Object Kernel BasicObject]
        }.transform_values(&:freeze).freeze

        # True for one of {KEPT_CLASS_CHAINS} when the project defines no `to_sym` on it or an ancestor.
        # `discovered_method?` also records the negative dependency, so adding such a `def` invalidates.
        def kept_class?(name, scope)
          chain = KEPT_CLASS_CHAINS[name]
          return false if chain.nil? || scope.nil?

          chain.none? { |owner| Rigor::Reflection.discovered_method?(owner, :to_sym, scope: scope) }
        end

        def ordering(name, base, scope)
          Rigor::Reflection.class_ordering(name, base, scope: scope)
        end
      end
    end
  end
end
