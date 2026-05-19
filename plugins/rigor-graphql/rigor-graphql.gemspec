# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-graphql"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: graphql-ruby Schema::Object recognition."
  spec.description = "Recognises `class T < GraphQL::Schema::Object` subclasses and walks " \
                     "every `field :name, Type, null: false` declaration, publishing the " \
                     "`{type_class => {field_name => {type:, nullable:}}}` table as the " \
                     "`:graphql_type_table` cross-plugin fact (ADR-9). Maps the canonical " \
                     "GraphQL scalar types (String / Integer / Boolean / Float / ID) to their " \
                     "underlying Ruby classes. Per the macro-expansion library survey at " \
                     "docs/notes/20260515-macro-expansion-library-survey.md § \"GraphQL-Ruby\", " \
                     "graphql-ruby's DSL is a metadata recorder rather than a method emitter — " \
                     "the plugin therefore publishes a static type table for downstream " \
                     "consumers rather than synthesising methods."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "rigortype", ">= 0.1.5", "< 0.2.0"
end
