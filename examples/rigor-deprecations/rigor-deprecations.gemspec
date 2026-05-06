# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-deprecations"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: config-driven deprecation warnings."
  spec.description = "The smallest worked example of the v0.1.0 plugin authoring surface. " \
                     "Surfaces :warning diagnostics at every call site matching a user-declared " \
                     "method signature in .rigor.yml. No I/O, no cache, no engine query — " \
                     "the recommended starting point for authoring your own Rigor plugin."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
