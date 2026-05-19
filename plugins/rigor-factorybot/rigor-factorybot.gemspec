# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-factorybot"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates FactoryBot.create / build / build_stubbed call shapes."
  spec.description = "Phase 1 (a) — self-contained validation. Walks `factory_search_paths` " \
                     "(default `[\"spec/factories\", \"spec/factories.rb\"]`), parses each file, " \
                     "and indexes the declared `factory :name do ... end` blocks (factory name + " \
                     "declared attribute keys). Validates every `FactoryBot.create(:name, key: ...)` " \
                     "/ `.build(...)` / `.build_stubbed(...)` / `.attributes_for(...)` call site " \
                     "against the index. Phase 1 (c) — AR column cross-check via the " \
                     "rigor-activerecord :model_index fact — ships as a follow-up slice."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
