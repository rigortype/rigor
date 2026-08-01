# frozen_string_literal: true

# rigor-dry-schema demo. Run from this directory:
#
#   cp .rigor.dist.yml .rigor.yml
#   RUBYLIB=$PWD/../lib:$PWD/../../rigor-dry-types/lib bundle exec rigor check
#
# The canonical dry-schema declarations. With the plugin enabled, rigor's prepare(services) hook scans
# this file, sees the `Dry::Schema.Params { ... }` / `Dry::Schema.JSON { ... }` assignments, and
# publishes the `:dry_schema_table` fact mapping each schema constant to its `{required: {...},
# optional: {...}}` typed-key shape.
#
# The table also backs the typed `SomeSchema.call(input).to_h` return the consumer below exercises. The
# remaining uplift (typed `Contract#call → Result` payloads through rigor-dry-validation) lands in a
# later slice per docs/design/20260517-dry-validation-slicing.md.

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

# The typed `to_h` return. `Rigor.dump_type` prints the inferred type at each site:
#
#   { email: String, age: Integer, ?nickname: String, ... }
#   String
#   String?
payload = NewUserSchema.call({}).to_h
Rigor.dump_type(payload)
Rigor.dump_type(payload[:email])
Rigor.dump_type(payload[:nickname])
