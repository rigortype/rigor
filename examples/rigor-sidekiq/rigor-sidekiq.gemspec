# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-sidekiq"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates Sidekiq worker `perform_async` argument arity."
  spec.description = "Walks `app/workers/` (and `app/sidekiq/`) for classes that " \
                     "`include Sidekiq::Job` (or the legacy `Sidekiq::Worker`), indexes " \
                     "their `#perform` arity, and validates `Worker.perform_async(...)` / " \
                     "`.perform_in(...)` / `.perform_at(...)` / `.perform_inline(...)` " \
                     "call sites for argument count. No Sidekiq runtime."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
