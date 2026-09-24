# frozen_string_literal: true

require_relative "../../type"
require_relative "../mutation_widening"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #1092 — the substitute {RbsDispatch} hands the translator for `Bases::Self` on an instance
      # receiver whose projection carries type arguments, so `Array[Integer]#tap {}` answers
      # `Array[Integer]` rather than the raw `Array` the class name alone builds. `nil` keeps that raw
      # nominal.
      #
      # The substitute is always a nominal built from the receiver's projected arguments, never the
      # receiver's shape: the pure self-returners keep the shape through ShapeDispatch (ADR-76 WD3), and a
      # block can mutate the receiver through its yielded alias, which MutationWidening does not follow.
      # For the same reason every argument is widened DEEPLY — a literal to its class, a nested
      # `Tuple` / `HashShape` to its projected nominal — so `[[1, 2]].tap { |a| a[0] << 3 }` cannot fold
      # `.first.size == 3`.
      #
      # A `-> self` method that can change the element types keeps the arguments only when the call
      # provably adds nothing outside them; otherwise the call value would claim `ints.map!(&:to_s)` is
      # still an `Array[Integer]`.
      module SelfSubstitute
        # In-place methods that cannot change the receiver's element, key, or value types.
        TYPE_PRESERVING = %i[
          sort! sort_by! reverse! uniq! compact! shuffle! rotate!
          select! filter! reject! keep_if delete_if delete subtract
          clear compare_by_identity rehash reset
        ].to_set.freeze

        # Adders whose positional arguments are each a new element (`Array` / `Set`).
        ELEMENT_ADDERS = %i[<< push append unshift prepend add add?].to_set.freeze

        # Adders whose positional arguments are each a collection of the receiver's own class.
        COLLECTION_ADDERS = %i[concat merge merge! update].to_set.freeze

        # Every other name MutationWidening knows as a receiver mutator (`map!`, `replace`, `fill`,
        # `flatten!`, `transform_values!`, ...) rewrites or may rewrite the element types.
        KNOWN_MUTATORS = (MutationWidening::ARRAY_MUTATORS | MutationWidening::HASH_MUTATORS).freeze

        module_function

        # @param args — the call's positional argument types.
        # @param block_type — the call's block return type, nil without a block.
        def for(receiver, receiver_args, method_name, args, block_type)
          return nil if receiver_args.empty?

          case receiver
          when Type::Nominal
            nominal_self(receiver.class_name, receiver_args, method_name, args, block_type)
          when Type::Tuple
            projected_self("Array", receiver_args) unless MutationWidening::ARRAY_MUTATORS.include?(method_name)
          when Type::HashShape
            projected_self("Hash", receiver_args) unless MutationWidening::HASH_MUTATORS.include?(method_name)
          when Type::Refined, Type::Difference
            self.for(receiver.base, receiver_args, method_name, args, block_type)
          when Type::Dynamic
            inner = self.for(receiver.static_facet, receiver_args, method_name, args, block_type)
            inner && Type::Combinator.dynamic(inner)
          end
        end

        def nominal_self(class_name, receiver_args, method_name, args, block_type)
          return nil unless preserves_type_args?(class_name, receiver_args, method_name, args, block_type)

          projected_self(class_name, receiver_args)
        end

        # Nil when every argument widens to the bare `Dynamic[top]`: `Hash[untyped, untyped]` says nothing
        # the raw `Hash` does not.
        def projected_self(class_name, receiver_args)
          type_args = receiver_args.map { |arg| deep_widen(arg) }
          return nil if type_args.all? { |arg| untyped?(arg) }

          Type::Combinator.nominal_of(class_name, type_args: type_args)
        end

        def preserves_type_args?(class_name, receiver_args, method_name, args, block_type)
          return true if TYPE_PRESERVING.include?(method_name)

          if ELEMENT_ADDERS.include?(method_name)
            receiver_args.size == 1 && all_provably_within?(receiver_args.first, args)
          elsif method_name == :insert
            receiver_args.size == 1 && all_provably_within?(receiver_args.first, args.drop(1))
          elsif COLLECTION_ADDERS.include?(method_name)
            block_type.nil? &&
              all_provably_within?(Type::Combinator.nominal_of(class_name, type_args: receiver_args), args)
          else
            !KNOWN_MUTATORS.include?(method_name) && !method_name.end_with?("!")
          end
        end

        def all_provably_within?(bound, args)
          args.all? { |arg| !imprecise?(arg) && bound.accepts(arg, mode: :gradual).yes? }
        end

        def imprecise?(type)
          case type
          when Type::Dynamic then true
          when Type::Union then type.members.any? { |member| imprecise?(member) }
          else false
          end
        end

        def untyped?(type)
          type.is_a?(Type::Dynamic) && type.static_facet.is_a?(Type::Top)
        end

        # `widen_value_pinned`, extended through nested shape carriers and applied type arguments.
        def deep_widen(type)
          case type
          when Type::Tuple
            return Type::Combinator.nominal_of("Array") if type.elements.empty?

            Type::Combinator.nominal_of("Array", type_args: [deep_widen(Type::Combinator.union(*type.elements))])
          when Type::HashShape
            deep_widen_hash_shape(type)
          when Type::Nominal
            return type if type.type_args.empty?

            Type::Combinator.nominal_of(type.class_name, type_args: type.type_args.map { |arg| deep_widen(arg) })
          when Type::Union
            Type::Combinator.union(*type.members.map { |member| deep_widen(member) })
          when Type::Dynamic
            untyped?(type) ? type : Type::Combinator.dynamic(deep_widen(type.static_facet))
          else
            Type::Combinator.widen_value_pinned(type)
          end
        end

        def deep_widen_hash_shape(shape)
          return Type::Combinator.nominal_of("Hash") if shape.pairs.empty?

          keys = Type::Combinator.union(*shape.pairs.keys.map { |key| Type::Combinator.constant_of(key) })
          values = Type::Combinator.union(*shape.pairs.values)
          Type::Combinator.nominal_of("Hash", type_args: [deep_widen(keys), deep_widen(values)])
        end
      end
    end
  end
end
