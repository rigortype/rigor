# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-dry-struct"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: ADR-16 Tier C worked target (heredoc-template synthesis)."
  spec.description = "Recognises dry-struct's `attribute :name, T` class-level DSL and synthesises " \
                     "a reader method on the enclosing Dry::Struct subclass. The first worked " \
                     "consumer of `Plugin::Macro::HeredocTemplate` (ADR-16 slice 2c). Plugin body " \
                     "is purely declarative — the manifest's heredoc_templates entry IS the plugin."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
