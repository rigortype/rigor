# frozen_string_literal: true

module Rigor
  module Inference
    class InEffectRefinements
      # Issue #1664 — the `def`s one file's refine bodies define, keyed by refining module, refined class (each name
      # the `refine` argument's spelling can denote) and method, with the `Module.nesting` each is written in. The
      # last `def` of a name wins, as Ruby's method table keeps it.
      class RefineDefs
        attr_reader :nestings

        def initialize
          @nodes = {}
          @nestings = {}.compare_by_identity
        end

        def record(owner, targets, def_node, nesting)
          by_class = (@nodes[owner] ||= {})
          targets.each { |class_name| (by_class[class_name] ||= {})[def_node.name] = def_node }
          @nestings[def_node] = nesting
        end

        def lookup(module_name, class_name, method_name) = @nodes.dig(module_name, class_name, method_name)

        # The table of a file that refines nothing.
        EMPTY = new.freeze
      end
    end
  end
end
