# frozen_string_literal: true

require "English"
require "prism"

require_relative "../cache/file_digest"
require_relative "../protection/closure_kill_oracle"
require_relative "../protection/dependency_closure"
require_relative "../protection/discovery_seed"
require_relative "../protection/mutation_cache"

require_relative "measurement_integrity_warning"

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

      # ADR-50 § WD2 — the bleeding-edge feature id gating the Tier-2 dependent-closure kill oracle (#254).
      # Same reason as above for naming it here rather than inlining the string.
      DEPENDENT_CLOSURE_KILL_ORACLE = "dependent-closure-kill-oracle"

      # #264 — the "loud" threshold for a rescued-harness-failure count. Below it, a rescued mutant reads as
      # the occasional transient this issue's `harness_errors` bucket exists to make VISIBLE, not to eliminate
      # (see {Protection::MutationScanner#classify}); at or above it, the pattern looks less like noise and
      # more like a harness defect worth stopping to investigate before trusting the ratio. Deliberately NOT
      # the `determine_protection_exit` gate: a `--threshold` build is pinned to the killed/survived ratio
      # today, and turning a harness-side symptom into a new way for that same command to exit non-zero would
      # silently change semantics CI already depends on. A loud stderr warning (plus the unconditional JSON
      # field) is the visibility this issue asks for without redefining what "the build is red" means.
      HARNESS_ERROR_WARN_FLOOR = 3

      # Issue #134 slice 2 — the bleeding-edge ids whose adoption changes what a Tier-2 measurement REPORTS,
      # and which therefore enter the identity of anything cached about it (#255: a behaviour feature's id is
      # part of the cache identity of everything it changes). Both are named above; this is the ordered set the
      # cache key reads, so a feature added to Tier 2 later has exactly one place to register.
      MUTATION_BEHAVIOUR_FEATURES = [DISCOVERY_SEEDED_MUTATION_SITES, DEPENDENT_CLOSURE_KILL_ORACLE].freeze

      private

      # Both measurement-integrity warnings, and the escalation rule between them, live in
      # {MeasurementIntegrityWarning}. Only the floor stays here: it is this command's policy, and
      # `coverage_command_spec` reads it off this module.
      #
      # @param report [MutationProtectionReport, FusedProtectionReport]
      def warn_harness_errors(report)
        MeasurementIntegrityWarning.emit(report, err: @err, floor: HARNESS_ERROR_WARN_FLOOR)
      end

      # The cross-file knowledge Tier 2 measures with — the #253 gate, and the ONLY place in this feature that
      # knows a feature id exists.
      #
      # Returns nil (today's behaviour: an unseeded per-file view on both halves of the measurement) unless the
      # project has adopted `discovery-seeded-mutation-sites`. With it adopted, returns the table set
      # {Protection::DiscoverySeed} builds over the scanned `paths` — class identity so a receiver whose class
      # is declared in a *sibling* file resolves instead of reading `Dynamic`, the def / ancestry index so the
      # method on it resolves too, and `param_inferred_types` (ADR-67 WD3) for an inferred-parameter receiver.
      #
      # One table set, two consumers, deliberately (issue #260): site selection admits a site and the kill
      # oracle can act on it. Seeding only the first admitted sites no mutation could ever break.
      #
      # Why the feature is off by default: an unseeded Tier 2 drops those sites from the denominator entirely,
      # so seeding ADDS sites and the effectiveness ratio moves on unchanged code — and `--threshold=RATIO`
      # exits 1 below a ratio users pin in CI. Turning it on by default would turn their build red with no
      # change on their side.
      #
      # Built ONCE here, on the parent, so {MutationForkScan}'s children copy-on-write inherit it inside the
      # scanner. Nothing crosses the marshal boundary: only the per-file results are marshaled back, and
      # neither a Scope nor a `Prism::Node` is among them.
      def mutation_discovery_seed(paths, configuration, environment, workers)
        return nil unless configuration.bleeding_edge_active?(DISCOVERY_SEEDED_MUTATION_SITES)

        seed = Protection::DiscoverySeed.build(
          paths: paths, environment: environment, target_ruby: configuration.target_ruby, workers: workers
        )
        seed.empty? ? nil : seed
      end

      # The kill oracle Tier 2 measures with — the #254 gate, and the only place that feature id is read.
      #
      # Returns nil (today's behaviour: {Protection::DiagnosticOracle}, which re-analyses the mutated file
      # alone) unless the project has adopted `dependent-closure-kill-oracle`. With it adopted, returns the
      # {Protection::ClosureKillOracle}, which counts a kill when a new diagnostic appears anywhere in the
      # mutated file's dependent closure — so a mutation whose damage lands in a CALLER is scored as the
      # catch it is.
      #
      # Why the feature is off by default: it moves the reported effectiveness ratio UP on unchanged code
      # (kills rise, the denominator does not), so a number recorded under it is not comparable with one
      # recorded without it — the ADR-50 WD2/WD7 reason for the overlay, even though the direction cannot
      # turn a `--threshold` build red.
      #
      # Both of its inputs are built HERE, once, on the parent — the ADR-46 dependents map (one recording
      # pass) and the per-file discovery bundles — so {MutationForkScan}'s children copy-on-write inherit
      # them and no per-mutant work is repeated per worker. `seed` composes the two features: it is handed
      # to the closure oracle's delegated {Protection::DiagnosticOracle} verbatim, so the mutated file's
      # verdict stays exactly the verdict the other feature's state produces, and this feature only ever
      # ADDS the kills that land in a dependent.
      def mutation_kill_oracle(paths, configuration, context, seed, workers)
        return nil unless configuration.bleeding_edge_active?(DEPENDENT_CLOSURE_KILL_ORACLE)

        Protection::ClosureKillOracle.new(
          configuration: configuration, environment: context.environment, project_scan: context.project_scan,
          paths: paths,
          dependents: Protection::DependencyClosure.build(
            paths: paths, configuration: configuration, environment: context.environment,
            cache_store: context.cache_store, workers: workers
          ),
          seed_bundles: Protection::DiscoverySeed.bundles(paths: paths),
          discovery_seed: seed
        )
      end

      # The scope {Protection::Mutator} judges a mutation site's receiver against, derived from the same seed
      # the oracle gets. nil (the gate off, or an empty seed) keeps the bare `Scope.empty` per file.
      def mutation_base_scope(seed, environment)
        return nil if seed.nil?

        base = Scope.empty(environment: environment)
        base.with_discovery(base.discovery.with(**seed))
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
        warn_harness_errors(report)
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
        # The fused path stays sequential end to end (`--workers` is warned about above), so the seed's own
        # parameter-inference pre-pass runs sequentially too rather than quietly re-enabling the forking the
        # warning just said was ignored. It is otherwise the same seed, threaded to the same two consumers, so
        # `--with-tests` measures the same site set as the plain path.
        seed = mutation_discovery_seed(paths, configuration, context.environment, 0)
        scanner = Protection::MutationScanner.new(
          configuration: configuration, environment: context.environment, project_scan: context.project_scan,
          limit: options[:limit], seed: options[:seed],
          site_selector: options[:include_dynamic] ? :all : :biteable,
          base_scope: mutation_base_scope(seed, context.environment), discovery_seed: seed,
          # #254 — the type half of the fused measurement is the same measurement, so the closure oracle
          # applies here too when adopted: a `--with-tests` run must not disagree with the plain run about
          # which mutants the TYPE axis caught, or the "add a type OR a test" verdict would depend on which
          # command you ran. Sequential like the rest of this path (`--workers` is warned about above).
          oracle: mutation_kill_oracle(paths, configuration, context, seed, 0)
        )
        accumulator = FusedProtectionAccumulator.new
        paths.each { |path| scan_fused_one(path, scanner, accumulator, test_oracle, configuration) }
        report = accumulator.to_report
        warn_harness_errors(report)
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
      #
      # #134 slice 2 — the files whose measurement is still valid are served from {Protection::MutationCache}
      # and never reach a worker at all; only the rest are forked over, and their fresh results are written
      # back. The cache read + write both happen on the parent, so the workers stay the pure-read, store-free
      # processes {MutationForkScan} documents.
      def scan_mutation_protection(paths, options)
        configuration = Configuration.load(options.fetch(:config))
        context = LanguageServer::ProjectContext.new(configuration: configuration)
        workers = CheckRunnerFactory.resolve_workers(options, configuration)
        seed = mutation_discovery_seed(paths, configuration, context.environment, workers)
        scanner = Protection::MutationScanner.new(
          configuration: configuration, environment: context.environment, project_scan: context.project_scan,
          limit: options[:limit], seed: options[:seed],
          base_scope: mutation_base_scope(seed, context.environment), discovery_seed: seed,
          oracle: mutation_kill_oracle(paths, configuration, context, seed, workers)
        )
        cache = mutation_result_cache(paths, options, configuration, context, seed)
        measure_mutation_files(paths, cache: cache, scanner: scanner, context: context,
                                      configuration: configuration, workers: workers)
      end

      # The cached / freshly-measured split, absorbed in `paths` order so the report is byte-identical however
      # the two sets were assembled.
      #
      # The two cache phases each get their OWN {Cache::FileDigest.with_run} scope and the MEASUREMENT sits
      # between them, deliberately: that scope installs a per-path digest memo. {Protection::ClosureKillOracle}
      # now writes each mutant to a fresh block-scoped path, so a memo spanning the measurement could no
      # longer serve one mutant another's digest — but keeping the measurement outside any memo scope stays
      # correct by construction rather than by the oracle's path discipline, and costs only one extra
      # SHA-256 per cached file against a measurement that is hundreds of analyses.
      def measure_mutation_files(paths, cache:, scanner:, context:, configuration:, workers:)
        cached = with_digest_run(configuration) { paths.to_h { |path| [path, cache.fetch(path)] }.compact }
        pending = paths - cached.keys
        fresh = if pending.empty?
                  {}
                else
                  MutationForkScan.run(paths: pending, scanner: scanner, environment: context.environment,
                                       configuration: configuration, workers: workers)
                end
        # `fetch`, never `[]`: a worker that died mid-slice must abort the run rather than quietly drop files
        # out of a ratio that `--threshold` gates CI on.
        with_digest_run(configuration) { pending.each { |path| cache.store(path, fresh.fetch(path)) } }
        report_mutation_cache(cache, measured: pending.size, served: cached.size)
        absorb_measured_files(paths, cached, fresh)
      end

      def absorb_measured_files(paths, cached, fresh)
        accumulator = MutationProtectionAccumulator.new
        paths.each do |path|
          absorb_mutation_result(accumulator, path, cached.fetch(path) { fresh.fetch(path) })
        end
        accumulator.to_report
      end

      # ADR-87 WD1's per-run digest scope, so the cache's own freshness checks honour `cache.validation:`
      # (and `RIGOR_STRICT_VALIDATION`) exactly as every other record-and-validate cache does.
      def with_digest_run(configuration, &)
        Cache::FileDigest.with_run(strict: configuration.cache_validation_strict?, &)
      end

      # The per-file result cache (#134 slice 2), or a disabled one. Two callers-side bypasses are decided
      # here rather than inside the cache: `--no-cache`, and the `dependent-closure-kill-oracle` overlay —
      # under that oracle a file's verdict depends on its DEPENDENTS' diagnostics, so validity would need the
      # dependencies of every dependent rather than `deps[A]`, and the feature is presumptively non-graduating
      # (#254). A bypass is sound and honest; a key that pretended otherwise would not be.
      def mutation_result_cache(paths, options, configuration, context, seed)
        Protection::MutationCache.build(
          configuration: configuration, roots: @argv, project_scan: context.project_scan,
          sampling: Protection::MutationCache::Sampling.new(
            limit: options[:limit], seed: options[:seed],
            site_selector: options[:include_dynamic] ? :all : :biteable
          ),
          feature_ids: MUTATION_BEHAVIOUR_FEATURES.select { |id| configuration.bleeding_edge_active?(id) },
          seed_inputs: seed.nil? ? nil : paths,
          bypass_reason: mutation_cache_bypass(options, configuration)
        )
      end

      def mutation_cache_bypass(options, configuration)
        return "--no-cache" if options[:no_cache]
        return DEPENDENT_CLOSURE_KILL_ORACLE if configuration.bleeding_edge_active?(DEPENDENT_CLOSURE_KILL_ORACLE)

        nil
      end

      # One stderr line saying what the cache did — stdout stays clean for JSON. Always printed, because "the
      # cache quietly stopped working" and "the cache quietly served a stale number" are indistinguishable
      # from the outside otherwise; the slice-3 gate reads this line to prove itself non-vacuous.
      def report_mutation_cache(cache, measured:, served:)
        if cache.enabled?
          @err.puts("coverage: mutation cache — re-measured #{measured} file(s), #{served} served from cache.")
        else
          @err.puts("coverage: mutation cache disabled (#{cache.reason}) — " \
                    "re-measured #{measured} file(s).")
        end
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
