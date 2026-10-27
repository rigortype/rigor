# frozen_string_literal: true

require "rbs"

module Rigor
  module SigGen
    # Issue [#2230](https://github.com/rigortype/rigor/issues/2230) — a rendered type names every class by its
    # fully qualified name, but without the leading `::`: `Type::Nominal#erase_to_rbs` writes `Set[untyped]` for
    # `::Set`. RBS resolves a relative name against the declaration it is written in, innermost namespace first,
    # so inside `module Foo` that declares a `Foo::Set` the written `Set[untyped]` names `::Foo::Set`. A generic
    # name then fails validation ("expects parameters [], but given args [untyped]"); a non-generic one types the
    # method as the wrong class without a word.
    #
    # This anchors a name with `::` only where the namespace the member is written in, or one enclosing it,
    # declares a constant with the name's first segment. Where nothing shadows it the spelling is unchanged, so
    # output for the common case does not churn. The check is over every enclosing namespace of the owner, which
    # covers both the nested `module Foo` / `class Bar` layout the writer emits and a compact `class Foo::Bar`
    # header, and it may anchor a name RBS would have resolved correctly anyway: an anchored name is never wrong,
    # while a missed one is.
    module TypeNameQualification
      module_function

      NAMED_TYPES = [
        RBS::Types::ClassInstance, RBS::Types::ClassSingleton, RBS::Types::Alias, RBS::Types::Interface
      ].freeze
      private_constant :NAMED_TYPES

      # A capitalised word not already preceded by `::` or part of a longer identifier: the first segment of a
      # relative class name. A cheap filter so the common case never reaches the parser.
      RELATIVE_HEAD = /(?<![\w:])[A-Z]\w*/
      private_constant :RELATIVE_HEAD

      # @param rendered — an erased RBS type whose names each spell the class they mean from the top level.
      # @param owner — the qualified name of the class or module the type is written in; nil at the top level.
      # @param declared — called with a qualified name (`"Foo::Set"`); true when the project or the RBS
      #   environment declares a constant there.
      def qualify(rendered, owner, &declared)
        namespaces = enclosing_namespaces(owner)
        return rendered if namespaces.empty?
        return rendered unless rendered.scan(RELATIVE_HEAD).any? { |head| shadowed?(head, namespaces, declared) }

        positions = []
        collect_positions(RBS::Parser.parse_type(rendered, require_eof: true), namespaces, declared, positions)
        positions.sort.reverse_each.with_object(+rendered) { |position, out| out.insert(position, "::") }
      rescue RBS::ParsingError
        rendered
      end

      # `"A::B::C"` → `["A::B::C", "A::B", "A"]`: every namespace a relative name written in `A::B::C`'s
      # declaration is looked up in before the top level.
      def enclosing_namespaces(owner)
        segments = owner.to_s.delete_prefix("::").split("::")
        segments.size.downto(1).map { |n| segments.first(n).join("::") }
      end

      def collect_positions(type, namespaces, declared, positions)
        if NAMED_TYPES.any? { |klass| type.is_a?(klass) } && !type.name.absolute?
          head = (type.name.namespace.path.first || type.name.name).to_s
          positions << type.location[:name].start_pos if shadowed?(head, namespaces, declared)
        end
        type.each_type { |child| collect_positions(child, namespaces, declared, positions) }
      end

      def shadowed?(head, namespaces, declared)
        namespaces.any? { |namespace| declared.call("#{namespace}::#{head}") }
      end
    end
  end
end
