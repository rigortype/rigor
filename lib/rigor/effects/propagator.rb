# frozen_string_literal: true

require_relative "discharge"
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
    #
    # **Three label lanes, one fixpoint** (#385), each monotone and each joined along the same edges:
    #
    # - `proven` — what the analyzer established.
    # - `undischarged` — the same closure computed from each unit's *undischarged* direct bundles, i.e.
    #   with every origin bundle `effects.tolerated:` discharges dropped at the seed ({Discharge}).
    #   Per-origin discharge needs nothing more than that: an origin belongs to exactly one unit's direct
    #   summary, so the transitive union of surviving bundles IS the closure of the seeded ones, and the
    #   judgment never has to materialise a per-method set of transitive origins. With no `tolerated:`
    #   list the policy is inert, the seed is identical, and the lane costs one `equal?`-true join.
    # - `declared` — the `≤` lane. It travels call edges **exactly as the proven lane does** (ADR-103
    #   WD1): a controller two hops above an attributed `Net::HTTP.get` reads `≤ io.net.http`, not merely
    #   "and possibly more". It is joined into itself and never into `proven`, which is the whole
    #   separation — a claim stays a claim however far it propagates.
    module Propagator
      NO_EDGES = [].freeze
      private_constant :NO_EDGES

      module_function

      # @param collection [FileCollection] the run's merged per-file collections
      # @param discharge [Discharge] the `effects.tolerated:` policy the undischarged lane is computed
      #   under; {Discharge.none} makes the two lanes equal.
      # @return [EffectTable]
      def propagate(collection, discharge: Discharge.none)
        return EffectTable.empty if collection.summaries.empty?

        summaries = collection.summaries
        edges = resolve_edges(collection)
        state = seed(summaries, discharge)
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

      # Causes are carried as a Set through the fixpoint and flattened back to a sorted Array in
      # {build_entries}. A Set is what {absorb} needs: unioning one along an edge must cost the source's
      # size and allocate NOTHING when it adds nothing, and the array-concat-and-uniq it replaces
      # allocated twice on every visit of every edge.
      def seed(summaries, discharge)
        summaries.transform_values do |summary|
          {
            proven: summary.proven,
            undischarged: discharge.inert? ? summary.proven : discharge.undischarged(summary.bundles),
            declared: summary.declared,
            exhaustive: summary.exhaustive?, causes: Set.new(summary.causes)
          }
        end
      end

      # A worklist to a fixpoint. `state[key]` changing can only change the methods that CALL `key`, so a
      # pass re-visits exactly those and the round-robin over the whole table is gone — that walk cost
      # O(passes × edges) and the passes are the graph's depth.
      #
      # Each pass still runs in sorted key order, so the answer does not depend on Hash insertion order
      # and a pooled run agrees with a sequential one bit for bit. (The lattice is finite and every step
      # monotone, so the least fixpoint is unique and visit order cannot change it; the sorted pass keeps
      # the *work* reproducible too.)
      def iterate(state, edges)
        order = state.keys.sort
        callers = reverse_edges(edges)
        pending = nil

        loop do
          dirty = nil
          order.each do |key|
            next if pending && !pending.include?(key)

            list = edges[key]
            next if list.nil?

            changed = false
            list.each { |callee| changed = true if absorb(state, key, callee) }
            next unless changed

            (dirty ||= Set.new).merge(callers[key]) if callers.key?(key)
          end
          break if dirty.nil?

          pending = dirty
        end
      end

      # `{callee_key => [caller_key]}` — who has to be re-visited when a key's closure moves.
      def reverse_edges(edges)
        edges.each_with_object({}) do |(caller_key, list), out|
          list.each { |callee| (out[callee] ||= []) << caller_key }
        end
      end

      def absorb(state, key, callee)
        target = state[key]
        source = state[callee]
        return false if source.nil? || target.equal?(source)

        # Each lane is named literally rather than looped over an array: this runs once per edge per
        # visit, and a literal array of lane names would allocate one per call for nothing.
        changed = join_lane(target, source, :proven)
        changed = true if join_lane(target, source, :undischarged)
        changed = true if join_lane(target, source, :declared)
        if target[:exhaustive] && !source[:exhaustive]
          target[:exhaustive] = false
          changed = true
        end
        causes = target[:causes]
        source[:causes].each { |cause| changed = true if causes.add?(cause) }
        changed
      end

      # Joins one label lane in place along an edge, answering whether it moved. {LabelSet#join} returns
      # the receiver untouched when the source adds nothing, so a converged region costs a comparison and
      # no allocation at all.
      def join_lane(target, source, lane)
        joined = target[lane].join(source[lane])
        moved = joined != target[lane]
        target[lane] = joined if moved
        moved
      end

      def build_entries(summaries, edges, state)
        summaries.each_with_object({}) do |(key, summary), out|
          closed = state.fetch(key)
          out[key] = EffectTable::Entry.new(
            key: key,
            direct: summary,
            proven: closed[:proven],
            undischarged: closed[:undischarged],
            declared: closed[:declared],
            exhaustive: closed[:exhaustive],
            causes: closed[:causes].sort_by { |cause, detail| [cause, detail.to_s] }.freeze,
            edges: edges.fetch(key, NO_EDGES)
          )
        end
      end

      private_class_method :resolve_edges, :seed, :iterate, :reverse_edges, :absorb, :join_lane,
                           :build_entries

      # The class graph a run's collections describe, and the edge resolution over it. Built once per
      # propagation; every lookup is a Hash read.
      class Index
        def initialize(collection)
          @summaries = collection.summaries
          @superclasses = collection.superclasses
          @includes = collection.includes
          @classes = build_classes(collection)
          @descendants = build_descendants(collection.superclasses)
          @descendant_closures = {}
          @targets = {}
        end

        # Every project method key `edge` may reach: the definition its ancestry resolves to, plus every
        # override of the same selector in a project subclass of the receiver's class.
        #
        # Memoised on `(receiver class, kind, selector)` — the answer depends on nothing else, and one
        # such triple is asked for once per call site in the project. `ApplicationRecord#save` alone is
        # thousands of sites on a Rails app, each of which used to re-walk the whole subclass forest.
        def targets_for(edge)
          @targets[[edge.receiver_class, edge.kind, edge.selector]] ||= begin
            separator = edge.kind == :singleton ? "." : "#"
            targets = []
            owner = resolve_owner(edge.receiver_class, separator, edge.selector)
            targets << owner if owner
            descendant_closure(edge.receiver_class).each do |subclass|
              key = "#{subclass}#{separator}#{edge.selector}"
              targets << key if @summaries.key?(key)
            end
            targets.freeze
          end
        end

        private

        # The transitive subclass closure, memoised per class. A deep hierarchy's root is asked for it
        # once, not once per selector reaching it.
        def descendant_closure(class_name)
          @descendant_closures[class_name] ||= descendants_of(class_name).freeze
        end

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
