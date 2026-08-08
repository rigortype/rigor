#!/usr/bin/env ruby
# frozen_string_literal: true

# Self-mutation testing of `lib/rigor/` — Product C (see docs/notes/20260618-self-mutation-testing-plan.md). Points the
# productized mutation machinery INWARD at Rigor's own implementation and fuses two kill oracles:
#
#   * the TYPE axis  — Rigor's own self-check (`DiagnosticOracle`): does a
#     type-visible breakage make `rigor check lib` newly complain?
#   * the TEST axis  — Rigor's own RSpec suite (`TestSuiteOracle`): does the
#     covering spec go red when the implementation is broken?
#
# A mutation killed by neither is an *implementation hole* — code that can be broken without either the type net or a
# test noticing. The report attributes each survivor so the cheaper missing guard is obvious: add a spec, or add a type
# / sharpen a self-check rule.
#
# This is a thin driver over `Rigor::Protection::{MutationScanner,TestSuiteOracle}` (one source of truth with ADR-63
# Tier 2 / ADR-70). It adds only the two things Product C needs over Product B (mutating a *user's* code):
#
#   1. The TEST runner uses Rigor's OWN bundle. `TestSuiteOracle`'s default
#      runner strips Bundler's env (right for a *foreign* project's Gemfile,
#      wrong here — the SUT bundle IS Rigor's). We inject a plain in-bundle
#      `system` runner.
#   2. Per-file coverage-scoped spec selection (tier 0: the convention mapping
#      `lib/rigor/a/b.rb -> spec/rigor/a/b_spec.rb`, falling back to every
#      `spec/rigor/a/b/*_spec.rb` when a file's specs are split per topic), so
#      the test axis runs only the relevant specs instead of the ~6,300-example
#      suite per mutant.
#
# The TYPE oracle here is the IN-PROCESS worktree engine, which is sound and the most rule-accurate choice: the engine
# is loaded once (clean) at startup and a mutation is only ever analysed *input* (the type axis never writes to disk) —
# so mutating the analyzer cannot corrupt the loaded oracle. The plan's independent (mise / clean-HEAD) oracle is for
# the broad-fuzz / robustness variant where rule-parity does not matter; not needed for this fused measure.
#
# Run inside the Flake:
#   nix --extra-experimental-features 'nix-command flakes' develop -c \
#     bundle exec ruby tool/mutation/self_mutate.rb lib/rigor/cli/ci_detector.rb
#
# Flags: --type-only        skip the test axis (Phase 1 — no disk writes, fast)
#        --site all|biteable  which sites to mutate (default: all — comprehensive;
#                             biteable = only sites the type checker can bite)
#        --limit N --seed N   sample at most N mutations/file (caps cost)
#        --config PATH        Rigor config (default: project default)
#        --json               machine-readable survivors (stdout; progress→stderr)
#        --verbose            do not suppress the spec runner's output

require "json"
require "optparse"
require "prism"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "rigor"
require "rigor/language_server"
require "rigor/protection/mutation_scanner"
require "rigor/protection/test_suite_oracle"

module RigorSelfMutation
  # Maps a `lib/rigor/**.rb` path to the list of specs that cover it, or nil when none exist. Tier 0 of the plan's
  # coverage-guided selection — cheap and exact for the 1:1 majority; a full `{line -> specs}` coverage index is the
  # precise fallback (future). Two conventions, in priority order:
  #
  #   1. the 1:1 sibling  `lib/rigor/a/b.rb -> spec/rigor/a/b_spec.rb`
  #   2. the per-topic directory `lib/rigor/a/b.rb -> spec/rigor/a/b/*_spec.rb`, used where a file's specs are split
  #      by topic instead of collected in one sibling. Without it such a file maps to no spec at all, the test axis
  #      never runs, and every type-survivor over-reports as an implementation hole.
  module SpecMap
    module_function

    def for(lib_path)
      base = lib_path.sub(%r{\Alib/}, "spec/").sub(/\.rb\z/, "")
      sibling = "#{base}_spec.rb"
      return [sibling] if File.file?(sibling)

      topical = Dir.glob(File.join(base, "*_spec.rb"))
      topical.empty? ? nil : topical
    end
  end

  # The in-bundle spec runner: plain `system` so the rspec subprocess inherits Rigor's OWN Bundler env (the SUT bundle
  # is Rigor's). Output suppressed unless --verbose.
  class BundledRunner
    def initialize(verbose:)
      @opts = verbose ? {} : { out: File::NULL, err: File::NULL }
    end

    def call(command)
      system(*command, **@opts)
    end
  end

  class Driver
    Outcome = Struct.new(:path, :spec, :type_killed, :test_killed, :survivors, :note, keyword_init: true)

    def initialize(options)
      @options = options
      config = Rigor::Configuration.load(options[:config])
      warn "cold setup (env + project scan)…"
      @ctx = Rigor::LanguageServer::ProjectContext.new(configuration: config)
      @ctx.environment
      @ctx.project_scan
      @config = config
      @runner = BundledRunner.new(verbose: options[:verbose])
      @coverage = options[:coverage_gap] ? JSON.parse(File.read(options[:coverage_gap])) : nil
    end

    def run(paths)
      files = expand(paths)
      return coverage_gap_sweep(files) if @coverage

      guard_clean!(files)
      install_restore_trap(files)
      outcomes = files.map { |f| measure(f) }
      report(outcomes)
    end

    # Whole-tree backlog without a per-mutant suite run (the efficient pass). For each file, the cheap in-process TYPE
    # axis over EVERY dispatch site (`:all`); a type-survivor whose line the suite never executed (per the
    # `--coverage-gap` index) is provably test-unprotected — a high-confidence implementation hole. A type-survivor on a
    # covered line is only *maybe* killed (covered ≠ asserted), so it is reported separately as needing the expensive
    # fused verification.
    def coverage_gap_sweep(files)
      holes = []
      needs_check = 0
      out = @options[:out] ? File.open(@options[:out], "w") : nil
      files.each_with_index do |path, i|
        warn "[#{i + 1}/#{files.size}] #{path}"
        source = File.read(path, encoding: Encoding::UTF_8)
        cold = cold_site_classifier(source, (@coverage[path.delete_prefix("lib/")] || []).to_set)
        file_holes = []
        scanner(:all).scan_file(path, source: source).sites.each do |s|
          if cold.call(s.line)
            file_holes << survivor(path, s.line, s.receiver, s.method_name, s.operator, :none)
          else
            needs_check += 1
          end
        end
        holes.concat(file_holes)
        # Stream a per-file JSONL line, flushed, so a killed run keeps its partial backlog (the sweep is the slow part).
        out&.puts(JSON.generate(path: path, holes: file_holes))
        out&.flush
      end
    ensure
      out&.close
      report_coverage_gap(holes, needs_check)
    end

    # A type-survivor is a high-confidence hole only when its ENCLOSING METHOD is entirely uncovered (a never-executed
    # def). Ruby line-coverage attributes a multi-line expression's execution to its first line, so a bare "line ∉
    # covered set" check false-flags the continuation lines of a covered expression — e.g. a tested `to_h`'s
    # hash-literal entries read as uncovered. Method-level coldness removes that artifact: every site inside a warm
    # method is treated as covered. (Trade-off: a cold branch inside a warm method is not flagged — accepted, this
    # favours precision over recall for a trustworthy backlog.) Class-body / constant sites have no enclosing def to
    # anchor on, suffer the same artifact, and are data not logic — they are never high-confidence holes.
    def cold_site_classifier(source, executed)
      defs = method_ranges(source).map { |r| [r, r.none? { |ln| executed.include?(ln) }] }
      lambda do |line|
        enclosing = defs.select { |r, _| r.cover?(line) }.min_by { |r, _| r.size }
        # A site with no enclosing def is class-body/constant data — not a high-confidence hole (it suffers the
        # multi-line attribution artifact with no method to anchor on). The signal is trustworthy only inside a def,
        # where coldness means the whole method never ran.
        enclosing ? enclosing.last : false
      end
    end

    # The line ranges (start..end) of every `def` in the source, via Prism.
    def method_ranges(source)
      ranges = []
      collect = lambda do |node|
        return unless node.is_a?(Prism::Node)

        ranges << (node.location.start_line..node.location.end_line) if node.is_a?(Prism::DefNode)
        node.compact_child_nodes.each { |c| collect.call(c) }
      end
      collect.call(Prism.parse(source).value)
      ranges
    end

    private

    def expand(paths)
      candidates = paths.flat_map do |p|
        File.directory?(p) ? Dir.glob(File.join(p, "**", "*.rb")) : [p]
      end
      candidates.select { |f| f.end_with?(".rb") && File.file?(f) }
    end

    # The test axis temporarily overwrites the real lib file on disk (the scanner restores per-mutant in an `ensure`).
    # Refuse to start with those files already dirty so an aborted run cannot be confused with the user's own edits, and
    # so the restore trap cannot stomp uncommitted work.
    def guard_clean!(files)
      return if @options[:type_only]

      dirty = files.reject { |f| `git status --porcelain -- #{f}`.strip.empty? }
      return if dirty.empty?

      abort "self_mutate: refusing to run the test axis on dirty files (commit/stash first):\n  " \
            "#{dirty.join("\n  ")}\n(or pass --type-only, which never writes to disk)"
    end

    # Belt-and-suspenders over the scanner's per-mutant `ensure`: a hard interrupt mid-suite would leave a mutant on
    # disk, so restore the targets from git on the way out.
    def install_restore_trap(files)
      return if @options[:type_only]

      restore = -> { system("git", "checkout", "--", *files, out: File::NULL, err: File::NULL) }
      at_exit(&restore)
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          restore.call
          exit(130)
        end
      end
    end

    def scanner(site_selector)
      Rigor::Protection::MutationScanner.new(
        configuration: @config, environment: @ctx.environment, project_scan: @ctx.project_scan,
        limit: @options[:limit], seed: @options[:seed], site_selector: site_selector
      )
    end

    def measure(path)
      source = File.read(path, encoding: Encoding::UTF_8)
      unless Prism.parse(source).success?
        return Outcome.new(path: path, type_killed: 0, test_killed: 0, survivors: [], note: "parse-error")
      end

      specs = @options[:type_only] ? nil : SpecMap.for(path)
      specs ? measure_fused(path, source, specs) : measure_type_only(path, source)
    end

    # Type axis only (Phase 1): no spec / --type-only. Biteable sites, since a
    # Dynamic site cannot be type-killed and there is no test axis to catch it.
    def measure_type_only(path, source)
      warn "[type-only] #{path}#{' (no convention spec)' unless @options[:type_only]}"
      r = scanner(:biteable).scan_file(path, source: source)
      Outcome.new(
        path: path, type_killed: r.killed, test_killed: 0,
        survivors: r.sites.map { |s| survivor(path, s.line, s.receiver, s.method_name, s.operator, :type_only) },
        note: @options[:type_only] ? nil : "no-spec"
      )
    end

    # Fused axis: type pass, then the covering specs on each type-survivor.
    def measure_fused(path, source, specs)
      command = %w[bundle exec rspec] + specs
      oracle = Rigor::Protection::TestSuiteOracle.new(command: command, runner: @runner)
      unless oracle.green?
        warn "[skip] #{path}: covering spec #{specs.join(' ')} is not green on clean code — type-only"
        return measure_type_only(path, source)
      end

      warn "[fused] #{path}  (spec: #{specs.join(' ')})"
      r = scanner(@options[:site]).scan_file_fused(path, test_oracle: oracle, source: source)
      Outcome.new(
        path: path, type_killed: r.type_killed, test_killed: r.test_killed,
        survivors: r.sites.map { |s| survivor(path, s.line, s.receiver, s.method_name, s.operator, :none) },
        note: nil
      )
    end

    def survivor(path, line, receiver, method_name, operator, protection)
      { path: path, line: line, receiver: receiver, method: method_name,
        operator: operator, protection: protection }
    end

    def report(outcomes)
      @options[:json] ? report_json(outcomes) : report_text(outcomes)
    end

    def report_json(outcomes)
      survivors = outcomes.flat_map(&:survivors)
      puts JSON.pretty_generate(
        summary: totals(outcomes),
        files: outcomes.map { |o|
          { path: o.path, type_killed: o.type_killed, test_killed: o.test_killed,
            survivors: o.survivors.size, note: o.note }
        },
        survivors: survivors
      )
    end

    def report_text(outcomes)
      t = totals(outcomes)
      puts "\nSelf-mutation of lib/rigor — fused type ∪ test"
      puts "  files measured:   #{t[:files]}  (type-only: #{t[:type_only_files]})"
      puts "  type-killed:      #{t[:type_killed]}"
      puts "  test-killed:      #{t[:test_killed]}"
      puts "  UNPROTECTED:      #{t[:unprotected]}  ← implementation holes (add a spec or a type)"
      puts "  fused protection: #{format('%.1f%%', t[:ratio] * 100)}" if t[:total].positive?

      holes = outcomes.flat_map(&:survivors).reject { |s| s[:protection] == :type_only }
      unless holes.empty?
        puts "\nUnprotected sites — neither a type nor a test caught the breakage:"
        holes.first(60).each do |s|
          puts "  #{s[:path]}:#{s[:line]}  #{s[:receiver]}##{s[:method]}  (#{s[:operator]})"
        end
        puts "  … and #{holes.size - 60} more" if holes.size > 60
      end

      type_only = outcomes.flat_map(&:survivors).select { |s| s[:protection] == :type_only }
      return if type_only.empty?

      puts "\nType-survivors on files without a convention spec (test axis not run):"
      type_only.first(20).each do |s|
        puts "  #{s[:path]}:#{s[:line]}  #{s[:receiver]}##{s[:method]}  (#{s[:operator]})"
      end
      puts "  … and #{type_only.size - 20} more" if type_only.size > 20
    end

    # Backlog from the coverage-gap pass: the high-confidence holes (type-blind
    # sites no spec executes), clustered by file and by (operator, receiver).
    def report_coverage_gap(holes, needs_check)
      if @options[:json]
        puts JSON.pretty_generate(
          summary: { holes: holes.size, needs_verification: needs_check },
          by_file: holes.group_by { |h| h[:path] }.transform_values(&:size).sort_by { |_, n| -n }.to_h,
          holes: holes
        )
        return
      end

      puts "\nCoverage-gap backlog — type-blind sites no spec executes (high-confidence holes)"
      puts "  holes:              #{holes.size}"
      puts "  needs-verification: #{needs_check}  (type-survivors on covered lines — covered ≠ asserted)"

      puts "\nBy file (top 25):"
      holes.group_by { |h| h[:path] }.transform_values(&:size).sort_by { |_, n| -n }.first(25).each do |path, n|
        puts "  #{format('%4d', n)}  #{path}"
      end

      puts "\nBy (operator, receiver) cluster (top 20):"
      holes.group_by { |h| [h[:operator], h[:receiver]] }.transform_values(&:size)
           .sort_by { |_, n| -n }.first(20).each do |(op, recv), n|
        puts "  #{format('%4d', n)}  #{op}  #{recv}"
      end
    end

    def totals(outcomes)
      tk = outcomes.sum(&:type_killed)
      sk = outcomes.sum(&:test_killed)
      holes = outcomes.flat_map(&:survivors).count { |s| s[:protection] == :none }
      total = tk + sk + holes
      { files: outcomes.size, type_only_files: outcomes.count { |o| o.note == "no-spec" },
        type_killed: tk, test_killed: sk, unprotected: holes, total: total,
        ratio: total.zero? ? 1.0 : (tk + sk).to_f / total }
    end
  end
end

options = { config: nil, limit: nil, seed: 1, site: :all, type_only: false, json: false, verbose: false,
            coverage_gap: nil, out: nil }
parser = OptionParser.new do |o|
  o.banner = "Usage: ruby tool/mutation/self_mutate.rb [options] <lib paths…>"
  o.on("--config PATH") { |v| options[:config] = v }
  o.on("--limit N", Integer) { |v| options[:limit] = v }
  o.on("--seed N", Integer) { |v| options[:seed] = v }
  o.on("--site SEL", %i[all biteable]) { |v| options[:site] = v }
  o.on("--type-only") { options[:type_only] = true }
  o.on("--coverage-gap PATH", "Whole-tree backlog: classify type-survivors against a suite " \
                              "line-coverage index (COVERAGE_JSON). No per-mutant suite run.") do |v|
    options[:coverage_gap] = v
  end
  o.on("--out PATH", "Stream per-file holes as JSONL (flushed per file) under --coverage-gap, " \
                     "so a killed run keeps its partial backlog.") { |v| options[:out] = v }
  o.on("--json") { options[:json] = true }
  o.on("--verbose") { options[:verbose] = true }
end
paths = parser.parse(ARGV)
abort parser.help if paths.empty?

RigorSelfMutation::Driver.new(options).run(paths)
