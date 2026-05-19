# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-activestorage"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: types ActiveStorage attachment macros on AR models."
  spec.description = "Walks ActiveRecord model files for `has_one_attached :avatar` / " \
                     "`has_many_attached :photos` macros, records the generated attachment " \
                     "accessor surface, and contributes `Nominal[ActiveStorage::Attached::One]` " \
                     "/ `Nominal[ActiveStorage::Attached::Many]` return types when the receiver " \
                     "is a known AR model. Consumes the `:model_index` fact published by " \
                     "`rigor-activerecord` (ADR-9 cross-plugin API) so model discovery stays " \
                     "single-rooted across the Rails plugin family. No Rails runtime."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
