# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-shoulda-matchers"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates shoulda-matchers matchers against the :model_index."
  spec.description = "Walks `RSpec.describe <Model> do ... end` blocks and validates the " \
                     "shoulda-matchers calls inside (`should validate_presence_of(:col)`, " \
                     "`should belong_to(:assoc)`, `should have_many(:assoc)`, " \
                     "`should have_db_column(:col)`, etc.) against the `:model_index` " \
                     "cross-plugin fact (ADR-9) published by `rigor-activerecord`. " \
                     "Column matchers validate the column exists on the model's table; " \
                     "association matchers validate the association exists with the " \
                     "expected kind (`belong_to` / `have_one` ↔ `:singular`; " \
                     "`have_many` / `have_and_belong_to_many` ↔ `:collection`). When " \
                     "`rigor-activerecord` is not loaded the plugin falls silent — " \
                     "the cross-check is opt-in."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
