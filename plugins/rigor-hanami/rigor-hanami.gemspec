# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-hanami"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates Hanami action protocol (#handle method presence and parameter typing)."
  spec.description = "Enforces the Hanami::Action protocol: every class under `app/actions/` must " \
                     "define `#handle(request, response)`. The plugin also provides " \
                     "`Hanami::Action::Request` / `Hanami::Action::Response` type information into " \
                     "action bodies via ADR-28 protocol contracts, so misuse of request or response " \
                     "is caught by core engine diagnostics. No `hanami` runtime dependency."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb sig/**/*.rbs])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
