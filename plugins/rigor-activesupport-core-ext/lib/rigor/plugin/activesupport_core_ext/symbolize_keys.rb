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
      # A key that is not a String or Symbol (an Integer, a project class) reads `Dynamic[top]`: no Rigor fact proves
      # a class has no `to_sym` (a mixin, a `pre_eval` file or a reopening can add one), so a kept key could claim
      # a type the program does not have. It declines (`nil`, the RBS row answers) when a receiver member is
      # neither a `Hash[K, V]` nor `nil`. A `nil` member is dropped: `nil.symbolize_keys` raises, and the engine
      # adds `nil` back for `&.`.
      module SymbolizeKeys
        HASH = "Hash"
        SYMBOLIZED_CLASSES = %w[String Symbol].freeze

        module_function

        # Answers `Hash[K', V]` (the union of such over the receiver's Hash members), or nil to decline.
        def result(receiver_type, scope)
          members = receiver_type.is_a?(Rigor::Type::Union) ? receiver_type.members : [receiver_type]
          answers = members.reject { |member| nil_member?(member) }.map { |member| member_answer(member, scope) }
          return nil if answers.empty? || answers.any?(:decline)

          hashes = answers.reject { |answer| answer == :empty }
          hashes.empty? ? nil : Rigor::Type::Combinator.union(*hashes)
        end

        # An empty closed shape is `{}`: it adds no key, so it drops out of the union rather than declining it.
        def member_answer(member, scope)
          return :empty if member.is_a?(Rigor::Type::HashShape) && member.closed? && member.pairs.empty?

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
            member.value.is_a?(String) || member.value.is_a?(Symbol) ? symbol : Rigor::Type::Combinator.untyped
          when Rigor::Type::Nominal
            symbolized_class?(member.class_name, scope) ? symbol : Rigor::Type::Combinator.untyped
          else Rigor::Type::Combinator.untyped
          end
        end

        def symbol
          Rigor::Type::Combinator.nominal_of("Symbol")
        end

        # String, Symbol and their subclasses go through `to_sym`.
        def symbolized_class?(name, scope)
          SYMBOLIZED_CLASSES.include?(name) ||
            SYMBOLIZED_CLASSES.any? { |base| %i[equal subclass].include?(ordering(name, base, scope)) }
        end

        def ordering(name, base, scope)
          Rigor::Reflection.class_ordering(name, base, scope: scope)
        end
      end
    end
  end
end
