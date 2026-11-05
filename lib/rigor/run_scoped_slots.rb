# frozen_string_literal: true

require "English"
require_relative "typing_state"
require_relative "inference/memo_audit"

module Rigor
  # Issues #2412 and #2399 — the run-end hook for per-thread state whose contents belong to one analysis run. An
  # owner declares such a slot in {TypingState} with `run_scoped: true` where it names it, and each entry point that
  # runs an analysis calls {.release} in its `ensure`, so a finished run, or one that raised, leaves none of its
  # scopes, discovery tables or environment behind on the thread.
  #
  # A slot that holds its run until the next run overwrites it retains one run per thread. A slot whose value
  # reaches its own key retains every run, as `LoopValueRecord`'s `ObjectSpace::WeakKeyMap` did: the map holds
  # its values strongly, and a recorded scope reaches the parse tree that holds the key node. Releasing at run end
  # bounds both. Inside a run nothing changes: every memo keeps its key and its hit rate, and a slot read outside
  # a run (a language-server hover on the main thread) refills on its first miss.
  #
  # Only Tables, Memos and Resources are run-scoped. A Frame a `with_*` block installs and restores is already empty
  # when the frame returns, and clearing it from inside a frame would break the frame.
  #
  # ADR-129 — run-scoped state is a `run_scoped: true` {TypingState} slot, and nothing else registers: this module
  # keeps no key list of its own.
  module RunScopedSlots
    # Empties every run-scoped {TypingState} slot on the calling thread.
    #
    # ADR-129 WD5 (#2785) — with the memo audit on, a mismatch no file drained (one raised by typing outside the
    # per-file loop: return summaries, return re-evaluation, sig-gen) would be released here unreported, so it is
    # raised after the release, unless an exception is already leaving the run.
    def self.release
      undrained = Inference::MemoAudit.enabled? ? Inference::MemoAudit.drain : nil
      TypingState.release_run_scoped
      raise undrained.first if undrained && !undrained.empty? && $ERROR_INFO.nil?

      nil
    end
  end
end
