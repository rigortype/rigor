# frozen_string_literal: true

require_relative "triage/hint"
require_relative "triage/catalogue"

module Rigor
  # ADR-23 — diagnostic triage. Aggregates a `rigor check`
  # diagnostic stream into the data behind the `rigor triage`
  # report: a rule-ID distribution, per-file hotspots, and the
  # heuristic hint catalogue ({Triage::Catalogue}).
  #
  # Pure over the diagnostic stream — no second analysis pass, no
  # analyzer internals. `Triage.analyze` is the single entry point;
  # rendering is {CLI::TriageRenderer}'s job.
  module Triage
    UNCATEGORISED = "(uncategorised)"

    Summary = Data.define(:total, :error, :warning, :info)
    RuleCount = Data.define(:rule, :count)
    Hotspot = Data.define(:file, :count, :by_rule)
    Report = Data.define(:summary, :distribution, :hotspots, :hints)

    module_function

    # @param diagnostics [Array<Analysis::Diagnostic>]
    # @param top [Integer] hotspot-file cap
    # @param hints [Boolean] run the heuristic catalogue
    # @return [Report]
    def analyze(diagnostics, top: 10, hints: true)
      Report.new(
        summary: build_summary(diagnostics),
        distribution: build_distribution(diagnostics),
        hotspots: build_hotspots(diagnostics, top),
        hints: hints ? Catalogue.recognise(diagnostics) : []
      )
    end

    # Diagnostics without a `rule` (parse errors, internal-analyzer
    # errors) bucket under a single sentinel rather than vanishing.
    def rule_key(diagnostic)
      diagnostic.qualified_rule || UNCATEGORISED
    end

    def build_summary(diagnostics)
      by_severity = diagnostics.group_by(&:severity).transform_values(&:size)
      Summary.new(
        total: diagnostics.size,
        error: by_severity.fetch(:error, 0),
        warning: by_severity.fetch(:warning, 0),
        info: by_severity.fetch(:info, 0)
      )
    end

    def build_distribution(diagnostics)
      diagnostics.group_by { |d| rule_key(d) }
                 .map { |rule, group| RuleCount.new(rule: rule, count: group.size) }
                 .sort_by { |row| [-row.count, row.rule] }
    end

    def build_hotspots(diagnostics, top)
      diagnostics.group_by(&:path)
                 .map { |path, group| hotspot_for(path, group) }
                 .sort_by { |spot| [-spot.count, spot.file] }
                 .first(top)
    end

    def hotspot_for(path, group)
      by_rule = group.group_by { |d| rule_key(d) }
                     .transform_values(&:size)
                     .sort_by { |rule, count| [-count, rule] }
                     .to_h
      Hotspot.new(file: path, count: group.size, by_rule: by_rule)
    end

    def report_to_h(report)
      {
        "summary" => {
          "total" => report.summary.total, "error" => report.summary.error,
          "warning" => report.summary.warning, "info" => report.summary.info
        },
        "distribution" => report.distribution.map { |r| { "rule" => r.rule, "count" => r.count } },
        "hotspots" => report.hotspots.map do |h|
          { "file" => h.file, "count" => h.count, "by_rule" => h.by_rule }
        end,
        "hints" => report.hints.map(&:to_h)
      }
    end
  end
end
