# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"
require_relative "acceptance_router"
require_relative "plain_lattice"

module Rigor
  module Type
    # A generic Result carrier representing a computation that either succeeded with a value of type
    # `ok_type` or failed with an error of type `err_type`.
    #
    # Models `Result[T, E]` (e.g. `Dry::Monads::Result[T, E]`).
    #
    # Subtyping is covariant in both positions: `Result[T1, E1] <: Result[T2, E2]` iff `T1 <: T2` and
    # `E1 <: E2`.
    class Result
      attr_reader :ok_type, :err_type

      alias success_type ok_type
      alias failure_type err_type

      def initialize(ok_type, err_type)
        raise ArgumentError, "ok_type must not be nil" if ok_type.nil?
        raise ArgumentError, "err_type must not be nil" if err_type.nil?

        @ok_type = ok_type
        @err_type = err_type
        freeze
      end

      def describe(verbosity = :short)
        "Result[#{ok_type.describe(verbosity)}, #{err_type.describe(verbosity)}]"
      end

      def erase_to_rbs
        "::Dry::Monads::Result[#{ok_type.erase_to_rbs}, #{err_type.erase_to_rbs}]"
      end

      include Rigor::Type::PlainLattice

      include Rigor::Type::AcceptanceRouter

      include Rigor::ValueSemantics

      value_fields :ok_type, :err_type

      def inspect
        "#<Rigor::Type::Result #{describe(:short)}>"
      end
    end
  end
end
