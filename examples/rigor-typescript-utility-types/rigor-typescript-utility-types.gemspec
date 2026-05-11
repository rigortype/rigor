# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-typescript-utility-types"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: TypeScript-canonical utility-type aliases (Pick, Omit, Partial, Required, Readonly)."
  spec.description = "Maps the TypeScript-canonical utility-type spellings (Pick<T, K>, Omit<T, K>, " \
                     "Partial<T>, Required<T>, Readonly<T>) onto the Rigor-canonical shape-projection " \
                     "type functions (pick_of[T, K], omit_of[T, K], partial_of[T], required_of[T], " \
                     "readonly_of[T]) introduced in ADR-13. Opt-in via .rigor.yml; off by default."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "rigortype", ">= 0.1.4", "< 0.2.0"
end
