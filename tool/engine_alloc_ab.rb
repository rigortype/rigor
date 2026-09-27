#!/usr/bin/env ruby
# frozen_string_literal: true

# Engine allocation A/B for a pull request (#1507): the base engine and the PR's engine each run `rigor check` over
# the SAME frozen corpus, and the allocation delta is the engine's own cost.
#
# ## Why a frozen corpus
#
# `lib` is Rigor's own source and grows with every PR, so a number measured over the current `lib` mixes corpus
# growth with engine cost: at the v0.4.0 cut the release gate rose 80.5% and the rise was accepted as a whole, and
# the engine's own share, +19.1% on a frozen corpus, was only separated afterwards (#1469). Here both engines read
# the corpus at one revision (the base's, by default), so a PR that only grows `lib` measures zero and a PR that makes
# the engine allocate more shows exactly that, on the PR that does it. The release gate (`tool/bench.rb`) now
# measures the same way, over the previous release's tree, but only at a cut.
#
# ## Method
#
# `git archive` the corpus revision into a scratch directory, and `lib data plugins` of each engine revision into
# its own. `lib/rigor` finds `data/` and `plugins/` beside itself, so each directory is a whole engine. Each engine
# then runs in a FRESH child process of this script (`--measure`): it puts the engine's `lib` first on the load
# path, changes into the corpus (config discovery is cwd-based) and counts `GC.stat(:total_allocated_objects)`
# around one in-process `rigor check --no-cache --no-stats --format json`. Afterwards it proves that no Rigor file
# loaded from this checkout instead of the engine, other than `rigor/version.rb`, which Bundler's gemspec loads
# first. The child starts in the repository root so Bundler resolves this checkout's bundle for both engines; the
# gem set is therefore the same on both sides and no delta is a gem change.
#
# Allocations are deterministic to a few hundred objects run to run (#1469), far inside any band worth warning on,
# so each engine runs once. Wall is printed for information only: on a shared runner it is noise.
#
# ## What it measures
#
# Only what `rigor check` over the corpus executes. The corpus's configuration loads no plugin, so of `plugins/`
# only the rbs-inline ingestion the engine runs by default (ADR-93) is measured, and a PR that changes nothing
# else ({TRIGGER_PATHS}) is skipped rather than reported as a zero it did not measure. Both engines run on the
# bundle of the checkout the tool runs from, which on CI is the PR's merge with its base: after a gem bump on the
# base, an older engine may run on gems newer than it shipped with, so read a failure there as that before blaming
# the PR's engine.
#
# ## Output
#
# A Markdown table on stdout (and appended to `--summary`, which CI points at `$GITHUB_STEP_SUMMARY`), plus a
# GitHub Actions `::warning::` when the head allocates more than `pr_allocations_pct` in `bench/thresholds.yml`
# over the base. It never fails on a regression — it is advisory — but it exits non-zero when an engine run fails:
# a `rigor check` exit other than 0 or 1 (a usage error is 64, an internal error 70), unparseable output, or a
# foreign load. A comparison that silently measured a partial run would read as an improvement.
#
# Usage:
#   ruby tool/engine_alloc_ab.rb --base REV --head REV [--corpus REV] [--target PATH] [--summary FILE]
#   ruby tool/engine_alloc_ab.rb --base "$(git merge-base origin/master HEAD)" --head WORKTREE   # uncommitted work
#   ruby tool/engine_alloc_ab.rb --measure ENGINE_DIR CORPUS_DIR TARGET   # internal: one fresh-process run

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"

# `tool/bench.rb` (the release gate) requires this file for `materialise`, `run_check`, `diagnostic_count` and
# `COMPLETED_EXITS`, so the two measure a corpus the same way.
module EngineAllocAB
  ROOT = File.expand_path("..", __dir__)
  # What each engine directory holds.
  ENGINE_PATHS = %w[lib data plugins].freeze
  # What a change must touch for the comparison to measure it (see "What it measures").
  TRIGGER_PATHS = %w[lib data plugins/rigor-rbs-inline].freeze
  WORKTREE = "WORKTREE"
  DEFAULT_WARN_PCT = 1.0
  # `rigor check`'s exit codes for a completed run: clean, and findings.
  COMPLETED_EXITS = [0, 1].freeze
  # The one checkout file a child may load: Bundler evaluates the gemspec, which requires it, before the engine.
  GEMSPEC_LOAD = File.join(ROOT, "lib", "rigor", "version.rb")

  module_function

  # One engine over one corpus, in THIS process. Only ever called in a `--measure` child.
  def measure(engine_dir, corpus_dir, target)
    $LOAD_PATH.unshift(File.join(engine_dir, "lib"))
    require "rigor/cli"

    out = StringIO.new
    err = StringIO.new
    Dir.chdir(corpus_dir) do
      GC.start
      before = GC.stat(:total_allocated_objects)
      gc_before = GC.stat(:time)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cpu0 = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      status = run_check(target, out, err)
      wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - cpu0
      gc_ms = GC.stat(:time) - gc_before
      allocations = GC.stat(:total_allocated_objects) - before
      diagnostics = diagnostic_count(out.string)
      unless COMPLETED_EXITS.include?(status) && diagnostics
        abort("rigor check exited #{status.inspect} with #{diagnostics.nil? ? 'unparseable' : 'parseable'} " \
              "output under #{engine_dir}:\n#{err.string}")
      end
      assert_engine_loads(engine_dir)
      { "allocations" => allocations, "wall_s" => wall.round(2), "diagnostics" => diagnostics,
        "output_digest" => Digest::SHA256.hexdigest(out.string),
        # For `tool/engine_wall_ab.rb`: process CPU (every thread), GC time, and whether YJIT ended up on.
        "cpu_s" => cpu.round(3), "gc_ms" => gc_ms, "yjit" => yjit_enabled? }
    end
  end

  def yjit_enabled? = defined?(RubyVM::YJIT) ? RubyVM::YJIT.enabled? : false

  def run_check(target, out, err)
    Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--format", "json", target], out: out, err: err).run
  rescue SystemExit => e
    e.status
  end

  # Every Rigor file the run loaded came from the engine under test, not from this checkout's `lib` or `plugins`,
  # which Bundler keeps on the load path (the gemspec's `require_paths`).
  def assert_engine_loads(engine_dir)
    checkout = %w[lib plugins].map { |dir| File.join(ROOT, dir, "") }
    foreign = $LOADED_FEATURES.select { |f| checkout.any? { |dir| f.start_with?(dir) } && f != GEMSPEC_LOAD }
    abort("loaded from the checkout instead of #{engine_dir}:\n#{foreign.first(5).join("\n")}") unless foreign.empty?
    cli = $LOADED_FEATURES.grep(%r{/rigor/cli\.rb\z}).first.to_s
    abort("rigor/cli loaded from #{cli}, not #{engine_dir}") unless cli.start_with?("#{engine_dir}/")
  end

  def diagnostic_count(json)
    JSON.parse(json).fetch("diagnostics").size
  rescue StandardError
    nil
  end

  # The verdict on two measurements. Pure, so the spec can drive it without running an engine. The band is compared
  # with the percentage as printed, so the table and the verdict cannot disagree at the boundary.
  def compare(base, head, warn_pct)
    delta = head.fetch("allocations") - base.fetch("allocations")
    pct = (100.0 * delta / base.fetch("allocations")).round(2)
    { "delta" => delta, "pct" => pct, "regressed" => pct > warn_pct,
      "same_output" => base["output_digest"] == head["output_digest"] }
  end

  def summary(revs, base, head, verdict, warn_pct)
    lines = [heading, "",
             "`rigor check --no-cache #{revs[:target]}` over the corpus at `#{revs[:corpus]}`, each engine in a " \
             "fresh process.", "",
             "| engine | revision | allocations | diagnostics | wall s |", "| --- | --- | ---: | ---: | ---: |"]
    [["base", revs[:base], base], ["head", revs[:head], head]].each do |name, rev, m|
      lines << "| #{name} | `#{rev}` | #{delimit(m['allocations'])} | #{m['diagnostics'].inspect} | #{m['wall_s']} |"
    end
    lines << "" << format("**Δ %s (%s%%)** against a %.1f%% warning band.%s", signed(verdict["delta"]),
                          signed_pct(verdict["pct"]), warn_pct, verdict["regressed"] ? " **Above the band.**" : "")
    lines << "The JSON output differs between the engines." unless verdict["same_output"]
    lines.join("\n")
  end

  def heading = "### Engine allocations (advisory, #1507)"

  def delimit(number)
    number.abs.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  end

  def sign(number) = number.negative? ? "−" : "+"

  def signed(number)
    "#{sign(number)}#{delimit(number)}"
  end

  def signed_pct(pct)
    format("%s%.2f", sign(pct), pct.abs)
  end

  def warn_pct(thresholds_path)
    value = YAML.safe_load_file(thresholds_path)&.fetch("pr_allocations_pct", nil)
    value.nil? ? DEFAULT_WARN_PCT : Float(value)
  end

  def git(*args)
    out, status = Open3.capture2("git", "-C", ROOT, *args)
    abort("git #{args.join(' ')} failed") unless status.success?
    out
  end

  # `rev`'s tree (or the working tree's, for WORKTREE) unpacked into `dir`, limited to `paths` when given.
  def materialise(rev, dir, paths = [])
    FileUtils.mkdir_p(dir)
    if rev == WORKTREE
      paths.each { |path| FileUtils.cp_r(File.join(ROOT, path), dir) }
    else
      archive = git("archive", "--format=tar", rev, *paths)
      _, status = Open3.capture2("tar", "-x", "-C", dir, stdin_data: archive, binmode: true)
      abort("tar failed for #{rev}") unless status.success?
    end
  end

  # `env` and `prefix` are for `tool/engine_wall_ab.rb`: a YJIT setting, and a `perf stat` wrapper.
  def run_child(engine_dir, corpus_dir, target, env: {}, prefix: [])
    raw, status = Open3.capture2(env, *prefix, RbConfig.ruby, File.expand_path(__FILE__), "--measure", engine_dir,
                                 corpus_dir, target, chdir: ROOT)
    abort("engine run for #{engine_dir} failed (#{status.inspect})") unless status.success?
    JSON.parse(raw.lines.last)
  end

  def engine_changed?(base, head)
    return true if head == WORKTREE

    _, status = Open3.capture2("git", "-C", ROOT, "diff", "--quiet", base, head, "--", *TRIGGER_PATHS)
    !status.success?
  end

  # A base that is not an ancestor of the work charges it with every engine change merged since they diverged.
  def warn_unless_ancestor(base)
    _, status = Open3.capture2("git", "-C", ROOT, "merge-base", "--is-ancestor", base, "HEAD")
    return if status.success?

    warn "warning: #{base} is not an ancestor of HEAD; the delta includes engine changes made since they " \
         "diverged. Pass --base \"$(git merge-base #{base} HEAD)\" to measure only this work."
  end

  def run(options)
    revs = { base: options.fetch(:base), head: options.fetch(:head), target: options.fetch(:target) }
    revs[:corpus] = options[:corpus] || revs[:base]
    abort("--base and --corpus must name a revision; the working tree is only a head engine") if
      [revs[:base], revs[:corpus]].include?(WORKTREE)
    warn_unless_ancestor(revs[:base]) if revs[:head] == WORKTREE
    unless engine_changed?(revs[:base], revs[:head])
      skip = "Engine unchanged between `#{revs[:base]}` and `#{revs[:head]}` (#{TRIGGER_PATHS.join(', ')}); " \
             "nothing to measure."
      emit("#{heading}\n\n#{skip}", options[:summary])
      return 0
    end

    Dir.mktmpdir("rigor-alloc-ab") do |scratch|
      # Resolved, so the child's load-path proof compares one spelling (macOS `/tmp` is `/private/tmp`).
      tmp = File.realpath(scratch)
      materialise(revs[:corpus], File.join(tmp, "corpus"))
      base_dir = File.join(tmp, "base")
      head_dir = File.join(tmp, "head")
      materialise(revs[:base], base_dir, ENGINE_PATHS)
      materialise(revs[:head], head_dir, ENGINE_PATHS)
      base = run_child(base_dir, File.join(tmp, "corpus"), revs[:target])
      head = run_child(head_dir, File.join(tmp, "corpus"), revs[:target])
      report(revs, base, head, warn_pct(options.fetch(:thresholds)), options[:summary])
    end
    0
  end

  def emit(text, summary_path)
    puts text
    File.write(summary_path, "#{text}\n", mode: "a") if summary_path
  end

  def report(revs, base, head, band, summary_path)
    verdict = compare(base, head, band)
    emit(summary(revs, base, head, verdict, band), summary_path)
    return unless verdict["regressed"] && ENV["GITHUB_ACTIONS"]

    puts format("::warning title=Engine allocations::The PR's engine allocates %s%% (%s) over the base on the " \
                "same corpus, above the %.1f%% band. See the job summary.", signed_pct(verdict["pct"]),
                signed(verdict["delta"]), band)
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.first == "--measure"
    _, engine_dir, corpus_dir, target = ARGV
    puts JSON.generate(EngineAllocAB.measure(engine_dir, corpus_dir, target))
    exit 0
  end

  options = { target: "lib", thresholds: File.join(EngineAllocAB::ROOT, "bench", "thresholds.yml") }
  OptionParser.new do |parser|
    parser.on("--base REV") { |v| options[:base] = v }
    parser.on("--head REV") { |v| options[:head] = v }
    parser.on("--corpus REV") { |v| options[:corpus] = v }
    parser.on("--target PATH") { |v| options[:target] = v }
    parser.on("--thresholds PATH") { |v| options[:thresholds] = v }
    parser.on("--summary PATH") { |v| options[:summary] = v }
  end.parse!
  abort("--base and --head are required") unless options[:base] && options[:head]
  exit EngineAllocAB.run(options)
end
