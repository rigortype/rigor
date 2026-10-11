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
          return EMPTY if declared.empty? && (query.nil? || query.empty?)
          return query.for_node(node, declared) { |name| activated_modules(scope, name) } if query

          declared.uniq.freeze
        end

        # ADR-121 WD7 — the in-effect list at `offset` of `query`'s file with no block source, each `using` expanded
        # through {.activated_modules}: what the check rules read through `Analysis::CheckRules::LexicalMethodSites`,
        # and what {.for_node} answers the typer for the same node with no declared module, so the two agree.
        def lexical_list(scope, query, offset)
          query.at(offset) { |name| activated_modules(scope, name) }
        end

        # Issue #1664 — the `def` a refine body gives `method_name` on `class_name` for the refining module
        # `module_name`, or nil where none can be read: this file's own refine body first, else one in a file that
        # declares the module (`Scope#discovered_class_sources`), parsed once a run. A gem refinement, a module a
        # `Module.new` write names in another file, or an anonymous module answer nil, which the typed arm reads as
        # an unreadable body (`Dynamic[top]`). The consumer's `refinement:<name>` edge covers an edit to that body
        # (`Incremental.changed_refinement_names`).
        def refinement_def(scope, module_name, class_name, method_name)
          refinement_def_with_query(scope, module_name, class_name, method_name).first
        end

        # {.refinement_def} as `[def_node, query]`, where `query` is the other file's {InEffectRefinements} the body was
        # found in, or nil for this file's own body (or none): the typed arm re-types a foreign body under that file's
        # in-effect refinements.
        def refinement_def_with_query(scope, module_name, class_name, method_name)
          own = scope.discovery.in_effect_refinements&.refinement_def(module_name, class_name, method_name)
          return [own, nil] if own

          (scope.discovered_class_sources[module_name] || EMPTY).each do |path|
            query = DefNodeResolver.refinement_query(path)
            found = query&.refinement_def(module_name, class_name, method_name)
            return [found, query] if found
          end
          NO_DEF
        end

        NO_DEF = [nil, nil].freeze
        private_constant :NO_DEF

        # Issue #1689 — {InEffectRefinements#class_body_refine?} on the query stamped for `scope`'s file; false where no
        # index stamped one, which keeps the call's refine-body reading.
        def class_body_refine?(scope, call_node)
          query = scope.discovery.in_effect_refinements
          !query.nil? && query.class_body_refine?(call_node)
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
        # ADR-121 WD7 — {UNDECLARED} when nothing declares `name` ({.declared_module?}), which drops it from a
        # `using`'s candidates (A1). A chain entry the project does not declare is dropped when it is a core or
        # stdlib module, which refines nothing (CRuby ships no refinements); any other enters by its spelling, which
        # {.opaque_module?} then rejects, so a module included from a gem or from a file outside the analysed paths
        # may refine anything.
        #
        # ADR-46 — the answer reads include edges declared in other files, so it depends on every file that
        # declares a module on the chain, and on the existence of each one's name: a new file reopening `name`, or
        # declaring an included module the project did not declare before, re-checks the consumer through
        # `class:<name>`.
        def activated_modules(scope, name)
          unless declared_module?(scope, name)
            Analysis::DependencyRecorder.read_last_segment(:class, name) if Analysis::DependencyRecorder.active?
            return UNDECLARED
          end

          chain = Scope::ResolutionChain.for(scope, name, :instance, :constants)
          record_chain(scope, name, chain) if Analysis::DependencyRecorder.active?
          return nil if chain.truncated? || chain.wildcard_mixin?

          modules = chain.entries.reverse_each.filter_map { |entry| activated_entry(scope, entry) }.uniq
          modules.include?(name) ? modules : modules << name
        end

        # ADR-121 WD7 (A4) — can Rigor not read every refinement of `name`, a module in an in-effect list? True when
        # the project does not declare it (a gem's module, a module required from outside the analysed paths, or
        # one only an `Object.const_set` makes), unless it is a core or stdlib module, which refines nothing; and
        # true when a targets-wildcard row (`{"*" => {"*" => [...]}}`) lists it or the wildcard, which some unreadable
        # `refine` wrote. Every reader that declines on an opaque module asks this, and nothing else. Gem modules
        # stay opaque even when the gem source walker read them.
        #
        # ADR-46 — the answer moves when a file declares or stops declaring the module (`class:<last segment>`) or
        # when a targets-wildcard row appears or vanishes (`refinement:*`).
        def opaque_module?(scope, name)
          if Analysis::DependencyRecorder.active?
            Analysis::DependencyRecorder.read_last_segment(:class, name)
            Analysis::DependencyRecorder.read_name(:refinement, WILDCARD)
          end
          unread = scope.discovered_refinements.dig(WILDCARD, WILDCARD)
          return true if unread && (unread.include?(name) || unread.include?(WILDCARD))
          return false if project_module?(scope, name)

          !core_or_stdlib_module?(scope, name)
        end

        # Does `list` (an in-effect list, the unknown marker skipped) hold an {.opaque_module?}?
        def opaque_in?(scope, list)
          list.any? { |name| name != UNKNOWN && opaque_module?(scope, name) }
        end

        # ADR-121 WD7 (A1) — does the project, RBS or an opted-in gem declare `name`? A `using`'s lexical candidates
        # that nothing declares are not the module Ruby's lookup finds, so they leave the list.
        def declared_module?(scope, name)
          return true if project_module?(scope, name)
          return true if scope.environment&.class_known?(name)

          gem_module?(scope, name)
        end

        # Issue #1120 — every module that refines `method_name` into `class_name` or one of its ancestors (a
        # refinement of `Object` reaches a `String` receiver), or nil when none does. The table is empty on a
        # project that refines nothing, which answers without a lookup.
        #
        # ADR-121 WD7 — a row the walk could not read counts too: a names-wildcard row of the class (the body may
        # define any name), and a row whose class the walk could not name ({.class_wildcard_key?}), which reaches
        # every receiver.
        #
        # ADR-46 — the answer is a function of every refinement of this name in the project, so the consumer
        # depends on the name whichever way it answers; a refine body edited in another file must re-check it
        # (`IncrementalSession#refinement_affected`). It also depends on the wildcard rows (`refinement:*`).
        def refining_modules(scope, class_name, method_name)
          record_refinement_names(method_name)
          refinements = scope.discovered_refinements
          return nil if refinements.empty?

          modules = nil
          refinements.each do |refined, methods|
            names = methods[method_name]
            unread = methods[WILDCARD]
            next if names.nil? && unread.nil?
            next unless refined_receiver_class?(scope, class_name, refined) || class_wildcard_key?(scope, refined)

            modules = (modules || []).concat(names || EMPTY, unread || EMPTY)
          end
          modules
        end

        # ADR-121 WD7 — {.refining_modules} for a receiver the class rows do not reach (a class object): only the rows
        # whose class the walk could not name ({.class_wildcard_key?}), for the name or as a names-wildcard.
        def class_unknown_refining_modules(scope, method_name)
          record_refinement_names(method_name)
          modules = nil
          scope.discovered_refinements.each do |refined, methods|
            names = methods[method_name]
            unread = methods[WILDCARD]
            next if (names.nil? && unread.nil?) || !class_wildcard_key?(scope, refined)

            modules = (modules || []).concat(names || EMPTY, unread || EMPTY)
          end
          modules
        end

        # ADR-121 WD7 (A5) — the name edges a consumer of the refinement table records: the method's, and the
        # wildcard's, so a wildcard row appearing or vanishing in another file re-checks it.
        def record_refinement_names(method_name)
          return unless Analysis::DependencyRecorder.active?

          Analysis::DependencyRecorder.read_name(:refinement, method_name)
          Analysis::DependencyRecorder.read_name(:refinement, WILDCARD)
        end

        # ADR-121 WD7 — is the refined-class key `refined` a class the walk could not name: the wildcard, or (A6) a
        # name no class declaration or RBS knows that a project constant write binds (`K = String; refine(K)`), whose
        # value is the class refined. A constant nothing binds (a gem's class with no RBS) keeps a normal row, which
        # matches no receiver.
        def class_wildcard_key?(scope, refined)
          return true if refined == WILDCARD
          return false if scope.discovered_classes.key?(refined) || scope.environment&.class_known?(refined)

          if Analysis::DependencyRecorder.active?
            Analysis::DependencyRecorder.read_last_segment(:constant, refined)
            Analysis::DependencyRecorder.read_last_segment(:class, refined)
          end
          !scope.bound_constant_names(refined).empty?
        end

        private

        WILDCARD = Scope::DiscoveryIndex::REFINEMENT_WILDCARD
        private_constant :WILDCARD

        def activated_entry(scope, entry)
          return entry.name unless entry.external?

          candidates = entry.candidates
          return nil if candidates.any? { |candidate| core_or_stdlib_module?(scope, candidate) }

          candidates.first || entry.raw
        end

        def project_module?(scope, name)
          scope.discovered_classes.key?(name) || !(scope.discovered_class_sources[name] || EMPTY).empty?
        end

        def core_or_stdlib_module?(scope, name)
          scope.environment&.rbs_loader&.core_or_stdlib_class?(name) || false
        end

        # A module an opted-in gem's source declares: one its catalogue files a method under, or one its refinement
        # rows name as a refining module.
        def gem_module?(scope, name)
          return true if scope.environment&.dependency_source_index&.gem_for(name)

          scope.discovered_refinements.each_value.any? do |methods|
            methods.each_value.any? { |modules| modules.include?(name) }
          end
        end

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
