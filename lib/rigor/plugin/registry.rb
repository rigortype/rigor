# frozen_string_literal: true

require_relative "blueprint"

module Rigor
  module Plugin
    # ADR-52 WD1 — the compiled contribution table. Categorises a loaded plugin set by which per-call
    # contribution paths each plugin actually implements, AND compiles the declarative gates (method names,
    # `block_as_methods` method names, `owns_receivers`) into frozen lookup structures, so the engine's hot
    # sites discover "no plugin cares about this call" in O(1) instead of O(plugins × rules) — a top hotspot
    # on plugin-heavy projects (GitLab's 11 plugins, of which only 2 implement any per-call path). Built once
    # per {Registry}.
    #
    # Ordering contract: the gates only PRUNE consultations that could not fire (every pruned rule would have
    # failed its own `methods:` / `method_names:` check); the engine still iterates the plugin subsets in
    # registry order and each plugin's rules in declaration order, so the surviving contributions arrive in
    # exactly the order the ungated walk produced — diagnostics stay byte-identical. The receiver-class
    # ancestry match for `dynamic_return` still happens per-dispatch inside `Plugin::Base#dynamic_return_type`.
    class ContributionIndex
      # Ordered (registry-order) subsets relevant to each collector, and the membership sets used to gate the
      # paths within a plugin. `for_file_diagnostics` is the subset the runner's per-file diagnostic loop
      # visits: plugins overriding `#diagnostics_for_file` or declaring at least one `node_rule`.
      attr_reader :for_method_dispatch, :for_statement, :for_file_diagnostics

      EMPTY_BLOCK_ENTRIES = [].freeze
      private_constant :EMPTY_BLOCK_ENTRIES

      def initialize(plugins)
        compile_memberships(plugins)
        compile_gates
        @block_entries_by_method_name = build_block_entries(plugins)
        @owns_receivers = plugins.flat_map { |p| manifest_for(p)&.owns_receivers || [] }.uniq.freeze
        # Per-run ancestry verdict memo, keyed by environment identity then class name. Mutable inside the
        # frozen index — sound because the class graph is fixed for the lifetime of a run.
        @owns_receiver_memo = {}.compare_by_identity
        freeze
      end

      def dynamic?(plugin) = @dynamic.include?(plugin)
      def narrowing_facts?(plugin) = @narrowing_facts.include?(plugin)

      # O(1) "could any plugin contribute a return type for a call named `method_name`?" — false only when
      # every `dynamic_return` rule is `methods:`-gated on other names, in which case the ungated walk would
      # have produced zero contributions too.
      def dispatch_candidate?(method_name)
        return true if @dynamic_global_gate.nil?

        @dynamic_global_gate.include?(method_name)
      end

      # O(1) statement-path sibling of {#dispatch_candidate?} over the `narrowing_facts` rules (which are
      # always `methods:`-gated).
      def statement_candidate?(method_name)
        return true if @narrowing_facts_global_gate.nil?

        @narrowing_facts_global_gate.include?(method_name)
      end

      # Per-plugin gate: false when the plugin declares no `dynamic_return` rules at all, or when every rule
      # is `methods:`-gated and none lists `method_name` — i.e. when `#dynamic_return_type` would return nil
      # without ever entering a rule block. Subsumes the old `dynamic?(plugin)` membership check at the
      # collector's call site.
      def dynamic_candidate_for?(plugin, method_name)
        return false unless @dynamic.include?(plugin)

        gate = @dynamic_gates[plugin]
        gate.nil? || gate.include?(method_name)
      end

      # Per-plugin gate over `narrowing_facts` rules; same contract as {#dynamic_candidate_for?}.
      def narrowing_facts_candidate_for?(plugin, method_name)
        return false unless @narrowing_facts.include?(plugin)

        gate = @narrowing_facts_gates[plugin]
        gate.nil? || gate.include?(method_name)
      end

      # The `Macro::BlockAsMethod` entries whose `method_names` include `method_name`, in (plugin
      # registration, manifest declaration) order — the same first-match order the previous plugins × entries
      # walk visited.
      def block_entries_for(method_name)
        @block_entries_by_method_name.fetch(method_name, EMPTY_BLOCK_ENTRIES)
      end

      # True when `class_name` equals or inherits from any plugin's manifest-declared `owns_receivers:` entry.
      # The union is compiled at build time (almost always empty → O(1) false) and per-class verdicts
      # memoise per environment.
      def owns_receiver?(class_name, environment)
        return false if @owns_receivers.empty? || class_name.nil?

        memo = (@owns_receiver_memo[environment] ||= {})
        memo.fetch(class_name) do
          memo[class_name] =
            @owns_receivers.any? { |owner| class_matches_owner?(class_name, owner, environment) }
        end
      end

      private

      # The categorisation sets + the ordered per-collector subsets.
      def compile_memberships(plugins)
        plugins.each { |p| reject_legacy_flow_hook!(p) }
        @dynamic = plugins.reject { |p| p.class.dynamic_returns.empty? }.to_set
        @narrowing_facts = plugins.reject { |p| p.class.narrowing_facts_rules.empty? }.to_set
        compile_collector_subsets(plugins)
      end

      def compile_collector_subsets(plugins)
        @for_method_dispatch = plugins.select { |p| @dynamic.include?(p) }.freeze
        @for_statement = plugins.select { |p| @narrowing_facts.include?(p) }.freeze
        @for_file_diagnostics =
          plugins.select { |p| file_diagnostics_overridden?(p) || !p.class.node_rules.empty? }.freeze
      end

      # The per-plugin and registry-global method-name gates.
      def compile_gates
        @dynamic_gates = build_name_gates(@dynamic) { |p| p.class.dynamic_returns }
        @narrowing_facts_gates = build_name_gates(@narrowing_facts) { |p| p.class.narrowing_facts_rules }
        @dynamic_global_gate = union_gate(@dynamic_gates)
        @narrowing_facts_global_gate = union_gate(@narrowing_facts_gates)
      end

      # ADR-52 WD3 — the legacy ungated `flow_contribution_for` hook was deleted pre-1.0. A plugin still
      # defining it would silently never be called, which is the worst failure mode for its author — surface
      # a loud load-time error with the migration mapping instead. (The Base default is gone, so any definer
      # wrote it themselves.)
      def reject_legacy_flow_hook!(plugin)
        return unless plugin.respond_to?(:flow_contribution_for)

        raise ArgumentError,
              "plugin #{(plugin.class.name || plugin.class).inspect} defines `flow_contribution_for`, " \
              "which was removed (ADR-52). Declare the per-call return type via `dynamic_return` " \
              "(receivers:/methods:/file_methods: gates, static or callable) and post-return narrowing " \
              "facts via `narrowing_facts` — see the CHANGELOG migration note."
      end

      # Same `Method#owner` trick for the per-file diagnostics hook — the Base default returns `[]`, so a
      # non-overriding plugin can be skipped without calling it.
      def file_diagnostics_overridden?(plugin)
        plugin.method(:diagnostics_for_file).owner != Rigor::Plugin::Base
      end

      # `plugin → Set[Symbol] | nil`. A frozen Set when EVERY rule of the plugin is `methods:`-gated (the
      # union of those names); nil when any rule is ungated (the plugin must be consulted for every method
      # name, exactly as before).
      def build_name_gates(members)
        gates = {}
        members.each do |plugin|
          rules = yield(plugin)
          # A static method-name Array can be compiled into the gate. A run-time callable `methods:` (ADR-52
          # slice 4) is unknown until after `#prepare`, and a receiver-only rule has no `methods:` — either
          # makes the plugin ungated-by-name (nil), consulted on every dispatch and filtered in the instance
          # path.
          gates[plugin] =
            if rules.all? { |rule| rule[:methods].is_a?(Array) }
              rules.flat_map { |rule| rule[:methods] }.to_set.freeze
            end
        end
        gates.freeze
      end

      # The registry-wide union of per-plugin gates, or nil when any plugin is ungated (no global pruning
      # possible). An empty plugin set unions to an empty frozen Set — the collectors' `relevant.empty?`
      # early return fires before it is consulted.
      def union_gate(gates)
        return nil if gates.value?(nil)

        gates.values.reduce(Set.new) { |acc, names| acc.merge(names) }.freeze
      end

      # `method-name Symbol → [BlockAsMethod entries]`, insertion-ordered by (plugin, declaration). Method
      # names are Symbol-normalised by `Macro::BlockAsMethod#initialize`.
      def build_block_entries(plugins)
        table = {}
        plugins.each do |plugin|
          entries = manifest_for(plugin)&.block_as_methods || []
          entries.each do |entry|
            entry.method_names.each { |name| (table[name] ||= []) << entry }
          end
        end
        table.each_value(&:freeze)
        table.freeze
      end

      # Mirrors `MethodDispatcher`'s previous per-dispatch matching: exact-name fast path, then
      # `Environment#class_ordering`, degrading to "no match" on any resolution failure.
      def class_matches_owner?(class_name, owner, environment)
        return true if class_name == owner
        return false if environment.nil?

        %i[equal subclass].include?(environment.class_ordering(class_name, owner))
      rescue StandardError
        false
      end

      # Manifest access tolerant of manifest-less plugin doubles in unit specs (a real loaded plugin always
      # carries one — the loader validates it).
      def manifest_for(plugin)
        plugin.manifest
      rescue StandardError
        nil
      end
    end

    # Read-side query API over the plugins loaded for a single `Analysis::Runner.run`. Constructed by
    # {Rigor::Plugin::Loader.load} and exposed downstream so the contribution merger (slice 3) and diagnostic
    # provenance (slice 5) can iterate over loaded plugin instances in deterministic order.
    #
    # The registry is read-only after construction; ordering is the order in which {Rigor::Plugin::Loader}
    # resolved configuration entries, which is project-config order with plugin-id alphabetical as the
    # tie-breaker.
    #
    # ADR-15 Phase 3 — alongside the instantiated `plugins`, the registry carries `blueprints`: a frozen,
    # Ractor-shareable `Array<Blueprint>` that records how to re-instantiate the same plugin set in a worker
    # Ractor. The eventual Phase 4 pool ships `blueprints` across the boundary and calls {.materialize}
    # per-Ractor; the live `plugins` carriage on the coordinator registry stays unchanged.
    class Registry
      attr_reader :plugins, :load_errors, :blueprints, :contribution_index, :resolved_gem_paths

      # @param plugins [Array<Rigor::Plugin::Base>] instantiated plugin instances in deterministic order.
      # @param load_errors [Array<Rigor::Plugin::LoadError>] failures surfaced during loading. Each error is
      #   also turned into a diagnostic by the runner.
      # @param blueprints [Array<Rigor::Plugin::Blueprint>] frozen, Ractor-shareable replay descriptors
      #   aligned 1:1 with `plugins`. The loader fills this in; callers that construct Registry manually MAY
      #   pass `[]` and accept that {.materialize} cannot replay the set.
      # @param resolved_gem_paths [Hash{String=>String,nil}] #194 slice 1 — `gem name => resolved file path`
      #   for each successfully required plugin gem, so `rigor plugins` can print where a loaded (and
      #   possibly frozen) plugin actually loaded from. Defaults to empty; a worker registry built by
      #   {.materialize} carries none (the provenance surface runs only on the coordinator).
      def initialize(plugins: [], load_errors: [], blueprints: [], resolved_gem_paths: {})
        @plugins = plugins.dup.freeze
        @load_errors = load_errors.dup.freeze
        @blueprints = blueprints.dup.freeze
        @resolved_gem_paths = resolved_gem_paths.dup.freeze
        @contribution_index = ContributionIndex.new(@plugins)
        compile_aggregates
        # ADR-52 WD4 — the single engine-owned node-rule walk, compiled once per run from the node-rule
        # plugin subset (registry order). The runner reuses it for every file; it builds fresh per-file
        # state internally, so it is safe to freeze and share.
        @node_rule_walk = NodeRuleWalk.new(@plugins)
        freeze
      end

      # ADR-52 WD4 — the per-run node-rule walk (see {NodeRuleWalk}).
      attr_reader :node_rule_walk

      # ADR-103 WD2 / WD6 / WD10 / WD14 (#387) — every loaded plugin's effect contribution, in
      # registration order, as {Contribution} rows.
      #
      # **Lazy, unlike the other aggregates.** A plugin MAY compute its `effect_attributions:` from project
      # facts — rigor-activejob reads `config.active_job.queue_adapter` to decide whether an enqueue is a
      # database write or a Redis one — and that is an I/O-boundary read a `rigor check` with no `effects:`
      # block must never pay. Nothing asks for this until {Rigor::Effects::PluginFacts.build} does, and
      # nothing calls that unless collection is on. Memoised into the frozen registry the same way
      # `contracts_for_path` memoises, and for the same reason: the answer is fixed for the run.
      def effect_contributions
        @effect_memo[:contributions] ||= compile_effect_contributions
      end

      # One plugin's effect contribution, flattened off whichever surface answered it (the manifest, or the
      # plugin's own override). Carries the two authority answers with it — `owner`, the label root this
      # plugin may open, and `discharge_allowed`, whether its attributions may discharge — so nothing
      # downstream has to re-derive who is first-party.
      Contribution = Data.define(:id, :owner, :requested_root, :discharge_allowed, :labels, :attributions,
                                 :edges, :entry_points) do
        def empty?
          labels.empty? && attributions.empty? && edges.empty? && entry_points.empty?
        end
      end

      # ADR-15 Phase 3 — build a fresh Registry from the supplied blueprint set by replaying
      # {Blueprint#materialize} per entry against `services`. The returned registry carries NEW plugin
      # instances (mutable per-Ractor accumulators included) and the same blueprint set, so a worker can hand
      # the materialised registry to Environment without losing the replay handle. `load_errors` is
      # intentionally empty: load-time failures already surfaced in the coordinator registry and don't repeat
      # per worker.
      def self.materialize(blueprints:, services:)
        plugins = blueprints.map { |bp| bp.materialize(services: services) }
        new(plugins: plugins, blueprints: blueprints, load_errors: [])
      end

      def find(id)
        id_s = id.to_s
        plugins.find { |plugin| plugin.manifest.id == id_s }
      end

      def ids
        plugins.map { |plugin| plugin.manifest.id }
      end

      def empty?
        plugins.empty?
      end

      def any_load_errors?
        !load_errors.empty?
      end

      # ADR-13 — flat ordered list of every loaded plugin's manifest-declared {TypeNodeResolver} instances,
      # in plugin registration order. `Environment#build_name_scope` builds a `TypeNode::ResolverChain` from
      # this list (environment.rb). The first non-nil `#resolve(node, scope)` return wins per ADR-13 WD3 /
      # WD5 — registration order is the user's lever.
      def type_node_resolvers
        plugins.flat_map { |plugin| plugin.manifest.type_node_resolvers }
      end

      # ADR-20 slice 6 — aggregate every loaded plugin's manifest-declared HKT registrations + definitions
      # into a single `Inference::HktRegistry` overlay that `Environment#hkt_registry` merges on top of the
      # bundled `Builtins::HktBuiltins.registry`. Last plugin to register a URI wins (registration order
      # determined by the user's `plugins:` list); user `.rbs` overlays merge on top of this overlay last.
      # Returns `Inference::HktRegistry::EMPTY` when no plugin contributes HKT entries so callers can skip the
      # merge.
      def hkt_overlay_registry
        registrations = plugins.flat_map { |plugin| plugin.manifest.hkt_registrations }
        definitions = plugins.flat_map { |plugin| plugin.manifest.hkt_definitions }
        return Inference::HktRegistry::EMPTY if registrations.empty? && definitions.empty?

        Inference::HktRegistry.new(registrations: registrations, definitions: definitions)
      end

      # ADR-25 — flat, ordered list of every loaded plugin's resolved RBS signature directories (absolute
      # paths), in plugin registration order. `Environment.for_project` merges these into the signature-path
      # set fed to `RbsLoader`, alongside the configuration's `signature_paths:` and the `bundler:` /
      # `rbs_collection:` discovery output.
      def signature_paths
        plugins.flat_map(&:signature_paths)
      end

      # ADR-26 — the aggregate set of "open" receiver class names declared across loaded plugins (manifest
      # `open_receivers:`). A class is open when a plugin vouches that it responds beyond its RBS-declared
      # method surface. `open_receiver?` is the membership predicate `Analysis::CheckRules` consults to skip
      # the `call.undefined-method` rule for such a class. Compiled at construction (ADR-52 WD1) — the
      # predicate runs per undefined-method candidate, so the previous per-call flat_map re-derived a frozen
      # invariant.
      attr_reader :open_receivers

      def open_receiver?(class_name)
        return false if class_name.nil?

        @open_receivers_set.include?(class_name.to_s)
      end

      # ADR-28 — flat, ordered list of every loaded plugin's path-scoped method-protocol contracts, in
      # plugin registration order. Read from each plugin's `#protocol_contracts` (which the manifest backs
      # by default but a plugin MAY override to fold in per-project config). Consumed by
      # `Inference::MethodParameterBinder` (the parameter-type provision) and by contributing plugins'
      # `#diagnostics_for_file` hooks (the presence + return-type check). Compiled at construction (ADR-52
      # WD1); a plugin's config-folding `#protocol_contracts` override is stable for the run because config
      # is injected at construction.
      attr_reader :protocol_contracts

      # ADR-38 — flat, ordered list of every loaded plugin's manifest-declared
      # `Rigor::Plugin::AdditionalInitializer` entries. `Inference::ScopeIndexer` consults the set at its
      # read-before-write nil soundness gate: a `def` whose name an entry covers, on a class that equals or
      # inherits from the entry's `receiver_constraint`, is treated like `initialize`. Compiled at
      # construction (ADR-52 WD1) — consulted per `def` node, ×2 sites in `ScopeIndexer`.
      attr_reader :additional_initializers

      # ADR-28 — the subset of `protocol_contracts` whose `path_glob` matches `path`. Contract globs are
      # authored project-root-relative (`lib/controller/**/*.rb`); the analyzer may hand this method either a
      # project-relative path (`rigor check` run from the project root) or an absolute one (run from
      # elsewhere, or a spec tmpdir), so the glob is matched both directly and as a `**/`-prefixed path
      # suffix. `File::FNM_PATHNAME` keeps `*` from crossing `/`; `File::FNM_EXTGLOB` enables `{a,b}` groups.
      # Returns `[]` for a nil path so the binder can call this unconditionally. Memoised per path (ADR-52
      # WD1) — consulted per `def` node by `MethodParameterBinder`, and the fnmatch sweep over every contract
      # is pure in (contract set, path).
      def contracts_for_path(path)
        return [] if path.nil?

        path_s = path.to_s
        @contracts_by_path[path_s] ||=
          protocol_contracts.select { |contract| path_matches_glob?(contract.path_glob, path_s) }.freeze
      end

      # ADR-32 WD4 + WD5 — flat ordered list of `[plugin, callable]` pairs for every loaded plugin that
      # declares a `source_rbs_synthesizer:` in its manifest. The engine invokes each callable once per
      # analysed Ruby source file at env-build time; non-nil return strings are merged into the RBS
      # environment as virtual signature sources. The full plugin instance is carried alongside the callable
      # so the engine's cache layer (WD5) can compose `plugin.plugin_entry` into its per-file descriptor — a
      # config change to the plugin (e.g. flipping `require_magic_comment:`) invalidates the dependent
      # synthesizer cache without any plugin-side bookkeeping.
      def source_rbs_synthesizers
        plugins.filter_map do |plugin|
          synthesizer = plugin.manifest.source_rbs_synthesizer
          next nil if synthesizer.nil?

          [plugin, synthesizer]
        end
      end

      FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
      private_constant :FNMATCH_FLAGS

      private

      # ADR-52 WD1 — aggregate queries the engine issues per def / per diagnostic candidate / per path are
      # compiled once at construction (the registry is frozen, so the flat_map-on-every-call versions
      # re-derived an invariant). `@contracts_by_path` is a mutable per-path memo inside the frozen registry
      # — safe because the contract set and the glob semantics are fixed for the lifetime of the run.
      def compile_aggregates
        @additional_initializers = @plugins.flat_map { |p| safe_manifest(p)&.additional_initializers || [] }.freeze
        @open_receivers = @plugins.flat_map { |p| (safe_manifest(p)&.open_receivers || []).map(&:to_s) }.uniq.freeze
        @open_receivers_set = @open_receivers.to_set.freeze
        @protocol_contracts = @plugins.flat_map { |p| safe_protocol_contracts(p) }.freeze
        @contracts_by_path = {}
        @effect_memo = {}
      end

      # Fail-soft per plugin: a plugin whose `effect_attributions:` override raises (a missing
      # `config/application.rb`, an unreadable path) contributes nothing rather than taking the run down.
      # An effect contribution is an enrichment; ADR-2 isolates plugin failures at the analyzer boundary
      # and this is that boundary.
      def compile_effect_contributions
        @plugins.filter_map { |plugin| effect_contribution_for(plugin) }.freeze
      end

      def effect_contribution_for(plugin)
        manifest = safe_manifest(plugin)
        return nil if manifest.nil?

        contribution = Contribution.new(
          id: manifest.id, owner: manifest.effect_owner, requested_root: manifest.effect_root,
          discharge_allowed: manifest.effect_discharge_allowed?,
          labels: plugin.effect_labels, attributions: plugin.effect_attributions,
          edges: plugin.effect_edges, entry_points: plugin.effect_entry_points
        )
        contribution.empty? ? nil : contribution
      rescue StandardError
        nil
      end

      def path_matches_glob?(glob, path)
        File.fnmatch?(glob, path, FNMATCH_FLAGS) ||
          File.fnmatch?(File.join("**", glob), path, FNMATCH_FLAGS)
      end

      # Construction-time manifest access tolerant of manifest-less plugin doubles in unit specs (a real
      # loaded plugin always carries one — the loader validates it). Mirrors
      # `ContributionIndex#manifest_for`.
      def safe_manifest(plugin)
        plugin.manifest
      rescue StandardError
        nil
      end

      def safe_protocol_contracts(plugin)
        plugin.protocol_contracts || []
      rescue StandardError
        []
      end
    end

    # Assigned after the class body completes — `Registry.new` runs at assignment time and `#initialize` calls
    # private helpers defined late in the body.
    Registry::EMPTY = Registry.new.freeze
  end
end
