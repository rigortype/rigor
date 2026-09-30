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
# Protocol, per mode and engine: remove the project's `.rigor/cache` and prime the cache with one cold run
# (recorded); time `--reps` null runs; then for the leaf and the hub, `--reps` times, edit the file, time one run,
# restore it, and run once more untimed to put the cache back. With `--profile-dir`, each scenario then runs once
# more, untimed, under vernier (see {PROFILER}). Each engine is laid out as an installed gem so that its result-cache
# key is the released one (see {arm_dirs}).
#
# Every timed run is checked for being the run it is labelled as, from a marker the child process writes at exit
# (`-r` on RUBYOPT; no engine change):
#   - an edit run, in either mode, must load the inference engine (a miss that saw the edit);
#   - every `--incremental` run must report itself `warm`;
#   - a null run is counted as a probe hit when it did not load the engine: the default mode's is served from the
#     plain run-result slot (ADR-87 WD4), `--incremental`'s from the one the incremental session writes (ADR-45
#     WD2). Both probes step aside for some configurations (worker pools, effects declarations), where the full
#     path still answers warm, so a null run that loads the engine is reported rather than failed.
# The same marker proves no Rigor file loaded from this checkout instead of the engine, and records whether YJIT
# was on.
#
# Correctness: the first timed run of each scenario is compared with a plain `rigor check --no-cache` of the same
# tree, which reads and writes neither the result cache nor the incremental snapshot. (`--incremental --no-cache`
# is not a cold run: it still replays the snapshot, #1525.) Any difference in the output fails the tool, the same
# findings in another order included (#1524). Every run passes `--no-baseline`, so a project baseline does not hide
# findings from the comparison.
#
# An edit is `method` (an empty method inserted into the file's main declaration: the one named after the file, else
# the widest multi-line class, else the widest module; see {edited}) or `comment` (a comment line appended). Both
# edits are checked to parse before any run. Under rbs-inline comment ingestion, which is on whenever
# the gem resolves, a comment edit widens an incremental closure at least as far as a method edit does (a hub whose
# dependents only call it re-analyses them for a comment and not for a new method). How far an edit
# spread is not reported yet: the `--incremental` banner does not carry the recheck size (#1526), and
# `--verify-incremental`'s count is a fixed half of the tree, not an edit's closure. So whether the chosen leaf and
# hub are a leaf and a hub rests on the files chosen; Mastodon's defaults were checked with an instrumented engine
# (1 and 277 files re-analysed).
#
# With `--base`, the two engines each get their own copy of the project, so their caches never meet, and every
# timed step alternates between them in ABBA order. The verdict per row is `tool/engine_wall_ab.rb`'s: medians,
# ranges, and separation beyond chance with the bar divided across the rows.
#
# Usage:
#   ruby tool/engine_warm_ab.rb --project DIR --leaf PATH --hub PATH --head REV|WORKTREE [--base REV]
#                               [--paths "app lib"] [--modes default,incremental] [--edit method|comment]
#                               [--reps N] [--no-verify] [--summary FILE] [--json FILE]
#                               [--profile-dir DIR --profile-lib VERNIER_LIB]

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "date"
require "prism"
require "tmpdir"
require "yaml"
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

  # With `--profile-dir`, loaded into one extra run per scenario (never a timed one): it wall-profiles the process
  # with vernier (whose lib `RIGOR_WARM_VERNIER_LIB` names, outside the bundle) from the moment it loads, which is
  # after Ruby's boot and `bundler/setup`, and vernier records GC as markers rather than samples. At exit it writes
  # the sampled window, the GC time inside it, and a breakdown: the chain of frames that nearly every sample shares
  # (descended while one child holds at least 90% of the samples, so a dominant phase is opened rather than hidden),
  # the children at the level where the samples fan out, and the inclusive and self top lists.
  PROFILER = <<~'PROFILER_RUBY'
    if (out = ENV["RIGOR_WARM_PROFILE"]) && !out.empty?
      begin
        $LOAD_PATH.unshift(ENV.fetch("RIGOR_WARM_VERNIER_LIB"))
        require "vernier"
        require "json"
      rescue LoadError => e
        warn "rigor-warm: vernier unavailable (#{e.message}); no profile written"
        out = nil
      end
    end
    if out
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      gc_before = GC.stat(:time)
      Vernier.start_profile(mode: :wall, interval: 1000, allocation_interval: 0)
      at_exit do
        result = Vernier.stop_profile
        gc_ms = GC.stat(:time) - gc_before
        stopped = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        require ENV.fetch("RIGOR_WARM_DESCENT")
        main = result.main_thread
        table = result.stack_table
        stacks = Hash.new(0)
        root_first = {}
        main[:samples].zip(main[:weights]) do |index, weight|
          stacks[root_first[index] ||= table.stack(index).frames.map(&:label).reverse] += weight
        end
        inclusive = Hash.new(0)
        leaf = Hash.new(0)
        stacks.each do |stack, weight|
          stack.uniq.each { |label| inclusive[label] += weight }
          leaf[stack.last] += weight
        end
        top = ->(counts, n) { counts.sort_by { |_, v| -v }.first(n) }
        rigor = inclusive.select { |k, _| k.start_with?("Rigor::", "Rigor.") }
        summary = WarmProfileDescent.call(stacks).merge(
          "sampled_ms" => stacks.values.sum, "window_ms" => ((stopped - started) * 1000).round, "gc_ms" => gc_ms,
          "inclusive_rigor" => top.(rigor, 40), "self" => top.(leaf, 40)
        )
        # The reduction above runs inside the child's wall time; the harness subtracts it.
        summary["post_ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - stopped) * 1000).round
        File.write(out, JSON.generate(summary))
      end
    end
  PROFILER_RUBY

  module_function

  # One `rigor check` in a fresh process. Aborts unless it completed (exit 0 or 1) with parseable JSON and loaded
  # nothing from this checkout.
  def check(engine_dir, project, extra_args, paths, scratch:, env_extra: {})
    args = ["check", "--no-stats", "--no-baseline", "--format", "json", *extra_args]
    marker = File.join(scratch, "marker.txt")
    FileUtils.rm_f(marker)
    preload = "-r#{File.join(scratch, 'marker.rb')}"
    preload += " -r#{File.join(scratch, 'profile.rb')}" if env_extra.key?("RIGOR_WARM_PROFILE")
    env = { "RUBYOPT" => "#{ENV.fetch('RUBYOPT', '')} #{preload}".strip,
            "RIGOR_WARM_MARKER" => marker, "RIGOR_WARM_CHECKOUT" => EngineAllocAB::ROOT }.merge(env_extra)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(engine_dir, "exe", "rigor"), *args, *paths,
                                      chdir: project)
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    diagnostics = EngineAllocAB.diagnostic_count(out)
    unless EngineAllocAB::COMPLETED_EXITS.include?(status.exitstatus) && diagnostics
      abort("rigor #{args.join(' ')} exited #{status.inspect} in #{project}:\n#{err[-2000..] || err}")
    end
    marks = parse_marker(File.exist?(marker) ? File.read(marker) : "")
    abort("rigor loaded #{marks['foreign']} from the checkout instead of #{engine_dir}") unless marks["foreign"].empty?
    { "wall_s" => wall.round(3), "diagnostics" => diagnostics, "digest" => Digest::SHA256.hexdigest(out),
      "set_digest" => set_digest(out), "engine_loaded" => marks["engine"] == "1", "yjit" => marks["yjit"] == "1",
      "incremental" => err[/--incremental (warm|cold)/, 1] }
  end

  def parse_marker(text)
    text.split.to_h { |pair| pair.split("=", 2) }.then { |h| { "foreign" => "" }.merge(h.transform_values(&:to_s)) }
  end

  # The output with its diagnostics in a canonical order. Two runs must print the same bytes; when they do not, this
  # tells a reorder (what `--incremental` printed after an edit until #1524) from different findings.
  def set_digest(json)
    parsed = JSON.parse(json)
    parsed["diagnostics"] = parsed.fetch("diagnostics").sort_by { |d| JSON.generate(d) }
    Digest::SHA256.hexdigest(JSON.generate(parsed))
  end

  # The file's text with the probe edit `n` applied. A `method` edit goes into the file's main declaration as Prism
  # parses it (so nothing inside a heredoc): the one named after the file (`migration_helpers.rb` →
  # `MigrationHelpers`) when there is one, else the multi-line class with the widest span, else the widest module.
  # Namespace wrappers whose body is a single class or module are skipped, and so are one-line declarations. The
  # probe goes before the declaration's `end`, or before its first `rescue`/`else`/`ensure` clause when the body has
  # one, in the file's own line endings.
  def edited(text, kind, n, file = nil)
    eol = text.include?("\r\n") ? "\r\n" : "\n"
    return "#{text.chomp}#{eol}# rigor-warm-probe #{n}#{eol}" if kind == "comment"

    target = probe_target(text, file)
    abort("no multi-line class or module whose `end` starts its line#{" in #{file}" if file}") unless target
    lines = text.lines
    indent = lines[target.location.start_line - 1][/\A[ \t]*/]
    lines.insert(insertion_line(target) - 1, "#{indent}  def __rigor_warm_probe_#{n}; end#{eol}")
    lines.join
  end

  def insertion_line(node)
    body = node.body
    clause = body.is_a?(Prism::BeginNode) && (body.rescue_clause || body.else_clause || body.ensure_clause)
    clause ? clause.location.start_line : node.end_keyword_loc.start_line
  end

  def probe_target(text, file = nil)
    result = Prism.parse(text)
    return nil unless result.success?

    lines = text.lines
    candidates = declarations(result.value).select do |node|
      loc = node.end_keyword_loc
      loc.start_line > node.location.start_line && lines[loc.start_line - 1][0...loc.start_column].strip.empty? &&
        !wrapper?(node)
    end
    named = file && candidates.select { |node| node.constant_path.slice.split("::").last == camelize(file) }
    pool = named.nil? || named.empty? ? candidates.grep(Prism::ClassNode) : named
    pool = candidates if pool.empty?
    pool.max_by { |node| node.location.end_line - node.location.start_line }
  end

  def camelize(file)
    File.basename(file, ".rb").split("_").map(&:capitalize).join
  end

  def wrapper?(node)
    statements = node.body.is_a?(Prism::StatementsNode) ? node.body.body : []
    statements.size == 1 && (statements.first.is_a?(Prism::ClassNode) || statements.first.is_a?(Prism::ModuleNode))
  end

  def declarations(node, found = [])
    found << node if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
    node.compact_child_nodes.each { |child| declarations(child, found) }
    found
  end

  # Both probe edits of `file` must parse, so a bad placement fails before any run is spent.
  def assert_probe_editable(project, file, kind, reps = 1)
    text = File.read(File.join(project, file))
    [1, 2, reps + 1].uniq.each do |n|
      abort("the #{kind} probe does not parse in #{file}") unless Prism.parse(edited(text, kind, n, file)).success?
    end
  end

  # Whether `file` lies under one of `paths` (directories or files, relative to the project).
  def within_paths?(project, file, paths)
    return true if paths.empty?

    target = File.expand_path(file, project)
    paths.any? do |path|
      root = File.expand_path(path, project)
      target == root || target.start_with?("#{root.chomp('/')}/")
    end
  end

  # A project whose configuration moves the cache elsewhere would keep its cache across the copy and the clear.
  # (Only the root config files are read, not an `includes:` chain.)
  def assert_default_cache(project)
    CONFIG_FILES.each do |name|
      path = File.join(project, name)
      next unless File.file?(path)

      config = begin
        YAML.safe_load_file(path, aliases: true, permitted_classes: [Date, Time, Symbol])
      rescue Psych::Exception
        nil
      end
      cache = config.is_a?(Hash) ? config["cache"] : nil
      next unless cache.is_a?(Hash) && cache.key?("path")

      abort("#{name} sets `cache.path`; the harness clears only the default .rigor/cache")
    end
  end

  class Journey
    attr_reader :samples, :cold, :failures, :notes, :yjit, :engine_loaded, :profiles

    def initialize(arms, options, scratch)
      @arms = arms # { name => { engine:, project: } }
      @options = options
      @scratch = scratch
      @samples = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } } # [mode, scenario] => arm => walls
      @yjit = Hash.new { |h, k| h[k] = Hash.new(0) } # [mode, scenario] => arm => runs with YJIT on
      @engine_loaded = Hash.new { |h, k| h[k] = Hash.new(0) } # [mode, scenario] => arm => runs that loaded it
      @cold = {}
      @profiles = {}
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
        FileUtils.rm_rf(File.join(arm[:project], ".rigor", "cache"))
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
      @arms.each { |name, arm| profile(mode, "null", name, arm) }
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
        end
      end
      return unless @options[:profile_dir]

      @arms.each do |name, arm|
        with_edit(arm, file, @options.fetch(:reps) + 1) { profile(mode, scenario, name, arm) }
        run_check(arm, mode_args(mode))
      end
    end

    # One extra, untimed run of the scenario under the profiler, in the same cache state as the timed ones. It must
    # be the same hit or miss as its row, and a YJIT state that differs from the timed runs' is noted: the
    # profiler's overhead can push a run past the deadline, and the profile then shows a compile burst the timed
    # rows never paid. (Under a fork pool, analysis runs in children the profiler does not follow.)
    def profile(mode, scenario, name, arm)
      dir = @options[:profile_dir]
      return unless dir

      key = "#{mode}/#{scenario}/#{name}"
      out = File.join(dir, "#{key.tr('/', '-')}.json")
      FileUtils.rm_f(out)
      result = EngineWarmAB.check(arm[:engine], arm[:project], mode_args(mode), paths, scratch: @scratch,
                                  env_extra: { "RIGOR_WARM_PROFILE" => out,
                                               "RIGOR_WARM_VERNIER_LIB" => @options.fetch(:profile_lib),
                                               "RIGOR_WARM_DESCENT" => File.join(__dir__, "warm_profile_descent.rb") })
      assert_labelled(mode, scenario, "#{name} (profiled)", result)
      timed_hit = @engine_loaded[[mode, scenario]][name] * 2 < @samples[[mode, scenario]][name].size
      @notes << "#{key}: the profiled run #{result['engine_loaded'] ? 'loaded the engine' : 'was a probe hit'}, unlike " \
                "most timed runs" if scenario == "null" && result["engine_loaded"] == timed_hit
      timed_yjit = @yjit[[mode, scenario]][name] * 2 > @samples[[mode, scenario]][name].size
      @notes << "#{key}: the profiled run ended with YJIT #{result['yjit'] ? 'on' : 'off'}, unlike most timed runs" if
        result["yjit"] != timed_yjit
      unless File.exist?(out)
        @notes << "#{key}: no profile was written"
        return
      end
      profile = JSON.parse(File.read(out))
      profile["wall_ms"] = (result["wall_s"] * 1000).round - profile.fetch("post_ms", 0)
      @profiles[key] = profile
    end

    def with_edit(arm, file, rep)
      path = File.join(arm[:project], file)
      original = File.read(path)
      File.write(path, EngineWarmAB.edited(original, @options.fetch(:edit), rep, file))
      yield
    ensure
      File.write(path, original) if original
    end

    def timed(mode, scenario, name, arm)
      result = run_check(arm, mode_args(mode))
      assert_labelled(mode, scenario, name, result)
      @samples[[mode, scenario]][name] << result["wall_s"]
      @yjit[[mode, scenario]][name] += 1 if result["yjit"]
      @engine_loaded[[mode, scenario]][name] += 1 if result["engine_loaded"]
      warn format("%-11s %-4s %-5s %.2fs", mode, name, scenario, result["wall_s"])
      result
    end

    # The run must be the hit or miss its row is about; otherwise the row times something else. An incremental edit
    # run served by the ADR-45 WD2 probe would be a stale answer, so it fails here as well as on the verify.
    def assert_labelled(mode, scenario, name, result)
      label = "#{name} #{mode} #{scenario}"
      if mode == "incremental" && result["incremental"] != "warm"
        @failures << "#{label}: the run reported `--incremental #{result['incremental'].inspect}`, not warm"
      end
      return if scenario == "null" || result["engine_loaded"]

      @failures << "#{label}: the edit run did not load the engine, so the edit was not seen"
    end

    # Against a plain `--no-cache` run, which touches neither the result cache nor the incremental snapshot. The
    # output must be the same bytes; the failure says whether only the order differs (#1524).
    def verify(mode, scenario, name, arm, result)
      cold = run_check(arm, ["--no-cache"])
      return if result["digest"] == cold["digest"]

      label = "#{name} #{mode} #{scenario}"
      @failures << if result["set_digest"] == cold["set_digest"]
                     "#{label}: the same diagnostics as a --no-cache run of the same tree, in a different order"
                   else
                     "#{label}: the warm diagnostics differ from a --no-cache run of the same tree"
                   end
    end
  end

  def run(options)
    Dir.mktmpdir("rigor-warm-ab") do |scratch|
      tmp = File.realpath(scratch)
      File.write(File.join(tmp, "marker.rb"), MARKER)
      File.write(File.join(tmp, "profile.rb"), PROFILER)
      if options[:profile_dir]
        FileUtils.mkdir_p(options[:profile_dir])
        _, err, status = Open3.capture3(RbConfig.ruby, "-I", options[:profile_lib], "-rvernier", "-e", "0")
        abort("vernier does not load from #{options[:profile_lib]}:\n#{err}") unless status.success?
      end
      arms = arm_dirs(options, tmp)
      journey = Journey.new(arms, options, tmp)
      begin
        journey.run
      rescue SystemExit => e
        journey.failures << "aborted: #{e.message.to_s.split.join(' ')[0, 300]}"
        raise
      ensure
        report(options, arms.keys, journey)
      end
      return journey.failures.empty? ? 0 : 1
    end
  end

  def arm_dirs(options, tmp)
    names = options[:base] ? %w[base head] : %w[head]
    names.to_h do |name|
      staging = File.join(tmp, "staging-#{name}")
      EngineAllocAB.materialise(options.fetch(name.to_sym), staging, EngineAllocAB::ENGINE_PATHS + ["exe"])
      # Laid out as an installed gem, `gems/rigortype-<VERSION>`, so the result-cache key identifies the engine by
      # its version (`Cache::EngineSource.version_pinned?`) as a released install does, instead of digesting the
      # engine's source on every run, a cost only a development checkout pays.
      version = File.read(File.join(staging, "lib", "rigor", "version.rb"))[/VERSION\s*=\s*"([^"]+)"/, 1]
      abort("no Rigor::VERSION in the #{name} engine") unless version
      engine = File.join(tmp, "engine-#{name}", "gems", "rigortype-#{version}")
      FileUtils.mkdir_p(File.dirname(engine))
      File.rename(staging, engine)
      project = File.join(tmp, "project-#{name}")
      FileUtils.cp_r(File.join(options.fetch(:project), "."), project)
      FileUtils.rm_rf(File.join(project, ".rigor", "cache"))
      [name, { engine: engine, project: project }]
    end
  end

  def report(options, arm_names, journey)
    rows = journey.samples.keys
    stats = rows.to_h do |row|
      by_arm = journey.samples.fetch(row)
      next [row, nil] unless arm_names.size == 2 && arm_names.all? { |name| by_arm.fetch(name, []).any? }

      [row, EngineWallAB.metric_stats(by_arm.fetch("base"), by_arm.fetch("head"),
                                      EngineWallAB::SEPARATION_ALPHA / [rows.size, 1].max)]
    end
    result = { "options" => options.except(:summary, :json), "cold_s" => journey.cold,
               "samples" => journey.samples.transform_keys { |k| k.join("/") },
               "yjit_on" => counts(rows, arm_names, journey.yjit),
               "engine_loaded" => counts(rows, arm_names, journey.engine_loaded), "failures" => journey.failures,
               "notes" => journey.notes, "stats" => stats.transform_keys { |k| k.join("/") },
               "profiles" => journey.profiles }
    File.write(options[:json], JSON.pretty_generate(result)) if options[:json]
    EngineAllocAB.emit(summary(options, arm_names, journey, stats), options[:summary])
  end

  def counts(rows, arm_names, table)
    rows.to_h { |row| [row.join("/"), arm_names.to_h { |name| [name, table[row][name]] }] }
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
    lines.concat(probe_notes(arm_names, journey))
    lines.concat(profile_notes(journey))
    lines << "" << journey.notes.join("\n") unless journey.notes.empty?
    lines << "" << journey.failures.map { |f| "**#{f}**" }.join("\n") unless journey.failures.empty?
    lines.join("\n")
  end

  # Each profiled scenario: its wall time, how much of it the profiler saw, the collapsed chain every sample shares,
  # and where the samples fan out below it, as shares of the profiled run's wall time.
  def profile_notes(journey)
    return [] if journey.profiles.empty?

    lines = ["", "<details><summary>Profiles: where each scenario's wall time goes</summary>", "",
             "Shares are of the profiled run's wall time. The profiler starts after Ruby boot and `bundler/setup`, " \
             "and GC is not sampled, so the shares do not add up to 100%.", ""]
    journey.profiles.each do |key, profile|
      wall = [profile.fetch("wall_ms"), 1].max
      share = ->(ms) { format("%.0f%%", 100.0 * ms / wall) }
      labels = profile.fetch("chain").map(&:first).reject { |label| label.start_with?("<") }
      chain = labels.last(3)
      prefix = (labels.size > chain.size ? "… › " : "") + chain.map { |label| "#{label} › " }.join
      phases = profile.fetch("phases").first(8).map { |label, ms| "#{label} #{share.(ms)}" }
      heaviest, inner = profile.fetch("inner", [nil, []])
      inside = inner.empty? ? "" : " (inside #{heaviest}: #{inner.first(5).map { |l, ms| "#{l} #{share.(ms)}" }.join('; ')})"
      lines << "- **#{key}** (#{wall} ms; sampled #{share.(profile.fetch('sampled_ms'))}, GC #{profile.fetch('gc_ms')} ms): " \
               "#{prefix}#{phases.join('; ')}#{inside}"
    end
    lines << "" << "</details>"
  end

  # How many null runs each mode's probe served without the engine: the default mode's from the plain run-result
  # slot (ADR-87 WD4), `--incremental`'s from the session's (ADR-45 WD2).
  def probe_notes(arm_names, journey)
    lines = %w[default incremental].filter_map do |mode|
      row = [mode, "null"]
      next unless journey.samples.key?(row)

      served = arm_names.map do |name|
        runs = journey.samples.fetch(row).fetch(name, []).size
        "#{name} #{runs - journey.engine_loaded[row][name]}/#{runs}"
      end
      "#{mode.capitalize} null runs served by the engine-free probe (the rest loaded the engine): " \
        "#{served.join(', ')}"
    end
    lines.empty? ? [] : ["", *lines]
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
    parser.on("--profile-dir DIR", "Write one vernier profile summary per scenario and engine") do |v|
      options[:profile_dir] = File.expand_path(v)
    end
    parser.on("--profile-lib DIR", "The vernier gem's lib directory (installed outside the bundle)") do |v|
      options[:profile_lib] = File.expand_path(v)
    end
  end.parse!
  abort("--project, --leaf, --hub and --head are required") unless options.values_at(:project, :leaf, :hub, :head).all?
  abort("--base must name a revision") if options[:base] == EngineAllocAB::WORKTREE
  abort("--profile-dir and --profile-lib go together") if options[:profile_dir].nil? != options[:profile_lib].nil?
  abort("--reps must be at least 1") if options[:reps] < 1
  abort("unknown mode in --modes") unless !options[:modes].empty? && (options[:modes] - EngineWarmAB::MODES).empty?
  %i[leaf hub].each do |key|
    abort("#{key} #{options[key]} is not a file in the project") unless File.file?(File.join(options[:project], options[key]))
  end
  EngineWarmAB.assert_default_cache(options[:project])
  %i[leaf hub].each do |key|
    file = options[key]
    unless EngineWarmAB.within_paths?(options[:project], file, options[:paths])
      abort("#{key} #{file} is outside --paths, so editing it changes nothing the run analyses")
    end
    EngineWarmAB.assert_probe_editable(options[:project], file, options[:edit], options[:reps])
  end
  exit EngineWarmAB.run(options)
end
