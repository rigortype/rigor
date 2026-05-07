# frozen_string_literal: true

require "digest"
require "json"

require_relative "manifest"

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
    class Base
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
      end

      attr_reader :services, :config

      def initialize(services:, config: {})
        @services = services
        @config = config.freeze
      end

      # Override in subclasses to wire any state the plugin needs
      # from the injected service container. Default is a no-op so
      # plugins that only contribute through later-slice protocol
      # hooks do not have to define an explicit body.
      def init(services) # rubocop:disable Lint/UnusedMethodArgument
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

      # Convenience accessor — `manifest` on the instance returns
      # the class-level manifest declaration.
      def manifest
        self.class.manifest
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

      private

      # ADR-7 § "Slice 6-B" — composes the per-call cache
      # descriptor from (1) the plugin's PluginEntry template
      # and (2) the IoBoundary's accumulated FileEntry rows.
      def build_plugin_cache_descriptor
        plugin_entry = Cache::Descriptor::PluginEntry.new(
          id: manifest.id,
          version: manifest.version,
          config_hash: digest_config(config)
        )
        boundary_descriptor = io_boundary.cache_descriptor
        Cache::Descriptor.new(
          plugins: [plugin_entry],
          files: boundary_descriptor.files
        )
      end

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
