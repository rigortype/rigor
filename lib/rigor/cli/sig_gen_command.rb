# frozen_string_literal: true

require "optionparser"

require_relative "../configuration"
require_relative "../effects/config_envelopes"
require_relative "../effects/registry"
require_relative "options"
require_relative "../sig_gen"
require_relative "command"

module Rigor
  class CLI
    # Executes the `rigor sig-gen` command — ADR-14 slices 1–3.
    #
    # Walks the given paths (or `configuration.paths` when none are supplied), classifies every reachable instance
    # method via {Rigor::SigGen::Generator}, and either prints the resulting RBS skeletons / unified-style diffs
    # (`--print`, `--diff`; slice 1) or writes them to the project signature tree via {Rigor::SigGen::Writer}
    # (`--write`; slice 2).
    #
    # `--write` follows the established Ruby community convention: `lib/foo/bar.rb` → `sig/foo/bar.rbs`. New methods are
    # inserted into the matching class declaration just before its closing `end`; new classes are appended to the file;
    # non-existent target files are created. User-authored declarations are NEVER replaced unless `--overwrite` is set
    # AND the candidate is a `tighter-return`.
    #
    # Parameter policy defaults to `untyped`. `--params=observed` (slice 3) opts in to caller-side observation
    # harvesting: the `ObservationCollector` walks `--observe=PATH...` (default: the project's test roots,
    # {Configuration#resolved_test_paths}), unions per-position arg types, and the generator emits the union per ADR-5
    # clause 2.
    # `--params=observed-strict` stays reserved-but-inert until the capability-role catalog ships (rejected with a usage
    # error so the surface stays stable).
    #
    # `--check` (ADR-112 WD4) is the CI freshness gate: it runs the `--write` merge with every other flag as given,
    # writes nothing, prints what would change, and exits 1 when anything would.
    class SigGenCommand < Command # rubocop:disable Metrics/ClassLength
      USAGE = "Usage: rigor sig-gen [options] [paths]"

      VALID_MODES = %w[print diff write check].freeze
      VALID_PARAM_POLICIES = %w[untyped observed observed-strict].freeze
      VALID_FORMATS = %w[text json].freeze

      # The skip reasons {#report_skipped} counts. The four left out each have a report of their own
      # ({#report_unrenderable}, {#report_unresolvable_superclasses}, {#report_inline_declared}, and the refusal
      # lines `--write` / `--check` print for `inline_differs`), so a method never shows up in two tallies.
      SUMMARISED_SKIP_REASONS = (SigGen::Classification::SKIP_DIAGNOSTIC_IDS.keys -
                                 %i[unrenderable_rbs unresolvable_superclass inline_declared
                                    inline_differs]).freeze
      private_constant :SUMMARISED_SKIP_REASONS

      # @return CLI exit status.
      def run
        options = parse_options
        return CLI::EXIT_USAGE if options.nil?

        configuration = Configuration.load(options.fetch(:config))
        paths = @argv.empty? ? configuration.paths : @argv

        observations = collect_observations(configuration, options)
        generator = SigGen::Generator.new(configuration: configuration, paths: paths,
                                          observations: observations,
                                          include_private: options.fetch(:include_private),
                                          effect_annotator: effect_annotator(configuration, paths, options),
                                          overwrite: options.fetch(:overwrite))
        candidates = generator.run
        mode = options.fetch(:mode).to_sym

        status = case mode
                 when :write then dispatch_write(candidates, configuration, options)
                 when :check then dispatch_check(candidates, configuration, options)
                 else
                   dispatch_print_or_diff(candidates, mode, options)
                   0
                 end
        report_skipped(candidates, options)
        report_inline_declared(candidates, options)
        report_withheld_annotations(candidates, options)
        report_unrenderable(generator.unrenderable)
        report_unresolvable_superclasses(generator.unresolvable_superclasses)
        status
      end

      private

      # ADR-103 WD9 — the effect table sig-gen writes annotations from, or `nil`.
      #
      # The gate is the project's own `effects:` opt-in and nothing else. An annotation is read back as an
      # enforced envelope, so turning emission on from a sig-gen flag alone would let one command commit a
      # project to a contract `rigor check` was never asked to keep; and a project that has not opted in
      # pays neither the analysis this needs nor a single changed byte of output.
      #
      # `--effect-envelopes` is the second, narrower switch: `%a{pure}` is the ecosystem's existing purity
      # spelling and round-trips through Steep as well as Rigor, while `%a{rigor:v1:effect …}` is Rigor's
      # own and belongs in a project's `sig/` only when the author asked for it by name.
      def effect_annotator(configuration, paths, options)
        unless configuration.effects_enabled?
          if options.fetch(:effect_envelopes)
            @err.puts("rigor sig-gen: --effect-envelopes needs the `effects:` opt-in in .rigor.yml; " \
                      "no effect annotation was emitted.")
          end
          return nil
        end

        require_relative "check_runner_factory"
        # Through the same factory `rigor check` and `rigor doctor` use, so the LRU cap, the worker
        # resolution and the tolerated-effects switch cannot drift from the command whose cache this run
        # shares. `workers: 0` because a collecting run is pinned to the sequential path anyway, and
        # `--no-cache` mirrors `rigor check`'s flag of the same name.
        runner = CheckRunnerFactory.build(
          configuration: configuration,
          options: { no_cache: options.fetch(:no_cache), explain: false, stats: false, workers: 0 },
          buffer: nil, cache_root: configuration.cache_path
        )
        runner.run((configuration.paths + paths).uniq)
        SigGen::EffectAnnotation::Annotator.new(
          table: runner.effect_table, envelopes: options.fetch(:effect_envelopes),
          envelope_index: runner.effect_envelopes, config_envelopes: config_envelopes(configuration)
        )
      end

      # The project's `effects.envelopes:` entries, for gate 0's `match:` half. Built with a plain
      # registry rather than the run's: gate 0 asks only WHETHER an entry selects this class, never what
      # it bounds, so the vocabulary a plugin would add cannot change the answer.
      def config_envelopes(configuration)
        Effects::ConfigEnvelopes.build(
          entries: configuration.effects_envelopes,
          registry: Effects::Registry.for_configuration(configuration)
        )
      rescue StandardError
        []
      end

      # The withheld half of the emission, counted the way {#report_skipped} counts a skip: a method that
      # did NOT get `%a{pure}` is the interesting case for a reader who expected one, and silence would
      # read as "sig-gen does not do this" rather than "this method did not earn it".
      def report_withheld_annotations(candidates, options)
        return unless options.fetch(:format) == "text"

        counts = candidates.each_with_object(Hash.new(0)) do |candidate, acc|
          reason = candidate.effect_reason
          acc[reason] += 1 if reason && reason != :emitted
        end
        return if counts.empty?

        breakdown = counts.map { |reason, n| "#{SigGen::EffectAnnotation::DIAGNOSTIC_IDS.fetch(reason)}: #{n}" }
        @err.puts(
          "rigor sig-gen: withheld an effect annotation from #{counts.values.sum} method(s) " \
          "(#{breakdown.join(', ')}). An annotation is enforced once written, so it is emitted only " \
          "from an exhaustive, undischarged summary."
        )
      end

      # Issue #778 — one stderr line per run saying how many methods the generator declined and why, so a
      # method missing from the output is never a silent absence. Text mode only: under `--format=json` every
      # skipped row is already in the payload with its `skip_reason`, and stderr stays clean for the consumer.
      # Per-method lines would be noise at project scale; the JSON payload is where each one is named.
      def report_skipped(candidates, options)
        return unless options.fetch(:format) == "text"

        counts = candidates.each_with_object(Hash.new(0)) do |candidate, acc|
          next unless candidate.classification == SigGen::Classification::SKIPPED
          next unless SUMMARISED_SKIP_REASONS.include?(candidate.skip_reason)

          acc[candidate.skip_reason] += 1
        end
        return if counts.empty?

        breakdown = counts.map { |reason, n| "#{SigGen::Classification::SKIP_DIAGNOSTIC_IDS.fetch(reason)}: #{n}" }
        @err.puts(
          "rigor sig-gen: skipped #{counts.values.sum} method(s) it could not type or would not overwrite " \
          "(#{breakdown.join(', ')}). Run with --format=json to see each one with its skip_reason."
        )
      end

      # ADR-112 WD4 — `sig_gen.inline_declared: skip` leaving methods out is the project's own choice, not a
      # method sig-gen "could not type or would not overwrite", so it is counted on a line of its own.
      def report_inline_declared(candidates, options)
        return unless options.fetch(:format) == "text"

        count = candidates.count { |c| c.skip_reason == :inline_declared }
        return if count.zero?

        @err.puts("rigor sig-gen: left #{count} method(s) declared inline out of sig/, as " \
                  "`sig_gen.inline_declared: skip` asks (sig.skipped.inline-declared).")
      end

      # A method whose rendered RBS does not parse is a Rigor rendering defect, not a fact about the user's
      # code — the generator skipped it (so the rest of the signatures are still usable and still valid), but
      # staying silent would leave the user with a quietly incomplete `sig/` and us with an unreported bug.
      # Reported on stderr so it never contaminates `--print` output being piped into a file.
      def report_unrenderable(unrenderable)
        return if unrenderable.empty?

        @err.puts(
          "rigor sig-gen: skipped #{unrenderable.size} method(s) whose generated RBS does not parse. " \
          "This is a bug in Rigor's RBS rendering, not in your code — please report it. " \
          "The remaining signatures are unaffected."
        )
        unrenderable.each do |method|
          @err.puts("  #{method.path}: #{method.class_name}##{method.method_name}")
          @err.puts("    rendered: #{method.rbs}")
          @err.puts("    #{method.error}")
        end
      end

      # Issue #735 — unlike {#report_unrenderable} this is a fact about the PROJECT's type universe, not a
      # Rigor defect: the class's superclass is not declared by any RBS the environment loads, so a sidecar
      # declaring it would fail to build and take the class's type coverage with it. Naming the unresolved
      # superclass is the actionable part — it is usually one gem's missing RBS standing between the user
      # and signatures for a whole layer of their app.
      def report_unresolvable_superclasses(unresolvable)
        return if unresolvable.empty?

        @err.puts(
          "rigor sig-gen: skipped #{unresolvable.size} class(es) whose superclass no loaded RBS declares. " \
          "A signature for them would fail to build (`RBS::NoSuperclassFoundError`) and would leave the " \
          "class LESS typed than it is now. Provide RBS for the superclass — `rbs collection install`, the " \
          "gem's own `sig/`, or a `signature_paths:` entry — and re-run."
        )
        unresolvable.sort.each { |class_name, superclass| @err.puts("  #{class_name} < #{superclass}") }
      end

      def dispatch_print_or_diff(candidates, mode, options)
        SigGen::Renderer.new(out: @out).render(
          candidates: candidates,
          mode: mode,
          format: options.fetch(:format),
          selection: options.fetch(:selection)
        )
      end

      # @return exit status — non-zero when a file the user asked to write could not be written.
      def dispatch_write(candidates, configuration, options)
        results = build_writer(configuration, options).write_all(candidates)

        refused = refused_candidates(candidates)
        SigGen::Renderer.new(out: @out).render_write(results: results, format: options.fetch(:format), refused: refused)
        SigGen::Renderer.refusal_lines(refused).each { |line| @err.puts(line) }
        # A refused write (an assembled file that does not parse, an existing target that is not valid UTF-8,
        # or a method whose inline and `sig/` declarations disagree without `--overwrite`) means the user asked for a
        # write and did not get one, so the command must not report success — a green `sig-gen --write` in CI
        # would otherwise mean nothing.
        refusals = %i[skipped_invalid_rbs skipped_invalid_encoding]
        results.any? { |result| refusals.include?(result.action) } || !refused.empty? ? 1 : 0
      end

      # ADR-112 WD4 — the methods whose inline and `sig/` declarations disagree, refused because the run did not
      # pass `--overwrite`. Unlike every other skip, `sig/` contradicts the source while one stands.
      def refused_candidates(candidates)
        candidates.select { |candidate| candidate.skip_reason == :inline_differs }
      end

      # ADR-112 WD4 — the same writer as {#dispatch_write}, flags included, in dry-run mode. Defined by what
      # `--write` would do rather than by whether `--diff` prints anything: a tighter return against an existing
      # declaration is a proposal `--write` declines without `--overwrite`, and a gate that counted it could
      # never pass on a project that reviewed it and said no. With `--overwrite` it counts, because `--write
      # --overwrite` would apply it.
      #
      # @return 1 when `sig/` is out of date (or a write would be refused), 0 when it is current.
      def dispatch_check(candidates, configuration, options)
        results = build_writer(configuration, options, dry_run: true).write_all(candidates)
        refused = refused_candidates(candidates)
        SigGen::Renderer.new(out: @out).render_check(results: results, format: options.fetch(:format),
                                                     refused: refused)
        stale = SigGen::Renderer.out_of_date(results)
        return 0 if stale.empty? && refused.empty?

        report_check_failure(stale, refused) if options.fetch(:format) == "text"
        1
      end

      def report_check_failure(stale, refused)
        unless stale.empty?
          @err.puts("rigor sig-gen --check: #{stale.size} signature file(s) out of date; " \
                    "run `rigor sig-gen --write` with the same options to update them.")
        end
        return if refused.empty?

        @err.puts("rigor sig-gen --check: #{refused.size} method(s) whose inline declaration and sig/ copy " \
                  "disagree; make them agree, or pass --overwrite to replace the sig/ member.")
      end

      def build_writer(configuration, options, dry_run: false)
        layout_index = SigGen::LayoutIndex.new(signature_paths: configuration.signature_paths)
        path_mapper = SigGen::PathMapper.new(configuration: configuration, layout_index: layout_index)
        SigGen::Writer.new(path_mapper: path_mapper, overwrite: options.fetch(:overwrite), dry_run: dry_run)
      end

      # Slice 3 — collect call-site argument observations when `--params=observed` is set. When `--observe=PATH` is not
      # specified, observe the project's test roots: `test_paths:`, or whichever of `spec/` and `test/` exist. With no
      # root at all the run still succeeds, but says so — otherwise every parameter stays `untyped` with nothing
      # naming the reason.
      def collect_observations(configuration, options)
        return {} if options.fetch(:params) != "observed"

        observe_paths = options.fetch(:observe)
        observe_paths = configuration.resolved_test_paths if observe_paths.empty?
        if observe_paths.empty?
          warn_no_test_roots(configuration)
        else
          warn_missing_test_roots(observe_paths)
        end
        SigGen::ObservationCollector.new(configuration: configuration, paths: observe_paths).collect
      end

      # A declared root that does not exist is read as empty, so name it: `sig-gen` is the only command that reads
      # the test roots, and without this the run looks exactly like one whose tests pass no typed arguments.
      def warn_missing_test_roots(observe_paths)
        missing = observe_paths.reject { |path| File.exist?(path) }
        return if missing.empty?

        consequence = missing.size == observe_paths.size ? "; every parameter stays untyped" : ""
        @err.puts("rigor sig-gen: no call sites are observed from #{missing.map(&:inspect).join(', ')}, " \
                  "which does not exist#{consequence}. Check `test_paths:` or --observe=PATH.")
      end

      def warn_no_test_roots(configuration)
        reason = if configuration.test_paths.nil?
                   "no spec/ or test/ directory was found and `test_paths:` is unset"
                 else
                   "`test_paths:` is empty"
                 end
        @err.puts("rigor sig-gen: --params=observed has no test roots to observe (#{reason}); every parameter " \
                  "stays untyped. Declare `test_paths:` in the configuration or pass --observe=PATH.")
      end

      def parse_options
        options = {
          mode: "print",
          format: "text",
          params: "untyped",
          selection: [],
          overwrite: false,
          observe: [],
          include_private: false,
          effect_envelopes: false,
          no_cache: false,
          config: nil
        }
        build_option_parser(options).parse!(@argv)

        message = validation_error(options)
        return options if message.nil?

        @err.puts("sig-gen: #{message}")
        nil
      end

      def build_option_parser(options) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        OptionParser.new do |opts| # rubocop:disable Metrics/BlockLength
          opts.banner = USAGE
          opts.on("--print", "Write RBS skeletons to stdout (default)") { select_mode(options, "print") }
          opts.on("--diff", "Write a unified diff against existing RBS") { select_mode(options, "diff") }
          opts.on("--write", "Write generated RBS to sig/<path>.rbs files") { select_mode(options, "write") }
          opts.on("--check", "Exit 1 when --write would change sig/; write nothing") { select_mode(options, "check") }
          opts.on("--overwrite", "Allow tighter-return updates, and inline declarations that disagree with sig/, " \
                                 "to replace user-authored RBS") do
            options[:overwrite] = true
          end
          opts.on("--include-private", "Emit private / protected instance methods (default: public only)") do
            options[:include_private] = true
          end
          opts.on("--effect-envelopes", "Also emit %a{rigor:v1:effect ...} for effectful methods " \
                                        "(requires the effects: opt-in)") do
            options[:effect_envelopes] = true
          end
          opts.on("--no-cache", "Do not read or write the analysis cache (effect collection only)") do
            options[:no_cache] = true
          end
          opts.on("--format=FORMAT", "Output format: text or json") { |value| options[:format] = value }
          opts.on("--params=POLICY", "Parameter policy: untyped (default), observed, observed-strict") do |value|
            options[:params] = value
          end
          opts.on("--observe=PATH", "Directory / file to scan for call-site observations (repeatable; " \
                                    "default: the configured test_paths)") do |value|
            options[:observe] << value
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
          Options.add_config(opts, options)
        end
      end

      # A second, different mode flag is a usage error rather than last-one-wins: `--check --write` must not
      # quietly write in a CI job that meant to gate, nor `--write --check` quietly not.
      def select_mode(options, mode)
        options[:mode] = options[:mode_given] && options[:mode] != mode ? "conflict" : mode
        options[:mode_given] = true
      end

      def validation_error(options)
        mode = options.fetch(:mode)
        format = options.fetch(:format)
        params = options.fetch(:params)

        return "--print, --diff, --write, and --check are mutually exclusive flags; pick one" if mode == "conflict"
        return "unsupported --format=#{format}" unless VALID_FORMATS.include?(format)
        return "unsupported --params=#{params}" unless VALID_PARAM_POLICIES.include?(params)
        if params == "observed-strict"
          return "--params=observed-strict is reserved until the capability-role catalog ships"
        end

        nil
      end
    end
  end
end
