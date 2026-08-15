# frozen_string_literal: true

require "rigor/plugin"

require_relative "factorybot/analyzer"
require_relative "factorybot/factory_discoverer"
require_relative "factorybot/factory_index"

module Rigor
  module Plugin
    # rigor-factorybot — validates `FactoryBot.create(:name, key: ...)` and the build / build_stubbed /
    # attributes_for / *_list family against a per-run index built from `factory_search_paths`.
    #
    # Recognises factory NAMES + literal ATTRIBUTE KEYS in the call's keyword hash. The AR column
    # cross-check uses the `rigor-activerecord` `:model_index` ADR-9 fact when that plugin is loaded
    # (optional `consumes:`). Traits, sequences, parent / child factories, and dynamic factory names are
    # deferred to follow-up slices.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-factorybot
    #         config:
    #           factory_search_paths:
    #             - spec/factories
    #             - spec/factories.rb
    #             # Minitest projects override:
    #             # - test/factories
    #
    # ## What it checks
    #
    # - **Factory existence** — every entry call's first positional Symbol / String literal is looked up
    #   in the index. Missing factories emit `unknown-factory` with a `DidYouMean` suggestion.
    # - **Attribute key existence** — every literal-Symbol keyword-argument key is matched against the
    #   factory's declared attribute names. Missing keys emit `unknown-attribute` with a `DidYouMean`
    #   suggestion.
    # - **Trace** — recognised entry calls also emit a `factory-call` info diagnostic listing the
    #   factory's declared attribute set.
    #
    # ## Recognised entry methods
    #
    # `FactoryBot.create`, `.build`, `.build_stubbed`, `.attributes_for`, `.create_list`, `.build_list`,
    # `.build_stubbed_list`. The legacy `FactoryGirl` constant is recognised identically. Implicit-receiver
    # calls (`create(:name)` inside an `include FactoryBot::Syntax::Methods` context) are NOT recognised —
    # too many false positives on plain `create` calls outside test files; deferred until receiver-type
    # inference can disambiguate.
    #
    # ## What's recognised inside `factory :name do ... end`
    #
    # - `name { "Alice" }` — implicit attribute via `method_missing` with a block (modern syntax).
    # - `name "Alice"` — implicit attribute with a positional argument (legacy syntax).
    # - `add_attribute(:name) { "Alice" }` — explicit form.
    #
    # Sequences (`sequence(:email) { ... }`), associations (`association :author`), traits (`trait :admin
    # do ... end`), and parent / child relationships (`factory :admin, parent: :user do ... end`) are
    # deferred to follow-up slices. Factories whose name is a non-literal expression (`factory
    # FACTORY_NAME do ... end`) are silently skipped.
    class Factorybot < Rigor::Plugin::Base
      manifest(
        id: "factorybot",
        # Bumped 2026-08-16 — publishes `:reachability_references` for `rigor unused` (ADR-102 WD3 / #350).
        version: "0.3.0",
        description: "Validates FactoryBot.create / build / attributes_for call shapes; " \
                     "publishes per-factory attribute set + inferred model class as the " \
                     ":factory_index ADR-9 fact (Pillar 2 Slice 3).",
        config_schema: {
          "factory_search_paths" => { kind: :array, default: ["spec/factories", "spec/factories.rb"] }
        },
        consumes: [
          { plugin_id: "activerecord", name: :model_index, optional: true }
        ],
        produces: [:reachability_references]
      )

      producer :factory_index, watch: -> { [[@factory_search_paths, "**/*.rb"]] } do |_params|
        FactoryDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @factory_search_paths
        ).discover
      end

      def init(_services)
        @factory_search_paths = Array(config.fetch("factory_search_paths")).map(&:to_s)
      end

      # ADR-102 WD3 / #350 — the model classes the factories build, published as `:reachability_references`
      # rather than as `:reachability_roots`.
      #
      # Both halves of that sentence are load-bearing.
      #
      # It is a CONTRIBUTION at all because a factory names its class by a mechanism the constant scan cannot
      # follow: `factory :user, class: "Admin::User"` is a string, and a bare `factory :user` is FactoryBot's
      # own constantization of the factory name. Neither leaves a constant node anywhere in the project.
      #
      # It is a REFERENCE rather than a root because factories live in the test tree. Rooting them would make
      # every factoried class production-reachable and erase ADR-102 WD8's "reachable only from tests"
      # category for exactly the classes it is most likely to be about — a model kept alive by its factory
      # and its spec and nothing else is the archetype of dead production code with a live test, and that is
      # the single most actionable row this report produces. Carrying the `:test` role keeps the finding.
      def prepare(services)
        index = producer_value(:factory_index)
        return if index.nil? || index.empty?

        references = index.entries.values.filter_map do |entry|
          { name: entry.model_class, role: :test } if entry.model_class
        end.uniq
        return if references.empty?

        services.fact_store.publish(plugin_id: manifest.id, name: :reachability_references, value: references)
      end

      # ADR-37 — per-call factory/attribute validation over the engine-owned walk. Each violation carries
      # its own location (the call's message_loc, or the offending attribute key), so it is positioned
      # via `diagnostic(node, location:)`. No file-level diagnostic remains, so there is no
      # `diagnostics_for_file`.
      node_rule Prism::CallNode do |node, _scope, path|
        index = producer_value(:factory_index)
        next [] if index.nil? || index.empty?

        # `:model_index` is rigor-activerecord's published fact (ADR-9); nil when that plugin isn't
        # loaded, in which case the analyzer falls back to factory-attributes-only checking.
        violations = Analyzer.violations_for(
          call_node: node, factory_index: index,
          model_index: read_fact(plugin_id: "activerecord", name: :model_index)
        )
        diagnostics_for(violations, path: path, node: node)
      end
    end

    Rigor::Plugin.register(Factorybot)
  end
end
