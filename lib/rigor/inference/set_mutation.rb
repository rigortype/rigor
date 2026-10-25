# frozen_string_literal: true

require_relative "../type"
require_relative "content_join"
require_relative "rewrite_mutation"

module Rigor
  module Inference
    # The Set half of {MutationWidening}'s seams (issue #2294), beside {StringMutation}.
    #
    # `f = Set["a"]; f.clear; f << 1; f.map { |v| v.fdiv(2) }` reported `undefined method 'fdiv' for String`
    # on code that prints `[0.5]`: the mutation seams answered `Tuple`, `HashShape`, `Constant[String]` and the
    # re-openable `Array` / `Hash` nominals, so a `Set` kept the elements it was built with through every
    # `<<`, `add`, `merge` and `replace`.
    #
    # A Set has no slots and no arity, so the only thing a mutation falsifies is the element set. Both carriers
    # this module answers end at the typed Set #2290 builds for a non-constant literal — `Set[E | Dynamic[top]]`:
    #
    # - a constant-folded `Constant[Set]` widens to that carrier, its members' value pins dropped
    #   ({MethodDispatcher.array_new_element}) and joined with the `Dynamic[top]` floor;
    # - a typed `Set` whose element already carries a gradual arm re-grows the way
    #   {MutationRejoin.regrowable_carrier?} lets an `Array` / `Hash` re-grow. A PRECISE `Set[String]` (an RBS
    #   return such as `Array#to_set`) is a claim somebody made and is left alone, as a precise `Array[String]`
    #   is.
    #
    # The carrier's element always carries the floor, so {ContentJoin.admissible_evidence} admits every added
    # member as itself: the seed-admissibility gate has nothing to contradict on a gradual seed.
    module SetMutation
      # Receiver-mutating Set methods. The non-bang siblings (`map` vs `map!`, `select` vs `select!`) and the
      # algebra (`|`, `+`, `-`, `&`, `^`) return a new Set and stay precise.
      MUTATORS = %i[
        << add add? merge replace
        map! collect! flatten!
        clear delete delete? delete_if keep_if select! filter! reject! subtract
      ].to_set.freeze

      # The {MUTATORS} that put elements in. `<<` / `add` / `add?` store their argument; `merge` stores every
      # argument's elements; `replace` its argument's elements, after {RewriteMutation} has dropped the old ones.
      CONTENT_ADDERS = %i[<< add add? merge replace].to_set.freeze

      module_function

      def constant?(type)
        type.is_a?(Type::Constant) && type.value.is_a?(::Set)
      end

      # True when `type` is a `Set` the seams may grow: a constant-folded one, or a typed one carrying a gradual
      # element arm.
      def carrier?(type)
        constant?(type) || (type.is_a?(Type::Nominal) && regrowable?(type))
      end

      def regrowable?(nominal)
        nominal.class_name == "Set" && nominal.type_args.size == 1 &&
          ContentJoin.union_members(nominal.type_args.first).any?(Type::Dynamic)
      end

      # The carrier `type` holds after `method_name` with argument types `arg_types`, or `nil` when the call is not
      # a Set mutator or `type` is not a carrier this seam grows. `nil` also answers a re-join that changed nothing,
      # so a remover on an already-widened Set does not rebind it.
      def widen(type, method_name, arg_types)
        return nil unless MUTATORS.include?(method_name)

        if constant?(type)
          join(floored(type.value.map { |v| Type::Combinator.constant_of(v) }), method_name, arg_types)
        elsif type.is_a?(Type::Nominal) && regrowable?(type)
          joined = join(type, method_name, arg_types)
          joined == type ? nil : joined
        end
      end

      def join(carrier, method_name, arg_types)
        carrier = RewriteMutation.arm(carrier, method_name)
        return carrier unless CONTENT_ADDERS.include?(method_name)

        added = added_elements(method_name, arg_types).map { |t| widened_member(t) }
        return carrier if added.empty?

        Type::Combinator.nominal_of("Set", type_args: [Type::Combinator.union(carrier.type_args.first, *added)])
      end

      # The element types one content-adder call puts in, from the call's argument types.
      def added_elements(method_name, arg_types)
        return [] if arg_types.empty?

        case method_name
        when :merge, :replace then arg_types.flat_map { |t| element_types(t) }
        else [arg_types.first || Type::Combinator.untyped]
        end
      end

      # `Set[E | Dynamic[top]]` over `members`, the #2290 typed-Set floor. An empty seed (`Set.new`) is
      # `Set[Dynamic[top]]`.
      def floored(members)
        widened = members.map { |m| widened_member(m) }
        Type::Combinator.nominal_of("Set", type_args: [Type::Combinator.union(*widened, Type::Combinator.untyped)])
      end

      # The element types an enumerable argument (`merge`'s, `replace`'s, the algebra's `_Each[A]`) yields: a
      # `Tuple`'s elements, an `Array` / `Set` / `Range` nominal's element parameter, a constant Set's or Range's
      # members. Anything else yields elements this seam cannot name, which are unknown rather than none.
      def element_types(type)
        case type
        when Type::Union then type.members.flat_map { |m| element_types(m) }
        when Type::Tuple then type.elements
        when Type::Nominal
          if %w[Array Set Range].include?(type.class_name) && type.type_args.size == 1
            type.type_args
          else
            [Type::Combinator.untyped]
          end
        when Type::Constant then constant_elements(type)
        else [Type::Combinator.untyped]
        end
      end

      def constant_elements(constant)
        value = constant.value
        if value.is_a?(::Set) then value.map { |v| Type::Combinator.constant_of(v) }
        elsif value.is_a?(::Range) && value.begin.is_a?(Integer)
          [Type::Combinator.nominal_of("Integer")]
        else [Type::Combinator.untyped]
        end
      end

      # A stored member's value pin and literal shape are dropped, as an `Array.new` fill's are: the set holds the
      # object, and the program keeps a reference to it.
      def widened_member(type)
        MethodDispatcher.array_new_element(type)
      end
    end
  end
end
