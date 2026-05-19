# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-rails-routes"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates Rails route-helper calls against `config/routes.rb`."
  spec.description = "Parses the project's `config/routes.rb` Ruby DSL via Prism (no Rails runtime " \
                     "dependency) and builds a helper table covering the resource / resource / root " \
                     "/ get|post|patch|put|delete / namespace / member / collection family. Each " \
                     "`*_path` / `*_url` call site is validated for helper existence and arity. The " \
                     "plugin publishes the helper table as a fact for downstream consumers " \
                     "(rigor-actionpack Phase 4)."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
