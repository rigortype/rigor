# frozen_string_literal: true

# rigor-graphql demo. Run from this directory:
#
#   cp .rigor.dist.yml .rigor.yml
#   RUBYLIB=$PWD/../lib bundle exec rigor check
#
# Two canonical Schema::Object subclasses with mixed scalar /
# user-defined field types. With the plugin enabled, rigor's
# `prepare(services)` hook scans this file, sees the
# subclasses, and publishes the `:graphql_type_table` fact
# mapping each type to its field-type map.
#
# At slice 1 the observable change is fact-publication only;
# the downstream uplift (resolver-method type-check, etc.)
# lands in a later slice.

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
