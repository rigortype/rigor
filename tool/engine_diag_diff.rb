#!/usr/bin/env ruby
# frozen_string_literal: true

# Cross-commit diagnostic differential (ADR-119 WD2, "The `SourceArity` differential"): the base engine and the
# head engine each run `rigor check` over the SAME corpus, and the diagnostic rows the head adds or drops are
# printed, filtered to one rule when asked. The `call.wrong-arity` use: after a change to `SourceArity`'s decision
# point the head's firings must be a subset of the base's, and each firing the change removes is adjudicated.
#
# ## Why two commits, not a flag
#
# An in-tree oracle would freeze the old decision code but still read the live scope, resolution chain and discovery
# tables, which the same change moves; its answers would drift with the change and the comparison would pass
# against itself. Two engines, each archived whole from its own revision (`lib data plugins`), share nothing.
#
# ## Method
#
# As `tool/engine_alloc_ab.rb`: `git archive` each engine revision into its own directory and the corpus (a revision,
# default the head's, or `--corpus-dir DIR` in place, for a survey checkout) into another, and run each engine in a
# FRESH child process (`--measure`) that puts the engine's `lib` first on the load path, changes into the corpus and
# runs one in-process `rigor check --no-cache --format json`. Afterwards it proves no Rigor file loaded from this
# checkout instead of the engine. Rows are keyed by [path, line, column, rule, message], the normalisation
# `rigor check --verify-incremental` compares by.
#
# ## Verdict
#
# Prints the rows only the base has (removed) and only the head has (added). Exits non-zero when a removed row of
# the filtered rule is missing from the `--adjudication` file (a YAML list of {path, line, column, message,
# verdict: fp-silenced | tp-lost, reason}; no file means an empty list), when an engine run fails, or when the base
# has fewer filtered rows than `--require-base-rows`, so a corpus that stopped firing cannot pass by reporting
# nothing. Added rows never fail the run, but each must be named in the PR: a head firing outside the base's is
# allowed only for a mechanism the change names.
#
# Usage:
#   ruby tool/engine_diag_diff.rb --base REV --head REV [--corpus REV | --corpus-dir DIR] [--target PATH]
#                                 [--rule RULE] [--adjudication FILE] [--require-base-rows N] [--summary FILE]
#   ruby tool/engine_diag_diff.rb --measure ENGINE_DIR CORPUS_DIR TARGET   # internal: one fresh-process run

require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"

require_relative "engine_alloc_ab"

module EngineDiagDiff
  ROOT = EngineAllocAB::ROOT
  KEY_FIELDS = %w[path line column rule message].freeze
  VERDICTS = %w[fp-silenced tp-lost].freeze
  ADJUDICATION_KEY = %w[path line column message].freeze

  module_function

  # One engine over one corpus, in THIS process. Only ever called in a `--measure` child.
  def measure(engine_dir, corpus_dir, target)
    $LOAD_PATH.unshift(File.join(engine_dir, "lib"))
    require "rigor/cli"

    out = StringIO.new
    err = StringIO.new
    Dir.chdir(corpus_dir) do
      status = EngineAllocAB.run_check(target, out, err)
      document = parse(out.string)
      unless EngineAllocAB::COMPLETED_EXITS.include?(status) && document
        abort("rigor check exited #{status.inspect} with #{document ? 'parseable' : 'unparseable'} output " \
              "under #{engine_dir}:\n#{err.string}")
      end
      EngineAllocAB.assert_engine_loads(engine_dir)
      rows(document)
    end
  end

  def parse(json)
    JSON.parse(json)
  rescue StandardError
    nil
  end

  # The diagnostics of a `--format json` document, as keyed rows in a total order.
  def rows(document)
    document.fetch("diagnostics").map { |hash| KEY_FIELDS.map { |field| hash[field] } }.sort_by do |path, line, column, rule, message|
      [path.to_s, line.to_i, column.to_i, rule.to_s, message.to_s]
    end
  end

  def filter(rows, rule)
    rule.nil? ? rows : rows.select { |row| row[3] == rule }
  end

  # `{ added:, removed: }`: the rows only the head has, and only the base has. Multiset-exact, so two identical
  # rows on one side and one on the other is one difference.
  def diff(base_rows, head_rows)
    { added: subtract(head_rows, base_rows), removed: subtract(base_rows, head_rows) }
  end

  def subtract(rows, others)
    remaining = others.tally
    rows.reject do |row|
      next false unless remaining.fetch(row, 0).positive?

      remaining[row] -= 1
      true
    end
  end

  # The adjudication entries, validated: a verdict outside {VERDICTS} or a missing reason is an error, because an
  # entry that says nothing adjudicates nothing.
  def load_adjudication(path)
    return [] if path.nil?

    entries = YAML.safe_load_file(path) || []
    raise ArgumentError, "#{path}: expected a YAML list" unless entries.is_a?(Array)

    entries.each_with_index.map { |entry, index| validate_entry(entry, index, path) }
  end

  def validate_entry(entry, index, path)
    label = "#{path}[#{index}]"
    raise ArgumentError, "#{label}: expected a mapping" unless entry.is_a?(Hash)

    missing = ADJUDICATION_KEY.reject { |key| entry.key?(key) }
    raise ArgumentError, "#{label}: missing #{missing.join(', ')}" unless missing.empty?
    raise ArgumentError, "#{label}: verdict must be one of #{VERDICTS.join(' | ')}" unless VERDICTS.include?(entry["verdict"])
    raise ArgumentError, "#{label}: a reason is required" if entry["reason"].to_s.strip.empty?

    entry
  end

  # Splits removed rows into the adjudicated (paired with their entry) and the rest.
  def adjudicate(removed, entries)
    index = entries.to_h { |entry| [ADJUDICATION_KEY.map { |key| entry[key] }, entry] }
    adjudicated, unadjudicated = removed.partition { |row| index.key?(row_key(row)) }
    { adjudicated: adjudicated.map { |row| [row, index.fetch(row_key(row))] }, unadjudicated: unadjudicated }
  end

  def row_key(row)
    path, line, column, _rule, message = row
    [path, line, column, message]
  end

  def format_row(row)
    path, line, column, rule, message = row
    "#{path}:#{line}:#{column} [#{rule}] #{message}"
  end

  # The report and the exit status. Pure: takes both engines' rows.
  def report(base_rows:, head_rows:, rule:, entries:, require_base_rows: 0)
    base = filter(base_rows, rule)
    head = filter(head_rows, rule)
    changes = diff(base, head)
    verdicts = adjudicate(changes[:removed], entries)
    problems = []
    problems << "the base has #{base.size} #{rule || 'diagnostic'} row(s), fewer than the required #{require_base_rows}" if base.size < require_base_rows
    unless verdicts[:unadjudicated].empty?
      problems << "#{verdicts[:unadjudicated].size} removed row(s) without an adjudication"
    end
    { text: render(base, head, changes, verdicts, rule, problems), ok: problems.empty? }
  end

  def render(base, head, changes, verdicts, rule, problems)
    lines = ["### Diagnostic differential#{" (`#{rule}`)" if rule}", "",
             "Base #{base.size} row(s), head #{head.size}: #{changes[:removed].size} removed, " \
             "#{changes[:added].size} added.", ""]
    section(lines, "Removed, adjudicated", verdicts[:adjudicated].map { |row, e| "#{format_row(row)} — #{e['verdict']}: #{e['reason']}" })
    section(lines, "Removed, NOT adjudicated", verdicts[:unadjudicated].map { |row| format_row(row) })
    section(lines, "Added (each must be named by the change)", changes[:added].map { |row| format_row(row) })
    counts = verdicts[:adjudicated].map { |_, entry| entry["verdict"] }.tally
    lines << "Adjudicated: #{VERDICTS.map { |verdict| "#{counts.fetch(verdict, 0)} #{verdict}" }.join(', ')}." << ""
    problems.each { |problem| lines << "**FAILED:** #{problem}." }
    lines.join("\n")
  end

  def section(lines, title, items)
    return if items.empty?

    lines << "**#{title}**" << ""
    items.each { |item| lines << "- #{item}" }
    lines << ""
  end

  def run_child(engine_dir, corpus_dir, target)
    raw, status = Open3.capture2(RbConfig.ruby, File.expand_path(__FILE__), "--measure", engine_dir, corpus_dir, target,
                                 chdir: ROOT)
    abort("engine run for #{engine_dir} failed (#{status.inspect})") unless status.success?
    JSON.parse(raw.lines.last)
  end

  def run(options)
    entries = load_adjudication(options[:adjudication])
    Dir.mktmpdir("rigor-diag-diff") do |scratch|
      tmp = File.realpath(scratch)
      corpus = options[:corpus_dir] ? File.realpath(options[:corpus_dir]) : File.join(tmp, "corpus")
      EngineAllocAB.materialise(options[:corpus] || options.fetch(:head), corpus) unless options[:corpus_dir]
      base_dir = File.join(tmp, "base")
      head_dir = File.join(tmp, "head")
      EngineAllocAB.materialise(options.fetch(:base), base_dir, EngineAllocAB::ENGINE_PATHS)
      EngineAllocAB.materialise(options.fetch(:head), head_dir, EngineAllocAB::ENGINE_PATHS)
      result = report(base_rows: run_child(base_dir, corpus, options.fetch(:target)),
                      head_rows: run_child(head_dir, corpus, options.fetch(:target)),
                      rule: options[:rule], entries: entries, require_base_rows: options.fetch(:require_base_rows))
      puts result[:text]
      File.write(options[:summary], "#{result[:text]}\n", mode: "a") if options[:summary]
      result[:ok] ? 0 : 1
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.first == "--measure"
    _, engine_dir, corpus_dir, target = ARGV
    puts JSON.generate(EngineDiagDiff.measure(engine_dir, corpus_dir, target))
    exit 0
  end

  options = { target: "lib", require_base_rows: 0 }
  OptionParser.new do |parser|
    parser.on("--base REV") { |v| options[:base] = v }
    parser.on("--head REV") { |v| options[:head] = v }
    parser.on("--corpus REV") { |v| options[:corpus] = v }
    parser.on("--corpus-dir DIR") { |v| options[:corpus_dir] = v }
    parser.on("--target PATH") { |v| options[:target] = v }
    parser.on("--rule RULE") { |v| options[:rule] = v }
    parser.on("--adjudication FILE") { |v| options[:adjudication] = v }
    parser.on("--require-base-rows N", Integer) { |v| options[:require_base_rows] = v }
    parser.on("--summary PATH") { |v| options[:summary] = v }
  end.parse!
  abort("--base and --head are required") unless options[:base] && options[:head]
  abort("--corpus and --corpus-dir are exclusive") if options[:corpus] && options[:corpus_dir]
  exit EngineDiagDiff.run(options)
end
