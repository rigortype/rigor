# frozen_string_literal: true

module Rigor
  module Plugin
    # ADR-38 declaration: "on `receiver_constraint` (and its subclasses), every method named in `methods`
    # (def-form) or `block_methods` (block-form) also establishes instance-variable state — treat it like
    # `initialize` for the read-before-write nil soundness gate."
    #
    # **Def-form** (`methods:`) — applies when the ivar write lives in a named `def` body. Example: Minitest
    # `def setup; @conn = …; end`.
    #
    # **Block-form** (`block_methods:`) — applies when the ivar write lives in a block passed to a method
    # call. Example: RSpec `before { @user = create(:user) }` / `let(:x) { @y = … }`. `ScopeIndexer` descends
    # the block body of any `CallNode` whose method name is in `block_methods`, collecting ivar writes exactly
    # as it would for a def-form initializer.
    #
    # At least one of `methods:` or `block_methods:` must be non-empty.
    #
    # Authored on a plugin manifest:
    #
    #   # def-form (Minitest):
    #   AdditionalInitializer.new(
    #     receiver_constraint: "Minitest::Test",
    #     methods: [:setup]
    #   )
    #
    #   # block-form (RSpec):
    #   AdditionalInitializer.new(
    #     receiver_constraint: "RSpec::ExampleGroup",
    #     block_methods: [:before, :let, :subject]
    #   )
    #
    # The Ruby analogue of PHPStan's `AdditionalConstructorsExtension`. `Rigor::Inference::ScopeIndexer`
    # consults the aggregated set at its read-before-write gate.
    #
    # The contribution can only ever *suppress* a nil widening — it never makes the analyzer stricter — so a
    # missed or over-broad match is false-positive-safe by construction (ADR-38 § "Why this is FP-safe").
    #
    # ## Fields
    #
    # - `receiver_constraint` — fully-qualified class name (String). The entry applies to that class and its
    #   subclasses.
    # - `methods` — Array of Symbol `def`-form method names (may be empty when only block_methods is used).
    # - `block_methods` — Array of Symbol call-with-block method names (may be empty when only methods is
    #   used).
    #
    # ## Ractor-shareability
    #
    # All fields are frozen at construction (ADR-15 Phase 1); `Ractor.shareable?` returns true after
    # `#initialize`.
    class AdditionalInitializer
      attr_reader :receiver_constraint, :methods, :block_methods

      def initialize(receiver_constraint:, methods: [], block_methods: [])
        validate_receiver_constraint!(receiver_constraint)
        validate_method_list!(methods, :methods)
        validate_method_list!(block_methods, :block_methods)
        validate_at_least_one!(methods, block_methods)

        @receiver_constraint = receiver_constraint.dup.freeze
        @methods = methods.map(&:to_sym).freeze
        @block_methods = block_methods.map(&:to_sym).freeze
        freeze
      end

      # True when `method_name` (a Symbol) is declared a def-form initializer by this entry.
      def covers_method?(method_name)
        methods.include?(method_name)
      end

      # True when `method_name` (a Symbol) is declared a block-form initializer by this entry.
      def covers_block_method?(method_name)
        block_methods.include?(method_name)
      end

      def to_h
        {
          "receiver_constraint" => receiver_constraint,
          "methods" => methods.map(&:to_s),
          "block_methods" => block_methods.map(&:to_s)
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

      def validate_method_list!(value, field)
        return if value.is_a?(Array) &&
                  value.all? { |m| m.is_a?(Symbol) || (m.is_a?(String) && !m.empty?) }

        raise ArgumentError,
              "Plugin::AdditionalInitializer##{field} must be an Array of " \
              "Symbol/non-empty String, got #{value.inspect}"
      end

      def validate_at_least_one!(methods, block_methods)
        return unless methods.empty? && block_methods.empty?

        raise ArgumentError,
              "Plugin::AdditionalInitializer requires at least one of methods: or block_methods: " \
              "to be non-empty"
      end
    end
  end
end
