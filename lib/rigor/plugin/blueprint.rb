# frozen_string_literal: true

module Rigor
  module Plugin
    # Frozen, `Ractor.shareable?` description of how to materialise
    # a single plugin instance inside a worker.
    # [ADR-15](../../../docs/adr/15-ractor-concurrency.md) Phase 3
    # introduces the carrier so the eventual worker pool can pass
    # `Array<Blueprint>` across a Ractor boundary verbatim; each
    # worker calls {#materialize} once at startup, then owns its
    # plugin instances (and their mutable per-run accumulators)
    # for the lifetime of the worker.
    #
    # Holds the constant path (`String`) of the plugin class — NOT
    # the class object itself. Plugin gems are required from the
    # main Ractor BEFORE any worker spawns, so every Ractor
    # resolves the same constant via `Object.const_get`.
    #
    # The `config` Hash is deep-copied + made shareable at
    # construction so the Blueprint stays decoupled from whatever
    # Hash the project configuration emitted. The original config
    # Hash held by the loader is therefore unaffected by Blueprint
    # construction.
    class Blueprint
      attr_reader :klass_name, :config

      def initialize(klass_name:, config: {})
        @klass_name = normalise_klass_name(klass_name)
        @config = Ractor.make_shareable(Marshal.load(Marshal.dump(config)))
        freeze
      end

      # Resolves the plugin class via `Object.const_get`, builds a
      # fresh instance bound to the supplied services container,
      # and calls `#init(services)`. Mirrors
      # {Rigor::Plugin::Loader#instantiate} bit-for-bit so the
      # blueprint-driven path stays consistent with the
      # configuration-driven load path.
      def materialize(services:)
        klass = Object.const_get(@klass_name)
        plugin = klass.new(services: services, config: @config)
        plugin.init(services)
        plugin
      end

      private

      def normalise_klass_name(name)
        case name
        when String
          name.dup.freeze
        when Module
          name.name.dup.freeze
        else
          raise ArgumentError, "Blueprint klass_name must be a String or Module, got #{name.class}"
        end
      end
    end
  end
end
