#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation-testing harness for Rigor — a *prototype* for the "壊したら壊れる"
# (break-the-code / does-the-checker-bite) question.
#
# Idea: take a file Rigor currently reports clean, inject a *type-visible* mutation (a literal flipped to nil, a
# literal's type swapped, a call renamed to a missing method, an arg appended), re-run `rigor check` on the mutated
# SOURCE, and see whether a NEW diagnostic appears. A surviving mutant — one that produces no new diagnostic — is a
# candidate false-negative blind spot.
#
# This is NOT classic mutation testing of a test suite. A type checker only sees a subset of behavioural bugs, so most
# random mutations are equivalent mutants (type-invariant) and survival is *correct*. We therefore restrict ourselves to
# mutations that SHOULD be type-visible and read the survival of
# *those* as signal — effectively a teeth-regression probe over the diagnostic
# taxonomy. See tool/mutation/README.md.
#
# Efficiency (the "editor mode + cache" path): the expensive builds — the RBS environment and the whole-project pre-pass
# (ProjectScan) — are paid ONCE via LanguageServer::ProjectContext, then every mutant reuses them through
# `Runner.new(environment:, prebuilt:)` + `#run_source` (in-memory overlay, no disk write). Passing `prebuilt:` also
# disables the run-result cache, whose key digests the *disk* file — so a mutant is never served a stale clean hit.
# Marginal cost per mutant ≈ re-analysing one file's body.
#
# Run inside the Flake:
#   nix --extra-experimental-features 'nix-command flakes' develop -c \
#     bundle exec ruby tool/mutation/mutate.rb lib/rigor/<some_file>.rb
#
# By default a type-aware filter (Phase 1.5) keeps only mutations whose anchor — the call receiver whose contract the
# mutation could violate — types to a concrete, non-Dynamic type. That focuses the run on sites where Rigor actually
# holds a contract; `--no-type-filter` disables it (A/B the filter).
#
# Flags: --config PATH  --limit N  --seed N  --operators a,b
#        --no-type-filter  --dry-run  --verbose

require "json"
require "optparse"
require "prism"
require "timeout"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "rigor"
require "rigor/language_server"        # ProjectContext lives here (editor-mode session)
require "rigor/protection/mutator"     # the type-visible mutator, productized into lib (ADR-63)

module RigorMutation
  # The mutation generator + type-aware filter live in `lib/` now (ADR-63 Tier 2 productized the per-file effectiveness
  # measurement). This dev harness keeps only the survivor *clustering* / sweep / fuzz tooling (dev-only per ADR-62 WD4)
  # and reuses the lib mutator so there is one source of truth. The aliases keep the rest of this file (which says
  # `Mutator` / `Mutation`) untouched.
  Mutator = Rigor::Protection::Mutator
  Mutation = Rigor::Protection::Mutation

  # Builds the warm session once: config + ProjectContext (RBS environment + whole-project ProjectScan memoised).
  # Progress goes to stderr so a sweep's `--json` stdout stays clean.
  module Session
    module_function

    def build(config_path)
      config = Rigor::Configuration.load(config_path)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ctx = Rigor::LanguageServer::ProjectContext.new(configuration: config)
      ctx.environment
      ctx.project_scan
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
      warn "cold setup (env + project scan): #{elapsed} ms"
      [config, ctx]
    end
  end

  # Analyses one file's mutants against its clean baseline over the shared warm
  # session. Reused by the single-file Harness and the multi-file Sweep.
  class Analyzer
    Result = Struct.new(:path, :records, :baseline_size, :dropped, keyword_init: true)

    def initialize(config:, ctx:, operators:, type_filter:)
      @config = config
      @ctx = ctx
      @operators = operators
      @type_filter = type_filter
    end

    # @return [Result, nil] nil when the file yields no (type-relevant) mutants.
    def run_file(path, seed:, limit:)
      # Force UTF-8: the Flake shell's default external encoding can be
      # US-ASCII, making byte-splicing a non-ASCII file raise an encoding error.
      source = File.read(path, encoding: Encoding::UTF_8)
      mutator = Mutator.new(source, operators: @operators)
      raw = mutator.mutations
      return nil if raw.empty?

      dropped = 0
      raw, dropped = mutator.filter_by_type(raw, environment: @ctx.environment, path: path) if @type_filter
      muts = sample(raw, seed, limit)
      return nil if muts.empty?

      baseline = signatures(analyse(source, path).diagnostics)
      records = muts.map { |mut| evaluate(source, path, mut, baseline) }
      Result.new(path: path, records: records, baseline_size: baseline.size, dropped: dropped)
    end

    private

    def sample(mutations, seed, limit)
      shuffled = mutations.shuffle(random: Random.new(seed))
      limit ? shuffled.first(limit) : shuffled
    end

    # cache_store: nil + prebuilt: scan ⇒ the run cache is bypassed and the
    # mutant is always re-analysed against the in-memory bytes.
    def analyse(mutant_source, path)
      runner = Rigor::Analysis::Runner.new(
        configuration: @config, environment: @ctx.environment, prebuilt: @ctx.project_scan,
        cache_store: nil, collect_stats: false
      )
      runner.run_source(source: mutant_source, path: path)
    end

    def evaluate(source, path, mut, baseline)
      mutant_source = mut.apply(source)
      return record(mut, :invalid, 0.0, []) unless Prism.parse(mutant_source).success?

      t = clock
      diags = analyse(mutant_source, path).diagnostics
      elapsed = ms(clock - t)
      new_diags = diags.reject { |d| baseline.include?(sig(d)) }
      status = new_diags.empty? ? :survived : :killed
      record(mut, status, elapsed, new_diags.map(&:rule).uniq,
             expected_hit: new_diags.any? { |d| d.rule == mut.expected_rule })
    rescue StandardError => e
      # A harness-level failure on one mutant must not abort the run.
      record(mut, :invalid, 0.0, [], error: "#{e.class}: #{e.message}")
    end

    def record(mut, status, elapsed, new_rules, expected_hit: false, error: nil)
      { mut: mut, status: status, ms: elapsed, new_rules: new_rules, expected_hit: expected_hit, error: error }
    end

    def signatures(diags) = diags.map { |d| sig(d) }.to_set
    def sig(diag) = [diag.rule, diag.path, diag.line, diag.column, diag.message]
    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def ms(seconds) = (seconds * 1000).round(1)
  end

  # Shared text formatting for a set of per-mutant records.
  module Report
    module_function

    def survivors(records, verbose:, with_path: false)
      live = records.select { |r| r[:status] == :survived }
      return if live.empty? && !verbose

      puts "── survivors (no new diagnostic) ───────────────────────"
      live.each { |r| puts "  #{site(r, with_path)} #{format('%-16s', r[:mut].operator)} #{r[:mut].label}" }
      if verbose
        puts "── killed ──────────────────────────────────────────────"
        records.select { |r| r[:status] == :killed }.each do |r|
          mark = r[:expected_hit] ? "✓expected" : "≠other"
          puts "  #{site(r,
                         with_path)} #{format('%-16s',
                                              r[:mut].operator)} #{format('%-9s',
                                                                          mark)} [#{r[:new_rules].join(',')}] #{r[:mut].label}"
        end
      end
      puts
    end

    def per_operator(records)
      puts "── per-operator ────────────────────────────────────────"
      records.group_by { |r| r[:mut].operator }.sort_by { |op, _| op.to_s }.each do |op, rs|
        puts format("  %-16s killed %-4d survived %-4d invalid %-4d  expected-rule-hit %d",
                    op, count(rs, :killed), count(rs, :survived), count(rs, :invalid),
                    rs.count { |r| r[:expected_hit] })
      end
    end

    def summary(records)
      killed = count(records, :killed)
      survived = count(records, :survived)
      total = killed + survived
      timings = records.select { |r| r[:status] != :invalid }.map { |r| r[:ms] }.sort
      puts "\n── summary ──────────────────────────────────────────────"
      puts "analysed mutants : #{total}   (invalid/skipped: #{count(records, :invalid)})"
      puts "killed           : #{killed}"
      puts "survived         : #{survived}  ← false-negative candidates"
      puts "teeth (kill %)   : #{total.zero? ? 'n/a' : "#{(100.0 * killed / total).round(1)}%"}"
      return if timings.empty?

      puts "per-mutant ms    : median #{timings[timings.size / 2]}  p90 #{timings[(timings.size * 0.9).floor]}  max #{timings.last}"
    end

    def count(records, status) = records.count { |r| r[:status] == status }

    def site(record, with_path)
      return format("L%-4d", record[:mut].line) unless with_path

      format("%-44s", "#{record[:path]}:#{record[:mut].line}")
    end
  end

  # Single-file run with a full per-mutant breakdown.
  class Harness
    def initialize(target:, config_path:, limit:, seed:, operators:, verbose:, type_filter:)
      @target = target
      @config_path = config_path
      @limit = limit
      @seed = seed
      @operators = operators
      @verbose = verbose
      @type_filter = type_filter
    end

    def run
      config, ctx = Session.build(@config_path)
      result = Analyzer.new(config: config, ctx: ctx, operators: @operators, type_filter: @type_filter)
                       .run_file(@target, seed: @seed, limit: @limit)
      abort("no type-relevant mutations for #{@target} (try --no-type-filter)") if result.nil?

      note = @type_filter ? "  (type-filter dropped #{result.dropped} non-concrete-anchor sites)" : "  (type-filter off)"
      puts "baseline diagnostics on #{@target}: #{result.baseline_size}"
      puts "mutations: #{result.records.size}#{note} (seed=#{@seed}, ops=#{@operators.join(',')})\n\n"
      Report.survivors(result.records, verbose: @verbose)
      Report.per_operator(result.records)
      Report.summary(result.records)
    end
  end

  # Corpus sweep: one warm session, every file's survivors aggregated and clustered into a ranked false-negative backlog
  # for the engine. Expand file / directory / glob arguments to a sorted, unique `.rb` list.
  module Paths
    module_function

    def expand(paths)
      paths.flat_map do |p|
        if File.directory?(p) then Dir.glob(File.join(p, "**", "*.rb"))
        elsif File.file?(p) then [p]
        else Dir.glob(p).select { |f| f.end_with?(".rb") }
        end
      end.uniq.sort
    end
  end

  class Sweep
    def initialize(paths:, config_path:, per_file:, seed:, operators:, type_filter:, json:, top:)
      @paths = paths
      @config_path = config_path
      @per_file = per_file
      @seed = seed
      @operators = operators
      @type_filter = type_filter
      @json = json
      @top = top
    end

    def run
      files = Paths.expand(@paths)
      abort("no .rb files under: #{@paths.join(' ')}") if files.empty?
      config, ctx = Session.build(@config_path)
      analyzer = Analyzer.new(config: config, ctx: ctx, operators: @operators, type_filter: @type_filter)

      records = []
      files.each_with_index do |path, i|
        warn format("[%d/%d] %s", i + 1, files.size, path)
        result = analyzer.run_file(path, seed: @seed, limit: @per_file)
        records.concat(result.records.map { |r| r.merge(path: result.path) }) if result
      end
      @json ? emit_json(records, files.size) : emit_text(records, files.size)
    end

    private

    # Cluster survivors by (operator, receiver type). A cluster is a systematic
    # blind spot: "mutating <operator> on a <receiver> never fires".
    def clusters(records)
      records.select { |r| r[:status] == :survived }
             .group_by { |r| [r[:mut].operator, cluster_type(r[:mut].anchor_type)] }
             .map { |(op, type), rs| cluster(op, type, rs) }
             .sort_by { |c| -c[:count] }
    end

    def cluster(operator, receiver, rs)
      methods = rs.map { |r| r[:mut].method_name }.compact.tally.sort_by { |_, c| -c }.first(5).map(&:first)
      { operator: operator, receiver: receiver, count: rs.size, methods: methods,
        examples: rs.first(3).map { |r| "#{r[:path]}:#{r[:mut].line}" } }
    end

    def cluster_type(type)
      return "(unresolved)" if type.nil?

      type.to_s.gsub(/"[^"]*"/, '"…"').gsub(/\b\d+\b/, "N")
    end

    def emit_text(records, file_count)
      warn "" # separate progress from the report
      puts "swept #{file_count} files, #{records.size} mutants analysed\n\n"
      Report.per_operator(records)
      Report.summary(records)
      print_clusters(clusters(records))
    end

    def print_clusters(clusters)
      puts "\n── survivor clusters (false-negative backlog, ranked) ───"
      if clusters.empty?
        puts "  none — every type-relevant mutant was killed"
        return
      end
      clusters.first(@top).each do |c|
        puts format("  %-4d %-16s recv=%s", c[:count], c[:operator], c[:receiver])
        puts "       methods: #{c[:methods].join(', ')}" unless c[:methods].empty?
        puts "       e.g. #{c[:examples].join('  ')}"
      end
      puts "  (#{clusters.size - @top} more clusters)" if clusters.size > @top
    end

    def emit_json(records, file_count)
      killed = Report.count(records, :killed)
      survived = Report.count(records, :survived)
      total = killed + survived
      payload = {
        "files" => file_count,
        "analysed" => total,
        "killed" => killed,
        "survived" => survived,
        "teeth_pct" => total.zero? ? nil : (100.0 * killed / total).round(1),
        "clusters" => clusters(records)
      }
      puts JSON.pretty_generate(payload)
    end
  end

  # Broad-fuzz mode — the soundness / robustness sibling of the teeth sweep. Not "does Rigor bite" but "can Rigor be
  # broken": stress the analyzer with aggressive, un-filtered mutation (every operator, every site) and report mutants
  # that make it CRASH (a rescued `internal analyzer error:` diagnostic), HANG (per-mutant timeout), or — with
  # `--repeat` — return NON-DETERMINISTIC diagnostics (which would break the cache's byte-identical contract,
  # ADR-45/54). A clean run finds nothing; a finding is a bug.
  class Fuzz
    CRASH_PREFIX = "internal analyzer error:"

    def initialize(paths:, config_path:, per_file:, seed:, timeout:, repeat:)
      @paths = paths
      @config_path = config_path
      @per_file = per_file
      @seed = seed
      @timeout = timeout
      @repeat = repeat
    end

    def run
      files = Paths.expand(@paths)
      abort("no .rb files under: #{@paths.join(' ')}") if files.empty?
      config, ctx = Session.build(@config_path)

      findings = []
      analysed = 0
      files.each_with_index do |path, i|
        warn format("[%d/%d] %s", i + 1, files.size, path)
        source = File.read(path, encoding: Encoding::UTF_8)
        sample(Mutator.new(source, operators: Mutator::ALL_OPERATORS).mutations).each do |mut|
          analysed += 1
          findings.concat(fuzz_one(config, ctx, source, path, mut))
        end
      end
      report(findings, files.size, analysed)
    end

    private

    def sample(mutations)
      shuffled = mutations.shuffle(random: Random.new(@seed))
      @per_file ? shuffled.first(@per_file) : shuffled
    end

    def fuzz_one(config, ctx, source, path, mut)
      mutant = mut.apply(source)
      return [] unless Prism.parse(mutant).success?

      diags = Timeout.timeout(@timeout) { analyse(config, ctx, mutant, path).diagnostics }
      crashes = diags.select { |d| d.message.to_s.start_with?(CRASH_PREFIX) }
      return crashes.map { |d| finding(:crash, path, mut, d.message) } unless crashes.empty?
      return [] unless @repeat

      again = Timeout.timeout(@timeout) { analyse(config, ctx, mutant, path).diagnostics }
      return [] if same_diagnostics?(diags, again)

      [finding(:nondeterministic, path, mut, "diagnostics differ across two identical runs")]
    rescue Timeout::Error
      [finding(:hang, path, mut, "exceeded #{@timeout}s")]
    rescue StandardError => e
      [finding(:harness_error, path, mut, "#{e.class}: #{e.message}")]
    end

    def analyse(config, ctx, mutant_source, path)
      Rigor::Analysis::Runner.new(
        configuration: config, environment: ctx.environment, prebuilt: ctx.project_scan,
        cache_store: nil, collect_stats: false
      ).run_source(source: mutant_source, path: path)
    end

    def same_diagnostics?(left, right)
      key = ->(diags) { diags.map { |d| [d.rule, d.line, d.column, d.message] }.sort }
      key.call(left) == key.call(right)
    end

    def finding(kind, path, mut, detail)
      { kind: kind, path: path, line: mut.line, operator: mut.operator, label: mut.label, detail: detail }
    end

    def report(findings, file_count, analysed)
      warn ""
      flags = "seed=#{@seed}, timeout=#{@timeout}s#{', repeat' if @repeat}"
      puts "fuzzed #{file_count} files, #{analysed} mutants (#{flags})\n\n"
      if findings.empty?
        puts "no robustness defects — no crash / hang#{' / nondeterminism' if @repeat} found"
        return
      end

      findings.group_by { |f| f[:kind] }.each { |kind, group| print_kind(kind, group) }
    end

    def print_kind(kind, group)
      puts "── #{kind} (#{group.size}) ──────────────────────────────"
      if kind == :crash
        group.group_by { |f| crash_class(f[:detail]) }.sort_by { |_, g| -g.size }.each do |klass, g|
          puts format("  %-4d %s", g.size, klass)
          g.first(3).each { |f| puts "       #{f[:path]}:#{f[:line]}  #{f[:operator]}  #{f[:label]}" }
        end
      else
        group.first(20).each { |f| puts "  #{f[:path]}:#{f[:line]}  #{f[:operator]}  #{f[:detail]}" }
        puts "  (#{group.size - 20} more)" if group.size > 20
      end
    end

    # "internal analyzer error: SomeError: msg" → "SomeError"
    def crash_class(message)
      message.to_s.sub(CRASH_PREFIX, "").strip.split(":").first&.strip || "?"
    end
  end

  class CLI
    MODES = %w[sweep fuzz].freeze

    def self.run(argv)
      mode = MODES.include?(argv.first) ? argv.shift : nil
      options = defaults
      parse(argv, options, mode: mode)
      case mode
      when "sweep" then run_sweep(argv, options)
      when "fuzz" then run_fuzz(argv, options)
      else run_single(argv, options)
      end
    end

    def self.defaults
      { config: nil, limit: nil, per_file: 40, top: 25, seed: 1, timeout: 10, repeat: false,
        operators: Mutator::OPERATORS, dry_run: false, verbose: false, type_filter: true, json: false }
    end

    def self.parse(argv, options, mode:) # rubocop:disable Metrics/AbcSize
      OptionParser.new do |o|
        o.banner = case mode
                   when "sweep" then "usage: bundle exec ruby tool/mutation/mutate.rb sweep <paths...> [options]"
                   when "fuzz" then "usage: bundle exec ruby tool/mutation/mutate.rb fuzz <paths...> [options]"
                   else "usage: bundle exec ruby tool/mutation/mutate.rb <target.rb> [options]"
                   end
        o.on("--config PATH", "Rigor config file (default: auto-discover)") { |v| options[:config] = v }
        o.on("--limit N", Integer, "single mode: sample at most N mutants") { |v| options[:limit] = v }
        o.on("--per-file N", Integer, "sweep mode: sample at most N mutants/file (default 40)") do |v|
          options[:per_file] = v
        end
        o.on("--top N", Integer, "sweep mode: show the top N survivor clusters (default 25)") { |v| options[:top] = v }
        o.on("--timeout N", Integer, "fuzz mode: per-mutant hang timeout in seconds (default 10)") do |v|
          options[:timeout] = v
        end
        o.on("--repeat", "fuzz mode: run each mutant twice and flag non-deterministic output") do
          options[:repeat] = true
        end
        o.on("--seed N", Integer, "RNG seed for sampling (default 1)") { |v| options[:seed] = v }
        o.on("--operators LIST", "comma list (default #{Mutator::OPERATORS.join(',')}; +arity_extra available)") do |v|
          options[:operators] = v.split(",").map(&:strip).map(&:to_sym)
        end
        o.on("--no-type-filter", "keep every mutation, even on Dynamic sites") { options[:type_filter] = false }
        o.on("--json", "sweep mode: emit the clustered backlog as JSON") { options[:json] = true }
        o.on("--dry-run", "single mode: list mutations, don't analyse") { options[:dry_run] = true }
        o.on("--verbose", "single mode: also list killed mutants + the rule") { options[:verbose] = true }
        o.on("-h", "--help") do
          puts o
          exit
        end
      end.parse!(argv)
    end

    def self.run_single(argv, options)
      target = argv.shift
      abort("usage: mutate.rb <target.rb> [options]  |  mutate.rb sweep <paths...>") unless target
      abort("not a file: #{target}") unless File.file?(target)

      return dry_run(target, options) if options[:dry_run]

      Harness.new(
        target: target, config_path: options[:config], limit: options[:limit],
        seed: options[:seed], operators: options[:operators], verbose: options[:verbose],
        type_filter: options[:type_filter]
      ).run
    end

    def self.run_sweep(argv, options)
      abort("sweep needs at least one path/dir/glob") if argv.empty?

      Sweep.new(
        paths: argv, config_path: options[:config], per_file: options[:per_file],
        seed: options[:seed], operators: options[:operators], type_filter: options[:type_filter],
        json: options[:json], top: options[:top]
      ).run
    end

    def self.run_fuzz(argv, options)
      abort("fuzz needs at least one path/dir/glob") if argv.empty?

      Fuzz.new(
        paths: argv, config_path: options[:config], per_file: options[:per_file],
        seed: options[:seed], timeout: options[:timeout], repeat: options[:repeat]
      ).run
    end

    def self.dry_run(target, options)
      source = File.read(target, encoding: Encoding::UTF_8)
      muts = Mutator.new(source, operators: options[:operators]).mutations
      muts = muts.sample(options[:limit], random: Random.new(options[:seed])) if options[:limit]
      muts.each { |m| puts format("L%-4d %-16s %s", m.line, m.operator, m.label) }
      puts "\n#{muts.size} mutations"
    end
  end
end

RigorMutation::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
