# frozen_string_literal: true

require "optionparser"
require "prism"

require_relative "../configuration"
require_relative "options"
require_relative "../environment"
require_relative "../inference/coverage_scanner"
require_relative "../scope"
require_relative "type_scan_renderer"
require_relative "type_scan_report"
require_relative "command"
require_relative "probe_environment"
require_relative "coverage_scan"

module Rigor
  class CLI
    # Executes the `rigor type-scan` command.
    #
    # The command walks every Prism node in one or more files, runs `Rigor::Scope#type_of` on each, and reports
    # per-node-class coverage of the inference engine's directly recognized classes. It is the project's primary CI gate
    # for tracking how much of an input source the engine can name without falling back to `Dynamic[Top]`.
    class TypeScanCommand < Command
      USAGE = "Usage: rigor type-scan [options] PATH..."

      LocatedEvent = Data.define(:file, :event)

      # @rbs return: Integer -- CLI exit status.
      def run
        options = parse_options
        paths = collect_paths(@argv, command_name: "type-scan")
        return CLI::EXIT_USAGE if paths.nil?
        return usage_error if paths.empty?

        report = scan_paths(paths, options)
        TypeScanRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_exit(report, options)
      end

      private

      def parse_options
        options = { format: "text", limit: 10, show_recognized: false, threshold: nil,
                    config: nil }

        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--format=FORMAT", "Output format: text or json") { |value| options[:format] = value }
          Options.add_config(opts, options)
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

      def usage_error
        @err.puts("type-scan: at least one path is required")
        @err.puts(USAGE)
        CLI::EXIT_USAGE
      end

      def scan_paths(paths, options)
        configuration = Configuration.load(options.fetch(:config))
        # Same seed set as `rigor coverage` and `coverage --protection` (#502). Without it a cross-file class
        # constant reads `Dynamic` and is counted as an unrecognised node, so the scan reports the engine as
        # blinder than it is — on Mastodon that alone was most of a 14.7% unrecognised rate.
        scope = CoverageScan.discovery_seeded_scope(
          files: paths,
          configuration: configuration,
          environment: project_environment(configuration, paths),
          parameter_inference: configuration.parameter_inference
        )
        scanner = Inference::CoverageScanner.new(scope: scope)
        accumulator = ScanAccumulator.new
        paths.each { |path| scan_one(path, scanner, accumulator, configuration) }
        accumulator.to_report(paths, options)
      end

      # Builds the plugin-aware environment that auto-detects `<cwd>/sig` by default and honours the
      # configuration's `libraries:` / `signature_paths:` keys when present. The scanned `paths` are threaded as
      # the plugin `source_rbs_synthesizer` inputs so coverage reflects the same synthesized RBS `rigor check`
      # sees (see {ProbeEnvironment}).
      def project_environment(configuration, source_files)
        ProbeEnvironment.build(configuration: configuration, source_files: source_files)
      end

      def scan_one(path, scanner, accumulator, configuration)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
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

      # Internal helper that accumulates per-file scan results into the totals carried by `Report`.
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
