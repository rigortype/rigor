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
    # A leading `::` (absolute root, `::Foo`) renders as `"Foo"` under both policies: the discovered-constant
    # tables are keyed by un-rooted names, so a rendered `"::Foo"` would miss every one of them. The root
    # marker is therefore carried OUT OF BAND by {.rooted?}, which a caller performing Ruby's lexical constant
    # lookup MUST consult — `::Foo` names the top-level `Foo` and never a lexically nearer shadow
    # ([#614](https://github.com/rigortype/rigor/issues/614)). A node that is neither a `ConstantReadNode`
    # nor a `ConstantPathNode` yields `nil` under both policies.
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

      # True when the reference is written with a leading `::` — `::Foo`, `::Foo::Bar`. Prism spells the
      # root as a `ConstantPathNode` with a nil `parent`, so the answer lives at the LEFTMOST segment of the
      # chain and the walk has to reach it: `::Foo::Bar` is a path node whose parent is itself a path node.
      # A `ConstantReadNode` is a bare name and is never rooted; a dynamic base (`expr::Bar`) is not a root
      # either, so the recursion stops at any non-constant parent.
      def rooted?(node)
        return false unless node.is_a?(Prism::ConstantPathNode)

        parent = node.parent
        return true if parent.nil?

        rooted?(parent)
      end
    end
  end
end
