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
# ## Sampling: every rep is a FRESH PROCESS (#987)
#
# `make bench-perf` is still ONE command. This process spawns itself — `ruby tool/bench.rb --measure TARGET` — once
# per rep, and each child does exactly what the whole script used to do: one in-process `Rigor::CLI` run over one
# target, printing its metrics as a single JSON object on stdout. The parent reduces the reps and gates.
#
# A rep cannot be a second loop inside one process, for two independent reasons:
#
#   * `peak_rss_kb` is `/proc/self/status`'s `VmHWM`, a per-process HIGH-WATER mark. A second in-process run can
#     never report a lower number than the first, so in-process reps do not sample RSS at all — they report the
#     running maximum, which is the one statistic repetition was supposed to defend against.
#   * the committed baseline is a COLD run. Wall time in a warm process (parsed sources cached, RBS environment
#     built, YJIT possibly already enabled mid-flight by `Runtime::Jit.enable_after`) is not comparable with it, so
#     a warm rep's "lower" wall is a different measurement, not a quieter one.
#
# Spawning also keeps the gate's YJIT handling untouched: the child inherits the environment
# (`RIGOR_DISABLE_YJIT`, `RUBY_YJIT_ENABLE`, `RUBYOPT`, `BUNDLE_GEMFILE`), so it decides about YJIT exactly as the
# single-run gate did, and each rep pays the same deferred-enable deadline from zero.
#
# ## Reduction: lower-of-N on the noisy axes only
#
# `wall_s` and `peak_rss_kb` take the LOWER of the reps. Host interference on a shared runner can only ever ADD
# time and resident pages, so the minimum is the sample least contaminated by the runner — and #987 measured ±7%
# spread on `peak_rss_kb` against a +10% band, i.e. noise nearly as wide as the gate itself.
#
# `allocations` and `diagnostics` stay SINGLE-SAMPLE (the first rep). Allocations are deterministic to ~±20
# objects and diagnostics are a count of a deterministic analysis; reducing them would buy nothing and would hide
# a real nondeterminism behind a min().
#
# Usage:
#   ruby tool/bench.rb [--target PATH ...] [--reps N] \
#     [--baseline PATH] [--thresholds PATH] [--write-baseline PATH]
#   ruby tool/bench.rb --measure PATH      # internal: one rep, JSON on stdout

require "json"
require "optparse"
require "rbconfig"
require "stringio"

# Namespaced so the reducer can be unit-tested (`spec/tool/bench_sampling_spec.rb` requires this file; the
# `$PROGRAM_NAME` guard at the bottom is what keeps requiring it from running a benchmark).
module Bench
  ROOT = File.expand_path("..", __dir__)

  # Reps per target. Two is the cheapest number that can defend against a single contaminated sample; the gate job
  # pays one extra cold analysis per target for it.
  DEFAULT_REPS = 2

  # The noisy axes — reduced by `min` across the reps. See the header for why "lower" is the right reducer here
  # rather than a median (interference is one-sided).
  LOWER_OF_REPS = %w[wall_s peak_rss_kb].freeze

  # The deterministic axes — taken from the first rep, unreduced.
  SINGLE_SAMPLE = %w[allocations diagnostics].freeze

  # A one-sided gate loses its teeth silently. The band is a percentage OF THE BASELINE, so a real improvement that
  # is never folded back in leaves the ceiling anchored at the old cost: after `lib` allocations fell 32.40M →
  # 23.52M (a `sig/` correctness fix removed a whole `stub_missing_referenced_types` pass), the +5% band still
  # permitted 34.02M — +44% over the real cost, and no run said so. This notice is the counterweight. It never
  # fails the build: an improvement is not a regression, and the only action it asks for is a reviewed baseline
  # commit.
  #
  # Allocations only, deliberately. It is the deterministic signal (`thresholds.yml`); wall and RSS drift with
  # runner noise, and a staleness notice that fires on noise is one people learn to scroll past — the same
  # false-positive cost the analyzer's own rules are held to.
  STALENESS_METRIC = "allocations"

  module_function

  # Peak RSS is read from /proc on Linux (the CI runner, which is the authoritative measurement host). On macOS /
  # other hosts there is no /proc/self/status, so RSS is reported nil and the gate skips it — local
  # `make bench-perf` still measures wall + allocations, which are portable.
  def peak_rss_kb
    status = "/proc/self/status"
    return nil unless File.readable?(status)

    File.read(status)[/VmHWM:\s+(\d+)\s+kB/, 1]&.to_i
  end

  # ONE rep, in THIS process. Only ever called in a `--measure` child, so the process it measures has done nothing
  # else first.
  def measure(target)
    $LOAD_PATH.unshift(File.join(ROOT, "lib")) unless $LOAD_PATH.include?(File.join(ROOT, "lib"))
    require "rigor/cli"

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

  # Collapse the reps into the single metric hash the gate and the suggested baseline both consume — the shape is
  # exactly what one rep returns, so nothing downstream learns that sampling happened.
  #
  # A metric that is nil in every rep (peak RSS off Linux) stays nil, which is what makes the gate skip it; a
  # metric nil in SOME reps reduces over the reps that have it rather than poisoning the result.
  def reduce_samples(samples)
    raise ArgumentError, "no samples to reduce" if samples.nil? || samples.empty?

    reduced = samples.first.dup
    LOWER_OF_REPS.each do |metric|
      values = samples.filter_map { |sample| sample[metric] }
      reduced[metric] = values.empty? ? nil : values.min
    end
    reduced
  end

  # The child's output and exit status. Its own method so the failure paths below are reachable from a spec without
  # spawning anything.
  def popen_rep(cmd)
    raw = IO.popen(cmd, &:read)
    [raw, $?]
  end

  # One rep = one fresh child of this script. Anything short of a clean, parseable rep aborts: a gate that silently
  # falls back to fewer samples than it claims is worse than one that stops.
  #
  # `status.inspect` rather than `exitstatus`, because a child killed by a signal (the OOM killer is the realistic
  # case for a benchmark) has a nil exit status and would otherwise print "exited nil".
  def measure_in_fresh_process(target)
    cmd = [RbConfig.ruby, File.expand_path(__FILE__), "--measure", target]
    raw, status = popen_rep(cmd)
    abort("bench rep for #{target} failed (#{status.inspect}) — no sample to reduce") unless status&.success?

    begin
      JSON.parse(raw)
    rescue JSON::ParserError
      abort("bench rep for #{target} produced unparseable output: #{raw.inspect}")
    end
  end

  # Each rep's own numbers go to stderr before they are reduced. Without them a reader sees only the reduced value
  # and cannot tell a quiet host from a wide spread — which is the exact question #987 was opened to answer.
  def run_reps(target, reps)
    (1..reps).map do |rep|
      warn "Benchmarking: rigor check #{target} (rep #{rep}/#{reps}, fresh process)"
      sample = measure_in_fresh_process(target)
      warn format("  rep %d: wall_s=%s allocations=%s peak_rss_kb=%s",
                  rep, sample["wall_s"], sample["allocations"], sample["peak_rss_kb"].inspect)
      sample
    end
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

  # The notice text, or nil when the metric is not the deterministic one or the drop is inside `stale_pct`.
  # `headroom` is what actually matters to a reader: how far the current cost could grow before the unrefreshed
  # band notices.
  def staleness_notice(target, metric, now_value, base_value, pct, limit, stale_pct)
    return nil unless metric == STALENESS_METRIC
    return nil unless now_value < base_value * (1 - (stale_pct / 100.0))

    drop = ((1 - (now_value.to_f / base_value)) * 100).round(1)
    headroom = (((limit / now_value.to_f) - 1) * 100).round
    "STALE #{target} #{metric}: #{now_value} is #{drop}% below baseline #{base_value}; " \
      "the +#{pct}% band still permits #{limit.round} (+#{headroom}% over the real cost)"
  end

  def parse_options(argv)
    options = {
      targets: [],
      baseline: File.join(ROOT, "bench", "baseline.json"),
      thresholds: File.join(ROOT, "bench", "thresholds.yml"),
      write: nil,
      reps: DEFAULT_REPS,
      measure: nil
    }
    OptionParser.new do |o|
      o.on("--target PATH") { |v| options[:targets] << v }
      o.on("--baseline PATH") { |v| options[:baseline] = v }
      o.on("--thresholds PATH") { |v| options[:thresholds] = v }
      o.on("--write-baseline PATH") { |v| options[:write] = v }
      o.on("--reps N", Integer) { |v| options[:reps] = v }
      o.on("--measure PATH") { |v| options[:measure] = v }
    end.parse!(argv)
    options[:targets] = ["lib"] if options[:targets].empty?
    raise ArgumentError, "--reps must be >= 1" if options[:reps] < 1
    options
  end

  def main(argv)
    options =
      begin
        parse_options(argv)
      rescue ArgumentError => e
        abort(e.message)
      end

    # Child mode: one rep, one JSON object on stdout, no gating. Nothing else may be printed to stdout here.
    if options[:measure]
      puts JSON.generate(measure(options[:measure]))
      exit 0
    end

    results = {}
    options[:targets].each { |target| results[target] = reduce_samples(run_reps(target, options[:reps])) }

    gate(results, options)
  end

  def gate(results, options)
    baseline =
      begin
        JSON.parse(File.read(options[:baseline], encoding: "UTF-8"))
      rescue StandardError
        { "calibrated" => false }
      end
    band = load_thresholds(options[:thresholds])

    # The suggestion sibling is written on EVERY run, not only an uncalibrated one. `bench/baseline.json`'s own
    # refresh instructions say to trigger release-gate.yml and commit the uploaded artifact's targets — and that
    # produced nothing whenever the baseline was calibrated, i.e. in the only state a refresh is ever wanted, with
    # the workflow's `if-no-files-found: ignore` swallowing the gap. Writing it unconditionally is what makes the
    # documented procedure work; the file is gitignored, so a local run still never touches the committed baseline.
    suggested = {
      "calibrated" => true,
      "calibrated_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
      "reps" => options[:reps],
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
  end
end

Bench.main(ARGV) if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
