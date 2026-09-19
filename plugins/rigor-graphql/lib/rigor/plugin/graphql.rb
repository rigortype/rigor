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
    # ## Shipped DSL signature (`sig/graphql.rbs`)
    #
    # Since graphql-ruby ships no RBS, the manifest's `signature_paths:` contributes the class-level
    # DSL surface — `field`/`argument`/`value`/`implements`/`description`/`graphql_name` and friends —
    # following graphql-ruby's real `Member`-rooted ancestry so subclass bodies stop reading every
    # DSL call as `Dynamic[top]`. Return types are the real carriers (`field` → `Schema::Field`,
    # `Enum.value` → `Schema::EnumValue`, setter/getter macros → their configured value) rather than
    # `void`, which the engine recovers as `top`. Scope and deferrals are documented at the top of
    # the sig file.
    #
    # The declared classes stay in `open_receivers:` because graphql-ruby's real surface is open:
    # schema plugins (`use`-able extensions) and user base classes add class-level DSL methods this
    # signature does not enumerate, so `call.undefined-method` must not read these classes as
    # closed.
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
        target_gems: ["graphql"],
        # 0.2.0, 2026-09-20 (#1100) — `signature_paths:` contributes the graphql-ruby class-level DSL
        # surface (`field`/`argument`/`value`/…), typed with the real carriers (`Field`/`Argument`/
        # `EnumValue`/…) so DSL calls stop reading `Dynamic[top]` inside recognised subclasses.
        version: "0.2.0",
        description: "Recognises `class T < GraphQL::Schema::{Object,Enum,InputObject,Mutation}` " \
                     "subclasses; publishes the per-type field-type table, the per-enum value " \
                     "list, the per-input-object argument table, and the per-mutation arguments+fields " \
                     "table; ships the graphql-ruby class-level DSL signature surface.",
        signature_paths: ["sig"],
        # ADR-43 WD4 — the classes the bundled sig covers completely enough that a Ruby-source subclass
        # (`class PostType < GraphQL::Schema::Object`) may bridge inherited calls to the RBS ancestor.
        # Listing one turns on `call.undefined-method`/arity checks for inherited DSL calls on every
        # subclass — justified here because the sig IS the authority (graphql-ruby ships none).
        rbs_complete_ancestors: %w[
          GraphQL::Schema
          GraphQL::Schema::Member
          GraphQL::Schema::Object
          GraphQL::Schema::Resolver
          GraphQL::Schema::Mutation
          GraphQL::Schema::RelayClassicMutation
          GraphQL::Schema::Subscription
          GraphQL::Schema::InputObject
          GraphQL::Schema::Enum
          GraphQL::Schema::EnumValue
          GraphQL::Schema::Union
          GraphQL::Schema::Scalar
          GraphQL::Schema::Directive
          GraphQL::Schema::Field
          GraphQL::Schema::Argument
          GraphQL::Dataloader::Source
          GraphQL::Types::Relay::BaseConnection
          GraphQL::Types::Relay::BaseEdge
          GraphQL::Types::Relay::PageInfo
          GraphQL::Types::Relay::BaseField
        ],
        open_receivers: %w[
          GraphQL::Schema
          GraphQL::Schema::Member
          GraphQL::Schema::Object
          GraphQL::Schema::Resolver
          GraphQL::Schema::Mutation
          GraphQL::Schema::RelayClassicMutation
          GraphQL::Schema::Subscription
          GraphQL::Schema::InputObject
          GraphQL::Schema::Enum
          GraphQL::Schema::EnumValue
          GraphQL::Schema::Union
          GraphQL::Schema::Scalar
          GraphQL::Schema::Directive
          GraphQL::Schema::Field
          GraphQL::Schema::Argument
          GraphQL::Schema::Interface
          GraphQL::Query
          GraphQL::Query::Context
          GraphQL::Dataloader
          GraphQL::Dataloader::Source
          GraphQL::Types::Relay::BaseConnection
          GraphQL::Types::Relay::BaseEdge
          GraphQL::Types::Relay::BaseField
        ],
        produces: %i[graphql_type_table graphql_enum_table graphql_input_object_table graphql_mutation_table]
      )

      def prepare(services)
        scanned = TypeScanner.scan(paths: scannable_paths(services), io_boundary: io_boundary)
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

      # ADR-45 WD1b (#613 / #630) — the classification probes go through the boundary, so an entry that
      # is not there yet (or stops being a directory) is a recorded dependency of the scan's input set.
      def scannable_paths(services)
        @scannable_paths ||= services.configuration.paths.flat_map do |entry|
          if io_boundary.directory?(entry)
            Dir.glob(File.join(entry, "**", "*.rb"), sort: true)
          elsif io_boundary.file?(entry) && entry.end_with?(".rb")
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
