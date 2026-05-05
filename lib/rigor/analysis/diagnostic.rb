# frozen_string_literal: true

module Rigor
  module Analysis
    class Diagnostic
      # The default source family. Matches the existing analyzer-
      # internal rule families; serialised as `"builtin"` and is the
      # baseline against which non-default families are recognised.
      DEFAULT_SOURCE_FAMILY = :builtin

      attr_reader :path, :line, :column, :message, :severity, :rule, :source_family

      # `rule:` is the stable identifier (a kebab-case string)
      # of the diagnostic's source rule. It is used by the
      # configuration and the in-source `# rigor:disable <rule>`
      # suppression comment system to identify diagnostics by
      # category. Diagnostics not produced by `CheckRules`
      # (parse errors, path errors, internal analyzer errors)
      # may leave `rule` as nil and stay unsuppressible.
      #
      # `source_family:` names the producer of the rule. The default
      # `:builtin` covers analyzer-internal rules; future families
      # like `:rbs_extended`, `:generated`, or `"plugin.<id>"` (per
      # ADR-2 § "Plugin Diagnostic Provenance") let consumers
      # distinguish where a diagnostic originated without committing
      # to the plugin API itself.
      # rubocop:disable Metrics/ParameterLists
      def initialize(path:, line:, column:, message:, severity: :error, rule: nil,
                     source_family: DEFAULT_SOURCE_FAMILY)
        # rubocop:enable Metrics/ParameterLists
        @path = path
        @line = line
        @column = column
        @message = message
        @severity = severity
        @rule = rule
        @source_family = source_family
      end

      def error?
        severity == :error
      end

      # The fully-qualified rule identifier — `<source_family>.<rule>`
      # when the source is non-default, or just `<rule>` for the
      # `:builtin` family. Returns nil when `rule` itself is nil
      # (e.g. parse errors and internal-analyzer errors).
      def qualified_rule
        return nil if rule.nil?
        return rule if source_family == DEFAULT_SOURCE_FAMILY

        "#{source_family}.#{rule}"
      end

      def to_h
        {
          "path" => path,
          "line" => line,
          "column" => column,
          "severity" => severity.to_s,
          "rule" => rule,
          "source_family" => source_family.to_s,
          "message" => message
        }
      end

      def to_s
        "#{path}:#{line}:#{column}: #{severity}: #{message}"
      end
    end
  end
end
