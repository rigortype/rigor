# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"
require_relative "acceptance_router"

module Rigor
  module Type
    # The dynamic-origin wrapper: marks values whose type came from an
    # unchecked source. Carries a static facet that records the analyzer's
    # best static knowledge. See docs/type-specification/value-lattice.md
    # for the algebra and docs/type-specification/special-types.md for the
    # untyped/Dynamic[T] relationship.
    #
    # Construct via Rigor::Type::Combinator.dynamic(static_facet).
    class Dynamic
      attr_reader :static_facet

      def initialize(static_facet)
        @static_facet = static_facet
        freeze
      end

      def describe(verbosity = :short)
        "Dynamic[#{static_facet.describe(verbosity)}]"
      end

      def erase_to_rbs
        "untyped"
      end

      def top
        Trinary.no
      end

      def bot
        Trinary.no
      end

      def dynamic
        Trinary.yes
      end

      include Rigor::Type::AcceptanceRouter

      include Rigor::ValueSemantics

      value_fields :static_facet

      def inspect
        "#<Rigor::Type::Dynamic #{describe(:short)}>"
      end
    end
  end
end
