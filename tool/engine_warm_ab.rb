#!/usr/bin/env ruby
# frozen_string_literal: true

# Warm-cache journeys (#1507): how long `rigor check` takes to answer on a real project when the cache is already
# warm, in the three cases an editor or a developer loop meets:
#
#   null  — nothing changed since the last run;
#   leaf  — one file nothing else depends on was edited (a script, a controller);
#   hub   — one file many others depend on was edited (a base model, a shared module).
#
# Each is measured for the default `rigor check` (the ADR-45 run-result cache) and for `rigor check --incremental`
# (ADR-46), since the two take different paths. Every run is a fresh process through the engine's own `exe/rigor`,
# which loads the `lib` beside it, so the numbers include boot, as a user's do.
#
# Protocol, per mode and engine: clear the project's cache and prime it with one cold run (recorded, and kept as
# the reference output); time `--reps` null runs; then for the leaf and the hub, `--reps` times, edit the file, time
# one run, restore the file, and run once more untimed to put the cache back. On the first repetition of each
# scenario the timed run's output is compared with a `--no-cache` run over the same tree, so a warm answer that
# differs from the cold one fails the tool instead of reading as a speed-up.
#
# An edit is `method` (a new empty method inserted before the file's last top-level `end`, which changes the
# class's declarations, the edit that widens an incremental closure) or `comment` (a comment line appended, which
# changes the file's bytes and nothing else).
#
# With `--base`, the two engines each get their own copy of the project, so their caches never meet, and every
# timed step alternates between them in ABBA order. The verdict per row is `tool/engine_wall_ab.rb`'s: medians,
# ranges, and separation beyond chance with the bar divided across the rows.
#
# Usage:
#   ruby tool/engine_warm_ab.rb --project DIR --leaf PATH --hub PATH --head REV|WORKTREE [--base REV]
#                               [--paths "app lib"] [--modes default,incremental] [--edit method|comment]
#                               [--reps N] [--no-verify] [--summary FILE] [--json FILE]

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "tmpdir"
require_relative "engine_alloc_ab"
require_relative "engine_wall_ab"

module EngineWarmAB
  MODES = %w[default incremental].freeze
  EDITS = %w[method comment].freeze
  SCENARIOS = %w[null leaf hub].freeze

  module_function

  # One `rigor check` in a fresh process. Aborts unless it completed (exit 0 or 1) with parseable JSON.
  def check(engine_dir, project, mode, paths, cache: true)
    args = ["check", "--no-stats", "--format", "json"]
    args << "--incremental" if mode == "incremental"
    args << "--no-cache" unless cache
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, status = Open3.capture3(RbConfig.ruby, File.join(engine_dir, "exe", "rigor"), *args, *paths,
                                      chdir: project)
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    diagnostics = EngineAllocAB.diagnostic_count(out)
    unless EngineAllocAB::COMPLETED_EXITS.include?(status.exitstatus) && diagnostics
      abort("rigor check #{args.join(' ')} exited #{status.inspect} in #{project}:\n#{err[-2000..] || err}")
    end
    { "wall_s" => wall.round(3), "diagnostics" => diagnostics, "digest" => Digest::SHA256.hexdigest(out),
      "set_digest" => set_digest(out) }
  end

  # The output with its diagnostics in a canonical order: what two runs must agree on even where they emit the
  # same findings in a different order (`--incremental` does, against a full run).
  def set_digest(json)
    parsed = JSON.parse(json)
    parsed["diagnostics"] = parsed.fetch("diagnostics").sort_by { |d| JSON.generate(d) }
    Digest::SHA256.hexdigest(JSON.generate(parsed))
  end

  # The file's text with the probe edit `n` applied.
  def edited(text, kind, n)
    return "#{text.chomp}\n# rigor-warm-probe #{n}\n" if kind == "comment"

    lines = text.lines
    last_end = lines.rindex { |line| line.match?(/\Aend\b/) }
    abort("no top-level `end` to insert the probe method before") unless last_end
    lines.insert(last_end, "  def __rigor_warm_probe_#{n}; end\n")
    lines.join
  end

  def clear_cache(project)
    FileUtils.rm_rf(File.join(project, ".rigor", "cache"))
  end

  class Journey
    attr_reader :samples, :cold, :failures, :notes

    def initialize(arms, options)
      @arms = arms # { name => { engine:, project: } }
      @options = options
      @samples = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } } # [mode, scenario] => arm => walls
      @cold = {}
      @failures = []
      @notes = []
    end

    def run
      @options.fetch(:modes).each do |mode|
        references = prime(mode)
        null_runs(mode, references)
        { "leaf" => @options.fetch(:leaf), "hub" => @options.fetch(:hub) }.each do |scenario, file|
          edit_runs(mode, scenario, file)
        end
      end
      self
    end

    private

    def order(rep) = rep.odd? ? @arms.keys : @arms.keys.reverse

    def paths = @options.fetch(:paths)

    def prime(mode)
      @arms.to_h do |name, arm|
        EngineWarmAB.clear_cache(arm[:project])
        result = EngineWarmAB.check(arm[:engine], arm[:project], mode, paths)
        @cold[[mode, name]] = result["wall_s"]
        warn format("%-11s %-4s prime  %.2fs", mode, name, result["wall_s"])
        [name, result]
      end
    end

    def null_runs(mode, references)
      (1..@options.fetch(:reps)).each do |rep|
        order(rep).each do |name|
          arm = @arms.fetch(name)
          result = timed(mode, "null", name, arm)
          next unless rep == 1

          compare(result, references.fetch(name), "#{name} #{mode} null", "the cold run that primed it")
        end
      end
    end

    def edit_runs(mode, scenario, file)
      (1..@options.fetch(:reps)).each do |rep|
        order(rep).each do |name|
          arm = @arms.fetch(name)
          path = File.join(arm[:project], file)
          original = File.read(path)
          File.write(path, EngineWarmAB.edited(original, @options.fetch(:edit), rep))
          begin
            result = timed(mode, scenario, name, arm)
            verify(mode, scenario, name, arm, result) if rep == 1 && @options.fetch(:verify)
          ensure
            File.write(path, original)
          end
          EngineWarmAB.check(arm[:engine], arm[:project], mode, paths)
        end
      end
    end

    def timed(mode, scenario, name, arm)
      result = EngineWarmAB.check(arm[:engine], arm[:project], mode, paths)
      @samples[[mode, scenario]][name] << result["wall_s"]
      warn format("%-11s %-4s %-5s %.2fs", mode, name, scenario, result["wall_s"])
      result
    end

    def verify(mode, scenario, name, arm, result)
      cold = EngineWarmAB.check(arm[:engine], arm[:project], mode, paths, cache: false)
      compare(result, cold, "#{name} #{mode} #{scenario}", "a --no-cache run of the same tree")
    end

    # Different findings fail the tool; the same findings in another order are recorded as a note.
    def compare(warm, cold, label, against)
      if warm["set_digest"] != cold["set_digest"]
        @failures << "#{label}: the warm diagnostics differ from #{against}"
      elsif warm["digest"] != cold["digest"]
        @notes << "#{label}: the same diagnostics as #{against}, in a different order"
      end
    end
  end

  def run(options)
    Dir.mktmpdir("rigor-warm-ab") do |scratch|
      tmp = File.realpath(scratch)
      arms = arm_dirs(options, tmp)
      journey = Journey.new(arms, options).run
      report(options, arms.keys, journey)
      return journey.failures.empty? ? 0 : 1
    end
  end

  def arm_dirs(options, tmp)
    names = options[:base] ? %w[base head] : %w[head]
    names.to_h do |name|
      engine = File.join(tmp, "engine-#{name}")
      EngineAllocAB.materialise(options.fetch(name.to_sym), engine, EngineAllocAB::ENGINE_PATHS + ["exe"])
      project = File.join(tmp, "project-#{name}")
      FileUtils.cp_r(File.join(options.fetch(:project), "."), project)
      [name, { engine: engine, project: project }]
    end
  end

  def report(options, arm_names, journey)
    rows = journey.samples.keys
    bar_rows = [rows.size, 1].max
    stats = rows.to_h do |row|
      by_arm = journey.samples.fetch(row)
      next [row, nil] unless arm_names.size == 2

      [row, EngineWallAB.metric_stats(by_arm.fetch("base"), by_arm.fetch("head"),
                                      EngineWallAB::SEPARATION_ALPHA / bar_rows)]
    end
    result = { "options" => options.except(:summary, :json), "cold_s" => journey.cold.transform_keys(&:join),
               "samples" => journey.samples.transform_keys { |k| k.join(" ") }, "failures" => journey.failures,
               "notes" => journey.notes,
               "stats" => stats.transform_keys { |k| k.join(" ") } }
    File.write(options[:json], JSON.pretty_generate(result)) if options[:json]
    EngineAllocAB.emit(summary(options, arm_names, journey, stats), options[:summary])
  end

  def summary(options, arm_names, journey, stats)
    lines = ["### Warm journeys (#1507)", "",
             "`rigor check` on `#{options[:project_label] || options[:project]}` (paths: " \
             "#{options[:paths].empty? ? 'from the config' : options[:paths].join(' ')}), leaf `#{options[:leaf]}`, " \
             "hub `#{options[:hub]}`, `#{options[:edit]}` edits, #{options[:reps]} runs per step" \
             "#{arm_names.size == 2 ? ' in ABBA order' : ''}. Wall seconds per fresh-process run, boot included.", ""]
    lines.concat(table(arm_names, journey, stats))
    lines << "" << "Cold priming runs: " + journey.cold.map { |(mode, arm), s| "#{arm} #{mode} #{s}s" }.join(", ")
    lines << "" << journey.notes.join("\n") unless journey.notes.empty?
    lines << "" << journey.failures.map { |f| "**#{f}**" }.join("\n") unless journey.failures.empty?
    lines.join("\n")
  end

  def table(arm_names, journey, stats)
    if arm_names.size == 1
      rows = ["| mode | scenario | median (min–max) |", "| --- | --- | ---: |"]
      journey.samples.each { |(mode, scenario), by_arm| rows << "| #{mode} | #{scenario} | #{cell(by_arm['head'])} |" }
      return rows
    end
    rows = ["| mode | scenario | base median (min–max) | head median (min–max) | Δ median | ranges separate |",
            "| --- | --- | ---: | ---: | ---: | --- |"]
    journey.samples.each do |(mode, scenario), by_arm|
      s = stats.fetch([mode, scenario])
      rows << "| #{mode} | #{scenario} | #{cell(by_arm['base'])} | #{cell(by_arm['head'])} | " \
              "#{EngineWallAB.change_cell(s['median_pct'])} | #{EngineWallAB.verdict_cell(s)} |"
    end
    rows
  end

  def cell(values)
    "#{EngineWallAB.median(values).round(2)} (#{values.min.round(2)}–#{values.max.round(2)})"
  end
end

if $PROGRAM_NAME == __FILE__
  options = { paths: [], modes: EngineWarmAB::MODES, edit: "method", reps: 3, verify: true }
  OptionParser.new do |parser|
    parser.on("--project DIR") { |v| options[:project] = File.realpath(v) }
    parser.on("--project-label TEXT") { |v| options[:project_label] = v }
    parser.on("--leaf PATH") { |v| options[:leaf] = v }
    parser.on("--hub PATH") { |v| options[:hub] = v }
    parser.on("--base REV") { |v| options[:base] = v }
    parser.on("--head REV") { |v| options[:head] = v }
    parser.on("--paths LIST") { |v| options[:paths] = v.split }
    parser.on("--modes LIST") { |v| options[:modes] = v.split(",") }
    parser.on("--edit KIND", EngineWarmAB::EDITS) { |v| options[:edit] = v }
    parser.on("--reps N", Integer) { |v| options[:reps] = v }
    parser.on("--no-verify") { options[:verify] = false }
    parser.on("--summary PATH") { |v| options[:summary] = v }
    parser.on("--json PATH") { |v| options[:json] = v }
  end.parse!
  abort("--project, --leaf, --hub and --head are required") unless options.values_at(:project, :leaf, :hub, :head).all?
  abort("--base must name a revision") if options[:base] == EngineAllocAB::WORKTREE
  abort("unknown mode in --modes") unless (options[:modes] - EngineWarmAB::MODES).empty?
  %i[leaf hub].each do |key|
    abort("#{key} #{options[key]} is not a file in the project") unless File.file?(File.join(options[:project], options[key]))
  end
  exit EngineWarmAB.run(options)
end
