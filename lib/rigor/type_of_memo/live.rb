# frozen_string_literal: true

module Rigor
  module TypeOfMemo
    # ADR-129 stage 4 — the memo live in the rule walk, mixed into {TypeOfMemo}'s singleton: `RIGOR_TYPE_OF_MEMO=rule`
    # or {TypeOfMemo.enable!} with `live: true`; `RIGOR_TYPE_OF_SHADOW=serve-live` (`live: true, serve: true`) is G1's
    # stage-4 form over it.
    module Live
      # ADR-129 stage 4 — the block's value, the type `node` has in `scope`, served from the memo when the file's
      # analysis is in the rule walk and the typing is not in a callee body (`callee`, the ADR-84 guard stack is not
      # empty: callee bodies open in stage 5). Elsewhere the block computes with no lookup, store or capture, and an
      # open capture still journals its reads, writes and touches. A hit whose read slice holds is served without
      # computing (WD3: its reads merged into the open captures, its writes replayed); a miss computes under a capture
      # and stores what an unrefused computation read and wrote.
      def live(state, scope, node, guard, &)
        table = state[TABLE]
        return yield if table.nil? || LEAVES[node.class] || !state.stack(guard).empty? || table.suspended.positive?

        # G1′: the memo must not run while a `memo_shut_while_installed` Frame is installed.
        MemoAudit.note_memo_lookup(state) if MemoAudit.enabled?

        id = state.id
        entry = table.live_entry(scope, node, id)
        counting = !@enabled.equal?(:live)
        count(:rule, :lookups) if counting
        return live_hit(state, table, scope, node, entry, counting, &) if entry && stale_names(state, :rule, entry).nil?

        compute_live(state, table, scope, node, id, &)
      end

      private

      # A live hit whose read slice holds: served, or under G1's stage-4 form over the live configuration
      # (`RIGOR_TYPE_OF_SHADOW=serve-live`: the same store, table and closure) recomputed and compared first.
      def live_hit(state, table, scope, node, entry, counting, &)
        if counting
          count(:rule, :hits)
          count(:rule, :root_hits) unless state.capturing?
        end
        return serve_hit(state, table, :rule, scope, node, entry, &) if @enabled.equal?(:live_serve)
        return entry unless entry.is_a?(Array)

        apply(state, entry[1], entry[2], entry[0])
      end

      # Serving an entry (WD3's hit, steps 2 and 3): its read slice merged into the open captures, its write slice
      # replayed, journaled; answers `type`. The live hit and G1's stage-4 form share it, so G1′'s hit-path faults
      # reach the live path.
      def apply(state, reads, writes, type)
        state.merge_reads(reads)
        state.replay(writes)
        type
      end

      # A live miss: compute under a capture and store an unrefused, unraised result (WD3), as {#compute_and_store}
      # does for the shadow.
      def compute_live(state, table, scope, node, id)
        state.open_capture
        returned = false
        begin
          type = yield
          returned = true
        ensure
          unless returned
            state.close_capture
            count(:rule, :raised)
          end
        end
        entry = state.close_capture_entry(type)
        if entry.nil?
          count(:rule, :refused)
        else
          table.live_store(scope, node, id, entry)
          count(:rule, :stored)
        end
        type
      end
    end
  end
end
