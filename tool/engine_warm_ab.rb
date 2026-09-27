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
# which loads the `lib` beside it. The processes run under this checkout's `bundle exec` environment, whose
# `-rbundler/setup` adds about 50 ms of boot that a gem-installed user does not pay.
#
# Protocol, per mode and engine: remove the project's `.rigor` directory and prime the cache with one cold run
# (recorded); time `--reps` null runs; then for the leaf and the hub, `--reps` times, edit the file, time one run,
# restore it, and run once more untimed to put the cache back.
#
# Every timed run is checked for being the run it is labelled as, from a marker the child process writes at exit
# (`-r` on RUBYOPT; no engine change):
#   - a default-mode null run must be served without loading the engine (the ADR-87 probe hit);
#   - a default-mode edit run must load it (a miss);
#   - every `--incremental` run must report itself `warm`.
# The same marker proves no Rigor file loaded from this checkout instead of the engine, and records whether YJIT
# was on.
#
# Correctness: the first timed run of each scenario is compared with a plain `rigor check --no-cache` of the same
# tree, which reads and writes neither the result cache nor the incremental snapshot. (`--incremental --no-cache`
# is not a cold run: it still replays the snapshot.) Different findings fail the tool; the same findings in
# another order are a note. Every run passes `--no-baseline`, so a project baseline does not hide findings from the
# comparison. For `--incremental` edits, the edit is also replayed once untimed under `--verify-incremental`, which
# reports how many files the recheck re-analysed (the closure the leaf and hub rows are about) and checks the
# incremental answer against a full run in the engine itself.
#
# An edit is `method` (an empty method inserted before the `end` that closes the file's last `class` or `module`
# header) or `comment`
# (a comment line appended). Under rbs-inline comment ingestion, which is on whenever the gem resolves, a comment
# edit widens an incremental closure as far as a method edit does, so the recorded closure is what tells a hub from
# a leaf.
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
  CONFIG_FILES = %w[.rigor.yml .rigor.dist.yml].freeze

  # Loaded into every child with `-r`: at exit it records whether the inference engine was loaded (the ADR-87 probe
  # serves a hit without `Inference::ExpressionTyper`: about 260 features against 750 on a miss), whether YJIT
  # was on, and any Rigor file loaded from this checkout's `lib` or `plugins` rather than the engine's.
  MARKER = <<~'MARKER_RUBY'
    at_exit do
      path = ENV["RIGOR_WARM_MARKER"]
      if path
        root = ENV.fetch("RIGOR_WARM_CHECKOUT")
        foreign = $LOADED_FEATURES.select do |f|
          (f.start_with?("#{root}/lib/") || f.start_with?("#{root}/plugins/")) && !f.end_with?("/lib/rigor/version.rb")
        end
        yjit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 1 : 0
        File.write(path, "engine=#{defined?(Rigor::Inference::ExpressionTyper) ? 1 : 0} yjit=#{yjit} foreign=#{foreign.first(3).join(',')}")
      end
    end
  MARKER_RUBY

  module_function

  # One `rigor check` in a fresh process. Aborts unless it completed (exit 0 or 1) with parseable JSON (or, for
  # `--verify-incremental`, which prints only its verdict, exit 0 or 1) and loaded nothing from this checkout.
  def check(engine_dir, project, extra_args, paths, scratch:)
    json = !extra_args.include?("--verify-incremental")
    args = ["check", "--no-stats", "--no-baseline", "--format", "json", *extra_args]
    marker = File.join(scratch, "marker.txt")
    FileUtils.rm_f(marker)
    env = { "RUBYOPT" => "#{ENV.fetch('RUBYOPT', '')} -r#{File.join(scratch, 'marker.rb')}".strip,
            "RIGOR_WARM_MARKER" => marker, "RIGOR_WARM_CHECKOUT" => EngineAllocAB::ROOT }
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(engine_dir, "exe", "rigor"), *args, *paths,
                                      chdir: project)
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    diagnostics = json ? EngineAllocAB.diagnostic_count(out) : 0
    unless EngineAllocAB::COMPLETED_EXITS.include?(status.exitstatus) && diagnostics
      abort("rigor #{args.join(' ')} exited #{status.inspect} in #{project}:\n#{err[-2000..] || err}")
    end
    marks = parse_marker(File.exist?(marker) ? File.read(marker) : "")
    abort("rigor loaded #{marks['foreign']} from the checkout instead of #{engine_dir}") unless marks["foreign"].empty?
    { "wall_s" => wall.round(3), "diagnostics" => diagnostics, "digest" => Digest::SHA256.hexdigest(out),
      "set_digest" => json ? set_digest(out) : nil, "engine_loaded" => marks["engine"] == "1", "yjit" => marks["yjit"] == "1",
      "incremental" => err[/--incremental (warm|cold)/, 1], "recheck" => recheck_size(err),
      "verify_failed" => err.include?("--verify-incremental FAILED") }
  end

  def parse_marker(text)
    text.split.to_h { |pair| pair.split("=", 2) }.then { |h| { "foreign" => "" }.merge(h.transform_values(&:to_s)) }
  end

  # `--verify-incremental`'s "(N/M files re-analyzed" line, as [N, M], or nil.
  def recheck_size(err)
    match = err.match(%r{\((\d+)/(\d+) files re-analyzed})
    match && [Integer(match[1]), Integer(match[2])]
  end

  # The output with its diagnostics in a canonical order: what two runs must agree on even where they emit the
  # same findings in a different order (`--incremental` does, against a full run: #1524).
  def set_digest(json)
    parsed = JSON.parse(json)
    parsed["diagnostics"] = parsed.fetch("diagnostics").sort_by { |d| JSON.generate(d) }
    Digest::SHA256.hexdigest(JSON.generate(parsed))
  end

  # The file's text with the probe edit `n` applied. A `method` edit goes inside the file's last `class` or
  # `module` header, before the `end` at that header's indentation, so the innermost namespace of the usual
  # `module X; class Y` layout gets it rather than the outer module.
  def edited(text, kind, n)
    return "#{text.chomp}\n# rigor-warm-probe #{n}\n" if kind == "comment"

    lines = text.lines
    class_at = lines.rindex { |line| line.match?(/\A\s*(?:class|module)\s+[A-Z]/) }
    abort("no `class` or `module` to insert the probe method into") unless class_at
    indent = lines[class_at][/\A\s*/]
    end_at = (class_at + 1...lines.size).find { |i| lines[i].match?(/\A#{Regexp.escape(indent)}end\b/) }
    abort("no `end` closing the file's last `class` or `module`") unless end_at
    lines.insert(end_at, "#{indent}  def __rigor_warm_probe_#{n}; end\n")
    lines.join
  end

  # A project whose configuration moves the cache elsewhere would keep its cache across the copy and the clear.
  def assert_default_cache(project)
    CONFIG_FILES.each do |name|
      path = File.join(project, name)
      next unless File.file?(path) && File.read(path).match?(/^cache:/)

      abort("#{name} sets `cache:`; the harness clears only the default .rigor/cache")
    end
  end

  class Journey
    attr_reader :samples, :cold, :failures, :notes, :closures, :yjit

    def initialize(arms, options, scratch)
      @arms = arms # { name => { engine:, project: } }
      @options = options
      @scratch = scratch
      @samples = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } } # [mode, scenario] => arm => walls
      @yjit = Hash.new { |h, k| h[k] = Hash.new(0) } # [mode, scenario] => arm => runs with YJIT on
      @cold = {}
      @closures = {}
      @failures = []
      @notes = []
    end

    def run
      @options.fetch(:modes).each do |mode|
        prime(mode)
        null_runs(mode)
        { "leaf" => @options.fetch(:leaf), "hub" => @options.fetch(:hub) }.each do |scenario, file|
          edit_runs(mode, scenario, file)
        end
      end
      self
    end

    private

    def order(rep) = rep.odd? ? @arms.keys : @arms.keys.reverse

    def paths = @options.fetch(:paths)

    def run_check(arm, args) = EngineWarmAB.check(arm[:engine], arm[:project], args, paths, scratch: @scratch)

    def mode_args(mode) = mode == "incremental" ? ["--incremental"] : []

    def prime(mode)
      @arms.each do |name, arm|
        FileUtils.rm_rf(File.join(arm[:project], ".rigor"))
        result = run_check(arm, mode_args(mode))
        @cold["#{mode}/#{name}"] = result["wall_s"]
        warn format("%-11s %-4s prime  %.2fs", mode, name, result["wall_s"])
      end
    end

    def null_runs(mode)
      (1..@options.fetch(:reps)).each do |rep|
        order(rep).each do |name|
          arm = @arms.fetch(name)
          result = timed(mode, "null", name, arm)
          verify(mode, "null", name, arm, result) if rep == 1 && @options.fetch(:verify)
        end
      end
    end

    def edit_runs(mode, scenario, file)
      (1..@options.fetch(:reps)).each do |rep|
        order(rep).each do |name|
          arm = @arms.fetch(name)
          with_edit(arm, file, rep) do
            result = timed(mode, scenario, name, arm)
            verify(mode, scenario, name, arm, result) if rep == 1 && @options.fetch(:verify)
          end
          run_check(arm, mode_args(mode))
          record_closure(mode, scenario, name, arm, file) if rep == 1 && mode == "incremental"
        end
      end
    end

    def with_edit(arm, file, rep)
      path = File.join(arm[:project], file)
      original = File.read(path)
      File.write(path, EngineWarmAB.edited(original, @options.fetch(:edit), rep))
      yield
    ensure
      File.write(path, original) if original
    end

    def timed(mode, scenario, name, arm)
      result = run_check(arm, mode_args(mode))
      assert_labelled(mode, scenario, name, result)
      @samples[[mode, scenario]][name] << result["wall_s"]
      @yjit[[mode, scenario]][name] += 1 if result["yjit"]
      warn format("%-11s %-4s %-5s %.2fs", mode, name, scenario, result["wall_s"])
      result
    end

    # The run must be the hit or miss its row is about; otherwise the row times something else.
    def assert_labelled(mode, scenario, name, result)
      label = "#{name} #{mode} #{scenario}"
      if mode == "incremental"
        @failures << "#{label}: the run reported `--incremental #{result['incremental'].inspect}`, not warm" unless
          result["incremental"] == "warm"
      elsif scenario == "null" && result["engine_loaded"]
        @failures << "#{label}: the null run loaded the engine, so it was not a result-cache hit"
      elsif scenario != "null" && !result["engine_loaded"]
        @failures << "#{label}: the edit run did not load the engine, so the edit was not seen"
      end
    end

    # Against a plain `--no-cache` run, which touches neither the result cache nor the incremental snapshot.
    def verify(mode, scenario, name, arm, result)
      cold = run_check(arm, ["--no-cache"])
      label = "#{name} #{mode} #{scenario}"
      if result["set_digest"] != cold["set_digest"]
        @failures << "#{label}: the warm diagnostics differ from a --no-cache run of the same tree"
      elsif result["digest"] != cold["digest"]
        @notes << "#{label}: the same diagnostics as a --no-cache run of the same tree, in a different order"
      end
    end

    # Replays the edit once untimed under `--verify-incremental`: the recheck's closure size, and the engine's own
    # incremental-versus-full check. The cache is put back afterwards.
    def record_closure(mode, scenario, name, arm, file)
      with_edit(arm, file, 1) do
        result = run_check(arm, ["--verify-incremental"])
        @closures["#{mode}/#{scenario}/#{name}"] = result["recheck"]
        @failures << "#{name} #{mode} #{scenario}: --verify-incremental reported no recheck size" unless result["recheck"]
        @failures << "#{name} #{mode} #{scenario}: --verify-incremental FAILED" if result["verify_failed"]
      end
      run_check(arm, mode_args(mode))
    end
  end

  def run(options)
    Dir.mktmpdir("rigor-warm-ab") do |scratch|
      tmp = File.realpath(scratch)
      File.write(File.join(tmp, "marker.rb"), MARKER)
      arms = arm_dirs(options, tmp)
      journey = Journey.new(arms, options, tmp)
      begin
        journey.run
      ensure
        report(options, arms.keys, journey)
      end
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
      FileUtils.rm_rf(File.join(project, ".rigor"))
      [name, { engine: engine, project: project }]
    end
  end

  def report(options, arm_names, journey)
    rows = journey.samples.keys
    stats = rows.to_h do |row|
      next [row, nil] unless arm_names.size == 2 && journey.samples.fetch(row).values.map(&:size).min.to_i.positive?

      by_arm = journey.samples.fetch(row)
      [row, EngineWallAB.metric_stats(by_arm.fetch("base"), by_arm.fetch("head"),
                                      EngineWallAB::SEPARATION_ALPHA / [rows.size, 1].max)]
    end
    result = { "options" => options.except(:summary, :json), "cold_s" => journey.cold,
               "samples" => journey.samples.transform_keys { |k| k.join("/") }, "closures" => journey.closures,
               "yjit_on" => journey.yjit.transform_keys { |k| k.join("/") }, "failures" => journey.failures,
               "notes" => journey.notes, "stats" => stats.transform_keys { |k| k.join("/") } }
    File.write(options[:json], JSON.pretty_generate(result)) if options[:json]
    EngineAllocAB.emit(summary(options, arm_names, journey, stats), options[:summary])
  end

  def summary(options, arm_names, journey, stats)
    revs = arm_names.map { |name| "#{name} `#{options.fetch(name.to_sym)}`" }.join(", ")
    lines = ["### Warm journeys (#1507)", "",
             "`rigor check` on `#{options[:project_label] || options[:project]}` (paths: " \
             "#{options[:paths].empty? ? 'from the config' : options[:paths].join(' ')}), #{revs}; leaf " \
             "`#{options[:leaf]}`, hub `#{options[:hub]}`, `#{options[:edit]}` edits, #{options[:reps]} runs per step" \
             "#{arm_names.size == 2 ? ' in ABBA order' : ''}. Wall seconds per fresh-process run, boot included.", ""]
    lines.concat(reps_warning(options, arm_names, journey))
    lines.concat(table(arm_names, journey, stats))
    lines << "" << "Cold priming runs: #{journey.cold.map { |key, s| "#{key} #{s}s" }.join(', ')}"
    lines << "" << "Incremental recheck (files re-analysed / total), from `--verify-incremental`: " \
                   "#{journey.closures.map { |key, (n, m)| "#{key} #{n}/#{m}" }.join(', ')}" unless journey.closures.empty?
    lines << "" << journey.notes.join("\n") unless journey.notes.empty?
    lines << "" << journey.failures.map { |f| "**#{f}**" }.join("\n") unless journey.failures.empty?
    lines.join("\n")
  end

  def reps_warning(options, arm_names, journey)
    return [] unless arm_names.size == 2

    needed = EngineWallAB.runs_needed([journey.samples.size, 1].max)
    return [] if options.fetch(:reps) >= needed

    ["**At #{options[:reps]} runs per arm no row can say the ranges separate (that takes #{needed}); a \"no\" here " \
     "is not evidence of no difference.**", ""]
  end

  def table(arm_names, journey, stats)
    yjit = ->(row, name) { "#{journey.yjit[row][name]}/#{journey.samples.fetch(row).fetch(name, []).size}" }
    if arm_names.size == 1
      rows = ["| mode | scenario | median (min–max) | YJIT on |", "| --- | --- | ---: | ---: |"]
      journey.samples.each_key do |row|
        rows << "| #{row.join(' | ')} | #{cell(journey.samples[row]['head'])} | #{yjit.(row, 'head')} |"
      end
      return rows
    end
    rows = ["| mode | scenario | base median (min–max) | head median (min–max) | Δ median | ranges separate |",
            "| --- | --- | ---: | ---: | ---: | --- |"]
    journey.samples.each_key do |row|
      s = stats.fetch(row)
      verdict = s ? "#{EngineWallAB.change_cell(s['median_pct'])} | #{EngineWallAB.verdict_cell(s)}" : "n/a | n/a"
      rows << "| #{row.join(' | ')} | #{cell(journey.samples[row]['base'])} | #{cell(journey.samples[row]['head'])} | " \
              "#{verdict} |"
    end
    rows
  end

  def cell(values)
    return "–" if values.nil? || values.empty?

    "#{EngineWallAB.median(values).round(2)} (#{values.min.round(2)}–#{values.max.round(2)})"
  end
end

if $PROGRAM_NAME == __FILE__
  options = { paths: [], modes: EngineWarmAB::MODES, edit: "method", reps: 5, verify: true }
  OptionParser.new do |parser|
    parser.on("--project DIR") { |v| options[:project] = File.realpath(v) }
    parser.on("--project-label TEXT") { |v| options[:project_label] = v }
    parser.on("--leaf PATH") { |v| options[:leaf] = v }
    parser.on("--hub PATH") { |v| options[:hub] = v }
    parser.on("--base REV") { |v| options[:base] = v }
    parser.on("--head REV") { |v| options[:head] = v }
    parser.on("--paths LIST") { |v| options[:paths] = v.split }
    parser.on("--modes LIST") { |v| options[:modes] = v.split(",").map(&:strip).reject(&:empty?) }
    parser.on("--edit KIND", EngineWarmAB::EDITS) { |v| options[:edit] = v }
    parser.on("--reps N", Integer) { |v| options[:reps] = v }
    parser.on("--no-verify") { options[:verify] = false }
    parser.on("--summary PATH") { |v| options[:summary] = v }
    parser.on("--json PATH") { |v| options[:json] = v }
  end.parse!
  abort("--project, --leaf, --hub and --head are required") unless options.values_at(:project, :leaf, :hub, :head).all?
  abort("--base must name a revision") if options[:base] == EngineAllocAB::WORKTREE
  abort("--reps must be at least 1") if options[:reps] < 1
  abort("unknown mode in --modes") unless !options[:modes].empty? && (options[:modes] - EngineWarmAB::MODES).empty?
  %i[leaf hub].each do |key|
    abort("#{key} #{options[key]} is not a file in the project") unless File.file?(File.join(options[:project], options[key]))
  end
  EngineWarmAB.assert_default_cache(options[:project])
  exit EngineWarmAB.run(options)
end
