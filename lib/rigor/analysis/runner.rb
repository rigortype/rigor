# frozen_string_literal: true

require "prism"

require_relative "../environment"
require_relative "../scope"
require_relative "../inference/scope_indexer"
require_relative "check_rules"
require_relative "diagnostic"
require_relative "result"

module Rigor
  module Analysis
    class Runner
      RUBY_GLOB = "**/*.rb"

      def initialize(configuration:)
        @configuration = configuration
      end

      # Walks every Ruby file under `paths`, parses it, builds a
      # per-node scope index through
      # `Rigor::Inference::ScopeIndexer`, and runs the
      # `Rigor::Analysis::CheckRules` catalogue over it. Returns
      # a `Rigor::Analysis::Result` aggregating every produced
      # diagnostic plus any Prism parse errors. The Environment
      # is built once at run start through `Environment.for_project`
      # so all files share the same RBS load.
      def run(paths = @configuration.paths)
        environment = Environment.for_project(
          libraries: @configuration.libraries,
          signature_paths: @configuration.signature_paths
        )
        expansion = expand_paths(paths)

        diagnostics = expansion.fetch(:errors)
        diagnostics += expansion.fetch(:files).flat_map { |path| analyze_file(path, environment) }

        Result.new(diagnostics: diagnostics)
      end

      private

      # Resolves the user-supplied path list into:
      # - `:files`  — the concrete `.rb` files to analyze.
      # - `:errors` — `Diagnostic` entries for each path that
      #   does not exist or is not a recognisable Ruby source.
      #
      # Surfacing path errors is a first-preview must-have:
      # `rigor check ./does_not_exist.rb` previously exited
      # cleanly with no output, which silently masked typos.
      def expand_paths(paths)
        files = []
        errors = []
        Array(paths).each do |path|
          if File.directory?(path)
            files.concat(Dir.glob(File.join(path, RUBY_GLOB)))
          elsif File.file?(path) && path.end_with?(".rb")
            files << path
          elsif File.exist?(path)
            errors << path_error(path, "not a Ruby file (expected `.rb` or a directory)")
          else
            errors << path_error(path, "no such file or directory")
          end
        end
        { files: files, errors: errors }
      end

      def path_error(path, message)
        Diagnostic.new(
          path: path,
          line: 1,
          column: 1,
          message: message,
          severity: :error
        )
      end

      def analyze_file(path, environment) # rubocop:disable Metrics/MethodLength
        parse_result = Prism.parse_file(path)
        return parse_diagnostics(path, parse_result) unless parse_result.errors.empty?

        scope = Scope.empty(environment: environment)
        index = Inference::ScopeIndexer.index(parse_result.value, default_scope: scope)
        CheckRules.diagnose(
          path: path,
          root: parse_result.value,
          scope_index: index,
          comments: parse_result.comments,
          disabled_rules: @configuration.disabled_rules
        )
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
      rescue StandardError => e
        [
          Diagnostic.new(
            path: path,
            line: 1,
            column: 1,
            message: "internal analyzer error: #{e.class}: #{e.message}",
            severity: :error
          )
        ]
      end

      def parse_diagnostics(path, parse_result)
        parse_result.errors.map do |error|
          location = error.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            message: error.message,
            severity: :error
          )
        end
      end
    end
  end
end
