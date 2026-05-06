# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-lisp-eval"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: types literal `Lisp.eval(...)` calls."
  spec.description = "Demonstrates the Rigor v0.1.0 plugin authoring surface by walking literal " \
                     "Lisp-style expressions inside `Lisp.eval(...)` calls and surfacing the " \
                     "statically-inferred return type as a diagnostic at the call site."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
