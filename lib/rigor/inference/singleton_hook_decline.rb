# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-119 WD3 (errata 2026-10-08, PR C2-a) — the singleton side's positional hook decline. A hook's edge on
    # the singleton side is recorded on no includer, so no chain state carries it (WD3); what the read CAN say
    # is where such an edge could land. A hook touches the singleton chain of a class `K` in two ways only:
    #
    # - (U1) `K.extend(X)`, `class_methods do`, a concern's `ClassMethods`: Ruby inserts `X` after `#<Class:K>`
    #   and before `#<Class:K.superclass>`, inside `K`'s own level;
    # - (U2) `included do def self.x end`, `define_singleton_method`, `singleton_class.class_eval`: a definition ON
    #   `#<Class:K>`, at the level's head.
    #
    # So a hook at level `i` cannot move a definer at an index at or before the level's head, and a definer found
    # at `#<Class:K_j>` itself, written in `K_j`'s own body, is immune to every hook of levels `j` and deeper. The
    # read's last candidate gives a BOUND: its index when it is that class entry and its `def` was written in
    # `K_j`'s body; one past it for an extended module's entry, or for a copy the extends fold put on `K_j`
    # (the `def`'s recorded nesting does not start with `K_j`), and every entry when nothing answers. The levels
    # tested are those that start before the bound and do not end before `from`. The read declines when a tested
    # level's own instance level (the class, its prepends and includes with their closures) or its singleton
    # segment (the class's singleton and its extends' closures) holds a HOOK-CAPABLE entry, or when a class
    # deeper than the shallowest tested level records a singleton `inherited` (its own or a folded copy) or
    # lists `"*"` on its `:extend` side, or is an external superclass that is hook-capable.
    #
    # Hook-capable, for a project entry or a declared module the chain holds as external (a candidate of its
    # spelling is a `discovered_class_sources`, `discovered_classes`, `discovered_includes` or
    # `discovered_extends` key; an ambiguous spelling tests every declared candidate and any capable one
    # declines): lists `"*"` on either side, records a singleton {Scope::ResolutionChain::Relevance::HOOKS} def,
    # or extends `ActiveSupport::Concern`. An undeclared external is capable unless RBS knows it (WD2(i)'s
    # limit: an RBS-known external is clean). The dynamic mark is not a hook signal. The verdict does not depend
    # on the name asked, so it is memoised per entry in the chain's flavor bucket with the ADR-46 edges it read
    # (a class edge and the negative class edge on the unqualified name per tested project entry, the negative
    # class edge on the spelling's last segment and the candidates' class edges per tested external), replayed on
    # every call while a recording is active.
    #
    # Known remainders, pinned in `spec/integration/definer_resolution_witness_spec.rb`: `class << self; prepend
    # P` is recorded as an `extend` (the chain places `P` after the singleton, so an own `def self.x` is trusted
    # against it); a concern is capable for every name; an own `def self.x` is trusted against its own level's
    # U2 hooks; and a superclass that only `extend`s adds two forks, so every read on its subclasses declines.
    module SingletonHookDecline
      WILDCARD = "*"
      CONCERN = "ActiveSupport::Concern"
      SIDES = %i[include extend].freeze

      module_function

      # True when a hook may have placed a definer of `method_name` ahead of the read's last candidate on the
      # singleton `chain` (the candidate set `hits`, read from `from`).
      def decline?(scope, chain, method_name, from, hits)
        bound = bound_of(scope, chain, method_name, hits.last)
        tested = tested_levels(chain, from, bound)
        return false if tested.empty?
        return true if chain.truncated?

        context = Context.new(scope, chain.flavor)
        tested.any? { |level| context.level_capable?(chain, level) } || context.deeper_hook?(chain, tested.first)
      end

      def bound_of(scope, chain, method_name, hit)
        return chain.entries.size if hit.nil?

        index = hit.index
        entry = chain.entries[index]
        # A singleton project entry on a singleton chain is always a level's class entry.
        own = !entry.external? && entry.side == :singleton && def_head(scope, entry.name, method_name) == entry.name
        own ? index : index + 1
      end

      # What a class entry's answer is when its `def` was written in another module's body: `:copy` when that
      # module is on the same level's singleton segment (the extends fold copied it there; the copy is not where
      # Ruby finds the method — the module's own entry is, and an entry between them may answer first — so the
      # read asks again past it), `:stray` when it is not (the fold and the chain resolved the `extend`'s name to
      # different modules, `extend X` inside `module A` with both `X` and `A::X` declared: the read declines), and
      # nil otherwise (the class's own `def`, no `def`, or one with no recorded nesting).
      def copy_kind(scope, chain, method_name, hit)
        entry = chain.entries[hit.index]
        return nil if entry.external? || entry.side != :singleton

        head = def_head(scope, entry.name, method_name)
        return nil if head.nil? || head == entry.name

        level = chain.level_starts.rindex { |start| start <= hit.index }
        return :stray if level.nil? || level >= chain.level_count

        found = chain.level_entries(level).any? { |candidate| candidate.side == :instance && candidate.name == head }
        found ? :copy : :stray
      end

      # The innermost `Module.nesting` entry `owner`'s singleton `def` of the name was written in, or nil.
      def def_head(scope, owner, method_name)
        node = scope.singleton_def_for(owner, method_name)
        return nil if node.nil?

        nesting = scope.discovery.discovered_def_nestings[node] || DefNodeResolver.rehydrated_nesting(node)
        nesting&.first
      end

      def tested_levels(chain, from, bound)
        starts = chain.level_starts
        size = chain.entries.size
        (0...chain.level_count).select { |level| starts[level] < bound && (starts[level + 1] || size) >= from }
      end

      # The verdicts' working state: the scope, the flavor and the memo the verdicts share.
      class Context
        def initialize(scope, flavor)
          @scope = scope
          @flavor = flavor
          @memo = Scope::ResolutionChain.hook_memo(scope, flavor)
          @recording = Analysis::DependencyRecorder.active?
        end

        # A tested level: its singleton segment, and its class's own instance level.
        def level_capable?(chain, level)
          return true if chain.level_entries(level).any? { |entry| capable?(entry) }

          class_name = chain.level_classes[level]
          !class_name.nil? && instance_level_capable?(class_name)
        end

        # A level deeper than `level` whose `inherited` can define on every subclass's singleton: one that is
        # hook-capable as a tested level is. Its class records `inherited` (own, folded, or a literal
        # `define_method`), or an entry of its own instance level or singleton segment can define it unseen (a
        # concern's `class_methods do def inherited`, a hook that extends the class with a module defining it),
        # or it is an external superclass that is hook-capable.
        def deeper_hook?(chain, level)
          ((level + 1)...chain.level_count).any? { |deeper| level_capable?(chain, deeper) }
        end

        def capable?(entry)
          return verdict(:project, entry.name) { project_capable?(entry.name) } unless entry.external?

          verdict(:external, entry) { external_capable?(entry) }
        end

        private

        def instance_level_capable?(class_name)
          verdict(:instance_level, class_name) do |edges|
            chain = Scope::ResolutionChain.for(@scope, class_name, :instance, @flavor)
            next true if chain.truncated?

            entries = chain.level_count.zero? ? chain.entries : chain.level_entries(0)
            entries.any? do |entry|
              edges.concat(entry_edges(entry))
              capable?(entry)
            end
          end
        end

        # The memoised `[verdict, edges]` of one test, its edges replayed while a recording is active.
        def verdict(kind, key)
          verdict, edges = @memo[[kind, key]] ||= begin
            edges = []
            value = yield(edges)
            [value ? true : false, edges.concat(own_edges(kind, key)).uniq.freeze].freeze
          end
          replay(edges) if @recording
          verdict
        end

        def own_edges(kind, key)
          return entry_edges(key) if kind == :external
          return EMPTY_EDGES if kind == :instance_level

          [[:class, key], [:missing, key.to_s.split("::").last]]
        end

        def entry_edges(entry)
          return [[:class, entry.name], [:missing, entry.last_segment]] unless entry.external?

          entry.candidates.map { |candidate| [:class, candidate] } << [:missing, entry.raw.to_s.split("::").last]
        end

        def replay(edges)
          edges.each do |kind, value|
            case kind
            when :class then Scope::ResolutionChain.record_class(@scope, value)
            when :missing then Analysis::DependencyRecorder.read_missing(:class, value)
            end
          end
        end

        def project_capable?(name)
          sides = @scope.discovery.unpositioned_mixins[name]
          return true if sides && SIDES.any? { |side| sides[side]&.include?(WILDCARD) }

          return true if records_hook?(name)

          extends_concern?(name)
        end

        # Whether `name` records a hook name on either side, or in its envelope table: a `def self.inherited`, a
        # module's instance `def inherited` (a hook once extended), `singleton_class.define_method(:inherited)`
        # (recorded as an instance method) and `define_singleton_method(:inherited)` (recorded only as an opaque
        # envelope, the name-literal evidence `ScopeIndexer#record_surface_evidence` files).
        def records_hook?(name)
          envelopes = @scope.parameter_envelopes_of(name)
          Scope::ResolutionChain::Relevance::HOOKS.any? do |hook|
            @scope.discovered_method?(name, hook, :singleton) || @scope.discovered_method?(name, hook, :instance) ||
              envelopes.key?([:singleton, hook]) || envelopes.key?([:instance, hook])
          end
        end

        # Whether `name`'s own singleton segment (its `extend`s, as the chain places them) holds
        # `ActiveSupport::Concern` — the concern shape's only signal, a framework name the follow-up ADR moves
        # behind the plugin API (WD3, Q11).
        def extends_concern?(name)
          chain = Scope::ResolutionChain.for(@scope, name, :singleton, @flavor)
          entries = chain.level_count.zero? ? chain.entries : chain.level_entries(0)
          entries.any? do |entry|
            entry.external? ? entry.candidates.include?(CONCERN) : entry.name == CONCERN
          end
        end

        # A declared module the chain holds as external is tested as that module; an undeclared one is capable
        # unless RBS knows it.
        def external_capable?(entry)
          declared = entry.candidates.select { |candidate| declared?(candidate) }
          return declared.any? { |name| verdict(:project, name) { project_capable?(name) } } unless declared.empty?

          entry.candidates.none? { |candidate| Rigor::Reflection.rbs_class_known?(candidate, scope: @scope) }
        rescue StandardError
          true
        end

        def declared?(name)
          discovery = @scope.discovery
          discovery.discovered_class_sources.key?(name) || discovery.discovered_classes.key?(name) ||
            discovery.discovered_includes.key?(name) || discovery.discovered_extends.key?(name)
        end
      end
      private_constant :Context

      EMPTY_EDGES = [].freeze
      private_constant :EMPTY_EDGES
    end
  end
end
