# frozen_string_literal: true

require_relative "path_expansion"
require_relative "run_cache_key"
require_relative "../cache/store"
require_relative "../cache/file_digest"
require_relative "../effects/identity"
require_relative "../effects/plugin_facts"
require_relative "../effects/registry"
require_relative "../plugin"
require_relative "../plugin/loader"
require_relative "../plugin/services"
require_relative "../reflection"
require_relative "../type/combinator"

module Rigor
  module Analysis
    # ADR-104 — the boot-slimming probe for the effects surfaces, the shape ADR-87 WD4's
    # {RunCacheProbe} gave `rigor check`.
    #
    # A warm `rigor effects` had almost no work left after #475 and #482 and still cost 2–2.5× a warm
    # `rigor check`, because it loaded the inference engine to compute two cache keys and adopt two
    # cached values. This serves the report from the #482 summary entry — the propagated table and the
    # unit sources — loading configuration, the cache, the plugin loader and the `effects/*` value
    # layer, and never `rigor/inference`.
    #
    # ## What makes an engine-free key possible
    #
    # The effects identity ({Effects::Identity.descriptor}) is the run's diagnostics key descriptor plus
    # the vocabulary version, the catalogue identity, the `effects:` digest and {Effects::PluginFacts}'
    # own digest. The first is what {RunCacheProbe} already computes without a loader; the rest are pure
    # functions of shipped data, configuration, and the plugins' class-level declarations — a plugin's
    # contributions are fixed by `init`, which the loader runs, so `#prepare` (the expensive half) is
    # not needed. `PluginFacts#digest` is computed before the project's superclass table is even
    # assigned to it, so the discovery tables a probe cannot build do not participate.
    #
    # ## Why a decline is always safe
    #
    # Every reason to decline — a key this path cannot reproduce, a miss, a stale dependency — ends in
    # the caller running the full `Analysis::Runner`, which answers exactly as it does today. The one
    # reproducibility gap is deliberate and inherited: a project whose plugins synthesise virtual RBS
    # gets a key without the `rbs.virtual_rbs` slot the runner writes, so it misses here rather than
    # matching something it should not.
    #
    # The rule the surfaces are held to (ADR-104's criterion): a probe may serve a surface only when
    # every answer that surface can give is reproducible from stored values and declarations alone.
    # `rigor effects` and the snapshot verbs qualify because their output is a pure function of the
    # table, the sources, the configuration and the vocabulary — the envelope diagnostics the full path
    # also computes are discarded by every one of them.
    class EffectsCacheProbe
      # What a served run hands back: the two cached tables, plus the vocabulary the caller would
      # otherwise rebuild (the probe loaded the plugins to key the entry, so it already knows it).
      Served = Data.define(:table, :sources, :registry, :plugin_facts)

      # @param configuration [Rigor::Configuration] with effects already enabled by the caller.
      def initialize(configuration:, cache_root:)
        @configuration = configuration
        @cache_root = cache_root
      end

      # @param paths [Array<String>] the analysed set — `configuration.paths` unioned with any path
      #   arguments, exactly what {CLI::EffectsCommand#analyze} hands the runner, because the analysed
      #   set is part of the diagnostics key.
      # @return [Served, nil] nil to decline, on any failure whatsoever.
      def serve(paths)
        return nil if @cache_root.nil? || !@configuration.effects_check?

        descriptor = effects_descriptor(paths)
        return nil if descriptor.nil?

        summary = validated_summary(descriptor)
        return nil if summary.nil?

        table, sources, = summary
        Served.new(table: table, sources: sources, registry: registry, plugin_facts: plugin_facts)
      rescue StandardError
        nil
      end

      private

      def effects_descriptor(paths)
        files = PathExpansion.ruby_files(paths, @configuration.exclude_patterns)
        base = RunCacheKey.descriptor(
          configuration: @configuration, files: files, explain: false,
          rbs_config_entries: RunCacheKey.libraries_config_entries(@configuration)
        )
        return nil if base.nil?

        Effects::Identity.descriptor(base: base, configuration: @configuration, registry: registry,
                                     plugin_facts: plugin_facts)
      end

      # The same shape guard the runner's own read half applies, for the same reason: a miss, a stale
      # dependency, a corrupt entry and a value of the wrong shape all mean "run it properly".
      def validated_summary(descriptor)
        store = Cache::Store.new(root: @cache_root, max_bytes: @configuration.cache_max_bytes)
        cached = Cache::FileDigest.with_run(strict: @configuration.cache_validation_strict?) do
          store.peek_validated(
            producer_id: RunCacheKey::RUN_EFFECTS_TABLE_PRODUCER_ID, key_descriptor: descriptor
          )
        end
        return nil unless cached.is_a?(Array) && cached.length == 3
        return nil unless cached[0].is_a?(Effects::EffectTable) && cached[1].is_a?(Hash)

        cached
      end

      # Loaded once, and shared by the key and the answer. `#prepare` is deliberately not run: a
      # plugin's effect contributions are fixed by `init`, and `#prepare` is the half that parses
      # routes and walks worker trees — the cost this probe exists to skip.
      def plugin_facts
        return @plugin_facts if defined?(@plugin_facts)

        @plugin_facts = Effects::PluginFacts.build(plugin_registry)
      end

      def plugin_registry
        services = Plugin::Services.new(reflection: Reflection, type: Type::Combinator,
                                        configuration: @configuration, cache_store: nil)
        Plugin::Loader.load(configuration: @configuration, services: services)
      rescue StandardError, ScriptError
        nil
      end

      def registry
        @registry ||= Effects::Registry.for_configuration(@configuration, plugin_facts: plugin_facts)
      end
    end
  end
end
