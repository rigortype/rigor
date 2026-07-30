#!/usr/bin/env ruby
# frozen_string_literal: true

# ADR-50 WD4 — perf-regression benchmark for `make bench-perf` / the release gate.
#
# Runs `rigor check` in-process over one or more targets, measures wall time, total allocated objects, and peak RSS
# (Linux only), then gates against a committed baseline within a tunable tolerance band (bench/thresholds.yml).
#
# First run (baseline uncalibrated): writes a SUGGESTED baseline to a `.updated.json` sibling and passes — the same
# calibrate-on-first-run pattern as tool/oss_sweep_compare.rb. The committed baseline is never overwritten implicitly;
# commit a CI-measured baseline to activate the gate.
#
# Usage:
#   ruby tool/bench.rb [--target PATH ...] \
#     [--baseline PATH] [--thresholds PATH] [--write-baseline PATH]

require "json"
require "optparse"
require "stringio"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))
require "rigor/cli"

options = {
  targets: [],
  baseline: File.join(ROOT, "bench", "baseline.json"),
  thresholds: File.join(ROOT, "bench", "thresholds.yml"),
  write: nil
}
OptionParser.new do |o|
  o.on("--target PATH") { |v| options[:targets] << v }
  o.on("--baseline PATH") { |v| options[:baseline] = v }
  o.on("--thresholds PATH") { |v| options[:thresholds] = v }
  o.on("--write-baseline PATH") { |v| options[:write] = v }
end.parse!
options[:targets] = ["lib"] if options[:targets].empty?

# Peak RSS is read from /proc on Linux (the CI runner, which is the authoritative measurement host). On macOS / other
# hosts there is no /proc/self/status, so RSS is reported nil and the gate skips it — local `make bench-perf` still
# measures wall + allocations, which are portable.
def peak_rss_kb
  status = "/proc/self/status"
  return nil unless File.readable?(status)

  File.read(status)[/VmHWM:\s+(\d+)\s+kB/, 1]&.to_i
end

def measure(target)
  out = StringIO.new
  err = StringIO.new
  GC.start
  before = GC.stat(:total_allocated_objects)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    Rigor::CLI.new(
      ["check", "--no-cache", "--no-stats", "--format", "json", target],
      out: out, err: err
    ).run
  rescue SystemExit
    # A subcommand that calls `exit`/`abort` — measure regardless.
  end
  wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  allocated = GC.stat(:total_allocated_objects) - before
  diagnostics =
    begin
      JSON.parse(out.string).fetch("diagnostics", []).size
    rescue StandardError
      nil
    end
  {
    "wall_s" => wall.round(3),
    "allocations" => allocated,
    "peak_rss_kb" => peak_rss_kb,
    "diagnostics" => diagnostics
  }
end

# Tiny `key: int` reader so the gate stays dependency-free. Lines that are
# blank or start with `#` are ignored; only the known band keys are honoured.
def load_thresholds(path)
  band = { "wall_pct" => 10, "allocations_pct" => 5, "rss_pct" => 10, "stale_pct" => 15 }
  return band unless File.readable?(path)

  File.foreach(path, encoding: "UTF-8") do |line|
    stripped = line.strip
    next if stripped.empty? || stripped.start_with?("#")

    key, value = stripped.split(":", 2)
    band[key.strip] = value.to_i if key && value && band.key?(key.strip)
  end
  band
end

results = {}
options[:targets].each do |target|
  warn "Benchmarking: rigor check #{target}"
  results[target] = measure(target)
end

baseline =
  begin
    JSON.parse(File.read(options[:baseline], encoding: "UTF-8"))
  rescue StandardError
    { "calibrated" => false }
  end
band = load_thresholds(options[:thresholds])

# The suggestion sibling is written on EVERY run, not only an uncalibrated one. `bench/baseline.json`'s own refresh
# instructions say to trigger release-gate.yml and commit the uploaded artifact's targets — and that produced nothing
# whenever the baseline was calibrated, i.e. in the only state a refresh is ever wanted, with the workflow's
# `if-no-files-found: ignore` swallowing the gap. Writing it unconditionally is what makes the documented procedure
# work; the file is gitignored, so a local run still never touches the committed baseline.
suggested = {
  "calibrated" => true,
  "calibrated_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
  "targets" => results
}
out_path = options[:write] || "#{options[:baseline].sub(/\.json\z/, '')}.updated.json"
File.write(out_path, "#{JSON.pretty_generate(suggested)}\n")

unless baseline["calibrated"]
  puts "First run — baseline uncalibrated; suggested baseline written to #{out_path}:"
  puts JSON.pretty_generate(results)
  puts "(Commit a CI-measured baseline as bench/baseline.json to activate the gate.)"
  exit 0
end

# A one-sided gate loses its teeth silently. The band is a percentage OF THE BASELINE, so a real improvement that is
# never folded back in leaves the ceiling anchored at the old cost: after `lib` allocations fell 32.40M → 23.52M
# (a `sig/` correctness fix removed a whole `stub_missing_referenced_types` pass), the +5% band still permitted 34.02M
# — +44% over the real cost, and no run said so. This notice is the counterweight. It never fails the build: an
# improvement is not a regression, and the only action it asks for is a reviewed baseline commit.
#
# Allocations only, deliberately. It is the deterministic signal (`thresholds.yml`); wall and RSS drift with runner
# noise, and a staleness notice that fires on noise is one people learn to scroll past — the same false-positive cost
# the analyzer's own rules are held to.
STALENESS_METRIC = "allocations"

# The notice text, or nil when the metric is not the deterministic one or the drop is inside `stale_pct`. `headroom`
# is what actually matters to a reader: how far the current cost could grow before the unrefreshed band notices.
def staleness_notice(target, metric, now_value, base_value, pct, limit, stale_pct)
  return nil unless metric == STALENESS_METRIC
  return nil unless now_value < base_value * (1 - (stale_pct / 100.0))

  drop = ((1 - (now_value.to_f / base_value)) * 100).round(1)
  headroom = (((limit / now_value.to_f) - 1) * 100).round
  "STALE #{target} #{metric}: #{now_value} is #{drop}% below baseline #{base_value}; " \
    "the +#{pct}% band still permits #{limit.round} (+#{headroom}% over the real cost)"
end

regressions = []
stale = []
results.each do |target, now|
  base = baseline.dig("targets", target)
  unless base
    warn "No baseline for target #{target} — skipping (recalibrate to add it)."
    next
  end

  {
    "wall_s" => band["wall_pct"],
    "allocations" => band["allocations_pct"],
    "peak_rss_kb" => band["rss_pct"]
  }.each do |metric, pct|
    b = base[metric]
    n = now[metric]
    next if b.nil? || n.nil? || b.zero?

    limit = b * (1 + (pct / 100.0))
    if n > limit
      delta = (((n.to_f / b) - 1) * 100).round(1)
      regressions << "FAIL #{target} #{metric}: #{n} > #{limit.round} " \
                     "(+#{delta}% vs baseline #{b}, band +#{pct}%)"
    else
      puts "OK   #{target} #{metric}: #{n} ≤ #{limit.round} (baseline #{b})"
      notice = staleness_notice(target, metric, n, b, pct, limit, band["stale_pct"])
      stale << notice if notice
    end
  end
end

unless stale.empty?
  warn "Perf-benchmark baseline looks stale:"
  stale.each { |s| warn "  #{s}" }
  warn "  Recalibrate from a Linux CI run: commit #{out_path}'s targets as #{options[:baseline]}."
end

if regressions.empty?
  puts "All perf-benchmark checks passed."
  exit 0
else
  warn "Perf-benchmark regressions detected:"
  regressions.each { |r| warn "  #{r}" }
  exit 1
end
