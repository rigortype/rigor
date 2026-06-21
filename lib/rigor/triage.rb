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
    # A (receiver-class, method) dispatch target the diagnostics
    # cluster on, built from the structured `Diagnostic#receiver_type`
    # / `#method_name` fields — never from message-string parsing.
    # `receiver` is nil for method-only diagnostics (a toplevel call,
    # a `def`-side return / override finding that has no call
    # receiver); `files` is the distinct-file count (a systemic vs.
    # localised signal); `rules` is the per-rule breakdown.
    Selector = Data.define(:receiver, :method_name, :count, :files, :rules)
    Report = Data.define(:summary, :distribution, :selectors, :hotspots, :hints, :include_info)

    module_function

    # WD6 (ADR-23): the volume views — distribution / selectors /
    # hotspots — route only the *actionable* diagnostics (error +
    # warning) by default. Plugin-emitted `:info` diagnostics are
    # overwhelmingly recognition trace (`plugin.activerecord.model-call`,
    # `plugin.rails-routes.helper`, …) — positive "Rigor resolved this
    # call" records, not problems — and on a real Rails app they swamp
    # the genuine error/warning signal (the field trip: 257 of 267
    # diagnostics were such trace) and invert the hotspot ranking
    # towards the files with the *most working* code. The summary still
    # reports the full info count, and `include_info: true` (the
    # `--include-info` flag) restores the pre-v0.2.3 behaviour. Hints
    # always see the full stream so the `gem-without-rbs` notice (an
    # info-severity `rbs.coverage.missing-gem`) survives; the
    # count-based H5/H6 recognisers guard against info themselves so
    # recognition trace never reads as a bug.
    #
    # @param diagnostics [Array<Analysis::Diagnostic>]
    # @param top [Integer] hotspot-file cap
    # @param hints [Boolean] run the heuristic catalogue
    # @param include_info [Boolean] route info into the volume views
    # @return [Report]
    def analyze(diagnostics, top: 10, hints: true, include_info: false)
      routed = include_info ? diagnostics : diagnostics.reject { |d| d.severity == :info }
      Report.new(
        summary: build_summary(diagnostics),
        distribution: build_distribution(routed),
        selectors: build_selectors(routed),
        hotspots: build_hotspots(routed, top),
        hints: hints ? Catalogue.recognise(diagnostics, include_info: include_info) : [],
        include_info: include_info
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

    # The class/method aggregation axis (ADR-23 follow-up). Groups
    # every diagnostic that carries a `method_name` by its
    # `(receiver_type, method_name)` pair so a consumer can answer
    # "which method / class concentrates the diagnostics?" with a
    # `jq` query over the JSON instead of parsing message text.
    # Method-only diagnostics (nil `receiver_type`) keep a null
    # `receiver` and still group by method. The full list is
    # returned uncapped — the JSON is the agent-facing surface; the
    # text renderer caps its own rows.
    def build_selectors(diagnostics)
      diagnostics.select(&:method_name)
                 .group_by { |d| [normalize_receiver(d.receiver_type) || d.receiver_type, d.method_name.to_s] }
                 .map { |(receiver, method), group| selector_for(receiver, method, group) }
                 .sort_by { |s| [-s.count, s.receiver.to_s, s.method_name] }
    end

    # Folds a receiver token — a `Diagnostic#receiver_type` display
    # string or a message-parsed token — to the class the diagnostics
    # should bucket under, so the selector axis does not fragment one
    # method across every distinct literal receiver. String / integer
    # / float / symbol literals collapse to their class; `singleton(C)`
    # and a bare `C` fold to `C`; a generic `C[...]` keeps the
    # `Array[String]` element form (the AR-relation heuristic keys on
    # it). Returns nil for a token it cannot reduce to a class (a
    # union display, an inferred shape) — the caller keeps the raw
    # string then, never losing the row. Shared with {Catalogue}.
    def normalize_receiver(token)
      return nil if token.nil?

      t = token.to_s.strip
      return "Integer" if t.match?(/\A-?\d+\z/)
      return "Float"   if t.match?(/\A-?\d+\.\d+\z/)
      return "String"  if t.start_with?('"', "'")
      return "Symbol"  if t.start_with?(":")

      singleton = t[/\Asingleton\(([\w:]+)\)\z/, 1]
      return singleton if singleton
      return t if t.start_with?("Array[")

      nominal = t[/\A([\w:]+)\[/, 1]
      return nominal if nominal
      return t if t.match?(/\A[\w:]+\z/)

      nil
    end

    def selector_for(receiver, method, group)
      rules = group.group_by { |d| rule_key(d) }
                   .transform_values(&:size)
                   .sort_by { |rule, count| [-count, rule] }
                   .to_h
      Selector.new(receiver: receiver, method_name: method, count: group.size,
                   files: group.map(&:path).uniq.size, rules: rules)
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
        "selectors" => report.selectors.map do |s|
          { "receiver" => s.receiver, "method" => s.method_name, "count" => s.count,
            "files" => s.files, "rules" => s.rules }
        end,
        "hotspots" => report.hotspots.map do |h|
          { "file" => h.file, "count" => h.count, "by_rule" => h.by_rule }
        end,
        "hints" => report.hints.map(&:to_h),
        # WD6: false means distribution / selectors / hotspots above
        # exclude `:info` (their counts will not sum to summary.total);
        # the summary's `info` field still reports the full count.
        "include_info" => report.include_info
      }
    end
  end
end
