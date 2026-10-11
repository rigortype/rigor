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
        # Issue #1749 — what {#lookup} answers for a name whose refinement the walk cannot attribute: one from a
        # `refine` that runs inside a method (it exists once the method has run, replacing what a refine body wrote for
        # the name, or adding nothing if it never runs, and `using` sees it only if it runs first), or from an eval on
        # a constant that several names denote (it runs on one of them, which another file decides, and replaces or is
        # replaced by a `def` of the name in a refine body of the module, whichever runs first). A `def` of the name
        # in a module-body refine, in this file or another, cannot say which one answers, so the name is never typed
        # from any body: the lookup ends there across every file that declares the module, and unlike {BODILESS} a
        # later record does not replace it.
        UNDECIDED = :undecided

        attr_reader :nestings

        def initialize
          @nodes = {}
          @nestings = {}.compare_by_identity
        end

        # `owners` are the refining modules (several where an eval on a constant may run on any of its names), each
        # filed under every class of `targets`. `name` is the method `def_node` answers for: its own name, or an
        # alias's (ADR-121 WD7). A nil `def_node` is a later definer with no body (`define_method`, `attr_*`, `undef`),
        # which replaces the earlier `def`. A name whose refinement the walk cannot attribute keeps no body and is
        # {UNDECIDED}: several owners (Ruby runs the body on one of them only), or `created`, true for a `refine` that
        # runs inside a method.
        def record(owners, targets, name, def_node, nesting, created: false)
          undecided = created || owners.size > 1
          def_node = nil if undecided
          owners.each do |owner|
            by_class = (@nodes[owner] ||= {})
            targets.each do |class_name|
              by_name = (by_class[class_name] ||= {})
              by_name[name] = undecided ? UNDECIDED : (def_node || BODILESS) unless by_name[name] == UNDECIDED
            end
          end
          @nestings[def_node] = nesting if def_node
        end

        def lookup(module_name, class_name, method_name) = @nodes.dig(module_name, class_name, method_name)
      end
    end
  end
end
