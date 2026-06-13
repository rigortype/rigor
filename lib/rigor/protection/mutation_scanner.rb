# frozen_string_literal: true

require "prism"

require_relative "../analysis/runner"
require_relative "mutator"

module Rigor
  module Protection
    # ADR-63 Tier 2 — the mutation *effectiveness* tier (the truth tier behind
    # Tier 1's static {Inference::ProtectionScanner} proxy). For one file it
    # answers the question Tier 1 only bounds: when a type-visible bug is
    # introduced at a dispatch site, does Rigor actually catch it?
    #
    # Mechanism (the ADR-62 warm loop, narrowed to per-file measurement):
    # generate the type-visible mutations ({Mutator}), keep only those whose
    # receiver Rigor holds a concrete type for (the type-aware filter — the
    # FP-safe meaning-maker; an unresolved receiver is kept), then for each:
    # re-analyse the mutated SOURCE against a clean baseline and read whether a
    # NEW diagnostic appears. A *killed* mutation is a caught breakage; a
    # *survived* one is a breakage Rigor missed — an "add a type here" site.
    #
    # The expensive builds (RBS environment + the whole-project pre-pass scan)
    # are paid ONCE by the caller and threaded in via `environment:` /
    # `project_scan:`; each mutant reuses them through
    # `Runner.new(prebuilt:)#run_source` (in-memory overlay, no disk write).
    # Passing `prebuilt:` disables the run-result cache (whose key digests the
    # *disk* file), so a mutant is never served a stale clean hit.
    class MutationScanner
      # A surviving mutation site — a breakage Rigor did not catch.
      SurvivingSite = Data.define(:line, :receiver, :method_name, :operator)

      FileResult = Data.define(:path, :killed, :survived, :sites) do
        # Mutations actually analysed (parse-invalid mutants are not counted).
        def total = killed + survived

        # Effectiveness ratio; a file with no type-relevant mutation is
        # vacuously fully effective (no breakage was available to miss).
        def ratio = total.zero? ? 1.0 : killed.to_f / total
      end

      # @param configuration [Rigor::Configuration]
      # @param environment [Rigor::Environment] pre-built once by the caller
      # @param project_scan [Rigor::Analysis::ProjectScan] pre-built once
      # @param limit [Integer, nil] optional per-file mutation cap (sampled with
      #   `seed`); nil analyses every type-relevant mutation (deterministic).
      # @param seed [Integer] RNG seed for the optional sample.
      def initialize(configuration:, environment:, project_scan:, limit: nil, seed: 1)
        @configuration = configuration
        @environment = environment
        @project_scan = project_scan
        @limit = limit
        @seed = seed
      end

      # @param path [String] the file to measure (used as the in-memory bind path)
      # @param source [String, nil] the file's source; read from disk when nil
      # @return [FileResult]
      def scan_file(path, source: nil)
        source ||= File.read(path, encoding: Encoding::UTF_8)
        mutator = Mutator.new(source)
        kept, = mutator.filter_by_type(mutator.mutations, environment: @environment, path: path)
        kept = sample(kept)
        return FileResult.new(path: path, killed: 0, survived: 0, sites: []) if kept.empty?

        baseline = signatures(analyse(source, path))
        measure(source, path, kept, baseline)
      end

      private

      def measure(source, path, mutations, baseline)
        killed = 0
        sites = []
        mutations.each do |mut|
          case classify(source, path, mut, baseline)
          when :killed then killed += 1
          when :survived then sites << surviving_site(mut)
            # :invalid — a parse-broken mutant; not a measurement, skip it.
          end
        end
        FileResult.new(path: path, killed: killed, survived: sites.size, sites: sites)
      end

      def classify(source, path, mut, baseline)
        mutant_source = mut.apply(source)
        return :invalid unless Prism.parse(mutant_source).success?

        new_diagnostics = analyse(mutant_source, path).reject { |d| baseline.include?(sig(d)) }
        new_diagnostics.empty? ? :survived : :killed
      rescue StandardError
        # A harness-level failure on one mutant must not abort the file.
        :invalid
      end

      # cache_store: nil + prebuilt: scan ⇒ the run cache is bypassed and the
      # mutant is always re-analysed against the in-memory bytes.
      def analyse(source, path)
        Rigor::Analysis::Runner.new(
          configuration: @configuration, environment: @environment, prebuilt: @project_scan,
          cache_store: nil, collect_stats: false
        ).run_source(source: source, path: path).diagnostics
      end

      def sample(mutations)
        return mutations unless @limit

        mutations.sample(@limit, random: Random.new(@seed))
      end

      def signatures(diagnostics) = diagnostics.to_set { |d| sig(d) }
      def sig(diagnostic) = [diagnostic.rule, diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message]

      def surviving_site(mut)
        SurvivingSite.new(line: mut.line, receiver: mut.anchor_type,
                          method_name: mut.method_name, operator: mut.operator.to_s)
      end
    end
  end
end
