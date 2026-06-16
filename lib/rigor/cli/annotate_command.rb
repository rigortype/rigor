# frozen_string_literal: true

require "English"
require "json"
require "optionparser"
require "prism"

require_relative "../configuration"
require_relative "options"
require_relative "../environment"
require_relative "../scope"
require_relative "../inference/def_return_typer"
require_relative "../inference/scope_indexer"
require_relative "../inference/statement_evaluator"
require_relative "prism_colorizer"
require_relative "command"

module Rigor
  class CLI
    # Executes `rigor annotate FILE`.
    #
    # For every source line the command finds the expression the
    # line evaluates to — the last statement that ends on the line
    # (so `1; 2; 3` reports `3`), or, for a line that no statement
    # closes, the widest expression ending there (so the `if nil`
    # header reports its condition). It infers that expression's
    # type and appends a `#=> <type>` comment (the xmpfilter /
    # seeing_is_believing convention).
    #
    # The annotated source is re-parsed with Prism — a sanity gate,
    # since the appended text is always a comment — and printed to
    # stdout. When colour is enabled and `bat`
    # (https://github.com/sharkdp/bat) is on PATH it is used for
    # highlighting; otherwise IRB-style highlighting via
    # {PrismColorizer}.
    class AnnotateCommand < Command
      USAGE = "Usage: rigor annotate [options] FILE"

      # Trailing `#=> …` annotation comment. Matched and stripped
      # before re-annotating so re-running is idempotent — this
      # follows xmpfilter's convention of owning the `#=>` marker,
      # and also absorbs the older `#=> dump_type: <type>` spelling
      # (idempotency across re-runs). The leading `\s` requirement
      # keeps a `#=>` inside a string literal (no preceding
      # whitespace ambiguity aside) from matching mid-expression.
      ANNOTATION_PATTERN = /\s+#=>(?:\s.*)?\z/

      # Arguments for highlighting through `bat`: the annotated
      # text arrives on stdin, so the language must be explicit;
      # `--style=plain` drops the grid/header chrome so the output
      # matches the PrismColorizer fallback line-for-line; paging
      # stays off because the CLI may itself sit in a pipeline.
      BAT_ARGS = %w[--language=ruby --style=plain --paging=never --color=always].freeze

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        file = @argv.shift
        if file.nil?
          @err.puts(USAGE)
          return CLI::EXIT_USAGE
        end
        unless File.file?(file)
          @err.puts("annotate: file not found: #{file}")
          return 1
        end

        execute(file, options)
      end

      private

      def parse_options
        # Default: colour a tty, unless `NO_COLOR` opts out. An
        # explicit `--color` / `--no-color` overrides both.
        options = { config: nil, color: @out.tty? && !no_color_env?, bat: nil, format: :text }

        parser = OptionParser.new do |opts|
          opts.banner = USAGE
          Options.add_config(opts, options)
          opts.on("--format=FORMAT", %w[text json],
                  "Output format: text (default) or json (a { line => type } map)") do |value|
            options[:format] = value.to_sym
          end
          opts.on("--[no-]color",
                  "Force or disable ANSI colour (default: auto-detect a tty; honours NO_COLOR)") do |value|
            options[:color] = value
          end
          opts.on("--[no-]bat",
                  "Force or disable highlighting through bat (default: when colour is on and bat is found)") do |value|
            options[:bat] = value
          end
        end
        parser.parse!(@argv)

        options
      end

      # https://no-color.org — colour output is suppressed by
      # default when `NO_COLOR` is present and not an empty string,
      # regardless of its value.
      def no_color_env?
        value = ENV.fetch("NO_COLOR", nil)
        !value.nil? && !value.empty?
      end

      def execute(file, options)
        configuration = Configuration.load(options.fetch(:config))
        # Force UTF-8 (with BOM tolerance) regardless of
        # `Encoding.default_external`. Under a minimal locale
        # the default is US-ASCII; reading multi-byte source
        # under that tag makes the post-parse `String#sub` /
        # `String#lines` calls in `#annotate` raise
        # `invalid byte sequence in US-ASCII`. Ruby source is
        # UTF-8 by convention (the parser's own assumption
        # absent a magic comment).
        source = File.read(file, mode: "r:bom|utf-8")
        parse_result = Prism.parse(source, filepath: file, version: configuration.target_ruby)
        return 1 if parse_errors?(parse_result, file)

        # `converged_loop_recording` re-records fixpoint-tracked loop
        # bodies from their converged (post-writeback) bindings, so a
        # loop-body line annotates the joined widened type (`Integer`)
        # rather than a stale first-iterations constant (`1 | 2`).
        scope_index = Inference::ScopeIndexer.index(
          parse_result.value, default_scope: base_scope(configuration),
                              converged_loop_recording: true
        )
        line_types = LineTypeCollector.new(scope_index).collect(parse_result.value)

        case options.fetch(:format)
        when :json
          emit_json(line_types)
        else
          @out.puts(render(annotate(source, line_types), color: options.fetch(:color), bat: options.fetch(:bat)))
        end
        0
      end

      # `--format json` — emit the { line_number => type } map directly, the
      # same data the text renderer consumes, so clients (the playground,
      # editors) get structured annotations without reparsing the `#=> <type>`
      # comment grammar. Values are the short type descriptions the text form
      # also shows; keys are 1-based line numbers as strings (JSON object keys).
      def emit_json(line_types)
        annotations = line_types.keys.sort.to_h { |line| [line.to_s, line_types[line].describe(:short)] }
        @out.puts(JSON.generate({ "annotations" => annotations }))
      end

      def base_scope(configuration)
        Scope.empty(
          environment: Environment.for_project(
            libraries: configuration.libraries,
            signature_paths: configuration.signature_paths
          )
        )
      end

      def parse_errors?(parse_result, file)
        return false if parse_result.success?

        parse_result.errors.each do |error|
          @err.puts("#{file}:#{error.location.start_line}: #{error.message}")
        end
        true
      end

      # Appends ` #=> <type>` to every line a type was inferred
      # for, aligning the comment column.
      def annotate(source, line_types)
        lines = source.lines
        column = annotation_column(lines, line_types)

        lines.each_with_index.map do |line, index|
          type = line_types[index + 1]
          eol = line.end_with?("\n") ? "\n" : ""
          code = line.chomp.sub(ANNOTATION_PATTERN, "")
          next "#{code}#{eol}" if type.nil?

          "#{code.ljust(column)}  #=> #{type.describe(:short)}#{eol}"
        end.join
      end

      def annotation_column(lines, line_types)
        widths = lines.each_index.filter_map do |index|
          next unless line_types.key?(index + 1)

          lines[index].chomp.sub(ANNOTATION_PATTERN, "").length
        end
        widths.max || 0
      end

      def render(annotated, color:, bat: nil)
        return annotated unless color
        return annotated unless Prism.parse(annotated).success?

        rendered = render_with_bat(annotated, forced: bat) unless bat == false
        rendered || PrismColorizer.colorize(annotated)
      end

      # Pipes the annotated source through `bat` and returns its
      # highlighted output, or nil when bat is unavailable or
      # fails (broken install, killed mid-write) — the caller
      # falls back to {PrismColorizer}. An explicit `--bat` with
      # no bat on PATH warns instead of failing silently.
      def render_with_bat(annotated, forced: nil)
        executable = bat_executable
        if executable.nil?
          @err.puts("annotate: --bat requested but no `bat` executable found on PATH") if forced
          return nil
        end

        output = IO.popen([executable, *BAT_ARGS], "r+") do |io|
          io.write(annotated)
          io.close_write
          io.read
        end
        return nil unless $CHILD_STATUS&.success?

        output.empty? ? nil : output
      rescue SystemCallError, IOError
        nil
      end

      def bat_executable
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          next if dir.empty?

          candidate = File.join(dir, "bat")
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end
    end

    # Walks a parsed program and resolves, per source line, the
    # type of the expression the line evaluates to. Used only by
    # {AnnotateCommand}.
    class LineTypeCollector
      def initialize(scope_index)
        @scope_index = scope_index
      end

      # @param program [Prism::ProgramNode]
      # @return [Hash{Integer => Rigor::Type}] 1-indexed line => type.
      def collect(program)
        by_line = {}
        each_statement(program) do |statement|
          type = type_of(statement)
          by_line[statement.location.end_line] = type unless type.nil?
        end
        fill_uncovered_lines(program, by_line)
        override_def_header_lines(program, by_line)
        by_line
      end

      private

      # Yields each statement node (a child of any `StatementsNode`
      # anywhere in the tree) in post-order: nested statements are
      # yielded before the enclosing statement that contains them.
      # `by_line[end_line] = type` overwrites earlier entries, so
      # post-order means the *outermost* statement closing a line
      # wins — for `b = if cond then :then else :else end` the
      # line resolves to the assignment's type (the if-expression's
      # union), not the else-branch's inner `:else`. Direct siblings
      # (`1; 2; 3`) are still yielded in source order so the last
      # sibling wins.
      def each_statement(node, &block)
        return if node.nil?

        if node.is_a?(Prism::StatementsNode)
          node.body.each do |stmt|
            each_statement(stmt, &block)
            block.call(stmt)
          end
        else
          node.compact_child_nodes.each { |child| each_statement(child, &block) }
        end
      end

      # For a line no statement closes (the `if` / block header
      # lines), fall back to the widest expression ending there.
      def fill_uncovered_lines(program, by_line)
        widest_per_line(program).each do |line, node|
          next if by_line.key?(line)

          type = node.is_a?(Prism::BlockParametersNode) ? block_params_type(node) : type_of(node)
          by_line[line] = type unless type.nil?
        end
      end

      # A `do |i|` header line's widest node is its BlockParametersNode —
      # not an expression, so evaluating it would only echo the
      # `Dynamic[top]` fallback. Annotate the line with the parameters'
      # inferred bindings instead (the single param's type, or a tuple
      # for multi-param blocks); decline (nil) when any param has no
      # plain name or no recorded binding, leaving the line bare.
      def block_params_type(params_node)
        inner = params_node.parameters
        return nil if inner.nil? || inner.requireds.empty?

        scope = @scope_index[params_node]
        types = inner.requireds.map do |param|
          return nil unless param.respond_to?(:name)

          scope.local(param.name) or return nil
        end
        types.size == 1 ? types.first : Type::Combinator.tuple_of(*types)
      end

      def widest_per_line(program)
        widest = {}
        walk(program) do |node|
          next if node.is_a?(Prism::ProgramNode) || node.is_a?(Prism::StatementsNode)

          line = node.location.end_line
          current = widest[line]
          widest[line] = node if current.nil? || span(node) > span(current)
        end
        widest
      end

      def span(node)
        node.location.end_offset - node.location.start_offset
      end

      def walk(node, &block)
        return if node.nil?

        block.call(node)
        node.compact_child_nodes.each { |child| walk(child, &block) }
      end

      # Types the node through the flow evaluator (not the bare
      # expression typer) under its recorded entry scope, so flow-only
      # forms type as the engine sees them — `i += 1` dispatches `+` on
      # `i`'s binding (`Integer`, post-fixpoint) instead of echoing the
      # RHS literal's `1`.
      def type_of(node)
        Inference::StatementEvaluator.new(scope: @scope_index[node]).evaluate(node).first
      rescue StandardError
        nil
      end

      # For every `def`, replace the annotation on the header line
      # (where the `def` keyword sits) with the method's inferred
      # return type. The default annotation there comes from the
      # parameter list (`name` typing as `Dynamic[top]`), which is
      # noise; the return type is what readers actually want next
      # to the method signature. When the return type cannot be
      # inferred (empty body, scope-lookup miss, or any error
      # under `DefReturnTyper.call`), the entry is deleted so no
      # annotation is shown on that line.
      def override_def_header_lines(program, by_line)
        each_def_node(program) do |def_node|
          line = def_node.location.start_line
          return_type = Inference::DefReturnTyper.call(def_node, @scope_index)
          if return_type.nil?
            by_line.delete(line)
          else
            by_line[line] = return_type
          end
        end
      end

      def each_def_node(node, &block)
        return if node.nil?

        block.call(node) if node.is_a?(Prism::DefNode)
        node.compact_child_nodes.each { |child| each_def_node(child, &block) }
      end
    end
  end
end
