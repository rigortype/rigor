# frozen_string_literal: true

require "rigor/plugin"

require_relative "alba/resource_index"
require_relative "alba/resource_collector"
require_relative "alba/resource_discoverer"

module Rigor
  module Plugin
    # rigor-alba — recognises the alba JSON serializer (https://github.com/okuramasafumi/alba) in an
    # application that uses it. Three facets, each of which only removes a diagnostic or adds a type:
    #
    # 1. **Block self.** `Alba.serialize(obj) { attributes :id }` and `Alba.hashify(obj) { ... }` `class_eval`
    #    their block on an anonymous `Class.new { include Alba::Resource }`, so the DSL calls inside resolve
    #    against `singleton(Alba::Resource)` (alba's own sig declares `[self: singleton(Resource)]`) instead of
    #    firing `call.unresolved-toplevel`.
    # 2. **`Alba.serialize(...)` returns `String`** (when no `with:` is given). Instance `#serialize`,
    #    `hashify`, `to_h`, `serializable_hash` and `as_json` stay unmodelled: the project may redefine
    #    `#serialize`, and alba's own RBS declares the rest `untyped`.
    # 3. **`rigor unused` roots.** `many :articles` with no `resource:` makes alba infer `ArticleResource` (or
    #    `ArticleSerializer`) through `Alba.inflector`; that name appears nowhere in source, so the class would
    #    be listed as unused. It is published as a root — and only when a class of that name exists.
    #
    # alba keeps its `sig/` in the repository but does not ship it in the gem, so in a user project the
    # constant `Alba` is unknown. The bundled `sig/alba.rbs` therefore declares just the two namespaces the
    # block-self and receiver matching need (`Alba`, `Alba::Resource`), and both are `open_receivers` so no
    # undeclared call on them is ever diagnosed.
    class Alba < Rigor::Plugin::Base
      manifest(
        id: "alba",
        target_gems: ["alba"],
        version: "0.1.0",
        description: "Types alba's inline-resource block self and serialize results, and roots inferred " \
                     "association resources for `rigor unused`.",
        config_schema: {
          "resource_search_paths" => { kind: :array, default: ["app"] }
        },
        signature_paths: ["sig"],
        open_receivers: %w[Alba Alba::Resource],
        produces: [:reachability_roots],
        block_as_methods: [
          Rigor::Plugin::Macro::BlockAsMethod.new(
            receiver_constraint: "Alba",
            method_names: %i[serialize hashify],
            self_type: "singleton(Alba::Resource)"
          )
        ]
      )

      producer :resource_index, watch: -> { [[@resource_search_paths, "**/*.rb"]] } do |_params|
        ResourceDiscoverer.new(io_boundary: io_boundary, search_paths: @resource_search_paths).discover
      end

      def init(_services)
        @resource_search_paths = Array(config.fetch("resource_search_paths")).map(&:to_s)
      end

      # `Alba.serialize(...)` — the class-level entry point ends in `Alba.encoder.call(...)` or
      # `resource.serialize`, both `String`. A `with:` keyword names a custom resource that may override
      # `#serialize`, and a keyword splat might carry one, so the call declines then. Instance `#serialize` on
      # a resource class is deliberately NOT contributed: a project module, `define_method` or a reopening
      # outside `resource_search_paths` can redefine it, and the engine already resolves that.
      dynamic_return receivers: ["singleton(Alba)"], methods: [:serialize] do |call_node, _scope|
        next nil unless call_node.is_a?(Prism::CallNode)
        next nil if custom_resource_possible?(call_node)

        Rigor::Type::Combinator.nominal_of("String")
      end

      # ADR-102 WD3 — the resource classes alba's association inference loads. Published only where the
      # inferred name resolves to a class the project declares ({ResourceIndex#inferred_roots}); a name nothing
      # matches contributes nothing, and an unavailable inflector (ADR-39: decline, never approximate) leaves
      # the report as it was.
      def prepare(services)
        index = resource_index
        return if index.nil?

        roots = index.inferred_roots { |name| Rigor::Plugin::Inflector.classify(name) }
        return if roots.empty?

        services.fact_store.publish(plugin_id: manifest.id, name: :reachability_roots, value: roots)
      rescue Rigor::Plugin::Inflector::Unavailable
        nil
      end

      private

      # `with:` names a custom resource; a splat (positional or keyword) might carry one.
      def custom_resource_possible?(call_node)
        arguments = call_node.arguments&.arguments || []
        arguments.any? do |argument|
          case argument
          when Prism::SplatNode, Prism::ForwardingArgumentsNode then true
          when Prism::KeywordHashNode then argument.elements.any? { |element| unknown_or_with_key?(element) }
          else false
          end
        end
      end

      def unknown_or_with_key?(element)
        !element.is_a?(Prism::AssocNode) || !element.key.is_a?(Prism::SymbolNode) || element.key.unescaped == "with"
      end

      def resource_index
        producer_value(:resource_index)
      end
    end

    Rigor::Plugin.register(Alba)
  end
end
