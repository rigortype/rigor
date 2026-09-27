#!/usr/bin/env ruby
# frozen_string_literal: true

# Engine wall and CPU A/B (#1507): the wall half of the campaign's measurement decision, for CI Linux.
#
# Allocations are deterministic, so `tool/engine_alloc_ab.rb` runs each engine once. Wall and CPU time are not: a
# shared host adds time to whichever run it disturbs, and a phased A/B (every base run, then every head run)
# confounds the phase with the treatment (`docs/agents/measurement.md`). So this runs the two engines `--reps` times
# each over one frozen corpus, alternating in ABBA order so a drift in the host charges both arms alike, every run
# a fresh process, after one discarded warm-up run of each arm. It reuses `tool/engine_alloc_ab.rb`'s engine arms,
# corpus and child, so the load-path proof and the failure rules are the same.
#
# Per run: wall, process CPU (user + system, every thread) and GC time, all over the `rigor check` call alone, and
# allocations, which check that each arm did the same work every run. With `--perf`, `perf stat` also counts
# user-space instructions (`instructions:u`) where the host exposes the counter. That count covers the whole child
# process, boot and engine load included, so it moves less than the others for the same change.
#
# YJIT. Rigor enables YJIT after a wall-clock deadline (`lib/rigor/runtime/jit.rb`), so how much of a run is
# JIT-compiled moves with host load. `--yjit default` keeps the shipped behaviour, which is what a user waits for.
# `on` (`RUBY_YJIT_ENABLE=1`, from the first instruction) and `off` (`RIGOR_DISABLE_YJIT=1`) take wall time out of
# that decision. When the arms end with YJIT in different states, the report says the comparison measured YJIT.
#
# The verdict. Each metric row gives both arms' median, min and max, and the change in the median. It also says
# whether the two arms' ranges separate (a tie does not). Separation alone is weak evidence at few runs: two arms
# drawn from one distribution separate with probability 2 / C(n + m, n), a third of the time at two runs each. So
# the row states that probability, and says "yes" only when it is at most {SEPARATION_ALPHA}. That takes at least
# four runs per arm; five is the default. The rows are correlated, so one "yes" among them is still one piece of
# evidence, not several.
#
# Usage:
#   ruby tool/engine_wall_ab.rb --base REV --head REV|WORKTREE [--corpus REV] [--target PATH] [--reps N]
#                               [--yjit default|on|off] [--perf] [--summary FILE] [--json FILE]

require "json"
require "open3"
require "optparse"
require "tmpdir"
require_relative "engine_alloc_ab"

module EngineWallAB
  METRICS = %w[wall_s cpu_s gc_ms instructions].freeze
  YJIT_ENV = {
    "default" => {},
    "on" => { "RUBY_YJIT_ENABLE" => "1" },
    "off" => { "RIGOR_DISABLE_YJIT" => "1" }
  }.freeze
  SEPARATION_ALPHA = 0.05
  DEFAULT_REPS = 5

  module_function

  # ABBA over `reps` rounds: rep 1 runs base then head, rep 2 head then base, and so on.
  def schedule(reps)
    (1..reps).flat_map { |rep| rep.odd? ? %i[base head] : %i[head base] }
  end

  def median(values)
    sorted = values.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  # The chance that `n` and `m` samples of ONE distribution land with their ranges apart: of the C(n + m, n)
  # equally likely orderings, exactly two put one arm wholly below the other.
  def separation_null_probability(n, m)
    2.0 / (1..n).reduce(1) { |acc, k| acc * (m + k) / k }
  end

  # Per-metric statistics for two arms' samples. Pure, so the spec drives it without running an engine. A metric
  # no run recorded is left out, and one whose base median is zero is listed as unusable rather than dropped.
  def stats(samples_by_arm)
    METRICS.filter_map do |metric|
      values = samples_by_arm.transform_values { |samples| samples.filter_map { |s| s[metric] } }
      next if values.values.any?(&:empty?)

      [metric, metric_stats(values.fetch(:base), values.fetch(:head))]
    end.to_h
  end

  def metric_stats(base, head)
    apart = base.max < head.min || head.max < base.min
    null = separation_null_probability(base.size, head.size)
    change = median(base).zero? ? nil : (100.0 * (median(head) - median(base)) / median(base)).round(2)
    { "base" => summarize(base), "head" => summarize(head), "median_pct" => change, "apart" => apart,
      "null_probability" => null.round(4), "separated" => apart && null <= SEPARATION_ALPHA }
  end

  def summarize(values)
    { "median" => median(values).round(3), "min" => values.min.round(3), "max" => values.max.round(3) }
  end

  # `instructions:u` from `perf stat -x,` output, or nil when the counter is not supported here.
  def parse_perf(text)
    text.each_line do |line|
      value, _unit, event = line.split(",")
      next unless event&.start_with?("instructions")

      return Integer(value, exception: false)
    end
    nil
  end

  # `perf stat` exits 0 on a VM without the hardware counter and prints `<not supported>`, so the count itself
  # is the test.
  def perf_available?
    _, err, status = Open3.capture3("perf", "stat", "-x,", "-e", "instructions:u", "true")
    status.success? && !parse_perf(err).nil?
  rescue SystemCallError
    false
  end

  def run_one(dir, corpus, target, yjit, perf_file)
    prefix = perf_file ? ["perf", "stat", "-x,", "-e", "instructions:u", "-o", perf_file, "--"] : []
    sample = EngineAllocAB.run_child(dir, corpus, target, env: YJIT_ENV.fetch(yjit), prefix: prefix)
    sample["instructions"] = parse_perf(File.read(perf_file)) if perf_file
    sample
  end

  def run(options)
    revs = { base: options.fetch(:base), head: options.fetch(:head), target: options.fetch(:target) }
    revs[:corpus] = options[:corpus] || revs[:base]
    perf = options[:perf] && perf_available?
    samples = { base: [], head: [] }
    Dir.mktmpdir("rigor-wall-ab") do |scratch|
      tmp = File.realpath(scratch)
      corpus = File.join(tmp, "corpus")
      EngineAllocAB.materialise(revs[:corpus], corpus)
      dirs = { base: File.join(tmp, "base"), head: File.join(tmp, "head") }
      dirs.each { |arm, dir| EngineAllocAB.materialise(revs[arm], dir, EngineAllocAB::ENGINE_PATHS) }
      # Discarded: the first runs after unpacking pay for a cold page cache and a cold host.
      %i[base head].each { |arm| run_one(dirs.fetch(arm), corpus, revs[:target], options.fetch(:yjit), nil) }
      schedule(options.fetch(:reps)).each_with_index do |arm, i|
        perf_file = perf ? File.join(tmp, "perf-#{i}.txt") : nil
        sample = run_one(dirs.fetch(arm), corpus, revs[:target], options.fetch(:yjit), perf_file)
        warn format("run %d %-4s wall=%.2fs cpu=%.2fs allocations=%d yjit=%p", i + 1, arm, sample["wall_s"],
                    sample["cpu_s"], sample["allocations"], sample["yjit"])
        samples[arm] << sample
      end
    end
    report(revs, options.merge(perf_used: perf), samples)
    0
  end

  def report(revs, options, samples)
    result = { "revisions" => revs, "labels" => options[:labels], "reps" => options[:reps], "yjit" => options[:yjit],
               "stats" => stats(samples), "samples" => samples }
    File.write(options[:json], JSON.pretty_generate(result)) if options[:json]
    EngineAllocAB.emit(summary(revs, options, samples, result["stats"]), options[:summary])
  end

  def summary(revs, options, samples, stats)
    lines = ["### Engine wall A/B (#1507)", "", intro(revs, options), "",
             "| metric | base median (min–max) | head median (min–max) | Δ median | ranges separate |",
             "| --- | ---: | ---: | ---: | --- |"]
    stats.each do |metric, s|
      lines << "| #{metric} | #{cell(s['base'])} | #{cell(s['head'])} | #{change_cell(s['median_pct'])} | " \
               "#{verdict_cell(s)} |"
    end
    lines << "" << "`--perf` was requested, but this host does not expose `instructions:u`." if
      options[:perf] && !options[:perf_used]
    lines.concat(consistency_notes(samples))
    lines.join("\n")
  end

  def intro(revs, options)
    labels = options[:labels] ? " (#{options[:labels]})" : ""
    "`rigor check --no-cache #{revs[:target]}` over the corpus at `#{revs[:corpus]}`: base `#{revs[:base]}`, " \
      "head `#{revs[:head]}`#{labels}, #{options[:reps]} runs each in ABBA order after a discarded warm-up, " \
      "YJIT `#{options[:yjit]}`."
  end

  def cell(summary)
    "#{summary['median']} (#{summary['min']}–#{summary['max']})"
  end

  def change_cell(pct)
    pct.nil? ? "n/a (base median 0)" : "#{EngineAllocAB.signed_pct(pct)}%"
  end

  def verdict_cell(stats)
    chance = format("%.1f%%", 100 * stats["null_probability"])
    return "yes (by chance #{chance})" if stats["separated"]
    return "no" unless stats["apart"]

    "undecided: apart, but #{chance} by chance at this run count"
  end

  # Each arm must do the same work every run, in the same YJIT state as the other arm; either failing makes the
  # rows measure something else.
  def consistency_notes(samples)
    notes = samples.flat_map do |arm, runs|
      allocations = runs.map { |run| run["allocations"] }
      line = ["", "#{arm}: allocations #{EngineAllocAB.delimit(allocations.min)}–" \
                  "#{EngineAllocAB.delimit(allocations.max)} across runs, YJIT on in " \
                  "#{runs.count { |run| run['yjit'] }}/#{runs.size}."]
      line << "**#{arm}: the diagnostics differ between runs.**" if runs.map { |run| run["output_digest"] }.uniq.size > 1
      line
    end
    notes.concat(["", yjit_warning]) if yjit_mixed?(samples)
    notes
  end

  def yjit_mixed?(samples)
    samples.values.flat_map { |runs| runs.map { |run| run["yjit"] } }.uniq.size > 1
  end

  def yjit_warning
    "**YJIT ended in different states across the runs, so the rows compare YJIT as much as the engines. " \
      "Rerun with `--yjit on` or `--yjit off`.**"
  end
end

if $PROGRAM_NAME == __FILE__
  options = { target: "lib", reps: EngineWallAB::DEFAULT_REPS, yjit: "default" }
  OptionParser.new do |parser|
    parser.on("--base REV") { |v| options[:base] = v }
    parser.on("--head REV") { |v| options[:head] = v }
    parser.on("--corpus REV") { |v| options[:corpus] = v }
    parser.on("--target PATH") { |v| options[:target] = v }
    parser.on("--reps N", Integer) { |v| options[:reps] = v }
    parser.on("--yjit MODE", EngineWallAB::YJIT_ENV.keys) { |v| options[:yjit] = v }
    parser.on("--perf") { options[:perf] = true }
    parser.on("--labels TEXT", "How the revisions were named, for the report") { |v| options[:labels] = v }
    parser.on("--summary PATH") { |v| options[:summary] = v }
    parser.on("--json PATH") { |v| options[:json] = v }
  end.parse!
  abort("--base and --head are required") unless options[:base] && options[:head]
  abort("--reps must be at least 2") if options[:reps] < 2
  abort("--base and --corpus must name revisions; the working tree is only a head engine") if
    [options[:base], options[:corpus]].include?(EngineAllocAB::WORKTREE)
  exit EngineWallAB.run(options)
end
