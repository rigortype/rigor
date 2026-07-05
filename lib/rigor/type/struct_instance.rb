# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"
require_relative "acceptance_router"
require_relative "plain_lattice"

module Rigor
  module Type
    # A `Struct.new` value instance (ADR-48 Struct follow-up) — `Point.new(1, 2)`. The mutable sibling of
    # {DataInstance}: a closed, total, class-tagged member map (member name -> value type),
    # HashShape-shaped but nominal.
    #
    # Unlike {DataInstance}, a `Struct` instance is **mutable** — `s.x = v`, `s[:x] = v`, and escape can
    # invalidate the member map. The folding tier therefore only projects member reads off a **fresh**
    # instance (the transient receiver of a `.new(...).x` / `.with(...).x` chain, which provably cannot
    # have been mutated between materialisation and the read); a read off a *stored* binding degrades to
    # `Dynamic[top]` rather than fold a possibly-stale member value. Promoting the fold to mutation-free
    # bound locals is the deferred slice 3 (see ADR).
    #
    # That mutability-gating lives in the dispatch tier (`StructFolding`), not the carrier: the carrier
    # itself just records the member map. Like {DataInstance}, non-folded methods project to the
    # `Struct` nominal (or the tagged class) through {RbsDispatch}'s `receiver_descriptor`, so non-member
    # calls resolve without mis-firing undefined-method.
    #
    # Equality and hashing are structural over the (member -> type) map and the class name.
    #
    # See docs/adr/48-data-struct-value-folding.md § "Struct follow-up".
    class StructInstance
      attr_reader :members, :class_name

      # @param members [Hash{Symbol => Rigor::Type}] ordered member -> type
      #   map. Every declared member is present (Struct instances are total).
      # @param class_name [String, nil] the tagging class name, or nil for
      #   an instance of an anonymous `Struct.new(...)` class.
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
        "#{class_name || 'Struct'}(#{rendered.join(', ')})"
      end

      # Erases to the tagging class nominal (conservative: the structural members are not RBS-expressible
      # as a class instance). The anonymous case erases to the `Struct` supertype.
      def erase_to_rbs
        name = class_name
        return "Struct" if name.nil?

        name
      end

      include Rigor::Type::PlainLattice

      include Rigor::Type::AcceptanceRouter

      include Rigor::ValueSemantics

      value_fields :members, :class_name

      def inspect
        "#<Rigor::Type::StructInstance #{describe(:short)}>"
      end
    end
  end
end
