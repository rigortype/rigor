# frozen_string_literal: true

module Rigor
  module Inference
    class InEffectRefinements
      # Issue #1664 — the `def`s one file's refine bodies define, keyed by refining module, refined class (each name
      # the `refine` argument's spelling can denote) and method, with the `Module.nesting` each is written in. The
      # last `def` of a name wins, as Ruby's method table keeps it.
      class RefineDefs
        # ADR-121 WD7 — what {#lookup} answers for a name whose last definer has no body (`define_method`, `attr_*`,
        # `undef`): the search for a body ends there, so the typed arm answers `Dynamic[top]` rather than another
        # file's `def`.
        BODILESS = :bodiless

        attr_reader :nestings

        def initialize
          @nodes = {}
          @nestings = {}.compare_by_identity
        end

        # `name` is the method `def_node` answers for: its own name, or an alias's (ADR-121 WD7). A nil `def_node` is a
        # later definer with no body (`define_method`, `attr_*`, `undef`), which replaces the earlier `def`.
        def record(owner, targets, name, def_node, nesting)
          by_class = (@nodes[owner] ||= {})
          targets.each { |class_name| (by_class[class_name] ||= {})[name] = def_node || BODILESS }
          @nestings[def_node] = nesting if def_node
        end

        def lookup(module_name, class_name, method_name) = @nodes.dig(module_name, class_name, method_name)
      end
    end
  end
end
