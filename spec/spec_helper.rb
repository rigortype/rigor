# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

# Silence MRI's once-per-process "Ractor API is experimental" warning
# during test runs. Rigor uses Ractors as a committed production
# feature (ADR-15 Phase 4 — `Analysis::Runner` worker pool), so the
# warning is informational noise on every `make verify`. Suppressed
# only here — downstream `rigortype` users keep the warning.
Warning[:experimental] = false if Warning.respond_to?(:[]=)

require "rigor"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }
Dir[File.expand_path("integration/**/support/**/*.rb", __dir__)].each { |f| require f }

RSpec.configure do |config|
  config.include RunnerHelpers, type: :runner
  config.define_derived_metadata(
    file_path: %r{/spec/rigor/analysis/runner_spec\.rb\z}
  ) do |meta|
    meta[:type] = :runner
  end

  # ADR-15 Phase 4b — `spec/rigor/analysis/runner_pool_spec.rb`
  # spawns real Ractors via `Runner.new(workers: N).run(...)`.
  # Ruby 4.0 + rbs 4.0.2 occasionally surfaces a Bus Error in
  # the inference path of LATER specs after Ractor cleanup
  # (likely RBS C-extension state interacting with main-Ractor
  # GC). The pool spec is excluded from the default suite to
  # keep `make verify` deterministic; set
  # `RIGOR_INCLUDE_RACTOR_POOL=1` to opt back in (run pool spec
  # in isolation via `make test-ractor-pool` if you want
  # repeatable coverage). The Phase 4b commit shipped with
  # this flake masked by run-to-run variance; Phase 4c will
  # address the worker-side env build stability.
  config.exclude_pattern = "spec/rigor/analysis/runner_pool_spec.rb" unless ENV["RIGOR_INCLUDE_RACTOR_POOL"]
end
