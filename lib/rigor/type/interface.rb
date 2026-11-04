# frozen_string_literal: true

require_relative "../trinary"
require_relative "../value_semantics"
require_relative "acceptance_router"
require_relative "plain_lattice"

module Rigor
  module Type
    # ADR-130 WD1 — an RBS interface under `Rigor::Plugin` (`_Scope`, `_Environment`, ...), as the facet of the
    # `Dynamic` that carries a plugin-interface value: `Dynamic[Rigor::Plugin::_Scope]`. It appears only there.
    # `Combinator.untyped?` reads such a `Dynamic` as `untyped`, and union normalisation erases it to `Dynamic[top]`
    # wherever a join would otherwise keep an arm master does not, so the facet changes one behaviour: a call of a
    # member the interface declares resolves through that member's RBS (`RbsDispatch`, ADR-130 WD3).
    #
    # `name` is spelled as `Nominal#class_name` is (`Rigor::Plugin::_Scope`), and `type_args` are the interface's
    # type arguments, translated in the caller's context. Every other RBS interface still translates to
    # `Dynamic[top]` (`RbsTypeTranslator`, ADR-130 WD4).
    class Interface
      attr_reader :name, :type_args

      EMPTY_TYPE_ARGS = [].freeze
      private_constant :EMPTY_TYPE_ARGS

      def initialize(name, type_args = EMPTY_TYPE_ARGS)
        raise ArgumentError, "name must be a String, got #{name.class}" unless name.is_a?(String)

        @name = name.frozen? ? name : name.dup.freeze
        @type_args = type_args.frozen? ? type_args : type_args.dup.freeze
        freeze
      end

      def describe(verbosity = :short)
        return name if type_args.empty?

        "#{name}[#{type_args.map { |arg| arg.describe(verbosity) }.join(', ')}]"
      end

      # A facet never reaches erasure on its own (`Dynamic#erase_to_rbs` is `untyped`); spelled as RBS for a
      # caller that erases the carrier directly.
      def erase_to_rbs
        return name if type_args.empty?

        "#{name}[#{type_args.map(&:erase_to_rbs).join(', ')}]"
      end

      include Rigor::Type::PlainLattice

      include Rigor::Type::AcceptanceRouter

      include Rigor::ValueSemantics

      value_fields :name, :type_args

      def inspect
        "#<Rigor::Type::Interface #{describe(:short)}>"
      end
    end
  end
end
