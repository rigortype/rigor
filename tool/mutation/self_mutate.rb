#!/usr/bin/env ruby
# frozen_string_literal: true

# Self-mutation testing of `lib/rigor/` — Product C (see
# docs/notes/20260618-self-mutation-testing-plan.md). Points the productized
# mutation machinery INWARD at Rigor's own implementation and fuses two kill
# oracles:
#
#   * the TYPE axis  — Rigor's own self-check (`DiagnosticOracle`): does a
#     type-visible breakage make `rigor check lib` newly complain?
#   * the TEST axis  — Rigor's own RSpec suite (`TestSuiteOracle`): does the
#     covering spec go red when the implementation is broken?
#
# A mutation killed by neither is an *implementation hole* — code that can be
# broken without either the type net or a test noticing. The report attributes
# each survivor so the cheaper missing guard is obvious: add a spec, or add a
# type / sharpen a self-check rule.
#
# This is a thin driver over `Rigor::Protection::{MutationScanner,TestSuiteOracle}`
# (one source of truth with ADR-63 Tier 2 / ADR-70). It adds only the two things
# Product C needs over Product B (mutating a *user's* code):
#
#   1. The TEST runner uses Rigor's OWN bundle. `TestSuiteOracle`'s default
#      runner strips Bundler's env (right for a *foreign* project's Gemfile,
#      wrong here — the SUT bundle IS Rigor's). We inject a plain in-bundle
#      `system` runner.
#   2. Per-file coverage-scoped spec selection (tier 0: the convention mapping
#      `lib/rigor/a/b.rb -> spec/rigor/a/b_spec.rb`), so the test axis runs only
#      the relevant spec instead of the ~6,300-example suite per mutant.
#
# The TYPE oracle here is the IN-PROCESS worktree engine, which is sound and the
# most rule-accurate choice: the engine is loaded once (clean) at startup and a
# mutation is only ever analysed *input* (the type axis never writes to disk) —
# so mutating the analyzer cannot corrupt the loaded oracle. The plan's
# independent (mise / clean-HEAD) oracle is for the broad-fuzz / robustness
# variant where rule-parity does not matter; not needed for this fused measure.
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
  # Maps a `lib/rigor/**.rb` path to its convention spec, or nil when none
  # exists. Tier 0 of the plan's coverage-guided selection — cheap and exact
  # for the 1:1 majority; a full `{line -> specs}` coverage index is the
  # precise fallback (future).
  module SpecMap
    module_function

    def for(lib_path)
      spec = lib_path.sub(%r{\Alib/}, "spec/").sub(/\.rb\z/, "_spec.rb")
      File.file?(spec) ? spec : nil
    end
  end

  # The in-bundle spec runner: plain `system` so the rspec subprocess inherits
  # Rigor's OWN Bundler env (the SUT bundle is Rigor's). Output suppressed
  # unless --verbose.
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
    end

    def run(paths)
      files = expand(paths)
      guard_clean!(files)
      install_restore_trap(files)
      outcomes = files.map { |f| measure(f) }
      report(outcomes)
    end

    private

    def expand(paths)
      candidates = paths.flat_map do |p|
        File.directory?(p) ? Dir.glob(File.join(p, "**", "*.rb")) : [p]
      end
      candidates.select { |f| f.end_with?(".rb") && File.file?(f) }
    end

    # The test axis temporarily overwrites the real lib file on disk (the
    # scanner restores per-mutant in an `ensure`). Refuse to start with those
    # files already dirty so an aborted run cannot be confused with the user's
    # own edits, and so the restore trap cannot stomp uncommitted work.
    def guard_clean!(files)
      return if @options[:type_only]

      dirty = files.reject { |f| `git status --porcelain -- #{f}`.strip.empty? }
      return if dirty.empty?

      abort "self_mutate: refusing to run the test axis on dirty files (commit/stash first):\n  " \
            "#{dirty.join("\n  ")}\n(or pass --type-only, which never writes to disk)"
    end

    # Belt-and-suspenders over the scanner's per-mutant `ensure`: a hard
    # interrupt mid-suite would leave a mutant on disk, so restore the targets
    # from git on the way out.
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

      spec = @options[:type_only] ? nil : SpecMap.for(path)
      spec ? measure_fused(path, source, spec) : measure_type_only(path, source)
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

    # Fused axis: type pass, then the covering spec on each type-survivor.
    def measure_fused(path, source, spec)
      command = %w[bundle exec rspec] << spec
      oracle = Rigor::Protection::TestSuiteOracle.new(command: command, runner: @runner)
      unless oracle.green?
        warn "[skip] #{path}: covering spec #{spec} is not green on clean code — type-only"
        return measure_type_only(path, source)
      end

      warn "[fused] #{path}  (spec: #{spec})"
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

options = { config: nil, limit: nil, seed: 1, site: :all, type_only: false, json: false, verbose: false }
parser = OptionParser.new do |o|
  o.banner = "Usage: ruby tool/mutation/self_mutate.rb [options] <lib paths…>"
  o.on("--config PATH") { |v| options[:config] = v }
  o.on("--limit N", Integer) { |v| options[:limit] = v }
  o.on("--seed N", Integer) { |v| options[:seed] = v }
  o.on("--site SEL", %i[all biteable]) { |v| options[:site] = v }
  o.on("--type-only") { options[:type_only] = true }
  o.on("--json") { options[:json] = true }
  o.on("--verbose") { options[:verbose] = true }
end
paths = parser.parse(ARGV)
abort parser.help if paths.empty?

RigorSelfMutation::Driver.new(options).run(paths)
