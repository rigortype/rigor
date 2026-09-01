# frozen_string_literal: true

require_relative "lib/rigor/version"

Gem::Specification.new do |spec|
  spec.name = "rigortype"
  spec.version = Rigor::VERSION
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Inference-first static analysis for Ruby."
  # ADR-27 — the "not in your Gemfile" sentence is deliberately in the *description*, not only in the
  # docs: rubygems.org renders it on the gem page, which is the page a coding agent fetches when it is
  # told "install https://rubygems.org/gems/rigortype". That page's own first suggestion is `bundle add
  # rigortype`, so the counter-instruction has to reach the same reader at the same moment.
  spec.description = "Rigor is a CLI-first static analyzer for Ruby applications that prioritizes type inference, " \
                     "clean application code, and zero runtime dependencies. Rigor is a standalone tool, not a " \
                     "library: install it independently rather than adding it to your application's Gemfile. It " \
                     "runs on Ruby 4.0 while your project keeps its own Ruby, and it reads your project as data " \
                     "rather than loading it, so a Gemfile entry only constrains your application's Ruby and " \
                     "dependency resolution. Installation channels (mise, asdf, gem install, container, Nix): " \
                     "https://github.com/rigortype/rigor/blob/master/docs/install.md"
  spec.homepage = "https://github.com/rigortype/rigor"
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]

  # Shown by both `gem install rigortype` (a supported channel, ADR-27 WD6) and `bundle add rigortype`
  # (not one), so the Gemfile half is phrased conditionally rather than as an accusation. This is the
  # only hook that reaches a Ruby-4.0 project where `bundle add` *succeeds* — there the Gemfile entry is
  # a delayed trap that surfaces at the next boot, not at install time.
  spec.post_install_message = <<~MESSAGE
    Rigor installs as a standalone CLI, not a project dependency. Run `rigor check app lib` from your
    project root — no `bundle exec`.

    If this came from `bundle add rigortype` or a Gemfile entry, remove it: Rigor runs on its own Ruby
    and analyses your project from the outside, so in a Gemfile it constrains your application's Ruby
    and dependency resolution without giving you anything. Per-project version pinning without that
    cost, plus every other channel, is documented in
    https://github.com/rigortype/rigor/blob/master/docs/install.md
  MESSAGE

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
      data/effects/**/*.yml
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
  # 0.5.0 is the floor, not a preference: CI's `Tests` matrix runs `binpacker run --shard K/N` and gates
  # the merge on `binpacker shards-check`, both of which arrived in 0.5.0. An older binpacker would fail
  # the run on an unknown flag rather than quietly running the whole suite three times, but it would fail
  # it far from the cause.
  spec.add_development_dependency "binpacker", ">= 0.5.0", "< 1.0"
  spec.add_development_dependency "rake", ">= 13.0", "< 15.0"
  # ADR-32 — the `rigor-rbs-inline` plugin under `plugins/`
  # depends on the upstream `rbs-inline` gem at runtime. The
  # production dependency lives on the plugin's own gemspec;
  # listed here as a development dep so the repo's integration
  # spec suite can exercise the plugin end-to-end without
  # users of `rigortype` paying the cost (ADR-0 zero-runtime-dep).
  spec.add_development_dependency "rbs-inline", ">= 0.5", "< 1.0"
  spec.add_development_dependency "rspec", ">= 3.13", "< 4.0"
  # Suite-performance instrumentation. The suite's runtime is concentrated in a
  # few hundred examples that each drive a real analysis, so "which files are
  # slow" (binpacker's timing file already answers that) is not enough — the
  # question is how much of an example goes to `let`/`before` setup versus the
  # thing under test. `RD_PROF` answers it per file, and `EVENT_PROF` attributes
  # suite time to instrumented engine entry points. Profilers stay inert unless
  # their env var is set, so this costs the default run only its require.
  spec.add_development_dependency "test-prof", ">= 1.6", "< 2.0"
  spec.add_development_dependency "rubocop", ">= 1.70", "< 2.0"
  spec.add_development_dependency "rubocop-rake", ">= 0.6", "< 1.0"
  spec.add_development_dependency "rubocop-rspec", ">= 3.0", "< 4.0"
end
