# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-rails"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin meta-gem: Tier 1+2 Rails ecosystem plugins (ADR-12 umbrella shape)."
  spec.description = "Convenience meta-gem that pulls in the Tier 1+2 Rails ecosystem plugins via " \
                     "`Gemfile` dependency resolution. A single `gem \"rigor-rails\"` line installs " \
                     "rigor-rails-routes / rigor-rails-i18n / rigor-actionmailer / rigor-activejob / " \
                     "rigor-activerecord / rigor-actionpack / rigor-factorybot. Per ADR-12 WD1 the " \
                     "umbrella is Gemfile-convenience only; users still enumerate the individual " \
                     "plugins they want active in `.rigor.yml`'s `plugins:` list. See " \
                     "docs/design/20260508-rails-plugins-roadmap.md for the per-plugin scope and " \
                     "the eventual publication path."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  # Tier 1 (current API)
  spec.add_dependency "rigor-actionmailer", ">= 0.1.0", "< 1.0"
  spec.add_dependency "rigor-activejob", ">= 0.1.0", "< 1.0"
  spec.add_dependency "rigor-rails-i18n", ">= 0.1.0", "< 1.0"
  spec.add_dependency "rigor-rails-routes", ">= 0.1.0", "< 1.0"

  # Tier 2 (current API + cross-plugin via ADR-9)
  spec.add_dependency "rigor-actionpack", ">= 0.1.0", "< 1.0"
  spec.add_dependency "rigor-activerecord", ">= 0.1.0", "< 1.0"
  spec.add_dependency "rigor-factorybot", ">= 0.1.0", "< 1.0"

  spec.add_dependency "rigortype", ">= 0.1.5", "< 0.2.0"
end
