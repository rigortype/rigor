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
      Entry = Data.define(:plugin_id, :path, :message)

      def initialize
        @entries = []
      end

      def record(plugin_id:, path:, message:)
        @entries << Entry.new(
          plugin_id: plugin_id.to_s.dup.freeze,
          path: path.to_s.dup.freeze,
          message: message.to_s.dup.freeze
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
