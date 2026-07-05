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
      private

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
        test_oracle = Protection::TestSuiteOracle.new(command: options.fetch(:test_command))
        return suite_not_green_error(options) unless test_oracle.green?

        context = LanguageServer::ProjectContext.new(configuration: configuration)
        scanner = Protection::MutationScanner.new(
          configuration: configuration, environment: context.environment, project_scan: context.project_scan,
          limit: options[:limit], seed: options[:seed],
          site_selector: options[:include_dynamic] ? :all : :biteable
        )
        accumulator = FusedProtectionAccumulator.new
        paths.each { |path| scan_fused_one(path, scanner, accumulator, test_oracle, configuration) }
        report = accumulator.to_report
        FusedProtectionRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_protection_exit(report, options)
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

      def scan_mutation_protection(paths, options)
        configuration = Configuration.load(options.fetch(:config))
        context = LanguageServer::ProjectContext.new(configuration: configuration)
        scanner = Protection::MutationScanner.new(
          configuration: configuration, environment: context.environment, project_scan: context.project_scan,
          limit: options[:limit], seed: options[:seed]
        )
        accumulator = MutationProtectionAccumulator.new

        paths.each { |path| scan_mutation_one(path, scanner, accumulator, configuration) }
        accumulator.to_report
      end

      def scan_mutation_one(path, scanner, accumulator, configuration)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
        if parse_result.errors.any?
          accumulator.record_parse_error(path, parse_result.errors)
          return
        end

        accumulator.absorb(scanner.scan_file(path, source: source))
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
