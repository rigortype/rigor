# frozen_string_literal: true

module Rigor
  module Source
    # Flattens a Prism constant-reference node (`ConstantReadNode` / `ConstantPathNode`) to its
    # source-qualified `"A::B::C"` string.
    #
    # Two nil policies for the one edge case that distinguishes the call sites — a constant path rooted in a
    # *dynamic* base (`expr::Bar`, where the left side is a runtime expression rather than a constant):
    #
    # * {.qualified_name} / {.render} are LENIENT — they drop the dynamic segment and render the trailing
    #   constant names (`expr::Bar` => "Bar"). The scope indexer and statement evaluator feed only genuine
    #   class/module path nodes and want a best-effort name.
    # * {.qualified_name_or_nil} is STRICT — a dynamic base anywhere in the chain yields `nil`, so a caller
    #   that statically names constants can treat the path as opaque rather than guessing.
    #
    # A leading `::` (absolute root, `::Foo`) renders as `"Foo"` under both policies. A node that is neither
    # a `ConstantReadNode` nor a `ConstantPathNode` yields `nil` under both.
    module ConstantPath
      module_function

      # Lenient dispatch over a constant-reference node.
      def qualified_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then render(node)
        end
      end

      # Lenient render of a `ConstantPathNode`; never nil for a path node.
      def render(node)
        prefix =
          case node.parent
          when Prism::ConstantReadNode then "#{node.parent.name}::"
          when Prism::ConstantPathNode then "#{render(node.parent)}::"
          else ""
          end
        "#{prefix}#{node.name}"
      end

      # Strict dispatch: a dynamic base anywhere in the path yields nil.
      def qualified_name_or_nil(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent
          return node.name.to_s if parent.nil?

          parent_name = qualified_name_or_nil(parent)
          return nil if parent_name.nil?

          "#{parent_name}::#{node.name}"
        end
      end
    end
  end
end
