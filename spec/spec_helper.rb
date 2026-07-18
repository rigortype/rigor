# frozen_string_literal: true

if ENV["COVERAGE"]
  require "coverage"
  Coverage.start(lines: true)
  at_exit do
    result = Coverage.result
    lib_root = File.expand_path("../lib", __dir__)
    lib_files = result.select { |path, _| path.start_with?(lib_root) }
    rows = lib_files.map do |path, data|
      lines = data[:lines]
      total = lines.compact.size
      hit   = lines.count { |n| n&.> 0 }
      [path.delete_prefix("#{lib_root}/"), total, hit]
    end
    report = rows.sort_by { |_, total, hit| hit.to_f / [total, 1].max }

    # Opt-in structured dump for the self-mutation harness (tool/mutation/self_mutate.rb --coverage-gap): {lib-relative
    # path => [executed line numbers]}. A mutation site on a line absent here is run by no spec, so it is provably
    # test-unprotected without a per-mutant suite run.
    if ENV["COVERAGE_JSON"]
      require "json"
      covered = lib_files.to_h do |path, data|
        lines = data[:lines]
        executed = (0...lines.size).select { |i| lines[i]&.positive? }.map { |i| i + 1 }
        [path.delete_prefix("#{lib_root}/"), executed]
      end
      File.write(ENV["COVERAGE_JSON"], JSON.generate(covered))
      warn "Coverage line-index written to #{ENV['COVERAGE_JSON']}"
    end

    out = File.expand_path("../coverage_report.txt", __dir__)
    File.open(out, "w") do |f|
      f.puts "# Coverage report — #{Time.now.strftime('%Y-%m-%d %H:%M')}"
      f.puts "# file | total_lines | covered | pct"
      report.each do |path, total, hit|
        pct = total.zero? ? 0 : (hit * 100.0 / total).round(1)
        f.printf("%<path>-80s  %<total>4d  %<hit>4d  %<pct>5.1f%%\n", path: path, total: total, hit: hit, pct: pct)
      end
    end
    warn "\nCoverage report written to coverage_report.txt"
  end
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

# Silence MRI's once-per-process "Ractor API is experimental" warning during test runs. Rigor uses Ractors as a
# committed production feature (ADR-15 Phase 4 — `Analysis::Runner` worker pool), so the warning is informational noise
# on every `make verify`. Suppressed only here — downstream `rigortype` users keep the warning.
Warning[:experimental] = false if Warning.respond_to?(:[]=)

# ADR-51 WD7 — disable CI auto-detection for the whole suite so the many `rigor check` text-output specs are
# deterministic regardless of whether the suite itself runs under a CI (Rigor's own CI is GitHub Actions, which would
# otherwise make `rigor check` augment its output with `::error` annotations). The CiDetector specs opt back in
# per-example by setting the platform env var + `RIGOR_CI_DETECT=1` and restoring both after.
ENV["RIGOR_CI_DETECT"] = "0"

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

  # ADR-15 Phase 4b — `spec/rigor/analysis/runner_pool_spec.rb` is excluded from the default suite and runs as its own
  # rspec process via `make test-ractor-pool` (part of `make verify` and CI). The original reason was real Ractor spawns
  # destabilising LATER same-process specs (Bus Error in the inference path — likely RBS C-extension state interacting
  # with main-Ractor GC after Ractor cleanup). Since the fork-backend default (86ed9129, `Runner#pool_backend`) the file
  # spawns no Ractors unless RIGOR_POOL_BACKEND=ractor is exported; the exclusion is kept so an exported backend
  # override can never destabilise the main suite. Set `RIGOR_INCLUDE_RACTOR_POOL=1` to opt the file back in to a
  # same-process run.
  config.exclude_pattern = "spec/rigor/analysis/runner_pool_spec.rb" unless ENV["RIGOR_INCLUDE_RACTOR_POOL"]

  # ADR-93 WD2 — `Configuration.load` default-wires the bundled `rigor-rbs-inline` plugin whenever the upstream
  # `rbs-inline` library is resolvable, which it is under this repo's bundle. Left live, that would inject the
  # plugin into almost every in-process `rigor check` the suite runs; and because the suite pervasively calls
  # `Rigor::Plugin.unregister!` while `require` is a once-per-process no-op, the reload against the emptied
  # registry surfaces a spurious `plugin_loader.load-error` (a suite artifact — a real `rigor` process starts
  # fresh, requires the plugin once, and loads it cleanly). So the environment probe is pinned off for the
  # whole suite, mirroring the RIGOR_CI_DETECT pin above. Specs that exercise the auto-wire tag themselves
  # `:rbs_inline_autowire` (and stub the probe to `true` in a controlled registry); the real behaviour is
  # covered end-to-end by those specs plus the ADR-93 WD4 corpus gate.
  config.before do |example|
    unless example.metadata[:rbs_inline_autowire]
      allow(Rigor::Configuration).to receive(:rbs_inline_library_resolvable?).and_return(false)
    end
  end
end
