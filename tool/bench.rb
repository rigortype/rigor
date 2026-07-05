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
  band = { "wall_pct" => 10, "allocations_pct" => 5, "rss_pct" => 10 }
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

unless baseline["calibrated"]
  fresh = {
    "calibrated" => true,
    "calibrated_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "targets" => results
  }
  out_path = options[:write] || "#{options[:baseline].sub(/\.json\z/, '')}.updated.json"
  File.write(out_path, "#{JSON.pretty_generate(fresh)}\n")
  puts "First run — baseline uncalibrated; suggested baseline written to #{out_path}:"
  puts JSON.pretty_generate(results)
  puts "(Commit a CI-measured baseline as bench/baseline.json to activate the gate.)"
  exit 0
end

regressions = []
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
    end
  end
end

if regressions.empty?
  puts "All perf-benchmark checks passed."
  exit 0
else
  warn "Perf-benchmark regressions detected:"
  regressions.each { |r| warn "  #{r}" }
  exit 1
end
