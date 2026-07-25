# frozen_string_literal: true

require "did_you_mean"
require "digest"
require "json"
require "prism"

require_relative "manifest"
require_relative "node_context"
require_relative "../analysis/diagnostic"
# `producer generation_cap:` defaults to (and validates against) `Cache::Store::UNBOUNDED_GENERATIONS`, and a
# plugin class body can be evaluated before anything else pulled the cache layer in.
require_relative "../cache/store"
require_relative "../source/node_walker"

module Rigor
  module Plugin
    # Base class every Rigor plugin subclasses. The plugin gem subclasses {Base}, declares its identity
    # through {.manifest}, registers the subclass with {Rigor::Plugin.register}, and overrides {#init} to wire
    # up any state it needs from the injected service container.
    #
    # This class implements all plugin protocol hooks: per-call return-type contributions (`dynamic_return`),
    # narrowing-fact contributions (`narrowing_facts`), AST node rules (`node_rule`), and producer/cache
    # hooks. Cumulative implementation per the ADR-37 / ADR-52 slice chain.
    #
    # Example plugin:
    #
    #   class MyRailsPlugin < Rigor::Plugin::Base
    #     manifest(
    #       id: "rails",
    #       version: "0.1.0",
    #       description: "Rails framework support for Rigor"
    #     )
    #
    #     def init(services)
    #       @reflection = services.reflection
    #       @type = services.type
    #     end
    #   end
    #
    #   Rigor::Plugin.register(MyRailsPlugin)
    class Base # rubocop:disable Metrics/ClassLength
      class << self
        # Declares the plugin's manifest. Called once at class definition time — the resulting {Manifest} is
        # cached on the class so {Rigor::Plugin::Loader} reads it without constructing the plugin.
        def manifest(**fields)
          if fields.empty?
            raise ArgumentError, "plugin #{self} did not declare a manifest" unless defined?(@manifest) && @manifest

            return @manifest
          end

          @manifest = Manifest.new(**fields)
        end

        # ADR-7 § "Slice 6-A" — DSL declaration of a cached producer. Plugin authors write
        #
        #   class MyPlugin < Rigor::Plugin::Base
        #     manifest(id: "rails", version: "0.1.0")
        #
        #     producer :schema_table do |params|
        #       schema = io_boundary.read_file("db/schema.rb")
        #       parse(schema, params)
        #     end
        #   end
        #
        # The block runs through `instance_exec` so `self` inside the body is the plugin instance —
        # `io_boundary`, `services`, `manifest`, `config` are all in scope. The block receives the call-site
        # `params` Hash as its sole argument; the same params Hash mixes into the cache key per
        # `Cache::Descriptor#cache_key_for`.
        #
        # `serialize:` / `deserialize:` apply to the producer's return VALUE (the cache layer wraps them
        # around the record-and-validate entry pair itself). Default round-trip is `Marshal.dump` /
        # `Marshal.load` per the v0.0.9 callable surface; producers whose return values are not Marshal-clean
        # must supply their own pair.
        #
        # `watch:` (ADR-60 WD3) declares the glob coverage of a discovery-style producer — the files whose
        # addition / removal / edit must invalidate the cached value even when the producer block never read
        # them individually (e.g. it globbed a directory itself). It is either
        #
        # - a static Array of `[roots, pattern, ...]` tuples (`roots` a String or Array of Strings; one or
        #   more glob-pattern suffixes per tuple — the same shape {#glob_descriptor} takes), or
        # - a Proc, run through `instance_exec` on the plugin instance at `cache_for` invocation time (NEVER
        #   at class-definition time — search roots are typically computed in `#init` from config), returning
        #   the same tuple Array.
        #
        # The evaluated tuples become {Cache::Descriptor::GlobEntry} rows in the dependency descriptor
        # recorded after the block runs; `Descriptor#fresh?` re-globs + re-digests on the next run.
        #
        # Producer ids are auto-prefixed `plugin.<manifest.id>.` at the cache layer (slice 6-C) so plugin-side
        # ids cannot collide with built-in producers.
        #
        # `generation_cap:` declares how many generations of this producer's entries survive
        # `Cache::Store#evict!`'s compaction pass. The default —
        # `Cache::Store::UNBOUNDED_GENERATIONS` — suits the usual plugin producer, which keys per file or per
        # discovered unit and keeps many entries live at once; only the size-based LRU pass bounds it. A
        # producer whose entries are WHOLE-PROJECT and content-keyed (each run's inputs produce a fresh key
        # and orphan the previous one) should declare a small positive Integer instead, so the orphans are
        # reclaimed rather than accumulating under the global byte cap.
        def producer(id, watch: nil, serialize: nil, deserialize: nil,
                     generation_cap: Cache::Store::UNBOUNDED_GENERATIONS, &block)
          raise ArgumentError, "Plugin::Base.producer requires a block body" if block.nil?

          validate_producer_watch!(watch)
          validate_producer_generation_cap!(id, generation_cap)
          @producers ||= {}
          @producers[id.to_sym] = {
            block: block, watch: watch, serialize: serialize, deserialize: deserialize,
            generation_cap: generation_cap
          }.freeze
          id.to_sym
        end

        # A bad `generation_cap:` is caught at class-definition time (plugin load) rather than at the first
        # `cache_for` round-trip, so the plugin author sees it before any caching happens.
        def validate_producer_generation_cap!(id, generation_cap)
          return if generation_cap == Cache::Store::UNBOUNDED_GENERATIONS
          return if generation_cap.is_a?(Integer) && generation_cap.positive?

          raise ArgumentError,
                "Plugin::Base.producer #{id.inspect} generation_cap: must be a positive Integer or " \
                "#{Cache::Store::UNBOUNDED_GENERATIONS.inspect}, got #{generation_cap.inspect}"
        end
        private :validate_producer_generation_cap!

        # ADR-60 WD3 — `watch:` is nil (no glob coverage), a static tuple Array, or a Proc evaluated per
        # `cache_for` call.
        def validate_producer_watch!(watch)
          return if watch.nil? || watch.is_a?(Array) || watch.respond_to?(:call)

          raise ArgumentError,
                "Plugin::Base.producer watch: must be nil, an Array of [roots, pattern, ...] tuples, " \
                "or a Proc returning one, got #{watch.inspect}"
        end
        private :validate_producer_watch!

        # Frozen snapshot of the producer table. Inherited producers from a superclass are intentionally NOT
        # surfaced — Plugin::Base subclasses do not chain producers, and the loader instantiates one subclass
        # per registration.
        def producers
          (@producers || {}).dup.freeze
        end

        # ADR-37 slice 1 — declares a node-scoped diagnostic rule. The engine owns a single AST walk per file
        # (see {#node_rule_diagnostics}) and dispatches each node to the rules registered for its type, so a
        # plugin author writes the check, never the traversal:
        #
        #   class MyPlugin < Rigor::Plugin::Base
        #     manifest(id: "demo", version: "0.1.0")
        #
        #     node_rule Prism::CallNode do |node, scope, path|
        #       next [] unless node.name == :transition_to
        #       [diagnostic(node, path: path, message: "…", rule: "x")]
        #     end
        #   end
        #
        # `node_type` is a `Prism::Node` subclass; the rule fires for every node where
        # `node.is_a?(node_type)`. The block runs through `instance_exec` so `self` is the plugin instance —
        # `config`, `services`, `io_boundary`, `diagnostic`, and the cross-plugin `services.fact_store` are
        # all in scope. It receives `(node, scope, path, file_context, context)` — the fourth argument is the
        # value built by {.node_file_context} for a two-pass plugin (`nil` otherwise); the fifth is a
        # {Rigor::Plugin::NodeContext} carrying the node's lexical ancestors (enclosing class / method / block
        # DSL). Trailing arguments may be omitted from the block's parameter list. The block MUST return an
        # Array of `Rigor::Analysis::Diagnostic` (an empty array to fire nothing); the runner stamps
        # `plugin.<id>` provenance.
        #
        # Multiple rules for the same `node_type` are allowed and run in declaration order. This is the
        # {.producer}-style class DSL rather than a manifest field because a rule carries logic that needs the
        # plugin instance, not pure data.
        def node_rule(node_type, &block)
          raise ArgumentError, "Plugin::Base.node_rule requires a block body" if block.nil?
          unless node_type.is_a?(Class) && node_type <= Prism::Node
            raise ArgumentError,
                  "Plugin::Base.node_rule node_type must be a Prism::Node subclass, got #{node_type.inspect}"
          end

          @node_rules ||= []
          @node_rules << { node_type: node_type, block: block }.freeze
          node_type
        end

        # Frozen snapshot of the declared node rules, in declaration order. Not inherited from a superclass —
        # like {.producers}, the loader instantiates one subclass per registration.
        def node_rules
          (@node_rules || []).dup.freeze
        end

        # ADR-37 slice 1c — declares a per-file context builder for a two-pass (collect-then-validate)
        # plugin. The block runs once per analysed file (via `instance_exec`, so the plugin instance is
        # `self`) BEFORE any node rule fires, receives `(root, scope)`, and returns an arbitrary file-local
        # value that is threaded to every {.node_rule} block as its fourth argument:
        #
        #   node_file_context do |root, _scope|
        #     collect_declared_states(root)        # the "collect" pass
        #   end
        #
        #   node_rule Prism::CallNode do |node, _scope, path, states|
        #     next [] unless transition_call?(node)
        #     validate(node, path, states)         # the "validate" pass
        #   end
        #
        # This is what lets a same-file two-pass plugin drop its hand-rolled validate walk: the collect pass
        # computes the closed namespace once (it MUST complete before validation because a reference may
        # precede its declaration), and the engine owns the validate walk. A cross-file collect belongs in
        # `#prepare` + `services.fact_store` instead — a node rule reads the fact directly and needs no
        # per-file context.
        #
        # Only one builder per plugin; a second declaration replaces the first. The block result is `nil`
        # when none is declared.
        def node_file_context(&block)
          raise ArgumentError, "Plugin::Base.node_file_context requires a block body" if block.nil?

          @node_file_context_block = block
        end

        # The declared per-file context builder block, or nil.
        def node_file_context_block
          defined?(@node_file_context_block) ? @node_file_context_block : nil
        end

        # ADR-37 slice 2 / ADR-52 WD2 — declares a per-call-site return-type contribution, gated by receiver
        # class, method name, or both. The narrow successor to the `return_type` slot of the deleted
        # `flow_contribution_for` hook (ADR-52 WD3):
        #
        #   # receiver-gated only:
        #   dynamic_return receivers: ["ActiveRecord::Base"] do |call_node, scope|
        #     # self = plugin instance; return a Rigor::Type or nil
        #   end
        #
        #   # receiver + method gated (preferred for focused rules):
        #   dynamic_return receivers: ["Result"], methods: [:unwrap, :unwrap!] do |call_node, scope|
        #     # fires only for Result#unwrap / Result#unwrap!
        #   end
        #
        #   # method-gated only (ADR-52 WD2 — receiver-independent rules,
        #   # e.g. a unit-dimension DSL whose receiver carrier is a
        #   # refinement, not a nominal class):
        #   dynamic_return methods: [:kilometers, :per_hour, :in_meters] do |call_node, scope|
        #     # fires for any receiver when the method name matches;
        #     # the block reads the receiver's shape itself
        #   end
        #
        # `receivers:` is a non-empty Array of class names; the engine calls the block only when the call's
        # receiver type's class equals or inherits from one of them (via `Environment#class_ordering`). It
        # MAY be omitted — then the rule is receiver-independent and fires on `methods:` alone.
        #
        # `methods:` is an Array of Symbol method names. When provided, the block is skipped unless
        # `call_node.name` is in the list — declarative and cheaper than an in-block guard (the engine
        # compiles it into the registry's contribution table, ADR-52 WD1). It is REQUIRED when `receivers:`
        # is omitted: a rule gated on neither would fire on every dispatch, which is exactly the ungated cost
        # the `flow_contribution_for` escape valve carries — `dynamic_return` declines to reintroduce it.
        #
        # Method-name and type-shape refinement can still be done inside the block. The block runs through
        # `instance_exec`, so `config` / `services` are in scope.
        # ADR-52 slice 3 — `receivers:` may also be a **callable** (a `-> { ... }` resolved once per run,
        # lazily, the first time the rule is consulted — always after `#prepare`) for a receiver set the
        # plugin only knows at run time:
        #
        #   dynamic_return receivers: -> { attachment_index.model_names } do |call_node, scope|
        #     # fires when the receiver class is one a `prepare`-time scan
        #     # found; the block does the precise per-call lookup
        #   end
        #
        # The callable runs through `instance_exec`, so it reads the plugin's own `#prepare`-built indexes.
        # It MUST be idempotent and post-`#prepare`-safe — reference a lazily-built / memoised index (as
        # activestorage's `attachment_index` and activerecord's `model_index` are), never a value captured at
        # class-definition time. The resolved set is a safe over-approximation of the block's own filter (it
        # admits subclasses too), so the block stays the precise gate and diagnostics are unchanged.
        #
        # ADR-52 slice 4 — `methods:` may ALSO be a callable, for a method-name set the plugin only knows at
        # run time (a Sorbet catalog's keys, a config-derived DSL method name):
        #
        #   dynamic_return methods: -> { catalog.method_names } do |call_node, scope|
        #     ...
        #   end
        #
        # Same contract as a callable `receivers:` — `instance_exec`'d, resolved lazily after `#prepare`,
        # memoised, idempotent. A callable method set cannot be compiled into the registry's name gate (it is
        # unknown at registry-build time), so the plugin is consulted on every dispatch and the name filter
        # runs in this instance path instead — the block still only fires for a listed name, so diagnostics
        # are unchanged.
        # ADR-52 slice 5a — `file_methods:` is the per-file specialisation of the run-time `methods:`
        # callable, for a name set that varies per analysed file (rigor-rspec's `let` names — the names
        # depend on each file's `describe`/`let` structure, so one run-wide set cannot exist). The callable
        # receives the file path, runs through `instance_exec`, and is memoised per `(rule, path)`:
        #
        #   dynamic_return file_methods: ->(path) { let_names_for(path) } do |call_node, scope|
        #     ...
        #   end
        #
        # Same idempotence contract as the other callables, plus: it MUST tolerate any path the engine
        # analyses (return `[]` / nil for a file it has no names for — never raise). Like a callable
        # `methods:`, it cannot compile into the registry name gate, so the plugin is consulted on every
        # dispatch and filtered here. `file_methods:` replaces `methods:` (declaring both is rejected — they
        # are the same gate at two scopes); it MAY combine with `receivers:`.
        def dynamic_return(receivers: nil, methods: nil, file_methods: nil, &block)
          raise ArgumentError, "Plugin::Base.dynamic_return requires a block body" if block.nil?

          validate_dynamic_return_gate!(receivers, methods, file_methods)
          validate_dynamic_return_receivers!(receivers) unless receivers.nil?
          validate_dynamic_return_methods!(methods)
          validate_dynamic_return_file_methods!(file_methods, methods)

          @dynamic_returns ||= []
          @dynamic_returns << {
            receivers: normalize_dynamic_return_receivers(receivers),
            methods: normalize_dynamic_return_methods(methods),
            file_methods: file_methods,
            block: block
          }.freeze
          nil
        end

        # A class-name Array is frozen element-wise; a run-time callable (ADR-52 slice 3) is stored verbatim
        # and resolved per instance.
        def normalize_dynamic_return_receivers(receivers)
          return nil if receivers.nil?
          return receivers if receivers.respond_to?(:call)

          receivers.map { |r| r.dup.freeze }.freeze
        end
        private :normalize_dynamic_return_receivers

        # A method-name Array is symbol-normalised + frozen; a run-time callable (ADR-52 slice 4) is stored
        # verbatim and resolved per instance.
        def normalize_dynamic_return_methods(methods)
          return nil if methods.nil?
          return methods if methods.respond_to?(:call)

          methods.map(&:to_sym).freeze
        end
        private :normalize_dynamic_return_methods

        # Frozen snapshot of the declared dynamic-return rules. Memoised: `@dynamic_returns` is built once at
        # class-definition time (via `dynamic_return`) and never mutated during analysis, and every element
        # is already frozen, so a fresh `dup.freeze` per call was pure waste — the engine calls this for
        # every plugin on every dispatch (`collect_plugin_contributions`), making it a top allocation site on
        # plugin-heavy projects. The cached frozen array is immutable, so sharing one instance across callers
        # is safe.
        # rubocop:disable Naming/MemoizedInstanceVariableName -- the natural name `@dynamic_returns` is the
        # canonical (mutable-at-definition) store this snapshots; the memo must be distinct.
        def dynamic_returns
          @dynamic_returns_snapshot ||= (@dynamic_returns || []).dup.freeze
        end
        # rubocop:enable Naming/MemoizedInstanceVariableName

        # ADR-52 WD2 — a rule must gate on something. `receivers:` alone, `methods:` alone, or both are
        # valid; neither is not (it would fire on every dispatch).
        def validate_dynamic_return_gate!(receivers, methods, file_methods)
          return unless receivers.nil? && file_methods.nil?
          return if (methods.is_a?(Array) && !methods.empty?) || methods.respond_to?(:call)

          raise ArgumentError,
                "Plugin::Base.dynamic_return requires receivers:, methods:, or file_methods: — a rule " \
                "gated on none would fire on every dispatch (that is what flow_contribution_for is for)"
        end

        # ADR-52 slice 5a — `file_methods:` must be a callable, and is mutually exclusive with `methods:`
        # (one name gate, two scopes — declaring both is a contradiction, not a composition).
        def validate_dynamic_return_file_methods!(file_methods, methods)
          return if file_methods.nil?

          unless file_methods.respond_to?(:call)
            raise ArgumentError,
                  "Plugin::Base.dynamic_return file_methods: must be a callable receiving the file path, " \
                  "got #{file_methods.inspect}"
          end
          return if methods.nil?

          raise ArgumentError,
                "Plugin::Base.dynamic_return file_methods: replaces methods: — declare one name gate, " \
                "not both"
        end

        def validate_dynamic_return_receivers!(receivers)
          # ADR-52 slice 3 — a run-time callable is resolved per instance after `#prepare`; its shape is
          # checked at resolution time.
          return if receivers.respond_to?(:call)
          return if receivers.is_a?(Array) && !receivers.empty? && receivers.all? { |r| r.is_a?(String) && !r.empty? }

          raise ArgumentError,
                "Plugin::Base.dynamic_return receivers: must be a non-empty Array of class-name Strings " \
                "or a callable, got #{receivers.inspect}"
        end

        def validate_dynamic_return_methods!(methods)
          return if methods.nil?
          # ADR-52 slice 4 — a run-time callable resolves to the name set per instance after `#prepare`; its
          # shape is checked then.
          return if methods.respond_to?(:call)
          return if methods.is_a?(Array) && !methods.empty? &&
                    methods.all? { |m| m.is_a?(Symbol) || (m.is_a?(String) && !m.empty?) }

          raise ArgumentError,
                "Plugin::Base.dynamic_return methods: must be a non-empty Array of Symbol/String, a callable, " \
                "or nil, got #{methods.inspect}"
        end

        private :validate_dynamic_return_gate!, :validate_dynamic_return_receivers!,
                :validate_dynamic_return_methods!, :validate_dynamic_return_file_methods!

        # ADR-37 slice 2 — declares a predicate/assertion narrowing contribution, method-gated. The narrow
        # successor to the `post_return_facts` slot of the deleted `flow_contribution_for` hook (ADR-52 WD3):
        #
        #   narrowing_facts methods: [:assert_kind_of] do |call_node, scope|
        #     # return an Array of post-return facts, or nil
        #   end
        #
        # `methods:` is a non-empty Array of method names; the engine calls the block only when
        # `call_node.name` is one of them. The block returns the same `post_return_facts` the merger applies.
        #
        # This hook supplies post-return *narrowing facts* — the predicate/assertion edges a call establishes
        # about its arguments or receiver, e.g. `assert_kind_of(String, x)` ⇒ `x` is narrowed to `String` on
        # the continuation. It does NOT give a call a *type*; for that use {dynamic_return} (per-call-site)
        # or contribute RBS via the manifest `signature_paths:`. `dynamic_return` is the type slot, this is
        # the fact slot.
        #
        # Renamed from `type_specifier` (ADR-80): the old name read as a parallel to `dynamic_return` (a
        # type) when it actually returns facts. The old verb was a deprecating alias through 0.2.x and is
        # gone in 0.3.0 — `narrowing_facts` is the only spelling.
        def narrowing_facts(methods:, &block)
          raise ArgumentError, "Plugin::Base.narrowing_facts requires a block body" if block.nil?
          unless methods.is_a?(Array) && !methods.empty? &&
                 methods.all? { |m| m.is_a?(Symbol) || (m.is_a?(String) && !m.empty?) }
            raise ArgumentError,
                  "Plugin::Base.narrowing_facts methods: must be a non-empty Array of Symbol/String, " \
                  "got #{methods.inspect}"
          end

          @narrowing_facts_rules ||= []
          @narrowing_facts_rules << { methods: methods.map(&:to_sym).freeze, block: block }.freeze
          nil
        end

        # Frozen snapshot of the declared narrowing-facts rules. Memoised for the same reason as
        # {dynamic_returns} — consulted per plugin per dispatch, over an array fixed at class-definition
        # time.
        # rubocop:disable Naming/MemoizedInstanceVariableName -- see dynamic_returns
        def narrowing_facts_rules
          @narrowing_facts_rules_snapshot ||= (@narrowing_facts_rules || []).dup.freeze
        end
        # rubocop:enable Naming/MemoizedInstanceVariableName
      end

      attr_reader :services, :config

      def initialize(services:, config: {})
        @services = services
        @config = merge_config_defaults(config).freeze
        # ADR-52 slice 3 — per-rule cache of resolved run-time `dynamic_return receivers:` callables. Created
        # here (before any subclass `initialize` freezes the instance) so the lazy memo-on-first-dispatch is
        # a Hash-content mutation, sound even on a self-freezing plugin.
        @dynamic_return_runtime_cache = {}
        # ADR-60 WD4 — nil-inclusive memo tables for the authoring helpers ({#read_fact} / {#producer_value}
        # / {#producer_error}). Allocated here, before any subclass `initialize` self-freeze, for the same
        # reason: a populate is a Hash-content mutation.
        @fact_cache = {}
        @producer_value_cache = {}
        @producer_errors = {}
      end

      # Override in subclasses to wire any state the plugin needs from the injected service container.
      # Default is a no-op so plugins that only contribute through later-slice protocol hooks do not have to
      # define an explicit body.
      def init(services) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      # NOTE: (ADR-52 WD3): the legacy ungated per-call hook `flow_contribution_for` was DELETED here pre-1.0
      # after its five production users migrated. Per-call return types are declared via the gated
      # {.dynamic_return} DSL (static / run-time / per-file name sets, static / run-time receiver sets);
      # post-return narrowing facts via {.narrowing_facts}. See the CHANGELOG migration note for the
      # idiom-by-idiom mapping.

      # ADR-9 slice 3 — per-run preparation hook. The runner invokes `#prepare(services)` on every loaded
      # plugin once per `Analysis::Runner.run`, after `#init` has run on every plugin and before any
      # `#diagnostics_for_file` call. Plugins use this hook to compute and publish facts other plugins
      # consume:
      #
      #   def prepare(services)
      #     services.fact_store.publish(
      #       plugin_id: manifest.id, name: :model_index, value: model_index
      #     )
      #   end
      #
      # Default no-op so plugins without facts to publish leave `#prepare` unimplemented. Failures isolate as
      # `:plugin_loader runtime-error` diagnostics; a plugin that raises in `#prepare` has its facts
      # considered un-published and downstream consumers see `nil` from `fact_store.read`.
      #
      # Slice 3 calls plugins in registration order. ADR-9 slice 5 introduces topological ordering by
      # `consumes:` so producers always run before consumers.
      def prepare(services) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      # ADR-7 § "Slice 5-A" — per-file diagnostic emission hook. Override in plugin subclasses to return an
      # array of `Rigor::Analysis::Diagnostic` rows for the analysed file. The runner stamps each returned
      # diagnostic with `source_family: "plugin.<manifest.id>"` automatically per ADR-7 § "Slice 5-B"; plugin
      # authors should construct diagnostics without setting `source_family` (any value they pass is
      # overwritten).
      #
      # `path` is the analysed file path; `scope` is the entry `Rigor::Scope` after `ScopeIndexer` ran; `root`
      # is the parsed `Prism::Node` root. Plugin authors can traverse `root` themselves or declare rules via
      # the `.node_rule` DSL (ADR-37, shipped). The PHPStan-style `Rule<TNode>` base class mentioned in ADR-2
      # was superseded by the block-based `.node_rule` DSL.
      #
      # Default returns `[]` so plugins that contribute through other channels (e.g. slice-4 narrowing
      # contributions, slice-6 cache producers) do not have to override.
      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        []
      end

      # ADR-37 slice 1 — runs the plugin's declared {.node_rule}s over one file and returns their
      # diagnostics. The engine owns the single AST walk here so plugin authors never hand-roll a traversal:
      # every node reachable from `root` is offered to each rule whose `node_type` it satisfies
      # (`node.is_a?`), the rule's block is `instance_exec`'d on this plugin instance with
      # `(node, scope, path)`, and the returned diagnostics are concatenated in (node, declaration) order.
      #
      # Returns `[]` immediately when the plugin declares no node rules, so it is a zero-cost no-op for every
      # plugin that does not use the DSL. The runner calls it alongside `#diagnostics_for_file` and stamps
      # `plugin.<id>` provenance on the result; a raise propagates to the runner's per-plugin isolation
      # boundary.
      def node_rule_diagnostics(path:, scope:, root:)
        rules = self.class.node_rules
        return [] if rules.empty? || root.nil?

        # ADR-37 slice 1c — build the per-file context once (the "collect" pass) before the engine-owned
        # validate walk, so a two-pass plugin sees the closed namespace at every node.
        context_block = self.class.node_file_context_block
        file_context = context_block ? instance_exec(root, scope, &context_block) : nil

        diagnostics = []
        Source::NodeWalker.each_with_ancestors(root) do |node, ancestors|
          # One frozen NodeContext per node, shared across the rules that match it (ADR-52 WD1) — built
          # lazily so non-matching nodes (the vast majority) allocate nothing.
          context = nil
          rules.each do |rule|
            next unless node.is_a?(rule[:node_type])

            context ||= NodeContext.new(ancestors)
            diagnostics.concat(Array(instance_exec(node, scope, path, file_context, context, &rule[:block])))
          end
        end
        diagnostics
      end

      # ADR-37 slice 2 — the return type contributed by this plugin's {.dynamic_return} rules for a call, or
      # nil. The engine calls this from `MethodDispatcher`; a rule fires only when `receiver_type`'s class
      # equals or inherits from one of its declared `receivers:`. First non-nil wins (declaration order).
      # Failures isolate to nil.
      def dynamic_return_type(call_node:, scope:, receiver_type:)
        rules = self.class.dynamic_returns
        return nil if rules.empty? || receiver_type.nil?

        # `class_name` is nil for a receiver carrier with no nominal class (a refinement dimension, an
        # inferred shape) — fine for a receiver-less (methods-only) rule (ADR-52 WD2), which gates on the
        # method name alone and reads the receiver shape inside its own block.
        class_name = dynamic_return_receiver_class_name(receiver_type)
        environment = scope&.environment
        rules.each do |rule|
          next unless dynamic_return_rule_applies?(rule, call_node, class_name, environment, scope)

          result = instance_exec(call_node, scope, &rule[:block])
          return result if result
        end
        nil
      rescue StandardError
        nil
      end

      # ADR-37 slice 2 — the post-return narrowing facts contributed by this plugin's {.narrowing_facts}
      # rules for a call. The engine calls this from `StatementEvaluator`; a rule fires only when
      # `call_node.name` is one of its declared `methods:`. Failures isolate to [].
      def narrowing_facts_for(call_node:, scope:)
        rules = self.class.narrowing_facts_rules
        return [] if rules.empty? || !call_node.respond_to?(:name)

        name = call_node.name
        facts = []
        rules.each do |rule|
          next unless rule[:methods].include?(name)

          result = instance_exec(call_node, scope, &rule[:block])
          facts.concat(Array(result)) if result
        end
        facts
      rescue StandardError
        []
      end

      # Builds a `Rigor::Analysis::Diagnostic` positioned at a Prism `node` for return from
      # `#diagnostics_for_file`. Internalises the 1-based `line` / `start_column + 1` convention every plugin
      # otherwise re-derives by hand, so authors pass the node and the message/severity/rule rather than
      # unpacking `node.location`.
      #
      # `source_family` is intentionally NOT accepted — the runner stamps `plugin.<manifest.id>` on every
      # returned diagnostic (ADR-7 § "Slice 5-B"), so any value set here would be overwritten.
      # Pass `location:` (a Prism location) to point the diagnostic at a sub-location of `node` rather than
      # `node.location` — typically `node.message_loc` so a matcher / method-name diagnostic points at the
      # name, not the receiver-spanning whole call. A `nil` `location:` falls back to `node.location`, so
      # `location: node.message_loc` reproduces the common `message_loc || location` idiom.
      def diagnostic(node, path:, message:, severity: :error, rule: nil, location: nil)
        Analysis::Diagnostic.from_location(
          location || node.location,
          path: path, message: message, severity: severity, rule: rule
        )
      end

      # ADR-60 WD4 — maps a plugin's own violation objects to `Rigor::Analysis::Diagnostic`s through
      # {#diagnostic}, absorbing the `violations.map { |v| diagnostic(node, …) }` block the node-rule plugins
      # otherwise repeat. Each violation duck-types: `#message` (required); optional `#node` (the Prism node
      # to position at — falls back to the `node:` argument, the common "all violations point at the same
      # call" case), `#location` (a sub-location such as `node.message_loc`), `#severity` (defaults
      # `:error`), and `#rule`. Returns an Array suitable for direct return from `#diagnostics_for_file` / a
      # `node_rule` block.
      def diagnostics_for(violations, path:, node: nil)
        Array(violations).map do |violation|
          target = (violation.node if violation.respond_to?(:node)) || node
          diagnostic(
            target,
            path: path,
            message: violation.message,
            severity: (violation.respond_to?(:severity) && violation.severity) || :error,
            rule: (violation.rule if violation.respond_to?(:rule)),
            location: (violation.location if violation.respond_to?(:location))
          )
        end
      end

      # ADR-60 WD4 — reads a cross-plugin fact (ADR-9) published by another plugin's `#prepare` hook,
      # memoised per `(plugin_id, name)` on this instance INCLUDING a nil result. The nil-inclusive memo
      # retires the hand-rolled `@x_resolved` flag the discovery plugins carried to distinguish "fact not
      # published" from "not yet read". `services.fact_store` is the only sanctioned cross-plugin channel; a
      # fact no loaded producer published reads as nil.
      def read_fact(plugin_id:, name:)
        key = [plugin_id.to_s, name.to_sym].freeze
        return @fact_cache[key] if @fact_cache.key?(key)

        @fact_cache[key] = services.fact_store.read(plugin_id: plugin_id.to_s, name: name.to_sym)
      end

      # ADR-60 WD4 — runs a declared {.producer} through {#cache_for} and returns its value, memoised per
      # `(id, params)` INCLUDING nil. A `StandardError` the producer raises (a malformed project file, an I/O
      # failure) is rescued, recorded for {#producer_error}, and yields nil — so one bad project file
      # degrades a plugin to silence rather than aborting the whole run. This is the `*_index_or_nil` shape
      # the discovery plugins hand-rolled, named once.
      def producer_value(id, params: {})
        key = [id.to_sym, params].freeze
        return @producer_value_cache[key] if @producer_value_cache.key?(key)

        @producer_value_cache[key] = cache_for(id, params: params).call
      rescue StandardError => e
        @producer_errors[id.to_sym] = e
        @producer_value_cache[key] = nil
      end

      # ADR-60 WD4 — the `StandardError` a prior {#producer_value} call rescued for `id`, or nil when it
      # succeeded or was never called. Plugins surface it as a load-error diagnostic from
      # `#diagnostics_for_file`.
      def producer_error(id)
        @producer_errors[id.to_sym]
      end

      # Boilerplate-reduction helper (review §1.3): the "did you mean …?" suggestion every
      # diagnostic-emitting plugin otherwise hand-rolls. Returns the closest of `candidates` to `name` via
      # `DidYouMean::SpellChecker` (the same engine Ruby's own `NoMethodError` hints use), or `nil` when
      # there is no good match / no candidates — replacing the per-plugin Levenshtein copies. A **class**
      # method so it is callable both from a plugin instance (`Rigor::Plugin::Base.suggest(...)`) and from an
      # `Analyzer` module function that has no instance.
      def self.suggest(name, candidates)
        dictionary = Array(candidates).map(&:to_s)
        return nil if dictionary.empty?

        DidYouMean::SpellChecker.new(dictionary: dictionary).correct(name.to_s).first
      end

      # Convenience accessor — `manifest` on the instance returns the class-level manifest declaration.
      def manifest
        self.class.manifest
      end

      # ADR-25 — absolute RBS signature directories this plugin contributes. Resolves each
      # `manifest.signature_paths` entry (declared relative to the plugin gem root) against that root. The
      # gem root is the directory above `lib/` in the file that defined the plugin class (falling back to
      # that file's directory for a non-conventional layout). Returns `[]` when the manifest declares no
      # `signature_paths:` or the class is anonymous (an anonymous class cannot ship a gem).
      # `Plugin::Loader` validates the resolved dirs exist at load time; `Environment.for_project` merges
      # them into the signature-path set fed to `RbsLoader`.
      def signature_paths
        relative = manifest.signature_paths
        return [] if relative.empty?

        class_name = self.class.name
        return [] if class_name.nil?

        file, = Object.const_source_location(class_name)
        return [] if file.nil?

        before, separator, = file.rpartition("/lib/")
        root = separator.empty? ? File.dirname(file) : before
        relative.map { |rel| File.expand_path(rel, root) }
      end

      # ADR-28 — the path-scoped method-protocol contracts this plugin contributes. Defaults to the
      # manifest-declared `protocol_contracts:`; the same indirection `#signature_paths` uses, so a plugin
      # MAY override this to fold per-project config into the contract set (e.g. substituting the convention
      # `path_glob` with a user-supplied one) without the manifest having to be config-aware.
      # `Plugin::Registry#protocol_contracts` aggregates the result across loaded plugins.
      def protocol_contracts
        manifest.protocol_contracts
      end

      # ADR-7 § "Slice 6-A/6-B" — per-plugin {IoBoundary}. Memoised so the boundary's accumulated `FileEntry`
      # rows persist across producer invocations within the same plugin instance and feed cache invalidation
      # via `cache_for`.
      def io_boundary
        @io_boundary ||= services.io_boundary_for(manifest.id)
      end

      # ADR-7 § "Slice 6-A" / ADR-60 WD3 — returns a callable that performs a `Cache::Store#fetch_or_validate`
      # round-trip for the named producer (the ADR-45 record-and-validate path). The entry is KEYED on the
      # stable identity inputs — the plugin's `PluginEntry` template (id, version, config_hash) composed with
      # the optional `descriptor:` extras — and stores, beside the value, a DEPENDENCY descriptor recorded
      # AFTER the producer block ran: the {IoBoundary}'s post-compute read history plus the evaluated
      # `watch:` {Cache::Descriptor::GlobEntry} rows. In-block reads are therefore always captured (the
      # structural stale-cache hazard `fetch_or_compute`'s call-time snapshot carried); the next run
      # re-validates the recorded dependencies by re-digest (`Descriptor#fresh?`) and recomputes when any
      # changed. The producer id is auto-prefixed `plugin.<manifest.id>.` per ADR-7 § "Slice 6-C" so plugin
      # caches stay sandboxed from built-in producers.
      #
      # When `services.cache_store` is `nil` (e.g. CLI `--no-cache`), the callable bypasses the cache and
      # runs the producer block every time — same semantics as the v0.0.9 cache surface for built-in
      # producers.
      #
      # `descriptor:` (optional) supplies extra `Cache::Descriptor` rows for IDENTITY inputs — gem-version
      # `GemEntry` pins, `ConfigEntry` rows for external state — that compose into the cache KEY via
      # `Cache::Descriptor.compose`; per-slot conflicts raise `Cache::Descriptor::Conflict` to make divergent
      # inputs visible rather than silently shadowing. A key change is a miss, so the invalidation effect of
      # the legacy `glob_descriptor`-as-`descriptor:` idiom is preserved unchanged.
      def cache_for(producer_id, params: {}, descriptor: nil)
        producer = self.class.producers[producer_id.to_sym]
        unless producer
          raise ArgumentError,
                "plugin #{manifest.id.inspect} did not declare producer #{producer_id.inspect}"
        end

        compute = -> { instance_exec(params, &producer[:block]) }
        store = services.cache_store
        return compute unless store

        prefixed_id = "plugin.#{manifest.id}.#{producer_id}"
        key_descriptor = compose_key_descriptor(descriptor)
        lambda do
          store.fetch_or_validate(
            producer_id: prefixed_id,
            key_descriptor: key_descriptor,
            generation_cap: producer[:generation_cap],
            params: params,
            serialize: pair_serializer(producer[:serialize]),
            deserialize: pair_deserializer(producer[:deserialize])
          ) do
            value = compute.call
            [value, producer_dependency_descriptor(producer)]
          end
        end
      end

      # Builds a `Cache::Descriptor` covering every file matched by `pattern` (a glob, e.g. `"**/*.rb"`)
      # under any of `roots`. Each matching file contributes a `:digest`-comparator `FileEntry` so the cache
      # invalidates on any content change, any addition (a newly-glob-matched file appears in the
      # descriptor), or any removal (the previously-matched file drops out).
      #
      # ADR-60 WD3 made this **private**: the declared way for a discovery-style producer to cover its glob
      # is `producer watch:` (one {Cache::Descriptor::GlobEntry} per glob in the record-and-validate
      # dependency descriptor), not a hand-built descriptor composed into the cache *key*. The method
      # survives only as the building block for the rare producer that needs `FileEntry` rows directly;
      # plugin code calls `watch:`.
      #
      # @param roots    [Array<String>] search roots (relative to the project root, or absolute paths)
      # @param patterns [Array<String>] glob suffixes joined under each root via `File.join(root, pattern)`.
      #   Multiple patterns union into one descriptor (`"**/*.erb", "**/*.html"` etc.).
      # @return [Rigor::Cache::Descriptor]
      def glob_descriptor(roots, *patterns)
        files = collect_glob_files(Array(roots), patterns)
        entries = files.map do |path|
          Cache::Descriptor::FileEntry.new(
            path: path,
            comparator: :digest,
            value: Digest::SHA256.file(path).hexdigest
          )
        end
        Cache::Descriptor.new(files: entries)
      end
      private :glob_descriptor

      private

      # ADR-40 — merge the manifest's declared `config_schema` `default:` values *under* the user-supplied
      # config (user wins), so a plugin reads `config.fetch("key")` and gets the declared default with no
      # `DEFAULT_*` constant. A class declared without a manifest (test doubles) keeps the raw config
      # unchanged.
      def merge_config_defaults(config)
        unless self.class.instance_variable_defined?(:@manifest) && self.class.instance_variable_get(:@manifest)
          return config
        end

        self.class.manifest.config_defaults.merge(config)
      end

      # ADR-37 slice 2 — the class name to match a `dynamic_return` `receivers:` entry against, from a
      # receiver `Type`. Covers the instance (`Nominal[X]`) and class (`Singleton[X]`) shapes; other carriers
      # decline (nil → no match).
      def dynamic_return_receiver_class_name(receiver_type)
        case receiver_type
        when Rigor::Type::Nominal, Rigor::Type::Singleton then receiver_type.class_name
        end
      end

      # The gate for one `dynamic_return` rule. Method-name gate first — a Symbol-array probe vs the receiver
      # ancestry resolution below (ADR-52 WD1); both are pure predicates, so order only affects cost. A
      # receiver-less rule (ADR-52 WD2) skips the ancestry check entirely and fires on the method name alone.
      def dynamic_return_rule_applies?(rule, call_node, class_name, environment, scope)
        return false if rule[:methods] && !resolved_dynamic_return_methods(rule).include?(call_node.name)

        if rule[:file_methods]
          # The path is read here, not in `dynamic_return_type`, so a spec-double scope without
          # `source_path` only affects `file_methods:` rules (other gate forms never touch it).
          path = scope.respond_to?(:source_path) ? scope.source_path : nil
          return false unless resolved_dynamic_return_file_methods(rule, path).include?(call_node.name)
        end

        receivers = resolved_dynamic_return_receivers(rule)
        return true if receivers.nil?
        return false if class_name.nil?

        receivers.any? { |c| class_matches_receiver?(class_name, c, environment) }
      end

      # ADR-52 slice 4 — the rule's method-name set. A static Array is returned as-is (`#include?` over
      # Symbols); a run-time callable is `instance_exec`'d against this plugin and memoised as a Symbol Set,
      # same lazy/idempotent contract as a callable `receivers:`. The cache key is namespaced so a rule that
      # makes both `methods:` and `receivers:` callable keeps two distinct memo slots.
      def resolved_dynamic_return_methods(rule)
        methods = rule[:methods]
        return methods unless methods.respond_to?(:call)

        (@dynamic_return_runtime_cache ||= {})[[:methods, rule]] ||=
          Array(instance_exec(&methods)).to_set(&:to_sym).freeze
      end

      # ADR-52 slice 5a — the rule's per-file method-name set. The `file_methods:` callable is
      # `instance_exec`'d with the file path and memoised per `(rule, path)` — one resolution per analysed
      # file, the per-file analogue of the run-wide `methods:` memo. A nil path (synthetic call sites with no
      # file context) resolves to the empty set: the gate has nothing to key on, so the rule declines —
      # fail-closed, consistent with the gate's purpose. A raising callable degrades to "declines this
      # dispatch" via `dynamic_return_type`'s surrounding rescue.
      EMPTY_NAME_SET = Set.new.freeze
      private_constant :EMPTY_NAME_SET

      def resolved_dynamic_return_file_methods(rule, path)
        return EMPTY_NAME_SET if path.nil?

        (@dynamic_return_runtime_cache ||= {})[[:file_methods, rule, path]] ||=
          Array(instance_exec(path, &rule[:file_methods])).to_set(&:to_sym).freeze
      end

      # ADR-52 slice 3 — the rule's receiver class-name Array. A static Array is returned as-is; a run-time
      # callable is `instance_exec`'d against this plugin (so it reads the `#prepare`-built indexes) and
      # memoised per rule for the run. Resolution is lazy — first reached during file analysis, always after
      # `#prepare` — and the callable is required to be idempotent, so the memoised set is stable. A callable
      # that raises degrades to "no receivers match" (the rule declines), never a crash, consistent with the
      # surrounding rescue.
      def resolved_dynamic_return_receivers(rule)
        receivers = rule[:receivers]
        return receivers unless receivers.respond_to?(:call)

        # `||= {}` keeps the path correct even when a caller bypassed `initialize` (`allocate` in unit specs
        # that inject a fake index); a self-freezing plugin already has the Hash from `initialize`, so the
        # `||=` is a no-op there (never a FrozenError).
        (@dynamic_return_runtime_cache ||= {})[rule] ||=
          Array(instance_exec(&receivers)).map { |c| c.to_s.dup.freeze }.freeze
      end

      # True when `class_name` equals or inherits from `constraint`, matched through
      # `Environment#class_ordering` (the mechanism `MacroBlockSelfType` / `additional_initializers` use).
      # Degrades to "no match" on any resolution failure (false-positive-safe).
      def class_matches_receiver?(class_name, constraint, environment)
        return true if class_name == constraint
        return false if environment.nil?

        %i[equal subclass].include?(environment.class_ordering(class_name, constraint))
      rescue StandardError
        false
      end

      def collect_glob_files(roots, patterns)
        matched = roots.flat_map do |root|
          absolute = File.expand_path(root.to_s)
          next [] unless File.directory?(absolute)

          patterns.flat_map { |pattern| Dir.glob(File.join(absolute, pattern.to_s)) }
        end
        matched.uniq.sort.select { |path| File.file?(path) }
      end

      public

      # ADR-32 WD5 — the `Cache::Descriptor::PluginEntry` template carrying this plugin's id, version, and a
      # SHA-256 digest of its (canonicalised) config hash. Callers outside the plugin (e.g.
      # `Environment.for_project` caching per-file synthesizer output) compose this entry into their own
      # cache descriptor so a config change to the plugin (e.g. flipping `require_magic_comment:`)
      # invalidates the dependent cache.
      def plugin_entry
        # Built fresh on each call rather than memoised so a plugin subclass that freezes itself in
        # `initialize` (e.g. `Rigor::Plugin::RbsInline` per ADR-32) doesn't trip a FrozenError on first read.
        # The construction cost is a single `Data.define`-backed value-object build; the cache key derivation
        # downstream is the expensive step, and it's already memoised inside `Cache::Store`.
        Cache::Descriptor::PluginEntry.new(
          id: manifest.id,
          version: manifest.version,
          config_hash: digest_config(config)
        )
      end

      private

      # ADR-60 WD3 — the cache KEY descriptor: the plugin's PluginEntry template composed with an optional
      # plugin-author-supplied extension carrying IDENTITY inputs (gem-version pins, `ConfigEntry` rows,
      # configuration-file digests). The IoBoundary read history deliberately does NOT enter the key — it is
      # recorded post-compute into the dependency descriptor instead (see {#producer_dependency_descriptor}).
      def compose_key_descriptor(extra)
        auto_built = Cache::Descriptor.new(plugins: [plugin_entry])
        return auto_built if extra.nil?

        Cache::Descriptor.compose(auto_built, extra)
      end

      # ADR-60 WD3 — the dependency descriptor stored beside the producer's value, built AFTER the block ran
      # so every in-block `io_boundary` read is captured, plus the evaluated `watch:` glob rows.
      #
      # The boundary snapshot may carry `ConfigEntry` rows (URL fetches, see {IoBoundary#open_url}).
      # `Descriptor#fresh?` refuses any non-file/glob slot, so including them makes the entry permanently
      # stale → the producer recomputes EVERY run. That is deliberate: it is sound (never stale) and
      # URL-reading producers are rare; a remote document has no cheap local re-validation anyway.
      def producer_dependency_descriptor(producer)
        boundary = io_boundary.cache_descriptor
        Cache::Descriptor.new(
          files: boundary.files,
          configs: boundary.configs,
          globs: watch_glob_entries(producer[:watch])
        )
      end

      # ADR-60 WD3 — evaluates a producer's `watch:` declaration into {Cache::Descriptor::GlobEntry} rows. A
      # Proc is `instance_exec`'d on this plugin instance (so `#init`-built search roots are in scope); the
      # result — like the static form — is an Array of `[roots, pattern, ...]` tuples, one GlobEntry per
      # (root, pattern) pair. Roots are expanded to absolute paths (matching {#glob_descriptor}) so freshness
      # re-validation does not depend on the validating process's working directory.
      def watch_glob_entries(watch)
        return [] if watch.nil?

        tuples = watch.respond_to?(:call) ? instance_exec(&watch) : watch
        Array(tuples).flat_map do |tuple|
          roots, *patterns = Array(tuple)
          Array(roots).flat_map do |root|
            absolute = File.expand_path(root.to_s)
            patterns.map { |pattern| Cache::Descriptor::GlobEntry.compute(root: absolute, pattern: pattern.to_s) }
          end
        end.uniq
      end

      # ADR-60 WD3 — `fetch_or_validate` stores a `[value, dependency_descriptor]` pair, but the producer's
      # declared `serialize:`/`deserialize:` contract covers the VALUE alone. These wrappers apply the custom
      # callable to the value half and Marshal the descriptor half, so a producer with a non-Marshal-clean
      # value keeps working unchanged. A nil callable returns nil — the store's default whole-pair Marshal
      # round-trip applies.
      def pair_serializer(serialize)
        return nil if serialize.nil?

        lambda do |pair|
          value, dependency_descriptor = pair
          Marshal.dump([serialize.call(value).b, Marshal.dump(dependency_descriptor)]).b
        end
      end

      def pair_deserializer(deserialize)
        return nil if deserialize.nil?

        lambda do |bytes|
          value_bytes, descriptor_bytes = Marshal.load(bytes) # rubocop:disable Security/MarshalLoad
          [deserialize.call(value_bytes), Marshal.load(descriptor_bytes)] # rubocop:disable Security/MarshalLoad
        end
      end

      def digest_config(config)
        canonical = Cache::Descriptor.canonicalize_value(config || {})
        Digest::SHA256.hexdigest(JSON.generate(canonical))
      end
    end
  end
end
