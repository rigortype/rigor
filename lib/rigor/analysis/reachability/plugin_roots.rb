# frozen_string_literal: true

require_relative "../../plugin"
require_relative "../../plugin/loader"
require_relative "../../plugin/services"
require_relative "../../reflection"
require_relative "../../type/combinator"

module Rigor
  module Analysis
    module Reachability
      # ADR-102 WD3 — the root-contribution protocol: framework knowledge stays in plugins, and the core
      # defines only the channel it arrives through.
      #
      # The channel is the EXISTING cross-plugin fact mechanism (ADR-9), not a new hook. A plugin declares
      # `produces: [:reachability_roots]` in its manifest and publishes an Array of fully-qualified constant
      # names from its `#prepare(services)` hook; this module loads the project's plugins, runs every
      # `#prepare`, and hands the union to {Graph}'s `root_fqns:`. Reusing the fact store means the ordering
      # guarantee is already settled — `#prepare` runs before anything reads the store — and a plugin that
      # already computes the knowledge (`rigor-rails-routes` parses `config/routes.rb` for its helper table
      # regardless) publishes a second view of it for free.
      #
      # Why roots at all: a Rails controller is reached by NAME at request time, so a reference index sees a
      # live controller exactly as it sees a dead one. Route roots were the single largest lever in the #345
      # corpus measurement — subtracting them removed 40 % / 62 % / 67 % of the class tier across three
      # targets, more than every other stage combined.
      #
      # **Fail-soft is the invariant.** A project with no plugins, a plugin gem that will not resolve, or a
      # plugin that raises in `#prepare` degrades to the root set the report had without plugins — never a
      # crash. `rigor unused` is a report a human reads; refusing to print it because one plugin is
      # misconfigured trades a slightly wider candidate list for no output at all.
      #
      # **Under-supply beats over-supply.** A root that names a constant the project does not declare is
      # inert (the graph intersects roots with owned declarations), but a root claiming a namespace it does
      # not really reach silently hides real dead code. That asymmetry is why {.collect} validates the shape
      # of what a plugin publishes rather than trusting it, and why the report surfaces the count of
      # supplied roots that matched no declaration — a plugin's contribution needs its own corpus check
      # (ADR-102 § Consequences).
      module PluginRoots
        # The fact name a root-contributing plugin publishes under. Namespaced by `plugin_id` inside the
        # store, so two plugins contributing roots never collide.
        FACT_NAME = :reachability_roots

        # A published entry is accepted only when it is shaped like a constant path. The filter is not a
        # security boundary — plugins are trusted code (ADR-2) — it keeps a plugin bug (a path, a helper
        # name, a nil) from entering the graph as a root that silently matches nothing.
        CONSTANT_NAME = /\A(?:::)?[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/

        module_function

        # Loads the project's configured plugins, runs every `#prepare`, and returns the union of every
        # published `:reachability_roots` fact.
        #
        # @param configuration [Rigor::Configuration] the loaded project configuration.
        # @param plugin_requirer [#call] how a plugin gem is brought into the process. The same seam
        #   `Analysis::Runner` exposes, so a spec can register a plugin class without publishing a gem.
        # @return [Array<String>] fully-qualified constant names, sorted and de-duplicated. Empty whenever
        #   the project declares no plugins, no plugin contributes roots, or anything at all goes wrong.
        def collect(configuration:, plugin_requirer: ->(name) { require name })
          return [] if configuration.plugins.empty?

          services = build_services(configuration)
          registry = Plugin::Loader.load(configuration: configuration, services: services,
                                         requirer: plugin_requirer)
          return [] if registry.nil? || registry.empty?

          run_prepare(registry)
          harvest(services.fact_store)
        rescue StandardError, ScriptError
          []
        end

        # Mirrors `CLI::ProbeEnvironment.load_plugin_registry`: a `Plugin::Services` with no cache store
        # (this is a one-shot report, so a producer recomputes rather than reading and writing cache slots)
        # driving `Plugin::Loader.load`. Holding the `Services` is what gives access to the fact store the
        # loaded plugins share — the loader hands the same instance to every plugin.
        def build_services(configuration)
          Plugin::Services.new(
            reflection: Reflection,
            type: Type::Combinator,
            configuration: configuration,
            cache_store: nil
          )
        end

        # Per-plugin isolation, matching `Analysis::WorkerSession#run_plugin_prepare`: one raising plugin
        # loses its own facts, never the facts of the plugins beside it.
        def run_prepare(registry)
          registry.plugins.each do |plugin|
            plugin.prepare(plugin.services)
          rescue StandardError, ScriptError
            next
          end
        end

        # Reads every plugin's contribution. `each_fact` rather than a `read(plugin_id:, name:)` per known
        # producer: the core deliberately does not know WHICH plugins contribute roots, which is the whole
        # point of routing this through the fact store instead of an allow-list in the core.
        def harvest(fact_store)
          roots = Set.new
          fact_store.each_fact do |fact|
            next unless fact.name == FACT_NAME

            Array(fact.value).each do |entry|
              name = entry.to_s
              roots << name.delete_prefix("::") if CONSTANT_NAME.match?(name)
            end
          end
          roots.to_a.sort
        end
      end
    end
  end
end
