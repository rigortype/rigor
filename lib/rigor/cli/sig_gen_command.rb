# frozen_string_literal: true

require "optionparser"

require_relative "../configuration"
require_relative "../sig_gen"

module Rigor
  class CLI
    # Executes the `rigor sig-gen` command — ADR-14 slice 1 MVP.
    #
    # Walks the given paths (or `configuration.paths` when none
    # are supplied), classifies every reachable instance method
    # via {Rigor::SigGen::Generator}, and prints the resulting
    # RBS skeletons (or unified-style diffs, or a JSON payload).
    #
    # The MVP supports `--print` (default) and `--diff`; the
    # `--write` mode arrives in slice 2 once the RBS-merge path
    # lands. Parameter policy is hard-coded to `untyped`; the
    # `--params` flag is parsed so the surface stays stable
    # across slices but only `untyped` is wired today.
    class SigGenCommand
      USAGE = "Usage: rigor sig-gen [options] [paths]"

      VALID_MODES = %w[print diff].freeze
      VALID_PARAM_POLICIES = %w[untyped observed observed-strict].freeze
      VALID_FORMATS = %w[text json].freeze

      def initialize(argv:, out:, err:)
        @argv = argv
        @out = out
        @err = err
      end

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        return CLI::EXIT_USAGE if options.nil?

        configuration = Configuration.load(options.fetch(:config))
        paths = @argv.empty? ? configuration.paths : @argv

        generator = SigGen::Generator.new(configuration: configuration, paths: paths)
        candidates = generator.run

        renderer = SigGen::Renderer.new(out: @out)
        renderer.render(
          candidates: candidates,
          mode: options.fetch(:mode).to_sym,
          format: options.fetch(:format),
          selection: options.fetch(:selection)
        )
        0
      end

      private

      def parse_options
        options = {
          mode: "print",
          format: "text",
          params: "untyped",
          selection: [],
          config: nil
        }
        build_option_parser(options).parse!(@argv)

        message = validation_error(options)
        return options if message.nil?

        @err.puts("sig-gen: #{message}")
        nil
      end

      def build_option_parser(options)
        OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--print", "Write RBS skeletons to stdout (default)") { options[:mode] = "print" }
          opts.on("--diff", "Write a unified diff against existing RBS") { options[:mode] = "diff" }
          opts.on("--format=FORMAT", "Output format: text or json") { |value| options[:format] = value }
          opts.on("--params=POLICY", "Parameter policy: untyped (default), observed, observed-strict") do |value|
            options[:params] = value
          end
          opts.on("--new-files", "Emit only new-file classifications") do
            options[:selection] << SigGen::Classification::NEW_FILE
          end
          opts.on("--new-methods", "Emit only new-method classifications") do
            options[:selection] << SigGen::Classification::NEW_METHOD
          end
          opts.on("--tighter-returns", "Emit only tighter-return classifications") do
            options[:selection] << SigGen::Classification::TIGHTER_RETURN
          end
          opts.on("--config=PATH", "Path to the Rigor configuration file") { |value| options[:config] = value }
        end
      end

      def validation_error(options)
        mode = options.fetch(:mode)
        format = options.fetch(:format)
        params = options.fetch(:params)

        return "--print and --diff are mutually exclusive flags; pick one" unless VALID_MODES.include?(mode)
        return "unsupported --format=#{format}" unless VALID_FORMATS.include?(format)
        return "unsupported --params=#{params}" unless VALID_PARAM_POLICIES.include?(params)
        return "--params=#{params} is reserved; slice 1 supports 'untyped' only" if params != "untyped"

        nil
      end
    end
  end
end
