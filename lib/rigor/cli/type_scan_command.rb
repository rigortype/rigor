# frozen_string_literal: true

require "optionparser"
require "prism"

require_relative "../environment"
require_relative "../inference/coverage_scanner"
require_relative "../scope"
require_relative "type_scan_renderer"
require_relative "type_scan_report"

module Rigor
  class CLI
    # Executes the `rigor type-scan` command.
    #
    # The command walks every Prism node in one or more files, runs
    # `Rigor::Scope#type_of` on each, and reports per-node-class coverage of
    # the inference engine's directly recognized classes. It is the project's
    # primary CI gate for tracking how much of an input source the engine can
    # name without falling back to `Dynamic[Top]`.
    class TypeScanCommand
      USAGE = "Usage: rigor type-scan [options] PATH..."

      LocatedEvent = Data.define(:file, :event)

      def initialize(argv:, out:, err:)
        @argv = argv
        @out = out
        @err = err
      end

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        paths = collect_paths(@argv)
        return CLI::EXIT_USAGE if paths.nil?
        return usage_error if paths.empty?

        report = scan_paths(paths, options)
        TypeScanRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_exit(report, options)
      end

      private

      def parse_options
        options = { format: "text", limit: 10, show_recognized: false, threshold: nil }

        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--format=FORMAT", "Output format: text or json") { |value| options[:format] = value }
          opts.on("--limit=N", Integer, "Max example events to print (text only)") do |value|
            options[:limit] = value
          end
          opts.on("--show-recognized", "Include classes with 0 unrecognized in the table") do
            options[:show_recognized] = true
          end
          opts.on("--threshold=RATIO", Float, "Exit non-zero when unrecognized/visits > RATIO") do |value|
            options[:threshold] = value
          end
        end
        parser.parse!(@argv)

        options
      end

      def collect_paths(args)
        paths = []
        args.each do |arg|
          if File.directory?(arg)
            paths.concat(Dir.glob(File.join(arg, "**/*.rb")))
          elsif File.file?(arg)
            paths << arg
          else
            @err.puts("type-scan: not a file or directory: #{arg}")
            return nil
          end
        end
        paths.uniq
      end

      def usage_error
        @err.puts("type-scan: at least one path is required")
        @err.puts(USAGE)
        CLI::EXIT_USAGE
      end

      def scan_paths(paths, options)
        scope = Scope.empty(environment: project_environment)
        scanner = Inference::CoverageScanner.new(scope: scope)
        accumulator = ScanAccumulator.new
        paths.each { |path| scan_one(path, scanner, accumulator) }
        accumulator.to_report(paths, options)
      end

      # Builds a project-aware environment that auto-detects `<cwd>/sig`
      # so calls scoped to the current project resolve through the
      # local RBS tree. Phase 2a does not yet wire stdlib opt-in here;
      # that lands when the configuration layer (`.rigor.yml`) gains an
      # `rbs:` section.
      def project_environment
        Environment.for_project
      end

      def scan_one(path, scanner, accumulator)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path)
        if parse_result.errors.any?
          accumulator.record_parse_error(path, parse_result.errors)
          return
        end

        accumulator.absorb(path, scanner.scan(parse_result.value))
      end

      def determine_exit(report, options)
        return 1 unless report.parse_errors.empty?

        threshold = options[:threshold]
        return 0 if threshold.nil?

        report.unrecognized_ratio > threshold ? 1 : 0
      end

      # Internal helper that accumulates per-file scan results into the
      # totals carried by `Report`.
      class ScanAccumulator
        def initialize
          @visits = Hash.new(0)
          @unrecognized = Hash.new(0)
          @events = []
          @parse_errors = []
        end

        def absorb(path, file_result)
          file_result.visits.each { |klass, count| @visits[klass] += count }
          file_result.unrecognized.each { |klass, count| @unrecognized[klass] += count }
          file_result.events.each do |event|
            @events << LocatedEvent.new(file: path, event: event)
          end
        end

        def record_parse_error(path, errors)
          @parse_errors << { file: path, errors: errors.map(&:message) }
        end

        def to_report(paths, options)
          Report.new(
            files: paths,
            parse_errors: @parse_errors,
            visits: @visits,
            unrecognized: @unrecognized,
            events: @events,
            options: options
          )
        end
      end
    end
  end
end
