# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-units"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: types a units-of-measure DSL on Numeric."
  spec.description = "Demonstrates the Rigor v0.1.0 plugin authoring surface by walking files that " \
                     "use a units-of-measure DSL (`100.kilometers`, `2.hours`, " \
                     "`distance / time`, `speed.in_kilometers_per_hour`) and surfacing the " \
                     "statically-inferred dimensional type as diagnostics. Catches dimensional " \
                     "mismatches such as `Distance + Time` at lint time."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
