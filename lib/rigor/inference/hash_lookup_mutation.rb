# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Inference
    # The lookup half of {MutationWidening}'s Hash seam.
    #
    # `Hash#default=`, `Hash#default_proc=` and `Hash#compare_by_identity` mutate the receiver without storing,
    # removing or rewriting a pair. What they change is what a READ of the pairs answers, and a closed `HashShape`
    # makes a claim about exactly that: a key outside `pairs` is provably missing, so `[]` reads `Constant[nil]`.
    # `counts = { a: 1 }; counts.default = 0` kept that claim, and `counts[:b] + 1` drew an error-level
    # `call.undefined-method` on code Ruby runs and prints 1 for.
    #
    # They are kept out of {MutationWidening::HASH_MUTATORS} on purpose. That table answers "the pair set changed",
    # and its other readers act on that answer: the widening there replaces the shape with a `Hash[K, V]` nominal,
    # which costs every present key's value for a mutation that left every pair where it was, and the effect
    # catalogue and the `non-empty-hash` witness read it as a store or a removal. This module answers the narrower
    # question instead, so the present keys keep their values.
    module HashLookupMutation
      MUTATORS = %i[default= default_proc= compare_by_identity].to_set.freeze

      module_function

      # The binding `shape` holds after `method_name`, or `nil` when the call changes no read of it.
      #
      # `default=` / `default_proc=` open the shape: a key outside `pairs` now reads the default, which the shape
      # cannot state, so it reads `untyped` — the answer an open shape gives an undeclared key. A present key still
      # reads its own value. A default proc can also store (`proc { |h, k| h[k] = [] }`), so a read may add a pair,
      # which is what the open policy says too: `size` / `keys` / `key?` stop folding.
      #
      # `compare_by_identity` changes the key a read has to pass, not the answer to a miss, so it leaves a closed
      # shape closed. What it can falsify is a HIT: see {.identity_sensitive?}.
      def widen_shape(shape, method_name)
        case method_name
        when :default=, :default_proc= then open_shape(shape)
        when :compare_by_identity then identity_widening(shape) if identity_sensitive?(shape)
        end
      end

      def open_shape(shape)
        return nil if shape.open?

        Type::HashShape.new(
          shape.pairs,
          required_keys: shape.required_keys,
          optional_keys: shape.optional_keys,
          read_only_keys: shape.read_only_keys,
          extra_keys: :open
        )
      end

      # True when some key of `shape` stops finding its pair under `compare_by_identity`. A read spells its key as a
      # new literal, and after the switch it hits only when that literal is the very object the hash stored. For a
      # Symbol, `true` / `false` / `nil` and an Integer in the fixnum range it always is. A String key is the frozen
      # copy the literal stored, which a later `"k"` is not unless `# frozen_string_literal: true` interns both — so
      # `s = { "k" => 1 }; s.compare_by_identity; s["k"]` is `nil` in one file and `1` in the next — and a bignum or
      # a heap Float is a fresh object per evaluation.
      #
      # A shape whose every key is identity-stable reads exactly as before; any other is widened by
      # {.identity_widening}.
      def identity_sensitive?(shape)
        shape.pairs.each_key.any? { |key| !identity_stable_key?(key) }
      end

      # An identity-sensitive shape widened as a storing mutator widens it, its values unpinned, with a `Dynamic[top]`
      # arm on the value side. A read of a String key may find its pair or miss it and answer `nil`, or a default set
      # before or after, and the nominal cannot say which: the arm keeps that read from folding (`s["k"] == 1`) or
      # drawing `possible nil receiver` in the file where the key does hit. It also keeps the answer independent of
      # order — a nominal ignores a later `default=`, so without the arm `s.compare_by_identity; s.default = "x"` read
      # `s["zz"]` as `Integer`.
      def identity_widening(shape)
        key, value = MutationWidening.widen_hash_shape(shape, values: :widen).type_args
        Type::Combinator.nominal_of("Hash", type_args: [key, Type::Combinator.union(value, Type::Combinator.untyped)])
      end

      # `Integer#bit_length` is at most 62 for exactly CRuby's 64-bit fixnum range, `-(2**62)..(2**62 - 1)`.
      def identity_stable_key?(key)
        case key
        when Symbol, true, false, nil then true
        when Integer then key.bit_length <= 62
        else false
        end
      end
    end
  end
end
