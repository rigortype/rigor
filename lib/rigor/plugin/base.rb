# frozen_string_literal: true

require "did_you_mean"
require "digest"
require "json"
require "prism"

require_relative "manifest"
require_relative "node_context"
require_relative "../analysis/diagnostic"
require_relative "../source/node_walker"

module Rigor
  module Plugin
    # Base class every Rigor plugin subclasses. The plugin gem
    # subclasses {Base}, declares its identity through {.manifest},
    # registers the subclass with {Rigor::Plugin.register}, and
    # overrides {#init} to wire up any state it needs from the
    # injected service container.
    #
    # Slice 1 ships only the registration / loading plumbing. The
    # protocol hooks (dynamic-return contributions, type-specifying
    # contributions, dynamic reflection) land in subsequent v0.1.0
    # slices and arrive as additional methods on this class.
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
        # Declares the plugin's manifest. Called once at class
        # definition time — the resulting {Manifest} is cached on
        # the class so {Rigor::Plugin::Loader} reads it without
        # constructing the plugin.
        def manifest(**fields)
          if fields.empty?
            raise ArgumentError, "plugin #{self} did not declare a manifest" unless defined?(@manifest) && @manifest

            return @manifest
          end

          @manifest = Manifest.new(**fields)
        end

        # ADR-7 § "Slice 6-A" — DSL declaration of a cached
        # producer. Plugin authors write
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
        # The block runs through `instance_exec` so `self` inside
        # the body is the plugin instance — `io_boundary`,
        # `services`, `manifest`, `config` are all in scope. The
        # block receives the call-site `params` Hash as its sole
        # argument; the same params Hash mixes into the cache
        # key per `Cache::Descriptor#cache_key_for`.
        #
        # `serialize:` / `deserialize:` are forwarded verbatim to
        # `Cache::Store#fetch_or_compute`. Default round-trip is
        # `Marshal.dump` / `Marshal.load` per the v0.0.9 callable
        # surface; producers whose return values are not Marshal-
        # clean must supply their own pair.
        #
        # Producer ids are auto-prefixed `plugin.<manifest.id>.`
        # at the cache layer (slice 6-C) so plugin-side ids cannot
        # collide with built-in producers.
        def producer(id, serialize: nil, deserialize: nil, &block)
          raise ArgumentError, "Plugin::Base.producer requires a block body" if block.nil?

          @producers ||= {}
          @producers[id.to_sym] = { block: block, serialize: serialize, deserialize: deserialize }.freeze
          id.to_sym
        end

        # Frozen snapshot of the producer table. Inherited
        # producers from a superclass are intentionally NOT
        # surfaced — Plugin::Base subclasses do not chain
        # producers, and the loader instantiates one
        # subclass per registration.
        def producers
          (@producers || {}).dup.freeze
        end

        # ADR-37 slice 1 — declares a node-scoped diagnostic rule.
        # The engine owns a single AST walk per file (see
        # {#node_rule_diagnostics}) and dispatches each node to the
        # rules registered for its type, so a plugin author writes the
        # check, never the traversal:
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
        # `node_type` is a `Prism::Node` subclass; the rule fires for
        # every node where `node.is_a?(node_type)`. The block runs
        # through `instance_exec` so `self` is the plugin instance —
        # `config`, `services`, `io_boundary`, `diagnostic`, and the
        # cross-plugin `services.fact_store` are all in scope. It
        # receives `(node, scope, path, file_context, context)` — the
        # fourth argument is the value built by {.node_file_context} for
        # a two-pass plugin (`nil` otherwise); the fifth is a
        # {Rigor::Plugin::NodeContext} carrying the node's lexical
        # ancestors (enclosing class / method / block DSL). Trailing
        # arguments may be omitted from the block's parameter list. The
        # block MUST return an Array of `Rigor::Analysis::Diagnostic`
        # (an empty array to fire nothing); the runner stamps
        # `plugin.<id>` provenance.
        #
        # Multiple rules for the same `node_type` are allowed and run
        # in declaration order. This is the {.producer}-style class DSL
        # rather than a manifest field because a rule carries logic that
        # needs the plugin instance, not pure data.
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

        # Frozen snapshot of the declared node rules, in declaration
        # order. Not inherited from a superclass — like {.producers},
        # the loader instantiates one subclass per registration.
        def node_rules
          (@node_rules || []).dup.freeze
        end

        # ADR-37 slice 1c — declares a per-file context builder for a
        # two-pass (collect-then-validate) plugin. The block runs once
        # per analysed file (via `instance_exec`, so the plugin instance
        # is `self`) BEFORE any node rule fires, receives `(root, scope)`,
        # and returns an arbitrary file-local value that is threaded to
        # every {.node_rule} block as its fourth argument:
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
        # This is what lets a same-file two-pass plugin drop its
        # hand-rolled validate walk: the collect pass computes the closed
        # namespace once (it MUST complete before validation because a
        # reference may precede its declaration), and the engine owns the
        # validate walk. A cross-file collect belongs in `#prepare` +
        # `services.fact_store` instead — a node rule reads the fact
        # directly and needs no per-file context.
        #
        # Only one builder per plugin; a second declaration replaces the
        # first. The block result is `nil` when none is declared.
        def node_file_context(&block)
          raise ArgumentError, "Plugin::Base.node_file_context requires a block body" if block.nil?

          @node_file_context_block = block
        end

        # The declared per-file context builder block, or nil.
        def node_file_context_block
          defined?(@node_file_context_block) ? @node_file_context_block : nil
        end

        # ADR-37 slice 2 / ADR-52 WD2 — declares a per-call-site
        # return-type contribution, gated by receiver class, method name,
        # or both. The narrow successor to the `return_type` slot of the
        # deleted `flow_contribution_for` hook (ADR-52 WD3):
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
        # `receivers:` is a non-empty Array of class names; the engine
        # calls the block only when the call's receiver type's class
        # equals or inherits from one of them (via
        # `Environment#class_ordering`). It MAY be omitted — then the rule
        # is receiver-independent and fires on `methods:` alone.
        #
        # `methods:` is an Array of Symbol method names. When provided, the
        # block is skipped unless `call_node.name` is in the list —
        # declarative and cheaper than an in-block guard (the engine
        # compiles it into the registry's contribution table, ADR-52 WD1).
        # It is REQUIRED when `receivers:` is omitted: a rule gated on
        # neither would fire on every dispatch, which is exactly the
        # ungated cost the `flow_contribution_for` escape valve carries —
        # `dynamic_return` declines to reintroduce it.
        #
        # Method-name and type-shape refinement can still be done inside
        # the block. The block runs through `instance_exec`, so `config`
        # / `services` are in scope.
        # ADR-52 slice 3 — `receivers:` may also be a **callable**
        # (a `-> { ... }` resolved once per run, lazily, the first time
        # the rule is consulted — always after `#prepare`) for a receiver
        # set the plugin only knows at run time:
        #
        #   dynamic_return receivers: -> { attachment_index.model_names } do |call_node, scope|
        #     # fires when the receiver class is one a `prepare`-time scan
        #     # found; the block does the precise per-call lookup
        #   end
        #
        # The callable runs through `instance_exec`, so it reads the
        # plugin's own `#prepare`-built indexes. It MUST be idempotent and
        # post-`#prepare`-safe — reference a lazily-built / memoised index
        # (as activestorage's `attachment_index` and activerecord's
        # `model_index` are), never a value captured at class-definition
        # time. The resolved set is a safe over-approximation of the
        # block's own filter (it admits subclasses too), so the block
        # stays the precise gate and diagnostics are unchanged.
        #
        # ADR-52 slice 4 — `methods:` may ALSO be a callable, for a
        # method-name set the plugin only knows at run time (a Sorbet
        # catalog's keys, a config-derived DSL method name):
        #
        #   dynamic_return methods: -> { catalog.method_names } do |call_node, scope|
        #     ...
        #   end
        #
        # Same contract as a callable `receivers:` — `instance_exec`'d,
        # resolved lazily after `#prepare`, memoised, idempotent. A
        # callable method set cannot be compiled into the registry's
        # name gate (it is unknown at registry-build time), so the
        # plugin is consulted on every dispatch and the name filter runs
        # in this instance path instead — the block still only fires for
        # a listed name, so diagnostics are unchanged.
        # ADR-52 slice 5a — `file_methods:` is the per-file
        # specialisation of the run-time `methods:` callable, for a name
        # set that varies per analysed file (rigor-rspec's `let` names —
        # the names depend on each file's `describe`/`let` structure, so
        # one run-wide set cannot exist). The callable receives the file
        # path, runs through `instance_exec`, and is memoised per
        # `(rule, path)`:
        #
        #   dynamic_return file_methods: ->(path) { let_names_for(path) } do |call_node, scope|
        #     ...
        #   end
        #
        # Same idempotence contract as the other callables, plus: it MUST
        # tolerate any path the engine analyses (return `[]` / nil for a
        # file it has no names for — never raise). Like a callable
        # `methods:`, it cannot compile into the registry name gate, so
        # the plugin is consulted on every dispatch and filtered here.
        # `file_methods:` replaces `methods:` (declaring both is
        # rejected — they are the same gate at two scopes); it MAY
        # combine with `receivers:`.
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

        # A class-name Array is frozen element-wise; a run-time callable
        # (ADR-52 slice 3) is stored verbatim and resolved per instance.
        def normalize_dynamic_return_receivers(receivers)
          return nil if receivers.nil?
          return receivers if receivers.respond_to?(:call)

          receivers.map { |r| r.dup.freeze }.freeze
        end
        private :normalize_dynamic_return_receivers

        # A method-name Array is symbol-normalised + frozen; a run-time
        # callable (ADR-52 slice 4) is stored verbatim and resolved per
        # instance.
        def normalize_dynamic_return_methods(methods)
          return nil if methods.nil?
          return methods if methods.respond_to?(:call)

          methods.map(&:to_sym).freeze
        end
        private :normalize_dynamic_return_methods

        # Frozen snapshot of the declared dynamic-return rules. Memoised:
        # `@dynamic_returns` is built once at class-definition time (via
        # `dynamic_return`) and never mutated during analysis, and every
        # element is already frozen, so a fresh `dup.freeze` per call was
        # pure waste — the engine calls this for every plugin on every
        # dispatch (`collect_plugin_contributions`), making it a top
        # allocation site on plugin-heavy projects. The cached frozen
        # array is immutable, so sharing one instance across callers is
        # safe.
        # rubocop:disable Naming/MemoizedInstanceVariableName -- the
        # natural name `@dynamic_returns` is the canonical (mutable-at-
        # definition) store this snapshots; the memo must be distinct.
        def dynamic_returns
          @dynamic_returns_snapshot ||= (@dynamic_returns || []).dup.freeze
        end
        # rubocop:enable Naming/MemoizedInstanceVariableName

        # ADR-52 WD2 — a rule must gate on something. `receivers:` alone,
        # `methods:` alone, or both are valid; neither is not (it would
        # fire on every dispatch).
        def validate_dynamic_return_gate!(receivers, methods, file_methods)
          return unless receivers.nil? && file_methods.nil?
          return if (methods.is_a?(Array) && !methods.empty?) || methods.respond_to?(:call)

          raise ArgumentError,
                "Plugin::Base.dynamic_return requires receivers:, methods:, or file_methods: — a rule " \
                "gated on none would fire on every dispatch (that is what flow_contribution_for is for)"
        end

        # ADR-52 slice 5a — `file_methods:` must be a callable, and is
        # mutually exclusive with `methods:` (one name gate, two scopes —
        # declaring both is a contradiction, not a composition).
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
          # ADR-52 slice 3 — a run-time callable is resolved per instance
          # after `#prepare`; its shape is checked at resolution time.
          return if receivers.respond_to?(:call)
          return if receivers.is_a?(Array) && !receivers.empty? && receivers.all? { |r| r.is_a?(String) && !r.empty? }

          raise ArgumentError,
                "Plugin::Base.dynamic_return receivers: must be a non-empty Array of class-name Strings " \
                "or a callable, got #{receivers.inspect}"
        end

        def validate_dynamic_return_methods!(methods)
          return if methods.nil?
          # ADR-52 slice 4 — a run-time callable resolves to the name set
          # per instance after `#prepare`; its shape is checked then.
          return if methods.respond_to?(:call)
          return if methods.is_a?(Array) && !methods.empty? &&
                    methods.all? { |m| m.is_a?(Symbol) || (m.is_a?(String) && !m.empty?) }

          raise ArgumentError,
                "Plugin::Base.dynamic_return methods: must be a non-empty Array of Symbol/String, a callable, " \
                "or nil, got #{methods.inspect}"
        end

        private :validate_dynamic_return_gate!, :validate_dynamic_return_receivers!,
                :validate_dynamic_return_methods!, :validate_dynamic_return_file_methods!

        # ADR-37 slice 2 — declares a predicate/assertion narrowing
        # contribution, method-gated. The narrow successor to the
        # `post_return_facts` slot of the deleted `flow_contribution_for`
        # hook (ADR-52 WD3):
        #
        #   type_specifier methods: [:assert_kind_of] do |call_node, scope|
        #     # return an Array of post-return facts, or nil
        #   end
        #
        # `methods:` is a non-empty Array of method names; the engine
        # calls the block only when `call_node.name` is one of them. The
        # block returns the same `post_return_facts` the merger applies.
        def type_specifier(methods:, &block)
          raise ArgumentError, "Plugin::Base.type_specifier requires a block body" if block.nil?
          unless methods.is_a?(Array) && !methods.empty? &&
                 methods.all? { |m| m.is_a?(Symbol) || (m.is_a?(String) && !m.empty?) }
            raise ArgumentError,
                  "Plugin::Base.type_specifier methods: must be a non-empty Array of Symbol/String, " \
                  "got #{methods.inspect}"
          end

          @type_specifiers ||= []
          @type_specifiers << { methods: methods.map(&:to_sym).freeze, block: block }.freeze
          nil
        end

        # Frozen snapshot of the declared type-specifier rules. Memoised
        # for the same reason as {dynamic_returns} — consulted per plugin
        # per dispatch, over an array fixed at class-definition time.
        # rubocop:disable Naming/MemoizedInstanceVariableName -- see dynamic_returns
        def type_specifiers
          @type_specifiers_snapshot ||= (@type_specifiers || []).dup.freeze
        end
        # rubocop:enable Naming/MemoizedInstanceVariableName
      end

      attr_reader :services, :config

      def initialize(services:, config: {})
        @services = services
        @config = merge_config_defaults(config).freeze
        # ADR-52 slice 3 — per-rule cache of resolved run-time
        # `dynamic_return receivers:` callables. Created here (before any
        # subclass `initialize` freezes the instance) so the lazy
        # memo-on-first-dispatch is a Hash-content mutation, sound even on
        # a self-freezing plugin.
        @dynamic_return_runtime_cache = {}
      end

      # Override in subclasses to wire any state the plugin needs
      # from the injected service container. Default is a no-op so
      # plugins that only contribute through later-slice protocol
      # hooks do not have to define an explicit body.
      def init(services) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      # NOTE: (ADR-52 WD3): the legacy ungated per-call hook
      # `flow_contribution_for` was DELETED here pre-1.0 after its five
      # production users migrated. Per-call return types are declared via
      # the gated {.dynamic_return} DSL (static / run-time / per-file
      # name sets, static / run-time receiver sets); post-return
      # narrowing facts via {.type_specifier}. See the CHANGELOG
      # migration note for the idiom-by-idiom mapping.

      # ADR-9 slice 3 — per-run preparation hook. The runner
      # invokes `#prepare(services)` on every loaded plugin once
      # per `Analysis::Runner.run`, after `#init` has run on every
      # plugin and before any `#diagnostics_for_file` call.
      # Plugins use this hook to compute and publish facts other
      # plugins consume:
      #
      #   def prepare(services)
      #     services.fact_store.publish(
      #       plugin_id: manifest.id, name: :model_index, value: model_index
      #     )
      #   end
      #
      # Default no-op so plugins without facts to publish leave
      # `#prepare` unimplemented. Failures isolate as
      # `:plugin_loader runtime-error` diagnostics; a plugin that
      # raises in `#prepare` has its facts considered un-published
      # and downstream consumers see `nil` from `fact_store.read`.
      #
      # Slice 3 calls plugins in registration order. ADR-9 slice 5
      # introduces topological ordering by `consumes:` so producers
      # always run before consumers.
      def prepare(services) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      # ADR-7 § "Slice 5-A" — per-file diagnostic emission hook.
      # Override in plugin subclasses to return an array of
      # `Rigor::Analysis::Diagnostic` rows for the analysed file.
      # The runner stamps each returned diagnostic with
      # `source_family: "plugin.<manifest.id>"` automatically per
      # ADR-7 § "Slice 5-B"; plugin authors should construct
      # diagnostics without setting `source_family` (any value
      # they pass is overwritten).
      #
      # `path` is the analysed file path; `scope` is the entry
      # `Rigor::Scope` after `ScopeIndexer` ran; `root` is the
      # parsed `Prism::Node` root. Plugin authors traverse `root`
      # themselves if they need node-scoped rules — the
      # `Rule<TNode>` API ADR-2 § "Custom rules" mentions stays
      # deferred to v0.1.x.
      #
      # Default returns `[]` so plugins that contribute through
      # other channels (e.g. slice-4 narrowing contributions,
      # slice-6 cache producers) do not have to override.
      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        []
      end

      # ADR-37 slice 1 — runs the plugin's declared {.node_rule}s over
      # one file and returns their diagnostics. The engine owns the
      # single AST walk here so plugin authors never hand-roll a
      # traversal: every node reachable from `root` is offered to each
      # rule whose `node_type` it satisfies (`node.is_a?`), the rule's
      # block is `instance_exec`'d on this plugin instance with
      # `(node, scope, path)`, and the returned diagnostics are
      # concatenated in (node, declaration) order.
      #
      # Returns `[]` immediately when the plugin declares no node rules,
      # so it is a zero-cost no-op for every plugin that does not use
      # the DSL. The runner calls it alongside `#diagnostics_for_file`
      # and stamps `plugin.<id>` provenance on the result; a raise
      # propagates to the runner's per-plugin isolation boundary.
      def node_rule_diagnostics(path:, scope:, root:)
        rules = self.class.node_rules
        return [] if rules.empty? || root.nil?

        # ADR-37 slice 1c — build the per-file context once (the
        # "collect" pass) before the engine-owned validate walk, so a
        # two-pass plugin sees the closed namespace at every node.
        context_block = self.class.node_file_context_block
        file_context = context_block ? instance_exec(root, scope, &context_block) : nil

        diagnostics = []
        Source::NodeWalker.each_with_ancestors(root) do |node, ancestors|
          # One frozen NodeContext per node, shared across the rules
          # that match it (ADR-52 WD1) — built lazily so non-matching
          # nodes (the vast majority) allocate nothing.
          context = nil
          rules.each do |rule|
            next unless node.is_a?(rule[:node_type])

            context ||= NodeContext.new(ancestors)
            diagnostics.concat(Array(instance_exec(node, scope, path, file_context, context, &rule[:block])))
          end
        end
        diagnostics
      end

      # ADR-37 slice 2 — the return type contributed by this plugin's
      # {.dynamic_return} rules for a call, or nil. The engine calls this
      # from `MethodDispatcher`; a rule fires only when `receiver_type`'s
      # class equals or inherits from one of its declared `receivers:`.
      # First non-nil wins (declaration order). Failures isolate to nil.
      def dynamic_return_type(call_node:, scope:, receiver_type:)
        rules = self.class.dynamic_returns
        return nil if rules.empty? || receiver_type.nil?

        # `class_name` is nil for a receiver carrier with no nominal
        # class (a refinement dimension, an inferred shape) — fine for a
        # receiver-less (methods-only) rule (ADR-52 WD2), which gates on
        # the method name alone and reads the receiver shape inside its
        # own block.
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

      # ADR-37 slice 2 — the post-return narrowing facts contributed by
      # this plugin's {.type_specifier} rules for a call. The engine
      # calls this from `StatementEvaluator`; a rule fires only when
      # `call_node.name`
      # is one of its declared `methods:`. Failures isolate to [].
      def type_specifier_facts(call_node:, scope:)
        rules = self.class.type_specifiers
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

      # Builds a `Rigor::Analysis::Diagnostic` positioned at a Prism
      # `node` for return from `#diagnostics_for_file`. Internalises the
      # 1-based `line` / `start_column + 1` convention every plugin
      # otherwise re-derives by hand, so authors pass the node and the
      # message/severity/rule rather than unpacking `node.location`.
      #
      # `source_family` is intentionally NOT accepted — the runner
      # stamps `plugin.<manifest.id>` on every returned diagnostic
      # (ADR-7 § "Slice 5-B"), so any value set here would be
      # overwritten.
      # Pass `location:` (a Prism location) to point the diagnostic at a
      # sub-location of `node` rather than `node.location` — typically
      # `node.message_loc` so a matcher / method-name diagnostic points
      # at the name, not the receiver-spanning whole call. A `nil`
      # `location:` falls back to `node.location`, so
      # `location: node.message_loc` reproduces the common
      # `message_loc || location` idiom.
      def diagnostic(node, path:, message:, severity: :error, rule: nil, location: nil)
        Analysis::Diagnostic.from_location(
          location || node.location,
          path: path, message: message, severity: severity, rule: rule
        )
      end

      # Boilerplate-reduction helper (review §1.3): the "did you mean …?"
      # suggestion every diagnostic-emitting plugin otherwise hand-rolls.
      # Returns the closest of `candidates` to `name` via
      # `DidYouMean::SpellChecker` (the same engine Ruby's own
      # `NoMethodError` hints use), or `nil` when there is no good match /
      # no candidates — replacing the per-plugin Levenshtein copies. A
      # **class** method so it is callable both from a plugin instance
      # (`Rigor::Plugin::Base.suggest(...)`) and from an `Analyzer` module
      # function that has no instance.
      def self.suggest(name, candidates)
        dictionary = Array(candidates).map(&:to_s)
        return nil if dictionary.empty?

        DidYouMean::SpellChecker.new(dictionary: dictionary).correct(name.to_s).first
      end

      # Convenience accessor — `manifest` on the instance returns
      # the class-level manifest declaration.
      def manifest
        self.class.manifest
      end

      # ADR-25 — absolute RBS signature directories this plugin
      # contributes. Resolves each `manifest.signature_paths` entry
      # (declared relative to the plugin gem root) against that
      # root. The gem root is the directory above `lib/` in the
      # file that defined the plugin class (falling back to that
      # file's directory for a non-conventional layout). Returns
      # `[]` when the manifest declares no `signature_paths:` or
      # the class is anonymous (an anonymous class cannot ship a
      # gem). `Plugin::Loader` validates the resolved dirs exist at
      # load time; `Environment.for_project` merges them into the
      # signature-path set fed to `RbsLoader`.
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

      # ADR-28 — the path-scoped method-protocol contracts this
      # plugin contributes. Defaults to the manifest-declared
      # `protocol_contracts:`; the same indirection
      # `#signature_paths` uses, so a plugin MAY override this to
      # fold per-project config into the contract set (e.g.
      # substituting the convention `path_glob` with a user-supplied
      # one) without the manifest having to be config-aware.
      # `Plugin::Registry#protocol_contracts` aggregates the result
      # across loaded plugins.
      def protocol_contracts
        manifest.protocol_contracts
      end

      # ADR-7 § "Slice 6-A/6-B" — per-plugin {IoBoundary}.
      # Memoised so the boundary's accumulated `FileEntry`
      # rows persist across producer invocations within the
      # same plugin instance and feed cache invalidation
      # via `cache_for`.
      def io_boundary
        @io_boundary ||= services.io_boundary_for(manifest.id)
      end

      # ADR-7 § "Slice 6-A" — returns a callable that performs
      # a `Cache::Store#fetch_or_compute` round-trip for the
      # named producer. The descriptor (per ADR-7 § "Slice
      # 6-B") is auto-assembled from the plugin's
      # `PluginEntry` template (id, version, config_hash) and
      # the {IoBoundary} read history. The producer id is
      # auto-prefixed `plugin.<manifest.id>.` per ADR-7 §
      # "Slice 6-C" so plugin caches stay sandboxed from
      # built-in producers.
      #
      # When `services.cache_store` is `nil` (e.g. CLI
      # `--no-cache`), the callable bypasses the cache and
      # runs the producer block every time — same semantics
      # as the v0.0.9 cache surface for built-in producers.
      #
      # `descriptor:` (optional, ADR-7 § "Slice 6" follow-up)
      # supplies extra `Cache::Descriptor` rows the plugin
      # author wants to compose into the auto-built descriptor
      # — typically gem-version `GemEntry`, configuration-file
      # `FileEntry` digests, or `ConfigEntry` rows for external
      # state the {IoBoundary} cannot capture itself. The
      # passed descriptor composes via `Cache::Descriptor.compose`
      # with the auto-built one (PluginEntry template + boundary
      # reads); per-slot conflicts raise
      # `Cache::Descriptor::Conflict` to make divergent inputs
      # visible rather than silently shadowing.
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
        composed_descriptor = compose_cache_descriptor(descriptor)
        lambda do
          store.fetch_or_compute(
            producer_id: prefixed_id,
            params: params,
            descriptor: composed_descriptor,
            serialize: producer[:serialize],
            deserialize: producer[:deserialize],
            &compute
          )
        end
      end

      # Builds a `Cache::Descriptor` covering every file matched by
      # `pattern` (a glob, e.g. `"**/*.rb"`) under any of `roots`.
      # Each matching file contributes a `:digest`-comparator
      # `FileEntry` so the cache invalidates on any content change,
      # any addition (a newly-glob-matched file appears in the
      # descriptor), or any removal (the previously-matched file
      # drops out).
      #
      # Pass the returned descriptor as `cache_for(..., descriptor: …)`
      # so the cache key reflects the project files the producer
      # reads from. Without it, `Plugin::Base#cache_for`'s
      # auto-built descriptor only includes files the
      # {Plugin::IoBoundary} has already read in the current
      # process — empty on the first call of a fresh process — so
      # the cache key is identical regardless of project state and
      # warm runs return stale producer output when files have
      # changed between sessions.
      #
      # Discovery-style producers (`actioncable`'s `:channel_index`,
      # `actionmailer`'s `:mailer_index`, `rails-i18n`'s
      # `:locale_index`) all follow the same pattern: walk a glob
      # under one or more search roots, parse / read every match,
      # build a typed index. They MUST call this helper at the
      # `cache_for(descriptor: …)` site to be cache-correct under
      # the persistent `Cache::Store` `rigor check` uses by
      # default.
      #
      # The helper pays one SHA-256 read per matched file at
      # call time; the producer block typically re-reads through
      # `io_boundary.read_file` so the cost is doubled. For
      # discovery globs in the 10-100 file range this is
      # negligible (~ms) relative to the parse + walk the
      # producer does on cache miss.
      #
      # @param roots    [Array<String>] search roots (relative to
      #   the project root, or absolute paths)
      # @param patterns [Array<String>] glob suffixes joined under
      #   each root via `File.join(root, pattern)`. Multiple
      #   patterns union into one descriptor (`"**/*.erb",
      #   "**/*.html"` etc.).
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

      private

      # ADR-40 — merge the manifest's declared `config_schema`
      # `default:` values *under* the user-supplied config (user wins),
      # so a plugin reads `config.fetch("key")` and gets the declared
      # default with no `DEFAULT_*` constant. A class declared without a
      # manifest (test doubles) keeps the raw config unchanged.
      def merge_config_defaults(config)
        unless self.class.instance_variable_defined?(:@manifest) && self.class.instance_variable_get(:@manifest)
          return config
        end

        self.class.manifest.config_defaults.merge(config)
      end

      # ADR-37 slice 2 — the class name to match a `dynamic_return`
      # `receivers:` entry against, from a receiver `Type`. Covers the
      # instance (`Nominal[X]`) and class (`Singleton[X]`) shapes; other
      # carriers decline (nil → no match).
      def dynamic_return_receiver_class_name(receiver_type)
        case receiver_type
        when Rigor::Type::Nominal, Rigor::Type::Singleton then receiver_type.class_name
        end
      end

      # The gate for one `dynamic_return` rule. Method-name gate first —
      # a Symbol-array probe vs the receiver ancestry resolution below
      # (ADR-52 WD1); both are pure predicates, so order only affects
      # cost. A receiver-less rule (ADR-52 WD2) skips the ancestry check
      # entirely and fires on the method name alone.
      def dynamic_return_rule_applies?(rule, call_node, class_name, environment, scope)
        return false if rule[:methods] && !resolved_dynamic_return_methods(rule).include?(call_node.name)

        if rule[:file_methods]
          # The path is read here, not in `dynamic_return_type`, so a
          # spec-double scope without `source_path` only affects
          # `file_methods:` rules (other gate forms never touch it).
          path = scope.respond_to?(:source_path) ? scope.source_path : nil
          return false unless resolved_dynamic_return_file_methods(rule, path).include?(call_node.name)
        end

        receivers = resolved_dynamic_return_receivers(rule)
        return true if receivers.nil?
        return false if class_name.nil?

        receivers.any? { |c| class_matches_receiver?(class_name, c, environment) }
      end

      # ADR-52 slice 4 — the rule's method-name set. A static Array is
      # returned as-is (`#include?` over Symbols); a run-time callable is
      # `instance_exec`'d against this plugin and memoised as a Symbol Set,
      # same lazy/idempotent contract as a callable `receivers:`. The
      # cache key is namespaced so a rule that makes both `methods:` and
      # `receivers:` callable keeps two distinct memo slots.
      def resolved_dynamic_return_methods(rule)
        methods = rule[:methods]
        return methods unless methods.respond_to?(:call)

        (@dynamic_return_runtime_cache ||= {})[[:methods, rule]] ||=
          Array(instance_exec(&methods)).to_set(&:to_sym).freeze
      end

      # ADR-52 slice 5a — the rule's per-file method-name set. The
      # `file_methods:` callable is `instance_exec`'d with the file path
      # and memoised per `(rule, path)` — one resolution per analysed
      # file, the per-file analogue of the run-wide `methods:` memo. A
      # nil path (synthetic call sites with no file context) resolves to
      # the empty set: the gate has nothing to key on, so the rule
      # declines — fail-closed, consistent with the gate's purpose. A
      # raising callable degrades to "declines this dispatch" via
      # `dynamic_return_type`'s surrounding rescue.
      EMPTY_NAME_SET = Set.new.freeze
      private_constant :EMPTY_NAME_SET

      def resolved_dynamic_return_file_methods(rule, path)
        return EMPTY_NAME_SET if path.nil?

        (@dynamic_return_runtime_cache ||= {})[[:file_methods, rule, path]] ||=
          Array(instance_exec(path, &rule[:file_methods])).to_set(&:to_sym).freeze
      end

      # ADR-52 slice 3 — the rule's receiver class-name Array. A static
      # Array is returned as-is; a run-time callable is `instance_exec`'d
      # against this plugin (so it reads the `#prepare`-built indexes) and
      # memoised per rule for the run. Resolution is lazy — first reached
      # during file analysis, always after `#prepare` — and the callable
      # is required to be idempotent, so the memoised set is stable. A
      # callable that raises degrades to "no receivers match" (the rule
      # declines), never a crash, consistent with the surrounding rescue.
      def resolved_dynamic_return_receivers(rule)
        receivers = rule[:receivers]
        return receivers unless receivers.respond_to?(:call)

        # `||= {}` keeps the path correct even when a caller bypassed
        # `initialize` (`allocate` in unit specs that inject a fake
        # index); a self-freezing plugin already has the Hash from
        # `initialize`, so the `||=` is a no-op there (never a FrozenError).
        (@dynamic_return_runtime_cache ||= {})[rule] ||=
          Array(instance_exec(&receivers)).map { |c| c.to_s.dup.freeze }.freeze
      end

      # True when `class_name` equals or inherits from `constraint`,
      # matched through `Environment#class_ordering` (the mechanism
      # `MacroBlockSelfType` / `additional_initializers` use). Degrades to
      # "no match" on any resolution failure (false-positive-safe).
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

      # ADR-7 § "Slice 6-B" — composes the per-call cache
      # descriptor from (1) the plugin's PluginEntry template
      # and (2) the IoBoundary's accumulated FileEntry rows.
      def build_plugin_cache_descriptor
        boundary_descriptor = io_boundary.cache_descriptor
        Cache::Descriptor.new(
          plugins: [plugin_entry],
          files: boundary_descriptor.files
        )
      end

      public

      # ADR-32 WD5 — the `Cache::Descriptor::PluginEntry`
      # template carrying this plugin's id, version, and a
      # SHA-256 digest of its (canonicalised) config hash.
      # Callers outside the plugin (e.g. `Environment.for_project`
      # caching per-file synthesizer output) compose this entry
      # into their own cache descriptor so a config change to
      # the plugin (e.g. flipping `require_magic_comment:`)
      # invalidates the dependent cache.
      def plugin_entry
        # Built fresh on each call rather than memoised so a
        # plugin subclass that freezes itself in `initialize`
        # (e.g. `Rigor::Plugin::RbsInline` per ADR-32) doesn't
        # trip a FrozenError on first read. The construction
        # cost is a single `Data.define`-backed value-object
        # build; the cache key derivation downstream is the
        # expensive step, and it's already memoised inside
        # `Cache::Store`.
        Cache::Descriptor::PluginEntry.new(
          id: manifest.id,
          version: manifest.version,
          config_hash: digest_config(config)
        )
      end

      private

      # ADR-7 § "Slice 6" follow-up — composes the auto-built
      # cache descriptor with an optional plugin-author-supplied
      # extension. Extra `GemEntry` / `FileEntry` / `ConfigEntry`
      # rows the plugin needs (gem-version pins, external
      # configuration files, sibling-plugin state) flow through
      # `Cache::Descriptor.compose`; the union behaviour matches
      # built-in producers (`RbsConstantTable`, `RbsEnvironment`).
      def compose_cache_descriptor(extra)
        auto_built = build_plugin_cache_descriptor
        return auto_built if extra.nil?

        Cache::Descriptor.compose(auto_built, extra)
      end

      def digest_config(config)
        canonical = Cache::Descriptor.canonicalize_value(config || {})
        Digest::SHA256.hexdigest(JSON.generate(canonical))
      end
    end
  end
end
