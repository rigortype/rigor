# frozen_string_literal: true

require "json"
require "prism"
require_relative "typing_state"

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

    PHASES = %i[main rule callee other].freeze

    # The Tables whose reads only record a filing a later reader never consumes (#2853).
    SET_ONLY = %i[dependency_reads self_call_misses].freeze

    SAMPLE_LIMIT = 50
    private_constant :SAMPLE_LIMIT

    # One file's entries, `scope => node => state id => entry`, and the phase its analysis is in.
    class Table
      attr_accessor :phase
      attr_reader :entries

      def initialize
        @entries = {}.compare_by_identity
        @phase = :other
      end
    end

    # The counters and mismatch samples of this process, behind a mutex: process counters like {MemoAudit}'s, never
    # read back into a type (ADR-129 WD5).
    class Stats
      def initialize
        @mutex = Mutex.new
        @counts = Hash.new { |hash, phase| hash[phase] = Hash.new(0) }
        @stale = Hash.new { |hash, phase| hash[phase] = Hash.new(0) }
        @samples = []
      end

      def count(phase, counter) = @mutex.synchronize { @counts[phase][counter] += 1 }

      def stale_miss(phase, names) = @mutex.synchronize { @stale[phase][names] += 1 }

      def sample(limit)
        @mutex.synchronize { @samples << yield if @samples.size < limit }
      end

      def counts = @mutex.synchronize { copy(@counts) }

      def stale = @mutex.synchronize { copy(@stale) }

      def samples = @mutex.synchronize { @samples.dup }

      def reset
        @mutex.synchronize do
          @counts.clear
          @stale.clear
          @samples.clear
        end
        nil
      end

      private

      def copy(by_phase) = by_phase.to_h { |phase, counters| [phase, counters.dup] }
    end

    @enabled = %w[1 true].include?(ENV["RIGOR_TYPE_OF_SHADOW"].to_s.downcase)
    @stats = Stats.new

    class << self
      def enabled? = @enabled

      def enable! = (@enabled = true)

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

      # A file's analysis starts: a fresh table, in the main pass. A no-op when off.
      def begin_file
        return unless @enabled

        table = Table.new
        table.phase = :main
        state = TypingState.current
        state[TABLE] = table
        nil
      end

      # The file's analysis moved on to `phase` (`:rule` once the main pass has indexed it).
      def phase!(phase)
        return unless @enabled

        table = TypingState.current[TABLE]
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

      # The block's value, the type `node` has in `scope`, computed by production under G1's shadow.
      # `callee` is whether the typing runs in a callee body (the ADR-84 guard stack is not empty).
      def shadow(state, scope, node, callee: false, &)
        return yield if LEAVES[node.class]

        table = state[TABLE] || (state[TABLE] = Table.new)
        phase = callee ? :callee : table.phase
        by_id = (table.entries[scope] ||= {}.compare_by_identity)[node] ||= {}
        id = state.id
        entry = by_id[id]
        count(phase, :lookups)
        return check_hit(state, phase, scope, node, entry, &) if entry && stale_names(state, phase, entry).nil?

        compute_and_store(state, phase, by_id, id, &)
      end

      private

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

      # nil when the entry's read slice holds; else counts the stale slots and answers their names.
      def stale_names(state, phase, entry)
        return nil unless entry.is_a?(Array)

        reads = entry[1]
        return nil if state.stale_read(reads).nil?

        names = state.stale_slots(reads).map { |slot| TypingState.slots[slot].name }.sort.freeze
        count(phase, :stale)
        count(phase, :stale_set_only) if (names - SET_ONLY).empty?
        @stats.stale_miss(phase, names.join(","))
        names
      end

      # A would-be hit: production computes, and G1 compares it with what serving the entry would have done.
      def check_hit(state, phase, scope, node, entry)
        stored, writes = entry.is_a?(Array) ? [entry[0], entry[2]] : [entry, EMPTY]
        count(phase, :checked)
        state.open_capture
        state.open_priors
        begin
          fresh = yield
        ensure
          priors = state.close_priors
          refused, = state.close_capture
        end
        judge(state, phase, scope, node, stored, fresh, writes, priors, refused)
        fresh
      end

      EMPTY = [].freeze
      private_constant :EMPTY

      def judge(state, phase, scope, node, stored, fresh, writes, priors, refused) # rubocop:disable Metrics/ParameterLists
        kinds = []
        kinds << :type unless fresh == stored
        kinds << :resource if refused
        diffs = table_diffs(state, writes, priors)
        kinds << :table unless diffs.empty?
        return if kinds.empty?

        count(phase, :mismatch)
        kinds.each { |kind| count(phase, :"mismatch_#{kind}") }
        sample(phase, scope, node, kinds, stored, fresh, diffs)
      end

      # The entries where the live tables differ from their pre-computation state with `writes` replayed: each key
      # the entry wrote must hold its last written value, and each key only the live computation wrote must hold
      # the value it replaced.
      def table_diffs(state, writes, priors)
        expected = TypingState::KeyIndex.new
        diffs = []
        # The last write of a key is what a replay leaves there: walk backwards and take each key once.
        writes.each_slice(3).reverse_each do |slot, key, value|
          next if expected.key?(slot, key)

          expected.store(slot, key, value)
          now = state.entry(slot, key)
          diffs << [slot, key, value, now] unless same?(value, now)
        end
        priors.each_slice(3) do |slot, key, prior|
          next if expected.key?(slot, key)

          now = state.entry(slot, key)
          diffs << [slot, key, prior, now] unless same?(prior, now)
        end
        diffs.uniq { |slot, key, _, _| [slot, key.is_a?(Array) ? key.map(&:__id__) : key.__id__] }
      end

      # Entry values compare by identity, or by `==` element-wise, a scope (which the one-slot caches record) by
      # identity alone: `Scope#==` ignores fields typing reads.
      def same?(left, right)
        return true if left.equal?(right)
        return false if left.is_a?(Scope) || right.is_a?(Scope)
        if left.is_a?(Array) && right.is_a?(Array)
          return left.size == right.size && left.each_index.all? { |index| same?(left[index], right[index]) }
        end

        left == right
      end

      def count(phase, counter) = @stats.count(phase, counter)

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

      # Appends this process's report to `RIGOR_TYPE_OF_SHADOW_REPORT`, when set (one JSON line).
      def write_report
        path = ENV.fetch("RIGOR_TYPE_OF_SHADOW_REPORT", nil)
        return unless @enabled && path

        line = JSON.generate(pid: Process.pid, counts: counts, stale: stale, samples: samples)
        File.open(path, "a") { |file| file.puts(line) }
      end
    end

    at_exit { send(:write_report) }
  end
end
