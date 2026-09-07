# frozen_string_literal: true

module Rigor
  module RbsExtended
    # ADR-13 slice 3b — per-run accumulator for `RBS::Extended` diagnostic events that the parser / resolver
    # cannot surface at the point of failure (the parsers are fail-soft, returning `nil` so call sites fall back
    # to the RBS-declared type).
    #
    # Owns three event streams:
    #
    # - `#unresolved_payloads` — `rigor:v1:*` directive payloads the resolver could not turn into a
    #   {Rigor::Type}. Surface as `dynamic.rbs-extended.unresolved` `:info` diagnostics.
    # - `#lossy_projections` — shape-projection type functions (`pick_of` / `omit_of` / `partial_of` /
    #   `required_of` / `readonly_of`) applied to a carrier that does not preserve shape information (anything
    #   other than `Type::HashShape` / `Type::Tuple`). Surface as `dynamic.shape.lossy-projection` `:info`
    #   diagnostics.
    # - `#hkt_directive_errors` — malformed `rigor:v1:hkt_register` / `rigor:v1:hkt_define` directives the
    #   ADR-20 parser declined. Surface as `dynamic.rbs-extended.hkt-directive-invalid` `:info` diagnostics.
    #
    # Mutable through the run; consumed once by {Rigor::Analysis::Runner} at end-of-run. Each event is
    # deduplicated by `(payload, source_location)` for unresolved, `(head, source_location)` for
    # lossy-projection, and `(message, path, line, column)` for an hkt directive, so a single annotation read
    # from many call sites yields one diagnostic.
    #
    # The reporter is intentionally thread-safe via a coarse `Mutex` because the inference engine may read the
    # same method definition from multiple files in parallel; the critical sections are short (Array#include? +
    # Array#<<) so the lock contention is negligible.
    class Reporter
      UnresolvedEntry = Data.define(:payload, :source_location)
      LossyProjectionEntry = Data.define(:head, :source_location)
      # Issue #785 — the position is flattened to `(path, line, column)` primitives rather than carried as the
      # `RBS::Location` its two siblings hold. Two reasons, and either alone decides it. The stream is drained
      # out of every fork-pool worker ({Rigor::Analysis::WorkerSession#drain_reporters}), and an `RBS::Location`
      # is a C-extension object with no `_dump`, so a `Marshal.dump` of the drain payload raises. And an
      # `RBS::Location` compares equal only against a location over the SAME `RBS::Buffer` object, so two
      # workers that each scanned the same `.rbs` would hand the coordinator two entries the dedup cannot
      # collapse — `--workers=N` would then print N copies of a row `--workers=0` prints once.
      HktDirectiveEntry = Data.define(:message, :path, :line, :column)

      def initialize
        @unresolved_payloads = []
        @lossy_projections = []
        @hkt_directive_errors = []
        @mutex = Mutex.new
      end

      # @return [Array<UnresolvedEntry>] frozen snapshot of the accumulated unresolved-payload events.
      def unresolved_payloads
        @mutex.synchronize { @unresolved_payloads.dup.freeze }
      end

      # @return [Array<LossyProjectionEntry>] frozen snapshot of the accumulated lossy-projection events.
      def lossy_projections
        @mutex.synchronize { @lossy_projections.dup.freeze }
      end

      # Records a `dynamic.rbs-extended.unresolved` event. The `source_location` argument is the {RBS::Location}
      # attached to the source annotation (or `nil` when the caller doesn't have one — the diagnostic falls back
      # to a generic location in that case).
      def record_unresolved(payload:, source_location: nil)
        entry = UnresolvedEntry.new(payload: payload.to_s, source_location: source_location)
        @mutex.synchronize do
          return if @unresolved_payloads.include?(entry)

          @unresolved_payloads << entry
        end
      end

      # Records a `dynamic.shape.lossy-projection` event for one of the five shape-projection heads. `head` MUST
      # be a String (`"pick_of"`, `"omit_of"`, …); the diagnostic message identifies which projection degraded.
      def record_lossy_projection(head:, source_location: nil)
        entry = LossyProjectionEntry.new(head: head.to_s, source_location: source_location)
        @mutex.synchronize do
          return if @lossy_projections.include?(entry)

          @lossy_projections << entry
        end
      end

      # @return [Array<HktDirectiveEntry>] frozen snapshot of the accumulated hkt-directive failures.
      def hkt_directive_errors
        @mutex.synchronize { @hkt_directive_errors.dup.freeze }
      end

      # Records a `dynamic.rbs-extended.hkt-directive-invalid` event: one malformed ADR-20 HKT directive the
      # {Rigor::RbsExtended::HktDirectives} parser declined. `message` names what the parser objected to; the
      # position triple is the annotation's `.rbs` file / line / 1-based column, each `nil` when the caller had
      # no location (the diagnostic then falls back to `.rigor.yml:1:1`).
      #
      # Every String is frozen individually, not just the enclosing `Data`: the entry crosses the pool drain
      # channel, whose stated invariant is that its payload is `Ractor.shareable?` as well as Marshal-clean.
      def record_hkt_error(message:, path: nil, line: nil, column: nil)
        entry = HktDirectiveEntry.new(
          message: message.to_s.dup.freeze, path: path.nil? ? nil : path.to_s.dup.freeze,
          line: line, column: column
        )
        @mutex.synchronize do
          return if @hkt_directive_errors.include?(entry)

          @hkt_directive_errors << entry
        end
      end

      # True when no events have accumulated. Used by callers that want to skip the diagnostic-emission pass
      # entirely on the common no-event path.
      def empty?
        @mutex.synchronize do
          @unresolved_payloads.empty? && @lossy_projections.empty? && @hkt_directive_errors.empty?
        end
      end
    end
  end
end
