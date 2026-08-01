# frozen_string_literal: true

require "English"
require "prism"

module Rigor
  class CLI
    # ADR-63 Tier 2 + ADR-70 — the mutation-effectiveness and fused static∪dynamic protection paths, factored out of
    # {CoverageCommand} to keep that command focused on dispatch. Mixed in, so each method runs in the command instance
    # (using `@out` / `@err` / `@argv` / `collect_paths` / `determine_protection_exit` and the Protection +
    # LanguageServer collaborators the command requires).
    module CoverageMutation
      # ADR-50 § WD2 — the bleeding-edge feature id gating the Tier-2 discovery seed (#253). Named here rather
      # than inlined at the call site: {Configuration#bleeding_edge_active?} raises on an id absent from the
      # registry, so the constant is the single place a rename has to reach.
      DISCOVERY_SEEDED_MUTATION_SITES = "discovery-seeded-mutation-sites"

      private

      # The scope Tier 2 judges a mutation site's receiver against — the #253 gate, and the ONLY place in this
      # feature that knows a feature id exists.
      #
      # Returns nil (today's behaviour: {Protection::Mutator} builds a bare `Scope.empty` per file) unless the
      # project has adopted `discovery-seeded-mutation-sites`. With it adopted, returns the same seeded scope
      # Tier 1 has built since 2026-07-04 — `discovered_classes` so a receiver whose class is declared in a
      # *sibling* file resolves instead of reading `Dynamic`, and `param_inferred_types` (ADR-67 WD3) so an
      # inferred-parameter receiver does too. Both span the scanned `paths` only.
      #
      # Why it is off by default: an unseeded Tier 2 drops those sites from the denominator entirely, so seeding
      # ADDS sites and the effectiveness ratio falls on unchanged code — and `--threshold=RATIO` exits 1 below a
      # ratio users pin in CI. Turning it on by default would turn their build red with no change on their side.
      #
      # Built ONCE here, on the parent, so {MutationForkScan}'s children copy-on-write inherit it inside the
      # scanner. Nothing crosses the marshal boundary: only the per-file results are marshaled back, and a Scope
      # is not among them.
      def mutation_base_scope(paths, configuration, environment, workers)
        return nil unless configuration.bleeding_edge_active?(DISCOVERY_SEEDED_MUTATION_SITES)

        scope_with_inferred_params(paths, configuration, environment, workers)
      end

      # ADR-63 Tier 2 — the mutation-effectiveness deep dive. Builds the RBS environment + project pre-pass once (the
      # warm loop), then re-analyses each target file's mutants against its clean baseline. Defaults to the git-changed
      # `.rb` files; explicit paths override (and enable the whole-project opt-in, which is minutes).
      def run_mutation_protection(options)
        explicit = collect_paths(@argv, command_name: "coverage")
        return CLI::EXIT_USAGE if explicit.nil?

        target_files = explicit.empty? ? changed_ruby_files : explicit
        if target_files.empty?
          @out.puts("No changed Ruby files to measure — pass paths to measure explicitly.")
          return 0
        end

        note_sampling(options)
        # `--with-tests` deliberately does NOT take the fork path below: {Protection::TestSuiteOracle} shells
        # out to the project's test runner, and concurrent suite invocations would race over one working tree.
        return run_fused_protection(target_files, options) if options[:with_tests]

        report = scan_mutation_protection(target_files, options)
        MutationProtectionRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_protection_exit(report, options)
      end

      # A `--limit` sample makes the report an estimate (per-file ratios over a random N of the mutations). Say so on
      # stderr — stdout stays clean for JSON.
      def note_sampling(options)
        return unless options[:limit]

        @err.puts(
          "coverage: sampling at most #{options[:limit]} mutations/file " \
          "(seed #{options[:seed]}); ratios are estimates."
        )
      end

      # ADR-70 — the fused static∪dynamic deep dive. The type pass is the ADR-63 Tier 2 warm loop; each type-survivor is
      # then run against the project's test suite (the runner hook). The suite MUST pass on clean code first, or "a
      # mutant survived" is meaningless — abort with a clear message if not.
      def run_fused_protection(paths, options)
        configuration = Configuration.load(options.fetch(:config))
        warn_workers_ignored_under_tests(options)
        test_oracle = Protection::TestSuiteOracle.new(command: options.fetch(:test_command))
        return suite_not_green_error(options) unless test_oracle.green?

        context = LanguageServer::ProjectContext.new(configuration: configuration)
        scanner = Protection::MutationScanner.new(
          configuration: configuration, environment: context.environment, project_scan: context.project_scan,
          limit: options[:limit], seed: options[:seed],
          site_selector: options[:include_dynamic] ? :all : :biteable,
          # The fused path stays sequential end to end (`--workers` is warned about above), so the seed's own
          # parameter-inference pre-pass runs sequentially too rather than quietly re-enabling the forking the
          # warning just said was ignored.
          base_scope: mutation_base_scope(paths, configuration, context.environment, 0)
        )
        accumulator = FusedProtectionAccumulator.new
        paths.each { |path| scan_fused_one(path, scanner, accumulator, test_oracle, configuration) }
        report = accumulator.to_report
        FusedProtectionRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_protection_exit(report, options)
      end

      # An explicit `--workers=N` on the fused path cannot be honoured, so say so rather than repeat the bug
      # this slice fixed (a flag accepted and silently dropped). Only the explicit flag warns — a project-wide
      # `parallel.workers:` or `RIGOR_RACTOR_WORKERS` default is not a request about *this* run.
      def warn_workers_ignored_under_tests(options)
        return unless options[:workers].to_i > 1

        @err.puts(
          "coverage: --workers is ignored with --with-tests — the test-suite oracle shells out to " \
          "#{options.fetch(:test_command).join(' ')}, and parallel runs would race."
        )
      end

      def scan_fused_one(path, scanner, accumulator, test_oracle, configuration)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
        if parse_result.errors.any?
          accumulator.record_parse_error(path, parse_result.errors)
          return
        end

        accumulator.absorb(scanner.scan_file_fused(path, source: source, test_oracle: test_oracle))
      end

      def suite_not_green_error(options)
        @err.puts(
          "coverage: the test suite must pass on clean code to measure test protection " \
          "(ran: #{options.fetch(:test_command).join(' ')})"
        )
        @err.puts(
          "  the command must exit 0 on a clean tree. A non-zero exit on otherwise-passing " \
          "tests also trips this — e.g. a SimpleCov coverage floor on a file-scoped run; " \
          "point --test-command at a plain pass/fail runner."
        )
        1
      end

      # Builds the RBS environment + whole-project pre-pass ONCE (≈6% of a 45-file run), then fork-maps the
      # per-file measurement — the ≈94% that is `Σ(1 + N_f)` single-file analyses — across the resolved worker
      # count (#134 slice 1). {MutationForkScan} returns `{path => result}` and the parent absorbs in `paths`
      # order, so the report is byte-identical to a sequential run whatever order the workers finished in.
      def scan_mutation_protection(paths, options)
        configuration = Configuration.load(options.fetch(:config))
        context = LanguageServer::ProjectContext.new(configuration: configuration)
        workers = CheckRunnerFactory.resolve_workers(options, configuration)
        scanner = Protection::MutationScanner.new(
          configuration: configuration, environment: context.environment, project_scan: context.project_scan,
          limit: options[:limit], seed: options[:seed],
          base_scope: mutation_base_scope(paths, configuration, context.environment, workers)
        )
        accumulator = MutationProtectionAccumulator.new

        results = MutationForkScan.run(
          paths: paths, scanner: scanner, environment: context.environment,
          configuration: configuration, workers: workers
        )
        # `fetch`, never `[]`: a worker that died mid-slice must abort the run rather than quietly drop files
        # out of a ratio that `--threshold` gates CI on.
        paths.each { |path| absorb_mutation_result(accumulator, path, results.fetch(path)) }
        accumulator.to_report
      end

      def absorb_mutation_result(accumulator, path, result)
        if result.is_a?(MutationForkScan::ParseError)
          accumulator.record_parse_error_count(path, result.count)
        else
          accumulator.absorb(result)
        end
      end

      # The git-changed (modified / added / untracked) `.rb` files that exist on disk — the default Tier 2 scope.
      # Returns [] outside a git work tree or when git is unavailable; the caller then reports "nothing to measure".
      def changed_ruby_files
        output = git_status_porcelain
        return [] if output.nil?

        output.each_line.filter_map { |line| changed_path(line) }.uniq.select { |p| File.file?(p) }
      end

      # Parse one `git status --porcelain` line (`XY <path>`, or `R  old -> new`)
      # into a candidate `.rb` path, or nil.
      def changed_path(line)
        path = line[3..]&.chomp
        return nil if path.nil? || path.empty?

        path = path.split(" -> ", 2).last if path.include?(" -> ")
        path = path.delete_prefix('"').delete_suffix('"')
        path.end_with?(".rb") ? path : nil
      end

      def git_status_porcelain
        output = IO.popen(%w[git status --porcelain --untracked-files=all], err: File::NULL, &:read)
        $CHILD_STATUS&.success? ? output : nil
      rescue SystemCallError
        nil
      end
    end
  end
end
