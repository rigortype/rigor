# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # A heterogeneous, fixed-arity array shape. Inhabitants are exactly
    # the Ruby `Array` instances whose length matches `elements.size`
    # and whose element at position `i` inhabits `elements[i]`.
    #
    # In RBS this corresponds to the tuple form `[A, B, C]`. A tuple
    # is always a subtype of `Array[union(elements)]`; method dispatch
    # therefore degrades to the underlying `Nominal[Array, [union]]`
    # while acceptance keeps the per-position precision.
    #
    # Slice 5 phase 1 introduces the carrier and surfaces it from the
    # `ArrayNode` literal handler when every element is a non-splat
    # value. Tuple-aware refinements for `tuple[0]`, `tuple.first`, and
    # destructuring assignment are deferred to Slice 5 phase 2; they
    # will run as a higher-priority dispatch tier above
    # {Rigor::Inference::MethodDispatcher::RbsDispatch}.
    #
    # Equality and hashing are structural across an ordered, frozen
    # element list. The empty Tuple `Tuple[]` is permitted; the array
    # literal handler keeps `[]` as raw `Nominal[Array]` (no element
    # evidence to lock the arity), but external constructors MAY build
    # `Tuple[]` directly when the zero-arity discipline is intended.
    #
    # See docs/type-specification/rbs-compatible-types.md (tuple) and
    # docs/type-specification/rigor-extensions.md (hash-shape and
    # tuple kin).
    class Tuple
      attr_reader :elements

      def initialize(elements)
        raise ArgumentError, "elements must be an Array, got #{elements.class}" unless elements.is_a?(Array)

        @elements = elements.dup.freeze
        freeze
      end

      def describe(verbosity = :short)
        return "[]" if elements.empty?

        "[#{elements.map { |t| t.describe(verbosity) }.join(', ')}]"
      end

      def erase_to_rbs
        return "[]" if elements.empty?

        "[#{elements.map(&:erase_to_rbs).join(', ')}]"
      end

      def top
        Trinary.no
      end

      def bot
        Trinary.no
      end

      def dynamic
        Trinary.no
      end

      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(self, other, mode: mode)
      end

      def ==(other)
        other.is_a?(Tuple) && elements == other.elements
      end
      alias eql? ==

      def hash
        [Tuple, elements].hash
      end

      def inspect
        "#<Rigor::Type::Tuple #{describe(:short)}>"
      end
    end
  end
end
