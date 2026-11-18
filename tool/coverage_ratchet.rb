# frozen_string_literal: true

# `make coverage` (#3315): runs `rigor coverage --format json` in-process over Rigor's own `lib/` and holds two of
# its figures to the pins in `tool/coverage_ratchet.yml` — the precision ratio and the share of Dynamic call sites.
# Each is a two-sided ratchet: a move past the slack fails in either direction, so a regression needs a declaration or
# a stated reason, and a gain is locked in by moving the pin.
#
# It refuses a vacuous pass: a run under another configuration than the pinned one, a summary without the fields it
# reads, a parse error, a scan below the floors, or a move so large it can only be an instrument change.
#
#   bundle exec ruby tool/coverage_ratchet.rb --config .rigor.gates.yml [--pins FILE] PATH...
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

  module_function

  # @param summary — the `summary` object of `rigor coverage --format json` (string keys).
  # @param config — `{ "path" => <config file as given>, "parameter_inference" => <the loaded value> }`.
  # @param pins — the parsed pins file.
  # @return `[ok, lines]`: whether the run passes, and what to print.
  def judge(summary:, config:, pins:)
    failures = config_failures(config, pins)
    missing = FIELDS.reject { |field| summary[field].is_a?(Integer) }
    if missing.any?
      return [false,
              failures + ["the coverage summary lacks #{missing.join(', ')}: the instrument changed"]]
    end

    failures.concat(vacuity_failures(summary, pins))
    lines = []
    unless failures.any?
      metrics(summary).each do |name, (numerator, denominator, worse)|
        figure = numerator.fdiv(denominator)
        lines << "#{name}: #{percent(figure)} (#{numerator} / #{denominator}); pin #{pin_text(pins, name)}"
        failures.concat(metric_failures(name, figure, numerator, denominator, worse, pins))
      end
    end
    lines << (failures.empty? ? "rigor: coverage ratchet OK" : "rigor: coverage ratchet FAILED")
    [failures.empty?, lines + failures.map { |failure| "  - #{failure}" }]
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

  def metric_failures(name, figure, numerator, denominator, worse, pins)
    entry = pins.fetch(name)
    pin = entry.fetch("pin")
    slack = entry.fetch("slack")
    delta = figure - pin
    return [] if delta.abs <= slack

    repin = "set `#{name}.pin` in tool/coverage_ratchet.yml to #{figure.round(4)} # #{numerator} / #{denominator}"
    if delta.abs > pins.fetch("max_step")
      return ["#{name} moved #{points(delta)} in one run, more than max_step (#{points(pins.fetch('max_step'))}): " \
              "the scan's classification or the tally changed, not the types. Fix the instrument; if the change " \
              "to it is deliberate, #{repin} and say so in the commit"]
    end

    if (delta.positive? ? :up : :down) == worse
      ["#{name} worsened by #{points(delta)}, past the #{points(slack)} slack. Declare in sig/ what the change " \
       "left untyped (`rigor sig-gen --print PATH` proposes it; the per-file `dynamic_call_count` and " \
       "`precise_ratio` of `rigor coverage --config #{pins.fetch('config')} --format json lib` show where). " \
       "If the loss is deliberate (a soundness fix that widens a type), #{repin} and give the reason in the " \
       "commit message"]
    else
      ["#{name} improved by #{points(delta)}, past the #{points(slack)} slack: lock the gain in — #{repin}"]
    end
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

  # Runs the scan and judges it. @return the exit status.
  def run(argv, out: $stdout)
    pins_path = PINS
    config_path = nil
    paths = []
    until argv.empty?
      argument = argv.shift
      case argument
      when "--pins" then pins_path = argv.shift
      when "--config" then config_path = argv.shift
      when /\A--config=(.+)\z/ then config_path = Regexp.last_match(1)
      else paths << argument
      end
    end
    if config_path.nil? || paths.empty?
      out.puts("usage: tool/coverage_ratchet.rb --config FILE [--pins FILE] PATH...")
      return 64
    end

    require_relative "../lib/rigor"
    require_relative "../lib/rigor/cli"
    pins = YAML.safe_load_file(pins_path)
    configuration = Rigor::Configuration.load(config_path)
    config = { "path" => repo_relative(config_path), "parameter_inference" => configuration.parameter_inference }
    # Refused before the scan: under the wrong config its figures prove nothing, and the key-on scan takes minutes.
    refused = config_failures(config, pins)
    unless refused.empty?
      ["rigor: coverage ratchet FAILED", *refused.map { |failure| "  - #{failure}" }].each { |line| out.puts(line) }
      return 1
    end

    json = StringIO.new
    status = Rigor::CLI.start(["coverage", "--config", config_path, "--format", "json", *paths], out: json)
    ok, lines = judge(summary: JSON.parse(json.string).fetch("summary", {}), config: config, pins: pins)
    lines.each { |line| out.puts(line) }
    ok && status.zero? ? 0 : 1
  end
end

exit(CoverageRatchet.run(ARGV.dup)) if $PROGRAM_NAME == __FILE__
