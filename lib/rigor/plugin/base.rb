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

        # ADR-37 slice 2 — declares a per-call-site return-type
        # contribution, receiver-gated (and optionally method-gated). The
        # narrow successor to the `return_type` slot of
        # `flow_contribution_for`:
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
        # `receivers:` is a non-empty Array of class names; the engine
        # calls the block only when the call's receiver type's class
        # equals or inherits from one of them (via
        # `Environment#class_ordering`).
        #
        # `methods:` is an optional Array of Symbol method names. When
        # provided, the block is also skipped unless `call_node.name` is
        # in the list — equivalent to `next if call_node.name != :foo`
        # at the top of the block, but declarative and cheaper (the
        # check runs before the block is entered). When omitted, every
        # method on a matching receiver is forwarded to the block as
        # before (backwards-compatible with existing rules).
        #
        # Method-name and type-shape refinement can still be done inside
        # the block. The block runs through `instance_exec`, so `config`
        # / `services` are in scope.
        def dynamic_return(receivers:, methods: nil, &block)
          raise ArgumentError, "Plugin::Base.dynamic_return requires a block body" if block.nil?

          validate_dynamic_return_receivers!(receivers)
          validate_dynamic_return_methods!(methods)

          normalized_methods = methods&.map(&:to_sym)&.freeze

          @dynamic_returns ||= []
          @dynamic_returns << {
            receivers: receivers.map { |r| r.dup.freeze }.freeze,
            methods: normalized_methods,
            block: block
          }.freeze
          nil
        end

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

        def validate_dynamic_return_receivers!(receivers)
          return if receivers.is_a?(Array) && !receivers.empty? && receivers.all? { |r| r.is_a?(String) && !r.empty? }

          raise ArgumentError,
                "Plugin::Base.dynamic_return receivers: must be a non-empty Array of class-name Strings, " \
                "got #{receivers.inspect}"
        end

        def validate_dynamic_return_methods!(methods)
          return if methods.nil?
          return if methods.is_a?(Array) && !methods.empty? &&
                    methods.all? { |m| m.is_a?(Symbol) || (m.is_a?(String) && !m.empty?) }

          raise ArgumentError,
                "Plugin::Base.dynamic_return methods: must be a non-empty Array of Symbol/String or nil, " \
                "got #{methods.inspect}"
        end

        private :validate_dynamic_return_receivers!, :validate_dynamic_return_methods!

        # ADR-37 slice 2 — declares a predicate/assertion narrowing
        # contribution, method-gated. The narrow successor to the
        # `post_return_facts` slot of `flow_contribution_for`:
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
      end

      # Override in subclasses to wire any state the plugin needs
      # from the injected service container. Default is a no-op so
      # plugins that only contribute through later-slice protocol
      # hooks do not have to define an explicit body.
      def init(services) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

      # ADR-2 § "Flow Contribution Bundle" / v0.1.1 Track 2
      # slice 7 — per-call return-type contribution hook. When
      # the inference engine dispatches a `Prism::CallNode` and
      # neither the precision tiers nor RBS resolve a result,
      # `MethodDispatcher` consults each loaded plugin via this
      # hook ahead of `RbsDispatch`. Plugins that override the
      # default return a {Rigor::FlowContribution} bundle whose
      # `return_type` slot pins the call site's result type.
      #
      # Default returns nil — plugins that don't refine return
      # types skip the override. Failures are isolated: a hook
      # that raises gets its contribution dropped silently for
      # this call so the rest of the dispatch chain continues.
      def flow_contribution_for(call_node:, scope:) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end

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
      # from `MethodDispatcher` alongside (and ahead of) the legacy
      # `flow_contribution_for`; a rule fires only when `receiver_type`'s
      # class equals or inherits from one of its declared `receivers:`.
      # First non-nil wins (declaration order). Failures isolate to nil.
      def dynamic_return_type(call_node:, scope:, receiver_type:)
        rules = self.class.dynamic_returns
        return nil if rules.empty? || receiver_type.nil?

        class_name = dynamic_return_receiver_class_name(receiver_type)
        return nil if class_name.nil?

        environment = scope&.environment
        rules.each do |rule|
          # Method-name gate first — a Symbol-array probe vs the
          # receiver ancestry resolution below (ADR-52 WD1). Both are
          # pure predicates, so the order only affects cost.
          next if rule[:methods] && !rule[:methods].include?(call_node.name)
          next unless rule[:receivers].any? { |c| class_matches_receiver?(class_name, c, environment) }

          result = instance_exec(call_node, scope, &rule[:block])
          return result if result
        end
        nil
      rescue StandardError
        nil
      end

      # ADR-37 slice 2 — the post-return narrowing facts contributed by
      # this plugin's {.type_specifier} rules for a call. The engine
      # calls this from `StatementEvaluator` alongside the legacy
      # `flow_contribution_for`; a rule fires only when `call_node.name`
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
