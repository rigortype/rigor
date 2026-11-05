# frozen_string_literal: true

require_relative "../../typing_state"
require_relative "../../memo_audit"

module Rigor
  module Inference
    module AliasMutationFloor
      # ADR-129 WD1 — the floor's four run-scoped Memos, each a pure function of the key it holds, and their accessors.
      # Each accessor's block computes the value: on a miss it is stored, on a hit {MemoAudit.check} compares it with
      # the stored one under `RIGOR_MEMO_AUDIT=1`, and while an audit recomputation runs ({MemoAudit.suspended?}) it
      # answers without reading or writing the memo.
      module Memos
        FACTS = TypingState.memo(
          :alias_mutation_floor_facts,
          run_scoped: true, audit: "alias floor facts",
          reason: "keyed by the body node; the facts are a pure function of the body and its parameters"
        )
        IVAR = TypingState.memo(
          :alias_mutation_floor_ivar_mutators,
          run_scoped: true, audit: "alias floor ivar mutator",
          reason: "keyed by def node; whether its body mutates an ivar is a pure function of the body"
        )
        FLOOR = TypingState.memo(
          :alias_mutation_floor_callee_floors,
          run_scoped: true, audit: "alias floor callee floor",
          reason: "keyed by the literal shape; the callee block floor is a pure function of it"
        )
        STORE = TypingState.memo(
          :alias_mutation_floor_unknown_stores,
          run_scoped: true, audit: "alias floor unknown store",
          reason: "keyed by call node, removed-keys mode and type, every input of the widened store"
        )
        private_constant :FACTS, :IVAR, :FLOOR, :STORE

        module_function

        # The facts of `body`. A hit is audited without the facts' per-read memos, which fill as reads are answered.
        def facts(body)
          return yield if MemoAudit.enabled? && MemoAudit.suspended?

          table = TypingState.current.weak_key_map(FACTS)
          facts = table[body]
          return table[body] = yield if facts.nil?

          MemoAudit.check("alias floor facts", audited(facts), body) { audited(yield) } if MemoAudit.enabled?
          facts
        end

        def ivar_mutator(def_node, &)
          return yield if MemoAudit.enabled? && MemoAudit.suspended?

          table = TypingState.current.weak_key_map(IVAR)
          cached = table[def_node]
          return table[def_node] = yield if cached.nil?

          MemoAudit.check("alias floor ivar mutator", cached, def_node, &)
        end

        def callee_floor(type, &)
          return yield if MemoAudit.enabled? && MemoAudit.suspended?

          state = TypingState.current
          table = (state[FLOOR] ||= {})
          return table[type] = yield unless table.key?(type)

          MemoAudit.check("alias floor callee floor", table[type], type, &)
        end

        def unknown_store(call_node, removed_keys, type, &)
          return yield if MemoAudit.enabled? && MemoAudit.suspended?

          state = TypingState.current
          table = (state[STORE] ||= {}.compare_by_identity)
          per_mode = ((table[call_node] ||= {})[removed_keys] ||= {})
          return per_mode[type] = yield unless per_mode.key?(type)

          MemoAudit.check("alias floor unknown store", per_mode[type], call_node, type, &)
        end

        def audited(facts) = facts.with(memo: nil, named_memo: nil)
      end
    end
  end
end
