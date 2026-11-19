# frozen_string_literal: true

require_relative "../../analysis/dependency_recorder"
require_relative "../../memo_audit"
require_relative "../../reflection"
require_relative "../../type"
require_relative "../../typing_state"
require_relative "../block_call_timing"
require_relative "../external_ancestor_resolution"
require_relative "project_patched"
require_relative "rbs_dispatch"
# Last, as `method_dispatcher.rb` required it ahead of the two memos below (#2399): what it loads declares its slots
# first, so the memos keep their place in `Rigor::TypingState.slots`.
require_relative "../../run_scoped_slots"

module Rigor
  module Inference
    module MethodDispatcher
      # The user-class ancestor fallback (Slice 7 phase 10): a receiver Rigor knows by name but not by RBS is retried
      # against `Object` (an instance, or an instance of an RBS-known module) or `Class` (a class object), so `puts`,
      # `raise` and `attr_reader` resolve on a class the project wrote without a signature. `MethodDispatcher.resolve`
      # asks it behind every other tier that reads the receiver's class and records the origin of a `Dynamic` answer,
      # so it is a call there and a member of no tier array.
      #
      # It declines where Ruby would not reach `Object` first: a name a core or stdlib ancestor of the class declares
      # (#2196), and a class object whose singleton chain holds a project definer of the name (#2284). On an explicit
      # receiver it answers no private method; `ProjectPatched.explicit_non_self_receiver?` reads the call node for it.
      #
      # The two memos it keeps are `Rigor::TypingState` slots, declared when this file loads. `method_dispatcher.rb`
      # requires it behind every file that declares a slot of its own, which is where the two declarations stood in
      # that file's body, so they keep their place in `Rigor::TypingState.slots`.
      module UserClassFallback
        module_function

        def try_dispatch(context)
          receiver_type = context.receiver
          environment = context.environment
          call_node = context.call_node
          return nil if environment.nil?

          fallback_receiver = user_class_fallback_receiver(receiver_type, environment)
          return nil if fallback_receiver.nil?
          return nil if declared_by_external_ancestor?(receiver_type, environment, context)
          return nil if project_singleton_definer?(receiver_type, context)

          # Preserve the ORIGINAL receiver type as the `self` substitution so `Kernel#dup: () ->
          # self` and other `self`-returning methods route through Object's RBS while still
          # returning the caller's type rather than `Object`. Without this, `base = self.dup`
          # inside a `Bundler::URI::Generic` instance method types `base` as `Object` because
          # `Bundler::URI::Generic` is not in RBS and the fallback's `self` resolves to Object.
          #
          # `public_only:` — when the call has an EXPLICIT, non-`self` receiver
          # (`Favourite.select(...)`), suppress the private `Object`/`Kernel`/`Class` methods the
          # fallback would otherwise resolve. Ruby raises `NoMethodError` for a private method
          # called with an explicit receiver, so resolving `Favourite.select` to the private
          # `Kernel#select` (`-> Array[String]`) is a confidently-wrong type. Implicit-self /
          # `self.`-receiver calls (`puts`, `raise`, `require`) keep resolving — those are the
          # fallback's intended targets.
          RbsDispatch.try_dispatch(
            context.with(
              receiver: fallback_receiver,
              self_type_override: receiver_type,
              public_only: ProjectPatched.explicit_non_self_receiver?(call_node),
              call_node: nil, scope: nil
            )
          )
        end

        # Issue #2196 — a project class whose ancestry reaches a core or stdlib class before `Object` (`class FL <
        # Array`) answers a name that class declares from that class, not from `Object` / `Kernel`: Ruby dispatches
        # `select { … }` on an `FL` to `Array#select`, never to the private `Kernel#select` (`-> Array[String]`). The
        # ancestor tiers decline such a name where they cannot type it (`RbsDispatch#returns_the_walked_ancestry?`),
        # and the `Object` fallback then fabricated `Kernel#select`'s answer, so `fields.detect { |f| f.errors }` read
        # `f` as `String`. The fallback declines the name instead, which leaves the call `Dynamic[top]`.
        # {ExternalAncestorResolution.resolve} answers nil for a name only `Object`, `Kernel` or `BasicObject` declares,
        # so `puts` and `raise` keep resolving.
        def declared_by_external_ancestor?(receiver_type, environment, context)
          return false unless receiver_type.is_a?(Type::Nominal)

          scope = context.scope
          return false if scope.nil?

          class_name = receiver_type.class_name
          method_name = context.method_name
          if MemoAudit.enabled? && MemoAudit.suspended?
            return external_ancestor_declares?(class_name, method_name, scope,
                                               environment)
          end

          memo = external_ancestor_memo(scope, environment)
          key = [class_name, method_name]
          if memo.key?(key)
            return MemoAudit.check("user class fallback external ancestor", memo[key], class_name, method_name) do
              external_ancestor_declares?(class_name, method_name, scope, environment)
            end
          end

          memo[key] = MemoAudit.key_audit("user class fallback external ancestor") do
            external_ancestor_declares?(class_name, method_name, scope, environment)
          end
        end

        def external_ancestor_declares?(class_name, method_name, scope, environment)
          !ExternalAncestorResolution.resolve(class_name, method_name, :instance,
                                              scope: scope, environment: environment, record_dependencies: false).nil?
        end

        # Issue #2284 — a class object whose singleton chain holds a project definer of the name (its own `def
        # self.name`, one a project superclass wrote, an `extend`ed module's `def name`) answers from that definer,
        # not from `Module#name` / `Class#…` on the `Singleton[Object]` fallback: Ruby's singleton ancestry puts
        # every project entry ahead of `Class`. The fallback declines so the typer's singleton-body inference
        # answers the definer's return, or `Dynamic` where the slot is contested and the def may not be the one
        # that runs.
        #
        # The chain walk files the class edge of every entry it passes, so it runs only for a name some project file
        # defines at all ({BlockCallTiming.project_defines_anywhere?}, which files the `defines:<name>` edge either way,
        # #1459). Without it every class-body `private` / `attr_reader` call on a project class would depend on its
        # whole ancestry. The by-name answer is memoised per discovery index; the edge is filed on every call.
        def project_singleton_definer?(receiver_type, context)
          return false unless receiver_type.is_a?(Type::Singleton)

          scope = context.scope
          return false if scope.nil?
          return false unless project_defines_name?(scope, context.method_name)

          !scope.singleton_def_through_ancestors(receiver_type.class_name, context.method_name).last.nil?
        end

        def project_defines_name?(scope, method_name)
          if MemoAudit.enabled? && MemoAudit.suspended?
            return BlockCallTiming.project_defines_anywhere?(method_name,
                                                             scope)
          end

          memo = defines_name_memo(scope)
          if memo.key?(method_name)
            Analysis::DependencyRecorder.read_missing(:defines, method_name) if Analysis::DependencyRecorder.active?
            return MemoAudit.check("user class fallback defines name", memo[method_name], method_name) do
              BlockCallTiming.project_defines_anywhere?(method_name, scope)
            end
          end

          memo[method_name] = MemoAudit.key_audit("user class fallback defines name") do
            BlockCallTiming.project_defines_anywhere?(method_name, scope)
          end
        end

        # ADR-129 WD1 — a run-scoped Memo: one slot keyed on the identity of the discovery index and the environment,
        # the only inputs the name table's answers read.
        DEFINES_NAME_MEMO = TypingState.memo(
          :user_class_fallback_defines_name,
          run_scoped: true, audit: "user class fallback defines name",
          reason: "one [discovery, environment, names] slot keyed on the identities of the discovery " \
                  "index and the environment; each name's answer reads only them"
        )
        private_constant :DEFINES_NAME_MEMO

        # One slot per discovery index and environment, as {#external_ancestor_memo} keeps its own: the answer reads
        # only the frozen discovery tables and the environment's `pre_eval:` patches.
        def defines_name_memo(scope)
          discovery = scope.discovery
          environment = scope.environment
          state = TypingState.current
          slot = state[DEFINES_NAME_MEMO]
          unless slot && slot[0].equal?(discovery) && slot[1].equal?(environment)
            slot = [discovery, environment, {}]
            state[DEFINES_NAME_MEMO] = slot
          end
          slot[2]
        end

        # ADR-129 WD1 — a run-scoped Memo, keyed as {DEFINES_NAME_MEMO} is.
        EXTERNAL_ANCESTOR_MEMO = TypingState.memo(
          :user_class_fallback_external_ancestor,
          run_scoped: true, audit: "user class fallback external ancestor",
          reason: "one [discovery, environment, answers] slot keyed on the identities of the " \
                  "discovery index and the RBS environment, the only inputs the walk reads"
        )
        private_constant :EXTERNAL_ANCESTOR_MEMO

        # One slot per discovery index and environment, as `RbsDispatch#ancestor_memo_slot` keeps its own: the answer
        # reads only the frozen discovery tables and the RBS environment, and its walk is withheld from dependency
        # recording, so it may be served again for the same pair.
        def external_ancestor_memo(scope, environment)
          discovery = scope.discovery
          state = TypingState.current
          slot = state[EXTERNAL_ANCESTOR_MEMO]
          unless slot && slot[0].equal?(discovery) && slot[1].equal?(environment)
            slot = [discovery, environment, {}]
            state[EXTERNAL_ANCESTOR_MEMO] = slot
          end
          slot[2]
        end

        def user_class_fallback_receiver(receiver_type, environment)
          case receiver_type
          when Type::Nominal
            # Modules: even when RBS knows the module, an instance method on a mixin-only module
            # (e.g. `PP::ObjectMixin`) observes Kernel / Object methods through every concrete
            # includer's ancestor chain. Route through the `Nominal[Object]` fallback so
            # `self.inspect` / `self.respond_to?` / `self.class` resolve cleanly when the module
            # itself does not declare them.
            known = Rigor::Reflection.rbs_class_known?(receiver_type.class_name, environment: environment)
            return environment.nominal_for_name("Object") if !known || environment.rbs_module?(receiver_type.class_name)

            nil
          when Type::Singleton
            return nil if Rigor::Reflection.rbs_class_known?(receiver_type.class_name, environment: environment)

            environment.singleton_for_name("Class")
          end
        end
      end
    end
  end
end
