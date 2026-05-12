# frozen_string_literal: true

require "optionparser"

require_relative "../configuration"
require_relative "../sig_gen"

module Rigor
  class CLI
    # Executes the `rigor sig-gen` command — ADR-14 slices 1–2.
    #
    # Walks the given paths (or `configuration.paths` when none
    # are supplied), classifies every reachable instance method
    # via {Rigor::SigGen::Generator}, and either prints the
    # resulting RBS skeletons / unified-style diffs (`--print`,
    # `--diff`; slice 1) or writes them to the project signature
    # tree via {Rigor::SigGen::Writer} (`--write`; slice 2).
    #
    # `--write` follows the established Ruby community
    # convention: `lib/foo/bar.rb` → `sig/foo/bar.rbs`. New
    # methods are inserted into the matching class declaration
    # just before its closing `end`; new classes are appended
    # to the file; non-existent target files are created. User-
    # authored declarations are NEVER replaced unless
    # `--overwrite` is set AND the candidate is a
    # `tighter-return`.
    #
    # Parameter policy stays at slice 1's `untyped` default;
    # `--params=observed` / `--params=observed-strict` remain
    # reserved-but-inert (rejected with a usage error so the
    # surface stays stable for slice 3).
    class SigGenCommand
      USAGE = "Usage: rigor sig-gen [options] [paths]"

      VALID_MODES = %w[print diff write].freeze
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

        candidates = SigGen::Generator.new(configuration: configuration, paths: paths).run
        mode = options.fetch(:mode).to_sym

        if mode == :write
          dispatch_write(candidates, configuration, options)
        else
          dispatch_print_or_diff(candidates, mode, options)
        end
        0
      end

      private

      def dispatch_print_or_diff(candidates, mode, options)
        SigGen::Renderer.new(out: @out).render(
          candidates: candidates,
          mode: mode,
          format: options.fetch(:format),
          selection: options.fetch(:selection)
        )
      end

      def dispatch_write(candidates, configuration, options)
        path_mapper = SigGen::PathMapper.new(configuration: configuration)
        writer = SigGen::Writer.new(path_mapper: path_mapper, overwrite: options.fetch(:overwrite))

        grouped = candidates.group_by(&:path)
        results = grouped.map { |source, group| writer.write(source, group) }

        SigGen::Renderer.new(out: @out).render_write(results: results, format: options.fetch(:format))
      end

      def parse_options
        options = {
          mode: "print",
          format: "text",
          params: "untyped",
          selection: [],
          overwrite: false,
          config: nil
        }
        build_option_parser(options).parse!(@argv)

        message = validation_error(options)
        return options if message.nil?

        @err.puts("sig-gen: #{message}")
        nil
      end

      def build_option_parser(options) # rubocop:disable Metrics/AbcSize
        OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--print", "Write RBS skeletons to stdout (default)") { options[:mode] = "print" }
          opts.on("--diff", "Write a unified diff against existing RBS") { options[:mode] = "diff" }
          opts.on("--write", "Write generated RBS to sig/<path>.rbs files") { options[:mode] = "write" }
          opts.on("--overwrite", "Allow tighter-return updates to replace user-authored RBS") do
            options[:overwrite] = true
          end
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

        return "--print, --diff, and --write are mutually exclusive flags; pick one" unless VALID_MODES.include?(mode)
        return "unsupported --format=#{format}" unless VALID_FORMATS.include?(format)
        return "unsupported --params=#{params}" unless VALID_PARAM_POLICIES.include?(params)
        return "--params=#{params} is reserved; slice 1 supports 'untyped' only" if params != "untyped"

        nil
      end
    end
  end
end
