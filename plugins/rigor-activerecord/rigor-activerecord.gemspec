# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-activerecord"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: types ActiveRecord finder + relation calls against db/schema.rb."
  spec.description = "Reads `db/schema.rb` and the project's AR model classes, then validates " \
                     "`Model.find` / `Model.find_by` / `Model.where` calls against the resolved " \
                     "table's columns. Catches typos in column names and queries against unknown " \
                     "models at lint time, with did-you-mean suggestions."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
