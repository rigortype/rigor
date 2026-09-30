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
    # Only PROJECT ancestors appear: an as-written name that resolves to no discovered class or module
    # is an external entry on the chain and contributes nothing here, so a `class Foo <
    # ActiveRecord::Base` adds no candidate and a constant owned by an RBS-known ancestor still resolves
    # only if the bare name reaches it at step 3. That gap is deliberate for this slice: widening to the
    # RBS ancestor graph is a separate question with its own FP surface.
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
      verdict = chain.settle(scope, owner) do |retro|
        first_ancestor_hit(constant_scopes_of(retro, class_name), &)&.first
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

      Scope::ResolutionChain.for(scope, class_name.to_s, :instance, :constants).record(scope)
      worlds
    end
    private_class_method :recorded_ancestor_constant_scopes

    # Reads the chain whole, so a recording run files every class on it (a no-op otherwise).
    def compute_ancestor_constant_scopes(class_name, scope)
      chain = Scope::ResolutionChain.for(scope, class_name.to_s, :instance, :constants)
      chain.record(scope)
      scopes = constant_scopes_of(chain, class_name)
      [scopes, chain].freeze
    end
    private_class_method :compute_ancestor_constant_scopes

    # The chain's project entries in order, each once, without `class_name` itself.
    def constant_scopes_of(chain, class_name)
      out = []
      chain.entries.each do |entry|
        name = entry.name
        out << name unless name.nil? || name == class_name || out.include?(name)
      end
      out.freeze
    end
    private_class_method :constant_scopes_of

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
