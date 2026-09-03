# frozen_string_literal: true

require_relative "crash_signature"

module Rigor
  module Analysis
    class Result
      attr_reader :diagnostics, :stats

      # @param stats [Rigor::Analysis::RunStats, nil] end-of-run telemetry (target file count, RBS class
      #   breakdown, wall + RSS) collected by the Runner. Nil when stats collection wasn't requested or wasn't
      #   applicable (early-exit paths like `validate_target_ruby` failure).
      def initialize(diagnostics: [], stats: nil)
        @diagnostics = diagnostics
        @stats = stats
      end

      def success?
        diagnostics.none?(&:error?)
      end

      # Issue #686 — true when a check rule (or a plugin's node-rule contribution) raised, so
      # `Runner#analyze_file_body`'s rescue REPLACED the affected file's whole diagnostic list with one
      # synthetic row. What comes back is then not a weaker account of the code; it is no account of it.
      #
      # Any consumer that compares two results, or reads an EMPTY result as "clean", has to ask this first.
      # A crashed baseline and a crashed mutant carry the same synthetic row, so `==` reports agreement; an
      # absence assertion holds on the one-diagnostic list the rescue leaves behind. That is how a kill
      # oracle scored survivors it never measured (#686) and how 1,177 spec examples passed with every check
      # rule crashing (#674).
      #
      # Narrower than "the run reported a failure", deliberately. A raising PLUGIN loses only that plugin's
      # contribution and a failed RBS definition build loses only a type — in both cases every builtin rule
      # still ran and its diagnostics are still here, so a consumer that refused those would be discarding a
      # real measurement. {CrashSignature} carries the full table and the reasoning.
      #
      # `success?` is deliberately NOT this question: a crash makes `success?` false (the row is `:error`),
      # which is why the CLI is loud and CI goes red. It is the callers that read the diagnostic LIST rather
      # than the exit code which need the predicate.
      def crashed?
        diagnostics.any? { |diagnostic| CrashSignature.discards_file_analysis?(diagnostic) }
      end

      # The diagnostics {#crashed?} answers true for, so a caller can name what it saw rather than only that
      # it saw something.
      #
      # @return [Array<Rigor::Analysis::Diagnostic>]
      def crash_diagnostics
        diagnostics.select { |diagnostic| CrashSignature.discards_file_analysis?(diagnostic) }
      end

      def error_count
        diagnostics.count(&:error?)
      end

      def to_h
        hash = {
          "success" => success?,
          "error_count" => error_count,
          "diagnostics" => diagnostics.map(&:to_h)
        }
        hash["stats"] = @stats.to_h if @stats
        hash
      end
    end
  end
end
