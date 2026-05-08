# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-rails-i18n"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates `t('key.path')` calls against `config/locales/*.yml`."
  spec.description = "Walks `config/locales/*.yml` to build a per-locale key catalogue, then " \
                     "validates every `t(literal_key, ...)` / `I18n.t(...)` call site against " \
                     "the catalogue: missing keys (with did-you-mean suggestions), interpolation " \
                     "variable mismatches, and per-locale coverage are reported. No Rails runtime."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
