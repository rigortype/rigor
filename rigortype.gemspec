# frozen_string_literal: true

require_relative "lib/rigor/version"

Gem::Specification.new do |spec|
  spec.name = "rigortype"
  spec.version = Rigor::VERSION
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Inference-first static analysis for Ruby."
  spec.description = "Rigor is a CLI-first static analyzer for Ruby applications that prioritizes type inference, " \
                     "clean application code, and zero runtime dependencies."
  spec.homepage = "https://github.com/rigortype/rigor"
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]

  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "source_code_uri" => spec.homepage,
    "documentation_uri" => "#{spec.homepage}/tree/master/docs",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.glob(
    %w[
      README.md
      LICENSE
      exe/*
      lib/**/*.rb
      sig/**/*.rbs
      data/builtins/**/*.yml
      data/**/*.rbs
      skills/*/SKILL.md
      skills/*/references/*.md
      docs/install.md
      docs/llms.txt
      docs/manual/**/*.md
      docs/handbook/**/*.md
    ]
  ) + Dir.glob("plugins/*/lib/**/*.rb") \
    + Dir.glob("plugins/*/sig/**/*.rbs")
  spec.bindir = "exe"
  spec.executables = ["rigor"]
  spec.require_paths = ["lib"] +
                       Dir.glob("plugins/*/lib")

  spec.add_dependency "language_server-protocol", ">= 3.17", "< 4.0"
  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rbs", ">= 3.0", "< 5.0"

  # ADR-39 — the bundled Rails plugins (`rigor-activerecord`,
  # `rigor-rails-routes`, `rigor-actionpack`) invoke the real
  # `ActiveSupport::Inflector` for authoritative inflection rather than
  # reimplementing them. The production dependency lives on each
  # plugin's own gemspec; listed here as a development dep so the repo's
  # integration spec suite can exercise the shared `Plugin::Inflector`
  # end-to-end without users of `rigortype` paying the cost
  # (ADR-0 zero-runtime-dep; same pattern as `rbs-inline` below).
  spec.add_development_dependency "activesupport", ">= 7.0", "< 9.0"
  # ADR-39 — rigor-rspec-rails validates `have_http_status(:symbol)`
  # against the real `Rack::Utils::SYMBOL_TO_STATUS_CODE` rather than a
  # vendored snapshot that could go stale (a newly-added Rack symbol
  # flagged as a false `unknown-symbol`). Development dep so the suite
  # exercises the real catalogue; the production dep belongs on the
  # plugin gem (rspec-rails apps already pull rack via actionpack).
  spec.add_development_dependency "rack", ">= 2.0", "< 4.0"
  spec.add_development_dependency "binpacker", ">= 0.1.0", "< 1.0"
  spec.add_development_dependency "rake", ">= 13.0", "< 15.0"
  # ADR-32 — the `rigor-rbs-inline` plugin under `plugins/`
  # depends on the upstream `rbs-inline` gem at runtime. The
  # production dependency lives on the plugin's own gemspec;
  # listed here as a development dep so the repo's integration
  # spec suite can exercise the plugin end-to-end without
  # users of `rigortype` paying the cost (ADR-0 zero-runtime-dep).
  spec.add_development_dependency "rbs-inline", ">= 0.5", "< 1.0"
  spec.add_development_dependency "rspec", ">= 3.13", "< 4.0"
  spec.add_development_dependency "rubocop", ">= 1.70", "< 2.0"
  spec.add_development_dependency "rubocop-rake", ">= 0.6", "< 1.0"
  spec.add_development_dependency "rubocop-rspec", ">= 3.0", "< 4.0"
end
