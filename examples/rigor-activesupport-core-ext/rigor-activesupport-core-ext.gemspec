# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-activesupport-core-ext"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Community RBS bundle for the most-frequently-flagged ActiveSupport core extensions."
  spec.description = "Ships RBS signatures for the ActiveSupport `core_ext` extensions that " \
                     "drove the bulk of `call.undefined-method` diagnostics in a four-project " \
                     "Rails survey (Redmine, Discourse, Mastodon, GitLab FOSS). Covers `Integer` " \
                     "/ `Float` duration multipliers, `Time` / `Date` calculations, `String` " \
                     "inflections / filters, `Array` / `Hash` extensions, and the universal " \
                     "`Object#blank?` / `#present?` / `#try` family. Opt-in by adding the gem's " \
                     "`sig/` directory to `.rigor.yml`'s `signature_paths:`. " \
                     "No analyzer-side plugin code."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb sig/**/*.rbs])
  spec.require_paths = ["lib"]

  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
