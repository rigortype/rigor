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
    # Recognises `class T < GraphQL::Schema::Object` subclasses
    # and walks every `field :name, Type, null: false` declaration
    # inside, publishing the resulting field-type map as the
    # `:graphql_type_table` cross-plugin fact (ADR-9). The macro
    # expansion library survey at
    # [docs/notes/20260515-macro-expansion-library-survey.md](../../../../../docs/notes/20260515-macro-expansion-library-survey.md)
    # § "GraphQL-Ruby" documents WHY this is a pure metadata-recorder
    # plugin rather than an ADR-16 substrate consumer: graphql-ruby's
    # `field` DSL emits NO Ruby methods (it just records a
    # `Schema::Field` on the class's `own_fields`). The user writes
    # resolver methods themselves; rigor's value here is producing a
    # static type table downstream consumers can cross-reference.
    #
    # ## What downstream consumers DO with `:graphql_type_table`
    #
    # The fact is the substrate for two future capabilities (both
    # demand-driven, NOT in slice 1):
    #
    # - Resolver-method check: for each `field :name, Type` whose
    #   `name` is also defined as a Ruby method on the class, verify
    #   the method's return type matches `Type`'s underlying class.
    # - Schema-query result typing: a future `rigor-graphql-execute`
    #   plugin could type `Schema.execute(query).to_h` against the
    #   queried fields.
    #
    # ## Floor / ceiling (slice 1)
    #
    # Slice 1 ships the **floor**:
    #
    # - Recognises `class T < GraphQL::Schema::Object` subclasses
    #   (including nested namespaces: `class Types::User < ...`,
    #   `module Types; class User < ...; end; end`).
    # - Recognises the `field :name, Type, **opts` declaration with:
    #   - `Type` as a `ConstantReadNode` / `ConstantPathNode` (`String`
    #     / `Integer` / `Boolean` / `Float` / `ID`, or a user-defined
    #     `Types::OtherObject`).
    #   - `null: true` / `null: false` keyword extracts nullability.
    # - Maps the canonical GraphQL scalar names to underlying Ruby
    #   classes (`String` → `String`, `Integer` → `Integer`,
    #   `Boolean` → `TrueClass`, `Float` → `Float`, `ID` → `String`).
    # - Publishes the table; no user-facing diagnostics yet.
    #
    # The **ceiling** (future slices, demand-driven):
    #
    # - **`GraphQL::Schema::Enum`** with `value "ACTIVE"` calls.
    # - **`GraphQL::Schema::Mutation`** + **`GraphQL::Schema::InputObject`**.
    # - **List / Non-Null wrappers** (`[String]`, `String.array`).
    # - **`resolver:` / `mutation:` reroute** recognition.
    # - **String type expressions** (`field :foo, "User"`) — defeats
    #   static resolution by design (graphql-ruby's `BuildType.parse_type`
    #   constantizes at runtime); a future slice could surface these
    #   as `graphql.string-type` `:info` diagnostics that point the
    #   user at the constant-reference form for static typing.
    class Graphql < Rigor::Plugin::Base
      manifest(
        id: "graphql",
        version: "0.1.0",
        description: "Recognises `class T < GraphQL::Schema::Object` subclasses and " \
                     "publishes the per-type field-type table.",
        produces: [:graphql_type_table]
      )

      def prepare(services)
        table = TypeScanner.scan(paths: scannable_paths(services))
        return if table.empty?

        services.fact_store.publish(
          plugin_id: manifest.id,
          name: :graphql_type_table,
          value: table
        )
      end

      def init(_services)
        @scannable_paths = nil
      end

      private

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
