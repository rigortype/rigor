# frozen_string_literal: true

require "prism"

require_relative "method_signature"
require_relative "sig_parser"

module Rigor
  module Plugin
    class Sorbet < Rigor::Plugin::Base
      # Walks a parsed Prism program looking for
      # `sig { ... }` / `sig do ... end` calls that immediately
      # precede a `def` (or a `def self.foo` / `class << self;
      # def foo; end`). Each recognised pair is parsed by
      # {SigParser} and recorded in the {Catalog} under its
      # qualified `(class_name, method_name, kind)` key.
      #
      # Anything we don't recognise (a stray `sig { ... }` not
      # followed by a `def`, a `def` with no preceding `sig`,
      # malformed sig blocks, etc.) is reported back to the
      # caller through `parse_errors:` so the plugin can emit a
      # `plugin.sorbet.parse-error` diagnostic. Walking is
      # otherwise infallible — a bad sig block does not abort
      # the catalog build for the rest of the file.
      module CatalogWalker
        # Detected error during walking. `kind` is one of:
        # `:no_block` / `:empty_block` / `:missing_returns_or_void`
        # / `:duplicate_sig` / `:dangling_sig`.
        ParseError = Data.define(:kind, :node, :path)

        module_function

        # @param root [Prism::Node] the file's program node.
        # @param catalog [Catalog] mutable; signatures are
        #   recorded into it.
        # @param path [String] file path used for diagnostic
        #   provenance.
        # @return [Array<ParseError>] errors observed during the
        #   walk; empty when the file is sig-clean.
        def walk(root:, catalog:, path:)
          state = State.new(catalog: catalog, path: path)
          walk_node(root, state, lexical_path: [], in_singleton_class: false)
          state.errors
        end

        State = Struct.new(:catalog, :path, :errors, keyword_init: true) do
          def initialize(catalog:, path:)
            super(catalog: catalog, path: path, errors: [])
          end

          def record_error(kind, node)
            errors << ParseError.new(kind: kind, node: node, path: path)
          end
        end

        def walk_node(node, state, lexical_path:, in_singleton_class:)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ClassNode, Prism::ModuleNode
            descend_class_or_module(node, state, lexical_path)
          when Prism::SingletonClassNode
            descend_singleton_class(node, state, lexical_path)
          when Prism::StatementsNode
            walk_statements(node, state, lexical_path: lexical_path, in_singleton_class: in_singleton_class)
          when Prism::DefNode
            # A `def` not preceded by a `sig` is fine; we just
            # don't record anything for it. The interesting case
            # is in `walk_statements`, which pairs sig+def.
          else
            node.compact_child_nodes.each do |child|
              walk_node(child, state, lexical_path: lexical_path, in_singleton_class: in_singleton_class)
            end
          end
        end

        def descend_class_or_module(node, state, lexical_path)
          name = qualified_name_for(node.constant_path)
          if name && node.body
            child_prefix = lexical_path + [name]
            walk_node(node.body, state, lexical_path: child_prefix, in_singleton_class: false)
          elsif node.body
            walk_node(node.body, state, lexical_path: lexical_path, in_singleton_class: false)
          end
        end

        def descend_singleton_class(node, state, lexical_path)
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_node(node.body, state, lexical_path: lexical_path, in_singleton_class: true)
          elsif node.body
            walk_node(node.body, state, lexical_path: lexical_path, in_singleton_class: false)
          end
        end

        # The pair-finding loop. Walks a `StatementsNode`'s
        # children left-to-right; when it encounters a `sig`
        # call, it remembers it and consumes the very next
        # `def` / `def self.foo` as the target. Anything between
        # a sig and its def (a comment is fine — comments aren't
        # AST nodes — but a method call would be a problem)
        # leaves the sig dangling.
        def walk_statements(statements, state, lexical_path:, in_singleton_class:)
          pending_sig = nil

          statements.body.each do |child|
            if pending_sig && def_node?(child)
              record_def_with_sig(child, pending_sig, state, lexical_path, in_singleton_class)
              pending_sig = nil
            elsif sig_call?(child)
              state.record_error(:duplicate_sig, pending_sig) if pending_sig
              pending_sig = child
            else
              if pending_sig
                state.record_error(:dangling_sig, pending_sig)
                pending_sig = nil
              end
              walk_node(child, state, lexical_path: lexical_path, in_singleton_class: in_singleton_class)
            end
          end

          state.record_error(:dangling_sig, pending_sig) if pending_sig
        end

        def sig_call?(node)
          node.is_a?(Prism::CallNode) &&
            node.name == :sig &&
            node.receiver.nil? &&
            !node.block.nil?
        end

        def def_node?(node)
          node.is_a?(Prism::DefNode)
        end

        def record_def_with_sig(def_node, sig_call, state, lexical_path, in_singleton_class)
          parsed = SigParser.parse(sig_call)
          if parsed.is_a?(SigParser::ParseError)
            state.record_error(parsed.reason, sig_call)
            return
          end

          class_name = lexical_path.empty? ? "Object" : lexical_path.join("::")
          kind = singleton_method?(def_node, in_singleton_class) ? :singleton : :instance
          catalog_record(state.catalog, class_name, def_node.name, kind, parsed)
        end

        def catalog_record(catalog, class_name, method_name, kind, parsed)
          catalog.record(
            MethodSignature.new(
              class_name: class_name,
              method_name: method_name,
              kind: kind,
              params: parsed.params,
              return_type: parsed.return_type,
              modifiers: parsed.modifiers
            )
          )
        end

        def singleton_method?(def_node, in_singleton_class)
          in_singleton_class || def_node.receiver.is_a?(Prism::SelfNode)
        end

        # Resolves a constant-path node (`Foo::Bar`,
        # `::Foo::Bar`) to its dot-separated name. Returns nil
        # for the rare dynamic-prefix shape so the walker
        # doesn't guess a qualified name in that case.
        def qualified_name_for(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil then "::#{parts.join('::')}"
            when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
            end
          end
        end
      end
    end
  end
end
