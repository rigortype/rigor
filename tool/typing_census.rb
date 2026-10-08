#!/usr/bin/env ruby
# frozen_string_literal: true

# Typing census (ADR-119 WD7(f)): the (class, method) pairs whose user-method return inference answers nothing
# (`ExpressionTyper#try_user_method_inference` returns nil, so the call falls through to `Dynamic`) under the head
# engine and not under the base engine, over one corpus.
#
# ## Why an instrument, not `rigor coverage` or `rigor type-of`
#
# `rigor coverage` seeds from `DiscoverySeed.discovery_tables` and `rigor type-of` reads every cross-file declaration
# as `Dynamic[top]` (`docs/agents/measurement.md`), so neither sees what `rigor check --no-cache` itself answers.
# This tool counts the answers of the engine's own scopes.
#
# ## Method
#
# As `tool/engine_diag_diff.rb`: each engine revision is archived whole (`lib data plugins`) and run in its own FRESH
# child process (`--measure`) over the corpus, `rigor check --no-cache --workers 0` (the counters are process-local
# and do not cross a `fork`). The child prepends a module over `try_user_method_inference` that records, per
# `(receiver class, method name)`, how many calls were typed and how many answered nil. Only calls whose receiver
# `user_inference_receiver?` admits reach the method, so the census is of project-class receivers. A pair's typed /
# untyped counts are over every call site, so one pair can be both.
#
# ## Output
#
# Totals per engine, then the pairs the base typed at least once and the head typed never (`lost`), and the pairs the
# head types and the base did not (`gained`), each with its counts. `--classes REGEX` adds the number of lost pairs
# whose class matches, for a stated count over a named set (GitLab's core models). `--json FILE` writes everything.
#
# Usage:
#   ruby tool/typing_census.rb --base REV --head REV --corpus-dir DIR [--target PATH]... [--classes REGEX] [--json FILE]
#   ruby tool/typing_census.rb --measure ENGINE_DIR CORPUS_DIR TARGET...   # internal: one fresh-process run

require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "stringio"
require "tmpdir"

require_relative "engine_alloc_ab"

module TypingCensus
  ROOT = EngineAllocAB::ROOT

  # Prepended over `Rigor::Inference::ExpressionTyper`; counts `[class_name, method_name] => [typed, untyped]`.
  module Instrument
    COUNTS = Hash.new { |hash, key| hash[key] = [0, 0] }
    private_constant :COUNTS

    def self.counts = COUNTS

    private

    def try_user_method_inference(receiver, call_node, *rest, **options)
      result = super
      if user_inference_receiver?(receiver)
        name = options[:method_name] || call_node.name
        COUNTS[[receiver.class_name.to_s, name.to_s]][result.nil? ? 1 : 0] += 1
      end
      result
    end
  end

  module_function

  # One engine over one corpus, in THIS process. Only ever called in a `--measure` child.
  def measure(engine_dir, corpus_dir, targets)
    $LOAD_PATH.unshift(File.join(engine_dir, "lib"))
    require "rigor/cli"
    require "rigor/inference/expression_typer"
    Rigor::Inference::ExpressionTyper.prepend(Instrument)

    out = StringIO.new
    err = StringIO.new
    Dir.chdir(corpus_dir) do
      status = run_check(targets, out, err)
      unless EngineAllocAB::COMPLETED_EXITS.include?(status)
        abort("rigor check exited #{status.inspect} under #{engine_dir}:\n#{err.string}")
      end
      EngineAllocAB.assert_engine_loads(engine_dir)
      Instrument.counts.map { |(klass, name), (typed, untyped)| [klass, name, typed, untyped] }
    end
  end

  def run_check(targets, out, err)
    Rigor::CLI.new(["check", "--no-cache", "--no-stats", "--workers", "0", "--format", "json", *targets], out: out,
                                                                                                          err: err).run
  rescue SystemExit => e
    e.status
  end

  # `{ lost:, gained:, totals: }` over two measurements (arrays of `[class, name, typed, untyped]`).
  def compare(base, head)
    b = index(base)
    h = index(head)
    lost = typed_only_in(b, h).map { |key, v| row(key, v, h[key]) }
    gained = typed_only_in(h, b).map { |key, v| row(key, b[key], v) }
    { lost: lost.sort_by { |r| r[:pair] }, gained: gained.sort_by { |r| r[:pair] },
      totals: { base: totals(b), head: totals(h) } }
  end

  # The pairs `side` types at least once that `other` never types.
  def typed_only_in(side, other)
    side.select { |key, (typed, _)| typed.positive? && other.fetch(key, [0, 0])[0].zero? }
  end

  def index(rows) = rows.to_h { |klass, name, typed, untyped| [[klass, name], [typed, untyped]] }

  def row(key, base, head)
    { pair: key, base: base || [0, 0], head: head || [0, 0] }
  end

  def totals(index)
    { pairs: index.size, typed_calls: index.values.sum { |v| v[0] }, untyped_calls: index.values.sum { |v| v[1] },
      untyped_only_pairs: index.count { |_, v| v[0].zero? } }
  end

  # rubocop:disable-next-line Metrics/AbcSize -- one report, one straight run of lines
  def render(result, classes)
    lines = ["### Typing census (`try_user_method_inference`)", ""]
    result[:totals].each do |side, t|
      lines << "- #{side}: #{t[:pairs]} pairs, #{t[:typed_calls]} typed calls, #{t[:untyped_calls]} untyped calls, " \
               "#{t[:untyped_only_pairs]} pairs never typed"
    end
    lines << "" << "Lost (the base typed the pair, the head never does): #{result[:lost].size}"
    result[:lost].each do |r|
      lines << "- #{r[:pair].join('#')} base typed/nil #{r[:base].inspect} -> head #{r[:head].inspect}"
    end
    lines << "" << "Gained (the head types the pair, the base never did): #{result[:gained].size}"
    result[:gained].each do |r|
      lines << "- #{r[:pair].join('#')} base #{r[:base].inspect} -> head typed/nil #{r[:head].inspect}"
    end
    if classes
      matched = result[:lost].count { |r| r[:pair][0].match?(classes) }
      lines << "" << "Lost pairs whose class matches `#{classes.source}`: #{matched} of #{result[:lost].size}"
    end
    lines.join("\n")
  end

  def run_child(engine_dir, corpus_dir, targets)
    command = [RbConfig.ruby, File.expand_path(__FILE__), "--measure", engine_dir, corpus_dir, *targets]
    raw, status = Open3.capture2(*command, chdir: ROOT)
    abort("engine run for #{engine_dir} failed (#{status.inspect})") unless status.success?
    JSON.parse(raw.lines.last)
  end

  def run(options)
    Dir.mktmpdir("rigor-typing-census") do |scratch|
      tmp = File.realpath(scratch)
      corpus = File.realpath(options.fetch(:corpus_dir))
      base_dir = File.join(tmp, "base")
      head_dir = File.join(tmp, "head")
      EngineAllocAB.materialise(options.fetch(:base), base_dir, EngineAllocAB::ENGINE_PATHS)
      EngineAllocAB.materialise(options.fetch(:head), head_dir, EngineAllocAB::ENGINE_PATHS)
      targets = options.fetch(:targets)
      result = compare(run_child(base_dir, corpus, targets), run_child(head_dir, corpus, targets))
      puts render(result, options[:classes])
      File.write(options[:json], JSON.pretty_generate(result)) if options[:json]
      0
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV.first == "--measure"
    _, engine_dir, corpus_dir, *targets = ARGV
    puts JSON.generate(TypingCensus.measure(engine_dir, corpus_dir, targets))
    exit 0
  end

  options = { targets: [] }
  OptionParser.new do |parser|
    parser.on("--base REV") { |v| options[:base] = v }
    parser.on("--head REV") { |v| options[:head] = v }
    parser.on("--corpus-dir DIR") { |v| options[:corpus_dir] = v }
    parser.on("--target PATH") { |v| options[:targets] << v }
    parser.on("--classes REGEX") { |v| options[:classes] = Regexp.new(v) }
    parser.on("--json FILE") { |v| options[:json] = v }
  end.parse!
  abort("--base, --head and --corpus-dir are required") unless options[:base] && options[:head] && options[:corpus_dir]
  options[:targets] = ["lib"] if options[:targets].empty?
  exit TypingCensus.run(options)
end
