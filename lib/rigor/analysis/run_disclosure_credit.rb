# frozen_string_literal: true

require_relative "../typing_state"

module Rigor
  module Analysis
    # Issue #2020 — what one file's analysis contributed to the run-scoped plugin tables ({Plugin::Base#disclose_once}
    # and {Plugin::Base#emit_once}), kept beside the file's cached answer so an `--incremental` recheck that serves
    # the file without analysing it can still report the rows a cold run reports.
    #
    # A replayed row must go stale with the inputs it is about, and the reads those inputs came from are credited to
    # one file at most: a plugin memoises the input (a locale index, a routes table), so the first file to trigger
    # the read is the only one credited with it, and a read in `#prepare` is credited to none. So each record also
    # carries, under `:reads`, every row the registering plugin's boundary holds once the file is analysed,
    # `#prepare`'s included. {IncrementalSession} keeps those rows per `[plugin id, key]`, not per file: when one goes
    # stale it re-analyses one registering file and drops the key's replays, rather than re-analysing every file that
    # registered it. Only inputs read through the boundary are covered.
    module RunDisclosureCredit
      ATTRIBUTION_KEY = :rigor_run_disclosure_attribution
      private_constant :ATTRIBUTION_KEY

      # ADR-129 WD3 / #2814 — the registrations sink is a Resource: a `type_of` memo hit that served an answer without
      # re-running the plugin hook would not append the registration the miss appended, so every {.attribute} refuses
      # each open capture. Its storage stays the thread variable above (ADR-129 WD5 shape 2); this slot declares its
      # kind.
      SINK = TypingState.resource(
        :run_disclosure_attribution,
        reason: "every run-scoped plugin registration appends to the collecting sink, which a memo hit would not replay"
      )
      private_constant :SINK

      module_function

      # Runs the block with run-scoped registrations attributed and returns the file's records — each a run-disclosure
      # record tagged with its `plugin_id` and carrying the registering plugin's boundary rows as `:reads`, one per
      # `[plugin id, key]` — frozen and Marshal-clean. A thread variable, as {Plugin::IoBoundary.attributing} uses, so a
      # registration from inside an `Enumerator` still lands, carrying the installing fiber's typing state as
      # {Plugin::IoBoundary.attributing} does.
      def collect
        registrations = []
        previous = Thread.current.thread_variable_get(ATTRIBUTION_KEY)
        Thread.current.thread_variable_set(ATTRIBUTION_KEY, [registrations, TypingState.current].freeze)
        begin
          yield
        ensure
          Thread.current.thread_variable_set(ATTRIBUTION_KEY, previous)
        end
        credit(registrations)
      end

      # Called by {Plugin::Base#disclose_once} and {Plugin::Base#emit_once} for every call, a repeat included. Touches
      # {SINK} on the calling fiber's typing state and on the installing fiber's (ADR-129 WD3, #2814).
      def attribute(plugin, record)
        state = TypingState.current
        state.touch(SINK)
        registrations, owner = Thread.current.thread_variable_get(ATTRIBUTION_KEY)
        return nil if registrations.nil?

        owner.touch(SINK)
        registrations.push([plugin, record])
        nil
      end

      def credit(registrations)
        return [].freeze if registrations.empty?

        reads = {}.compare_by_identity
        records = registrations.map do |plugin, record|
          rows = reads[plugin] ||= boundary_rows(plugin).freeze
          record.merge(plugin_id: plugin_id(plugin), reads: rows).freeze
        end
        records.uniq { |record| identity(record) }.freeze
      end

      # The de-duplication identity a record shares with every other registration of its key.
      def identity(record)
        [record[:plugin_id], record[:key]]
      end

      # The record as the aggregator replays it, without the rows that decide whether it is stale.
      def replayable(record)
        record.except(:reads).freeze
      end

      # The boundary's file and listing rows, read without triggering its lazy initializer: a plugin that never
      # built one read nothing through it. {Plugin::Base#built_io_boundary} is private to the engine, so it is sent.
      def boundary_rows(plugin)
        boundary = plugin.__send__(:built_io_boundary) or return []
        descriptor = boundary.cache_descriptor
        descriptor.files + descriptor.globs
      end

      def plugin_id(plugin)
        plugin.manifest.id
      rescue StandardError
        plugin.class.to_s
      end
    end
  end
end
