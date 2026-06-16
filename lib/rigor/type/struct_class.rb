# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"
require_relative "acceptance_router"
require_relative "plain_lattice"

module Rigor
  module Type
    # The class object produced by `Struct.new(:x, :y)` (ADR-48 Struct
    # follow-up). The mutable sibling of {DataClass}: it models the *class*
    # (the value bound to `Point` in `Point = Struct.new(:x, :y)`, or the
    # anonymous superclass in `class Point < Struct.new(:x, :y)`), carrying
    # the ordered member-name list so `Point.new(...)` can materialise a
    # {StructInstance}.
    #
    # `keyword_init` records the `Struct.new(..., keyword_init: true)` flag
    # so `.new` only materialises a precise instance for the matching call
    # form — a positional `.new(1, 2)` on a `keyword_init: true` struct, or
    # a keyword `.new(x: 1)` on a positional struct, is a different runtime
    # shape and must degrade rather than fold a wrong member map.
    #
    # `class_name` carries the binding name when known (the named-subclass
    # form) and is `nil` for the anonymous result of a bare `Struct.new(...)`
    # before it is assigned to a constant.
    #
    # Equality and hashing are structural over the member list, the class
    # name, and the keyword-init flag.
    #
    # See docs/adr/48-data-struct-value-folding.md § "Struct follow-up".
    class StructClass
      attr_reader :members, :class_name, :keyword_init

      # @param members [Array<Symbol>] ordered member names.
      # @param class_name [String, nil] the bound class name, or nil for
      #   the anonymous `Struct.new(...)` result.
      # @param keyword_init [Boolean] the `keyword_init:` flag.
      def initialize(members, class_name = nil, keyword_init: false)
        unless members.is_a?(Array) && members.all?(Symbol)
          raise ArgumentError, "members must be an Array of Symbols, got #{members.inspect}"
        end
        unless class_name.nil? || (class_name.is_a?(String) && !class_name.empty?)
          raise ArgumentError, "class_name must be a non-empty String or nil, got #{class_name.inspect}"
        end

        @members = members.dup.freeze
        @class_name = class_name&.freeze
        @keyword_init = keyword_init ? true : false
        freeze
      end

      def describe(_verbosity = :short)
        return "singleton(#{class_name})" if class_name

        "Struct.new(#{members.map(&:inspect).join(', ')})"
      end

      def erase_to_rbs
        "singleton(#{class_name || 'Struct'})"
      end

      include Rigor::Type::PlainLattice

      include Rigor::Type::AcceptanceRouter

      include Rigor::ValueSemantics

      value_fields :members, :class_name, :keyword_init

      def inspect
        "#<Rigor::Type::StructClass #{describe(:short)}>"
      end
    end
  end
end
