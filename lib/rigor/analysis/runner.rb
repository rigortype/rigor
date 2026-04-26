# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    class Runner
      RUBY_GLOB = "**/*.rb"

      def initialize(configuration:)
        @configuration = configuration
      end

      def run(paths = @configuration.paths)
        diagnostics = expand_paths(paths).flat_map do |path|
          analyze_file(path)
        end

        Result.new(diagnostics: diagnostics)
      end

      private

      def expand_paths(paths)
        Array(paths).flat_map do |path|
          if File.directory?(path)
            Dir.glob(File.join(path, RUBY_GLOB))
          elsif File.file?(path) && path.end_with?(".rb")
            path
          else
            []
          end
        end
      end

      def analyze_file(path)
        result = Prism.parse_file(path)

        result.errors.map do |error|
          location = error.location

          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: error.message,
            severity: :error
          )
        end
      rescue Errno::ENOENT => e
        [
          Diagnostic.new(
            path: path,
            line: 1,
            column: 1,
            message: e.message,
            severity: :error
          )
        ]
      end
    end
  end
end
