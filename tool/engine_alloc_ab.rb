#!/usr/bin/env ruby
# frozen_string_literal: true

# Engine allocation A/B for a pull request (#1507): the base engine and the PR's engine each run `rigor check` over
# the SAME frozen corpus, and the allocation delta is the engine's own cost.
#
# ## Why a frozen corpus
#
# The release gate (`tool/bench.rb`, `bench/thresholds.yml`) measures `rigor check lib` against a committed
# baseline, and `lib` is Rigor's own source. Every PR that adds code grows that corpus, so the gate's number mixes
# corpus growth with engine cost: at the v0.4.0 cut it rose 80.5%, of which the engine's share on a frozen corpus
# was +19.1% (#1469), all of it accumulated inside a +5% band. Here both engines read the corpus at one revision
# (the base's, by default), so a PR that only grows `lib` measures zero and a PR that makes the engine allocate more
# shows exactly that.
#
# ## Method
#
# `git archive` the corpus revision into a scratch directory, and `lib data plugins` of each engine revision into
# its own. `lib/rigor` finds `data/` and `plugins/` beside itself, so each directory is a whole engine. Each engine
# then runs in a FRESH child process of this script (`--measure`): it puts the engine's `lib` first on the load
# path, proves `rigor/cli` loaded from there, changes into the corpus (config discovery is cwd-based) and counts
# `GC.stat(:total_allocated_objects)` around one in-process `rigor check --no-cache --no-stats --format json`. The
# child starts in the repository root so Bundler resolves this checkout's bundle for both engines; the gem set is
# therefore the same on both sides and no delta is a gem change.
#
# Allocations are deterministic to a few hundred objects run to run (#1469), far inside any band worth warning on,
# so each engine runs once. Wall is printed for information only: on a shared runner it is noise.
#
# ## Output
#
# A Markdown table on stdout (and appended to `--summary`, which CI points at `$GITHUB_STEP_SUMMARY`), plus a
# GitHub Actions `::warning::` when the head allocates more than `pr_allocations_pct` in `bench/thresholds.yml`
# over the base. It never fails on a regression — it is advisory — but it does exit non-zero when an engine run
# itself fails, since a comparison that silently measured nothing is worse than none.
#
# Usage:
#   ruby tool/engine_alloc_ab.rb --base REV --head REV [--corpus REV] [--target PATH] [--summary FILE]
#   ruby tool/engine_alloc_ab.rb --base origin/master --head WORKTREE     # the uncommitted tree as the head engine
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

module EngineAllocAB
  ROOT = File.expand_path("..", __dir__)
  ENGINE_PATHS = %w[lib data plugins].freeze
  WORKTREE = "WORKTREE"
  DEFAULT_WARN_PCT = 1.0

  module_function

  # One engine over one corpus, in THIS process. Only ever called in a `--measure` child.
  def measure(engine_dir, corpus_dir, target)
    $LOAD_PATH.unshift(File.join(engine_dir, "lib"))
    require "rigor/cli"
    loaded = $LOADED_FEATURES.grep(%r{/rigor/cli\.rb\z}).first.to_s
    abort("rigor/cli loaded from #{loaded}, not #{engine_dir}") unless loaded.start_with?("#{engine_dir}/")

    out = StringIO.new
    Dir.chdir(corpus_dir) do
      GC.start
      before = GC.stat(:total_allocated_objects)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--format", "json", target],
                       out: out, err: StringIO.new).run
      rescue SystemExit
        # `check` exits non-zero on findings; the measurement stands regardless.
      end
      wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      allocations = GC.stat(:total_allocated_objects) - before
      { "allocations" => allocations, "wall_s" => wall.round(2), "diagnostics" => diagnostic_count(out.string),
        "output_digest" => Digest::SHA256.hexdigest(out.string) }
    end
  end

  def diagnostic_count(json)
    JSON.parse(json).fetch("diagnostics").size
  rescue StandardError
    nil
  end

  # The verdict on two measurements. Pure, so the spec can drive it without running an engine.
  def compare(base, head, warn_pct)
    delta = head.fetch("allocations") - base.fetch("allocations")
    pct = 100.0 * delta / base.fetch("allocations")
    { "delta" => delta, "pct" => pct.round(2), "regressed" => pct > warn_pct,
      "same_output" => base["output_digest"] == head["output_digest"] }
  end

  def summary(revs, base, head, verdict, warn_pct)
    lines = ["### Engine allocations (advisory, #1507)", "",
             "`rigor check --no-cache #{revs[:target]}` over the corpus at `#{revs[:corpus]}`, each engine in a " \
             "fresh process.", "",
             "| engine | revision | allocations | diagnostics | wall s |", "| --- | --- | ---: | ---: | ---: |"]
    [["base", revs[:base], base], ["head", revs[:head], head]].each do |name, rev, m|
      lines << "| #{name} | `#{rev}` | #{delimit(m['allocations'])} | #{m['diagnostics'].inspect} | #{m['wall_s']} |"
    end
    lines << "" << format("**Δ %s (%+.2f%%)** against a %.1f%% warning band.%s", signed(verdict["delta"]),
                          verdict["pct"], warn_pct, verdict["regressed"] ? " **Above the band.**" : "")
    lines << "The JSON output differs between the engines." unless verdict["same_output"]
    lines.join("\n")
  end

  def delimit(number)
    number.abs.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  end

  def signed(number)
    "#{number.negative? ? '−' : '+'}#{delimit(number)}"
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

  def run_child(engine_dir, corpus_dir, target)
    raw, status = Open3.capture2(RbConfig.ruby, File.expand_path(__FILE__), "--measure", engine_dir, corpus_dir,
                                 target, chdir: ROOT)
    abort("engine run for #{engine_dir} failed (#{status.inspect})") unless status.success?
    JSON.parse(raw.lines.last)
  end

  def engine_changed?(base, head)
    return true if head == WORKTREE

    _, status = Open3.capture2("git", "-C", ROOT, "diff", "--quiet", base, head, "--", *ENGINE_PATHS)
    !status.success?
  end

  def run(options)
    revs = { base: options.fetch(:base), head: options.fetch(:head), target: options.fetch(:target) }
    revs[:corpus] = options[:corpus] || revs[:base]
    abort("--corpus must name a revision; the working tree is only an engine") if revs[:corpus] == WORKTREE
    unless engine_changed?(revs[:base], revs[:head])
      puts "Engine unchanged between #{revs[:base]} and #{revs[:head]} (#{ENGINE_PATHS.join(', ')}); nothing to measure."
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

  def report(revs, base, head, band, summary_path)
    verdict = compare(base, head, band)
    text = summary(revs, base, head, verdict, band)
    puts text
    File.write(summary_path, "#{text}\n", mode: "a") if summary_path
    return unless verdict["regressed"] && ENV["GITHUB_ACTIONS"]

    puts format("::warning title=Engine allocations::The PR's engine allocates %+.2f%% (%+d) over the base " \
                "on the same corpus, above the %.1f%% band. See the job summary.", verdict["pct"],
                verdict["delta"], band)
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
