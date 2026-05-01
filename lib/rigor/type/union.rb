# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # A normalized non-empty union of two or more distinct types. Unions are
    # constructed exclusively through Rigor::Type::Combinator.union, which
    # flattens nested unions, deduplicates structurally-equal members, and
    # collapses single-member or empty results to the appropriate scalar
    # type. Direct calls to .new are an internal contract: callers MUST pass
    # an already-normalized members array.
    #
    # See docs/type-specification/normalization.md.
    class Union
      attr_reader :members

      def initialize(members)
        unless members.is_a?(Array) && members.size >= 2
          raise ArgumentError, "Union requires at least two members; use Combinator.union for normalization"
        end

        @members = members.freeze
        freeze
      end

      def describe(verbosity = :short)
        members.map { |m| m.describe(verbosity) }.join(" | ")
      end

      def erase_to_rbs
        members.map(&:erase_to_rbs).join(" | ")
      end

      def top
        Trinary.no
      end

      def bot
        Trinary.no
      end

      def dynamic
        members.any? { |m| m.respond_to?(:dynamic) && m.dynamic.yes? } ? Trinary.maybe : Trinary.no
      end

      def accepts(other, mode: :gradual)
        Inference::Acceptance.accepts(self, other, mode: mode)
      end

      def ==(other)
        other.is_a?(Union) && members == other.members
      end
      alias eql? ==

      def hash
        [Union, members].hash
      end

      def inspect
        "#<Rigor::Type::Union #{describe(:short)}>"
      end
    end
  end
end
