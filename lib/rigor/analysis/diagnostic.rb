# frozen_string_literal: true

module Rigor
  module Analysis
    class Diagnostic
      attr_reader :path, :line, :column, :message, :severity

      def initialize(path:, line:, column:, message:, severity: :error)
        @path = path
        @line = line
        @column = column
        @message = message
        @severity = severity
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
          "message" => message
        }
      end

      def to_s
        "#{path}:#{line}:#{column}: #{severity}: #{message}"
      end
    end
  end
end
