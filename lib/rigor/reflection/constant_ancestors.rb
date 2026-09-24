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

    module_function

    # #354 — the project classes and modules whose own constants `class_name` inherits, in Ruby's
    # ancestor order: included / prepended modules before the superclass (Ruby places mixins nearer),
    # transitively, breadth-first. `class_name` itself is excluded — step 1 already covered it.
    #
    # Only PROJECT ancestors appear. `Scope#superclass_of` / `#includes_of` carry as-written names
    # from the discovery pre-pass, and an as-written name that resolves to no discovered class or
    # module is dropped — so a `class Foo < ActiveRecord::Base` contributes nothing and a constant
    # owned by an RBS-known ancestor still resolves only if the bare name reaches it at step 3. That
    # gap is deliberate for this slice: widening to the RBS ancestor graph is a separate question
    # with its own FP surface.
    #
    # Memoised per run because step 2 runs on every constant reference whose lexical candidates all
    # miss — which is the common case for a core-class reference (`String` inside `class Foo`). The
    # bucket keys on the identity of the runner-seeded run-generation token (ADR-84 WD2), falling
    # back to the per-file discovery table for runner-less scopes, so a re-run in one process (LSP,
    # ADR-62 warm loop) cannot hit stale entries.
    def ancestor_constant_scopes(class_name, scope)
      # ADR-46: `superclass_of` / `includes_of` record a cross-file class dependency per consumer
      # file, and the memo is run-scoped rather than file-scoped — a hit would skip the recording and
      # under-record the edge for every later file. Recording runs are rare (incremental only), so
      # they simply bypass the memo rather than complicate its key.
      return compute_ancestor_constant_scopes(class_name, scope) if Analysis::DependencyRecorder.active?

      generation = scope.run_generation || scope.discovered_superclasses
      slot = Thread.current[ANCESTOR_SCOPES_KEY]
      unless slot && slot[0].equal?(generation)
        slot = [generation, {}]
        Thread.current[ANCESTOR_SCOPES_KEY] = slot
      end
      bucket = slot[1]
      bucket.fetch(class_name) { bucket[class_name] = compute_ancestor_constant_scopes(class_name, scope) }
    end
    private_class_method :ancestor_constant_scopes

    def compute_ancestor_constant_scopes(class_name, scope)
      queue = [class_name]
      seen = { class_name => true }
      out = []
      until queue.empty?
        current = queue.shift
        # Mixins first, then the superclass — Ruby's ancestor order.
        scope.includes_of(current).each do |raw|
          resolved = resolve_ancestor_name(current, raw, scope)
          next if resolved.nil? || seen[resolved]

          seen[resolved] = true
          out << resolved
          queue << resolved
        end
        raw_super = scope.superclass_of(current)
        next if raw_super.nil?

        resolved_super = resolve_ancestor_name(current, raw_super, scope)
        next if resolved_super.nil? || seen[resolved_super]

        seen[resolved_super] = true
        out << resolved_super
        queue << resolved_super
      end
      out.freeze
    end
    private_class_method :compute_ancestor_constant_scopes

    # Resolves an ancestor name AS WRITTEN (`"Base"`, or a qualified `"A::B"`) against the nesting in
    # force where the subclass's header is written — `Scope#ancestor_name_candidates`, the single
    # owner of that order, which `Scope#enqueue_ancestors` reads for method lookup and the
    # override-visibility rule reads for its own walk. Returns nil when no candidate names a
    # discovered project class or module.
    def resolve_ancestor_name(subclass_qualified, raw, scope)
      scope.ancestor_name_candidates(subclass_qualified, raw)
           .find { |candidate| known_project_namespace?(candidate, scope) }
    end
    private_class_method :resolve_ancestor_name

    def known_project_namespace?(name, scope)
      scope.discovered_superclasses.key?(name) ||
        scope.discovered_includes.key?(name) ||
        scope.discovered_classes.key?(name)
    end
    private_class_method :known_project_namespace?
  end
end
