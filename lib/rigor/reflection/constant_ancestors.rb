# frozen_string_literal: true

module Rigor
  # {Reflection}'s constant-ancestor walk ([#354](https://github.com/rigortype/rigor/issues/354)), split out for
  # the reader rather than for the loader: the whole-spelling ladder's step 2 (`reflection.rb`) and the
  # segment-wise path walk (`reflection/constant_path.rb`) both ask which project classes and modules a
  # name's owner inherits constants from, and this file answers that once for both. Reopening the module
  # keeps the walk behind the facade its callers already read.
  module Reflection
    # #354 — thread-local slot for the per-run ancestor-scope memo. See {.ancestor_constant_scopes}.
    ANCESTOR_SCOPES_KEY = :__rigor_ancestor_constant_scopes__
    private_constant :ANCESTOR_SCOPES_KEY

    # The recording run's slot. See {.recorded_ancestor_constant_scopes}.
    RECORDED_ANCESTOR_SCOPES_KEY = :__rigor_recorded_ancestor_constant_scopes__
    private_constant :RECORDED_ANCESTOR_SCOPES_KEY

    module_function

    # #354 — the project classes and modules whose own constants `class_name` inherits, in Ruby's
    # ancestor order: the entries of `class_name`'s `Scope::ResolutionChain` — prepended modules, then
    # included ones, then the superclass's chain likewise — each once. `class_name` itself is excluded:
    # step 1 already covered it.
    #
    # Issue #1571 — this was a breadth-first walk of its own, which is not Ruby's order: `class C < Base;
    # include A` with `A` including `M` reached `Base::X` (depth 1) before `M::X` (depth 2), while Ruby's
    # ancestors are `[C, A, M, Base]`. It reads the chain's `:constants` flavor, whose predicate for a
    # project class also admits a module that holds only constants.
    #
    # Project ancestors appear, and (issue #1698) a module the class body `include`s or `prepend`s that
    # only RBS or the class registry declares: `include AcLibraryRb` puts `AcLibraryRb` at its Ruby
    # position, so `Segtree` inside the class reads `AcLibraryRb::Segtree` as Ruby does. Such an entry
    # contributes its OWN constants only; the RBS ancestry behind it is not expanded, as for every external
    # entry. An external SUPERCLASS (`class Foo < ActiveRecord::Base`) still contributes nothing, and a
    # constant it owns resolves only if the bare name reaches it at step 3: widening to the superclass's
    # RBS graph is a separate question with its own FP surface. See {.external_constant_owner}.
    #
    # Memoised per run because step 2 runs on every constant reference whose lexical candidates all
    # miss — which is the common case for a core-class reference (`String` inside `class Foo`). The
    # bucket keys on the identity of the runner-seeded run-generation token (ADR-84 WD2), falling
    # back to the per-file discovery table for runner-less scopes, so a re-run in one process (LSP,
    # ADR-62 warm loop) cannot hit stale entries.
    def ancestor_constant_scopes(class_name, scope)
      ancestor_constant_worlds(class_name, scope).first
    end
    private_class_method :ancestor_constant_scopes

    # ADR-24 / #1570 — the first ancestor that owns a constant, asked as {.ancestor_constant_scopes} orders
    # them and settled by `Scope::ResolutionChain#settle`: the block's first truthy answer where the chain
    # stands, and otherwise the answer of the breadth-first order this rung used before the chain
    # (`Scope::ResolutionChain::MasterOrder`) — where a skipped `include` would put a different owner first,
    # which constant Ruby reads depends on the order the bodies ran.
    def agreed_ancestor_hit(class_name, scope, &)
      scopes, chain = ancestor_constant_worlds(class_name, scope)
      owner, hit = first_ancestor_hit(scopes, &)
      verdict = chain.settle(scope, owner, owner: owner) do |retro|
        first_ancestor_hit(constant_scopes_of(retro, class_name, scope), &)&.first
      end
      return hit if verdict == :chain

      first_ancestor_hit(master_constant_scopes(class_name, scope), &)&.last
    end
    private_class_method :agreed_ancestor_hit

    def master_constant_scopes(class_name, scope)
      Scope::ResolutionChain::MasterOrder.breadth_first(scope, class_name.to_s, :constants)
    end
    private_class_method :master_constant_scopes

    def first_ancestor_hit(entries)
      entries.each do |entry|
        hit = yield entry
        return [entry, hit] if hit
      end
      nil
    end
    private_class_method :first_ancestor_hit

    # `[scopes, chain]` — {.ancestor_constant_scopes} and the chain they were read from, which settles the
    # answer.
    def ancestor_constant_worlds(class_name, scope)
      # ADR-46: the answer depends on every class on the chain, and the memo is run-scoped rather than
      # file-scoped — a hit would skip the recording and under-record the edge for every later file. A
      # recording run reads the chain, which is memoised per discovery index, and files its edges on
      # every call.
      return recorded_ancestor_constant_scopes(class_name, scope) if Analysis::DependencyRecorder.active?

      generation = scope.run_generation || scope.discovered_superclasses
      slot = Thread.current[ANCESTOR_SCOPES_KEY]
      unless slot && slot[0].equal?(generation)
        slot = [generation, {}]
        Thread.current[ANCESTOR_SCOPES_KEY] = slot
      end
      bucket = slot[1]
      bucket.fetch(class_name) { bucket[class_name] = compute_ancestor_constant_scopes(class_name, scope) }
    end
    private_class_method :ancestor_constant_worlds

    # The recording run's memo. The answer is every project entry of the chain, so its edges are the
    # root's and every entry's — what `Scope::ResolutionChain#record` files, which a computation does and a
    # hit replays, in the same order. One slot keyed on the discovery index: the answer and the edges are
    # both read from it, so the key is exact, and the slot never pins more than the index it serves.
    def recorded_ancestor_constant_scopes(class_name, scope)
      discovery = scope.discovery
      slot = Thread.current[RECORDED_ANCESTOR_SCOPES_KEY]
      unless slot && slot[0].equal?(discovery)
        slot = [discovery, {}]
        Thread.current[RECORDED_ANCESTOR_SCOPES_KEY] = slot
      end
      bucket = slot[1]
      worlds = bucket[class_name]
      return bucket[class_name] = compute_ancestor_constant_scopes(class_name, scope) if worlds.nil?

      chain = Scope::ResolutionChain.for(scope, class_name.to_s, :instance, :constants)
      chain.record(scope)
      record_external_owner_edges(chain)
      worlds
    end
    private_class_method :recorded_ancestor_constant_scopes

    # Reads the chain whole, so a recording run files every class on it (a no-op otherwise).
    def compute_ancestor_constant_scopes(class_name, scope)
      chain = Scope::ResolutionChain.for(scope, class_name.to_s, :instance, :constants)
      chain.record(scope)
      record_external_owner_edges(chain)
      scopes = constant_scopes_of(chain, class_name, scope)
      [scopes, chain].freeze
    end
    private_class_method :compute_ancestor_constant_scopes

    # The chain's project entries in order, each once, without `class_name` itself, with each mixin entry
    # the project does not declare standing as the module {.external_constant_owner} names.
    def constant_scopes_of(chain, class_name, scope)
      out = []
      chain.entries.each do |entry|
        name = entry.external? ? external_constant_owner(entry, scope) : entry.name
        out << name unless name.nil? || name == class_name || out.include?(name)
      end
      out.freeze
    end
    private_class_method :constant_scopes_of

    # Issue #1698 — the module an external `include` / `prepend` entry names, when the constant ladder may
    # read its constants, or nil. Ruby resolved the spelling at the `include` lexically, so the first of the
    # entry's candidates (most qualified first) that exists is the module. The answer is the first candidate
    # RBS or the class registry knows, and nil when a nearer candidate is a constant the project binds
    # ({.project_written_candidate?}): Ruby's module is then that constant, whose constants nothing here
    # describes. The candidates are the entry's own, behind the namespace of the body that wrote the edge
    # (`entry.owner`), which Ruby searches first and the chain's resolver does not consult. An ambiguous
    # spelling has no candidates and answers nil. A superclass edge answers nil (see
    # {.ancestor_constant_scopes}).
    def external_constant_owner(entry, scope)
      return nil if entry.superclass_edge || entry.candidates.empty?

      env = scope.environment
      external_owner_candidates(entry).each do |candidate|
        return nil if project_written_candidate?(candidate, scope)
        return candidate if env.class_known?(candidate)
      end
      nil
    end
    private_class_method :external_constant_owner

    def external_owner_candidates(entry)
      return entry.candidates if entry.owner.nil? || entry.raw.start_with?("::")

      ["#{entry.owner}::#{entry.raw}", *entry.candidates]
    end
    private_class_method :external_owner_candidates

    # ADR-46 — the name edges of {.external_constant_owner}'s guard, for every mixin entry it read: a file that
    # starts writing or declaring a nearer spelling of the module's name (`User::AcLibraryRb = …` in a file the
    # reader has no other edge to) moves the answer. Keyed on the spelling's last segment, as the ladder's own
    # `constant:` and `class:` edges are. A memo hit replays them beside the chain's own edges.
    def record_external_owner_edges(chain)
      return unless Analysis::DependencyRecorder.active?

      chain.entries.each do |entry|
        next unless entry.external? && !entry.superclass_edge

        Analysis::DependencyRecorder.read_last_segment(:constant, entry.raw)
        Analysis::DependencyRecorder.read_last_segment(:class, entry.raw)
      end
    end
    private_class_method :record_external_owner_edges

    # Issue #1698 — whether the walk must stop at the RBS-only mixin `owner` because a module its own RBS ancestry
    # holds may own the name (`candidate` answers for some ancestor after `owner` itself), or because that
    # ancestry cannot be read. Ruby searches the mixin's ancestry right after it, before any later entry of the
    # chain and before the top level, and the chain does not expand it, so a later answer would be a guess.
    # Where no module of the ancestry owns the name, where they sit does not matter to this name and the walk
    # goes on.
    def external_mixin_ancestry_stop?(owner, scope)
      loader = rbs_loader_for(scope, nil)
      ancestors = loader ? loader.ancestor_names_for(owner) : []
      return true if ancestors.empty?

      ancestors.any? { |ancestor| ancestor != owner && yield(ancestor) }
    end
    private_class_method :external_mixin_ancestry_stop?

    # Whether the project binds `candidate` itself: a namespace under the `:constants` flavor's tables, or a
    # constant write the census records (#1290), typed or not.
    def project_written_candidate?(candidate, scope)
      known_project_namespace?(candidate, scope) || scope.shadowing_constant_names(candidate).include?(candidate)
    end
    private_class_method :project_written_candidate?

    # Whether `name` is a namespace the project declares — the predicate the chain's `:constants` flavor
    # resolves ancestor names with, and the path walk's (`reflection/constant_path.rb`) test for a head.
    def known_project_namespace?(name, scope)
      scope.discovered_superclasses.key?(name) ||
        scope.discovered_includes.key?(name) ||
        scope.discovered_classes.key?(name)
    end
    private_class_method :known_project_namespace?
  end
end
