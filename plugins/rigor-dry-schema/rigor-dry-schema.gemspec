# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-dry-schema"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: dry-schema schema-definition recognition (ADR-12)."
  spec.description = "Recognises `Foo = Dry::Schema.{Params,JSON,define} { ... }` declarations " \
                     "and publishes a `{schema_const_fqn => {required: {...}, optional: {...}}}` " \
                     "table as the `:dry_schema_table` cross-plugin fact (ADR-9). Consumes the " \
                     "`:dry_type_aliases` fact published by `rigor-dry-types` so user-authored " \
                     "type references (`value(Types::Email)`) resolve to their underlying class. " \
                     "Floor for `rigor-dry-validation` per the slicing plan in " \
                     "docs/design/20260517-dry-validation-slicing.md."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "rigortype", ">= 0.1.5", "< 0.2.0"
end
