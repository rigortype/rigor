# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # The top of the value lattice: contains every value, including untyped
    # boundaries. See docs/type-specification/special-types.md.
    class Top
      class << self
        def instance
          @instance ||= new.freeze
        end

        private :new
      end

      def describe(_verbosity = :short)
        "top"
      end

      def erase_to_rbs
        "top"
      end

      def top
        Trinary.yes
      end

      def bot
        Trinary.no
      end

      def dynamic
        Trinary.no
      end

      def ==(other)
        other.is_a?(Top)
      end
      alias eql? ==

      def hash
        Top.hash
      end

      def inspect
        "#<Rigor::Type::Top>"
      end
    end
  end
end
