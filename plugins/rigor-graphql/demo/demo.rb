# frozen_string_literal: true

# rigor-graphql demo. Run from this directory:
#
#   cp .rigor.dist.yml .rigor.yml
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# Two canonical Schema::Object subclasses with mixed scalar / user-defined field types. With the plugin
# enabled, rigor's `prepare(services)` hook scans this file, sees the subclasses, and publishes the
# `:graphql_type_table` fact mapping each type to its field-type map.
#
# The plugin also bundles the graphql-ruby class-level DSL signature (`sig/` via the manifest's
# `signature_paths:`), so each `field` call itself types as `GraphQL::Schema::Field` rather than
# `Dynamic[top]` — try `Rigor.dump_type(field :name, String, null: false)` inside a subclass.

module Types
  class User < GraphQL::Schema::Object
    field :name, String, null: false
    field :email, String, null: true
    field :age, Integer, null: false
    field :is_active, Boolean, null: false
  end

  class Post < GraphQL::Schema::Object
    field :title, String, null: false
    field :body, String, null: false
    field :author, User, null: false
  end
end
