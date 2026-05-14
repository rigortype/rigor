# frozen_string_literal: true

require_relative "../trinary"

module Rigor
  module Type
    # A `Method` carrier that tracks the bound `(receiver, name)` pair.
    #
    # Ruby's `Object#method(name)` returns a `Method` instance whose
    # later `.call` / `.()` / `[]` dispatches `name` on the original
    # receiver. The plain RBS `Method` nominal cannot carry that
    # binding, so call sites on the resulting `Method` collapse to
    # `untyped` — losing the per-method precision the original
    # receiver supports.
    #
    # `BoundMethod` keeps the binding so the dispatcher can substitute
    # the original `(receiver, name)` dispatch at `.call` / `.()` /
    # `[]` time. The carrier erases to `Method` at the RBS boundary so
    # downstream RBS interop (e.g. passing the value into a method
    # whose parameter is typed `::Method`) stays compatible — the
    # binding is only consulted when Rigor itself dispatches.
    #
    # See `lib/rigor/inference/method_dispatcher/method_folding.rb`
    # for the forward (`Object#method(:sym)`) and backward
    # (`BoundMethod#call`) folding tiers that consume / produce this
    # carrier.
    class BoundMethod
      attr_reader :receiver_type, :method_name

      def initialize(receiver_type:, method_name:)
        raise ArgumentError, "receiver_type must not be nil" if receiver_type.nil?
        raise ArgumentError, "method_name must be a Symbol, got #{method_name.inspect}" unless method_name.is_a?(Symbol)

        @receiver_type = receiver_type
        @method_name = method_name
        freeze
      end

      def describe(verbosity = :short)
        "Method<#{receiver_type.describe(verbosity)}##{method_name}>"
      end

      def erase_to_rbs
        "Method"
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
        other.is_a?(BoundMethod) &&
          receiver_type == other.receiver_type &&
          method_name == other.method_name
      end
      alias eql? ==

      def hash
        [BoundMethod, receiver_type, method_name].hash
      end

      def inspect
        "#<Rigor::Type::BoundMethod #{describe(:short)}>"
      end
    end
  end
end
