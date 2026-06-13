#!/usr/bin/env ruby
# frozen_string_literal: true

# Mutation-testing harness for Rigor — a *prototype* for the "壊したら壊れる"
# (break-the-code / does-the-checker-bite) question.
#
# Idea: take a file Rigor currently reports clean, inject a *type-visible*
# mutation (a literal flipped to nil, a literal's type swapped, a call renamed
# to a missing method, an arg appended), re-run `rigor check` on the mutated
# SOURCE, and see whether a NEW diagnostic appears. A surviving mutant — one
# that produces no new diagnostic — is a candidate false-negative blind spot.
#
# This is NOT classic mutation testing of a test suite. A type checker only
# sees a subset of behavioural bugs, so most random mutations are equivalent
# mutants (type-invariant) and survival is *correct*. We therefore restrict
# ourselves to mutations that SHOULD be type-visible and read the survival of
# *those* as signal — effectively a teeth-regression probe over the diagnostic
# taxonomy. See tool/mutation/README.md.
#
# Efficiency (the "editor mode + cache" path): the expensive builds — the RBS
# environment and the whole-project pre-pass (ProjectScan) — are paid ONCE via
# LanguageServer::ProjectContext, then every mutant reuses them through
# `Runner.new(environment:, prebuilt:)` + `#run_source` (in-memory overlay, no
# disk write). Passing `prebuilt:` also disables the run-result cache, whose
# key digests the *disk* file — so a mutant is never served a stale clean hit.
# Marginal cost per mutant ≈ re-analysing one file's body.
#
# Run inside the Flake:
#   nix --extra-experimental-features 'nix-command flakes' develop -c \
#     bundle exec ruby tool/mutation/mutate.rb lib/rigor/<some_file>.rb
#
# Flags: --config PATH  --limit N  --seed N  --operators a,b  --dry-run  --verbose

require "optparse"
require "prism"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "rigor"
require "rigor/language_server" # ProjectContext lives here (editor-mode session)

module RigorMutation
  # One concrete edit: replace source bytes [start, stop) with `replacement`.
  Mutation = Struct.new(
    :operator, :expected_rule, :start, :stop, :replacement, :line, :label,
    keyword_init: true
  ) do
    def apply(source)
      prefix = source.byteslice(0, start)
      suffix = source.byteslice(stop, source.bytesize - stop) || ""
      "#{prefix}#{replacement}#{suffix}"
    end
  end

  # Generates type-visible mutations of a Ruby source string by walking the
  # Prism AST and recording byte-range splices (no unparser needed — Prism
  # hands us exact offsets, and the analyzer re-parses the spliced source).
  class Mutator
    IDENT = /\A[a-z_][A-Za-z0-9_]*\z/
    QUOTES = ['"', "'"].freeze

    # The operator set this prototype ships. Each maps to the diagnostic rule
    # family it is *engineered* to trip when the mutated value/call sits in a
    # context where Rigor has type knowledge.
    OPERATORS = %i[nil_inject type_swap undefined_method arity_extra].freeze

    def initialize(source, operators: OPERATORS)
      @source = source
      @operators = operators
      @parse = Prism.parse(source)
    end

    def mutations
      return [] unless @parse.success?

      out = []
      walk(@parse.value) { |node| collect(node, out) }
      out
    end

    private

    def walk(node, &blk)
      return if node.nil?

      blk.call(node)
      node.compact_child_nodes.each { |child| walk(child, &blk) }
    end

    def collect(node, out)
      case node
      when Prism::IntegerNode, Prism::FloatNode
        literal_mutations(node, out, numeric: true)
      when Prism::StringNode
        literal_mutations(node, out, numeric: false)
      when Prism::CallNode
        call_mutations(node, out)
      end
    end

    # Mutate a literal: drop it to nil (possible-nil channel) and swap its
    # type (type-mismatch channel). String literals are only touched when the
    # node is a real quoted string, so we never corrupt `%w[...]` words.
    def literal_mutations(node, out, numeric:)
      return if !numeric && !QUOTES.include?(node.opening_loc&.slice)

      loc = node.location
      add(out, :nil_inject, "flow.possible-nil", loc.start_offset, loc.end_offset,
          "nil", loc.start_line, "literal → nil  (#{snippet(loc)})")
      swap = numeric ? '"rigor_mutant"' : "0"
      add(out, :type_swap, "call.type-mismatch", loc.start_offset, loc.end_offset,
          swap, loc.start_line, "literal type swap  (#{snippet(loc)} → #{swap})")
    end

    def call_mutations(node, out)
      rename_call(node, out)
      extend_arity(node, out)
    end

    # Rename the *call site* (not the def) to a method that cannot exist, so a
    # typed receiver trips call.undefined-method. We leave `def` signatures
    # untouched on purpose: the prebuilt ProjectScan still carries the file's
    # original declarations, so mutating only bodies/call-sites keeps it valid.
    def rename_call(node, out)
      name = node.name.to_s
      mloc = node.message_loc
      return unless mloc && IDENT.match?(name)

      add(out, :undefined_method, "call.undefined-method", mloc.start_offset, mloc.end_offset,
          "#{name}__rigor_absent", mloc.start_line, "call ##{name} → missing method")
    end

    # Append a trailing argument inside explicit `(...)` parens to trip an
    # arity diagnostic against a known fixed-arity signature.
    def extend_arity(node, out)
      open = node.opening_loc
      close = node.closing_loc
      return unless close && open&.slice == "("

      args = node.arguments&.arguments
      insertion = args && !args.empty? ? ", nil" : "nil"
      add(out, :arity_extra, "call.argument-count", close.start_offset, close.start_offset,
          insertion, node.location.start_line, "call ##{node.name} +1 arg")
    end

    def add(out, operator, rule, start, stop, replacement, line, label)
      return unless @operators.include?(operator)

      out << Mutation.new(operator: operator, expected_rule: rule, start: start, stop: stop,
                          replacement: replacement, line: line, label: label)
    end

    def snippet(loc)
      text = loc.slice.gsub(/\s+/, " ")
      text.length > 30 ? "#{text[0, 27]}..." : text
    end
  end

  # Drives the warm loop: build env + scan once, analyse the baseline, then
  # each mutant, and judge kills by diagnostic-set difference.
  class Harness
    def initialize(target:, config_path:, limit:, seed:, operators:, verbose:)
      @target = target
      @config_path = config_path
      @limit = limit
      @seed = seed
      @operators = operators
      @verbose = verbose
    end

    def run
      source = File.read(@target)
      mutations = select(Mutator.new(source, operators: @operators).mutations)
      abort("no mutations generated for #{@target}") if mutations.empty?

      config = Rigor::Configuration.load(@config_path)
      ctx = build_context(config)
      baseline = signatures(analyse(config, ctx, source).diagnostics)
      puts "baseline diagnostics on #{@target}: #{baseline.size}"
      puts "mutations: #{mutations.size} (seed=#{@seed}, ops=#{@operators.join(',')})\n\n"

      records = mutations.map { |mut| evaluate(config, ctx, source, mut, baseline) }
      report(records)
    end

    private

    def select(mutations)
      shuffled = mutations.shuffle(random: Random.new(@seed))
      @limit ? shuffled.first(@limit) : shuffled
    end

    # The expensive part, paid once. ProjectContext memoises both the RBS
    # environment and the whole-project ProjectScan.
    def build_context(config)
      t = clock
      ctx = Rigor::LanguageServer::ProjectContext.new(configuration: config)
      ctx.environment
      ctx.project_scan
      puts "cold setup (env + project scan): #{ms(clock - t)} ms"
      ctx
    end

    # One analysis of `mutant_source` overlaid at @target. cache_store: nil +
    # prebuilt: scan ⇒ the run cache is bypassed and the mutant is always
    # re-analysed against the in-memory bytes.
    def analyse(config, ctx, mutant_source)
      runner = Rigor::Analysis::Runner.new(
        configuration: config,
        environment: ctx.environment,
        prebuilt: ctx.project_scan,
        cache_store: nil,
        collect_stats: false
      )
      runner.run_source(source: mutant_source, path: @target)
    end

    def evaluate(config, ctx, source, mut, baseline)
      mutant_source = mut.apply(source)
      return { mut: mut, status: :invalid, ms: 0.0, new_rules: [] } unless Prism.parse(mutant_source).success?

      t = clock
      diags = analyse(config, ctx, mutant_source).diagnostics
      elapsed = ms(clock - t)
      new_diags = diags.reject { |d| baseline.include?(sig(d)) }
      status = new_diags.empty? ? :survived : :killed
      { mut: mut, status: status, ms: elapsed, new_rules: new_diags.map(&:rule).uniq,
        expected_hit: new_diags.any? { |d| d.rule == mut.expected_rule } }
    end

    def signatures(diags)
      diags.map { |d| sig(d) }.to_set
    end

    def sig(diag)
      [diag.rule, diag.path, diag.line, diag.column, diag.message]
    end

    def report(records)
      run_records = records.reject { |r| r[:status] == :invalid }
      timings = run_records.map { |r| r[:ms] }.sort

      print_survivors(records)
      print_per_operator(records)

      killed = run_records.count { |r| r[:status] == :killed }
      survived = run_records.count { |r| r[:status] == :survived }
      invalid = records.count { |r| r[:status] == :invalid }
      total = killed + survived

      puts "\n── summary ──────────────────────────────────────────────"
      puts "analysed mutants : #{total}   (invalid/skipped: #{invalid})"
      puts "killed           : #{killed}"
      puts "survived         : #{survived}  ← false-negative candidates"
      puts "targeted kill %  : #{total.zero? ? 'n/a' : "#{(100.0 * killed / total).round(1)}%"}"
      return if timings.empty?

      puts "per-mutant ms    : median #{timings[timings.size / 2]}  p90 #{timings[(timings.size * 0.9).floor]}  max #{timings.last}"
    end

    def print_survivors(records)
      survivors = records.select { |r| r[:status] == :survived }
      return if survivors.empty? && !@verbose

      puts "── survivors (no new diagnostic) ───────────────────────"
      survivors.each do |r|
        puts format("  L%-4d %-16s %s", r[:mut].line, r[:mut].operator, r[:mut].label)
      end
      if @verbose
        puts "── killed ──────────────────────────────────────────────"
        records.select { |r| r[:status] == :killed }.each do |r|
          mark = r[:expected_hit] ? "✓expected" : "≠other"
          puts format("  L%-4d %-16s %-9s [%s] %s", r[:mut].line, r[:mut].operator, mark,
                      r[:new_rules].join(","), r[:mut].label)
        end
      end
      puts
    end

    def print_per_operator(records)
      puts "── per-operator ────────────────────────────────────────"
      records.group_by { |r| r[:mut].operator }.sort_by { |op, _| op.to_s }.each do |op, rs|
        killed = rs.count { |r| r[:status] == :killed }
        survived = rs.count { |r| r[:status] == :survived }
        invalid = rs.count { |r| r[:status] == :invalid }
        expected = rs.count { |r| r[:expected_hit] }
        puts format("  %-16s killed %-3d survived %-3d invalid %-3d  expected-rule-hit %d",
                    op, killed, survived, invalid, expected)
      end
    end

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def ms(seconds) = (seconds * 1000).round(1)
  end

  class CLI
    def self.run(argv)
      options = { config: nil, limit: nil, seed: 1, operators: Mutator::OPERATORS, dry_run: false, verbose: false }
      parser = OptionParser.new do |o|
        o.banner = "usage: bundle exec ruby tool/mutation/mutate.rb <target.rb> [options]"
        o.on("--config PATH", "Rigor config file (default: auto-discover)") { |v| options[:config] = v }
        o.on("--limit N", Integer, "sample at most N mutants") { |v| options[:limit] = v }
        o.on("--seed N", Integer, "RNG seed for sampling (default 1)") { |v| options[:seed] = v }
        o.on("--operators LIST", "comma list: #{Mutator::OPERATORS.join(',')}") do |v|
          options[:operators] = v.split(",").map(&:strip).map(&:to_sym)
        end
        o.on("--dry-run", "list mutations, don't analyse") { options[:dry_run] = true }
        o.on("--verbose", "also list killed mutants + the rule that fired") { options[:verbose] = true }
        o.on("-h", "--help") do
          puts o
          exit
        end
      end
      parser.parse!(argv)

      target = argv.shift
      abort(parser.to_s) unless target
      abort("not a file: #{target}") unless File.file?(target)

      if options[:dry_run]
        dry_run(target, options)
      else
        Harness.new(
          target: target, config_path: options[:config], limit: options[:limit],
          seed: options[:seed], operators: options[:operators], verbose: options[:verbose]
        ).run
      end
    end

    def self.dry_run(target, options)
      source = File.read(target)
      muts = Mutator.new(source, operators: options[:operators]).mutations
      muts = muts.sample(options[:limit], random: Random.new(options[:seed])) if options[:limit]
      muts.each { |m| puts format("L%-4d %-16s %s", m.line, m.operator, m.label) }
      puts "\n#{muts.size} mutations"
    end
  end
end

RigorMutation::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
