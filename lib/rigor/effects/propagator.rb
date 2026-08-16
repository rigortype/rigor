# frozen_string_literal: true

require_relative "effect_table"
require_relative "file_collection"

module Rigor
  module Effects
    # Closes a run's collected summaries over the call graph (ADR-103 WD12).
    #
    # Two jobs, in order:
    #
    # 1. **Resolve edges.** The collector records a call as `(receiver class, kind, selector)`; a file
    #    cannot say which definition that reaches, because the class graph spans the project. Here the
    #    merged ancestry resolves it — the receiver's own class first, then its includes, then its
    #    superclass chain — and then the **closed world** joins every project-known override of the same
    #    selector below the receiver's class (ADR-103 WD4: Ruby has no `final`, and the analyzer already
    #    takes this posture for types). A call that resolves to nothing in the project is dropped, not
    #    tainted: the taint for an unresolvable call was already decided per site, from the typer's own
    #    verdict.
    # 2. **Reach a fixpoint.** Proven labels join along edges, the exhaustiveness bit ANDs, and causes
    #    union. The lattice is finite (label sets over a closed vocabulary × one bit × a closed cause
    #    enum) and every step is monotone, so iteration terminates on its own — a recursive or mutually
    #    recursive cycle simply converges, and no recursion cap is needed or wanted here.
    #
    # Propagation is graph-only: it reads no source, types nothing, and touches no `Scope`. It is
    # fail-soft as a whole — an exception yields the empty table rather than failing the run.
    module Propagator
      module_function

      # @param collection [FileCollection] the run's merged per-file collections
      # @return [EffectTable]
      def propagate(collection)
        return EffectTable.empty if collection.summaries.empty?

        summaries = collection.summaries
        edges = resolve_edges(collection)
        state = seed(summaries)
        iterate(state, edges)
        EffectTable.new(build_entries(summaries, edges, state))
      rescue StandardError
        EffectTable.empty
      end

      # `{caller_key => [callee_key]}`, sorted and de-duplicated.
      def resolve_edges(collection)
        index = Index.new(collection)
        collection.edges.each_with_object({}) do |(caller_key, list), out|
          targets = list.flat_map { |edge| index.targets_for(edge) }.uniq.sort
          out[caller_key] = targets.freeze unless targets.empty?
        end
      end

      def seed(summaries)
        summaries.transform_values do |summary|
          { proven: summary.proven, exhaustive: summary.exhaustive?, causes: summary.causes }
        end
      end

      # Round-robin to a fixpoint in sorted key order, so the answer does not depend on Hash insertion
      # order and a pooled run agrees with a sequential one bit for bit.
      def iterate(state, edges)
        order = state.keys.sort
        loop do
          changed = false
          order.each do |key|
            edges[key]&.each { |callee| changed = true if absorb(state, key, callee) }
          end
          break unless changed
        end
      end

      def absorb(state, key, callee)
        target = state[key]
        source = state[callee]
        return false if source.nil? || target.equal?(source)

        changed = false
        joined = target[:proven].join(source[:proven])
        unless joined == target[:proven]
          target[:proven] = joined
          changed = true
        end
        if target[:exhaustive] && !source[:exhaustive]
          target[:exhaustive] = false
          changed = true
        end
        merged = (target[:causes] + source[:causes]).uniq
        return changed if merged.size == target[:causes].size

        target[:causes] = merged
        true
      end

      def build_entries(summaries, edges, state)
        summaries.each_with_object({}) do |(key, summary), out|
          closed = state.fetch(key)
          out[key] = EffectTable::Entry.new(
            key: key,
            direct: summary,
            proven: closed[:proven],
            exhaustive: closed[:exhaustive],
            causes: closed[:causes].sort_by { |cause, detail| [cause, detail.to_s] }.freeze,
            edges: edges.fetch(key, [].freeze)
          )
        end
      end

      private_class_method :resolve_edges, :seed, :iterate, :absorb, :build_entries

      # The class graph a run's collections describe, and the edge resolution over it. Built once per
      # propagation; every lookup is a Hash read.
      class Index
        def initialize(collection)
          @summaries = collection.summaries
          @superclasses = collection.superclasses
          @includes = collection.includes
          @classes = build_classes(collection)
          @descendants = build_descendants(collection.superclasses)
        end

        # Every project method key `edge` may reach: the definition its ancestry resolves to, plus every
        # override of the same selector in a project subclass of the receiver's class.
        def targets_for(edge)
          separator = edge.kind == :singleton ? "." : "#"
          targets = []
          owner = resolve_owner(edge.receiver_class, separator, edge.selector)
          targets << owner if owner
          descendants_of(edge.receiver_class).each do |subclass|
            key = "#{subclass}#{separator}#{edge.selector}"
            targets << key if @summaries.key?(key)
          end
          targets
        end

        private

        # Ancestry order mirrors the engine's: the class itself, the modules it includes, then its
        # superclass, recursively. Cycle-guarded, because a project may declare one. Ancestry names
        # arrive as as-written candidate lists (see `Scanner#lexical_candidates`); every candidate is
        # enqueued and the most-qualified one comes first, so the right constant wins the race and a
        # spelling that names nothing simply matches no key.
        def resolve_owner(class_name, separator, selector)
          seen = Set.new
          queue = [class_name]
          until queue.empty?
            current = queue.shift
            next if current.nil? || !seen.add?(current)

            key = "#{current}#{separator}#{selector}"
            return key if @summaries.key?(key)

            queue.concat(@includes.fetch(current, []))
            queue.concat(@superclasses.fetch(current, []))
          end
          nil
        end

        def descendants_of(class_name)
          collected = []
          queue = @descendants.fetch(class_name, []).dup
          seen = Set.new
          until queue.empty?
            current = queue.shift
            next unless seen.add?(current)

            collected << current
            queue.concat(@descendants.fetch(current, []))
          end
          collected
        end

        # The subclass index the closed-world override join walks. Unlike the ancestor walk, this one
        # must pick **one** parent per child: enqueuing every candidate would let `A::Base` and `B::Base`
        # share the short spelling `Base` and join an unrelated class's override into the proven lane.
        # The most-qualified candidate the project actually defines wins; a child whose parent is outside
        # the project keeps its first (most-qualified) spelling and simply matches nothing.
        def build_descendants(superclasses)
          superclasses.each_with_object({}) do |(child, candidates), out|
            parent = candidates.find { |candidate| @classes.include?(candidate) } || candidates.first
            (out[parent] ||= []) << child
          end
        end

        # Every class name the project defines a method on — the evidence `build_descendants` resolves an
        # as-written superclass against.
        def build_classes(collection)
          collection.summaries.each_key.with_object(Set.new) do |key, out|
            index = key.index("#") || key.index(".")
            out << key[0, index] if index
          end
        end
      end
    end
  end
end
