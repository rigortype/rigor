# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # The bottom of the value lattice: contains no values. The result type of
    # expressions that cannot terminate normally. See
    # docs/type-specification/special-types.md.
    class Bot
      # ADR-15 Phase 4b.x — eager singleton so workers READ
      # `@instance` without performing the lazy `||=` write
      # that non-main Ractors are forbidden from doing.
      @instance = new.freeze

      class << self
        attr_reader :instance

        private :new
      end

      def describe(_verbosity = :short)
        "bot"
      end

      def erase_to_rbs
        "bot"
      end

      def top
        Trinary.no
      end

      def bot
        Trinary.yes
      end

      def dynamic
        Trinary.no
      end

      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(self, other, mode: mode)
      end

      def ==(other)
        other.is_a?(Bot)
      end
      alias eql? ==

      def hash
        Bot.hash
      end

      def inspect
        "#<Rigor::Type::Bot>"
      end
    end
  end
end
