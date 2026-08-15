# frozen_string_literal: true

require "rbs"

require_relative "scan"

module Rigor
  module Analysis
    module Reachability
      # ADR-102 WD7 / issue #363 — the RBS half of the reference corpus.
      #
      # A constant named only from the project's own `sig/` is genuinely referenced, which is why signatures
      # are read at all: the #345 probe reported such constants as false candidates until an RBS-side hook was
      # added. But a signature file also DECLARES, and the two must not be confused.
      #
      # The first implementation scanned each file for constant-shaped tokens, which cannot tell the
      # difference. With `rbs-inline`-generated signatures — where every project class has a mirror
      # declaration under `sig/` — that made a large fraction of the project unconditionally reachable: on one
      # application 48 of 101 roots came from `sig/`, hiding seven candidates and ten test-only rows. Over-supply
      # is the worse direction (an under-supplied root leaves a row where a human can see it; an over-supplied
      # one removes it where nobody will), so this parses instead.
      #
      # The rule: a declaration's own name is a DECLARATION and contributes nothing. Every type name appearing
      # in a POSITION — a superclass, a mixin argument, a parameter or return type, a constant's type, a type
      # alias body, a generic argument — is a reference and counts.
      module SignatureScan
        module_function

        # @param file [String] path to a `.rbs` file.
        # @return [Array<Scan::Reference>] one file-level reference per distinct referenced name. Empty when the
        #   file cannot be read or parsed — a broken signature is the analyzer's business, not this scan's.
        def call(file)
          _, _, decls = ::RBS::Parser.parse_signature(::RBS::Buffer.new(name: file, content: File.read(file)))
          found = []
          decls.each { |decl| walk(decl, [], found) }
          found.uniq.map do |name, nesting|
            Scan::Reference.new(as_written: name, nesting: nesting, from: nil, role: :config, path: file,
                                line: 1)
          end
        rescue ::RBS::BaseError, SystemCallError, ArgumentError
          []
        end

        # Walks a declaration, threading the lexical nesting so a name written relative to an enclosing module
        # resolves the way the graph's own candidate walk expects. Without this, `module A; class B < C; end`
        # would contribute a bare `C` that resolves against nothing.
        def walk(node, nesting, out)
          case node
          when ::RBS::AST::Declarations::Class then walk_class(node, nesting, out)
          when ::RBS::AST::Declarations::Module then walk_module(node, nesting, out)
          when ::RBS::AST::Declarations::Interface
            descend(node, nesting + segments(node.name), out)
          when ::RBS::AST::Members::Include, ::RBS::AST::Members::Extend, ::RBS::AST::Members::Prepend
            record(node.name, nesting, out)
            node.args&.each { |arg| collect_types(arg, nesting, out) }
          when ::RBS::AST::Members::MethodDefinition
            node.overloads.each { |overload| collect_types(overload.method_type, nesting, out) }
          when *TYPED_NODES
            collect_types(node.type, nesting, out)
          end
        end

        # Nodes whose whole contribution is the type they carry: a constant's or alias's right-hand side, and
        # the attribute / variable families.
        TYPED_NODES = [
          ::RBS::AST::Declarations::Constant, ::RBS::AST::Declarations::TypeAlias,
          ::RBS::AST::Members::AttrReader, ::RBS::AST::Members::AttrWriter,
          ::RBS::AST::Members::AttrAccessor, ::RBS::AST::Members::InstanceVariable,
          ::RBS::AST::Members::ClassInstanceVariable, ::RBS::AST::Members::ClassVariable
        ].freeze

        def walk_class(node, nesting, out)
          record(node.super_class&.name, nesting, out)
          node.super_class&.args&.each { |arg| collect_types(arg, nesting, out) }
          descend(node, nesting + segments(node.name), out)
        end

        def walk_module(node, nesting, out)
          node.self_types&.each { |self_type| record(self_type.name, nesting, out) }
          descend(node, nesting + segments(node.name), out)
        end

        def descend(node, nesting, out)
          node.members&.each { |member| walk(member, nesting, out) }
        end

        # Every `RBS::TypeName` reachable from a type, found reflectively. RBS's type zoo is wide (unions,
        # intersections, tuples, records, optionals, procs, generics) and grows between releases; enumerating
        # the classes would silently drop references the day a new one lands, and dropping a reference here
        # manufactures a false candidate.
        def collect_types(type, nesting, out)
          return if type.nil?

          record(type.name, nesting, out) if type.respond_to?(:name) && type.name.is_a?(::RBS::TypeName)
          type.instance_variables.each do |ivar|
            value = type.instance_variable_get(ivar)
            case value
            when ::RBS::TypeName then record(value, nesting, out)
            when Array then value.each { |v| collect_types(v, nesting, out) }
            when Hash then value.each_value { |v| collect_types(v, nesting, out) }
            else collect_types(value, nesting, out) if value.respond_to?(:instance_variables)
            end
          end
        end

        # Records the name AS WRITTEN together with the nesting it was written under, and lets
        # {Graph#resolve} do the lexical walk — the same walk it does for a name read out of Ruby source.
        #
        # An earlier version hand-built the qualified form instead (`"#{nesting}::#{bare}"`) on the reasoning
        # that over-approximating which of absolute / relative / top-level a name is could only fail to remove
        # a candidate. That was wrong, and it resurrected the very defect #363 fixed. `include Alba::Resource`
        # inside `class SignageResource` produced `SignageResource::Alba::Resource`; the graph resolves a
        # reference to a member as a reference to its owner, so it peeled that to `SignageResource::Alba` and
        # then to `SignageResource` — a declaration. The reference is file-level, so the class rooted ITSELF,
        # and three genuinely dead classes stayed out of the report on the project where this was found.
        #
        # Passing the real nesting cannot do that: the walk tries the qualified candidate, misses, and the peel
        # then applies to the written name alone.
        def record(type_name, nesting, out)
          return if type_name.nil?

          bare = type_name.to_s.delete_prefix("::")
          return if bare.empty?

          out << [bare, nesting.dup.freeze]
        end

        def segments(type_name)
          type_name.to_s.delete_prefix("::").split("::")
        end
      end
    end
  end
end
