# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-sorbet"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: ingests Sorbet `sig` blocks as method-signature contributions."
  spec.description = "Reads inline `sig { params(...).returns(T) }` annotations on first-party " \
                     "Ruby code and contributes the parsed signatures to Rigor's analyzer at " \
                     "every call site. Slice 1 of ADR-11; later slices add `T.let` / `T.cast` / " \
                     "`T.must` flow primitives, RBI files, sigil honoring, and exhaustiveness " \
                     "via `T.absurd`."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
