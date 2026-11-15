# frozen_string_literal: true

require "prism"
require_relative "../../type"

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #3243 — the element half of the #540 mutation census. `S = [+"a"].freeze` with a method running
      # `S[0] << "b"` mutates the String the constant's `Tuple` holds, not the constant: the receiver of `<<` is the
      # element read `S[0]`, so the census recorded no name and `S[0] == "a"` folded always-truthy on a program that
      # stores `"ab"` there. The census now records such a mutation as the root's name plus the steps of the read
      # chain, and widens only the element those steps reach, so the outer `Tuple`'s arity and its untouched sibling
      # slots keep their pins.
      #
      # {.path} reads the chain and decides nothing about what its root is; `record_literal_receiver_mutation`
      # decides which roots (a constant, a class variable) the census tracks.
      module MutatedElementCensus
        # The calls that read ONE element of a container, with the argument counts that make them one. `first` /
        # `last` take none here (with one they return a sub-array), `[]` / `at` one, `fetch` one or two (the second
        # is a default), `dig` at least one.
        READERS = { "[]": 1..1, first: 0..0, last: 0..0, dig: 1.., at: 1..1, fetch: 1..2 }.freeze

        # A literal Symbol or String key, which names one value of a `HashShape`. On a `Tuple` it names no position,
        # so every position widens, as a step that is not statically known does.
        KeyStep = Data.define(:key)

        # Values an element may hold whose `<<` / `[]=` / … is not an in-place mutation of the value (`Integer#<<`
        # shifts, a `nil` element raises): widening them would only discard a correct pin.
        IMMUTABLE_CLASSES = %w[Integer Float Rational Complex Symbol TrueClass FalseClass NilClass Range].to_set.freeze
        private_constant :IMMUTABLE_CLASSES

        module_function

        # `[root, steps]` for a chain of element reads, or `nil` when `node` is not one. A step is an Integer index
        # (negative counts from the end), `:first`, `:last`, a {KeyStep}, or `:all` for an index that is not a
        # literal. `:first` / `:last` stay distinct from `0` / `-1` because a `HashShape` answers them differently.
        def path(node)
          cursor = unparenthesized(node)
          return nil unless cursor.is_a?(Prism::CallNode) && READERS.key?(cursor.name)

          steps = []
          while cursor.is_a?(Prism::CallNode)
            call_steps = call_steps(cursor)
            return nil if call_steps.nil?

            steps.unshift(*call_steps)
            cursor = unparenthesized(cursor.receiver)
          end
          [cursor, steps.freeze]
        end

        def unparenthesized(node)
          while node.is_a?(Prism::ParenthesesNode)
            body = node.body
            return node unless body.is_a?(Prism::StatementsNode) && body.body.size == 1

            node = body.body.first
          end
          node
        end

        NO_ARGUMENTS = [].freeze
        private_constant :NO_ARGUMENTS

        # A block is not looked at: the containers the census tracks are core `Array` / `Hash` values, whose readers
        # ignore one or, as `fetch`'s does, answer a default only where no element exists. A splatted argument reads
        # as a step that is not a literal, which can only widen more.
        def call_steps(call)
          arity = READERS[call.name]
          return nil if arity.nil? || call.receiver.nil?

          args = call.arguments&.arguments || NO_ARGUMENTS
          return nil unless arity.cover?(args.size)

          case call.name
          when :first, :last then [call.name]
          when :dig then args.map { |arg| step_of(arg) }
          else [step_of(args.first)]
          end
        end

        def step_of(node)
          case node
          when Prism::IntegerNode then node.value
          when Prism::SymbolNode then KeyStep.new(node.unescaped.to_sym)
          when Prism::StringNode then KeyStep.new(node.unescaped)
          else :all
          end
        end

        # Every recorded `[name, steps]` pair, shallowest first (ties keep their recording order), so the widened
        # table does not depend on the order the mutations appear in.
        def ordered(paths)
          paths.each_with_index.sort_by { |(pair, index)| [pair[1].size, index] }.map(&:first)
        end

        # `type` with the element `steps` reach widened as the census widens a mutated constant, or `nil` when the
        # steps reach nothing widenable.
        def widen(type, steps)
          return leaf(type) if steps.empty?

          case type
          when Type::Tuple then widen_tuple(type, steps)
          when Type::HashShape then widen_hash_shape(type, steps)
          when Type::Union then widen_members(type.members, steps)
          when Type::Dynamic
            inner = widen(type.static_facet, steps)
            inner && Type::Combinator.dynamic(inner)
          when Type::Difference
            inner = widen(type.base, steps)
            inner && Type::Combinator.difference(inner, type.removed)
          # A nominal names no position, so whichever element was mutated, every one of them stops being pinned.
          when Type::Nominal then changed(type, ScopeIndexer.census_unpinned_content(type))
          end
        end

        def leaf(type)
          return nil unless mutable?(type)

          changed(type, ScopeIndexer.census_mutated_type(type))
        end

        def changed(before, after) = after == before ? nil : after

        def mutable?(type)
          case type
          when Type::Constant then StringMutation.constant?(type)
          when Type::Tuple, Type::HashShape, Type::Dynamic, Type::Difference, Type::Refined then true
          when Type::Nominal then !IMMUTABLE_CLASSES.include?(type.class_name)
          when Type::Union, Type::Intersection then type.members.any? { |member| mutable?(member) }
          else false
          end
        end

        def widen_members(members, steps)
          widened_any = false
          rebuilt = members.map do |member|
            widened = widen(member, steps)
            next member if widened.nil?

            widened_any = true
            widened
          end
          widened_any ? Type::Combinator.union(*rebuilt) : nil
        end

        def widen_tuple(tuple, steps)
          elements = tuple.elements.dup
          rest = steps.drop(1)
          widened_any = false
          tuple_positions(tuple.elements.size, steps.first).each do |position|
            inner = widen(elements[position], rest)
            next if inner.nil?

            elements[position] = inner
            widened_any = true
          end
          widened_any ? Type::Tuple.new(elements) : nil
        end

        # An out-of-range index selects nothing: the read answers `nil`, and the mutation raises on it.
        def tuple_positions(size, step)
          case step
          when :all, KeyStep then (0...size).to_a
          when :first then size.zero? ? [] : [0]
          when :last then size.zero? ? [] : [size - 1]
          else
            position = step.negative? ? step + size : step
            position.between?(0, size - 1) ? [position] : []
          end
        end

        def widen_hash_shape(shape, steps)
          pairs = shape.pairs.dup
          widened_any = false
          hash_shape_targets(shape, steps).each do |key, rest|
            inner = widen(pairs[key], rest)
            next if inner.nil?

            pairs[key] = inner
            widened_any = true
          end
          return nil unless widened_any

          Type::HashShape.new(pairs, required_keys: shape.required_keys, optional_keys: shape.optional_keys,
                                     read_only_keys: shape.read_only_keys, extra_keys: shape.extra_keys)
        end

        # `[[key, remaining steps], …]` one step selects. A key step names its literal key, Integer keys included; a
        # step that is not literal names every key. `first` reads a fresh `[key, value]` pair, so a mutation of the
        # pair itself touches nothing the shape holds, and one through its value (`H.first[1] << x`, `.last`, `[-1]`
        # or an index that is not literal) reaches every value, since which pair is first is not tracked here. A
        # pair's key is frozen or immutable. `Hash#last` does not exist.
        def hash_shape_targets(shape, steps)
          step = steps.first
          rest = steps.drop(1)
          case step
          when :all then shape.pairs.keys.map { |key| [key, rest] }
          when KeyStep then shape.pairs.key?(step.key) ? [[step.key, rest]] : []
          when Integer then shape.pairs.key?(step) ? [[step, rest]] : []
          when :first
            return [] unless [1, -1, :last, :all].include?(rest.first)

            shape.pairs.keys.map { |key| [key, rest.drop(1)] }
          else []
          end
        end
      end
    end
  end
end
