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

      # @param collection — the run's merged per-file collections
      # @param discharge — the `effects.tolerated:` policy the undischarged lane is computed
      #   under; {Discharge.none} makes the two lanes equal.
      # @param declined_unit_keys — unit keys the run KNOWS a source file for and has no summary for
      #   (#1065): a template a plugin claimed and declined. An edge's fallback list is not tried past one
      #   of them, because the file the framework runs is the one that produced nothing.
      def propagate(collection, discharge: Discharge.none, declined_unit_keys: nil)
        return EffectTable.empty if collection.summaries.empty?

        summaries = collection.summaries
        state = seed(summaries, discharge)
        edges = resolve_edges(collection, state, declined_unit_keys)
        iterate(state, edges)
        EffectTable.new(build_entries(summaries, edges, state))
      rescue StandardError
        EffectTable.empty
      end

      # `{caller_key => [callee_key]}`, sorted and de-duplicated. Seeds the `unresolved-super` taint in
      # the same pass, because whether a `super` resolved is exactly what this resolution answers.
      def resolve_edges(collection, state, declined_unit_keys = nil)
        index = Index.new(collection, declined_unit_keys: declined_unit_keys)
        collection.edges.each_with_object({}) do |(caller_key, list), out|
          targets = list.flat_map do |edge|
            resolved = index.resolve(edge)
            taint_unresolved_super(state, caller_key, edge) if edge.super_call && resolved.empty?
            taint_unresolved_callee(state, caller_key, edge) if edge.taint_if_unresolved && resolved.empty?
            mark_unclaimed(state, caller_key) if edge.unclaimed && !edge.super_call && !index.owner_resolved?(edge)
            resolved
          end.uniq.sort
          out[caller_key] = targets.freeze unless targets.empty?
        end
      end

      # A `super` the project's own ancestry does not answer — the implementation is in a gem, in Ruby's
      # core, or in a module prepended at run time — is the case the taint exists for (#446). Silence
      # would be the one thing the effect model must never say: that the list is complete when a call in
      # the body was not read. An unresolved ORDINARY edge is dropped instead, because most such calls
      # are inherited ones the catalogue simply has no row for and the site's own taint was already
      # decided from the typer's verdict; a `super` has no site verdict to fall back on, and it always
      # dispatches to something.
      #
      # Decided here rather than in the collector because only the merged ancestry can say whether the
      # parent resolves, and written into the SEED rather than into the direct summary so the fixpoint
      # carries it to this method's callers exactly as it carries any other cause. A snapshot's
      # `methods:` table records direct summaries and so does not show it; `reach:`, the report and the
      # judgment all read the closure and do.
      def taint_unresolved_super(state, caller_key, edge)
        entry = state[caller_key]
        return if entry.nil?

        entry[:exhaustive] = false
        entry[:causes] << ["unresolved-super", edge.selector].freeze
      end

      # #1048 — a `callee:` edge a plugin's row produced, whose named unit is not in the table: the
      # template the render site pointed at was never analysed, so the row's `template-not-analysed` cause
      # is seeded here after all.
      #
      # The taint is ADDED on failure rather than subtracted on success, which is what keeps the fixpoint
      # monotone and the answer independent of visit order. It is also why a row whose rule declined
      # outright — a computed `render foo`, a `render json:` — never reaches this: {UnitScan} tainted that
      # site directly and recorded no edge, so nothing about an unresolvable render changed.
      def taint_unresolved_callee(state, caller_key, edge)
        entry = state[caller_key]
        return if entry.nil?

        entry[:exhaustive] = false
        # Frozen here rather than trusted from the edge: `Marshal.load` of a `Data` bypasses
        # `initialize`, so a pooled worker's collection restores the pair unfrozen while a sequential
        # one has the scan's frozen original. A cause travels into a `Set` shared by the whole fixpoint,
        # and the two paths must hand it the same value. `#freeze` on an already-frozen array is free.
        entry[:causes] << edge.taint_if_unresolved.freeze
      end

      # #391 — an edge nothing bounded whose receiver's OWN ancestry holds no project definition: the
      # callee's footprint was described by nobody, so the closure is "what the analyzer read", not
      # "what the method does".
      #
      # The question is deliberately {Index#owner_resolved?} and NOT "did this edge resolve to nothing".
      # An ordinary edge also joins every project subclass override of the selector (the closed-world
      # join of ADR-103 WD4), so a receiver typed as a gem class a project subclass happens to override
      # resolves non-empty while the receiver's own dispatch target is still undescribed — `B.run` on a
      # `Base2 < Vendor::Client` reaches `Vendor::Client#run` at run time whatever `Sub2#run` does.
      #
      # Decided HERE for the same reason the `super` taint is: only the merged ancestry can say whether
      # the edge resolves. Unlike that taint it is not a cause and does not touch exhaustiveness — every
      # existing consumer reads exactly what it read before. Its one reader is sig-gen's emission, which
      # must not write `%a{pure}` about a callee nobody described.
      def mark_unclaimed(state, caller_key)
        entry = state[caller_key]
        return if entry.nil?

        entry[:unclaimed] = true
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
            exhaustive: summary.exhaustive?, causes: Set.new(summary.causes),
            unclaimed: summary.unclaimed?
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
        if !target[:unclaimed] && source[:unclaimed]
          target[:unclaimed] = true
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
            edges: edges.fetch(key, NO_EDGES),
            unclaimed: closed[:unclaimed]
          )
        end
      end

      private_class_method :resolve_edges, :taint_unresolved_super, :taint_unresolved_callee,
                           :mark_unclaimed, :seed, :iterate,
                           :reverse_edges, :absorb, :join_lane, :build_entries

      # The class graph a run's collections describe, and the edge resolution over it. Built once per
      # propagation; every lookup is a Hash read.
      class Index
        def initialize(collection, declined_unit_keys: nil)
          @summaries = collection.summaries
          @declined = declined_unit_keys.nil? || declined_unit_keys.empty? ? nil : declined_unit_keys.to_a.to_set
          @superclasses = collection.superclasses
          @includes = collection.includes
          @classes = build_classes(collection)
          @descendants = build_descendants(collection.superclasses)
          @descendant_closures = {}
          @targets = {}
          # #391 — `{memo key => whether the receiver's own ancestry answered}`, filled by
          # {#call_targets} so {#owner_resolved?} costs a Hash read rather than a second ancestor walk.
          @owner_resolved = {}
        end

        # Every project method key `edge` may reach: the definition its ancestry resolves to, plus every
        # override of the same selector in a project subclass of the receiver's class.
        #
        # Memoised on `(receiver class, kind, selector, super?)` — the answer depends on nothing else, and
        # one such tuple is asked for once per call site in the project. `ApplicationRecord#save` alone is
        # thousands of sites on a Rails app, each of which used to re-walk the whole subclass forest.
        def targets_for(edge)
          @targets[memo_key(edge)] ||= begin
            separator = edge.kind == :singleton ? "." : "#"
            key = memo_key(edge)
            if edge.super_call
              super_targets(edge, separator)
            else
              constructor_targets(edge, key) || call_targets(edge, key, separator)
            end
          end
        end

        # {#targets_for}, then — only where that answered nothing — the first of the edge's
        # `fallback_selectors` that resolves (#1065), spelled as the same edge with that selector. A unit
        # under the requested key therefore always wins and a fallback never joins a second target beside
        # it: the lookup runs ONE template, and an edge to both would put a label on the caller that no
        # execution of the render produces. Empty when every candidate fails, which is what lets the
        # caller seed `taint_if_unresolved` exactly as before.
        # A requested key the run **declined** — a template whose file exists and whose plugin produced no
        # unit — stops there. "No unit answers" and "no such template" are different facts, and only the
        # second licenses the framework's next candidate: an `_x.js.haml` beside an `_x.html.erb` is run by
        # Action View as Haml, so joining the ERB unit would be a label no execution produces.
        def resolve(edge)
          resolved = targets_for(edge)
          return resolved unless resolved.empty? && edge.fallback_selectors
          return NO_TARGETS if declined?(edge)

          fallback_targets(edge)
        end

        # Whether the receiver's OWN ancestry holds a project definition of the selector — the half of
        # {#targets_for} the closed-world subclass join hides (#391).
        #
        # `targets_for` answers "which project bodies may this edge reach", and for an effect closure the
        # join is right: Ruby has no `final`, so a subclass override really can run. It is the wrong
        # question for "is this callee described at all". A receiver typed as a class the project only
        # subclasses dispatches into that class's own implementation, which lives in a gem or in core;
        # that a project subclass overrides the same selector says nothing about it. Only emission asks
        # this, and only to decline.
        def owner_resolved?(edge)
          targets_for(edge)
          @owner_resolved.fetch(memo_key(edge), false)
        end

        private

        def declined?(edge)
          !@declined.nil? && @declined.include?("#{edge.receiver_class}.#{edge.selector}")
        end

        def fallback_targets(edge)
          edge.fallback_selectors.each do |selector|
            resolved = targets_for(edge.with(selector: selector, fallback_selectors: nil))
            return resolved unless resolved.empty?
          end
          NO_TARGETS
        end

        def memo_key(edge)
          [edge.receiver_class, edge.kind, edge.selector, edge.super_call, edge.constant_receiver]
        end

        NEW_SELECTOR = "new"
        INITIALIZE_SELECTOR = "initialize"
        private_constant :NEW_SELECTOR, :INITIALIZE_SELECTOR

        # Class objects whose `new` is Ruby's own reflective constructor rather than a project class's
        # (#1039). `Class.new` allocates an anonymous class and runs `Class#initialize`, NOT the
        # `#initialize` of whatever the project happens to have named `Class`; the same holds for
        # `Module.new`, and for `Struct.new` / `Data.define`, which build a class rather than an instance.
        # Listed by name rather than left to the project-known guard below, because a project that reopens
        # `Class` at all would otherwise turn every `Class.new` in it into a call on that reopening.
        RESERVED_CONSTRUCTOR_OWNERS = %w[Class Module Struct Data].freeze
        private_constant :RESERVED_CONSTRUCTOR_OWNERS

        # Superclass spellings whose `#initialize` is Ruby's own and empty. A project chain that ends here
        # — or ends implicitly, with no `<` at all — has no constructor body anywhere, which is what
        # {#empty_constructor?} has to establish before it may say ∅ rather than "undescribed".
        EMPTY_CONSTRUCTOR_ROOTS = %w[Object BasicObject].freeze
        private_constant :EMPTY_CONSTRUCTOR_ROOTS

        # #1039 — `Const.new` on a class the project defines, resolved to that class's `#initialize`.
        #
        # The collector records the call as `(Const, :singleton, "new")`, because that is what the typer
        # saw; nothing in the project defines `Const.new`, so the edge resolved to nothing and every
        # constructor body stayed out of its caller's closure. `new` is the one selector in Ruby whose
        # dispatch target is spelled under a different key, and this is the rewrite: the same ancestor walk
        # {#resolve_owner} performs, on the instance side, for `initialize`.
        #
        # Three boundaries, and each of them can only narrow:
        #
        # - a project `def self.new` **wins**. It is the definition `Const.new` actually reaches, and a
        #   constructor that overrides `new` is the case where `#initialize` is not the answer. Resolved
        #   through the singleton ancestry, so an inherited `self.new` wins too.
        # - the receiver must be a class the project defines, and must not be one of
        #   {RESERVED_CONSTRUCTOR_OWNERS}. `Class.new { … }` is not a constructor call on a project class
        #   and must never reach a project `#initialize`; a gem class the project only calls `new` on is
        #   undescribed exactly as it was, and stays unclaimed.
        # - the closed-world subclass join is **dropped for a written constant receiver, and only for one**.
        #   `Base.new` names the class object it constructs, so `Sub#initialize` cannot run and joining it
        #   would put a proven label on the caller that no execution of that site can produce — the `super`
        #   argument (see {#super_targets}) rather than the ordinary-call one. But the edge is keyed on the
        #   receiver's TYPE, and `self.class.new`, a `Singleton[Base]` local's `.new` and a receiver-less
        #   `new` in a singleton body produce the identical tuple while genuinely constructing a subclass.
        #   {FileCollection::Edge#constant_receiver} is what tells them apart, and every shape that is not
        #   a written constant keeps the join — over `Sub#initialize` and over a subclass `Sub.new` alike.
        # - an ancestry the scanner could not read ({FileCollection::OPAQUE_ANCESTOR} — a non-constant
        #   superclass expression, an aliased `initialize`) declines, leaving the caller as unclaimed as it
        #   was before this rule existed.
        #
        # @return the targets, or `nil` when the rewrite does not apply and ordinary resolution should run
        def constructor_targets(edge, memo_key)
          return nil unless constructor_edge?(edge)

          owner = resolve_owner(edge.receiver_class, "#", INITIALIZE_SELECTOR)
          return nil unless owner || empty_constructor?(edge.receiver_class)

          @owner_resolved[memo_key] = true
          targets = owner ? [owner] : []
          targets.concat(subclass_constructors(edge.receiver_class)) unless edge.constant_receiver
          targets.uniq.freeze
        end

        # Whether the `new` rewrite applies to this edge at all — the guards of {#constructor_targets},
        # each of which can only decline: a singleton `new` on a project class that is not one of Ruby's
        # own class builders, whose singleton ancestry defines no `new` of its own, and whose constructor
        # the scan could read both above it and (where the join applies) below it.
        def constructor_edge?(edge)
          edge.kind == :singleton && edge.selector == NEW_SELECTOR &&
            !RESERVED_CONSTRUCTOR_OWNERS.include?(edge.receiver_class) &&
            project_class?(edge.receiver_class) &&
            resolve_owner(edge.receiver_class, ".", NEW_SELECTOR).nil? &&
            !opaque_ancestry?(edge.receiver_class) &&
            (edge.constant_receiver || !opaque_descendant?(edge.receiver_class))
        end

        # Every constructor a subclass of `class_name` supplies — its own `#initialize`, and its own
        # `.new` where it overrides one. The closed-world join of step 2, spelled for the two keys a
        # constructor can live under.
        def subclass_constructors(class_name)
          descendant_closure(class_name).each_with_object([]) do |subclass, keys|
            keys << "#{subclass}##{INITIALIZE_SELECTOR}" if @summaries.key?("#{subclass}##{INITIALIZE_SELECTOR}")
            keys << "#{subclass}.#{NEW_SELECTOR}" if @summaries.key?("#{subclass}.#{NEW_SELECTOR}")
          end
        end

        # The same question DOWNWARD, and only where the closed-world join applies. A subclass whose own
        # constructor is unreadable — `class AliasedChild < Parent; alias initialize setup` — is reached by
        # `self.class.new` in `Parent`, and {#subclass_constructors} would find no `AliasedChild#initialize`
        # key and say nothing. The join is the whole reason this edge may construct a subclass at all, so an
        # unreadable one in the closure declines the edge instead.
        def opaque_descendant?(class_name)
          descendant_closure(class_name).any? do |subclass|
            @includes.fetch(subclass, []).include?(FileCollection::OPAQUE_ANCESTOR) ||
              @superclasses.fetch(subclass, []).include?(FileCollection::OPAQUE_ANCESTOR)
          end
        end

        # Whether anything in `class_name`'s ancestry told the scanner its constructor is not readable from
        # the source (#1039): a superclass expression that is not a constant path, or an `alias` that makes
        # `initialize` another method. The sentinel rides the ancestry tables, so one walk finds it wherever
        # in the chain it was recorded.
        def opaque_ancestry?(class_name)
          queue = [class_name]
          seen = Set.new
          until queue.empty?
            current = queue.shift
            next unless seen.add?(current)
            return true if current == FileCollection::OPAQUE_ANCESTOR

            queue.concat(@includes.fetch(current, []))
            queue.concat(@superclasses.fetch(current, []))
          end
          false
        end

        # Whether `class_name`'s constructor is *known* to be `BasicObject#initialize`, whose footprint is
        # ∅ (#1039).
        #
        # This is the design choice in the rewrite. "No `#initialize` in the ancestry" has two readings —
        # the project defines none and none exists (a plain `class Bare; end`, constructed by Ruby's own
        # empty constructor), or the project defines none and a gem's base class does. The first resolves
        # to a known-empty definition: the edge contributes nothing AND leaves its caller claimed, because
        # the callee was read — there is simply nothing in it. The second is undescribed and must keep
        # marking its caller unclaimed. Only an ancestry that closes inside the project can tell them
        # apart, so that is what this walks, and it answers `false` the moment the walk leaves.
        #
        # No summary row is invented for `BasicObject#initialize`. A row would be a *method of the
        # project* in every table that lists them — the snapshot, `rigor effects`, the pure report — for a
        # definition the project does not contain; the answer belongs to the edge, and the edge is already
        # the thing {#owner_resolved?} is asked about.
        #
        # An `include` anywhere in the chain ends the walk conservatively. The collection's include table
        # is a flat list of as-written *candidate spellings* (`include Foo` inside `module A` records both
        # `A::Foo` and `Foo`), so it cannot say whether a class includes one project module or one gem
        # module the project cannot see — and a module is free to define `initialize`. Such a class keeps
        # exactly today's behaviour: its `new` edge resolves to nothing and its callers stay unclaimed.
        # The table holds instance-side includes only. A module mixed into the singleton class, by
        # `extend` or by an `include` inside `class << self`, is not in it, so a `new` such a module
        # supplies is not seen, and the walk can answer `true` for a class whose `new` does work.
        def empty_constructor?(class_name)
          queue = [class_name]
          seen = Set.new
          until queue.empty?
            current = queue.shift
            next unless seen.add?(current)
            return false unless project_class?(current)
            return false unless @includes.fetch(current, []).empty?

            parents = @superclasses.fetch(current, [])
            next if parents.empty?

            known = parents.find { |candidate| project_class?(candidate) }
            return false if known.nil? && parents.none? { |candidate| EMPTY_CONSTRUCTOR_ROOTS.include?(candidate) }

            queue << known if known
          end
          true
        end

        # Whether the project defines this class at all: it defines a method on it, declares its
        # superclass, or declares what it includes. Any one of the three is a `class` body the scanner
        # read, which is what licenses reading its silence about `initialize` as an answer.
        def project_class?(class_name)
          !class_name.nil? &&
            (@classes.include?(class_name) || @superclasses.key?(class_name) || @includes.key?(class_name))
        end

        def call_targets(edge, memo_key, separator)
          targets = []
          owner = resolve_owner(edge.receiver_class, separator, edge.selector)
          @owner_resolved[memo_key] = !owner.nil?
          targets << owner if owner
          descendant_closure(edge.receiver_class).each do |subclass|
            key = "#{subclass}#{separator}#{edge.selector}"
            targets << key if @summaries.key?(key)
          end
          targets.freeze
        end

        # A `super` reaches **one** definition, and the closed-world override join every other edge gets
        # is deliberately absent from it (#446). `super` in `C#m` dispatches into the ancestry above `C`
        # in the receiver's chain, and a subclass of `C` is never in it however the receiver was
        # constructed — so joining `D#m` would put a proven label on `C#m` that no execution of `C#m` can
        # produce. Ruby's lack of `final` is the argument for the join at an ordinary call site and says
        # nothing here.
        def super_targets(edge, separator)
          target = resolve_super(edge.receiver_class, separator, edge.selector)
          target ? [target].freeze : NO_TARGETS
        end

        NO_TARGETS = [].freeze
        private_constant :NO_TARGETS

        # The transitive subclass closure, memoised per class. A deep hierarchy's root is asked for it
        # once, not once per selector reaching it.
        def descendant_closure(class_name)
          @descendant_closures[class_name] ||= descendants_of(class_name).freeze
        end

        # Ancestry order mirrors the engine's: the class itself, the modules it includes, then its
        # superclass, recursively. Cycle-guarded, because a project may declare one. Ancestry names
        # arrive as as-written candidate lists (see `AncestryRecorder#lexical_candidates`); every candidate is
        # enqueued and the most-qualified one comes first, so the right constant wins the race and a
        # spelling that names nothing simply matches no key.
        def resolve_owner(class_name, separator, selector)
          walk_ancestors([class_name], Set.new, separator, selector)
        end

        # Where `super` from `class_name#selector` lands: the same ancestor walk, started one step up —
        # the modules the class includes, then its superclass chain — with the class itself already in
        # `seen`, because a method never `super`s into itself.
        #
        # The includes are instance-side only. `include M` puts `M#m` between the class and its
        # superclass, which is exactly where `super` looks, while `M.m` is a singleton method `include`
        # never contributes. A singleton `super` that really does reach a module went through `extend` or
        # a `class << self` include, neither of which is collected, so the walk steps over the module: it
        # reaches the superclass chain's definition when there is one, without the module's labels, and
        # resolves to nothing and taints when there is not.
        def resolve_super(class_name, separator, selector)
          queue = separator == "#" ? @includes.fetch(class_name, []).dup : []
          queue.concat(@superclasses.fetch(class_name, []))
          walk_ancestors(queue, Set.new([class_name]), separator, selector)
        end

        def walk_ancestors(queue, seen, separator, selector)
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
