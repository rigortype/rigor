# frozen_string_literal: true

module Rigor
  module Plugin
    # Per-run cross-plugin fact store. ADR-9 § "Plugin::FactStore".
    #
    # A plugin publishes typed `(plugin_id, name) -> value` tuples
    # in its `Plugin::Base#prepare(services)` hook (slice 3); other
    # plugins read them in `#diagnostics_for_file` via
    # `services.fact_store.read(plugin_id:, name:)`. The store is
    # constructed fresh at the start of every `Analysis::Runner.run`
    # and discarded at the end — caching the underlying expensive
    # computation is the producer's job (`Plugin::Base.producer`);
    # the FactStore just publishes a *reference* to that
    # already-cached result.
    #
    # `(plugin_id, name)` is a unique key. A second `publish` with
    # the same value is a no-op (`==` comparison); a second
    # `publish` with a different value raises {Conflict}. Since
    # `plugin_id` namespaces the key, a real conflict only happens
    # when a single plugin publishes twice with differing values —
    # the conflict signals a plugin-author bug, never a load-time
    # interaction between unrelated plugins.
    class FactStore
      Fact = Data.define(:plugin_id, :name, :value)

      class Conflict < StandardError
        attr_reader :plugin_id, :name, :existing, :incoming

        def initialize(plugin_id:, name:, existing:, incoming:)
          @plugin_id = plugin_id
          @name = name
          @existing = existing
          @incoming = incoming
          super(
            "fact store conflict: plugin #{plugin_id.inspect} published " \
            "two different values for #{name.inspect} " \
            "(existing: #{existing.inspect}, incoming: #{incoming.inspect})"
          )
        end
      end

      def initialize
        @facts = {}
        @mutex = Mutex.new
      end

      # Writes a `(plugin_id, name) -> value` triple. Idempotent if
      # the same value is published twice (`==`); raises
      # {Conflict} if the values differ.
      #
      # @param plugin_id [String] producing plugin's manifest id.
      # @param name [Symbol, String] fact name (canonicalised to
      #   Symbol for lookup).
      # @param value [Object] frozen-shape value object the
      #   producer chose to publish. The value is stored as-is.
      def publish(plugin_id:, name:, value:)
        plugin_id = plugin_id.to_s
        name = name.to_sym
        @mutex.synchronize do
          existing = @facts[[plugin_id, name]]
          if existing && existing.value != value
            raise Conflict.new(plugin_id: plugin_id, name: name, existing: existing.value, incoming: value)
          end

          @facts[[plugin_id, name]] = Fact.new(plugin_id: plugin_id, name: name, value: value)
        end
        nil
      end

      # @return [Object, nil] the published value, or `nil` when no
      #   fact is registered. Reads do NOT establish a dependency —
      #   `manifest(consumes:)` (slice 4) is the dependency
      #   declaration mechanism.
      def read(plugin_id:, name:)
        fact = @mutex.synchronize { @facts[[plugin_id.to_s, name.to_sym]] }
        fact&.value
      end

      # @return [Boolean] whether a fact is registered.
      def published?(plugin_id:, name:)
        @mutex.synchronize { @facts.key?([plugin_id.to_s, name.to_sym]) }
      end

      # @yield [Fact] every published fact in publication order.
      def each_fact(&)
        snapshot = @mutex.synchronize { @facts.values }
        snapshot.each(&)
      end
    end
  end
end
