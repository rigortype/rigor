# frozen_string_literal: true

require_relative "../type"
require_relative "external_ancestor_resolution"
require_relative "../typing_state"
require_relative "../memo_audit"

module Rigor
  module Inference
    # Issue #1234 — does the PROJECT define the method a receiver answers a name with? The captured-binding
    # pass reads a catalogued iterator name on an unclassified receiver as repetition
    # ({ClosureEscapeAnalyzer.repeats_by_name?}), and that reading is wrong for a method the project wrote
    # under the same name: `class Vault; def select(key) = yield(key.to_s); end` runs its block once. The
    # ancestry step of {ClosureEscapeAnalyzer.classify} asks the same question, of the same call, to rule the
    # project out as the method's owner.
    #
    # "Defines" is a `def`, `define_method` or `attr_*` anywhere in a project class's ancestry, on the
    # instance side or on the singleton side for a class-object receiver, or a signature whose declaring
    # owner is a project class or module.
    module ProjectMethodOwnership
      NO_TARGETS = [].freeze
      private_constant :NO_TARGETS

      # ADR-129 WD1 — a run-scoped Memo keyed on the identity of the discovery index and the environment, the only
      # inputs the buckets' answers read.
      MEMO = TypingState.memo(
        :project_method_ownership,
        run_scoped: true, audit: ["project method defines", "block runs", "ancestry non-escaping"],
        reason: "answer buckets keyed on the discovery index and environment identities"
      )
      private_constant :MEMO

      module_function

      # The `[class_name, kind]` pairs the receiver's method is looked up on — `[]` for a receiver Rigor
      # cannot see at all — or nil when the carrier names a class this cannot resolve, or is one it does not
      # recognise, so a caller that cannot tell whether the project owns the method can decline. The audit,
      # carrier by carrier:
      #
      # - `Dynamic`, `Top` — unseen: `[]`.
      # - `Nominal`, `StructInstance`, `DataInstance` — their `class_name`, instance side.
      # - `Singleton`, `StructClass`, `DataClass` — their `class_name`, singleton side.
      # - `Tuple` → `Array`, `HashShape` → `Hash`, `IntegerRange` → `Integer`, `FloatRange` → `Float`,
      #   `Constant` → its value's class, `BoundMethod` → `Method`: instance side of that core class, which a
      #   project reopening may still define the method on.
      # - `Union`, `Intersection` — every member's targets; a member it cannot resolve resolves the whole.
      # - `Refined`, `Difference` — their `base`. `App` — its erasure `bound`.
      # - A struct / data carrier with no `class_name` (an anonymous `Struct.new` value), `Bot`, `Maybe`,
      #   `Result`, and any carrier added later — nil.
      def targets(receiver_type)
        case receiver_type
        when Type::Dynamic, Type::Top then NO_TARGETS
        when Type::Nominal, Type::StructInstance, Type::DataInstance
          class_target(receiver_type.class_name, :instance)
        when Type::Singleton, Type::StructClass, Type::DataClass
          class_target(receiver_type.class_name, :singleton)
        when Type::Union, Type::Intersection then member_targets(receiver_type.members)
        when Type::Refined, Type::Difference then targets(receiver_type.base)
        when Type::App then targets(receiver_type.bound)
        else core_targets(receiver_type)
        end
      end

      # Whether the project's source, or a signature whose declaring owner is a project class or module,
      # defines `method_sym` on `class_name` or an ancestor the project declares. Memoised ({.memo}): the
      # ancestry step and the name reading ask it of the same call, and every block call on the class asks
      # it again.
      def defines?(class_name, method_sym, kind, scope)
        return false if scope.nil?

        by_method = (memo(scope)[kind][class_name] ||= {})
        if by_method.key?(method_sym)
          return MemoAudit.check("project method defines", by_method[method_sym], class_name, method_sym) do
            compute_defines?(class_name, method_sym, kind, scope)
          end
        end

        by_method[method_sym] = MemoAudit.key_audit("project method defines") do
          compute_defines?(class_name, method_sym, kind, scope)
        end
      end

      # One slot per thread, keyed on the identity of the scope's frozen discovery index and its environment —
      # the only inputs {.defines?} and the ancestry step read — and replaced, not accumulated, when either
      # changes: the shape of `ExpressionTyper#class_graph_buckets`, whose rationale applies unchanged. A
      # `Scope` merges each file's discovery with the project pre-pass, so the slot turns over per file, and
      # an ADR-46 dependency the first lookup recorded belongs to the file every later hit serves. Pool
      # workers are separate processes, and a Ractor has its own {TypingState}. The `:ancestry` bucket
      # belongs to {ClosureEscapeAnalyzer}'s ancestry step. The `:block_runs` bucket belongs to
      # {BlockRunCount}.
      def memo(scope)
        return new_buckets if MemoAudit.enabled? && MemoAudit.suspended?

        discovery = scope.discovery
        environment = scope.environment
        state = TypingState.current
        slot = state[MEMO]
        unless slot && slot[0].equal?(discovery) && slot[1].equal?(environment)
          slot = [discovery, environment, new_buckets]
          state[MEMO] = slot
        end
        slot[2]
      end

      class << self
        private

        # Empty buckets: a new slot's, and a throwaway set while an audit recomputation bypasses the memo.
        def new_buckets = { instance: {}, singleton: {}, ancestry: {}, block_runs: {}.compare_by_identity }

        def class_target(class_name, kind)
          class_name.nil? ? nil : [[class_name.to_s, kind]]
        end

        def member_targets(members)
          members.each_with_object([]) do |member, out|
            resolved = targets(member)
            return nil if resolved.nil?

            out.concat(resolved)
          end
        end

        def core_targets(receiver_type)
          case receiver_type
          when Type::Tuple then class_target("Array", :instance)
          when Type::HashShape then class_target("Hash", :instance)
          when Type::IntegerRange then class_target("Integer", :instance)
          when Type::FloatRange then class_target("Float", :instance)
          when Type::Constant then class_target(receiver_type.value.class.name, :instance)
          when Type::BoundMethod then class_target("Method", :instance)
          end
        end

        def compute_defines?(class_name, method_sym, kind, scope)
          return true if source_defines?(class_name, method_sym, kind, scope)

          # `ExternalAncestorResolution.method_definition` owns the rescue for a malformed signature.
          definition = ExternalAncestorResolution.method_definition(class_name, method_sym, kind, scope: scope)
          owner = definition.respond_to?(:defined_in) ? definition.defined_in : nil
          !owner.nil? && scope.known_user_class?(owner.to_s.delete_prefix("::"))
        end

        def source_defines?(class_name, method_sym, kind, scope)
          return true if scope.discovered_method_through_ancestors?(class_name, method_sym, kind)

          found, = if kind == :singleton
                     scope.singleton_def_through_ancestors(class_name, method_sym)
                   else
                     scope.user_def_through_ancestors(class_name, method_sym)
                   end
          !found.nil?
        end
      end
    end
  end
end
