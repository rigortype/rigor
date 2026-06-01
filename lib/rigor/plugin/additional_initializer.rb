# frozen_string_literal: true

module Rigor
  module Plugin
    # ADR-38 declaration: "on `receiver_constraint` (and its
    # subclasses), every method named in `methods` also establishes
    # instance-variable state — treat it like `initialize` for the
    # read-before-write nil soundness gate."
    #
    # Authored on a plugin manifest:
    #
    #   manifest(
    #     id: "minitest",
    #     version: "0.1.0",
    #     additional_initializers: [
    #       Rigor::Plugin::AdditionalInitializer.new(
    #         receiver_constraint: "Minitest::Test",
    #         methods: [:setup]
    #       )
    #     ]
    #   )
    #
    # The Ruby analogue of PHPStan's `AdditionalConstructorsExtension`.
    # `Rigor::Inference::ScopeIndexer` consults the aggregated set at
    # its single read-before-write gate: for a `def` whose name is in
    # `methods` on a class that equals or inherits from
    # `receiver_constraint` (matched via `Environment#class_ordering`,
    # the same mechanism ADR-16 Tier A uses), the method's ivar writes
    # are folded into the class's `init_writes` set, so a sibling
    # method reading those ivars no longer gets a `Constant[nil]`
    # widening.
    #
    # The contribution can only ever *suppress* a nil widening — it
    # never makes the analyzer stricter — so a missed or over-broad
    # match is false-positive-safe by construction (ADR-38 § "Why this
    # is FP-safe").
    #
    # ## Fields
    #
    # - `receiver_constraint` — fully-qualified class name (String).
    #   The entry applies to that class and its subclasses.
    # - `methods` — Array of Symbol method names treated as
    #   initializers on a matching class.
    #
    # ## Ractor-shareability
    #
    # Both fields are frozen at construction (ADR-15 Phase 1);
    # `Ractor.shareable?` returns true after `#initialize`, so the
    # value object survives `Plugin::Registry.materialize` into a
    # worker Ractor.
    class AdditionalInitializer
      attr_reader :receiver_constraint, :methods

      def initialize(receiver_constraint:, methods:)
        validate_receiver_constraint!(receiver_constraint)
        validate_methods!(methods)

        @receiver_constraint = receiver_constraint.dup.freeze
        @methods = methods.map(&:to_sym).freeze
        freeze
      end

      # True when `method_name` (a Symbol) is declared an initializer
      # by this entry. The class-constraint match is the caller's
      # responsibility (it needs the environment's class graph).
      def covers_method?(method_name)
        methods.include?(method_name)
      end

      def to_h
        {
          "receiver_constraint" => receiver_constraint,
          "methods" => methods.map(&:to_s)
        }
      end

      def ==(other)
        other.is_a?(AdditionalInitializer) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end

      private

      def validate_receiver_constraint!(value)
        return if value.is_a?(String) && !value.empty?

        raise ArgumentError,
              "Plugin::AdditionalInitializer#receiver_constraint must be a non-empty String, " \
              "got #{value.inspect}"
      end

      def validate_methods!(value)
        if value.is_a?(Array) && !value.empty? &&
           value.all? { |m| m.is_a?(Symbol) || (m.is_a?(String) && !m.empty?) }
          return
        end

        raise ArgumentError,
              "Plugin::AdditionalInitializer#methods must be a non-empty Array of " \
              "Symbol/non-empty String, got #{value.inspect}"
      end
    end
  end
end
