# frozen_string_literal: true

# `make coverage` (#3315): runs `rigor coverage --format json` in-process over Rigor's own `lib/` and holds two of
# its figures to the pins in `tool/coverage_ratchet.yml` — the precision ratio and the share of Dynamic call sites.
# The ratchet is one-sided: a figure worse than its pin by more than the slack fails; a figure better than its pin by
# more than the slack passes with a notice that prints the tighter pin lines. `--tighten` writes every figure that is
# better than its pin into the pins file, and never moves a pin the worse way.
#
# It refuses a vacuous pass: a run under another configuration than the pinned one, a summary without the fields it
# reads, a parse error, a scan below the floors, or a move in either direction so large it can only be an instrument
# change.
#
#   bundle exec ruby tool/coverage_ratchet.rb --config .rigor.gates.yml [--pins FILE] [--tighten] PATH...
#
# docs/agents/measurement.md § "The self-typing ratchet" says how to read and refresh the figures.

require "json"
require "stringio"
require "yaml"

module CoverageRatchet
  PINS = File.expand_path("coverage_ratchet.yml", __dir__)
  ROOT = File.expand_path("..", __dir__)

  # `rigor coverage --format json`'s `summary` keys the judge reads.
  FIELDS = %w[expressions_typed precise_count call_sites dynamic_call_count parse_errors].freeze

  # Ratios are compared with this tolerance, so a figure exactly on the edge of its slack does not fail on float noise.
  EPSILON = 1e-9

  # This change's own delta, as against the distance from the pin: the same scan at the merge base (its own engine,
  # from an archive) and at HEAD. Spelled out in docs/agents/measurement.md § "The self-typing ratchet".
  DELTA_COMMAND =
    "base=$(git merge-base HEAD origin/master) && rm -rf tmp/ratchet-base && mkdir -p tmp/ratchet-base && " \
    'git archive "$base" exe lib sig data plugins .rigor.dist.yml .rigor.gates.yml | tar -x -C tmp/ratchet-base && ' \
    '(cd tmp/ratchet-base && BUNDLE_GEMFILE="$OLDPWD/Gemfile" bundle exec exe/rigor coverage --config ' \
    ".rigor.gates.yml --format json lib) > tmp/ratchet-base.json && " \
    "bundle exec exe/rigor coverage --config .rigor.gates.yml --format json lib > tmp/ratchet-head.json"

  module_function

  # @param summary — the `summary` object of `rigor coverage --format json` (string keys).
  # @param config — `{ "path" => <config file, relative to the repository root>, "parameter_inference" => <value> }`.
  # @param pins — the parsed pins file.
  # @return `[ok, lines, better]`: whether the run passes, what to print, and the figures better than their pins
  #   (`name => [new pin, numerator, denominator]`).
  def judge(summary:, config:, pins:)
    failures = config_failures(config, pins)
    missing = FIELDS.reject { |field| summary[field].is_a?(Integer) }
    if missing.any?
      return [false, failure_lines(failures + ["the coverage summary lacks #{missing.join(', ')}: the instrument " \
                                               "changed"]), {}]
    end

    failures.concat(vacuity_failures(summary, pins))
    return [false, failure_lines(failures), {}] unless failures.empty?

    lines = []
    notices = []
    better = {}
    metrics(summary).each do |name, (numerator, denominator, worse)|
      figure = numerator.fdiv(denominator)
      lines << "#{name}: #{percent(figure)} (#{numerator} / #{denominator}); pin #{pin_text(pins, name)}"
      verdict, text = metric_verdict(name, figure, numerator, denominator, worse, pins)
      failures << text if verdict == :fail
      notices << text if verdict == :notice
      better[name] = [pin_value(figure, worse), numerator, denominator] if %i[notice better].include?(verdict)
    end
    return [false, lines + failure_lines(failures), better] unless failures.empty?

    [true, lines + notices.map { |notice| "  notice: #{notice}" } + ["rigor: coverage ratchet OK"], better]
  end

  def failure_lines(failures)
    ["rigor: coverage ratchet FAILED", *failures.map { |failure| "  - #{failure}" }]
  end

  # name => [numerator, denominator, the direction that is a regression]
  def metrics(summary)
    {
      "precision" => [summary["precise_count"], summary["expressions_typed"], :down],
      "dynamic_call_share" => [summary["dynamic_call_count"], summary["call_sites"], :up]
    }
  end

  def config_failures(config, pins)
    failures = []
    if config["path"] != pins.fetch("config")
      failures << "ran under #{config['path'].inspect}, but the pins are measured under #{pins.fetch('config')}: " \
                  "pass `--config #{pins.fetch('config')}`"
    end
    if config["parameter_inference"] != pins.fetch("parameter_inference")
      failures << "parameter_inference is #{config['parameter_inference'].inspect} in #{config['path']}, but the " \
                  "pins are measured with #{pins.fetch('parameter_inference').inspect}"
    end
    failures
  end

  def vacuity_failures(summary, pins)
    floors = pins.fetch("floors")
    failures = []
    failures << "#{summary['parse_errors']} file(s) did not parse" if summary["parse_errors"].positive?
    if summary["expressions_typed"] < floors.fetch("expressions")
      failures << "the scan counted #{summary['expressions_typed']} expressions, under the floor of " \
                  "#{floors.fetch('expressions')}: it visited the wrong tree or lost files"
    end
    if summary["call_sites"] < floors.fetch("call_sites")
      failures << "the scan counted #{summary['call_sites']} call sites, under the floor of " \
                  "#{floors.fetch('call_sites')}: it visited the wrong tree or the tally broke"
    end
    failures
  end

  # @return `[verdict, text]`: `:fail`, `:notice` (better past the slack), `:better` (better within it) or `:ok`.
  def metric_verdict(name, figure, numerator, denominator, worse, pins)
    entry = pins.fetch(name)
    slack = entry.fetch("slack")
    delta = figure - entry.fetch("pin")
    pin_line = "#{name}.pin: #{pin_value(figure, worse)} # #{numerator} / #{denominator}"
    worse_by = worse == :up ? delta : -delta

    if delta.abs > pins.fetch("max_step") + EPSILON
      return [:fail, "#{name} moved #{points(delta)} from its pin, more than max_step " \
                     "(#{points(pins.fetch('max_step'))}): the scan's classification or the tally changed, not the " \
                     "types. Fix the instrument; a deliberate instrument change re-pins (#{pin_line}) and says so"]
    end
    return [:fail, worse_text(name, worse_by, slack, pin_line, pins)] if worse_by > slack + EPSILON
    if -worse_by > slack + EPSILON
      return [:notice, "#{name} is #{points(worse_by)} better than its pin, past the #{points(slack)} slack. " \
                       "Tighten it in tool/coverage_ratchet.yml (or run `make coverage-tighten`): #{pin_line}"]
    end

    [worse_by.negative? ? :better : :ok, nil]
  end

  def worse_text(name, worse_by, slack, pin_line, pins)
    "#{name} is #{points(worse_by)} worse than its pin, past the #{points(slack)} slack. The distance is measured " \
      "against the pin, not against this change's base, so part of it may be earlier changes' drift. This change's " \
      "own delta is the `summary` of tmp/ratchet-head.json against tmp/ratchet-base.json after: #{DELTA_COMMAND}. " \
      "(1) If the delta is this change's, declare in sig/ what it left untyped (`rigor sig-gen --print PATH` " \
      "proposes it; the `by_file` rows of the two files show where). (2) Otherwise, or if the loss is deliberate, " \
      "moving the pin the worse way is a `gate-row` decision: an approval-queue.d/ entry of class gate-row " \
      "(docs/agents/contribution-flow.md § \"Decisions and the approval queue\"). With no earlier such move in " \
      "#{File.basename(PINS)} as precedent it is serious: ask the maintainer first. The new pin would be " \
      "#{pin_line} (config #{pins.fetch('config')})"
  end

  # Rewrites the `pin:` line of each figure in `better` (from {judge}) in the pins file at `path`.
  def tighten(path, better)
    text = File.read(path)
    better.each do |name, (pin, numerator, denominator)|
      pattern = /^(#{Regexp.escape(name)}:\n(?:[ \t]+.*\n)*?[ \t]+pin: )\S+( #.*)?$/
      text = text.sub(pattern) { "#{Regexp.last_match(1)}#{pin} # #{numerator} / #{denominator}" }
    end
    File.write(path, text)
  end

  # A pin to four decimals, rounded toward the worse side so the pin never claims more than was measured.
  def pin_value(figure, worse)
    scaled = figure * 10_000
    (worse == :down ? (scaled + EPSILON).floor : (scaled - EPSILON).ceil) / 10_000.0
  end

  def pin_text(pins, name)
    entry = pins.fetch(name)
    "#{percent(entry.fetch('pin'))} ± #{points(entry.fetch('slack'))}"
  end

  def repo_relative(path)
    Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(ROOT)).to_s
  end

  def percent(ratio) = "#{(ratio * 100).round(2)}%"

  def points(ratio) = "#{format('%.2f', (ratio * 100).abs)} points"

  def parse_argv(argv)
    options = { pins: PINS, config: nil, tighten: false, paths: [] }
    until argv.empty?
      argument = argv.shift
      case argument
      when "--pins" then options[:pins] = argv.shift
      when "--config" then options[:config] = argv.shift
      when /\A--config=(.+)\z/ then options[:config] = Regexp.last_match(1)
      when "--tighten" then options[:tighten] = true
      else options[:paths] << argument
      end
    end
    options
  end

  # Runs the scan and judges it. @return the exit status.
  def run(argv, out: $stdout)
    options = parse_argv(argv.dup)
    if options[:config].nil? || options[:paths].empty?
      out.puts("usage: tool/coverage_ratchet.rb --config FILE [--pins FILE] [--tighten] PATH...")
      return 64
    end

    require_relative "../lib/rigor"
    require_relative "../lib/rigor/cli"
    pins = YAML.safe_load_file(options[:pins])
    configuration = Rigor::Configuration.load(options[:config])
    config = { "path" => repo_relative(options[:config]), "parameter_inference" => configuration.parameter_inference }
    # Refused before the scan: under the wrong config its figures prove nothing, and the key-on scan takes minutes.
    refused = config_failures(config, pins)
    unless refused.empty?
      failure_lines(refused).each { |line| out.puts(line) }
      return 1
    end

    json = StringIO.new
    status = Rigor::CLI.start(["coverage", "--config", options[:config], "--format", "json", *options[:paths]],
                              out: json)
    ok, lines, better = judge(summary: JSON.parse(json.string).fetch("summary", {}), config: config, pins: pins)
    lines.each { |line| out.puts(line) }
    if ok && options[:tighten] && !better.empty?
      tighten(options[:pins], better)
      out.puts("rigor: tightened #{better.keys.join(', ')} in #{options[:pins]}")
    end
    ok && status.zero? ? 0 : 1
  end
end

exit(CoverageRatchet.run(ARGV)) if $PROGRAM_NAME == __FILE__
