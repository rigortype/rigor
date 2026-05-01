# frozen_string_literal: true

require "prism"

require_relative "../environment"
require_relative "../scope"
require_relative "../inference/coverage_scanner"
require_relative "../inference/scope_indexer"
require_relative "../inference/method_dispatcher/file_folding"
require_relative "check_rules"
require_relative "diagnostic"
require_relative "result"

module Rigor
  module Analysis
    class Runner # rubocop:disable Metrics/ClassLength
      RUBY_GLOB = "**/*.rb"

      def initialize(configuration:, explain: false)
        @configuration = configuration
        @explain = explain
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
        Inference::MethodDispatcher::FileFolding.fold_platform_specific_paths =
          @configuration.fold_platform_specific_paths

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
        diagnostics = CheckRules.diagnose(
          path: path,
          root: parse_result.value,
          scope_index: index,
          comments: parse_result.comments,
          disabled_rules: @configuration.disabled_rules
        )
        diagnostics + explain_diagnostics(path, parse_result.value, scope)
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

      # v0.0.2 #10 — fail-soft fallback explanation. When
      # `--explain` is set the runner additionally walks the
      # file with `Rigor::Inference::CoverageScanner` and emits
      # one `:info` diagnostic per directly-unrecognized node,
      # naming the node class and the type the engine fell back
      # to. The CoverageScanner is the canonical "first-event-
      # per-node" probe: it already filters out pass-through
      # wrappers (`ProgramNode`, `StatementsNode`,
      # `ParenthesesNode`) so the explain stream is attributable
      # to the leaf node that actually triggered the fallback.
      def explain_diagnostics(path, root, scope)
        return [] unless @explain

        result = Inference::CoverageScanner.new(scope: scope).scan(root)
        result.events.map { |event| explain_diagnostic(path, event) }
      end

      def explain_diagnostic(path, event)
        location = event.location
        line = location ? location.start_line : 1
        column = location ? location.start_column + 1 : 1
        Diagnostic.new(
          path: path,
          line: line,
          column: column,
          message: "fail-soft fallback at #{event.node_class}: #{event.inner_type.describe(:short)}",
          severity: :info,
          rule: "fallback"
        )
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
