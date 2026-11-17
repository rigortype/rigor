# frozen_string_literal: true

require "prism"
require_relative "../../scope"
require_relative "../../type"
require_relative "../../memo_audit"
require_relative "../../typing_state"
require_relative "../../inference/definer_resolution"
require_relative "../dependency_recorder"
require_relative "../diagnostic"
require_relative "receiver_predicates"
require_relative "rule_ids"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `def.method-visibility-mismatch` (v0.1.2, Issues #1568 and #1984): an explicit-receiver
      # call to a method the project records `:private`, on an instance receiver or a class-object receiver
      # (`private`, `private :name`, `private_class_method`, `class << self` with `private`).
      #
      # The one entry point is {.diagnostic}, called by `CheckRules.call_node_diagnostics`. It reads
      # {ReceiverPredicates}, `Inference::DefinerResolution` and `Scope::ResolutionChain`, owns the
      # run-scoped memo of the names some class records private, and calls nothing else in `CheckRules`.
      module VisibilityMismatch
        module_function

        # v0.1.2 — `def.method-visibility-mismatch`. Fires when an explicit-receiver `Prism::CallNode`
        # targets a user-class method whose `discovered_method_visibilities` entry is `:private`. The rule
        # is intentionally narrow:
        #
        # - Only `:private`. `:protected` access depends on subclass tracking the engine does not yet
        #   model; broadening waits for that surface.
        # - Only user classes whose visibility table the indexer built. RBS-known classes (stdlib, gems)
        #   are NOT consulted yet — RBS visibility is reliable but surfacing it would broaden the rule to a
        #   level the per-rule false-positive triage hasn't covered.
        # - Implicit-self calls are skipped (always allowed for private). Calls whose receiver is
        #   `Prism::SelfNode` are also skipped — Ruby 2.7+ permits `self.foo` for private methods.
        # - Receiver MUST resolve to a `Type::Nominal` so the rule has a single class identity to query.
        #   Unions / Dynamic / shape carriers are skipped.
        # - Issue #1568 — a module the class PREPENDS sits ahead of it in Ruby's order, so a definition there
        #   is what the call reaches; the class's own private `def` answers only when nothing prepended
        #   defines the name ({#reached_definer_visibility}).
        # - Issue #1984 — a class-object receiver (`Type::Singleton`, `K.x`) is checked against the singleton side:
        #   the definition the call reaches on `K`'s singleton chain (its own singleton methods, its extended
        #   modules' instance methods, then the superclass's singleton chain) must be recorded `:private`
        #   (`private_class_method`, `class << self` with `private`, a private method of an extended module).
        # - Issue #1984 — Ruby hands a private call to `method_missing`, so a `method_missing` or
        #   `respond_to_missing?` a project entry on the receiver's chain records, on the side the call reaches,
        #   declines the rule ({#missing_hook_on_chain?}).
        def diagnostic(path, call_node, facts, lexical_sites = nil)
          return nil unless explicit_non_self_receiver?(call_node.receiver)

          scope = facts.scope
          return nil if scope.nil?

          # ADR-67 WD6b — an inferred-parameter receiver's nominal type is an open-call-site lower bound; a
          # private-method visibility firing against it is an FP by construction. Decline.
          return nil if ReceiverPredicates.inferred_param_receiver?(call_node, scope)

          receiver_type = facts.receiver_type
          case receiver_type
          when Type::Nominal then instance_visibility_mismatch(path, call_node, scope, receiver_type, lexical_sites)
          when Type::Singleton then singleton_visibility_mismatch(path, call_node, scope, receiver_type, lexical_sites)
          end
        end

        def instance_visibility_mismatch(path, call_node, scope, receiver_type, lexical_sites)
          visibility = scope.discovered_method_visibility(receiver_type.class_name, call_node.name)
          return nil unless visibility == :private

          reached = reached_definer_visibility(scope, receiver_type.class_name, call_node.name)
          return nil if reached == :undecided
          return nil unless reached.nil? || reached == :private
          return nil if missing_hook_on_chain?(scope, receiver_type.class_name, :instance)
          # ADR-121 WD7 — a refinement in effect (or one Rigor cannot read) may redefine the method, public.
          return nil if ReceiverPredicates.refined_method_in_effect?(receiver_type.class_name, call_node, scope,
                                                                     :instance, lexical_sites)

          build_visibility_mismatch_diagnostic(path, call_node, receiver_type.class_name)
        end

        # Issue #1984 — the singleton side reads only the reached definer: a private singleton method may be inherited
        # (`private_class_method :new` on a superclass) or come from an extended module, so there is no own-table
        # gate as on the instance side. It reports only:
        #
        # - a constant receiver (`K.x`, `A::K.x`): `self.class.x` or a local may hold a subclass that makes the name
        #   public again (`public_class_method :new`, a template-method `def self.x`);
        # - a call inside a `def` ({#load_time_call?}): code that runs while the files load (a class body's
        #   `ALL = [K.new]` before its `private_class_method :new`) may run before the call is private;
        # - no class on the chain may have had every singleton name made public (`K.public_class_method(*names)`,
        #   `K.singleton_class.class_eval { … }`; {#singleton_wildcard_contested?}).
        def singleton_visibility_mismatch(path, call_node, scope, receiver_type, lexical_sites)
          class_name = receiver_type.class_name
          return nil unless call_node.receiver.is_a?(Prism::ConstantReadNode) ||
                            call_node.receiver.is_a?(Prism::ConstantPathNode)
          return nil unless private_singleton_candidate?(scope, call_node.name)
          return nil if load_time_call?(scope, call_node)
          return nil unless reached_definer_visibility(scope, class_name, call_node.name, :singleton) == :private
          return nil if missing_hook_on_chain?(scope, class_name, :singleton)
          return nil if singleton_wildcard_contested?(scope, class_name)
          return nil if ReceiverPredicates.refined_method_in_effect?(class_name, call_node, scope, :singleton,
                                                                     lexical_sites)

          build_visibility_mismatch_diagnostic(path, call_node, "singleton(#{class_name})")
        end

        # ADR-129 WD1 — a run-scoped Memo: one `[discovery, names]` slot keyed on the discovery index's identity, the
        # only input the name set reads.
        PRIVATE_NAMES_MEMO = TypingState.memo(
          :check_rules_private_singleton_names,
          run_scoped: true, audit: "private singleton names",
          reason: "one [discovery, names] slot keyed on the discovery index's identity; the name " \
                  "set reads only its method-visibility tables"
        )
        private_constant :PRIVATE_NAMES_MEMO

        # Issue #1984 — the table-only gate the singleton side asks before it reads a chain, as the instance side asks
        # its own table first: whether any class records `name` private, on its singleton side or on its instance
        # side (an extended module's private method is private on the extender's singleton). Without it every
        # `Widget.new` would read, and file the dependency edges of, the whole singleton chain. The set is memoised per
        # discovery index.
        def private_singleton_candidate?(scope, name)
          DependencyRecorder.read_visibility("*", name) if DependencyRecorder.active?
          discovery = scope.discovery
          if Inference::MemoAudit.enabled? && Inference::MemoAudit.suspended?
            return private_recorded_names(discovery.discovered_method_visibilities).include?(name.to_sym)
          end

          state = TypingState.current
          slot = state[PRIVATE_NAMES_MEMO]
          unless slot && slot[0].equal?(discovery)
            names = Inference::MemoAudit.key_audit("private singleton names") do
              private_recorded_names(discovery.discovered_method_visibilities)
            end
            slot = [discovery, names]
            state[PRIVATE_NAMES_MEMO] = slot
            return slot[1].include?(name.to_sym)
          end
          Inference::MemoAudit.check("private singleton names", slot[1], name) do
            private_recorded_names(discovery.discovered_method_visibilities)
          end.include?(name.to_sym)
        end

        def private_recorded_names(tables)
          tables.each_value.with_object(Set.new) do |table, names|
            table.each { |slot, visibility| names << (slot.is_a?(Array) ? slot.last : slot) if visibility == :private }
          end
        end

        # Issue #1984 — whether the call is outside every `def` the file's deferred ranges name. A `def` is named
        # wherever it is written in a class body, at the top level or in a `class_eval` block, so a call in it is not
        # load time and may be reported. The top level, class bodies, and blocks and lambdas that are not such a `def`
        # (a `map { … }` or `define_method` block, a `-> { }`) are load time and decline: such code may run while the
        # files load, before a later `private_class_method` or in a load order where the private declaration has not
        # run yet.
        def load_time_call?(scope, call_node)
          rows = scope.discovered_deferred_ranges[scope.source_path]
          return true if rows.nil?

          offset = call_node.location.start_offset
          # A row with no side (a `def` in a block, a `define_method` name) is a block's range or no range at all.
          rows.none? { |(start, finish, _name, kind, _owner)| !kind.nil? && start <= offset && offset < finish }
        end

        SINGLETON_WILDCARD_SLOT = %i[singleton *].freeze
        private_constant :SINGLETON_WILDCARD_SLOT

        # Issue #1984 — whether a project class on `class_name`'s singleton chain has its wildcard singleton slot
        # contested: a call the walk saw may have made any of its singleton methods public.
        def singleton_wildcard_contested?(scope, class_name)
          discovery = scope.discovery
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, :singleton, :methods)
          chain.entries.any? do |entry|
            DependencyRecorder.read_visibility(entry.name, SINGLETON_WILDCARD_SLOT.last) unless entry.external?
            !entry.external? && discovery.contested?(:discovered_method_visibilities,
                                                     [entry.name, SINGLETON_WILDCARD_SLOT])
          end
        end

        VISIBILITY_MISSING_HOOKS = %i[method_missing respond_to_missing?].freeze
        private_constant :VISIBILITY_MISSING_HOOKS

        # Issue #1984 — whether a project entry on `class_name`'s chain for `side` records a `method_missing` or
        # `respond_to_missing?` on the side that entry stands for (a singleton entry's singleton methods, a mixin's
        # instance methods), or the chain cannot be read whole. Ruby sends a private call to `method_missing`, so
        # such a hook may answer it.
        def missing_hook_on_chain?(scope, class_name, side)
          chain = Scope::ResolutionChain.for(scope, class_name.to_s, side, :methods)
          return true if chain.truncated?

          chain.entries.any? do |entry|
            next false if entry.external?

            kind = entry.side == :singleton ? :singleton : :instance
            VISIBILITY_MISSING_HOOKS.any? { |hook| records_hook?(scope, entry.name, hook, kind) }
          end
        end

        def records_hook?(scope, owner, hook, kind)
          return true if scope.discovered_method?(owner, hook, kind)

          !(kind == :singleton ? scope.singleton_def_for(owner, hook) : scope.user_def_for(owner, hook)).nil?
        end

        # Issue #1568, ADR-119 C1c — the recorded visibility of the definition a call on `class_name` reaches: the
        # first project entry on the class's {Scope::ResolutionChain} from its head that records the name, so a
        # module the class PREPENDS answers ahead of the class. `Inference::DefinerResolution` reads it with the
        # `:visibility` question's default answer. It is `:undecided` wherever the chain does not settle the order
        # (an unpositioned or forked mixin, a conditional include) or an ancestor ahead of the definer may define
        # the name (one RBS does not know), and the caller declines; a definer whose visibility slot ADR-119's
        # producers contest is not alone (`DefinerResolution` asks the next candidate too), so it is `:undecided`
        # there without a read of the table here. nil is nothing recording the name at all, and the class's own
        # visibility stands. An ancestor the project does not declare is passed over, as the method lookup passes it.
        def reached_definer_visibility(scope, class_name, method_name, side = :instance)
          case Inference::DefinerResolution.resolve(scope, class_name, method_name, side, question: :visibility)
          in Inference::DefinerResolution::Known(answer:)
            answer
          in Inference::DefinerResolution::UNKNOWN
            :undecided
          in Inference::DefinerResolution::ABSENT
            nil
          end
        end

        def explicit_non_self_receiver?(receiver)
          return false if receiver.nil?
          return false if receiver.is_a?(Prism::SelfNode)

          true
        end

        def build_visibility_mismatch_diagnostic(path, call_node, receiver_name)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_VISIBILITY_MISMATCH,
            path: path,
            message: "private method `#{call_node.name}' called on #{receiver_name} receiver",
            severity: :error,
            receiver_type: receiver_name,
            method_name: call_node.name.to_s
          )
        end

        private_class_method :instance_visibility_mismatch, :singleton_visibility_mismatch,
                             :private_singleton_candidate?, :private_recorded_names, :load_time_call?,
                             :singleton_wildcard_contested?, :missing_hook_on_chain?, :records_hook?,
                             :reached_definer_visibility, :explicit_non_self_receiver?,
                             :build_visibility_mismatch_diagnostic
      end
    end
  end
end
