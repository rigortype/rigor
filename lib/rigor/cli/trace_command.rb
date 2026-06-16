# frozen_string_literal: true

require "json"
require "optionparser"
require "prism"

require_relative "../configuration"
require_relative "options"
require_relative "../environment"
require_relative "../scope"
require_relative "../inference/flow_tracer"
require_relative "../inference/scope_indexer"
require_relative "command"
require_relative "trace_renderer"

module Rigor
  class CLI
    # Executes the `rigor trace` command: re-runs the inference engine
    # over one file under {Rigor::Inference::FlowTracer} and replays the
    # recorded event stream — scope binds, union formation, method
    # dispatch, and (with `--verbose`) every expression enter/result —
    # as a step-through terminal animation. A teaching probe: it shows
    # HOW Rigor arrives at a type, where `rigor type-of` shows only the
    # answer.
    #
    # The tracer is observational; this command never changes what
    # `rigor check` would infer for the same file.
    class TraceCommand < Command
      USAGE = "Usage: rigor trace [options] FILE"

      # Default frame kinds: the three teachable moments. :enter/:result
      # add one frame per literal and drown the signal; `--verbose`
      # opts into them.
      DEFAULT_KINDS = %i[bind union dispatch].freeze
      VERBOSE_KINDS = (%i[enter result] + DEFAULT_KINDS).freeze

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        file = @argv.first
        if file.nil? || @argv.size != 1
          @err.puts(USAGE)
          return CLI::EXIT_USAGE
        end
        return 1 unless file_exists?(file)

        execute(file: file, options: options)
      end

      private

      def parse_options
        options = { format: "text", delay: nil, verbose: false, line: nil, config: nil }
        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--format=FORMAT", "Output format: text (animation) or json (raw event stream)") do |value|
            options[:format] = value
          end
          opts.on("--delay=SECONDS", Float,
                  "Autoplay with SECONDS between frames (default: step on key press)") do |value|
            options[:delay] = value
          end
          opts.on("--line=N", Integer, "Only replay events whose source range starts on line N") do |value|
            options[:line] = value
          end
          opts.on("--verbose", "Include every expression enter/result frame") { options[:verbose] = true }
          Options.add_config(opts, options)
        end
        parser.parse!(@argv)
        options
      end

      def execute(file:, options:)
        configuration = Configuration.load(options.fetch(:config))
        source = File.read(file, encoding: Encoding::UTF_8)
        parse_result = Prism.parse(source, filepath: file, version: configuration.target_ruby)
        return 1 if parse_errors?(parse_result, file)

        events = record_events(parse_result.value, file, configuration)
        frames = filter(events, options)

        if options.fetch(:format) == "json"
          @out.puts(JSON.pretty_generate(frames.map { |event| event_to_h(event) }))
          return 0
        end

        if frames.empty?
          @out.puts("trace: no events to replay (try --verbose)")
          return 0
        end

        interactive = @out.respond_to?(:tty?) && @out.tty?
        TraceRenderer.new(out: @out, source: source, file: file)
                     .play(frames, delay: options.fetch(:delay), interactive: interactive)
        0
      end

      # Mirrors the single-file path `rigor type-of` takes: a
      # project-aware environment, an empty seed scope, one
      # statement-level evaluation of the whole program — but recorded
      # under the FlowTracer.
      def record_events(root, file, configuration)
        environment = Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths
        )
        scope = Scope.empty(environment: environment, source_path: file)
        Inference::FlowTracer.record { scope.evaluate(root) }
      end

      def filter(events, options)
        kinds = options.fetch(:verbose) ? VERBOSE_KINDS : DEFAULT_KINDS
        frames = events.select { |event| kinds.include?(event.kind) }
        line = options.fetch(:line)
        frames = frames.select { |event| event.location && event.location[:start_line] == line } if line
        frames
      end

      def event_to_h(event)
        {
          kind: event.kind,
          depth: event.depth,
          location: event.location,
          stack: event.stack,
          data: event.data
        }
      end

      def file_exists?(file)
        return true if File.file?(file)

        @err.puts("trace: file not found: #{file}")
        false
      end

      def parse_errors?(result, file)
        return false if result.errors.empty?

        result.errors.each { |error| @err.puts("#{file}:#{error.location.start_line}: #{error.message}") }
        true
      end
    end
  end
end
