# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-actionpack"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates Action Pack route-helper calls in controllers."
  spec.description = "Phase 4 of the Action Pack plugin family. Reads the `:helper_table` " \
                     "fact published by `rigor-rails-routes` (ADR-9 cross-plugin API) and " \
                     "validates every `*_path` / `*_url` call inside controller files. " \
                     "Phases 1-3 (strong parameters, filter chains, render targets) ship " \
                     "as separate slices. No Rails runtime."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
