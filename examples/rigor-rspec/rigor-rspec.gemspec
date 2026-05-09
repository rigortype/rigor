# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-rspec"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates RSpec `let` / `subject` declarations."
  spec.description = "Walks RSpec spec files for `RSpec.describe` / `describe` / `context` " \
                     "blocks and validates the `let` / `subject` declarations inside each: " \
                     "duplicate declarations within the same scope are flagged as " \
                     "warnings, and recursive `let(:name) { name }` self-references are " \
                     "flagged as errors. Deliberately scoped — mock-target validation and " \
                     "let-typo detection in `it` bodies are out of scope for v0.1.0 (see the " \
                     "README's `Future direction`). No RSpec runtime dependency."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
