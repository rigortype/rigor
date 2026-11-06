# frozen_string_literal: true

require "json"
require "prism"
require_relative "typing_state"
require_relative "memo_audit"
require_relative "type_of_memo/stats"
require_relative "type_of_memo/table"
require_relative "type_of_memo/checking"
require_relative "type_of_memo/serving"
require_relative "type_of_memo/live"

module Rigor
  # ADR-129 stage 3 — the `ExpressionTyper#type_of` result memo in **shadow** form (WD5's G1, stage-3 form). It keys a
  # computation on `(scope identity, node identity, state id)` (WD2), opens a journal capture around it, and stores
  # what an unrefused computation read and wrote (WD3). It never serves anything: on a would-be hit, an entry whose read
  # slice still holds, production computes as usual inside a priors window, and G1 checks afterwards that
  # - the type equals the entry's;
  # - the live tables equal their pre-computation state with the entry's write slice replayed;
  # - the live computation touched no Resource.
  # A read slice that no longer holds is a miss, not a mismatch, counted by the slots whose reads went stale, which
  # measures what the journal costs in hits (#2853 for the set-only Tables). Output is production's by construction.
  #
  # Like {MemoAudit}, a process switch (`RIGOR_TYPE_OF_SHADOW=1`, read once at load, or {enable!}), a single boolean
  # check when off. With `RIGOR_TYPE_OF_SHADOW_REPORT=path`, each process appends one JSON line of its counters and
  # mismatch samples to `path` when it exits. The memo is shut while a tracer is attached or a typer carries
  # instance state (`@tracer`, `@operand_types`: WD1's bypass), and leaf nodes are never stored (WD3).
  module TypeOfMemo
    # ADR-129 WD4 — the per-file table, a Memo by kind: entries keyed on the state id, which carries every Frame
    # (WD2), and checked by G1 rather than by `MemoAudit.check` (its hits recompute in production already).
    TABLE = TypingState.memo(
      :type_of_memo,
      run_scoped: true,
      reason: "the type_of memo's per-file entries, keyed on scope, node and state id; G1 checks every would-be hit"
    )
    private_constant :TABLE

    # WD3 — never stored: their typing is a read the memo could only repeat.
    LEAVES = %w[
      LocalVariableReadNode InstanceVariableReadNode ClassVariableReadNode GlobalVariableReadNode SelfNode
      IntegerNode FloatNode RationalNode ImaginaryNode StringNode SymbolNode NilNode TrueNode FalseNode
      RegularExpressionNode SourceFileNode SourceLineNode SourceEncodingNode ConstantReadNode ConstantPathNode
      NumberedReferenceReadNode BackReferenceReadNode
    ].to_h { |name| [Prism.const_get(name), true] }.freeze
    private_constant :LEAVES

    # The Tables whose reads only record a filing a later reader never consumes (#2853).
    SET_ONLY = %i[dependency_reads self_call_misses].freeze

    SAMPLE_LIMIT = 50
    private_constant :SAMPLE_LIMIT

    # The mode: false (off), true (the stage-3 shadow), `:serve` (G1's stage-4 form), or live (stage 4: the memo
    # serves in the rule walk), `:live` without counters, so the live path takes no lock, and `:live_counted` with
    # them, when a report is asked for. The shadow is the audit, so it wins over `RIGOR_TYPE_OF_MEMO`.
    @enabled =
      case ENV["RIGOR_TYPE_OF_SHADOW"].to_s.downcase
      when "1", "true" then true
      when "serve" then :serve
      else
        if ENV["RIGOR_TYPE_OF_MEMO"].to_s.downcase == "rule"
          ENV.fetch("RIGOR_TYPE_OF_SHADOW_REPORT", "").empty? ? :live : :live_counted
        else
          false
        end
      end
    @stats = Stats.new

    class << self
      include Checking
      include Serving
      include Live

      def enabled? = @enabled

      # Whether the memo is live (ADR-129 stage 4): it serves its rule-walk hits.
      def live? = @enabled == :live || @enabled == :live_counted

      # Turns the shadow on. `serve: true` is G1's stage-4 form (ADR-129 WD5), for specs and audit tools only: a
      # would-be hit is recomputed with the memo suspended, the recomputation's Table writes are undone, and the entry
      # is served (validated, its reads merged upward, its writes replayed), so output depends on the memo. `live:
      # true` is stage 4's production form ({live}); `count: true` makes it keep its counters.
      def enable!(serve: false, live: false, count: false)
        @enabled = if live then count ? :live_counted : :live
                   elsif serve then :serve
                   else true
                   end
      end

      def disable! = (@enabled = false)

      # `{phase => {counter => n}}`, the counters since the last {reset}.
      def counts = @stats.counts

      # `{phase => {slot names => n}}`: the would-be hits whose read slice did not hold, by the slots that went stale.
      def stale = @stats.stale

      # The first mismatches seen since the last {reset}, each a Hash.
      def samples = @stats.samples

      # The number of mismatches since the last {reset}, all phases.
      def mismatches = counts.sum { |_, counters| counters[:mismatch] }

      def reset = @stats.reset

      # A file's analysis starts: a fresh table, in the main pass. A no-op when off. With
      # `RIGOR_TYPE_OF_SHADOW_ELIDE=1` (ADR-129 WD2's ELIDE, measured in stage 3), the table keys on the thread's ELIDE
      # id, restarted here. The state is extended at the first file's start: every frame open then closes after that
      # file ends (the per-file analysis is nested in it), so none exits through the plain `State#with`, which would
      # not restore the ELIDE id.
      #
      # Live, the memo opens in the rule walk only (WD6's stage 4), so the table is installed by {phase!} instead and
      # the main pass looks nothing up.
      def begin_file
        return unless @enabled && Ractor.main?

        state = TypingState.current
        state[TABLE] = live? ? nil : new_table(state, :main)
        nil
      end

      # The file's analysis moved on to `phase` (`:rule` once the main pass has indexed it). Live, this opens the
      # memo: the file's table starts here.
      def phase!(phase)
        return unless @enabled

        state = TypingState.current
        if live?
          state[TABLE] = new_table(state, phase) if phase == :rule && Ractor.main?
          return nil
        end

        table = state[TABLE]
        table.phase = phase if table
        nil
      end

      # A file's analysis ended: its entries go (WD4: the table is per file).
      def end_file
        return unless @enabled

        state = TypingState.current
        state[TABLE] = nil
        nil
      end

      # The block's value, the type `node` has in `scope`, computed by production under G1's shadow. Typing outside a
      # file's analysis ({begin_file} .. {end_file}: a pre-pass, a language-server query, a non-main Ractor) has no
      # table and is not shadowed.
      # `callee` is whether the typing runs in a callee body (the ADR-84 guard stack is not empty).
      def shadow(state, scope, node, callee: false, &)
        return yield if LEAVES[node.class]

        table = state[TABLE]
        return yield if table.nil? || table.suspended.positive?

        # G1′: the memo must not run while a `memo_shut_while_installed` Frame is installed.
        MemoAudit.note_memo_lookup(state) if MemoAudit.enabled?

        phase = callee ? :callee : table.phase
        by_id = (table.entries[scope] ||= {}.compare_by_identity)[node] ||= {}
        id = table.elide ? state.elide_id : state.id
        entry = by_id[id]
        count(phase, :lookups)
        if entry && stale_names(state, phase, entry).nil?
          return serve_hit(state, table, phase, scope, node, entry, &) if @enabled == :serve

          return check_hit(state, phase, scope, node, entry, &)
        end

        compute_and_store(state, phase, by_id, id, &)
      end

      private

      def new_table(state, phase)
        # Live, the memo keys on the exact id: in the rule walk alone ELIDE adds no hit (stage 4 measured it on
        # Mastodon, where its rule-walk gain in stage 3 came from main-pass entries).
        elide = !live? && %w[1 true].include?(ENV["RIGOR_TYPE_OF_SHADOW_ELIDE"].to_s.downcase)
        if elide
          state.extend(TypingState::ElideId) unless state.is_a?(TypingState::ElideId)
          state.restart_elide_id
        end
        Table.new(elide: elide, phase: phase)
      end

      # A miss: compute under a capture and store an unrefused, unraised result (WD3).
      def compute_and_store(state, phase, by_id, id)
        state.open_capture
        returned = false
        begin
          type = yield
          returned = true
        ensure
          refused, records = state.close_capture
          count(phase, :raised) unless returned
        end
        if refused
          count(phase, :refused)
        else
          reads, writes = state.slices(records)
          by_id[id] = reads.empty? && writes.empty? ? type : [type, reads, writes].freeze
          count(phase, :stored)
        end
        type
      end

      EMPTY = [].freeze
      private_constant :EMPTY

      # nil when the entry's read slice holds; else counts the stale slots and answers their names.
      def stale_names(state, phase, entry)
        return nil unless entry.is_a?(Array)

        reads = entry[1]
        return nil if state.stale_read(reads).nil?

        return EMPTY if @enabled.equal?(:live)

        names = state.stale_slots(reads).map { |slot| TypingState.slots[slot].name }.sort.freeze
        count(phase, :stale)
        count(phase, :stale_set_only) if (names - SET_ONLY).empty?
        @stats.stale_miss(phase, names.join(","))
        names
      end

      # Live without a report (`:live`), nothing is counted.
      def count(phase, counter)
        @stats.count(phase, counter) unless @enabled.equal?(:live)
      end

      def sample(phase, scope, node, kinds, stored, fresh, diffs)
        @stats.sample(SAMPLE_LIMIT) do
          {
            phase: phase, kinds: kinds, path: scope.source_path.to_s, line: node.location.start_line,
            node: node.class.name.delete_prefix("Prism::"),
            stored: describe(stored), fresh: describe(fresh),
            diffs: diffs.first(4).map do |slot, key, want, now|
              [TypingState.slots[slot].name, describe(key), describe(want), describe(now)]
            end
          }
        end
      end

      def describe(value)
        return "ABSENT" if TypingState::ABSENT.equal?(value)
        return value.describe(:short).to_s[0, 160] if value.respond_to?(:describe)

        value.inspect[0, 160]
      rescue StandardError => e
        "<describe failed: #{e.class}>"
      end

      public

      # A forked child starts: the counters it inherited are the parent's, which the parent reports.
      def forked
        reset if @enabled
        nil
      end

      # Appends this process's report to `RIGOR_TYPE_OF_SHADOW_REPORT`, when set (one JSON line). Runs at exit, and a
      # forked worker calls it before its `exit!`, which skips `at_exit`.
      def write_report
        path = ENV.fetch("RIGOR_TYPE_OF_SHADOW_REPORT", nil)
        return unless @enabled && path

        line = JSON.generate(pid: Process.pid, counts: counts, stale: stale, samples: samples)
        File.open(path, "a") { |file| file.puts(line) }
      rescue StandardError => e
        # A report that cannot be written must not keep a forked worker from its `exit!`, nor change the exit status.
        warn("rigor: RIGOR_TYPE_OF_SHADOW_REPORT not written: #{e.class}: #{e.message}")
      end
    end

    at_exit { send(:write_report) }
  end
end
