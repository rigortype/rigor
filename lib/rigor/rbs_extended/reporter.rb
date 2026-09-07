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
    # deduplicated by its whole entry — `(payload, path, line, column)` for unresolved, `(head, path, line,
    # column)` for lossy-projection, `(message, path, line, column)` for an hkt directive — so a single
    # annotation read from many call sites yields one diagnostic.
    #
    # The reporter is intentionally thread-safe via a coarse `Mutex` because the inference engine may read the
    # same method definition from multiple files in parallel; the critical sections are short (Array#include? +
    # Array#<<) so the lock contention is negligible.
    class Reporter
      # Every entry carries its position as `(path, line, column)` primitives, flattened from the parser's
      # `RBS::Location` by {.position_of} at record time. Issues #785 (hkt) and #805 (the two older streams).
      # Two reasons, and either alone decides it. All three streams are drained out of every fork-pool worker
      # ({Rigor::Analysis::WorkerSession#drain_reporters}), and an `RBS::Location` is a C-extension object with
      # no `_dump`, so a `Marshal.dump` of the drain payload raises `TypeError` — which kills the worker at
      # drain time and degrades the run to in-process re-analysis. And an `RBS::Location` compares equal only
      # against a location over the SAME `RBS::Buffer` object, so two workers that each read the same `.rbs`
      # would hand the coordinator two entries the dedup cannot collapse — `--workers=N` would then print N
      # copies of a row `--workers=0` prints once.
      #
      # The record methods take the triple rather than the location for the same reason: a door that accepts
      # an `RBS::Location` is a door a future caller reintroduces the bug through.
      UnresolvedEntry = Data.define(:payload, :path, :line, :column)
      LossyProjectionEntry = Data.define(:head, :path, :line, :column)
      HktDirectiveEntry = Data.define(:message, :path, :line, :column)

      # Flattens an `RBS::Location` (or anything answering the same readers) to the `(path, line, column)`
      # triple every entry carries. `column` is 1-based, since `RBS::Location#start_column` is 0-based and
      # diagnostics are not. Each component is `nil` when the location cannot supply it, and the diagnostic
      # then falls back to `.rigor.yml:1:1`.
      #
      # Fail-soft by construction, like every parser that calls it: a location that raises while being read
      # costs the entry its position, never the run.
      #
      # @param source_location [RBS::Location, nil]
      # @return [Array(String, nil, Integer, nil, Integer, nil)]
      def self.position_of(source_location)
        return [nil, nil, nil] if source_location.nil?

        buffer = source_location.respond_to?(:buffer) ? source_location.buffer : nil
        name = buffer.respond_to?(:name) ? buffer.name.to_s : ""
        line = source_location.respond_to?(:start_line) ? source_location.start_line : nil
        column = source_location.respond_to?(:start_column) ? source_location.start_column + 1 : nil
        [name.empty? ? nil : name, line, column]
      rescue StandardError
        [nil, nil, nil]
      end

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

      # Records a `dynamic.rbs-extended.unresolved` event. The position triple is the source annotation's
      # `.rbs` file / line / 1-based column — {.position_of} flattens the caller's `RBS::Location` into it —
      # each `nil` when the caller had no location (the diagnostic then falls back to `.rigor.yml:1:1`).
      def record_unresolved(payload:, path: nil, line: nil, column: nil)
        entry = UnresolvedEntry.new(
          payload: frozen_text(payload), path: frozen_text(path), line: line, column: column
        )
        @mutex.synchronize do
          return if @unresolved_payloads.include?(entry)

          @unresolved_payloads << entry
        end
      end

      # Records a `dynamic.shape.lossy-projection` event for one of the five shape-projection heads. `head` MUST
      # be a String (`"pick_of"`, `"omit_of"`, …); the diagnostic message identifies which projection degraded.
      # The position triple is read exactly as {#record_unresolved}'s is.
      def record_lossy_projection(head:, path: nil, line: nil, column: nil)
        entry = LossyProjectionEntry.new(
          head: frozen_text(head), path: frozen_text(path), line: line, column: column
        )
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
          message: frozen_text(message), path: frozen_text(path), line: line, column: column
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

      private

      # `nil` stays `nil` — the diagnostic falls back to `.rigor.yml:1:1` on a missing path. Anything else
      # becomes an individually frozen String: the `Data` wrapper is frozen on its own, but the pool drain's
      # stated invariant is that its payload is `Ractor.shareable?`, which is a DEEP freeze. Coercing here also
      # means a caller that hands the door an `RBS::Location` by mistake stores its `#to_s`, not the object —
      # the entry cannot become un-Marshalable from the outside.
      def frozen_text(value)
        value.nil? ? nil : value.to_s.dup.freeze
      end
    end
  end
end
