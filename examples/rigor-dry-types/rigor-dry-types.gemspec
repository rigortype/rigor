# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-dry-types"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: dry-types alias-module recognition (ADR-12 Tier A foundation)."
  spec.description = "Recognises `module X; include Dry.Types(); end` declarations and publishes " \
                     "the resulting `Types::String` / `Types::Integer` / … alias table as the " \
                     "`:dry_type_aliases` cross-plugin fact (ADR-9). Foundation gem for the " \
                     "`rigor-dry-*` family per ADR-12; consumed by `rigor-dry-struct` / " \
                     "`rigor-dry-validation` / `rigor-dry-schema` once their precision-promotion " \
                     "slices wire through the fact."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "rigortype", ">= 0.1.5", "< 0.2.0"
end
