# frozen_string_literal: true

# rigor-dry-schema demo. Run from this directory:
#
#   cp .rigor.dist.yml .rigor.yml
#   RUBYLIB=$PWD/../lib:$PWD/../../rigor-dry-types/lib bundle exec rigor check
#
# The canonical dry-schema declarations. With the plugin
# enabled, rigor's prepare(services) hook scans this file, sees
# the `Dry::Schema.Params { ... }` / `Dry::Schema.JSON { ... }`
# assignments, and publishes the `:dry_schema_table` fact
# mapping each schema constant to its `{required: {...},
# optional: {...}}` typed-key shape.
#
# At slice 1 the observable change is fact-publication only;
# the downstream uplift (typed `Contract#call → Result.to_h`
# returns through rigor-dry-validation) lands in a later slice
# per docs/design/20260517-dry-validation-slicing.md.

module Types
  include Dry.Types()

  Email = String.constrained(format: /@/)
end

NewUserSchema = Dry::Schema.Params do
  required(:email).value(Types::Email)
  required(:age).value(:integer)
  optional(:nickname).maybe(:string)
end

ProductJSON = Dry::Schema.JSON do
  required(:sku).filled(:string)
  required(:price).value(:decimal)
end
