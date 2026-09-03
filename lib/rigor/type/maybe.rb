# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"
require_relative "acceptance_router"
require_relative "plain_lattice"

module Rigor
  module Type
    # A generic Maybe carrier representing an optional value that either contains a value of type
    # `value_type` or nothing.
    #
    # Models `Maybe[T]` (e.g. `Dry::Monads::Maybe[T]`).
    #
    # Subtyping is covariant: `Maybe[T1] <: Maybe[T2]` iff `T1 <: T2`.
    class Maybe
      attr_reader :value_type

      def initialize(value_type)
        raise ArgumentError, "value_type must not be nil" if value_type.nil?

        @value_type = value_type
        freeze
      end

      def describe(verbosity = :short)
        "Maybe[#{value_type.describe(verbosity)}]"
      end

      def erase_to_rbs
        "::Dry::Monads::Maybe[#{value_type.erase_to_rbs}]"
      end

      include Rigor::Type::PlainLattice

      include Rigor::Type::AcceptanceRouter

      include Rigor::ValueSemantics

      value_fields :value_type

      def inspect
        "#<Rigor::Type::Maybe #{describe(:short)}>"
      end
    end
  end
end
