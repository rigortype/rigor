# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name    = "rigor-playground"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email   = ["maintainers@example.invalid"]

  spec.summary     = "Browser-based Rigor playground — local server + CodeMirror frontend."
  spec.description = "Starts a local Rack/Puma server serving the Rigor browser playground. " \
                     "Run `rigor playground` to open the editor with real-time diagnostics, " \
                     "type annotations, and inline type-of hover. Implements ADR-29."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files         = Dir.glob(%w[README.md lib/**/*.rb frontend/**/*])
  spec.require_paths = ["lib"]

  spec.add_dependency "puma",      "~> 6.0"
  spec.add_dependency "rack",      "~> 3.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.3.0"
end
