# frozen_string_literal: true

module Rigor
  module Plugin
    # ADR-32 WD6 — per-run accumulator for failures encountered by a plugin's
    # `Manifest#source_rbs_synthesizer` callable. The synthesizer returns `[:error, message]` on parse failure
    # (per its contract); `Environment.for_project` routes the tuple through `#record` here.
    # `Analysis::Runner` queries `#entries` after analysis and emits one `source-rbs-synthesis-failed` `:info`
    # diagnostic per entry so the user sees which files contributed nothing and why.
    #
    # Empty by default. The Runner only emits diagnostics when at least one entry is recorded — projects
    # without synthesizer-emitting plugins pay zero cost.
    #
    # Thread-/Ractor-safety: this reporter is per-`WorkerSession` in pool mode, so concurrent writes from one
    # Ractor's `collect_virtual_rbs` loop are serialised by the worker body itself. The sequential path shares a
    # single reporter across the run; entries are appended one at a time during env build (before any per-file
    # analysis runs), so no locking is needed.
    class SourceRbsSynthesisReporter
      # `kind` separates the two outcomes the Runner reports differently (ADR-32 WD12): `:failed` is a
      # synthesis that raised or could not parse, `:not_honoured` a synthesis that SUCCEEDED while silently
      # dropping an annotation it parsed. They are not the same news — the first says the file contributed
      # nothing, the second that it contributed all but one thing — so they carry distinct diagnostic ids.
      # Defaults to `:failed`, the pre-WD12 meaning, so an older caller records what it always did.
      Entry = Data.define(:plugin_id, :path, :message, :kind)

      def initialize
        @entries = []
      end

      def record(plugin_id:, path:, message:, kind: :failed)
        @entries << Entry.new(
          plugin_id: plugin_id.to_s.dup.freeze,
          path: path.to_s.dup.freeze,
          message: message.to_s.dup.freeze,
          kind: kind
        )
        nil
      end

      def entries
        @entries.dup.freeze
      end

      def empty?
        @entries.empty?
      end
    end
  end
end
