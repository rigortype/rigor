# frozen_string_literal: true

require "optionparser"
require "prism"

require_relative "../analysis/buffer_binding"
require_relative "../configuration"
require_relative "../environment"
require_relative "../scope"
require_relative "../source/node_locator"
require_relative "../inference/fallback_tracer"
require_relative "../inference/scope_indexer"
require_relative "../inference/precision_scanner"
require_relative "../source/node_children"
require_relative "type_of_renderer"
require_relative "command"
require_relative "options"
require_relative "probe_environment"

module Rigor
  class CLI
    # Executes the `rigor type-of` command.
    #
    # The command is a thin probe over `Rigor::Scope#type_of`: it locates the deepest expression at a `(file, line,
    # column)` triple and prints the inferred type, RBS erasure, and (optionally) the recorded fail-soft fallbacks.
    #
    # Encapsulating the command in its own class keeps `Rigor::CLI` focused on dispatching and lets us evolve the
    # type-of UX (extra flags, watch mode, streaming output) without bloating the CLI shell. Output formatting is
    # delegated to {TypeOfRenderer}.
    class TypeOfCommand < Command
      USAGE = "Usage: rigor type-of [options] FILE:LINE[:COL] [FILE:LINE[:COL] ...]"

      Result = Data.define(:file, :line, :column, :node, :type, :tracer, :enumeration) do
        def initialize(enumeration: nil, **rest)
          super
        end
      end

      LineEnumeration = Data.define(:total, :shown)

      # One requested position. A nil `column` means "the first 40 expressions starting on this line" — the form that
      # exists because hand-computing a column is the single most error-prone part of using this command.
      Target = Data.define(:file, :line, :column)

      # Cap on the expressions one bare `FILE:LINE` prints, so a long line cannot bury the answer.
      LINE_ENUMERATION_CAP = 40
      private_constant :LINE_ENUMERATION_CAP

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        buffer = Options.resolve_buffer_binding(options, err: @err)
        return CLI::EXIT_USAGE if buffer == :usage_error

        targets = parse_position_arguments(@argv)
        return CLI::EXIT_USAGE if targets.nil?

        execute(targets: targets, options: options, buffer: buffer)
      end

      private

      def parse_options
        options = { format: "text", trace: false, config: nil, tmp_file: nil, instead_of: nil }

        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--format=FORMAT", "Output format: text or json") { |value| options[:format] = value }
          opts.on("--trace", "Record fail-soft fallbacks via FallbackTracer") { options[:trace] = true }
          Options.add_config(opts, options)
          Options.add_editor_mode(opts, options)
        end
        parser.parse!(@argv)

        options
      end

      # One process, N positions. Every invocation used to rebuild the plugin-aware environment and reparse the
      # file for a single answer, so investigating a chain of expressions cost one process each — the dominant
      # cost of using this command in anger. The environment is now built once for the whole request and each
      # file is parsed and scope-indexed once, however many positions land in it.
      def execute(targets:, options:, buffer: nil)
        configuration = Configuration.load(options.fetch(:config))
        environment = project_environment(targets.map(&:file).uniq, configuration)
        base_scope = Scope.empty(environment: environment)

        results_by_target = Array.new(targets.length)
        targets.each_with_index.group_by { |target, _index| target.file }.each do |file, indexed_targets|
          file_results = resolve_file(file, indexed_targets, configuration, base_scope, options, buffer)
          return file_results if file_results.is_a?(Integer)

          file_results.each { |index, resolved| results_by_target[index] = resolved }
        end
        results = results_by_target.compact.flatten(1)
        return 1 if results.empty?

        TypeOfRenderer.new(out: @out).render(results, format: options.fetch(:format))
        0
      end

      # Every result for one file: parsed and indexed once, then each requested position resolved against that
      # index. Returns an Integer exit status instead when the file itself cannot be probed.
      def resolve_file(file, indexed_targets, configuration, base_scope, options, buffer)
        # Under editor mode the logical `file` may not exist on disk (user editing a new file); the runtime check
        # is only that the BUFFER is readable, which `resolve_buffer_binding` has already enforced.
        physical = buffer ? buffer.resolve(file) : file
        return 1 unless file_exists?(buffer ? physical : file)

        source = File.read(physical)
        parse_result = Prism.parse(source, filepath: file, version: configuration.target_ruby)
        return 1 if parse_errors?(parse_result, file)

        # Built with no tracer attached — it would otherwise double-record fallback events with the per-node
        # `type_of` calls below.
        scope_index = Inference::ScopeIndexer.index(parse_result.value, default_scope: base_scope)
        locator = Source::NodeLocator.new(source: source, root: parse_result.value)
        lines = indexed_targets.filter_map { |target, _index| target.line if target.column.nil? }
        line_nodes, line_totals = collect_line_nodes(parse_result.value, lines)

        resolve_targets(file: file, indexed_targets: indexed_targets, locator: locator, line_nodes: line_nodes,
                        line_totals: line_totals, scope_index: scope_index, options: options)
      end

      def resolve_targets(file:, indexed_targets:, locator:, line_nodes:, line_totals:, scope_index:, options:)
        indexed_targets.map do |target, index|
          if target.column.nil?
            resolved = enumerate_line(file, target.line, line_nodes.fetch(target.line),
                                      line_totals.fetch(target.line), scope_index, options)
            next [index, resolved]
          end

          node = locate_node(locator: locator, file: file, line: target.line, column: target.column)
          return CLI::EXIT_USAGE if node == :out_of_range
          next [index, []] if node.nil?

          [index, [type_result(file, target.line, target.column, node, scope_index, options)]]
        end
      end

      # Collect every requested line in one full syntax walk. Unlike `Source::NodeWalker`, this deliberately
      # descends into `defined?`: the probe inventories source expressions, including operands Ruby inspects but
      # does not evaluate. Candidate storage stays bounded while retaining the first 40 nodes in display order.
      def collect_line_nodes(root, lines)
        return [{}, {}] if lines.empty?

        candidates = lines.uniq.to_h { |line| [line, []] }
        totals = candidates.to_h { |line, _nodes| [line, 0] }
        walk_syntax(root) do |node|
          line = node.location.start_line
          nodes = candidates[line]
          next if nodes.nil?
          next if Inference::PrecisionScanner::NON_EXPRESSION_NODE_TYPES.include?(node.class.name)

          totals[line] += 1
          nodes << node
          trim_line_nodes(nodes) if nodes.length > LINE_ENUMERATION_CAP * 2
        end
        candidates.each_value { |nodes| trim_line_nodes(nodes) }
        [candidates, totals]
      end

      def walk_syntax(node, &block)
        return unless node.is_a?(Prism::Node)

        block.call(node)
        node.rigor_each_child { |child| walk_syntax(child, &block) }
      end

      def trim_line_nodes(nodes)
        nodes.sort_by! { |node| [node.location.start_column, -node.location.length] }
        nodes.slice!(LINE_ENUMERATION_CAP, nodes.length)
      end

      # Up to 40 expressions STARTING on `line`, outermost first at each 1-based column. This form removes
      # the column arithmetic: `rigor type-of file.rb:42` answers "what are the types on line 42" without the user
      # having to guess which byte the receiver starts at.
      def enumerate_line(file, line, nodes, total, scope_index, options)
        if nodes.empty?
          @err.puts("type-of: no expression found on #{file}:#{line}")
          return []
        end

        enumeration = LineEnumeration.new(total: total, shown: nodes.length)
        nodes.map do |node|
          type_result(file, line, node.location.start_column + 1, node, scope_index, options,
                      enumeration: enumeration)
        end
      end

      def type_result(file, line, column, node, scope_index, options, enumeration: nil)
        tracer = options[:trace] ? Inference::FallbackTracer.new : nil
        type = scope_index[node].type_of(node, tracer: tracer)
        Result.new(file: file, line: line, column: column, node: node, type: type, tracer: tracer,
                   enumeration: enumeration)
      end

      # Builds the plugin-aware environment relative to the probed file, so the reported type matches what `rigor
      # check` computes for the same position — including types synthesized from inline RBS annotations by the
      # ADR-93 auto-wired `rigor-rbs-inline` plugin (see {ProbeEnvironment} for the #162 misattribution this
      # closes). The probed file is threaded as the synthesizer's `source_files:`. Project-RBS auto-detection
      # roots at CWD today; future work will walk parent directories to find the enclosing `Gemfile`/`*.gemspec`
      # so probes against files outside the current process's CWD still see the right `sig/` tree.
      def project_environment(files, configuration)
        ProbeEnvironment.build(configuration: configuration, source_files: files)
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

      def locate_node(locator:, file:, line:, column:)
        node = locator.at_position(line: line, column: column)
        @err.puts("type-of: no expression found at #{file}:#{line}:#{column}") if node.nil?
        node
      rescue Source::NodeLocator::OutOfRangeError => e
        @err.puts("type-of: #{e.message}")
        :out_of_range
      end

      def parse_position_arguments(argv)
        if argv.empty?
          @err.puts("type-of: expected FILE:LINE[:COL] or FILE LINE COL")
          @err.puts(USAGE)
          return nil
        end

        colon = argv.map { |arg| try_colon_form(arg) }
        return colon if colon.all?
        return legacy_triple(argv) if argv.size == 3 && colon.none?
        # A single unparseable argument keeps its old, specific diagnosis ("must be integers", "expected
        # FILE:LINE:COL") rather than the generic multi-position complaint below.
        return single_colon_form(argv[0]) if argv.size == 1

        @err.puts("type-of: expected FILE:LINE[:COL] (repeatable) or FILE LINE COL, got #{argv.inspect}")
        @err.puts(USAGE)
        nil
      end

      # `FILE:LINE:COL` or `FILE:LINE`, or nil when the argument is not in either form. Silent: the caller
      # decides whether a nil means "try the three-argument form" or "report a usage error", and a probe should
      # not print a complaint about a shape it is about to accept under a different reading.
      def try_colon_form(arg)
        parts = arg.split(":")
        return nil if parts.size < 2 || !integer_literal?(parts[-1])

        # Three or more segments is the `FILE:LINE:COL` reading; if its LINE is not a number the argument is a
        # typo, not a column-less position, and must reach the specific "must be integers" diagnosis.
        if parts.size >= 3
          return nil unless integer_literal?(parts[-2])

          Target.new(file: parts[0..-3].join(":"), line: Integer(parts[-2], 10), column: Integer(parts[-1], 10))
        else
          Target.new(file: parts[0], line: Integer(parts[-1], 10), column: nil)
        end
      end

      def integer_literal?(value)
        value.match?(/\A\d+\z/)
      end

      # The pre-batch single-argument path, kept for its error messages. Returns nil after printing one.
      def single_colon_form(arg)
        position = parse_colon_form(arg)
        return nil if position.nil?

        file, line, column = position
        [Target.new(file: file, line: line, column: column)]
      end

      def legacy_triple(argv)
        position = decode_position(*argv)
        return nil if position.nil?

        file, line, column = position
        [Target.new(file: file, line: line, column: column)]
      end

      # The strict `FILE:LINE:COL` reading, used only to produce the specific error for a single unparseable
      # argument. The permissive reading (which also accepts `FILE:LINE`) is {try_colon_form}.
      def parse_colon_form(arg)
        parts = arg.split(":")
        if parts.size < 3
          @err.puts("type-of: expected FILE:LINE:COL, got #{arg.inspect}")
          @err.puts(USAGE)
          return nil
        end

        column = parts.pop
        line = parts.pop
        decode_position(parts.join(":"), line, column)
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
