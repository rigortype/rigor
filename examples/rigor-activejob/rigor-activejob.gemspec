# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-activejob"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates ActiveJob `Job.perform_later` argument arity."
  spec.description = "Walks `app/jobs/` (or the configured `job_search_paths`) for classes whose " \
                     "direct superclass is `ApplicationJob` / `ActiveJob::Base`, records each " \
                     "discovered class's `#perform` arity, and validates `Job.perform_later(...)` " \
                     "/ `Job.perform_now(...)` / `Job.perform(...)` call sites against it. No " \
                     "Rails runtime dependency — the plugin reads project source only."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
