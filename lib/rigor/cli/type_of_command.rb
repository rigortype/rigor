# frozen_string_literal: true

require "optionparser"
require "prism"

require_relative "../environment"
require_relative "../scope"
require_relative "../source/node_locator"
require_relative "../inference/fallback_tracer"
require_relative "type_of_renderer"

module Rigor
  class CLI
    # Executes the `rigor type-of` command.
    #
    # The command is a thin probe over `Rigor::Scope#type_of`: it locates the
    # deepest expression at a `(file, line, column)` triple and prints the
    # inferred type, RBS erasure, and (optionally) the recorded fail-soft
    # fallbacks.
    #
    # Encapsulating the command in its own class keeps `Rigor::CLI` focused on
    # dispatching and lets us evolve the type-of UX (extra flags, watch mode,
    # streaming output) without bloating the CLI shell. Output formatting is
    # delegated to {TypeOfRenderer}.
    class TypeOfCommand
      USAGE = "Usage: rigor type-of [options] FILE:LINE:COL"

      Result = Data.define(:file, :line, :column, :node, :type, :tracer)

      def initialize(argv:, out:, err:)
        @argv = argv
        @out = out
        @err = err
      end

      # @return [Integer] CLI exit status.
      def run
        options = parse_options

        target = parse_position_argument(@argv)
        return CLI::EXIT_USAGE if target.nil?

        execute(target: target, options: options)
      end

      private

      def parse_options
        options = { format: "text", trace: false }

        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--format=FORMAT", "Output format: text or json") { |value| options[:format] = value }
          opts.on("--trace", "Record fail-soft fallbacks via FallbackTracer") { options[:trace] = true }
        end
        parser.parse!(@argv)

        options
      end

      def execute(target:, options:)
        file, line, column = target
        return 1 unless file_exists?(file)

        source = File.read(file)
        parse_result = Prism.parse(source, filepath: file)
        return 1 if parse_errors?(parse_result, file)

        node = locate_node(source: source, root: parse_result.value, file: file, line: line, column: column)
        return CLI::EXIT_USAGE if node == :out_of_range
        return 1 if node.nil?

        tracer = options[:trace] ? Inference::FallbackTracer.new : nil
        scope = Scope.empty(environment: project_environment(file))
        type = scope.type_of(node, tracer: tracer)
        result = Result.new(file: file, line: line, column: column, node: node, type: type, tracer: tracer)

        TypeOfRenderer.new(out: @out).render(result, format: options.fetch(:format))
        0
      end

      # Builds a project-aware environment relative to the probed file.
      # Project-RBS auto-detection roots at CWD today; future work will
      # walk parent directories to find the enclosing `Gemfile`/`*.gemspec`
      # so probes against files outside the current process's CWD still
      # see the right `sig/` tree.
      def project_environment(_file)
        Environment.for_project
      end

      def file_exists?(file)
        return true if File.file?(file)

        @err.puts("type-of: file not found: #{file}")
        false
      end

      def parse_errors?(result, file)
        return false if result.errors.empty?

        result.errors.each { |error| @err.puts("#{file}:#{error.location.start_line}: #{error.message}") }
        true
      end

      def locate_node(source:, root:, file:, line:, column:)
        node = Source::NodeLocator.at_position(source: source, root: root, line: line, column: column)
        @err.puts("type-of: no expression found at #{file}:#{line}:#{column}") if node.nil?
        node
      rescue Source::NodeLocator::OutOfRangeError => e
        @err.puts("type-of: #{e.message}")
        :out_of_range
      end

      def parse_position_argument(argv)
        case argv.size
        when 1
          parse_colon_form(argv[0])
        when 3
          decode_position(*argv)
        else
          @err.puts("type-of: expected FILE:LINE:COL or FILE LINE COL")
          @err.puts(USAGE)
          nil
        end
      end

      def parse_colon_form(arg)
        parts = arg.split(":")
        if parts.size < 3
          @err.puts("type-of: expected FILE:LINE:COL, got #{arg.inspect}")
          @err.puts(USAGE)
          return nil
        end

        column = parts.pop
        line = parts.pop
        file = parts.join(":")
        decode_position(file, line, column)
      end

      def decode_position(file, line, column)
        [file, Integer(line, 10), Integer(column, 10)]
      rescue ArgumentError
        @err.puts("type-of: line and column must be integers")
        nil
      end
    end
  end
end
