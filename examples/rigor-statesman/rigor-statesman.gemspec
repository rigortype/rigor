# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-statesman"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: validates state-machine transitions against declared states."
  spec.description = "Reference example for the two-pass DSL analysis pattern. Walks `state_machine " \
                     "do ... end` blocks to collect declared states, then validates `transition_to(:state)` " \
                     "call sites with Levenshtein-based did-you-mean suggestions."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
