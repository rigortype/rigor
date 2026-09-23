# frozen_string_literal: true

require_relative "../type"
require_relative "content_join"

module Rigor
  module Inference
    # The Hash methods that change what a read MISSES into without touching an entry: `default=`,
    # `default_proc=` and `compare_by_identity`. A closed `HashShape` reads a computed key as its values
    # `| nil`, which rests on a miss reading `nil`; after `h.default = 0` a miss reads `0`, after
    # `default_proc=` it reads whatever the proc returns, and after `compare_by_identity` a String key the
    # shape declares can miss. So the shape stops standing for the hash, as it does under any other
    # in-place mutator — but none of these three adds or removes an entry, so the widened carrier keeps
    # the key and value evidence and stays `non-empty-hash` when a required key made the shape non-empty.
    #
    # It lives beside `MutationWidening` rather than inside it because the question differs from the
    # Array / Hash tables': those partition a carrier's content, this one its miss rule.
    module MissRuleMutation
      MUTATORS = %i[default= default_proc= compare_by_identity].to_set.freeze

      module_function

      # A union is left to `MutationWidening`'s memberwise widening, whose members come back through here.
      def applies?(type, method_name)
        MUTATORS.include?(method_name) && !type.is_a?(Type::Union)
      end

      # The binding a `HashShape` holds after `method_name`, or `nil` for any other carrier: a `Hash[K, V]`
      # nominal (bare or `non-empty-hash`) already reads a miss optimistically, and its arguments are a
      # declaration this seam may not grow.
      def widen(type, method_name, arg_types)
        return nil unless type.is_a?(Type::HashShape)

        key = type.pairs.empty? ? Type::Combinator.untyped : ContentJoin.key_union_for(type.pairs.keys)
        values = type.pairs.empty? ? [Type::Combinator.untyped] : type.pairs.values
        value = Type::Combinator.union(*values, *miss_values(method_name, arg_types))
        widened = Type::Combinator.nominal_of("Hash", type_args: [key, value])
        return widened unless type.pairs.keys.any? { |k| !type.optional_key?(k) }

        Type::Combinator.difference(widened, Type::Combinator.hash_shape_of({}))
      end

      # What a miss now reads, joined into the value side. `default=` answers its argument, widened off its
      # value pin so `h[k] == 0` does not fold, and to `untyped` when it is a mutable literal a later read
      # may grow; `default_proc=` answers whatever the proc returns.
      def miss_values(method_name, arg_types)
        case method_name
        when :default= then [default_value(arg_types.first)]
        when :default_proc= then [Type::Combinator.untyped]
        else []
        end
      end

      def default_value(arg)
        return Type::Combinator.untyped if arg.nil? || arg.is_a?(Type::Tuple) || arg.is_a?(Type::HashShape)

        Type::Combinator.widen_value_pinned(arg)
      end
    end
  end
end
