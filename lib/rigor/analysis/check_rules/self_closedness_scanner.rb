# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      # ADR-24 slice 4 — read-side companion to `call.self-undefined-method`.
      # Walks a file's parse tree once and collects the qualified names of
      # declarations that are NOT confidently closed for self-call
      # undefined-method analysis, so the rule can exclude them:
      #
      # - **Modules** — a `module M` is a mixin contract; its methods may be
      #   provided by includers (template-method pattern), so an unresolved
      #   self-call inside it is not provably a typo.
      # - **Classes with a dynamic `attr_*` accessor** — `attr_reader(*NAMES)`
      #   / `attr_accessor(:a, SOME_CONST)` synthesizes readers whose names
      #   are not statically decidable, so the class's method surface cannot
      #   be enumerated from source.
      #
      # The enclosing declaration of a self-call is always in the same file
      # as the call (even a reopened class restates `class Foo`), so a
      # per-file AST scan suffices — no cross-file plumbing. Names are built
      # to match the engine's qualified `self` type (`Module.nesting`-style
      # `A::B::C`).
      class SelfClosednessScanner
        ATTR_MACROS = %i[attr_reader attr_accessor attr_writer].freeze
        private_constant :ATTR_MACROS

        def initialize(root)
          @root = root
        end

        # @return [Set<String>] qualified names to exclude from the rule.
        def open_class_names
          names = Set.new
          walk(@root, [], names)
          names
        end

        private

        def walk(node, prefix, names)
          return unless node.is_a?(Prism::Node)

          case node
          when Prism::ModuleNode
            name = constant_path_name(node.constant_path)
            child_prefix = name ? prefix + [name] : prefix
            names << child_prefix.join("::") if name
            walk(node.body, child_prefix, names) if node.body
          when Prism::ClassNode
            name = constant_path_name(node.constant_path)
            child_prefix = name ? prefix + [name] : prefix
            names << child_prefix.join("::") if name && dynamic_attr_class?(node)
            walk(node.body, child_prefix, names) if node.body
          else
            node.compact_child_nodes.each { |child| walk(child, prefix, names) }
          end
        end

        # True when the class body directly invokes an `attr_*` macro with a
        # non-literal argument (a splat, a constant, a method call) — the
        # synthesized accessor names are then not statically knowable.
        def dynamic_attr_class?(class_node)
          body = class_node.body
          return false unless body.is_a?(Prism::StatementsNode)

          body.body.any? do |stmt|
            stmt.is_a?(Prism::CallNode) &&
              stmt.receiver.nil? &&
              ATTR_MACROS.include?(stmt.name) &&
              dynamic_attr_arguments?(stmt)
          end
        end

        def dynamic_attr_arguments?(call_node)
          args = call_node.arguments&.arguments
          return false if args.nil? || args.empty?

          args.any? { |arg| !arg.is_a?(Prism::SymbolNode) && !arg.is_a?(Prism::StringNode) }
        end

        # Renders a class/module path node to its source-qualified name
        # (`Foo`, `Foo::Bar`, leading `::` stripped); nil for a dynamic
        # constant path the scanner cannot name statically.
        def constant_path_name(node)
          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            parent = node.parent ? constant_path_name(node.parent) : nil
            child = node.name.to_s
            node.parent.nil? ? child : (parent && "#{parent}::#{child}")
          end
        end
      end
    end
  end
end
