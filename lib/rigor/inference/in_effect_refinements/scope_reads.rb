# frozen_string_literal: true

module Rigor
  module Inference
    class InEffectRefinements
      # Issue #1673 — the answers that need the project as well as the file: a `using`'s include expansion, the
      # refining modules of a name, and the typer's entry ({Scope#in_effect_refinements}). Each records the
      # dependencies its answer reads (ADR-46), so a warm run answers as a cold one.
      module ScopeReads
        # The in-effect refinements at `node` as {Scope#in_effect_refinements} answers them: the file's list from
        # the query `Inference::ScopeIndexer` stamps on the discovery index, each `using` expanded through
        # {.activated_modules}, then `declared`. A scope no index stamped answers `declared` alone.
        def for_node(scope, node, declared = EMPTY)
          query = scope.discovery.in_effect_refinements
          return query.for_node(node, declared) { |name| activated_modules(scope, name) } if query

          declared.empty? ? EMPTY : declared.uniq.freeze
        end

        # Issue #1671 — the modules whose refinements `using name` puts in effect, in activation order: the project
        # modules on `name`'s instance-side `Scope::ResolutionChain` (what a module includes and prepends,
        # transitively) in reverse ancestor order, each at its first position, so the module's own refinements
        # follow its includes and a module it prepends follows it and wins. CRuby's `using_module_recursive` walks
        # `RCLASS_SUPER` to its end before each link, and a prepended module sits above the module's origin. `name`
        # itself goes last when the chain does not list it. Nil, read as "any module may be in effect", when the
        # chain may hold a module it does not list: it was cut at its limit, or a module on it records a mixin the
        # tables cannot name.
        #
        # ADR-46 — the answer reads include edges declared in other files, so it depends on every file that
        # declares a module on the chain, and on the existence of each one's name: a new file reopening `name`, or
        # declaring an included module the project did not declare before, re-checks the consumer through
        # `class:<name>`.
        def activated_modules(scope, name)
          chain = Scope::ResolutionChain.for(scope, name, :instance, :constants)
          record_chain(scope, name, chain) if Analysis::DependencyRecorder.active?
          return nil if chain.truncated? || chain.wildcard_mixin?

          modules = chain.entries.reverse_each.filter_map { |entry| entry.name unless entry.external? }.uniq
          modules.include?(name) ? modules : modules << name
        end

        # Issue #1120 — every module that refines `method_name` into `class_name` or one of its ancestors (a
        # refinement of `Object` reaches a `String` receiver), or nil when none does. The table is empty on a
        # project that refines nothing, which answers without a lookup.
        #
        # ADR-46 — the answer is a function of every refinement of this name in the project, so the consumer
        # depends on the name whichever way it answers; a refine body edited in another file must re-check it
        # (`IncrementalSession#refinement_affected`).
        def refining_modules(scope, class_name, method_name)
          Analysis::DependencyRecorder.read_name(:refinement, method_name) if Analysis::DependencyRecorder.active?
          refinements = scope.discovered_refinements
          return nil if refinements.empty?

          modules = nil
          refinements.each do |refined, methods|
            names = methods[method_name]
            next if names.nil? || !refined_receiver_class?(scope, class_name, refined)

            (modules ||= []).concat(names)
          end
          modules
        end

        private

        def refined_receiver_class?(scope, class_name, refined)
          return true if class_name == refined

          environment = scope.environment
          !environment.nil? && environment.class_ordering(class_name, refined) == :subclass
        end

        def record_chain(scope, name, chain)
          chain.record(scope)
          Analysis::DependencyRecorder.read_last_segment(:class, name)
          chain.entries.each do |entry|
            if entry.external?
              entry.candidates.each { |candidate| Analysis::DependencyRecorder.read_last_segment(:class, candidate) }
            else
              Analysis::DependencyRecorder.read_missing(:class, entry.last_segment)
            end
          end
        end
      end
    end
  end
end
