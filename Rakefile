# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# Run the spec suite across `PARALLEL_TEST_PROCESSORS` (or
# CPU-count) worker processes via `parallel_tests`. Each
# worker runs RSpec on a balanced slice of the spec files
# so the wall-clock time scales with available cores.
# Plugin registry is process-global; the parallel runner
# uses separate processes, so registry state stays isolated.
#
# `--group-by filesize` is a better default than the
# upstream `found` (file-discovery order) because the spec
# distribution here is skewed: `runner_spec.rb` is ~2× the
# next-largest spec file. The filesize grouping at least
# keeps the big file on its own worker rather than
# bundling it with other slow files.
desc "Run the spec suite in parallel across processes"
task :spec_parallel do
  count = ENV.fetch("PARALLEL_TEST_PROCESSORS", "")
  args = ["bundle", "exec", "parallel_rspec", "--group-by", "filesize"]
  args.push("-n", count) unless count.empty?
  # ADR-15 Phase 4b — `runner_pool_spec.rb` is excluded by the
  # sequential `make test` path via `RSpec.config.exclude_pattern`
  # (spec_helper.rb). parallel_rspec splits files BEFORE workers
  # load spec_helper, so the exclude_pattern there doesn't apply
  # — we have to pass `--exclude-pattern` natively here.
  # `RIGOR_INCLUDE_RACTOR_POOL=1` opts the pool spec back in,
  # mirroring the sequential exclusion's opt-out shape.
  args.push("--exclude-pattern", "spec/rigor/analysis/runner_pool_spec.rb") unless ENV["RIGOR_INCLUDE_RACTOR_POOL"]
  args.push("spec")
  exec(*args)
end

task default: :spec
