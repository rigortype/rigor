# frozen_string_literal: true

require_relative "typing_state"

module Rigor
  # ADR-127 WD3 — the memo audit. A memo hit is correct only when the key holds every input the value
  # was computed from, and a key that misses one answers a caller with another caller's value (#2516, #2524). With the
  # audit on, every hit in the callee floor's memos (`resolved_census`, the unrecorded hand-off memo, the successor
  # store and `def_census`) recomputes the value and raises {Mismatch} when it differs from the stored one, so a key
  # defect fails on the first hit instead of waiting for an order that exposes it.
  #
  # Like {BudgetTrace}, a switch for specs and CI (`RIGOR_MEMO_AUDIT=1` in the environment, read once at load, or
  # {enable!}): off by default, a single boolean check when off. A recomputation
  # runs with the audit suspended on its thread and the memos bypassed ({suspended?}), so it reads nothing stored.
  #
  # A mismatch raises, and is also kept on this thread's list until {drain} takes it (ADR-129 WD5, #2785): the
  # typing path rescues `StandardError` in many places, and a raise one of them swallows would turn the defect into
  # an ordinary fallback answer. The runner drains the list after each file and reports what it holds the way it
  # reports a mismatch no rescue caught, and {raise_undrained!} fails the run on what a file never drained.
  #
  # **The key audit** (ADR-129 WD1) checks the other half at every miss: a Memo, or a Table a computation fills (the
  # ADR-84 return memo), whose miss computation reads a Frame must key on the state id or on that Frame's value.
  # {key_audit} runs a miss computation with its Frame reads noted ({TypingState::KeyAudit}) and compares them with
  # the Frame terms the key read through {TypingState::State#key_frame} when {key} built it. A read Frame the key
  # does not carry, and that neither the computation installed itself nor the site declared ({key_declaration}), is a
  # {KeyMismatch}: kept on this thread's list like a raised mismatch, and not raised, since the computation's answer
  # is correct for this caller.
  module MemoAudit
    # A memo hit whose stored value differs from a fresh computation.
    class Mismatch < StandardError; end

    # A memo miss whose computation read a Frame its key does not carry (ADR-129 WD1's key audit).
    class KeyMismatch < Mismatch; end

    # What a miss site declares beside its key terms (ADR-129 WD1), by Frame slot name:
    # - `forced`: Frames the memo installs at a constant (or a value derived from its key) before the key is built,
    #   so the computation reads that form rather than the caller's;
    # - `gaps`: `slot name => reason` naming the issue of a known key gap, read without a key term and reported as a
    #   named exception rather than a mismatch;
    # - `carried`: `slot name => reason` for Frames another key term carries (a run-level flag, fixed while the run
    #   generation the memo's bucket keys on is), counted as key terms.
    KeyDeclaration = Data.define(:forced, :gaps, :carried)

    # ADR-129 WD1 — a Frame, installed around a recomputation. `@enabled` is a process switch, outside the typing
    # state (WD5).
    SUSPENDED = TypingState.frame(
      :memo_audit_suspended, reason: "set around an audit recomputation, which bypasses every memo"
    )
    private_constant :SUSPENDED

    # ADR-129 WD1 — a Resource: the mismatches raised on this thread and not drained yet. Typing never reads it; an
    # append refuses every open capture, which only an audited run reaches.
    MISMATCHES = TypingState.resource(
      :memo_audit_mismatches,
      run_scoped: true,
      reason: "the audit's mismatches on this thread, appended where raised, drained per file, never read by typing"
    )
    private_constant :MISMATCHES

    EMPTY = [].freeze
    private_constant :EMPTY

    # ADR-129 WD1 — the Frames every key audit names as exceptions rather than mismatches, with their reasons: the
    # audit's own switch and the process switches whose installed recorders a computation may file into.
    KEY_AUDIT_SWITCHES = {
      memo_audit_suspended: "the audit's own switch: a nested hit's check reads it",
      flow_tracer: "a process switch (WD5): the tracer is an output, and the type_of memo is shut under one (WD4)",
      effects_collector: "a process switch (WD5): recording into its contents touches a Resource",
      dependency_recorder: "a process switch (WD5): the recorder files ADR-46 dependency edges, which no type reads",
      self_call_resolution_recorder: "a process switch (WD5): its records are a journaled Table, never read back"
    }.freeze

    # ADR-129 WD1 — a Resource: the named exceptions key audits on this thread met, `[label, slot name] => reason`.
    # Typing never reads it.
    KEY_EXCEPTIONS = TypingState.resource(
      :memo_audit_key_exceptions,
      run_scoped: true,
      reason: "the key audit's named exceptions met on this thread, for specs and reports; never read by typing"
    )
    private_constant :KEY_EXCEPTIONS

    NO_DECLARATION = KeyDeclaration.new(forced: EMPTY, gaps: {}.freeze, carried: {}.freeze)
    private_constant :NO_DECLARATION

    @enabled = %w[1 true].include?(ENV["RIGOR_MEMO_AUDIT"].to_s.downcase)

    module_function

    def enabled? = @enabled

    # True while an audit recomputation runs on this thread. The callee floor's memos are then bypassed (read and
    # write), so the recomputation reads no stored entry of another memo: a defect shared across a table (a stale
    # `resolved_census(:edges)` entry) would otherwise make the recomputed value match the stored one.
    def suspended? = TypingState.current[SUSPENDED]

    def enable! = (@enabled = true)

    def disable! = (@enabled = false)

    # `stored`, after checking it against `yield` when the audit is on. `label` and the key parts (`key`, `key2`) name
    # the memo entry in the failure; they are passed apart so an audit that is off allocates nothing.
    def check(label, stored, key, key2 = nil, &)
      return stored unless @enabled && !TypingState.current[SUSPENDED]

      fresh = suspended(&)
      return stored if fresh == stored

      mismatch = Mismatch.new(
        "#{label} memo hit differs from a fresh computation for #{[key, key2].inspect[0, 120]}: " \
        "stored #{stored.inspect[0, 200]}, fresh #{fresh.inspect[0, 200]}"
      )
      state = TypingState.current
      state.append(MISMATCHES, mismatch)
      raise mismatch
    end

    # The mismatches raised on this thread since the last drain, oldest first, and an empty list for the next file.
    # Each has been raised, so it carries the backtrace a crash row is built from.
    def drain
      state = TypingState.current
      mismatches = state.read(MISMATCHES)
      return EMPTY if mismatches.nil? || mismatches.empty?

      state.write(MISMATCHES, nil)
      mismatches
    end

    # ADR-129 WD1 — checks a `carried:` claim at the install of a run-level flag (`flag`, ADR-130's erasure or
    # dispatch-off frame). The return memo counts the flag as carried by its bucket's run-generation key, which holds
    # only while the flag is installed around a whole run: with the audit on, an install that finds the return memo
    # holding entries (a run in progress, or one that was not released) raises instead of silently mixing answers
    # computed under both values.
    def check_run_level_install(flag)
      return unless @enabled

      held = TypingState.current[TypingState.slot(:user_method_return_memo).index]
      return if held.nil? || held[1].empty?

      raise Mismatch, "#{flag} installed while the return memo holds entries: the memo's key carries it only as a " \
                      "flag installed around a whole run (ADR-129 WD1 key audit)"
    end

    # Raises the first mismatch no file drained (one raised outside every file's analysis), so a run that ends with
    # one fails instead of releasing it with the run's other slots.
    def raise_undrained!
      return unless @enabled

      mismatches = drain
      raise mismatches.first unless mismatches.empty?
    end

    def suspended(&)
      TypingState.current.with(SUSPENDED, true, &)
    end

    # A frozen {KeyDeclaration} for a miss site, built once into a constant so an audit that is off allocates nothing.
    def key_declaration(forced: EMPTY, gaps: {}, carried: {})
      KeyDeclaration.new(forced: forced.map(&:to_sym).freeze, gaps: gaps.transform_keys(&:to_sym).freeze,
                         carried: carried.transform_keys(&:to_sym).freeze)
    end

    # The key the block builds. When the audit is on, the Frames the block reads through
    # {TypingState::State#key_frame} are remembered as the key's terms for the {key_audit} of the miss that follows.
    def key(&)
      return yield unless @enabled

      auditing_state.collect_key_terms(&)
    end

    # The block's value: a memo's miss computation, keyed by `key` ({key}, or nil for a key that reads no Frame) and
    # declared by `declaration` ({key_declaration}). When the audit is on, a Frame the computation reads that the key
    # does not carry is a {KeyMismatch} on this thread's list, named by `label` (the slot's `audit:` or `computed:`
    # label), unless it is internal, forced, carried, a declared gap or a {KEY_AUDIT_SWITCHES} switch.
    #
    # A computation that raises or throws is not judged, and its audit is closed on the way out. A computation that
    # returns is judged whether or not its memo then stores it (the return memo's WD3 bracket may refuse it), which
    # only reports more. An audit recomputation ({suspended?}) is not judged either, but it still opens the site's
    # declaration, so a gap it declares reaches the audits around it as it does on a miss: the verdict of an enclosing
    # miss does not depend on whether this memo hit.
    def key_audit(label, declaration = nil, key = nil)
      return yield unless @enabled

      state = auditing_state
      declaration ||= NO_DECLARATION
      judged = !state[SUSPENDED]
      terms = state.key_terms_for(key) if judged
      state.open_key_audit(label, declaration.gaps)
      begin
        value = yield
      ensure
        reads = state.close_key_audit
      end
      judge_key_audit(state, label, declaration, terms, reads) if judged
      value
    end

    # The named exceptions key audits on this thread have met since the run began, `[label, slot name] => reason`.
    def key_exceptions
      TypingState.current.read(KEY_EXCEPTIONS) || {}
    end

    def auditing_state
      state = TypingState.current
      state.extend(TypingState::KeyAudit) unless state.is_a?(TypingState::KeyAudit)
      state
    end

    def judge_key_audit(state, label, declaration, terms, reads)
      return if reads.empty? || terms.include?(TypingState::KeyAudit::STATE_ID)

      reads.each do |slot, via|
        name = TypingState.slots[slot].name
        next note_key_exception(state, label, name, "through the #{via[0]} miss: #{via[1]}") unless via == true
        next if terms.include?(slot) || declaration.forced.include?(name) || declaration.carried.key?(name)

        reason = key_exception_reason(declaration, name)
        reason ? note_key_exception(state, label, name, reason) : report_key_mismatch(state, label, name)
      end
    end

    # Why a miss may read the Frame `name` without a key term, or nil: a gap its site declares, or a switch.
    def key_exception_reason(declaration, name) = declaration.gaps[name] || KEY_AUDIT_SWITCHES[name]

    def note_key_exception(state, label, name, reason)
      seen = state.acquire(KEY_EXCEPTIONS) { {} }
      seen[[label, name]] ||= reason
    end

    # Keeps one {KeyMismatch} per message on the list until it is drained: a key defect repeats at every miss.
    def report_key_mismatch(state, label, name)
      message = "key audit: the #{label} miss read the Frame #{name}, which its key does not carry"
      pending = state.read(MISMATCHES)
      return if pending&.any? { |mismatch| mismatch.message == message }

      mismatch = KeyMismatch.new(message)
      mismatch.set_backtrace(caller.drop_while { |frame| frame.include?("/memo_audit.rb:") })
      state.append(MISMATCHES, mismatch)
    end
  end

  # The engine reaches the audit as `Inference::MemoAudit`; it lives at `lib/rigor/memo_audit.rb` so the value layer
  # (`Reflection`, `Scope`) can load it without loading an `inference/` file (ADR-104's warm effects probe budget), as
  # `TypingState` does (#2796).
  module Inference
    MemoAudit = Rigor::MemoAudit
  end
end
