# frozen_string_literal: true

require_relative "blueprint"

module Rigor
  module Plugin
    # Read-side query API over the plugins loaded for a single
    # `Analysis::Runner.run`. Constructed by
    # {Rigor::Plugin::Loader.load} and exposed downstream so the
    # contribution merger (slice 3) and diagnostic provenance
    # (slice 5) can iterate over loaded plugin instances in
    # deterministic order.
    #
    # The registry is read-only after construction; ordering is
    # the order in which {Rigor::Plugin::Loader} resolved
    # configuration entries, which is project-config order with
    # plugin-id alphabetical as the tie-breaker.
    #
    # ADR-15 Phase 3 — alongside the instantiated `plugins`, the
    # registry carries `blueprints`: a frozen, Ractor-shareable
    # `Array<Blueprint>` that records how to re-instantiate the
    # same plugin set in a worker Ractor. The eventual Phase 4
    # pool ships `blueprints` across the boundary and calls
    # {.materialize} per-Ractor; the live `plugins` carriage on
    # the coordinator registry stays unchanged.
    class Registry
      attr_reader :plugins, :load_errors, :blueprints

      # @param plugins [Array<Rigor::Plugin::Base>] instantiated
      #   plugin instances in deterministic order.
      # @param load_errors [Array<Rigor::Plugin::LoadError>] failures
      #   surfaced during loading. Each error is also turned into a
      #   diagnostic by the runner.
      # @param blueprints [Array<Rigor::Plugin::Blueprint>] frozen,
      #   Ractor-shareable replay descriptors aligned 1:1 with
      #   `plugins`. The loader fills this in; callers that
      #   construct Registry manually MAY pass `[]` and accept
      #   that {.materialize} cannot replay the set.
      def initialize(plugins: [], load_errors: [], blueprints: [])
        @plugins = plugins.dup.freeze
        @load_errors = load_errors.dup.freeze
        @blueprints = blueprints.dup.freeze
        freeze
      end

      # ADR-15 Phase 3 — build a fresh Registry from the supplied
      # blueprint set by replaying {Blueprint#materialize} per
      # entry against `services`. The returned registry carries
      # NEW plugin instances (mutable per-Ractor accumulators
      # included) and the same blueprint set, so a worker can
      # hand the materialised registry to Environment without
      # losing the replay handle. `load_errors` is intentionally
      # empty: load-time failures already surfaced in the
      # coordinator registry and don't repeat per worker.
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

      # ADR-13 slice 2 — flat ordered list of every loaded
      # plugin's manifest-declared {TypeNodeResolver} instances,
      # in plugin registration order. Slice 3 wires this into
      # the parser's resolver chain; until then the method is a
      # read-side aggregator only. The first non-nil
      # `#resolve(node, scope)` return wins per ADR-13 WD3 / WD5
      # — registration order is the user's lever.
      def type_node_resolvers
        plugins.flat_map { |plugin| plugin.manifest.type_node_resolvers }
      end

      # ADR-20 slice 6 — aggregate every loaded plugin's
      # manifest-declared HKT registrations + definitions
      # into a single `Inference::HktRegistry` overlay that
      # `Environment#hkt_registry` merges on top of the
      # bundled `Builtins::HktBuiltins.registry`. Last
      # plugin to register a URI wins (registration order
      # determined by the user's `plugins:` list); user
      # `.rbs` overlays merge on top of this overlay last.
      # Returns `Inference::HktRegistry::EMPTY` when no
      # plugin contributes HKT entries so callers can skip
      # the merge.
      def hkt_overlay_registry
        registrations = plugins.flat_map { |plugin| plugin.manifest.hkt_registrations }
        definitions = plugins.flat_map { |plugin| plugin.manifest.hkt_definitions }
        return Inference::HktRegistry::EMPTY if registrations.empty? && definitions.empty?

        Inference::HktRegistry.new(registrations: registrations, definitions: definitions)
      end

      EMPTY = new.freeze
    end
  end
end
