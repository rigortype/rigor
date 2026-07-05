# frozen_string_literal: true

require "prism"

require "rigor/plugin"

require_relative "graphql/type_scanner"

module Rigor
  module Plugin
    # rigor-graphql — Tier 3 of the
    # [Rails plugins roadmap](../../../../../docs/design/20260508-rails-plugins-roadmap.md)
    # § "3D".
    #
    # Recognises `class T < GraphQL::Schema::Object` subclasses and walks every `field :name, Type,
    # null: false` declaration inside, publishing the resulting field-type map as the
    # `:graphql_type_table` cross-plugin fact (ADR-9). The macro expansion library survey at
    # docs/notes/20260515-macro-expansion-library-survey.md § "GraphQL-Ruby" documents WHY this is a
    # pure metadata-recorder plugin rather than an ADR-16
    # substrate consumer: graphql-ruby's `field` DSL emits NO Ruby methods (it just records a
    # `Schema::Field` on the class's `own_fields`). The user writes resolver methods themselves; rigor's
    # value here is producing a static type table downstream consumers can cross-reference.
    #
    # ## What downstream consumers DO with the published facts
    #
    # The tables are the substrate for two future capabilities (demand-driven, not yet implemented):
    #
    # - Resolver-method check: for each `field :name, Type` whose `name` is also defined as a Ruby method
    #   on the class, verify the method's return type matches `Type`'s underlying class.
    # - Schema-query result typing: a future `rigor-graphql-execute` plugin could type
    #   `Schema.execute(query).to_h` against the queried fields.
    #
    # ## What's recognised
    #
    # - `class T < GraphQL::Schema::Object` subclasses (including nested namespaces); `field :name, Type,
    #   null: ...` declarations with constant-reference or list-array types and GraphQL→Ruby scalar
    #   mapping.
    # - `class T < GraphQL::Schema::Enum`; `value "ACTIVE"` calls.
    # - `class T < GraphQL::Schema::InputObject` / `GraphQL::Schema::Mutation`; `argument :name, Type,
    #   required: ...` declarations.
    # - No user-facing diagnostics yet.
    #
    # ## Deferred (demand-driven)
    #
    # - **`resolver:` / `mutation:` reroute** recognition.
    # - **String type expressions** (`field :foo, "User"`) — defeats static resolution by design
    #   (graphql-ruby's `BuildType.parse_type` constantizes at runtime); a future slice could surface
    #   these as `graphql.string-type` `:info` diagnostics pointing the user at the constant-reference
    #   form for static typing.
    class Graphql < Rigor::Plugin::Base
      manifest(
        id: "graphql",
        version: "0.1.0",
        description: "Recognises `class T < GraphQL::Schema::{Object,Enum,InputObject,Mutation}` " \
                     "subclasses; publishes the per-type field-type table, the per-enum value " \
                     "list, the per-input-object argument table, and the per-mutation arguments+fields " \
                     "table.",
        produces: %i[graphql_type_table graphql_enum_table graphql_input_object_table graphql_mutation_table]
      )

      def prepare(services)
        scanned = TypeScanner.scan(paths: scannable_paths(services))
        publish_if_present(services, :graphql_type_table, scanned.fetch(:types))
        publish_if_present(services, :graphql_enum_table, scanned.fetch(:enums))
        publish_if_present(services, :graphql_input_object_table, scanned.fetch(:input_objects))
        publish_if_present(services, :graphql_mutation_table, scanned.fetch(:mutations))
      end

      def init(_services)
        @scannable_paths = nil
      end

      private

      def publish_if_present(services, name, value)
        return if value.nil? || value.empty?

        services.fact_store.publish(plugin_id: manifest.id, name: name, value: value)
      end

      def scannable_paths(services)
        @scannable_paths ||= services.configuration.paths.flat_map do |entry|
          if File.directory?(entry)
            Dir.glob(File.join(entry, "**", "*.rb"), sort: true)
          elsif File.file?(entry) && entry.end_with?(".rb")
            [entry]
          else
            []
          end
        end.uniq.freeze
      end
    end

    Rigor::Plugin.register(Graphql)
  end
end
