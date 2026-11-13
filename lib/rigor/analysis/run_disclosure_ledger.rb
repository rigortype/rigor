# frozen_string_literal: true

require_relative "run_disclosure_credit"

module Rigor
  module Analysis
    # Issue #2020 — the `--incremental` session's record of the run-scoped plugin rows ({Plugin::Base#disclose_once},
    # {Plugin::Base#emit_once}) each analysed file's hooks registered, so a recheck can replay them for the files it
    # serves from cache.
    #
    # - `files` maps a path to its records as the aggregator replays them, one per `[plugin id, key]` identity.
    # - `reads` maps an identity to the registering plugin's boundary rows when it was last registered
    #   ({RunDisclosureCredit}), `#prepare`'s reads included.
    #
    # Staleness is per identity, not per file. A plugin memoises the input a notice is about and re-registers the
    # notice from every file's hook, so crediting the rows to every registering file would re-analyse all of them on
    # any edit to an input the plugin read (one view edit re-analysed 400 of 400 files in an app with one i18n view
    # row). Instead a recheck finds the identities whose rows went stale, re-analyses ONE live registering file for
    # each (the first by path), and withholds those identities' replays. When that file registers the identity, every
    # other holder takes its record. When it registers nothing — the edit took the notice out of its text, it no
    # longer parses, the plugin raised — the recheck cannot tell whether the identity is gone, so it runs again with
    # every other live holder of the identity analysed ({#unresolved_holders}), and the identity is dropped only if
    # none of them registers it either.
    #
    # One shape stays unsound: a key whose registration or record depends both on an input the plugin read and on the
    # registering file's own text. When the input changes and the chosen file still registers the key, the other
    # holders take its record even where, re-analysed, they would register another record or none, until each is
    # re-analysed itself. {Plugin::Base#disclose_once} asks a key not to vary between workers, which rules it out for a
    # plugin that keeps the contract. Only inputs read through the plugin's boundary are tracked; state a plugin carries
    # across files, or an input it reads around the boundary (`ENV`, a direct `File.read`), can leave a replayed row
    # that never clears.
    class RunDisclosureLedger
      attr_reader :files, :reads

      def initialize(files: {}, reads: {})
        @files = files
        @reads = reads
      end

      # The ledger a baseline builds from `fresh` (`{path => [record with :reads]}`, `Runner#analysis_disclosures`).
      def self.from(fresh)
        new.tap { |ledger| ledger.absorb(fresh, fresh.keys, Set.new) }
      end

      def self.load(data)
        data.is_a?(Hash) ? new(files: data.fetch(:files, {}), reads: data.fetch(:reads, {})) : new
      end

      def to_h
        { files: @files, reads: @reads }
      end

      # The identities with a boundary row that no longer validates under `fresh_row` (a row → Boolean predicate).
      def stale_identities(&fresh_row)
        verdicts = {}
        @reads.each_with_object(Set.new) do |(identity, rows), stale|
          stale << identity if rows.any? { |row| !verdicts.fetch(row) { verdicts[row] = fresh_row.call(row) } }
        end
      end

      # One live registering file per stale identity, the first by path, skipping `removed`.
      def refreshers(stale, removed)
        return Set.new if stale.empty?

        holders = {}
        @files.each do |path, records|
          next if removed.include?(path)

          records.each do |record|
            identity = RunDisclosureCredit.identity(record)
            holders[identity] = [holders[identity], path].compact.min if stale.include?(identity)
          end
        end
        holders.values.to_set
      end

      # The live holders, outside `analyzed`, of every `stale` identity no file in `analyzed` registered in `fresh`:
      # the files that must be analysed when the chosen refresher registered nothing. Analysing every one of them
      # settles the identity, since every holder has then decided it afresh.
      def unresolved_holders(fresh, analyzed, stale, removed)
        return Set.new if stale.empty?

        registered = analyzed.flat_map do |path|
          Array(fresh[path]).map { |record| RunDisclosureCredit.identity(record) }
        end
        unresolved = stale - registered
        return Set.new if unresolved.empty?

        @files.each_with_object(Set.new) do |(path, records), holders|
          next if removed.include?(path) || analyzed.include?(path)

          holders << path if records.any? { |record| unresolved.include?(RunDisclosureCredit.identity(record)) }
        end
      end

      # The records to replay for `paths`, without the `stale` identities. Unpinned defence: a stale identity's replay
      # cannot reach the output today, since a refresher that registers it wins over the replay and one that does not
      # sends every holder into the second pass.
      def served(paths, stale = Set.new)
        @files.values_at(*paths).compact.flatten(1).reject do |record|
          stale.include?(RunDisclosureCredit.identity(record))
        end
      end

      # Folds a run's registrations in: every path in `analyzed` takes this run's records (or none), every identity
      # this run registered takes this run's rows, and each `stale` identity is refreshed or dropped in the files the
      # run did not analyse. Identities no file holds any more lose their rows.
      def absorb(fresh, analyzed, stale)
        registered = {}
        analyzed.each do |path|
          records = Array(fresh[path])
          records.each { |record| registered[RunDisclosureCredit.identity(record)] ||= record }
          store(path, records.map { |record| RunDisclosureCredit.replayable(record) })
        end
        registered.each { |identity, record| @reads[identity] = record[:reads] }
        refresh_unanalysed(stale, registered, analyzed.to_set)
        prune
      end

      def forget(path)
        @files.delete(path)
      end

      private

      def refresh_unanalysed(stale, registered, analyzed)
        return if stale.empty?

        @files.each_key.to_a.each do |path|
          next if analyzed.include?(path)

          store(path, @files[path].filter_map do |record|
            identity = RunDisclosureCredit.identity(record)
            next record unless stale.include?(identity)

            registered[identity] && RunDisclosureCredit.replayable(registered[identity])
          end)
        end
      end

      def store(path, records)
        records.empty? ? @files.delete(path) : @files[path] = records.freeze
      end

      # Unpinned hygiene: an identity no file holds is never replayed, so keeping its rows changes no answer; pruning
      # them keeps a stale row from re-analysing a file for nothing and the snapshot from growing.
      def prune
        held = @files.each_value.flat_map do |records|
          records.map { |record| RunDisclosureCredit.identity(record) }
        end.to_set
        @reads.select! { |identity, _| held.include?(identity) }
      end
    end
  end
end
