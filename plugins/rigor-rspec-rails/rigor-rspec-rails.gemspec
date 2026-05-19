# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-rspec-rails"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin: validates rspec-rails behavioral matchers."
  spec.description = "Recognises rspec-rails matchers whose arguments are statically " \
                     "checkable and emits domain-specific diagnostics. v0.1.0 covers " \
                     "`have_http_status(int_or_symbol)` — validates that an Integer " \
                     "argument is in the 100..599 range and that a Symbol argument is " \
                     "one of the Rack::Utils::SYMBOL_TO_STATUS_CODE keys or one of " \
                     "Rails' status-group aliases (`:success` / `:successful` / " \
                     "`:missing` / `:redirect` / `:error` / `:client_error` / " \
                     "`:server_error` / `:informational`). The other heavyweight matchers " \
                     "(`render_template`, `route_to`, `redirect_to`, `have_enqueued_job`, " \
                     "...) are deferred — `render_template` overlaps with " \
                     "rigor-actionpack's render-target validation; route_to / redirect_to " \
                     "need cross-plugin routes coordination. Sibling to rigor-rspec / " \
                     "rigor-minitest under Pillar 2 (the 'Your specs are types' track)."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
