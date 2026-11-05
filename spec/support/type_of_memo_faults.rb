# frozen_string_literal: true

# ADR-129 WD5's G1′ — fault injection, the gate's own gate. Each fault disables one mechanism the `type_of` memo's
# soundness rests on; `spec/rigor/type_of_memo_faults_spec.rb` asserts that G1's stage-4 form
# (`Rigor::TypeOfMemo.enable!(serve: true)`) reports a mismatch with each fault on. The faults live here, prepended once
# into the classes they bend and each a no-op unless {TypeOfMemoFaults.inject} selected it, so no production path
# carries a switch.
module TypeOfMemoFaults
  FAULTS = %i[
    ignore_frame skip_validation skip_absent_logging skip_upward_merge skip_replay_journal refuse_innermost
    store_raised skip_restore skip_memo_miss skip_read_through_memo_miss
  ].freeze

  # The Frame `ignore_frame` installs without a fresh id: the threaded block-body flag, ADR-129's Context witness.
  IGNORED_FRAME = :threaded_block_body

  @active = nil

  class << self
    attr_reader :active

    def inject(fault)
      raise ArgumentError, "unknown G1′ fault #{fault.inspect}" unless fault.nil? || FAULTS.include?(fault)

      @active = fault
    end

    def on?(fault) = @active == fault

    # Runs the block with `fault` injected.
    def with(fault)
      previous = @active
      inject(fault)
      yield
    ensure
      inject(previous)
    end
  end

  # Faults on a thread's typing state.
  module StateFaults
    # ignore_frame: the Frame is installed under the id already current, so the key cannot tell its values apart.
    # skip_restore: an install leaves its own id behind instead of restoring the saved one.
    def with(slot, value, &)
      if TypeOfMemoFaults.on?(:ignore_frame) && Rigor::TypingState.slots[slot].name == TypeOfMemoFaults::IGNORED_FRAME
        return ignored_install(slot, value, &)
      end
      return super unless TypeOfMemoFaults.on?(:skip_restore)

      inner = nil
      begin
        super do
          inner = id
          yield
        end
      ensure
        @id = inner if inner
      end
    end

    # skip_absent_logging: a read that found no entry is not logged.
    def log_read(slot, key, value)
      return if TypeOfMemoFaults.on?(:skip_absent_logging) && Rigor::TypingState::ABSENT.equal?(value)

      super
    end

    def log_bound_read(slot, store, key, value)
      return if TypeOfMemoFaults.on?(:skip_absent_logging) && Rigor::TypingState::ABSENT.equal?(value)

      super
    end

    # skip_upward_merge: a served hit's reads do not reach the enclosing captures.
    def merge_reads(reads)
      return if TypeOfMemoFaults.on?(:skip_upward_merge)

      super
    end

    # skip_replay_journal: a served hit's writes are replayed but not journaled.
    def replay(writes)
      return super unless TypeOfMemoFaults.on?(:skip_replay_journal)

      writes.each_slice(3) { |slot, key, value| send(:put, slot, key, value) }
      nil
    end

    # refuse_innermost: a touch refuses only the innermost open capture.
    def refuse_captures
      return super unless TypeOfMemoFaults.on?(:refuse_innermost)

      @refused[-1] = true unless @refused.empty?
      nil
    end

    # skip_memo_miss / skip_read_through_memo_miss: WD1's Memo rule, or its read-through form, is not applied.
    def memo_miss(own = nil, &)
      return yield if own.nil? && TypeOfMemoFaults.on?(:skip_memo_miss)
      return yield if own && TypeOfMemoFaults.on?(:skip_read_through_memo_miss)

      super
    end

    private

    def ignored_install(slot, value)
      values = @values
      previous = values[slot]
      values[slot] = value
      begin
        yield
      ensure
        values[slot] = previous
      end
    end
  end

  # Faults on the memo's lookup and store.
  module MemoFaults
    private

    # skip_validation: a would-be hit is taken without checking that its read slice still holds.
    def stale_names(state, phase, entry)
      return nil if TypeOfMemoFaults.on?(:skip_validation)

      super
    end

    # store_raised: a computation that raised is stored, as an entry with a nil type and empty slices.
    def compute_and_store(state, phase, by_id, id)
      return super unless TypeOfMemoFaults.on?(:store_raised)

      begin
        super
      rescue StandardError
        by_id[id] = [nil, [].freeze, [].freeze].freeze
        raise
      end
    end
  end

  Rigor::TypingState::State.prepend(StateFaults)
  Rigor::TypeOfMemo.singleton_class.prepend(MemoFaults)
end
