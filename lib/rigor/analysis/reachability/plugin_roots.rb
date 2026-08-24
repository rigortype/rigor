# frozen_string_literal: true

require_relative "../../plugin"
require_relative "../../plugin/loader"
require_relative "../../plugin/services"
require_relative "../../reflection"
require_relative "../../type/combinator"

module Rigor
  module Analysis
    module Reachability
      # ADR-102 WD3 — the plugin contribution protocol: framework knowledge stays in plugins, and the core
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
      # **Two facts, because a root is not the only thing a plugin knows.** `:reachability_references` is the
      # sibling fact (#350): an Array of `{name:, role:}`, threaded into the graph as extra REFERENCES rather
      # than as roots. FactoryBot is the motivating case — `factory :user, class: "Admin::User"` names a class
      # by a string the constant scan cannot see, so it is real evidence of use, but a factory lives in the
      # test tree and rooting it would promote `Admin::User` to production-reachable and erase WD8's
      # "reachable only from tests" answer for it. Carrying the referrer's role keeps the two apart.
      #
      # The module keeps its `PluginRoots` name because roots stay its primary product, and because both
      # facts arrive through ONE plugin-load pass — loading the registry a second time would double a
      # report's startup cost to collect a strictly smaller fact.
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

        # The sibling fact: references that carry their referrer's role instead of rooting anything (#350).
        REFERENCE_FACT_NAME = :reachability_references

        # A published entry is accepted only when it is shaped like a constant path. The filter is not a
        # security boundary — plugins are trusted code (ADR-2) — it keeps a plugin bug (a path, a helper
        # name, a nil) from entering the graph as a root that silently matches nothing.
        CONSTANT_NAME = /\A(?:::)?[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/

        # The roles {Scan.role_for} assigns a file, and therefore the only roles a plugin may claim for a
        # reference it contributes. An unrecognised role is dropped rather than defaulted: defaulting to
        # `:production` would silently promote a test-tree reference, which is the one outcome WD8 exists to
        # prevent.
        ROLES = %i[production test task config].freeze

        # One plugin-contributed reference. `role` is the role of whatever names the constant, exactly as a
        # scanned file's role would be.
        Reference = Data.define(:name, :role)

        # Everything one plugin-load pass yields. Roots seed the mark-and-sweep; references enter the graph
        # beside the scanned ones.
        Contribution = Data.define(:roots, :references) do
          def self.empty = new(roots: [].freeze, references: [].freeze)

          def empty? = roots.empty? && references.empty?
        end

        module_function

        # Loads the project's configured plugins, runs every `#prepare`, and returns the union of every
        # published `:reachability_roots` and `:reachability_references` fact.
        #
        # @param configuration [Rigor::Configuration] the loaded project configuration.
        # @param plugin_requirer [#call] how a plugin gem is brought into the process. The same seam
        #   `Analysis::Runner` exposes, so a spec can register a plugin class without publishing a gem.
        # @param cache_store [Rigor::Cache::Store, nil] when given, each plugin's `#prepare` producers read
        #   and write the same ADR-60 record-and-validate slots they use under `rigor check`, instead of
        #   recomputing from scratch — a routes parse or a factory discovery is a validated cache read on
        #   every invocation after the first. Nil keeps the historical recompute-always behaviour.
        # @return [Contribution] sorted and de-duplicated. Empty whenever the project declares no plugins, no
        #   plugin contributes anything, or anything at all goes wrong.
        def collect(configuration:, plugin_requirer: ->(name) { require name }, cache_store: nil)
          return Contribution.empty if configuration.plugins.empty?

          services = build_services(configuration, cache_store)
          registry = Plugin::Loader.load(configuration: configuration, services: services,
                                         requirer: plugin_requirer)
          return Contribution.empty if registry.nil? || registry.empty?

          run_prepare(registry)
          harvest(services.fact_store)
        rescue StandardError, ScriptError
          Contribution.empty
        end

        # Mirrors `Analysis::WorkerSession`'s services: the shared fact store plus whatever cache store the
        # caller holds. Holding the `Services` is what gives access to the fact store the loaded plugins
        # share — the loader hands the same instance to every plugin.
        def build_services(configuration, cache_store)
          Plugin::Services.new(
            reflection: Reflection,
            type: Type::Combinator,
            configuration: configuration,
            cache_store: cache_store
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
          references = Set.new
          fact_store.each_fact do |fact|
            case fact.name
            when FACT_NAME then Array(fact.value).each { |entry| collect_root(entry, roots) }
            when REFERENCE_FACT_NAME then Array(fact.value).each { |entry| collect_reference(entry, references) }
            end
          end
          Contribution.new(roots: roots.to_a.sort.freeze,
                           references: references.to_a.sort_by { |ref| [ref.name, ref.role] }.freeze)
        end

        def collect_root(entry, roots)
          name = entry.to_s
          roots << name.delete_prefix("::") if CONSTANT_NAME.match?(name)
        end

        # A reference entry is a Hash so the fact stays self-describing across the store — a bare pair would
        # read identically whichever way round a plugin author wrote it. String and Symbol keys are both
        # accepted because a plugin may have round-tripped the value through a cache slot.
        def collect_reference(entry, references)
          return unless entry.is_a?(Hash)

          name = (entry[:name] || entry["name"]).to_s
          role = (entry[:role] || entry["role"])&.to_sym
          return unless CONSTANT_NAME.match?(name) && ROLES.include?(role)

          references << Reference.new(name: name.delete_prefix("::"), role: role)
        end
      end
    end
  end
end
