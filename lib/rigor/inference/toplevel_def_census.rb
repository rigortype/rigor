# frozen_string_literal: true

require_relative "../typing_state"
require_relative "memo_audit"

module Rigor
  module Inference
    # Issue #2515 — whether the `<toplevel>` def table's answer for a name IS the method a receiverless call of that
    # name runs, so the callee mutation floor may read the def as written. {.reliable?} is false (the floor reads every
    # argument as written, `StatementEvaluator::FLOOR_EVERY`) when any of these holds for `name`:
    #
    # - {Scope#toplevel_def_ambiguity} names a reason (the slot is contested, several ownerless definition rows of the
    #   name exist, a `def self.name` defines it on `main`, an `alias` introduces it, an anonymous class body defines
    #   it, `Object` defines it or has a module prepended);
    # - a `pre_eval:` patch defines `name` on `Object`, `Kernel` or `BasicObject`.
    #
    # A visibility toggle (`private :name`, `public :name`) does not change which def answers a receiverless call, and
    # `method_missing` on `Object` only answers a name nothing defines, so neither is a hazard.
    #
    # The answer is a function of the discovery index and the name (the environment is the run's), so it is memoised
    # per index. A recorder is told the `defines:<name>` name edge on every call, hit or not
    # ({Scope#toplevel_def_ambiguity}), so a file that starts or stops defining the name re-checks the caller; the memo
    # is bypassed while one is active, as the callee floor's other memos are.
    module ToplevelDefCensus
      OBJECT_OWNERS = %w[Object Kernel BasicObject].freeze
      # ADR-129 WD1 — a run-scoped Memo, per discovery index and name: the answer is a function of both, and
      # `MemoAudit` checks it on a hit.
      RELIABLE = TypingState.memo(
        :toplevel_def_reliable,
        run_scoped: true,
        reason: "keyed by discovery index, then name; the environment is the run's; audited by MemoAudit"
      )
      private_constant :OBJECT_OWNERS, :RELIABLE

      module_function

      # True when the `<toplevel>` table's def for `name` is the method a receiverless call of `name` runs.
      def reliable?(scope, name)
        return compute?(scope, name) if Analysis::DependencyRecorder.active? || MemoAudit.suspended?

        table = TypingState.current.weak_key_map(RELIABLE)
        by_name = (table[scope.discovery] ||= {})
        return by_name[name] = compute?(scope, name) unless by_name.key?(name)

        MemoAudit.check("top-level def census", by_name[name], name) { compute?(scope, name) }
      end

      def compute?(scope, name)
        return false unless scope.toplevel_def_ambiguity(name).nil?

        !patched?(scope, name)
      end

      # True when a `pre_eval:` patch defines `name` on an `Object`-level class.
      def patched?(scope, name)
        patched = scope.environment&.project_patched_methods
        return false if patched.nil?

        patched.by_key.each_key.any? do |(owner, method_name, _kind)|
          method_name == name && OBJECT_OWNERS.include?(owner)
        end
      end
    end
  end
end
