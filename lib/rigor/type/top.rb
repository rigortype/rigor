# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # The top of the value lattice: contains every value, including untyped
    # boundaries. See docs/type-specification/special-types.md.
    class Top
      # ADR-15 Phase 4b.x — eager singleton (see Bot.rb).
      @instance = new.freeze

      class << self
        attr_reader :instance

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

      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(self, other, mode: mode)
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
