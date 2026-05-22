# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-web"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: enforces a path-scoped controller protocol."
  spec.description = "Reference example for the ADR-28 path-scoped method-protocol contract " \
                     "surface. Declares that every class under lib/controller/ must define " \
                     "#get(Rack::Request) -> Rack::Response — the engine provides the parameter " \
                     "type into the method body and the plugin checks the method's presence and " \
                     "return type. Ships RBS for Rack::Request / Rack::Response via signature_paths."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb sig/**/*.rbs])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
