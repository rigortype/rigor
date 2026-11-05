# frozen_string_literal: true

module Rigor
  module TypeOfMemo
    # G1's stage-4 form (ADR-129 WD5), mixed into {TypeOfMemo}'s singleton: on a would-be hit with
    # `TypeOfMemo.enable!(serve: true)`, the memo serves the entry and checks it against a recomputation. For specs
    # and audit tools; the CLI's `RIGOR_TYPE_OF_SHADOW=1` never serves.
    module Serving
      EMPTY = [].freeze
      private_constant :EMPTY

      private

      # G1's stage-4 form (ADR-129 WD5) on one would-be hit:
      # 1. recompute on the same scope objects with the memo suspended, in a capture and a priors window, and record
      #    the final state of every entry either side touches; a recomputation that touched a Resource is a mismatch
      #    and its answer stands;
      # 2. undo the recomputation's Table writes and drop its journal records, which the served entry replaces;
      # 3. serve the entry: validate its reads, merge them into the enclosing captures, replay its writes, and compare
      #    the touched entries and the type with the recorded ones. A recomputation that raises where an entry exists
      #    is a mismatch too.
      def serve_hit(state, table, phase, scope, node, entry, &)
        stored, reads, writes = entry.is_a?(Array) ? entry : [entry, EMPTY, EMPTY]
        count(phase, :checked)
        mark = state.journal_size
        fresh, priors, refused = recompute(state, table, phase, scope, node, stored, &)
        if refused
          judge(state, phase, scope, node, stored, fresh, writes, priors, refused)
          return fresh
        end

        live = touched(writes, priors).map { |slot, key| [slot, key, state.entry(slot, key)] }
        state.undo(priors)
        state.truncate_journal(mark)
        kinds = []
        kinds << :revalidate if state.stale_read(reads)
        state.merge_reads(reads)
        state.replay(writes)
        served(state, phase, scope, node, kinds, stored, fresh, live)
        stored
      end

      def recompute(state, table, phase, scope, node, stored)
        state.open_capture
        state.open_priors
        table.suspended += 1
        returned = false
        begin
          fresh = yield
          returned = true
        ensure
          table.suspended -= 1
          priors = state.close_priors
          refused, = state.close_capture
          report(phase, scope, node, [:raised], stored, nil, []) unless returned
        end
        [fresh, priors, refused]
      end

      # Every entry the served writes or the recomputation's writes touch, each once.
      def touched(writes, priors)
        seen = TypingState::KeyIndex.new
        keys = []
        [writes, priors].each do |slice|
          slice.each_slice(3) do |slot, key, _|
            next if seen.key?(slot, key)

            seen.store(slot, key, true)
            keys << [slot, key]
          end
        end
        keys
      end

      def served(state, phase, scope, node, kinds, stored, fresh, live) # rubocop:disable Metrics/ParameterLists
        kinds << :type unless same?(fresh, stored)
        diffs = live.filter_map do |slot, key, want|
          now = state.entry(slot, key)
          [slot, key, want, now] unless same?(want, now)
        end
        kinds << :table unless diffs.empty?
        report(phase, scope, node, kinds, stored, fresh, diffs) unless kinds.empty?
      rescue StandardError => e
        report(phase, scope, node, [:judge_error, "#{e.class}: #{e.message[0, 120]}"], stored, fresh, [])
      end
    end
  end
end
