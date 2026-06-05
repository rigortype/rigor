# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"
require_relative "acceptance_router"

module Rigor
  module Type
    # A `Data.define` value instance (ADR-48) — `Point.new(1, 2)`. Models a
    # closed, total, class-tagged member map (member name -> value type).
    # HashShape-shaped, but nominal: a `DataInstance` tagged `Point` is a
    # different type from one tagged `Line` even with identical members,
    # and it erases to its class nominal rather than an RBS record.
    #
    # `Data` instances are frozen, so the member map is sound for the
    # instance's whole lifetime — the reason `Data` is the first target
    # (a `Struct` instance can be mutated through a setter or `[]=`, which
    # would invalidate the map; that follow-up is deferred — see ADR-48).
    #
    # Member reads fold to the member's type (`Point.new(1, 2).x` ->
    # `Constant[1]`); `[]`, `to_h`, `deconstruct`, `deconstruct_keys`,
    # `members`, and `with` project precisely. Methods this carrier does
    # not fold project to the `Data` nominal (or the tagged class) through
    # {RbsDispatch}'s `receiver_descriptor`, so non-member calls resolve
    # without mis-firing undefined-method.
    #
    # Equality and hashing are structural over the (member -> type) map and
    # the class name.
    #
    # See docs/adr/48-data-struct-value-folding.md.
    class DataInstance
      attr_reader :members, :class_name

      # @param members [Hash{Symbol => Rigor::Type}] ordered member -> type
      #   map. Every declared member is present (Data instances are total).
      # @param class_name [String, nil] the tagging class name, or nil for
      #   an instance of an anonymous `Data.define(...)` class.
      def initialize(members, class_name = nil)
        unless members.is_a?(Hash) && members.each_key.all?(Symbol)
          raise ArgumentError, "members must be a Hash with Symbol keys, got #{members.inspect}"
        end
        unless class_name.nil? || (class_name.is_a?(String) && !class_name.empty?)
          raise ArgumentError, "class_name must be a non-empty String or nil, got #{class_name.inspect}"
        end

        @members = members.dup.freeze
        @class_name = class_name&.freeze
        freeze
      end

      # @return [Array<Symbol>] ordered member names.
      def member_names
        members.keys
      end

      # @return [Rigor::Type, nil] the member's value type, or nil when the
      #   name is not a declared member.
      def member_type(name)
        members[name]
      end

      def describe(verbosity = :short)
        rendered = members.map { |name, type| "#{name}: #{type.describe(verbosity)}" }
        "#{class_name || 'Data'}(#{rendered.join(', ')})"
      end

      # Erases to the tagging class nominal (conservative: the structural
      # members are not RBS-expressible as a class instance). The
      # anonymous case erases to the `Data` supertype.
      def erase_to_rbs
        name = class_name
        return "Data" if name.nil?

        name
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
        "#<Rigor::Type::DataInstance #{describe(:short)}>"
      end
    end
  end
end
