# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-pattern"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: validates literal arguments against named regex patterns."
  spec.description = "Reference example for plugin -> analyzer collaboration. The plugin asks " \
                     "Rigor's type system whether each argument is provably a literal string " \
                     "(via Type::Combinator.literal_string_compatible?) and runs the configured " \
                     "regex against the literal value at lint time."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
