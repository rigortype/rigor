#!/usr/bin/env ruby
# frozen_string_literal: true

# Issue #427 — the anti-vacuity assertion for the `Self-check diff (warm == cold)` gate.
#
# That gate is our detector for cache-identity regressions, most importantly the rbs `TypeName#hash` /
# `Namespace#hash` memoisation hazard that `lib/rigor/cache/rbs_environment_marshal_patch.rb` exists to
# neutralise: a memoised hash rides into the Marshal'd `rbs.environment` blob and comes back wrong in a
# FRESH process, so every analysis built on it is quietly different. Catching that needs one specific
# condition — a cross-process restore of that blob, followed by a real analysis against it.
#
# The gate could not meet that condition on the pull requests that matter most, for two separate reasons:
#
# 1. **A lockfile change leaves nothing restorable.** The cache key and both restore-keys are scoped to
#    `hashFiles('Gemfile.lock')` — correctly, since a stale-lockfile restore makes the gem-without-rbs
#    count diverge — so a gem bump starts the warm arm empty and the diff compares two cold runs. Observed
#    on #412 (rbs 4.1.1 → 4.1.3, sole changed file `Gemfile.lock`), green against nothing.
# 2. **A fully warm arm never loads the environment at all.** Measured: with the whole-run
#    `analysis.run-diagnostics` slot populated, `rigor check` is served from it and `rbs.environment` is
#    consulted ZERO times — the analysis does not happen, so a broken env cannot show. The warm arm only
#    exercises the hazard when the whole-run slot misses and the RBS slices hit.
#
# The workflow now puts the arm in exactly that state (prime when the restore missed, then drop the
# whole-run slot), and this asserts the state was reached: `rbs.environment` served this run, so the
# diagnostics the diff compares were computed against a cross-process-restored environment.
#
# The whole-run slot's own correctness is not this gate's job and is not left uncovered — it is pinned
# in-suite by the ADR-45 specs and `spec/rigor/effects/persistence_spec.rb`, both of which assert a
# cache-served run against a computed one.
#
# Usage: bundle exec ruby tool/warm_cache_assertion.rb [PATH...]

require "English"
require "fileutils"
require "open3"

require_relative "../lib/rigor/configuration"

# The producer whose cross-process restore the hazard rides in. Asserting on THIS rather than on any
# hit at all is the difference between "a cache was read" and "the cache that can be wrong was read".
PRODUCER = "rbs.environment"

# `    rbs.environment: 1 hit, 0 misses, 0 writes`. Parsed narrowly on purpose: a pattern that cannot
# find its line must FAIL rather than pass quietly, which is the same trap one level up from the one
# this gate is about.
def run_line(producer)
  /^\s+#{Regexp.escape(producer)}:\s+(\d+)\s+hits?,\s+(\d+)\s+miss(?:es)?,\s+(\d+)\s+writes?$/
end

def fail_with(message)
  warn("warm-cache assertion FAILED: #{message}")
  warn("")
  warn("The `Self-check diff (warm == cold)` gate compares this arm's diagnostics against the cold")
  warn("arm's. Unless this arm analysed against a cross-process-restored `#{PRODUCER}`, the gate cannot")
  warn("see a cache-identity regression — the rbs Marshal-hash hazard among them (issue #427).")
  exit 1
end

paths = ARGV.empty? ? ["lib"] : ARGV

# The tool establishes its own measurement state, the way `tool/mutation_cache_gate.rb` runs its own
# three arms rather than trusting the caller to have set one up.
#
# The state it needs is the one the workflow puts the MEASURED run in: RBS slices present, whole-run
# slot absent. That slot has to be dropped here and not merely by the workflow beforehand, because the
# measured `rigor check` between the two WRITES it back — the first version of this gate asserted
# against the state the check left rather than the state it ran in, and failed for that reason.
slot = File.join(Rigor::Configuration.load(nil).cache_path, "analysis.run-diagnostics")
FileUtils.rm_rf(slot)

command = ["bundle", "exec", "exe/rigor", "check", "--cache-stats", *paths]
stdout, stderr, status = Open3.capture3(*command)

# A check that finds diagnostics exits 1; that is not this gate's business. Only a crash is.
fail_with("`#{command.join(' ')}` did not run (exit #{status.exitstatus})\n#{stderr}") if
  status.exitstatus.nil? || status.exitstatus > 1
fail_with("the run printed no `this run:` cache statistics at all") unless stdout.include?("this run:")

match = stdout.match(run_line(PRODUCER))
if match.nil?
  fail_with(
    "the run printed cache statistics, but nothing for `#{PRODUCER}` — the environment was never " \
    "consulted, which means either nothing was restored or the whole-run slot served this run without " \
    "analysing at all"
  )
end

hits, misses, = match.captures.map(&:to_i)
fail_with("`#{PRODUCER}` reports #{hits} hits — it was rebuilt, not restored") if hits.zero?
fail_with("`#{PRODUCER}` reports #{misses} miss(es) alongside #{hits} hit(s)") unless misses.zero?

puts "warm-cache assertion OK: #{PRODUCER} served this run from cache (#{hits} hit(s), 0 misses), so the " \
     "diagnostics were computed against a cross-process-restored environment."
