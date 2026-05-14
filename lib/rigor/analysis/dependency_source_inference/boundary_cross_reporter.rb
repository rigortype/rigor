# frozen_string_literal: true

module Rigor
  module Analysis
    module DependencySourceInference
      # ADR-10 slice 5c — per-run accumulator for the
      # `dynamic.dependency-source.boundary-cross` `:info`
      # diagnostic.
      #
      # The diagnostic fires when both an authoritative source
      # (RBS today; plugins later) AND a `mode: :full` opt-in
      # gem's source catalog resolve the same `(class_name,
      # method_name)`. The dispatcher takes the authoritative
      # source's answer (per ADR-10's tier order), but records
      # the boundary crossing so the user can audit whether RBS
      # and the gem source have drifted.
      #
      # The accumulator deduplicates per `(class_name,
      # method_name, gem_name)` so a method called from many
      # files yields one diagnostic.
      #
      # Used in the same pattern as
      # {Rigor::RbsExtended::Reporter}: the dispatcher writes
      # events into the per-run instance; {Rigor::Analysis::Runner}
      # drains it at end-of-run into a flat
      # `Rigor::Analysis::Diagnostic` list.
      class BoundaryCrossReporter
        Entry = Data.define(:class_name, :method_name, :gem_name, :rbs_display)

        def initialize
          @entries = []
          @mutex = Mutex.new
        end

        # @return [Array<Entry>] frozen snapshot of the recorded
        #   boundary-cross events. Each entry is a Data with
        #   `class_name` (String), `method_name` (Symbol),
        #   `gem_name` (String), and `rbs_display` (String —
        #   the authoritative-side type's human-facing form,
        #   embedded into the diagnostic message).
        def entries
          @mutex.synchronize { @entries.dup.freeze }
        end

        def empty?
          @mutex.synchronize { @entries.empty? }
        end

        # Records one boundary-cross event. Deduplicates on the
        # `(class_name, method_name, gem_name)` triple — the
        # diagnostic per-receiver-per-method-per-owning-gem is
        # the actionable unit.
        def record(class_name:, method_name:, gem_name:, rbs_display:)
          entry = Entry.new(
            class_name: class_name, method_name: method_name,
            gem_name: gem_name, rbs_display: rbs_display
          )
          @mutex.synchronize do
            return if @entries.any? { |existing| same_key?(existing, entry) }

            @entries << entry
          end
        end

        private

        def same_key?(existing, entry)
          existing.class_name == entry.class_name &&
            existing.method_name == entry.method_name &&
            existing.gem_name == entry.gem_name
        end
      end
    end
  end
end
