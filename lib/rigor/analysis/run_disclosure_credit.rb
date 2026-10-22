# frozen_string_literal: true

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

      module_function

      # Runs the block with run-scoped registrations attributed and returns the file's records — each a run-disclosure
      # record tagged with its `plugin_id` and carrying the registering plugin's boundary rows as `:reads`, one per
      # `[plugin id, key]` — frozen and Marshal-clean. A thread variable, as {Plugin::IoBoundary.attributing} uses, so a
      # registration from inside an `Enumerator` still lands.
      def collect
        registrations = []
        previous = Thread.current.thread_variable_get(ATTRIBUTION_KEY)
        Thread.current.thread_variable_set(ATTRIBUTION_KEY, registrations)
        begin
          yield
        ensure
          Thread.current.thread_variable_set(ATTRIBUTION_KEY, previous)
        end
        credit(registrations)
      end

      # Called by {Plugin::Base#disclose_once} and {Plugin::Base#emit_once} for every call, a repeat included.
      def attribute(plugin, record)
        Thread.current.thread_variable_get(ATTRIBUTION_KEY)&.push([plugin, record])
        nil
      end

      def credit(registrations)
        return [].freeze if registrations.empty?

        reads = {}
        registrations.map do |plugin, record|
          rows = reads[plugin.object_id] ||= boundary_rows(plugin).freeze
          record.merge(plugin_id: plugin_id(plugin), reads: rows).freeze
        end.uniq { |record| identity(record) }.freeze
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
      # built one read nothing through it.
      def boundary_rows(plugin)
        boundary = plugin.instance_variable_get(:@io_boundary) or return []
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
