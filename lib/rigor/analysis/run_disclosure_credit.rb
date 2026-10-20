# frozen_string_literal: true

module Rigor
  module Analysis
    # Issue #2020 — what one file's analysis contributed to the run-scoped plugin tables ({Plugin::Base#disclose_once}
    # and {Plugin::Base#emit_once}), kept beside the file's cached answer so an `--incremental` recheck that serves
    # the file without analysing it can still report the rows a cold run reports.
    #
    # A replayed row must go stale with the inputs it is about, and the reads those inputs came from are credited to
    # one file at most: a plugin memoises the input (a locale index, a routes table), so the first file to trigger
    # the read is the only one credited with it, and a read in `#prepare` is credited to none. So a file that
    # registered a row is also credited with every read the registering plugin's boundary holds once the file is
    # analysed, `#prepare`'s included. A change to any of them then puts the file back into the closure, where its
    # hook decides afresh. That over-credits, which only ever re-analyses a file sooner.
    module RunDisclosureCredit
      ATTRIBUTION_KEY = :rigor_run_disclosure_attribution
      private_constant :ATTRIBUTION_KEY

      module_function

      # Runs the block with run-scoped registrations attributed, appends the registering plugins' boundary rows to
      # `reads`, and returns the file's records — each a run-disclosure record tagged with its `plugin_id`, one per
      # `[plugin id, key]` — frozen and Marshal-clean. A thread variable, as {Plugin::IoBoundary.attributing} uses,
      # so a registration from inside an `Enumerator` still lands.
      def collect(reads)
        registrations = []
        previous = Thread.current.thread_variable_get(ATTRIBUTION_KEY)
        Thread.current.thread_variable_set(ATTRIBUTION_KEY, registrations)
        begin
          yield
        ensure
          Thread.current.thread_variable_set(ATTRIBUTION_KEY, previous)
        end
        credit(registrations, reads)
      end

      # Called by {Plugin::Base#disclose_once} and {Plugin::Base#emit_once} for every call, a repeat included.
      def attribute(plugin, record)
        Thread.current.thread_variable_get(ATTRIBUTION_KEY)&.push([plugin, record])
        nil
      end

      def credit(registrations, reads)
        return [].freeze if registrations.empty?

        registrations.map(&:first).uniq(&:object_id).each { |plugin| reads.concat(boundary_rows(plugin)) }
        registrations.map { |plugin, record| record.merge(plugin_id: plugin_id(plugin)).freeze }
                     .uniq { |record| [record[:plugin_id], record[:key]] }.freeze
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
