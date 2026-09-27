#!/usr/bin/env ruby
# frozen_string_literal: true

# Engine wall and CPU A/B (#1507): the wall half of the campaign's measurement decision, for CI Linux.
#
# Allocations are deterministic, so `tool/engine_alloc_ab.rb` runs each engine once. Wall and CPU time are not: a
# shared host adds time to whichever run it disturbs, and a phased A/B (every base run, then every head run)
# confounds the phase with the treatment (`docs/agents/measurement.md`). So this runs the two engines `--reps` times
# each over one frozen corpus, alternating in ABBA order so a drift in the host charges both arms alike, every run
# a fresh process. It reuses `tool/engine_alloc_ab.rb`'s engine arms, corpus and child, so the load-path proof and
# the failure rules are the same.
#
# Per run: wall, process CPU (user + system, every thread), GC time, and allocations. Allocations are a check that
# both arms did the same work each time, not a result. With `--perf`, `perf stat` also counts user-space
# instructions (`instructions:u`), where the host exposes the counter.
#
# YJIT. Rigor enables YJIT after a wall-clock deadline (`lib/rigor/runtime/jit.rb`), so how much of a run is
# JIT-compiled moves with host load. `--yjit default` keeps the shipped behaviour, which is what a user waits
# for. `immediate` (`RIGOR_YJIT_DEADLINE=0`) and `off` (`RIGOR_DISABLE_YJIT=1`) take wall time out of that
# decision, which is what makes instruction counts comparable between runs.
#
# The report gives each arm's median, min and max per metric and the change in the median, and says whether the
# two arms' ranges separate. Separation under alternation is evidence; a median shift inside overlapping ranges
# is not.
#
# Usage:
#   ruby tool/engine_wall_ab.rb --base REV --head REV|WORKTREE [--corpus REV] [--target PATH] [--reps N]
#                               [--yjit default|immediate|off] [--perf] [--summary FILE] [--json FILE]

require "json"
require "optparse"
require "tmpdir"
require_relative "engine_alloc_ab"

module EngineWallAB
  METRICS = %w[wall_s cpu_s gc_ms instructions].freeze
  YJIT_ENV = {
    "default" => {},
    "immediate" => { "RIGOR_YJIT_DEADLINE" => "0" },
    "off" => { "RIGOR_DISABLE_YJIT" => "1" }
  }.freeze

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

  # Per-metric statistics for two arms' samples. Pure, so the spec drives it without running an engine.
  def stats(samples_by_arm)
    METRICS.filter_map do |metric|
      values = samples_by_arm.transform_values { |samples| samples.filter_map { |s| s[metric] } }
      next if values.values.any?(&:empty?) || median(values[:base]).zero?

      base, head = values.values_at(:base, :head)
      change = 100.0 * (median(head) - median(base)) / median(base)
      [metric, { "base" => summarize(base), "head" => summarize(head), "median_pct" => change.round(2),
                 "separated" => base.max < head.min || head.max < base.min }]
    end.to_h
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

  def perf_available?
    system("perf", "stat", "-x,", "-e", "instructions:u", "true", out: File::NULL, err: File::NULL)
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
    warn "perf stat is unavailable here; instructions are not counted." if options[:perf] && !perf
    samples = { base: [], head: [] }
    Dir.mktmpdir("rigor-wall-ab") do |scratch|
      tmp = File.realpath(scratch)
      corpus = File.join(tmp, "corpus")
      EngineAllocAB.materialise(revs[:corpus], corpus)
      dirs = { base: File.join(tmp, "base"), head: File.join(tmp, "head") }
      dirs.each { |arm, dir| EngineAllocAB.materialise(revs[arm], dir, EngineAllocAB::ENGINE_PATHS) }
      schedule(options.fetch(:reps)).each_with_index do |arm, i|
        perf_file = perf ? File.join(tmp, "perf-#{i}.txt") : nil
        sample = run_one(dirs.fetch(arm), corpus, revs[:target], options.fetch(:yjit), perf_file)
        warn format("run %d %-4s wall=%.2fs cpu=%.2fs allocations=%d", i + 1, arm, sample["wall_s"],
                    sample["cpu_s"], sample["allocations"])
        samples[arm] << sample
      end
    end
    report(revs, options, samples)
    0
  end

  def report(revs, options, samples)
    result = { "revisions" => revs, "reps" => options[:reps], "yjit" => options[:yjit],
               "stats" => stats(samples), "samples" => samples }
    File.write(options[:json], JSON.pretty_generate(result)) if options[:json]
    EngineAllocAB.emit(summary(revs, options, samples, result["stats"]), options[:summary])
  end

  def summary(revs, options, samples, stats)
    lines = ["### Engine wall A/B (#1507)", "",
             "`rigor check --no-cache #{revs[:target]}` over the corpus at `#{revs[:corpus]}`: base `#{revs[:base]}`, " \
             "head `#{revs[:head]}`, #{options[:reps]} runs each in ABBA order, YJIT `#{options[:yjit]}`.", "",
             "| metric | base median (min–max) | head median (min–max) | Δ median | ranges separate |",
             "| --- | ---: | ---: | ---: | --- |"]
    stats.each do |metric, s|
      lines << "| #{metric} | #{cell(s['base'])} | #{cell(s['head'])} | " \
               "#{EngineAllocAB.signed_pct(s['median_pct'])}% | #{s['separated'] ? 'yes' : 'no'} |"
    end
    lines.concat(consistency_notes(samples))
    lines.join("\n")
  end

  def cell(summary)
    "#{summary['median']} (#{summary['min']}–#{summary['max']})"
  end

  # Each arm must do the same work every run; a spread in allocations or diagnostics means it did not.
  def consistency_notes(samples)
    samples.flat_map do |arm, runs|
      allocations = runs.map { |run| run["allocations"] }
      notes = ["", "#{arm}: allocations #{EngineAllocAB.delimit(allocations.min)}–" \
                   "#{EngineAllocAB.delimit(allocations.max)} across runs, YJIT on in " \
                   "#{runs.count { |run| run['yjit'] }}/#{runs.size}."]
      notes << "**#{arm}: the diagnostics differ between runs.**" if runs.map { |run| run["output_digest"] }.uniq.size > 1
      notes
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { target: "lib", reps: 5, yjit: "default" }
  OptionParser.new do |parser|
    parser.on("--base REV") { |v| options[:base] = v }
    parser.on("--head REV") { |v| options[:head] = v }
    parser.on("--corpus REV") { |v| options[:corpus] = v }
    parser.on("--target PATH") { |v| options[:target] = v }
    parser.on("--reps N", Integer) { |v| options[:reps] = v }
    parser.on("--yjit MODE", EngineWallAB::YJIT_ENV.keys) { |v| options[:yjit] = v }
    parser.on("--perf") { options[:perf] = true }
    parser.on("--summary PATH") { |v| options[:summary] = v }
    parser.on("--json PATH") { |v| options[:json] = v }
  end.parse!
  abort("--base and --head are required") unless options[:base] && options[:head]
  abort("--reps must be at least 2") if options[:reps] < 2
  abort("--base and --corpus must name revisions; the working tree is only a head engine") if
    [options[:base], options[:corpus]].include?(EngineAllocAB::WORKTREE)
  exit EngineWallAB.run(options)
end
