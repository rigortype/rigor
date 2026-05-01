# frozen_string_literal: true

module Rigor
  module Analysis
    class Diagnostic
      attr_reader :path, :line, :column, :message, :severity, :rule

      # `rule:` is the stable identifier (a kebab-case string)
      # of the diagnostic's source rule. It is used by the
      # configuration and the in-source `# rigor:disable <rule>`
      # suppression comment system to identify diagnostics by
      # category. Diagnostics not produced by `CheckRules`
      # (parse errors, path errors, internal analyzer errors)
      # may leave `rule` as nil and stay unsuppressible.
      # rubocop:disable Metrics/ParameterLists
      def initialize(path:, line:, column:, message:, severity: :error, rule: nil)
        # rubocop:enable Metrics/ParameterLists
        @path = path
        @line = line
        @column = column
        @message = message
        @severity = severity
        @rule = rule
      end

      def error?
        severity == :error
      end

      def to_h
        {
          "path" => path,
          "line" => line,
          "column" => column,
          "severity" => severity.to_s,
          "rule" => rule,
          "message" => message
        }
      end

      def to_s
        "#{path}:#{line}:#{column}: #{severity}: #{message}"
      end
    end
  end
end
