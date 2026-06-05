# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"
require_relative "acceptance_router"

module Rigor
  module Type
    # The class object produced by `Data.define(:x, :y)` (ADR-48). Models
    # the *class*, not an instance — the value bound to `Point` in
    # `Point = Data.define(:x, :y)` or the anonymous superclass in
    # `class Point < Data.define(:x, :y)`. Parameterised by the ordered
    # member-name list so that `Point.new(...)` can materialise a precise
    # {DataInstance}.
    #
    # `class_name` carries the binding name when known (the named-subclass
    # form, ADR-48 slice 3) and is `nil` for the anonymous result of a bare
    # `Data.define(...)` before it is assigned to a constant. It tags the
    # instances `.new` produces; it does not change the carrier's folding
    # behaviour.
    #
    # Equality and hashing are structural over the member list and the
    # class name. Two distinct `Data.define(:x)` results are equal *as
    # types* — they describe the same shape; the engine distinguishes the
    # constants they are bound to by the binding, not by the carrier.
    #
    # See docs/adr/48-data-struct-value-folding.md.
    class DataClass
      attr_reader :members, :class_name

      # @param members [Array<Symbol>] ordered member names.
      # @param class_name [String, nil] the bound class name, or nil for
      #   the anonymous `Data.define(...)` result.
      def initialize(members, class_name = nil)
        unless members.is_a?(Array) && members.all?(Symbol)
          raise ArgumentError, "members must be an Array of Symbols, got #{members.inspect}"
        end
        unless class_name.nil? || (class_name.is_a?(String) && !class_name.empty?)
          raise ArgumentError, "class_name must be a non-empty String or nil, got #{class_name.inspect}"
        end

        @members = members.dup.freeze
        @class_name = class_name&.freeze
        freeze
      end

      def describe(_verbosity = :short)
        return "singleton(#{class_name})" if class_name

        "Data.define(#{members.map(&:inspect).join(', ')})"
      end

      def erase_to_rbs
        "singleton(#{class_name || 'Data'})"
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

      include Rigor::Type::AcceptanceRouter

      include Rigor::ValueSemantics

      value_fields :members, :class_name

      def inspect
        "#<Rigor::Type::DataClass #{describe(:short)}>"
      end
    end
  end
end
